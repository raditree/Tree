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
| [ui/widgets/](ui/widgets/) | 文件面板（**VS Code 型资源管理器** [file_tree.dart](ui/widgets/file_tree.dart) + 类型图标纯函数 [file_tree_icon.dart](ui/widgets/file_tree_icon.dart)）/ 查看器（源码高亮 + 编辑保存 + 分屏，见 [split_panes.dart](ui/widgets/split_panes.dart)）/ **集成终端（[terminal_panel.dart](ui/widgets/terminal_panel.dart)，Ctrl+J）**/ 消息输入框（[message_input.dart](ui/widgets/message_input.dart) + [attachment_preview.dart](ui/widgets/attachment_preview.dart) + 无边框输入样式 [input_style.dart](ui/widgets/input_style.dart)）/ 右栏详情（[detail_panel.dart](ui/widgets/detail_panel.dart)）、PDF 预览、Spec、待办、提问、插件、MCP、模型信息、Git 历史、设置页 |
| [ui/services/](ui/services/) | 重播守卫、下载中心、会话重命名、插件 UI 槽位注册、主题、**共享编辑缓冲（[editor_buffer.dart](ui/services/editor_buffer.dart)）**、**代码高亮（[code_highlight.dart](ui/services/code_highlight.dart)）**、**行号槽布局（[code_gutter_layout.dart](ui/services/code_gutter_layout.dart)：逐视觉行给号，软换行的续行留空）**、**编辑器偏好（[editor_settings.dart](ui/services/editor_settings.dart)）**、详情选中（[detail_selection.dart](ui/services/detail_selection.dart)）、**团队级模式与目录合成（[team_scope_view.dart](ui/services/team_scope_view.dart)）**、**工作空间相对路径纯函数与条目名校验（[workspace_paths.dart](ui/services/workspace_paths.dart)）** |

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
    文本域**自己不画边框**（边框归外层卡片，聚焦时卡片描边转主色）：装饰必须覆盖
    `enabledBorder` / `focusedBorder` 等五个 border 字段，**只写 `border: InputBorder.none`
    压不住全局 `inputDecorationTheme`**（解析顺序 focusedBorder → enabledBorder → border），
    表现就是「输入框里还有一个方框」（用户 2026-10-03 的截图）。统一常量见
    [ui/widgets/input_style.dart](ui/widgets/input_style.dart)，代码编辑器同一条口径。

11. **消息流是一行式：模型消息高亮、工具与思考各占一行，完整内容去右栏「详情」页**
    （[ui/widgets/tool_call_card.dart](ui/widgets/tool_call_card.dart)、[ui/widgets/thinking_card.dart](ui/widgets/thinking_card.dart)、
    [ui/widgets/detail_panel.dart](ui/widgets/detail_panel.dart)、[ui/services/detail_selection.dart](ui/services/detail_selection.dart)）：
    模型消息是**高亮块**（左侧主色竖条 + 极淡同色底，**没有整圈边框**），用户消息仍是主色气泡；
    工具调用一行 =「中文标签 + 关键参数（等宽）」+ 行尾增量（编辑 / 写入按行数给 `+N -M`）、转圈或箭头；
    **临时员工**（`subagent`）的消息与工具行在**这一段开头**画一条标记「临时员工「名」 · 层级 N」
    （[ui/models/message.dart](ui/models/message.dart) 的 `subagentId` / `subagentName` / `subagentParentId` /
    `subagentLevel`，[ui/widgets/message_list.dart](ui/widgets/message_list.dart) 的 `_SubagentTagBar`）：临时员工
    没有自己的会话，它的话与工具调用都写进**会话主人**的消息流（`agent_id` 仍是主人，帧过滤口径不变），
    不打标就会看起来像主 agent 在说话；同一个临时员工的连续消息 / 工具**只在第一行顶一次**标签（避免每条都占一行），
    换人或换回主 agent 再出现时重新标；`subagent` 工具卡片本身就是普通工具卡片（中文标签「临时员工」，
    行正文给 `task`，复用与后台在行里带出来）——**不认工具名的特例渲染**这条口径不变。
    增量**只从这次调用的参数算**：`edit` 取 `old_text` / `new_text`、`write` 取 `content`——**核心 schema 的键名**
    （不是 `path` / `old_string` / `new_string`；对错了就是恒 `+0 -0`）；编辑工具的**结果**只有「已替换 N 处」这类话、
    **不带 diff**，所以不许去解析结果文本；参数不全 / 不是编辑写入类工具 ⇒ 行尾**不给数字**（`+0 -0` 是假信息，宁缺勿假）；
    行数与核心的 `LineSplitter` 同口径（末尾换行不额外算一行）。
    思考一行 =「思考 · 首行摘要」。**中栏不再就地展开**——一轮里工具动辄几十条，卡片会把时间线切散，
        一行之后整轮动作像一份清单。悬停有呼应（图标提亮 + 底色），点击 → 右栏**第 6 个内置页签「详情」**摊开完整参数与结果；
    **再点同一条 = 取消选中**（详情页回空态）——工具行与思考行共用 `DetailSelection.toggle()` 这一条口径，
    省得把鼠标移到详情页去点「关闭详情」（用户 2026-10-04）；
    详情页里 `write` / `edit` 另给一段**变更**，并且**按源码渲染**（同一门语言表、同一份配色：`write` 的内容走
    `buildCodeTextSpan`；`edit` 的每一行走 `codeColorRuns` 整段词法结果再按行切片——块注释 / 多行字符串跨行不断色，
    见 [code_highlight_lines.dart](ui/services/code_highlight_lines.dart)；用户 2026-10-04：「为什么没按源码渲染」）：
    最好带少量几行上下文方便用户阅读」）：`write` 摊开写进去的**内容**（超 2000 行 / 128 KB 才截断并如实标注），
    `edit` 给**带上下文的变更块**——`-` 旧行 / `+` 新行 / 无前缀是上下文，上下文是读一次**磁盘当前内容**、
    按这次调用的 `new_text` 定位后上下各取 3 行（[tool_change_view.dart](ui/services/tool_change_view.dart)，纯函数；
    落在行中间的替换按**整行**标出来）；定位不到（文件之后又被改过）或读不到就**如实说明**并退回「查找 / 替换」
    参数视图——绝不把两段原文伪装成 diff；**翻历史**（文件之后又被改过，读出来的当前内容里定位不到）**也不什么都不给**：
    退回"只用调用参数"的 `-` 旧 / `+` 新变更块（没有上下文、如实标注「上下文不可得」）——那份上下文当时没被存下来，
    不假装有；
    右栏收着时自动展开。选中项走 [DetailSelection](ui/services/detail_selection.dart)（全局 ChangeNotifier，存消息**快照**，
    帧后按 id 刷新——跑着的工具 / 思考内容是原地变更的，必须跟着长），切 agent / 整表重拉时清空。

