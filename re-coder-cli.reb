REBOL [
    Title:   {Re Coder CLI — Interactive Coding Agent}
    Name:    're-coder-cli
    Author:  {Hermes Agent}
    Version: 3.0.0
    Rights:  {MIT}
    Purpose: {Interactive REPL-style CLI for re-coder-agent.
              Supports /bg (session switching) and /async (fire-and-forget tasks).
              Modeled after Claude Code / Codex CLI experience.}
]

; ═══════════════════════════════════════════════════════════
;  Load Dependencies
; ═══════════════════════════════════════════════════════════

; Prevent agent-stream from auto-running main when loaded as library
re-coder-as-library: true

do %./re-coder-agent-stream.reb
do %./session-manager.reb
do %./async-manager.reb

; ═══════════════════════════════════════════════════════════
;  CLI State
; ═══════════════════════════════════════════════════════════

cli-state: make object! [
    running:       true
    turn-count:    0
    session-start: none
    input-buffer:  copy ""
    multi-line:    false
]

; ═══════════════════════════════════════════════════════════
;  ANSI Color Helpers
; ═══════════════════════════════════════════════════════════

c-reset:   "^[[0m"
c-bold:    "^[[1m"
c-dim:     "^[[2m"
c-red:     "^[[31m"
c-green:   "^[[32m"
c-yellow:  "^[[33m"
c-blue:    "^[[34m"
c-magenta: "^[[35m"
c-cyan:    "^[[36m"
c-white:   "^[[37m"
c-bright-green:  "^[[92m"
c-bright-cyan:   "^[[96m"
c-bright-yellow: "^[[93m"
c-bright-white:  "^[[97m"

; ═══════════════════════════════════════════════════════════
;  Banner
; ═══════════════════════════════════════════════════════════

show-banner: func [] [
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
    print rejoin [c-dim "  Model:    " c-reset c-bright-green config/model c-reset]
    print rejoin [c-dim "  API:      " c-reset c-dim config/base-url c-reset]
    print rejoin [c-dim "  Work Dir: " c-reset c-dim to-string config/work-dir c-reset]
    print rejoin [c-dim "  Stream:   " c-reset
                  either config/stream-mode [rejoin [c-green "ON"]][rejoin [c-yellow "OFF"]]
                  c-reset]
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
    print rejoin [c-bright-cyan c-bold "  Session Commands" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-bright-cyan "  /bg" c-reset c-dim "           Send current session to background" c-reset]
    print rejoin [c-bright-cyan "  /bg /list" c-reset c-dim "     List all sessions" c-reset]
    print rejoin [c-bright-cyan "  /bg <N>" c-reset c-dim "       Resume session #N (swap foreground)" c-reset]
    print rejoin [c-bright-cyan "  /bg /drop <N>" c-reset c-dim " Drop session #N" c-reset]
    print rejoin [c-bright-cyan "  /bg /help" c-reset c-dim "     Show /bg help" c-reset]
    print rejoin [c-bright-cyan "  /fork" c-reset c-dim "         Fork current session (copy context)" c-reset]
    print rejoin [c-bright-cyan "  /new" c-reset c-dim "          Start a fresh session" c-reset]
    print ""
    print rejoin [c-bright-cyan c-bold "  Async Tasks (/async)" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-bright-cyan {  /async /name <n> "<prompt>"} c-reset c-dim {  Fire-and-forget task} c-reset]
    print rejoin [c-bright-cyan {  /async /name <n> /time 5m "<p>"} c-reset c-dim { Time-limited} c-reset]
    print rejoin [c-bright-cyan {  /async /name <n> /loop 3 "<p>"} c-reset c-dim { Loop N times} c-reset]
    print rejoin [c-bright-cyan "  /async /list" c-reset c-dim "          List all async tasks" c-reset]
    print rejoin [c-bright-cyan "  /async /task <name>" c-reset c-dim "      View task output" c-reset]
    print rejoin [c-bright-cyan "  /async /kill <name>" c-reset c-dim "      Kill running task" c-reset]
    print rejoin [c-bright-cyan "  /async /drop <name>" c-reset c-dim "      Drop task + logs" c-reset]
    print rejoin [c-bright-cyan "  /async /help" c-reset c-dim "           Show /async help" c-reset]
    print ""
    print rejoin [c-bright-cyan c-bold "  General Commands" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-bright-cyan "  /help" c-reset c-dim "         Show this help" c-reset]
    print rejoin [c-bright-cyan "  /quit" c-reset c-dim "         Exit (same as /exit)" c-reset]
    print rejoin [c-bright-cyan "  /clear" c-reset c-dim "        Clear current conversation" c-reset]
    print rejoin [c-bright-cyan "  /history" c-reset c-dim "      Show message count" c-reset]
    print rejoin [c-bright-cyan "  /model <name>" c-reset c-dim " Switch model" c-reset]
    print rejoin [c-bright-cyan "  /workdir <d>" c-reset c-dim "  Set working directory" c-reset]
    print rejoin [c-bright-cyan "  /stream" c-reset c-dim "       Toggle streaming ON/OFF" c-reset]
    print rejoin [c-bright-cyan "  /config" c-reset c-dim "       Show current config" c-reset]
    print rejoin [c-bright-cyan "  /multi" c-reset c-dim "        Toggle multi-line input mode" c-reset]
    print ""
    print rejoin [c-dim "  Multi-line: type " c-reset c-bright-cyan "///" c-reset c-dim " (triple slash) or use " c-reset
                  c-bright-cyan "/multi" c-reset c-dim " toggle" c-reset]
    print ""
]

