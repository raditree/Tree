# team（团队领域）

把"团队"表达成 **agent 字段**而不是独立的成员表：成员就是 agent，团队关系写在 `agents/<id>.yaml` 里。
本模块负责成员管理、消息寻址与派发、工作目录与 SSH 口径。

## 文件

| 文件 | 作用 |
| --- | --- |
| [team_service.dart](team_service.dart) | 团队领域服务：建队 / 建成员 / 更新 / 审核 / 移除，把规则钉成硬约束 |
| [team_model.dart](team_model.dart) | 成员视图（字段白名单）与活动日志路径 `memberLogPath` |
| [team_workspace.dart](team_workspace.dart) | 工作目录口径 `teamWorkspaceFor` 与 SSH 口径 `teamSshConfigFor` |
| [message_dispatcher.dart](message_dispatcher.dart) | 消息派发：寻址 → 审核闸门 → 投递；活动日志的读写 |
| [team_repair.dart](team_repair.dart) | 启动自愈：`parent_agent_id`/`team_id` 指向不存在的 agent 时重挂 / 升顶层（子树平移，改动前备份 `.bak.<n>`）；共享工作目录镜像 `syncWorkspaceMirrors` |

## 不变量（assertions）

1. **成员就是 agent**：`team_id`（= TOP id）/ `parent_agent_id` / `level` 直接写在成员自己的 yaml 里，用户可以手改；`member_count` 一律按**实际成员数回填**，不是累加出来的计数器。
2. **工作目录只有团队所有者（TOP）那一份**，成员一律跟随它（`teamWorkspaceFor` 沿途向上找，带深度与 seen 去重，配置成环也不会死循环）。成员自己 yaml 里的 `workspace_dir` **不生效**——否则"和 leader 共享工作目录"就变成一条能被旧配置悄悄覆盖的软约定，而"成员各自 `workspaces/<member_id>`"正是用户在界面上看不到成员进度的成因（见 [docs/known-issues.md](../../../../../docs/known-issues.md)）。
3. **成员跟随 leader 的 SSH**：自己的 `ssh:` 优先，否则取 TOP 的（`teamSshConfigFor`）——SSH 团队里成员必须在**同一台机器**上干活。
   `teamSshConfigFor` 是**"这是远端吗"的唯一判据**：工具层、文件面板、Git 面板、集成终端都走它，任何一处都不许
   退回 `agent.sshConfig`（只看后者会把 SSH leader 的成员判成本机：文件面板去本机找远端路径、终端在本机起 shell——
   两者都是真实 bug，见 [../files/README.md](../files/README.md) 不变量 9 与 [../terminal/README.md](../terminal/README.md)）。
   **没有"成员覆盖成 local"这个概念**：TOP 配了 SSH 时成员无法单独切回本地，界面会如实拒绝并提示到 TOP 上去关
   （见 [lib/README.md](../../../../../lib/README.md) 不变量 15）。
4. **私有状态按 agent 分栏**：`.tree/<agent_id>/.self/`。**用 id，不用名字**（名字会变、也可能重复）；共享一份 `.self` 会把 `activity.log` 混在一起、且无法归属到具体成员。
5. **三条硬规则**（都有自动化测试）：① **没有模型写入口**——team 工具的 create / update / review 收到 `model_id` 一律报错，模型只能由用户在界面上分配；② **新建成员恒为 `pending_model` 且 `model_id` 为空**，用户放行前不接收消息；③ **只能碰自己的子树**——不可移除自身 / 上级 / 非后代，目标有下级时必须显式 `cascade`。
6. 派发只做**寻址、闸门、活动日志**：串行与代次由 `ConversationService` 承担；投递**不阻塞**（要等结果用 `wait_for`）。
7. **无静默回传**：成员正常完成不会自动发给任何人；只有"未就绪 / 模型缺失"这类错误才以 auto_reply 回到发送方。
8. **派发没有任何静态超时**；判活点是链路心跳台账。失活期间 **fail-closed**：不落库、不触发生成、直接以**显式错误**拒绝（原因含「心跳丢失」），同时把这条消息登记进**待补发队列**，重连 / 心跳恢复后补发——所以不静默丢消息。为什么不是"先投递再补发"：`deliver` 会**先**把消息写进成员会话再触发生成，补发会产生重复消息；fail-closed 同时避免了"落了库但成员永远看不到"的静默假成功。
9. `wait_for` 的活性结论：`unknown`（没有活性信息）**不判死**，只有 `lost`（心跳丢失）才收口——避免把"还没开始跑"当成"已经死了"。
10. 活动日志经 agent **自己的工作空间 IO** 读写（SSH 成员因此写在远端），写入按 agent 串行（读回 → 追加 → 写回），超 512 KB 只保留最近 400 行并记一行截断标记（日志是过程记录，不当事实源）。
11. 名单接口返回的成员视图是**字段白名单**，绝不包含 `system_prompt`（否则提示词会泄漏给整棵树）；只有 `query_member` / `update_member` 才额外返回它。
12. **悬空指针必须被兜住——删除 agent 的团队后果有两条规则**（[test/team_repair_test.dart](../../../test/team_repair_test.dart) 与 [test/agent_delete_api_test.dart](../../../test/agent_delete_api_test.dart) 强制）：
    ① **删除路径与 team 工具同规则**：`DELETE /api/agents/{id}` 有下级时必须显式 `?cascade=1`（否则 409 + `cascade_required`），
    删完按**实际成员数**回填 TOP 的 `team_member_count`（用户侧删除不走 team 工具，不回调就留旧值）；
    ② **历史遗留的悬空指针在核心启动时自愈**（`team_repair.dart`）：上级还在 ⇒ 重挂到 TOP 并把整棵子树的
    `team_id`/`level` 一起平移；团队也没了 ⇒ 最上层孤儿**升为独立顶层 agent**；`team_id` 悬空但父链完好 ⇒ 按父链修正。
    为什么必须修（实测）：孤儿成员的 `directMembers` / `cascadeIds` / `_subtree` 全都够不着——广播不达、
    级联停止与级联删除失效、连 team 工具都再也删不掉它们（`_subtree` 同样沿父链走），但它们**仍会被寻址、还能干活**。
    写盘口径：修好就写盘，但每个被改的 yaml 先备份 `.bak.<n>`（n 递增、绝不覆盖）；幂等（再跑一次零动作）。
