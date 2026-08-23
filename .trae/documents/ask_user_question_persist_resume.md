# 计划：AskUserQuestion 持久化 + 暂停本轮 + 答完唤醒（含团队成员）

## 摘要

把"向用户提问"从**阻塞等待（10 分钟超时）**改为**持久化型异步提问**：

- 问题持久化到 SQLite，并作为会话历史消息展示。
- agent 提问后**主动暂停本轮**（不再阻塞线程、立即回到空闲），前端卡片可见可答。
- 用户作答（无论多久、是否断线/刷新）后，后端注入答案到该 agent 的 LLM 上下文，**自动恢复继续执行**。
- 覆盖主 agent 与团队成员。

已确认：**teammates 的提问会出现在主会话消息里、用户能回复**——因为后端 `ws_manager.send_message(user_id, ...)` 按用户推送，且前端 `_handleAskUserQuestion` 不按 agent 过滤。

---

## 现状与根因

- [ask_question_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/ask_question_tool.py#L126) `event.wait(timeout=600)` 阻塞工具线程；超时后 `_pending` 移除，答案被丢弃。全程线程挂起、agent 不干活。
- 问题不走历史：只是瞬态 WS 事件，内存 `_ask_registry`（按 user 单例）持有，断线/刷新/重启即丢。
- 提问 payload 无 `agent_id`/`session_id`，AskUserQuestionTool 只带 `user_id`，无法定位"哪个 agent、哪个会话"来唤醒。
- [llm.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/llm/llm.py#L680-L746) 工具循环每轮调 `handler(**args)` 后继续循环；目前 ask 会一直阻塞这个循环。

核心改动：让 ask 工具的 `execute` **不阻塞**地返回一个"暂停哨兵"，工具循环检测到后停止本轮并触发持久化与闲置，作答后经现有 broker/消息派发通道重新触发一轮。

---

## 决策（已与用户确认）

1. **覆盖范围**：主 agent + 团队成员。
2. **唤醒**：作答后自动继续（注入答案、重新触发该 agent 的执行）。
3. **超时**：无超时（用户可查数小时资料）。

---

## 数据模型

### 新增表 `pending_questions`（存活态；重启后可路由）
在 [conversation_store.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/conversation_store.py) 新增：

```
pending_questions(
  qid TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,          -- 实际提问的 agent（主 agent 或成员 id）
  session_id TEXT NOT NULL,
  is_member INTEGER DEFAULT 0,     -- resume 走成员分发还是主 agent 分发
  question TEXT NOT NULL,
  options TEXT DEFAULT '[]',       -- JSON 数组
  answer TEXT,
  status TEXT DEFAULT 'pending',   -- pending / answered / cancelled
  created_at INTEGER NOT NULL
)
```

CRUD：`save_pending_question` / `get_pending_question(qid)` / `mark_pending_answered(qid, answer)` / `mark_pending_cancelled(qid)`。

### `messages` 表扩展（会话历史可见、断线/刷新后重投递卡片）
- 新增列：`answer TEXT`、`answered INTEGER DEFAULT 0`；选项复用 `tool_arguments`（JSON 存 `options` 数组）。
- 提问时写入一条 `kind='ask_user_question'` 的 message（`msg_id=qid`）；作答时把该行 `answered=1`、`answer` 写入。
- `get_history` 返回 `options`/`answered`/`answer`，供前端刷新后重建卡片并恢复可答状态。

---

## 后端改动

### 1. `data/conversation_store.py`
- `_ensure_db`：新增 `pending_questions` 建表；给 `messages` 补 `answer`/`answered` 列。
- `store_message`：增加可选 `answer`/`answered`/`msg_id` 参数。
- 新增 `pending_questions` 四组 CRUD 函数。
- `get_history`：SELECT 并返回 `answer`/`answered`，从 `tool_arguments` 解出 `options`。

### 2. `tool/ask_question_tool.py`
- `__init__` 增加参数：`agent_id`、`session_id`、`is_member`（bool），`top_agent_id` 可选。
- `execute(arguments)`：改为**不阻塞**：
  1. 生成 `qid`；`save_pending_question(...)`（status=pending）。
  2. 写一条 `kind='ask_user_question'` 的历史 message（`msg_id=qid`，`options`）。
  3. 推送 `ask_user_question` payload（在 id/question/options 基础上**追加 `agent_id`、`session_id`**）。
  4. 返回哨兵：`{"__ask_paused__": True, "qid": qid}`。
- 删除 `event.wait` 超时阻塞；删除 `resolve`/`cancel` 线程逻辑（改由 DB + chat.py 驱动）。
- 保留 `_notify_user`（payload 更新）。

### 3. `llm/llm.py` 工具循环（L680-746）
- `result = handler(**args)` 后，检测 `isinstance(result, dict) and result.get("__ask_paused__")`：
  - 若命中：把该工具结果写为占位 `{"role":"tool","tool_call_id":..., "content":"等待用户回答…"}`（保持上下文一致，供后续续跑），**跳过 current_todo 注入/图像追加**，然后停止本轮。用模块内哨兵异常 `_AskPaused(qid)` 终止 `chat()` 内部循环（不再 `continue`）。
- 这样上下文里保留：assistant(tool_calls) + tool 占位，可供续跑。

### 4. `agent/chat.py`
- 新增 `resume_after_answer(user_id, agent_id, session_id, answer, is_member)`：
  - 若 `is_member`：走成员分发（复用 `_dispatch_agent_message`/`team_broker.dispatch`），content 为 `用户回答：…`。
  - 否则：走主 agent 分发（复用 `_dispatch_user_message`），content 同上。
  - 均通过既有 broker/新消息触发新一轮；context 已含占位 tool 信息，模型据此继续原任务。
- 在 `_handle_user_message`/成员处理的 `try/finally` 与当前 `_send_text_as_agent` 调用点外层，捕获 `_AskPaused`（来自 llm.chat）：捕获后 `session.save_context()`（或既有落库路径）**持久化当前上下文**，并 `_send_status_idle`（或新增 `_send_status_awaiting`）。保证"暂停轮"不抛错、agent 归闲、上下文落库。

### 5. `tool/__init__.py`（L220-225）
- `AskUserQuestionTool(ws_manager, user_id, agent_id=..., session_id=..., is_member=...)`：`register_builtin_tools` 已有 `user_id/agent_id/session_id`；`is_member` 由调用侧（成员处理时传 True，主 agent 时 False）决定。需要把 `is_member` 传入 `register_builtin_tools`。
- 找到成员工具注册调用点（`_process_member_message`），传 `is_member=True`。

### 6. `ws/endpoints.py`（user_answer / cancel_question，L178-206）
- `user_answer`：按 `qid` 查 `get_pending_question`。
  - 无记录或状态非 pending → 回错误"没有等待回答的问题"。
  - 否则 `mark_pending_answered(qid, answer)`；更新对应历史 message `answered=1`、`answer`；推送一条轻量 `ask_user_question_resolved`（含 qid）供前端同步状态（可选）；`asyncio.create_task(resume_after_answer(user, agent, session, answer, is_member))`。
- `cancel_question`：`mark_pending_cancelled(qid)`，不触发 resume。

---

## 前端改动

### 7. `lib/ui/models/message.dart`
- 已支持 `options`/`answered`；补 `fromJson` 解析后端新增的 `answer`/`options`（`answered` 已有）。

### 8. 断线/刷新后重投递与恢复可答（历史驱动，无需改副作用）
- 提问已作为 `kind='ask_user_question'` 历史消息落库，`getHistory` 返回它 → [message_panel.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/message_panel.dart#L236) 历史加载即重建卡片。
- 卡片 `answered` 来自后端历史 → 已答的显示"已提交"，未答的可答；**无需手动重新投递**。
- `_handleAskAnswer` 发送 `user_answer`（含 qid/answer）后标记 answered；后端应答后启动续跑，卡片下方出现新的流式输出。

### 9. （可选，后置）agent_status 侧
- 暂停时可让前端显示"等待你的回答"而非纯 idle（用 `agent_status` 带 `awaiting` 标志）。作为增强项，非必须。

---

## 边界与注意事项

- **同用户多并发提问**：`pending_questions` 按 `qid` 主键，互不冲突；`_ask_registry` 可保留为按 user 的单例（仅用于推送/WS 已足够），路由统一走 DB 的 `qid→(agent, session, is_member)`。可把 `_ask_registry` 降级为空壳或删除。
- **占位 tool 消息的续跑兼容**：部分网关对"assistant 带 tool_calls 却无对应 tool result"报 400；占位 tool result 恰好规避。续跑时该占位后的 `user: 用户回答…` 让模型完成任务。
- **重启边界**：主 agent 提问的持久化与 resume 全程 DB 驱动，**重启后仍可答、可唤醒**。成员提问：DB 记录与卡片可恢复、可标记；但成员运行时(team_broker)随后端重启重建，续跑依赖重建后的 broker 分发，属**尽力而为**，计划不额外做成员状态的跨重启重建。
- **`_asking`**：前端在 answered 后禁用输入，不会重复提交；历史驱动的 answered 状态保证刷新后不误可答已答问题。
- **不做**：diff/merge/fetch 等无关改动；不新增独立"待办提问" UI 页（沿用内联卡片）。

---

## 验证

**后端**
- 单测（`tests/test_ask_builtin.py` 或新增）：
  - `execute` 返回哨兵且落库；`pending_questions` 与历史 message（kind=ask_user_question）成对存在。
  - `user_answer` 无记录 → 200/错误分支；有记录 → 标记 answered、触发 resume（mock 分发）。
  - `get_history` 返回 options/answered/answer。
- 现有 `pytest tests/` 冒烟，确认无回归。

**前端**
- `flutter analyze` 无错误。
- 手动：
  - 让 agent 提问 → 卡片出现、agent 归 idle；不点，等 >10 分钟也不关闭（无超时）。
  - 期间刷新页面 → 卡片仍显示（历史恢复）、可答。
  - 作答 → agent 自动继续原任务，卡片变"已提交"，答案出现在上下文。
  - 让**成员**提问 → 主面板出现成员卡片，可答、成员自动续跑。

**注意**：后端改动需重启服务（按你偏好不擅动后端进程，实施后再确认）。