12. **源码模式按语言着色，且只能编辑纯文本**（[ui/services/code_highlight.dart](ui/services/code_highlight.dart)、
    [ui/widgets/file_viewer.dart](ui/widgets/file_viewer.dart)、[io/api_service.dart](io/api_service.dart) 的 `saveFileContent`）：
    着色不引第三方包，一张规则表 + 单遍扫描（关键字 / 类型 / 字符串 / 注释 / 数字 / 注解 / 函数名），
    **只在 ≤ 128 KB 时着色**（超过退回单色，保证输入不卡），记号按「文本 + 配色」缓存——按键才重算一次；
    代码视图左侧有**行号槽**（[ui/services/code_gutter_layout.dart](ui/services/code_gutter_layout.dart)），且**软换行感知**：
    一条逻辑行折成多个视觉行时只给首行编号（续行不画数字），行号与正文用**同一套度量**——同一 TextStyle、
    同一 textScaler、同一内容宽度（= 窗格宽 − 槽宽 − 正文 contentPadding 左右 − 光标留白），否则折行点不同、
    从折行处开始数字就整体错位；可编辑（TextField）与只读（SelectableText.rich）两条分支都有，并且跟着正文
    **同一条滚动控制器**平移（不挂第二个 Scrollable），正文顶部的 contentPadding 也算进偏移；行号布局只在
    文本 / 可用宽度变化时重算（缓存在槽里，不是每帧算），数字不参与命中与选择（点它不动光标、选中正文不带行号）；
    图片 / PDF / Office 与 Markdown / SVG **预览**这些模式没有行号槽。
    是否文本**看字节**（前 4 KB 有 NUL 就当二进制，扩展名骗人的文件不会被渲染成乱码）。只读闸门（缺一不可）：
    图片 / PDF / Office（复杂格式）、**被截断的大文件**（写回去等于把文件截短）、含 NUL 的二进制、外部显式传入的
    `readOnly`。**同文件双开不在这条闸门里**——那两个窗格共享同一份缓冲（不变量 13）。
    保存**一律走核心** `PUT /api/files/{id}/content`（本机与 SSH 同一套，前端不直接写盘），带 `if_size` 做外部改动检测：
    磁盘现值不符 → 409 → UI 给「覆盖保存（force）/ 放弃我的改动并刷新 / 取消」。自动保存只做**失焦与离开**
    （切走、关窗格、换文件、关查看器；可在设置里关掉改成纯手动 Ctrl+S），**没有定时器**——定时写入会打断正在输入的思路。

13. **分屏（VS Code 型）只做二分，同一个文件的两个窗格共享一份缓冲**（[ui/widgets/split_panes.dart](ui/widgets/split_panes.dart)
    +`file_panel` + [ui/services/editor_buffer.dart](ui/services/editor_buffer.dart)）：左右 / 上下可切、
    分隔可拖（夹在 0.2–0.8，同方向最小 120px）、每格独立打开文件与保存、可用空间太窄降级成单窗格。
    **同一个文件**在两个窗格里打开时两侧共用**同一个** `EditorBuffer`（一个 `CodeEditingController` + 一份
    `dirty` / `saving` / `loadedSize`，VS Code 的 TextDocument 口径）：两边都能编辑、一边打字另一边立刻可见，
    谁保存都只写一次盘——**没有**"两份缓冲互相覆盖"这回事，所以旧的"非活动窗格强制只读"口径**已被推翻**；
    双开只留一条"两侧共享同一份缓冲，就地编辑即同步"的提示，不再拦编辑。
    控制器归缓冲所有：**两个窗格都关掉之后**才释放（先关掉的那个不能把另一个正在用的控制器 dispose 掉）；
    [FileViewer](ui/widgets/file_viewer.dart) 的 `buffer` 参数可空，没外部传时自己 new 一份并自己释放
    （既有调用方与测试零改动）。换文件 / 关窗格前先 `confirmLeave()`：开着失焦保存就静默写回，关着就问
    「保存 / 不保存 / 取消」——问的是**共享**的那份脏标记，同一份文档的两个窗格只问一次。

