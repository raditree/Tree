import 'package:tree_core/tree_core.dart';

/// 假传输：按"轮次脚本"回放事件序列，并记录收到的请求。
///
/// 用途：`LlmSession` 的行为（工具循环、用量累计、上下文裁剪、取消）可以完全
/// 脱离网络与端点单测。每一轮 = 脚本里的一组事件；脚本用完后按"直接结束"处理。
class FakeTransport implements LlmTransport {
  FakeTransport(this.script);

  /// 每轮的事件序列（第一轮 = 第一次请求的响应）。
  final List<List<LlmStreamEvent>> script;

  /// 收到的全部请求（按顺序）。
  final List<LlmRequest> requests = <LlmRequest>[];

  int _turn = 0;

  /// 已消费的轮次数。
  int get turnsUsed => _turn;

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    requests.add(request);
    if (_turn >= script.length) {
      yield const LlmFinishEvent('stop');
      return;
    }
    final List<LlmStreamEvent> events = script[_turn++];
    for (final LlmStreamEvent event in events) {
      if (isCancelled?.call() ?? false) {
        yield const LlmFailureEvent('已取消', cancelled: true);
        return;
      }
      yield event;
      if (event is LlmFailureEvent || event is LlmFinishEvent) return;
    }
  }

  @override
  Future<void> close() async {}
}

/// 假工具执行器：声明若干工具并记录调用，返回脚本化结果。
class FakeToolRunner implements ToolRunner {
  FakeToolRunner({
    this.specs = const <ToolSpec>[],
    this.result = '工具结果',
    this.error,
    this.shouldThrow = false,
  });

  final List<ToolSpec> specs;
  final String result;
  final Object? error;
  final bool shouldThrow;

  final List<ToolInvocation> invocations = <ToolInvocation>[];

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) => specs;

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async {
    invocations.add(invocation);
    if (shouldThrow) throw StateError('工具炸了');
    if (error != null) return ToolOutcome('$error', isError: true);
    return ToolOutcome(result);
  }

  @override
  Future<void> close() async {}
}

/// 组装一段"正文流式输出"的脚本。
List<LlmStreamEvent> textScript(String text, {bool withUsage = true}) {
  final List<LlmStreamEvent> events = <LlmStreamEvent>[];
  final int part = (text.length / 3).ceil();
  for (int start = 0; start < text.length; start += part) {
    final int end = start + part > text.length ? text.length : start + part;
    events.add(LlmTextDelta(text.substring(start, end)));
  }
  if (withUsage) {
    events.add(
      const LlmUsageEvent(
        LlmUsage(promptTokens: 100, completionTokens: 7, totalTokens: 107),
      ),
    );
  }
  events.add(const LlmFinishEvent('stop'));
  return events;
}

/// 组装一段"分片工具调用"的脚本：arguments 被切成 [splits] 段下发。
List<LlmStreamEvent> toolCallScript({
  required String name,
  required String arguments,
  String callId = 'call_1',
  int index = 0,
  int splits = 3,
  bool withUsage = true,
}) {
  final List<LlmStreamEvent> events = <LlmStreamEvent>[
    LlmToolCallDelta(index: index, id: callId, name: name),
  ];
  final int part = (arguments.length / splits).ceil().clamp(
    1,
    arguments.length,
  );
  for (int start = 0; start < arguments.length; start += part) {
    final int end = start + part > arguments.length
        ? arguments.length
        : start + part;
    events.add(
      LlmToolCallDelta(
        index: index,
        argumentsDelta: arguments.substring(start, end),
      ),
    );
  }
  if (withUsage) {
    events.add(
      const LlmUsageEvent(
        LlmUsage(promptTokens: 50, completionTokens: 5, totalTokens: 55),
      ),
    );
  }
  events.add(const LlmFinishEvent('tool_calls'));
  return events;
}
