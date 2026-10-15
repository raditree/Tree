import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 阶段 C：核心侧 **SSH 执行站点链路** `StationTunnelLink` 的选路钉住。
///
/// 定位（2026-10-15：SSH 迁移到「处理拓展点位」）：插件订上 `ssh.execute` 后，
/// 核心把每个 SSH 动作投成一次 `station/request`（经 `PluginBus.relaySshExecute`），
/// 而**复用同一个** `TunnelSshTransport`——liveness / PTY / 回退判据全部沿用。
/// 这里用真总线 + 真假插件进程（`--ssh-execute`：订阅点位并按 action 回隧道形状），
/// 无需真 sshd，即可钉住：
/// - `available` 严格跟随「点位有没有订阅者」（与旧的按能力认**并列**、互不影响）；
/// - `ensure` → 会话建立，`request` / `snapshot` 都经站点投递、回包被正确解析；
/// - `TunnelSshTransport.connect(stationLink, …)` 端到端建得起（证明接口对得上）；
/// - agent 随连接（`scopeAgentId`）携带 ⇒ 隔离四元组成立；缺它则 fail-open 回退。
void main() {
  late Directory temp;
  late String script;

  const String team = 'team-1';
  const String agent = 'agt_1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_station_link_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
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

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  Future<PluginBus> startBus(String yaml, {List<String> logs = const []}) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.isEmpty ? null : logs.add,
    );
    addTearDown(bus.close);
    // 复刻生产接线：team 由 agent 归属解析、mode 认 ssh（这是 SSH 工作空间）。
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: agentId == agent ? team : '',
          agentId: agentId,
          sessionId: sessionId,
        );
    bus.agentModeKeyResolver = (String agentId) =>
        agentId == agent ? StationModeKey.ssh : '';
    await bus.start();
    return bus;
  }

  /// SSH 执行接管者：订阅 `ssh.execute` 并按 action 回隧道形状。
  String sshExecutePluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sshexec\n'
      '    name: SSH 执行接管插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--ssh-execute"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  Future<void> waitForSubscription(
    PluginBus bus,
    List<String> logs, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (bus.sshExecuteStationSubscribed()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      bus.sshExecuteStationSubscribed(),
      isTrue,
      reason: '插件必须订上 ssh.execute；日志：${logs.join(' | ')}',
    );
  }

  TunnelConnectRequest connectRequest({String scopeAgent = agent}) =>
      TunnelConnectRequest(
        host: '10.0.0.1',
        port: 22,
        username: 'tester',
        password: 'pw',
        root: '/home/tester',
        heartbeatInterval: const Duration(seconds: 30),
        maxMissedHeartbeats: 3,
        scopeAgentId: scopeAgent,
      );

  // ── ① available 跟随订阅；未订 ⇒ 站点不可用 ⇒ 可回退 ─────────────────────

  test('未订站点 ⇒ available=false，ensure 抛可回退的 agentUnreachable', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      'enabled: true\nplugins: []\n',
      logs: logs,
    );
    final StationTunnelLink link = StationTunnelLink(bus);

    expect(link.available, isFalse, reason: '无订阅者 ⇒ 站点路径不可用');
    expect(
      link.unavailableReason,
      contains('SSH 执行中转站点位'),
      reason: '判空必须给可读原因',
    );

    expect(
      () => link.ensure(connectRequest()),
      throwsA(
        isA<TunnelUnavailableException>().having(
          (TunnelUnavailableException e) => e.shouldFallback,
          'shouldFallback',
          isTrue,
        ),
      ),
      reason: '没有站点接管 ⇒ 回退内置（可回退类）',
    );
    link.dispose();
  });

  // ── ② 站点端到端：ensure / request / snapshot 都经 relaySshExecute ───────

  test('订站点 ⇒ available=true，ensure 建会话、request/snapshot 经站点投递被正确解析',
      () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(sshExecutePluginYaml(), logs: logs);
    await waitForSubscription(bus, logs);
    final StationTunnelLink link = StationTunnelLink(bus);
    addTearDown(link.dispose);

    expect(link.available, isTrue);

    final TunnelSession session = await link.ensure(connectRequest());
    expect(session.connId, isNotEmpty);
    expect(session.root, '/home/fake');
    expect(session.agent['version'], '9.9.9');

    // request → 站点 action=request → 假插件回 {ok, result:{seen}}。
    final Object? res = await session.request(
      'agent.fs.stat',
      <String, dynamic>{'path': '/a'},
    );
    expect(res, isA<Map<Object?, Object?>>());
    expect((res! as Map)['seen'], 'agent.fs.stat');

    // snapshot → 站点 action=state → ready（这是心跳的权威判活面）。
    final TunnelSnapshot snap = await session.snapshot();
    expect(snap.connId, session.connId);
    expect(snap.ready, isTrue);

    await session.close();
  });

  // ── ③ 复用既有 TunnelSshTransport：接口对得上、连接建得起 ────────────────

  test('TunnelSshTransport.connect(stationLink, …) 端到端可用（复用同一传输）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(sshExecutePluginYaml(), logs: logs);
    await waitForSubscription(bus, logs);
    final StationTunnelLink link = StationTunnelLink(bus);
    addTearDown(link.dispose);

    final TunnelSshTransport transport = await TunnelSshTransport.connect(
      link,
      connectRequest(),
      log: logs.add,
    );
    expect(transport.root, '/home/fake');
    expect(transport.agentInfo['version'], '9.9.9');
    // 建连即起心跳；显式关闭应干净返回（不抛）。
    await transport.close();
  });

  // ── ④ agent 缺失 ⇒ 隔离四元组不成立 ⇒ fail-open 回退（不假装接管）──────────

  test('连接未带 scopeAgentId ⇒ 站点作用域不成立 ⇒ fail-open 回退内置', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(sshExecutePluginYaml(), logs: logs);
    await waitForSubscription(bus, logs);
    final StationTunnelLink link = StationTunnelLink(bus);
    addTearDown(link.dispose);

    // 点位有订阅者 ⇒ available=true；但投递时 agent 为空 ⇒ team 解析不出 ⇒ scope 非法。
    expect(link.available, isTrue);
    expect(
      () => link.ensure(connectRequest(scopeAgent: '')),
      throwsA(isA<TunnelUnavailableException>()),
      reason: 'relay 对非法作用域返回 null ⇒ 站点如实判为未接管，可回退内置',
    );
  });
}
