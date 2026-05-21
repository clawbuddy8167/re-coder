REBOL [
    Title:   {Scheduler — Built-in timer and subagent coordination}
    Name:    'scheduler
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Built-in scheduler for re-coder agent. Manages:
              1. Self-ping timers — agent schedules reminders for itself
              2. Subagent registry — track spawned child agent processes
              3. Poll loop — CLI calls poll-timers to inject due prompts

              KEY INSIGHT (from Phantty/反重力):
              The agent pauses main thread, sets a Timer to send itself
              prompts to maintain liveness, while subagents do work
              in parallel. This is "内置 scheduler" — not external cron,
              but the agent's own self-coordination mechanism.}
]

; ═══════════════════════════════════════════════════════════
;  Scheduler State
; ═══════════════════════════════════════════════════════════

scheduler: make object! [
    ; ── Scheduled self-pings ──
    ; Each: #[id: "abc" fire-at: <datetime> prompt: "..." recurring: none|<time> fired: false]
    timers: copy []

    ; ── Subagent registry ──
    ; Each: #[id: "sa-abc" name: "..." pid: <int> workdir: %... state: running|done|error
    ;        marker-file: %... result: "" created: <datetime>]
    subagents: copy []

    ; ── Pending prompts to inject into conversation ──
    ; When a timer fires or subagent completes, the prompt goes here.
    ; CLI main loop picks these up between user inputs.
    pending-prompts: copy []

    ; ── Config ──
    max-timers: 32
    max-subagents: 8
    poll-interval: 0:0:2      ; 2 seconds

    ; ═══════════════════════════════════════════════════════
    ;  Timer Management
    ; ═══════════════════════════════════════════════════════

    gen-id: func [prefix [string!] /local chars id i] [
        chars: "0123456789abcdef"
        id: copy prefix
        repeat i 6 [append id pick chars (random 16)]
        id
    ]

    ; Schedule a self-ping: after 'delay' (time!), inject 'prompt' into conversation.
    ; Returns timer ID.
    schedule-timer: func [
        delay   [time!]
        prompt  [string!]
        /recurring interval [time!]   ; if set, re-fire every interval
        /local id timer
    ] [
        if (length? timers) >= max-timers [
            return rejoin ["Max timers (" max-timers ") reached."]
        ]

        id: gen-id "tmr-"
        timer: make map! reduce [
            to-set-word 'id id
            to-set-word 'fire-at now + delay
            to-set-word 'prompt prompt
            to-set-word 'recurring either recurring [interval][none]
            to-set-word 'fired false
        ]
        append timers timer

        ; Also spawn a background sleep process for precise timing
        spawn-timer-process id delay

        id
    ]

    ; Cancel a timer by ID
    cancel-timer: func [id [string!] /local new-timers] [
        new-timers: copy []
        foreach t timers [
            unless (select t 'id) = id [append/only new-timers t]
        ]
        timers: new-timers
        ; Clean up marker file
        attempt [delete to-rebol-file rejoin [".re-coder/timers/" id ".ready"]]
        rejoin ["Cancelled timer " id]
    ]

    ; Spawn a background process that sleeps then writes a marker
    spawn-timer-process: func [id [string!] delay [time!] /local cmd delay-sec marker-dir] [
        marker-dir: %.re-coder/timers/
        make-dir/deep marker-dir

        delay-sec: to-integer delay/hour * 3600 + (delay/minute * 60) + delay/second
        if delay-sec < 1 [delay-sec: 1]

        cmd: rejoin [
            "(sleep " delay-sec " && echo 'ready' > "
            to-string marker-dir id ".ready) &"
        ]
        call/shell cmd
    ]

    ; Poll timers — check if any are due. Returns list of due prompts.
    poll-timers: func [/local now-t due-list remaining t marker-file] [
        now-t: now
        due-list: copy []
        remaining: copy []

        foreach t timers [
            either (select t 'fired) [
                ; If recurring, check if it's time to re-fire
                if all [
                    select t 'recurring
                    now-t >= (select t 'fire-at)
                ] [
                    append due-list select t 'prompt
                    t/fire-at: now-t + select t 'recurring
                ]
                append/only remaining t
            ][
                ; Check if due
                either now-t >= (select t 'fire-at) [
                    ; Verify marker file exists (background sleep done)
                    marker-file: to-rebol-file rejoin [".re-coder/timers/" select t 'id ".ready"]
                    either exists? marker-file [
                        t/fired: true
                        append due-list select t 'prompt
                        attempt [delete marker-file]
                        ; If recurring, schedule next
                        if select t 'recurring [
                            t/fire-at: now-t + select t 'recurring
                            spawn-timer-process select t 'id select t 'recurring
                        ]
                        append/only remaining t
                    ][
                        ; Marker not ready yet, keep waiting
                        append/only remaining t
                    ]
                ][
                    append/only remaining t
                ]
            ]
        ]

        timers: remaining

        ; Queue due prompts
        foreach p due-list [append pending-prompts p]

        due-list
    ]

    ; Get next pending prompt (consumed — removed from queue)
    next-pending: func [] [
        if empty? pending-prompts [return none]
        result: first pending-prompts
        pending-prompts: skip pending-prompts 1
        result
    ]

    ; ═══════════════════════════════════════════════════════
    ;  Subagent Management
    ; ═══════════════════════════════════════════════════════

    ; Spawn a subagent: runs 'prompt' in an isolated child process.
    ; Returns subagent ID immediately (non-blocking).
    spawn-subagent: func [
        name    [string!]
        prompt  [string!]
        /model  model-name [string!]
        /workdir wd [file!]
        /local id sa-dir marker-file cmd pid sa
    ] [
        if (length? subagents) >= max-subagents [
            return rejoin ["Max subagents (" max-subagents ") running. Wait for some to finish."]
        ]

        id: gen-id "sa-"
        sa-dir: to-rebol-file rejoin [".re-coder/subagents/" id "/"]
        make-dir/deep sa-dir

        marker-file: rejoin [to-string sa-dir ".done"]

        ; Build command: run re-coder-agent.reb with the prompt
        cmd: rejoin [
            "cd " to-string what-dir " && "
            "rebol3 re-coder-agent.reb "
            "--work-dir " to-string sa-dir " "
        ]
        if model-name [append cmd rejoin ["--model " model-name " "]]
        append cmd rejoin [mold prompt " > " to-string sa-dir "output.log 2>&1; "]
        append cmd rejoin ["echo EXIT_CODE:$? > " marker-file " &"]

        call/shell cmd

        sa: make map! reduce [
            to-set-word 'id id
            to-set-word 'name name
            to-set-word 'workdir sa-dir
            to-set-word 'state "running"
            to-set-word 'marker-file to-rebol-file marker-file
            to-set-word 'created now
        ]
        append subagents sa

        id
    ]

    ; Check subagent status. Returns map with state and output.
    check-subagent: func [id [string!] /local sa output-file exit-code content] [
        sa: none
        foreach s subagents [
            if (select s 'id) = id [sa: s break]
        ]
        unless sa [return rejoin ["Subagent not found: " id]]

        ; Check if done
        if (select sa 'state) = "running" [
            either exists? (select sa 'marker-file) [
                ; Read exit code
                exit-code: 0
                attempt [
                    content: to-string read (select sa 'marker-file)
                    if find content "EXIT_CODE:" [
                        exit-str: trim copy/part skip find content "EXIT_CODE:" 10 tail content
                        exit-code: to-integer trim/all exit-str
                    ]
                ]
                sa/state: either exit-code = 0 ["done"]["error"]
            ][
                ; Still running — return partial output
                output-file: to-rebol-file rejoin [to-string select sa 'workdir "output.log"]
                partial: either exists? output-file [
                    out: to-string read output-file
                    either (length? out) > 1000 [
                        rejoin ["...(running, last 1000 chars)^/" copy/part skip out ((length? out) - 1000) 1000]
                    ][out]
                ]["(no output yet)"]

                return make map! reduce [
                    to-set-word 'id id
                    to-set-word 'name select sa 'name
                    to-set-word 'state "running"
                    to-set-word 'output partial
                ]
            ]
        ]

        ; Read final output
        output-file: to-rebol-file rejoin [to-string select sa 'workdir "output.log"]
        output: either exists? output-file [to-string read output-file]["(no output)"]

        make map! reduce [
            to-set-word 'id id
            to-set-word 'name select sa 'name
            to-set-word 'state select sa 'state
            to-set-word 'output output
        ]
    ]

    ; List all subagents
    list-subagents: func [/local result sa] [
        result: copy []
        foreach sa subagents [
            ; Refresh state if running
            if (select sa 'state) = "running" [
                if exists? (select sa 'marker-file) [sa/state: "done"]
            ]
            append/only result reduce [
                select sa 'id
                select sa 'name
                select sa 'state
                select sa 'created
            ]
        ]
        result
    ]

    ; Wait for a specific subagent to finish (blocking with timeout)
    wait-subagent: func [
        id      [string!]
        /timeout t [time!]
        /local sa deadline
    ] [
        sa: none
        foreach s subagents [
            if (select s 'id) = id [sa: s break]
        ]
        unless sa [return rejoin ["Subagent not found: " id]]

        unless t [t: 0:0:30]  ; default 30s timeout
        deadline: now + t

        while [now < deadline] [
            if (select sa 'state) <> "running" [
                return check-subagent id
            ]
            if exists? (select sa 'marker-file) [
                sa/state: "done"
                return check-subagent id
            ]
            wait 0:0:1
        ]

        ; Timeout — return partial result
        check-subagent id
    ]

    ; Clean up a finished subagent
    cleanup-subagent: func [id [string!] /local new-subs sa] [
        new-subs: copy []
        foreach sa subagents [
            either (select sa 'id) = id [
                attempt [
                    call/shell rejoin ["rm -rf " to-string select sa 'workdir]
                ]
            ][
                append/only new-subs sa
            ]
        ]
        subagents: new-subs
        rejoin ["Cleaned up subagent " id]
    ]

    ; ═══════════════════════════════════════════════════════
    ;  Status / Display
    ; ═══════════════════════════════════════════════════════

    status: func [/local lines t sa] [
        lines: copy []
        append lines "Scheduler Status:"
        append lines rejoin ["  Timers: " length? timers " active"]
        foreach t timers [
            append lines rejoin [
                "    " select t 'id " → fires at " select t 'fire-at
                either select t 'recurring [rejoin [" (every " select t 'recurring ")"]][""]
                either select t 'fired [" (fired)"][""]
            ]
        ]
        append lines rejoin ["  Subagents: " length? subagents " registered"]
        foreach sa subagents [
            append lines rejoin [
                "    " select sa 'id " [" select sa 'state "] " select sa 'name
            ]
        ]
        append lines rejoin ["  Pending prompts: " length? pending-prompts]
        lines
    ]

    ; Check if there's anything to do (timers due or subagents finished)
    has-work: func [] [
        either (length? pending-prompts) > 0 [true][
            foreach sa subagents [
                if all [
                    (select sa 'state) = "running"
                    exists? (select sa 'marker-file)
                ] [return true]
            ]
            false
        ]
    ]
]

print "scheduler loaded"
