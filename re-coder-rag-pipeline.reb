REBOL [
    Title:   {Re Coder RAG Pipeline — Multi-Query, Token Windowing, 3-Phase RAG}
    Name:    're-coder-rag-pipeline
    Purpose: {Multi-query expansion, token-aware document chunking, and
              3-phase pipeline (retrieve → filter+chunk → QA).}
]

; ═══════════════════════════════════════════════════════════
;  Dependencies
; ═══════════════════════════════════════════════════════════

unless value? 'rag-search [do %./re-coder-rag-search.reb]
unless value? 'rag-doc-filter [do %./re-coder-rag-filter.reb]

; ═══════════════════════════════════════════════════════════
;  Utilities
; ═══════════════════════════════════════════════════════════

; Approximate token count (4 chars ≈ 1 token)
est-tokens: func [s [string!]] [to-integer (length? s) / 4]

; Build conversation text for prompts
build-conv-text: func [convs [block!] /local out msg role content] [
    out: copy {}
    foreach msg convs [
        role:    any [select msg 'role  select msg #role  {unknown}]
        content: any [select msg 'content select msg #content {}]
        append out rejoin [{<} role {>: } content newline]
    ]
    out
]

; ═══════════════════════════════════════════════════════════
;  Phase 0: Multi-Query Expansion
;  Converts conversation → multiple search queries
; ═══════════════════════════════════════════════════════════

rag-expand-queries: func [
    conversations  [block!]     ; [{role: "user" content: "..."} ...]
    /max max-n    [integer!]   ; max queries (default 3)
    /model m      [string!]
    /url   u      [string!]
    /key   k      [string!]
    /local conv-text api-model api-url api-key system-prompt user-prompt msgs response content parsed queries
] [
    max-n:    any [max-n 3]
    api-model: any [m  select rag-api-config 'model  {deepseek-chat}]
    api-url:  any [u  select rag-api-config 'api-url  {https://api.deepseek.com/v1}]
    api-key:  any [k  rag-api-config/api-key  get-env {DEEPSEEK_API_KEY}  {}]

    if empty? api-key [return copy []]

    conv-text: build-conv-text conversations

    system-prompt: {
You are a search query generator. Analyze the conversation and generate search queries
to retrieve relevant knowledge from a codebase.

Output ONLY valid JSON — no markdown, no explanation:
{
  "queries": [
    {"query": "specific search term", "importance": 8, "purpose": "why this query helps"}
  ]
}

Requirements:
- importance: 1-10 (higher = more critical to answer the question)
- purpose:  one sentence explaining what this query should find
- Queries should be diverse — different keywords and angles
- Focus on the user's LAST question and its context
}

    user-prompt: rejoin [
        {Conversation:} newline conv-text newline
        {Generate up to } max-n { search queries to find relevant code. Output JSON only.}
    ]

    msgs: make map! reduce [
        #model api-model
        #messages reduce [
            make map! reduce [#role {system} #content system-prompt]
            make map! reduce [#role {user}   #content user-prompt]
        ]
        #temperature 0.3
        #max_tokens 1024
    ]

    response: http-post-json api-url api-key msgs
    unless all [map? response  select response 'choices] [return copy []]

    content: any [
        attempt [select (select response 'choices)/1/message 'content]
        {}
    ]

    ; Extract JSON from response (might be wrapped in ```json)
    json-str: content
    if find json-str {```json} [
        parse json-str [thru {```json} copy json-str to {```}]
    ]
    if find json-str {```} [
        parse json-str [thru {```} copy json-str to {```}]
    ]

    parsed: attempt [load-json json-str]
    unless map? parsed [return copy []]

    query-items: any [select parsed 'queries  select parsed {queries}  []]
    unless block? query-items [return copy []]

    ; Normalize and filter
    queries: copy []
    foreach q query-items [
        if map? q [
            q-text: any [select q 'query  select q {query}  {}]
            q-imp:  any [attempt [to-integer select q 'importance] 5]
            q-purp: any [select q 'purpose  select q {purpose}  {}]
            unless empty? q-text [
                append/only queries make map! reduce [
                    #query      q-text
                    #importance q-imp
                    #purpose    q-purp
                ]
            ]
        ]
        if (length? queries) >= max-n [break]
    ]

    queries
]

; ═══════════════════════════════════════════════════════════
;  Phase 1: Multi-Query Search
;  Runs rag-search for each expanded query, merges results
; ═══════════════════════════════════════════════════════════

rag-multi-search: func [
    queries       [block!]     ; from rag-expand-queries
    dir-path      [file! string! none!]
    extensions    [block! none!]
    /local all-results seen query hit-key result-key merged i q
] [
    all-results: copy []
    seen: copy #[]

    foreach q queries [
        query-text: select q 'query
        if none? query-text [continue]

        results: rag-search query-text dir-path extensions 10

        foreach hit results [
            hit-key: rejoin [hit/file {:} hit/line]
            unless select seen hit-key [
                put seen hit-key true
                put hit 'source_query query-text
                put hit 'importance    any [select q 'importance 5]
                append/only all-results hit
            ]
        ]
    ]

    ; Sort by importance (if multiple queries), then by file path
    sort/compare all-results func [a b] [
        imp-a: any [select a 'importance 0]
        imp-b: any [select b 'importance 0]
        either imp-a <> imp-b [imp-b < imp-a] [
            (to-string select a 'file) < (to-string select b 'file)
        ]
    ]

    all-results
]

; ═══════════════════════════════════════════════════════════
;  Phase 2: Token-Aware Document Windowing
;  Takes full documents + conversation, extracts relevant
;  line ranges to fit within token budget
; ═══════════════════════════════════════════════════════════

rag-token-window: func [
    conversations  [block!]     ; conversation history
    documents      [block!]     ; [{file: "a.py" content: "..."} ...]
    /limit token-limit [integer!]  ; max total tokens (default 8000)
    /model m [string!]
    /url   u [string!]
    /key   k [string!]
    /local api-model api-url api-key conv-text doc-texts system-prompt user-prompt msgs response content json-str parsed windows result i doc file content-text
] [
    token-limit: any [token-limit 8000]
    api-model:   any [m  select rag-api-config 'model  {deepseek-chat}]
    api-url:     any [u  select rag-api-config 'api-url  {https://api.deepseek.com/v1}]
    api-key:     any [k  rag-api-config/api-key  get-env {DEEPSEEK_API_KEY}  {}]

    if empty? api-key [return documents]  ; fallback: return all docs

    if empty? documents [return copy []]

    conv-text: build-conv-text conversations

    ; Build document text with line numbers
    doc-texts: copy {}
    foreach doc documents [
        file: any [select doc 'file  select doc #file  {unknown}]
        content-text: any [select doc 'content  select doc #content  {}]
        append doc-texts rejoin [{=== } file { ===} newline]
        cnt: 0
        foreach line split content-text newline [
            cnt: cnt + 1
            append doc-texts rejoin [cnt {: } line newline]
        ]
        append doc-texts newline
    ]

    system-prompt: {
You are a document chunker. Given a conversation and documents with line numbers,
identify the specific line ranges that are relevant to answering the user's question.

Output ONLY valid JSON:
{
  "ranges": [
    {"file": "path.py", "start": 10, "end": 25, "relevance": "why these lines matter"}
  ]
}

Rules:
- Only include lines that DIRECTLY help answer the user's last question
- Total extracted lines should fit within a reasonable context window
- Merge overlapping ranges in the same file
- Maximum 5 ranges total
- If nothing is relevant, return empty ranges array
}

    user-prompt: rejoin [
        {Conversation:} newline conv-text newline
        {Documents (with line numbers):} newline doc-texts newline
        {Which specific line ranges are relevant? Return JSON with line numbers.}
    ]

    msgs: make map! reduce [
        #model api-model
        #messages reduce [
            make map! reduce [#role {system} #content system-prompt]
            make map! reduce [#role {user}   #content user-prompt]
        ]
        #temperature 0.1
        #max_tokens 2048
    ]

    response: http-post-json api-url api-key msgs
    unless all [map? response  select response 'choices] [return documents]

    content: any [
        attempt [select (select response 'choices)/1/message 'content]
        {}
    ]

    ; Extract JSON
    json-str: content
    if find json-str {```json} [parse json-str [thru {```json} copy json-str to {```}]]
    if find json-str {```}     [parse json-str [thru {```}     copy json-str to {```}]]

    parsed: attempt [load-json json-str]
    unless map? parsed [return documents]  ; fallback: return all docs

    ranges: any [select parsed 'ranges  select parsed {ranges}  []]
    unless block? ranges [return documents]

    if empty? ranges [return documents]

    ; Extract content within ranges from original documents
    windows: copy []
    foreach r ranges [
        unless map? r [continue]
        r-file: any [select r 'file  select r {file}  {}]
        r-start: any [attempt [to-integer select r 'start] 1]
        r-end:   any [attempt [to-integer select r 'end]   999999]
        r-reason: any [select r 'relevance  select r {relevance}  {}]

        ; Find matching document
        foreach doc documents [
            doc-file: any [select doc 'file  select doc #file  {}]
            if doc-file <> r-file [continue]

            doc-content: any [select doc 'content  select doc #content  {}]
            lines: split doc-content newline
            extracted: copy {}
            for line-num r-start (min r-end (length? lines)) 1 [
                if line-num <= length? lines [
                    append extracted rejoin [line-num {: } pick lines line-num newline]
                ]
            ]

            unless empty? extracted [
                append/only windows make map! reduce [
                    #file      r-file
                    #start     r-start
                    #end       (min r-end (length? lines))
                    #content   trim extracted
                    #relevance r-reason
                ]
            ]
            break
        ]
    ]

    either empty? windows [documents] [windows]
]

; ═══════════════════════════════════════════════════════════
;  Result Ranking: boost files appearing in multiple queries
; ═══════════════════════════════════════════════════════════

rag-rank-results: func [
    results [block!]
    /local freq boosting base-score file-name ranked
] [
    if empty? results [return copy []]

    ; Count file frequency across query sources
    freq: copy #[]
    foreach hit results [
        fname: select hit 'file
        if fname [
            cnt: any [select freq fname 0]
            put freq fname cnt + 1
        ]
    ]

    ; Calculate boosted score for each hit
    boosting: copy []
    foreach hit results [
        fname: select hit 'file
        base-score: any [select hit 'importance 5]
        file-freq: any [select freq fname 1]
        ; Boost: files that appear across multiple queries get higher score
        boost: base-score * (file-freq ** 0.7)
        put hit 'boosted_score boost
        put hit 'file_frequency file-freq
        append/only boosting hit
    ]

    ; Sort by boosted_score desc, then file path
    sort/compare boosting func [a b] [
        score-a: any [select a 'boosted_score 0]
        score-b: any [select b 'boosted_score 0]
        either score-a <> score-b [score-b < score-a] [
            (to-string select a 'file) < (to-string select b 'file)
        ]
    ]

    ; Trim to top 20
    ranked: copy []
    count: 0
    foreach hit boosting [
        if count >= 20 [break]
        append/only ranked hit
        count: count + 1
    ]
    ranked
]

; ═════════════════════════════════════════════════════════==
;  Phase 3: Answer Generation over Filtered + Windowed Docs
; ═══════════════════════════════════════════════════════════

rag-answer: func [
    conversations  [block!]     ; conversation history
    documents      [block!]     ; filtered + windowed docs [{file: "a" content: "..."} ...]
    /model m       [string!]
    /url   u       [string!]
    /key   k       [string!]
    /local api-model api-url api-key conv-text doc-context system-prompt user-prompt msgs response content
] [
    api-model: any [m  select rag-api-config 'model  {deepseek-chat}]
    api-url:   any [u  select rag-api-config 'api-url  {https://api.deepseek.com/v1}]
    api-key:   any [k  rag-api-config/api-key  get-env {DEEPSEEK_API_KEY}  {}]

    if empty? api-key [return {Error: No API key configured.}]
    if empty? documents [return {No relevant documents found to answer the question.}]

    conv-text: build-conv-text conversations

    ; Build document context
    doc-context: copy {}
    foreach doc documents [
        file:    any [select doc 'file    select doc #file    {unknown}]
        content: any [select doc 'content  select doc #content  {}]
        append doc-context rejoin [
            {### } file newline
            {```} newline content newline {```} newline newline
        ]
    ]

    system-prompt: {
You are a codebase expert. Answer the user's question based ONLY on the provided
document context. If the context doesn't contain enough information, say so clearly.

Rules:
- Cite specific file names and line numbers when referencing code
- Be concise but thorough
- If the documents don't answer the question, state that clearly
- Do NOT make up information not present in the documents
}

    user-prompt: rejoin [
        {Conversation history:} newline conv-text newline
        {Relevant documents:}   newline doc-context newline
        {Based on the above, answer the user's last question.}
    ]

    msgs: make map! reduce [
        #model api-model
        #messages reduce [
            make map! reduce [#role {system} #content system-prompt]
            make map! reduce [#role {user}   #content user-prompt]
        ]
        #temperature 0.3
        #max_tokens 4096
    ]

    response: http-post-json api-url api-key msgs
    unless all [map? response  select response 'choices] [
        return {Error: LLM API call failed.}
    ]

    content: any [
        attempt [select (select response 'choices)/1/message 'content]
        {No response generated.}
    ]

    rejoin [
        content newline newline
        {---} newline
        {Sources: } (length? documents) { document(s)} newline
    ]
]

; ═══════════════════════════════════════════════════════════
;  Full 3-Phase Pipeline
; ═══════════════════════════════════════════════════════════

rag-pipeline: func [
    query         [string!]      ; user's question
    dir-path      [file! string! none!]
    extensions    [block! none!]
    /history  convs [block!]     ; conversation history (optional)
    /model m        [string!]
    /url   u        [string!]
    /key   k        [string!]
    /local conversations queries search-results filter-result documents windows answer
] [
    dir-path:   any [dir-path  %.]

    ; Build conversation block
    conversations: either history [convs] [
        reduce [
            make map! reduce [#role {user} #content query]
        ]
    ]

    ; Phase 0: Expand query into multiple search queries
    print {[Phase 0] Expanding query...}
    queries: rag-expand-queries/max conversations 3
    if empty? queries [
        queries: reduce [make map! reduce [#query query #importance 10 #purpose {Original query}]]
    ]
    print rejoin [{  Generated } (length? queries) { queries}]
    foreach q queries [
        print rejoin [{    [} select q 'importance {] } select q 'query]
    ]

    ; Phase 1: Multi-query search + rank
    print {[Phase 1] Searching with multiple queries...}
    raw-results: rag-multi-search queries dir-path extensions
    search-results: rag-rank-results raw-results
    print rejoin [{  Found } (length? search-results) { ranked results (from } (length? raw-results) { raw)}]

    if empty? search-results [
        return {No relevant files found in the codebase.}
    ]

    ; Load content from cache or read files
    ; (In future: integrate with rag-cache)
    documents: copy []
    foreach hit search-results [
        file-path: hit/file
        content: any [
            attempt [to-string read to-rebol-file file-path]
            {}
        ]
        unless empty? content [
            append/only documents make map! reduce [
                #file    file-path
                #content content
                #line    hit/line
                #match   any [select hit 'match {}]
            ]
        ]
    ]

    print rejoin [{  Loaded } (length? documents) { documents}]

    ; Phase 2: Filter + Window
    print {[Phase 2] Filtering and windowing documents...}
    filter-result: rag-doc-filter/threshold conversations documents 5
    filtered-docs: select filter-result 'filtered
    print rejoin [{  Filter kept } (length? filtered-docs) { / } (length? documents) { documents}]

    if empty? filtered-docs [
        return {All retrieved documents were filtered out as irrelevant.}
    ]

    ; Apply token windowing to fit context budget
    documents-for-qa: rag-token-window/limit conversations filtered-docs 8000
    print rejoin [{  After windowing: } (length? documents-for-qa) { chunks}]

    ; Phase 3: Answer
    print {[Phase 3] Generating answer...}
    answer: rag-answer conversations documents-for-qa

    answer
]

print {re-coder-rag-pipeline loaded. Available: rag-expand-queries, rag-multi-search, rag-token-window, rag-answer, rag-pipeline}
