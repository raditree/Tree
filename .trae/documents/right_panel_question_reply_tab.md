# 计划：右侧面板新增「问题回复」Tab（统一汇总并答复所有提问）

## 摘要

`AskUserQuestion` 工具当前只把提问以**内联卡片**插入中栏消息流，问题会被后续模型输出淹没、难以找回。本次改动在右侧面板新增一个「问题回复」顶层 Tab，把提问**统一汇总**到右侧，支持查看与答复。

已确认的设计（用户拍板）：
- **保留**中栏内联卡片，同时新增右侧提问页（两处都能作答）。
- 展示范围：**按当前会话分离、但包含所有 agent**（含团队成员提问）。
- 待回答 + 已回复的历史问题都显示，待回答置顶。
- **导航定位**：点击右侧某条提问可**跳转到中栏对话框对应的提问上下文位置**（自动切到该提问所属 agent/会话，并滚动定位到该提问卡片处）。**成员提问**则打开该成员的工作进度详情窗口并滚动定位（主面板不持久化成员提问卡片）。

关键技术事实（已核实）：
- `sessions` 表 `PRIMARY KEY (session_id)`，`session_id` 全局唯一；默认会话 `session_default` 各 agent 共用 → 按 `(user_id, session_id)` 查 `pending_questions` 即可拿到「当前会话 + 所有 agent」的问题。
- 提问已持久化在 [pending_questions](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/conversation_store.py#L614-L646)（含 `agent_id/top_agent_id/session_id/is_member/question/options/answer/status`），无需新增数据表。
- 答复链路（`mark_pending_answered` + 回写历史消息 + `resume_after_answer` 唤醒）已在 [ws/endpoints.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/endpoints.py#L184-L229) 的 `user_answer` 分支实现，可复用同一套函数。

---

## 现状分析

- 提问工具 [ask_question_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/ask_question_tool.py#L108-L161) 落库 + 写历史 + 推 `ask_user_question` WS 事件 + 返回暂停哨兵。
- 中栏 [message_panel.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/message_panel.dart#L449-L512) 收到 `ask_user_question` 后插入内联卡片（`_AskQuestionCard`），用户作答走 `_handleAskAnswer` 发送 WS `user_answer`。收到 `ask_user_question_resolved` 目前**未处理**。
- 右侧面板 [file_panel.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/file_panel.dart#L82-L83) 顶层 3 个 Tab（文件 / MCP 配置 / 模型信息），`_tabController` 长度 3；已接收 `sessionId` 参数（Todo 面板会话隔离同款）。
- 全局 ChangeNotifier 模式已有先例：[workspace_refresh_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/workspace_refresh_service.dart)。
- 右侧面板仅在选中 agent（`workspaceId` 非空）时渲染 `FilePanel`，未选中时显示占位。**结论**：提问页挂在 `FilePanel` 内，未选 agent 时不可见（可接受的边界，见决策）。

---

## 改动方案

### 后端

#### 1. `server/data/conversation_store.py` — 新增列表查询
在 `mark_pending_cancelled` 之后新增：

```python
def list_questions(
    user_id: str, session_id: Optional[str] = None
) -> List[Dict[str, Any]]:
    """按用户（可选按会话过滤）列出全部提问，按创建时间倒序。
    返回字段与 get_pending_question 一致（options 解 JSON、is_member 转 bool）。
    """
```
- `session_id` 为空时返回该用户全部提问；否则仅返回该会话的。
- 复用 `_connect()` / `conn.row_factory = sqlite3.Row`，与 `get_pending_question` 同风格；options 字段 `json.loads` 容错。

#### 2. `server/agent/routes.py` — 新增两个 REST 端点
沿用 `get_current_user` 依赖（`openid`），`router` 前缀已是 `/api`：

- `GET /api/questions?session_id=xxx`
  - 返回 `{"questions": [...]}`（调 `list_questions(user_id, session_id)`；`session_id` 缺省不过滤）。
- `POST /api/questions/{qid}/answer`，body `{"answer": "..."}`
  - 复用现有函数：`get_pending_question(qid)` → 校验存在且 `status == "pending"` 且 `user_id` 归属当前用户；失败抛 `HTTPException(400/403)`。
  - 成功：`mark_pending_answered(qid, answer)`；`state.ws_manager.send_message(user_id, {"type": "ask_user_question_resolved", "data": {"id": qid, "session_id": ...}})` 供中栏同步；`asyncio.create_task(resume_after_answer(pending["user_id"], pending["agent_id"], pending["top_agent_id"], pending["session_id"], answer, pending["is_member"], pending.get("sender_id", "")))`。
  - 需在文件顶部 import：`mark_pending_answered`、`get_pending_question`、`resume_after_answer`、`list_questions`。
  - **不改动** WS `user_answer` 分支（保持既有行为零回归），REST 端点只是等价的新入口。

### 前端

#### 3. `lib/io/api_service.dart` — 新增两个 API
- `static Future<List<Map<String, dynamic>>> getQuestions({String? sessionId})`
  - `_getJson('/api/questions', query: sessionId 非空时 {'session_id': sessionId})`，取 `data['questions']`。
- `static Future<void> answerQuestion(String qid, String answer)`
  - `_postJson('/api/questions/$qid/answer', body: {'answer': answer})`。

#### 4. 新增 `lib/io/question_update_service.dart` — 全局变更通知
镜像 `WorkspaceRefreshService` 的全局 `ChangeNotifier` 单例，用于「中栏 → 右栏」实时刷新：

```dart
class QuestionUpdateService extends ChangeNotifier {
  QuestionUpdateService._();
  static final QuestionUpdateService instance = QuestionUpdateService._();
  void notifyChanged() => notifyListeners();
}
```
（不节流：提问/作答事件频率低，无需合并。）

#### 5. 新增 `lib/ui/widgets/question_panel.dart` — 提问列表面板
`StatefulWidget`，参数 `{String sessionId}`。结构参照 `TodoPanel`：
- 内部模型 `_QuestionItem`（qid / agentId / topAgentId / sessionId / isMember / question / options / answer / status / createdAt），`fromJson` 解析。
- `initState`：`_load()` + `QuestionUpdateService.instance.addListener(_load)`。
- `didUpdateWidget`：`sessionId` 变化时重新 `_load()`。
- `_load()`：软更新（有旧数据不闪加载态）调 `ApiService.getQuestions(sessionId)`，`pending` 置顶、`answered`/`cancelled` 在后。
- 渲染：
  - 空态「暂无提问」。
  - 每张卡片：提问文本 + 来源标签（`ApiService.getAgents()` 映射 `top_agent_id` → agent 名；`is_member` 加「成员」前缀，无映射回退显示 `agent_id`）+ 状态徽标（待回答/已回复/已取消）。
  - `pending`：选项按钮 + 「或直接输入回答…」输入框（复用 `_AskQuestionCard` 交互样式）；提交调 `ApiService.answerQuestion(qid, answer)`，成功后本地置 `answered` 并 `QuestionUpdateService.instance.notifyChanged()` 刷新自身，错误用 SnackBar 提示。
  - `answered`：置灰选项 + 显示「已回复：xxx」；`cancelled`：显示「已取消」。
- 作答成功不依赖 WS；中栏内联卡片由后端 `ask_user_question_resolved` 同步（见第 6 点）。

#### 6. `lib/ui/widgets/file_panel.dart` — 增加「问题回复」Tab
- `_tabController = TabController(length: 4, ...)`（原 3）。
- `_buildTopTabBar` 的 `tabs` 追加 `Tab(text: '问题回复')`；若 4 个 tab 在窄面板放不下，给 TabBar 包 `isScrollable: true`（保持现有 `labelStyle` 等）。
- `TabBarView` children 追加 `QuestionPanel(sessionId: widget.sessionId)`。
- 现有「点击空白折叠右栏」的外层 `GestureDetector` 无需改动（子项交互优先消费）。

#### 7. `lib/ui/widgets/message_panel.dart` — 双向同步
- `_handleAskUserQuestion`（收到新提问）末尾：`QuestionUpdateService.instance.notifyChanged()`，让右栏即时出现新问题。
- `_handleAskAnswer`（中栏作答）末尾：`QuestionUpdateService.instance.notifyChanged()`，让右栏标记已回复。
- `_handleIncomingMessage` 新增分支：
  ```dart
  } else if (type == 'ask_user_question_resolved') {
    final String id = ((data['data'] as Map?)?['id'] as String?) ?? '';
    final int idx = _messages.indexWhere((m) => m.id == id);
    if (idx >= 0) {
      setState(() => _messages[idx].answered = true);
    }
  }
  ```
  （右栏作答后中栏内联卡片即时置灰。）

#### 8. 导航定位：中栏滚动到指定提问卡片（通用机制）
新增一条「右侧提问 → 中栏/成员窗口定位」链路：`QuestionPanel → FilePanel → MainPage →（主 agent：MessagePanel → MessageList / 成员：TeammateDetailPage → MessageList）`。

**`lib/ui/widgets/message_list.dart`** — `MessageList`/`_MessageListView` 新增两个可选参数：
- `String? scrollToMessageId`、`int scrollToRevision`（外部递增触发定位）。
- `_MessageListViewState`：
  - 维护 `final Map<String, GlobalKey> _itemKeys`；`itemBuilder` 中每条消息外层用 `GlobalKey(key: ValueKey(message.id))` 包裹（`GlobalObjectKey` 亦可），保证定位目标可寻址。
  - 维护 `String? _highlightedId` 与 `Timer? _highlightTimer`。
  - `didUpdateWidget` 中检测 `scrollToRevision` 变化且 `scrollToMessageId` 非空：`postFrameCallback` 后执行 `_scrollToMessage(id)`。
  - `_scrollToMessage(id)` 算法（兼容**目标未构建**的远距离消息，无需估算高度）：
    1. `idx = messages.indexWhere((m) => m.id == id)`；`idx < 0` 直接返回。
    2. `key = _itemKeys[id]`；若 `key?.currentContext != null`（已构建）→ `Scrollable.ensureVisible(key.currentContext!, alignment: 0.2, duration: 300ms)`，随后设 `_highlightedId = id` 并启动 2 秒 `_highlightTimer` 清除。
    3. 若未构建（`ListView.builder` 懒加载、目标在视口外）→ 先按比例粗跳：`_controller.jumpTo(maxScrollExtent * (idx / messages.length))`，再 `addPostFrameCallback` 重试一次 `_scrollToMessage(id)`（此时目标已被构建，走第 2 步精确定位）。粗跳基于位置比例，但最终 `ensureVisible` 保证精确，目标必达。
  - 高亮表现：命中卡片外层 `Container` 在 `_highlightedId == message.id` 时加主题色边框/浅色背景，2 秒后还原（也便于 `ensureVisible` 后用户一眼看到位置）。
- 该机制被中栏 `MessagePanel` 与成员窗口 `TeammateDetailPage` 复用（见第 12 点）。

**`lib/ui/widgets/message_panel.dart`** — `MessagePanel` 新增两个可选参数：
- `String? navigateMessageId`、`int navigateTrigger`（MainPage 传入，递增触发）。
- 内部字段 `String? _pendingScrollId`：
  - `didUpdateWidget`：若 `navigateTrigger` 变化且 `navigateMessageId` 非空 → 记录 `_pendingScrollId`；若目标会话 ≠ `_currentSessionId`，先 `setState` 切换 `_currentSession` 并 `widget.onSessionChanged?.call(...)`，再 `_loadHistory()`；若 agent 已变化，则走既有 agent 切换路径（`_loadSessions` → `_loadHistory`），`_pendingScrollId` 在历史加载后消费。
  - `_loadHistory` 末尾：若 `_pendingScrollId != null`，则**不递增 `_scrollRevision`**（避免先滚底再跳位的闪烁），改为 `setState(() { _scrollToMessageId = _pendingScrollId!; _scrollToRevision++; _pendingScrollId = null; })`，并透传给 `MessageList`。
- 需要新增字段 `int _scrollToRevision = 0;` 与 `String? _scrollToMessageId;`。

#### 9. `lib/ui/widgets/question_panel.dart` — 新增导航回调
- `QuestionPanel` 增加参数：
  ```dart
  final void Function({
    required bool isMember,
    required String agentId,     // 提问方 id（成员提问时为成员 id）
    required String topAgentId,
    required String sessionId,
    required String messageId,
  })? onNavigateToQuestion;
  ```
- 每条提问卡片的来源标签行/「定位」按钮可点击 → 按上述签名回调（`topAgentId` 为空时回退用 `agentId`）。
- 若回调为空则不显示定位入口（兼容无 MainPage 场景）。

#### 10. `lib/ui/widgets/file_panel.dart` — 透传导航回调
- `FilePanel` 增加同名回调参数，原样转发给 `QuestionPanel`。

#### 11. `lib/ui/pages/main_page.dart` — 处理导航
- 新增状态：`String? _navigateMessageId; int _navigateTrigger = 0;`
- `_buildFilePanel()` 的 `FilePanel` 增加 `onNavigateToQuestion: _handleNavigateToQuestion`。
- `_handleNavigateToQuestion({required bool isMember, required String agentId, required String topAgentId, required String sessionId, required String messageId})`：
  - **主 agent 提问**（`!isMember`）→ 切中栏上下文 + 滚动定位：
    ```dart
    final Agent? target = _agents.where((a) => a.id == agentId).firstOrNull;
    if (target == null) { /* SnackBar：对应 Agent 不存在或已删除 */ return; }
    setState(() {
      _selectedAgent = target;
      _currentSessionId = sessionId;
      _navigateMessageId = messageId;
      _navigateTrigger++;
    });
    ```
  - **成员提问**（`isMember`）→ 打开成员进度详情窗口并滚动定位（不动中栏上下文）：
    ```dart
    final Agent? leader = _agents.where((a) => a.id == topAgentId).firstOrNull;
    if (leader == null) { /* SnackBar：所属 Agent 不存在或已删除 */ return; }
    final String memberName =
        (await ApiService.getTeammates(leader.id))
            .where((m) => m['id'] == agentId)
            .map((m) => (m['name'] as String?) ?? '')
            .firstOrNull ?? '';
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TeammateDetailPage(
        leader: leader,
        memberId: agentId,
        memberName: memberName.isNotEmpty ? memberName : agentId,
        sessionId: sessionId,
        scrollToMessageId: messageId,   // 进度页加载后滚动定位
      ),
    ));
    ```
- 中栏 `MessagePanel` 增加 `navigateMessageId: _navigateMessageId, navigateTrigger: _navigateTrigger`。
- 需要 import `teammates_window_page.dart` 中的 `TeammateDetailPage`。

#### 12. `lib/ui/widgets/teammates_window_page.dart` — 成员窗口定位
- `TeammateDetailPage` 增加可选参数 `String? scrollToMessageId`。
- 新增字段 `int _scrollToRevision = 0;` 与 `String? _scrollToMessageId;`。
- `_loadHistory` 中，把现有的 `_scrollRevision++` 改为**条件触发**，避免「先滚底、再跳位」的闪烁：
  ```dart
  setState(() {
    _liveMessages.clear();
    for (final item in history) {
      _liveMessages.add(ChatMessage.fromJson(item));
    }
    if (widget.scrollToMessageId != null) {
      _scrollToMessageId = widget.scrollToMessageId;
      _scrollToRevision++;        // 触发 MessageList 定位滚动
    } else {
      _scrollRevision++;          // 原逻辑：滚动到底部
    }
  });
  ```
- 进度页 `MessageList` 透传：`MessageList(messages: _liveMessages, revision: _scrollRevision, scrollToMessageId: _scrollToMessageId, scrollToRevision: _scrollToRevision)`（`_scrollToMessageId` 一旦消费后无需清空，revision 递增才触发）。
- **关键依据（已核实）**：成员提问经 [ask_question_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/ask_question_tool.py#L141-L152) 以 `store_message(user_id, agent_id=成员id, kind="ask_user_question", msg_id=qid)` **落库在成员名下**；`get_history(memberId, sessionId)`（[conversation_store.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/conversation_store.py#L342-L366)）返回 `kind/options/answered`，`ChatMessage.fromJson` 正确解析 → 成员历史里天然包含该提问卡片且 `message.id == qid == scrollToMessageId`，直接复用第 8 点的 `MessageList` 定位+高亮机制即可，无需在成员侧新增任何查询。
- 进度页 `MessageList` 不传 `onAskAnswer`，卡片只读展示（成员提问由右栏作答）。

---

## 决策与边界

- **保留内联卡片**：中栏仍展示提问上下文，仅新增统一入口，两处可答。
- **会话隔离 + 所有 agent**：`GET /api/questions` 按 `session_id` 过滤、不过滤 agent，因此团队成员提问也汇总进来；跨 agent 的 `session_default` 会聚合展示（符合「所有 agent」语义）。
- **待答 + 已答都显示**：`pending` 置顶可交互，`answered`/`cancelled` 置灰在后。
- **作答入口**：右栏走 REST（无需在右栏再建 WS 连接），中栏保持 WS `user_answer` 不变，两条路径后端收敛到同一套逻辑。
- **导航定位**：
  - 主 agent 提问 → 自动切换中栏到该提问所属 **top agent** 与会话，历史加载完成后滚动定位到该提问内联卡片并短暂高亮；重复点击同一条（触发号递增）仍可再次定位。
  - **成员提问** → 打开该成员的工作进度详情窗口（`TeammateDetailPage`）并滚动定位到该提问（成员提问卡片已在成员历史中，刷新后仍在）；**不改变**中栏/左栏当前上下文，也不持久化成员提问卡片到主面板历史。
- **未选 agent 时右栏为占位**：提问页不可见（沿用现状），不做右栏结构重构。
- **不做**：删除内联卡片、按 agent 过滤、提问去重、取消功能 UI、后端进程改动（改完需用户确认重启）。

---

## 验证

**后端**
- 扩展 `server/tests/test_ask_persist.py`（或新增用例）：
  - `list_questions`：造 2 个用户/2 会话的问题，校验会话过滤、倒序、字段解析。
  - `POST /api/questions/{qid}/answer`：无记录 400 / 非本人 403 / pending 成功（`status=answered`、历史消息回写、`resume_after_answer` 被触发——mock 或仅验证返回）。
- 运行 `pytest tests/` 冒烟，确认既有 `test_ask_persist.py`、`test_member_reply_sender.py` 无回归。

**前端**
- `flutter analyze` 无错误。
- 手动：
  - 让主 agent 提问 → 右栏「问题回复」页出现该问题（待回答），中栏内联卡片仍存在。
  - 从右栏作答 → 右栏卡片变「已回复」，中栏对应内联卡片即时置灰，agent 自动续跑。
  - 让**成员**提问 → 右栏汇总显示（带「成员」标签），可答、成员续跑。
  - **导航定位（主 agent）**：在右栏点击某条主 agent 提问 → 中栏自动切到对应 agent/会话，滚动到该提问卡片并短暂高亮；点同一提问第二次仍能重新定位；点属于另一 agent 的提问 → 左栏选中态、中栏标题、右栏工作空间都随之切换。
  - **导航定位（成员）**：在右栏点击某条成员提问 → 自动打开该成员的工作进度详情窗口，滚动定位到该提问卡片并高亮；中栏/左栏当前上下文不被改动。
  - 切换会话 → 右栏提问列表按会话刷新；刷新页面后右栏列表与历史一致。
  - 未选中 agent 时右栏保持原占位，不报错。

**生效方式**：后端改动需重启服务（按既有偏好，实施完成后由用户确认重启）；前端改动热重载即可。
