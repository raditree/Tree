# lib（Flutter 前端）

三栏桌面界面 + 与本地核心的传输层。**不持有业务逻辑**：所有状态取自核心的 REST/WS。

## 结构

| 位置 | 内容 |
| --- | --- |
| [main.dart](main.dart) | 启动序列：附着或拉起核心 → 读握手 → `ApiService.setToken` → 建 WS |
| [io/core_process_launcher.dart](io/core_process_launcher.dart) | 找核心可执行文件（`TREE_CORE_EXE` → 应用同目录 → `.output/`）、拉起、解析握手、退出时请它优雅退出；找不到时给**带修复指引**的错误页 |
| [io/tray_service.dart](io/tray_service.dart) | 托盘图标与菜单（恢复窗口 / 退出）、**关闭按钮的默认行为（隐藏到托盘）**与它的设置；[ui/widgets/close_to_tray_dialog.dart](ui/widgets/close_to_tray_dialog.dart) 是首次关闭时的一次性说明 |
| [io/single_instance.dart](io/single_instance.dart) | **同数据根单实例锁**：回环端口 + 带锁键的握手；被拒绝的那个实例只负责把已有窗口叫到前面（`AlreadyRunningApp` 在 [main.dart](main.dart)） |
| [io/api_service.dart](io/api_service.dart) | 全部 REST 端点的封装（唯一出网口） |
| [io/websocket_service.dart](io/websocket_service.dart) | WS 连接与重连、**10s 心跳**、帧分发 |
| [io/local_executor_service.dart](io/local_executor_service.dart) · [io/ssh_executor_service.dart](io/ssh_executor_service.dart) | per-team 执行模式配置（local/ssh 的读写与注册）；命令本身由核心执行 |
| [ui/pages/main_page.dart](ui/pages/main_page.dart) | 三栏骨架、agent 列表（顶层 agent + 团队成员）、会话切换、插件槽位作用域 |
| [ui/widgets/message_panel.dart](ui/widgets/message_panel.dart) | 中栏消息流：分段渲染、工具/思考**一行式**（完整内容见右栏「详情」页）、提问卡片、断线重播去重、按 agent+会话过滤 |
| [ui/widgets/teammates_window_page.dart](ui/widgets/teammates_window_page.dart) | 团队成员拓扑与成员工作进度窗口 |
| [ui/widgets/](ui/widgets/) | 文件面板 / 查看器 / PDF 预览、Spec、待办、提问、插件、MCP、模型信息、Git 历史、设置页 |
| [ui/services/](ui/services/) | 重播守卫、下载中心、会话重命名、插件 UI 槽位注册、主题 |

## 不变量（assertions）

1. **前端不直接读盘 / 不跑命令**（除系统文件对话框与"在资源管理器中显示"）：文件、Git、终端、模型信息一律经核心
   REST/WS；核心不可达时显示错误页而不是白屏。
2. **帧过滤**：中栏只接收当前 agent + 当前会话的帧；成员窗口只接收该成员 + 该会话的帧——否则并行会话会串台。
3. **重播去重**：断线重连后的重播帧必须按消息 id + 流式序号判掉，不得重复渲染。
4. 协议常量从 `package:tree_protocol` 取，不写字面量。
5. 密钥只读不显（模型面板走字段白名单）；日志不打印 token。
6. 左栏列出**全部 agent（顶层 + 团队成员）**（[ui/pages/main_page.dart](ui/pages/main_page.dart) 的
   `_railAgents` + `railAgentsOf`）：成员也是独立 agent 文件（`team_id` 指向 TOP），点开就是它自己的
   会话，与顶层 agent 同一条通路。顺序 = 顶层在前（保持接口顺序）＋ 成员紧跟各自的 TOP，
   `team_id` 指向的 TOP 不在列表里时兜底列在末尾——**绝不因为"找不到根"丢掉一个 agent**。
   **成员其余口径不变**：工具根 / 系统提示词 / 文件面板仍解析到 leader 的工作目录与 SSH（`teamWorkspaceFor`），
   插件作用域仍按 `teamScopeId` 回指团队，团队拓扑与成员进度仍看 teammates 窗口（不再是唯一入口）。
7. **关闭按钮默认不是退出**：`window_manager.setPreventClose(true)` 拦下 WM_CLOSE，改成隐藏窗口到系统托盘
   （核心与在跑的任务继续）；真正的退出只有两条明确路径——托盘菜单「退出 Tree」与设置页的退出按钮，
   两条都走 `TrayService.quit()`（先 `CoreProcessLauncher.stop()` 让核心优雅退出，再销毁窗口；实测关窗到
   核心 exit=0 约 0.6s）。**首次关闭先弹一次说明框**（[close_to_tray_dialog.dart](ui/widgets/close_to_tray_dialog.dart)，
   勾着「记住我的选择」时把这次选择写进设置：选退出 ⇒ `close_to_tray=false`，选后台 ⇒ 不再问）。
   两条安全底线：**托盘装不上就绝不隐藏**（`TrayService.decideClose` 退回 quit，否则用户会被关在门外）、
   **核心启动失败的错误页不拦关闭**（那里没有窗口监听者，拦下就关不掉了）。
