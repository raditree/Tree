import 'agent_engine.dart';

/// 占位回复引擎：固定回显。
///
/// M3 起**生产路径是真实 LLM**（`LlmAgentEngine`），本类的用途收敛为：
/// 1. 未配置模型时的降级/自检行为可被测试稳定复现（无网络、输出确定）；
/// 2. WS 帧序列与落库逻辑的单测替身——端点波动不该影响协议测试。
class ScriptedAgent implements AgentEngine {
  ScriptedAgent({
    this.chunkDelay = const Duration(milliseconds: 40),
    this.chunkChars = 24,
  });

  /// 每片段之间的延迟（模拟流式节奏；测试中传 [Duration.zero]）。
  final Duration chunkDelay;

  /// 每片段的字符数。
  final int chunkChars;

  /// 生成固定回复文本（纯函数，便于单测与文档引用）。
  static String replyFor(String userContent) {
    final String quoted = userContent.trim();
    return '【占位回复】本段文本由 tree_core 的占位引擎生成（未走真实模型）。\n\n'
        '你发送的内容：\n> ${quoted.isEmpty ? '(空)' : quoted}\n\n'
        '链路自证：本段经本机回环 WebSocket 流式下发'
        '（msg_start → msg_chunk × N → msg_end），用户消息与回复已写入核心'
        '进程存储（~/.tree）。配置真实模型后即由 LLM 生成。';
  }

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    final String reply = replyFor(context.userContent);
    for (int start = 0; start < reply.length; start += chunkChars) {
      if (isCancelled()) {
        yield const AgentDone(cancelled: true);
        return;
      }
      if (chunkDelay > Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }
      if (isCancelled()) {
        yield const AgentDone(cancelled: true);
        return;
      }
      final int end = (start + chunkChars) > reply.length
          ? reply.length
          : start + chunkChars;
      yield AgentText(reply.substring(start, end));
    }
    yield const AgentDone(finishReason: 'stop');
  }

  @override
  Future<void> close() async {}
}
