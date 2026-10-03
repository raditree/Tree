import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **运行中工具登记表**（`ToolRunRegistry`）与它的三站/面板面（plan §4 步骤 2-5，§10 D1~D5）。
///
/// 病根：工具执行没有静态上限 ⇒ 一条不返回的命令让整批工具永不结束 ⇒ 引擎把批中途
/// 到来的用户消息无限延期 ⇒ teammate 永久失联且无日志（见 `.self/recon-arch-stability.md`
/// §2.7）。这里钉住的正是"可见 + 可显式收手"的最小闭环：
/// 登记 / 收尾 / 句柄失效 / 超阈值 warning「每次运行只发一次」/ REST 快照形状 /
/// 广播载荷形状 / 显式关闭 ⇒ 在途调用收敛（批能收尾）。
///
/// 别真等 120 s：阈值是**可注入**的（`threshold:`），时钟也可以注入（`now:`）。
void main() {
  const String agent = 'agt_1';
  const String session = 'ses_1';

  /// terminal 的"跑很久"命令（本地路径）。
  String longCommand(int seconds) =>
      Platform.isWindows ? 'Start-Sleep -Seconds $seconds' : 'sleep $seconds';

  group('登记表：增删查 + 句柄语义', () {
    test('start 返回冻结格式的句柄并登记在表里；finish 收尾后不留痕', () {
      final ToolRunRegistry registry = ToolRunRegistry();
      final ToolRun run = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'find /mnt/space -name x'},
        agentId: agent,
        sessionId: session,
      );

      expect(
        RegExp(r'^toolrun_\d+_[a-z0-9]{4}_\d+$').hasMatch(run.handle),
        isTrue,
        reason: '句柄格式冻结为 toolrun_<ms>_<rand>_<n>（plan §10 D1）',
      );
      expect(run.tool, 'terminal');
      expect(run.agentId, agent);
      expect(run.sessionId, session);
      expect(run.command, contains('find /mnt/space'));
      expect(registry.length, 1);
      expect(registry.list().single.handle, run.handle);

      registry.finish(run);
      expect(registry.length, 0);
      // 幂等：重复 finish 不抛
      registry.finish(run);
      registry.finish(run.handle);
      expect(registry.length, 0);
      expect(run.finished, isTrue);
    });

    test('句柄失效（未知 / 已结束）⇒ closed:false + 可读原因；不跨重启存活', () async {
      final ToolRunRegistry registry = ToolRunRegistry();
      final ToolCloseOutcome missing = await registry.close('toolrun_1_abcd_1');
      expect(missing.closed, isFalse);
      expect(missing.note, contains('已失效'));
      expect(missing.note, contains('内存'), reason: '要说明登记表是纯内存、重启即清空');
      expect(missing.tool, isEmpty);

      // 运行结束（finish）后句柄同样失效
      final ToolRun run = registry.start(
        tool: 'grep',
        arguments: <String, dynamic>{'pattern': 'x'},
        agentId: agent,
        sessionId: session,
      );
      registry.finish(run);
      final ToolCloseOutcome after = await registry.close(run.handle);
      expect(after.closed, isFalse);
      expect(after.note, contains(run.handle));
    });

    test('close：登记表清空 + 在途调用收到显式关闭说明（含工具名 / handle / 提示别重跑）',
        () async {
      final ToolRunRegistry registry = ToolRunRegistry();
      registry.terminate = (ToolRun run) async => '测试：没有本机进程句柄';
      final ToolRun run = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': longCommand(30)},
        agentId: agent,
        sessionId: session,
      );

      final ToolCloseOutcome outcome = await registry.close(run.handle);
      expect(outcome.closed, isTrue);
      expect(outcome.tool, 'terminal');
      expect(outcome.note, contains('没有本机进程句柄'));
      expect(
        outcome.toJson().keys,
        <String>{'closed', 'tool', 'elapsed_ms', 'note'},
        reason: '执行站 tool.close 的返回形状冻结（plan §10 D5）',
      );
      expect(registry.length, 0, reason: '关闭后登记表必须清空');
      expect(run.isCloseRequested, isTrue);
      expect(await run.closeRequested, contains('没有本机进程句柄'));
      expect(run.closedOutcomeText, contains('【已按显式关闭请求终止】'));
      expect(run.closedOutcomeText, contains('terminal'));
      expect(run.closedOutcomeText, contains(run.handle));
      expect(run.closedOutcomeText, contains('不要直接重跑'));
    });
  });

  group('超阈值 warning：每次运行只发一次（含跨阈值只发一次）', () {
    test('跨阈值后反复检查 / 计时器到点，都只发一条会话提示 + 一行 core.log', () async {
      int nowMs = 1000000;
      final List<String> notices = <String>[];
      final List<String> logs = <String>[];
      final ToolRunRegistry registry = ToolRunRegistry(
        threshold: const Duration(milliseconds: 40),
        now: () => nowMs,
        notice: (String a, String s, String text) {
          expect(a, agent);
          expect(s, session);
          notices.add(text);
        },
        log: logs.add,
      );
      final ToolRun run = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{
          'command': 'find /mnt/space -name "M4_REPORT.md"',
        },
        agentId: agent,
        sessionId: session,
      );

      // 未到阈值：检查多少次都不发
      nowMs += 10;
      registry.checkTimeouts();
      expect(notices, isEmpty);
      expect(run.warned, isFalse);

      // 跨过阈值：第一次发；此后反复检查（含计时器到点）都不再发
      nowMs += 100000;
      registry.checkTimeouts();
      expect(notices, hasLength(1), reason: '跨阈值只发一次');
      expect(run.warned, isTrue);
      expect(run.overThreshold(registry.threshold), isTrue);

      registry.checkTimeouts();
      registry.checkTimeouts();
      // 计时器到点那条路径（同一次运行）也不该补发第二条
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(notices, hasLength(1), reason: 'warning 每次运行只发一次');

      final String text = notices.single;
      expect(text, contains('terminal'), reason: '文案含工具名');
      expect(text, contains('秒'), reason: '文案含已执行秒数');
      expect(text, contains('find /mnt/space'), reason: '文案含命令摘要');
      expect(text, contains('正在执行的 tool'), reason: '文案要指向右栏面板（plan §4 步骤 3）');
      expect(text, contains('关闭'), reason: '文案要说明怎么收手');
      expect(logs.where((String l) => l.contains('超阈值')), hasLength(1));
      expect(logs.single, contains(run.handle));

      // 收尾后：即便"已经是超阈值状态"，也不再发（运行已不在表里）
      registry.finish(run);
      registry.checkTimeouts();
      expect(notices, hasLength(1));
    });

    test('广播站点位落点：超阈值时收到一次冻结载荷（7 个键）', () {
      int nowMs = 2000000;
      final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
      final ToolRunRegistry registry = ToolRunRegistry(
        threshold: const Duration(milliseconds: 50),
        now: () => nowMs,
        onTimeout: payloads.add,
      );
      registry.start(
        tool: 'plugin__demo__slow',
        arguments: <String, dynamic>{'secret_token': 'sk-x', 'q': 'hi'},
        agentId: agent,
        sessionId: session,
      );
      nowMs += 500;
      registry.checkTimeouts();
      registry.checkTimeouts();

      expect(payloads, hasLength(1), reason: '超阈值只广播一次');
      expect(
        payloads.single.keys,
        <String>{
          'handle',
          'agent_id',
          'session_id',
          'tool',
          'command',
          'elapsed_ms',
          'started_at',
        },
        reason: '载荷键集冻结（plan §10 D4）',
      );
      expect(payloads.single['agent_id'], agent);
      expect(payloads.single['session_id'], session);
      expect(payloads.single['tool'], 'plugin__demo__slow');
      expect(payloads.single['elapsed_ms'], 500);
      expect(payloads.single['started_at'], 2000000);
      expect(
        payloads.single['command'],
        contains('***'),
        reason: '敏感键打码（密钥不进日志/帧）',
      );
      expect(payloads.single['command'], isNot(contains('sk-x')));
    });
  });

  group('REST 快照（GET /api/tools/running 的数据源）', () {
    test('形状冻结；over_threshold 与 command_preview 按阈值/长度算', () {
      int nowMs = 3000000;
      final ToolRunRegistry registry = ToolRunRegistry(
        threshold: const Duration(seconds: 120),
        now: () => nowMs,
      );
      final String longText = 'x' * 500;
      registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': longText},
        agentId: agent,
        sessionId: session,
      );
      final ToolRun shortRun = registry.start(
        tool: 'grep',
        arguments: <String, dynamic>{'pattern': 'foo'},
        agentId: 'agt_2',
        sessionId: 'ses_2',
      );

      final Map<String, dynamic> body = registry.snapshot();
      expect(body.keys, <String>{'runs'});
      final List<Map<String, dynamic>> runs =
          (body['runs'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(runs, hasLength(2));
      expect(
        runs.first.keys,
        <String>{
          'handle',
          'agent_id',
          'session_id',
          'tool',
          'command_preview',
          'started_at',
          'elapsed_ms',
          'over_threshold',
        },
        reason: 'REST 快照字段冻结（plan §4 步骤 4）',
      );
      expect(runs.first['over_threshold'], isFalse);
      expect(runs.first['elapsed_ms'], 0);
      expect(
        (runs.first['command_preview'] as String).length,
        ToolRun.commandPreviewChars + 1,
        reason: '超长命令只给预览（截断 + 省略号）',
      );
      expect(runs.first['command_preview'], endsWith('…'));

      nowMs += 121000;
      final List<Map<String, dynamic>> after =
          (registry.snapshot()['runs'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      expect(after.every((Map<String, dynamic> r) => r['over_threshold'] == true),
          isTrue);
      expect(registry.stuck(), hasLength(2));
      expect(
        registry.stuckFor('agt_2').single.handle,
        shortRun.handle,
        reason: 'stuckFor 按 agent 过滤（query_status 用）',
      );
    });
  });

  group('query_status.stuck_tools 的数据源', () {
    test('stuckJson 字段冻结 + hint 是防呆风险提示', () {
      int nowMs = 4000000;
      final ToolRunRegistry registry = ToolRunRegistry(
        threshold: const Duration(milliseconds: 100),
        now: () => nowMs,
      );
      final ToolRun run = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'find /mnt/space -name "*.md"'},
        agentId: agent,
        sessionId: session,
      );
      nowMs += 300;
      final Map<String, dynamic> stuck = registry.stuckFor(agent).single
          .stuckJson();
      expect(
        stuck.keys,
        <String>{'handle', 'tool', 'elapsed_ms', 'command', 'hint'},
        reason: '字段冻结（plan §4 步骤 6）',
      );
      expect(stuck['handle'], run.handle);
      expect(stuck['elapsed_ms'], 300);
      expect(stuck['hint'], contains('find'));
      expect(stuck['hint'], contains('-maxdepth'));
      expect(stuck['hint'], contains('tool.close'));
    });

    test('summarizeToolCommand：terminal 取命令本身；其它工具取参数摘要并打码', () {
      expect(
        summarizeToolCommand('terminal', <String, dynamic>{'command': 'ls -l\necho hi'}),
        'ls -l echo hi',
        reason: '多行命令压成一行（warning / 面板都是一行）',
      );
      expect(
        summarizeToolCommand('terminal', <String, dynamic>{}),
        contains('未给 command'),
      );
      final String summary = summarizeToolCommand('write', <String, dynamic>{
        'file_path': 'a.txt',
        'api_key': 'k-123',
      });
      expect(summary, contains('a.txt'));
      expect(summary, contains('***'));
      expect(summary, isNot(contains('k-123')));
    });
  });

  group('广播站 system.tool.timeout', () {
    late Directory temp;
    late PluginBus bus;
    late List<String> logs;

    const String team = 'team-1';

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_tool_timeout_');
      logs = <String>[];
      final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
      file.createSync(recursive: true);
      file.writeAsStringSync('enabled: true\nplugins: []\n');
      bus = PluginBus(configFile: file.path, log: logs.add);
      addTearDown(bus.close);
      bus.callSiteContext = (String agentId, String sessionId) =>
          StationScopeContext(teamId: team, agentId: agentId, sessionId: sessionId);
      bus.agentModeKeyResolver = (String agentId) => StationModeKey.local;
      bus.stations.livenessProbe = (String pluginId) =>
          const StationLivenessState.alive();
    });

    tearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    test('点位已登记（id / 别名 / 在 StationHubIds.all 里）', () {
      expect(StationHubIds.broadcastToolTimeout, 'system.tool.timeout');
      expect(StationHubIds.all, contains(StationHubIds.broadcastToolTimeout));
      final StationPointSpec? spec = StationPoints.byId(
        StationHubIds.broadcastToolTimeout,
      );
      expect(spec, isNotNull);
      expect(spec!.kind, StationKind.broadcast);
      expect(spec.alias, 'tool.timeout');
      expect(
        StationPoints.resolveAlias(kindWire: 'broadcast', point: 'tool.timeout'),
        hasLength(1),
        reason: '插件按 {station: broadcast, point: tool.timeout} 能订上',
      );
    });

    test('订阅者收到一次载荷（含 point 与冻结键）', () async {
      final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];
      expect(
        bus.stations.pointFor(StationHubIds.broadcastToolTimeout),
        isNotNull,
      );
      final StationSubResult subscribed = bus.stations.subscribe(
        StationHubIds.broadcastToolTimeout,
        StationSubscriber(
          pluginId: 'demo',
          scope: const StationScope(teamId: team),
        ),
        (StationRequest request) async {
          received.add(
            Map<String, dynamic>.from(request.payload as Map),
          );
          return const StationReply.ok(null);
        },
      );
      expect(subscribed.ok, isTrue, reason: subscribed.error);

      bus.announceToolTimeout(<String, dynamic>{
        'handle': 'toolrun_1_abcd_1',
        'agent_id': agent,
        'session_id': session,
        'tool': 'terminal',
        'command': 'find /mnt/space -name x',
        'elapsed_ms': 120500,
        'started_at': 1000,
      });

      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (received.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received, hasLength(1));
      expect(received.single['point'], StationHubIds.broadcastToolTimeout);
      expect(received.single['handle'], 'toolrun_1_abcd_1');
      expect(received.single['elapsed_ms'], 120500);
      expect(received.single['tool'], 'terminal');
      expect(received.single['agent_id'], agent);
      expect(received.single['session_id'], session);
      expect(received.single['command'], contains('find /mnt/space'));
      expect(received.single['started_at'], 1000);
    });
  });

  group('WorkspaceToolRunner 挂载（所有工具调用的同一入口）', () {
    late Directory temp;
    late String workspace;
    late List<String> logs;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_tool_runs_');
      workspace = p.join(temp.path, 'ws');
      Directory(workspace).createSync(recursive: true);
      logs = <String>[];
    });

    tearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    });

    test('执行期间登记在表里，结束即移除（finally 收尾）', () async {
      final ToolRunRegistry registry = ToolRunRegistry(
        threshold: const Duration(seconds: 120),
      );
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => workspace,
        toolRuns: registry,
        log: logs.add,
      );
      addTearDown(runner.close);

      final Future<ToolOutcome> pending = runner.run(
        const ToolInvocation(
          id: 'call-1',
          name: 'terminal',
          arguments: <String, dynamic>{'command': 'echo hi'},
          agentId: agent,
          sessionId: session,
        ),
      );
      // 命令很短，执行期间表里可能是 0/1 条：这里断言的是"跑完不留痕"
      final ToolOutcome outcome = await pending;
      expect(outcome.isError, isFalse);
      expect(registry.length, 0, reason: '工具返回后登记项必须移除');
    });

    test('显式关闭 ⇒ 在途调用立刻收敛（批能收尾）+ 登记表清空', () async {
      final ToolRunRegistry registry = ToolRunRegistry(
        threshold: const Duration(seconds: 120),
      );
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => workspace,
        toolRuns: registry,
        log: logs.add,
      );
      addTearDown(runner.close);
      registry.terminate = runner.terminateToolRun;

      final Stopwatch watch = Stopwatch()..start();
      final Future<ToolOutcome> pending = runner.run(
        ToolInvocation(
          id: 'call-2',
          name: 'terminal',
          arguments: <String, dynamic>{'command': longCommand(3)},
          agentId: agent,
          sessionId: session,
        ),
      );

      // 等它真的在跑（登记表里出现这次运行）
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (registry.length == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final ToolRun run = registry.list().single;
      expect(run.tool, 'terminal');
      expect(run.command, contains('Start-Sleep'));

      final ToolCloseOutcome closed = await registry.close(run.handle);
      expect(closed.closed, isTrue);
      expect(registry.length, 0);

      final ToolOutcome outcome = await pending.timeout(const Duration(seconds: 2));
      watch.stop();
      expect(
        outcome.isError,
        isTrue,
        reason: '被关闭的调用没有正常完成 ⇒ 如实标记为错误结果',
      );
      expect(outcome.content, contains('【已按显式关闭请求终止】'));
      expect(outcome.content, contains(run.handle));
      expect(
        outcome.content,
        contains('本机进程句柄'),
        reason: '没有 pid ⇒ 如实说明没杀到进程（不假装杀成功）',
      );
      expect(
        watch.elapsed.inSeconds,
        lessThan(3),
        reason: '关闭必须让在途调用立刻收敛，而不是等命令跑完',
      );
    });
  });
}