14. **Ctrl+J 把输入框那块换成集成终端（真 PTY）**（[ui/widgets/terminal_panel.dart](ui/widgets/terminal_panel.dart)、
    [ui/services/vt_screen.dart](ui/services/vt_screen.dart)、[io/websocket_service.dart](io/websocket_service.dart) 的 `terminalFrames`）：
    打开时**主动展开**（按面板高 40%，夹 160–420）并把焦点交给终端，再按一次回到输入框（草稿靠草稿缓存原样回来）；
    快捷键**与焦点无关**：绑在 MainPage 顶层的 `CallbackShortcuts`（`main-global-shortcuts`）上，经全局
    [TerminalToggleRequest](ui/services/terminal_toggle_request.dart) 广播——焦点在文件树 / 代码编辑器 / 详情页 / 终端自身时
    照样唤起（挂在输入框上的局部快捷键只在输入框有焦点时收得到）；**没有任何主焦点时**冒泡到顶层这一路也成立。
    终端**没有输入行**，按键走**两条路**（这是引擎契约，改之前先看 [docs/known-issues.md](../docs/known-issues.md) #12）：
    **控制键**（回车 `\r`、退格 `0x7f`、方向键 `ESC[A..D`、Ctrl+字母 `0x01..0x1A`）经 `Focus.onKeyEvent` 译成终端字节；
    **可打印字符一律判 `ignored`、交给平台的文本输入**（[ui/services/terminal_ime_input.dart](ui/services/terminal_ime_input.dart)
    的 `TerminalTextInputClient`——只有它收得到中文 / 日文这类要"组字"的输入法）——引擎在键事件被判 `handled`
    时**就不再派发文字**，两条路因此天然互斥、不会重复输入。这条连接**必须带本视图的 `viewId`**
    （`View.of(context).viewId`，与 `EditableText` 同口径）：缺了平台侧 `setClient` 直接报错、文字被静默丢掉
    ⇒ **中英文一个字都打不出来**（真机踩过）。Ctrl+J 例外（留给切换）。
    **输入法通道的两条硬口径**（用户 2026-10-03：「中文输入下模拟终端出 bug」；同一天又回归了一次
    ——「模拟终端又出问题」，见 [docs/known-issues.md](../docs/known-issues.md) #20）：
    ① **只补差额**——平台送来的永远是 `TextInputModel` 的**整段文本**（`SendStateUpdate`），提交那一刻不发状态、
    随后 `ComposeEndHook` 发的是"整段文本 + composing 无效"，所以必须自己记住"已经交给 PTY 的前缀"、
    只补新定下来的那一截；组字尾巴（`composing` 覆盖的那段）一个字都不发，尾巴被引擎连在提交结果前
    一起送回来时也要剥掉；
    ② **绝不回推 `setEditingState`**（唯一一次是 `attach` 时把模型清空）：回推会走引擎
    `TextInputModel::SetText(text)` 的**默认参数**路径（`composing_range = TextRange(0)`，折叠 ⇒
    `composing_ = false`），而紧接着的 `SetComposingRange` 开头就是 `if (!composing_) return false;`，
    救不回来；组字态一没，`AddText`（只有 `composing_` 为真才"删掉组字文本再插入"）就从
    **"替换组字区"退化成"追加"** ⇒ 拼音越堆越多，被"只补差额"当成新定字转发给 PTY，shell 里就是一串
    拼音（真机截图 `E:\…>nninini…。hani。…`，且没有换行）。**这条线不要再碰**：
    `test/terminal_ime_input_test.dart` 有一条用例专门钉住"组字期间 `TextInput.setEditingState` 出现 0 次"。
    同一链路还要报一次**光标那一格在哪**
    （`setEditableSizeAndTransform` + `setMarkedTextRect`，Windows 用它们摆 IME 窗口）：不报的话候选窗会用
    **上一个可编辑控件**（被 Ctrl+J 顶掉的 composer）的陈旧矩形。
    **选中 / 复制粘贴**（用户 2026-10-03：「没法选中文字，没法复制粘贴」）：左键拖拽在格子上取选区
    （[ui/services/terminal_selection.dart](ui/services/terminal_selection.dart) 是纯逻辑；坐标用**绝对行号** = 历史 + 屏幕拼成
    一条线，所以输出把内容顶上去、用户往上翻历史，选区都还锚在同一段文字上；**resize 会重排行 ⇒ 那里清选区**）；
    `Ctrl+Shift+C` / `Ctrl+Insert` / **有选中时的 `Ctrl+C`**（没选中时 `Ctrl+C` 照旧发 `0x03` = SIGINT）复制，
    `Ctrl+V` / `Shift+Insert` / 右键菜单（没选中时"复制"置灰并说明）粘贴；复制按行取文本、**裁掉行尾空格**、
    多行用 `\n` 连接（末尾不补换行，粘贴时 `\n` 会被换回 `\r`）；应用开了括号粘贴（`?2004`）时按 xterm 口径包
    `ESC[200~ … ESC[201~`；**粘贴不过 `#TSend` 拦截层**（那层只拦手打的一行）。
    核心开**真伪终端**，输出是**原始字节**（base64 过 WS），前端用自制的 VT 解析器还原成屏幕
    （光标定位 / SGR / 备用屏都在内），再 `CustomPaint` 画格子。两个后端**都是真 PTY**：
    本机 agent 走平台伪终端（Windows ConPTY / POSIX `script`）；远端（SSH）agent 走 SSH 会话通道 +
    `pty-req`（dartssh2），并**复用那条已建好的 SSH 连接**（不为终端再连一次），远端的
    `terminal_ready.cwd` 是空串——远端工作目录由 `SshWorkspaceIO` 自己解决，界面显示「工作区」。
    判据是**有效 SSH**（成员跟随团队 TOP 的 SSH，见不变量 15）；没接线时回可读错误，**绝不**
    悄悄在本机给远端 agent 起一个终端。关面板 / 换 agent / 断连都会把 shell 收掉。
    **右下角那个圆键是两态的**（用户 2026-10-04）：agent **正在生成且输入框为空**时它是
    **停止键**（实心圆 + 白色圆角方块，[ui/widgets/stop_button.dart](ui/widgets/stop_button.dart)），
    一开始打字就换回发送键——发送本身就意味着"中止在途那一轮并另起一轮"，没必要先停再发；
    成员面板的输入行同一个口径（在那里顺手暂停 teammates）。
    （会话历史的**窗口化加载**——滑到哪加载哪、限制缓存长度、滑块按全局下标算、"回到底部"直接重载——
    见不变量 19。）
    **回滚缓冲**：主屏整屏滚动时被顶出去的行进历史（上限 2000 行；备用屏与滚动区域内部的滚动不进——
    xterm 口径），鼠标滚轮往上翻、**滚到底自动恢复跟随**，翻上去时工具条上出现「已回滚 N 行」胶囊（点它回到最新）；
    新输出不会把正在回看的视野拽走（视图钉在同一段内容上，靠 `historyPushed` 计数）。`ED3`（`CSI 3 J`）与 RIS 清空历史。
    **清屏**（工具条那颗按钮与 `Ctrl+L`，用户 2026-10-03：「清屏键无效」）＝**本地立刻清**（往 [VtScreen](ui/services/vt_screen.dart)
    喂标准序列 `ESC[2J` + `ESC[3J` + `ESC[H`：清屏 + 清历史 + 游标归位，并复位回滚视图）
    **＋ 仍然把 `Ctrl+L`(`0x0c`) 送给 shell**：只发 `0x0c` 是"交给 shell 办"，而 shell 未必有这个绑定——
    本机默认 shell 是 `cmd.exe`（没有 `Ctrl+L`）⇒ 按下去什么都不发生。反过来 bash / PSReadLine 拿到 `0x0c`
    会自己重画提示符，两者叠加不冲突（先空屏、各自再画）。
    **`#TSend`：在终端里直接给当前会话发消息**（[ui/services/terminal_send_command.dart](ui/services/terminal_send_command.dart)）——
    `#TSend "一段话"`、`#TSend @<文件路径>`，也能混写（`#TSend "看这个" @C:\x\a.md`；路径带空格写 `@"C:\a b.md"`）；
    它走 composer 的**同一个发送口**（附件上传 / 上屏 / WS 帧完全一致），因此终端里发的和手打的等价。
    实现是**按键层拦截**：以 `#` 开头且仍是 `#TSend` 前缀的那一行只在本地缓存、一个字节都不给 shell，一旦不是它
    （如 `#Tx`）就把缓存**原样补发**——对 shell 与用户而言等于从来没拦过（退格吃本地缓存、方向键 / Ctrl+C / Tab 前
    先补发缓存）；`#TSend` 单独一行会提示"后面要跟内容"，而不是静默吞掉用户那一行。
    终端的边界（VT 解析器没实现的部分、远端分支**没有真机 sshd 验证过**）见
    [docs/known-issues.md](../docs/known-issues.md) #12。
    终端还会把操作系统那句"用户没法照做"的话翻成指引（用户 2026-10-03：「别忘了模拟终端啊」，
    后来「补上」）：**两种措辞都认**——① 系统措辞 `不受信任的装入点` / `untrusted mount point` /
    `无法遍历该路径`；② **CMake 措辞** `add_subdirectory given source … which is not an existing
    directory` **且**同时出现 `.plugin_symlinks`（单看它是通用措辞，任何缺目录都这么报，故判据是
    "两半同时命中"，见 `TerminalNoticeScene.allOf`）。命中的那一帧弹一次可读指引，给的是**改正后的
    下一步**（"退出 Tree、从开始菜单重开一次；或先在系统终端里跑这条命令"，机制见
    [docs/known-issues.md](../docs/known-issues.md) #16）——**不再是**"先去管理员终端 pub get"
    （真因查清后那已不是最优解）。跨帧稳健（留**字节尾巴**，关键字被切断、甚至切在 UTF-8 多字节字符
    中间也认得出；CMake 那两半相隔约 60 字节，同在一个窗口内）、**每会话只提示一次**、重开终端重置
    （[ui/services/terminal_output_notice.dart](ui/services/terminal_output_notice.dart)）。
    本地终端与本地工具命令的**环境**由核心按"登录口径"重建（见 [tree_local_exec 不变量 14](../packages/tree_local_exec/README.md)）：
    Tree 的终端不该继承 core 被谁拉起时的那一份。

15. **运行模式与工作目录是团队级的：成员默认继承团队 TOP**（[ui/services/team_scope_view.dart](ui/services/team_scope_view.dart)，
    [test/team_scope_view_test.dart](../test/team_scope_view_test.dart) 强制；核心口径见
    [team/README.md](../packages/tree_core/lib/src/team/README.md) 不变量 2/3/13，**用户断言 2026-10-03**）：
    中栏左上角的模式开关与目录**按团队 TOP 合成**，不再是"只看成员自己那份配置"——
    ① **模式**：成员自己**显式**配了 SSH 就以自己为准（与核心 `teamSshConfigFor` 同优先级），否则跟随 TOP；
    ② **工作目录**：**只有 TOP 那份算数**（成员自己那份是核心写的镜像），显示 TOP 的目录；TOP 未配置时退回
    成员自己那份镜像——核心会把 TOP 的默认目录也镜像进来，成员页因此**永远显示一个真实目录**，
    而不是让用户去"重新选择工作目录"；
    ③ **选目录写入团队 TOP**（照成员 id 写等于改一个没人读的字段），并提示"团队成员共用这一个目录"；
    ④ 团队 TOP 配了 SSH 时成员**切不回本地**：核心没有"成员覆盖成 local"这个概念，界面**如实拒绝**并说明
    去哪改，不假装切成功。

