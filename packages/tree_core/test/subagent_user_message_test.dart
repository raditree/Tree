import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// **用户直接跟临时员工说话 / 停止它**（用户 2026-10-04：「允许用户停止 subagent 的工作、
/// 向其发消息」）。
///
/// 入口复用同一条 `user_message` 帧（收件人是 `sub_…`），核心侧改走
/// [ConversationService.sendToSubagent]：
/// - 消息按 `role='user'` + **它的标记**落库（它自己的历史按标记取；发起者的模型上下文
///   照旧看不到它——否则父的工具批会被切开）；
/// - 它正在跑就**打断**（与主 agent 的插话同一口径），这条消息接着跑；
/// - 跑完把报告注入**发起者会话**（与后台临时员工同一段话术）；
/// - 跨会话 / 未知 id 一律可读错误，不静默落库。
/// 可以中途换掉的引擎：默认是"立刻答完"的占位引擎；需要"跑着别停"的用例（打断 / 停止）
/// 换成 [_SlowEngine]。
class _SwitchableEngine implements AgentEngine {
  AgentEngine delegate = ScriptedAgent(chunkDelay: Duration.zero);

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) => delegate.run(context, isCancelled: isCancelled);

  @override
  Future<void> close() async {}
}

/// 直接报错（模拟"其他错误导致的中止"）。
class _FailingEngine implements AgentEngine {
  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    yield const AgentText('我先试一下');
    yield const AgentError('炸了：工具链挂了');
    yield const AgentDone();
  }

  @override
  Future<void> close() async {}
}

/// 一直转到被取消（模拟"正在跑的一轮"，用来验证打断 / 停止）。
class _SlowEngine implements AgentEngine {
  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    yield const AgentText('开工');
    while (!isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    yield const AgentDone(cancelled: true);
  }

  @override
  Future<void> close() async {}
}

