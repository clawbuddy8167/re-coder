REBOL [
    Title:   {Async Task Manager}
    Name:    'async-manager
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Fire-and-forget async task management for re-coder CLI.
              Inspired by auto-coder's /async — spawn background agents
              for isolated tasks with time limits, loops, and workflows.}
]

; ═══════════════════════════════════════════════════════════
;  Constants
; ═══════════════════════════════════════════════════════════

ASYNC-DIR: %.re-coder/async/
ASYNC-META-DIR: %.re-coder/async/meta/
ASYNC-TASKS-DIR: %.re-coder/async/tasks/
MAX-ASYNC-TASKS: 16

; ═══════════════════════════════════════════════════════════
;  Task States
; ═══════════════════════════════════════════════════════════
;  pending → running → done
;                   → error
;                   → killed (via /kill)
;  queued (waiting for loop iteration)

; ═══════════════════════════════════════════════════════════
;  Async Task Object
; ═══════════════════════════════════════════════════════════

make-async-task: func [
    id       [string!]
    name     [string!]
    prompt   [string!]
    /options opts [map!]
][
    make object! [
        id:           id
        name:         name
        prompt:       prompt
        state:        'pending
        created:      now
        started:      none
        finished:     none
        process-id:   none
        output:       copy ""
        error-msg:    none
        ; Options
        time-limit:   any [select opts 'time-limit  none]   ; e.g. 5 minutes
        loop-count:   any [select opts 'loop-count  1]      ; how many times to run
        loop-current: 0
        workflow:     any [select opts 'workflow     none]   ; predefined workflow name
        model:        any [select opts 'model       none]   ; model override
        work-dir:     any [select opts 'work-dir    none]   ; working directory
    ]
]

; ═══════════════════════════════════════════════════════════
;  Async Manager
; ═══════════════════════════════════════════════════════════

async-manager: make object! [
    tasks: #[]          ; id -> task object
    name-to-id: #[]     ; name -> id (for /async /name xxx lookups)

    ; ── Generate task ID ──
    gen-id: func [/local chars id i][
        chars: "0123456789abcdef"
        id: copy ""
        repeat i 8 [
            append id pick chars (random 16)
        ]
        id
    ]

    ; ── Ensure directories ──
    ensure-dirs: func [] [
        make-dir/deep ASYNC-DIR
        make-dir/deep ASYNC-META-DIR
        make-dir/deep ASYNC-TASKS-DIR
    ]

    ; ── Task dir path ──
    task-dir: func [name [string!] /local safe][
        safe: sanitize-name name
        to-rebol-file rejoin [to-string ASYNC-TASKS-DIR safe "/"]
    ]

    ; ── Meta file path ──
    meta-file: func [id [string!] /local][
        to-rebol-file rejoin [to-string ASYNC-META-DIR id ".json"]
    ]

    ; ── Sanitize task name for filesystem ──
    sanitize-name: func [name [string!] /local out c][
        out: copy ""
        foreach c to-string name [
            case [
                find "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" c [append out c]
                c = #" " [append out "-"]
                true [true]
            ]
        ]
        if empty? out [out: "task"]
        if (length? out) > 40 [out: copy/part out 40]
        out
    ]

    ; ── Create a new async task ──
    create: func [
        name     [string!]
        prompt   [string!]
        /options opts [map!]
        /local id task td
    ][
        ensure-dirs

        ; Check limit
        if (length? keys-of tasks) >= MAX-ASYNC-TASKS [
            return rejoin ["Max async tasks (" MAX-ASYNC-TASKS ") reached. Drop some first."]
        ]

        ; Check duplicate name
        if select name-to-id name [
            return rejoin ["Task name '" name "' already exists. Use a different name or /drop it first."]
        ]

        id: gen-id
        task: make-async-task/options id name prompt any [opts #[]]

        put tasks id task
        put name-to-id name id

        ; Create task working directory
        td: task-dir name
        make-dir/deep td

        ; Save metadata
        save-meta task

        task
    ]

    ; ── Save task metadata to disk ──
    save-meta: func [task /local mf json][
        mf: meta-file task/id
        json: rejoin [
            "{" newline
            {  "id": "} task/id {",} newline
            {  "name": "} task/name {",} newline
            {  "prompt": "} escape-json task/prompt {",} newline
            {  "state": "} task/state {",} newline
            {  "created": "} task/created {",} newline
            {  "started": "} any [task/started "null"] {",} newline
            {  "finished": "} any [task/finished "null"] {",} newline
            {  "process-id": "} any [task/process-id "null"] {",} newline
            {  "time-limit": "} any [task/time-limit "null"] {",} newline
            {  "loop-count": } task/loop-count {,} newline
            {  "loop-current": } task/loop-current {,} newline
            {  "workflow": "} any [task/workflow "null"] {",} newline
            {  "model": "} any [task/model "null"] {",} newline
            {  "work-dir": "} any [task/work-dir "null"] {",} newline
            {  "error-msg": "} any [task/error-msg "null"] {"} newline
            "}"
        ]
        write mf json
    ]

    ; ── Escape JSON special chars ──
    escape-json: func [s [string!] /local out c][
        out: copy ""
        foreach c to-string s [
            case [
                c = #"^"" [append out {\"}]
                c = #"^/" [append out {\n}]
                c = #"^M" [true]  ; skip CR
                c = #"^-" [append out {\t}]
                true [append out c]
            ]
        ]
        out
    ]

    ; ── Load all tasks from disk ──
    load-all: func [/local files mf task-map id task max-n][
        ensure-dirs
        files: attempt [read ASYNC-META-DIR]
        unless files [return none]

        foreach f files [
            if (find to-string f) and (find to-string f ".json") [
                mf: to-rebol-file rejoin [to-string ASYNC-META-DIR to-string f]
                task-map: try [load-json read mf]
                if map? task-map [
                    id: select task-map 'id
                    if id [
                        task: make-async-task/options
                            id
                            any [select task-map 'name "unnamed"]
                            any [select task-map 'prompt ""]
                            reduce [
                                'time-limit select task-map 'time-limit
                                'loop-count any [select task-map 'loop-count 1]
                                'workflow select task-map 'workflow
                                'model select task-map 'model
                                'work-dir select task-map 'work-dir
                            ]
                        task/state: to-word any [select task-map 'state "pending"]
                        task/created: any [attempt [to-date select task-map 'created] now]
                        task/started: select task-map 'started
                        task/finished: select task-map 'finished
                        task/process-id: select task-map 'process-id
                        task/loop-current: any [select task-map 'loop-current 0]
                        task/error-msg: select task-map 'error-msg

                        ; Load output
                        output-file: to-rebol-file rejoin [to-string ASYNC-TASKS-DIR sanitize-name task/name "/output.log"]
                        if exists? output-file [
                            task/output: to-string read output-file
                        ]

                        put tasks id task
                        put name-to-id task/name id
                    ]
                ]
            ]
        ]
    ]

    ; ── Start a task ──
    start: func [
        task [object!]
        /local cmd script-path log-path output-file td
    ][
        task/state: 'running
        task/started: now
        save-meta task

        td: task-dir task/name
        output-file: rejoin [to-string td "output.log"]
        log-file: rejoin [to-string td "worker.log"]

        ; Clear output
        write to-rebol-file output-file ""

        script-path: to-string clean-path %./re-coder-async-worker.reb

        ; Build command
        cmd: rejoin [
            "cd " to-string what-dir " && "
            "nohup rebol3 " script-path
            " --task-id " task/id
            " --task-name " mold task/name
            " --loop-count " task/loop-count
        ]

        if task/time-limit [
            append cmd rejoin [" --time-limit " task/time-limit]
        ]

        if task/model [
            append cmd rejoin [" --model " task/model]
        ]

        if task/work-dir [
            append cmd rejoin [" --work-dir " task/work-dir]
        ]

        append cmd rejoin [" " mold task/prompt]
        append cmd rejoin [" > " log-file " 2>&1 &"]

        ; Spawn non-blocking
        call/shell cmd

        ; Brief wait to let it start
        wait 0:0:0.5

        ; Try to read PID
        attempt [
            state-file: rejoin [to-string td "state.json"]
            if exists? to-rebol-file state-file [
                state-map: try [load-json read to-rebol-file state-file]
                if map? state-map [
                    task/process-id: select state-map 'process-id
                ]
            ]
        ]

        save-meta task
        task
    ]

    ; ── List all tasks ──
    list: func [/local result task][
        result: copy []
        foreach [id task] tasks [
            append/only result reduce [
                task/name
                task/id
                to-string task/state
                format-time task/created
                task/loop-current
                task/loop-count
                either (length? task/prompt) > 50 [
                    rejoin [copy/part task/prompt 50 "..."]
                ][task/prompt]
            ]
        ]
        ; Sort by created time (newest first)
        sort/reverse result
        result
    ]

    ; ── Get task by name or id ──
    get-task: func [ref [string!] /local id][
        ; Try by name first
        id: select name-to-id ref
        if id [return select tasks id]
        ; Try by id
        select tasks ref
    ]

    ; ── Get task output ──
    get-output: func [task /local output-file td][
        td: task-dir task/name
        output-file: rejoin [to-string td "output.log"]
        if exists? to-rebol-file output-file [
            task/output: to-string read to-rebol-file output-file
        ]
        task/output
    ]

    ; ── Kill a task ──
    kill: func [task /local pid][
        task/state: 'killed
        pid: task/process-id
        if pid [
            attempt [call/shell rejoin ["kill " to-string pid " 2>/dev/null"]]
        ]
        task/finished: now
        save-meta task
        rejoin ["Killed task '" task/name "' (" task/id ")"]
    ]

    ; ── Drop a task ──
    drop: func [ref [string!] /local task id td][
        task: get-task ref
        unless task [return rejoin ["Task not found: " ref]]

        ; Kill if running
        if task/state = 'running [kill task]

        id: task/id
        name: task/name

        ; Remove from memory
        remove/key tasks id
        remove/key name-to-id name

        ; Remove files
        td: task-dir name
        attempt [call/shell rejoin ["rm -rf " to-string td]]
        attempt [call/shell rejoin ["rm -f " to-string meta-file id]]

        rejoin ["Dropped task '" name "' (" id ")"]
    ]

    ; ── Check if any tasks are running ──
    any-running: func [/local task][
        foreach [id task] tasks [
            if task/state = 'running [return true]
        ]
        false
    ]

    ; ── Poll tasks (check for state changes) ──
    poll: func [/local task td state-file state-map new-state output-file][
        foreach [id task] tasks [
            if task/state = 'running [
                td: task-dir task/name
                state-file: rejoin [to-string td "state.json"]
                if exists? to-rebol-file state-file [
                    state-map: try [load-json read to-rebol-file state-file]
                    if map? state-map [
                        new-state: to-word any [select state-map 'state "running"]
                        if new-state <> task/state [
                            task/state: new-state
                            task/finished: select state-map 'finished
                            task/error-msg: select state-map 'error-msg
                            task/loop-current: any [select state-map 'loop-current task/loop-current]
                            ; Reload output
                            output-file: rejoin [to-string td "output.log"]
                            if exists? to-rebol-file output-file [
                                task/output: to-string read to-rebol-file output-file
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]

    ; ── Format time ──
    format-time: func [dt /local][
        either dt [
            rejoin [
                pad/with copy/part to-string dt/month 2 "0" "-"
                pad/with copy/part to-string dt/day 2 "0" " "
                pad/with copy/part to-string dt/hour 2 "0" ":"
                pad/with copy/part to-string dt/minute 2 "0"
            ]
        ]["--"]
    ]

    ; ── Parse time string (e.g. "5m", "1h", "30s") → time! ──
    parse-time: func [s [string!] /local num unit][
        s: trim s
        if empty? s [return none]

        ; Extract number and unit
        num: copy ""
        unit: copy ""
        foreach c to-string s [
            case [
                find "0123456789" c [append num c]
                true [append unit c]
            ]
        ]

        either empty? num [none][
            num: to-integer num
            case [
                unit = "s" [to-time num]
                unit = "m" [to-time num * 60]
                unit = "h" [to-time num * 3600]
                true [to-time num * 60]  ; default minutes
            ]
        ]
    ]

    ; ── Show task detail ──
    format-detail: func [task /local lines][
        poll  ; refresh state
        lines: copy []
        append lines rejoin ["  Name:     " task/name]
        append lines rejoin ["  ID:       " task/id]
        append lines rejoin ["  State:    " task/state]
        append lines rejoin ["  Created:  " format-time task/created]
        if task/started [
            append lines rejoin ["  Started:  " format-time task/started]
        ]
        if task/finished [
            append lines rejoin ["  Finished: " format-time task/finished]
        ]
        if task/time-limit [
            append lines rejoin ["  Time:     " task/time-limit]
        ]
        append lines rejoin ["  Loops:    " task/loop-current "/" task/loop-count]
        if task/model [
            append lines rejoin ["  Model:    " task/model]
        ]
        append lines rejoin ["  Prompt:   " task/prompt]
        if task/error-msg [
            append lines rejoin ["  Error:    " task/error-msg]
        ]
        lines
    ]
]
