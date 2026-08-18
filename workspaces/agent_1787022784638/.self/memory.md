# 记忆文档 (memory.md)

## 任务记录

### 2026-08-18 · 任务：Tree 项目 team 工具可用性全面诊断

**任务目标**：
- 全面检查并诊断 Tree 项目 team 工具的可用性（从代码中诊断），用户实测 team 工具不稳定。

**关键决策**：
- 用 help/mcp(help) 了解工具，先用 terminal 实测环境，发现 terminal 运行在 Windows cmd 环境（`ls` 不可用、提示为 cmd），而非预期的 Linux/Docker。
- 采用「静态代码审查 + 运行时实证」双管齐下：通读 team_tool.py / team_broker.py / agent_store.py / docker_manager.py / main.py / local_executor.py / workspace_io.py / routes.py / 前端 local_executor_service.dart，并实际 docker exec / 本地文件检查验证。
- 编写辅助 Python 脚本（slice_file/grep_lines/locate_methods 等）在 Windows 上绕过 cmd 引号嵌套问题读取大文件。

**遇到的问题及解决方案**：
1. **terminal 工具实际在 Windows cmd 环境**：工作目录为 `E:\programs\Tree\flutter_application_tree\flutter_application_tree`，`ls` 报“不是内部或外部命令”。
   - 解决：改用 Windows 命令（dir/type/findstr）+ 编写 Python 脚本（写 tmp/*.py）执行复杂分析。
2. **read 工具路径校验**：只允许字母数字与 `/_-.` 字符，Windows 绝对路径（含 `\`）被拒；改用相对路径 `server/core/xxx.py` 成功。
3. **cmd 引号嵌套**：`python -c "..."` 中引号嵌套导致 SyntaxError；改用 `tmp/*.py` 脚本 + `python tmp\xxx.py` 执行。
4. **python -c 引号转义**：所有需 Python 内联执行的逻辑改为写脚本文件。

**重要结论（team 工具诊断）**：
- 环境事实：Windows 10 + Docker Desktop（后端 venv docker SDK 7.2.0 可用）；后端运行中（PID 136824，:8000）；本地执行器已注册（MCP terminal 返回 Windows 结果）；`shutil.which("sh")`=None；Git 在 `D:\Download\Git`，但 `_resolve_sh` 只探测 C 盘固定路径。
- **架构级问题（最严重）**：team 工具与 LLM 工具“双轨制”。LLM 工具（read/write/terminal）在本地模式经 LocalWorkspaceIO → 反向 WS → 本地目录；team 工具内部（_save_roster/_load_roster/_write_member_identity/git_log/view_member_output/send_file/_append_activity_log）一律走 `docker_manager.exec_in_workspace` → Docker 容器（可用时）或 server/workspaces（不可用时）。两者物理隔离：roster 写容器、LLM 读本地；成员 Git 提交在本地、team 查容器。
- **共享成员 roster 路径不一致**：`_rewrite_private_tokens` 对共享成员把 `.self` 重写为 `workspaces/{member_id}/.self`，leader 写 roster 不重写 → 成员永远读不到 leader 写的 roster（已实证）。
- **逻辑 bug（已实证）**：
  1. `_action_broadcast` 从不调用 `_dispatch_to_member` → 广播收不到。
  2. `complete_task` / `report_task_completion` 未注册进 `execute()` 的 dispatch（仅 14 个 action）→ 任务永远 pending，成员永远 working。
  3. `_action_wait_for` 轮询 leader TeamTool 内存 work_status，但成员完成时仅发 WS 事件（_send_status_idle）+ 清 _active_tasks，无代码更新 leader 内存 → wait_for 必然超时。
  4. `_action_create_member` 中 `getattr(self, "member_id", None)` 恒为 None（TeamTool.__init__ 未设置 self.member_id）→ can_lead_team 联动是死代码。
- **Windows/本地适配问题**：`_resolve_sh()` 找不到 sh（实测 None）；native fallback 不支持 tail（view_member_log 依赖）等命令；exec_in_workspace 本地分支 base64 误判、native fallback 正则不匹配多行 base64。
- **次要问题**：TeamTool 内存无锁；tasks/messages/work_status 不持久化；成员→leader 消息走错 broker（_team_broker 而非 _top_chat_broker）；routes 队友消息 _parse_roster_table 只有 7 列缺 system_prompt；_parse_roster_md 硬编码 workspace_id=member_id、can_lead_team=True；共享成员 rebuild 不彻底。
- **修复建议（优先级）**：① 统一工作空间访问层（team 工具改用 WorkspaceIO）；② 修复 roster 路径一致性；③ 广播补投递；④ 任务闭环（注册 action + 同步 work_status）；⑤ wait_for 改轮询 _active_tasks；⑥ 修复 can_lead_team 联动；⑦ _resolve_sh 动态探测 + native fallback 补 tail；⑧ TeamTool 加锁；⑨ 成员→leader 消息路由修正。
- 完整报告已保存：`docs/team_tool_diagnosis.md`。

### 2026-08-18 · 第二轮补充审查（用户反馈后深化）

**用户反馈与修正**：
- 用户指出“roster 路径不一致”是误判：`.self` 空间本就应独立，成员读自己空间 roster 为空是正确行为。已修正（从 bug 移除，真正问题是双轨制）。
- 用户指出“teammate 无法向 team leader 发消息（路径未阻塞，但无法查询 leader 的 agent id）”——深挖确认是 4 层断裂。

**成员→Leader 消息链路 4 层断裂（实证）**：
1. 查不到 leader id：team 无 query_leader action；help 身份区对成员不透出 leader；唯一途径是成员主动 read .self/identity.md。
2. 即使知道 id 也被静默丢弃（实证）：_action_send_message 向 leader 发送时 target 字典 model_id="" → _process_member_message 中 _model_configs.get("")=None → “成员模型不存在” → return；dispatched:True 但实际不处理。正确做法从 get_agent(user_id, leader_id) 取 model_id。
3. 走错 broker：所有 TeamTool 绑 _team_broker，成员→leader 消息投递到 _team_broker，与用户消息的 _top_chat_broker 并发 → 并发操作同一 session，破坏 leader 串行。
4. 回复不回投：_process_member_message 处理后回复只写 leader 历史 + 推 WS，无机制投回成员 → 单向通信。

**新实证**：
- Leader 容器 workspace_agent_1787015498656 的 .self/team_roster.md 存在，3 名成员 work_status 全部卡在 working（任务闭环断裂直接证据）。
- 共享成员 Git 提交与 leader 主工作区混合：leader 容器 /workspace 是单一 git 仓库（term_probe1.txt/.output/.self/workspaces 全混），无成员级 Git 隔离，与 docs/team_structure.md 声称“Git 隔离”矛盾；git_log(member_id) 解析到 leader 容器。
- leader_name 恒为 "self"（实证）：AgentLLMSession 无 agent_name 属性 → _leader_name() 恒返回 "self"，identity.md 中 team_leader: self (agent_id) 名称丢失。
- send_file 只写文件不通知成员：文件复制成功但成员收不到到达通知、不触发处理。
- 前端 teammates_window_page.dart 只有“用户→成员”发消息入口，无成员→leader 入口。

**修复建议补充（成员→Leader 链路）**：
- 新增 query_leader action 或在 help 身份区透出 leader_id；
- _action_send_message 向 leader 发送时从 get_agent() 取 model_id；
- 成员→leader 消息路由到 _top_chat_broker（复用 leader 串行队列）；
- leader 回复后经 broker 回投成员。

**后续待办/提示**：
- 用户尚未要求实施修复；若后续修复，建议从“统一 WorkspaceIO”开始。
- 诊断脚本已清理（tmp/ 下临时脚本已删）。
- 注意：本 agent 私人空间为 `workspaces/agent_1787022784638/.self`（本地模式），与 `workspaces/agent_1787008529546`（团队 Leader 的私人空间）不同。

### 2026-08-18 · 第三轮：team 工具改造实施（8 项需求落地 + 状态机修正）

**任务目标**：将前两轮诊断结论落地为实际改造，按用户 8 项需求实施：
1. teammates 与顶部 agent 统一 update memory 流程；
2. update memory 加锁（含顶部 agent），期间 User/Teammates/Team Leader 均无法发消息；
3. update memory 门控：工具调用次数达到 7 次才触发，累加器落盘、更新后清零、各 agent 隔离；
4. terminal 改为内置 tool（避免 MCP 嵌套解析错误）；
5. list_members 分组列出有关系的 agent（team_leader / teammates / team_member）；
6. 取消 send_file（leader 与 teammates 共享工作目录 base）；
7. 封装节点间消息发送 API（一对多、User-Agent 与 Agent-Agent 收敛、顶部 agent 团队隔离）；
8. 成员工具循环最后一次回复 content 自动回发对应 leader。

**关键决策与实现**：
- **统一消息 API**：新增 main._dispatch_agent_message(user_id, target_ids, content, source_agent_id, top_agent_id, system_prompt, extra)。用户消息（_dispatch_user_message）、teammates 路由（send_teammate_message）、team 工具 send_message/broadcast 全部收敛到此出口；target_ids 支持字符串或列表（原生一对多）；顶部 agent 走 _top_chat_broker、成员走 _team_broker；跨顶部 agent 隔离（仅上级 leader/直属成员/同旗下成员可达）；入口统一做 _is_memory_updating 锁检查。
- **memory 门控与锁**：conversation_store 新增 agent_tool_count 表（(user_id, agent_id) 主键，各 agent 隔离），get/increment/reset_tool_count；_run_memory_update 入口检查计数达到 7 才触发；_memory_updating 集合 + _lock/_unlock/_is_memory_updating；_stream_agent_reply 每次 tool_call 递增（silent 模式不计）。
- **terminal 内置化**：新建 server/tools/terminal_tool.py（基于 WorkspaceIO，云端容器/本地目录统一），从 mcp_tools/server.py、本地 handler、tool_defs 移除 terminal 暴露。
- **list_members 分组**：_action_list_members 返回 groups: {team_leader, teammates, team_member}，新增 _lookup_agent_by_id（agent_store）与 _load_roster_of（读上级 roster）。
- **send_file 取消**：从工具 enum 与 dispatch 移除；方法保留但直接返回已取消（共享工作目录）。
- **成员回复回传 leader**：_process_member_message 完成后把 full_reply 经统一消息 API 回传 leader_id（前缀 [成员 xxx 完成回复]）。
- **状态机修正**：用户指出 update memory 不应回跳 working，删除 _run_memory_update 内两处 _send_status_working（skip 分支与 finally），最终状态流为 working → updating_memory → idle（idle 由两个调用方 finally 发送：成员 1120 行 / 顶部 agent 1566 行）。

**遇到的问题及解决方案**：
1. MCP 工具调用参数嵌套歧义：edit 调用反复失败（action 误放入 arguments / tool_name 顶层缺失），最终改用「write 写规则脚本 + terminal 执行」批量精确替换（tmp/rule_*.py），规避解析问题。
2. write 工具偶发 file_path 不能为空：内容过长或含特殊字符时触发；拆小步骤 + 首次失败重试可稳定通过。
3. 统一消息 API 初版测试发现 2 处缺陷：用户→成员时 leader_id 为空（改为 source_agent_id or top_agent_id）；成员查找应基于顶部 agent 而非发送方（top_agent_id or source_agent_id）。已修复并复测。
4. 前端 teammates_window_page.dart 无成员→leader 入口（前两轮已发现）：本轮未改前端，成员→leader 已由统一 API 支持（leader_id 经 agent_store 补齐 model_id，修复原静默丢弃 bug）。

**重要结论**：
- 本轮修复了前两轮诊断的多个根因：成员→leader model_id 丢失（静默丢弃）、broadcast 不投递、send_message 一对多、跨顶部隔离、memory 期间消息竞态。
- 统一消息 API 成为 User-Agent / Agent-Agent 的唯一出口（收敛出口），团队隔离与 memory 锁在出口统一实施。
- 双轨制仍未彻底统一：team_tool 内部 roster/日志仍直调 docker_manager；本轮完成 terminal 统一与 WorkspaceIO 抽象扩展（新增 git_log/list_files），全量迁移留待后续迭代。
- 功能测试（stub broker/roster）全部通过：用户→成员、成员→leader（model_id 修复）、跨顶部拒绝、leader→多成员一对多、成员→同级、memory 锁拒绝。

**验证与文档**：
- 8 个修改文件 ast.parse 全部通过；import main OK；inspect.getsource(_run_memory_update) 断言无 _send_status_working。
- 修改文件：server/main.py、server/tools/{team_tool,terminal_tool,__init__,help_tool}.py、server/core/{workspace_io,conversation_store}.py、server/mcp_tools/server.py。
- 改造记录：docs/team_tool_refactor.md。
- 临时脚本已清理（tmp/*.py）。

### 2026-08-18 · 第四轮：工作空间基础工具全部内置化（read/write/edit/terminal）

**任务目标**：用户要求把 write/edit/read 也改为内置 tool（第三轮已完成 terminal 内置化），彻底消除 MCP stdio 嵌套解析错误。

**关键决策与实现**：
- 新建 server/tools/read_tool.py / write_tool.py / edit_tool.py（内容与旧 mcp_tools 版一致，均基于 WorkspaceIO；edit 复用内置 read/write）。
- tools/__init__.py：import 改内置版本；本地 in-process handler 与 tool_defs 仅保留 embed_search；注册循环加入 read/write/edit/terminal 四个内置工具（顺序：help, set, refresh, mcp, read, write, edit, terminal, team, ask_user_question）。
- mcp_tools/server.py：workspace stdio server 仅保留 embed_search（docstring 已更新）。
- 删除旧文件：mcp_tools/read_tool.py / write_tool.py / edit_tool.py / terminal_tool.py（全量扫描确认无残留引用）。

**遇到的问题及解决方案**：
- 旧 mcp_tools/edit_tool.py 内部自引用 read/write（仅自身引用，无外部依赖）→ 确认可安全删除。
- 写入大文件偶发 file_path 不能为空 → 拆小步骤 + 重试（沿用第三轮经验）。

**重要结论**：
- 四个工作空间基础工具与 LLM 工具循环同进程直连，彻底消除 MCP stdio 子进程嵌套解析错误。
- WorkspaceIO 抽象保证云端容器 / 本地目录双轨行为一致；mcp/refresh 工具保留用于接入第三方 MCP 服务。
- 双轨制遗留：team_tool 内部 roster/日志仍直调 docker_manager（尚未迁移到 WorkspaceIO），留待后续迭代。

**验证**：
- import main OK；8 文件 ast.parse 通过；工具注册列表实测含 read/write/edit/terminal；
- 功能实测（stub WorkspaceIO）：read 读取、write 写入、edit 精确替换+唯一性校验、terminal 执行全部通过。
- 修改文件：server/tools/{read_tool,write_tool,edit_tool}.py（新增）、server/tools/__init__.py、server/mcp_tools/server.py；删除 mcp_tools 下 4 个旧工具文件。
- 文档已更新：docs/team_tool_refactor.md（第 3 节改为“工作空间工具全部内置化”）。

### 2026-08-18 · 第五轮：系统重启后自由体验新架构（实测验证）

**任务目标**：系统重启后，用户要求自由体验新架构（前四轮改造已全部落地）。

**实测验证结果（全部通过）**：
1. **工具内置化生效**：`refresh` 后 MCP 工具列表从 12 项收敛为 **8 项**（仅 embed_search + 7 个文档工具）；read/write/edit/terminal 已在 LLM 工具循环内直接可用，全程无 MCP 嵌套解析错误。
2. **memory 门控落盘运转**：`agent_tool_count` 表存在；本轮计数从 8 → 25 → **29**（每次工具调用实时递增，silent 模式不计）；**记忆维护闭环已实际运转过一次**——memory.md 上次更新于 12:48:44（第四轮总结），说明第三轮“触发→更新→清零→重新累积”链路在真实运行中验证通过。
3. **list_members 分组生效**：返回 `groups: {team_leader, teammates, team_member}` 结构；独立顶部 agent 三组皆空，符合隔离预期。
4. **send_file 取消生效**：team 工具 action 列表已无 send_file。
5. **跨团队隔离生效**：向 leader（agent_1787008529546）的成员 member_1787016828_x3clpa 发消息 → `rejected`（无关系 agent 不可达）。
6. **工作空间双轨一致**：本地 `workspaces/` 下 agent_1787022784638（我）与 3 名成员 .self 独立；各成员 memory.md 记录各自任务，健康。
7. **后端重启正常**：端口 8000 监听；6 个 agents 记录完好。

**附带发现（非本次改造问题，双轨制遗留）**：
- 团队 Leader `agent_1787008529546` 的 `.self` 下**缺少 team_roster.md**（只有 identity/memory/rule），但其 identity.md 声称已组建 3 名成员（member_1787016828_x3clpa / 7xql6q / ij3yml）。疑似双轨制遗留：roster 曾写入 Docker 容器路径而非本地 workspaces；或 leader 会话重建 TeamTool 后 roster 尚未重建。成员 workspace 与 memory 均存在。**后续迭代候选：team_tool 内部 roster/日志访问从 docker_manager 直调迁移到 WorkspaceIO（统一双轨制）**。

**验证方法沉淀**：
- `refresh` + `mcp(help)` 看工具列表数量：12→8 即可快速确认内置化改造是否生效（低成本回归验证手段）。
- `sqlite3 server/data/conversations.db "SELECT * FROM agent_tool_count"` 直接看各 agent 工具计数，验证门控累积/清零。
- 检查 `.self/memory.md` 的 mtime 与 md5 判断记忆维护是否触发（基线/后验对比）。

**本轮触发的记忆维护**：工具计数 29 ≥ 7，本次回复进入 update memory 阶段（working → updating_memory → idle），完成后计数清零。

### 2026-08-18 · 第六轮：实测 team 工具组队 + 双轨制统一 + 执行模式注入

**任务目标**：用户要求先看 memory update 实现，然后实测 team 工具是否可用，并组一支维护团队（"以后就一起维护项目了"）。

**memory update 审查（_run_memory_update, main.py:549）**：
- 门控：get_tool_count < 7 跳过；≥7 触发，完成后 reset_tool_count 清零（各 agent 隔离、落盘 agent_tool_count 表）。
- 锁：_lock_memory_update 防重入；5 处入口拦截（顶部 agent 消息 980、teammates 路由 1188、team 工具 1270、broker 1314、用户投递）。
- 状态机：working → updating_memory → idle（不回跳 working；idle 由调用方 finally 发送）。
- 上下文接近上限（≥0.9*max_seqlen）时跳过记忆维护，避免超长输入卡死。

**组队实测（全部通过）**：
- list_models 4 项；create_member 创建 3 名成员成功（member_1787028983_gj0jap 后端 / member_1787028988_kcihfd 前端 / member_1787028988_nswajn 测试，均 deepseek-v4-flash-official）。
- list_members 分组生效：3 名全部归入 teammates 组。
- send_message 投递成功，成员真实执行工具循环（help/terminal/read/mcp 多轮），最终回复经回传链路送达 leader（[成员 xxx 完成回复] 前缀）——**成员→leader 闭环实测可用**。
- 发现字段缺陷：roster 表只有 7 列（缺 system_prompt/can_lead_team）→ 成员 can_lead_team 显示 True（默认值）、system_prompt 为空（第一轮诊断的 _parse_roster_table 缺列问题，双轨制遗留）。

**组队暴露的双轨制问题（关键）**：
- Docker 容器真实存在（03efdf117367...），成员工作空间建在容器 /workspace/workspaces/{id}/.self（identity/rule/activity 都有，缺 memory.md）。
- 但成员工具走本地执行器（baseDir=项目根）→ 成员 read .self/identity.md 报"文件不存在"，误读到 leader（我）的 identity，一路猜路径。
- 前端 LocalExecutorService._resolveWorkspaceDir：私人 .self → baseDir/workspaces/{id}，工作文件 → baseDir（本地模式）；但后端 TeamTool 的 roster/身份读写仍直调 docker_manager → **双轨制在组队场景的实证**。

**terminal 长命令稳定性实测（cmd 固有行为，非内置化 bug）**：
- `&&` 多命令、引号/中文、括号分支、dir|findstr 管道：正常。
- `python -c "print(123)"` → exit 0 但**无输出**：cmd /c 不剥离引号，python 收到 `"print(123)"`（带引号代码=表达式求值无副作用）。
- `cmd /c "python -c \"print(123)\""`（Dart 转义）→ 系统找不到路径。
- **exec_argv 直接 argv 传递稳定**（`python -c 'print(123)'` → 123）：引号问题可用 argv 绕开。

**用户灵魂拷问："为什么你作为 leader，工作环境在本地还是沙箱都分不清？" → 根因：执行模式信息从未注入**：
- _SYSTEM_PROMPT（main.py:78）固定两句话，无执行环境；_build_workspace_extra_info（321）只注入 identity/rule/storage_warning；前端 base_dir 注释明写"仅供后端记录/展示，不参与路径映射"。
- 我和成员全靠调用 terminal 猜自己在哪（成员更惨：空间在容器、工具走本地，猜都猜不到）。

**修复 1：执行模式注入（main.py）**：
- 新增 _build_exec_mode_text()：按 local_executor.is_local(mode_key=top_agent_id) 判定，注入"本地（工作目录 base；私人空间 .self 在 base/workspaces/{id}/.self；团队共享 base）"或"云端沙箱（容器路径）"。
- _build_workspace_extra_info 增加 exec_mode 字段，成员/顶部 agent 两个调用点传参；本地/云端/None 三种场景 stub 验证通过；import main OK。

**修复 2：双轨制统一（TeamTool 注入 WorkspaceIO）**：
- team_tool.py __init__ 增加 io 参数；新增 _io_write/_io_read 辅助（优先 io，回退 docker exec）。
- 新增 _init_member_private_space()：create_member 时初始化成员 .self（rule/memory/activity），本地模式落到 baseDir/workspaces/{id}/.self。
- _write_member_identity/_save_roster/_load_roster/_load_roster_of 全部优先走 io。
- tools/__init__.py register_builtin_tools 传 io=io。
- 10 条规则全部成功，ast.parse 通过；stub 测试通过（成员能读到自己 identity、roster 落 leader 本地、重建 TeamTool 能加载 roster）。

**遗留/待办**：
- 已建 3 名成员空间仍在容器（03efdf...），本地模式下与工具路径分离 → **建议重启后端后重建成员**（本地模式 create_workspace 走本地路径，配合新注入完全一致）。
- 成员 identity 中 can_lead_team 显示"是"（roster 缺列默认 True）——若需准确，roster 表需扩展列或成员信息存 agent_store。
- help 对成员仍注入"顶层 Agent"身份（help_tool 未按成员渲染身份区），成员误以为自己是顶层；待后续迭代修正 help 身份区按 level 渲染。

### 2026-08-18 · 第七轮：compact 后 help 信息是否保留的审查

**用户问题**：compact 后 help 的信息（含刚注入的 exec_mode）还留得住吗？是否上下文丢失？

**审查结论：留得住，且不是上下文丢失**：
- **workspace_extra_info（身份/rule/exec_mode）存放在 HelpTool 实例属性上**（help_tool.py 构造时传入，`self.workspace_extra_info`），不在 LLM context 里。
- **compact（llm.py:657-720 compress）只重组 self.context 消息列表**：`self.context = system_msgs + [summary_msg] + to_keep`，并重置 `_last_prompt_tokens` 锚点。完全不碰 `registered_tools`、HelpTool 实例、workspace_extra_info。
- 因此 compact 后：help 工具定义还在（每轮 chat 的 tools 参数照常暴露）；重新调用 help 时 `execute()` 从 workspace_extra_info **现读**身份/rule/exec_mode 原样返回。
- "信息丢了"的感觉来自：compact 把**之前 help 输出的文本**（作为历史 tool result）总结进 summary——若 agent 不重新调 help，工作记忆里不再有 exec_mode 细节。但这正是 help 设计：机制性信息靠"随时可重新获取"而非"上下文残留"（这也是系统提示词"先调用 help"的原因）。

**边界**：
1. **快照语义**：workspace_extra_info 是会话构造时计算的一次性快照；运行中 identity.md/rule.md 被改，compact 后 help 读的是旧快照（需会话重建刷新）——不是丢失，是快照设计。
2. **会话重建更保险**：clear_user_agent / update_member 重建会话会重新计算 workspace_extra_info（重新读文件 + 重新注入 exec_mode），反而更新鲜。

**关键洞察**：把身份/rule/exec_mode 放 help 而非系统提示词，是"即取即用"设计——系统提示词会被 compact 保留但会无限膨胀；help 是动态获取。exec_mode 属于 workspace_extra_info，compact 与会话重建两种场景都能被 help 重新调出，不会消失。

**本轮待办提醒**：此前 main.py / team_tool.py 的修改（exec_mode 注入 + TeamTool 注入 io + _init_member_private_space）需**重启后端才生效**；已建 3 名成员空间在容器，本地模式建议重启后重建。

### 2026-08-18 · 第八轮：help 永久保留特权（最贴近系统提示词的那次）

**用户需求**："你这么久我就没看你调用过 help，要不给 help 一个额外特权，最接近系统提示词的那次 help 调用永久保留。"（先问"compact 后 help 的信息还留得住吗"，第七轮确认留得住但依赖重新调用；用户进一步要求把最近系统提示词的 help 调用做成 compact 豁免，作为常驻环境基线。）

**关键约束（OpenAI API）**：tool 消息必须紧跟对应 assistant 消息，所以 help 调用必须**成对保留**（assistant tool_call + 对应 tool 结果），不能只留 tool 结果。

**实现（llm.py compress，2 处修改）**：
1. **剥离 help 块**：在压缩前扫描 other_msgs，识别 role=assistant 且 tool_calls 含 name=="help" 的消息，连同其后紧随的 role=tool（tool_call_id 属于该 assistant）组成 help 块；从 to_summarize/to_keep 中剔除。
2. **只保留一次**（用户二次收紧"要那么多 help 干啥"）：`kept_help = help_blocks[0]` —— 只取**最靠前（最贴近系统提示词）**的块；其余 help 块按普通消息处理（可总结区总结、保留区留存）。避免多个 help 输出在上下文反复堆积膨胀。
3. 重组：`self.context = system_msgs + [summary_msg] + kept_help + to_keep`（help 块紧跟总结、位于最近任务之前，顺序合理）。

**测试验证（构造真实形态上下文，monkeypatch _summarize_with_llm）**：
- 场景：系统提示词 + 最早 help（特权）+ 任务0（内含第二次 help，应总结）+ 任务1/2/3（保留）。
- 压缩后：SUMMARY 总结了第二次 help + 任务0；最早 help 调用对完整保留（tool 内容含 exec_mode）；任务1/2/3 保留。
- 断言全过：仅最早 help 保留、第二次 help 被总结、任务0 被总结、最近任务保留、总结位置正确。
- ast.parse OK、import main OK、LimitlessContextSession.compress 不受影响（no-op 不变）。

**效果**：compact 后上下文永远只有最早那次 help（环境基线：执行模式/身份/工具机制），不会堆积多个 help 膨胀上下文；agent 即使从不重调 help，核心环境认知也常驻。

**待办提醒（延续）**：main.py（exec_mode 注入）/ team_tool.py（io 注入）/ llm.py（help 保留）三处修改均需**重启后端生效**；已建 3 名成员空间在容器（03efdf...），本地模式建议重启后重建（配合新注入路径一致）。

### 2026-08-18 · 第九轮：memory.md 是否自动注入的审查（发现"只写不读"半闭环）

**用户灵魂拷问**："memory 每次更新，也没看你看过啊，会自动注入上下文吗？"——质疑记忆维护闭环是否真的把写下的记忆带回 agent 认知。

**审查结论：不会自动注入，用户观察正确**。记忆维护是**只写不读的半闭环**：
- ✅ **写**：工具计数 ≥7 → update memory → 写入 .self/memory.md → 清零（链路完整）。
- ❌ **读**：**没有任何机制把 memory.md 带回上下文**。compact 后长期记忆等于不存在，这也是"每轮维护后还在重复踩坑"的原因。

**证据链（代码确认）**：
1. **注入链只有两条，均不含 memory**：
   - system prompt（main.py:78 _SYSTEM_PROMPT）：固定两句话，不含任何文件。
   - help 的 workspace_extra_info（main.py:361 _build_workspace_extra_info）：只注入 exec_mode / **identity.md**(391) / **rule.md**(402) / storage_warning(409)，**没有任何一行读 memory.md**。
2. **llm.py 不读 .self 文件**：全文件仅 context_snapshot.json（会话恢复快照），无 memory 注入；compress 只重组 LLM context 消息列表，不注入任何 .self 文件。
3. 因此唯一看到 memory.md 的方式是 agent 主动 `read .self/memory.md`——而我（和其他 agent）从未读过。

**附带认知**：rule.md / identity.md 能"常驻"是因为它们进了 help 的 workspace_extra_info；memory.md 被漏掉，导致三份记忆文档注入待遇不一致。

**修复选项（已向用户提出，待决策）**：
1. **全量注入**：memory 加进 _build_workspace_extra_info，help 全量返回——改动最小，但 memory.md 渐长，help 输出膨胀吃 token。
2. **索引注入**（推荐）：只注入各轮记忆的**标题+日期清单**（轻量恒定），agent 需要细节时主动 read .self/memory.md——成本低、保证 agent 知道"有哪些记忆、去哪读"。
3. **最近 N 条 + 更早索引**：折中，最近 2 轮完整、更早只留标题。

**待办**：等用户选择修复方案后实施；若选方案 2，改 _build_workspace_extra_info 增加 memory_index 字段（解析 memory.md 的 `### 日期 · 标题` 行）。

### 2026-08-18 · 第十轮：memory 全量注入 help（<4k 压缩）+ help 刷新机制 + compact 长度实测

**用户拍板**："全量注入+memory总大小限制（memory.md<4k），超出发系统提示词压缩。那另一个问题：compact 后保留最早 help，那 memory 更新也加不进去啊，要不 compact 保留的同时刷新一下 help 内容。"

**实现（3 文件，已接线验证）**：
1. **main.py**：
   - 常量 `_MEMORY_INJECT_LIMIT = 4096`（字符）；`_memory_compress_cache: {workspace_id: (md5指纹, 压缩文本)}`。
   - `_compress_memory_text()`：优先 LLM 压缩（默认模型，temperature 0.2，max_tokens 1024，prompt 要求 4000 字内中文摘要），失败回退"保头保尾截断"（头 1800 + 尾 1600）；带 md5 指纹缓存，memory 未变化时直接复用，避免每次 help 重复触发 LLM 压缩。
   - `_build_workspace_extra_info` 增加 memory 注入：≤4k 全量，>4k 压缩后注入 `info["memory"]`。
   - `_register_tools` 新增 `member_system_prompt` 参数 + `_extra_info_refresher` 闭包（现读现算 extra_info），传给 register_builtin_tools；成员 2 处调用透传 member_system_prompt。
2. **help_tool.py**：`__init__` 新增 `refresh_extra_info` 回调；`execute()` 每次执行前调用刷新 `self.workspace_extra_info`（memory.md 每次记忆维护都更新，快照必过期）；`_build_workspace_info_section` 增加 `## 记忆档案 (memory.md)` 板块（rule 之后、存储告警之前）。
3. **tools/__init__.py**：`register_builtin_tools` 新增 `extra_info_refresher` 参数并透传给 `HelpTool(refresh_extra_info=...)`（已补接线）。

**验证**：3 文件 AST parse OK、import main OK、HelpTool 参数含 refresh_extra_info。

**用户追问："但 help 在最前面，更新意味着前缀缓存失效，compact 后上下文长度能压到多少？" → 实测分析**：
- **.self 现状**：memory.md **17553 字符（~8.8k tokens）**、rule.md 4.2k、identity.md 1.7k；memory 远超 4k 上限走压缩（注入 3418 字符 ≈ 1.7k tokens）。
- **完整 help 输出 14166 字符（~7.1k tokens）**，其中工作空间信息板块 9366 字符（~4.7k，含 identity+rule+memory）是大头；其余板块：身份 0.2k / 工具机制 0.8k / 系统机制 1.1k / 用户期望 0.2k / 工具清单 0.06k。
- **compact 后上下文估算（当前 agent 真实历史）**：system 0.2k + summary ~1k（719 条旧历史 22k tokens 被总结）+ kept_help 7.1k + to_keep 3.8k（最近 3 轮 126 条）≈ **12.1k tokens**；对比全量 26k，压缩比干净。
- **max_seqlen=204800、压缩阈值 163840**：compact 后 12.1k 仅占阈值 7%，**无"压缩后立刻又压"死循环风险**。
- **前缀缓存结论（用户顾虑核心）**：compact 本身用新 summary 替换全部历史，无论 help 刷不刷新，compact 后整个上下文都是全新排布、前缀必然全失效 → **"compact 时刷新 help"与 compact 固有失效完全重叠，额外成本 = 0**。compact 后到下次 compact 之间 help 块固定，前缀稳定，DeepSeek 硬盘缓存正常命中（命中部分 10% 价格）。
- **稳态成本**：help 块 7.1k tokens 每轮携带（命中时约 0.7k 等价；compact 后首轮全量）。

**优化建议（已提出，待用户确认）**：
1. memory 注入上限 4k → 2k（当前压缩后 3.4k 仍偏大，help 块 7.1k 中 memory 1.7k + rule 2.1k 占过半）；
2. rule.md 也加限长压缩（现 4.2k 字符全量注入无限制）；
3. （可选）compact 保留 help 时只保留精华板块（exec_mode/identity/rule/memory），丢弃静态工具机制/系统机制说明（需要时可重调 help 获取）。

**重要待办（用户需求未完成部分）**：
- **compact 时重渲染 kept_help 块内容未实现**：用户要求"compact 保留 help 的同时刷新 help 内容"。当前实现只覆盖 **help execute 时现刷**（agent 重调 help 拿到最新 memory）；但 compact 保留的"最早 help 块"是历史消息文本，compress 不会自动重渲染。要让 compact 后常驻 help 反映最新 memory，需给 session 绑定 help 渲染回调（main 层提供），compress 时若有 kept_help 用最新渲染替换 tool 内容——**待实施**。
- 优化建议 1/2/3 待用户拍板。

**本轮代码状态**：memory 注入 + execute 刷新已可运行（AST/import 验证过）；compact 重渲染与优化未做，后端重启后生效（memory 注入随 extra_info 每次 help 现算）。

### 2026-08-18 · 第十一轮：最终落地——rule.md 限长 + help 刷新收敛到 compact + compact 重渲染 kept_help

**用户最终拍板（修正第十轮中间方案）**："给 rule.md 也设限（<4k），只要 compact 后上下文长度本身就不长，那注入影响不大。**注意所有的 help 信息刷新都是在 compact 触发上下文重构时发生**。"

**关键转变**：第十轮的"execute 每次现刷"方案被推翻——help 块作为历史消息留在上下文中，若每次执行都变内容，会**破坏前缀稳定性、频繁失效 KV 缓存**。最终改为：**平时 execute 用快照（内容不变、前缀稳定利于缓存命中）；只在 compact 触发上下文重构时刷新 help 块（此时前缀必然重排，刷新零额外成本）**。

**实现（4 文件，全部落地 + 测试通过）**：
1. **main.py**：
   - `_MEMORY_INJECT_LIMIT` → `_SELF_DOC_INJECT_LIMIT = 4096`（memory/rule 统一上限）。
   - `_compress_memory_text` 泛化为 `_compress_self_doc(workspace_id, doc_key, text, kind)`，缓存键 `{workspace_id}:{doc_key}`（md5 指纹）。
   - **rule.md 注入同样设限**：≤4k 全量，>4k 压缩（`_compress_self_doc(..., "rule.md", "工作准则")`）。
   - memory 注入改用新函数（当前 memory.md 20281 字符 → 压缩 3425；rule.md 4863 → 3426）。
2. **help_tool.py**：`execute()` **移除每次自动刷新**（保留快照）；新增 `render_fresh_content()`（刷新 extra_info + 重渲染），**专供 compact 调用**。
3. **tools/__init__.py**：构造 HelpTool 传 `refresh_extra_info`；绑定 `session.help_refresh_callback`（调 `render_fresh_content()`，返回新 assistant(tool_call=help)+tool(result) 消息对，保证 OpenAI tool_call 配对约束）；无回调时压缩保留旧块。
4. **llm.py compress**：保留最早 help 块后，若 session 有 `help_refresh_callback` → 用最新渲染替换 kept_help（try/except 失败沿用旧块）。

**测试验证（test_help_refresh.py 全过）**：
- 平时 help execute：用快照（rule v1、无 memory），**refresh 回调调用 0 次**——前缀稳定 ✅
- compact 触发重构：刷新回调被调 1 次，help 块替换为 rule v2 + 最新 memory ✅
- 旧 help 块被替换无残留、tool_call 配对约束满足 ✅
- `_compress_self_doc` 指纹缓存验证：同内容二次压缩实际调用 1 次（不重复触发 LLM）✅
- 4 文件 AST parse OK、import main OK ✅

**长度实测（最终态）**：memory 20281→3425 字符、rule 4863→3426 字符；compact 后上下文 ~12k tokens（max_seqlen=204800，阈值 163840，占 7%，无死循环风险）；help 块 7.1k 为每轮固定负担，命中缓存时约 0.7k 等价。

**待办（延续）**：main.py / help_tool.py / tools/__init__.py / llm.py 四处修改需**重启后端生效**；已建 3 名成员空间仍在容器（03efdf...），本地模式建议重启后重建（配合 exec_mode 注入 + TeamTool io 注入路径一致）。

### 2026-08-18 · 第十二轮：重启验证暴露双轨制致命 bug（help 注入读容器、记忆写本地）+ 修复

**任务目标**：用户重启后端后验证 memory/rule 注入 + compact 刷新新架构是否生效。

**验证结果（暴露严重 bug）**：
- 进程启动时间 16:50 < 代码修改时间 16:44 → 代码已加载，但 help 输出仍是旧内容：
  - 无"记忆档案"板块（memory 注入完全没生效）、无"执行模式"板块
  - identity 显示默认文案、rule 显示 323 字节旧版
- **根因（双轨制铁证）**：
  - 记忆维护写路径：`_run_memory_update` → `_stream_agent_reply(silent=True)` → 内置 read/write/edit → `LocalWorkspaceIO` → **本地 baseDir**（`workspaces/agent_1787022784638/.self`：memory 22KB、rule 5.6KB、identity 2.4KB 全部最新版）
  - help 注入读路径：`_read_workspace_file` **硬编码 docker_manager** → Docker 容器 `workspace_agent_1787022784638`(03efdf117367)：只有旧 rule.md(323B)+activity.log+roster，**无 identity.md、无 memory.md**
  - 即：help 永远读到容器里的空壳工作空间，读不到 agent 实际写的记忆 → 即使实现注入也白搭

**修复（2 处）**：
1. **main.py 新增 `_get_workspace_io(user_id, agent_id)`**：本地模式（`local_executor.is_local`）返回 `LocalWorkspaceIO`（经 WS 到前端解析 `baseDir/workspaces/{id}/.self`），云端返回 `CloudWorkspaceIO`；`_build_workspace_extra_info` 读 identity/rule/memory 改用统一 IO（`_read_self_doc` 闭包，io 失败回退 `_read_workspace_file`），与内置工具同路径语义。
2. **help_tool.py 补 exec_mode 渲染**：板块二新增 `## 执行模式`（第六轮注入的 exec_mode 一直没渲染，是隐藏缺陷）。

**验证**：AST OK；exec_mode/memory/rule 渲染断言全过；`_get_workspace_io` 在 `_local_executor=None` 时回退 CloudWorkspaceIO 不抛异常。

**关键认知沉淀**：项目"双轨制"比预想更深——不仅 team 工具 roster 与 LLM 工具分离，**连 help 注入读 .self 都走容器、而记忆维护写 .self 走本地 baseDir**。凡涉及 .self 文档读写，必须统一走 WorkspaceIO 通道，否则写读必然分叉。

**待办**：修复代码需**再次重启后端**生效；重启后 help 应显示 `## 执行模式：本地…` + `## 记忆档案 (memory.md)` 压缩版 + `## 工作准则 (rule.md)` 压缩版。

### 2026-08-18 · 第十三轮：IO 阻塞修复（asyncio.to_thread）+ help 注入全链路验证通过

**任务目标**：用户重启后端后验证第十二轮修复；用户指出"IO 处理阻塞了，现在应该已经修好了，继续工作"——第十二轮的 `_get_workspace_io` 引入了一个隐藏死锁风险，用户已修复。

**用户修复的 IO 阻塞（关键，吸取教训）**：
- 本地模式下 `_build_workspace_extra_info` 经 `LocalWorkspaceIO` 走**反向 WS** 读 .self 文件（**同步阻塞**）。
- 若在**事件循环线程内**直接同步调用（消息处理路径 `_process_member_message` / `_handle_user_message` 原本如此），`local_executor.request` 会用 `run_coroutine_threadsafe` 往事件循环发 WS 消息，但**事件循环被自身阻塞，send_message 永远不会被调度执行 → 死锁 ~120s/文件**。
- **用户修复**：两处调用包 `await asyncio.to_thread(_build_workspace_extra_info, ...)`，把同步 IO 移到线程池，避免阻塞事件循环。
- **教训**：涉及反向 WS 的同步 IO（LocalWorkspaceIO 全家桶）绝不能在事件循环线程直接调用，必须 asyncio.to_thread；工具执行路径（chat 线程）天然无此问题（chat 循环在独立线程）。

**execute 刷新设计确认（用户恢复并细化）**：
- 用户修 IO 时把 execute() 的每次刷新**加回来了**，但设计更精细（help_tool.py:139-151 注释）：
  - **主动调 help**（execute）：每次刷新拿最新 memory/rule/identity——产出文本作为**本轮新 tool 结果**追加进上下文（新消息），**不影响已有前缀消息的 KV 缓存** ✅
  - **compact 常驻块**（render_fresh_content）：只在 compact 重构时刷新，避免常驻块内容漂移破坏前缀稳定性 ✅
- 即最终语义：**主动 help = 现读最新；常驻 help 块 = 仅在 compact 重构时刷新**。两者不冲突，各自正确。

**重启后实测（help 输出完整验证通过）**：
- `## 执行模式`：`本地（工作目录 E:\...\flutter_application_tree；私人空间 .self 位于 .../workspaces/agent_1787022784638/.self；团队共享工作目录 ...）` ✅
- `## 你的身份`：读到**本地最新 identity.md**（含到第十二轮的近期职责）✅
- `## 工作准则 (rule.md)`：5613 字符 > 4096 → **自动压缩摘要**（含任务目标/角色定位/核心准则）✅
- `## 记忆档案 (memory.md)`：23630 字 → **压缩摘要 ~4500 字**（第一轮至今全部记忆）✅
- **双轨制闭环达成**：记忆维护写本地 baseDir（LocalWorkspaceIO）→ help 注入经 `_get_workspace_io` 读同一位置 → **读写同源**。

**回归验证（verify_refresh_chain.py 全过）**：
1. 主动 help execute：每次刷新拿最新（ID_NEW/RULE_NEW/MEMORY_NEW），refresh=1 ✅
2. compact：常驻 help 块被刷新替换（新内容、旧块无残留、tool_call 配对约束满足）✅
3. 无回调（无限上下文 session）：保留旧块 ✅
- 注：compress 测试需 ≥4 条 user 消息（help 块豁免后 to_summarize 非空才真正压缩；只有 3 条 user 全在保留区时 compress 返回 False 是正确行为）。

**本轮最终状态**：memory/rule 注入 help（<4k 全量、超限压缩、md5 指纹缓存）+ 主动 help 现刷 + compact 常驻块刷新 + 统一 IO 通道（`_get_workspace_io`）+ IO 阻塞修复（asyncio.to_thread）——**全链路实测通过，无需再重启**。

**遗留待办（延续第六轮）**：已建 3 名成员空间仍在容器（03efdf...），本地模式下建议重建使路径一致；roster 表缺 system_prompt/can_lead_team 列；help 对成员仍注入"顶层 Agent"身份（未按 level 渲染）。

### 2026-08-18 · 第十四轮：记忆维护文档质量修复（发现并修复上次维护的重复插入失误）

**任务目标**：系统触发记忆维护后，全面检查 .self 三文档健康度，发现并修复上次（第十三轮）记忆维护的失误。

**发现的问题（上次记忆维护失误实证）**：
1. **identity.md 第九~十二轮重复**（行 27-31 vs 32-35）：上次 append 时 old_text 误用了"第八轮"那行（而非真正的文末"第十二轮"），把"第九~十三轮"整块插到第八轮后，而原有的第九~十二轮还在 → 第九~十二轮各出现 2 次。
2. **rule.md 编号 24、25 重复 + 顺序错乱**：上次 append 时 old_text 用了"第 23 条"（误以为文末），实际文件在第 23 条后**已有** 24'-31（更早轮次追加的条目），插入后变成 23, 24(反向WS), 25(help刷新), 24'(记忆读侧), 25'(注入限长), 26-31。
3. **根因**：上次记忆维护**没有先 read 全文档**，凭记忆中的"文末"做 edit，而实际文档比我记忆的更完整（更早轮次已追加过条目，但 memory.md 未记录这些追加动作——盲点）。

**修复（已备份到 .output/*_backup_before_fix.md）**：
- identity.md：脚本删除重复的第九~十二轮（9 行含多余空行），保留唯一完整版；验证各轮次出现 1 次。
- rule.md：重编号使 1-33 连续——91 行 24→26（**中文引号"读""写"导致初次匹配失败**，用 edit 带引号替换成功）、96 行 25→27、99 行 26→28、103 行 27→29、107 行 28→30、114 行 29→31、118 行 30→32、124 行 31→33；验证无重复无缺失。
- memory.md：13 个轮次标题唯一，无需修复。

**教训沉淀（新增 rule.md 第 34 条）**：
- 记忆维护 edit 前**必须 read 全文**，确认真正的文末（old_text 取文末唯一片段），不能凭记忆；
- 追加后**验证编号/标题唯一性**（脚本扫描），防止插入到文件中部造成重复；
- **中文引号（" "）会导致 edit/正则匹配失败**——先 inspect 码点确认原文，再精确替换；
- 更早轮次的 rule.md 追加动作应在 memory.md 留痕（记忆盲点：memory 只记任务，不记 .self 文档自身的增量）。

**本轮最终状态**：.self 三文档结构健康（memory 13 标题、rule 33 条连续、identity 13 轮次唯一）；备份保留在 .output/。







