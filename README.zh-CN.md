# re-coder-agent

适用于 **Rebol3** 的代码助手。

已在 [Rebol3](https://github.com/Oldes/Rebol3) `rebol3-bulk-macos-arm64` 与 [DeepSeek 模型](https://api-docs.deepseek.com/) 下测试。

**语言：** [English](README.md) · 简体中文（本页）

## 文件结构

```
re-coder-ai/
├── re-coder-agent.reb              ← 主程序
├── re-coder-cli.reb                ← 交互式 CLI (REPL)
├── re-coder-bg-worker.reb          ← 后台 worker 进程
├── session-manager.reb             ← 多会话管理
├── re-coder                        ← 启动脚本 (chmod +x)
├── re-coder-rag-search.reb         ← RAG 检索（grep/rg + 可选 LLM）
├── test-re-coder-rag-search.reb    ← 检索测试（21 项）
├── README.md
└── README.zh-CN.md                 ← 本文件
```

## 依赖

- **Rebol3**（Oldes 分支）运行时 — 从 [Oldes/Rebol3](https://github.com/Oldes/Rebol3/releases) 下载预编译二进制（3.21.0+）
- 环境变量 **`DEEPSEEK_API_KEY`**

## 使用
### 交互式 CLI

启动交互式编码会话（类似 Claude Code / Codex）：

```bash
# 交互模式
DEEPSEEK_API_KEY=*** ./re-coder

# 单次模式（传入提示词）
DEEPSEEK_API_KEY=*** ./re-coder "写一个 Python 爬虫"

# 自定义模型
DEEPSEEK_API_KEY=*** ./re-coder --model deepseek-chat "解释 async/await"
```

**CLI 命令：**

**会话命令：**

| 命令 | 说明 |
|------|------|
| `/bg` | 当前会话沉到后台，启动新前台 |
| `/bg /list` | 列出所有会话及状态 |
| `/bg <N>` | 召回第 N 号会话（双向交换） |
| `/bg /drop <N>` | 丢弃第 N 号会话 |
| `/fork` | 分叉当前会话（复制上下文） |
| `/new` | 开始全新会话 |

**通用命令：**

| 命令 | 说明 |
|------|------|
| `/help` | 显示帮助 |
| `/quit` `/exit` | 退出 |
| `/clear` | 清空对话历史 |
| `/history` | 显示消息计数 |
| `/model <名称>` | 切换模型 |
| `/workdir <目录>` | 设置工作目录 |
| `/stream` | 切换流式输出 ON/OFF |
| `/config` | 显示当前配置 |
| `/multi` | 切换多行输入模式 |

**多行输入：**
- 输入 `///`（三个斜杠）进入多行模式（一次性）
- 或使用 `/multi` 切换持久多行模式


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

**说明：** 当前仓库**不包含**「远端 RAG 服务配置 / CRUD」（类似 auto-coder 里的 `RAGConfigManager`），只提供本地 **`re-coder-rag-search.reb`** 关键词检索与 `rag-ask`。

### RAG 检索（`re-coder-rag-search.reb`）

检索层用 **`grep` / `rg`（有则优先）** 做**子串、不区分大小写**匹配，**不是**向量语义检索。传给 `rag-grep` / `rag-search` / `rag-ask` 的 **query 必须是代码或文档里会出现的片段**（函数名、注释、标题里的词等），整句英文问句往往 **0 命中**。

```bash
rebol3 test-re-coder-rag-search.reb
# => 21/21 tests passed
```

```rebol
do %./re-coder-rag-search.reb

; rag-grep / rag-search：参数为「检索词」、目录、扩展名块或 none、最多条数
probe rag-grep {quicksort} %. [%.py] 10
results: rag-search {rag-search} %. [%.reb %.md] 5
probe rag-build-context results

; rag-ask：先要能 grep 到内容，才会组上下文并调聊天 API
; 四个位置参数 + 可选 /model /url /key（默认 DeepSeek，密钥读 DEEPSEEK_API_KEY）
answer: rag-ask {rag-grep} %. [%.reb] 5
; answer: rag-ask {port} %. [%.reb %.md] 8 /model "deepseek-chat" /url "https://api.deepseek.com/v1" /key "sk-..."

; 不推荐：整句提问当检索词（在 .reb 里通常匹配不到）
; rag-ask "How does rag work?" %. [%.reb] 5

; 可改为关键词 + 带上说明文档扩展名，例如：
; rag-ask {rag-search} %. [%.reb %.md] 5
```

**`rag-ask` 参数**

| 参数 | 含义 |
|------|------|
| `query` | 给 grep/rg 用的模式（关键词），不是自然语言完整问句 |
| `dir-path` | 根目录，`%.` 为当前目录 |
| `extensions` | `none` 不限扩展名，或 `[%.reb %.md]` 等 |
| `max-results` | 最多采纳多少条命中 |
| `/model` | 模型名（默认 `deepseek-chat`） |
| `/url` | API 根 URL |
| `/key` | API Key（不设则用环境变量 `DEEPSEEK_API_KEY`） |

对外函数：`rag-grep`、`rag-search`、`rag-ask`、`rag-index-files`、`rag-build-context`、`rag-read-snippet`。

| 对照 auto-coder.rag | 本仓库 |
|---------------------|--------|
| 配置 CRUD | 暂未提供 |
| 检索 | `re-coder-rag-search.reb`（基于 grep/rg） |
