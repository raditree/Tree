import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 可控引擎：开始后一直转，直到被取消（用于验证 stop / 级联停止）。
class _GatedEngine implements AgentEngine {
  final List<String> started = <String>[];

  /// **收敛闸门**：被取消后先停在这里，由测试放行才结束这一轮；null = 不拦。
  ///
  /// 用来消掉一个调度竞态（实测：`第二条` 与 `stop` 两帧间隔 0ms 时"排队那条不
  /// 启动"，间隔 30ms 时它就启动了）："排队那条算不算被 stop 作废"取决于"这一轮
  /// 结束"与"stop 帧被处理"谁先发生，中间只隔一个 5ms 轮询，并行满负载会翻。
  Completer<void>? convergeGate;

  /// 这一轮已到达闸门（测试据此确知"它收敛了，但还没结束"）。
  final Completer<void> atGate = Completer<void>();

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    started.add(context.agentId);
    yield const AgentText('开始');
    while (!isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final Completer<void>? gate = convergeGate;
    if (gate != null) {
      if (!atGate.isCompleted) atGate.complete();
      await gate.future;
    }
    yield const AgentDone(cancelled: true);
  }

  @override
  Future<void> close() async {}
}

/// 级联停止（M5c）：TOP 停整棵树、成员只停自己、排队任务被丢弃。
void main() {
  late CoreServer server;
  late MemoryStore store;
  late TeamService teams;
  late _GatedEngine engine;
  late CoreAgent top;
  late CoreAgent member;
  late TestWs ws;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() async {
    store = MemoryStore();
    final CoreSettings settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    teams = TeamService(store: store, settings: settings);
    engine = _GatedEngine();
    server = await CoreServer.start(
      store: store,
      settings: settings,
      teamService: teams,
      engine: engine,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    top = store.createAgent(name: '队长', modelId: 'demo');
    final String memberId =
        teams.createMember(top.id, <String, dynamic>{
              'action': 'create_member',
              'member_name': '成员甲',
            })['member_id']
            as String;
    teams.assignModel(
      topId: top.id,
      memberId: memberId,
      body: <String, dynamic>{'model_id': 'demo', 'review_status': 'approved'},
    );
    member = store.agent(memberId)!;
    ws = await TestWs.connect(server);
    ws.record();
  });

  tearDown(() async {
    await ws.close();
    await server.close();
  });

  Future<void> startTopRun() async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': top.id,
      'content': '干活',
      'session_id': sessionId,
    });
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'working',
      reason: 'working',
    );
  }

  test('stop(TOP)：自己停止、成员补 idle、返回 stopping', () async {
    await startTopRun();
    expect(server.conversation.isRunning(top.id), isTrue);
    expect(server.conversation.isRunning(member.id), isFalse);

    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': top.id, 'session_id': sessionId},
    });
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'stopping',
      reason: 'stopping',
    );
    // 没有在途任务的成员也收到 idle（否则成员窗口一直显示"工作中"）
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>?)?['agent_id'] == member.id &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
      reason: '成员 idle',
    );
    // 必须等 **TOP 自己**回到 idle：waitIdle() 会先匹配到成员补发的 idle 而立即返回，
    // 于是断言时 TOP 可能仍在收尾（isRunning 还是 true）——那是竞态不是真实行为。
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>?)?['agent_id'] == top.id &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
      reason: 'TOP idle',
    );
    expect(server.conversation.isRunning(top.id), isFalse);
  });

  test('stop(成员)：只停自己，不影响 TOP', () async {
    await startTopRun();
    unawaited(
      server.conversation.deliver(
        agentId: member.id,
        sessionId: sessionId,
        content: '做点事',
        senderId: top.id,
        senderName: '队长',
      ),
    );
    // 成员会话里收到带 [来自] 前缀的消息（模型据此知道该向谁回发）
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final CoreMessage incoming = store
        .messages(member.id, sessionId)
        .lastWhere((CoreMessage m) => m.role == 'user');
    expect(incoming.content, startsWith('[来自 队长] 做点事'));

    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': member.id, 'session_id': sessionId},
    });
    // 等成员**真的**回到 idle，而不是睡 80ms：并行满负载下"睡够了"是假前提。
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>?)?['agent_id'] == member.id &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
      reason: '成员 idle',
    );
    expect(server.conversation.isRunning(member.id), isFalse);
    expect(
      server.conversation.isRunning(top.id),
      isTrue,
      reason: '成员 stop 不得连带停掉 TOP',
    );
    // 收尾：停掉 TOP，避免 tearDown 时还有在途任务
    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': top.id, 'session_id': sessionId},
    });
    await waitIdle(ws);
  });

  test('stop：排队任务被丢弃（不会在停止后再拉起来）', () async {
    final Completer<void> gate = Completer<void>();
    engine.convergeGate = gate; // TOP 这一轮收敛后停在闸门，等测试放行
    await startTopRun();
    // 第二条消息在 working 期间排队（它同时打断 TOP 在途那一轮 ⇒ 那一轮收敛到闸门）
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': top.id,
      'content': '第二条',
      'session_id': sessionId,
    });
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
      reason: 'stopping',
    );

    gate.complete(); // 放行 TOP 那一轮 ⇒ 排队那条按旧代次被丢弃
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>?)?['agent_id'] == top.id &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
      reason: 'TOP idle',
    );
    expect(server.conversation.droppedQueuedCount, 1);
    expect(server.conversation.isRunning(top.id), isFalse);
    expect(
      engine.started,
      <String>[top.id],
      reason: '排队的那条不应再启动一轮（这里是确定的先后，不是调度竞态）',
    );
  });

  test('stop：没有在途任务且无成员时回错误帧（不静默）', () async {
    // 有成员的 TOP 即便没有在途任务也算"停成功"（成员收到 idle），
    // 因此这里用一个没有任何成员的 TOP 来验证错误分支。
    final CoreAgent solo = store.createAgent(name: '空队');
    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': solo.id},
    });
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
      reason: 'error 帧',
    );
    final Map<String, dynamic> frame = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
    );
    expect((frame['data'] as Map<String, dynamic>)['message'], '没有进行中的任务可停止');
  });
}
