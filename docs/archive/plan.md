# Tree 项目 8 大项改造 — 侦察与实施方案（v1）

> 顶层 Agent 侦察汇总（2026-08-22）。所有改动分阶段 git 提交，测试齐全。
> 可靠模型：deepseek-v4-flash-official（`server/configs/models/deepseek-v4-flash_official.yaml`）。

---

## 0. 代码地图（侦察结论）

**前端（Flutter，lib/）**
- `ui/pages/main_page.dart`：三栏布局（左 AgentList / 中 MessagePanel / 右 FilePanel），
  已有 `_leftCollapsed/_rightCollapsed` 折叠与 `_collapsedWidth=40` 窄条（顶部小按钮展开）。
- `ui/widgets/message_panel.dart`：核心消息面板。`_modeLocked` 会话锁定、
  `_handleSend`（带 session_id）、`_handleStop`（发 WS stop）、多会话管理
  （_handleSelectSession/_handleCreateSession/_handleRenameSession/_handleDeleteSession）。
- `ui/widgets/session_picker.dart`：会话下拉。现有：标题栏右键（仅当前会话）弹重命名/删除；
  **缺**：下拉列表项内右键。
- `ui/widgets/message_list.dart`：agent 消息 `MarkdownBody(selectable:true)` → 选择被拆断；
  空态文案"暂无消息"。
- `ui/widgets/create_agent_dialog.dart`：模型下拉 + 系统提示词输入（模型信息修改可复用）。
- `io/api_service.dart`：REST 封装（getModels/createAgent/getSessions 等）。

**后端（FastAPI，server/）**
- `ws/endpoints.py`：WS 路由。`user_message→_dispatch_user_message`、`stop→_cancel_active_task`。
- `agent/chat.py`：`_handle_user_message`（session_id 透传 OK）、`_stream_agent_reply`（协作式取消，
  cancel_event 检查点在 `session.chat` 生成器 yield 间隙，**阻塞在 tool/LLM 时停止无效**）、
  `_build_member_topology_text`（system prompt 注入成员，**优先 team_store 表**，OK）。
- `llm/llm.py`：`_run_completion_loop`（385）工具执行 `handler(**args)` **同步阻塞、无取消检查**；
  `_build_api_kwargs`（265）messages 直接传 self.context（vision 支持需改消息格式）。
- `agent/routes.py`：`create_agent_endpoint` 无条件 `init_team_for_top`（团队表数据与模式无关）；
  `get_agent_teammates` **读工作空间 .self/team_roster.md 文件**（跨模式丢失根因）。
- `tool/team_tool.py`：`_load_roster` 优先 team_store 表（OK）；`_save_roster` 写文件。
- `data/team_store.py`：teams/team_members 表（SQLite conversations.db，权威源）。
- `data/team_init.py`：TOP 建队（16 角色，写表 + roster 视图经 docker exec）。
- `tool/read_tool.py`：141 行，读文本文件；无图像支持。
- `config/models.py`：ModelConfig（name/base_url/api_key/model_id/api_model_id/thinking + extra；
  未知字段进 extra → `if_vision` 可直接放 yaml 顶层进 extra 或加显式字段）。
- `data/embed_model.py`：读 `configs/embed_model.yaml`，支持 dimensions；`max_input_length` 未用于截断。
- `mcp_tools/`：`server.py`（stdio MCP，暴露 embed_search）、`document_server.py`、`embed_search_tool.py`。

**配置**
- `configs/models/`：deepseek-v4-flash.yaml、deepseek-v4-flash_official.yaml、qwen3_7_plus.yaml、model.example.yaml。
- `configs/embed_model.yaml`：已配（base_url=192.168.0.111:8393，dimensions=1024，max_input_length=512）。

---

## 1. 多会话模式锁定跨会话隔离（后端为主）

**问题**：其他会话的消息发到默认会话（消息路由串会话）。
**方案**：
- 后端：审计消息全链路 session_id 透传（`_handle_user_message` → `_stream_agent_reply` →
  `_store_message`/WS 推送/`save_context`；tool 执行、agent_status、usage 全部带 session_id），
  修复缺失/回退 DEFAULT_SESSION 的点。
- 前端：`_modeLocked` 保持"按历史动态判断"（有历史锁定、空会话不锁），切换/新建会话时
  `_loadHistory` 已正确重置；确认模式锁定状态不与会话串扰（lock 状态按 agent+session 记忆可选）。
- 验证：多会话并发发消息，各会话历史/上下文独立，互不串。

## 2. 会话右键 + 停止按钮 + team 跨模式

### 2a 会话下拉窗内右键重命名/删除（前端）
- 把 `SessionPicker` 的 `PopupMenuButton` 下拉改为自定义下拉列表（`MenuAnchor` 或 Overlay），
  列表项包 `GestureDetector(onSecondaryTapDown)`，右键/长按该项弹出该会话的重命名/删除菜单。
- 默认会话项禁用右键操作。

### 2b 停止按钮中止 tool loop（后端）
- `llm.py`：`AgentLLMSession` 增加可选 `cancel_event`（threading.Event）或回调；
  `_run_completion_loop` 在每轮循环开始、每次 tool_call 执行前检查取消 → 停止并 yield cancelled。
