# re-coder-agent

A minimal code agent for **Rebol3**.

Tested with [Rebol3](https://github.com/Oldes/Rebol3) (`rebol3-bulk-macos-arm64`) and the [DeepSeek API](https://api-docs.deepseek.com/).

**Languages:** English (this file) · [中文](README.zh-CN.md)

## Repository layout

```
re-coder-ai/
├── re-coder-agent.reb              ← main agent script
├── re-coder-cli.reb                ← interactive CLI (REPL)
├── re-coder-bg-worker.reb          ← background worker process
├── re-coder-async-worker.reb       ← async task worker process
├── session-manager.reb             ← multi-session management
├── async-manager.reb               ← async task management
├── re-coder                        ← launcher script (chmod +x)
├── re-coder-rag-search.reb         ← RAG search/retrieval (grep/rg + optional LLM)
├── memory-manager.reb              ← persistent memory system (Rebol-native)
├── memory.reb                      ← agent memory file (auto-managed)
├── test-re-coder-rag-search.reb    ← RAG search tests (21 tests)
├── README.md                       ← this file (English)
└── README.zh-CN.md                 ← Chinese readme
```

### Memory System

The agent has **persistent memory** stored as executable Rebol code in `memory.reb`. The agent can read, modify, and search its own memory across sessions.

```bash
# Memory tools available to the agent:
read_memory()              # Full memory summary
read_memory("user/name")   # Read specific field
write_memory("corrections", "用户说营收按合同算")  # Record correction
write_memory("kv/project-x", "使用 Rust + WASM")   # Ad-hoc notes
search_memory("营收")       # Search all memory for keyword
```

Memory structure:
```rebol
make object! [
    user:       #[name: "..." language: "..." preferences: #[]]
    env:        #[os: "..." projects-dir: "..." tools: [...]]
    skills:     [#[name: "..." version: 1 last-used: ...]]
    corrections: [#[date: ... topic: "..." correction: "..."]]
    iterations: [#[date: ... change: "..." result: "pass"|"fail"]]
    projects:   [#[project: "..." path: "..." notes: "..."]]
    kv:         #[key: "value" ...]
]
```

## Requirements

- **Rebol3** (Oldes fork) — grab a prebuilt binary from [Oldes/Rebol3 releases](https://github.com/Oldes/Rebol3/releases) (3.21.0+).
- **`DEEPSEEK_API_KEY`** in your environment.

## Usage

```bash
# Basic
DEEPSEEK_API_KEY=sk-xxx \
rebol3 re-coder-agent.reb "Write a Node.js quicksort"

# Custom model and base URL
DEEPSEEK_API_KEY=sk-xxx \
rebol3 re-coder-agent.reb \
    --model kimi-k2.6 \
    --base-url https://api.moonshot.cn/v1 \
    "Explain how recursion works and write an example"


DEEPSEEK_API_KEY=sk-xxx \
rebol3 re-coder-agent.reb \
    --model mimo-v2.5-pro \
    --base-url https://api.xiaomimimo.com/v1 \
    "Explain how recursion works and write an example"

# Working directory for agent output
DEEPSEEK_API_KEY=sk-xxx \
rebol3 re-coder-agent.reb \
    --work-dir ./output/ \
    "Create a Python CLI tool"
```

### RAG Search (Document Retrieval)

### Interactive CLI

Launch an interactive coding session (like Claude Code / Codex):

```bash
# Interactive mode
DEEPSEEK_API_KEY=*** ./re-coder

# One-shot mode (prompt as argument)
DEEPSEEK_API_KEY=*** ./re-coder "Write a Python web scraper"

# With custom model
DEEPSEEK_API_KEY=*** ./re-coder --model deepseek-chat "Explain async/await"
```

**Session Commands:**

| Command | Description |
|---------|-------------|
| `/bg` | Send current session to background, start new foreground |
| `/bg /list` | List all sessions with status |
| `/bg <N>` | Resume session #N (bidirectional swap) |
| `/bg /drop <N>` | Drop session #N |
| `/fork` | Fork current session (copy context) |
| `/new` | Start a fresh session |

**Async Tasks:**

| Command | Description |
|---------|-------------|
| `/async /name <n> "prompt"` | Fire-and-forget background task |
| `/async /name <n> /time 5m "p"` | Time-limited task (s/m/h) |
| `/async /name <n> /loop 3 "p"` | Loop N iterations |
| `/async /list` | List all async tasks |
| `/async /task <name>` | View task output |
| `/async /kill <name>` | Kill running task |
| `/async /drop <name>` | Drop task + logs |


**General Commands:**

| Command | Description |
|---------|-------------|
| `/help` | Show help |
| `/quit` `/exit` | Exit |
| `/clear` | Clear conversation history |
| `/history` | Show message count |
| `/model <name>` | Switch model |
| `/workdir <dir>` | Set working directory |
| `/stream` | Toggle streaming ON/OFF |
| `/config` | Show current config |
| `/multi` | Toggle multi-line input mode |

**Multi-line input:**
- Type `///` (triple slash) to enter multi-line mode (one-shot)
- Or use `/multi` to toggle persistent multi-line mode

```bash
# Example session
$ ./re-coder
  ❯ Create a Python function that reads CSV files and returns a DataFrame
  ⏳ Thinking...
  ▸ I'll create a utility function for you...
  🔧 write_file (path=data_utils.py, content=...)
  ✓ Written 1234 bytes to data_utils.py
  🔧 run_command (command=python data_utils.py)
  ✓ (no output)
```

### Background Sessions (/bg)

Inspired by [auto-coder.chat's /bg](https://zhuhailin.com/zh/blog/bg-multi-session) — run multiple AI tasks in parallel within one terminal.

```bash
$ ./re-coder

# Start a long task
  ❯ [abc12345] ❯ Write a comprehensive test suite for my API
  ⏳ Thinking...
  ▸ I'll analyze your API and create tests...

# Task is running — send it to background
  ❯ /bg
  ✓ Session sent to background: abc12345
  New foreground session: def67890

# Now do something else in the new foreground
  ❯ [def67890] ❯ What's the quicksort algorithm?
  ▸ Quicksort is a divide-and-conquer...

# Check background progress
  ❯ /bg /list
  Sessions
  ────────────────────────────────────
    #  ID        State      Created   Summary
  ────────────────────────────────────
    1  abc12345  running    05-12     Write a comprehensive test suite...
    2  def67890  active     05-12     What's the quicksort algorithm...

# Resume the background session when done
  ❯ /bg 1
  ✓ Resumed session #1 abc12345 (state: done)
  Summary: Write a comprehensive test suite for my API

# Fork to try a different approach
  ❯ /fork
  ✓ Forked session: 789abc12 (copy of previous context)
```

`re-coder-rag-search.reb` implements **keyword retrieval** via `grep` or **ripgrep** (`rg`) when available. It is **not** semantic / embedding search: the query string is passed to the shell search tool as the match pattern, so use **tokens that actually appear** in your files (identifiers, comments, doc headings).

```bash
# Run search tests
rebol3 test-re-coder-rag-search.reb
# => 21/21 tests passed
```

Load once, then call the functions:

```rebol
do %./re-coder-rag-search.reb

; --- rag-grep / rag-search (same query semantics) ---
; dir-path: e.g. current dir %. 
; extensions: none -> search all indexed file types; or e.g. [%.reb %.md]
; max-results: cap hits (grep/rg pipeline uses head -n)

probe rag-grep {quicksort} %. [%.py] 10
results: rag-search {rag-search} %. [%.reb %.md] 5
probe rag-build-context results

; --- rag-ask (retrieve, build context, call chat API) ---
; Four required args; optional refinements override defaults.
; Default model/url DeepSeek unless you set DEEPSEEK_API_KEY or pass /key.

answer: rag-ask {rag-grep} %. [%.reb] 5

; Overrides (optional):
; answer: rag-ask {port} %. [%.reb %.md] 8 /model "deepseek-chat" /url "https://api.deepseek.com/v1" /key "sk-..."

; BAD for retrieval: a full English question as the only pattern (often zero hits in code):
; rag-ask "How does rag work?" %. [%.reb] 5
; Prefer keywords, or include %.md and use words from docs, e.g. {rag-search} or {re-coder-rag-search}.
```

**`rag-ask` signature**

| Part | Meaning |
|------|---------|
| `query` | Grep pattern (keywords / identifiers), not a conversational question |
| `dir-path` | Root directory (`%.` = current) |
| `extensions` | `none` or block of `%.ext` filters |
| `max-results` | Max grep hits fed into context |
| `/model name` | Chat model (default `deepseek-chat`) |
| `/url endpoint` | API base URL (default `https://api.deepseek.com/v1`) |
| `/key secret` | API key (else `get-env {DEEPSEEK_API_KEY}`) |

**Scope:** This repo ships **local keyword retrieval** only (`re-coder-rag-search.reb`). A separate **RAG service config / CRUD** module (akin to `RAGConfigManager` in auto-coder.rag) is **not included** for now.

**Rough parallel**

| Layer | auto-coder.rag | This repo |
|-------|---------------|-----------|
| Config (CRUD) | `RAGConfigManager` | *not shipped* |
| Retrieval | `LongContextRAG.search()` | `re-coder-rag-search.reb` (grep/rg-based) |

Available functions: `rag-grep`, `rag-search`, `rag-ask`, `rag-index-files`, `rag-build-context`, `rag-read-snippet`.
