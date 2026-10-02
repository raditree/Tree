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

  /// **收敛闸门**：被取消后先停在这里，由测试放行才结束这一轮；null = 不拦。
  ///
  /// 用来消掉一个调度竞态（实测：两帧间隔 0ms 时"排队那条不启动"，间隔 30ms 时
  /// 它就启动了）：`第二条` 会打断在途那一轮，而"排队那条到底算不算被 stop 作废"
  /// 取决于"这一轮结束"与"stop 帧被处理"谁先发生——两者之间只隔一个 5ms 轮询，
  /// 并行满负载时会翻。让这一轮在闸门处停住，测试就能先确认 stop 已被处理
  /// （见 `stopping` 帧），再放行；断言于是与调度无关。
  Completer<void>? convergeGate;

  /// 这一轮已到达闸门（测试据此确知"它收敛了，但还没结束"）。
  final Completer<void> atGate = Completer<void>();

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
    final Completer<void>? gate = convergeGate;
    if (gate != null) {
      if (!atGate.isCompleted) atGate.complete();
      await gate.future;
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
  // 并行满负载（16 路用例 + 起子进程）时 5s 是睡出来的假期限，实测会假失败；
  // 这是轮询，条件一满足就返回，放宽不花时间。
  Duration timeout = const Duration(seconds: 20),
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

    test('跨会话的新消息不打断在途那一轮：两个会话**并行**跑（不排队）', () async {
      const String other = 'ses_other';
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');

      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': top.id,
        'content': '另一个会话的消息',
        'session_id': other,
      });
      await _untilTrue(
        () => engine.started.length == 2,
        reason: '另一会话那一轮并行启动（既不等前一轮、也不打断它）',
      );

      expect(server.conversation.interruptedRunCount, 0, reason: '跨会话不算打断');
      expect(server.conversation.activeRunCount, 2, reason: '两个会话同时在跑');
      expect(engine.contexts[1].sessionId, other);
      expect(
        engine.cancelledAtEnd,
        isEmpty,
        reason: '谁也没被取消：跨会话打断只会让那个会话的答复凭空消失',
      );
      expect(server.conversation.isRunning(top.id), isTrue);
    });

    test('stop 是 agent 级的：并行在跑的每个会话都被停掉', () async {
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');
      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': top.id,
        'content': '另一个会话的消息',
        'session_id': 'ses_other',
      });
      await _untilTrue(() => engine.started.length == 2, reason: '并行启动');
      expect(server.conversation.activeRunCount, 2);

      ws.send(<String, dynamic>{
        'type': WsInboundType.stop,
        'data': <String, dynamic>{'agent_id': top.id, 'session_id': sessionId},
      });
      await _untilTrue(
        () => !server.conversation.isRunning(top.id),
        reason: '两个会话都收敛',
      );
      expect(server.conversation.activeRunCount, 0);
      expect(engine.cancelledAtEnd, hasLength(2));
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
      final Completer<void> gate = Completer<void>();
      engine.convergeGate = gate; // 第一轮收敛后停在闸门，等测试放行
      sendMessage('第一条');
      await _untilTrue(() => engine.started.length == 1, reason: '第一轮启动');

      // 第二条 = 插话：第一轮的取消标记立刻置上。它随后停在闸门处，
      // 所以"第二条此刻还在队列里"是确定的，不靠 5ms 轮询的先后。
      sendMessage('第二条');
      await engine.atGate.future;

      ws.send(<String, dynamic>{
        'type': WsInboundType.stop,
        'data': <String, dynamic>{'agent_id': top.id, 'session_id': sessionId},
      });
      // `stopping` 由核心在 `_stopAgentTree`（⇒ `cancelAgent` ⇒ 代次前进）**之后**
      // 才发出：收到它就证明"排队任务已作废"生效了，与放行闸门的先后无关。
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.agentStatus &&
            (f['data'] as Map<String, dynamic>?)?['status'] == 'stopping',
        reason: 'stopping 帧',
      );

      gate.complete(); // 放行第一轮 ⇒ 排队那条按旧代次被丢弃
      await _untilTrue(
        () => server.conversation.droppedQueuedCount == 1,
        reason: '排队任务被丢弃',
      );
      await _untilTrue(
        () => !server.conversation.isRunning(top.id),
        reason: '收敛完成',
      );
      expect(server.conversation.isRunning(top.id), isFalse);
      expect(
        engine.started,
        <String>[top.id],
        reason:
            'stop 之后排队的那轮必须被丢弃（这里是确定的先后，不是调度竞态）：'
            'droppedQueuedCount=${server.conversation.droppedQueuedCount}',
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
      // 用 `!isBefore` 而不是 `isAfter`：DateTime 只有毫秒精度，工具收尾与返回落在
      // 同一毫秒时 isAfter 会误判（全量并行跑时实测偶发）。这仍然抓得住真 bug——
      // "整轮提前结束"时 now 会早于 finishedAt（若工具还没收尾，上面那条 isNotNull 先失败）。
      expect(
        DateTime.now().isBefore(tools.finishedAt!),
        isFalse,
        reason: '整轮在工具跑完之后才结束（"立即"的边界就在这一次工具内）',
      );
    });
  });
}
