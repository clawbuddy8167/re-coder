REBOL [
    Title:   {Re Coder Background Worker}
    Name:    're-coder-bg-worker
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Background worker process for re-coder CLI sessions.
              Spawned by the main CLI when a session is sent to /bg.
              Runs the agent loop independently, writing output to session files.}
]

; ═══════════════════════════════════════════════════════════
;  Load Dependencies
; ═══════════════════════════════════════════════════════════

do %./re-coder-agent-stream.reb

; ═══════════════════════════════════════════════════════════
;  Worker State
; ═══════════════════════════════════════════════════════════

worker: make object! [
    session-id:   none
    session-dir:  none
    state-file:   none
    output-file:  none
    conv-file:    none
    conversation: copy []
    user-prompt:  ""
    running:      true
]

; ═══════════════════════════════════════════════════════════
;  File I/O Helpers
; ═══════════════════════════════════════════════════════════

write-output: func [text [string!]] [
    write/append to-rebol-file worker/output-file text
]

write-state: func [state [string!] /local json nl][
    nl: newline
    json: rejoin [
        "{" nl
        {  "id": "} worker/session-id {",} nl
        {  "state": "} state {",} nl
        {  "created": "} now {",} nl
        {  "summary": "} worker/user-prompt {",} nl
        {  "slot": 0,} nl
        {  "process-id": "} system/options/pid {"} nl
        "}"
    ]
    write to-rebol-file worker/state-file json
]

save-conversation: func [/local json][
    write to-rebol-file worker/conv-file to-json worker/conversation
]

; ═══════════════════════════════════════════════════════════
;  Agent Turn (writes output to file)
; ═══════════════════════════════════════════════════════════

run-agent-turn: func [
    messages [block!]
    /local content response msg
][
    content: copy ""

    ; Stream with callback — write tokens to output file
    response: llm-client/chat-stream/with-tools messages func [token [string!]] [
        if string? token [
            append content token
            write-output token
        ]
    ] registry/specs

    unless map? response [return none]

    ; Build message
    msg: make map! reduce [
        to-set-word 'role {assistant}
        to-set-word 'content any [select response 'content  ""]
        to-set-word 'tool_calls any [select response 'tool_calls  []]
    ]

    msg
]

; ═══════════════════════════════════════════════════════════
;  Main Worker Loop
; ═══════════════════════════════════════════════════════════

run-worker: func [
    sid       [string!]
    prompt    [string!]
    /local sdir msg tool-calls text fn-data fn-name fn-args fn-args-json result tc tool-msg
][
    worker/session-id: sid
    worker/session-dir: rejoin [".re-coder/sessions/" sid "/"]
    worker/state-file: rejoin [worker/session-dir "state.json"]
    worker/output-file: rejoin [worker/session-dir "output.log"]
    worker/conv-file: rejoin [worker/session-dir "conversation.json"]
    worker/user-prompt: prompt

    ; Load existing conversation if any
    if exists? to-rebol-file worker/conv-file [
        worker/conversation: try [load-json read to-rebol-file worker/conv-file]
        unless block? worker/conversation [worker/conversation: copy []]
    ]

    ; Mark as running
    write-state "running"

    ; Clear output log
    write to-rebol-file worker/output-file ""

    ; Write header
    write-output rejoin [
        newline
        "═══════════════════════════════════════" newline
        "  Background Worker [" sid "]" newline
        "  Prompt: " prompt newline
        "═══════════════════════════════════════" newline
        newline
    ]

    ; Initialize agent tools
    code-agent/init

    ; Ensure we have a system prompt
    if empty? worker/conversation [
        sys-msg: make map! reduce [
            to-set-word 'role {system}
            to-set-word 'content system-prompt
        ]
        append/only worker/conversation sys-msg
    ]

    ; Add user message
    user-msg: make map! reduce [
        to-set-word 'role {user}
        to-set-word 'content prompt
    ]
    append/only worker/conversation user-msg

    ; Agent loop
    repeat turn config/max-turns [
        write-output rejoin [newline "--- Turn " turn " ---" newline]

        msg: run-agent-turn worker/conversation
        unless msg [
            write-output newline
            write-output "ERROR: LLM call failed."
            write-state "error"
            return
        ]

        append/only worker/conversation msg

        text: any [select msg 'content  ""]
        tool-calls: any [select msg 'tool_calls  []]

        ; Save conversation after each turn
        save-conversation

        if empty? tool-calls [
            write-output newline
            write-output rejoin [newline "=== Completed in " turn " turns ===" newline]
            write-state "done"
            save-conversation
            return
        ]

        ; Process tool calls
        foreach tc tool-calls [
            fn-data: select tc 'function
            either map? fn-data [
                fn-name: select fn-data 'name
                fn-args-json: select fn-data 'arguments
                unless string? fn-args-json [fn-args-json: "{}"]

                fn-args: try [load-json fn-args-json]
                unless map? fn-args [fn-args: #[]]

                write-output newline
                write-output rejoin ["  [tool] " fn-name newline]

                ; Resolve relative paths
                if all [
                    string? fn-name
                    find fn-name {file}
                    path-val: select fn-args 'path
                    string? path-val
                    not find path-val {/}
                ][
                    put fn-args 'path rejoin [to-string config/work-dir path-val]
                ]

                result: registry/execute fn-name fn-args

                write-output rejoin ["  [done] " copy/part result 200 newline]

                tool-msg: make map! reduce [
                    to-set-word 'role {tool}
                    to-set-word 'tool_call_id select tc 'id
                    to-set-word 'content result
                ]
            ][
                tool-msg: make map! reduce [
                    to-set-word 'role {tool}
                    to-set-word 'tool_call_id any [select tc 'id  {-}]
                    to-set-word 'content {[Tool error: missing function object]}
                ]
            ]
            append/only worker/conversation tool-msg
            save-conversation
        ]
    ]

    ; Max turns
    write-output newline
    write-output rejoin ["=== Max turns (" config/max-turns ") reached ===" newline]
    write-state "done"
    save-conversation
]

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════

main: func [/local args sid prompt][
    args: system/options/args

    unless all [args  (length? args) >= 3  args/1 = "--session-id"][
        print "Usage: rebol3 re-coder-bg-worker.reb --session-id <id> <prompt>"
        quit/return 1
    ]

    sid: args/2
    prompt: either (length? args) > 2 [
        ; Join remaining args as prompt
        out: copy ""
        i: 3
        while [i <= length? args] [
            unless i = 3 [append out " "]
            append out pick args i
            i: i + 1
        ]
        out
    ][""]

    unless config/api-key [
        print "ERROR: DEEPSEEK_API_KEY not set."
        write-state "error"
        quit/return 1
    ]

    ; Run
    run-worker sid prompt
]

main
