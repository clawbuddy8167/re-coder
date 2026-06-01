REBOL [
    Title:   {Memory Manager — Rebol-native persistent memory for re-coder agent}
    Name:    'memory-manager
    Author:  {Hermes Agent}
    Version: 1.0.0
    Rights:  {MIT}
    Purpose: {Load, query, and persist agent memory as executable Rebol code.
              
              DESIGN: memory is a Rebol object! stored in memory.reb.
              Agent loads it with `do`, modifies it in-place, saves with `mold`.
              Zero parsing cost — memory IS code.}
]

; ═══════════════════════════════════════════════════════════
;  Memory State (loaded from memory.reb or initialized fresh)
; ═══════════════════════════════════════════════════════════

memory: none

memory-file: %memory.reb

; ═══════════════════════════════════════════════════════════
;  Default Memory Template
; ═══════════════════════════════════════════════════════════

default-memory: func [] [
    make object! [
        ; ── User Profile ──
        user: make object! [
            name:     {unknown}
            language: {zh-CN}
            preferences: #[]  ; key-value pairs
        ]

        ; ── Environment ──
        env: make object! [
            os:          system/platform
            projects-dir: {~/Projects/}
            tools:       copy []  ; discovered tools
        ]

        ; ── Learned Skills ──
        ; Each: #[name: "..." version: 1  last-used: <date>  notes: "..."]
        skills: copy []

        ; ── Corrections ──
        ; User corrections the agent should remember
        ; Each: #[date: <date>  topic: "..."  correction: "..."  applied: true]
        corrections: copy []

        ; ── Iteration History ──
        ; Self-modification log
        ; Each: #[date: <date>  change: "..."  file: "..."  result: "pass"|"fail"]
        iterations: copy []

        ; ── Project Context ──
        ; Per-project notes accumulated over sessions
        ; Each: #[project: "..."  path: "..."  notes: "..."  last-visited: <date>]
        projects: copy []

        ; ── Ad-hoc Key-Value Store ──
        ; For anything that doesn't fit above
        kv: #[]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Load / Save
; ═══════════════════════════════════════════════════════════

load-memory: func [
    /path mem-path [file!]
    /local result
][
    if path [memory-file: mem-path]

    either exists? memory-file [
        result: try [do memory-file]
        either error? result [
            print [{⚠️ memory.reb parse error: } mold result]
            print {   Using default memory.}
            memory: default-memory
        ][
            either object? result [
                memory: result
                print [{✅ Memory loaded from } memory-file]
            ][
                print [{⚠️ memory.reb did not return an object, using defaults}]
                memory: default-memory
            ]
        ]
    ][
        print [{ℹ️ No } memory-file { found, creating default memory}]
        memory: default-memory
        save-memory
    ]
]

save-memory: func [
    /to  dest [file!]
    /local target serialized
][
    target: any [dest memory-file]

    ; Serialize with readable formatting
    serialized: mold/only memory

    ; Add header comment
    output: rejoin [
        {; ═══════════════════════════════════════════════════^/}
        {; re-coder-agent memory file^/}
        {; Auto-generated — edit with care, or let the agent manage it^/}
        {; Last saved: } now {^/}
        {; ═══════════════════════════════════════════════════^/}
        {^/}
        serialized
        {^/}
    ]

    write target output
    rejoin [{✅ Memory saved to } target { (} length? output { bytes)}]
]

; ═══════════════════════════════════════════════════════════
;  Query & Modify Helpers
; ═══════════════════════════════════════════════════════════

; Get a nested path from memory: memory-get "user/preferences/model"
memory-get: func [path-str [string!] /local parts current] [
    parts: split path-str "/"
    current: memory
    foreach p parts [
        unless object? current [return none]
        current: select current to-word p
    ]
    current
]

; Set a nested path: memory-set "user/preferences/model" "deepseek-chat"
memory-set: func [path-str [string!] value /local parts obj key] [
    parts: split path-str "/"
    if empty? parts [return none]

    obj: memory
    foreach p copy/part parts (length? parts) - 1 [
        unless object? obj [return none]
        obj: select obj to-word p
    ]

    key: to-word last parts
    if object? obj [
        either in obj key [
            set in obj key value
        ][
            ; Dynamic addition — Rebol objects don't natively support this
            ; Fall back to kv store
            put memory/kv path-str value
        ]
    ]
    true
]

; Append to a block field: memory-append "corrections" #[date: now ...]
memory-append: func [path-str [string!] item /local val] [
    val: memory-get path-str
    either block? val [
        append val item
        true
    ][
        false
    ]
]

; Search memory for a keyword across all text fields
memory-search: func [keyword [string!] /local results search-block] [
    results: copy []

    search-block: func [blk [block!] prefix [string!] /local i entry] [
        i: 1
        foreach entry blk [
            either map? entry [
                foreach [k v] entry [
                    if all [string? v  find v keyword] [
                        append results rejoin [prefix "/" i "/" k ": " copy/part v 100]
                    ]
                ]
            ][
                if all [string? entry  find entry keyword] [
                    append results rejoin [prefix "/" i ": " copy/part entry 100]
                ]
            ]
            i: i + 1
        ]
    ]

    search-block memory/corrections "corrections"
    search-block memory/iterations "iterations"
    search-block memory/projects "projects"
    search-block memory/skills "skills"

    ; Search kv store
    foreach [k v] memory/kv [
        if all [string? v  find v keyword] [
            append results rejoin ["kv/" k ": " copy/part v 100]
        ]
    ]

    either empty? results [{(no matches)}] [join results newline]
]

; ═══════════════════════════════════════════════════════════
;  Auto-Memory Helpers (called by agent after key events)
; ═══════════════════════════════════════════════════════════

; Record a user correction
remember-correction: func [topic [string!] correction [string!]] [
    append memory/corrections reduce [
        make map! reduce [
            to-set-word 'date        now
            to-set-word 'topic       topic
            to-set-word 'correction  correction
            to-set-word 'applied     true
        ]
    ]
    save-memory
    rejoin [{📝 Remembered correction: } topic]
]

; Record a self-iteration
remember-iteration: func [change [string!] file [string!] result [string!]] [
    append memory/iterations reduce [
        make map! reduce [
            to-set-word 'date    now
            to-set-word 'change  change
            to-set-word 'file    file
            to-set-word 'result  result
        ]
    ]
    save-memory
    rejoin [{🔄 Recorded iteration: } change]
]

; Record project context
remember-project: func [project [string!] path [string!] notes [string!] /local found] [
    ; Update existing or add new
    found: false
    foreach p memory/projects [
        if select p 'project = project [
            put p 'notes notes
            put p 'last-visited now
            found: true
            break
        ]
    ]
    unless found [
        append memory/projects reduce [
            make map! reduce [
                to-set-word 'project       project
                to-set-word 'path          path
                to-set-word 'notes         notes
                to-set-word 'last-visited  now
            ]
        ]
    ]
    save-memory
    rejoin [{📁 Updated project memory: } project]
]

; Discover and record tools in environment
discover-tools: func [/local tools-list tool-name] [
    tools-list: copy []
    foreach [cmd name] [
        {git}       {git}
        {python3}   {python3}
        {node}      {node}
        {ffmpeg}    {ffmpeg}
        {docker}    {docker}
        {rebol3}    {rebol3}
    ][
        tool-name: name
        call-result: try [call/wait/shell/output rejoin [{which } cmd] ""]
        unless error? call-result [
            append tools-list tool-name
        ]
    ]
    memory/env/tools: tools-list
    save-memory
    rejoin [{🔧 Discovered tools: } join tools-list ", "]
]

; ═══════════════════════════════════════════════════════════
;  Export as text (for injecting into system prompt)
; ═══════════════════════════════════════════════════════════

memory-summary: func [/local lines] [
    lines: copy []

    ; User
    append lines rejoin [{User: } memory/user/name { (lang: } memory/user/language {)}]
    unless empty? memory/user/preferences [
        append lines rejoin [{Preferences: } mold memory/user/preferences]
    ]

    ; Corrections (last 5)
    if (length? memory/corrections) > 0 [
        append lines {Recent corrections:}
        count: 0
        foreach c reverse copy memory/corrections [
            count: count + 1
            if count > 5 [break]
            append lines rejoin [{  - } select c 'topic {: } select c 'correction]
        ]
    ]

    ; Skills
    if (length? memory/skills) > 0 [
        append lines rejoin [{Known skills: } length? memory/skills]
        foreach s memory/skills [
            append lines rejoin [{  - } select s 'name { v} select s 'version]
        ]
    ]

    ; Projects (last 3)
    if (length? memory/projects) > 0 [
        append lines {Recent projects:}
        count: 0
        foreach p reverse copy memory/projects [
            count: count + 1
            if count > 3 [break]
            append lines rejoin [{  - } select p 'project {: } copy/part any [select p 'notes ""] 80]
        ]
    ]

    ; Iterations (last 3)
    if (length? memory/iterations) > 0 [
        append lines {Recent self-iterations:}
        count: 0
        foreach it reverse copy memory/iterations [
            count: count + 1
            if count > 3 [break]
            append lines rejoin [{  - } select it 'change { → } select it 'result]
        ]
    ]

    either empty? lines [{(no memory yet)}] [join lines newline]
]
