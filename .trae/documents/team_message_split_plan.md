# team_tool 拆分为 team / message 两个独立工具 实施计划

## 一、仓库调研结论

### 1.1 现状链路

- [team_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/team_tool.py)（约 2091 行）单体类 `TeamTool`，以工具名 `team` 经 [tool/__init__.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py#L229-L235) 的 `register_builtin_tools` 注册到**每个** TOP 与成员会话（成员会话由 [chat.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L243-L260) `_register_tools` 装配，传入各自的 agent_id/leader_id/team_id）。
- 成员名单权威源是 SQLite `team_members` 表（[team_store.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/team_store.py)），`.self/team_roster.md` 仅为生成视图；TOP 创建时由 [team_init.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/team_init.py) 全量预建成员（parent_agent_id=TOP）。
- 消息出口：工具持 `message_dispatcher`（= chat.`_dispatch_agent_message`），无 dispatcher 时回退 broker 直投（`_dispatch_to_member`）。
- 工具描述来自 [builtin.yaml](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/prompt/versions/1.0.0/tools/builtin.yaml#L58-L67)，经 `versions.active_tool_description(name)` 读取；**未登记的工具名会在注册时抛 KeyError**。另有审计清单 [tool_protocol.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/prompt/tool_protocol.py#L73-L94) `TOOL_MANIFEST`。
- 引用 team action 的提示词/规范：[tool-routing.md](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/prompt/versions/1.0.0/chapters/tool-routing.md)、[task-paradigm.md](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/prompt/versions/1.0.0/chapters/task-paradigm.md)、chat.`_build_member_topology_text`（[chat.py:813-864](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L813-L864)）、内置 spec（complex-task.md / team-meeting.md / hard-task.md）。
- REST 层（[agent/routes.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/routes.py) 的 teammates / teammate log / teammate message）**不依赖 TeamTool 类**，本次无需改动；`session.team_tool` 赋值后全仓库无读取方（死引用）。
- 任务相关方法（`assign_task/query_tasks/complete_task/report_task_completion/update_member_score/mark_member_idle/_action_send_file`）除自身与测试外**无外部调用方**；`ContextIsolator` 类本身有独立单测，仅删除工具内的引用，类保留。

### 1.2 工作目录统一后的 git / 日志现状（对应要求 2、说明 1）

- 云端共享模式：`create_workspace(shared_with=TOP)` 下成员不建独立容器/卷，共享 TOP 的 `/workspace`，私人空间为 `agentspace/{member_id}/.self`（[docker_manager.py:409-445](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/docker_manager.py#L409-L445)）。共享建空间路径**跳过** `_setup_parent_remote`，即没有 per-member 分支；容器内 git 身份是 TOP 的。
- 因此 `query_status/view_member_output` 里的 `docker_manager.git_log(member_ws)`：
  - 云端：解析到 TOP 共享容器执行 `git log --all`，返回的是**整个共享仓库**的提交，无法归属到具体成员（无成员分支、无成员 author 配置）→ 语义模棱两可；
  - 本地反向 WS 模式：服务端 docker 不可用，走 `<server>/workspaces/{member_id}` 降级目录，该目录在反向 WS 部署下通常不存在 → 错误被吞，`last_commit` 恒为空 → **事实已失效**。
- 日志：`agentspace/{id}/.self/activity.log` 由 chat.`_append_activity_log`（[chat.py:1479-1505](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1479-L1505)）追加，read 工具允许相对路径 `agentspace/...`（无 `..`、非绝对路径即合法），统一工作目录下 leader 可直接 read 队友日志；无 agentspace 的 gitignore 规则，日志天然被 git 追踪。
  - **时间格式现状（已核查）**：全部 17 个日志写入点统一经 `_clock_now()`（[chat.py:1474-1476](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1474-L1476)）打前缀，格式仅为 `HH:MM:SS`，**无日期**——跨天运行时无法判断产出日期。对策：把 `_clock_now()` 改为 `%Y-%m-%d %H:%M:%S`（一处改动覆盖全部写入点；历史旧行格式保持原样不迁移）。
  - 待验证点：`_append_activity_log` 走 `state.docker_manager.exec_in_workspace` 而非统一 IO（反向 WS），本地模式落点可能是服务端降级目录而非用户 base 目录。REST `/teammate/{id}/log` 已走 `io.read_file`。实施时需验证本地模式落点，若不一致则把该函数改走 `_get_workspace_io` 通道（小改动），这是"删除 view_member_log 后 leader 直接读日志"成立的前提。
- 工具结果时间现状（已核查）：工具执行统一入口在 [llm.py:1001-1084](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/llm/llm.py#L1001-L1084) 的 tool_call 循环，`handler(**args)` 的结果经 `_tool_context_content` 写入给模型的 tool 消息——**当前结果不带任何时间**。集中注入点明确：在该循环构造 `base_content` 时统一追加"返回时间"脚注，一处覆盖全部内置工具与 MCP 工具。

### 1.3 调研中发现的现有缺陷（计划内一并修复）

1. **成员自身 level 永远为 0**：`TeamTool.__init__` 硬编码 `self.level=0`，`register_builtin_tools` 从不传入成员层级。成员调 `create_member` 时层级校验形同虚设（`0 >= max_level` 恒不成立），且新成员被记为 `level=self.level+1=1`，与实际深度不符；max_level 只对 TOP 有效。
2. **can_lead_team 端到端不闭环**：update_member 只改 leader 进程内存中的成员 dict；team_store 无此列（update 白名单不含它）、roster 视图不渲染它、目标成员自己的工具实例永远是 True、重启复位。是一个"看起来可用实际无效"的开关。
3. **update_member 不支持 role/duty**：函数体根本不读取这两个参数，create_member 也不接收；但 list_members 的 hint、builtin.yaml、complex-task spec 都指导模型"用 update_member 补 role/duty"。只传 role/duty 会得到"未提供任何可更新的字段"错误。
4. **list_members 成员视角结果不可靠**（对应要求 5）：
   - `_load_from_team_store` 装载 TOP 下**全部**成员（含当前 agent 自己），自己的行会落进 `team_member` 组；
   - `team_leader` 的 level 硬编码 0：L2 成员的 leader 是 L1，显示错误；
   - sub-leader 是成员而非 agent_store 中的 agent，leader 名称解析失败时回退裸 id；
   - 顶层 `members` 键只含直属，`total` 却含三个组，口径不一致；`team_member` 行直接泄漏内部字段（system_prompt/message_history/task_ids 等），且无 `relation` 标注；
   - legacy roster 回退解析把**所有**行的 parent_agent_id 置为当前 agent：非 TOP agent 会把全 TOP 成员误判为直属，波及 broadcast 收件人与 create_member 的直属计数。
5. **broker 回退路径 leader_id 错误**：`_dispatch_to_member` payload 固定带 `leader_id=self.leader_id`。L1 给自建的 L2 投初始化消息时，L2 收到的 leader 是 TOP 而非 L1（dispatcher 主路径因 `leader_id=source_agent_id` 恰好正确，回退路径错）。
6. **wait_for 假完成竞态**：send_message 后立即 wait_for，若成员 worker 尚未在 `_active_tasks` 登记，首轮轮询即判定全部 idle 而立即返回"完成"。
7. **send_message/broadcast 返回信息不全**：任一目标成功 status 即 "sent"，无 dispatcher 的 sent/rejected 明细；错误 hint 未给出可操作建议；`self.messages/self.tasks/message_history/task_ids` 全为仅写不读的内存死状态。
8. create_member 的直属计数基于初始化快照（他进程/他工具实例的新建不可见）；name 在 team_store 层无唯一约束，重名后按 name 寻址会命中歧义首条。

### 1.4 需求本身的潜在缺陷/歧义（提请注意，计划已给对策）

- **list_members/list_teams 在两个工具中重复**：必然带来行为漂移风险。对策：抽公共基类，**同一份实现**，两个工具只是暴露的 action 子集不同；代价是每会话多一次 team_store 只读查询（可忽略）。
- **删除 view_member_log 的前提**是三模式下 leader 都能用 read 读到 `agentspace/{id}/.self/activity.log`。云端/设计意图成立（章节⑨已承诺 agentspace 互可见）；本地模式依赖前端执行器对显式 `agentspace/<id>/.self/...` 路径不做二次改写（docker_manager 已有此约定）。需实测验证；REST 日志通道保留作为前端兜底。
- **broadcast 仅直属**与"成员看不到自己创建了谁"的潜在误解：多数预建 L1 成员没有直属，broadcast 会返回 0 收件人 → 必须返回明确 hint（"你无直属成员，点对点请用 send_message"），避免模型误判全员已通知。
- **无任务 action 后**，wait_for 等待的唯一信号是成员执行态（`_active_tasks`），成员空闲但尚未读消息、以及成员完成后 leader 如何验收，都要靠 send_message 回发 + read 日志/产物闭环；提示词必须写清这套替代流程，否则模型会继续寻找 assign_task。

## 二、目标设计

两个独立 LLM 工具：

- `team`（类 `TeamTool`，文件保留 `tool/team_tool.py`）：`list_models / list_teams / list_members / create_member / query_member / update_member / query_status`
- `message`（类 `MessageTool`，新文件 `tool/message_tool.py`）：`send_message / broadcast / list_members / list_teams / wait_for`
- 公共能力放新文件 `tool/team_base.py`（类 `TeamToolBase`）：构造参数、自身身份引导、名单实时加载/回退解析、寻址解析、live 状态、IO 助手、list_teams/list_members 统一输出、roster 视图读写。

### 2.1 统一 list_members 语义（修复 1.3-4）

- 动作执行时从 team_store **实时读取**（`get_members(top)`），失败/空再回退 roster 文件；内存名单仅作同会话新建成员的补充。
- 输出统一成员视图字段（不泄漏内部字段）：`id, name, role, duty, model_id, level, can_lead_team, parent_agent_id, leader_name, relation, work_status(实时), log_path`，其中 `log_path = agentspace/{id}/.self/activity.log`。
- 分组：
  - `team_leader`：由 leader_id 解析，**先查 team_members（sub-leader）再查 agent_store（TOP）**，带真实 level；TOP 自身该组为空；
  - `teammates`：parent_agent_id == 本 agent（直属）；
  - `team_member`：TOP 内其余成员，**排除自己**，附 relation（peer/indirect）；
  - 顶层 `members` = 三组合集（扁平、字段一致），`total` 与合集一致；筛选参数 model_id/level/work_status 作用于两个成员组（不含 leader）。
- roster legacy 回退：仅 TOP 视角把解析行视为直属；非 TOP 视角一律归 `team_member`（消除伪直属）。

### 2.2 team 工具变更

- **自身身份引导**：构造后从 `team_store.get_member(team_id, agent_id)` 读取自身 `level/can_lead_team`（无行=TOP：0/True），修复缺陷 1。
- create_member：level 用自身真实 level+1；直属计数与重名校验改实时查 team_store（重名返回明确错误+建议换名）；支持 role/duty 入参并落库；`_dispatch_to_member` 的 leader_id 改为新成员的真实直属 leader（self.agent_id，通用化：取 member.parent_agent_id）；保留建空间/身份文件/私人空间/roster/初始化消息。
- update_member：**补齐 role/duty**；can_lead_team 落库（需新列，见 2.4）；保留 work_status 只读拒绝；更新后同步 team_store + roster + 名单推送。
- query_status：**彻底删除 git last_commit/current_task**（不保留任何 git 字段；统一工作目录下归属无意义、本地模式已失效），返回 `member_id/name/work_status/last_active_at/log_path/hint`：
  - `last_active_at` 从该成员 activity.log 最后一行解析时间戳（带日期；读失败留空并注明）；
  - hint 明确教会模型**通过日志检索具体产出**：`read agentspace/{id}/.self/activity.log` 通读、或用 terminal `grep`/`tail` 检索 `[done]`/`[tool]` 行定位产出文件与完成时间；产出文件本身在共享工作目录直接 read；不再提示任何 git 查产出的方式。
- 删除：view_member_output/view_member_log/_list_workspace_files、任务全套、send_file 死代码、_sanitize_file_path、messages/tasks 内存态、_generate_task_id、ContextIsolator 引用、mark_member_idle/update_member_score/complete_task/report_task_completion。
- 错误返回一律带可操作 hint（缺 target_member_id 时提示先 list_members；模型不存在时提示先 list_models；成员不存在时回显近似名单获取方式）。

### 2.3 message 工具变更

- 构造与 team 工具相同的依赖（session/docker_manager 可不要/broker/user_id/agent_id/leader_id/team_id/message_dispatcher/io/session_id），自身身份引导复用基类。
- send_message：寻址解析实时化（内存新建成员 → team_store 按 id/name → 同用户 TOP）；**跨 TOP 顶层寻址仅 TOP 自己可用**（成员使用直接给 unknown + 隔离说明 hint，与 dispatcher 的团队隔离一致）；返回逐目标明细 `{status, sent, rejected, unknown}` 与汇总 hint；删除内存消息记账。
- broadcast：收件人=实时名单中 parent_agent_id==self.agent_id（保持仅直属，要求 4）；0 直属时返回明确 hint；返回收件人 id 列表与 rejected。
- wait_for：保留逗号分隔 target_member_ids + timeout（默认 300s，上限 600s）；修复竞态——每个目标须**至少观测到一次 working** 后再等其转 idle，首个轮询窗口给约 5s 启动宽限（期间未出现 working 则视为未接单/已完成并在结果中标注 `never_started`，提示模型用 send_message 确认）；目标解析支持 name；错误时提示先 list_members。

### 2.4 数据层小迁移

- `team_members` 增加 `can_lead_team INTEGER NOT NULL DEFAULT 1`（复用现有 `_migrate_column` 幂等迁移）；`add_member` 增参、`update_member` 白名单放行。
- 不改 teams 表、不动 team_init 的全量建队（预建成员默认 can_lead_team=1）。

### 2.5 时间信息补齐（本轮反馈新增）

- **活动日志加日期**：`_clock_now()` 格式由 `%H:%M:%S` 改为 `%Y-%m-%d %H:%M:%S`。全部 17 个写入点共用此函数，一处改全覆盖；日志行形如 `[2026-06-30 14:23:05] [done] 回复完成`，跨天可判断产出日期。时区沿用服务器本地时间（与现状一致）。
- **所有工具结果统一带返回时间**：在 [llm.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/llm/llm.py#L1047-L1084) 工具循环构造写入上下文的 `base_content` 时，统一追加脚注（如 `\n\n---\n结果返回时间：2026-06-30 14:23:05（服务器本地时间）`），使模型对任意工具（内置 + MCP）的产出时间都有判断依据；AskUserQuestion 占位、异常结果、未找到工具同样带时间。同时在 yield 给前端的 tool_call dict 中增 `timestamp` 字段（前端忽略多余字段无影响，供后续展示）。
  - 注意：不污染工具原始返回（前端 tool_end 展示与 dict 结果的图像/重定向逻辑保持原样），只在**模型可见的 tool 消息 content** 与事件元数据上加时间。
- team/message 两个工具自身的返回也在基类提供统一 `generated_at` 字段（与上条脚注互为印证，字典结果中可被结构化读取）。

## 三、文件与模块

| 文件 | 变更 |
| --- | --- |
| `server/tool/team_base.py` | **新增**：TeamToolBase（身份引导、名单实时加载与 legacy 回退、寻址、live 状态、IO 助手、list_teams/list_members、roster 读写、_dispatch_to_member 修正） |
| `server/tool/team_tool.py` | 重构：仅保留 7 个 team action；删除任务/产出/日志/文件相关代码；role/duty、level、can_lead_team 修复 |
| `server/tool/message_tool.py` | **新增**：MessageTool，5 个 action |
| `server/tool/__init__.py` | 装配并注册两个工具（工具名 team/message）；删除死引用 `session.team_tool`；更新"内置工具"计数注释 |
| `server/data/team_store.py` | 增 can_lead_team 列迁移与 add/update 支持；其余不动 |
| `server/agent/chat.py` | 更新 `_build_member_topology_text` 文案（任务派发改述为 message send_message；日志/产出查看路径说明）；`_clock_now()` 改为带日期格式；`_append_activity_log` 落点验证，必要时改走统一 IO；更新过时 docstring 中的 view_member_log/assign_task 字样 |
| `server/llm/llm.py` | 工具循环统一给模型可见的 tool 结果追加"结果返回时间"脚注；yield 的 tool_call 事件增 timestamp 字段 |
| `server/prompt/versions/1.0.0/tools/builtin.yaml` | 拆为 `team`（成员/团队管理）与 `message`（通信/广播/等待）两条描述，移除 assign_task/view_* 表述 |
| `server/prompt/tool_protocol.py` | TOOL_MANIFEST 增 `message`、更新 team purpose |
| `server/prompt/versions/1.0.0/chapters/tool-routing.md`、`task-paradigm.md` | 协同路由拆成 team/message 两条；团队会议段落去掉 assign_task |
| `server/tool/spec/builtin/complex-task.md`、`team-meeting.md`、`hard-task.md` | assign_task→message send_message 派活；view_member_log/view_member_output→read `agentspace/{id}/.self/activity.log` 与直接 read 产物 |
| `server/README.md` | 工具清单一行的小修订（可选） |
| `server/tests/` | 更新 7 个受影响测试 + 新增 list_members 专项测试（见验证节） |

REST 层、team_broker、team_init、前端、`agent/context_isolation.py` 不改。

## 四、实施步骤（依赖顺序）

1. **team_store 迁移**：can_lead_team 列 + add_member 参数 + update 白名单；跑现有 team 测试确认不回归。
2. **新建 team_base.py**：搬运并集中公共逻辑，实现自身身份引导、实时名单加载、统一 list_members/list_teams、寻址解析（含 sub-leader 解析、自己排除、legacy 归属修正）、修正 `_dispatch_to_member` 的 leader_id。
3. **重构 team_tool.py**：继承基类，只留 7 个 action；create_member/update_member 增强（level/role/duty/can_lead_team/实时计数重名校验）；query_status 瘦身；删除全部任务/日志/产出代码与死状态。
4. **新建 message_tool.py**：send_message（明细返回+实时寻址+跨 TOP 限制）、broadcast（直属+0 收件人 hint）、wait_for（seen_working+启动宽限）、复用基类 list_members/list_teams；编写独立工具定义与参数 schema（仅各自需要的字段）。
5. **tool/__init__.py 装配**：实例化两个工具并注册（builtin.yaml 必须先有 message 条目，否则注册抛 KeyError）；删除 session.team_tool。
6. **提示词与 spec 文案**：builtin.yaml、tool_protocol、两章节、三个内置 spec、chat 拓扑章节文案；确认无残留 assign_task/view_member_* 引用；文案中写明"查成员产出→read/grep 其 activity.log（行首带日期时间）"。
7. **时间信息补齐**：`_clock_now()` 加日期；llm.py 工具循环统一注入"结果返回时间"脚注与事件 timestamp；基类返回统一 `generated_at`。
8. **活动日志落点验证**：本地（反向 WS）模式确认 `agentspace/{id}/.self/activity.log` 落在用户统一工作根；不符则把 `_append_activity_log` 改走 `_get_workspace_io` 通道。
9. **测试更新与新增**（见第五节，**1.3 节每项缺陷均有对应回归测试**），全量跑通。

## 五、验证（每个已发现缺陷均有回归测试）

### 5.1 新增专项测试 `server/tests/test_team_list_members.py`（要求 5）

用临时 DB 覆盖：
1. TOP 视角：teammates=预建 L1，team_member=L2，无 leader 组；
2. L1 视角：leader=TOP（level 0）、自建 L2 在 teammates、平级在 team_member、**自己不出现在任何组**；
3. L2 视角：leader 经 team_members 解析为 L1（level 1，名称正确，不回退裸 id）；
4. 实时 work_status 叠加、三种筛选器（model_id/level/work_status）、log_path 字段存在且路径正确；
5. legacy roster 回退：非 TOP 视角不产生伪直属（防 1.3-4 回归）；
6. team 与 message 两个工具的 list_members/list_teams 输出完全一致（防行为漂移）。

### 5.2 缺陷→回归测试映射（1.3 节 8 项 + 时间项，逐一覆盖）

| # | 缺陷 | 回归测试断言 |
| --- | --- | --- |
| 1 | 自身 level 恒 0 | L1 工具实例引导后 `self.level==1`；其 create_member 落库 level=2；max_level 下 L1 再建 L3 被拒；TOP 实例 level=0 正常建 L1 |
| 2 | can_lead_team 不闭环 | update_member 写 False 后 team_store 行持久化为 0；**新建工具实例**重新引导读到 False（不再恒 True）；list_members/roster 渲染该字段；旧库迁移后默认 1 |
| 3 | role/duty 不支持 | create_member 带 role/duty 落库并可 query_member 读回；update_member **仅传** role/duty 成功（不再报"无可更新字段"） |
| 4 | list_members 视角不可靠 | 即 5.1 专项全部用例 |
| 5 | broker 回退 leader_id 错 | L1 实例 `_dispatch_to_member` 投递给自建 L2 时，捕获 payload 断言 leader_id==该 L1（而非 TOP）；TOP 投递仍为 TOP |
| 6 | wait_for 假完成竞态 | 目标从未置 working → 结果标 `never_started` 且不立即返回成功；先 working 后 idle → 正常完成；timeout 返回明确 hint |
| 7 | send_message 明细缺失 | 混合 sent/rejected/unknown 多目标：逐目标明细齐全、unknown 带"先 list_members"hint；成员跨 TOP 寻址被拒并带隔离 hint |
| 8 | 计数快照/重名歧义 | team_store 中已有直属（非本实例创建）时 create_member 上限实时生效；同 team 重名 create 被拒并提示换名；按 name 寻址唯一命中 |
| 9 | query_status git 字段 | 断言返回不含 last_commit/current_task/git 任何键；含 work_status/last_active_at/log_path；hint 含 activity.log 检索指引 |
| 10 | 日志无日期 | patch `exec_in_workspace` 捕获命令并 base64 解码，断言行首匹配 `^\[YYYY-MM-DD HH:MM:SS\]` |
| 11 | 工具结果无时间 | 跑一次最小 tool_call 循环（stub handler），断言写入 context 的 tool 消息含"结果返回时间"且匹配日期时间格式；yield 事件含 timestamp；异常/未找到工具结果同样带时间 |
| 12 | broadcast 直属口径 | L1 实例 broadcast 只命中其自建 L2（实时 DB 名单，不命中预建平级）；0 直属返回明确 hint 且不伪装成功 |

测试文件组织：#1/#2/#3/#8 入新增 `test_team_member_lifecycle.py`；#5 入 `test_team_dispatch.py`；#6/#7/#12 入 `test_message_tool.py`；#9 入 team 工具测试；#10 新增 `test_activity_log_format.py`；#11 新增 `test_tool_result_timestamp.py`（置于 tests 下，stub LLM 不发起真实请求）。

### 5.3 更新受影响的现有测试

test_team_resolve（寻址改到 MessageTool/基类）、test_team_create_member、test_team_limits（`_resolve_team_limits` 导入路径改基类，team_tool 保留再导出兼容）、test_team_update_member_preserves、test_fix_noop_tools（list_models 仍在 team、message 无 list_models）、test_stop_cascade（live_status 走基类、work_status 拒绝仍在 team）、test_8items_rest_api（session 透传用例改到 MessageTool/基类 `_dispatch_to_member`）；另排查断言"工具结果原文精确相等"的既有测试，为时间脚注注入做适配（断言改为包含关系）。

### 5.4 全量验证

- `python -m unittest discover -s server/tests` 全绿；
- grep 确认无 `assign_task/query_tasks/complete_task/view_member_log/view_member_output/last_commit` 残留引用（含提示词与 spec）；
- 冒烟：import 注册链，register_builtin_tools 后 team/message 两个工具定义均可生成，builtin.yaml 两条描述齐全；
- 手工核查一条活动日志样例行首为完整日期时间。

## 六、风险与对策

- **提示词遗漏导致模型继续调用已删 action**：删除 action 后 LLM 调用会收到"未知 action"错误（无引导）。对策：builtin.yaml/章节/内置 spec/拓扑文案同步改写，并在两个工具的未知 action 错误中给出可用 action 列表；内置 spec 是模型常读文本，必须改全。
- **双工具实例名单短暂不一致**（同一轮内先 create 再 send）：对策为 message 侧寻址实时查 team_store（create_member 先落库后返回），不依赖实例内存。
- **can_lead_team 迁移面**：仅加列不改语义默认（旧数据默认 1 与现行为一致）；update_member 历史上设置过的内存值无法找回（本就未持久化），可接受。
- **wait_for 阻塞工具线程**：维持现状（最长 timeout，默认 300s），保留超时 hint 告知模型结束本轮、等成员回发自动唤醒；不扩大改动为事件驱动。
- **时间脚注影响既有测试/上下文体积**：脚注固定约 40 字符/次工具调用，对上下文影响可忽略；既有精确匹配断言在 5.3 中统一适配；重定向机制对脚注无影响（脚注在重定向之后追加）。
- **共享仓库 git 查询彻底移除**：query_status 不再提供任何 git 信息；成员产出时间一律以 activity.log（行首日期时间）与工具结果返回时间为准，需要 commit 归属时由 agent 在 commit message 内自行标注 member id（提示词说明）。
- **不动后端运行进程**：仅代码与测试改动，重启由用户自行决定（遵循既定偏好）。
