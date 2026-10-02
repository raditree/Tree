# lib（Flutter 前端）

三栏桌面界面 + 与本地核心的传输层。**不持有业务逻辑**：所有状态取自核心的 REST/WS。

## 结构

| 位置 | 内容 |
| --- | --- |
| [main.dart](main.dart) | 启动序列：附着或拉起核心 → 读握手 → `ApiService.setToken` → 建 WS |
| [io/core_process_launcher.dart](io/core_process_launcher.dart) | 找核心可执行文件（`TREE_CORE_EXE` → 应用同目录 → `.output/`）、拉起、解析握手、关窗时请它优雅退出；找不到时给**带修复指引**的错误页 |
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

## 测试

```bash
flutter analyze lib test     # 必须零告警
flutter test                 # 仓库根的 test/：组件 + 假核心 HTTP/WS 测试
```

钉子用例：`test/message_replay_guard_test.dart`、`test/session_rename_test.dart`、`test/plugin_panel_admin_test.dart`、
`test/main_page_sidebar_width_test.dart`、`test/message_list_scroll_test.dart`。
