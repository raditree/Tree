import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **中转站 LLM 四个点位 + `station/stream` 流式回填**（点位化，2026-10-01）。
///
/// 这里跑的是**真插件进程 + 真站点中枢 + 真 stdio 通道**，而不是进程内假订阅者：
/// 流式接管的整条数据面是
/// `插件 stdout → PluginHost._onLine → _onNotification → PluginBus._emitPluginEvent
///  → _handleStationStream`，
/// 只有真进程才能覆盖（进程内订阅者根本没有这条链路）。
///
/// 覆盖语义（全部来自 `docs/plugin-development.md` §5）：
/// - **一次性接管**：OpenAI 兼容响应 / 裸 message ⇒ 展开成与流式同一套事件；
/// - **流式接管**：`{stream:true}` 回包 + `station/stream` 增量 + `done` 收尾；
/// - **三条收尾路径**：done/error、用户取消（下发 `station/cancel`）、心跳丢失/进程退出；
/// - **fail-open 红线**：无订阅者 / 未接线 / 回包非法 ⇒ 一律返回 null（原路径）；
/// - 归属校验：只有打开这条流的插件能往里推。
///
/// 每个用例都有超时保护（`_Probe` 内部计时器 + `test` 的 timeout），绝不永久挂住。
void main() {
  late Directory temp;
  late String script;
  late int busSeq;
  late List<PluginBus> buses;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String session = 'sess-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_llm_relay_');
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
        // Windows 上文件句柄可能还没释放，稍后重试
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  /// 一条插件配置项（args 必须是简单值：路径统一用 `/`，YAML 里再逐项加引号）。
  ///
  /// argv = `[夹具脚本, ...flags]`（`command` 是 dart 可执行文件本身）。
  String pluginEntry({
    required String id,
    required List<String> flags,
    String scopeTeam = team,
  }) =>
      '  - id: $id\n'
      '    name: 假 LLM 插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${<String>[script, ...flags].map((String f) => '"${slash(f)}"').join(', ')}]\n'
      '    granularity: team\n'
      '    scope: {team_id: $scopeTeam}\n';

  /// 起一条真总线（[entries] = `pluginEntry(...)` 的列表）。
  ///
  /// 每个用例/每次调用用**独立的配置目录**——否则第二条总线会从同一个
  /// stations.yaml 恢复出上一条留下的订阅（订阅者已不在），相互串台。
  Future<PluginBus> startBus(
    List<String> entries, {
    bool enabled = true,
    List<String> logs = const <String>[],
    Duration heartbeat = const Duration(seconds: 30),
    int missThreshold = 3,
    String stationsYaml = '',
  }) async {
    final String dir = p.join(temp.path, 'bus-${++busSeq}');
    final File file = File(p.join(dir, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(
      entries.isEmpty
          ? 'enabled: $enabled\nplugins: []\n'
          : 'enabled: $enabled\nplugins:\n${entries.join()}',
    );
    if (stationsYaml.isNotEmpty) {
      // 预置站点存储（用非中转站占住某个点位 id，验证"点位不可用 ⇒ 不接管"）
      File(StationStore.pathFor(file.path)).writeAsStringSync(stationsYaml);
    }
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: heartbeat,
      missThreshold: missThreshold,
      // 始终接线日志：失败时 reason 里要能看到"插件为什么没起来"
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

  /// 等插件把订阅建立起来（真进程：起进程 → 主动 subscribe 有延迟）。
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
      reason:
          '插件必须订阅上点位 $pointId；日志：${logs.join(' | ')}；'
          '插件 stderr：'
          '${bus.instances().map((({String pluginId, PluginHost host}) i) => '${i.pluginId}: ${i.host.stderrTail}').join(' /// ')}',
    );
  }

  /// 轮询等一个条件成立（有上限：绝不永久挂住）。
  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
    String description = '条件',
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    fail('等待「$description」超时（${timeout.inMilliseconds}ms）');
  }

  LlmRequest request({String model = 'demo-model', String user = '你好'}) =>
      LlmRequest(model: model, messages: <LlmMessage>[LlmMessage.user(user)]);

  Future<Stream<LlmStreamEvent>?> relay(
    PluginBus bus, {
    int turn = 1,
    bool Function()? isCancelled,
    String agentId = agent,
    String sessionId = session,
  }) => bus.relayLlmHandle(
    request: request(),
    agentId: agentId,
    sessionId: sessionId,
    turn: turn,
    isCancelled: isCancelled ?? () => false,
  );

  // ── ① 一次性接管 ─────────────────────────────────────────────────────

  test(
    '①一次性接管：裸 message 展开成 text / thinking / tool_call / usage / finish 事件',
    () async {
      final List<String> logs = <String>[];
      final PluginBus bus = await startBus(<String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayLlmHandle,
            '--llm-mode',
            'once',
          ],
        ),
      ], logs: logs);
      await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

      final Stream<LlmStreamEvent>? stream = await relay(bus);
      expect(stream, isNotNull, reason: '插件回了一次性接管报文，核心必须返回事件流（不再调系统 LLM）');
      final List<LlmStreamEvent> events = await stream!
          .timeout(const Duration(seconds: 10))
          .toList();

      expect(
        events.whereType<LlmTextDelta>().single.text,
        '插件一次性接管',
        reason: 'content 必须变成正文增量',
      );
      expect(
        events.whereType<LlmThinkingDelta>().single.text,
        '先想想',
        reason: 'reasoning_content 必须变成思考增量（与流式同一套事件）',
      );
      final LlmToolCallDelta call = events.whereType<LlmToolCallDelta>().single;
      expect(call.id, 'call_once');
      expect(call.name, 'read');
      expect(call.argumentsDelta, '{"path":"a.txt"}');
      final LlmUsageEvent usage = events.whereType<LlmUsageEvent>().single;
      expect(usage.usage.promptTokens, 11);
      expect(usage.usage.completionTokens, 4);
      expect(
        usage.usage.totalTokens,
        15,
        reason: '端点没给 total 时按 prompt+completion 兜底',
      );
      expect(events.last, isA<LlmFinishEvent>());
      expect((events.last as LlmFinishEvent).reason, 'stop');
      expect(bus.openLlmStreams, 0, reason: '一次性接管不建长流');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('①b 一次性接管：OpenAI 非流式响应（choices[0].message）也认', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'once-openai',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull, reason: 'OpenAI 形状的响应必须被认出来（协议明确接受）');
    final List<LlmStreamEvent> events = await stream!
        .timeout(const Duration(seconds: 10))
        .toList();
    expect(events.whereType<LlmTextDelta>().single.text, 'OpenAI 形状接管');
    expect(events.whereType<LlmToolCallDelta>().single.name, 'write');
    expect(events.whereType<LlmUsageEvent>().single.usage.promptTokens, 3);
    expect(events.whereType<LlmFinishEvent>().single.reason, 'stop');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── ② 流式接管 ───────────────────────────────────────────────────────

  test('②流式接管：增量按顺序产出、done 正常收尾（紧凑写法 + OpenAI 分片写法）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'stream',
          '--stream-delay-ms',
          '30',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull, reason: '插件回了 {stream:true}，核心必须返回一条由通知喂数据的流');
    expect(bus.openLlmStreams, 1, reason: '流式接管在途时总线要持有这条流');

    final List<LlmStreamEvent> events = await stream!
        .timeout(const Duration(seconds: 15))
        .toList();

    // 顺序也是语义的一部分：界面按到达顺序渲染，乱序等于输出错乱
    final List<String> labels = events
        .map(
          (LlmStreamEvent e) => switch (e) {
            LlmTextDelta(:final String text) => 'text:$text',
            LlmThinkingDelta(:final String text) => 'thinking:$text',
            LlmToolCallDelta(:final String? name, :final String? id) =>
              'tool:${id ?? '-'}:${name ?? '-'}',
            LlmUsageEvent(:final LlmUsage usage) =>
              'usage:${usage.promptTokens}/${usage.completionTokens}',
            LlmFinishEvent(:final String reason) => 'finish:$reason',
            LlmFailureEvent(:final String message) => 'failure:$message',
          },
        )
        .toList();
    expect(labels, <String>[
      'text:流式1',
      'thinking:先看文件',
      'tool:call_s1:read',
      'tool:-:-',
      'text:流式尾',
      'usage:7/3',
      'finish:stop',
    ], reason: '紧凑写法与 OpenAI 分片写法必须产出同一套事件，且顺序不乱');

    // 分片拼起来就是完整参数（工具循环按 index 拼接，这是它依赖的口径）
    final String arguments = events
        .whereType<LlmToolCallDelta>()
        .map((LlmToolCallDelta d) => d.argumentsDelta)
        .join();
    expect(arguments, '{"path":"a.txt"}');
    expect(bus.openLlmStreams, 0, reason: 'done 之后流必须收尾（不能留着占 request_id）');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('②b 流式 error 收尾：以失败事件结束（不抛、不挂）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'stream-error',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull);
    final List<LlmStreamEvent> events = await stream!
        .timeout(const Duration(seconds: 15))
        .toList();
    expect(events.whereType<LlmTextDelta>().single.text, '半截');
    final LlmFailureEvent failure = events.whereType<LlmFailureEvent>().single;
    expect(failure.message, contains('上游 500'));
    expect(failure.cancelled, isFalse, reason: 'error 收尾不是"用户取消"');
    expect(bus.openLlmStreams, 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── ③ 取消 ───────────────────────────────────────────────────────────

  test(
    '③取消：isCancelled 变真 ⇒ 失败事件 cancelled:true，且插件确实收到 station/cancel',
    () async {
      final List<String> logs = <String>[];
      final String recordFile = p.join(temp.path, 'notify.jsonl');
      final PluginBus bus = await startBus(<String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayLlmHandle,
            '--llm-mode',
            'silent',
            '--record',
            recordFile,
            '--late-delta-after-cancel',
          ],
        ),
      ], logs: logs);
      await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

      bool cancelled = false;
      final Stream<LlmStreamEvent>? stream = await relay(
        bus,
        isCancelled: () => cancelled,
      );
      expect(
        stream,
        isNotNull,
        reason: 'silent 模式也回了 {stream:true}，所以这条流是插件接管的',
      );
      final _Probe probe = _Probe(stream!);
      await waitUntil(
        () => bus.openLlmStreams == 1,
        timeout: const Duration(seconds: 5),
        description: '插件接管流打开',
      );

      cancelled = true;
      await probe.finished.timeout(const Duration(seconds: 15));

      expect(probe.events, hasLength(1), reason: 'silent 模式没有增量，只有收尾那一条失败事件');
      final LlmFailureEvent failure = probe.events.single as LlmFailureEvent;
      expect(
        failure.cancelled,
        isTrue,
        reason: '取消不算错误，UI 不应报错（cancelled 必须为真）',
      );
      expect(failure.message, contains('取消'));
      expect(bus.openLlmStreams, 0, reason: '取消后流必须收尾并摘掉 request_id');

      // 核心确实向**插件**下发了 station/cancel（下行通知，带同一个 request_id）
      await waitUntil(
        () => File(recordFile).existsSync(),
        description: '插件收到 station/cancel 并落记录',
      );
      final List<Map<String, dynamic>> recorded = File(recordFile)
          .readAsLinesSync()
          .where((String l) => l.trim().isNotEmpty)
          .map((String l) => jsonDecode(l) as Map<String, dynamic>)
          .toList(growable: false);
      final String? openId = _requestIdFromLogs(logs);
      expect(
        openId,
        isNotNull,
        reason: '日志里应有"流式接管"那一条（含 request_id）：${logs.join(' | ')}',
      );
      final Map<String, dynamic> cancel = recorded.singleWhere(
        (Map<String, dynamic> n) => n['method'] == 'station/cancel',
        orElse: () => fail('插件必须收到 station/cancel；实收：$recorded'),
      );
      final Map<String, dynamic> cancelParams =
          (cancel['params'] as Map<dynamic, dynamic>).map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          );
      expect(
        cancelParams['request_id'],
        openId,
        reason: '取消必须带**同一个** request_id，插件才认得出该停哪条流',
      );
      expect('${cancelParams['reason']}', contains('停止'), reason: '可读原因要一起下发');

      // 取消后到达的增量一律丢弃（夹具收到 cancel 后会故意再推一条 LATE）：
      // 流已收尾，总线里也没有这条流的记录，迟到增量只能被丢弃。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        probe.events.whereType<LlmTextDelta>().map((LlmTextDelta d) => d.text),
        isNot(contains('LATE')),
        reason: '取消后到达的 delta 不得再进流',
      );
      expect(
        logs.where((String l) => l.contains('已丢弃')).length,
        greaterThanOrEqualTo(1),
        reason: '迟到增量应被丢弃并记可读日志；实际日志：${logs.join(' | ')}',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // ── ④ 心跳丢失 / 进程退出 ────────────────────────────────────────────

  test('④插件进程退出 ⇒ 接管流以失败收尾（不永久等）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'exit-after-stream',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull, reason: '插件先回 {stream:true} 再退出：核心仍应认出接管并建流');
    final List<LlmStreamEvent> events = await stream!
        .timeout(const Duration(seconds: 15))
        .toList();
    final LlmFailureEvent failure = events.whereType<LlmFailureEvent>().single;
    expect(failure.message, contains('心跳丢失'), reason: failure.message);
    expect(
      failure.message,
      contains('插件进程已退出'),
      reason: '判死原因必须可读（"进程已退出"与"连续未达"是两回事）',
    );
    expect(failure.cancelled, isFalse);
    expect(bus.openLlmStreams, 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('④b心跳连续丢失 ⇒ 接管流以失败收尾（判活口径，不是静态总超时）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      <String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayLlmHandle,
            '--llm-mode',
            'silent',
            '--ignore-ping',
          ],
        ),
      ],
      logs: logs,
      heartbeat: const Duration(milliseconds: 150),
      missThreshold: 3,
    );
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull);
    final _Probe probe = _Probe(stream!);
    await waitUntil(() => bus.openLlmStreams == 1, description: '插件接管流打开');

    // 三拍未回 ping ⇒ degraded：显式跑三拍比依赖后台看门狗更确定
    for (int i = 0; i < 3; i++) {
      await bus.watchdog();
    }
    expect(
      bus.healthOf('llm')['degraded'],
      isTrue,
      reason: '连续 3 拍没有心跳证据 ⇒ degraded（只标健康度、不杀进程）',
    );
    await probe.finished.timeout(const Duration(seconds: 15));
    final LlmFailureEvent failure = probe.events
        .whereType<LlmFailureEvent>()
        .single;
    expect(failure.message, contains('心跳丢失'), reason: failure.message);
    expect(failure.cancelled, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── ⑤ 无订阅者 / 未接线 ⇒ null（快路径） ─────────────────────────────

  test('⑤无订阅者 ⇒ 返回 null 且零等待（不发起站点往返）', () async {
    final List<String> logs = <String>[];
    // 插件在跑，但**没订**这个点位：走"无订阅者"快路径
    final PluginBus bus = await startBus(<String>[
      pluginEntry(id: 'llm', flags: <String>['--llm-mode', 'once']),
    ], logs: logs);
    expect(bus.instances(), hasLength(1), reason: '插件必须真的起来了（否则测的是"没插件"）');

    final Stopwatch watch = Stopwatch()..start();
    final Stream<LlmStreamEvent>? stream = await relay(bus);
    watch.stop();
    expect(stream, isNull, reason: '没人订阅 = 不接管，调用方走系统 LLM');
    expect(
      watch.elapsedMilliseconds,
      lessThan(500),
      reason: '无订阅者必须零等待（实测 ${watch.elapsedMilliseconds}ms）',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑤b未接线（总开关关 / 无法证明归属）⇒ 返回 null 且零等待', () async {
    final List<String> logs = <String>[];
    // ① 总开关关闭：插件系统整体不启用
    final PluginBus disabled = await startBus(
      <String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayLlmHandle,
            '--llm-mode',
            'once',
          ],
        ),
      ],
      enabled: false,
      logs: logs,
    );
    expect(disabled.instances(), isEmpty, reason: '总开关关闭时不启动任何插件');
    expect(await relay(disabled), isNull);

    // ② 调用点无法证明归属（agent 没有 team）：站点消息 fail-closed，直接不投
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'stream',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);
    final Stopwatch watch = Stopwatch()..start();
    final Stream<LlmStreamEvent>? stream = await relay(bus, agentId: 'ghost');
    watch.stop();
    expect(stream, isNull, reason: 'scope 证明不了归属 ⇒ 不投递（fail-closed）');
    expect(
      watch.elapsedMilliseconds,
      lessThan(500),
      reason: '归属证明不了时必须零等待，不能去问插件（实测 ${watch.elapsedMilliseconds}ms）',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑤c内置点位被别的类型占用 ⇒ 按点位表纠正（不静默失效）', () async {
    // 站点存储里预置一个**广播站**占用 `system.relay.llm.handle` 这个 id
    //（手改文件 / 旧文件残留 / 半截写入都可能造成）。
    //
    // 语义（2026-10-01 定稿）：**内置 id 的类型由点位表唯一决定**。若不纠正，就会
    // 出现"点位静默失效 + 插件订阅假成功"的双重静默——`relayPointFor` 返回 null
    // 让四个 LLM 中转点位全部回退系统默认，而插件用 `station_id` 订阅它还能拿到
    // `ok:true`（广播站可订阅）却永远收不到请求。所以 load() 必须**按表重建**并
    // 记可读日志、把纠正结果写回盘上（此后幂等）。
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      <String>[],
      logs: logs,
      stationsYaml:
          'version: 1\n'
          'stations:\n'
          '  - id: ${StationHubIds.relayLlmHandle}\n'
          '    kind: broadcast\n'
          '    description: 占位（同 id 但不是中转站）\n'
          '    max_subscriptions: 32\n'
          '    builtin: true\n'
          '    created_at: 1\n'
          '    subscribers:\n'
          '      - {plugin_id: stale, scope: {team_id: $team}, subscribed_at: 2}\n',
    );
    expect(
      bus.stations.station(StationHubIds.relayLlmHandle),
      isA<RelayStation>(),
      reason: '内置点位 id 的类型以点位表为准：广播站要被重建成中转站',
    );
    expect(
      bus.stations.station(StationHubIds.relayLlmHandle)!.kind,
      StationKind.relay,
    );
    expect(
      bus.stations.relayPointFor(StationHubIds.relayLlmHandle),
      isNotNull,
      reason: '纠正后该点位必须真的可用（否则四个 LLM 中转点位会静默回退）',
    );
    // 原有订阅尽力保留（该点位只允许一个订阅者，这里恰好一条）
    expect(
      bus.stations
          .station(StationHubIds.relayLlmHandle)!
          .subscribers
          .map((StationSubscriber s) => s.pluginId),
      <String>['stale'],
      reason: '落盘订阅不该在类型纠正时被静默丢掉',
    );
    expect(
      logs.any(
        (String l) =>
            l.contains(StationHubIds.relayLlmHandle) && l.contains('与点位表'),
      ),
      isTrue,
      reason: '纠正是"异常但可自愈"的事件，必须留下可读线索；实收日志：$logs',
    );
    // 保留的订阅没有回包通道（插件不在跑）⇒ 这一次仍不接管，但要给出可读原因
    expect(
      await relay(bus),
      isNull,
      reason: '订阅者没有回包通道 ⇒ fail-open 到系统 LLM（不能抛、不能挂）',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── ⑥ relayLlmRequest：投入 LLM 前改写 ──────────────────────────────

  test('⑥relayLlmRequest：插件改写后的报文生效（model / messages / extra 透传）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmRequest,
          '--llm-request-mode',
          'rewrite',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmRequest, logs);

    final LlmRequest? rewritten = await bus.relayLlmRequest(
      request: request(),
      agentId: agent,
      sessionId: session,
      turn: 2,
    );
    expect(rewritten, isNotNull, reason: '插件给了合法改写，核心必须采用');
    expect(rewritten!.model, 'plugin-model');
    expect(rewritten.messages, hasLength(1), reason: 'messages 是整体替换');
    expect(rewritten.messages.single.role, LlmRole.user);
    expect(rewritten.messages.single.content, '插件改写后的输入');
    expect(rewritten.temperature, 0.25);
    expect(rewritten.extra['response_format'], <String, dynamic>{
      'type': 'json_object',
    }, reason: '未识别字段必须透传（静默丢弃会变成最难查的一类问题）');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑥b回包非法 ⇒ 返回 null（放行原请求，fail-open）', () async {
    final List<String> logs = <String>[];
    for (final String mode in <String>['invalid', 'invalid-messages']) {
      final PluginBus bus = await startBus(<String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayLlmRequest,
            '--llm-request-mode',
            mode,
          ],
        ),
      ], logs: logs);
      await waitForSubscription(bus, StationHubIds.relayLlmRequest, logs);
      expect(
        await bus.relayLlmRequest(
          request: request(),
          agentId: agent,
          sessionId: session,
          turn: 3,
        ),
        isNull,
        reason: '回包重建不出请求（$mode）⇒ 必须放行原请求',
      );
    }
    // 无订阅者时同样放行（快路径）
    final PluginBus idle = await startBus(<String>[]);
    expect(
      await idle.relayLlmRequest(
        request: request(),
        agentId: agent,
        sessionId: session,
        turn: 3,
      ),
      isNull,
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ── ⑦ relayCompaction / relaySystemPrompt ───────────────────────────

  test('⑦relayCompaction：插件接管 ⇒ 拿到摘要正文；回 null ⇒ 回退内置摘要器', () async {
    final CoreAgent coreAgent = CoreAgent(
      id: agent,
      name: '甲',
      createdAt: 1,
      updatedAt: 1,
    );
    final CoreSession coreSession = CoreSession(
      sessionId: session,
      agentId: agent,
      title: '会话',
      createdAt: 1,
      updatedAt: 1,
    );

    for (final (String mode, String? expected) in <(String, String?)>[
      ('text', '插件摘要'),
      ('map', '插件摘要（map）'),
      ('', null),
    ]) {
      final List<String> logs = <String>[];
      final PluginBus bus = await startBus(<String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayContextCompact,
            if (mode.isNotEmpty) ...<String>['--compact-mode', mode],
          ],
        ),
      ], logs: logs);
      await waitForSubscription(bus, StationHubIds.relayContextCompact, logs);
      final String? summary = await bus.relayCompaction(
        agent: coreAgent,
        session: coreSession,
        prompt: '请压缩',
        messages: <CoreMessage>[
          CoreMessage(
            id: 'm1',
            agentId: agent,
            sessionId: session,
            role: 'user',
            content: '你好',
            timestamp: 1,
          ),
        ],
        instruction: '保留要点',
        header: '【历史摘要】',
      );
      expect(
        summary,
        expected,
        reason: mode.isEmpty
            ? '插件回 null = 不接管，调用方回退内置摘要器'
            : '回包形态 $mode 都必须被认出来',
      );
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('⑦b relaySystemPrompt：字符串接管 / 空串 = 明确不要系统提示词 / null = 不改', () async {
    const AgentRunContext context = AgentRunContext(
      agentId: agent,
      sessionId: session,
      systemPrompt: '内置提示词',
      userContent: '你好',
      history: <CoreMessageRef>[],
    );

    for (final (String mode, String? expected) in <(String, String?)>[
      ('text', '插件改写后的提示词'),
      ('map', '插件改写后的提示词（map）'),
      ('empty', ''),
      ('', null),
    ]) {
      final List<String> logs = <String>[];
      final PluginBus bus = await startBus(<String>[
        pluginEntry(
          id: 'llm',
          flags: <String>[
            '--subscribe-point',
            StationHubIds.relayPromptSystem,
            if (mode.isNotEmpty) ...<String>['--prompt-mode', mode],
          ],
        ),
      ], logs: logs);
      await waitForSubscription(bus, StationHubIds.relayPromptSystem, logs);
      final String? prompt = await bus.relaySystemPrompt(
        context: context,
        defaultPrompt: '内置提示词',
      );
      expect(
        prompt,
        expected,
        reason: mode == 'empty'
            ? '空串是"明确不要系统提示词"，必须与 null（不改）区分开'
            : '回包形态 $mode 的结果',
      );
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ── ⑧ 归属校验 ───────────────────────────────────────────────────────

  test('⑧归属校验：另一个插件往别人的 request_id 推 ⇒ 被拒绝且不影响那条流', () async {
    final List<String> logs = <String>[];
    final String requestLog = p.join(temp.path, 'open-stream.txt');
    final String marker = p.join(temp.path, 'foreign-sent.txt');
    final String finish = p.join(temp.path, 'finish.txt');
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'owner',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'stream-hold',
          '--request-log',
          requestLog,
          '--finish-file',
          finish,
          '--stream-delay-ms',
          '20',
        ],
      ),
      pluginEntry(
        id: 'foreign',
        flags: <String>[
          '--foreign-stream',
          requestLog,
          '--foreign-marker',
          marker,
          '--foreign-delay-ms',
          '600',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);
    expect(
      bus.instances().map(
        (({String pluginId, PluginHost host}) i) => i.pluginId,
      ),
      containsAll(<String>['owner', 'foreign']),
      reason: '两个插件都必须在跑（第二个是为了冒名往别人的流里推）',
    );

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull);
    final _Probe probe = _Probe(stream!);
    // owner 自己的增量先到（证明这条流是活的、我们在读的是同一条）
    await waitUntil(
      () => probe.events.any(
        (LlmStreamEvent e) => e is LlmTextDelta && e.text == 'OWN-1',
      ),
      description: 'owner 自己的增量到达',
    );
    // foreign 读到 request_id 后（延迟 600ms）冒名推一条，并落标记文件
    await waitUntil(
      () => File(marker).existsSync(),
      description: 'foreign 冒名推流完成',
    );
    // 再等一会儿：若归属校验失效，FOREIGN 早就该出现在流里了
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      probe.events.whereType<LlmTextDelta>().map((LlmTextDelta d) => d.text),
      isNot(contains('FOREIGN')),
      reason: '只有打开这条流的插件能往里推（点位唯一订阅者 = 归属可证明）',
    );
    expect(
      probe.events.whereType<LlmFailureEvent>(),
      isEmpty,
      reason: '外来推流不得把这条流搞失败',
    );
    expect(
      logs
          .where((String l) => l.contains('foreign') && l.contains('试图写入'))
          .length,
      greaterThanOrEqualTo(1),
      reason: '越权推流必须记可读日志（拒绝，而不是静默）；实际日志：${logs.join(' | ')}',
    );

    // 放行 owner 正常收尾：这条流自始至终没被外来增量污染
    File(finish).writeAsStringSync('go');
    await probe.finished.timeout(const Duration(seconds: 15));
    expect(probe.events.last, isA<LlmFinishEvent>());
    expect((probe.events.last as LlmFinishEvent).reason, 'stop');
    expect(bus.openLlmStreams, 0);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('⑧b未知 request_id 的 station/stream ⇒ 丢弃不崩，且不影响在途流', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(<String>[
      pluginEntry(
        id: 'llm',
        flags: <String>[
          '--subscribe-point',
          StationHubIds.relayLlmHandle,
          '--llm-mode',
          'stream',
          '--bogus-stream',
        ],
      ),
    ], logs: logs);
    await waitForSubscription(bus, StationHubIds.relayLlmHandle, logs);

    final Stream<LlmStreamEvent>? stream = await relay(bus);
    expect(stream, isNotNull);
    final List<LlmStreamEvent> events = await stream!
        .timeout(const Duration(seconds: 15))
        .toList();
    expect(
      events.whereType<LlmTextDelta>().map((LlmTextDelta d) => d.text),
      isNot(contains('GHOST')),
      reason: '未知 request_id 的增量必须被丢弃（不报错、不串进任何流）',
    );
    expect(events.whereType<LlmFinishEvent>().single.reason, 'stop');
    expect(
      logs.where((String l) => l.contains('关联不到在途流')).length,
      greaterThanOrEqualTo(1),
      reason: '丢弃要记可读日志；实际日志：${logs.join(' | ')}',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}

/// 从总线日志里取出这次"流式接管"的 request_id（`（relay-…-N）`）。
String? _requestIdFromLogs(List<String> logs) {
  final RegExp pattern = RegExp(r'（(relay-[^）]+)）');
  for (final String line in logs) {
    if (!line.contains('流式接管')) continue;
    final RegExpMatch? match = pattern.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// 手动读一条流的探针（要能在中途断言，所以不能用 `toList`）。
///
/// 自带超时计时器：**任何**用例都不会因为流不收尾而永久挂住（超时以错误结束
/// [finished]，断言处随即可读地失败）。
class _Probe {
  _Probe(
    Stream<LlmStreamEvent> stream, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    _subscription = stream.listen(
      events.add,
      onError: (Object error, StackTrace stack) {
        if (!closed.isCompleted) closed.completeError(error, stack);
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
    );
    _timer = Timer(timeout, () {
      if (!closed.isCompleted) {
        closed.completeError(
          TimeoutException('插件接管流在 ${timeout.inMilliseconds}ms 内没有收尾'),
        );
      }
    });
  }

  final List<LlmStreamEvent> events = <LlmStreamEvent>[];
  final Completer<void> closed = Completer<void>();

  late final StreamSubscription<LlmStreamEvent> _subscription;
  late final Timer _timer;

  Future<void> get finished async {
    try {
      await closed.future;
    } finally {
      _timer.cancel();
      await _subscription.cancel();
    }
  }
}
