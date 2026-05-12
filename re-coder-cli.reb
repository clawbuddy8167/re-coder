REBOL [
    Title:   {Re Coder CLI — Interactive Coding Agent}
    Name:    're-coder-cli
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Interactive REPL-style CLI for re-coder-agent.
              Modeled after Claude Code / Codex CLI experience.}
]

; ═══════════════════════════════════════════════════════════
;  Load Dependencies
; ═══════════════════════════════════════════════════════════

do %./re-coder-agent-stream.reb

; ═══════════════════════════════════════════════════════════
;  CLI State
; ═══════════════════════════════════════════════════════════

cli-state: make object! [
    running:       true
    conversation:  copy []      ; message history
    turn-count:    0
    session-start: none
    input-buffer:  copy ""
    multi-line:    false        ; multi-line input mode
]

; ═══════════════════════════════════════════════════════════
;  ANSI Color Helpers
; ═══════════════════════════════════════════════════════════

; Reset
c-reset:   "^[[0m"
; Bold
c-bold:    "^[[1m"
; Dim
c-dim:     "^[[2m"
; Colors
c-red:     "^[[31m"
c-green:   "^[[32m"
c-yellow:  "^[[33m"
c-blue:    "^[[34m"
c-magenta: "^[[35m"
c-cyan:    "^[[36m"
c-white:   "^[[37m"
; Bright
c-bright-green:  "^[[92m"
c-bright-cyan:   "^[[96m"
c-bright-yellow: "^[[93m"
c-bright-white:  "^[[97m"
; Background
c-bg-dark: "^[[48;5;236m"

; ═══════════════════════════════════════════════════════════
;  Banner
; ═══════════════════════════════════════════════════════════

show-banner: func [/local version-line model-line api-line dir-line stream-line] [
    print ""
    print rejoin [c-cyan c-bold "  ╔═══════════════════════════════════════════════════════════════╗" c-reset]
    print rejoin [c-cyan c-bold "  ║" c-reset
                  c-bright-white c-bold "   ■ Re Coder CLI — Interactive Coding Agent" c-reset
                  c-cyan c-bold "                ║" c-reset]
    print rejoin [c-cyan c-bold "  ║" c-reset
                  c-dim "     Powered by Rebol3 + LLM Streaming" c-reset
                  c-cyan c-bold "                     ║" c-reset]
    print rejoin [c-cyan c-bold "  ╚═══════════════════════════════════════════════════════════════╝" c-reset]
    print ""

    ; Status line
    version-line: rejoin [c-dim "  Version:  1.0.0" c-reset]
    model-line:   rejoin [c-dim "  Model:    " c-reset c-bright-green config/model c-reset]
    api-line:     rejoin [c-dim "  API:      " c-reset c-dim config/base-url c-reset]
    dir-line:     rejoin [c-dim "  Work Dir: " c-reset c-dim to-string config/work-dir c-reset]
    stream-line:  rejoin [c-dim "  Stream:   " c-reset
                          either config/stream-mode [
                              rejoin [c-green "ON" c-reset]
                          ][
                              rejoin [c-yellow "OFF" c-reset]
                          ]]

    print version-line
    print model-line
    print api-line
    print dir-line
    print stream-line
    print ""
    print rejoin [c-dim "  Type " c-reset c-bright-cyan "/help" c-reset c-dim " for commands, " c-reset
                  c-bright-cyan "/quit" c-reset c-dim " to exit" c-reset]
    print ""
]

; ═══════════════════════════════════════════════════════════
;  Help
; ═══════════════════════════════════════════════════════════