16. **右栏文件面板是 VS Code 型资源管理器：彩色类型图标、没有"大小 / 修改时间"两列、缩进引导线、
    整行悬停与选中，并且能新建 / 重命名 / 删除**（[ui/widgets/file_tree.dart](ui/widgets/file_tree.dart)、
    [ui/widgets/file_tree_icon.dart](ui/widgets/file_tree_icon.dart)、[ui/widgets/file_panel.dart](ui/widgets/file_panel.dart)、
    [ui/services/workspace_paths.dart](ui/services/workspace_paths.dart)、[ui/models/git_status.dart](ui/models/git_status.dart)，
    用户 2026-10-03：「现在太简陋了，对标 VS Code」）：
    ① **口径变化（不是漏改）**：旧的"单层列表 + 面包屑进入子目录 + 当前目录"换成**惰性加载的嵌套树**——目录就地展开 / 折叠
    （展开时才拉那一层），面包屑取消，头部显示「根目录 + 同步作用域」，而**同步作用域改由选中项推导**（选中目录 = 它自己，
    选中文件 = 它所在目录），[FileSyncButton](ui/widgets/file_sync_button.dart) 的 `currentPath` 语义不变；
    **展开状态跨刷新保持**（工具写文件 / 上传 / 切执行模式重拉之后不塌）；
    ② **行只有名字 + 类型图标**（行高 22、字号 13、行内左右 padding 6）：大小与修改时间两列**下到悬停 tooltip**
    （`3.7 KB · 2026-10-02 11:31`；目录给 `N 项 · 时间`，没加载过子项时只给时间、不编数字），超长名走
    `TextOverflow.ellipsis`，tooltip 第一行永远是全名；
    ③ **类型图标是中性单色的**（[fileTreeVisualFor](ui/widgets/file_tree_icon.dart) 给形状 + 类型名，
    颜色由 `fileTreeIconColor(scheme)` = `colorScheme.onSurfaceVariant` 给）：目录收起 / 展开都是**描边文件夹**
    （展开只转左侧箭头，图标形状不变），`.dart` / `.md` / `.py` / `.sh` / `.json` / `.yaml` / 图片 / PDF / 压缩包 /
    纯文本 / 未知类型各有**不同形状**的图标。**这一步推翻了旧口径「写死色板、不跟主题色」**（用户 2026-10-04 看图：
    「文件为什么是这种橙色，改成图二的样式」）：写死的高饱和色板在深色主题下就是那一坨橙黄，而资源管理器真正要用
    颜色表达的是「这条文件改没改」（git 状态，见⑥）——所以**颜色只留给 git 状态**。**各家族的图标形状必须两两不同**
    （颜色已统一，认类型只能靠形状）。源码家族取自 [code_highlight](ui/services/code_highlight.dart) 的 `languageForPath`
    （高亮认得的语言，图标也认得，不再抄第二张扩展名表）；
    ④ **箭头只在目录上**（`AnimatedRotation` 0 → 0.25 圈 = 顺时针 90°），文件行留**等宽空槽**（同级文件与目录名字必须对齐）；
    每层画 1px 缩进引导线（低透明度 `outlineVariant`，落在父级箭头槽中心）；
    ⑤ **整行悬停浅底 / 选中更重的底 + 左侧 2px 主色条**；↑/↓ 在树里移动选中（→/← 展开折叠或跳父级、Enter 打开、F2 改名、
    Delete 删除），行高固定所以选中项能精算着滚进可见区；头部那颗「全部折叠」**没有展开项时置灰**
    （tooltip 改说「没有展开的目录（都收着呢）」，右键菜单里同样置灰），真收了就**滚回顶部**——
    "没有可收的东西"时点了没反应最容易被当成 bug（用户 2026-10-04 反馈）；
    ⑥ **git 状态着色**：`GET /api/files/{id}/git-status` 拉**一次**缓存在面板状态（不塞进每一行的重建路径），整行名字染色 +
    行尾字母 M/U/A/D/R/I（VS Code gitDecoration 口径，"被忽略"更淡），**目录聚合子项状态**
    （删除 > 修改 > 未跟踪 > 新增 > 重命名 > 忽略）；`is_repo=false` / 核心还没有这个端点 / 断网**一律静默不着色**
    （状态色是锦上添花，不能把它变成错误页）；新建 / 改名 / 删除后失效重拉；
    ⑦ **新建 / 重命名 / 删除**：新建文件走既有 `PUT .../content`（空内容）、新建文件夹 `POST .../mkdir`、
    改名 `POST .../rename`、删除 `DELETE ...?path=[&recursive=1]`（[io/api_service.dart](io/api_service.dart) 的
    `getFilesWithMeta` / `getGitStatus` / `createDirectory` / `renamePath` / `deletePath`；路径常量取自协议包的
    `ApiPaths`，不写字面量，见不变量 4）。名字校验（空 / 路径分隔符 / 非法字符 / Windows 保留名 / 同名，见
    [validateEntryName](ui/services/workspace_paths.dart)）在**前端先挡一道**——核心的写文本端点**没有"仅新建"语义**，
    重名会被它静默覆盖，所以创建前还要**重新列一次目录**复查；行内改名（回车确认 / Esc 或失焦取消），重名给**行内**红字；
    删除前确认（目录**显式**递归：确认框里写明"里面的内容会一起删除"），**工作空间根永远不许删**（前端与核心各拦一道）。
    超大目录被核心截断时给一行「仅显示前 N 项」（`getFilesWithMeta` 保留 `truncated`，旧的 `getFiles` 会丢它）；
    ⑧ **目录在左、查看器在右，目录可一键收起（2026-10-04 三改：上下分栏已被推翻）**：打开文件后**不再**用覆盖层
    盖住目录——那会让"打开文件后新建 / 改名 / 删除根本点不到"，接线（`onPathRenamed` / `onPathDeleted`）也永远点不到。
    布局经 [split_panes.dart](ui/widgets/split_panes.dart)：**左栏** = 文件子 Tab（树 / Git 历史 / Todo），
    **右栏** = 查看器（工具条 + 1–2 个窗格），中间可拖；比例默认 **0.3** 并**记在面板状态**里（关掉再开还是刚才的比例）。
    **为什么从上下改成左右**（连着上次的理由一起推翻）：上下分栏把查看器**压扁**——代码是按行看的，高度比宽度更吃紧；
    而面板宽度是用户能拖的（右栏上限随窗口宽度变化）。**没打开文件时目录独占**（不留空分栏）。
    **收起 / 显示**：查看器工具条上的箭头键切换意愿（`_treeWanted`），收起后查看器占满整格。**意愿与"这一刻能不能
    显示"分开**——面板太窄时按下面的降级口径只显示查看器，但*不*清掉意愿，拖宽之后目录自己回来，不用再点一次。
    **降级口径**：可用**宽度** < 400px（`_treeSplitDegradeBelow`，每侧最小 200px）时只显示查看器，并在工具条上
    **如实写出原因**（`tree-too-narrow-hint`：「面板太窄 · 目录已收起（拖宽右栏恢复）」）——不让用户对着一个看起来
    没反应的按钮猜。窄栏位的自保：目录头部（`根目录` + 同步作用域）与查看器头部（文件名 / 语言标签 / 动作键）都必须
    能缩——查看器头部在 < 360px 时把预览切换 / 复制 / 下载收进「更多」菜单（`_headerAction` = 28px 紧凑键），
    目录头部的标题走 `Flexible` + 省略号，否则左右分栏下必然出现黄黑溢出条。
    开 / 关查看器时文件子 Tab 区用 `GlobalKey`（`_fileTabsKey`）
    **搬**进 / 搬出分栏而不是重建：展开状态、选中项、已加载的目录都不丢。树里的改名 / 删除对已打开文件的联动经
    `FileTree.onPathRenamed` / `onPathDeleted` → FilePanel 更新窗格路径（缓冲实例不动）或关掉窗格并提示。

