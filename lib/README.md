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
| [ui/widgets/](ui/widgets/) | 文件面板 / 查看器（源码高亮 + 编辑保存 + 分屏，见 [split_panes.dart](ui/widgets/split_panes.dart)）/ **集成终端（[terminal_panel.dart](ui/widgets/terminal_panel.dart)，Ctrl+J）**/ 消息输入框（[message_input.dart](ui/widgets/message_input.dart) + [attachment_preview.dart](ui/widgets/attachment_preview.dart) + 无边框输入样式 [input_style.dart](ui/widgets/input_style.dart)）/ 右栏详情（[detail_panel.dart](ui/widgets/detail_panel.dart)）、PDF 预览、Spec、待办、提问、插件、MCP、模型信息、Git 历史、设置页 |
| [ui/services/](ui/services/) | 重播守卫、下载中心、会话重命名、插件 UI 槽位注册、主题、**代码高亮（[code_highlight.dart](ui/services/code_highlight.dart)）**、**编辑器偏好（[editor_settings.dart](ui/services/editor_settings.dart)）**、详情选中（[detail_selection.dart](ui/services/detail_selection.dart)）、**团队级模式与目录合成（[team_scope_view.dart](ui/services/team_scope_view.dart)）** |

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
    思考一行 =「思考 · 首行摘要」。**中栏不再就地展开**——一轮里工具动辄几十条，卡片会把时间线切散，
    一行之后整轮动作像一份清单。悬停有呼应（图标提亮 + 底色），点击 → 右栏**第 5 个内置页签「详情」**摊开完整参数与结果；
    右栏收着时自动展开。选中项走 [DetailSelection](ui/services/detail_selection.dart)（全局 ChangeNotifier，存消息**快照**，
    帧后按 id 刷新——跑着的工具 / 思考内容是原地变更的，必须跟着长），切 agent / 整表重拉时清空。

12. **源码模式按语言着色，且只能编辑纯文本**（[ui/services/code_highlight.dart](ui/services/code_highlight.dart)、
    [ui/widgets/file_viewer.dart](ui/widgets/file_viewer.dart)、[io/api_service.dart](io/api_service.dart) 的 `saveFileContent`）：
    着色不引第三方包，一张规则表 + 单遍扫描（关键字 / 类型 / 字符串 / 注释 / 数字 / 注解 / 函数名），
    **只在 ≤ 128 KB 时着色**（超过退回单色，保证输入不卡），记号按「文本 + 配色」缓存——按键才重算一次；
    是否文本**看字节**（前 4 KB 有 NUL 就当二进制，扩展名骗人的文件不会被渲染成乱码）。只读闸门（缺一不可）：
    图片 / PDF / Office（复杂格式）、**被截断的大文件**（写回去等于把文件截短）、含 NUL 的二进制、分屏里被锁的副本。
    保存**一律走核心** `PUT /api/files/{id}/content`（本机与 SSH 同一套，前端不直接写盘），带 `if_size` 做外部改动检测：
    磁盘现值不符 → 409 → UI 给「覆盖保存（force）/ 放弃我的改动并刷新 / 取消」。自动保存只做**失焦与离开**
    （切走、关窗格、换文件、关查看器；可在设置里关掉改成纯手动 Ctrl+S），**没有定时器**——定时写入会打断正在输入的思路。

13. **分屏（VS Code 型）只做二分**（[ui/widgets/split_panes.dart](ui/widgets/split_panes.dart) +`file_panel`）：左右 / 上下可切、
    分隔可拖（夹在 0.2–0.8，同方向最小 120px）、每格独立打开文件与保存、可用空间太窄降级成单窗格。
    **同一个文件**在两个窗格里打开时，非活动窗格强制只读——两份缓冲各写各的，后保存的那次会把对方写的覆盖掉。
    换文件 / 关窗格前先 `confirmLeave()`：开着失焦保存就静默写回，关着就问「保存 / 不保存 / 取消」。

14. **Ctrl+J 把输入框那块换成集成终端（真 PTY）**（[ui/widgets/terminal_panel.dart](ui/widgets/terminal_panel.dart)、
    [ui/services/vt_screen.dart](ui/services/vt_screen.dart)、[io/websocket_service.dart](io/websocket_service.dart) 的 `terminalFrames`）：
    打开时**主动展开**（按面板高 40%，夹 160–420）并把焦点交给终端，再按一次回到输入框（草稿靠草稿缓存原样回来）；
    终端**没有输入行**——所有按键经 `Focus.onKeyEvent` 译成终端字节（回车 `\r`、退格 `0x7f`、方向键 `ESC[A..D`、
    Ctrl+字母 `0x01..0x1A`、可打印字符走 `event.character` 的 UTF-8），Ctrl+J 例外（留给切换）。
    核心开**真伪终端**，输出是**原始字节**（base64 过 WS），前端用自制的 VT 解析器还原成屏幕
    （光标定位 / SGR / 备用屏都在内），再 `CustomPaint` 画格子。两个后端**都是真 PTY**：
    本机 agent 走平台伪终端（Windows ConPTY / POSIX `script`）；远端（SSH）agent 走 SSH 会话通道 +
    `pty-req`（dartssh2），并**复用那条已建好的 SSH 连接**（不为终端再连一次），远端的
    `terminal_ready.cwd` 是空串——远端工作目录由 `SshWorkspaceIO` 自己解决，界面显示「工作区」。
    判据是**有效 SSH**（成员跟随团队 TOP 的 SSH，见不变量 15）；没接线时回可读错误，**绝不**
    悄悄在本机给远端 agent 起一个终端。关面板 / 换 agent / 断连都会把 shell 收掉。
    终端的边界（VT 解析器没实现的部分、远端分支**没有真机 sshd 验证过**）见
    [docs/known-issues.md](../docs/known-issues.md) #12。

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
派生文本纯函数、右栏页签接线源钉）、`test/message_stream_style_test.dart`（模型消息高亮块不套边框、用户消息仍是气泡）、
`test/code_highlight_test.dart`（语言识别、各语言词法、注释与字符串的优先级、未闭合块注释、记号不重叠、控制器着色 +
大文件退回单色 + 输入法组字交回平台）、`test/file_editor_test.dart`（真起假核心 HttpServer：改一下就进未保存态、Ctrl+S 发出
完整内容与 `if_size`、保存失败给可见原因、409 冲突 → 覆盖保存带 force=1、截断/二进制/图片/分屏副本四种只读闸门、
失焦保存的开与关、返回时静默写回或问一次）、`test/split_panes_test.dart`（二分几何、拖动比例、夹取、太窄降级、
文件面板的分屏接线源钉）、`test/vt_screen_test.dart`（VT 解析器：换行 / `\r` 覆盖、SGR、CUP/ED/EL、备用屏进出、
跨块 UTF-8、宽字符两格、未知序列安全跳过、resize、DSR/DA 应答、随机含 ESC 字节流不抛）、
`test/terminal_panel_test.dart`（终端面板：打开就发 `terminal_open` 与尺寸并抢焦点、ready 显示 shell/cwd、
输出进缓冲、键盘译码（回车 / 方向键 / Ctrl+C）、Ctrl+J 交给外层、error 与 exit 的显示、别的会话 id 的帧被丢、
dispose 发 `terminal_close`、布局变化发 `terminal_resize`）、
`test/team_scope_view_test.dart`（团队级模式/目录合成：成员跟随 TOP 的模式与目录、自己的 SSH 优先、
目录只认 TOP 那份、TOP 是 SSH 时成员切不回本地）。
