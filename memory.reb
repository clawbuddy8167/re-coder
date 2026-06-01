; ═══════════════════════════════════════════════════
; re-coder-agent memory file
; Auto-generated — edit with care, or let the agent manage it
; ═══════════════════════════════════════════════════

make object! [
    user: make object! [
        name: "祝海林"
        language: "zh-CN"
        preferences: #[
            verbose: true
            model: "deepseek-chat"
        ]
    ]

    env: make object! [
        os: "macOS"
        projects-dir: "~/Projects/"
        tools: copy []
    ]

    skills: copy []

    corrections: copy [
        #[
            date: 2026-05-31
            topic: "shell"
            correction: "不能用 cat，要用 read_file"
            applied: true
        ]
        #[
            date: 2026-05-31
            topic: "code"
            correction: "不能用 sed，要用 patch"
            applied: true
        ]
        #[
            date: 2026-05-31
            topic: "search"
            correction: "不能用 grep，要用 search_files"
            applied: true
        ]
    ]

    iterations: copy []

    projects: copy []

    kv: #[]

    ; ═══════════════════════════════════════════════════
    ; L2: Executable Rules (0 token cost — code executes directly)
    ; ═══════════════════════════════════════════════════

    ; Shell command validation rules
    ; Each: #[trigger: "bad_pattern"  fix: "good_replacement"  msg: "human message"]
    shell-rules: copy [
        #[
            trigger: "cat "
            fix: "read_file"
            msg: "不要用 cat，用 read_file 工具"
        ]
        #[
            trigger: "grep "
            fix: "search_files"
            msg: "不要用 grep，用 search_files 工具"
        ]
        #[
            trigger: "sed "
            fix: "patch"
            msg: "不要用 sed，用 patch 工具"
        ]
        #[
            trigger: "find "
            fix: "search_files"
            msg: "不要用 find，用 search_files 工具"
        ]
        #[
            trigger: "head "
            fix: "read_file"
            msg: "不要用 head，用 read_file 工具（支持 offset/limit）"
        ]
        #[
            trigger: "tail "
            fix: "read_file"
            msg: "不要用 tail，用 read_file 工具（支持 offset/limit）"
        ]
    ]

    ; Pre-execution hooks for any tool
    ; Each: #[tool: "tool_name"  check: func [args] [...]  action: "block"|"warn"]
    hooks: copy []
]