17. **首次使用有八步新手引导，处处可跳过**（[ui/services/onboarding_steps.dart](ui/services/onboarding_steps.dart)、
    [ui/services/onboarding_state.dart](ui/services/onboarding_state.dart)、
    [ui/widgets/onboarding_guide.dart](ui/widgets/onboarding_guide.dart)、
    [ui/services/onboarding_requests.dart](ui/services/onboarding_requests.dart)，**用户断言 2026-10-04**）：
    顺序**就是用户定的顺序**（不要顺手重排）：模型配置（设置页）→ 创建 agent → 配置模型信息 →
    配置工作目录 → 启用插件 → 文件浏览 → Ctrl+J → demo 输入（「创建一名成员，负责插件开发」）。
    ① **浮层是非模态的**（盖在中栏上方一小块）：每一步的「带我过去」都要打开**真实界面**——设置页的
    「自定义模型」一节、建 agent 对话框、右栏「模型信息」/「文件」页、插件管理面板、集成终端、
    工作目录选择器；模态对话框会把那些界面挡在外面，用户只能对着引导发愣；
    ② **只做导航、不替用户决定**：除最后一步外「带我过去」只是把人带到地方；最后一步把 demo 那句话
    **填进输入框**（光标就位、**不自动发送**，用户看清了自己按发送）；
    ③ **处处可跳过**：「下一步（跳过这步）」= 不做这一步直接走，「跳过引导」= 整段收工，两者都记进
    [OnboardingState](ui/services/onboarding_state.dart)（SharedPreferences `tree.onboarding.v1`，**UI 级偏好**，
    不占核心配置）⇒ 之后不再自动弹；设置页的「新手引导」卡片可以**重新显示**（清记录再从头弹一次），
    否则用户只能删配置才能再看一遍、也没法验证；
    ④ 跨面板的动作走**全局广播**（`ComposerPrefillRequest` / `WorkspacePickRequest`，与
    [TerminalToggleRequest](ui/services/terminal_toggle_request.dart) 同一范式）：引导在 MainPage 里、
    要落地的动作在消息面板里（只有它知道当前 agent / 会话、手里有那份工作目录配置），所以只广播
    「要做这件事」；右栏页签用「索引 + 请求序号」表达（用户自己翻页后再点一次「带我过去」也要生效，
    不能被「值没变」吞掉）；
    ⑤ 偏好读不到（平台不支持 / 测试环境）时**静默不弹**，绝不因为引导把启动搞出未捕获异常。

18. **临时员工的产出不混杂进主消息流，去它自己的视角看**（[ui/services/subagent_transcript.dart](ui/services/subagent_transcript.dart)、
    [ui/widgets/subagent_view_switcher.dart](ui/widgets/subagent_view_switcher.dart)、[ui/widgets/subagent_process_list.dart](ui/widgets/subagent_process_list.dart)，
    **用户断言 2026-10-04**）：
    ① **中栏只渲染主 agent 自己的消息**（列表的 `visible` 谓词 = `!isSubagentMessage`，命中者渲染成**零高度槽位**；
    `visibleStreamMessages` 仍是这条口径的纯函数落点，见不变量 19）：临时员工的文本 / 思考 /
    工具调用不再与主 agent 的混在一起；
    ② 两处能看它的过程，且**共用同一份渲染**（[SubagentProcessList]）：**调用它的那次 `subagent` 工具调用的详情页**
    （就地看，里面的工具行还能再点进去看那条工具的详情），以及**中栏就地切换的「临时员工视角」**；
    ③ **进它的视角不新开窗口**（**用户断言 2026-10-04**）：借父 agent 那个窗口，只把**对话数据**与**上下文长度条**
    换成它的（[ui/services/conversation_view.dart](ui/services/conversation_view.dart) 的 `viewMessages` / `viewContext` 是
    这条口径的唯一落点，面板只做接线）：消息区换成它的完整过程（顶部一行身份条：由「X」召来 · 第 N 层 · sub_… + 它自己的
    上下文读数 + 它自己的「工作中/空闲」），标题栏写「临时员工「名字」」；**输入框照常可用**
    （用户 2026-10-04：「允许用户停止 subagent 的工作、向其发消息」）——发出去的消息收件人是**它**
    （前端那条乐观气泡也打它的标记，否则会跑到主消息流里），核心走 `sendToSubagent`；
    它在跑时右下角那颗键是**只停它**的停止键；**用户停止/插话中止的那一轮不向发起者注入结束提示**
    （原因由用户自己说，用户往往马上又发一条让它接着干），而**出错导致的中止必须注入**；
    切 session / 换 agent / 整表重拉一律回到主会话，过程分栏里不存在的 id 也回主会话（`_effectiveViewId`）；
    ④ **切换的 UI 在输入框右下、发送键左侧**（[ui/widgets/subagent_view_switcher.dart](ui/widgets/subagent_view_switcher.dart)，
    与会话切换同族的胶囊 + 下拉，列出「主会话」与每一个临时员工）；**进入视角后锁定会话切换**
    （[SessionPicker](ui/widgets/session_picker.dart) 的 `locked`：图标变锁、点它只说原因、右键重命名/删除一并关掉）；
    ⑤ **语义对齐——它与「发出这次调用的那个 agent」同级**（用户更正：**不是**与 teammates 同级）：入口挂在那个 agent 的
    会话头上（「「凌川」召来的临时员工（N 名）」→ 选一个进它的视角），措辞一律「由「X」召来 · 第 N 层」，**不复用团队的
    「层级」一词**；父级名字从过程消息的 `subagent_parent_id` 认（认不出就写「（未知调用方）」——**不编名字**）；
    ⑥ **它的上下文长度不计入主 agent 的读数**：中栏的「上下文」实时帧**不认**带 `subagent_id` 的（`_recordUsage` 直接返回），
    历史恢复用量也跳过带标记的消息；这个数字只在它自己的视图里显示（「它的上下文：1200 / 64000 tokens（不并进主 agent
    的统计）」）——临时员工是**另一个 LLM 上下文**，混进来会把主 agent 的读数带偏。

