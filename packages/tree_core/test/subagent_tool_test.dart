import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 可控假引擎：**不调任何 LLM**，事件脚本 + 完成时机全在测试手里。
///
/// [hold] = true 时每次 run 在产出正文后**卡在闸门上**，直到 [release]（用它证明
/// 多个后台临时员工是**真的并行**：第一个没结束第二个就已经开始）。
class _FakeEngine implements AgentEngine {
  /// 每次 run 的上下文（断言"子 agent 只看到自己的历史"）。
  final List<AgentRunContext> contexts = <AgentRunContext>[];

  /// 每次 run 的 agentId（按开始顺序）。
  final List<String> started = <String>[];

  bool hold = false;

  /// 只对这些 agentID 卡闸门（其余照常跑完）：验证"父在途 + 子不卡"这类交叉场景。
  final Set<String> holdFor = <String>{};

  /// 只产出思考/工具、不产出正文（验证"没有最终报告"的可读文案）。
  bool emptyReply = false;

  /// 每次 run 直接抛错（验证失败路径也收干净运行态）。
  bool throwOnRun = false;

  int active = 0;
  int maxActive = 0;
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    contexts.add(context);
    started.add(context.agentId);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (throwOnRun) throw StateError('假引擎故意抛错');
      final String body = emptyReply ? '' : '报告：${context.userContent}';
      if (body.isNotEmpty) yield AgentText(body);
      if (hold || holdFor.contains(context.agentId)) {
        final Completer<void> gate = Completer<void>();
        _gates[context.agentId] = gate;
        await gate.future;
      }
      yield const AgentDone();
    } finally {
      active--;
      _gates.remove(context.agentId);
    }
  }

  void release(String agentId) {
    final Completer<void>? gate = _gates[agentId];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseAll() {
    for (final Completer<void> gate in _gates.values.toList()) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<void> close() async {}
}

/// 记账用广播槽（断言消息帧上的 subagent 标记）。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  @override
  void broadcast(Map<String, dynamic> frame) => frames.add(frame);
}

