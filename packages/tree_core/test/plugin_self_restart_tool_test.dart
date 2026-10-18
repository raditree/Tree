// 阶段 3（第 4 天）：agent 经 tool **热重启插件（含重启它自己）**的钉住用例。
//
// 跑的是真子进程（插件仓 `plugins/self_updater` 的源码入口 + 可挂起假插件夹具），
// 执行站接线与生产同一条（`ExecuteStationMounts.forStore(pluginManager: bus.handlePluginCommand)`）。
// 所有结论都来自核心侧读数、插件回包与日志行 —— 不靠"看起来重启成功了"。
//
// 钉住的六件事（plan 第 4 天步骤 6/7 的验收口径）：
// 1. **自重启不许挂死**：目标 == 发起者时核心先应答再动手（`deferred: true` 立刻回来），
//    下一回合才真的换一世 —— 反过来的话这条工具调用就是在等一个正在退出的进程；
// 2. 自重启确实续跑：快照入池 1 次、新一世是第 2 代、日志里有「快照已入池」；
// 3. 重启**别人**时结论是完整的：`resumed` / `generation` / `lifecycle`，
//    `wait_ready` 缺省还会再读一次 `plugin.state` 把新一世的阶段附进结果；
// 4. 失败一律可读：目标不存在 ⇒ 原因原样递回（不许退化成"未给出原因"）；
//    快照两条原语不给模型；证不了归属就拒（fail-closed）；
// 5. 控制面四条**都留审计行**（谁 / 何时 / 目标 / 结论），快照两条不刷日志；
// 6. 「强制停止」是全框架唯一能因用户按钮而 `kill()` 的入口，且它真的把
//    一个"赖着不退"的进程停掉了（D8 不许的是**时长**判死，不是用户显式动作）。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_lifecycle.dart';
import 'package:tree_core/tree_core.dart';

/// 与 `plugin_tool_define_self_updater_test.dart` 同样的手抄：命名空间那一段
/// 来自插件在 hello 里的自报 id，两边不同串就必须在这里红掉。
const String kNamespaced = 'plugin__self_updater__plugin_hot_restart';

