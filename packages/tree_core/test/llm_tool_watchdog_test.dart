// 「工具久不返回」的两条兜底（用户 2026-10-03 定夺口径）+ 引擎侧生命周期留痕。
//
// 1. **对账采用真实结果**：存储里若已有这次工具调用的结果 ⇒ 用它让**批收尾**
//    （**绝不注入合成结果**：探针只能交出"已经存在的那一份"）；
// 2. **没有结果 ⇒ 继续等显式取消**：不切开批、不放宽"批中途消息推迟到批结果之后"的
//    语义（两条都是用户**明确保留**的断言）；显式关闭（用户右栏 / 插件 `tool.close` /
//    agent `tool_runs action=close`，同一个实现）会让在途调用收敛，本 await 随之正常返回。
//
// 红/绿：把实现（`llm_session.dart` 的看门狗与探针）stash 掉 ⇒ 本文件的 ①③ 编译期红
// （`toolResultProbe` / `toolWatchdogInterval` 尚不存在）⇒ 证明"这两条此前没有"；
// 恢复后全绿。
import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 一个**永不返回**的工具（模拟"命令挂着不返回"那类现场），可被显式"收敛"。
class _HangingToolRunner implements ToolRunner {
  _HangingToolRunner({required this.specs});

  final List<ToolSpec> specs;
  final Completer<ToolOutcome> _gate = Completer<ToolOutcome>();
  int runs = 0;

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) => specs;

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) {
    runs++;
    return _gate.future;
  }

  /// 模拟"显式关闭 ⇒ 在途调用收敛"：交出一段可读结果。
  void converge(String result) {
    if (!_gate.isCompleted) _gate.complete(ToolOutcome(result));
  }

  @override
  Future<void> close() async {}
}

void main() {
  const List<ToolSpec> readTool = <ToolSpec>[
    ToolSpec(name: 'read_file', description: '读文件'),
  ];

  LlmSession session({
    required FakeTransport transport,
    required ToolRunner tools,
    ToolResultProbe? probe,
    void Function(String)? log,
  }) => LlmSession(
    transport: transport,
    model: 'demo',
    tools: readTool,
    toolRunner: tools,
    maxSeqlen: 128000,
    toolResultProbe: probe,
    toolWatchdogInterval: const Duration(milliseconds: 20),
    log: log,
  );

  Stream<AgentEvent> run(LlmSession s) => s.run(
    messages: <LlmMessage>[const LlmMessage.user('读一下')],
    agentId: 'a',
    sessionId: 's',
    isCancelled: () => false,
  );

  test('① 对账采用：存储里已有结果 ⇒ 用它收尾（真实结果，不注入合成内容）', () async {
    final List<String> logs = <String>[];
    final _HangingToolRunner tools = _HangingToolRunner(specs: readTool);
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      toolCallScript(name: 'read_file', arguments: '{"path":"a.txt"}'),
      textScript('收工'),
    ]);
    int probes = 0;
    final List<AgentEvent> events = await session(
      transport: transport,
      tools: tools,
      probe:
          ({
            required String agentId,
            required String sessionId,
            required String toolCallId,
          }) async {
            probes++;
            expect(toolCallId, isNotEmpty, reason: '对账必须带 callId');
            return '磁盘上已有的结果';
          },
      log: logs.add,
    ).let(run).toList();

    final AgentToolEnd end = events.whereType<AgentToolEnd>().single;
    expect(
      end.result,
      '磁盘上已有的结果',
      reason: '用的是存储里那一份真值，不是"结果缺失/超时"那种合成文案',
    );
    expect(events.whereType<AgentDone>(), isNotEmpty, reason: '批收尾 ⇒ 会话继续');
    expect(transport.turnsUsed, 2, reason: '收尾后照常发下一跳（工具结果已回灌）');
    expect(probes, greaterThan(0));
    expect(
      logs.any((String l) => l.contains('请求已发出')),
      isTrue,
      reason: 'C′：请求发出要留痕（此前"发出去了然后什么都没有"完全不可见）',
    );
    expect(
      logs.any((String l) => l.contains('首个事件')),
      isTrue,
      reason: 'C′：首个事件要留痕',
    );
    expect(
      logs.any((String l) => l.contains('对账采用')),
      isTrue,
      reason: 'C′：对账命中要留痕',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('② 没有结果 ⇒ 一直等（不假装成功、批不收尾）；显式关闭后立刻收敛', () async {
    final List<String> logs = <String>[];
    final _HangingToolRunner tools = _HangingToolRunner(specs: readTool);
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      toolCallScript(name: 'read_file', arguments: '{}'),
      textScript('收工'),
    ]);
    final List<AgentEvent> events = <AgentEvent>[];
    final StreamSubscription<AgentEvent> sub = run(
      session(
        transport: transport,
        tools: tools,
        probe:
            ({
              required String agentId,
              required String sessionId,
              required String toolCallId,
            }) async => null,
        log: logs.add,
      ),
    ).listen(events.add);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      events.whereType<AgentToolEnd>(),
      isEmpty,
      reason: '存储里没有结果 ⇒ 继续等，绝不用合成结果假装成功',
    );
    expect(transport.turnsUsed, 1, reason: '批没收尾 ⇒ 不会发下一跳');
    expect(
      logs.any((String l) => l.contains('继续等显式取消')),
      isTrue,
      reason: 'C′：等待本身要留痕（这就是凌川那类现场此前查不到的那一行）',
    );

    // 显式关闭（四个入口同一个实现）⇒ 在途调用收敛 ⇒ 批收尾、会话继续
    tools.converge('被显式关闭：命令已在后台运行/已终止');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      events
          .whereType<AgentToolEnd>()
          .map((AgentToolEnd e) => e.result),
      contains('被显式关闭：命令已在后台运行/已终止'),
      reason: '关闭后批收尾、会话继续（这条断言就是"停止后重发"能救回来的前提）',
    );
    await sub.cancel();
  }, timeout: const Timeout(Duration(seconds: 30)));
}

extension<T> on T {
  /// 让"构造 → 立即调用"读起来顺一点（测试内部小工具）。
  R let<R>(R Function(T) f) => f(this);
}