show-help: func [] [
    print ""
    print rejoin [c-bright-cyan c-bold "  Commands" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-bright-cyan "  /help" c-reset c-dim "        Show this help message" c-reset]
    print rejoin [c-bright-cyan "  /quit" c-reset c-dim "        Exit the CLI" c-reset]
    print rejoin [c-bright-cyan "  /exit" c-reset c-dim "        Same as /quit" c-reset]
    print rejoin [c-bright-cyan "  /clear" c-reset c-dim "       Clear conversation history" c-reset]
    print rejoin [c-bright-cyan "  /history" c-reset c-dim "     Show conversation summary" c-reset]
    print rejoin [c-bright-cyan "  /model" c-reset c-dim " <name> Switch model (e.g. deepseek-chat)" c-reset]
    print rejoin [c-bright-cyan "  /workdir" c-reset c-dim " <d>  Set working directory" c-reset]
    print rejoin [c-bright-cyan "  /stream" c-reset c-dim "       Toggle streaming ON/OFF" c-reset]
    print rejoin [c-bright-cyan "  /config" c-reset c-dim "       Show current configuration" c-reset]
    print rejoin [c-bright-cyan "  /multi" c-reset c-dim "        Toggle multi-line input mode" c-reset]
    print ""
    print rejoin [c-bright-cyan c-bold "  Input" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-dim "  Type your coding task and press Enter." c-reset]
    print rejoin [c-dim "  In multi-line mode, press Enter twice to submit." c-reset]
    print rejoin [c-dim "  Prefix with " c-reset c-bright-cyan "///" c-reset c-dim " (triple slash) for multi-line (one-shot)." c-reset]
    print ""
]

; ═══════════════════════════════════════════════════════════
;  Status Display
; ═══════════════════════════════════════════════════════════

show-config: func [] [
    print ""
    print rejoin [c-bright-cyan c-bold "  Configuration" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-dim "  Model:     " c-reset c-bright-green config/model c-reset]
    print rejoin [c-dim "  API:       " c-reset c-dim config/base-url c-reset]
    print rejoin [c-dim "  Work Dir:  " c-reset c-dim to-string config/work-dir c-reset]
    print rejoin [c-dim "  Max Turns: " c-reset c-dim to-string config/max-turns c-reset]
    print rejoin [c-dim "  Stream:    " c-reset
                  either config/stream-mode [rejoin [c-green "ON"]][rejoin [c-yellow "OFF"]]
                  c-reset]
    print rejoin [c-dim "  API Key:   " c-reset
                  either empty? config/api-key [
                      rejoin [c-red "(not set)"]
                  ][
                      rejoin [c-dim copy/part config/api-key 8 "..."]
                  ]
                  c-reset]
    print ""
]

show-history: func [] [
    count: 0
    foreach msg cli-state/conversation [
        role: select msg 'role
        if role <> "system" [count: count + 1]
    ]
    print ""
    print rejoin [c-dim "  Conversation: " c-reset c-bright-white to-string count c-reset c-dim " messages, " c-reset
                  c-bright-white to-string cli-state/turn-count c-reset c-dim " agent turns" c-reset]
    print ""
]

; ═══════════════════════════════════════════════════════════
;  Tool Call Display (pretty)
; ═══════════════════════════════════════════════════════════

display-tool-call: func [fn-name [string!] args [map!] /local args-str] [
    args-str: either empty? args [""][
        ; Format args nicely
        parts: copy []
        foreach [k v] args [
            val: either string? v [
                either (length? v) > 60 [
                    rejoin [copy/part v 60 "..."]
                ][v]
            ][mold v]
            append parts rejoin [to-string k "=" val]
        ]
        join-items parts ", "
    ]
    print ""
    print rejoin [c-yellow "  🔧 " c-bright-yellow fn-name c-reset
                  either empty? args-str [""][rejoin [c-dim " (" args-str ")" c-reset]]]
]

display-tool-result: func [result [string!] /local short] [
    short: either (length? result) > 300 [
        rejoin [copy/part result 300 c-dim "...(truncated)" c-reset]
    ][result]
    print rejoin [c-green "  ✓ " c-reset c-dim short c-reset]
]

display-tool-error: func [result [string!]] [
    print rejoin [c-red "  ✗ " c-reset c-red result c-reset]
]

; ═══════════════════════════════════════════════════════════
;  Agent Turn (Streaming with Pretty Display)
; ═══════════════════════════════════════════════════════════

