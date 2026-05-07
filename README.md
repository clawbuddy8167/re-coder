# re-coder-agent

A minimal code agent for **Rebol3**.

Tested with [Rebol3](https://github.com/Oldes/Rebol3) (`rebol3-bulk-macos-arm64`) and the [DeepSeek API](https://api-docs.deepseek.com/).

**Languages:** English (this file) · [中文](README.zh-CN.md)

## Repository layout

```
re-coder-ai/
├── re-coder-agent.reb              ← main agent script
├── re-coder-rag-search.reb         ← RAG search/retrieval (grep/rg + optional LLM)
├── test-re-coder-rag-search.reb    ← RAG search tests (21 tests)
├── README.md                       ← this file (English)
└── README.zh-CN.md                 ← Chinese readme
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
