# Agent 系统插件化（构建计划）

> 状态：计划稿（2026-10-24）。
> 定位：[ui-pluginization.md](ui-pluginization.md) 的配套实施文档，负责把**核心里的 agent 能力整体剥离**为一个插件。
> 目标：核心不再认识 agent / 会话 / 提问 / 团队 / 模型；这些全部成为 `tree.agent` 插件的领域知识，**功能零丢失**。

---

## 0. 一句话

把 `packages/tree_core/lib/src/{agent,llm,team,tool,mcp}` 连同 34 条存量 REST 端点与 2 条上行指令（合计 36 条）整体迁给二进制插件 `tree.agent`；核心只保留插件平台、日志、数据存储三类基础 API。实现方式不是"另写一个插件"，而是**把现有实现原样搬进插件仓内的共享包 `tree_agent_loop`，让插件二进制引用它**——用搬运替代重写，才能保住功能等价。

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
| `terminal/` | PTY | **迁出核心** → `local_executor` 插件（见 §4.6） |
| `files/file_service.dart` | 本地/远端文件读写 | **迁出核心** → `local_executor` / `ssh_executor`（见 §4.6） |
| `store/` | 文件存储、原子写、记录、用量日志 | 领域记录（`records` / `tree_store` / `subagent_registry`）随迁；通用小件插件自备；核心只留通用 KV 与日志 |

### 1.2 REST 端点（36 条，2026-10-25 实测冻结）

口径来源：`core_server.dart` 的 `_registerRoutes` 逐条点数，非旧文档推算。

| 组 | 条数 | 端点（方法 + 路径） |
| --- | --- | --- |
| agent 定义 | 7 | `GET/POST /api/agents`、`GET/PATCH/DELETE /api/agents/{id}`、`GET .../models-info`、`GET .../todos` |
| 模型池 | 4 | `GET/POST /api/models`、`PATCH/DELETE /api/models/{id}` |
| 团队 | 4 | `GET .../teammates`、`PATCH /api/agents/{leader}/teammate/{member}`、`GET .../teammate/{id}/log`、`POST .../teammate/{id}/message` |
| 子 agent | 2 | `GET .../subagents`、`GET .../subagents/{sid}/transcript` |
| 会话 / 历史 | 8 | `GET/DELETE /api/conversations/{id}`、`GET/POST .../sessions`、`GET/PATCH/DELETE .../sessions/{sid}`、`POST .../sessions/{sid}/specs` |
| 维护 | 3 | `POST .../reset`、`POST .../compact`、`POST .../ssh/reconnect` |
| 提问 | 2 | `GET /api/questions`、`POST /api/questions/{qid}/answer` |
| 运行监督 | 2 | `GET /api/tools/running`、`POST /api/tools/running/{handle}/close` |
| token 节奏（§4.8 判为领域） | 2 | `GET/POST /api/settings/token-rate` |
| **存量小计** | **34** | |
| 上行改委派（新增） | 2 | `POST /api/agents/{id}/messages`、`POST /api/agents/{id}/cancel` |
| **合计移交** | **36** | 核心一条不留 |

> **旧口径作废**：`23 条存量 / 25 条移交` 是错的；按组逐条数出来是 `34 + 2 = 36`。
> 详见 [ui-pluginization.md](ui-pluginization.md) §4.2。
>
> **G-1 逐条契约（2026-10-25 建立）**：36 条的请求字段、成功/失败回包、副作用与已知缺口见 [agent_api_contract.md](agent_api_contract.md)。迁移时以那张表为功能等价基线；表内 §3 的 C-01~C-12 是必须先拍板的契约缺口。

其余归属（同一次实测）：`spec` 2、`mcp` 3、`files` 13、`git` 3、核心永久面 36，合计 93 条契约。

### 1.3 WS 帧

| 方向 | 帧 | 去向 |
| --- | --- | --- |
| 下行 | `message`、`tool_start`、`tool_end`、`agent_status`、`agent_done`、`agent_error`、`question` | 改由插件以 `station_delivery` 的 topic 发出 |
| 上行 | `send_message`、`cancel`、`answer_question` | 前两条改为新增委派端点；`answer_question` 复用 `POST /api/questions/{qid}/answer` |

