# Tree 架构重构 v2 Spec

## Why

当前架构经过多轮功能叠加后存在结构性债务：`server/main.py` 单文件 2300 行承担聊天编排/消息分发/记忆维护/预算/roster 解析等全部职责；`docker_manager.py`（~75KB）与 `team_tool.py`（~60KB）为上帝模块；并发模型依赖"调用方必须记得 to_thread"的隐性契约（已多次引发死锁）；团队严格隔离无法跨 Top agent 协作；LLM 思考过程不可见；help 工具承载全部系统信息导致按需拉取、token 效率低。

本次重构目标：
1. **可拓展性**：按 7（Python）+ 2（Flutter）核心组件重组，WorkspaceIO 升级为 async 接口并扩展 SSH 第三模式；
2. **会话管理**：支持一个 agent 多个并行会话（独立上下文/历史/状态）；
3. **减法**：删除 limitless context model、预算功能、help/set/refresh 工具、自动记忆更新；
4. **增强**：system prompt 全量增强（信息常驻 + Spec 索引）、tool description 用户需求量化、Spec 体系（3 个内置任务型 Spec + spec 检索/选择 + 重构 context 注入 hook）、团队初始化（TOP 创建全量建队 + 成员拓扑常驻 + 名单变更推送）与跨 Top 顶层通信、thinking 内容解析与前端展示。

## What Changes

### REMOVED
- **BREAKING**: `LimitlessContextSession` 及 `is_limitless_context` 配置字段、相关全部分支与测试
- **BREAKING**: 预算功能全套：`core/budget.py`、`budget_update` WS 事件、`/api/budget` 端点、工具结果尾部预算摘要注入、`_check_budget_threshold`、前端预算 UI、`budget_settings` 表
- **BREAKING**: `help` / `set` / `refresh` 内置工具（信息全量迁入 system prompt；mcp 改为直接工具，不再经 set/refresh 间接调用）
- **BREAKING**: 自动记忆更新：`_run_memory_update` 自动触发路径、`tool_count` 表与门控、`updating_memory` 状态、`memory_update_skip_ratio` 配置
- **BREAKING**: `.self/rule.md`（无需 rule，规则并入 Spec 体系）
- **BREAKING**: team 工具 `create_member` 动作（成员于 TOP agent 创建时全量预建，不再动态创建；改由 `update_member` 修改成员信息）
- 用量统计**保留**（llm usage 解析、`msg_end` usage、messages 表 usage 列、`_estimate_context_tokens`），仅前端展示口径变化（见 MODIFIED）

### ADDED
- SSH 运行模式：`SSHWorkspaceIO` + `SSHConnectionManager`（paramiko，DB 持久化配置，懒连接 + 探活重连）
- 多会话并行：`sessions` 表 + `SessionManager`（create/list/get/close）+ REST API + WS 全链路 `session_id`
- Spec 体系：`spec` 工具（search 检索 / select 多选 / read / create / list / update）+ 3 个内置任务型 Spec（easy/complex/hard，置顶不简化为固定索引）+ Spec 落盘 `workspace/<agent id>/spec/` + 重构 context 注入 hook（create_session/compact 触发，未重构时保留快照保证上下文缓存命中率）+ 前端 Spec 面板（浏览/搜索/多选，UI 调后端 API）
- Spec 元数据索引：`specs` DB 表（title/task_type/description/when/tags/embedding）支撑语义检索（复用 Embed 组件）
- 跨 Top team 通信：`teams` 全局注册表 + agent 名称同用户全局唯一 + `list_teams` 动作
- TOP agent 创建即全量建队：创建 TOP 时预建全部成员（200+ 名字池 `server/data/names.json` + 标准角色模板，职责留空、状态 idle、初始化 `workspace/<agent id>/`、登记团队与成员名单）
- 成员拓扑常驻：整个成员拓扑（上级 + 全体成员的 name/role/duty/model_id/status）注入每位 teammate agent 的 system prompt，支撑上下级沟通
- 名单变更推送：TOP agent 修改成员信息（model_id/职责/分工/状态）时，经 system prompt 向该 TOP 下所有 agent 推送更新后的成员名单（触发其 context 重构）
- thinking 支持：ModelConfig `thinking` 字段、`reasoning_content` 流式解析、上下文回写、WS `kind=thinking` 段、messages 表 `kind='thinking'` 持久化、前端 `ThinkingCard`（默认折叠可展开）
- `SetTodoList` 内置工具（任务分解/进度跟踪，`.self/todos.md` 持久化 + `todo_update` WS 推送）
- tool description 量化：7 用户需求维度框架 + 统一 description 模板 + system prompt 需求→工具路由表
- 组件化目录：Python `ws/agent/tool/io_/llm/data/config` 七组件（`io` 与 Python 内置 `io` 模块冲突，包名取 `io_`）；Flutter `ui/io` 两组件
- WorkspaceIO async 化：接口改 async，实现内部处理线程切换，消灭调用方 `to_thread` 隐性契约

