REBOL [
    Title:   {Re Coder Agent (Rebol3)}
    Name:    're-coder-agent
    Author:  {Hermes Agent}
    Version: 2.0.0
    Rights:  {MIT}
    Purpose: {A minimal code agent with LLM client, tool registry, and agent loop.
              Written for Rebol3 (Rebol/Bulk 3.21.0+).
              
              KEY DESIGN RULE: auto-evaluates function! values on access.
              NEVER store function! in map!/block!. Store word! and use
              do/reduce pattern to invoke: do reduce ['apply :fn-word arg-block]}
]

; ═══════════════════════════════════════════════════════════
;  Configuration
; ═══════════════════════════════════════════════════════════

config: make object! [
    model:    {deepseek-chat}
    api-key:  any [get-env {DEEPSEEK_API_KEY}  get-env {OPENAI_API_KEY}  {}]
    base-url: any [get-env {DEEPSEEK_BASE_URL}  {https://api.deepseek.com}]
    work-dir: %./agent-output/
    max-turns: 20
    response-cutoff: 3000         ; max chars from tool output
    print-llm-input: false
    print-llm-output: true
    ; 0 = print full raw HTTP body; >0 = only first N chars (when print-llm-output)
    llm-raw-output-chars: 10000
    ; Parsed assistant message (content / tool_calls) as JSON-ish log
    print-llm-parsed: true
]

; ═══════════════════════════════════════════════════════════
;  Helpers
; ═══════════════════════════════════════════════════════════

json-to-map: func [json [string!]] [
    try [load-json json]
]

join-items: func [items [block!] sep [string! char!]] [
    out: copy {}
    first?: true
    foreach item items [
        unless first? [append out sep]
        append out to-string item
        first?: false
    ]
    out
]

; ─ First top-level `{ ... }` in s (handles strings; ignores braces inside "...").
; Returns `[blob remainder]` or none.
split-leading-json-object: func [s [string!]] [
    start: find s #"{"
    unless start [return none]

    depth: 0
    in-str: false
    esc: false
    p: start

    while [not tail? p] [
        c: first p
        either in-str [
            either esc [esc: false] [
                either c = #"\" [esc: true] [
                    if c = #"^"" [in-str: false]
                ]
            ]
        ][
            case [
                c = #"^"" [in-str: true]
                c = #"{" [depth: depth + 1]
                c = #"}" [
                    depth: depth - 1
                    if depth = 0 [
                        return reduce [
                            copy/part start next p
                            next p
                        ]
                    ]
                ]
                true [true]
            ]
        ]
        p: next p
    ]
    none
]

; load-json glue-fail → try tail from first `{` → peel multiple `{…}{…}` blobs, keep last OK map.

load-chat-completion-map: func [output [string!]] [
    parsed: try [load-json output]
    if map? parsed [return parsed]

    js: find output #"{"
    if js [
        parsed: try [load-json copy/part js tail output]
        if map? parsed [return parsed]
    ]

    last-m: none
    cnt: 0
    rem: output
    while [true] [
        pair: split-leading-json-object rem
        unless pair [break]
        cnt: cnt + 1
        blob: first pair
        rem: second pair
        m: try [load-json blob]
        if map? m [last-m: m]
    ]
    if all [cnt > 1  map? last-m] [
        print [{⚠ Raw HTTP body had } cnt { JSON objects glued together; using the last one for this turn.}]
    ]
    last-m
]

; ═══════════════════════════════════════════════════════════
;  HTTP POST helper
;
;  Rebol3's built-in write url [post headers body]
;  times out against modern TLS servers (DeepSeek, OpenAI).
;  Use curl via call/output instead for reliable connectivity.
; ═══════════════════════════════════════════════════════════

http-post-json: func [
    url     [url! string!]
    payload [map!]
    headers [map!]
][
    body: to-json payload
    unless body [print {❌ to-json failed} return none]

    auth-header: select headers 'Authorization
    content-type: select headers 'Content-Type
    unless content-type [content-type: {application/json}]

    ; Build curl command — use temp file for body to avoid shell quoting issues
    ; restricts /tmp/, use current directory for temp file
    tmpfile: %./.hermes-http-body.tmp
    write tmpfile body

    curl-cmd: rejoin [
        {curl -s --connect-timeout 15 --max-time 120 }
        {-X POST }
        {-H "Content-Type: } content-type {" }
        {-H "Authorization: } auth-header {" }
        {--data-binary @} to-string tmpfile { }
        { } url { }
    ]

    output: ""
    err: try [ec: call/wait/shell/output curl-cmd output]
    if error? err [
        print [{❌ curl failed: } mold err]
        return none
    ]

    ; call/output may fill output as binary! — load-json requires string!
    output: to-string output

    if config/print-llm-output [
        n: length? output
        lim: config/llm-raw-output-chars
        either all [integer? lim  positive? lim] [
            show: copy/part output lim
            if n > lim [append show {...}]
            print [{  Raw response (first } lim { chars, total } n {):} newline show]
        ][
            print [{  Raw response (full, } n { chars):} newline output]
        ]
    ]

    ; Strip UTF-8 BOM if present
    bom: #{EF BB BF}
    if all [
        (length? output) >= 3
        bom = copy/part output 3
    ][
        output: skip output 3
    ]

    parsed: load-chat-completion-map output

    ; load-chat-completion-map returns none or map! (already handled try/err inside)
    unless map? parsed [
        print [{❌ JSON parse failed. Output (first 300 chars):}]
        print copy/part output 300
        print [{  (response length: } length? output { chars)}]
        return none
    ]

    parsed
]

; ═══════════════════════════════════════════════════════════
;  LLM Client
; ═══════════════════════════════════════════════════════════

llm-client: make object! [
    chat: func [
        messages [block!]
        /with-tools tool-defs [block!]
    ][
        url: to-url rejoin [config/base-url {/chat/completions}]

        payload: make map! reduce [
            to-set-word 'model config/model
            to-set-word 'messages messages
            ; to-set-word 'temperature 0.1
        ]

        if with-tools [
            put payload 'tools tool-defs
            put payload 'tool_choice {auto}
        ]

        headers: make map! reduce [
            to-set-word 'Content-Type {application/json}
            to-set-word 'Authorization rejoin [{Bearer } config/api-key]
        ]

        if config/print-llm-input [
            print [newline {── LLM Request ──}]
            print [{  URL: } url]
            print [{  Body: } to-json payload]
            print {──────────────────}
        ]

        http-post-json url payload headers
    ]
]

; ═══════════════════════════════════════════════════════════
;  Helper: reliable /local detection
; ═══════════════════════════════════════════════════════════

is-local?: func [w [word! refinement!]] [
    not none? find "local" to-string w
]

; ═══════════════════════════════════════════════════════════
;  Tool Registry
;
;  CORE DESIGN: auto-evaluates function! values when
;  accessed via select, path syntax, or assignment. So we
;  NEVER store functions. Instead store the function name as
;  a word! and invoke via: do reduce ['apply :fn-word args]
;
;  Also: cannot do 'words-of' on a dynamic word reference
;  (':fn-word' in do/reduce causes auto-evaluation). So tools
;  must register their parameter structure directly.
; ═══════════════════════════════════════════════════════════

tool-registry: make object! [
    tools: #[]

    register: func [
        name         [string!]
        handler-word [word!]
        params       [block!]
        tool-spec    [block! map!]
    ][
        entry: make map! reduce [
            to-set-word 'handler-word handler-word
            to-set-word 'params params
            to-set-word 'spec tool-spec
        ]
        put tools name entry
    ]

    ; Build the arg block for apply from stored params structure.
    ; params block has same format as words-of output:
    ;   [/path dir-path]  — refinement + its parameter
    ;   [path content]    — simple positional params
    build-arg-block: func [params [block!] args [map!]] [
        result: clear copy []
        i: 1
        len: length? params

        while [i <= len] [
            w: pick params i

            ; Stop at /local section
            if all [refinement? :w  is-local? w] [break]

            if refinement? :w [
                ; e.g. /path -> match 'path key in args map
                ref-key: to-word to-string w
                arg-val: select args ref-key
                if arg-val <> none [
                    append result w
                    ; Consume the refinement's parameter if present
                    if i < len [
                        next-w: pick params (i + 1)
                        unless any [refinement? :next-w  is-local? next-w] [
                            append result arg-val
                            i: i + 1
                        ]
                    ]
                ]
                i: i + 1
                continue
            ]

            ; Regular positional parameter — skip if not in args
            val: select args w
            if val <> none [append result val]
            i: i + 1
        ]

        result
    ]

    execute: func [name [string!] args [map!]] [
        entry: select tools name
        unless entry [return rejoin [{❌ Unknown tool: } name]]

        fn-word: select entry 'handler-word
        unless fn-word [return rejoin [{❌ Tool } name { has no handler-word}]]

        params: any [select entry 'params  copy []]
        arg-block: build-arg-block params args

        ; Invoke: do reduce ['apply :fn-word arg-block]
        ; This avoids function! auto-evaluation entirely.
        call-block: reduce ['apply to-get-word fn-word arg-block]
        result: try [do call-block]

        if error? result [
            return rejoin [{❌ Error: } mold result]
        ]

        ; Normalize result to string for LLM
        either string? result [
            result
        ][
            either none? result [
                {[No output]}
            ][
                either any [block? result  map? result  object? result] [
                    to-json result
                ][
                    to-string :result
                ]
            ]
        ]
    ]

    specs: func [] [
        result: copy []
        foreach [name entry] tools [
            spec: select entry 'spec
            if spec [append result spec]
        ]
        result
    ]
]

; ═══════════════════════════════════════════════════════════
;  Built-in Tools
; ═══════════════════════════════════════════════════════════

tool-write-file: func [
    path    [string!]
    content [string!]
][
    full-path: either find path {/} [
        to-rebol-file path
    ][
        to-rebol-file rejoin [to-string config/work-dir path]
    ]

    dir: first split-path full-path
    make-dir/deep dir
    write full-path content

    rejoin [{✅ Written } (length? content) { bytes to } path]
]

tool-read-file: func [
    path [string!]
][
    full-path: either find path {/} [
        to-rebol-file path
    ][
        to-rebol-file rejoin [to-string config/work-dir path]
    ]

    unless exists? full-path [
        return rejoin [{❌ File not found: } path]
    ]

    to-string read full-path
]

tool-run-command: func [
    command [string!]
][
    output: ""
    err: try [
        ec: call/wait/shell/output command output
    ]

    if error? err [
        return rejoin [{❌ Command failed: } mold err]
    ]

    if empty? output [
        return {(no output)}
    ]

    trimmed: copy/part output config/response-cutoff
    if (length? output) > config/response-cutoff [
        append trimmed newline
        append trimmed {⏱ [Output truncated]}
    ]

    trimmed
]

tool-list-files: func [/path dir-path [string!]] [
    unless dir-path [dir-path: {.}]

    result: try [
        files: read to-rebol-file dir-path
        collected: collect [
            foreach f files [
                unless find [{%node_modules} {%venv} {%__pycache__} {%git}] f [
                    keep to-string f
                ]
            ]
        ]
        collected
    ]

    if error? result [return rejoin [{❌ Cannot list: } mold result]]
    if empty? result [return {(empty directory)}]

    join-items result newline
]

; ═══════════════════════════════════════════════════════════
;  Memory Manager (load before tools, so tools can use it)
; ═══════════════════════════════════════════════════════════

unless value? 'memory-manager [do %./memory-manager.reb]

; ═══════════════════════════════════════════════════════════
;  Memory Tools
; ═══════════════════════════════════════════════════════════

tool-read-memory: func [
    /path path-str [string!]
][
    either path [
        val: memory-get path-str
        either none? val [
            rejoin [{❌ Memory path not found: } path-str]
        ][
            either object? val [
                mold val
            ][
                to-string mold val
            ]
        ]
    ][
        memory-summary
    ]
]

tool-write-memory: func [
    key   [string!]
    value [string!]
][
    ; Try to parse value as Rebol, fall back to string
    parsed: try [load value]
    actual-val: either any [error? parsed  none? parsed] [value] [parsed]

    either find key "/" [
        ; Nested path: "corrections" append, "kv/foo" set
        either find key "kv/" [
            kv-key: copy/part skip key 3 length? key
            put memory/kv kv-key actual-val
            save-memory
            rejoin [{✅ Set kv/} kv-key]
        ][
            memory-set key actual-val
            save-memory
            rejoin [{✅ Set } key]
        ]
    ][
        ; Top-level: append to a block or set a value
        either key = "corrections" [
            remember-correction "manual" value
        ][
            either key = "iterations" [
                remember-iteration value "manual" "recorded"
            ][
                put memory/kv key actual-val
                save-memory
                rejoin [{✅ Set kv/} key]
            ]
        ]
    ]
]

tool-search-memory: func [
    keyword [string!]
][
    memory-search keyword
]

; ═══════════════════════════════════════════════════════════
;  Scheduler Tools (self-ping + subagent coordination)
; ═══════════════════════════════════════════════════════════

; Ensure scheduler is loaded (standalone mode guard)
unless value? 'scheduler [do %./scheduler.reb]

tool-spawn-subagent: func [
    name    [string!]
    prompt  [string!]
    /model  model-name [string!]
    /workdir wd [string!]
] [
    either model [
        either workdir [
            scheduler/spawn-subagent/model/workdir name prompt model-name to-rebol-file wd
        ][
            scheduler/spawn-subagent/model name prompt model-name
        ]
    ][
        either workdir [
            scheduler/spawn-subagent/workdir name prompt to-rebol-file wd
        ][
            scheduler/spawn-subagent name prompt
        ]
    ]
]

tool-check-subagent: func [
    id [string!]
] [
    result: scheduler/check-subagent id
    either map? result [
        rejoin [
            "Subagent " id " [" select result 'state "]^/"
            "Output:^/" select result 'output
        ]
    ][
        to-string result
    ]
]

tool-schedule-check: func [
    seconds [integer!]
    prompt  [string!]
] [
    delay: to-time seconds
    result: scheduler/schedule-timer delay prompt
    either string? result [
        rejoin ["❌ " result]
    ][
        rejoin ["✅ Scheduled self-check in " seconds "s (timer: " result ") — will inject: " copy/part prompt 80]
    ]
]

; ═══════════════════════════════════════════════════════════
;  OpenAI-style Tool Specs (for LLM tool definitions)
; ═══════════════════════════════════════════════════════════

tool-specs: compose/deep [
    #[
        type: {function}
        function: #[
            name: {write_file}
            description: {Write content to a file (creates directories if needed).}
            parameters: #[
                type: {object}
                properties: #[
                    path: #[type: {string} description: {File path}]
                    content: #[type: {string} description: {File content}]
                ]
                required: [{path} {content}]
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {read_file}
            description: {Read a file's contents.}
            parameters: #[
                type: {object}
                properties: #[
                    path: #[type: {string} description: {File path}]
                ]
                required: [{path}]
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {run_command}
            description: {Execute a shell command and capture its output.}
            parameters: #[
                type: {object}
                properties: #[
                    command: #[type: {string} description: {Shell command to execute}]
                ]
                required: [{command}]
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {list_files}
            description: {List files in a directory.}
            parameters: #[
                type: {object}
                properties: #[
                    path: #[type: {string} description: {Directory path (default: current)}]
                ]
                required: []
            ]
        ]
    ]
    ; ── Memory tools ──
    #[
        type: {function}
        function: #[
            name: {read_memory}
            description: {Read agent memory. No args = full summary. With path = read specific field, e.g. "user/preferences" or "corrections". Memory is persisted across sessions.}
            parameters: #[
                type: {object}
                properties: #[
                    path: #[type: {string} description: {Optional dot-path like "user/name" or "corrections". Omit for full summary.}]
                ]
                required: []
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {write_memory}
            description: {Write to agent memory. Key can be "corrections" (append), "iterations" (append), "kv/xxx" (set key-value), or a nested path. Value is stored as Rebol data. Memory auto-saves to memory.reb.}
            parameters: #[
                type: {object}
                properties: #[
                    key: #[type: {string} description: {Memory key: "corrections", "iterations", "kv/mykey", "user/preferences"}]
                    value: #[type: {string} description: {Value to store. Can be Rebol syntax or plain text.}]
                ]
                required: [{key} {value}]
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {search_memory}
            description: {Search agent memory for a keyword. Scans corrections, iterations, projects, skills, and kv store. Returns matching entries.}
            parameters: #[
                type: {object}
                properties: #[
                    keyword: #[type: {string} description: {Search term to find in memory}]
                ]
                required: [{keyword}]
            ]
        ]
    ]
    ; ── Scheduler tools ──
    #[
        type: {function}
        function: #[
            name: {spawn_subagent}
            description: {Spawn a background subagent to work on a task independently. Returns immediately with a subagent ID. Use check_subagent to poll its status. The subagent runs re-coder-agent.reb as an isolated process.}
            parameters: #[
                type: {object}
                properties: #[
                    name: #[type: {string} description: {A short name for this subagent task}]
                    prompt: #[type: {string} description: {The full prompt for the subagent to work on}]
                    model: #[type: {string} description: {Optional model override for the subagent}]
                    workdir: #[type: {string} description: {Optional working directory for the subagent}]
                ]
                required: [{name} {prompt}]
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {check_subagent}
            description: {Check the status and output of a spawned subagent. Returns state (running/done/error) and output so far.}
            parameters: #[
                type: {object}
                properties: #[
                    id: #[type: {string} description: {The subagent ID returned by spawn_subagent}]
                ]
                required: [{id}]
            ]
        ]
    ]
    #[
        type: {function}
        function: #[
            name: {schedule_check}
            description: {Schedule a self-ping: after N seconds, the prompt is injected back into your conversation automatically. Use this to check on subagents or retry tasks after a delay. You remain active — the prompt comes to you.}
            parameters: #[
                type: {object}
                properties: #[
                    seconds: #[type: {integer} description: {Seconds to wait before injecting the prompt}]
                    prompt: #[type: {string} description: {The prompt to inject when the timer fires, e.g. "Check if subagent sa-abc123 is done"}]
                ]
                required: [{seconds} {prompt}]
            ]
        ]
    ]
]

