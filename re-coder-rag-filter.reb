REBOL [
    Title:   {Re Coder RAG Doc Filter — LLM-based document relevance scoring}
    Name:    're-coder-rag-filter
    Purpose: {Filter retrieved documents by asking LLM to score relevance
              against the conversation. Returns only relevant docs.}
]

; ═══════════════════════════════════════════════════════════
;  Dependencies
; ═══════════════════════════════════════════════════════════

; http-post-json and api config from re-coder-rag-search
unless value? 'http-post-json [
    do %./re-coder-rag-search.reb
]

; Default API config
rag-api-config: make map! reduce [
    #model      {deepseek-chat}
    #api-url    {https://api.deepseek.com/v1}
    #api-key    none     ; set from env on first use
]

; ═══════════════════════════════════════════════════════════
;  Internal helpers
; ═══════════════════════════════════════════════════════════

; Ensure API key is set
ensure-api-key: does [
    unless rag-api-config/api-key [
        rag-api-config/api-key: any [
            get-env {DEEPSEEK_API_KEY}
            get-env {OPENAI_API_KEY}
            {}
        ]
    ]
]

; Build conversation text for prompt
build-conv-text: func [conversations [block!] /local out msg] [
    out: copy {}
    foreach msg conversations [
        role: any [select msg 'role  select msg #role  {unknown}]
        content: any [select msg 'content  select msg #content  {}]
        append out rejoin [{<} role {>: } content newline]
    ]
    out
]

; Build document text for prompt
build-doc-text: func [doc [map! string!] /local file content] [
    either map? doc [
        file:    any [select doc 'file   select doc #file   {unknown}]
        content: any [select doc 'content select doc #content {}]
        rejoin [{File: } file newline {Content: newline} content]
    ][
        doc  ; raw string
    ]
]

; Parse LLM response: "yes/8" or "no/3" or "yes/<8>" etc.
parse-relevance: func [response [string!] /local lower clean parts] [
    lower: lowercase trim response
    ; Try yes/<N> or no/<N>
    clean: copy lower
    ; Remove markdown formatting
    replace/all clean {```} {}
    replace/all clean {**} {}
    replace/all clean {__} {}
    clean: trim clean

    ; Extract first line
    if find clean newline [clean: copy/part clean find clean newline]

    ; Look for yes/ or no/
    either parse clean [thru {yes} thru {/} copy rest to end] [
        rest: trim rest
        ; Strip angle brackets: <8> → 8
        if all [not empty? rest  (first rest) = #"<"] [
            rest: copy next rest
            if (last rest) = #">" [rest: copy/part rest (length? rest) - 1]
        ]
        score: attempt [to-integer rest]
        either all [integer? score  score >= 0  score <= 10] [
            reduce [true score]
        ][
            reduce [false 0]
        ]
    ][
        either parse clean [thru {no} thru {/} copy rest to end] [
            score: attempt [to-integer trim rest]
            either all [integer? score  score >= 0  score <= 10] [
                reduce [false score]
            ][
                reduce [false 0]
            ]
        ][
            ; Fallback: look for a number
            nums: copy {}
            foreach c clean [if find {0123456789} c [append nums c]]
            score: either empty? nums [0] [attempt [to-integer nums]]
            if find clean {yes} [return reduce [true any [score 5]]]
            if find clean {no}  [return reduce [false any [score 0]]]
            reduce [false 0]
        ]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Main filter function
; ═══════════════════════════════════════════════════════════

rag-doc-filter: func [
    conversations [block!]    ; [{role: "user" content: "..."} ...]
    documents     [block!]    ; [{file: "a.py" content: "..."} ...]
    /threshold thresh [integer!]  ; minimum relevance score (default 5)
    /model  model-name  [string!]
    /url    api-url     [string!]
    /key    api-key     [string!]
    /local conv-text sys-prompt user-prompt response parsed relevant score docs-with-scores api-model api-url-final api-key-final i doc doc-text msgs
] [
    ensure-api-key
    if empty? rag-api-config/api-key [
        return make map! reduce [
            #error  {No API key. Set DEEPSEEK_API_KEY environment variable.}
            #filtered copy []
            #scores  copy []
        ]
    ]

    thresh:     any [thresh 5]
    api-model:  any [model-name  select rag-api-config 'model  {deepseek-chat}]
    api-url-final: any [api-url  select rag-api-config 'api-url  {https://api.deepseek.com/v1}]
    api-key-final: any [api-key  rag-api-config/api-key]

    conv-text: build-conv-text conversations

    ; Process each document sequentially
    filtered: copy []
    scores: copy []

    i: 1
    doc-count: length? documents

    foreach doc documents [
        doc-text: build-doc-text doc

        ; Build prompt
        system-prompt: {
You are a document relevance judge. Given a conversation history and a document,
determine if the document is relevant to answering the user's last question.

Reply with EXACTLY one line: yes/<score> or no/<score>
where <score> is 0-10 (10=highly relevant, 0=completely irrelevant).

Do NOT include explanations, just the score line.
}

        user-prompt: rejoin [
            {Conversation history:}  newline conv-text    newline
            {Document to evaluate:} newline doc-text      newline
            {Is this document relevant to the user's last question?}
        ]

        msgs: make map! reduce [
            #model model-name
            #messages reduce [
                make map! reduce [#role {system} #content system-prompt]
                make map! reduce [#role {user}   #content user-prompt]
            ]
            #temperature 0.0
            #max_tokens 64
        ]

        response: http-post-json api-url-final api-key-final msgs

        ; Parse response
        either all [map? response  select response 'choices] [
            choices: select response 'choices
            either all [block? choices  not empty? choices] [
                msg: select choices/1 'message
                content: either map? msg [any [select msg 'content {}]] [
                    ; Fallback: try text key
                    any [select choices/1 'text  select choices/1 'content]
                ]
                if string? content [
                    parsed: parse-relevance content
                    relevant: parsed/1
                    score:    parsed/2
                    print rejoin [{  [} i {/} doc-count {] } either relevant [{✓}][{✗}] { score=} score { } either map? doc [select doc 'file][{text}]]

                    append scores make map! reduce [
                        #score score
                        #relevant relevant
                    ]

                    if score >= thresh [
                        if map? doc [
                            doc-score: copy doc
                            put doc-score 'relevance_score score
                            append/only filtered doc-score
                        ][
                            append/only filtered make map! reduce [
                                #file {text-doc}
                                #content doc
                                #relevance_score score
                            ]
                        ]
                    ]
                ]
            ][
                ; API error
                ; Include doc anyway on API failure
                if map? doc [append/only filtered doc]
            ]
        ][
            ; API call failed — include doc anyway
            if map? doc [append/only filtered doc]
        ]

        i: i + 1
    ]

    make map! reduce [
        #filtered filtered
        #scores    scores
        #total     doc-count
        #kept      length? filtered
    ]
]

; ═══════════════════════════════════════════════════════════
;  Convenience: set API config
; ═══════════════════════════════════════════════════════════

rag-filter-config: func [
    /model m [string!]
    /url   u [string!]
    /key   k [string!]
] [
    if model [put rag-api-config 'model m]
    if url   [put rag-api-config 'api-url u]
    if key   [put rag-api-config 'api-key k]
    rag-api-config
]

print {re-coder-rag-filter loaded. Available: rag-doc-filter, rag-filter-config}