13. **成员 yaml 里的 `workspace_dir` 是"共享目录的镜像"**（`syncWorkspaceMirrors`，
    [test/workspace_mirror_test.dart](../../../test/workspace_mirror_test.dart) 强制；**用户断言 2026-10-03**）：
    写进去的是**有效目录**——TOP 显式配置的 `workspace_dir`；TOP 没配置时写 TOP 的**默认目录**
    （`<数据根>/workspaces/<top_id>`，而不是成员自己的默认目录）。维护时机三处：**建成员时**、
    **核心启动自愈时**、**TOP 改目录的 PATCH 之后**（都先备份 `.bak.<n>`，都幂等；TOP 自己的配置是用户
    配置项，**绝不改写**）。它仍然**不参与运行期解析**（见不变量 2）——只有两个作用：
    ① 界面能显示成员实际在用的目录（不再显示「选择目录」）；② **升级交接**：TOP 被外部删除
    （手删 `agents/<top>.yaml`、历史遗留数据）后成员被本模块升为独立 TOP 时，
    **不可以退回"重新选择工作目录"**（配置不能留空，按 TOP 填写）——没有这份镜像，成员会悄悄落到
    `workspaces/<member_id>`，用户看到的是"文件不见了"。
    口径边界：镜像不是"第二份配置"，手改它没有意义（运行期不看、下次镜像会覆盖回去）。
14. **成员面板列的是「这个 agent 自己的下属」，不是「它所属的团队」**
    （[test/teammates_api_test.dart](../../../test/teammates_api_test.dart) 强制；**用户断言 2026-10-03**：
    成员「凌川」的成员面板里出现了「凌川」自己）：`GET /api/agents/{id}/teammates` 的成员名单 = 以该 agent
    为根的**下属子树**——TOP（`team_id` 为空）取 `members(teamId)`（就是整队，取值与顺序照旧），
    成员取 `descendants(id)`；**绝不把自己、自己的兄弟、自己的上级列成「它的成员」**，
    `pending_member_count` 只数这份名单。响应体额外回一份 `self` 描述符（`id` / `name` / `level` /
    `is_member` / `top_agent_id` / `top_agent_name`），界面据此如实标注根节点——成员**不是** Level 0、
    也不是「团队负责人」。为什么以前会错：`teamIdOf(id)` 对成员回指团队，于是整队（含它自己）都成了
    「它的成员」；`team` 工具的 `list_members` 早就把自己排除掉了（同一类口径的前一半），这里是后一半。
    **同口径的徽章**：`GET /api/agents` 的 `pending_member_count` = 这份名册里 `ReviewStatus.needsUser` 的成员数
    （左栏红点 / teammates 入口角标）——TOP 数整队、成员只数自己的下属。此前这个参数**从没被赋值**（恒 0），
    `docs/team.md` 却写着「未就绪成员会在 leader 上显示红点」，于是那排红点永远不会亮；现在面板与徽章由
    同一个 `_rosterOf` 决定，不会出现「面板是空的、红点却亮着」。

## 测试

```bash
cd packages/tree_core
dart test test/team_service_test.dart test/team_workspace_test.dart test/message_dispatcher_test.dart \
          test/member_overrides_test.dart test/teammates_api_test.dart test/teammate_message_api_test.dart \
          test/team_repair_test.dart test/agent_delete_api_test.dart test/workspace_mirror_test.dart
```
