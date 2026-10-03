# 示例插件（examples/plugins）

本目录是**插件生态的参考实现**：纯标准库的 Python 插件 + 可直接粘贴的 `plugins.yaml`
片段。**系统性的口径（协议、四类站与 17 个点位、隔离语义、UI 槽位、`plugins.yaml`
全字段、调试手段）在 [`docs/plugin-development.md`](../../docs/plugin-development.md)**
——那份指南是唯一权威，本文件只负责"从哪个示例下手"，不重复它的内容。

## 先跑通，再读大示例

```powershell
# ① 最小示例：hello / ping / tools/list / 一个工具（不连真核心，30 秒看完）
python examples/plugins/minimal_plugin.py --selftest

# ② 完整示例：四站 + 插件布局 + 点位化新能力（同样不连真核心）
python examples/plugins/sample_plugin.py --selftest

# ③ 内置压缩插件：压缩编排 + 左栏面板 / 面板按钮回传（同样不连真核心）
python examples/plugins/compact_plugin.py --selftest
```

三个 `--selftest` 都用**假核心**（往插件 stdin 写、读 stdout 断言），不启动桌面端、
不需要参数、不产生副作用：先确认脚本本身没坏，再去配 `plugins.yaml`。

## 示例矩阵

| 文件 / 开关 | 演示什么 | 该看哪份文档 |
|---|---|---|
| `minimal_plugin.py`（无开关） | **最小插件骨架**：`hello` / `ping`（心跳）/ `tools/list` / `tools/call`，含并发读循环与 stderr 日志 | §1 一分钟上手、§2 RPC 清单、§6.3 工具申报 |
| `sample_plugin.py`（默认） | **四站全链路**：收集站申报 + 广播/事件订阅 + 执行站 `fs.read` + 中转站工具前/后改写；`ui/manifest` 声明 activity / panel / **card** 槽位并推卡片 | §3 站点体系、§5 中转站、§6 执行站、§7 UI、§8 收集站 |
| `--relay-llm <关键词>` | 中转站 `system.relay.llm.handle`：最后一条 user 消息含关键词时**流式接管**（`thinking` + 分片正文 + `done`），并处理下行 `station/cancel` | §5.4 接管 LLM |
| `--relay-llm-tool-call` | 流式接管里多推一段 `tool_call` 增量（会**真的**触发一次工具调用，所以单独开关） | §5.4 |
| `--relay-prompt` | 中转站 `system.relay.prompt.system`：在 `default` 后追加一行 | §5.3 各点位载荷 |
| `--llm-call <prompt>` | 执行站 `llm.call`：站点处**硬设** `response_format=json_object`，回包含 `json` / `text` / `model` / `usage` | §6.1 命令清单 |
| `--tool-call <tool> <json>` | 执行站 `tool.call`：执行任意工具，默认**绕开**工具中转/广播（`relay:false`） | §6.3 |
| `--rename-session` | 执行站 `session.rename`：把当前会话改成带时间戳的标题（前端即时刷新） | §6.1 |
| `--watch-tools` | 广播站 `system.broadcast.tool.pre` + `.tool.post`：统计"看到了 N 次工具调用"并推到面板 | §7.1 广播、§3.2 订点位 |
| `--self-station` | 插件**自建站点**并订阅自己（`station/register` → `station/subscribe`）：按 team/agent 分流时的"转发型订阅者"正解 | §3.2、§7 |
| `--threshold N` / `--no-relay` / `--no-panel` / `--no-fs-demo` / `--agent-id` / `--read-path` / `--slot-key` / `--card-interval` / `--stop-cascade` | 既有开关：轮次阈值与 `agent.stop`、是否订工具中转、是否声明面板、启动自检、命令目标 agent、卡片槽位键与刷新周期 | §6、§7 |
| `--selftest`（两个脚本都有） | 假核心自测：不连真核心验证协议形状（订阅回包、流式 `request_id`、`station/cancel`、三条新命令的请求构造…） | §10 调试与测试 |

## compact 插件：左栏「上下文压缩」面板

`compact_plugin.py` 除了做压缩，还会在**左栏**放一页可视面板（`ui/manifest` 声明一条
`activity` 槽位：左侧活动栏多一个图标，点开就是左栏整页）。看板长得是这样：

```
▌上下文压缩                                     ← 标题
点位订阅：已订阅 system.relay.context.compact · 经手 4 次（接管 3 / 未接管 1）·
用量记录 6 条 · 最近会话：agt_1/ses_1 · 最近原因：未接管：总结调用 llm.call 失败：端点 429
                                                                         ← 概览（一行）
已覆盖原文条数（核心报的水位线）  ▓▓▓▓▓▓░░░░  6 / 12                        ← 进度（最近一次）
┌──────────┬──────────┬──────────┬─────────┬──────────────────────────────────────────┐
│ 时间     │ 来源     │ 覆盖条数 │ 耗时    │ 降级 / 未接管原因                        │
├──────────┼──────────┼──────────┼─────────┼──────────────────────────────────────────┤
│ 16:40:02 │ relay    │ 42       │ 3.1 s   │ —                                        │
│ 16:39:10 │ plugin   │ —        │ 260 ms  │ 用量 demo-model · 输入 300 · 输出 30     │
│ 16:38:02 │ llm.call │ —        │ 700 ms  │ 用量 demo-model · 输入 800 · 输出 60（估算）│
│ 16:37:10 │ 未知     │ —        │ 120 ms  │ 未接管：总结模型没有回 json               │
│ 16:31:55 │ builtin  │ —        │ 1.8 s   │ 用量 demo-model · 输入 1.2k · 缓存 900 · 输出 120 │
└──────────┴──────────┴──────────┴─────────┴──────────────────────────────────────────┘
[ 立即压缩一次 ]  [ 刷新 ]                                                  ← 按钮组
```