### MODIFIED
- 前端用量展示：由 token 明细改为**当前上下文长度**（token 数）
- system prompt：全量增强（身份/角色、任务执行范式=任务分型路由、需求→工具路由表、.self 文档注入（identity/memory，删 rule）、**Spec 索引（内置 3 置顶）+ 已选 Spec 全文注入**、工作空间与执行模式含 shell 类型、成员拓扑与寻址规则、Spec 维护指引）
- 工具集收敛为 9 个：ReadFile / WriteFile / EditFile / Terminal / mcp / team / SetTodoList / AskUserQuestion / spec
- team 工具：移除 `create_member`（成员预建于 TOP 创建），新增 `update_member`（改成员信息并触发名单推送）；`send_message` / `assign_task` 支持 top 内成员寻址（按 name，基于拓扑）与跨 Top 顶层寻址（按 TOP agent name，用户透露，限同用户）
- update memory 升级为 Spec 体系：Spec = 持久化文件（`workspace/<agent id>/spec/`），模型主动检索/选择/创建 + 用户经 UI Spec 面板选择；注入时机 = 重构 context（create_session/compact），未重构时保留快照保证上下文缓存命中率
- 执行模式说明（exec_mode）：三模式（cloud/local/ssh）+ shell 类型透出（cloud=Linux sh；local Windows=cmd 并在 system prompt 注明；local mac/linux=bash；ssh=远端 shell）

## Impact

- **重构（移动+拆分）**: `server/main.py` → `server/agent/`（chat 编排/dispatch/spec）+ `server/ws/`（WS 端点与路由）；`server/core/*` → 按七组件归位；`lib/services/*` → `lib/io/`；`lib/pages`+`lib/widgets`+`lib/models` → `lib/ui/`
- **删除文件**: `server/core/budget.py`、`server/core/data_collection_store.py`（快照基于 usage 明细，随预算删除）、`server/tools/help_tool.py`、`server/tools/set_tool.py`、`server/tools/refresh_tool.py`、`server/tests/test_limitless_context.py`
- **新增文件**: `server/io/ssh_workspace_io.py`、`server/io/ssh_connection_manager.py`、`server/agent/session_manager.py`、`server/agent/spec_engine.py`（Spec 索引/注入 hook/重构触发）、`server/data/team_store.py`、`server/data/session_store.py`、`server/data/ssh_store.py`、`server/data/spec_store.py`、`server/data/names.json`（200+ 名字池）、`server/agent/team_init.py`（TOP 创建全量建队 + 名单初始化/推送）、`server/tool/spec_tool.py`、`server/tool/todo_tool.py`、`server/tool/spec/builtin/{easy-task,complex-task,hard-task}.md`（3 个内置 Spec）、`lib/ui/widgets/thinking_card.dart`、`lib/ui/widgets/session_picker.dart`、`lib/ui/widgets/spec_panel.dart`
- **DB 变更**: 新增 `sessions` / `teams` / `team_members`（top_agent_id/member_id/name/role/duty/model_id/status/timestamps，成员名单结构化存储，`team_roster.md` 为生成视图）/ `ssh_connections` / `specs`（Spec 元数据索引 + embedding）表；删除 `budget_settings` / `tool_count` 表；`agent_context` 主键扩为 `(user_id, agent_id, session_id)`（旧数据迁移入 `session_default`）；会话状态增加 `selected_spec_ids`（按会话的 Spec 选择）
- **外部依赖**: paramiko（已安装 5.0.0）

---