> **重要修正**：上行指令没有 REST 等价物，必须一并转成委派端点，因此 agent 插件实际承担 **36 条**（34 存量 + 2 新增）：
> `POST /api/agents/{id}/messages`、`POST /api/agents/{id}/cancel` 为新增。
> 这两条属于插件自有路由，由插件经 `system.collect.api.routes` 申报，核心不实现。

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
| 对外 API | 36 条委派路由，由 `system.collect.api.routes` 申报 |
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
| 本地命令执行 / PTY | `local_executor` 插件 | 与 `ssh_executor` 同一套执行站接口（§4.6） |
| 本地文件读写 | `local_executor`（或 `files` 插件） | 经 workspace 租约，核心不碰文件 |
| 远端命令 / 文件 | `ssh_executor` 插件 | 现有通道 |
| 日志、通用键值存储、插件管理、租约登记 | 核心 | 基础 API，无领域语义 |

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

本次迁移中，`local_executor` 与 `ssh_executor` 的 `exec.command` / `file.*` / `terminal.*` **全部是插件自建**，核心不内置这些站，只负责把命令路由给对应插件。

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

### 4.6 执行与文件：全部下沉能力插件，核心零 PTY / 零文件操作

**修正**：此前「PTY 保留核心」的说法作废。核心定位是调度微内核，PTY 与本地文件修改都是「具体工作」，不是调度。

归属改为镜像现有 `ssh_executor` 的模式：

| 能力 | 归属 | 说明 |
| --- | --- | --- |
| 本地进程 / 命令执行 | `local_executor` 插件 | `Process.start` 在插件内，核心不拉起子进程 |
| 本地 PTY（交互终端） | `local_executor` 插件 | 核心不留 `terminal/`；PTY 句柄归插件 |
| 本地文件读 / 写 / 列目录 / 移动 / 上传 | `local_executor`（或拆出 `files` 插件） | 路径守卫、原子写、锁都在插件内 |
| 远端命令 / 远端文件 | `ssh_executor` 插件 | 已有形态，接口与本地执行器对齐 |

调用关系：

```
tree.agent ──执行站命令(lease_id + relpath/argv)──> local_executor ──> OS / PTY
     │                                                    │
     └──执行站命令(同一接口)──> ssh_executor ──> 远端主机 ──┘
UI（文件浏览 / 终端）──REST 委派──> core ──> 对应执行器插件
```

- **执行站归属**：`exec.command` / `file.*` / `terminal.*` 这些执行站**由 `local_executor` / `ssh_executor` 在插件内部自行定义**（`plugin.json` 声明 + 站点注册），**不是核心内置**。核心只做路由、身份透传与响应校验，不实现任何执行语义。
- **本地 vs 远端由 `tree.agent` 决定**：它拥有 agent → workspace 的领域映射；核心不判断。
- **路径安全**：执行器只接受「租约内的相对路径」。`workspace/register {lease_id, dir}` 在核心登记的是**纯字符串映射**（`lease_id → dir`），无 agent/team 语义；执行器校验「解析后的绝对路径仍在租约根内」。
- **PTY 流**：核心只做通用字节流中继（`stream session: open/input/resize/close` + 有序字节帧），不认识终端语义；UI 通过 REST 建流、再订阅插件 topic。原「PTY 是 WebSocket 唯一例外」的规则改为「核心提供与协议无关的流中继」。
- **崩溃影响**：执行器崩溃会带走其 PTY 会话与在途命令；由看门狗重启插件，UI 收到 `closed` 并提示。这是把能力下沉必须接受的代价。

### 4.6.1 核心职责白名单（反向约束）

核心**只做**这些事，多一件都算定位漂移：

| 允许 | 不允许 |
| --- | --- |
| 插件生命周期 / 看门狗 / 站点总线 | 任何领域模型（agent / session / team / model / question） |
| WS / REST 传输与委派路由 | PTY、终端会话、子进程（除拉起插件外） |
| 通用键值存储 `/api/store/*`、日志 `/api/logs/*` | 业务数据读写（agents.yaml、会话、用量账本） |
| 通用 workspace 租约登记（`lease_id → dir`，纯字符串） | 文件读 / 写 / 列目录 / 路径守卫 |
| 认证（核心令牌、UI 附着） | 跨 team / 跨 agent 的领域授权 |

> 关于「核心只 store 业务数据」：准确说是**只 store 通用数据**——键值、日志、租约。业务记录（agent/会话/团队/模型）在迁移后归插件自有目录，核心连格式都不认识。
>
> 注意：`exec.command` / `file.*` / `terminal.*` **不在**核心站点表里——它们由 `local_executor` / `ssh_executor` 插件自建并注册，核心只在总线里转发。

