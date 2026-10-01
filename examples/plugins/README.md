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
```

两个 `--selftest` 都用**假核心**（往插件 stdin 写、读 stdout 断言），不启动桌面端、
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