## 目标架构

```
server/
├── ws/        WebSocket（全局）: 连接管理 / JWT 鉴权 / 消息路由 / 反向执行通道
├── agent/     Agent: SessionManager / chat 编排 / TeamMessageBroker / Spec / 统一消息投递
├── tool/      Tool: registry + 9 内置工具（含 spec）+ MCPManager（外部 MCP + workspace 服务）
├── io_/       IO: WorkspaceIO(ABC) → Cloud/Local/SSH + ModeResolver + 各连接管理器
├── llm/       LLM: AgentLLMSession（唯一会话类）+ thinking 解析 + 压缩 + client factory
├── data/      Data: SQLite 统一存储（users/agents/teams/sessions/messages/context/archive/embed_cache/ssh）
└── config/    Config: app.yaml + models/*.yaml（+thinking 字段）

lib/
├── ui/        UI: pages + widgets（ThinkingCard / 会话切换器 / 三态开关 / todo 面板）
└── io/        IO: http_client / ws_client / local_executor / 模式注册
```

### 核心 API

| API | 签名 | 说明 |
|---|---|---|
| WorkspaceIO | `async read_file / write_file / exec_shell / exec_argv / grep_search / git_log / list_files` | 文件读写 + 终端命令，cloud+local+ssh 三实现，统一 `{exit_code, stdout, stderr, error?}` 返回 |
| Embed | `embed(texts: List[str]) -> List[vec]` | 纯文本 embed，带 LRU+DB 缓存，支持 batch 分片 |
| LLM | `chat(messages, on_tool_turn) -> Stream[Text \| Thinking \| ToolCall]` | 流式产出，含 thinking 段 |
| Agent | `send_message / create_session / select_specs / rebuild_context / cancel` | 会话与消息编排入口 |
| Spec | `list / search / select / read / create / update` | Spec 索引/语义检索/选择挂 hook/读取/创建/更新（内容存 workspace spec/，索引存 specs 表） |
| WS | `send_to_user / on_message / reverse_request` | 全局推送与反向执行请求配对 |
| Data | users / agents / teams / sessions / messages / context store | SQLite 统一访问 |
| Config | `get_config() / get_model_configs()` | 应用与模型配置 |

---

## ADDED Requirements

### Requirement: 组件化目录结构
后端 SHALL 重组为 `ws / agent / tool / io_ / llm / data / config` 七个组件目录（`io` 与 Python 内置 `io` 模块冲突，包名取 `io_`）；前端 SHALL 重组为 `ui / io` 两个组件目录。重组以"移动 + 拆分"方式进行，行为不变，每步可运行。

#### Scenario: 后端启动
- **WHEN** 执行 `python server/main.py`
- **THEN** `main.py` 仅保留应用装配 + lifespan + WS 端点挂载，业务逻辑全部位于七组件内
- **AND** 现有 REST / WS 功能与重构前一致

#### Scenario: 前端运行
- **WHEN** 运行 Flutter 应用
- **THEN** 网络/WS/本地执行全部经 `lib/io/` 组件，UI 组件不直接 import http/web_socket_channel 原始 API

### Requirement: 三模式运行（cloud docker / local / ssh）
系统 SHALL 支持三种执行模式，按 `(user_id, top_agent_id)` 维度选择，优先级 local > ssh > cloud，且同一 top agent 同时只能启用一种非 cloud 模式。

#### Scenario: 模式互斥
- **WHEN** 某 top agent 已启用 local 模式，前端再注册 ssh 模式
- **THEN** 后端拒绝并返回明确错误（提示先注销 local），不静默切换

#### Scenario: SSH 工作空间
- **WHEN** 注册 ssh 模式（host/port/username/auth/remote_base_dir）
- **THEN** SSHConnectionManager 测试连接，成功后落 `ssh_connections` 表并激活
- **AND** 工具调用经 SSHWorkspaceIO 在远端执行：顶部 agent → `remote_base_dir`，成员 → `remote_base_dir/workspaces/{workspace_id}`
- **AND** 重启后端后 ssh 配置仍生效（DB 持久化）