### 4.7 密钥与模型配置

先把两类「密钥」分开，避免继续含混：

| 名称 | 属于谁 | 存哪 / 谁注入 | 本期结论 |
| --- | --- | --- | --- |
| **模型供应商 API Key**（OpenAI/Anthropic 等） | agent 领域 | 插件自有配置 / `/api/store/tree.agent`；核心不持有 | 随 `tree.agent` 走，明文落盘 + 权限收紧（Windows ACL `icacls` 收紧到当前用户），不写日志 |
| **落盘加密主密钥**（若启用加密） | 宿主 | **核心**在启动插件时通过 `config.env` 注入（如 `TREE_AGENT_SECRET`），或取自 OS 凭据管理器 | 本期**不做**加密；未来只允许核心注入，**不是 loader** |
| `TREE_CORE_TOKEN` | 核心 | loader/核心注入 UI 插件，用于附着认证 | 与 agent 无关，不属于本迁移 |

> **「loader 注入」的说法作废**：loader 只负责拉起核心并完成 ready 握手，它不认识插件、也不该认识。能注入插件环境变量的只有核心的 `PluginConfig.env`。若未来需要主密钥，落点写死为「核心 → `config.env`」或「OS 凭据管理器」，不得把插件知识漏进 loader。

### 4.8 `core_settings.dart` 必须先拆分

现状把**平台开关**和**单一 agent 领域的模型配置**混在一个类里，这与「调度核心」定位冲突。拆分口径：

| 现状字段 / 能力 | 归属 | 去向 |
| --- | --- | --- |
| `frame_rate`（UI 推送合并帧率） | 平台 | 留核心 |
| `heartbeat_interval` / `missed_heartbeat_limit` / `livenessNotice` | 平台（插件判活） | 留核心 |
| `data_collection_enabled` | 平台（遥测开关） | 留核心 |
| `extra`（未知键透传） | 平台 | 留核心（仅透传，不解释） |
| `models` / `CoreModelConfig`（含 `api_key`、`base_url`、thinking、vision、effort、`max_seqlen`、`max_output_tokens`、`token_scale`、`longest_session_tokens`） | **agent 领域** | **随 `tree_agent_loop` 迁走**；落 `models/<id>.yaml` 原路径 |
| `token_acquisition_rate`（LLM 逐 token 取用节奏） | **agent 领域** | 随迁 |
| `fallbackMaxSeqlen` | **agent 领域** | 随迁 |
| `/api/settings` 的领域键 | 领域 | 由 `tree.agent` 的委派路由提供；核心 `/api/settings` 只回平台键 |

拆分完成前不得开始 A1 的数据接管；否则插件会继续被迫感知核心设置模型。

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
| A2 只读面 | agents / models / sessions / conversations / todos / subagents / teammates / tools-running 的读路径 | 36 条中只读部分返回与核心逐字节一致（同一数据目录） |
| A3 写路径与生成 | 消息发送、取消、LLM 调用、工具编排、提问、reset/compact | 同一会话在插件侧跑出的记录与核心侧结构一致 |
| A4 帧迁移 | 广播站注册，topic 沿用原帧名；UI 订阅切换到新来源 | 双轨比对无差异后关闭核心直发 |
| A5 交接 | 核心删除 34 条路由 + 2 条上行指令 + `agent/llm/team/tool` 目录 | 核心 `grep` 不到领域模型；§5 全表打勾 |

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
13. **插件不得 import 任何核心包**：只允许 pub.dev 依赖与插件仓自带的 `_kit`；复用核心能力走核心内置站（仅平台通用能力）或 UI 的 REST 端点。`local_executor` / `ssh_executor` 的 `exec/file/terminal` 执行站属**插件自建**，不是核心内置。
14. **核心的站点 scope 不得含领域字段**（`team_id/agent_id/session_id/mode_key`）；领域归属与跨域授权由领域插件自己负责，核心只认证调用方与 workspace 租约。
15. **核心设置只保留平台级**；模型池、token 节奏等 agent 领域配置随 `tree.agent` 迁走。
16. **核心不持有 PTY、终端会话与文件操作**：本地执行 / 文件修改归 `local_executor`，远端归 `ssh_executor`；核心只保留与协议无关的流中继与租约登记。

---

