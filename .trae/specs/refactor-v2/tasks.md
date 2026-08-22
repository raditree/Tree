# Tasks

## P0: 骨架重组 + 三模式

- [x] Task 1: 后端七组件目录重组（移动 + 拆分，行为不变）
  - [x] SubTask 1.1: 建 `server/ws/`：迁移 `core/ws_manager.py` + main.py WS 端点 + token 提取
  - [x] SubTask 1.2: 建 `server/agent/`：从 main.py 拆出 chat 编排（`_handle_user_message`/`_stream_agent_reply`/`_process_member_message`）、统一投递（`_dispatch_agent_message`/`_find_roster_member`/`_parse_roster_table`）、`core/team_broker.py`
  - [x] SubTask 1.3: 建 `server/io_/`（`io` 与 Python 内置模块冲突，取 `io_`）：迁移 `core/workspace_io.py`、`core/docker_manager.py`、`core/local_executor.py`（ModeResolver 随 SubTask 3.4 落地）
  - [x] SubTask 1.4: 建 `server/llm/`：迁移 `core/llm.py`、`core/models.py`（模型配置归 config/）
  - [x] SubTask 1.5: 建 `server/data/`：迁移 `core/user_store.py`、`core/agent_store.py`、`core/conversation_store.py`、`core/embed_model.py`、`core/memory.py`
  - [x] SubTask 1.6: 建 `server/config/`：迁移 `core/config.py`、`core/models.py`
  - [x] SubTask 1.7: `server/tool/` 归位（现 `tools/` 更名），MCPManager 随迁；`server/main.py` 瘦身为装配 + lifespan
  - [x] SubTask 1.8: 全局 import 修正 + 启动回归（REST/WS 全功能冒烟）
- [x] Task 2: WorkspaceIO async 化
  - [x] SubTask 2.1: ABC 改 async 接口，Cloud/Local 实现内部处理线程切换（docker exec → to_thread；Local 反向 WS 保持 Future 配对但接口 async）
  - [x] SubTask 2.2: 全调用点改造：tool/ 各工具、agent/chat、roster 读取、活动日志、附件上传（删除调用方手动 to_thread）
- [ ] Task 3: SSH 模式
  - [ ] SubTask 3.1: `data/ssh_store.py`：ssh_connections 表 CRUD
  - [ ] SubTask 3.2: `io_/ssh_connection_manager.py`：register/unregister/is_ssh/get_connection（懒连接 + transport 探活重连 + 测试连接）
  - [ ] SubTask 3.3: `io_/ssh_workspace_io.py`：七个 async 方法（sftp read/write + exec_command + 路径映射 top→remote_base_dir / 成员→workspaces/{id}）
  - [ ] SubTask 3.4: ModeResolver 三分支 + 互斥校验（local 与 ssh 同注册拒绝）
  - [ ] SubTask 3.5: WS 消息 `register_ssh_executor` / `unregister_ssh_executor` + REST `POST/DELETE /api/ssh`
  - [ ] SubTask 3.6: exec_mode 文本三模式 + shell 类型（含 cmd 注明）
  - [ ] SubTask 3.7: 单测：mock paramiko 下七方法全通过；真实 SSH 主机全链路（若有）
- [ ] Task 4: 前端两组件重组
  - [ ] SubTask 4.1: `lib/io/`：迁移 api_service → http_client、websocket_service → ws_client、local_executor_service、auth_service、theme_service 归位
  - [ ] SubTask 4.2: `lib/ui/`：迁移 pages/widgets/models；UI 不直接 import http/web_socket_channel
  - [ ] SubTask 4.3: 前端模式三态开关 UI（cloud/local/ssh，含 SSH 配置表单：host/port/user/auth/remote_base_dir）

## P1: 减法

- [ ] Task 5: 删除 limitless context
  - [ ] SubTask 5.1: 删 `LimitlessContextSession`、`is_limitless_context` 字段与加载、main/agent 全部分支
  - [ ] SubTask 5.2: 删 `test_limitless_context.py` 与相关用例
- [ ] Task 6: 删除预算功能
  - [ ] SubTask 6.1: 删 `core/budget.py`、`_setup_session_budget`/`_check_budget_threshold`/`_send_budget_update_ws`、llm 内预算记账与工具结果预算摘要注入
  - [ ] SubTask 6.2: 删 `/api/budget` 端点、`budget_update` WS 事件、`budget_settings` 表
  - [ ] SubTask 6.3: 删前端预算 UI 与 API 方法
