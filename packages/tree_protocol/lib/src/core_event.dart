/// 核心进程内部事件类型（LLM 会话生成器 → 编排层）。
///
/// 现状对应 `server/llm/llm.py::_run_completion_loop` 的 `yield` 产出与
/// `server/agent/chat.py::_stream_agent_reply` 的消费分支。这些**不是 WS 帧**，
/// 但同属跨模块协议：Dart 核心用同一组常量保证语义等价。
abstract final class CoreEventType {
  /// 正文增量。
  static const String text = 'text';

  /// 推理（thinking）增量。
  static const String thinking = 'thinking';

  /// 一次工具调用（含 name/arguments/result，工具执行完成后产出）。
  static const String toolCall = 'tool_call';

  /// 本轮被取消（停止按钮置位后在下个检查点退出）。
  static const String cancelled = 'cancelled';

  /// 本轮正常结束。
  static const String done = 'done';

  /// AskUserQuestion 触发暂停（agent 归闲，待用户作答后唤醒）。
  static const String askPaused = 'ask_paused';

  /// 错误终止（消费线程异常，content 为可读文案）。
  static const String error = 'error';

  /// 全部内部事件类型。
  static const Set<String> all = <String>{
    text,
    thinking,
    toolCall,
    cancelled,
    done,
    askPaused,
    error,
  };
}
