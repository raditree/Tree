import 'plugin_ui.dart';
import 'terminal.dart';

/// WebSocket **上行**消息类型（前端 → 核心进程）。
///
/// 对应 `server/ws/endpoints.py::register_ws` 的 `msg_type` 分发链，共 12 种。
/// 桌面分支中这些帧改走本地回环 WS（M1），类型与字段保持不变。
abstract final class WsInboundType {
  /// 心跳保活（前端每 10s 一次；必须小于核心判活窗口 I×N = 30s）。
  static const String heartbeat = 'heartbeat';

  /// 用户消息（顶层 agent 会话入口）。
  static const String userMessage = 'user_message';

  /// 停止当前 agent（含成员级联）。
  static const String stop = 'stop';

  /// 回答提问（ask_user_question 的应答）。
  static const String userAnswer = 'user_answer';

  /// 取消提问。
  static const String cancelQuestion = 'cancel_question';

  // 说明（M7c）：桌面端工具由**核心进程本机执行**，因此原先的
  // `register_*_executor`（注册前端执行能力）与 `tool_exec_response` /
  // `tool_exec_progress`（反向执行结果回报）整套上行帧已删除——它们描述的
  // "前端执行器"不存在了。插件宿主同理（核心自己拉起插件进程）。

  /// 插件 UI 交互回调（Q12）：前端在插件槽位上的按钮点击 / 表单提交。
  ///
  /// 值复用 [PluginUiFrameType.action]（**别名**，不重复字面量）；核心收到后按
  /// `plugin_id` 路由给声明该槽位的插件（见 core_server 的 pluginUiAction 分支）。
  static const String pluginUiAction = PluginUiFrameType.action;

  // ── 集成终端（Ctrl+J） ────────────────────────────────────────────────
  // 值复用 [TerminalInboundType.*]（**别名**，不重复字面量），见 terminal.dart。

  /// 开一个终端会话。
  static const String terminalOpen = TerminalInboundType.open;

  /// 键盘输入。
  static const String terminalInput = TerminalInboundType.input;

  /// 改窗口尺寸。
  static const String terminalResize = TerminalInboundType.resize;

  /// 结束会话。
  static const String terminalClose = TerminalInboundType.close;

  /// 全部上行类型（完备性测试与文档用）。
  static const Set<String> all = <String>{
    heartbeat,
    userMessage,
    stop,
    userAnswer,
    cancelQuestion,
    pluginUiAction,
    terminalOpen,
    terminalInput,
    terminalResize,
    terminalClose,
  };
}