- [ ] Task 7: 删除 help/set/refresh 工具
  - [ ] SubTask 7.1: 删 `help_tool.py`/`set_tool.py`/`refresh_tool.py` 及注册、mcp 工具改为直接工具（列出+调用）
  - [ ] SubTask 7.2: 删 extra_info_refresher / help_refresh_callback / compact help 块重建逻辑（信息改由 system prompt 常驻，见 P3）
- [ ] Task 8: 删除自动记忆更新
  - [ ] SubTask 8.1: 删 `_run_memory_update` 自动触发、`_memory_updating` 锁机制（Spec 体系无静默循环，锁一并删除）、`updating_memory` 状态
  - [ ] SubTask 8.2: 删 `tool_count` 表与 get/increment/reset
  - [ ] SubTask 8.3: 删 `.self/rule.md`（无需 rule，规则并入 Spec 体系）
- [ ] Task 9: 前端用量口径
  - [ ] SubTask 9.1: 删 token 明细展示，改显示当前上下文长度（msg_end 携带 context_length，后端由 `_estimate_context_tokens` 计算）
  - [ ] SubTask 9.2: 删 data collection 开关 UI 与后端 `data_collection_store`

## P2: 多会话并行

- [ ] Task 10: 数据层
  - [ ] SubTask 10.1: `sessions` 表 + `data/session_store.py`（create/list/get/rename/close 软删）
  - [ ] SubTask 10.2: `agent_context` / `messages` 主键与索引扩 `session_id`；旧数据迁移脚本（→ `session_default`）
- [ ] Task 11: Agent 组件 SessionManager
  - [ ] SubTask 11.1: 会话生命周期 + 按 `(user_id, agent_id, session_id)` 的 AgentLLMSession 缓存（替换现 session_cache 键）
  - [ ] SubTask 11.2: 活跃任务/取消/`selected_spec_ids`（Spec 选择）全部按 session 维度（`_active_tasks` 键扩）
  - [ ] SubTask 11.3: 上下文保存/恢复按 session；compact 端点改 session 级
- [ ] Task 12: 协议与 REST
  - [ ] SubTask 12.1: WS 全链路 `session_id`（user_message 入，push 事件出）
  - [ ] SubTask 12.2: REST sessions CRUD + 历史按 session 拉取
- [ ] Task 13: 前端会话切换器
  - [ ] SubTask 13.1: `ui/widgets/session_picker.dart`（会话列表/新建/重命名/删除）
  - [ ] SubTask 13.2: 消息面板按 session 加载历史与状态；stop/compact 按钮按 session 作用
  - [ ] SubTask 13.3: 默认会话兜底（无会话时自动用 `session_default`）

## P3: 工具与 system prompt

- [ ] Task 14: 9 工具集（含 spec）
  - [ ] SubTask 14.1: 工具重命名与归一（ReadFile/WriteFile/EditFile/Terminal/mcp/team/SetTodoList/AskUserQuestion），registry 统一注册
  - [ ] SubTask 14.2: `tool/todo_tool.py`：SetTodoList（todos/merge，写 `.self/todos.md` + `todo_update` WS + 返回快照）
  - [ ] SubTask 14.3: mcp 直接工具：列出可用 MCP 工具（workspace/document/外部）+ 调用
  - [ ] SubTask 14.4: `tool/spec_tool.py` 工具定义（第 9 个工具，description 量化；action=search/select/read/create/list/update，调用 P4 的 spec_engine）
- [ ] Task 15: description 量化
  - [ ] SubTask 15.1: 7 需求维度框架文档化（tool/README 或模块 docstring）
  - [ ] SubTask 15.2: 9 工具 description 按模板重写（功能 | 贡献维度 | 何时用/不用 | 前置依赖）
- [ ] Task 16: system prompt 全量增强
  - [ ] SubTask 16.1: 9 章节结构（身份/任务执行范式=任务分型路由/需求→工具路由表/.self 文档注入/Spec 索引+已选 Spec 全文/工作空间与执行模式含 shell/成员拓扑与寻址规则/Spec 维护指引）
  - [ ] SubTask 16.2: .self 文档注入（memory 超 4k 压缩逻辑保留，rule 已删）+ compact 后重注入
  - [ ] SubTask 16.3: 重构 context 时机统一（create_session、compact 后、名单变更）+ 未重构时保留 system prompt 快照（保上下文缓存命中率）；名单变更触发该 TOP 下所有 agent 重构

## P4: Spec + 团队初始化 + 跨 Top

