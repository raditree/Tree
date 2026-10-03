# 团队与成员

> 面向"想知道团队到底怎么跑"的人。实现入口：`packages/tree_core/lib/src/team/`、`tool/team_tool.dart`、`tool/message_tool.dart`。

## 1. 成员就是 agent

成员不是另建一张表，而是一个普通 agent 文件 `agents/<member_id>.yaml`，靠这几个字段表达团队关系：

| 字段 | 含义 |
| --- | --- |
| `team_id` | 所属团队 = **TOP agent 的 id**（TOP 自身为空串） |
| `parent_agent_id` | 直属上级（TOP 自身为空串） |
| `level` | 层级（TOP = 0） |
| `max_level` / `max_members_per_level` | 该 TOP 的层级与每层成员上限 |
| `role` / `duty` | 角色与职责（派活时给模型看的） |
| `review_status` | `pending_model` / `pending_review` / `approved` / `rejected` |
| `can_lead_team` | 是否允许再建子团队 |

**成员也是独立的 agent 文件**（可以手改 yaml、有独立 `workspace_id`），但**工作目录与 leader 共享**、
**私有状态按 agent 分栏**（见 §3）。

## 2. 创建与审核

1. leader 调 `team create_member`（或用户走 REST）→ 成员恒为 **无模型 + `pending_model`**；
   `team` 工具的 create/update/review **收到 `model_id` 一律报错**——模型只能由用户在
   「团队 → 成员 → 模型配置」里分配（`PATCH /api/agents/{leader}/teammate/{member}`）。
2. 审阅通过（`approved`）后成员才会接活；未就绪成员收到消息会**明确拒绝**并回传给发送方，不静默丢。
3. 移除/回收：只能碰自己的子树；目标有下级时必须显式 cascade。**用户侧删除同规则**：
   `DELETE /api/agents/{id}` 有下级时回 409 + `cascade_required`（列出下级），确认后带 `?cascade=1` 才连整棵子树删
   （叶→根）；**正在运行的 agent 一律拒绝删除**（409 + `running`）——`stop` 抢不动正在执行的工具，
   请先停止并等它变空闲。删完按实际成员数回填 TOP 的 `team_member_count`。
4. 悬空指针自愈：历史数据里已有「上级被删」的成员，核心启动时修一次（`team_repair.dart`）——上级还在就重挂到 TOP
   （子树 `team_id`/`level` 整体平移），团队也没了就把最上层孤儿升为独立顶层 agent；每个被改的 `agents/<id>.yaml`
   先备份成 `.bak.<n>`。为什么要修：孤儿成员广播够不着、级联停止与级联删除失效、team 工具也删不掉，
   但它们仍会被寻址、还能干活（见 [known-issues.md](known-issues.md) #9 第 8 条）。

## 3. 工作目录与私有状态

- **共享工作目录**：成员与 leader 同一个根（同一份项目文件）——测试写 `hello.http`，leader 直接读得到。
  解析规则见 `teamWorkspaceFor(...)`：一路向上找到团队 TOP，用 TOP 的 `workspace_dir`（空则用 TOP 的默认目录）；
  **成员自己 yaml 里的 `workspace_dir` 不生效**。
- **私有状态分栏**：`.self/…`（模型口径）真实落在 `.tree/<agent_id>/.self/…`
  （提示词、规范、规范附带文档、长结果、活动日志、计划笔记）。翻译由 `PrivateWorkspaceIO` 一处完成。
- **SSH 跟随**：成员没有自己的 `ssh:` 就用团队 TOP 那份（同一台远端主机、同一个根，`teamSshConfigFor`）；显式配了就用自己的。
- 旧工作空间的 `.self` 在核心启动时**一次性迁移**到 `.tree/<TOP id>/.self`；成员以前各自的工作目录
  （如 `workspaces/<member_id>/`）留在原地不搬。

## 4. 会话与并发

- 团队会话是 leader 与成员**共享的会话 id**：用户在哪个 agent 的聊天里发消息，就归到那个 agent 的会话流里。
- **派活/回信默认归集到"发起这一跳的会话"**（`message` 工具自动补 `session_id = ToolInvocation.sessionId`），
  所以用户在 teammates 窗口（按当前会话过滤）看得到成员的执行与回信；不这样就会出现
  "成员干了活但界面一片空白"（见 [known-issues.md](known-issues.md) #9）。
- 同一 agent 的**不同会话并行**；同一会话内串行，插话（新消息）会打断在途那一轮——**只打断收件人自己那一轮**（用户 2026-10-03 断言：发给主 agent 不影响它名下的临时员工，发给临时员工不影响父与其他临时员工）；父那轮若正卡在阻塞工具上，新消息按"正在执行的工具跑完才收敛"排队等它返回。
- `stop` 是 agent 级的：该 agent 的全部在途会话与排队任务一起停。

## 5. 派活与沟通（`message` 工具）

| action | 语义 |
| --- | --- |
| `send_message` | 给成员 / 直属 leader / 其他 TOP 发消息；可带 `files`（复制到接收方 `.input/<日期>/`；本机↔SSH、SSH↔SSH 都能投递，跨机经本机中转） |
| `broadcast` | 给**全部直属**成员广播（不跨层级） |
| `wait_for` | 等成员完成当前工作；**没有静态时长上限**，只有"心跳丢失 / 未响应"才收口并返回**部分结果 + 未响应者清单** |
| `list_members` / `list_teams` | 与 `team` 工具同一实现 |

约定（也写进了工具描述）：**不存在"任务"对象**，派活就是发消息；系统**不会替对方回传总结**，
需要回复就在消息里明确要求；禁止只为确认收到 / 寒暄而互发。

## 6. 活动日志