#### Scenario: shell 类型透出
- **WHEN** 构建 system prompt 的执行模式说明
- **THEN** cloud 注明 `Linux 容器，shell = sh (POSIX)`
- **AND** local Windows 注明 `shell = cmd.exe` 及其语法注意事项
- **AND** ssh 注明远端 shell 类型与"远端主机、操作不可逆"提示

#### Scenario: WorkspaceIO async 化
- **WHEN** 任何组件调用 WorkspaceIO 方法
- **THEN** 调用为 `await io.xxx(...)`，线程切换由 IO 实现内部完成
- **AND** 调用方不再需要手动 `asyncio.to_thread` 包裹（消除事件循环死锁隐患）

### Requirement: 多会话并行（会话管理）
系统 SHALL 支持一个 agent 拥有多个并行会话，每个会话拥有独立上下文、对话历史与运行状态。

#### Scenario: 会话生命周期
- **WHEN** 用户调用 `POST /api/agents/{id}/sessions`
- **THEN** 创建新会话并返回 `session_id`（自动生成标题，可后续重命名）
- **WHEN** 用户 `GET /api/agents/{id}/sessions`
- **THEN** 返回该 agent 全部会话（含最后更新时间与状态）
- **WHEN** 用户 `DELETE /api/sessions/{sid}`
- **THEN** 软删除该会话及其上下文（审计保留）

#### Scenario: 会话隔离
- **WHEN** 同一 agent 的两个会话同时收发消息
- **THEN** 各自使用独立 `AgentLLMSession`（上下文互不干扰）、独立历史、独立 stop/compact/Spec 状态
- **AND** WS 全部 agent 事件携带 `session_id`，前端按会话分发渲染

#### Scenario: 旧数据迁移
- **WHEN** 重构后首次启动
- **THEN** 每个已有 agent 的旧上下文自动归入默认会话 `session_default`
- **AND** 前端未选择会话时默认使用 `session_default`

### Requirement: 工具体系（9 工具 + description 量化）
内置工具集 SHALL 收敛为 9 个：ReadFile / WriteFile / EditFile / Terminal / mcp / team / SetTodoList / AskUserQuestion / spec。每个工具 description SHALL 按统一模板声明其覆盖的用户需求维度与贡献。

#### Scenario: description 量化模板
- **WHEN** LLM 查看任一工具定义
- **THEN** description 包含：`[一句话功能] | 贡献维度: <维度名>（对哪个用户需求直接贡献）` + `何时使用 / 何时不用 / 前置依赖`
- **AND** 需求维度 ∈ {上下文获取, 文件产出, 环境执行, 外部能力, 协同, 任务管理, 人机协作}

#### Scenario: mcp 直接工具
- **WHEN** 模型需要外部 MCP 能力（文档解析/搜索/第三方服务）
- **THEN** 直接调用 mcp 工具（列出可用 MCP 工具 + 指定工具与参数调用），无需 set/refresh 中间步骤

#### Scenario: SetTodoList
- **WHEN** 模型处理长任务调用 SetTodoList（todos 列表 + merge 标志）
- **THEN** 任务列表写入 `.self/todos.md` 并推送 `todo_update` WS 事件
- **AND** 返回当前任务快照供模型后续引用

#### Scenario: spec 工具
- **WHEN** 模型需要检索/选择/沉淀 Spec
- **THEN** 调用 spec 工具：`search`（语义检索，复用 Embed 对 title/description/when 比对）/ `select`（多选挂 hook）/ `read`（全文）/ `create`（创建新 Spec）/ `list`（索引）/ `update`
- **AND** `select` 仅记录选择（session `selected_spec_ids`），实际注入发生在下次重构 context；立即使用经 `read` 返回全文（进对话上下文，不占用 system prompt）

#### Scenario: Terminal 环境注明
- **WHEN** 执行环境为 local Windows
- **THEN** system prompt 明确注明 shell 为 cmd.exe，模型生成命令时遵循 cmd 语法

### Requirement: System Prompt 全量增强
系统提示词 SHALL 全量注入 agent 运行所需的全部静态/半静态信息，不再依赖 help 工具按需拉取。

