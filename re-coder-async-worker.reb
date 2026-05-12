REBOL [
    Title:   {Re Coder Async Worker}
    Name:    're-coder-async-worker
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Async worker process for /async tasks.
              Spawned by async-manager, runs independently.}
]

; ═══════════════════════════════════════════════════════════
;  Load Dependencies
; ═══════════════════════════════════════════════════════════

do %./re-coder-agent-stream.reb

; ═══════════════════════════════════════════════════════════
;  Worker State
; ═══════════════════════════════════════════════════════════

worker: make object! [
    task-id:      none
    task-name:    none
    prompt:       ""
    loop-count:   1
    time-limit:   none   ; time! e.g. 0:05:00
    model:        none
    work-dir:     none
    task-dir:     none
    state-file:   none
    output-file:  none
    running:      true
    start-time:   none
]

; ═══════════════════════════════════════════════════════════
;  File I/O
; ═══════════════════════════════════════════════════════════

write-output: func [text [string!]] [
    write/append to-rebol-file worker/output-file text
]

write-state: func [state [string!] /local json nl err][
    nl: newline
    err: either state = "error" [rejoin [{,} nl {  "error-msg": "worker error"}]][""]
    json: rejoin [
        "{" nl
        {  "id": "} worker/task-id {",} nl
        {  "name": "} worker/task-name {",} nl
        {  "state": "} state {",} nl
        {  "process-id": "} system/options/pid {",} nl
        {  "started": "} worker/start-time {",} nl
        {  "finished": "} now {",} nl
        {  "loop-current": 0} err nl
        "}"
    ]
    write to-rebol-file worker/state-file json
]

; ═══════════════════════════════════════════════════════════
;  Agent Turn
; ═══════════════════════════════════════════════════════════

run-agent-turn: func [
    messages [block!]
    /local content response msg
][
    content: copy ""

    response: llm-client/chat-stream/with-tools messages func [token [string!]] [
        if string? token [
            append content token
            write-output token
        ]
    ] registry/specs

    unless map? response [return none]

    msg: make map! reduce [
        to-set-word 'role {assistant}
        to-set-word 'content any [select response 'content  ""]
        to-set-word 'tool_calls any [select response 'tool_calls  []]
    ]
    msg
]

; ═══════════════════════════════════════════════════════════
;  Check Time Limit
; ═══════════════════════════════════════════════════════════

check-time: func [/local elapsed][
    if worker/time-limit [
        elapsed: difference now worker/start-time
        if elapsed > worker/time-limit [
            write-output newline
            write-output rejoin ["=== TIME LIMIT REACHED (" worker/time-limit ") ===" newline]
            return false
        ]
    ]
    true
]

; ═══════════════════════════════════════════════════════════
;  Run Single Task Loop
; ═══════════════════════════════════════════════════════════

