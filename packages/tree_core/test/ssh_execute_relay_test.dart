import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **中转站点位「SSH 执行」**（`system.relay.ssh.execute`，阶段 A 地基）：
///
/// 定位重写后，中转站不只做「数据拦截-回填」，还承接「整块处理工作」——SSH 执行
/// 因此与工具改写同构，共用中转站的四条不变量（fail-open / scope 校验 / 唯一订阅者 /
/// 无静态超时）。这里跑**真插件进程 + 真中转站**（阶段 A 只钉核心侧 API 面，主路径
/// 尚未接线，`relaySshExecute` 目前没有生产调用方）。
///
/// 覆盖语义：
/// - **无订阅者 ⇒ fail-open**：[PluginBus.sshExecuteStationSubscribed] 为 false，
///   [PluginBus.relaySshExecute] 走快路径返回 null（零等待、零中转日志）；
/// - **有订阅者且回包合法 ⇒ 原样透传 Map**（夹具 `--station-echo` 把请求回显成对象）；
/// - **只有 capability 不订站点 ⇒ 仍为 false**（旧插件不被动进入新路径）；
/// - 订阅经**显式点位** `ssh.execute` 命中（`station: 'relay'` 留空只订工具前/后）。
void main() {
  late Directory temp;
  late String script;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String session = 'sess-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_ssh_relay_');
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

  /// 起一条真总线（复刻生产接线：team / mode 按 agent 真实归属）。
  ///
  /// [yaml] = 完整 `plugins.yaml` 内容；[logs] 非空则把核心日志收进来供断言。
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
        agentId == agent ? StationModeKey.local : '';
    await bus.start();
    return bus;
  }

  /// 订阅 `ssh.execute` 点位并回显请求的插件（`--station-echo`：非 phase 请求原样回显成对象）。
  String sshRelayPluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sshrelay\n'
      '    name: SSH 中转插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--relay-subscribe", '
      '"--relay-point", "ssh.execute", "--station-echo"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  /// 等订阅建立（真进程起进程后主动 subscribe 有延迟；失败时带日志可读报错）。
  Future<void> waitForSubscription(
    PluginBus bus,
    String pointId,
    List<String> logs, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final RelayStation? station = bus.stations.relayPointFor(pointId);
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (station != null && station.subscribers.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      station?.subscribers,
      isNotEmpty,
      reason: '插件必须订阅上点位 $pointId；日志：${logs.join(' | ')}',
    );
  }

  // ── ① 无订阅者 ⇒ fail-open（快路径，零中转日志） ─────────────────────────

  test('无订阅者：subscribed=false、relaySshExecute 返回 null 且零中转日志', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      'enabled: true\nplugins: []\n',
      logs: logs,
    );

    expect(
      bus.sshExecuteStationSubscribed(),
      isFalse,
      reason: '没有任何插件订上 ssh.execute ⇒ 核心不该认为有中转站',
    );

    final Map<String, dynamic>? result = await bus.relaySshExecute(
      action: 'ensure',
      agentId: agent,
      sessionId: session,
      payload: <String, dynamic>{'host': 'example.com'},
    );
    expect(result, isNull, reason: '无订阅者必须 fail-open 回退内置');
    expect(
      logs.where((String l) => l.contains('SSH 中转')).toList(),
      isEmpty,
      reason: '无订阅者走快路径，不该产生任何 SSH 中转日志',
    );
  });

  // ── ② 有订阅者且回包合法 ⇒ 原样透传 Map ────────────────────────────────

  test('订阅 ssh.execute 并回显：subscribed=true、relaySshExecute 透传回包对象', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(sshRelayPluginYaml(), logs: logs);
    await waitForSubscription(bus, StationHubIds.relaySshExecute, logs);

    // 点位唯一订阅者（中转站 scopeKeyUnique）：订上了就恰好一个。
    final RelayStation station =
        bus.stations.relayPointFor(StationHubIds.relaySshExecute)!;
    expect(station.subscribers, hasLength(1));
    expect(station.subscribers.single.pluginId, 'sshrelay');
    expect(
      bus.sshExecuteStationSubscribed(),
      isTrue,
      reason: '订上站点 ⇒ 核心选路应认「有中转站」',
    );

    final Map<String, dynamic>? result = await bus.relaySshExecute(
      action: 'ensure',
      agentId: agent,
      sessionId: session,
      payload: <String, dynamic>{'host': 'example.com', 'username': 'open'},
    );
    expect(result, isNotNull, reason: '合法回包必须原样透传：${logs.join(' | ')}');
    // 夹具 --station-echo 把请求回显成 {echo, station_id, kind, meta}
    expect(
      result!['station_id'],
      StationHubIds.relaySshExecute,
      reason: '回包要能证明投递到了正确的点位',
    );
    final Map<String, dynamic> echoed =
        (result['echo'] as Map).map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    expect(echoed['action'], 'ensure', reason: 'action 必须随请求投递给插件');
    expect(echoed['host'], 'example.com', reason: 'payload 字段原样并入投递报文');
  });

  // ── ③ 只有 capability、不订站点 ⇒ 仍不进入新路径 ────────────────────────

  test('旧插件只报 capability 不订站点：subscribed 仍为 false（不被动吸入新路径）', () async {
    final List<String> logs = <String>[];
    // 假插件不带 --relay-subscribe：起进程、报能力，但不订阅任何中转站点位。
    final PluginBus bus = await startBus(
      'enabled: true\n'
      'plugins:\n'
      '  - id: legacy\n'
      '    name: 旧 SSH 插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n',
      logs: logs,
    );
    // 给进程一点起来握手的时间，再断言它没订上（避免时序假阴性）。
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(
      bus.sshExecuteStationSubscribed(),
      isFalse,
      reason: '只报能力不订站点 ⇒ 新选路信号必须为 false（旧行为走 tunnel.*）',
    );
    expect(
      bus.stations.relayPointFor(StationHubIds.relaySshExecute)!.subscribers,
      isEmpty,
    );
  });
}