#### Scenario: system prompt 内容
- **WHEN** 重构 context（create_session / compact）构建 system prompt
- **THEN** 包含：① 身份与角色（.self/identity.md，默认顶层 Agent 说明）② 任务执行范式（任务分型路由：判型 easy/complex/hard → 选对应内置 Spec → 按其 workflow 执行）③ 需求→工具路由表（7 维度）④ .self 文档注入（memory.md，超 4k 压缩；rule.md 已删）⑤ **Spec 索引**（内置 3 置顶 + 自定义 Spec，含 id/task_type/title/when 摘要）⑥ **已选 Spec 全文**（本会话挂 hook 的 Spec，注入 workflow/规范/注意事项全文）⑦ 工作空间与执行模式（三模式 + shell 类型 + `.self/` 与 `spec/` 位置 + 存储软上限告警）⑧ 成员拓扑与寻址规则（TOP + 全体成员 name/role/duty/model_id/status；top 内按 name 寻址、跨 Top 顶层按 TOP agent name 寻址、回复路径）⑨ Spec 维护指引（何时应 search/select/create spec）
- **AND** 不再注册 help/set/refresh 工具

#### Scenario: 注入时机与上下文缓存
- **WHEN** 重构 context（create_session / compact 完成 / 名单变更：TOP 修改成员信息）
- **THEN** 重建 system prompt（注入最新 Spec 索引 + 已选 Spec 全文 + memory + 成员拓扑）
- **WHEN** 未重构 context 的常规对话轮次
- **THEN** 保留既有 system prompt 快照不变、不重注入（保证 LLM 网关前缀缓存命中率）
- **AND** 中途 select 的 Spec 于下次重构生效；需立即使用时 read 全文（进对话上下文）
- **AND** 名单变更推送触发该 TOP 下所有 agent 重构（名单变更低频，值得打破缓存以保证沟通信息一致）

### Requirement: Spec 体系（原 update memory）
Spec SHALL 为持久化的任务型规范文件，存放于 `workspace/<agent id>/spec/`，取代原"update memory"（不再需要 rule.md）。Spec 支持模型主动检索/选择/创建与用户经 UI Spec 面板选择；注入时机为重构 context（create_session/compact），未重构时保留快照以保证上下文缓存命中率。

#### Scenario: Spec 文件格式
- **WHEN** 一个 Spec 存在
- **THEN** 它是 Markdown 文件，front matter 含：`id / title / task_type(easy|complex|hard|自定义) / description(一句话，供索引与语义检索) / when(适用条件列表) / tags / pinned(内置 3 = true) / builtin / created_at / updated_at`
- **AND** 正文固定三段：`## 工作流（workflow）`、`## 该类任务规范`、`## 注意事项`
- **AND** 内置 Spec 为服务端模板（`server/tool/spec/builtin/`），自定义 Spec 经 WorkspaceIO 落盘到 agent 工作空间 `spec/`（cloud/local/ssh 三模式通用）

#### Scenario: 内置 3 个 Spec（置顶，不简化为固定索引以保留未来兼容性）
- **WHEN** 任一 agent 构建 Spec 索引
- **THEN** 内置 3 个 Spec 始终包含并置顶：
  1. **easy-task**（easy）— 索引条件：单文件(≤3)局部改动 / 明确问答查资料 / 预计 tool call ≤5 / 无新增依赖与接口变更 / 用户明示"简单改下"。**workflow**：ReadFile 读上下文 → 直接 Edit/Write/Terminal 执行 → Terminal 验证 → 汇报；**切换判定**：执行中 tool call 已 >8 未收敛 / 发现跨文件跨模块影响 / 需多方案比较 → 立即切 complex-task。**规范**：无需团队与 todo；先读后写。**注意**：easy 是初判非承诺，复杂度增长必须切换不得硬撑。
  2. **complex-task**（complex）— 索引条件：跨文件跨模块 / 需分工 / 新功能多组件 / 环境依赖变更 / 用户说"开发功能/重构/多步"。**workflow**：① spec search 找适用自定义 Spec（命中→select 并遵循之；未命中→走通用流程且完成后 spec create 沉淀）② SetTodoList 分解（每项可独立验证）③ 按可并行度指派成员（可并行/需不同技能→team update_member 设分工 + assign_task 指派；强耦合串行→自行逐步）④ 按 todo 执行（Read→Write/Edit/Terminal→验证，完成即更新 todo）⑤ 全量验证 ⑥ 汇报 ⑦ 无适用 Spec 时 spec create 沉淀。**规范**：todo 必建且全程跟踪；先检索 spec 再执行；update_member 给成员设职责/分工后再 assign_task；assign_task 必含目标/输入/验收/产出。**注意**：激活 1-3 个成员为宜（成员已预建，按需激活）；并行避免同文件冲突（按模块拆分）。
  3. **hard-task**（hard）— 索引条件：架构级框架级变更 / 新领域无经验 / 高不确定需多方案 / 高危（安全/性能/数据迁移/兼容）/ 用户说"重新设计/大重构/企业级/谨慎"。**workflow**：① spec search（明确命中→select 并**回归 complex-task**；仅模糊或无命中→走企业级流水线）② 界定边界（范围/不做项/约束/验收，写入 todo 首项或 .self/）③ 召开团队会议（team update_member 激活 架构/前端/后端/测试/安全 等角色成员并设分工，team send_message 开会，各成员按角色给方案，汇总比较选型并记录理由）④ 标准团队开发流水线（需求分析→方案设计→方案评审→实现→测试→交付，每阶段有产出物与评审）⑤ 高危操作 AskUserQuestion 用户确认 ⑥ **spec create 补充相应 Spec（强制，缺则任务未闭环）**。**规范**：必须过会议讨论阶段（不直接动手）；流水线每阶段有产出物与评审不跳过；方案文档写入工作空间可追溯；高危必确认；末尾必补 spec。**注意**：问题过大应拆多个 hard-task；会议中若不满足 hard 判据可降级 complex；spec 补充是最后强制步骤。