19. **中栏消息流是"按全局下标寻址的窗口"**（[ui/services/message_window.dart](ui/services/message_window.dart)、
    [ui/widgets/message_list.dart](ui/widgets/message_list.dart)、[ui/widgets/message_scrollbar.dart](ui/widgets/message_scrollbar.dart)，
    **用户断言 2026-10-04**：「右侧滑块位置按全局长度算，滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息」
    「回到底部按钮直接重载入历史」）：
    ① 整份会话流是一张**槽位表**（下标 0 = 最旧那条），元素为 `null` 表示这一段还没取回来——列表里画成**等高占位槽**
    （[MessageWindow](ui/services/message_window.dart) 只做放置 / 去重 / 淘汰，纯 Dart 可单测）；表长**只随新消息增长**
    （加载、淘汰都不改变它）= 滑块不乱跳的根基；
    ② 列表把**视口坐标**（[MessageWindowCoordinate](ui/services/message_window.dart)：本帧构建到的下标区间 + 全局条数）
    **每帧**刷给面板与滑块——刷新由**滚动通知**与 itemBuilder 两侧驱动，因为**滚动不重建父组件**（早先只在
    `build` 里注册一次帧后回调 ⇒ 滚动期间一次都不上报，拇指死在原地；用户 2026-10-03「页面上滚，拇指不动」）；
    权威区间取自渲染树里 SliverList **这一趟真的布局过**的子项（`childScrollOffset != null`，
    被 `AutomaticKeepAlive` 留在树里的屏外子项不算），itemBuilder 收集的区间只作兜底；
    面板按 `GET /api/conversations/{id}?from=<下标>&limit=N` 只补那一段
    （核心回 `offset` = 这一页第一条的全局下标，见 [server/README.md](../packages/tree_core/lib/src/server/README.md) 不变量 14）——
    **缺口在视口顶切开**（`splitGapAtViewportTop`：先补"视口及以下"，再补"整段在视口上方"那份）：
    横跨视口的缺口若整段补下来，视口上方由占位变实会长高、把用户正在读的一段整体推下去；
    补页 + 淘汰**同一时刻只跑一趟**（反复触发只覆盖"最新坐标"，一趟内的请求串行），视口附近已加载好时
    第一道 `gapsFor` 就是空 ⇒ 滚动零网络、零 `setState`；淘汰离视口超过 **200** 条的槽位
    （"仅缓存坐标附近的历史，其余均丢弃"）——**正在流式 / 正在跑工具的消息永不被淘汰**，末尾 200 条常驻；
    补页失败只留着占位槽，下次滑动再试；补不出东西来的段记一笔不再空转（防死循环）；
    ③ 右侧滑块**按全局下标算几何**（第一条的下标 / 全局条数，长度 = 看得见的条数 / 全局条数、有抓得住的下限），
    拖它 = 跳到该下标并补那一段（原生 `Scrollbar` 跟随"已构建内容的估算范围"，窗口化列表里必然乱跳，故自绘）；
    **必须显式关掉原生那条**（`ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false))`，
    [ui/widgets/message_list.dart](ui/widgets/message_list.dart)）——桌面 ScrollBehavior 会给每个竖向 Scrollable
    自动包一条原生 `Scrollbar`，不关就与自绘那条叠在同一条 14px 窄带里：一条稳、一条跳（用户 2026-10-03
    「主对话框的滑块乱跳」就是它；只关滚动条，物理/越界指示/拖拽设备保留，其它面板依赖原生滑块故不做全局改造）；
    拖拽另有两处硬口径：**按位置反解下标必须是绘制几何的严格逆**（`messageScrollbarIndexAt`；两边各算一套会差
    `total/(total-visible)` 倍）、**拖拽期间几何输入与拇指位置都钉住**（指针为准、松手再对齐真实坐标）——
    少了任一条，拇指都会被自己报出去的下标甩到指针前面（长会话约 1%，`total=100` 的短会话可达 33%）；
    **拇指直接监听坐标**（`ValueListenableBuilder`）：滚动只重绘拇指、不重建列表（"鼠标滚动丝滑"）；
    落点按**坐标**算（`pixelOffsetForIndex`：以视口第一条为锚点、占位区 88px/条）而不是"下标 × 占位高度"
    （已加载消息的真实高度各不相同，从 0 开始算会把误差一路累积），松手/点击后再用实测落点
    **反馈校正 ≤3 次**（`MessageSeekCorrection`，两点割线反推这一带的真实步长；用户一动就放弃，绝不与用户抢）——
    没有这一步，拇指停在指针那儿、内容却停在别处，松手后拇指只好"回落"
    （用户 2026-10-03：「松开后拇指回落到底部或顶部，但中间页面不会随其回落」）；
    滑块能指到的最靠后下标是 `total - 看得见的条数`（"最后一条正好落在视口底" = 贴底），拖到最底下时列表**直达底部**；
    ④ **「回到底部」= 重载末尾一段**（`resetTail`：窗口换成"末尾页 + 比它新的实时尾巴"）＋直达底部——不再在几千条
    估算高度里做一次滚动动画（那正是"划不到底"的来源）；实时追加落在末尾，末尾那段常驻所以流式不受影响；
    ⑤ 定位一条早已被淘汰的消息用 `at=<id>`（取含它的那一段），并把那一页额外钉住不被淘汰（`evict(keepAlso:)`）；
    ⑥ 面板**上方**补页时按高度差补偿滚动位置（[padAboveStamp] → 布局阶段 `correctPixels`，视口钉在同一段内容上）；
    **补偿量必须取"实测高度差"，不得取"滚动范围差"**——这是用户 2026-10-03「触发一次懒加载后抖动非常厉害」
    那条的根因与修法：懒构建列表未到底时 `maxScrollExtent` 是 `estimateMaxScrollOffset` 的**外推值**
    （末尾已布局偏移 + 已建子项平均高 × 剩余条数），误差 **∝ 剩余条数**；真机几千条、视口在中段时单帧可差上千像素
    （实测：补 3 格占位槽 ⇒ 视口偏移 **+6932px**，补 12 格 ⇒ **+87873px**），而 `shiftAbove` 只在补页帧置位
    ⇒ 噪声恰好只在懒加载那一帧被施加。做法：补页**之前**记下"视口顶那条真消息的**底边**"
    （= 下一条子项的顶边；取渲染树的 `layoutOffset`——实测逐条累加值，与外推无关；布局期**不读** `.size`，
    会触发 `size accessed beyond the scope of layout` 断言），布局后取同一探针的差做 `correctPixels`；
    锚点用**底边**而非顶边，因为紧贴视口顶的那一格**自身往往就是**"占位槽 → 真消息"的那一格，
    只补它上方长出的部分会把它自己长出的高度推给下面正在读的内容；估算差只作**兜底**，且以"视口高 × 2"**限幅**
    （宁可不补，也不错补上千像素）。
    跟随模式下依旧"粘底"（贴住就一直跟着长高走，用户一上滚立刻停手）。

