# re-coder-agent

A minimal code agent for **Rebol3**.

Tested with [Rebol3](https://github.com/Oldes/Rebol3) (`rebol3-bulk-macos-arm64`) and the [DeepSeek API](https://api-docs.deepseek.com/).

**Languages:** English (this file) · [中文](README.zh-CN.md)

## Repository layout

```
re-coder/
├── re-coder-agent.reb    ← main script (~750 lines)
├── README.md             ← this file (English)
└── README.zh-CN.md       ← Chinese readme
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
    --model deepseek-v4-flash \
    --base-url https://api.deepseek.com \
    "Explain how recursion works and write an example"

# Working directory for agent output
DEEPSEEK_API_KEY=sk-xxx \
rebol3 re-coder-agent.reb \
    --work-dir ./output/ \
    "Create a Python CLI tool"
```