- `chat.py`：`_stream_agent_reply._consume` 已检查 cancel_event；把 cancel_event 传入 session.chat，
  使阻塞环节之间可快速响应停止。
- terminal 等长命令：给 `TerminalTool` 执行加超时（可配置，默认如 120s），超时返回错误并继续，
  避免无限阻塞；停止时不再启动新 tool。

### 2c team 跨模式保留（后端）
- `routes.get_agent_teammates` 改为**优先 team_store 表**（权威），表空回退 roster 文件；
  实时状态叠加 `_active_tasks`。
- `team_init._write_roster_view`：roster 视图写入位置兼容 cloud/local/ssh（必要时写本地与容器双份，
  或 teammates 统一读表后不再依赖文件）。
- `team_broker.py` 与 `_dispatch_agent_message` 的 roster 读取同样优先表。

## 3. 右侧面板扩展：MCP 配置 + 模型信息

**后端新增 REST**：
- `GET/POST/DELETE /api/mcp/services`：列出/注册/删除 MCP 服务（MCPManager 支持 stdio 外接）。
  内置服务：embed_search（workspace）、document_server。
- `PATCH /api/agents/{id}`：修改 model_id / system_prompt（agent_store 加 update）。
- `GET /api/agents/{id}/models-info`：返回可用模型池（含 max_seqlen/thinking/if_vision 等 info）。

**前端右栏**：FilePanel 改为 Tab 容器（文件管理 / MCP 配置 / 模型信息）。
- MCP 配置页：服务列表 + 开关/注册表单（名称 + 命令 + 参数）。
- 模型信息页：复用 create_agent_dialog 的模型下拉 + system_prompt 编辑，提交 PATCH；
  展示模型 info 卡片（max_seqlen、thinking、base_url 脱敏等）。

## 4. 消息 markdown 选择/复制（前端）
- 方案：agent 消息保留 MarkdownBody 渲染，但气泡增加"复制全文"按钮（SelectableText 的
  SelectionArea 无法根治拆段）；或用 `SelectionArea` 包裹 + 长按弹出"复制全文"。
- 推荐：气泡右上 hover 出现"复制"按钮 + `MarkdownBody` 外层 `SelectionArea` 兜底；
  纯文本消息用 `SelectableText`（已如此）。

## 5. 桌面图标（资源）
- 用原图 `屏幕截图 2026-08-12 183834.png` → Python PIL 处理：裁方 → 圆角 → 300x300 PNG；
  生成 windows ico（多尺寸）与 web favicon；按 Flutter 平台资源约定放置
  （windows/runner/resources/app_icon.ico、web/icons/、android mipmap 可选）。
- 检查 `flutter_launcher_icons` 或手写脚本。

## 6. embed 模型适配（后端）
- 确认 `embed_search_tool.py` 读取 `configs/embed_model.yaml`（load_embed_model_config）；
  增加 `max_input_length` 截断保护（超长文本截断后 embedding）。
- 若 embed 服务未挂载（mcp server 或 REST），补 REST `POST /api/embed/search`。

## 7. read_tool 图像输入（后端 + 模型配置）
- 模型 yaml 顶层加 `if_vision: true`（ModelConfig 加显式字段 or extra 读取）。
- read_tool：参数扩展 `image: true`（或自动识别扩展名 .png/.jpg/.jpeg/.webp/.gif），
  读取二进制 → base64，返回 `{image_base64, mime, width?, height?}`。
- llm.py：上下文中的图像内容转 OpenAI vision 格式：
  `content: [{type:"text", text:"..."}, {type:"image_url", image_url:{url:"data:<mime>;base64,<...>"}}]`。
  - 用户消息含图片附件 → user message content 数组；
  - read 工具结果含图像 → tool 结果文本插入一个标记 + 图像 content（或下一轮 user 消息携带）。
- 非视觉模型（if_vision 缺失/ false）：read 图像返回"该模型不支持图像"提示。
- 视觉请求仅当模型 if_vision=true 时构造（deepseek-v4-flash-official 若无视觉则标记 false，
  由模型 yaml 决定）。

## 8. UI 体验优化（前端）
- 左栏：Agent 列表较少时空位区域点击也可折叠（或在 header 折叠按钮已存在基础上，
  空白处右键/双击折叠）；agent 多时保持 header 折叠按钮可达。
- 折叠窄条：整条可点击展开（不只顶部按钮）；保留竖排文字。
- 空消息："你好👋，欢迎使用 Tree"（居中排版，emoji 与文字分行）。
- 邻近缩放：窗口缩放时三栏按比例自适应（LayoutBuilder 已用）；补充"Ctrl+滚轮缩放 UI"或
  布局缩放因子（与用户确认后实现）。

---

## 阶段提交计划（便于回滚）
1. commit A：后端 bug 修复（会话隔离、停止中止、team 跨模式、embed 接入、read_tool 图像）+
   对应 pytest。
2. commit B：后端新增 REST（MCP 服务、agent PATCH、models-info）+ pytest。
3. commit C：前端（会话右键、右栏 Tab、markdown 复制、UI 体验）+ flutter analyze/test。
4. commit D：桌面图标资源。
5. commit E：测试全量回归 + 文档 + spec 沉淀。
