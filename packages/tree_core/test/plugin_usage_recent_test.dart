import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **压缩载荷里捎给插件的「最近用量行」**（`usage_file` + `recent_usage`）。
///
/// 为什么需要这条路：逐调用账本在**数据根**下的会话目录里
/// （`data/<agent>/<session>/usage.jsonl`），而插件（`fs.read` 只在工作空间作用域内）
/// **读不到数据根**——于是"这次压缩花了多少 token""内置兜底那次花了多少"在插件面板上
/// 永远是空白。核心是唯一同时够得到账本与插件的地方，所以在压缩中转 payload 里捎上
/// 最近 N 行（`PluginBus.usageRecentProvider` 接线注入）。
///
/// 这里跑的是**真插件进程 + 真站点中枢**，取证口是夹具的 `--compact-log`（它把收到的
/// 每个 `context.compact` 请求的**完整 params** 逐行落盘）——不是"进程内假订阅者"，
/// 因为要证明的正是"线上真的发出去了"。
///
/// 钉住四条契约：
/// 1. **接了 provider** ⇒ payload 带 `usage_file`（排障路径）+ `recent_usage`
///    （解析后的行对象，形状 = `usage.jsonl` 的行 = `UsageCall.toJson()`）；
/// 2. **条数有上限**（[PluginBus.maxRecentUsageLines]，取**最后** N 行 = 最近的那些）；
/// 3. **未接线 / provider 抛异常 / 返回 null** ⇒ 两个键都不出现，且**压缩照常**
///    （用量是遥测，fail-open）；
/// 4. **生产接线真的接上了**：`CoreServer.start(usageLog: …)` 之后，账本里落盘的行
///    一路走到 `bus.usageRecentProvider` 的返回值里（`TreePaths.usageFile` +
///    `UsageLog.read` + `UsageCall.toJson` 三点对齐）。
void main() {
  late Directory temp;
  late String script;
  late int busSeq;
  late List<PluginBus> buses;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String session = 'sess-1';
  const String compactPoint = StationHubIds.relayContextCompact;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_usage_recent_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_llm_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假 LLM 插件脚本必须存在');
    busSeq = 0;
    buses = <PluginBus>[];
  });

  tearDown(() async {
    for (final PluginBus bus in buses) {
      await bus.close();
    }
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上插件进程可能还没松开文件句柄，稍后重试
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  /// 起一条真总线 + 一个订阅了压缩点位、并把载荷落盘的假插件。
  ///
  /// `--compact-mode list`：回一份**合法**的接管结果（这样 [PluginBus.relayCompaction]
  /// 会走完正常路径返回非 null；用药量相关的用例不该顺手验别的失败分支）。
  Future<PluginBus> startBus(String compactLog, List<String> logs) async {
    final String dir = p.join(temp.path, 'bus-${++busSeq}');
    final File file = File(p.join(dir, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    final List<String> argv = <String>[
      script,
      '--subscribe-point',
      compactPoint,
      '--compact-mode',
      'list',
      '--compact-log',
      compactLog,
    ];
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: probe\n'
      '    name: 载荷取证插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argv.map((String a) => '"${slash(a)}"').join(', ')}]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n',
    );
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      missThreshold: 3,
      log: logs.add,
    );
    buses.add(bus);
    // 复刻生产接线（CoreServer._wirePluginStations）：team / mode 按 agent 真实归属。
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

  /// 等插件把点位订阅建立起来（真进程：起进程 → 主动 subscribe 有延迟）。
  Future<void> waitForSubscription(PluginBus bus, List<String> logs) async {
    final RelayStation? station = bus.stations.relayPointFor(compactPoint);
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (station != null && station.subscribers.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      station?.subscribers,
      isNotEmpty,
      reason:
          '插件必须订上 $compactPoint；日志：${logs.join(' | ')}；'
          '插件 stderr：'
          '${bus.instances().map((({String pluginId, PluginHost host}) i) => '${i.pluginId}: ${i.host.stderrTail}').join(' /// ')}',
    );
  }

  /// 读插件落盘的**最后一个** `context.compact` 载荷（`params.payload`）。
  ///
  /// 轮询是必要的：插件是另起进程，落盘与"核心收到回包"之间没有顺序保证。
  Future<Map<String, dynamic>> lastPayload(String compactLog) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final File file = File(compactLog);
      if (file.existsSync()) {
        final List<String> lines = file
            .readAsLinesSync()
            .where((String line) => line.trim().isNotEmpty)
            .toList();
        if (lines.isNotEmpty) {
          final Map<String, dynamic> params =
              jsonDecode(lines.last) as Map<String, dynamic>;
          return params['payload'] as Map<String, dynamic>;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('插件没落盘 context.compact 载荷：$compactLog');
  }

  /// `usage.jsonl` 的一行（形状 = `UsageCall.toJson()`；序号替代时间，便于断言顺序）。
  Map<String, dynamic> usageLine(int index, {String source = 'compact'}) =>
      <String, dynamic>{
        'at': '2026-10-03T16:31:${(index % 60).toString().padLeft(2, '0')}.000000',
        'source': source,
        'model': 'demo-model',
        'prompt_tokens': index,
        'cached_tokens': index % 3 == 0 ? null : index,
        'completion_tokens': index * 2,
        'estimated': index % 2 == 0,
        'duration_ms': 100 + index,
      };

  Future<CompactionRelayReply?> compactOnce(PluginBus bus) => bus.relayCompaction(
    agent: CoreAgent(id: agent, name: '甲', createdAt: 1, updatedAt: 1),
    session: CoreSession(
      sessionId: session,
      agentId: agent,
      title: '会话',
      createdAt: 1,
      updatedAt: 1,
      compactedMessageCount: 1,
      compactedSummary: '旧的摘要正文',
    ),
    systemPrompt: '内置拼装的系统提示词',
    totalMessageCount: 4,
    compactedMessageCount: 1,
    existingSummary: '旧的摘要正文',
    wireRequest: <String, dynamic>{
      'model': 'demo-model',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': '引擎的提示词'},
        <String, dynamic>{'role': 'user', 'content': '引擎看到的历史'},
      ],
    },
  );

  test('接了 provider ⇒ payload 带 usage_file + recent_usage（形状 = usage.jsonl 的行）', () async {
    final String compactLog = p.join(temp.path, 'compact-payload.jsonl');
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(compactLog, logs);
    await waitForSubscription(bus, logs);

    final List<String> asked = <String>[];
    final Map<String, dynamic> line = usageLine(3, source: 'llm.call');
    bus.usageRecentProvider = (String agentId, String sessionId) async {
      asked.add('$agentId/$sessionId');
      return PluginUsageRecent(
        path: p.join(temp.path, 'data', agentId, sessionId, 'usage.jsonl'),
        calls: <Map<String, dynamic>>[line],
      );
    };

    final CompactionRelayReply? reply = await compactOnce(bus);
    expect(reply, isNotNull, reason: '插件回了合法结果，压缩照常接管');

    // provider 必须拿到**这次压缩**的 agent / 会话：账本是按会话分文件的，
    // 拿错会话就等于把别人的账贴到这个面板上。
    expect(asked, <String>['$agent/$session']);

    final Map<String, dynamic> payload = await lastPayload(compactLog);
    final String usagePath = '${payload['usage_file']}'.replaceAll('\\', '/');
    expect(
      usagePath,
      contains('usage.jsonl'),
      reason: '账本路径随载荷发出去（只作排障：插件读不到数据根）',
    );
    expect(
      usagePath,
      contains('$agent/$session'),
      reason: '路径必须是这次压缩那个会话的账本',
    );
    final Object? recent = payload['recent_usage'];
    expect(recent, isA<List<dynamic>>());
    expect(
      (recent! as List<dynamic>).single,
      line,
      reason: '原样透传（形状 = UsageCall.toJson()，别在核心侧另拼一份键）',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('条数上限：provider 给 80 行也只发最近 50 行（掐头不掐尾）', () async {
    final String compactLog = p.join(temp.path, 'compact-payload.jsonl');
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(compactLog, logs);
    await waitForSubscription(bus, logs);
    bus.usageRecentProvider = (String agentId, String sessionId) async =>
        PluginUsageRecent(
          path: 'unused/usage.jsonl',
          calls: <Map<String, dynamic>>[
            for (int i = 0; i < 80; i++) usageLine(i),
          ],
        );

    expect(await compactOnce(bus), isNotNull);
    final Map<String, dynamic> payload = await lastPayload(compactLog);
    final List<dynamic> recent = payload['recent_usage'] as List<dynamic>;
    expect(
      recent,
      hasLength(PluginBus.maxRecentUsageLines),
      reason: '账本会随会话一直长：压缩载荷必须是有界的',
    );
    expect(
      (recent.first as Map<String, dynamic>)['prompt_tokens'],
      30,
      reason: '掐掉最旧的 30 行（留最后 50 = 最近的那些）',
    );
    expect(
      (recent.last as Map<String, dynamic>)['prompt_tokens'],
      79,
      reason: '最新的那行必须在（顺序为早 → 晚）',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('未接线 ⇒ 两个键都不出现（与"确实没有用量"区分开）', () async {
    final String compactLog = p.join(temp.path, 'compact-payload.jsonl');
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(compactLog, logs);
    await waitForSubscription(bus, logs);
    // 故意**不**接 usageRecentProvider：老核心 / 没配 UsageLog 的部署就是这个形态
    expect(bus.usageRecentProvider, isNull);

    expect(await compactOnce(bus), isNotNull, reason: '没有用量照样压缩');
    final Map<String, dynamic> payload = await lastPayload(compactLog);
    expect(
      payload.containsKey('usage_file'),
      isFalse,
      reason: '未接线 ⇒ 不带这个键（插件据此知道"这条通路没有"，而不是"没有用量"）',
    );
    expect(payload.containsKey('recent_usage'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('provider 抛异常 / 返回 null ⇒ 不带键、压缩照常（fail-open）', () async {
    final String compactLog = p.join(temp.path, 'compact-payload.jsonl');
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(compactLog, logs);
    await waitForSubscription(bus, logs);

    bus.usageRecentProvider = (String agentId, String sessionId) async =>
        throw StateError('账本读崩了');
    expect(
      await compactOnce(bus),
      isNotNull,
      reason: '用量是遥测：它出问题绝不该影响一次压缩（fail-open）',
    );
    Map<String, dynamic> payload = await lastPayload(compactLog);
    expect(payload.containsKey('recent_usage'), isFalse);
    expect(
      logs.any((String line) => line.contains('读取最近用量行失败')),
      isTrue,
      reason: '失败要留一句可读日志（否则"面板没有用量"又成了靠猜）',
    );

    bus.usageRecentProvider = (String agentId, String sessionId) async => null;
    expect(await compactOnce(bus), isNotNull);
    payload = await lastPayload(compactLog);
    expect(payload.containsKey('usage_file'), isFalse);
    expect(payload.containsKey('recent_usage'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('生产接线：CoreServer 把 provider 接到真实账本（路径 / 读尾部 / 行形状）', () async {
    final PluginBus bus = PluginBus(
      configFile: p.join(temp.path, 'wire', 'config', 'plugins.yaml'),
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    buses.add(bus);
    final TreePaths paths = TreePaths(p.join(temp.path, 'data-root'));
    final UsageLog ledger = UsageLog(paths);
    final CoreServer server = await CoreServer.start(
      pluginBus: bus,
      usageLog: ledger,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    addTearDown(server.close);
    expect(
      bus.usageRecentProvider,
      isNotNull,
      reason: '接线点就是 _wirePluginRelayPoints：不接上，插件面板永远没有用量',
    );

    // 走**生产同一条落盘路径**记两笔（内置压缩 + llm.call），读回来时必须逐字对得上
    ledger.record(
      agent,
      session,
      UsageCall(
        at: DateTime(2026, 10, 3, 16, 31, 55),
        source: UsageSource.compact,
        model: 'demo-model',
        promptTokens: 1200,
        cachedTokens: 900,
        completionTokens: 120,
        durationMs: 1800,
      ),
    );
    ledger.record(
      agent,
      session,
      UsageCall(
        at: DateTime(2026, 10, 3, 16, 38, 2),
        source: UsageSource.llmCall,
        model: 'demo-model',
        promptTokens: 800,
        completionTokens: 60,
        estimated: true,
        durationMs: 700,
      ),
    );
    await ledger.flush();

    final PluginUsageRecent? recent =
        await bus.usageRecentProvider!(agent, session);
    expect(recent, isNotNull);
    expect(
      recent!.path,
      paths.usageFile(agent, session),
      reason: '路径必须是 TreePaths.usageFile（插件拿去排障时要对得上）',
    );
    expect(recent.calls, hasLength(2));
    expect(
      recent.calls.map((Map<String, dynamic> c) => c['source']).toList(),
      <String>['compact', 'llm.call'],
      reason: '早 → 晚；来源就是 usage.jsonl 的口径（插件面板照它映射 builtin/llm.call）',
    );
    expect(recent.calls.first['at'], contains('2026-10-03T16:31:55'));
    expect(recent.calls.first['prompt_tokens'], 1200);
    expect(recent.calls.first['cached_tokens'], 900);
    expect(recent.calls.first['completion_tokens'], 120);
    expect(recent.calls.first['estimated'], isFalse);
    expect(recent.calls.first['duration_ms'], 1800);
    expect(
      recent.calls.last['cached_tokens'],
      isNull,
      reason: '端点没给就是 null（不编造 0——面板据此不显示"缓存 0"）',
    );
    expect(recent.calls.last['estimated'], isTrue);

    // 账本还不存在的会话 ⇒ 空列表（不是错误：老会话本来就没有这份文件）
    final PluginUsageRecent? missing =
        await bus.usageRecentProvider!('agt_nobody', 'sess_none');
    expect(missing, isNotNull);
    expect(missing!.calls, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
