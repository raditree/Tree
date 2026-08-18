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