## 8. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| 生成循环多一跳，延迟上升 | 批量推帧（§4.4）；工具边界才同步等待 |
| 双跑期两写冲突 | 双跑期核心强制只读；文件锁由插件持有 |
| 插件崩溃导致所有会话不可用 | 看门狗 + 热重启；崩溃期间端点 503 并显示可读原因 |
| 执行器插件崩溃导致 PTY / 文件操作中断 | 看门狗重启；UI 收 `closed` 并提示；文件写操作保持幂等，PTY 会话需重开 |
| 密钥明文落盘 | 权限收紧；如需加密，主密钥由**核心**注入 `config.env`（非 loader）；不写日志 |
| 交接后回退困难 | A5 单独成 commit；保留只读旧格式，回退核心可立即恢复接管 |

---

## 9. 开放问题（2026-10-25 已全部拍板）

1. ~~UI 插件能否向执行站下令~~ **已定**：不能。UI 对功能的调用一律走 REST（插件需把能力注册成委派路由）；UI 只保留"订阅广播接收推送"与"发布自建广播站"两项站点操作。
2. **子 agent 的执行体** **已定**：由 `tree.agent` **内部调度**；核心不认知子 agent 执行体（不变量 10）。平台当前也不支持「按声明逐 agent 起实例」，勘测见 §10.2。
3. **密钥来源** **已定**：模型供应商 API Key 随插件、明文落盘 + 权限收紧；落盘加密本期不做，「loader 注入」说法作废（§4.7）。
4. **MCP** **已定**：整体迁往 `mcp` 插件（含客户端），核心零 MCP 代码。
5. **终端工具** **已定**：命令执行走向 `local_executor` / `ssh_executor` **插件自建**的执行站；`tree.agent` 不直接 `Process.start`、不持有 PTY。

---

## 10. 现状与阻塞（2026-10-25 实测）

批次 G **尚未开始**：以下事实决定 A1 能否落地（第 1/3/4 项仍未解除；第 5 项已于 2026-10-25 解除）。

| # | 事实 | 影响 |
| --- | --- | --- |
| 1 | 插件仓挂载在 `plugins/`（远端仓库名 `tree-plugins`），但其中**没有** `tree.agent/` 目录；发布索引 `plugins/release/plugin-index.json` 也没有该条目 | A1「插件二进制 + stdio 循环」需先在插件仓新建目录与包 |
| 2 | ~~`packages/tree_agent` 重名~~ **已规避**：新包定名 `tree_agent_loop`（放 `plugins/tree.agent/`）；现有 `packages/tree_agent` 是目标机 Linux 执行体，不改名、不复用 | 无（命名冲突消解） |
| 3 | 领域代码规模约 20k 行：`agent` 5345 / `llm` 5030 / `team` 2683 / `tool` 5139 / `mcp` 1572；且对核心基础件有硬依赖——`agent → store 12 / util 5 / tool 5 / settings 4 / plugin 2`、`tool → team 7 / plugin 5 / spec 4 / store 4`、`llm → util 6 / settings 5 / agent 5 / store 5` | 插件不得 import 核心包，故必须：领域层与通用小件**复制随迁**、设置先拆分、插件互通改**执行器插件的自建执行站**（§10.1） |
| 4 | 核心测试 176 个文件，其中大量用例直接 import `src/agent|llm|team|tool`；`_registerRoutes` 已逐条点清：`tree.agent` 34 条 + spec 2 + mcp 3 + files 13 + git 3 + 核心永久面 36 = 91 条已注册（+2 条新增 = 93） | 旧「23 / 25 条」口径作废；A2 基线按 36 条冻结（§1.2） |
| 5 | ~~委派白名单 `ApiPaths.delegated` 是**静态 18 条路径**~~ **已解除（2026-10-25，L-28）**：`DelegatedRouter` 改为命名空间规则 + 保留前缀 + 与核心已实现路由同键拒收；核心删实现后同一申报自动生效 | 新插件加路由不再需要改核心（证据：`ui-pluginization.md` §4.5、`http_router.dart`、`delegated_rest_test.dart`） |

