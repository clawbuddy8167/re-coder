REBOL [
    Title:   {Session Manager — Multi-session background support}
    Name:    'session-manager
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Manages multiple concurrent sessions for re-coder-cli.
              Each session has independent conversation history, state,
              and output. Supports background execution via child processes.}
]

; ═══════════════════════════════════════════════════════════
;  Constants
; ═══════════════════════════════════════════════════════════

MAX-BACKGROUND-SESSIONS: 16
SESSION-STATES: [running done idle cancelled error]
SESSIONS-DIR: %.re-coder/sessions/

; ═══════════════════════════════════════════════════════════
;  Session Object
; ═══════════════════════════════════════════════════════════

make-session: func [
    id       [string!]
    summary  [string!]
    conversation [block!]
    /state st [word!]
][
    make object! [
        id:           id
        state:        any [st 'idle]
        created:      now
        summary:      summary
        conversation: copy conversation
        output-log:   copy ""
        process-id:   none   ; OS PID of background worker
        slot:         none   ; slot number when in background
    ]
]

; ═══════════════════════════════════════════════════════════
;  Session Manager
; ═══════════════════════════════════════════════════════════

session-manager: make object! [
    ; ── State ──
    sessions: copy #[]        ; id -> session object
    slot-order: copy []       ; ordered list of session ids (for slot numbering)
    active-id: none           ; current foreground session id
    next-slot: 1

    ; ── Generate short ID ──
    gen-id: func [/local chars id i][
        chars: "0123456789abcdef"
        id: copy ""
        repeat i 8 [
            append id pick chars (random 16)
        ]
        id
    ]

    ; ── Get session dir path ──
    session-dir: func [id [string!] /local dir][
        dir: rejoin [to-string SESSIONS-DIR id "/"]
        to-rebol-file dir
    ]

    ; ── Ensure sessions directory exists ──
    ensure-dir: func [] [
        make-dir/deep SESSIONS-DIR
    ]

    ; ── Create a new session ──
    create: func [
        summary  [string!]
        conversation [block!]
        /local id session dir
    ][
        ensure-dir
        id: gen-id
        session: make-session/with-state id summary conversation 'idle
        session/slot: next-slot
        put sessions id session
        append slot-order id
        next-slot: next-slot + 1

        ; Persist
        save-session session

        session
    ]

    ; ── Set active (foreground) session ──
    set-active: func [id [string!] none-ok [logic!] /local session][
        session: select sessions id
        unless session [
            either none-ok [return none][
                make error! rejoin ["Session not found: " id]
            ]
        ]
        set in self 'active-id id
        session
    ]

    ; ── Get active session ──
    get-active: func [/local session][
        unless active-id [return none]
        select sessions active-id
    ]

    ; ── Find next free slot ──
    free-slot: func [/local i][
        ; Find first gap in slot numbers, or append
        i: 1
        foreach id slot-order [
            either i = slot [
                i: i + 1
            ][break]
        ]
        i
    ]

    ; ── List background sessions ──
    list-background: func [/local result session][
        result: copy []
        foreach id slot-order [
            session: select sessions id
            if all [session  id <> active-id] [
                append/only result session
            ]
        ]
        result
    ]

    ; ── Get session by slot number ──
    by-slot: func [num [integer!] /local session][
        foreach id slot-order [
            session: select sessions id
            if all [session  session/slot = num] [
                return session
            ]
        ]
        none
    ]

    ; ── Send active to background ──
    send-to-background: func [/local session][
        session: get-active
        unless session [
            return "No active session to send to background."
        ]
        session/state: 'idle
        save-session session

        ; Create new foreground session
        new-fg: create "New session" copy []
        set in self 'active-id new-fg/id

        reduce [session new-fg]
    ]

    ; ── Resume session from background ──
    resume: func [num [integer!] /local bg-session old-fg result][
        bg-session: by-slot num
        unless bg-session [
            return rejoin ["No session in slot #" num]
        ]

        ; Swap: old foreground goes to background, bg comes to foreground
        old-fg: get-active
        if old-fg [
            old-fg/state: 'idle
            save-session old-fg
        ]

        ; Mark bg session as active
        bg-session/state: 'idle
        set in self 'active-id bg-session/id
        save-session bg-session

        reduce [bg-session old-fg]
    ]

    ; ── Drop session ──
    drop: func [num [integer!] /local bg-session id][
        bg-session: by-slot num
        unless bg-session [
            return rejoin ["No session in slot #" num]
        ]

        ; If running, try to cancel
        if bg-session/state = 'running [
            cancel-session bg-session
        ]

        ; Remove from slot-order and sessions
        id: bg-session/id
        remove find slot-order id
        remove/key sessions id

        ; Cleanup disk
        cleanup-session-dir id

        rejoin ["Dropped session #" num " (" id ")"]
    ]

    ; ── Fork current session ──
    fork: func [/local active new-session][
        active: get-active
        unless active [
            return "No active session to fork."
        ]
        new-session: create rejoin ["Fork of: " active/summary] active/conversation
        set in self 'active-id new-session/id
        new-session
    ]

    ; ── New session (clear and start fresh) ──
    fresh: func [/local old new-session][
        old: get-active
        if old [
            old/state: 'idle
            save-session old
        ]
        new-session: create "New session" copy []
        set in self 'active-id new-session/id
        new-session
    ]

    ; ── Persist session to disk ──
    save-session: func [session /local dir state-file conv-file output-file][
        dir: session-dir session/id
        make-dir/deep dir

        ; State file
        state-file: rejoin [to-string dir "state.json"]
        write to-rebol-file state-file to-json reduce [
            'id session/id
            'state to-string session/state
            'created to-string session/created
            'summary session/summary
            'slot session/slot
            'process-id session/process-id
        ]

        ; Conversation file
        conv-file: rejoin [to-string dir "conversation.json"]
        write to-rebol-file conv-file to-json session/conversation

        ; Output log
        output-file: rejoin [to-string dir "output.log"]
        write to-rebol-file output-file session/output-log
    ]

    ; ── Load session from disk ──
    load-session: func [id [string!] /local dir state-file conv-file output-file state-map conv session][
        dir: session-dir id

        state-file: rejoin [to-string dir "state.json"]
        unless exists? to-rebol-file state-file [return none]

        state-map: try [load-json read to-rebol-file state-file]
        unless map? state-map [return none]

        conv-file: rejoin [to-string dir "conversation.json"]
        conv: either exists? to-rebol-file conv-file [
            try [load-json read to-rebol-file conv-file]
        ][copy []]
        unless block? conv [conv: copy []]

        output-file: rejoin [to-string dir "output.log"]
        output: either exists? to-rebol-file output-file [
            to-string read to-rebol-file output-file
        ][copy ""]

        session: make-session/with-state id
            any [select state-map 'summary "untitled"]
            conv
            to-word any [select state-map 'state "idle"]

        session/slot: any [select state-map 'slot 0]
        session/process-id: select state-map 'process-id
        session/output-log: output
        session/created: any [
            attempt [to-date select state-map 'created]
            now
        ]

        session
    ]

    ; ── Load all sessions from disk ──
    load-all: func [/local dirs id session max-slot][
        ensure-dir
        dirs: attempt [read SESSIONS-DIR]
        unless dirs [return]

        max-slot: 0
        foreach dir dirs [
            ; dir is like "abcd1234/"
            id: trim/with to-string dir "/"
            if (length? id) >= 8 [
                session: load-session copy/part id 8
                if session [
                    put sessions session/id session
                    append slot-order session/id
                    if session/slot > max-slot [max-slot: session/slot]
                ]
            ]
        ]
        next-slot: max-slot + 1
    ]

    ; ── Update session output (called by background worker) ──
    append-output: func [id [string!] text [string!] /local session output-file dir][
        session: select sessions id
        unless session [return]

        append session/output-log text

        ; Also append to disk file
        dir: session-dir session/id
        output-file: rejoin [to-string dir "output.log"]
        write/append to-rebol-file output-file text
    ]

    ; ── Update session state ──
    set-state: func [id [string!] st [word!] /local session][
        session: select sessions id
        unless session [return]
        session/state: st
        save-session session
    ]

    ; ── Cancel a running session ──
    cancel-session: func [session /local pid][
        pid: session/process-id
        if pid [
            attempt [
                call/shell rejoin ["kill " to-string pid]
            ]
        ]
        session/state: 'cancelled
        session/process-id: none
        save-session session
    ]

    ; ── Cleanup session directory ──
    cleanup-session-dir: func [id [string!] /local dir][
        dir: session-dir id
        attempt [
            call/shell rejoin ["rm -rf " to-string dir]
        ]
    ]

    ; ── Check if any background session is running ──
    any-running: func [/local session][
        foreach id slot-order [
            if id <> active-id [
                session: select sessions id
                if session/state = 'running [return true]
            ]
        ]
        false
    ]

    ; ── Poll background sessions (check state files for updates) ──
    poll-backgrounds: func [/local dir state-file state-map session][
        foreach id slot-order [
            if id <> active-id [
                session: select sessions id
                if session/state = 'running [
                    ; Re-read state from disk (worker may have updated it)
                    dir: session-dir id
                    state-file: rejoin [to-string dir "state.json"]
                    if exists? to-rebol-file state-file [
                        state-map: try [load-json read to-rebol-file state-file]
                        if map? state-map [
                            new-state: to-word any [select state-map 'state "running"]
                            if new-state <> session/state [
                                session/state: new-state
                                ; Reload output
                                output-file: rejoin [to-string dir "output.log"]
                                if exists? to-rebol-file output-file [
                                    session/output-log: to-string read to-rebol-file output-file
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]

    ; ── Summary for /bg /list ──
    format-list: func [/local result session state-color created-str summary-preview][
        poll-backgrounds
        result: copy []
        foreach id slot-order [
            session: select sessions id
            if session [
                either id = active-id [
                    append/only result reduce [
                        session/slot
                        copy/part session/id 8
                        "active"
                        format-time session/created
                        either (length? session/summary) > 40 [
                            rejoin [copy/part session/summary 40 "..."]
                        ][session/summary]
                    ]
                ][
                    append/only result reduce [
                        session/slot
                        copy/part session/id 8
                        to-string session/state
                        format-time session/created
                        either (length? session/summary) > 40 [
                            rejoin [copy/part session/summary 40 "..."]
                        ][session/summary]
                    ]
                ]
            ]
        ]
        result
    ]

    ; ── Time formatting helper ──
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
]