- **来源列**（核心给的 `source` → 面板的口径）：
  - `relay` = 本插件**接管**的那几次（带覆盖条数、总耗时、降级/未接管原因）；
  - `builtin` = **核心内置 compact** 的那次总结（`usage.jsonl` 里 `source=compact`）；
  - `llm.call` = 执行站一次性调用（**压缩插件自己的总结调用走的就是它**）；
  - `plugin` = `llm.handle` 被插件**整体接管**的一跳；
  - `未知` = 这一行不是本插件经手的、也没能从用量里认出来（**不猜**）。
- **用量从哪来**：逐调用账本落在数据根下的会话目录里
  （`data/<agent>/<session>/usage.jsonl`），而插件**读不到数据根**（它的 `fs.read` 只在
  工作空间作用域内）——所以**核心在压缩请求的 payload 里捎来最近 50 行**（`recent_usage`）
  与账本路径（`usage_file`，排障用）。它是滚动窗口、每次请求都重发，插件按行去重后并入。
  没有这两个键（核心未接线 / 账本还不存在）时，面板就只有 `relay` 那几行，不会凭空造数。
  `--usage-jsonl <路径>` 是**离线回放**旁路（开发期把一份账本文件喂给面板看）。
- **「立即压缩一次」**：经执行站 `agent.compact` 调核心的手动压缩（与 REST `/compact`
  同一个入口；agent 正在生成时会被拒，原因会原样出现在"原因"列）。它会顺手把
  压缩来源 / 覆盖条数 / 降级原因一起带回来。
- 面板**只读**（不给插件额外权限）；视图是受限控件集 JSON，没有 webview；表格 5 列固定
  （用量写在最后一列，不扩列）。
- `--no-panel` = 不申报面板（只想后台跑压缩时用）；`--panel-records N` 改显示条数（默认 10）；
  `--agent-id X` 给"立即压缩一次"一个没有上下文时的兜底目标。
- 面板按钮回调的**线上形状**（判据在 `params.event` 上，别判 `method`）见
  [docs/plugin-development.md](../../docs/plugin-development.md) §7.2；压缩载荷里的
  `usage_file` / `recent_usage` 见同文件 §5.3。

## 配进核心（`plugins.yaml` 片段）

配置文件在 **`<数据根>/config/plugins.yaml`**（默认数据根见核心启动日志的「数据目录」）。
`command` 填**解释器**，脚本放 `args[0]`：

```yaml
enabled: true
plugins:
  - id: minimal                     # 工具在模型眼里叫 plugin__minimal__hello_tool
    name: 最小示例插件
    command: "D:/app/python/python.exe"          # 用 `where.exe python` 找绝对路径
    args: ["E:/programs/Tree/desktop/examples/plugins/minimal_plugin.py"]
    enabled: true
    scope: {}                       # **空 = 作用于所有 team**（不是"缺少 team"）

  - id: sample
    command: "D:/app/python/python.exe"
    args:                            # YAML 列表：一项一个 argv，别写成一行
      - "E:/programs/Tree/desktop/examples/plugins/sample_plugin.py"
      - "--threshold"
      - "200"
      - "--watch-tools"
      - "--relay-llm"
      - "示例插件接管"
    enabled: true
    scope: {}
```

开关也可以走**环境变量**（`SAMPLE_PLUGIN_TOOL_ROUND_LIMIT` / `SAMPLE_PLUGIN_RELAY_LLM` /
`SAMPLE_PLUGIN_LLM_CALL` / `SAMPLE_PLUGIN_TOOL_CALL` + `SAMPLE_PLUGIN_TOOL_CALL_ARGS` …），
写在 `plugins.yaml` 的 `env:` 下即可免改 `args`（命令行优先）。

也可以不改文件：**设置 → 插件开发 → 插件面板**里每个插件各有开关，改完热应用；
面板同时显示实例状态、订阅与每个点位的计数。

## 两个脚本共同的约定

- **stdout 只放协议报文**（一行一条 JSON-RPC）；**日志走 stderr** 或 `log` 通知；
- **每个入站请求另开线程**处理：处理中还要回 `ping`，单线程顺序处理会自锁；
- **心跳必回**：不回 `ping` 会被判 `degraded`，中转请求会立刻判"未响应"；
- 只用标准库，Python 3.8+，脚本可被绝对路径启动（不依赖 cwd、不做相对导入）。