run-task-loop: func [
    prompt [string!]
    /local conversation msg tool-calls text
    fn-data fn-name fn-args fn-args-json result tc tool-msg
][
    ; Initialize agent
    code-agent/init

    ; Build conversation
    conversation: copy []
    append/only conversation make map! reduce [
        to-set-word 'role {system}
        to-set-word 'content system-prompt
    ]
    append/only conversation make map! reduce [
        to-set-word 'role {user}
        to-set-word 'content prompt
    ]

    ; Agent loop
    repeat turn config/max-turns [
        ; Check time
        unless check-time [return 'timeout]

        msg: run-agent-turn conversation
        unless msg [
            write-output newline
            write-output "ERROR: LLM call failed."
            return 'error
        ]

        append/only conversation msg

        text: any [select msg 'content  ""]
        tool-calls: any [select msg 'tool_calls  []]

        if empty? tool-calls [return 'done]

        ; Process tool calls
        foreach tc tool-calls [
            unless check-time [return 'timeout]

            fn-data: select tc 'function
            either map? fn-data [
                fn-name: select fn-data 'name
                fn-args-json: select fn-data 'arguments
                unless string? fn-args-json [fn-args-json: "{}"]

                fn-args: try [load-json fn-args-json]
                unless map? fn-args [fn-args: #[]]

                write-output newline
                write-output rejoin ["  [tool] " fn-name newline]

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
                    to-set-word 'content {[Tool error]}
                ]
            ]
            append/only conversation tool-msg
        ]
    ]

    'max-turns
]

; ═══════════════════════════════════════════════════════════
;  Main Worker Loop (with /loop support)
; ═══════════════════════════════════════════════════════════

run-worker: func [/local loop-i result][
    worker/start-time: now

    ; Override model if specified
    if worker/model [config/model: worker/model]
    if worker/work-dir [config/work-dir: to-rebol-file worker/work-dir]

    write-state "running"

    write-output rejoin [
        newline
        "═══════════════════════════════════════" newline
        "  Async Worker [" worker/task-name "]" newline
        "  ID: " worker/task-id newline
        "  Prompt: " worker/prompt newline
        "  Loops: " worker/loop-count newline
        either worker/time-limit [rejoin ["  Time limit: " worker/time-limit newline]][""]
        "═══════════════════════════════════════" newline
        newline
    ]

    loop-i: 0
    repeat i worker/loop-count [
        loop-i: i
        write-output rejoin [newline "=== Loop " i "/" worker/loop-count " ===" newline]

        ; Update loop count in state
        attempt [
            nl: newline
            state-json: rejoin [
                "{" nl
                {  "id": "} worker/task-id {",} nl
                {  "name": "} worker/task-name {",} nl
                {  "state": "running",} nl
                {  "process-id": "} system/options/pid {",} nl
                {  "started": "} worker/start-time {",} nl
                {  "loop-current": } i nl
                "}"
            ]
            write to-rebol-file worker/state-file state-json
        ]

        result: run-task-loop worker/prompt

        case [
            result = 'timeout [
                write-output newline
                write-output "=== Task stopped: time limit reached ===" newline
                write-state "done"
                return
            ]
            result = 'error [
                write-state "error"
                return
            ]
            true [
                write-output newline
                write-output rejoin ["=== Loop " i " completed ===" newline]
            ]
        ]
    ]

    write-state "done"
    write-output newline
    write-output rejoin ["=== All " loop-i " loops completed ===" newline]
]

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════

main: func [/local args task-id task-name loop-count time-limit model work-dir prompt i arg][
    args: system/options/args

    unless all [args  (length? args) >= 2] [
        print "Usage: rebol3 re-coder-async-worker.reb --task-id <id> --task-name <name> [--loop N] [--time 5m] [--model m] [--work-dir d] <prompt>"
        quit/return 1
    ]

    ; Parse args
    prompt-parts: copy []
    i: 1
    while [i <= length? args] [
        arg: pick args i
        switch/default arg [
            "--task-id"    [i: i + 1  if i <= length? args [task-id: pick args i]]
            "--task-name"  [i: i + 1  if i <= length? args [task-name: pick args i]]
            "--loop-count" [i: i + 1  if i <= length? args [loop-count: to-integer pick args i]]
            "--time-limit" [i: i + 1  if i <= length? args [time-limit: pick args i]]
            "--model"      [i: i + 1  if i <= length? args [model: pick args i]]
            "--work-dir"   [i: i + 1  if i <= length? args [work-dir: pick args i]]
        ][
            append prompt-parts arg
        ]
        i: i + 1
    ]

    prompt: either empty? prompt-parts [""][
        join-items prompt-parts " "
    ]

    ; Validate
    unless task-id   [print "ERROR: --task-id required" quit/return 1]
    unless task-name [print "ERROR: --task-name required" quit/return 1]
    unless config/api-key [
        print "ERROR: DEEPSEEK_API_KEY not set"
        quit/return 1
    ]

    ; Set worker state
    worker/task-id: task-id
    worker/task-name: task-name
    worker/prompt: prompt
    worker/loop-count: any [loop-count 1]
    worker/task-dir: rejoin [".re-coder/async/tasks/" task-name "/"]
    worker/state-file: rejoin [worker/task-dir "state.json"]
    worker/output-file: rejoin [worker/task-dir "output.log"]

    if time-limit [worker/time-limit: time-limit]
    if model [worker/model: model]
    if work-dir [worker/work-dir: work-dir]

    ; Run
    run-worker
]

main