#### Scenario: Spec 索引与注入
- **WHEN** 重构 context（create_session / compact）
- **THEN** system prompt 注入 Spec 索引：内置 3 置顶 + 自定义 Spec（id/task_type/title/when 摘要），超 N 条仅展示前 N（用 spec search 取更多）
- **AND** 注入本会话已选（挂 hook）Spec 的全文（工作流/规范/注意事项），保证 compact 后 Spec 指引不丢失
- **AND** memory（.self/memory.md）默认挂 hook 一并注入（超 4k 压缩）

#### Scenario: 用户经 UI 选择（用户操作 UI，非直接调 API）
- **WHEN** 用户在前端打开 Spec 面板（按 agent/session）
- **THEN** 可浏览 Spec 列表（内置 3 置顶 + 自定义）、关键词检索、多选（勾选）挂 hook
- **AND** 前端经 `lib/io/` 调后端 REST（GET specs / POST search / POST spec-select / GET spec-select）完成，用户不直接调裸 API
- **AND** 选择于下次重构 context（compact/新建会话）生效；面板展示当前会话已选 Spec 与生效时机说明

### Requirement: 团队初始化与成员拓扑
创建 TOP agent 时 SHALL 全量预建其成员（不再动态创建）；整个成员拓扑 SHALL 常驻每位 teammate agent 的 system prompt 以支撑上下级沟通；TOP agent 修改成员信息时 SHALL 向该 TOP 下所有 agent 推送更新后的名单。

#### Scenario: TOP 创建即全量建队
- **WHEN** 创建 TOP agent
- **THEN** 同时预建全部成员：名字取自 200+ 名字池（同用户内全局唯一）、角色取自标准角色模板（默认 16 个，可配置）、职责留空、状态 idle
- **AND** 初始化 `workspace/<agent id>/`（含 `.self/` 与 `spec/`）
- **AND** 团队登记到 `teams` 表、成员名单写入 `team_members` 表（生成 `team_roster.md` 视图）
- **AND** team 工具无 `create_member` 动作（成员不动态创建/删除，TOP 仅可 `update_member` 调整）

#### Scenario: 成员拓扑常驻（上下级沟通）
- **WHEN** 构建任一 teammate agent 的 system prompt
- **THEN** 注入其所属 TOP 的完整成员拓扑：上级（TOP）+ 全体成员（name/role/duty/model_id/status）
- **AND** 成员可据此识别上级与同级，直接进行上下级与同级沟通（按 name 寻址）

