import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 记录每次运行拿到的系统提示词（= 真会发出去的那条 `[0] system`）。
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

/// 系统提示词 **pin 落库**：跨重启逐字复用、来源变了也复用旧快照。
///
/// 用户 2026-10-04 断言原文：
/// 「系统提示词的重建必须在初次对话或 compact 后，断言：若需启用新的工作空间提示词
/// 文件 + agent 提示词 + 工作空间段 + Spec 索引 + 已选 Spec 全文 + 用户可编辑提示词，
/// 必须开新会话或 compact，否则**必用缓存复用旧版快照**」。
///
/// 为什么（真机事故，见 docs/known-issues.md #28）：`system` 是消息序列第 0 条，它换
/// 一个字节，端点前缀缓存整条谱系作废；而这份钉住值以前只活在进程内存里 ⇒ 每次重启
/// 都重建 ⇒ 重启后第一个请求（往往正是最贵的压缩，24 万 token）付全价。
void main() {
  const String sessionId = TreeStore.defaultSessionId;

  /// 起一台核心 + 一个 WS，返回可直接发消息的句柄。
  Future<({CoreServer server, TestWs ws, _CapturingEngine engine})> boot({
    TreeStore? store,
    SystemPromptStore? prompts,
  }) async {
    final _CapturingEngine engine = _CapturingEngine();
    final CoreServer server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      engine: engine,
      store: store,
      systemPromptStore: prompts,
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    return (server: server, ws: ws, engine: engine);
  }

  /// 发一条消息并等到第 [runs] 轮真的跑起来。
  Future<void> send(
    CoreServer server,
    TestWs ws,
    _CapturingEngine engine,
    String agentId,
    String content,
    int runs,
  ) async {
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

  /// 换掉提示词的一个外部来源（真实场景里对应 Spec 快照补扫完成 / 文件被改）。
  void changePromptSource(String marker) {
    final String Function(CoreAgent)? original = specIndexProvider;
    specIndexProvider = (CoreAgent agent) => '## 变了的索引\n- $marker';
    addTearDown(() => specIndexProvider = original);
  }

  setUp(() {
    // 两个来源都显式设成确定值（全局 provider 会跨用例泄漏）
    systemPromptFileProvider = (CoreAgent _) => '全局约定段（工作空间提示词文件）';
    selectedSpecsProvider = null;
    specIndexProvider = null;
  });

  tearDown(() {
    systemPromptFileProvider = null;
    selectedSpecsProvider = null;
    specIndexProvider = null;
  });

  group('pin 落库 / 跨重启', () {
    late Directory root;
    late Directory workspace;
    late FileTreeStore first;
    late CoreServer serverA;
    late TestWs wsA;
    late _CapturingEngine engineA;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('tree_pin_root_');
      workspace = Directory.systemTemp.createTempSync('tree_pin_ws_');
      addTearDown(() async {
        for (final Directory dir in <Directory>[root, workspace]) {
          for (int i = 0; i < 5; i++) {
            try {
              if (dir.existsSync()) dir.deleteSync(recursive: true);
              break;
            } catch (_) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        }
      });
      first = FileTreeStore(TreePaths(root.path));
      final ({CoreServer server, TestWs ws, _CapturingEngine engine}) a =
          await boot(store: first);
      serverA = a.server;
      wsA = a.ws;
      engineA = a.engine;
    });

    /// 关掉第一台核心与它的 store（落盘队列要 flush 完，重启才读得到）。
    Future<void> stopFirst() async {
      await wsA.close();
      await serverA.close();
      await first.close();
    }

    test('重启后同一会话的 [0] system 逐字相同（复用落库值，不重建）', () async {
      final CoreAgent agent = serverA.store.createAgent(name: 'pin 落库用例');
      await send(serverA, wsA, engineA, agent.id, '第一轮', 1);
      final String before = engineA.prompts.first;
      expect(before, isNotEmpty);
      expect(
        first.session(agent.id, sessionId)!.systemPromptPinned,
        before,
        reason: '首轮就该把钉住值落库（跨重启复用的依据）',
      );

      await stopFirst();

      // 重启：新进程、新 store、同一个数据目录
      final FileTreeStore second = FileTreeStore(TreePaths(root.path));
      addTearDown(second.close);
      final ({CoreServer server, TestWs ws, _CapturingEngine engine}) b =
          await boot(store: second);
      addTearDown(() async {
        await b.ws.close();
        await b.server.close();
      });
      expect(second.agent(agent.id), isNotNull, reason: 'agent 应从盘上读回来');
      await send(b.server, b.ws, b.engine, agent.id, '第二轮', 1);

      expect(b.engine.prompts.first, before, reason: '重启不该改字节（断言：必用旧快照）');
      expect(
        second.session(agent.id, sessionId)!.systemPromptPinned,
        before,
        reason: '复用不改落库值',
      );
    });

    test('来源变了但没开新会话 / compact ⇒ 仍复用旧快照', () async {
      final CoreAgent agent = serverA.store.createAgent(name: 'pin 复用用例');
      await send(serverA, wsA, engineA, agent.id, '第一轮', 1);
      final String before = engineA.prompts.first;

      await stopFirst();

      // 来源变了（模拟 Spec 快照补扫出全量索引 / 用户改了提示词文件）
      systemPromptFileProvider = (CoreAgent _) => '被改过的全局段 brand-new-var';
      changePromptSource('brand-new-var');

      final FileTreeStore second = FileTreeStore(TreePaths(root.path));
      addTearDown(second.close);
      final ({CoreServer server, TestWs ws, _CapturingEngine engine}) b =
          await boot(store: second);
      addTearDown(() async {
        await b.ws.close();
        await b.server.close();
      });
      await send(b.server, b.ws, b.engine, agent.id, '第二轮', 1);

      expect(b.engine.prompts.first, before, reason: '来源变了不等于重建');
      expect(b.engine.prompts.first, isNot(contains('brand-new-var')));
      expect(b.engine.prompts.first, isNot(contains('被改过的全局段')));
    });
  });

  test('初次对话：工作空间提示词文件必须**先热完**再钉（冷启动不得缺段）', () async {
    final Directory wsDir = Directory.systemTemp.createTempSync('tree_pin_cold_');
    addTearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    // 真·SystemPromptStore：本进程首次 snapshot() 恒返回空串（后台才补读）——
    // 这正是真机事故里"提示词少了最前面那段"的来源（known-issues #28）。
    final SystemPromptStore prompts = SystemPromptStore(
      ioFor: (String _) async => LocalWorkspaceIO(wsDir.path),
    );
    expect(prompts.snapshot('agt_cold'), isEmpty, reason: '未热时确实是空的');

    systemPromptFileProvider = (CoreAgent agent) => prompts.snapshot(agent.id);

    final ({CoreServer server, TestWs ws, _CapturingEngine engine}) a = await boot(
      prompts: prompts,
    );
    addTearDown(() async {
      await a.ws.close();
      await a.server.close();
    });
    final CoreAgent agent = a.server.store.createAgent(name: '冷启动用例');
    await send(a.server, a.ws, a.engine, agent.id, '第一轮', 1);

    expect(
      a.engine.prompts.first,
      contains('你是当前任务的专业执行者'),
      reason: '第一轮就必须带上工作空间提示词文件（预热要先热完再拼）',
    );
    expect(
      a.server.store.session(agent.id, sessionId)!.systemPromptPinned,
      a.engine.prompts.first,
    );
  });

  test('compact / 显式失效之后才重建，并重新落库', () async {
    final ({CoreServer server, TestWs ws, _CapturingEngine engine}) a = await boot();
    addTearDown(() async {
      await a.ws.close();
      await a.server.close();
    });
    final CoreAgent agent = a.server.store.createAgent(name: '失效重建用例');
    await send(a.server, a.ws, a.engine, agent.id, '第一轮', 1);
    final String before = a.engine.prompts.first;

    changePromptSource('brand-new-var');
    a.server.conversation.invalidateSystemPrompt(agent.id, sessionId);
    expect(
      a.server.store.session(agent.id, sessionId)!.systemPromptPinned,
      isEmpty,
      reason: '失效要连落库一起清（否则"复用旧快照"会把刚失效的那份又捡回来）',
    );

    await send(a.server, a.ws, a.engine, agent.id, '第二轮', 2);
    expect(a.engine.prompts[1], isNot(before), reason: '失效后重建');
    expect(a.engine.prompts[1], contains('brand-new-var'));
    expect(
      a.server.store.session(agent.id, sessionId)!.systemPromptPinned,
      a.engine.prompts[1],
      reason: '重建后要重新落库',
    );
  });
}
