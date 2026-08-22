# Checklist

## P0 骨架与三模式
- [ ] 后端目录为 `ws / agent / tool / io_ / llm / data / config` 七组件（`io` 与 Python 内置模块冲突，取 `io_`），`main.py` 仅装配 + lifespan + WS 挂载
- [ ] 前端目录为 `ui / io` 两组件，UI 不直接 import http/web_socket_channel 原始 API
- [ ] 重构后 REST / WS 全功能回归通过（登录、agent CRUD、对话流式、工具卡片、文件面板、teammates）
- [ ] WorkspaceIO 为 async 接口，调用方无手动 `asyncio.to_thread` 包裹
- [ ] local / ssh / cloud 三模式按 `(user_id, top_agent_id)` 选择，优先级 local > ssh > cloud
- [ ] local 与 ssh 同时注册时后端拒绝并返回明确错误
- [ ] SSH 配置（host/port/username/auth/remote_base_dir）落 DB，重启后生效
- [ ] SSHWorkspaceIO 七方法在 mock paramiko 下单测通过；路径映射 top→remote_base_dir / 成员→workspaces/{id}
- [ ] 前端三态开关 + SSH 配置表单可用
- [ ] exec_mode 文本含 shell 类型（cloud=sh / local Windows=cmd 注明 / local mac=bash / ssh=远端 shell）

## P1 减法
- [ ] 代码中无 `LimitlessContextSession` / `is_limitless_context` 任何残留引用
- [ ] 代码中无 budget 相关残留（模块/WS 事件/REST 端点/前端 UI/工具结果摘要注入）
- [ ] 内置工具集恰好 9 个：ReadFile / WriteFile / EditFile / Terminal / mcp / team / SetTodoList / AskUserQuestion / spec
- [ ] help / set / refresh 工具文件已删除，mcp 可直接列出并调用外部 MCP 工具
- [ ] 无自动记忆更新（无 tool_count 表/门控、无 updating_memory 状态、主回复后不自动触发 spec）
- [ ] `.self/rule.md` 已删除（规则并入 Spec 体系）
- [ ] 前端仅展示当前上下文长度（token 数），无 prompt/completion/cached 明细

## P2 多会话并行
- [ ] 一个 agent 可创建多个会话，各自独立上下文/历史/状态
- [ ] 两会话并发对话互不干扰（上下文、stop、compact 均按 session 隔离）
- [ ] WS 全部 agent 事件携带 session_id，前端按会话分发渲染
- [ ] REST：sessions CRUD + 历史按 session 拉取 + compact 按 session
- [ ] 旧数据迁移：既有 agent 上下文归入 `session_default`，前端默认选中
- [ ] 重启后会话列表与上下文恢复

## P3 工具与 system prompt
- [ ] 9 工具 description 均含：功能 | 贡献维度（7 维度之一）| 何时用/不用 | 前置依赖
- [ ] system prompt 含 9 章节：身份/任务执行范式=任务分型路由/需求→工具路由表/.self 文档注入/Spec 索引+已选 Spec 全文/工作空间与执行模式/成员拓扑与寻址规则/Spec 维护指引
- [ ] memory.md 注入（超 4k 压缩，rule 已删），compact 后重注入
- [ ] SetTodoList：写 `.self/todos.md` + `todo_update` WS + 返回快照
- [ ] local Windows 下 system prompt 注明 cmd 语法注意事项

## P4 Spec 体系 + 团队初始化 + 跨 Top
- [ ] 内置 3 个 Spec 模板（easy-task/complex-task/hard-task）存在且置顶，为真实 Spec 文件而非固定索引字符串
- [ ] Spec 文件格式正确：front matter（id/title/task_type/description/when/tags/pinned/builtin/时间戳）+ 工作流/规范/注意事项三段
- [ ] Spec 经 WorkspaceIO 落盘 `workspace/<agent id>/spec/`，cloud/local/ssh 三模式均可读写
- [ ] specs 表 + title/description/when 的 embedding 同步正确（复用 Embed）
- [ ] spec 工具 6 动作可用：search（语义检索）/ select（多选挂 hook）/ read（全文）/ create（写盘+同步）/ list（索引）/ update
- [ ] 重构 context（create_session/compact/名单变更）注入 Spec 索引（内置 3 置顶）+ 已选 Spec 全文 + memory + 成员拓扑
- [ ] 未重构 context 时保留 system prompt 快照不重注入（上下文缓存命中率不受影响）
- [ ] 中途 select 的 Spec 于下次重构生效；read 立即返回全文
- [ ] easy-task 执行中超阈值/跨文件/不确定时切换 complex-task
- [ ] complex-task 先 search spec、建 todo、按可并行度指派成员（update_member+assign_task）、无 spec 时 create 沉淀
- [ ] hard-task 走会议 + 企业级流水线（每阶段产出物+评审）、高危 AskUserQuestion 确认、末尾强制补 spec
- [ ] 前端 Spec 面板：浏览/搜索/多选挂 hook，用户经 UI 操作（非裸 API），展示已选与生效时机
- [ ] 创建 TOP agent 即全量建队：预建全部成员（200+ 名字池取名、标准角色模板、职责留空、状态 idle）、初始化 `workspace/<agent id>/`、登记团队与名单
- [ ] team 工具无 create_member；有 update_member（改成员信息并触发名单推送）
- [ ] 成员拓扑（TOP + 全体成员 name/role/duty/model_id/status）常驻每位 teammate 的 system prompt
- [ ] TOP 经 update_member 修改成员信息后，该 TOP 下所有 agent 收到更新后的名单（触发 context 重构）
- [ ] team send_message/assign_task 支持 top 内按 name 寻址（基于拓扑），解析失败错误信息明确
- [ ] 跨 Top 顶层寻址按 TOP agent name（用户透露，top-to-top）；跨 top 消息可投递且回复按 source_agent_id 回发
- [ ] 跨 TOP 成员名单不传递（有单测）；跨用户寻址一律拒绝（有单测）
- [ ] list_teams 动作 + `GET /api/teams` 返回本用户名下全部团队（供 TOP 熟悉其他 TOP）
- [ ] agent 名称（含 TOP 与成员）同用户全局唯一（冲突拒绝）

## P5 thinking
- [ ] 模型配置 `thinking: true` 时流式解析 reasoning_content（兼容 reasoning 字段）
- [ ] WS 推送 thinking 段（msg_start kind=thinking + chunk + end）
- [ ] 带 thinking 的 assistant 消息回写上下文时保留 reasoning_content
- [ ] thinking 段持久化，历史重载可见
- [ ] 前端 ThinkingCard 默认折叠（思考中动效/时长/首行摘要），点击展开 markdown
- [ ] `thinking: false` 模型不产生 thinking 段

## P6 收尾
- [ ] 新增单测全绿：会话/三模式/Spec/跨top/thinking
- [ ] `git status` 无运行时产物（workspaces/、tmp/、server/workspaces/、.output/、*.db 已 ignore 或清理）
- [ ] 一次性脚本（probe/*.sh、server/_*.py、tmp/repro*）已清理
- [ ] server/README.md 与新目录结构一致
- [ ] `python server/main.py` 启动无报错，`flutter analyze` 无新增告警
