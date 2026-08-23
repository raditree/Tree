# 成员回复回发目标：按“谁发给它”回发

## Summary

当前团队成员处理完消息后，其**最终总结**会被自动回发给 `leader_id`
（`_process_member_message` 里 `leader_id = source_agent_id or top_agent_id`）。

- 经团队工具（`send_message`/`assign_task`）由某个 agent 发出时，`source_agent_id`
  是真实发送者，回发目标正确；
- 但**用户从 teammates 窗口直接发给成员**走 [send_teammate_message](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/routes.py#L498-L508)，
  `source_agent_id=""`，`leader_id` 兜底成 top agent → 成员的总结被自动回发给 top agent，
  把 top agent 卷进了用户与成员的单独对话。

目标：**谁发给成员的，成员的最终总结就自动回发给谁**。发送方可以是任意层级：
- **上级 leader**（顶部 agent 或子 leader）：
- **平级**（同一团队下的其他成员）：以及
- **下级**（成员自己的直属/直属层级下属成员）。

三种发送方的总结都要回发给该发送方（agent），而不是一律回发给 top agent。
- **用户直接发（teammates）**：**只留在成员会话/teammates 窗口**，不转发给任何 agent
  （用户不是 agent，无法经 `_dispatch_agent_message` 投递；其回复已通过 WS 实时推送给用户）。
- 一并覆盖“用户直接发→成员提问→回答续跑”边缘：`ask_user_question` 续跑后成员总结
  也要溯源原发送方，需在 `pending_questions` 表增加 `sender_id` 列持久化。

**为什么平级/下级可行**：[`_dispatch_agent_message`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1702-L1737)
的目标为**成员**的分支没有团队隔离拒绝，成员→成员本就经
[`_find_roster_member`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1582-L1630)
按 roster 解析；隔离拒绝只存在于“目标为顶部 agent”的分支（跨 Top 限制）。
因此回发给“平级/下级（成员发送方）”天然可路由——只要 sender_id 指向该发送方。
当前总回发给 top，恰恰是因为 `leader_id=top`，从没尝试按真实发送方寻址。

## 现状分析（已确认）

- 成员负载在 [_dispatch_agent_message](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1633-L1745) 成员分支构造：
  `leader_id = source_agent_id or top_agent_id`，随后 `if extra: payload.update(extra)`。
- [_process_member_message](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1373-L1568)：
  - `leader_id = payload.get("leader_id","")`；
  - 模型缺失报错块（约 L1420）用 `if leader_id:` 回发；
  - 最终总结回发（约 L1540）用 `if full_reply and leader_id:`。
- `leader_id` 同时被 [register_builtin_tools → TeamTool](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py#L214-L220) 用作成员“认识自己上级”，**不能置空**。
  因此需新增独立字段 `sender_id` 表示“本条消息的发送方”，`leader_id` 语义不变。
- AskUserQuestionTool 在 [register_builtin_tools](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py#L221-L225) 构造，
  execute 里 `save_pending_question` 持久化提问（[ask_question_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/ask_question_tool.py#L122-L132)）。
- 用户回答唤醒走 [endpoints.py user_answer](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/endpoints.py#L209-L217)
  → [resume_after_answer](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1776-L1810) 成员分支
  以 `source=top` 重新投递，导致续跑后总结又回发给 top。
- `pending_questions` 表结构见 [conversation_store.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/conversation_store.py#L114-L130)，
  无 `sender_id` 列。库迁移使用 `PRAGMA table_info` + `ALTER TABLE ADD COLUMN` 幂等模式（见同文件 L107-L112）。

## 设计决策

1. `sender_id` = 真正触发成员本次处理的发送方。
   - agent 发送 = `source_agent_id or top_agent_id` —— `source_agent_id` 即真实发送方，
     可以是**上级 leader、平级成员或下级成员**；仅当发送方缺失时才兜底 top。
   - 用户直发 = `""`（显式置空）。
2. `_dispatch_agent_message` 成员负载 dict 显式加 `"sender_id": source_agent_id or top_agent_id`，
   再靠 `payload.update(extra)` 让调用方可**显式覆盖**：
   - 用户直发（routes）`extra["sender_id"] = ""`；
   - 续跑（resume）`extra["sender_id"] = persistent 原发送方`；
   - 团队工具 `extra` 无 `sender_id` → 保持 computed（= 真实 agent 发送方，平级/下级亦可）。
2b. 回发“平级/下级（成员）发送方”依赖 _dispatch_agent_message 的**成员分支**（本就无隔离拒绝）：
    `_find_roster_member(user_id, top_agent_id(or source), sender_id)` 按 roster 解析并投递，
    无需改动隔离逻辑。回发“上级 top”走顶部 agent 分支，`target==owner_top` 不被拒绝。
3. `_process_member_message` 读 `sender_id`：**key 存在就用（含空串），key 缺失才回退 `leader_id`**。
   这样老负载（无 `sender_id`）自动回退到 `leader_id`，回发目标不变，**向后兼容**。
4. 每收到一条消息在 session 上记录 `session.sender_id = sender_id`，
   AskUserQuestionTool 在读提问时刻取 `session.sender_id` 持久化，保证“每问一次”获得
   当时正确的发送方（而非注册时的快照）。
5. `pending_questions` 增加 `sender_id` 列（幂等 ADD），`save/get` 增列；resume 从 pending
   读原发送方并透传回成员负载，续跑总结回发到原发送方。

## 变更清单

### 1. `server/agent/chat.py`（核心）

- **`_dispatch_agent_message` 成员分支**（约 L1719 负载 dict）：新增一项
  `"sender_id": source_agent_id or top_agent_id`。后续 `payload.update(extra)` 自动让
  调用方覆盖。
- **`_process_member_message`**：
  - 读取 `leader_id` 之后新增：
    ```python
    sender_id = payload.get("sender_id")
    if sender_id is None:
        sender_id = payload.get("leader_id", "")
    ```
  - 模型缺失报错块（约 L1420）：`if leader_id:` → `if sender_id:`；
    `_dispatch_agent_message(..., [sender_id], ..., top_agent_id=top_agent_id or sender_id, ...)`。
  - session 确保后（约 L1478，`_append_activity_log` 之前）：`session.sender_id = sender_id`。
  - 最终总结回发块（约 L1540）：`if full_reply and leader_id:` → `if full_reply and sender_id:`；
    `_dispatch_agent_message(..., [sender_id], ..., top_agent_id=top_agent_id or sender_id, ...)`。
    `extra` 仍带 `{"auto_reply": True, "session_id": session_id}`。
- **`resume_after_answer`**（L1776）：签名加 `sender_id: str = ""`；
  成员分支 `_dispatch_agent_message(..., extra={"session_id": session_id, "sender_id": sender_id})`。

### 2. `server/agent/routes.py`

- `send_teammate_message`：`extra={"session_id": session_id}` → `extra={"session_id": session_id, "sender_id": ""}`。
  （`session_id` 兜底与透传逻辑保留，是上一任务的会话隔离修复。）

### 3. `server/tool/__init__.py`（register_builtin_tools）

- `AskUserQuestionTool` 构造新增 `session=session`，使其能在提问时读取实时的 `session.sender_id`。

### 4. `server/tool/ask_question_tool.py`

- `__init__` 新增 `session: Any = None` 参数并保存为 `self._session`。
- `execute` 在 `save_pending_question(...)` 前计算并传入：
  `sender_id = getattr(self._session, "sender_id", "") or "" if self._session else ""`
  （新增 `sender_id` 形参传给 `save_pending_question`）。

### 5. `server/data/conversation_store.py`

- `_ensure_db` 在 `CREATE TABLE pending_questions` 之后，按既有幂等模式补列：
  ```python
  pq_cols = {row[1] for row in conn.execute("PRAGMA table_info(pending_questions)").fetchall()}
  if "sender_id" not in pq_cols:
      conn.execute("ALTER TABLE pending_questions ADD COLUMN sender_id TEXT NOT NULL DEFAULT ''")
  ```
- `save_pending_question`：签名加 `sender_id: str = ""`，INSERT/UPDATE 带上该列。
- `get_pending_question`：SELECT 与返回 dict 增加 `sender_id`。

### 6. `server/ws/endpoints.py`

- `user_answer` 分支调用 `resume_after_answer(...)` 时追加最后一个参数 `pending.get("sender_id", "")`。

### 7. 测试

- **扩展** `server/tests/test_send_teammate_message_session.py`：`send_teammate_message`
  投递的 `extra` 现在同时为 `{"session_id": ..., "sender_id": ""}`，断言 `extra["sender_id"] == ""`
  （用户直发不应回发给任何 agent）。
- **新增** `server/tests/test_member_reply_sender.py`（沿用现有 `MagicMock/AsyncMock` patch 风格）：
  - 用户直发（负载 `sender_id=""`）→ 成员处理后**不**调用回发 `_dispatch_agent_message`；
  - 上级 top 直发（`sender_id="top"`）→ 成员总结回发给 `top`；
  - **平级/下级（成员）发送**（`sender_id="peerA"`，且该发送方已是团队成员）→
    成员总结回发给 `peerA`（断言 `_dispatch_agent_message` 的 `[peerA]`），并确认走
    成员分支而非被顶部隔离拒绝；
  - 无 `sender_id` 老负载 → 回退 `leader_id`，保持旧行为（防回归）。
- **更新** `server/tests/test_ask_persist.py`：`save_pending_question/get_pending_question`
  `sender_id` 落库往返（签名默认 `""`，既有用例不破坏）。
- 既有用例（test_fix_noop_tools 的“成员回复 leader”、test_8items_rest_api 成员负载
  `leader_id="leader-1"` 无 `sender_id`）走回退分支，**不需改动**。

## 假设与决策

- 用户不是 agent，无法经 `_dispatch_agent_message` 参与投递；其与成员对话的回复已由
  WS 实时推送到 teammates 窗口，故用户直发言下成员总结“不转发给任何 agent”。
- `leader_id` 语义保持不变（成员认识自己上级），仅新增 `sender_id` 表达“本条发送方”。
- `sender_id` 缺失时回退 `leader_id`，保证老路径与旧负载向后兼容。
- 覆盖 ask/resume 边缘需在 `pending_questions` 增加一列（幂等迁移，低风险）。
- 发送方为“平级/下级（成员）”时，回发依赖 `_dispatch_agent_message` 的成员分支按 roster 解析
  （该分支本就无隔离拒绝）；**不改动**现有团队隔离与 `_find_roster_member` 解析逻辑。
- 回发目标的可达性由既有 roster / `_find_roster_member` 决定：能被寻址的发送方即可收到
  总结；沿现有团队成员拓扑可达者（top、直属成员、上级 roster 的平级成员）均覆盖。

## 验证

1. `cd server/tests && python -m unittest test_send_teammate_message_session test_member_reply_sender test_ask_persist -v`
2. 回归：`python -m unittest test_fix_noop_tools test_8items_rest_api test_team_resolve test_stop_cascade -v`
3. `python -m unittest discover -s . -q`（视目录大小选择性全量）
4. `GetDiagnostics` 检查改动文件无语法/导入错误。
5. 行为验证（重启后端后手工）：
   - teammates 窗口直接给成员发消息 → 成员完成后，teammates 窗口出现其流式回复，
     **且 top agent 主会话不出现**该总结；
   - 顶部 agent `send_message` 给成员 → 成员总结回发给 top（主会话可见，协作不变）；
   - 平级/下级 agent 给成员发消息（若该路由可用）→ 成员总结回发给该平级/下级，而非 top；
   - 成员 `ask_user_question` 提问→用户回答→续跑完成后，总结仍只回到原发送方。