> 结论：G 的正确起点不是搬代码，而是先完成五项前置（`core_settings` 拆分、scope 去领域化立项、`local_executor` 执行站就位、~~委派白名单去静态化~~ **已完成**、按 36 条建 G-1 对照表），再按 A1（最小端点 `GET /api/agents` 走通 stdio / 委派 / 一致性）验证脚手架。剩余四项：L-22 / L-23 / L-24~L-26 / L-19。

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
| 8 | **插件不得 import 任何核心包**；复用只能走核心平台内置站（仅通用能力）、**执行器插件的自建执行站**，或 UI 的 REST 委派端点；通用小件由插件自备（§10.1） |
| 9 | `core_settings.dart` 先按「平台级 / 领域级」拆分，拆分前不得开始 A1 数据接管（§4.8） |
| 10 | 插件 scope 必须去领域化：`team_id / agent_id / session_id / mode_key` 逐步移除，授权搬到「执行器插件 + workspace 租约」（§10.3） |
| 11 | **执行与文件全部下沉**：本地命令 / PTY / 文件修改归 `local_executor`，远端归 `ssh_executor`；核心零 PTY、零文件操作，只留通用流中继与租约登记（§4.6） |
| 12 | **路由基线按实测冻结**：`tree.agent` = **36 条**（34 存量 + 2 新增），核心永久面 36 条；「裁剪到 25 条」的口径作废（那份 25 是数错的）。是否裁剪功能另立遗留项 L-27，不与 G 混做 |

---

## 10.1 核心基础件依赖清单（2026-10-25 修正）

> **已拍板：插件不得 import 任何核心包**（`tree_core`、`tree_protocol` 及主仓内其它包）。
> 理由：插件仓可能被其他开发者单独 checkout，任何 `path:` / 相对路径依赖都会断。
>
> 插件复用核心能力只有两条路：
> 1. **核心主动提供的平台内置站**（仅限核心拥有的通用能力：通用键值存储、日志、租约解析）；
> 2. UI 插件走 **REST 委派端点**。
>
> 注意区分：`exec.command` / `file.*` / `terminal.*` 由 `local_executor` / `ssh_executor` **插件内部定义并注册**，不是核心内置站；核心只负责把命令路由到对应执行器。
>
> 因此本节不再有「共享包下放」选项，只有 **随迁（插件自备）**、**调用核心内置站**、或 **向其它插件的自建执行站下令**。
> `plugins/_kit` 属于插件仓自身，随插件仓分发，不算核心包。

### 正向依赖与处理

| 核心文件 | 使用方 | 用途 | 处理方式 |
| --- | --- | --- | --- |
| `store/tree_store.dart` | agent 4 / team 2 / tool 1 | 数据访问主入口 | **随迁**（领域数据层） |
| `store/records.dart` | agent 1 / team 2 / llm 1 | 领域记录模型 | **随迁**（本就是领域类型） |
| `store/subagent_registry.dart` | agent 2 / tool 1 | 子 agent 登记 | **随迁** |
| `store/atomic_file.dart` | agent 1 / llm 1 / team 1 / tool 1 / mcp 1 | 原子写 | 插件自备（通用小件，复制进 `tree_agent_loop`） |
| `store/tree_paths.dart` | agent 1 / team 1 / tool 1 | 路径布局 | 插件自备（改为接收 `data_dir`） |
| `store/write_queue.dart` | agent 1 | 串行写 | 插件自备 |
| `store/yaml_codec.dart` | mcp 1 | YAML 编解码 | 插件自备（或用 pub 依赖 `yaml`） |
| `store/usage_log.dart` | agent 1 / llm 3 | 用量记录 | 走核心 `/api/logs`，或插件自备账本 |
| `util/ids.dart` | agent 3 / team 1 / llm 1 | id 生成 | 插件自备 |
| `util/tokens.dart` | agent 2 / llm 5 | token 估算 | 插件自备 |
| `util/liveness.dart` | team 1 / mcp 3 | 心跳判活 | 插件自备（MCP 则迁 `mcp` 插件） |
| `settings/core_settings.dart` | agent 3 / llm 4 / team 1 | 全局设置 | **先拆分**：平台级留核心；模型池 / token 节奏随迁（见 §4.8） |
| `settings/ssh_config.dart` | agent 1 / team 1 / tool 1 | SSH 配置 | **随迁**（领域配置）；实际执行走 `ssh_executor` 插件 |
| `plugin/agent_events.dart` | agent 2 | 事件形状 | **随迁**（topic 载荷由插件自定义） |
| `plugin/plugin_bus.dart` | tool 2 | 向插件执行站下命令 | **不提供**：改为向 `local_executor` / `ssh_executor` 等插件**自建**执行站下令 |
| `plugin/plugin_host.dart` / `station_runtime.dart` / `station_scope.dart` | tool 1 | 插件工具适配 | **不提供**：站点命令是唯一互通通道 |
| `ws/ws_hub.dart` | agent 1 | 事件推送 | **删除**：改广播站 topic |
| `spec/spec_service.dart` / `spec/builtin_specs.dart` | tool 4 | spec 工具 | 走 `spec` 插件执行站 |