- [ ] Task 17: Spec 体系
  - [ ] SubTask 17.1: 内置 3 个 Spec 模板 `server/tool/spec/builtin/{easy-task,complex-task,hard-task}.md`（front matter + 工作流/规范/注意事项三段；内容按 spec.md 内置 3 Spec 场景展开）
  - [ ] SubTask 17.2: Spec 文件格式解析器（front matter ↔ 对象、三段校验；经 WorkspaceIO 落盘 `workspace/<agent id>/spec/`，三模式通用）
  - [ ] SubTask 17.3: `data/spec_store.py`：specs 表 CRUD + title/description/when 的 embedding 同步（复用 Embed 组件）
  - [ ] SubTask 17.4: `agent/spec_engine.py`：Spec 索引构建（内置 3 置顶 + 自定义）/ 重构 context 时注入（create_session/compact 触发）/ 未重构保留快照（保缓存）/ session `selected_spec_ids` 管理
  - [ ] SubTask 17.5: `tool/spec_tool.py` 动作实现：search（语义检索 Embed 比对）/ select（多选挂 hook）/ read（全文）/ create（写盘 + 同步 specs 表）/ list（索引）/ update
  - [ ] SubTask 17.6: REST 端点（GET specs / POST search / POST+GET spec-select / POST 创建）
  - [ ] SubTask 17.7: WS `spec_update` 推送（索引/选择变更，供面板刷新）
  - [ ] SubTask 17.8: 前端 `ui/widgets/spec_panel.dart`（浏览/搜索/多选 + 已选与生效时机说明）
- [ ] Task 18: 团队初始化 + 成员拓扑 + 跨 Top
  - [ ] SubTask 18.1: `data/names.json`（200+ 名字池）+ `data/team_store.py`：teams / team_members 表，登记/查询，agent 名称同用户全局唯一校验
  - [ ] SubTask 18.2: `agent/team_init.py`：TOP 创建即全量建队（预建全部成员：名字池取名 + 标准角色模板（默认 16，可配置）、职责留空、状态 idle、初始化 `workspace/<agent id>/`（含 .self/ 与 spec/）、登记团队与名单、生成 team_roster.md）
  - [ ] SubTask 18.3: team 工具移除 create_member、新增 update_member（改成员 model_id/职责/分工/状态 → 更新 team_members + 重新生成 team_roster.md → 向该 TOP 下所有 agent 推送名单）
  - [ ] SubTask 18.4: 成员拓扑常驻 system prompt（TOP + 全体成员 name/role/duty/model_id/status 注入每位 teammate）；名单变更作为重构 context 第三触发器
  - [ ] SubTask 18.5: top 内寻址（按 name，基于拓扑）+ 跨 Top 顶层寻址（按 TOP agent name，用户透露，top-to-top）；回复按 source_agent_id 溯源回发
  - [ ] SubTask 18.6: `list_teams` 动作 + REST `GET /api/teams`（供 TOP"熟悉"本用户名下其他 TOP）
  - [ ] SubTask 18.7: 安全边界：跨用户寻址一律拒绝（单测覆盖）；跨 TOP 成员名单不传递（单测覆盖）

## P5: thinking

- [ ] Task 19: 后端
  - [ ] SubTask 19.1: ModelConfig `thinking` 字段（models/*.yaml + 加载 + 前端模型展示可选）
  - [ ] SubTask 19.2: llm 流式解析 `delta.reasoning_content`（兼容 `reasoning`），yield thinking 段
  - [ ] SubTask 19.3: assistant 消息 `reasoning_content` 上下文回写（tool_calls 轮次）
  - [ ] SubTask 19.4: WS `msg_start(kind=thinking)` 段推送 + messages 表 `kind='thinking'` 持久化
- [ ] Task 20: 前端
  - [ ] SubTask 20.1: ChatMessage kind='thinking' 分支 + ws_client 段路由
  - [ ] SubTask 20.2: `ui/widgets/thinking_card.dart`：默认折叠（思考中动效/时长/首行摘要），点击展开 markdown
  - [ ] SubTask 20.3: 历史重载渲染 thinking 段

## P6: 收尾

- [ ] Task 21: 测试补齐
  - [ ] SubTask 21.1: 会话并行/迁移/重启恢复 单测
  - [ ] SubTask 21.2: 三模式 ModeResolver/互斥/SSHWorkspaceIO(mock paramiko) 单测
  - [ ] SubTask 21.3: Spec 锁/手动触发/回滚 单测；跨 top 寻址/边界 单测
  - [ ] SubTask 21.4: thinking 解析/回写 单测（mock openai stream）
- [ ] Task 22: 仓库卫生
  - [ ] SubTask 22.1: `.gitignore` 补 `workspaces/`、`tmp/`、`server/workspaces/`、`.output/`、`server/*.db`
  - [ ] SubTask 22.2: 清理一次性脚本（`*.sh` probe、`server/_*.py`、`tmp/repro*`、`server/workspaces/`、顶层 `workspaces/`）
  - [ ] SubTask 22.3: 更新 server/README.md 与新目录结构一致
