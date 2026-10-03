// `llm.call` 的**软超时**（用户 2026-10-03 定夺 (a)：把原来的硬超时改成软的）。
//
// 全仓断言（写进 llm/README.md 不变量）：**没有任何硬超时**；限制只有两类——
// ①心跳丢失 ②软超时；**软超时后只允许显式关闭**。
// 此前这里是 `.timeout(120s, onTimeout: 已中止)`：一刀切中止插件的一次性调用
// （压缩插件走的就是它）⇒ 与断言冲突。
//
// 红（旧实现）：到点回包变成 `{'error': 'llm.call 超过 Ns 未完成，已中止'}`。
// 绿（新实现）：到点**只留痕、不中止**，回包照旧在流结束时送达（**结果不丢**）。
import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 可控传输：由测试决定何时吐事件（用来制造"到点了还没结束"的现场）。
class _SlowTransport implements LlmTransport {
  final StreamController<LlmStreamEvent> _events =
      StreamController<LlmStreamEvent>();

  void push(LlmStreamEvent event) => _events.add(event);

  Future<void> finish() async {
    if (!_events.isClosed) await _events.close();
  }

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) => _events.stream;

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

/// 假的可关闭句柄（登记表那一项的替身）：`isClosed` 由测试置位，模拟"被显式关闭"。
class _Guard implements LlmRequestGuard {
  bool isClosed = false;
  bool finished = false;

  @override
  String get handle => 'call_test_1';

  @override
  bool get closed => isClosed;

  @override
  void finish() => finished = true;
}

void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
  );

  LlmJsonCaller callerOf(_SlowTransport transport, List<String> logs, Duration t) =>
      LlmJsonCaller(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        timeout: t,
        log: logs.add,
      );

  Future<Map<String, dynamic>> callIt(LlmJsonCaller caller) => caller.call(
    agentId: 'agt_1',
    modelId: 'demo',
    messages: <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': '给我一个 JSON'},
    ],
  );

  test('软超时到点不中止：仍在等回包，回包到来时照旧送达（结果不丢）', () async {
    final _SlowTransport transport = _SlowTransport();
    final List<String> logs = <String>[];
    final LlmJsonCaller caller = callerOf(
      transport,
      logs,
      const Duration(milliseconds: 60),
    );

    final Future<Map<String, dynamic>> pending = callIt(caller);
    // 越过软超时点（60ms）再多等一会儿：此时**不该**有任何"已中止"
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(
      logs.any((String l) => l.contains('软超时') && l.contains('不中止')),
      isTrue,
      reason: '到点要留痕（说明"仍在跑、不中止、要收手请走显式关闭入口"）',
    );

    // 到点之后**仍然在等**：这时回包照旧送达
    transport.push(const LlmTextDelta('{"ok":true}'));
    await transport.finish();
    final Map<String, dynamic> reply = await pending;
    expect(
      reply['error'],
      isNull,
      reason: '软超时**不是失败**：旧实现在这里会返回"llm.call 超过 Ns 未完成，已中止"',
    );
    expect(reply['ok'], isTrue, reason: '结果照旧送达（不丢）');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('timeout 为 0 = 永不软超时（连留痕都不发生）', () async {
    final _SlowTransport transport = _SlowTransport();
    final List<String> logs = <String>[];
    final LlmJsonCaller caller = callerOf(transport, logs, Duration.zero);
    final Future<Map<String, dynamic>> pending = callIt(caller);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      logs.where((String l) => l.contains('软超时')),
      isEmpty,
      reason: '0 = 永不软超时：不设计时器、不留痕',
    );
    transport.push(const LlmTextDelta('{"ok":true}'));
    await transport.finish();
    expect((await pending)['error'], isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('软超时到点登记成"可关闭运行"；被显式关闭 ⇒ 立刻取消并交出可读原因', () async {
    final _SlowTransport transport = _SlowTransport();
    final List<String> logs = <String>[];
    final _Guard guard = _Guard();
    int registered = 0;
    final LlmJsonCaller caller = LlmJsonCaller(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
      timeout: const Duration(milliseconds: 60),
      requestRegistrar:
          ({
            required String agentId,
            required String sessionId,
            required String model,
            required int turn,
          }) {
            registered++;
            return guard;
          },
      log: logs.add,
    );

    final Future<Map<String, dynamic>> pending = callIt(caller);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      registered,
      1,
      reason: '软超时到点**才**登记（正常快调用不进表，不打扰右栏与 query_status）',
    );
    expect(
      logs.any((String l) => l.contains('可关闭运行')),
      isTrue,
      reason: 'C′：登记要留痕（含句柄，便于去 tool_runs / 右栏关它）',
    );

    // 显式关闭：用户右栏 / 插件 `tool.close` / agent `tool_runs action=close`（同一实现）
    guard.isClosed = true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final Map<String, dynamic> reply = await pending;
    expect(
      reply['error'],
      contains('显式关闭'),
      reason: '关闭 ⇒ 立刻以取消收尾并给出可读原因（不是无限等、也不是"已中止"）',
    );
    expect(guard.finished, isTrue, reason: '登记项要收尾（不留在表里冒充"还在跑"）');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
