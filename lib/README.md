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
| [ui/pages/main_page.dart](ui/pages/main_page.dart) | 三栏骨架、agent 列表（只列顶层 agent）、会话切换、插件槽位作用域 |
| [ui/widgets/message_panel.dart](ui/widgets/message_panel.dart) | 中栏消息流：分段渲染、工具卡片、提问卡片、断线重播去重、按 agent+会话过滤 |
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
6. 左栏只列顶层 agent（`team_id` 为空）；成员入口是 teammates 窗口。
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

## 测试

```bash
flutter analyze lib test     # 必须零告警
flutter test                 # 仓库根的 test/：组件 + 假核心 HTTP/WS 测试
```

钉子用例：`test/message_replay_guard_test.dart`、`test/session_rename_test.dart`、`test/plugin_panel_admin_test.dart`、
`test/main_page_sidebar_width_test.dart`、`test/message_list_scroll_test.dart`、`test/tray_service_test.dart`（关闭决策与设置默认值）、
`test/close_to_tray_dialog_test.dart`（首次关闭说明框的返回值）、`test/single_instance_test.dart`（锁键/端口纯函数、
第二个实例被识别并唤起窗口、外人占端口不拦人）。