show-bg-help: func [] [
    print ""
    print rejoin [c-bright-cyan c-bold "  /bg — Background Session Management" c-reset]
    print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
    print rejoin [c-bright-cyan "  /bg" c-reset c-dim "             Send current session to background, start new" c-reset]
    print rejoin [c-bright-cyan "  /bg /list" c-reset c-dim "       List all sessions with status" c-reset]
    print rejoin [c-bright-cyan "  /bg <N>" c-reset c-dim "         Resume session #N to foreground" c-reset]
    print rejoin [c-bright-cyan "  /bg /drop <N>" c-reset c-dim "   Drop session #N" c-reset]
    print rejoin [c-bright-cyan "  /bg /help" c-reset c-dim "       Show this help" c-reset]
    print ""
    print rejoin [c-dim "  States: " c-reset
                  c-yellow "running" c-reset c-dim " | " c-reset
                  c-green "done" c-reset c-dim " | " c-reset
                  c-dim "idle" c-reset c-dim " | " c-reset
                  c-dim "cancelled" c-reset c-dim " | " c-reset
                  c-red "error" c-reset]
    print rejoin [c-dim "  Max background sessions: " c-reset c-bright-white to-string MAX-BACKGROUND-SESSIONS c-reset]
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

show-history: func [/local active count][
    active: session-manager/get-active
    count: 0
    if active [
        foreach msg active/conversation [
            if (select msg 'role) <> "system" [count: count + 1]
        ]
    ]
    print ""
    print rejoin [c-dim "  Session: " c-reset c-bright-white either active [copy/part active/id 8]["none"] c-reset
                  c-dim " | Messages: " c-reset c-bright-white to-string count c-reset
                  c-dim " | Turns: " c-reset c-bright-white to-string cli-state/turn-count c-reset]
    print ""
]

; ═══════════════════════════════════════════════════════════
;  Session Display
; ═══════════════════════════════════════════════════════════

show-session-list: func [/local rows active active-id state-color][
    session-manager/poll-backgrounds
    rows: session-manager/format-list
    active: session-manager/get-active
    active-id: either active [active/id][none]

    print ""
    print rejoin [c-bright-cyan c-bold "  Sessions" c-reset]
    print rejoin [c-dim "  ────────────────────────────────────────────────────────────────" c-reset]
    print rejoin [c-dim "  " c-bold
                  pad/with "  #" 5 #" "
                  pad/with "ID" 10 #" "
                  pad/with "State" 12 #" "
                  pad/with "Created" 10 #" "
                  "Summary" c-reset]
    print rejoin [c-dim "  ────────────────────────────────────────────────────────────────" c-reset]

    foreach row rows [
        slot: row/1
        id:   row/2
        st:   row/3
        tm:   row/4
        sum:  row/5

        state-color: case [
            st = "running"   [c-yellow]
            st = "done"      [c-green]
            st = "error"     [c-red]
            st = "active"    [c-bright-green]
            true             [c-dim]
        ]

        marker: either st = "active" ["▸ "]["  "]

        print rejoin [
            "  " c-dim marker c-reset
            c-dim pad/with to-string slot 3 #" " c-reset " "
            c-dim pad/with id 8 #" " c-reset " "
            state-color pad/with st 10 #" " c-reset " "
            c-dim pad/with tm 8 #" " c-reset " "
            c-dim sum c-reset
        ]
    ]
    print ""
    print rejoin [c-dim "  Total: " c-reset c-bright-white to-string length? rows c-reset c-dim " session(s)" c-reset]
    print ""
]

; ═══════════════════════════════════════════════════════════
;  Tool Call Display
; ═══════════════════════════════════════════════════════════

display-tool-call: func [fn-name [string!] args [map!] /local args-str parts][
    args-str: either empty? args [""][
        parts: copy []
        foreach [k v] args [
            val: either string? v [
                either (length? v) > 60 [rejoin [copy/part v 60 "..."]][v]
            ][mold v]
            append parts rejoin [to-string k "=" val]
        ]
        join-items parts ", "
    ]
    print ""
    print rejoin [c-yellow "  🔧 " c-bright-yellow fn-name c-reset
                  either empty? args-str [""][rejoin [c-dim " (" args-str ")" c-reset]]]
]

display-tool-result: func [result [string!] /local short][
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
    /local content tool-calls response msg
][
    content: copy ""
    tool-calls: copy []

    print ""
    print rejoin [c-dim "  ⏳ Thinking..." c-reset]

    response: llm-client/chat-stream/with-tools messages func [token [string!]] [
        if string? token [
            if token = "DONE" [return]
            if all [(length? token) >= 6  "ERROR:" = copy/part token 6] [
                print rejoin [c-red "  " token c-reset]
                return
            ]
            if empty? content [
                prin "^[[1A^[[2K"
                prin rejoin [c-bright-white c-bold "  ▸ " c-reset]
            ]
            append content token
            prin token
        ]
    ] code-agent/registry/specs

    if not empty? content [print ""]

    unless map? response [return none]

    ; Shell / buffered path: tokens may not stream to callback; still print full text once
    text-from-api: any [select response 'content ""]
    if all [not empty? text-from-api  empty? content] [
        prin "^[[1A^[[2K"
        print rejoin [c-bright-white c-bold "  ▸ " c-reset text-from-api]
    ]

    msg: make map! reduce [
        to-set-word 'role {assistant}
        to-set-word 'content any [select response 'content  ""]
        to-set-word 'tool_calls any [select response 'tool_calls  []]
    ]

    msg
]

; ═══════════════════════════════════════════════════════════
;  Get Current Conversation (from session manager)
; ═══════════════════════════════════════════════════════════

get-conversation: func [/local active][
    active: session-manager/get-active
    either active [active/conversation][copy []]
]

set-conversation: func [conv [block!] /local active][
    active: session-manager/get-active
    if active [active/conversation: conv]
]

; ═══════════════════════════════════════════════════════════
;  Process a User Message
; ═══════════════════════════════════════════════════════════

process-user-input: func [
    user-text [string!]
    /local active conversation user-msg msg tool-calls text
    fn-data fn-name fn-args fn-args-json result tc tool-msg
][
    active: session-manager/get-active
    unless active [
        print rejoin [c-red "  ✗ No active session. Use /new to create one." c-reset]
        return none
    ]

    ; Update summary if this is the first user message
    if empty? active/summary [
        active/summary: copy/part user-text 60
    ]

    conversation: active/conversation

    ; Add user message
    user-msg: make map! reduce [
        to-set-word 'role {user}
        to-set-word 'content user-text
    ]
    append/only conversation user-msg

    ; Agent loop
    repeat turn config/max-turns [
        cli-state/turn-count: cli-state/turn-count + 1

        msg: run-agent-turn conversation
        unless msg [
            print rejoin [c-red "  ✗ LLM call failed — check API key and endpoint." c-reset]
            return none
        ]

        append/only conversation msg

        text: any [select msg 'content  ""]
        tool-calls: any [select msg 'tool_calls  []]

        if empty? tool-calls [
            ; Save conversation
            session-manager/save-session active
            return none
        ]

        foreach tc tool-calls [
            fn-data: select tc 'function
            either map? fn-data [
                fn-name: select fn-data 'name
                fn-args-json: select fn-data 'arguments
                unless string? fn-args-json [fn-args-json: "{}"]

                fn-args: try [load-json fn-args-json]
                unless map? fn-args [fn-args: #[]]

                display-tool-call fn-name fn-args

                if all [
                    string? fn-name
                    find fn-name {file}
                    path-val: select fn-args 'path
                    string? path-val
                    not find path-val {/}
                ][
                    put fn-args 'path rejoin [to-string config/work-dir path-val]
                ]

                result: code-agent/registry/execute fn-name fn-args

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
            append/only conversation tool-msg
        ]

        ; Save after tool calls
        session-manager/save-session active
    ]

    print rejoin [c-yellow "  ⏱ Max turns (" config/max-turns ") reached." c-reset]
    session-manager/save-session active
]


; ═══════════════════════════════════════════════════════════
;  /async Command Handler
; ═══════════════════════════════════════════════════════════

handle-async-command: func [args [string!] /local parts subcmd name prompt time-limit loop-count
    opts task result rows state-color arg rest output parsed-time out][
    args: trim args
    parts: copy []
    foreach w split args " " [if not empty? trim w [append parts w]]
    subcmd: either empty? args [none][parts/1]

    case [
        subcmd = "/help" [
            print ""
            print rejoin [c-bright-cyan c-bold "  /async — Fire-and-Forget Tasks" c-reset]
            print rejoin [c-dim "  ─────────────────────────────────────────────────────" c-reset]
            print rejoin [c-bright-cyan {  /async /name <n> "<prompt>"} c-reset c-dim {  Spawn named task} c-reset]
            print rejoin [c-bright-cyan {  /async /name <n> /time 5m "<p>"} c-reset c-dim { Time-limited (s/m/h)} c-reset]
            print rejoin [c-bright-cyan {  /async /name <n> /loop 3 "<p>"} c-reset c-dim { Loop N iterations} c-reset]
            print rejoin [c-bright-cyan "  /async /list" c-reset c-dim "          List all tasks" c-reset]
            print rejoin [c-bright-cyan "  /async /task <name>" c-reset c-dim "      View task output" c-reset]
            print rejoin [c-bright-cyan "  /async /kill <name>" c-reset c-dim "      Kill running task" c-reset]
            print rejoin [c-bright-cyan "  /async /drop <name>" c-reset c-dim "      Drop task + logs" c-reset]
            print ""
        ]

        subcmd = "/list" [
            async-manager/poll
            rows: async-manager/list
            print ""
            print rejoin [c-bright-cyan c-bold "  Async Tasks" c-reset]
            print rejoin [c-dim "  ────────────────────────────────────────────────────────────────" c-reset]
            print rejoin [c-dim "  " c-bold
                          pad/with "Name" 14 #" "
                          pad/with "ID" 10 #" "
                          pad/with "State" 10 #" "
                          pad/with "Created" 10 #" "
                          pad/with "Loops" 7 #" "
                          "Prompt" c-reset]
            print rejoin [c-dim "  ────────────────────────────────────────────────────────────────" c-reset]
            foreach row rows [
                state-color: case [
                    row/3 = "running"  [c-yellow]
                    row/3 = "done"     [c-green]
                    row/3 = "error"    [c-red]
                    true               [c-dim]
                ]
                print rejoin [
                    "  "
                    c-bright-white pad/with row/1 12 #" " c-reset " "
                    c-dim pad/with row/2 8 #" " c-reset " "
                    state-color pad/with row/3 8 #" " c-reset " "
                    c-dim pad/with row/4 8 #" " c-reset " "
                    c-dim pad/with rejoin [row/5 "/" row/6] 5 #" " c-reset " "
                    c-dim row/7 c-reset
                ]
            ]
            either empty? rows [
                print rejoin [c-dim "  (no async tasks)" c-reset]
            ][
                print rejoin [c-dim "  Total: " c-reset c-bright-white to-string length? rows c-reset c-dim " task(s)" c-reset]
            ]
            print ""
        ]

        subcmd = "/task" [
            name: parts/2
            unless name [print rejoin [c-red "  Usage: /async /task <name>" c-reset] return none]
            task: async-manager/get-task name
            either task [
                async-manager/poll
                print ""
                print rejoin [c-bright-cyan c-bold "  Task: " name c-reset]
                foreach line async-manager/format-detail task [print line]
                print ""
                output: async-manager/get-output task
                either empty? output [
                    print rejoin [c-dim "  (no output yet)" c-reset]
                ][
                    print rejoin [c-dim "  ── Output ──" c-reset]
                    either (length? output) > 2000 [
                        print rejoin [c-dim "  ..." copy/part skip output ((length? output) - 2000) 2000 c-reset]
                    ][
                        print rejoin [c-dim "  " output c-reset]
                    ]
                ]
                print ""
            ][
                print rejoin [c-red "  Task not found: " name c-reset]
            ]
        ]

        subcmd = "/kill" [
            name: parts/2
            unless name [print rejoin [c-red "  Usage: /async /kill <name>" c-reset] return none]
            task: async-manager/get-task name
            either task [
                result: async-manager/kill task
                print rejoin [c-yellow "  ✓ " result c-reset]
            ][
                print rejoin [c-red "  Task not found: " name c-reset]
            ]
        ]

        subcmd = "/drop" [
            name: parts/2
            unless name [print rejoin [c-red "  Usage: /async /drop <name>" c-reset] return none]
            result: async-manager/drop name
            print rejoin [c-dim "  " result c-reset]
        ]

        subcmd = "/name" [
            name: parts/2
            unless name [print rejoin [c-red "  Usage: /async /name <name> "prompt"" c-reset] return none]

            time-limit: none
            loop-count: 1
            rest: copy skip parts 2

            while [not empty? rest] [
                arg: first rest
                case [
                    arg = "/time" [
                        either (length? rest) > 1 [
                            time-limit: second rest
                            rest: skip rest 2
                        ][print rejoin [c-red "  /time needs value" c-reset] return none]
                    ]
                    arg = "/loop" [
                        either (length? rest) > 1 [
                            loop-count: any [attempt [to-integer second rest] 1]
                            rest: skip rest 2
                        ][print rejoin [c-red "  /loop needs number" c-reset] return none]
                    ]
                    true [break]
                ]
            ]

            prompt: either empty? rest [""][
                out: copy ""
                foreach w rest [unless empty? out [append out " "] append out w]
                if all [(length? out) >= 2 (first out) = #"^"" (last out) = #"^""][
                    out: copy/part skip out 1 ((length? out) - 1)
                ]
                out
            ]

            if empty? prompt [print rejoin [c-red "  Usage: /async /name <name> "prompt"" c-reset] return none]

            opts: make map! []
            if time-limit [
                parsed-time: async-manager/parse-time time-limit
                if parsed-time [put opts 'time-limit parsed-time]
            ]
            if loop-count > 1 [put opts 'loop-count loop-count]

            task: async-manager/create/options name prompt opts
            either object? task [
                task: async-manager/start task
                print rejoin [c-green "  ✓ Async task: " c-reset c-bright-white name c-reset c-dim " (" task/id ")" c-reset]
                if loop-count > 1 [print rejoin [c-dim "  Loops: " loop-count c-reset]]
                if time-limit [print rejoin [c-dim "  Time: " time-limit c-reset]]
            ][
                print rejoin [c-red "  ✗ " task c-reset]
            ]
        ]

        true [
            print rejoin [c-red "  Unknown /async command: " subcmd c-reset]
        ]
    ]
]

; ═══════════════════════════════════════════════════════════
;  /bg Command Handler
; ═══════════════════════════════════════════════════════════

handle-bg-command: func [args [string!] /local parts subcmd num result bg-sessions][
    args: trim args
    parts: split args " "
    subcmd: either empty? args [none][parts/1]

    case [
        ; /bg (no args) — send current to background
        any [none? subcmd  empty? subcmd] [
            ; Start background worker for current session
            result: start-background-worker
            either result [
                print rejoin [c-green "  ✓ Session sent to background: " c-reset
                              c-bright-white copy/part result 8 c-reset]
                ; Create new foreground
                session-manager/fresh
                cli-state/turn-count: 0
                init-foreground-session
                print rejoin [c-dim "  New foreground session: " c-reset
                              c-bright-white copy/part (session-manager/get-active)/id 8 c-reset]
            ][
                print rejoin [c-red "  ✗ Failed to start background worker." c-reset]
            ]
        ]

        ; /bg /list
        subcmd = "/list" [
            show-session-list
        ]

        ; /bg /drop <N>
        subcmd = "/drop" [
            num: attempt [to-integer parts/2]
            either num [
                result: session-manager/drop num
                print rejoin [c-dim "  " result c-reset]
            ][
                print rejoin [c-red "  Usage: /bg /drop <N>" c-reset]
            ]
        ]

        ; /bg /help
        subcmd = "/help" [
            show-bg-help
        ]

        ; /bg <N> — resume session N
        true [
            num: attempt [to-integer subcmd]
            either num [
                result: session-manager/resume num
                either block? result [
                    resumed: result/1
                    old: result/2
                    print rejoin [c-green "  ✓ Resumed session #" num " " c-reset
                                  c-bright-white copy/part resumed/id 8 c-reset
                                  c-dim " (state: " to-string resumed/state ")" c-reset]
                    if old [
                        print rejoin [c-dim "  Previous active sent to bg" c-reset]
                    ]
                    ; Show summary
                    if resumed/summary [
                        print rejoin [c-dim "  Summary: " c-reset resumed/summary]
                    ]
                    ; Load conversation into display
                    cli-state/turn-count: 0
                    ; Print last few messages for context
                    show-session-context resumed
                ][
                    print rejoin [c-red "  ✗ " result c-reset]
                ]
            ][
                print rejoin [c-red "  Usage: /bg <N> or /bg /list or /bg /drop <N>" c-reset]
            ]
        ]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Start Background Worker
; ═══════════════════════════════════════════════════════════

start-background-worker: func [
    /local active sid prompt cmd script-path log-path
][
    active: session-manager/get-active
    unless active [return none]

    sid: active/id

    ; Find the last user message as prompt
    prompt: ""
    foreach msg active/conversation [
        if (select msg 'role) = "user" [
            prompt: select msg 'content
        ]
    ]

    ; Save current state
    active/state: 'running
    session-manager/save-session active

    ; Build command to spawn worker
    script-path: to-string clean-path %./re-coder-bg-worker.reb
    log-path: rejoin [to-string session-manager/session-dir sid "worker.log"]

    cmd: rejoin [
        "cd " to-string what-dir " && "
        "nohup rebol3 " script-path
        " --session-id " sid
        " " mold prompt
        " > " log-path " 2>&1 &"
    ]

    ; Spawn non-blocking
    call/shell cmd

    ; Give it a moment to start
    wait 0:0:0.5

    ; Read PID from state file (worker writes it)
    attempt [
        state-file: rejoin [to-string session-manager/session-dir sid "/state.json"]
        state-map: try [load-json read to-rebol-file state-file]
        if map? state-map [
            active/process-id: select state-map 'process-id
        ]
    ]

    sid
]

; ═══════════════════════════════════════════════════════════
;  Show Session Context (when resuming)
; ═══════════════════════════════════════════════════════════

show-session-context: func [session /local conv msg role content tool-calls][
    conv: session/conversation
    unless block? conv [return none]

    print ""
    print rejoin [c-dim "  ── Session Context ──" c-reset]

    ; Show last few messages
    shown: 0
    foreach msg conv [
        role: select msg 'role
        if role = "system" [continue]

        content: any [select msg 'content  ""]
        tool-calls: any [select msg 'tool_calls  []]

        case [
            role = "user" [
                print ""
                print rejoin [c-bright-cyan "  ❯ " c-reset content]
            ]
            role = "assistant" [
                unless empty? content [
                    print rejoin [c-bright-white "  ▸ " c-reset
                                  either (length? content) > 200 [
                                      rejoin [copy/part content 200 c-dim "..." c-reset]
                                  ][content]]
                ]
                unless empty? tool-calls [
                    foreach tc tool-calls [
                        fn-data: select tc 'function
                        if map? fn-data [
                            print rejoin [c-yellow "  🔧 " select fn-data 'name c-reset]
                        ]
                    ]
                ]
            ]
            role = "tool" [
                result: any [select msg 'content ""]
                short: either (length? result) > 100 [
                    rejoin [copy/part result 100 c-dim "..." c-reset]
                ][result]
                print rejoin [c-green "  ✓ " c-reset c-dim short c-reset]
            ]
        ]
        shown: shown + 1
    ]

    ; Show output log if available
    if session/output-log [
        unless empty? session/output-log [
            print ""
            print rejoin [c-dim "  ── Background Output ──" c-reset]
            ; Show last 500 chars
            log: session/output-log
            either (length? log) > 500 [
                print rejoin [c-dim "  ..." copy/part skip log ((length? log) - 500) 500 c-reset]
            ][
                print rejoin [c-dim "  " log c-reset]
            ]
        ]
    ]

    print rejoin [c-dim "  ─────────────────────" c-reset]
    print ""
]

; ═══════════════════════════════════════════════════════════
;  Initialize Foreground Session
; ═══════════════════════════════════════════════════════════

init-foreground-session: func [/local active][
    active: session-manager/get-active
    unless active [
        ; Create initial session
        session-manager/create "Initial session" copy []
        session-manager/set-active session-manager/slot-order/1
        active: session-manager/get-active
    ]

    ; Ensure system prompt
    if empty? active/conversation [
        sys-msg: make map! reduce [
            to-set-word 'role {system}
            to-set-word 'content system-prompt
        ]
        append/only active/conversation sys-msg
    ]

    session-manager/save-session active
]

; ═══════════════════════════════════════════════════════════
;  Command Handler
; ═══════════════════════════════════════════════════════════

handle-command: func [cmd [string!] /local parts arg command active result][
    cmd: trim cmd
    parts: split cmd " "
    command: first parts
    arg: either (length? parts) > 1 [trim copy/part skip cmd length? first parts tail cmd][none]

    switch/default command [
        "/help"    [show-help]
        "/quit"    [cli-state/running: false  print rejoin [c-dim "  Goodbye!" c-reset]]
        "/exit"    [cli-state/running: false  print rejoin [c-dim "  Goodbye!" c-reset]]
        "/clear"   [
            active: session-manager/get-active
            if active [
                clear active/conversation
                init-foreground-session
            ]
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

        ; ── Session commands ──
        "/bg"      [handle-bg-command any [arg ""]]
        "/async"   [handle-async-command any [arg ""]]
        "/sessions" [show-session-list]
        "/fork"    [
            result: session-manager/fork
            either object? result [
                cli-state/turn-count: 0
                print rejoin [c-green "  ✓ Forked session: " c-reset
                              c-bright-white copy/part result/id 8 c-reset
                              c-dim " (copy of previous context)" c-reset]
                init-foreground-session
            ][
                print rejoin [c-red "  ✗ " result c-reset]
            ]
        ]
        "/new"     [
            session-manager/fresh
            cli-state/turn-count: 0
            init-foreground-session
            active: session-manager/get-active
            print rejoin [c-green "  ✓ New session: " c-reset
                          c-bright-white copy/part active/id 8 c-reset]
        ]
    ][
        print rejoin [c-red "  Unknown command: " command c-reset
                      c-dim "  Type /help for available commands" c-reset]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Prompt
; ═══════════════════════════════════════════════════════════

show-prompt: func [/local active sid-bg][
    active: session-manager/get-active
    sid-bg: either active [rejoin [c-dim "[" copy/part active/id 4 "]" c-reset]][""]

    either cli-state/multi-line [
        prin rejoin [c-bright-cyan "  ... " c-reset]
    ][
        prin rejoin [sid-bg " " c-bright-cyan "❯ " c-reset]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Multi-line Input
; ═══════════════════════════════════════════════════════════

read-multiline: func [/local lines line][
    lines: copy []
    print rejoin [c-dim "  Multi-line mode. Press Enter on empty line to submit." c-reset]
    forever [
        prin rejoin [c-dim "  ... " c-reset]
        line: input
        either empty? trim line [
            either empty? lines [
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

read-triple-slash: func [/local lines line][
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

main-loop: func [/local user-input][
    ; Initialize agent
    code-agent/init

    ; Load existing sessions from disk
    session-manager/load-all

    ; Initialize or restore foreground session
    init-foreground-session

    cli-state/session-start: now

    ; REPL
    while [cli-state/running] [
        show-prompt

        user-input: attempt [input]

        unless user-input [
            print ""
            print rejoin [c-dim "  Goodbye!" c-reset]
            break
        ]

        user-input: trim user-input

        if empty? user-input [continue]

        if user-input = "///" [
            user-input: read-triple-slash
            unless user-input [continue]
        ]

        if (first user-input) = #"/" [
            handle-command user-input
            continue
        ]

        if cli-state/multi-line [
            user-input: read-multiline
            unless user-input [continue]
        ]

        process-user-input user-input
    ]
]

; ═══════════════════════════════════════════════════════════
;  CLI Argument Parsing
; ═══════════════════════════════════════════════════════════

parse-cli-args: func [/local args i arg prompt-parts prompt][
    args: system/options/args
    unless args [return none]

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
            "--stream"    [config/stream-mode: true]
            "--no-stream" [config/stream-mode: false]
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
                print {}
                print {Session Commands (in REPL):}
                print {  /bg               Send current session to background}
                print {  /bg /list         List all sessions}
                print {  /bg <N>           Resume session N}
                print {  /bg /drop <N>     Drop session N}
                print {  /fork             Fork current session}
                print {  /new              Start fresh session}
                quit/return 0
            ]
        ][
            append prompt-parts arg
        ]
        i: i + 1
    ]

    unless empty? prompt-parts [
        prompt: join-items prompt-parts " "
        return reduce ['one-shot prompt]
    ]

    none
]

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════

main: func [/local mode prompt][
    unless config/api-key [
        print rejoin [c-red "  ❌ DEEPSEEK_API_KEY environment variable not set." c-reset]
        print rejoin [c-dim "  Usage: DEEPSEEK_API_KEY=*** rebol3 re-coder-cli.reb" c-reset]
        quit/return 1
    ]

    mode: parse-cli-args

    either mode [
        ; One-shot mode
        prompt: second mode
        show-banner
        print rejoin [c-dim "  One-shot mode:" c-reset]
        print rejoin [c-bright-white "  " prompt c-reset]
        print ""
        code-agent/init
        session-manager/create "One-shot task" copy []
        session-manager/set-active session-manager/slot-order/1
        init-foreground-session
        process-user-input prompt
    ][
        ; Interactive mode
        show-banner
        main-loop
    ]
]

main
