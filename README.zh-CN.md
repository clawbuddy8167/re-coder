# re-coder-agent

适用于 **Rebol3** 的代码助手。

已在 [Rebol3](https://github.com/Oldes/Rebol3) `rebol3-bulk-macos-arm64` 与 [DeepSeek 模型](https://api-docs.deepseek.com/) 下测试。

**语言：** [English](README.md) · 简体中文（本页）

## 文件结构

```
re-coder/
├── re-coder-agent.reb     ← 主程序（约 750 行）
├── README.md              ← 默认英文说明
└── README.zh-CN.md        ← 本文件（中文）
```

## 依赖

- **Rebol3**（Oldes 分支）运行时 — 从 [Oldes/Rebol3](https://github.com/Oldes/Rebol3/releases) 下载预编译二进制（3.21.0+）
- 环境变量 **`DEEPSEEK_API_KEY`**

## 使用

```bash
# 基本用法
DEEPSEEK_API_KEY=sk-xxx 
rebol3 re-coder-agent.reb "Write a Node.js quicksort"

# 自定义模型和端点
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

# 指定工作目录
DEEPSEEK_API_KEY=sk-xxx 
rebol3 re-coder-agent.reb \
    --work-dir ./output/ \
    "Create a Python CLI tool"
```
