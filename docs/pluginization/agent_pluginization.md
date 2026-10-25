# Agent 系统插件化（构建计划）

> 状态：计划稿（2026-10-24）。
> 定位：[ui-pluginization.md](ui-pluginization.md) 的配套实施文档，负责把**核心里的 agent 能力整体剥离**为一个插件。
> 目标：核心不再认识 agent / 会话 / 提问 / 团队 / 模型；这些全部成为 `tree.agent` 插件的领域知识，**功能零丢失**。

---

## 0. 一句话

把 `packages/tree_core/lib/src/{agent,llm,team,tool,mcp}` 连同 23 条 REST 端点与 2 条上行指令，整体迁给二进制插件 `tree.agent`；核心只保留插件平台、日志、数据存储三类基础 API。实现方式不是"另写一个插件"，而是**把现有实现原样搬进插件仓内的共享包 `tree_agent_loop`，让插件二进制引用它**——用搬运替代重写，才能保住功能等价。

---

## 1. 现状盘点（要搬什么）

### 1.1 核心模块

| 模块 | 内容 | 去向 |
| --- | --- | --- |
| `agent/agent_engine.dart` | 生成循环、状态机、事件推进 | `tree_agent_loop` |
| `agent/conversation_service.dart` | 会话读写与分页 | `tree_agent_loop` |
| `agent/compaction_service.dart` | 上下文压缩 | `tree_agent_loop` |
| `agent/question_broker.dart` / `question_store.dart` | 提问回路 | `tree_agent_loop` |
| `agent/subagent_service.dart` + `store/subagent_*` | 子 agent | `tree_agent_loop` |
| `agent/scripted_agent.dart` | 脚本化 agent | `tree_agent_loop` |
| `agent/system_prompt_file.dart` / `workspace_prompt.dart` / `attachment_prompt.dart` | 提示词组装 | `tree_agent_loop` |
| `agent/tool_result_repair.dart` | 工具结果修复 | `tree_agent_loop` |
| `agent/private_workspace_io.dart` | 私有工作空间 | `tree_agent_loop` |
| `llm/` | 模型调用、流式解析、供应商适配 | `tree_agent_loop` |
| `team/` | 团队、成员、消息 | `tree_agent_loop` |
| `tool/` | 工具注册、调用编排、运行登记 | `tree_agent_loop` |
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
loader ──spawn──> tree_core.exe ──stdin/stdout──> tree.agent (runtime: headless)
                      │                                │
                      │<── api/delegate (REST 请求) ────│
                      │<── station_delivery (topic) ────│
                      │─── workspace/register ─────────>│（登记工作空间定位）
                      │                                │