- 位置：`.self/activity.log`（真实路径 `.tree/<agent_id>/.self/activity.log`）；
  `memberView.log_path` 返回模型口径的相对路径，leader 可直接 `read`/`grep`。
- 写入内容：`[start(成员)] 收到 <发送者> 消息: <摘要>`、`[done(成员)] 回复完成`、
  `[stale]` / `[blocked]` / `[error]` / `[auto_reply]` 等显式原因。
- 读写都走该 agent 的**工作空间 IO** ⇒ **SSH 模式的 agent 写自己远端那份**；
  同一 agent 的写入串行化（IO 只有读文件/写文件，没有追加原语）。
- 通过 `GET /api/agents/{memberId}/teammate/{memberId}/log?lines=60` 读尾部。
- **不是完整记录**：只有上面这几类生命周期行，而且写回时会截断（超 512 KB 只留最近 400 行）——它够判断
  "谁在动、卡在哪"，不够复盘"到底做了什么"。**SSH 模式下日志在远端那台机器上**，而本机的事实源（数据根下的
  `data/<agent>/<session>/messages.jsonl` 与本机原文件）远端够不着 ⇒ 系统提示词按模式写明：要完整查询就
  `message send_message` 找**工作空间在本机**的团队代查，并可请它把**原文件推到远端**（用它自己的终端
  `scp` / `rsync` 之类，或按约定放共享位置）。**附件（`files`）本机与 SSH 成员之间都能投递**：
  两侧各自解析成本机目录或该 agent 的**工作空间 IO**（判据是有效 SSH `teamSshConfigFor`），据此覆盖
  local→local / local→SSH / SSH→local / SSH→SSH（含两台不同远端主机）；跨机经**本机进程中转**、
  **单文件上限 32 MB**（超限与越界只算该文件失败，其余照投）；两侧都解析不到才回一句"未投递"（见 §8）。

### 6.1 运行态与停止的作用域（用户 2026-10-03）

- `agent_status` 的 `data` 里：**主 agent 自己**的帧带 `own_running`（working ⇒ true / idle ⇒ false），
  子级帧带 `subagent_id` 等标记、不带 `own_running`；「自己收尾、名下还有临时员工在跑」时照样发一条
  `own_running: false` + `subagent_running: true`（聚合口径靠它，主视角据此换回发送键）。
- `stop` 传 `sub_…` ⇒ **只停它自己**（`cascade: false`）：父、兄弟、其他成员、团队都不受影响；
  主 agent 的 `stop` 语义一个字没改（仍级联它的团队子树 + 名下临时员工）。
- 入口列表（中栏右下那个切换器）取自**落盘名册**（`GET /api/agents/{agentId}/subagents`，
  即 `data/<agentId>/<sessionId>/subagents.json`）⇒ 不随中栏消息窗口的加载 / 淘汰抖动；
  名册仍然**不跨会话保留**（切 agent / 换会话一并清）。

## 7. 界面入口

- **左栏 agent 列表列出全部 agent（含成员）**：`team_id` 指向 TOP 的成员紧跟它的 TOP 之后
  （`railAgentsOf`，找不到 TOP 的兜底列在末尾）；选中成员就是它自己的会话，与顶层 agent 同一条通路。
  **2026-10-02 二改**：此前判"成员不独立出现在左栏"，同日改为允许出现——「选中 leader → 团队（teammates）
  → 点成员」仍是看团队拓扑与成员进度的入口，只是不再是唯一入口。成员的**工作目录 / SSH 仍复用 leader 的**（见 §8）。
- 未就绪成员会在 leader 上显示红点（`pending_member_count`），点击进「模型配置」赋模型并审核。

## 8. 已知取舍

- `GET /api/agents` 返回**全部** agent（含成员）：左栏照单全收（`railAgentsOf` 只决定顺序、不再过滤，见 §7）；
  提问归因、提问导航也按 id 找成员。
- 成员的 `workspace_id` 仍是独立的（避免 `FileService.agentFor` 把 leader 的 workspace 解析成成员，
  那会让 SSH 团队的远端文件面板错落到成员的本机目录）；共享的是**目录**，不是这个 id。
- 成员继承 SSH 后，它们的**本地**活动日志不适用（工作空间在远端）——日志改走远端 IO（见 §6）；
  **附件投递同样走工作空间 IO**（不再"远端就不投递"），跨机经本机中转、单文件上限 32 MB（见 §6）。
- [docs/archive/team_structure.md](archive/team_structure.md) 是某次运行的团队编制产物（agent 写入的），不是设计文档。

## 9. 测试钉子

- `test/team_workspace_test.dart`：成员解析到 TOP、成员自己的 `workspace_dir` 无效、多级成员、成环保护、SSH 继承。
- `test/message_dispatcher_test.dart`：审核闸门、派活归集发起会话、`wait_for` 判活与部分结果、
  活动日志（IO 路径 + SSH 模式 + 未接线兜底）。
- `test/team_service_test.dart` / `test/cascade_stop_test.dart` / `test/message_interrupt_test.dart`：
  名单白名单（成员自己调用不会把自己列两遍）、级联停止、会话并行与插话。
- `test/agent_delete_api_test.dart`：删除的两道闸门（有下级 409 + `cascade_required` 且什么都不动；`cascade=1`
  叶→根删 + 计数回填；运行中 409 + `running`，停止并空闲后才删得掉；删完不留 `data/<id>`）。
- `test/team_repair_test.dart`：上级被删→重挂 TOP + 层级平移 + `.bak.<n>` 备份 + 落盘；TOP 也没了→升为顶层；
  `team_id` 悬空但父链完好→按父链修正；幂等（再跑一次零动作、不再加备份）。