; ═══════════════════════════════════════════════════════════
;  System Prompt
; ═══════════════════════════════════════════════════════════

system-prompt: {You are a Code Agent — an AI that writes, reads, and runs code.

You have these tools:
1. `write_file(path, content)` — Create or overwrite a file
2. `read_file(path)` — Read a file's contents
3. `run_command(command)` — Execute a shell command
4. `list_files(path)` — List files in a directory
5. `read_memory(path?)` — Read your persistent memory (omit path for full summary)
6. `write_memory(key, value)` — Write to persistent memory (auto-saves to memory.reb)
7. `search_memory(keyword)` — Search memory for a keyword
8. `spawn_subagent(name, prompt)` — Spawn a background subagent (returns ID immediately)
9. `check_subagent(id)` — Check subagent status and get output
10. `schedule_check(seconds, prompt)` — Schedule a self-ping after N seconds

Memory System (IMPORTANT):
- You have persistent memory in memory.reb that survives across sessions
- Memory includes: user profile, corrections, iteration history, project notes, kv store
- When the user corrects you, write_memory("corrections", "the correction") so you remember
- When you modify yourself, write_memory("iterations", "what changed")
- When you learn about a project, write_memory("kv/project-name", "notes")
- At the start of complex tasks, read_memory() to recall relevant context
- Use search_memory("keyword") to find related past experiences

Workflow:
1. Check memory for relevant context: read_memory()
2. Analyze the user's request
3. Plan which files to create / modify
4. Use tools one at a time
5. Always verify: after writing code, run it to make sure it works
6. Record learnings: write_memory("iterations", "what I did")
7. Report the final result to the user

Self-Scheduling Pattern (IMPORTANT):
When you spawn subagents, you can stay alive by scheduling self-checks:
- spawn_subagent("build frontend", "Build the React app...") → returns id "sa-abc123"
- spawn_subagent("build backend", "Build the API server...") → returns id "sa-def456"
- schedule_check(10, "Check if subagent sa-abc123 and sa-def456 are done")
After this, stop responding. When the timer fires, you get the prompt back automatically.
Then check_subagent each one, collect results, and either schedule another check or report.

This is like setting an alarm clock — you pause, the alarm wakes you up with a reminder.

Rules:
- Write clean, well-commented code
- Include error handling
- Run verification commands to confirm correctness
- If something fails, fix it and retry
- For parallel work, use spawn_subagent + schedule_check instead of blocking waits
- Remember corrections and learnings in memory
}