/// `subagent` 工具的形状、校验、复用、层级、并行后台与清理。
void main() {
  late MemoryStore inner;
  late SubagentRegistry registry;
  late SubagentStore store;
  late CoreSettings settings;
  late _RecordingHub hub;
  late _FakeEngine engine;
  late ConversationService conversation;
  late SubagentService service;
  late CoreAgent owner;

  setUp(() {
    inner = MemoryStore();
    registry = SubagentRegistry(persistence: inner);
    store = SubagentStore(inner: inner, registry: registry);
    settings = CoreSettings();
    settings.putModel(CoreModelConfig(modelId: 'demo', name: 'demo'));
    hub = _RecordingHub();
    engine = _FakeEngine();
    conversation = ConversationService(
      store: store,
      hub: hub,
      settings: settings,
      subagents: registry,
      engine: engine,
      pacingEnabled: false,
    );
    service = SubagentService(
      store: store,
      registry: registry,
      settings: settings,
    );
    service.runner = conversation.runSubagent;
    owner = store.createAgent(name: 'leader', modelId: 'demo');
  });

  tearDown(() async {
    engine.releaseAll();
    conversation.dispose();
  });

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
    String description = '条件',
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待「$description」超时');
  }

  Future<ToolOutcome> callTool(
    Map<String, dynamic> arguments, {
    String? agentId,
    String sessionId = TreeStore.defaultSessionId,
  }) => BuiltinTools.run(
    ToolInvocation(
      id: 'tc',
      name: 'subagent',
      arguments: arguments,
      agentId: agentId ?? owner.id,
      sessionId: sessionId,
    ),
    null,
    subagentChannel: service,
    withSubagent: true,
  );

  List<CoreSubagent> roster({String? sessionId}) =>
      registry.records(owner.id, sessionId ?? TreeStore.defaultSessionId);

  test('工具形状：名字/必填/参数与"接上才声明"', () {
    final ToolSpec spec = SubagentTool.spec();
    expect(spec.name, 'subagent');
    expect(spec.parameters['required'], <String>['task']);
    final Map<String, dynamic> properties =
        (spec.parameters['properties'] as Map<String, dynamic>);
    expect(properties.keys, containsAll(<String>['task', 'name', 'subagent_id', 'background']));
    expect(
      (properties['background'] as Map<String, dynamic>)['type'],
      'boolean',
    );
    // 声明即能力：没接服务就不声明（模型不会去调一个不存在的工具）
    expect(
      BuiltinTools.specs(withSubagent: true).map((ToolSpec s) => s.name),
      contains('subagent'),
    );
    expect(
      BuiltinTools.specs(withSubagent: false).map((ToolSpec s) => s.name),
      isNot(contains('subagent')),
    );
    // 工具本身不读文件：工作空间不可用不该连带它失败（工作空间由子 agent 自己解析）
    expect(BuiltinTools.needsWorkspace('subagent'), isFalse);
    // 描述里必须写清两条用户口径（复用判据 + 再派发边界）
    expect(spec.description, contains('职责/范围一致'));
    expect(spec.description, contains('层级上限'));
    expect(spec.description, contains('共享同一个工作空间'));
  });

  test('使用策略写在三处提示词资产里（工具描述 / 系统提示词 / 内置 Spec），口径一致', () {
    // ① 工具描述：模型决定"要不要调"时看到的那段
    final String tool = SubagentTool.spec().description;
    expect(tool, contains('什么时候用'));
    expect(tool, contains('什么时候不用'));
    expect(tool, contains('职责/范围一致'));
    expect(tool, contains('共享同一个工作空间'));
    expect(tool, contains('请用 team'));

    // ② 系统提示词种子：动手之前就该知道"什么时候派活、边界在哪"
    expect(defaultSystemPromptSeed, contains('## 临时员工（subagent）使用策略'));
    expect(defaultSystemPromptSeed, contains('task 必须自包含'));
    expect(defaultSystemPromptSeed, contains('subagent_id'));
    expect(defaultSystemPromptSeed, contains('共享同一个工作空间'));

    // ③ 内置 Spec：挂规范干活时的分工口径（三份都要写明临时员工的位置与禁令）
    for (final String id in <String>['general-task', 'hard-task', 'team-meeting']) {
      expect(
        kBuiltinSpecTexts[id],
        contains('subagent'),
        reason: '$id 要写清临时员工的使用边界（挂上规范后不许把它当成员用）',
      );
    }
    expect(kBuiltinSpecTexts['general-task'], contains('不算"分工"'));
    expect(kBuiltinSpecTexts['hard-task'], contains('成员 vs 临时员工'));
    expect(kBuiltinSpecTexts['team-meeting'], contains('不许召临时员工去干活'));
  });

  test('缺 task / 空 task：可读错误（明说它看不到你的会话历史）', () async {
    final ToolOutcome missing = await callTool(<String, dynamic>{});
    expect(missing.isError, isTrue);
    expect(missing.content, contains('缺少 task'));
    expect(missing.content, contains('会话历史'));

    final ToolOutcome empty = await callTool(<String, dynamic>{'task': '   '});
    expect(empty.isError, isTrue);
    expect(empty.content, contains('task 不能为空'));
    expect(roster(), isEmpty, reason: '校验失败不该建任何实体');
  });

  test('background=false：把最终报告作为工具结果返回，并回传 id', () async {
    final ToolOutcome outcome = await callTool(<String, dynamic>{
      'task': '整理 docs/ 下的接口文档',
      'name': '文档员',
    });
    expect(outcome.isError, isFalse, reason: outcome.content);
    expect(outcome.content, contains('报告：整理 docs/ 下的接口文档'));
    final CoreSubagent record = roster().single;
    expect(record.name, '文档员');
    expect(record.level, 1);
    expect(record.parentId, owner.id);
    expect(outcome.content, contains(record.id), reason: '结果必须回传 id 供复用');
    // 它自己那一轮跑完后：运行态收干净、名册里留着（随会话持久化，可复用）
    expect(conversation.activeRunCount, 0);
    expect(roster(), hasLength(1));
    // 消息归集到父会话并带标记；父 agent 自己的 messages() 不含它
    expect(store.messages(owner.id, TreeStore.defaultSessionId), isEmpty);
    final List<CoreMessage> all = store.sessionMessages(
      owner.id,
      TreeStore.defaultSessionId,
    );
    expect(all, isNotEmpty);
    expect(all.every((CoreMessage m) => m.subagentId == record.id), isTrue);
    expect(
      all.first.kind,
      MessageKinds.subagentTask,
      reason: 'task 是它自己的输入（引擎按 user 翻译）',
    );
    expect(all.first.content, '整理 docs/ 下的接口文档');
    // 消息帧也带标记（前端据此分组）
    final Map<String, dynamic> frame = hub.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == 'message',
      orElse: () => <String, dynamic>{},
    );
    if (frame.isNotEmpty) {
      expect(frame['subagent_id'], record.id);
      expect(frame['agent_id'], owner.id, reason: '不冒充父 agent，但归在它的会话里');
    }
  });

  test('复用：同一个 id 续活（历史延续、不新建实体）；按 id 与名称都能命中', () async {
    final ToolOutcome first = await callTool(<String, dynamic>{
      'task': '第一步：读 a.txt',
      'name': '甲',
    });
    expect(first.isError, isFalse, reason: first.content);
    final CoreSubagent record = roster().single;
    final int contextsAfterFirst = engine.contexts.length;

    final ToolOutcome second = await callTool(<String, dynamic>{
      'task': '第二步：改 a.txt',
      'subagent_id': record.id,
    });
    expect(second.isError, isFalse, reason: second.content);
    expect(second.content, contains('复用'));
    expect(roster(), hasLength(1), reason: '复用不许新建实体');
    expect(roster().single.id, record.id);
    expect(registry.handle(record.id)?.runCount, 2);

    // 复用那一轮拿到的历史 = 它自己的历史（第一轮任务 + 第一轮产出 + 第二轮任务）
    final AgentRunContext reused = engine.contexts[contextsAfterFirst];
    final List<String> history = reused.history
        .map((CoreMessageRef r) => r.content)
        .toList(growable: false);
    expect(history, contains('第一步：读 a.txt'));
    expect(history.any((String c) => c.contains('报告：第一步')), isTrue);
    expect(history.last, '第二步：改 a.txt', reason: '本次 task 是它的最后一条输入');
    expect(
      history.any((String c) => c.contains('leader')),
      isFalse,
      reason: '它看不到父会话（父会话里没有的它也没有）',
    );

    // 按名称复用（同会话唯一）
    final ToolOutcome byName = await callTool(<String, dynamic>{
      'task': '第三步：再改一次',
      'subagent_id': '甲',
    });
    expect(byName.isError, isFalse, reason: byName.content);
    expect(roster(), hasLength(1));
    expect(registry.handle(record.id)?.runCount, 3);
  });

  test('复用：找不到目标 / 同名歧义 / 另一个会话的 id 都给可读错误', () async {
    final ToolOutcome missing = await callTool(<String, dynamic>{
      'task': 'x',
      'subagent_id': 'sub_nope_1',
    });
    expect(missing.isError, isTrue);
    expect(missing.content, contains('找不到要复用的临时员工'));
    expect(missing.content, contains('本会话还没有临时员工'));

    await callTool(<String, dynamic>{'task': '甲的事', 'name': '同名'});
    await callTool(<String, dynamic>{'task': '乙的事', 'name': '同名'});
    final ToolOutcome ambiguous = await callTool(<String, dynamic>{
      'task': 'x',
      'subagent_id': '同名',
    });
    expect(ambiguous.isError, isTrue);
    expect(ambiguous.content, contains('多个临时员工叫'));
    expect(roster(), hasLength(2), reason: '歧义不该新建实体');

    // 另一个会话的 id：不许静默新建、不许错命中
    final CoreSession other = store.createSession(owner.id, title: '另一个会话')!;
    final ToolOutcome crossSession = await callTool(
      <String, dynamic>{'task': 'x', 'subagent_id': roster().first.id},
      sessionId: other.sessionId,
    );
    expect(crossSession.isError, isTrue);
    expect(crossSession.content, contains('另一个会话'));
    expect(roster(sessionId: other.sessionId), isEmpty);
  });

  test('层级：临时员工可以再召一个（层级 +1），超上限给可读错误', () async {
    final ToolOutcome l1 = await callTool(<String, dynamic>{'task': '第一层'});
    expect(l1.isError, isFalse, reason: l1.content);
    final CoreSubagent first = roster().single;
    expect(first.level, 1);

    // 模拟"它自己再召一个"：工具调用者 = 这个临时员工
    final ToolOutcome l2 = await callTool(
      <String, dynamic>{'task': '第二层'},
      agentId: first.id,
    );
    expect(l2.isError, isFalse, reason: l2.content);
    expect(roster(), hasLength(2));
    final CoreSubagent second = roster()
        .firstWhere((CoreSubagent s) => s.level == 2);
    expect(second.parentId, first.id);
    expect(second.ownerAgentId, owner.id, reason: '整棵树归同一个会话主人');

    final ToolOutcome l3 = await callTool(
      <String, dynamic>{'task': '第三层'},
      agentId: second.id,
    );
    expect(l3.isError, isFalse, reason: l3.content);
    final CoreSubagent third = roster()
        .firstWhere((CoreSubagent s) => s.level == SubagentLimits.maxDepth);

    final ToolOutcome tooDeep = await callTool(
      <String, dynamic>{'task': '第四层'},
      agentId: third.id,
    );
    expect(tooDeep.isError, isTrue, reason: '超限必须显式报错，不静默截断');
    expect(tooDeep.content, contains('层级上限'));
    expect(tooDeep.content, contains('套娃'));
    expect(roster(), hasLength(SubagentLimits.maxDepth));

    // 超限时**复用**仍可用（复用不加深层级）
    final ToolOutcome reuseDeep = await callTool(
      <String, dynamic>{'task': '第四层改用复用', 'subagent_id': third.id},
      agentId: third.id,
    );
    expect(reuseDeep.isError, isFalse, reason: reuseDeep.content);
  });

  test('并行后台：同一轮连开 3 个，三个真的同时跑；三份结果各注入一次且不串', () async {
    final List<({SubagentTag tag, String notice})> notices =
        <({SubagentTag tag, String notice})>[];
    service.onFinished = (
      String ownerAgentId,
      String sessionId,
      String notice,
      SubagentTag tag,
    ) {
      notices.add((tag: tag, notice: notice));
    };
    engine.hold = true;

    final List<Future<ToolOutcome>> calls = <Future<ToolOutcome>>[
      for (int i = 0; i < 3; i++)
        callTool(<String, dynamic>{
          'task': '并行任务-$i',
          'name': '并发$i',
          'background': true,
        }),
    ];
    final List<ToolOutcome> handles = await Future.wait(calls);
    for (final ToolOutcome handle in handles) {
      expect(handle.isError, isFalse, reason: handle.content);
      expect(handle.content, contains('后台'));
    }
    // 三个都真的跑起来了（第一个没结束第二个就已经开始）
    await waitUntil(() => engine.started.length == 3, description: '三个后台都开跑');
    expect(engine.started.toSet(), hasLength(3), reason: '每个临时员工一个独立运行标识');
    expect(engine.maxActive, 3, reason: '不许做成"同一会话只允许一个后台子任务"');
    expect(conversation.activeRunCount, 3);
    expect(roster(), hasLength(3), reason: '名册要容纳多个并发条目（按 id）');

    // 先放一个：它自己的运行态收干净，其余继续跑（逐个收，不误伤）
    final String firstId = engine.started.first;
    engine.release(firstId);
    await waitUntil(() => notices.length == 1, description: '第一个完成注入');
    expect(conversation.activeRunCount, 2);
    expect(roster(), hasLength(3), reason: '跑完一个只收运行态，名册条目留着（可复用）');
    expect(notices.single.tag.id, firstId);
    // 通知与它自己的任务对得上（内容不串）
    expect(notices.single.notice, contains(notices.single.tag.name));

    engine.releaseAll();
    await waitUntil(() => notices.length == 3, description: '三份结果都注入');
    expect(
      notices.map((n) => n.notice).toSet(),
      hasLength(3),
      reason: '三份结果不串、不覆盖',
    );
    expect(
      notices.map((n) => n.tag.id).toSet(),
      hasLength(3),
      reason: '每个都带自己的标记',
    );
    expect(
      notices.map((n) => n.tag.id).toSet(),
      engine.started.toSet(),
    );
    for (int i = 0; i < 3; i++) {
      expect(
        notices.any((n) => n.notice.contains('并行任务-$i')),
        isTrue,
        reason: '第 $i 份必须到达',
      );
    }
    await waitUntil(() => conversation.activeRunCount == 0, description: '运行态收干净');
  });

  test('后台结果经 wake 注入父会话：三个都到、各带标记（不丢不覆盖）', () async {
    // 复刻 CLI 的接线：onFinished → tools.onHookFinished → conversation.wake
    service.onFinished = (
      String ownerAgentId,
      String sessionId,
      String notice,
      SubagentTag tag,
    ) {
      unawaited(
        conversation.wake(
          agentId: ownerAgentId,
          sessionId: sessionId,
          notice: notice,
          subagent: tag,
        ),
      );
    };
    for (int i = 0; i < 3; i++) {
      final ToolOutcome handle = await callTool(<String, dynamic>{
        'task': '后台任务-$i',
        'background': true,
      });
      expect(handle.isError, isFalse, reason: handle.content);
    }
    expect(roster(), hasLength(3));
    await waitUntil(
      () => store
              .sessionMessages(owner.id, TreeStore.defaultSessionId)
              .where(
                (CoreMessage m) =>
                    m.kind == MessageKinds.subagentReport &&
                    m.subagentId.isNotEmpty,
              )
              .length >=
          3,
      description: '三份完成报告都注入父会话',
    );
    final List<CoreMessage> reports = store
        .sessionMessages(owner.id, TreeStore.defaultSessionId)
        .where((CoreMessage m) => m.kind == MessageKinds.subagentReport)
        .toList(growable: false);
    expect(reports, hasLength(3), reason: '三份报告都必须到达（不许被后一个盖掉）');
    expect(reports.map((CoreMessage m) => m.subagentId).toSet(), hasLength(3));
    for (int i = 0; i < 3; i++) {
      expect(
        reports.where((CoreMessage m) => m.content.contains('后台任务-$i')),
        hasLength(1),
        reason: '第 $i 份报告必须唯一对应第 $i 个任务（内容不串）',
      );
    }
    // 父 agent 的模型上下文：**只有**完成报告这一种带标记的消息（它是"新的输入"）；
    // 临时员工的任务与它自己说的话都不进父上下文（工具批必须保持原子）
    final List<CoreMessage> ownerContext = store.messages(
      owner.id,
      TreeStore.defaultSessionId,
    );
    expect(
      ownerContext.every(
        (CoreMessage m) => !m.isSubagentMessage || m.isSubagentReport,
      ),
      isTrue,
    );
    expect(
      ownerContext.where((CoreMessage m) => m.kind == MessageKinds.subagentTask),
      isEmpty,
      reason: '任务已经写在发起者的 subagent 调用参数里，不该再当一条输入灌回去',
    );
    expect(ownerContext.where((CoreMessage m) => m.isSubagentReport), hasLength(3));
  });

  test('阻塞式子任务与并行后台共存；父 agent 在途轮次不与之撞键（不死锁）', () async {
    // 父那一轮先占住 (owner, session)（阻塞等待中），再召一个阻塞临时员工：
    // 两者的运行标识不同，必须都能跑完（撞了就是死锁）
    engine.holdFor.add(owner.id);
    final Future<void> parentTurn = conversation.handleUserMessage(
      <String, dynamic>{
        'agent_id': owner.id,
        'session_id': TreeStore.defaultSessionId,
        'content': '父 agent 自己在跑',
      },
    );
    await waitUntil(() => engine.started.contains(owner.id), description: '父那一轮已开始');

    final ToolOutcome blocking = await callTool(<String, dynamic>{
      'task': '阻塞子任务',
    }).timeout(const Duration(seconds: 10));
    expect(blocking.isError, isFalse, reason: blocking.content);
    expect(blocking.content, contains('报告：阻塞子任务'));

    engine.releaseAll();
    await parentTurn.timeout(const Duration(seconds: 10));
    expect(conversation.activeRunCount, 0);
  });

  test('工具表：临时员工没有 team / message，但**有** subagent（可套娃）', () async {
    final Directory ws = Directory.systemTemp.createTempSync('tree_subagent_ws_');
    addTearDown(() {
      try {
        ws.deleteSync(recursive: true);
      } catch (_) {}
    });
    final TeamService teams = TeamService(store: store, settings: settings);
    final TeamMessageDispatcher messages = TeamMessageDispatcher(
      store: store,
      teams: teams,
      deliver:
          ({
            required String agentId,
            required String sessionId,
            required String content,
            String senderId = '',
            String senderName = '',
          }) async {},
    );
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String agentId) => ws.path,
      teamService: teams,
      messageDispatcher: messages,
      subagentService: service,
      askQuestion: (AskQuestionRequest request) async =>
          const QuestionOutcome(answer: ''),
    );
    addTearDown(runner.close);

    final List<String> parentTools = runner
        .specsFor(agentId: owner.id, sessionId: TreeStore.defaultSessionId)
        .map((ToolSpec s) => s.name)
        .toList(growable: false);
    // 声明即能力：没接 subagentService 的执行器**不声明** subagent
    final WorkspaceToolRunner noSubagent = WorkspaceToolRunner(
      resolveWorkspaceDir: (String agentId) => ws.path,
    );
    addTearDown(noSubagent.close);
    expect(
      noSubagent
          .specsFor(agentId: owner.id, sessionId: TreeStore.defaultSessionId)
          .map((ToolSpec s) => s.name),
      isNot(contains('subagent')),
    );
    expect(
      parentTools,
      containsAll(<String>[
        'team',
        'message',
        'subagent',
        'read',
        'write',
        'edit',
        'grep',
        'terminal',
        'ask_user_question',
      ]),
    );

    await callTool(<String, dynamic>{'task': '干活'});
    final String subId = roster().single.id;
    final List<String> subTools = runner
        .specsFor(agentId: subId, sessionId: TreeStore.defaultSessionId)
        .map((ToolSpec s) => s.name)
        .toList(growable: false);
    expect(
      subTools,
      contains('subagent'),
      reason: '它可以再召临时员工（只用于把同一个大任务拆细）',
    );
    expect(subTools, isNot(contains('team')), reason: '临时员工不能建队/管队');
    expect(subTools, isNot(contains('message')), reason: '临时员工不能被派活/派活');
    expect(
      subTools,
      containsAll(<String>['read', 'write', 'edit', 'grep', 'terminal']),
      reason: '其余内置工具照旧继承父',
    );

    // 权限兜底（工具表之外的第二道）：以临时员工身份调 team / message 给可读错误
    for (final String tool in <String>['team', 'message']) {
      final ToolOutcome denied = await runner.run(
        ToolInvocation(
          id: 'x',
          name: tool,
          arguments: <String, dynamic>{'action': 'list_teams'},
          agentId: subId,
          sessionId: TreeStore.defaultSessionId,
        ),
      );
      expect(denied.isError, isTrue);
      expect(denied.content, contains('临时员工不能使用'));
    }

    // 工作空间口径：私有分栏 + IO 都归到会话主人（工作空间里不会留下 sub_* 目录）
    expect(service.privateOwnerOf(subId), owner.id);
    final WorkspaceIO? ownerIo = await runner.ioFor(owner.id);
    final WorkspaceIO? subIo = await runner.ioFor(subId);
    expect(ownerIo, isNotNull);
    expect(
      identical(subIo, ownerIo),
      isTrue,
      reason: '临时员工复用发起者那条工作空间 IO（同一根、同一条 SSH 连接）',
    );
  });

  test('可读失败：没有模型 / 模型不在池里 / 工作空间不可用 / 未知 agent', () async {
    final CoreAgent noModel = store.createAgent(name: '没模型');
    final ToolOutcome missingModel = await callTool(
      <String, dynamic>{'task': 'x'},
      agentId: noModel.id,
    );
    expect(missingModel.isError, isTrue);
    expect(missingModel.content, contains('没有可用模型'));
    expect(missingModel.content, contains('设置 → 自定义模型'), reason: '要说清去哪配');

    final CoreAgent badModel = store.createAgent(name: '坏模型', modelId: 'nope');
    final ToolOutcome unknownModel = await callTool(
      <String, dynamic>{'task': 'x'},
      agentId: badModel.id,
    );
    expect(unknownModel.isError, isTrue);
    expect(unknownModel.content, contains('不在模型池里'));

    service.probeWorkspace = (String agentId) async => '工作空间不可用：没有工作目录';
    final ToolOutcome noWorkspace = await callTool(<String, dynamic>{'task': 'x'});
    expect(noWorkspace.isError, isTrue);
    expect(noWorkspace.content, contains('工作空间不可用'));
    service.probeWorkspace = null;

    final ToolOutcome ghost = await callTool(
      <String, dynamic>{'task': 'x'},
      agentId: 'agt_missing',
    );
    expect(ghost.isError, isTrue);
    expect(ghost.content, contains('未知 agent'));

    final ToolOutcome noSession = await callTool(
      <String, dynamic>{'task': 'x'},
      sessionId: '',
    );
    expect(noSession.isError, isTrue);
    expect(noSession.content, contains('缺少会话上下文'));
    expect(roster(), isEmpty);
  });

  group('停止临时员工：只停它自己（用户 2026-10-03）', () {
    test('传 sub_… 只取消它自己那一轮：兄弟照跑，且不向发起者注入结束提示', () async {
      // 复刻 CLI 接线：后台完成 ⇒ 报告注入父会话（onFinished → wake）
      service.onFinished = (
        String ownerAgentId,
        String sessionId,
        String notice,
        SubagentTag tag,
      ) {
        unawaited(
          conversation.wake(
            agentId: ownerAgentId,
            sessionId: sessionId,
            notice: notice,
            subagent: tag,
          ),
        );
      };
      engine.hold = true;
      await callTool(<String, dynamic>{'task': '甲：干活', 'name': '甲', 'background': true});
      await callTool(<String, dynamic>{'task': '乙：干活', 'name': '乙', 'background': true});
      await waitUntil(() => engine.started.length == 2, description: '两个后台都开跑');
      final String subA = roster().firstWhere((CoreSubagent s) => s.name == '甲').id;
      final String subB = roster().firstWhere((CoreSubagent s) => s.name == '乙').id;
      expect(conversation.activeRunCount, 2);

      expect(conversation.cancelAgent(subA), isTrue, reason: '命中的是它自己那一轮');
      expect(
        conversation.isRunning(subB),
        isTrue,
        reason: '兄弟不受影响（运行键 = (subagentId, sessionId)，两两不同）',
      );
      engine.release(subA);
      await waitUntil(
        () => conversation.activeRunCount == 1,
        description: '只有乙还在跑',
      );
      expect(roster(), hasLength(2), reason: '停止不移除名册条目（还能复用接着做）');

      engine.releaseAll();
      // 乙的完成报告会**唤醒父**再跑一轮（wake）：那一轮别再卡在闸门上
      engine.hold = false;
      await waitUntil(
        () => store
            .sessionMessages(owner.id, TreeStore.defaultSessionId)
            .any(
              (CoreMessage m) =>
                  m.kind == MessageKinds.subagentReport &&
                  m.subagentId == subB,
            ),
        description: '乙的完成报告已注入父会话',
      );
      await waitUntil(() => conversation.activeRunCount == 0, description: '都收干净');
      final List<CoreMessage> all = store.sessionMessages(
        owner.id,
        TreeStore.defaultSessionId,
      );
      expect(
        all.where(
          (CoreMessage m) =>
              m.kind == MessageKinds.subagentReport && m.subagentId == subA,
        ),
        isEmpty,
        reason: '人叫停的不向发起者注入结束提示（用户自己会说原因）',
      );
      expect(
        all.where(
          (CoreMessage m) =>
              m.kind == MessageKinds.subagentReport && m.subagentId == subB,
        ),
        hasLength(1),
        reason: '乙是自然结束：报告照旧回发起者',
      );
    });

    test('插话：给主 agent 发消息不打断它名下的临时员工（用户 2026-10-03 断言）', () async {
      // 复刻 CLI 接线：后台完成 ⇒ 报告注入父会话（onFinished → wake）
      service.onFinished = (
        String ownerAgentId,
        String sessionId,
        String notice,
        SubagentTag tag,
      ) {
        unawaited(
          conversation.wake(
            agentId: ownerAgentId,
            sessionId: sessionId,
            notice: notice,
            subagent: tag,
          ),
        );
      };
      engine.hold = true;
      // 父 agent 自己那一轮先跑起来（有在途轮次，插话才有的可打断）
      final Future<void> parentTurn = conversation.handleUserMessage(
        <String, dynamic>{
          'agent_id': owner.id,
          'session_id': TreeStore.defaultSessionId,
          'content': '父自己在跑',
        },
      );
      await waitUntil(
        () => engine.started.contains(owner.id),
        description: '父那轮已开始',
      );
      // 它名下的后台临时员工也开跑（也卡在闸门上）
      await callTool(<String, dynamic>{
        'task': '长活',
        'name': '甲',
        'background': true,
      });
      await waitUntil(() => engine.started.length == 2, description: '临时员工也开跑');
      final String sub = roster().single.id;

      // 用户给**主 agent** 发消息 = 插话
      final Future<void> interjection = conversation.handleUserMessage(
        <String, dynamic>{
          'agent_id': owner.id,
          'session_id': TreeStore.defaultSessionId,
          'content': '插话一句',
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        conversation.isRunning(sub),
        isTrue,
        reason: '子 agent 不受影响（用户 2026-10-03 硬断言：发给主 agent 不打断它的子 agent）',
      );

      // 放闸：父那轮收尾、临时员工自然跑完
      engine.hold = false;
      engine.releaseAll();
      await parentTurn.timeout(const Duration(seconds: 10));
      await interjection.timeout(const Duration(seconds: 10));
      await waitUntil(
        () => store
            .sessionMessages(owner.id, TreeStore.defaultSessionId)
            .any(
              (CoreMessage m) =>
                  m.kind == MessageKinds.subagentReport && m.subagentId == sub,
            ),
        description: '临时员工的完成报告照旧注入发起者（没被当成"人叫停"）',
      );
      await waitUntil(
        () => conversation.activeRunCount == 0,
        description: '都收干净',
      );
    });

    test('agent_status：子级帧不冒充主 agent；主 agent 自己收尾时单独说清', () async {
      // 两个轮次都停在闸门上：父自己的轮次结束时，乙**仍然在跑**（聚合口径才成立）
      engine.hold = true;
      engine.holdFor.add(owner.id);
      final Future<void> parentTurn = conversation.handleUserMessage(
        <String, dynamic>{
          'agent_id': owner.id,
          'session_id': TreeStore.defaultSessionId,
          'content': '父自己在跑',
        },
      );
      await waitUntil(
        () => engine.started.contains(owner.id),
        description: '父那一轮已开始',
      );
      await callTool(<String, dynamic>{'task': '乙：干活', 'name': '乙', 'background': true});
      await waitUntil(() => engine.started.length == 2, description: '临时员工也开跑');

      Map<String, dynamic>? dataOf(Map<String, dynamic> frame) =>
          (frame['data'] as Map<String, dynamic>?)?.cast<String, dynamic>();

      // 主 agent 自己的 working 帧：带 own_running（主视角据此显示停止键）
      expect(
        hub.frames.any((Map<String, dynamic> f) {
          final Map<String, dynamic>? d = dataOf(f);
          if (f['type'] != 'agent_status' || d == null) return false;
          return d['status'] == 'working' &&
              d['agent_id'] == owner.id &&
              d['own_running'] == true;
        }),
        isTrue,
        reason: '主 agent 自己的轮次能被认出来（主视角据此显示停止键）',
      );
      // 子级帧：带 subagent_id、**不带** own_running（别让主视角跟着变）
      expect(
        hub.frames.any((Map<String, dynamic> f) {
          final Map<String, dynamic>? d = dataOf(f);
          if (f['type'] != 'agent_status' || d == null) return false;
          return d['status'] == 'working' &&
              d['subagent_id'] != null &&
              !d.containsKey('own_running');
        }),
        isTrue,
        reason: '临时成员的运行情况不应影响主 agent（用户 2026-10-03）',
      );

      engine.release(owner.id);
      await parentTurn.timeout(const Duration(seconds: 10));
      expect(
        hub.frames.any((Map<String, dynamic> f) {
          final Map<String, dynamic>? d = dataOf(f);
          if (f['type'] != 'agent_status' || d == null) return false;
          return d['status'] == 'idle' &&
              d['agent_id'] == owner.id &&
              d['own_running'] == false &&
              d['subagent_running'] == true &&
              d['subagent_id'] == null;
        }),
        isTrue,
        reason: '主 agent 自己收尾必须单独说清（聚合口径：乙还在跑）',
      );

      engine.releaseAll();
      await waitUntil(() => conversation.activeRunCount == 0, description: '收干净');
    });
  });

  test('没有文本产出 / 运行报错：都要可读，且运行态收干净', () async {
    engine.emptyReply = true;
    final ToolOutcome empty = await callTool(<String, dynamic>{'task': '只调工具'});
    expect(empty.isError, isFalse);
    expect(empty.content, contains('没有输出任何文本'));
    expect(conversation.activeRunCount, 0);

    engine.throwOnRun = true;
    final ToolOutcome failed = await callTool(<String, dynamic>{'task': '炸一次'});
    expect(failed.isError, isTrue);
    expect(failed.content, contains('执行失败'));
    expect(conversation.activeRunCount, 0);
    expect(roster(), hasLength(2), reason: '失败不删除实体（它还能被复用接着做）');
  });
}