#### Scenario: 名单变更推送
- **WHEN** TOP agent 经 team `update_member` 修改成员信息（设置 model_id / 职责 / 分工 / 状态等）
- **THEN** 更新 `team_members` 表并重新生成 `team_roster.md`
- **AND** 经 system prompt 向该 TOP 下所有 agent 推送更新后的成员名单（触发其 context 重构、注入新拓扑）
- **AND** 跨 TOP 成员名单不传递（各 TOP 的 agent 仅可见本 TOP 名单）

#### Scenario: 名字池
- **WHEN** 为成员分配名字
- **THEN** 从 `server/data/names.json`（200+ 名字池，可配置扩展）取用，保证同用户内全局唯一
- **AND** 名字池耗尽时返回明确错误（提示扩充名字池）

### Requirement: 跨 Top 团队通信
team 工具 SHALL 支持 top 内成员通信（按 name，基于拓扑）与跨 Top agent 通信（按 TOP agent name，用户透露），范围限同一用户；跨 TOP 成员名单不传递。

#### Scenario: 全局命名
- **WHEN** TOP agent 创建（含全量建队）
- **THEN** 团队登记到 `teams` 表 `(team_name, top_agent_id, user_id, UNIQUE(user_id, team_name))`
- **AND** agent 名称（含 TOP 与成员）在同一用户内全局唯一（创建时校验，冲突则拒绝）

#### Scenario: top 内寻址
- **WHEN** 模型调用 team send_message / assign_task，target = 本 TOP 内成员 name
- **THEN** 经成员拓扑（system prompt 常驻）解析 name → member_id → 统一投递
- **AND** 解析失败返回明确错误（成员不存在 / 职责未设置提示先 update_member）

#### Scenario: 跨 Top 顶层寻址（用户透露）
- **WHEN** 需跨 TOP 协作，用户向本 TOP agent 透露其他 TOP agent 的 name（或 id）
- **THEN** 本 TOP agent 按 TOP agent name 寻址并交互（top-to-top），接收方 TOP 再在其内部调度成员
- **AND** 跨 TOP 不传递对方成员名单；如需对接具体成员，由对方 TOP 在交互中透露该成员 name
- **AND** TOP agent 可通过 list_teams 了解本用户名下有哪些 TOP（用于"熟悉"）

#### Scenario: 安全边界
- **WHEN** 寻址目标属于其他用户的团队
- **THEN** 拒绝投递（跨用户不开放）

#### Scenario: 回复路径
- **WHEN** 跨 Top 接收方完成处理
- **THEN** 回复经 source_agent_id 溯源回发原发起 agent（复用统一投递入口）

### Requirement: Thinking 解析与展示
LLM 层 SHALL 解析 thinking（推理）内容，前端 SHALL 以默认折叠、可展开的卡片展示。

#### Scenario: thinking 流式解析
- **WHEN** 模型配置 `thinking: true` 且流式 chunk 携带 `reasoning_content`（兼容 `reasoning` 字段）
- **THEN** LLM 层 yield `{"type": "thinking", "content": ...}` 段
- **AND** WS 推送 `msg_start(kind="thinking")` + `msg_chunk` + `msg_end`（复用段协议）

#### Scenario: thinking 上下文回写
- **WHEN** 带 thinking 的 assistant 消息进入下一轮上下文
- **THEN** 原样保留 `reasoning_content` 字段回传网关（避免 400）
- **AND** `thinking: false` 的模型不产生 thinking 段

#### Scenario: 前端展示
- **WHEN** 前端收到 thinking 段
- **THEN** 渲染 ThinkingCard：默认折叠（显示思考中动效/完成时长 + 首行摘要），点击展开完整 markdown
- **AND** thinking 段持久化（messages 表 `kind='thinking'`），历史重载后可见

### Requirement: 用量展示口径
系统 SHALL 保留 usage 统计（用于上下文压缩判断与历史展示），删除预算功能，前端仅展示当前上下文长度。

#### Scenario: 前端展示
- **WHEN** agent 回复完成
- **THEN** 前端展示当前上下文长度（token 数，来自 `last_usage.prompt_tokens` + 新增消息估算）
- **AND** 不再展示 prompt/completion/cached 明细与预算信息
- **AND** 不存在任何 budget API / WS 事件 / UI

---

## MODIFIED Requirements