UI (runtime: ui) ──WS──> tree_core ──转发──> 订阅者
```

| 项 | 约定 |
| --- | --- |
| 形态 | `runtime: headless`，`command` 指向 Dart AOT 单文件可执行体 |
| 代码来源 | 新包 `tree_agent_loop`（插件仓 `plugins/tree.agent/`），从 `tree_core` 平移；**不得反向依赖 `tree_core`** |
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

新建 `tree_agent_loop`（插件仓内），把 §1.1 的模块**原样移入**（只改 import 与依赖注入方式），然后：

- 核心删除这些目录；
- 插件二进制 `import 'package:tree_agent_loop/...'` 并实现 stdio 循环与委派分发。

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

先把两类「密钥」分开，避免继续含混：

| 名称 | 属于谁 | 存哪 / 谁注入 | 本期结论 |
| --- | --- | --- | --- |
| **模型供应商 API Key**（OpenAI/Anthropic 等） | agent 领域 | 插件自有配置 / `/api/store/tree.agent`；核心不持有 | 随 `tree.agent` 走，明文落盘 + 权限收紧（Windows ACL `icacls` 收紧到当前用户），不写日志 |
| **落盘加密主密钥**（若启用加密） | 宿主 | **核心**在启动插件时通过 `config.env` 注入（如 `TREE_AGENT_SECRET`），或取自 OS 凭据管理器 | 本期**不做**加密；未来只允许核心注入，**不是 loader** |
| `TREE_CORE_TOKEN` | 核心 | loader/核心注入 UI 插件，用于附着认证 | 与 agent 无关，不属于本迁移 |

> **「loader 注入」的说法作废**：loader 只负责拉起核心并完成 ready 握手，它不认识插件、也不该认识。能注入插件环境变量的只有核心的 `PluginConfig.env`。若未来需要主密钥，落点写死为「核心 → `config.env`」或「OS 凭据管理器」，不得把插件知识漏进 loader。

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
| A1 骨架 | `plugins/tree.agent/`（包 `tree_agent_loop`）建立；插件二进制 + stdio 循环 + 健康检查 + 日志/存储接入 | 空插件能被启停；日志出现在 `/api/logs/plugin:tree.agent` |
| A2 只读面 | agents / models / sessions / conversations / todos / subagents / teammates / tools-running 的读路径 | 25 条中只读部分返回与核心逐字节一致（同一数据目录） |
| A3 写路径与生成 | 消息发送、取消、LLM 调用、工具编排、提问、reset/compact | 同一会话在插件侧跑出的记录与核心侧结构一致 |
| A4 帧迁移 | 广播站注册，topic 沿用原帧名；UI 订阅切换到新来源 | 双轨比对无差异后关闭核心直发 |
| A5 交接 | 核心删除 23 条路由 + 2 条上行指令 + `agent/llm/team/tool` 目录 | 核心 `grep` 不到领域模型；§5 全表打勾 |

A1–A4 期间核心与插件**双跑**（同一数据目录，核心只读、插件写），A5 一次性切换并删除。

---

## 7. 不变量

1. `tree_agent_loop` **不得**依赖 `tree_core`，依赖方向单向。
2. 交接完成后，核心代码与协议中不得出现 agent / session / question / teammate / model 的领域类型与路由。
3. 数据**原地接管**：交接后同一文件只有一个写者，核心只读窗口期不超过一个批次。
4. 功能对等以 §5 清单为准，任一条缺失即视为交接失败。
5. 上行指令一律改为委派端点，**不新增**插件到 UI 的反向请求通道。
6. 插件互通一律走站点命令：**执行站与收集站均可跨插件发起**，归属不限（内置 / 自建）。命令必须带 `request_id`、可超时、可取消、进运行登记，并限制深度 ≤ 1 防环。不扩展 `api/delegate` 给插件发起。
7. 流式增量必须合并后推送，禁止逐 token 写 stdio。
8. 热重启（`suspension: keep`）期间在途生成不得丢帧，恢复后补发终态。
9. `tools/list` 是可选能力：缺失或为空**不得阻断插件上线**，也不得被视为插件不可用。
10. **核心不认识「子 agent 执行体」**：核心没有子 agent 进程、执行器或调度器概念；子 agent 的创建、排队、并发与回收全部在 `tree.agent` 进程内部完成，对外只暴露与会话一致的委派端点。核心只看到「一次委派请求」。
11. MCP 整体迁 `mcp` 插件；核心不留 MCP 客户端 / 服务端代码，也不认识 MCP 工具类型。
12. 命令执行一律走**工具插件贡献的执行站**；`tree.agent` 不直接 `Process.start`、不持有 PTY，避免绕过权限与审计。

---

## 8. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| 生成循环多一跳，延迟上升 | 批量推帧（§4.4）；工具边界才同步等待 |
| 双跑期两写冲突 | 双跑期核心强制只读；文件锁由插件持有 |
| 插件崩溃导致所有会话不可用 | 看门狗 + 热重启；崩溃期间端点 503 并显示可读原因 |
| 密钥明文落盘 | 权限收紧；如需加密，主密钥由**核心**注入 `config.env`（非 loader）；不写日志 |
| 交接后回退困难 | A5 单独成 commit；保留只读旧格式，回退核心可立即恢复接管 |

---

## 9. 开放问题（2026-10-25 已全部拍板）

1. ~~UI 插件能否向执行站下令~~ **已定**：不能。UI 对功能的调用一律走 REST（插件需把能力注册成委派路由）；UI 只保留"订阅广播接收推送"与"发布自建广播站"两项站点操作。
2. **子 agent 的执行体** **已定**：由 `tree.agent` **内部调度**；核心不认知子 agent 执行体（不变量 10）。平台当前也不支持「按声明逐 agent 起实例」，勘测见 §10.2。
3. **密钥来源** **已定**：模型供应商 API Key 随插件、明文落盘 + 权限收紧；落盘加密本期不做，「loader 注入」说法作废（§4.7）。
4. **MCP** **已定**：整体迁往 `mcp` 插件（含客户端），核心零 MCP 代码。
5. **终端工具** **已定**：命令执行走工具插件执行站；`tree.agent` 不直接 `Process.start`、不持有 PTY。

---

## 10. 现状与阻塞（2026-10-25 实测）

批次 G **尚未开始**：以下四项事实决定 A1 能否落地（第 1/3/4 项仍未解除）。

| # | 事实 | 影响 |
| --- | --- | --- |
| 1 | 插件仓挂载在 `plugins/`（远端仓库名 `tree-plugins`），但其中**没有** `tree.agent/` 目录；发布索引 `plugins/release/plugin-index.json` 也没有该条目 | A1「插件二进制 + stdio 循环」需先在插件仓新建目录与包 |
| 2 | ~~`packages/tree_agent` 重名~~ **已规避**：新包定名 `tree_agent_loop`（放 `plugins/tree.agent/`）；现有 `packages/tree_agent` 是目标机 Linux 执行体，不改名、不复用 | 无（命名冲突消解） |
| 3 | 领域代码规模约 20k 行：`agent` 5345 / `llm` 5030 / `team` 2683 / `tool` 5139 / `mcp` 1572；且对核心基础件有硬依赖——`agent → store 12 / util 5 / tool 5 / settings 4 / plugin 2`、`tool → team 7 / plugin 5 / spec 4 / store 4`、`llm → util 6 / settings 5 / agent 5 / store 5` | 「只改 import 与注入」实际需要先把 `store / settings / util / plugin 客户端` 一并下放或抽共享包，否则不变量 1（不得依赖 `tree_core`）无法满足 |
| 4 | 核心测试 176 个文件，其中大量用例直接 import `src/agent|llm|team|tool`；`core_server.dart` 的 `_registerRoutes` 实际注册约 **33 条**领域路由（agents CRUD、models、sessions、conversations、subagents、teammates、specs、reset/compact/ssh reconnect、questions 等） | §1.2 / §6 的「23 / 25 条」口径已漂移；A2 的「逐字节一致」基线需先重新点数并冻结 |

结论：G 的正确起点不是搬代码，而是先拍板下面两件事，然后按 A1（最小端点 `GET /api/agents` 走通 stdio / 委派 / 一致性）验证脚手架。

### 已拍板（2026-10-25）

| # | 结论 |
| --- | --- |
| 1 | 插件源码放 `E:\programs\Tree\desktop\plugins`；该目录的远端仓库名即 **`tree-plugins`**；新建 `plugins/tree.agent/` |
| 2 | 新包定名 **`tree_agent_loop`**；现有 `packages/tree_agent` 不改名、不复用 |
| 3 | 子 agent 由 `tree.agent` **内部调度**；核心不认知子 agent 执行体（不变量 10） |
| 4 | MCP 整体迁 `mcp` 插件（不变量 11） |
| 5 | 命令执行走工具插件执行站（不变量 12） |
| 6 | 领域测试（`agent/llm/team/tool/mcp` 相关用例）**随代码迁到插件仓** `tree_agent_loop`；核心只保留插件平台 / 协议 / 服务端测试 |
| 7 | 模型供应商 Key 随插件明文落盘 + 权限收紧；落盘加密本期不做；「loader 注入」作废（§4.7） |

### 仍需拍板

8. **基础件供给方式**：`store / settings / util / plugin 客户端` 是用共享包下放，还是由核心暴露为插件 API（`/api/store`、`/api/logs` 已具备，其余需补）？具体依赖清单见 §10.1。
9. **路由点数基线**：以 `_registerRoutes` 的 33 条为准重写 §1.2/§5/§6，还是趁机裁剪到真正的 25 条功能面？

---

## 10.1 核心基础件依赖清单（供拍板 #8）

> 口径：领域目录（`agent/llm/team/tool/mcp`）**直接 import** 的核心文件；`←` 后是使用方。
> 这张表就是「要么下放到共享包、要么变成插件 API」的全部候选。

### 正向依赖（插件需要的东西）

| 核心文件 | 使用方 | 用途 | 下放难度 |
| --- | --- | --- | --- |
| `store/tree_store.dart` | agent 4 / team 2 / tool 1 | 数据访问主入口（agent/session/message/team 读写） | 高：与 `records` 绑定 |
| `store/records.dart` | agent 1 / team 2 / llm 1 | **领域记录模型**（CoreAgent/Session/Message/Team） | 高：本就是领域类型，应整体迁走 |
| `store/atomic_file.dart` | agent 1 / llm 1 / team 1 / tool 1 / mcp 1 | 原子写 | 低：通用件 |
| `store/tree_paths.dart` | agent 1 / team 1 / tool 1 | 路径布局 | 低：通用件 |
| `store/write_queue.dart` | agent 1 | 串行写 | 低：通用件 |
| `store/usage_log.dart` | agent 1 / llm 3 | 用量记录 | 中：可改走日志 API |
| `store/subagent_registry.dart` | agent 2 / tool 1 | 子 agent 登记 | 低：领域件，随迁 |
| `store/yaml_codec.dart` | mcp 1 | YAML 编解码 | 低：通用件 |
| `util/ids.dart` | agent 3 / team 1 / llm 1 | id 生成 | 低 |
| `util/tokens.dart` | agent 2 / llm 5 | token 估算 | 低 |
| `util/liveness.dart` | team 1 / mcp 3 | 心跳判活 | 低 |
| `settings/core_settings.dart` | agent 3 / llm 4 / team 1 | 全局设置（模型、并发、压缩阈值） | 中：领域设置项要拆 |
| `settings/ssh_config.dart` | agent 1 / team 1 / tool 1 | SSH 配置 | 中：跨域 |
| `plugin/agent_events.dart` | agent 2 | 事件形状 | 低：本质是协议，宜移 `tree_protocol` |
| `plugin/plugin_bus.dart` | tool 2 | 向插件执行站下命令 | 高：插件客户端要抽 |
| `plugin/plugin_host.dart` / `station_runtime.dart` / `station_scope.dart` | tool 1 | 插件工具适配 | 高 |
| `ws/ws_hub.dart` | agent 1 | 事件推送 | 低：迁移后改 topic，直接删除 |
| `spec/spec_service.dart` / `spec/builtin_specs.dart` | tool 4 | spec 工具 | 中：spec 插件化后改执行站 |

### 反向依赖（核心必须先切断，否则删不掉领域目录）

| 核心文件 | import 的领域模块 |
| --- | --- |
| `server/core_server.dart` | agent 8 / llm 2 / mcp 2 / team 5 / tool 6 |
| `plugin/plugin_bus.dart` | `agent_engine`、`compaction_service`、`llm_types`、`openai_codec`、`tool_runner` |
| `plugin/execute_mounts.dart` | `tool/builtin_tools`、`tool/terminal_hooks`、`tool/tool_runner` |
| `spec/spec_service.dart` | `tool/tool_runner` |
| `files/file_service.dart` | `team/team_workspace` |
| `terminal/terminal_service.dart` | `team/team_workspace` |

> 关键结论：`store/records.dart`、`store/tree_store.dart`、`settings/core_settings.dart` 是三条主干；它们不迁，`tree_agent_loop` 就不可能不依赖 `tree_core`。反向依赖里 `plugin_bus` 与 `execute_mounts` 是硬点（核心插件平台反过来 import 领域代码），必须先改成协议/站点边界。

---

## 10.2 勘测：插件平台是否支持「按声明逐 agent 起实例」

**结论：当前不支持，声明不会产生多实例。**

| 证据 | 事实 |
| --- | --- |
| `PluginConfig.granularity` | 仅解析 / 校验 / 序列化（`plugin_host.dart`），全仓没有分支按它创建进程 |
| `PluginBus._hosts` | `Map<String, PluginHost>`，**按 plugin id 唯一**；一个配置只有一个进程 |
| `StationScope`（team/agent/session） | 只用于订阅过滤与消息投递，不参与进程生命周期 |
| `station_runtime.dart` | 默认 scope 仅用于订阅，不触发实例化 |

若未来要「逐 agent 单独起实例」，平台需新增：实例键 `(plugin_id, agent_id)`、按需 spawn 与回收、每实例独立看门狗/站点命名空间、委派按信封 `agent_id` 路由、并发上限。**本期不做**，登记为遗留项 L-20。

> 全部未闭环项（含 G-1~G-7、U-3/U-4、C-11、手工回归、文档缺口）已统一登记在
> [ui-pluginization_acceptance.md §12 遗留项台账](ui-pluginization_acceptance.md#12-遗留项台账2026-10-25-落档)。

在以上决策落定前，核心路由、领域帧与 `agent/llm/team/tool` 目录**保持原样**（不变量 2/3 要求插件验收后才可删除；提前删会直接破坏现有功能）。
