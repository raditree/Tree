import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// 可控引擎：启动后一直转，直到被取消；把每次 run 的历史快照记下来。
class _GatedEngine implements AgentEngine {
  final List<String> started = <String>[];
  final List<AgentRunContext> contexts = <AgentRunContext>[];
  final List<bool> cancelledAtEnd = <bool>[];

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    started.add(context.agentId);
    contexts.add(context);
    yield const AgentText('开始');
    while (!isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    cancelledAtEnd.add(true);
    yield const AgentDone(cancelled: true);
  }

  @override
  Future<void> close() async {}
}

/// 慢工具：**故意忽略** isCancelled，用来固定"正在执行的工具打断不了"这条边界。
class _SlowToolRunner implements ToolRunner {
  _SlowToolRunner({this.delay = const Duration(milliseconds: 200)});

  final Duration delay;
  DateTime? startedAt;
  DateTime? finishedAt;

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) => const <ToolSpec>[
    ToolSpec(
      name: 'slow',
      description: '慢工具',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    ),
  ];

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async {
    startedAt ??= DateTime.now();
    await Future<void>.delayed(delay); // 不检查取消：模拟"已经开始执行的命令"
    finishedAt = DateTime.now();
    return const ToolOutcome('慢工具结果');
  }

  @override
  Future<void> close() async {}
}

Future<void> _untilTrue(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = '',
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('超时等待：$reason');
}

void main() {
  const String sessionId = TreeStore.defaultSessionId;

  group('新消息打断在途 tool loop', () {
    late CoreServer server;
    late MemoryStore store;
    late _GatedEngine engine;
    late CoreAgent top;
    late TestWs ws;

    setUp(() async {
      store = MemoryStore();
      final CoreSettings settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'demo',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-test',
      });
      engine = _GatedEngine();
      server = await CoreServer.start(
        store: store,
        settings: settings,
        engine: engine,
        enableHeartbeat: false,
        streamChunkDelay: Duration.zero,
      );
      top = store.createAgent(name: '队长', modelId: 'demo');
      ws = await TestWs.connect(server);
      ws.record();
    });

    tearDown(() async {
      server.conversation.cancelAgent(top.id);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await ws.close();
      await server.close();
    });

    void sendMessage(String content) => ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': top.id,
      'content': content,
      'session_id': sessionId,
    });

    test('在途时发第二条：当前轮立刻收敛，新消息那轮马上启动且历史含两条', () async {
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');
      expect(server.conversation.isRunning(top.id), isTrue);

      sendMessage('第二条');
      await _untilTrue(
        () => engine.started.length == 2,
        reason: '第二轮启动（说明第一轮让位了）',
      );

      expect(server.conversation.interruptedRunCount, 1);
      final List<String> users = engine.contexts[1].history
          .where((CoreMessageRef r) => r.isUser)
          .map((CoreMessageRef r) => r.content)
          .toList();
      expect(users, <String>['第一条', '第二条'], reason: '注入 = 新消息已在历史里且顺序正确');

      // 打断**不**产生"已停止本轮生成。"（那是用户按 stop 的语义）
      expect(
        store
            .messages(top.id, sessionId)
            .where((CoreMessage m) => m.content.contains('已停止本轮生成')),
        isEmpty,
      );
    });

    test('用户按 stop 仍然给可见提示（打断与停止不混淆）', () async {
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');
      ws.send(<String, dynamic>{
        'type': WsInboundType.stop,
        'data': <String, dynamic>{'agent_id': top.id, 'session_id': sessionId},
      });
      await _untilTrue(
        () => store
            .messages(top.id, sessionId)
            .any((CoreMessage m) => m.content.contains('已停止本轮生成')),
        reason: '停止提示',
      );
      expect(server.conversation.interruptedRunCount, 0, reason: 'stop 不算打断');
    });

    test('团队投递（deliver）同样打断在途那一轮', () async {
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');

      // 不 await：这两个入口的 Future 要等"排队的那一轮整个跑完"才 resolve，
      // 而本测试用的是"不取消就不停"的引擎（await 会一直挂着）。
      unawaited(
        server.conversation.deliver(
          agentId: top.id,
          sessionId: sessionId,
          content: '来自队友的消息',
          senderName: '队友',
        ),
      );
      await _untilTrue(() => engine.started.length == 2, reason: '投递那轮启动');

      expect(server.conversation.interruptedRunCount, 1);
      expect(
        engine.contexts[1].history
            .where((CoreMessageRef r) => r.isUser)
            .map((CoreMessageRef r) => r.content)
            .toList(),
        <String>['第一条', '[来自 队友] 来自队友的消息'],
      );
    });

    test('hook 唤醒（wake）同样打断，且提示按 notice 落库', () async {
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');

      unawaited(
        server.conversation.wake(
          agentId: top.id,
          sessionId: sessionId,
          notice: '[terminal hook] 后台命令已结束',
        ),
      );
      await _untilTrue(() => engine.started.length == 2, reason: '唤醒那轮启动');

      expect(server.conversation.interruptedRunCount, 1);
      final CoreMessage notice = store
          .messages(top.id, sessionId)
          .firstWhere((CoreMessage m) => m.content.contains('terminal hook'));
      expect(notice.kind, 'notice');
    });

    test('打断后紧接着 stop：新消息那轮不会启动（epoch 语义不回归）', () async {
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');
      sendMessage('第二条');
      ws.send(<String, dynamic>{
        'type': WsInboundType.stop,
        'data': <String, dynamic>{'agent_id': top.id, 'session_id': sessionId},
      });
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(server.conversation.isRunning(top.id), isFalse);
      expect(
        engine.started,
        <String>[top.id],
        reason:
            'stop 之后排队的那轮必须被丢弃（droppedQueuedCount=${server.conversation.droppedQueuedCount}）',
      );
    });
  });

  group('打断的能力边界', () {
    test('正在执行的工具跑完才收敛（工具本身不可打断）', () async {
      final CoreModelConfig model = CoreModelConfig(
        modelId: 'demo',
        name: '演示',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        maxSeqlen: 64000,
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'slow', arguments: '{}', withUsage: false),
      ]);
      final _SlowToolRunner tools = _SlowToolRunner(
        delay: const Duration(milliseconds: 150),
      );
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model : null,
        transportFactory: (CoreModelConfig c) => transport,
        toolRunner: tools,
      );
      addTearDown(engine.close);

      bool cancelled = false;
      final Future<void> done = engine
          .run(
            AgentRunContext(
              agentId: 'agt_1',
              sessionId: 'ses_1',
              modelId: 'demo',
              systemPrompt: '系统提示',
              userContent: '跑个慢工具',
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '跑个慢工具'),
              ],
            ),
            isCancelled: () => cancelled,
          )
          .drain<void>();

      await _untilTrue(() => tools.startedAt != null, reason: '工具开始执行');
      cancelled = true; // 工具执行中取消
      await done;

      expect(tools.finishedAt, isNotNull);
      expect(
        DateTime.now().isAfter(tools.finishedAt!),
        isTrue,
        reason: '整轮在工具跑完之后才结束（"立即"的边界就在这一次工具内）',
      );
    });
  });
}
