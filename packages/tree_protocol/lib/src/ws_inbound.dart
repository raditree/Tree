/// WebSocket **上行**消息类型（前端 → 核心进程）。
///
/// 对应 `server/ws/endpoints.py::register_ws` 的 `msg_type` 分发链，共 12 种。
/// 桌面分支中这些帧改走本地回环 WS（M1），类型与字段保持不变。
abstract final class WsInboundType {
  /// 心跳保活（前端每 30s 一次）。
  static const String heartbeat = 'heartbeat';

  /// 用户消息（顶层 agent 会话入口）。
  static const String userMessage = 'user_message';

  /// 停止当前 agent（含成员级联）。
  static const String stop = 'stop';

  /// 回答提问（ask_user_question 的应答）。
  static const String userAnswer = 'user_answer';

  /// 取消提问。
  static const String cancelQuestion = 'cancel_question';

  /// 注册本地执行器（本机工具执行能力）。
  static const String registerLocalExecutor = 'register_local_executor';

  /// 注销本地执行器。
  static const String unregisterLocalExecutor = 'unregister_local_executor';

  /// 注册 SSH 执行器。
  static const String registerSshExecutor = 'register_ssh_executor';

  /// 注销 SSH 执行器。
  static const String unregisterSshExecutor = 'unregister_ssh_executor';

  /// 工具执行结果回报（反向通道）。
  static const String toolExecResponse = 'tool_exec_response';

  /// 工具执行进度续期（长任务防误判卡死）。
  static const String toolExecProgress = 'tool_exec_progress';

  /// 插件宿主通道上行（本批仅 event='exit'）。
  static const String pluginHostEvent = 'plugin_host_event';

  /// 全部上行类型（完备性测试与文档用）。
  static const Set<String> all = <String>{
    heartbeat,
    userMessage,
    stop,
    userAnswer,
    cancelQuestion,
    registerLocalExecutor,
    unregisterLocalExecutor,
    registerSshExecutor,
    unregisterSshExecutor,
    toolExecResponse,
    toolExecProgress,
    pluginHostEvent,
  };
}