### 反向依赖（核心必须先切断，否则删不掉领域目录）

| 核心文件 | import 的领域模块 |
| --- | --- |
| `server/core_server.dart` | agent 8 / llm 2 / mcp 2 / team 5 / tool 6 |
| `plugin/plugin_bus.dart` | `agent_engine`、`compaction_service`、`llm_types`、`openai_codec`、`tool_runner` |
| `plugin/execute_mounts.dart` | `tool/builtin_tools`、`tool/terminal_hooks`、`tool/tool_runner` |
| `spec/spec_service.dart` | `tool/tool_runner` |
| `files/file_service.dart` | `team/team_workspace` |
| `terminal/terminal_service.dart` | `team/team_workspace` |

> **关键结论（修正版）**：
> - `records` / `tree_store` 整体随迁；通用小件复制进插件仓，不再抽共享包。
> - `core_settings.dart` **不能整包下放**：它按单一 agent 设计，必须先拆成「平台设置」与「领域设置」（§4.8）。
> - 反向依赖里 `plugin_bus` 与 `execute_mounts` 是硬点：核心插件平台反过来 import 领域代码，必须改成「协议 + 插件自建执行站」边界。
> - `tree_agent_loop` 只允许依赖 pub.dev 包与 `plugins/_kit`；CI 需加一条检查：插件仓内不得出现 `package:tree_core/...` 或 `package:tree_protocol/...`。

### 核心现有能力也要搬走（配合 §4.6）

| 核心现有文件 | 去向 |
| --- | --- |
| `files/file_service.dart` | 本地部分 → `local_executor`；远端部分 → 并入 `ssh_executor`；UI 文件 REST 改为委派到执行器 |
| `terminal/terminal_service.dart` | → `local_executor` 的 PTY 执行站；核心只留通用流中继 |
| `server/core_server.dart` 里的文件 / 终端路由 | 从核心路由表移除，改由执行器插件声明 |

> 这两个文件目前反向 import `team/team_workspace`（领域），搬迁时一并切断。

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

---

## 10.3 勘测：插件 scope 仍含领域字段（应去掉）

**结论：是，仍然存在，且渗透 13 个文件。** `StationScope` 当前字段为 `teamId / agentId / sessionId / modeKey`，`StationScopeContext` 另带同样三项 + `modeKey`。

| 使用点 | 用到的字段 | 作用 | 去领域化后的替代 |
| --- | --- | --- | --- |
| `station_scope.dart` | 定义 / `fromJson` / `toJson` | 订阅与命令的上下文 | 删除四个领域字段，只留通用上下文 |
| `station_runtime.dart:98` | `sessionId > agentId > teamId` | 派生订阅粒度 | 改为 `plugin_id + connection_id + topic` |
| `station_channel.dart:108` | `scope.key` | 订阅者键 | 同上 |
| `station_instance.dart:474` | `teamId` | 投递过滤 | 广播给全部订阅者，由订阅方自行过滤 |
| `plugin_bus.dart:859-865` | team/agent/session | scope 匹配 | 同上 |
| `plugin_bus.dart:3767` | `team_id` / `mode` | 站点 state 回包 | 删除这些键 |
| `execute_mounts.dart:550/589/629/660/673` | `teamId` / `agentId` / `modeKey` | **跨 team / 跨 agent / 跨模式 fail-closed 授权** | 安全语义必须重新安置：核心只校验 workspace 租约与调用方身份，领域归属由 `tree.agent` 自己保证 |
| `execute_mounts.dart:874/1202` | `sessionId` | 用量记账归属 | 改为调用方传入的 opaque `account_id` |
| `plugin_tool_definition.dart:27` | 默认 `StationScope()` | 工具调用上下文 | 改为与领域无关的 `workspace_dir / data_dir` |
| `plugin_state_pool.dart` | 声明 scope | 状态池键 | 删除 |
| `agent_events.dart` | `agent_id` / `session_id` / `team_id` | 事件载荷 | 随 `tree_agent_loop` 迁走，核心不解释 |
| `core_server.dart` / `plugin_host.dart` | 解析、透传 | UI 订阅 / 插件命令 | 改为通用上下文 |

