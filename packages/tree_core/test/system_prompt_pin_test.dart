import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 记录每次运行拿到的系统提示词（= 真会发出去的那条 [0] system）。
class _CapturingEngine implements AgentEngine {
  final List<String> prompts = <String>[];

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    prompts.add(context.systemPrompt);
    yield const AgentText('ok');
    yield const AgentDone();
  }

  @override
  Future<void> close() async {}
}

/// 系统提示词**按会话钉住**：发消息不重建，只有会话初始化 / compact / 显式失效才重建。
void main() {
  late CoreServer server;
  late TestWs ws;
  late _CapturingEngine engine;
  late String agentId;
  const String sessionId = TreeStore.defaultSessionId;

  setUp(() async {
    engine = _CapturingEngine();
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      engine: engine,
    );
    agentId = server.store.createAgent(name: '钉住用例').id;
    ws = await TestWs.connect(server);
    ws.record();
  });

  tearDown(() async {
    await ws.close();
    await server.close();
  });

  /// 发一条消息并等到第 [runs] 次运行真的开始（引擎记到第 [runs] 条提示词）。
  Future<void> send(String content, int runs) async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': content,
      'session_id': sessionId,
    });
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (engine.prompts.length < runs && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await waitIdle(ws);
    expect(engine.prompts.length, runs, reason: '第 $runs 轮没有跑起来');
  }

  /// 换掉提示词的外部来源（真实场景里对应 ⑦/⑧ 快照补扫完成、工作空间文件被改）。
  void changePromptSource(String marker) {
    final String Function(CoreAgent)? original = specIndexProvider;
    specIndexProvider = (CoreAgent agent) => '## 变了的索引\n- $marker';
    addTearDown(() => specIndexProvider = original);
  }

  test('发消息不重建：外部来源变了，下一轮仍是同一串字节', () async {
    await send('第一轮', 1);
    final String first = engine.prompts.first;
    expect(first, isNotEmpty);
    expect(server.conversation.pinnedSystemPrompt(agentId, sessionId), first);

    changePromptSource('brand-new-var');
    await send('第二轮', 2);

    expect(engine.prompts[1], first, reason: '发消息不该让系统提示词变样');
    expect(engine.prompts[1], isNot(contains('brand-new-var')));
  });

  test('显式失效（compact / 用户改提示词 / 重置走同一条）之后才重建', () async {
    await send('第一轮', 1);
    final String first = engine.prompts.first;

    changePromptSource('brand-new-var');
    server.conversation.invalidateSystemPrompt(agentId, sessionId);
    await send('第二轮', 2);

    expect(engine.prompts[1], isNot(first), reason: '显式失效后重建');
    expect(engine.prompts[1], contains('brand-new-var'));
  });
}
