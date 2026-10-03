import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **临时员工起的 `terminal hook` 完成之后，收尾要落在对应目标**（用户 2026-10-03 现场）。
///
/// 三条口径（一条都不许弄坏）：
/// 1. hook 的**日志与超长结果重定向**落在**会话主人那一份**（子继承发起者的工作空间/
///    私有分栏，工作空间里不会出现 `sub_*` 目录）——这是既有刻意口径；
/// 2. 完成提示要落进**会话主人**的会话流、并带临时员工的标记（界面按标记分组）；
/// 3. 被唤醒的是**那个临时员工自己**（运行键 `(sub_…, session)`，不与正阻塞等它的父
///    撞键），且它那一轮读到的是**它自己的历史**（不是父的、也不是空历史）。
///
/// 回归的 bug：`_finished` 没带标记 ⇒ `wake` 用 `sub_…` 取会话取到 null 直接 return
/// ⇒ 提示不落库、子永远不被唤醒、父在 `wait_for`/`subagent` 上白等。
void main() {
  const String sessionId = TreeStore.defaultSessionId;
  const String subId = 'sub_hook_1';

  late Directory temp;
  late MemoryStore inner;
  late SubagentRegistry registry;
  late SubagentStore store;
  late CoreSettings settings;
  late _RecordingHub hub;
  late _CapturingEngine engine;
  late ConversationService conversation;
  late SubagentService service;
  late WorkspaceToolRunner tools;
  late CoreAgent owner;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_sub_hook_');
    inner = MemoryStore();
    registry = SubagentRegistry(persistence: inner);
    store = SubagentStore(inner: inner, registry: registry);
    settings = CoreSettings();
    settings.putModel(CoreModelConfig(modelId: 'demo', name: 'demo'));
    hub = _RecordingHub();
    engine = _CapturingEngine();
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
    owner = store.createAgent(name: '主人', modelId: 'demo');
    // 名册里预置一个临时员工（本用例只关心 hook 的收尾链路，不起它的 LLM 轮）
    final int now = DateTime.now().millisecondsSinceEpoch;
    inner.putSubagent(
      CoreSubagent(
        id: subId,
        name: '甲',
        ownerAgentId: owner.id,
        sessionId: sessionId,
        parentId: owner.id,
        level: 1,
        agent: CoreAgent(
          id: subId,
          name: '甲',
          modelId: 'demo',
          createdAt: now,
          updatedAt: now,
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );
    registry.ensureSession(owner.id, sessionId);
    tools = WorkspaceToolRunner(
      resolveWorkspaceDir: (String id) => temp.path,
      subagentService: service,
    );
    // CLI 里的同一根接线（完成回调 → 唤醒；标记要透传）
    tools.onHookFinished =
        (
          String agentId,
          String sessionId,
          String notice, {
          SubagentTag? subagent,
        }) {
          unawaited(
            conversation.wake(
              agentId: agentId,
              sessionId: sessionId,
              notice: notice,
              subagent: subagent,
            ),
          );
        };
    // 它自己的历史（hook 之前就在）+ 父自己的话（用来证明"读到的是自己那一段"）
    store.appendMessage(
      CoreMessage(
        id: 'm_owner',
        agentId: owner.id,
        sessionId: sessionId,
        role: 'user',
        content: '主人自己的话',
        timestamp: 1,
      ),
    );
    store.appendMessage(
      CoreMessage(
        id: 'm_sub',
        agentId: owner.id,
        sessionId: sessionId,
        role: 'agent',
        content: '甲：干活',
        kind: MessageKinds.subagentTask,
        timestamp: 2,
        subagentId: subId,
        subagentName: '甲',
        subagentParentId: owner.id,
        subagentLevel: 1,
      ),
    );
  });

  tearDown(() async {
    await tools.close();
    conversation.dispose();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('临时员工的 terminal hook 完成后：提示归到会话主人 + 唤醒它自己 + 用得到自己的历史', () async {
    final ToolOutcome started = await tools.run(
      ToolInvocation(
        id: 'tc_hook',
        name: 'terminal',
        arguments: <String, dynamic>{
          'command': 'echo hook-for-sub',
          'hook': true,
        },
        agentId: subId,
        sessionId: sessionId,
      ),
    );
    expect(started.isError, isFalse, reason: started.content);
    expect(started.content, contains('task_id'), reason: 'hook 模式立刻返回 task_id');

    // ② 完成提示落进**会话主人**的会话流，且带临时员工标记
    await _waitUntil(
      () => store
          .sessionMessages(owner.id, sessionId)
          .any(
            (CoreMessage m) =>
                m.content.contains('[terminal hook]') && m.subagentId == subId,
          ),
      description: '完成提示落进会话主人的会话流并带 subagent_id',
    );
    final CoreMessage notice = store
        .sessionMessages(owner.id, sessionId)
        .lastWhere((CoreMessage m) => m.content.contains('[terminal hook]'));
    expect(
      notice.agentId,
      owner.id,
      reason: '归属是会话主人（不是谁都读不到的 sub_…::session 那一份）',
    );
    expect(notice.subagentId, subId);
    expect(
      notice.kind,
      isNot(MessageKinds.subagentReport),
      reason: '这是喂给**它自己**的提示（它自己的历史按标记取，报告类会被排掉）',
    );
    expect(
      hub.frames.any(
        (Map<String, dynamic> f) =>
            f['subagent_id'] == subId &&
            '${f['content'] ?? ''}'.contains('[terminal hook]'),
      ),
      isTrue,
      reason: '帧也带标记（界面按标记把它显示在这名临时员工名下）',
    );

    // ③ 被唤醒的是它自己，且那一轮读得到**它自己的历史**
    await _waitUntil(
      () => engine.contexts.any((AgentRunContext c) => c.agentId == subId),
      description: '被唤醒的是那个临时员工自己',
    );
    final AgentRunContext woken = engine.contexts.lastWhere(
      (AgentRunContext c) => c.agentId == subId,
    );
    expect(woken.userContent, contains('[terminal hook]'));
    final List<String> history = woken.history
        .map((CoreMessageRef r) => r.content)
        .toList(growable: false);
    expect(
      history.any((String c) => c.contains('甲：干活')),
      isTrue,
      reason: '它读得到自己的历史（不是空历史）',
    );
    expect(
      history.any((String c) => c.contains('主人自己的话')),
      isFalse,
      reason: '不是父那一段历史',
    );

    // ① 日志/重定向仍落在会话主人那一份：工作空间根下的 .output/，且没有 sub_* 目录
    expect(
      Directory(p.join(temp.path, '.output')).existsSync(),
      isTrue,
      reason: 'hook 日志落在继承来的工作空间里',
    );
    expect(
      Directory(p.join(temp.path, '.tree', subId)).existsSync(),
      isFalse,
      reason: '既有口径：不许在用户工作空间里留下 sub_* 目录',
    );
    expect(conversation.activeRunCount, 0, reason: '被唤醒那一轮已收干净');
  });
}

/// 假引擎：只记录每一轮拿到的上下文（本用例关心"谁被唤醒、带什么历史"）。
class _CapturingEngine implements AgentEngine {
  final List<AgentRunContext> contexts = <AgentRunContext>[];

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    contexts.add(context);
    yield const AgentText('收到');
    yield const AgentDone();
  }

  @override
  Future<void> close() async {}
}

/// 记账用广播槽（断言帧上带 subagent 标记）。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  @override
  void broadcast(Map<String, dynamic> frame) => frames.add(frame);
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  String description = '条件',
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待「$description」超时');
}