void main() {
  const String sessionId = TreeStore.defaultSessionId;

  late MemoryStore inner;
  late SubagentRegistry registry;
  late SubagentStore store;
  late CoreSettings settings;
  late CoreServer server;
  late SubagentService service;
  late _SwitchableEngine engine;
  late CoreAgent top;
  late TestWs ws;

  setUp(() async {
    inner = MemoryStore();
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    registry = SubagentRegistry(persistence: inner);
    store = SubagentStore(inner: inner, registry: registry);
    server = await CoreServer.start(
      store: store,
      subagents: registry,
      settings: settings,
      engine: engine = _SwitchableEngine(),
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    // 与 CLI 同一套接线：工具落点的 runner 就是会话层那条运行路径
    service = SubagentService(
      store: store,
      registry: registry,
      settings: settings,
    )..runner = server.conversation.runSubagent;
    top = store.createAgent(name: '队长', modelId: 'demo');
    ws = await TestWs.connect(server);
    ws.record();
  });

  tearDown(() async {
    await ws.close();
    await server.close();
  });

  /// 召一个临时员工（走工具那条路，返它的 id）。
  Future<String> summon({String task = '把 a.txt 改成 b', String session = sessionId}) async {
    final ToolOutcome outcome = await SubagentTool.run(
      ToolInvocation(
        id: 'tc-1',
        name: 'subagent',
        arguments: <String, dynamic>{'task': task},
        agentId: top.id,
        sessionId: session,
      ),
      service,
    );
    expect(outcome.isError, isFalse, reason: outcome.content);
    return registry.records(top.id, session).single.id;
  }

  /// 它的标记（名册里的记录 → 帧/消息上那四个字段）。
  SubagentTag tagOfRecord(String subId) {
    final CoreSubagent r = registry.handle(subId)!;
    return SubagentTag(id: r.id, name: r.name, parentId: r.parentId, level: r.level);
  }

  List<CoreMessage> tagged(String subId) => store
      .messages(subId, sessionId)
      .toList(growable: false);

  Future<void> send(String subId, String content, {String? session}) async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': subId,
      'content': content,
      'session_id': session ?? sessionId,
    });
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  test('用户的话落成 role=user 的普通消息 + 它的标记；父的上下文看不到它', () async {
    final String subId = await summon();
    await send(subId, '再做一遍，这次带上日志');

    final List<CoreMessage> history = tagged(subId);
    final CoreMessage said = history.firstWhere(
      (CoreMessage m) => m.role == 'user' && m.content.contains('再做一遍'),
      orElse: () => throw StateError('用户那句话没有被落库：${history.map((CoreMessage m) => "${m.role}:${m.content}").toList()}'),
    );
    expect(said.role, 'user', reason: '用户说的话就是 user，不是 agent 的 task 提示');
    expect(said.kind, isNot(MessageKinds.subagentTask));
    expect(said.subagentId, subId, reason: '必须带它的标记：它自己的历史按标记取');
    // 发起者的模型上下文里看不到它（工具批不能被切开）
    expect(
      store.messages(top.id, sessionId).where((CoreMessage m) => m.content.contains('再做一遍')),
      isEmpty,
    );
  });

  test('那一轮真的跑了（以它的身份），完成后报告注入了发起者会话', () async {
    final String subId = await summon();
    await send(subId, '接着做完');
    // 等报告注入：wake 会写一条带标记的 subagent_report
    DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final bool injected = store
          .messages(top.id, sessionId)
          .any((CoreMessage m) => m.isSubagentReport && m.subagentId == subId);
      if (injected) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final List<CoreMessage> reports = store
        .messages(top.id, sessionId)
        .where((CoreMessage m) => m.isSubagentReport && m.subagentId == subId)
        .toList();
    expect(reports, isNotEmpty, reason: '发起者要知情：报告注入它的会话');
    expect(reports.last.content, contains('接着做完'), reason: '引擎按这一轮的输入作答');
  });

  test('它正在跑时发消息 = 打断那一轮并把它跑起来（与主 agent 插话同一口径）', () async {
    final String subId = await summon();
    // 召完再换"跑着不停"的引擎：这一轮起来后会一直转到被取消
    engine.delegate = _SlowEngine();
    // 没在跑：先手动起一轮（阻塞在会话层的那条运行路径上）
    final Future<SubagentTurnResult> running = server.conversation.runSubagent(
      SubagentTurnRequest(
        tag: tagOfRecord(subId),
        ownerAgentId: top.id,
        sessionId: sessionId,
        task: '长活',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final int interruptedBefore = server.conversation.interruptedRunCount;
    await send(subId, '停一下，先做这个');
    expect(
      server.conversation.interruptedRunCount,
      greaterThan(interruptedBefore),
      reason: '用户说话 = 插话：先打断在途那一轮',
    );
    await running;
  });

  test('用户停止这一轮：**不向发起者注入结束提示**（原因由用户自己说）', () async {
    final String subId = await summon();
    engine.delegate = _SlowEngine();
    final Future<SubagentTurnResult> running = server.conversation.runSubagent(
      SubagentTurnRequest(
        tag: tagOfRecord(subId),
        ownerAgentId: top.id,
        sessionId: sessionId,
        task: '长活',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(server.conversation.isRunning(subId), isTrue);

    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': subId, 'session_id': sessionId},
    });
    final SubagentTurnResult result = await running;
    expect(result.cancelled, isTrue, reason: '这一轮是被人为中止的');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(
      store
          .messages(top.id, sessionId)
          .where((CoreMessage m) => m.isSubagentReport && m.subagentId == subId),
      isEmpty,
      reason: '用户按了停止：父不该收到"我的员工结束了一轮"，用户会自己说原因',
    );
  });

  test('出错导致的中止：**要**向发起者注入提示（否则父以为活还在干）', () async {
    final String subId = await summon();
    engine.delegate = _FailingEngine();
    await send(subId, '做点会炸的事');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final List<CoreMessage> reports = store
        .messages(top.id, sessionId)
        .where((CoreMessage m) => m.isSubagentReport && m.subagentId == subId)
        .toList();
    expect(reports, isNotEmpty, reason: '出错必须让发起者知道');
    expect(reports.last.content, contains('炸了'));
  });

  test('跨会话发消息：可读错误，不落库', () async {
    final String subId = await summon();
    ws.frames.clear();
    await send(subId, '喂', session: 'ses_other');
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
      reason: '跨会话的可读错误',
    );
    final List<Map<String, dynamic>> errors = ws.frames
        .where((Map<String, dynamic> f) => f['type'] == WsOutboundType.error)
        .toList();
    expect(
      errors.last.toString(),
      contains('只活在它被召来的那个会话里'),
    );
    expect(
      tagged(subId).where((CoreMessage m) => m.content == '喂'),
      isEmpty,
      reason: '没发出去就不该落库',
    );
  });

  test('未知 id：可读错误，不落库', () async {
    ws.frames.clear();
    await send('sub_不存在', '喂');
    expect(
      ws.frames
          .where((Map<String, dynamic> f) => f['type'] == WsOutboundType.error)
          .toString(),
      contains('临时员工不存在'),
    );
  });

  test('停止：stop 帧带上它的 id 就停它，且 idle 帧带 subagent_id（前端据此换回发送键）', () async {
    final String subId = await summon();
    engine.delegate = _SlowEngine();
    final Future<SubagentTurnResult> running = server.conversation.runSubagent(
      SubagentTurnRequest(
        tag: tagOfRecord(subId),
        ownerAgentId: top.id,
        sessionId: sessionId,
        task: '长活',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(server.conversation.isRunning(subId), isTrue);

    ws.frames.clear();
    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': subId, 'session_id': sessionId},
    });
    await running;
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(server.conversation.isRunning(subId), isFalse, reason: '它这一轮被停了');
    expect(
      server.conversation.isRunning(top.id),
      isFalse,
      reason: '停临时员工**不该**连带停发起者（父那轮照常收尾）',
    );
    expect(
      ws.frames.any(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.agentStatus &&
            (f['data'] as Map<String, dynamic>?)?['subagent_id'] == subId &&
            (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
      ),
      isTrue,
      reason: '临时员工的 idle 必须带它自己的标记（父还在跑时也要报）',
    );
  });
}
