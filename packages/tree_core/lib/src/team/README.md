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

## 不变量（assertions）

1. **成员就是 agent**：`team_id`（= TOP id）/ `parent_agent_id` / `level` 直接写在成员自己的 yaml 里，用户可以手改；`member_count` 一律按**实际成员数回填**，不是累加出来的计数器。
2. **工作目录只有团队所有者（TOP）那一份**，成员一律跟随它（`teamWorkspaceFor` 沿途向上找，带深度与 seen 去重，配置成环也不会死循环）。成员自己 yaml 里的 `workspace_dir` **不生效**——否则"和 leader 共享工作目录"就变成一条能被旧配置悄悄覆盖的软约定，而"成员各自 `workspaces/<member_id>`"正是用户在界面上看不到成员进度的成因（见 [docs/known-issues.md](../../../../../docs/known-issues.md)）。
3. **成员跟随 leader 的 SSH**：自己的 `ssh:` 优先，否则取 TOP 的（`teamSshConfigFor`）——SSH 团队里成员必须在**同一台机器**上干活。
4. **私有状态按 agent 分栏**：`.tree/<agent_id>/.self/`。**用 id，不用名字**（名字会变、也可能重复）；共享一份 `.self` 会把 `activity.log` 混在一起、且无法归属到具体成员。
5. **三条硬规则**（都有自动化测试）：① **没有模型写入口**——team 工具的 create / update / review 收到 `model_id` 一律报错，模型只能由用户在界面上分配；② **新建成员恒为 `pending_model` 且 `model_id` 为空**，用户放行前不接收消息；③ **只能碰自己的子树**——不可移除自身 / 上级 / 非后代，目标有下级时必须显式 `cascade`。
6. 派发只做**寻址、闸门、活动日志**：串行与代次由 `ConversationService` 承担；投递**不阻塞**（要等结果用 `wait_for`）。
7. **无静默回传**：成员正常完成不会自动发给任何人；只有"未就绪 / 模型缺失"这类错误才以 auto_reply 回到发送方。
8. **派发没有任何静态超时**；判活点是链路心跳台账。失活期间 **fail-closed**：不落库、不触发生成、直接以**显式错误**拒绝（原因含「心跳丢失」），同时把这条消息登记进**待补发队列**，重连 / 心跳恢复后补发——所以不静默丢消息。为什么不是"先投递再补发"：`deliver` 会**先**把消息写进成员会话再触发生成，补发会产生重复消息；fail-closed 同时避免了"落了库但成员永远看不到"的静默假成功。
9. `wait_for` 的活性结论：`unknown`（没有活性信息）**不判死**，只有 `lost`（心跳丢失）才收口——避免把"还没开始跑"当成"已经死了"。
10. 活动日志经 agent **自己的工作空间 IO** 读写（SSH 成员因此写在远端），写入按 agent 串行（读回 → 追加 → 写回），超 512 KB 只保留最近 400 行并记一行截断标记（日志是过程记录，不当事实源）。
11. 名单接口返回的成员视图是**字段白名单**，绝不包含 `system_prompt`（否则提示词会泄漏给整棵树）；只有 `query_member` / `update_member` 才额外返回它。

## 测试

```bash
cd packages/tree_core
dart test test/team_service_test.dart test/team_workspace_test.dart test/message_dispatcher_test.dart \
          test/member_overrides_test.dart test/teammates_api_test.dart test/teammate_message_api_test.dart
```