; ═══════════════════════════════════════════════════════════
;  Agent Loop
; ═══════════════════════════════════════════════════════════

code-agent: make object! [
    registry: none

    init: func [] [
        set in self 'registry tool-registry

        ; Load persistent memory
        load-memory

        ; Register tools — pass word! (not function!) to avoid auto-evaluation
        ; params = words-of output at compile time:
        ;   tool-write-file:  [path content]
        ;   tool-read-file:   [path]
        ;   tool-run-command: [command]
        ;   tool-list-files:  [/path dir-path]
        registry/register {write_file}  'tool-write-file  [path content]         pick tool-specs 1
        registry/register {read_file}   'tool-read-file   [path]                 pick tool-specs 2
        registry/register {run_command} 'tool-run-command [command]              pick tool-specs 3
        registry/register {list_files}  'tool-list-files  [/path dir-path]       pick tool-specs 4
        ; Memory tools
        registry/register {read_memory}   'tool-read-memory   [/path path-str]   pick tool-specs 5
        registry/register {write_memory}  'tool-write-memory  [key value]        pick tool-specs 6
        registry/register {search_memory} 'tool-search-memory [keyword]          pick tool-specs 7
        ; Scheduler tools
        registry/register {spawn_subagent} 'tool-spawn-subagent [name prompt /model model-name /workdir wd] pick tool-specs 8
        registry/register {check_subagent} 'tool-check-subagent [id]              pick tool-specs 9
        registry/register {schedule_check} 'tool-schedule-check [seconds prompt]  pick tool-specs 10
    ]

    run: func [user-prompt [string!]] [
        ; Build initial messages with memory context
        sys-msg: make map! reduce [
            to-set-word 'role {system}
            to-set-word 'content system-prompt
        ]

        ; Inject memory summary into user message
        mem-context: memory-summary
        enriched-prompt: rejoin [
            user-prompt
            {^/^[Memory Context:^/} mem-context {^/]^/}
        ]

        user-msg: make map! reduce [
            to-set-word 'role {user}
            to-set-word 'content enriched-prompt
        ]
        messages: reduce [sys-msg user-msg]

        make-dir/deep config/work-dir

        repeat turn config/max-turns [
            print [newline {=== Turn } turn { ===}]

            response: llm-client/chat/with-tools messages registry/specs
            unless response [
                return {❌ LLM call failed — check your API key and endpoint.}
            ]

            choices: select response 'choices
            if any [not block? choices  empty? choices] [
                return {❌ Unexpected response format (missing or empty choices array).}
            ]

            choice: pick choices 1
            unless map? choice [
                return {❌ Unexpected response format (invalid first choice).}
            ]
            msg: select choice 'message
            unless map? msg [return {❌ Unexpected response format (no message).}]

            if config/print-llm-parsed [
                print [newline {── LLM 出参 (assistant message) ──}]
                pj: try [to-json msg]
                either all [string? pj  not empty? pj] [
                    print pj
                ][
                    print mold msg
                ]
                useg: select response 'usage
                if map? useg [
                    uj: try [to-json useg]
                    either all [string? uj  not empty? uj] [
                        print [{  usage: } uj]
                    ][
                        print [{  usage: } mold useg]
                    ]
                ]
                print {──────────────────}
            ]

            append messages msg

            text: any [select msg 'content  {}]
            tool-calls: any [select msg 'tool_calls  []]

            if empty? tool-calls [
                print [newline {[Done] Agent finished in } turn { turns.}]
                done-msg: make map! reduce [
                    to-set-word 'role {system}
                    to-set-word 'content {[Task complete. Report the result to the user in your next response.]}
                ]
                append messages done-msg
                return text
            ]

            foreach tc tool-calls [
                fn-data: select tc 'function
                tool-msg: none
                either map? fn-data [
                    fn-name: select fn-data 'name
                    fn-args-json: select fn-data 'arguments
                    unless string? fn-args-json [fn-args-json: "{}"]

                    ; On parse failure try yields error!, which is truthy — never pass to select
                    fn-args: try [load-json fn-args-json]
                    unless map? fn-args [fn-args: #[]]

                    print [{  🔧 } fn-name { } mold fn-args]

                    ; Resolve relative file paths against work-dir
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

                    short: copy/part result 500
                    if (length? result) > 500 [append short {...}]
                    print [{  → } short]

                    tool-msg: make map! reduce [
                        to-set-word 'role {tool}
                        to-set-word 'tool_call_id select tc 'id
                        to-set-word 'content result
                    ]
                ][
                    print [{  ⚠ Malformed tool_calls item (no function map): } mold copy/part mold tc 120]
                    tool-msg: make map! reduce [
                        to-set-word 'role {tool}
                        to-set-word 'tool_call_id any [select tc 'id  {-}]
                        to-set-word 'content {[Tool error: missing function object in tool_calls]}
                    ]
                ]
                append messages tool-msg
            ]
        ]

        {⏱ Max turns reached.}
    ]
]

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════

main: func [] [
    unless config/api-key [
        print {❌ DEEPSEEK_API_KEY environment variable not set.}
        print {Usage: DEEPSEEK_API_KEY=*** rebol3 re-coder-agent.r3 <prompt>}
        print {   or: DEEPSEEK_API_KEY=*** rebol3 re-coder-agent.r3 --model deepseek-chat --base-url <url> {Write a Node.js quicksort}}
        quit/return 1
    ]

    args: system/options/args
    unless args [
        print {❌ No prompt provided.}
        print {Usage: DEEPSEEK_API_KEY=*** rebol3 re-coder-agent.r3 <prompt>}
        quit/return 1
    ]

    ; Parse flags and prompt from args
    prompt-parts: copy []
    i: 1
    while [i <= length? args] [
        arg: pick args i
        switch/default arg [
            {--model} [
                i: i + 1
                if i <= length? args [config/model: pick args i]
            ]
            {--base-url} [
                i: i + 1
                if i <= length? args [config/base-url: pick args i]
            ]
            {--work-dir} [
                i: i + 1
                if i <= length? args [
                    config/work-dir: to-rebol-file pick args i
                ]
            ]
        ][
            append prompt-parts arg
        ]
        i: i + 1
    ]

    prompt: {}
    unless empty? prompt-parts [
        prompt: join-items prompt-parts { }
    ]

    ; Banner
    print [newline {■ Re Coder Agent (Rebol3)}]
    print [{  Model:  } config/model]
    print [{  API:    } config/base-url]
    print [{  Dir:    } config/work-dir]
    print [newline {  Prompt: } prompt newline]

    ; Run agent
    agent: code-agent
    agent/init
    result: agent/run prompt

    print [newline {==========================================}]
    print {■ Agent final response:}
    print result
]

; === Bootstrap ===
main
