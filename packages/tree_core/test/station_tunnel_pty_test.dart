import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 阶段 D：站点路径的两处**运行时接缝**钉住（无需真 sshd，真插件进程 + 真总线）：
///
/// 1. **PTY fan-out**：`tunnel/event` 现在**同时**喂两条并存消费者——旧 `PluginTunnelLink`
///    独占的 [PluginBus.onTunnelEvent] 字段，与 `StationTunnelLink` 注册的监听器列表。
///    一条 `tunnel/event` 应两条都到（各按全局唯一 `conn_id` 认领），证明迁移把旧链路
///    降级为兼容层后**并存不互斥**；不属于自己 `conn_id` 的应被丢弃（这里用同一 conn_id 命中）。
/// 2. **快照判死**：插件重启 ⇒ 台账清空 ⇒ 本 `conn_id` 从 `state` 回包消失 ⇒
///    `snapshot()` 如实返回 `down`（`ready == false`）——这正是 `TunnelSshTransport._beat`
///    据以判死、核心撤换缓存的确凿证据（站点路径不绑实例，判死只认快照）。
void main() {
  late Directory temp;
  late String script;

  const String team = 'team-1';
  const String agent = 'agt_1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_station_pty_');
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

  /// SSH 执行接管者：`extraFlag` 选 `--ssh-execute`（就绪）或 `--ssh-execute-down`（空台账）。
  String sshExecutePluginYaml({String extraFlag = '--ssh-execute'}) =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sshexec\n'
      '    name: SSH 执行接管插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "$extraFlag"]\n'
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

  TunnelConnectRequest connectRequest() => TunnelConnectRequest(
    host: '10.0.0.1',
    port: 22,
    username: 'tester',
    password: 'pw',
    root: '/home/tester',
    heartbeatInterval: const Duration(seconds: 30),
    maxMissedHeartbeats: 3,
    scopeAgentId: agent,
  );

  // ── ① PTY fan-out：一条 tunnel/event 同时命中旧字段与站点监听器 ────────────
  test(
    'tunnel/event 双发：旧 onTunnelEvent 字段与站点会话都按 conn_id 收到 PTY 字节',
    () async {
      final List<String> logs = <String>[];
      final PluginBus bus = await startBus(sshExecutePluginYaml(), logs: logs);
      await waitForSubscription(bus, logs);

      // 旧兼容消费者：本测试手工挂上（生产中由 PluginTunnelLink 构造时挂），
      // 只为钉住「派发两条都发」——它与站点链路的监听器并存。
      final Completer<Map<String, dynamic>> legacyEvent =
          Completer<Map<String, dynamic>>();
      bus.onTunnelEvent = (String pluginId, Map<String, dynamic> params) {
        if (!legacyEvent.isCompleted) legacyEvent.complete(params);
      };

      final StationTunnelLink link = StationTunnelLink(bus);
      addTearDown(link.dispose);
      final TunnelSession session = await link.ensure(connectRequest());
      addTearDown(session.close);

      // 站点消费者：先订阅会话事件流，再触发插件推一帧 tunnel/event。
      final Completer<TunnelShellEvent> stationEvent =
          Completer<TunnelShellEvent>();
      session.events.listen((TunnelShellEvent e) {
        if (!stationEvent.isCompleted) stationEvent.complete(e);
      });

      await session.request(
        'ssh.pty.emit',
        <String, dynamic>{},
      ); // 夹具在收到该 method 时主动推一帧 shell.data。

      final TunnelShellEvent station = await stationEvent.future.timeout(
        const Duration(seconds: 10),
      );
      expect(station.connId, session.connId);
      expect(station.kind, 'shell.data');
      expect(utf8.decode(station.data), 'PTY-BYTES');

      final Map<String, dynamic> legacy = await legacyEvent.future.timeout(
        const Duration(seconds: 10),
      );
      expect(
        legacy['conn_id'],
        session.connId,
        reason: '旧字段消费者必须收到同一条 tunnel/event（fan-out，非二选一）',
      );
      expect(legacy['kind'], 'shell.data');
    },
  );

  // ── ② 快照判死：state 回空台账 ⇒ snapshot 如实 down（不假装 ready）──────────
  test(
    'state 回包不含本 conn_id ⇒ snapshot 判 down（撤换缓存的依据）',
    () async {
      final List<String> logs = <String>[];
      final PluginBus bus = await startBus(
        sshExecutePluginYaml(extraFlag: '--ssh-execute-down'),
        logs: logs,
      );
      await waitForSubscription(bus, logs);
      final StationTunnelLink link = StationTunnelLink(bus);
      addTearDown(link.dispose);

      final TunnelSession session = await link.ensure(connectRequest());
      addTearDown(session.close);
      // ensure 仍能建会话（点位在、订阅在）；判死只由快照面决定。
      expect(session.connId, isNotEmpty);

      final TunnelSnapshot snap = await session.snapshot();
      expect(snap.connId, session.connId);
      expect(snap.ready, isFalse, reason: '台账里没有这条 ⇒ 如实判死，不假装 ready');
      expect(snap.state, 'down');
    },
  );
}
