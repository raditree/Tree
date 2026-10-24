# Agent 系统插件化（构建计划）

> 状态：计划稿（2026-10-24）。
> 定位：[ui-pluginization.md](ui-pluginization.md) 的配套实施文档，负责把**核心里的 agent 能力整体剥离**为一个插件。
> 目标：核心不再认识 agent / 会话 / 提问 / 团队 / 模型；这些全部成为 `tree.agent` 插件的领域知识，**功能零丢失**。

---

## 0. 一句话

把 `packages/tree_core/lib/src/{agent,llm,team,tool,mcp}` 连同 23 条 REST 端点与 2 条上行指令，整体迁给二进制插件 `tree.agent`；核心只保留插件平台、日志、数据存储三类基础 API。实现方式不是"另写一个插件"，而是**把现有实现原样搬进共享包 `packages/tree_agent`，让插件二进制引用它**——用搬运替代重写，才能保住功能等价。

---

## 1. 现状盘点（要搬什么）

### 1.1 核心模块

| 模块 | 内容 | 去向 |
| --- | --- | --- |
| `agent/agent_engine.dart` | 生成循环、状态机、事件推进 | `tree_agent` |
| `agent/conversation_service.dart` | 会话读写与分页 | `tree_agent` |
| `agent/compaction_service.dart` | 上下文压缩 | `tree_agent` |
| `agent/question_broker.dart` / `question_store.dart` | 提问回路 | `tree_agent` |
| `agent/subagent_service.dart` + `store/subagent_*` | 子 agent | `tree_agent` |
| `agent/scripted_agent.dart` | 脚本化 agent | `tree_agent` |
| `agent/system_prompt_file.dart` / `workspace_prompt.dart` / `attachment_prompt.dart` | 提示词组装 | `tree_agent` |
| `agent/tool_result_repair.dart` | 工具结果修复 | `tree_agent` |
| `agent/private_workspace_io.dart` | 私有工作空间 | `tree_agent` |
| `llm/` | 模型调用、流式解析、供应商适配 | `tree_agent` |
| `team/` | 团队、成员、消息 | `tree_agent` |
| `tool/` | 工具注册、调用编排、运行登记 | `tree_agent` |
| `mcp/` | MCP 客户端（连接、列工具、调用） | `mcp` 插件 |
| `terminal/` | PTY | **保留核心**（宿主能力，见 §4.6） |
| `store/` | 文件存储、原子写、记录、用量日志 | 核心保留基础件；领域记录搬走 |

### 1.2 REST 端点（23 条）