### Requirement: WebSocket 协议
- 新增：`msg_start(kind=thinking)` 段；`todo_update`；`spec_update`（Spec 索引/选择变更推送，供前端面板刷新）；`register_ssh_executor` / `unregister_ssh_executor`；所有 agent 事件携带 `session_id`
- 删除：`budget_update`；`agent_status: updating_memory`；`agent_status: spec` / `spec_done`（Spec 不再有静默长循环，无需运行状态）
- 保留：`msg_start/msg_chunk/msg_end`、`tool_start/tool_end`、`agent_status(working/idle/stopping)`、`stop`、`user_answer/cancel_question`、`register_local_executor`、`tool_exec_request/tool_exec_response`、`heartbeat`

### Requirement: REST API
- 新增：`GET/POST /api/agents/{id}/sessions`、`DELETE /api/sessions/{sid}`、`GET /api/sessions/{sid}/messages`、`GET /api/agents/{id}/specs`（列表/索引）、`POST /api/agents/{id}/specs/search`（检索）、`POST /api/sessions/{sid}/spec-select`（多选挂 hook）、`GET /api/sessions/{sid}/spec-select`、`POST /api/agents/{id}/specs`（创建，供 UI/模型）、`GET /api/teams`、`POST/DELETE /api/ssh`
- 删除：`POST/GET /api/budget/{agent_id}`、data collection 开关相关端点
- 保留：auth（register/login/password/logout/账号注销流程）、agents CRUD、conversations（改为按 session）、`/compact`（session 级）、teammates/log/message、文件同步与下载

### Requirement: 数据层
- 新增表：`sessions`（session_id/user_id/agent_id/title/created_at/updated_at/status/deleted_at/selected_spec_ids）、`teams`（team_name/top_agent_id/user_id/created_at）、`ssh_connections`（user_id/agent_id/host/port/username/auth_type/password/private_key_path/remote_base_dir/timestamps）、`specs`（id/agent_id(内置为 NULL)/title/task_type/description/when_json/tags_json/builtin/pinned/embedding/created_at/updated_at，Spec 元数据索引供语义检索，内容本体在 workspace spec/ 文件）
- 删除表：`budget_settings`、`tool_count`
- 变更：`agent_context` 主键 → `(user_id, agent_id, session_id)`；`messages` 增加 `session_id` 列（旧数据回填 `session_default`）；保留 `agent_context_archive` 审计机制

### Requirement: 模型配置
- 删除 `is_limitless_context` 字段
- 新增 `thinking: bool`（默认 false）
- 保留其余字段与 extra 机制

---

## 实施阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 骨架 | 目录重组为 7+2 组件；WorkspaceIO async 化；SSHWorkspaceIO + SSHConnectionManager + 三态注册 | 重构前全部功能回归通过；SSH mock 单测通过 |
| P1 减法 | 删 limitless / 预算 / help/set/refresh / 自动记忆；前端用量改上下文长度 | 启动无残留引用；前端无 usage 明细与预算 UI |
| P2 会话 | SessionManager + sessions 表 + REST + WS session_id + 旧数据迁移 + 前端会话切换器 | 多会话并行互不干扰；重启后恢复 |
| P3 工具与 prompt | 9 工具集（+spec）+ description 量化 + system prompt 全量增强（含 Spec 索引章节）+ SetTodoList | 工具定义符合模板；prompt 含全部 9 章节 |
| P4 Spec + 团队 + 跨 Top | 内置 3 Spec 模板 + Spec 文件格式 + spec 工具 + specs 表/embedding + 重构 context 注入 hook + 前端 Spec 面板 + TOP 全量建队（200+ 名字池）+ 成员拓扑常驻 + 名单变更推送 + 跨 Top 顶层寻址 + list_teams | Spec 索引/选择注入正确；注入时机正确（create/compact/名单变更）；UI 多选生效；TOP 创建全量建队+拓扑常驻+名单推送正确；跨 top 顶层投递/回传正确；跨 top 名单不传递；命名冲突拒绝 |
| P5 thinking | 配置 + 解析 + 回写 + 协议 + 持久化 + ThinkingCard | thinking 段流式渲染折叠/展开；历史可见 |
| P6 收尾 | 测试补齐（会话/三模式/spec/跨top/thinking）；仓库卫生（workspaces/tmp/probe 脚本清理 + .gitignore） | 测试全绿；`git status` 无运行产物 |