void main() {
  late Directory temp;
  late String repo;
  late String selfUpdaterBin;
  late String suspendableScript;
  late List<String> logs;
  late PluginBus bus;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_self_restart_');
    logs = <String>[];
    final String? found = BuiltinPluginCatalog.repoRoot(Directory.current.path);
    expect(found, isNotNull, reason: '用例锚不到仓根 ⇒ 插件源码路径无从拼');
    repo = found!;
    selfUpdaterBin = p.join(
      repo,
      'plugins',
      'self_updater',
      'self_updater_plugin.dart',
    );
    suspendableScript = p.join(
      repo,
      'packages',
      'tree_core',
      'test',
      'fixtures',
      'suspendable_plugin.dart',
    );
    expect(File(selfUpdaterBin).existsSync(), isTrue, reason: selfUpdaterBin);
    // 入口现在住在**插件仓的一个 package** 里（2026-10-18 搬迁）：`dart run` 要按入口
    // 文件往上找 `package_config.json` 才能解析它的依赖。没跑过
    // `dart run tool/build_plugins.dart`（它先 `pub get`）就会在这里红——
    // 红得明确比默默跑过强（不查 package_config 的话，它可能“看着绿了但其实没测”）。
    expect(
      File(p.join(repo, 'plugins', 'self_updater', '.dart_tool', 'package_config.json')).existsSync(),
      isTrue,
      reason: '插件包还没 pub get：先跑 dart run tool/build_plugins.dart',
    );
    expect(
      File(suspendableScript).existsSync(),
      isTrue,
      reason: suspendableScript,
    );
  });

  tearDown(() async {
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  // ── 夹具 ───────────────────────────────────────────────────────────────

  String eventLogOf(String id) => p.join(temp.path, '$id.events.jsonl');

  List<Map<String, dynamic>> events(String id) {
    final File file = File(eventLogOf(id));
    if (!file.existsSync()) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final String line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  /// 一条 self_updater 条目（[scopeLine] 决定它能不能证明归属）。
  List<String> selfUpdaterEntry({
    String scopeLine = '{team_id: team-1, mode_key: local}',
  }) => <String>[
    '  - id: $kSelfUpdaterPluginId',
    '    name: 框架自迭代插件',
    '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"',
    '    args: ["${selfUpdaterBin.replaceAll('\\', '/')}"]',
    '    enabled: true',
    '    granularity: team',
    '    suspension: keep',
    '    scope: $scopeLine',
  ];

  /// 一条可挂起假插件条目（重启目标用它：事件日志能数出"真的起了两个进程"）。
  List<String> alphaEntry({
    List<String> extraArgs = const <String>[],
  }) => <String>[
    '  - id: alpha',
    '    name: 甲插件',
    '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"',
    '    args: ["${suspendableScript.replaceAll('\\', '/')}", "--id", "alpha", '
        '"--event-log", "${eventLogOf('alpha').replaceAll('\\', '/')}"'
        '${extraArgs.isEmpty ? '' : ', '}${extraArgs.map((String a) => '"$a"').join(', ')}]',
    '    enabled: true',
    '    granularity: team',
    '    suspension: keep',
    '    scope: {team_id: team-1, mode_key: local}',
  ];

  /// 写清单 + 起总线 + **接上执行站的 plugin.* 挂载**（与 CoreServer 生产同一个实现）。
  Future<void> startBus(List<String> entries) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(
      <String>['enabled: true', 'plugins:', ...entries, ''].join('\n'),
    );
    bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      // 心跳节拍拉长：本文件关心的是重启链路与审计，不要探活定时器插进来
      heartbeatInterval: const Duration(seconds: 30),
      log: (String message) => logs.add(message),
    );
    final ExecuteStationMounts mounts = ExecuteStationMounts.forStore(
      store: MemoryStore(),
      ioFor: (String agentId) async => null,
      pluginManager: bus.handlePluginCommand,
    );
    expect(bus.mountExecuteStations(mounts), isNull, reason: '挂载必须全成功');
    await bus.start();
  }

  /// 经 **tool** 下一次动作（走真插件的 `station/command`，不绕过去直接调 bus：
  /// 白名单、归属校验、审计都在这条链上，绕过就等于没测到它们）。
  Future<PluginCallResult> callTool(Map<String, dynamic> arguments) =>
      bus.callTool(kNamespaced, arguments);

  Future<void> waitFor(
    bool Function() condition,
    String what, {
    int rounds = 240,
  }) async {
    for (int i = 0; i < rounds; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('等「$what」等到第 $rounds 轮仍未成立；日志：$logs');
  }

  /// 等**一行日志**出现。为什么要单独一个助手：新一世的 `ready` 在 `hotRestart` 里
  /// 发生在“结论行”之前（中间还夹着一次工具表收集），拿 `ready` 当信号去断言
  /// 后面的日志就会必输；要等就等那条日志本身。
  Future<String> waitForLog(bool Function(String line) hit, String what) async {
    String found = '';
    await waitFor(() {
      for (final String line in logs) {
        if (hit(line)) {
          found = line;
          return true;
        }
      }
      return false;
    }, what);
    return found;
  }

  /// 审计行（形如 `插件控制面审计｜2026-10-15 11:02:03+08:00｜插件 self_updater ⇒ …`）。
  List<String> auditLines() =>
      logs.where((String m) => m.contains('插件控制面审计')).toList();

  // ── 用例 ───────────────────────────────────────────────────────────────

  test('自重启：目标就是发起者 ⇒ 先应答再动手，随后真的换了一世并续上快照', () async {
    await startBus(<String>[...selfUpdaterEntry()]);
    expect(bus.generationOf(kSelfUpdaterPluginId), 1);
    expect(bus.lifecycleOf(kSelfUpdaterPluginId), PluginLifecycleState.ready);

    final Stopwatch elapsed = Stopwatch()..start();
    final PluginCallResult result = await callTool(<String, dynamic>{
      'action': 'restart',
      'plugin_id': kSelfUpdaterPluginId,
    });
    elapsed.stop();

    // ① 代答：**回包必须在动手之前拿到**。这条阈值不是"时长判据"（那是 D8 禁止的），
    //    它只是把"挂死"与"慢"分开：挂死的形态是这条 await 永远不返回。
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, contains('"deferred":true'));
    expect(result.text, contains('先应答再动手'));
    expect(elapsed.elapsed.inSeconds, lessThan(10));

    // ② 下一回合才真的重启：等"新一世就绪"这个**事件**（不是等时长）。
    //    代际在 spawn 时就 +1，而 lifecycle 要到 hello 回包才置 ready：
    //    只等前者会把断言做在"过里已经启动了但还没握手完"那一瞬上。
    await waitFor(
      () =>
          bus.generationOf(kSelfUpdaterPluginId) == 2 &&
          bus.lifecycleOf(kSelfUpdaterPluginId) == PluginLifecycleState.ready,
      'self_updater 的第 2 世就绪',
    );
    expect(bus.lifecycleOf(kSelfUpdaterPluginId), PluginLifecycleState.ready);
    expect(
      logs.any((String m) => m.contains('就绪（第 2 代）')),
      isTrue,
      reason: '$logs',
    );

    // ③ 快照真的走了一遍池（1 次入池、随后被新一世取走 ⇒ 池里不剩东西）。
    //    顺序不是“先取快照再 ready”：新一世是在 hello **之后**才发 `plugin.stateFetch`，
    //    所以“已 ready 而快照还没被取走”是正常现场。拿它当必定同时成立去断言，
    //    机器一忙就会偶发失败（与上面那条“等日志而不是等 ready”同一个坑）。
    expect(bus.statePool.putCount, 1, reason: '一份可续跑状态只递一次');
    await waitFor(() => bus.statePool.length == 0, '新一世把快照取走（取回即消费）');
    expect(bus.statePool.length, 0, reason: '取回即消费（一份快照只喂一世）');
    final String settled = await waitForLog(
      (String m) => m.contains('自重启收尾') && m.contains('快照已入池'),
      '自重启的收尾行（带“快照已入池”）',
    );
    expect(settled, contains('第 2 代'));

    // ④ 审计：自重启那一条**不许写成"成功"**（结论在下一回合），也不许静默
    final List<String> restartAudit = auditLines()
        .where((String m) => m.contains('plugin.restart'))
        .toList();
    expect(restartAudit, hasLength(1), reason: '$restartAudit');
    expect(restartAudit.single, contains('插件 $kSelfUpdaterPluginId'));
    expect(restartAudit.single, contains('目标=$kSelfUpdaterPluginId'));
    expect(restartAudit.single, contains('已受理'));
    expect(
      RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}')
          .hasMatch(restartAudit.single),
      isTrue,
      reason:
          '审计必须带**可读**的时间戳与偏移（“何时”是事后唯一能查的东西）：'
          '${restartAudit.single}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('重启别的插件：结论完整（resumed/代际/阶段），wait_ready 决定要不要再读一次状态', () async {
    await startBus(<String>[...selfUpdaterEntry(), ...alphaEntry()]);
    await waitFor(
      () =>
          events('alpha').any((Map<String, dynamic> e) => e['kind'] == 'fetch'),
      'alpha 第一世问过快照',
    );

    final PluginCallResult withState = await callTool(<String, dynamic>{
      'action': 'restart',
      'plugin_id': 'alpha',
    });
    expect(withState.isError, isFalse, reason: withState.text);
    final Map<String, dynamic> outcome = _payloadOf(withState.text);
    expect(outcome['ok'], isTrue);
    expect(outcome['resumed'], isTrue, reason: 'alpha 声明了 suspension: keep');
    expect(outcome['dump_id'], 'alpha#1');
    expect(outcome['generation'], 2);
    expect(outcome['lifecycle'], 'ready');
    // wait_ready 缺省 true ⇒ 结果里附一份 plugin.state 的读数（模型看得见"第几世"）
    final Map<String, dynamic> settled =
        outcome['settled'] as Map<String, dynamic>;
    expect(settled['lifecycle'], 'ready');
    expect(settled['generation'], 2);
    // 真的起了第二个进程（数事件，不看返回值）
    expect(
      events('alpha').where((Map<String, dynamic> e) => e['kind'] == 'start'),
      hasLength(2),
    );

    final int stateAuditsBefore = auditLines()
        .where((String m) => m.contains('plugin.state '))
        .length;
    final PluginCallResult noWait = await callTool(<String, dynamic>{
      'action': 'restart',
      'plugin_id': 'alpha',
      'wait_ready': false,
    });
    expect(noWait.isError, isFalse, reason: noWait.text);
    expect(_payloadOf(noWait.text).containsKey('settled'), isFalse);
    expect(
      auditLines().where((String m) => m.contains('plugin.state ')).length,
      stateAuditsBefore,
      reason: 'wait_ready=false ⇒ 不该多下一次状态命令（读数只在要的时候读）',
    );
    expect(bus.generationOf('alpha'), 3);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('失败都是结果：目标不存在的原因必须原样递回，不退化成"未给出原因"', () async {
    await startBus(<String>[...selfUpdaterEntry()]);

    final PluginCallResult ghost = await callTool(<String, dynamic>{
      'action': 'restart',
      'plugin_id': 'ghost',
    });
    expect(ghost.isError, isTrue, reason: '重启一个清单里没有的插件必须算失败');
    expect(ghost.text, contains('没有插件条目 ghost'), reason: ghost.text);
    expect(ghost.text, isNot(contains('未给出原因')));
    // 失败隔离：self_updater 自己照旧在跑（不变量 10）
    expect(bus.lifecycleOf(kSelfUpdaterPluginId), PluginLifecycleState.ready);
    expect(
      auditLines().any(
        (String m) => m.contains('plugin.restart') && m.contains('失败：'),
      ),
      isTrue,
      reason: '$logs',
    );

    // 快照两条原语不交给模型（D9）：tool 层直接拒，而且压根没下命令
    final PluginCallResult refused = await callTool(<String, dynamic>{
      'action': 'stateDump',
      'plugin_id': kSelfUpdaterPluginId,
    });
    expect(refused.isError, isTrue);
    expect(refused.text, contains('不是可申报的能力'));
    expect(auditLines().any((String m) => m.contains('stateDump')), isFalse);

    // 其余四条里要指名目标的不给 id 就拒（插件本地先拦，不打到执行站）
    final PluginCallResult missingId = await callTool(<String, dynamic>{
      'action': 'state',
    });
    expect(missingId.isError, isTrue);
    expect(missingId.text, contains('需要 plugin_id'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('归属证明不了 ⇒ 执行站 fail-closed 拒绝，而原因说得出"为什么"', () async {
    // 通配订阅（scope 空）⇒ 控制面四条没有可证明的 team：这是"谁的命令"这个问题
    // 没有答案，不是"命令写错了"。拒要拒得能说清，否则用户只会看到一个 tool 失败。
    await startBus(<String>[...selfUpdaterEntry(scopeLine: '{}')]);
    expect(
      bus.definitionOf(kNamespaced),
      isNotNull,
      reason: '空 scope 仍走 tools/list 申报 ⇒ 工具本身是有的',
    );

    final PluginCallResult denied = await callTool(<String, dynamic>{
      'action': 'list',
    });
    expect(denied.isError, isTrue, reason: denied.text);
    expect(denied.text, contains('team_id'));
    expect(denied.text, contains('没有可证明的归属身份'));
    // 拒了就不该有"成功"的审计行（审计记的是结论，不是尝试）
    expect(
      auditLines().any(
        (String m) => m.contains('plugin.list') && m.contains('成功'),
      ),
      isFalse,
      reason: '$logs',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('action=list 经 tool 拿到全部插件读数（lifecycle / 代际 / 可否挂起）', () async {
    await startBus(<String>[...selfUpdaterEntry(), ...alphaEntry()]);

    final PluginCallResult listed = await callTool(<String, dynamic>{
      'action': 'list',
    });
    expect(listed.isError, isFalse, reason: listed.text);
    final Map<String, dynamic> outcome = _payloadOf(listed.text);
    expect(outcome['ok'], isTrue);
    final List<dynamic> plugins = outcome['plugins'] as List<dynamic>;
    expect(
      plugins.map((dynamic e) => (e as Map<String, dynamic>)['plugin_id']),
      containsAll(<String>[kSelfUpdaterPluginId, 'alpha']),
    );
    for (final Object? entry in plugins) {
      final Map<String, dynamic> row = entry as Map<String, dynamic>;
      expect(row['lifecycle'], isA<String>(), reason: '${row['plugin_id']}');
      expect(row['generation'], isA<int>());
      expect(row['suspendable'], isTrue);
    }
    // 四条控制面命令都留审计（这一条走的是 plugin.list）
    expect(
      auditLines().any(
        (String m) =>
            m.contains('plugin.list') &&
            m.contains('目标=（全部）') &&
            m.contains('成功'),
      ),
      isTrue,
      reason: '$logs',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('强制停止：唯一能因用户动作而 kill 的入口，真的停住了一个赖着不退的进程', () async {
    // alpha 收到 shutdown 也**不退**、而且彻底沉默：这正是"核心不等时长、也不因
    // 沉默杀它"（D8）留下的那一格 —— 能停它的只有用户显式按下的那个按钮。
    await startBus(<String>[
      ...selfUpdaterEntry(),
      ...alphaEntry(
        extraArgs: <String>['--no-exit-on-shutdown', 'true', '--beat-ms', '0'],
      ),
    ]);
    expect(bus.lifecycleOf('alpha'), PluginLifecycleState.ready);

    final Map<String, dynamic> stopped = await bus.forceStop('alpha');
    expect(stopped['ok'], isTrue);
    expect(stopped['killed'], 1, reason: '赖着不退的那个必须被显式 kill');
    expect(stopped['exited'], isTrue, reason: '停完必须确认退出');
    expect(stopped['lifecycle'], 'stopped');
    expect(stopped['kill_reason'], contains('用户显式强制停止'));
    expect(
      logs.any((String m) => m.contains('唯一的用户强杀入口')),
      isTrue,
      reason: '$logs',
    );
    // 条目还在、仍是启用态 ⇒ 下一次对账会把它再拉起来（面板文案据此说话）
    expect(bus.config('alpha')!.enabled, isTrue);
    expect(stopped['note'], contains('下一次对账'));
    // 只停 alpha：self_updater 不受牵连（不变量 10）
    expect(bus.lifecycleOf(kSelfUpdaterPluginId), PluginLifecycleState.ready);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 工具回包的文本就是 jsonEncode 的结果（MCP 的 content[0].text）：解开再看字段，
/// 断言才不会退化成"文本里好像有这个词"。
Map<String, dynamic> _payloadOf(String text) {
  final int start = text.indexOf('{');
  expect(start, greaterThanOrEqualTo(0), reason: '工具结果里没有 JSON：$text');
  final Object? decoded = jsonDecode(text.substring(start));
  return decoded is Map
      ? decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
      : throw StateError('工具结果不是对象：$text');
}
