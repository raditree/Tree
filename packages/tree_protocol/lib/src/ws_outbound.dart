/// WebSocket **下行**消息类型（核心进程 → 前端）。
///
/// 与现状 server 的下行帧一一对应（`server/agent/chat.py` 流式与状态推送、
/// `server/ws/ws_manager.py` 分帧与心跳、`server/io_/local_executor.py` 反向执行请求、
/// `server/plugin/*` 插件事件）。桌面分支保持帧形状不变，前端 lib/ui 才能零改动。
abstract final class WsOutboundType {
  // ── 流式回复分段（agent 输出） ─────────────────────────────────────────
  /// 文本/思考段开始。
  static const String msgStart = 'msg_start';

  /// 段内容增量。
  static const String msgChunk = 'msg_chunk';

  /// 段结束。
  static const String msgEnd = 'msg_end';

  /// 段/轮次的 token 用量（进度条分母为 max_seqlen）。
  static const String msgUsage = 'msg_usage';

  /// 工具调用开始（含参数）。
  static const String toolStart = 'tool_start';

  /// 工具调用结束（含结果）。
  static const String toolEnd = 'tool_end';

  // ── 会话与状态 ────────────────────────────────────────────────────────
  /// agent 工作状态（working/idle/...）。
  static const String agentStatus = 'agent_status';

  /// 会话被创建（成员自动建会话时通知前端刷新）。
  static const String sessionCreated = 'session_created';

  /// todo 列表更新。
  static const String todoUpdate = 'todo_update';

  /// 提问卡片推送。
  static const String askUserQuestion = 'ask_user_question';

  /// 提问已解决（跨端/多窗口同步）。
  static const String askUserQuestionResolved = 'ask_user_question_resolved';

  /// 通用文本消息（`_send_text_as_agent` 路径）。
  static const String message = 'message';

  /// 错误提示（`data.message` 携带可读文案）。
  static const String error = 'error';

  // ── 传输层 ────────────────────────────────────────────────────────────
  /// 心跳。
  ///
  /// 注意：**双向**使用同一字面量——前端定时上报，核心进程也会主动下发
  /// （`ws_manager.py` 保活循环），故同时存在于上行与下行常量中。
  static const String heartbeat = 'heartbeat';

  /// 大帧分片：起始片。
  static const String frameBegin = 'frame_begin';

  /// 大帧分片：中间片。
  static const String frameChunk = 'frame_chunk';

  /// 大帧分片：结束片。
  static const String frameEnd = 'frame_end';

  // ── 执行器注册回执 ────────────────────────────────────────────────────
  static const String registerLocalExecutorAck = 'register_local_executor_ack';
  static const String unregisterLocalExecutorAck =
      'unregister_local_executor_ack';
  static const String registerSshExecutorAck = 'register_ssh_executor_ack';
  static const String unregisterSshExecutorAck = 'unregister_ssh_executor_ack';

  /// 执行器注册丢失通知（需前端重新注册）。
  static const String registrationLost = 'registration_lost';

  // ── 反向执行通道（核心进程 → 前端执行器） ──────────────────────────────
  /// 工具执行请求。
  static const String toolExecRequest = 'tool_exec_request';

  /// 工具执行取消。
  static const String toolExecCancel = 'tool_exec_cancel';

  // ── 插件 ──────────────────────────────────────────────────────────────
  /// 插件自定义事件（`plugin_event`）。
  static const String pluginEvent = 'plugin_event';

  /// 插件实例生命周期状态。
  static const String pluginStatus = 'plugin_status';

  /// 全部下行类型（完备性测试与文档用）。
  static const Set<String> all = <String>{
    msgStart,
    msgChunk,
    msgEnd,
    msgUsage,
    toolStart,
    toolEnd,
    agentStatus,
    sessionCreated,
    todoUpdate,
    askUserQuestion,
    askUserQuestionResolved,
    message,
    error,
    heartbeat,
    frameBegin,
    frameChunk,
    frameEnd,
    registerLocalExecutorAck,
    unregisterLocalExecutorAck,
    registerSshExecutorAck,
    unregisterSshExecutorAck,
    registrationLost,
    toolExecRequest,
    toolExecCancel,
    pluginEvent,
    pluginStatus,
  };

  /// 分帧三件套（server 侧由 `ws_manager._FRAME_*` 常量产出，非字面量，
  /// 完备性测试单独核对）。
  static const Set<String> frameChunking = <String>{
    frameBegin,
    frameChunk,
    frameEnd,
  };
}