20. **「用量」与「核心日志」两块读数都直接读本机文件，路径只能来自握手**（
    [ui/services/usage_log_files.dart](ui/services/usage_log_files.dart)、
    [ui/services/core_log_files.dart](ui/services/core_log_files.dart)、
    [ui/widgets/usage_calls_panel.dart](ui/widgets/usage_calls_panel.dart)、
    [ui/widgets/core_log_card.dart](ui/widgets/core_log_card.dart)）：
    ① 数据根只有一个来源 —— 握手可选字段 `data_root`（[io/core_process_launcher.dart](io/core_process_launcher.dart)）；
    拿不到就说"没有入口"（老核心 / 附着模式 / 核心未起），**绝不猜** `%APPDATA%\Tree` 之类的替代路径；
    ② 目录名按核心口径拼（`data/<agent_id>/<session_id>/…`）并做**路径穿越校验**（只允许 `[A-Za-z0-9_.-]`，
    拒绝 `.` / `..` / 空串），非法 id 只是"这一条读不了"，不是崩溃；
    ③ **只读尾部**（日志 200 行 ≤512 KiB、账本 50 行 ≤256 KiB）、坏行跳过并计数、任何 IO 异常都转成
    一句可读原因（"读不到"与"还没调用过"必须分得开）——这两块都是旁路读数，**永不抛、永不红**；
    ④ **账本会在"没有对话帧"的时刻增长**：压缩那两路（内置 `compact`、插件中转经执行站 `llm.call`）
    只写 `usage.jsonl`、不发对话帧，实时行入口永远收不到它们 ⇒ 「本轮调用列表」在挂载读一次之外，
    还必须**在 `llm_hidden` 系统提示帧到达时**（自动/手动压缩都会来）**以及离开 `compacting` 状态时**
    重读账本尾部（重读走同键去重 + 孪生合并，重复读不会长出第二行）——
    少了这一步，用户点了压缩、账本明明多了一行，界面却永远显示「0 次」（用户 2026-10-03 真机报告）。

21. **临时员工的入口列表取自落盘名册，不随消息窗口抖动**（用户 2026-10-03：「进入某个临时成员的
    选项经常会无端变化」；[test/subagent_transcript_test.dart](../test/subagent_transcript_test.dart)）：
    入口（[ui/widgets/subagent_view_switcher.dart](ui/widgets/subagent_view_switcher.dart)）**不再**从
    「当前已加载的消息窗口」里数：`SubagentTranscript` 多了一层**落盘名册**
    （[ui/models/subagent_roster.dart](ui/models/subagent_roster.dart) ← `GET /api/agents/{agentId}/subagents`，
    数据源是 `data/<agentId>/<sessionId>/subagents.json`），名册条目**恒在**且排在消息流观察到的前面；
    名字与「谁召来的」也**名册优先**（消息还没加载 / 已被淘汰时仍然正确）。中栏窗口化只热视口附近
    （不变量 19）**不再影响入口**。名册拉取失败**不清空**（保留上一次 + 留一行日志），退回消息流那一份。
    **「不跨会话保留」照旧**：切 agent / 换会话 `SubagentTranscript.clear()` 把名册层与消息层**一起**清掉。
22. **运行态与停止只作用在「当前视角的那个人」上**（用户 2026-10-03：「临时成员的运行情况不应影响主 agent
    运行情况……只有切到对应视角后才改停止按钮，且仅停止对应临时成员」；本文件不变量 18、
    [test/subagent_view_test.dart](../test/subagent_view_test.dart)）：输入框主按钮的 busy / 停止键，主视角只看
    `agent_status` 里 **`own_running == true`**（= 主 agent 自己的轮次）；子级帧（带 `subagent_id`）**只**
    更新「那个临时员工自己在跑」那一份，绝不把主视角变成停止键（旧核心没有 `own_running` 时按 status 判，
    与接线前逐字一致）。切到某个临时员工视角后，busy / 停止键只看**它自己**，点停止只发**它**的 id
    （核心对 `sub_…` 关掉团队级联 ⇒ 只停它自己，父 / 兄弟 / 其他成员不受影响）。
    **下拉条目还要看得见"它此刻在不在跑"**（用户 2026-10-03：「临时成员下拉里要看得见"是否在工作中"」）：
    以**只读**参数 `workingIds`（就是面板那份 `_workingSubagents`）传进
    [ui/widgets/subagent_view_switcher.dart](ui/widgets/subagent_view_switcher.dart)，在跑的条目多一个
    **克制**的指示（小圆点 + 「工作中」，跟随主题色），空闲态**不加**任何东西；**主会话那条永不显示**
    （它不是临时员工）。状态**不塞回** `SubagentTranscript`——那是"过程 / 入口"的分栏，与"谁在跑"是两件事。

## 测试

```bash
flutter analyze lib test     # 必须零告警
flutter test                 # 仓库根的 test/：组件 + 假核心 HTTP/WS 测试
```

