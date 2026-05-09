REBOL [
    Title: {Subagent Runner}
    Name: 'subagent-runner
    Version: 1.0.0
    Rights: {MIT}
]

subagent-runner: make object! [
    workdir: %./subagent-workdir/
    max-parallel: 4
    cleanup: false
    verbose: true

    safe-dir-name: func [title [string!] /local name c][
        name: copy ""
        foreach c to-string title [
            case [
                find "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" c [append name c]
                c = #" " [append name "-"]
                true [true]
            ]
        ]
        if empty? name [name: "task"]
        if (length? name) > 50 [name: copy/part name 50]
        name
    ]

    split-by-h2: func [content [string!] /local tasks lines current-task title line][
        tasks: copy []
        lines: split content newline
        current-task: copy ""
        title: "untitled"
        foreach line lines [
            case [
                all [
                    (length? line) > 3
                    (copy/part line 3) = "## "
                ][
                    if not empty? trim current-task [
                        append/only tasks reduce [title trim current-task]
                    ]
                    title: trim copy/part skip line 3 tail line
                    current-task: copy ""
                ]
                all [
                    (length? line) > 2
                    (copy/part line 2) = "# "
                ][
                    ; Skip H1 lines
                    true
                ]
                true [
                    append current-task line
                    append current-task newline
                ]
            ]
        ]
        if not empty? trim current-task [
            append/only tasks reduce [title trim current-task]
        ]
        tasks
    ]

    split-by-h1: func [content [string!] /local tasks lines current-task title][
        tasks: copy []
        lines: split content newline
        current-task: copy ""
        title: "untitled"
        foreach line lines [
            either all [
                (length? line) > 2
                (copy/part line 2) = "# "
            ][
                if not empty? trim current-task [
                    append/only tasks reduce [title trim current-task]
                ]
                title: trim copy/part skip line 2 tail line
                current-task: copy ""
            ][
                append current-task line
                append current-task newline
            ]
        ]
        if not empty? trim current-task [
            append/only tasks reduce [title trim current-task]
        ]
        tasks
    ]

    split-by-delimiter: func [content [string!] delim [string!] /local tasks parts idx][
        tasks: copy []
        parts: split content delim
        idx: 1
        foreach part parts [
            if not empty? trim part [
                append/only tasks reduce [rejoin ["task-" idx] trim part]
                idx: idx + 1
            ]
        ]
        tasks
    ]

    auto-split: func [content [string!] /local h1-count h2-count lines line][
        h1-count: 0
        h2-count: 0
        lines: split content newline
        foreach line lines [
            case [
                all [
                    (length? line) > 2
                    (copy/part line 2) = "# "
                ][h1-count: h1-count + 1]
                all [
                    (length? line) > 3
                    (copy/part line 3) = "## "
                ][h2-count: h2-count + 1]
            ]
        ]
        case [
            h1-count > 1 [split-by-h1 content]
            h2-count > 1 [split-by-h2 content]
            true [reduce [["single-task" content]]]
        ]
    ]

    create-workspace: func [task-id [string!] /local ws-path][
        ws-path: rejoin [workdir safe-dir-name task-id %/]
        make-dir/deep ws-path
        ws-path
    ]

    cleanup-workspace: func [task-id [string!] /local ws-path][
        if cleanup [
            ws-path: rejoin [workdir safe-dir-name task-id %/]
            attempt [delete-dir ws-path]
        ]
    ]

    cleanup-all: func [/local dirs dir][
        if exists? workdir [
            dirs: read workdir
            foreach dir dirs [
                if dir? rejoin [workdir dir] [
                    attempt [delete-dir rejoin [workdir dir]]
                ]
            ]
        ]
    ]

    generate-script: func [task-id [string!] code [string!] /local s][
        s: rejoin ["REBOL []^/; task: " task-id "^/" code "^/"]
        s
    ]

    execute-task: func [task-id [string!] code [string!] /local ws-path script-file marker-file cmd pid][
        ws-path: create-workspace task-id
        script-file: rejoin [ws-path %task.reb]
        write script-file generate-script task-id code
        marker-file: rejoin [ws-path %.done]
        cmd: rejoin [
            "cd " to-string ws-path " && "
            "rebol3 -q task.reb > output.log 2>&1; "
            "echo EXIT_CODE:$? > .done"
        ]
        pid: call/shell cmd
        reduce [task-id pid ws-path marker-file]
    ]

    check-task-done: func [marker-file [file!]][
        either exists? marker-file [true][false]
    ]

    read-task-output: func [ws-path [file!] /local log-file][
        log-file: rejoin [ws-path %output.log]
        either exists? log-file [to-string read log-file][""]
    ]

    read-task-exit-code: func [marker-file [file!] /local content exit-str][
        if exists? marker-file [
            content: to-string read marker-file
            if find content "EXIT_CODE:" [
                exit-str: trim copy/part skip find content "EXIT_CODE:" 10 tail content
                exit-str: trim/all exit-str
                return to-integer exit-str
            ]
        ]
        -1
    ]

    show-progress: func [total [integer!] completed [integer!] running [integer!] /local pct][
        unless verbose [exit]
        pct: to-integer (completed * 100) / total
        print rejoin ["  " pct "% (" completed "/" total ") Running: " running]
    ]

    run-parallel: func [
        tasks [block!]
        /local total running completed results
        new-running pair id code pid ws-path marker-file
        output exit-code start-time script-file
    ][
        total: (length? tasks) / 2
        running: copy []
        completed: copy []
        results: copy []
        start-time: now/time/precise

        if verbose [
            print ""
            print "====================================="
            print "  Subagent Runner"
            print "====================================="
            print rejoin ["  Tasks: " total]
            print rejoin ["  Max parallel: " max-parallel]
            print "  Starting..."
        ]

        foreach [id code] tasks [
            while [(length? running) >= max-parallel] [
                wait 0.2
                new-running: copy []
                foreach pair running [
                    marker-file: pick pair 4
                    either check-task-done marker-file [
                        exit-code: read-task-exit-code marker-file
                        append completed reduce [pick pair 1 pick pair 3 exit-code]
                        if verbose [
                            either exit-code = 0 [
                                print rejoin ["  OK  " pick pair 1]
                            ][
                                print rejoin ["  FAIL " pick pair 1 " (exit: " exit-code ")"]
                            ]
                        ]
                    ][
                        append/only new-running pair
                    ]
                ]
                running: new-running
            ]
            pair: execute-task id code
            append/only running pair
            if verbose [print rejoin ["  -> " id]]
        ]

        while [not empty? running] [
            wait 0.2
            new-running: copy []
            foreach pair running [
                id: pick pair 1
                pid: pick pair 2
                ws-path: pick pair 3
                marker-file: pick pair 4
                either check-task-done marker-file [
                    exit-code: read-task-exit-code marker-file
                    append completed reduce [id ws-path exit-code]
                    if verbose [
                        either exit-code = 0 [
                            print rejoin ["  OK  " id]
                        ][
                            print rejoin ["  FAIL " id " (exit: " exit-code ")"]
                        ]
                    ]
                ][
                    append/only new-running pair
                ]
            ]
            running: new-running
            show-progress total ((length? completed) / 3) (length? running)
        ]

        foreach [id ws-path exit-code] completed [
            output: read-task-output ws-path
            append/only results reduce [id output exit-code]
        ]

        foreach [id ws-path exit-code] completed [
            cleanup-workspace id
        ]

        if verbose [
            print "  ----------------------------"
            print rejoin ["  Done in " now/time/precise - start-time]
            print "====================================="
        ]

        results
    ]

    run-from-file: func [file [file!] /local content tasks flat pair][
        unless exists? file [
            print rejoin ["File not found: " file]
            return copy []
        ]
        content: to-string read file
        tasks: auto-split content
        if verbose [print rejoin ["  Split into " length? tasks " tasks"]]
        flat: copy []
        foreach pair tasks [
            append/only flat first pair
            append/only flat second pair
        ]
        run-parallel flat
    ]

    run-from-block: func [tasks [block!]][
        run-parallel tasks
    ]

    run-tasks: func [codes [block!] /local tasks idx][
        tasks: copy []
        idx: 1
        foreach code codes [
            append tasks reduce [rejoin ["task-" idx] code]
            idx: idx + 1
        ]
        run-parallel tasks
    ]
]

parallel: func [codes [block!] /max n [integer!] /local runner][
    runner: subagent-runner
    if max [runner/max-parallel: n]
    runner/run-tasks codes
]

parallel-file: func [file [file!] /local runner][
    runner: subagent-runner
    runner/run-from-file file
]

print "subagent-runner loaded"