run-agent-turn: func [
    messages [block!]
    /local content tool-calls response msg text result fn-data fn-name fn-args fn-args-json tc
][
    ; Initialize
    content: copy ""
    tool-calls: copy []

    ; Show thinking indicator
    print ""
    print rejoin [c-dim "  ⏳ Thinking..." c-reset]

    ; Stream with callback
    response: llm-client/chat-stream/with-tools messages func [token [string!]] [
        case [
            string? token [
                ; First token: clear thinking line and show response prefix
                if empty? content [
                    ; Move up one line and clear it
                    prin "^[[1A^[[2K"
                    prin rejoin [c-bright-white c-bold "  ▸ " c-reset]
                ]
                append content token
                prin token
            ]
        ]
    ] registry/specs

    ; Newline after streaming
    if not empty? content [print ""]

    ; Check errors
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
;  Process a User Message
; ═══════════════════════════════════════════════════════════

process-user-input: func [user-text [string!] /local user-msg msg tool-calls text fn-data fn-name fn-args fn-args-json result tc tool-msg done-msg] [
    ; Add user message to conversation
    user-msg: make map! reduce [
        to-set-word 'role {user}
        to-set-word 'content user-text
    ]
    append/only cli-state/conversation user-msg

    ; Agent loop (handles tool calls)
    repeat turn config/max-turns [
        cli-state/turn-count: cli-state/turn-count + 1

        ; Call LLM
        msg: run-agent-turn cli-state/conversation
        unless msg [
            print rejoin [c-red "  ✗ LLM call failed — check API key and endpoint." c-reset]
            return
        ]

        ; Add assistant message
        append/only cli-state/conversation msg

        text: any [select msg 'content  ""]
        tool-calls: any [select msg 'tool_calls  []]

        ; If no tool calls, we're done
        if empty? tool-calls [
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

                display-tool-call fn-name fn-args

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

                either find result "❌" [
                    display-tool-error result
                ][
                    display-tool-result result
                ]

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
            append/only cli-state/conversation tool-msg
        ]
    ]

    ; Max turns reached
    print rejoin [c-yellow "  ⏱ Max turns (" config/max-turns ") reached." c-reset]
]

; ═══════════════════════════════════════════════════════════
;  Command Handler
; ═══════════════════════════════════════════════════════════

handle-command: func [cmd [string!] /local parts arg] [
    ; Trim and lowercase
    cmd: trim cmd
    parts: split cmd " "
    command: first parts
    arg: either (length? parts) > 1 [trim copy/part skip cmd length? first parts tail cmd][none]

    switch/default command [
        "/help"    [show-help]
        "/quit"    [cli-state/running: false  print rejoin [c-dim "  Goodbye!" c-reset]]
        "/exit"    [cli-state/running: false  print rejoin [c-dim "  Goodbye!" c-reset]]
        "/clear"   [
            clear cli-state/conversation
            cli-state/turn-count: 0
            print rejoin [c-green "  ✓ Conversation cleared." c-reset]
        ]
        "/history" [show-history]
        "/config"  [show-config]
        "/multi"   [
            cli-state/multi-line: not cli-state/multi-line
            print rejoin [c-dim "  Multi-line mode: " c-reset
                          either cli-state/multi-line [rejoin [c-green "ON"]][rejoin [c-yellow "OFF"]]
                          c-reset]
        ]
        "/model"   [
            either arg [
                config/model: arg
                print rejoin [c-green "  ✓ Model set to: " c-bright-green arg c-reset]
            ][
                print rejoin [c-dim "  Current model: " c-reset c-bright-green config/model c-reset]
            ]
        ]
        "/workdir" [
            either arg [
                config/work-dir: to-rebol-file arg
                print rejoin [c-green "  ✓ Work dir set to: " c-bright-green arg c-reset]
            ][
                print rejoin [c-dim "  Current work dir: " c-reset c-bright-green to-string config/work-dir c-reset]
            ]
        ]
        "/stream"  [
            config/stream-mode: not config/stream-mode
            print rejoin [c-dim "  Streaming: " c-reset
                          either config/stream-mode [rejoin [c-green "ON"]][rejoin [c-yellow "OFF"]]
                          c-reset]
        ]
    ][
        print rejoin [c-red "  Unknown command: " command c-reset
                      c-dim "  Type /help for available commands" c-reset]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Prompt
; ═══════════════════════════════════════════════════════════

show-prompt: func [] [
    either cli-state/multi-line [
        prin rejoin [c-bright-cyan "  ... " c-reset]
    ][
        prin rejoin [c-bright-cyan "  ❯ " c-reset]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Multi-line Input
; ═══════════════════════════════════════════════════════════

read-multiline: func [/local lines line] [
    lines: copy []
    print rejoin [c-dim "  Multi-line mode. Press Enter on empty line to submit." c-reset]
    forever [
        prin rejoin [c-dim "  ... " c-reset]
        line: input
        either empty? trim line [
            either empty? lines [
                ; Double empty = cancel
                print rejoin [c-dim "  (cancelled)" c-reset]
                return none
            ][
                return join-items lines "^/"
            ]
        ][
            append lines line
        ]
    ]
]

; ═══════════════════════════════════════════════════════════
;  One-shot Triple-slash Multi-line
; ═══════════════════════════════════════════════════════════

read-triple-slash: func [/local lines line] [
    lines: copy []
    print rejoin [c-dim "  Multi-line input (end with empty line):" c-reset]
    forever [
        prin rejoin [c-dim "  ... " c-reset]
        line: input
        either empty? trim line [
            return join-items lines "^/"
        ][
            append lines line
        ]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Main REPL Loop
; ═══════════════════════════════════════════════════════════

main-loop: func [/local user-input] [
    ; Initialize agent
    code-agent/init

    ; Initialize conversation with system prompt
    sys-msg: make map! reduce [
        to-set-word 'role {system}
        to-set-word 'content system-prompt
    ]
    append/only cli-state/conversation sys-msg

    cli-state/session-start: now

    ; REPL
    while [cli-state/running] [
        show-prompt

        ; Read input
        user-input: attempt [input]

        ; Handle EOF / Ctrl-D
        unless user-input [
            print ""
            print rejoin [c-dim "  Goodbye!" c-reset]
            break
        ]

        user-input: trim user-input

        ; Skip empty
        if empty? user-input [continue]

        ; Check for triple-slash multi-line
        if user-input = "///" [
            user-input: read-triple-slash
            unless user-input [continue]
        ]

        ; Commands
        if (first user-input) = #"/" [
            either find user-input " " [
                handle-command user-input
            ][
                handle-command user-input
            ]
            continue
        ]

        ; Multi-line mode
        if cli-state/multi-line [
            user-input: read-multiline
            unless user-input [continue]
        ]

        ; Process
        process-user-input user-input
    ]
]

; ═══════════════════════════════════════════════════════════
;  CLI Argument Parsing
; ═══════════════════════════════════════════════════════════

parse-cli-args: func [/local args i arg prompt-parts prompt] [
    args: system/options/args
    unless args [
        ; No args = interactive mode
        return none
    ]

    ; Parse flags
    prompt-parts: copy []
    i: 1
    while [i <= length? args] [
        arg: pick args i
        switch/default arg [
            "--model" [
                i: i + 1
                if i <= length? args [config/model: pick args i]
            ]
            "--base-url" [
                i: i + 1
                if i <= length? args [config/base-url: pick args i]
            ]
            "--work-dir" [
                i: i + 1
                if i <= length? args [config/work-dir: to-rebol-file pick args i]
            ]
            "--stream" [
                config/stream-mode: true
            ]
            "--no-stream" [
                config/stream-mode: false
            ]
            "--help" "-h" [
                print {Usage: rebol3 re-coder-cli.reb [options] [prompt]}
                print {}
                print {Options:}
                print {  --model <name>     Set LLM model (default: deepseek-chat)}
                print {  --base-url <url>   Set API base URL}
                print {  --work-dir <dir>   Set working directory}
                print {  --stream           Enable streaming (default)}
                print {  --no-stream        Disable streaming}
                print {}
                print {If prompt is provided, runs in one-shot mode.}
                print {Otherwise, enters interactive REPL.}
                quit/return 0
            ]
        ][
            append prompt-parts arg
        ]
        i: i + 1
    ]

    ; If prompt provided, run one-shot
    unless empty? prompt-parts [
        prompt: join-items prompt-parts " "
        return reduce ['one-shot prompt]
    ]

    none
]

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════

main: func [/local mode prompt] [
    ; Check API key
    unless config/api-key [
        print rejoin [c-red "  ❌ DEEPSEEK_API_KEY environment variable not set." c-reset]
        print rejoin [c-dim "  Usage: DEEPSEEK_API_KEY=*** rebol3 re-coder-cli.reb" c-reset]
        quit/return 1
    ]

    ; Parse args
    mode: parse-cli-args

    either mode [
        ; One-shot mode
        prompt: second mode
        show-banner
        print rejoin [c-dim "  One-shot mode:" c-reset]
        print rejoin [c-bright-white "  " prompt c-reset]
        print ""
        code-agent/init
        process-user-input prompt
    ][
        ; Interactive mode
        show-banner
        main-loop
    ]
]

; === Bootstrap ===
main