见 [ui-pluginization.md §4.2](ui-pluginization.md#42-agent-面23-条--agent-插件批次-f)。**23 条全部移交，核心一条不留。**

### 1.3 WS 帧

| 方向 | 帧 | 去向 |
| --- | --- | --- |
| 下行 | `message`、`tool_start`、`tool_end`、`agent_status`、`agent_done`、`agent_error`、`question` | 改由插件以 `station_delivery` 的 topic 发出 |
| 上行 | `send_message`、`cancel`、`answer_question` | 前两条改为新增委派端点；`answer_question` 复用 `POST /api/questions/{qid}/answer` |

> **重要修正**：交接不是"23 条"。上行指令没有 REST 等价物，必须一并转成委派端点，因此 agent 插件实际承担 **25 条**：
> `POST /api/agents/{id}/messages`、`POST /api/agents/{id}/cancel` 为新增。
> 这两条属于插件自有路由，登记在 `delegated` 集合，核心不实现。

---

## 2. 目标架构

```
loader ──spawn──> tree_core.exe ──stdin/stdout──> tree.agent (binary plugin)
                      │                                │
                      │<── api/delegate (REST 请求) ────│
                      │<── station_delivery (topic) ────│
                      │─── workspace/register ─────────>│（登记工作空间定位）
                      │                                │
UI (kind: ui) ──WS──> tree_core ──转发──> 订阅者
```

| 项 | 约定 |
| --- | --- |
| 形态 | `kind: binary`，Dart AOT 单文件可执行体 |
| 代码来源 | 新包 `packages/tree_agent`，从 `tree_core` 平移；**不得反向依赖 `tree_core`** |
| 传输 | stdio 行式 JSON-RPC（与现有插件一致） |
| 对外 API | 25 条委派路由，由 `system.collect.api.routes` 申报 |
| 对外事件 | 注册广播站，topic 沿用原帧名 |
| 持久化 | 小状态走 `/api/store/tree.agent`；大对象（会话、流水）落在插件自有目录 |
| 日志 | 写 `/api/logs/plugin:tree.agent`（沿用核心日志 API） |
| 生命周期 | 常驻；`suspension: keep`（热重启不丢在途生成状态） |

---

## 3. 领域职责归属表（迁移后）

| 职责 | 归属 | 说明 |
| --- | --- | --- |
| agent 定义、模型池、团队关系 | `tree.agent` | 核心不再持有 `agents.yaml` 语义 |
| 生成循环、流式增量 | `tree.agent` | 每轮结束后批量推帧，避免逐 token stdio 抖动 |
| 工具编排与运行登记 | `tree.agent` | 工具**定义**仍由各插件经点位贡献 |
| 提问回路 | `tree.agent` | UI 答题走 `POST /api/questions/{qid}/answer` |
| 子 agent、团队消息 | `tree.agent` | 依赖 `tree.agent` 自身状态 |
| MCP 连接与工具 | `mcp` 插件 | 核心不再有 MCP 代码 |
| 命令执行 / PTY | 核心（宿主） | 见 §4.6 |
| 文件读写 | `files` / `spec` 插件 | 经 `workspace_dir` |
| 日志、键值存储、插件管理 | 核心 | 基础 API |

---

## 4. 关键设计决策

### 4.1 用"提取包"而不是"重写"

新建 `packages/tree_agent`，把 §1.1 的模块**原样移入**（只改 import 与依赖注入方式），然后：

- 核心删除这些目录；
- 插件二进制 `import 'package:tree_agent/...'` 并实现 stdio 循环与委派分发。

这样行为等价性由编译器与现有测试保证，而不是靠人工比对。

### 4.2 工作空间定位

核心不再认识"agent 的工作目录"。解决方案：插件启动时用 `workspace/register {workspace_id, dir}` 登记；核心维护 `workspace_id → dir` 的**纯字符串映射**，在委派信封里解析成 `workspace_dir`。核心不解释它是什么。

### 4.3 插件互通（站点命令）

先说结论：**插件 → 插件 的请求/应答通道今天就有**，是 `station/trigger`。我此前的说法有误，现按代码事实更正（[plugin_bus.dart `_handleStationTrigger`](file:///e:/programs/Tree/desktop/packages/tree_core/lib/src/plugin/plugin_bus.dart#L5424-L5465)）：

| 站点类型 | 当前实现（`_handleStationTrigger`） | 原语应然 |
| --- | --- | --- |
| 自建共享收集站（`shared: true`） | 可被插件触发 | 可 |
| 自建共享广播站 | 可被插件订阅 | 可 |
| 自建执行站 | **被拒** | **可——对接入点下令** |
| 内置站（`system.*`） | 默认被拒 | 可，但需显式声明"允许插件下令" |

术语：**内置** = 核心定义；**自建** = 插件定义。两者都可以是执行站 / 收集站 / 广播站。所以「乙插件自建执行站、甲插件向它下令」是合法形态；前文"插件不能定义执行站"的说法是错的。

**执行站原语（此处更正前文的语义漂移）**

> **执行站 = 「对接入点下令，接入点执行并处理」。** 发起方不限（核心、插件均可），归属不限（核心内置、插件自建）。

当前实现里的两条拒绝（[plugin_bus.dart `_handleStationTrigger`](file:///e:/programs/Tree/desktop/packages/tree_core/lib/src/plugin/plugin_bus.dart#L5452-L5465)）——「执行站不支持 trigger」「内置站触发时机由核心决定」——是**实现限制，不是原语语义**，应放开。放开前必须补齐的契约：

| 必须补齐 | 内容 |
| --- | --- |
| 请求契约 | 下发带 `request_id`；支持超时与取消；结果按 `request_id` 回包，不与广播混流 |
| scope 解析 | 触发时由**核心**解析四元组并随命令下发；插件不得自行推断 scope |
| 在途登记 | 插件发起的命令同样进入运行登记（可按接入点查询、可取消），否则无法展示与中止 |
| 递归防护 | 一次命令内不得再触发执行站（深度 ≤ 1），防 A→B→A 环 |
| 授权 | `allowed_plugins` 白名单 + 调用方 `plugin_id` 校验；内置执行站需显式声明"允许插件下令" |

由此带来两个简化：

- **不再需要 `system.collect.plugin.invoke` 网关**：agent 直接向能力插件的自建执行站下令即可；
- **不需要把 `api/delegate` 扩展给插件发起**：插件间走站点命令，不另造通道。

站点类型的选型依据变为**语义**，而不是发起方：

| 站点 | 语义 | 发起方 | 回包 |
| --- | --- | --- | --- |
| 执行站 | 下令执行（有副作用） | 核心 / 插件 | 单处理者应答 |
| 收集站 | 采集数据（无副作用） | 核心 / 插件 | 汇总多订阅者 |
| 广播站 | 事件推送 | 接入点主动 | 无 |

**工具申报仍为可选**：`tools/list` 只是给 LLM 的适配器，插件的能力契约是站点。未申报工具的插件照常上线；agent 需要调用某个插件时，对它定义的执行站下令即可。

### 4.4 流式帧的节流

现在核心直接写 WS；改由插件经 stdio 发 `station/trigger` 后，token 级增量会被行式 JSON 放大。约定：

- 增量按 **50 ms 或 32 个 token** 合并为一批（先到者触发）；
- 首 token 与结束帧立即发送，不参与合并；
- 压测门槛：单会话 ≥ 200 token/s 时 CPU 增量 < 5%。

### 4.5 数据：原地接管，不搬迁

`agents.yaml`、会话文件、团队与用量记录**保持原路径与格式**，插件直接读写，核心停止读写。

- 好处：零迁移、零格式漂移、可回退（只要回退时插件没写过新格式）。
- 约束：交接后**核心不得再触碰这些文件**；同一文件只允许一个写者。

### 4.6 PTY 归属

PTY 是宿主能力（进程、终端句柄），不属于 agent 领域，**保留核心**。agent 插件不做 PTY；命令执行走工具插件贡献的执行站。

### 4.7 密钥与模型配置

模型供应商密钥属于 agent 领域，随插件走。存储走 `/api/store/tree.agent`，**明文落盘但权限收紧**；如需加密，加密密钥由 loader 注入，核心不持有。

---

## 5. 功能对等清单（验收必须逐条打勾）

| # | 功能 | 现状 | 迁移后 |
| --- | --- | --- | --- |
| 1 | agent 增删改查 | 核心 | 插件 |
| 2 | 模型池与 `models-info` | 核心 | 插件 |
| 3 | 会话列表 / 创建 / 改名 / 删除 | 核心 | 插件 |
| 4 | 会话内容读取（分页） | 核心 | 插件 |
| 5 | 生成循环与终止 | 核心 | 插件 |
| 6 | 流式消息、工具卡片 | 核心直发 WS | 插件 topic |
| 7 | 工具定义汇总与调用 | 核心 | 插件（定义仍来自各插件） |
| 8 | 运行中工具登记 / 强制关闭 | 核心内存表 | 插件内存表 |
| 9 | 提问 / 答题 | 核心 | 插件 |
| 10 | 子 agent 与逐字稿 | 核心 | 插件 |
| 11 | 团队、成员、消息、成员日志 | 核心 | 插件 |
| 12 | 待办（todos） | 核心 | 插件 |
| 13 | 重置 / 压缩 | 核心 | 插件 |
| 14 | SSH 连接重建入口 | 核心 | 插件（调用 SSH 中转站） |
| 15 | 取消生成 | WS 上行 | `POST /api/agents/{id}/cancel` |
| 16 | 发送消息 | WS 上行 | `POST /api/agents/{id}/messages` |
| 17 | 用量记录 | 核心 | 插件（可继续用核心日志 API） |
| 18 | 系统提示词 / 工作空间提示组装 | 核心 | 插件 |

**任一条未打勾，批次 G 不成立。**

---

## 6. 交付批次

| 批次 | 内容 | 完成判据 |
| --- | --- | --- |
| A1 骨架 | `packages/tree_agent` 建立；插件二进制 + stdio 循环 + 健康检查 + 日志/存储接入 | 空插件能被启停；日志出现在 `/api/logs/plugin:tree.agent` |
| A2 只读面 | agents / models / sessions / conversations / todos / subagents / teammates / tools-running 的读路径 | 25 条中只读部分返回与核心逐字节一致（同一数据目录） |
| A3 写路径与生成 | 消息发送、取消、LLM 调用、工具编排、提问、reset/compact | 同一会话在插件侧跑出的记录与核心侧结构一致 |
| A4 帧迁移 | 广播站注册，topic 沿用原帧名；UI 订阅切换到新来源 | 双轨比对无差异后关闭核心直发 |
| A5 交接 | 核心删除 23 条路由 + 2 条上行指令 + `agent/llm/team/tool` 目录 | 核心 `grep` 不到领域模型；§5 全表打勾 |

A1–A4 期间核心与插件**双跑**（同一数据目录，核心只读、插件写），A5 一次性切换并删除。

---

## 7. 不变量

1. `tree_agent` **不得**依赖 `tree_core`，依赖方向单向。
2. 交接完成后，核心代码与协议中不得出现 agent / session / question / teammate / model 的领域类型与路由。
3. 数据**原地接管**：交接后同一文件只有一个写者，核心只读窗口期不超过一个批次。
4. 功能对等以 §5 清单为准，任一条缺失即视为交接失败。
5. 上行指令一律改为委派端点，**不新增**插件到 UI 的反向请求通道。
6. 插件互通一律走站点命令：**执行站与收集站均可跨插件发起**，归属不限（内置 / 自建）。命令必须带 `request_id`、可超时、可取消、进运行登记，并限制深度 ≤ 1 防环。不扩展 `api/delegate` 给插件发起。
7. 流式增量必须合并后推送，禁止逐 token 写 stdio。
8. 热重启（`suspension: keep`）期间在途生成不得丢帧，恢复后补发终态。
9. `tools/list` 是可选能力：缺失或为空**不得阻断插件上线**，也不得被视为插件不可用。

---

## 8. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| 生成循环多一跳，延迟上升 | 批量推帧（§4.4）；工具边界才同步等待 |
| 双跑期两写冲突 | 双跑期核心强制只读；文件锁由插件持有 |
| 插件崩溃导致所有会话不可用 | 看门狗 + 热重启；崩溃期间端点 503 并显示可读原因 |
| 密钥明文落盘 | 权限收紧 + 可选 loader 注入密钥；不写日志 |
| 交接后回退困难 | A5 单独成 commit；保留只读旧格式，回退核心可立即恢复接管 |

---

## 9. 开放问题（需拍板）

1. ~~UI 插件能否向执行站下令~~ **已定**：不能。UI 对功能的调用一律走 REST（插件需把能力注册成委派路由）；UI 只保留"订阅广播接收推送"与"发布自建广播站"两项站点操作。
2. **子 agent 的执行体**：仍由 `tree.agent` 内部调度，还是每个子 agent 起独立插件实例？
3. **密钥来源**：随插件明文存储，还是由 loader 每次启动注入？
4. **MCP**：确认整体迁往 `mcp` 插件（含客户端），核心零 MCP 代码。
5. **终端工具**：agent 侧的命令执行走工具插件执行站，还是允许直接 `Process.start`（更快但绕过权限与审计）。
