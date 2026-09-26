import 'dart:async';

/// 回复生成器接口（LLM 会话的抽象）。
///
/// M1 由 [ScriptedAgent] 提供固定回显，M3 由真实 LLM 会话（openai_dart 或
/// 手写 SSE 传输）实现同一接口。会话服务只依赖本接口，因此 M3 替换引擎
/// 时无需改动 WS/存储/状态机代码。
abstract interface class ReplyEngine {
  /// 流式产出回复片段。
  ///
  /// [isCancelled] 在每个片段产出前被检查：返回 true 时实现方应尽快结束流
  /// （对应前端「停止」按钮 → WS `stop` 帧）。
  Stream<String> stream({
    required String agentId,
    required String systemPrompt,
    required String userContent,
    required bool Function() isCancelled,
  });
}

/// M1 占位回复引擎：固定回显，用于打通"WS 上行 → 流式下行 → 落库"全链路。
///
/// 刻意**不做**任何网络调用：M1 的验收目标就是链路本身可观测。回复文本会
/// 说明当前里程碑，使 UI 上看到的流式输出即自证。
class ScriptedAgent implements ReplyEngine {
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
    return '【核心进程骨架已连通】M1 阶段尚未接入 LLM（M3）与工具（M4），'
        '本段为固定回显。\n\n'
        '你发送的内容：\n> ${quoted.isEmpty ? '(空)' : quoted}\n\n'
        '链路自证：本段文本由 tree_core 经本机回环 WebSocket 流式下发'
        '（msg_start → msg_chunk × N → msg_end），用户消息与回复已写入核心'
        '进程存储。M2 落盘前，重启应用不会保留。';
  }

  @override
  Stream<String> stream({
    required String agentId,
    required String systemPrompt,
    required String userContent,
    required bool Function() isCancelled,
  }) async* {
    final String reply = replyFor(userContent);
    for (int start = 0; start < reply.length; start += chunkChars) {
      if (isCancelled()) return;
      if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      if (isCancelled()) return;
      final int end = (start + chunkChars) > reply.length
          ? reply.length
          : start + chunkChars;
      yield reply.substring(start, end);
    }
  }
}