8. **同一数据根只允许一个实例**（[single_instance.dart](io/single_instance.dart)）：UI 在**拉起核心之前**先抢一把
   回环端口锁——锁键 = 数据根（`TREE_HOME`，未设即 `default`；`TREE_INSTANCE_KEY` 可显式覆盖），
   哈希到 45800..45899。第二个实例握手通过后**立刻退出**，并请已有实例把窗口叫到前面
   （`onActivate` ⇒ `TrayService.showWindow`），绝不拉起第二个核心——两个核心共用一个数据根会互相覆盖会话。
   安全底线：端口被**别的程序**占用（握手无应答 / 回的内容不对）时**照常启动**，不能因为撞了个端口
   就把用户挡在门外。

9. **删除 agent 的两道闸门要在 UI 里变成可操作交互**（[io/api_service.dart](io/api_service.dart) 的
   `AgentDeleteBlocked` + [ui/pages/main_page.dart](ui/pages/main_page.dart)）：核心对「有下级成员」回 409 +
   `cascade_required`，UI 摊开下级清单请用户确认，再带 `?cascade=1` 重试（删掉组长会让组员变孤儿，不该一次点击就发生）；
   对「正在运行」回 409 + `running`，UI 提示「先停止并等它空闲」（`stop` 抢不动正在执行的工具，核心不替用户等待）。
   `deleteAgent` **必须解析响应体**：旧实现只看状态码，用户只会看到「删除失败（HTTP 409）」，不知道为什么、该怎么办。
   删**成员**时**不清插件作用域**——只有删团队 TOP（`teamId` 为空）才回落，否则该队的站点/槽位会被滤成「站点（0）」。

10. **输入框是卡片式，附件在发送前就能预览**（[ui/widgets/message_input.dart](ui/widgets/message_input.dart)、
    [ui/widgets/attachment_preview.dart](ui/widgets/attachment_preview.dart)）：附件预览在上、文本域在中、
    底部一行左边「+」（添加文件 / 展开输入框）、右边**只有**圆形发送键；「展开」只把文本域**原位变高**
    （0.4×窗口高，夹在 140–360），Esc 收起，**不动草稿与附件**（展开/收起不换 TextField，焦点与光标不丢）。
    附件一律可预览：图片给缩略图、其它给「图标 + 名称 + 大小」卡片，点开读**本机**文件（发送前附件还没上传，
    所以 FileViewer 那套工作空间路径的查看器在这里用不了）。判定口径两条：是不是图片看扩展名，
    **是不是文本一律看字节**（前 4 KB 出现 NUL 就当二进制，扩展名骗人的文件不会被渲染成乱码）。
    读不到就直说——「文件不存在 / 已被移动」「大小未知」，不显示 0 B、不静默、不红屏。

11. **消息流是一行式：模型消息高亮、工具与思考各占一行，完整内容去右栏「详情」页**
    （[ui/widgets/tool_call_card.dart](ui/widgets/tool_call_card.dart)、[ui/widgets/thinking_card.dart](ui/widgets/thinking_card.dart)、
    [ui/widgets/detail_panel.dart](ui/widgets/detail_panel.dart)、[ui/services/detail_selection.dart](ui/services/detail_selection.dart)）：
    模型消息是**高亮块**（左侧主色竖条 + 极淡同色底，**没有整圈边框**），用户消息仍是主色气泡；
    工具调用一行 =「中文标签 + 关键参数（等宽）」+ 行尾增量（编辑 / 写入按行数给 `+N -M`）、转圈或箭头；
    思考一行 =「思考 · 首行摘要」。**中栏不再就地展开**——一轮里工具动辄几十条，卡片会把时间线切散，
    一行之后整轮动作像一份清单。悬停有呼应（图标提亮 + 底色），点击 → 右栏**第 5 个内置页签「详情」**摊开完整参数与结果；
    右栏收着时自动展开。选中项走 [DetailSelection](ui/services/detail_selection.dart)（全局 ChangeNotifier，存消息**快照**，
    帧后按 id 刷新——跑着的工具 / 思考内容是原地变更的，必须跟着长），切 agent / 整表重拉时清空。

## 测试

```bash
flutter analyze lib test     # 必须零告警
flutter test                 # 仓库根的 test/：组件 + 假核心 HTTP/WS 测试
```

钉子用例：`test/message_replay_guard_test.dart`、`test/session_rename_test.dart`、`test/plugin_panel_admin_test.dart`、
`test/main_page_sidebar_width_test.dart`、`test/message_list_scroll_test.dart`、`test/tray_service_test.dart`（关闭决策与设置默认值）、
`test/close_to_tray_dialog_test.dart`（首次关闭说明框的返回值）、`test/single_instance_test.dart`（锁键/端口纯函数、
第二个实例被识别并唤起窗口、外人占端口不拦人）、`test/agent_delete_flow_test.dart`（删除闸门的 UI 接线：结构化 409、
级联重试、只删 TOP 才回落插件作用域）、`test/message_input_test.dart`（输入框：多文件粘贴、草稿按 team+session、
「+」菜单展开原位变高与 Esc 收起、图片缩略图 vs 文件卡、点开预览）、`test/attachment_preview_test.dart`
（附件预览：扩展名分类与大小文案、三档读取（文本 / 二进制 / 图片 / 缺失 / 目录 / 截断）、预览对话框）、
`test/tool_row_detail_test.dart`（一行式：中文标签 + 关键参数、行尾增量、悬停提亮、点击 → 详情页完整参数与结果、空态与关闭、
派生文本纯函数、右栏页签接线源钉）、`test/message_stream_style_test.dart`（模型消息高亮块不套边框、用户消息仍是气泡）。