### 移除方案（三步，不能一把删）

1. **协议先扩后收**：新增通用 `context {workspace_dir, data_dir, client_id}`；`team_id/agent_id/session_id` 标记废弃但继续接受一个版本（避免 UI 与现有插件同时断）。
2. **授权搬家**：跨 team / 跨 workspace 的 fail-closed 检查从核心的 `execute_mounts` 搬到「执行器插件 + workspace 租约」——核心只登记 `lease_id → dir` 并认证调用方，执行器只证明「路径在租约根内」；「这个 agent 属于这个 team」由 `tree.agent` 自己保证。
3. 之后删除字段、映射、`scope.key` 与 UI 侧 scope 订阅参数，并更新 `tree_protocol` 的站点契约。

> 这是一次协议破坏性变更，**不属于 G**；登记为遗留项 L-23，需单独立项与独立审批。

## 10.4 路由可见面：核心硬编码 36 条，其余由插件申报

**目标形态（迁移完成后）**

| 层 | 内容 | 是否有 per-route 硬编码 |
| --- | --- | --- |
| 核心路由表 | 36 条核心永久面（插件管理、日志、store、bootstrap、meta、站点、平台设置、租约） | **有**，但这 36 条是核心自己的接口，本就该硬编码 |
| 委派路由 | 其余 57 条（agent 36 / spec 2 / mcp 3 / files 13 / git 3） | **没有**：插件启动时经 `system.collect.api.routes` 申报 `{method, pattern}`，核心只维护「归属表」并转发 `api/delegate` |
| 冲突 | 同一 `method + pattern` 被两家插件申报 ⇒ 整条拒收，`/api/meta` 不出现 | 规则化处理，不逐条配置 |

即：**核心不会为任何插件路由写 handler**；`router.add` 只在 `_registerRoutes` 里给核心自己的 36 条用。

**当前实现（2026-10-25：L-28 已落地）**

1. `stubApiPaths` 为空集（已无害）；`stubRouter` 仍在查表链里，作为「没人认领」的兜底，不构成硬编码。
2. ~~`ApiPaths.delegated` 是静态 18 条路径白名单~~ **已去静态化**：`DelegatedRouter` 改为命名空间规则（`/api/` 前缀、保留前缀、段形状合法），并把「与核心已实现路由同键」列为可读拒收。核心删除某条实现后，同一申报**自动生效**，新增插件路由不再需要改核心。

**落地形态**

| 旧规则 | L-28 后 |
| --- | --- |
| 路径必须在静态白名单内 | 路径满足命名空间规则：`/api/` 前缀 + 不在保留前缀内 + 段形状合法 |
| 白名单按批次手工追加 | 无白名单；`coreOwned`（36）/ `delegated`（57）/ `pendingHandoffRoutes`（55）只作**门禁与 G-1 对照口径**，不参与运行期放行 |
| 契约全集 `kept` 静态 93 条 | `kept` 仍是**路径**集合（70）；方法路由契约由 `coreOwned ∪ delegated`（93）表达 |
| 门禁 `coreOwned ∪ delegated == kept` | 门禁：`coreOwned ⊆ 核心 router 键集 ⊆ coreOwned ∪ pendingHandoffRoutes`，且核心 router 路径 ⊆ `kept` |
| 核心路由与委派谁先匹配 | 已实现优先（不变）；申报与**当前已实现**路由同键 ⇒ 申报阶段可读拒收 |
| 冲突检测 | 保留：同 `METHOD pattern` 双家申报整条拒收，不按启动顺序择一 |

> 保留五段**整段前缀**（`/api/plugin`、`/api/bootstrap`、`/api/meta`、`/api/logs`、`/api/store`），既避免逐条枚举，也防止插件伪装平台控制面。

---

> 全部未闭环项（含 G-1~G-7、U-3/U-4、C-11、手工回归、文档缺口）已统一登记在
> [ui-pluginization_acceptance.md §12 遗留项台账](ui-pluginization_acceptance.md#12-遗留项台账2026-10-25-落档)。

在以上决策落定前，核心路由、领域帧与 `agent/llm/team/tool` 目录**保持原样**（不变量 2/3 要求插件验收后才可删除；提前删会直接破坏现有功能）。
