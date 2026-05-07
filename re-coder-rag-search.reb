REBOL [
    Title:   {Re Coder RAG Search — Document Retrieval}
    Name:    're-coder-rag-search
    Purpose: {Retrieval layer for re-coder-rag. Searches local filesystem
              and calls configured RAG service APIs.}
]

; ═══════════════════════════════════════════════════════════
;  Grep-based local file search
; ═══════════════════════════════════════════════════════════

rag-grep: func [
    query       [string!]
    dir-path    [file! string! none!]
    extensions  [block! none!]
    max-results [integer! none!]
    /local cmd results ext-glob-rg ext-include-grep grep-ext parsed line parts file rest line-num dir-for-shell colon-at
] [
    dir-path:   any [dir-path   %.]
    max-results: any [max-results 20]
    dir-for-shell: mold to-string to-rebol-file dir-path


    ; Extension filters: ripgrep uses --glob; BSD/GNU grep uses --include.
    ext-glob-rg: copy {}
    ext-include-grep: copy {}
    if extensions [
        foreach ext extensions [
            pat: rejoin [{*} to-string ext]
            append ext-glob-rg rejoin [{--glob '} pat {' }]
            append ext-include-grep rejoin [{--include='} pat {' }]
        ]
    ]

    ; Prefer ripgrep when installed; use exit status + stdout, not attempt (call returns exit code, often truthy).
    rg-available: false
    out: copy {}
    if zero? call/wait/shell/output {command -v rg 2>/dev/null} out [
        if not empty? trim to-string out [rg-available: true]
    ]

    cmd: either rg-available [
        rejoin [{rg -n -i --max-count 1 } ext-glob-rg {-- } mold query { } dir-for-shell { 2>/dev/null | head -n } max-results]
    ][
        ; Trailing space before mold query avoids zsh glob ('--include=*"pat"') and broken grep args.
        grep-ext: either extensions [ext-include-grep][rejoin [{--include='*' }]]
        rejoin [{grep -rn -i } grep-ext mold query { } dir-for-shell { 2>/dev/null | head -n } max-results]
    ]

    results: any [
        attempt [
            out: copy {}
            call/wait/shell/output cmd out
            trim to-string out
        ]
        {}
    ]

    either empty? results [copy []][
        ; Parse "file:line:content" format
        parsed: copy []
        foreach line split results newline [
            if empty? trim line [continue]
            parts: split line {：}  ; try Chinese colon
            if (length? parts) < 2 [parts: split line {:}]
            if (length? parts) < 2 [continue]

            file: trim parts/1
            rest: trim copy/part at line (1 + length? file) 9999
            rest: trim rest
            if (first rest) = #":" [rest: trim copy next rest]
            if (first rest) = #":" [rest: trim copy next rest]

            line-num: 1
            colon-at: find rest #":"
            if colon-at [
                line-num: any [attempt [to-integer trim copy/part rest colon-at] 1]
                rest: trim copy next colon-at
            ]

            append/only parsed make map! reduce [
                #file  file
                #line  line-num
                #match trim rest
            ]
        ]
        parsed
    ]
]

; ═══════════════════════════════════════════════════════════
;  Read file snippet around a match
; ═══════════════════════════════════════════════════════════

rag-read-snippet: func [
    file-path [file! string!]
    line-num  [integer!]
    lines     [integer! none!]
    /local start end content lines-data snippet prefix i
] [
    lines:    any [lines 5]
    start: max 1 (line-num - lines)
    end: line-num + lines

    content: any [
        attempt [to-string read file-path]
        {}
    ]

    lines-data: split content newline
    snippet: copy {}
    for i start (min end (length? lines-data)) 1 [
        prefix: either i = line-num [{>>> }][{    }]
        append snippet rejoin [prefix i {: } pick lines-data i newline]
    ]

    snippet
]

; ═══════════════════════════════════════════════════════════
;  Search and retrieve full context
; ═══════════════════════════════════════════════════════════

rag-search: func [
    query       [string!]
    dir-path    [file! string! none!]
    extensions  [block! none!]
    max-results [integer! none!]
    /local results snippets hit snippet
] [
    dir-path:   any [dir-path  %.]
    max-results: any [max-results 10]

    results: rag-grep query dir-path extensions max-results

    if empty? results [return copy []]

    ; Enrich with snippet context
    foreach hit results [
        snippet: rag-read-snippet to-rebol-file hit/file hit/line 5
        hit/snippet: snippet
    ]

    results
]