钉子用例：`test/message_replay_guard_test.dart`、`test/session_rename_test.dart`、`test/plugin_panel_admin_test.dart`、
`test/main_page_sidebar_width_test.dart`、`test/message_list_scroll_test.dart`、`test/message_window_coordinate_test.dart`
（窗口坐标 / 落点 / 反馈校正 / 缺口切分四条纯函数）、`test/message_scrollbar_test.dart`、`test/tray_service_test.dart`（关闭决策与设置默认值）、
`test/close_to_tray_dialog_test.dart`（首次关闭说明框的返回值）、`test/single_instance_test.dart`（锁键/端口纯函数、
第二个实例被识别并唤起窗口、外人占端口不拦人）、`test/agent_delete_flow_test.dart`（删除闸门的 UI 接线：结构化 409、
级联重试、只删 TOP 才回落插件作用域）、`test/message_input_test.dart`（输入框：多文件粘贴、草稿按 team+session、
「+」菜单展开原位变高与 Esc 收起、图片缩略图 vs 文件卡、点开预览）、`test/attachment_preview_test.dart`
（附件预览：扩展名分类与大小文案、三档读取（文本 / 二进制 / 图片 / 缺失 / 目录 / 截断）、预览对话框）、
`test/tool_row_detail_test.dart`（一行式：中文标签 + 关键参数、行尾增量、悬停提亮、点击 → 详情页完整参数与结果、空态与关闭、
派生文本纯函数、右栏页签接线源钉）、`test/message_stream_style_test.dart`（模型消息高亮块不套边框、用户消息仍是气泡）、
`test/code_highlight_test.dart`（语言识别、各语言词法、注释与字符串的优先级、未闭合块注释、记号不重叠、控制器着色 +
大文件退回单色 + 输入法组字交回平台）、`test/code_gutter_layout_test.dart`（行号槽布局：逐视觉行给号、折行的续行留空、宽度越窄折行越多、尾随换行与空文本各占一个号、纵向位置单调递增且末行底边 = totalHeight、宽度非法不抛）、`test/file_editor_test.dart`（真起假核心 HttpServer：改一下就进未保存态、Ctrl+S 发出
完整内容与 `if_size`、保存失败给可见原因、409 冲突 → 覆盖保存带 force=1、截断/二进制/图片/外部 readOnly 四种只读闸门、
**同文件双窗格共享一份缓冲**（同一个控制器、一边打字另一边立刻可见、任一窗格保存后两边一起变成已保存且只发一次 PUT、
真只读的文档不建控制器、窗格 dispose 不动外部传入的缓冲、缓冲只在值真变时通知）、真面板分屏的端到端接线（同一份缓冲 +
关掉一个窗格后另一个继续可编辑）、失焦保存的开与关、返回时静默写回或问一次、**源码模式的行号槽**（左侧出现 1..N、加行删行跟着变、软换行时续行不编号且行号与正文逐行对齐、滚动后跟着 offset 平移且仍然对齐、只读视图同样有、图片 / Markdown 预览没有））、`test/split_panes_test.dart`（二分几何、拖动比例、夹取、太窄降级、
文件面板的分屏接线源钉：同文件双开复用同一个缓冲、不再锁只读）、`test/vt_screen_test.dart`（VT 解析器：换行 / `\r` 覆盖、SGR、CUP/ED/EL、备用屏进出、
跨块 UTF-8、宽字符两格、未知序列安全跳过、resize、DSR/DA 应答、随机含 ESC 字节流不抛）、
`test/vt_scrollback_test.dart`（回滚缓冲：主屏整屏滚动才进历史、备用屏与滚动区域内部不进、上限丢最老的、
`historyPushed` 只增、`ED3` 清历史而 `ED2` 不动、resize 后历史行跟着换宽度、RIS 复位）、
`test/terminal_ime_input_test.dart`（输入法通道：定字整段交出去、组字中一个字都不交、组字前半截已定字只交前缀、删到空安全、没 attach 也不炸、
**平台重发整段只补差额**、**收缩（退格）不重发**、**引擎把"残留组字 + 提交结果"整段送回来时只发新定字**（真机拼音漏进 shell 的钉子）、
直接定原文（结果 == 组字）不误剥、追加形态只交一份、连着两轮组字不串、**原样回显不许改写平台模型**）、
`test/terminal_selection_test.dart`（终端选区纯逻辑：反向拖拽规范化、单行 / 多行 / 跨历史与当前屏、行尾空格裁掉、宽字符两半合一个字、
越界与空表夹住不抛、`columnsIn` 的首行 / 中间行 / 末行区间）、
`test/composer_primary_action_test.dart`（右下角那个键两态：生成中且空 = 停止键并回调、一开始打字换回发送键、删空转回、不在生成中始终是发送键、没接停止回调就不显示）、
`test/terminal_send_command_test.dart`（`#TSend`：引号 / 裸文本 / `@路径` / 混写 / 带空格路径的解析，以及按键拦截的吞与补发：整行扣住、发现不是指令时原样补发、退格只吃本地缓存、其它按键前先补发、`#TSend` 单独一行 = 空指令）、
`test/terminal_panel_test.dart`（终端面板：打开就发 `terminal_open` 与尺寸并抢焦点、ready 显示 shell/cwd、
输出进缓冲、键盘译码（回车 / 方向键 / Ctrl+C）、Ctrl+J 交给外层、error 与 exit 的显示、别的会话 id 的帧被丢、
dispose 发 `terminal_close`、布局变化发 `terminal_resize`、**输入法连接必须带 `viewId`**——缺了平台不认这个 client，
中英文一个字都打不出来、**左键拖拽选中 + Ctrl+C 复制（有选区时不再发 0x03）**、Ctrl+Shift+C / Ctrl+Insert 复制、
没选中时 Ctrl+C 仍发 0x03、Ctrl+V / Shift+Insert 粘贴（`\n` → `\r`）、**开了 `?2004` 就包 `ESC[200~…ESC[201~`**、
右键菜单（没选中时"复制"置灰）、单击清选区、**光标那一格报给平台**（IME 候选窗定位））、
`test/message_window_test.dart`（消息窗口：按 `offset` 放页并按 id 去重对齐、实时追加落末尾且同 id 原位替换、
`gapsFor` 只报没加载的连续段、淘汰只留视口附近与末尾且正在流式 / 正在跑工具的不淘汰、`resetTail` 重载末尾一段）、
`test/message_scrollbar_test.dart`（右侧滑块几何与交互：位置按**全局下标**算、长度 = 可见条数 / 全局条数并有下限、
装得下整屏就不画、拖它按落点换算成全局下标回调出去、**反解与绘制严格互逆**（抓拇指顶端/底端反解回来还是那一条）、
反解单调不减、**拖拽时拇指跟着指针走**（面板把回填下标当真值也一样，旧口径会按 `total/(total-visible)` 领跑）、
**桌面平台下中栏不许再有原生 `Scrollbar`**（否则它在自绘那条旁边乱跳）且列表照样能滚）、
`test/conversation_history_api_test.dart`（真起假核心 HttpServer：末尾一段只带 `limit`、`from=` 拉那一段、
`at=` 定位、`before=` 老口径、不带 limit 时不发 limit，且 `offset` / `total` 解析正确）、
`test/team_scope_view_test.dart`（团队级模式/目录合成：成员跟随 TOP 的模式与目录、自己的 SSH 优先、
目录只认 TOP 那份、TOP 是 SSH 时成员切不回本地）。
`test/file_tree_icon_test.dart`（文件树视觉映射纯函数：目录收起 / 展开的图标与暖黄、一张"扩展名 → 类型 + 固定色"表、
各家族（图片 / 压缩包 / 纯文本 / 其它源码）、大小写与完整路径与反斜杠、无扩展名与点开头 → 未知类型不猜、各家族颜色互不相同，
以及 git 状态配色与"被忽略更淡"）、
`test/workspace_paths_test.dart`（工作空间相对路径纯函数：归一化 / 拼接 / 父目录 / 祖孙判据的前缀陷阱 / 改名整段重映射；
名字校验的空·点·分隔符·保留字符·控制字符·结尾点空格·过长·Windows 保留名·同名（不分大小写、重命名跳过自己、没变化）、
行内改名默认选中名字本体）、
`test/workspace_git_status_test.dart`（git 状态：状态码解析（含 porcelain 的 `??` / `!`，**未知码不着色**）、
字母 / 中文 / 聚合优先级严格递减、响应宽容解析（不是仓库 / 缺 is_repo / entries 非 List / 未知状态与缺 path 丢掉 / truncated）、
目录聚合（前缀陷阱 `src2` 不算在 `src` 名下、优先级取最需要注意的、目录自身条目、根聚合全部））、
`test/file_tree_explorer_test.dart`（真起假核心 HttpServer：行高 22 与字号 13 与省略号、**不再渲染大小 / 时间列**
（只在悬停 tooltip 里，含全名与 `N 项`）、箭头只在目录上且展开转 90°、同级文件与目录名字对齐、缩进引导线随层级
（1 层 1 条、2 层 2 条）且是 1px、整行悬停浅底、选中更重的底 + 2px 主色条、键盘 ↑/↓ 移动选中与 → 展开、
点目录就地展开（惰性拉那一层）再点折叠、**展开状态跨刷新保持**、空目录 / 目录加载失败 / 根加载失败 / 截断 / 首帧加载中各档提示、
git 着色（文件按状态 + 目录聚合 + 一次请求 + `is_repo=false` 与端点 404 都静默）与改名 / 删除后重拉、
右键菜单项齐备（含既有"下载"回调）、空白处右键只给通用动作、复制路径写剪贴板、在文件夹中显示算不出绝对路径时如实拒绝、
新建文件（PUT 空内容 / 重名不覆盖 / 对话框非法名不关框）、新建文件夹（核心 409 原样显示）、
行内改名（回车确认 / 重名行内红字不提交 / Esc 取消）、删除（目录确认框警告递归且带 recursive=1 / 文件不警告 / 取消什么都不做 /
工作空间根不发请求））、
`test/file_tree_viewer_sync_test.dart`（树 ↔ 查看器**同屏**的端到端接线，全部真点击：没打开文件时树独占 /
打开文件出现上下分栏且树与查看器都在 / 「关闭查看器」回到树独占、分屏后（查看器内部两格）在树里点另一个文件落到
**活动窗格**、打开文件后**在树里右键重命名它** → 窗格路径跟着改并按新路径重拉 + 树里换成新名字、
打开文件后**在树里删除它** → 窗格自动关掉 + 给提示 + 回到树独占、打开 / 关闭查看器不丢树的展开状态（子树被搬而不是重建）、
拖分隔条改变比例且关掉再开仍是该比例、面板太矮（可用高度 < 200）降级成只显示查看器且一键回到树）。