; ═══════════════════════════════════════════════════════════
;  Build context string from search results
; ═══════════════════════════════════════════════════════════

rag-build-context: func [
    results [block!]
    /local ctx buf
] [
    if empty? results [return {No relevant documents found.}]

    ctx: copy {}
    foreach hit results [
        append ctx rejoin [
            {### } hit/file { (line } hit/line {) newline}
            {``` newline}
            hit/snippet
            {``` newline newline}
        ]
    ]

    copy ctx
]

; ═══════════════════════════════════════════════════════════
;  LLM-powered question answering over retrieved context
; ═══════════════════════════════════════════════════════════

rag-ask: func [
    query       [string!]
    dir-path    [file! string! none!]
    extensions  [block! none!]
    max-results [integer! none!]
    /model name       [string!]
    /url endpoint     [string!]
    /key secret       [string!]
    /local results context system-prompt response messages model-name api-url api-key
] [
    dir-path:   any [dir-path  %.]
    max-results: any [max-results 8]

    ; Step 1: Search
    results: rag-search query dir-path extensions max-results

    if empty? results [
        return {No relevant documents found for your query.}
    ]

    ; Step 2: Build context
    context: rag-build-context results

    ; Step 3: LLM call (/model, /url, /key override defaults)
    model-name: any [name {deepseek-chat}]
    api-url: any [endpoint {https://api.deepseek.com/v1}]
    api-key: any [secret get-env {DEEPSEEK_API_KEY}]
    if none? api-key [return {Error: No API key. Set DEEPSEEK_API_KEY or use /key "..." .}]

    system-prompt: {
You are a codebase expert. Answer the user's question based ONLY on the provided code context.
If the context doesn't contain enough information to answer, say so clearly.
Cite file names and line numbers in your answer.
}

    messages: make map! reduce [
        #model model-name
        #messages reduce [
            make map! reduce [#role {system} #content system-prompt]
            make map! reduce [#role {user} #content rejoin [{Code context: newline} context {newlineQuestion: } query]]
        ]
        #temperature 0.3
        #max_tokens 4096
    ]

    response: attempt [http-post-json api-url api-key messages]
    either response [
        either find response 'choices [
            choices: response/choices
            either empty? choices [
                {No response generated.}
            ][
                msg: choices/1/message
                rejoin [
                    msg/content newline newline
                    {--- newline}
                    {Retrieved from: } (length? results) { file(s) newline}
                ]
            ]
        ][
            rejoin [{API error: } mold response]
        ]
    ][
        {Failed to call LLM API.}
    ]
]

; ═══════════════════════════════════════════════════════════
;  HTTP POST helper for LLM calls
; ═══════════════════════════════════════════════════════════

http-post-json: func [
    url     [string!]
    api-key [string!]
    body    [map!]
    /local cmd tmpfile result
] [
    tmpfile: rejoin [{/tmp/hermes-rag-} random 999999 {.json}]
    write to-rebol-file tmpfile to-json body

    cmd: rejoin [
        {curl -s -X POST } mold url {/chat/completions}
        { -H 'Content-Type: application/json'}
        { -H 'Authorization: Bearer } api-key {'}
        { -d @} tmpfile
    ]

    result: attempt [
        out: copy {}
        call/wait/shell/output cmd out
        to-string out
    ]

    attempt [delete to-rebol-file tmpfile]

    either all [string? result  not empty? result] [
        attempt [load-json result]
    ][
        none
    ]
]

; ═══════════════════════════════════════════════════════════
;  Simple index: list files in directory
; ═══════════════════════════════════════════════════════════

rag-index-files: func [
    dir-path    [file! string! none!]
    extensions  [block! none!]
    /local files filtered f f-str ext
] [
    dir-path: any [dir-path  %.]
    files: attempt [read to-rebol-file dir-path]
    if none? files [return copy []]

    filtered: copy []
    foreach f files [
        f-str: to-string f
        either extensions [
            foreach ext extensions [
                if find f-str to-string ext [
                    append filtered f
                    break
                ]
            ]
        ][
            unless find f-str {.git} [append filtered f]
        ]
    ]

    filtered
]

print {re-coder-rag-search loaded. Available: rag-grep, rag-search, rag-ask, rag-index-files}
