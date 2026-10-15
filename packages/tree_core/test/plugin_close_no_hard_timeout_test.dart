// 插件**关闭与退出**的判据钉住用例（20261015-hot-restart 阶段 1，D8）。
//
// D8 要消除的是「**时长**判死」：原实现是 `close()` 里 `exitCode.timeout(2s)` →
// 超时 `kill()`。本文件从几个方向钉住它不再存在：
//
// A. **心跳在、只是慢** ⇒ 看门狗跑很多拍也绝不杀它（真子进程：插件收到 shutdown
//    后继续按拍发通知，用例连跑 15 轮看门狗，收尸计数必须是 0）；
// B. **判失活后才收尸**，而且**不能早于**连续 N 拍：逐轮读数钉住第 1、2 拍没杀、
//    第 N 拍才杀，并且原因里写的是"收尸"而不是"超时"；
// C. **自己退了就不用收尸**：插件在 N 拍之内自然退出 ⇒ 台账销账、`killed=false`；
// D. **源码级红线**：`close()` 的实现里既没有 `timeout(` 也没有 `.kill(`——
//    强杀只能来自"判失活后的收尸"或"用户显式动作"这两处，不许藏在关闭路径里；
// E. **默认不等退出** ⇒ 一个赖着不退的插件拖不住整轮串行对账（去 2s 的连带义务）；
// F. **核心自己退出** ⇒ 赖着的进程被收尸，不留孤儿。
//
// 这里用**真子进程**（`test/fixtures/suspendable_plugin.dart`）而不是假宿主：
// "赖着不退"这件事只有真进程能证明，假宿主说"我没退"不算数。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String script;
  late String configFile;
  late List<PluginBus> buses;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_close_timeout_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'suspendable_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue);
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    Directory(p.dirname(configFile)).createSync(recursive: true);
    File(configFile).writeAsStringSync('enabled: true\nplugins: []\n');
    buses = <PluginBus>[];
  });

  tearDown(() async {
    for (final PluginBus bus in buses) {
      try {
        await bus.close();
      } catch (_) {
        // 关停失败不该盖掉用例的断言结果
      }
    }
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String eventLogOf(String id) => p.join(temp.path, '$id.events.jsonl');

  /// 某类事件的条数（假插件每收到 shutdown 就写一行；`beat` 是它"还活着且还在说话"的证据）。
  int eventCount(String id, String kind) {
    final File file = File(eventLogOf(id));
    if (!file.existsSync()) return 0;
    int hit = 0;
    for (final String line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> decoded =
          jsonDecode(line) as Map<String, dynamic>;
      if (decoded['kind'] == kind) hit++;
    }
    return hit;
  }

  /// 一条插件条目；[beatMs] > 0 = 赖着不退时继续按拍发通知（心跳在），
  /// = 0 = 彻底沉默但也不退；[selfStopMs] > 0 = 收到 shutdown 后 N 毫秒自己退出。
  List<String> entry(
    String id, {
    required int beatMs,
    bool enabled = true,
    int selfStopMs = 0,
  }) {
    final List<String> args = <String>[
      script,
      '--id',
      id,
      '--event-log',
      eventLogOf(id),
      '--no-exit-on-shutdown',
      'true',
      '--beat-ms',
      '$beatMs',
      if (selfStopMs > 0) ...<String>['--self-stop-ms', '$selfStopMs'],
    ];
    return <String>[
      '  - id: $id',
      '    name: $id 插件',
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"',
      '    args: [${args.map((String a) => '"${a.replaceAll('\\', '/')}"').join(', ')}]',
      '    enabled: $enabled',
      '    granularity: team',
      '    scope: {team_id: team-1}',
    ];
  }

  void writeEntries(Iterable<String> entries) {
    File(configFile).writeAsStringSync(
      <String>['enabled: true', 'plugins:', ...entries, ''].join('\n'),
    );
  }

  PluginBus newBus(Duration heartbeatInterval) {
    final PluginBus bus = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      heartbeatInterval: heartbeatInterval,
      missThreshold: 3,
    );
    buses.add(bus);
    return bus;
  }

  Future<void> settle(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  List<String> idsOf(List<PluginReconcileAction> actions) => <String>[
    for (final PluginReconcileAction action in actions) action.pluginId,
  ];

  // ── 用例 ───────────────────────────────────────────────────────────────

  test('A 心跳在、只是慢 ⇒ 跑很多拍看门狗也绝不收尸（D8 的正命题）', () async {
    // 心跳间隔比“看门狗拍的节奏”密得多：这才是“链路在、只是慢”的真实形状。
    // 反过来（拍比心跳密）本来就该被判失活，那不是本条要钉的东西。
    writeEntries(entry('alpha', beatMs: 5));
    final PluginBus bus = newBus(const Duration(milliseconds: 40));
    await bus.start();
    expect(bus.instances(), hasLength(1));

    // 要求它退（对账里 enabled=false ⇒ 断开，不重启）
    writeEntries(entry('alpha', beatMs: 5, enabled: false));
    await bus.applyConfigs();
    expect(bus.instances(), isEmpty, reason: '已经要求它退了');
    expect(
      bus.reapingReadings(),
      hasLength(1),
      reason: '退出还没确认 ⇒ 挂在收尸台账上',
    );

    // 15 轮看门狗（每轮之间留 40ms，总共≈600ms，远超"3 拍"）：
    // 插件每 5ms 发一条通知 ⇒ 每一轮都必然有新的心跳证据把丢拍清零
    for (int round = 0; round < 15; round++) {
      await bus.watchdog();
      await settle(40);
    }

    expect(bus.straysKilled, 0, reason: '心跳在就不是杀人的理由（D8）');
    final List<Map<String, dynamic>> reaping = bus.reapingReadings();
    expect(reaping, hasLength(1));
    expect(reaping.single['killed'], isFalse);
    expect(reaping.single['exited'], isFalse);
    expect(reaping.single['missed_heartbeats'], lessThan(3));
    // 进程确实还活着并且还在说话（不是台账在替它撒谎）
    expect(eventCount('alpha', 'beat'), greaterThan(5));
  });

  test('B 判失活后才收尸，而且不得早于连续 N 拍（N=3）', () async {
    writeEntries(entry('alpha', beatMs: 0)); // 沉默但不退
    final PluginBus bus = newBus(const Duration(milliseconds: 40));
    await bus.start();
    writeEntries(entry('alpha', beatMs: 0, enabled: false));
    await bus.applyConfigs();
    expect(bus.reapingReadings(), hasLength(1));

    await bus.watchdog();
    Map<String, dynamic> reading = bus.reapingReadings().single;
    expect(reading['missed_heartbeats'], 1);
    expect(
      reading['killed'],
      isFalse,
      reason: '第 1 拍就杀 = 又是时长判死，只是把 2s 换成了 40ms',
    );

    await bus.watchdog();
    reading = bus.reapingReadings().single;
    expect(reading['missed_heartbeats'], 2);
    expect(reading['killed'], isFalse);

    await bus.watchdog();
    reading = bus.reapingReadings().single;
    expect(reading['missed_heartbeats'], 3);
    expect(reading['stale'], isTrue);
    expect(reading['killed'], isTrue, reason: '连续 N 拍彻底沉默 ⇒ 收尸');
    expect(bus.straysKilled, 1);
    // 原因必须是"判失活后的收尸"，不许写成超时（措辞也是契约：日志与用例都靠它识别）
    final String reason = reading['kill_reason'] as String;
    expect(reason, contains('收尸'));
    expect(reason, contains('心跳'));
    expect(reason, isNot(contains('超时')));
  });

  test('C 自己退了就不用收尸：台账销账、killed=false', () async {
    // 沉默，但 120ms 后自己退出；判活窗口 3×100ms = 300ms ⇒ 在它退出前不会判死
    writeEntries(entry('alpha', beatMs: 0, selfStopMs: 120));
    final PluginBus bus = newBus(const Duration(milliseconds: 100));
    await bus.start();
    writeEntries(entry('alpha', beatMs: 0, selfStopMs: 120, enabled: false));
    await bus.applyConfigs();

    await settle(400);
    await bus.watchdog();

    expect(bus.straysKilled, 0, reason: '它是自己退的，不是被收的');
    expect(
      bus.reapingReadings(),
      isEmpty,
      reason: '退出已确认 ⇒ 台账销账（收尸台账不能变成黑洞）',
    );
    expect(eventCount('alpha', 'shutdown'), greaterThan(0));
  });

  test('D 源码红线：close() 里没有 timeout( 也没有 .kill(', () {
    final String source = File(
      p.join(
        Directory.current.path,
        'lib',
        'src',
        'plugin',
        'plugin_host.dart',
      ),
    ).readAsStringSync();
    final int at = source.indexOf('Future<void> close(');
    expect(at, greaterThan(0), reason: 'close() 必须还在（拆两阶段而不是删掉它）');
    final int end = source.indexOf('\n  }', at);
    final String body = source.substring(at, end);

    expect(
      body.contains('timeout('),
      isFalse,
      reason: 'D8：取消插件退出的**时长**判死（原来是 exitCode.timeout(2s)）',
    );
    expect(
      body.contains('.kill('),
      isFalse,
      reason: '关闭路径不许直接强杀；强杀只在 killStray()（收尸 / 用户显式动作）',
    );
    // 等的是事件，不是时长
    expect(body, contains('waitForExit'));
    expect(body, contains('exited'));
    // 全文件的**代码**（不算注释）都不许再出现"exitCode.timeout"这个旧判据：
    // 注释里可以提“原来是什么”，代码里不能再留它的任何一个零件。
    final String code = source
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('exitCode.timeout'), isFalse);
  });

  test('E 默认不等退出 ⇒ 一个赖着不退的插件拖不住整轮对账', () async {
    // alpha 赖着不退（沉默），beta 正常但也不退（继续发心跳）。整轮对账必须很快跑完，
    // 不被 alpha 拖住——这正是"去掉 2s 硬超时"必须连带改掉调用侧的原因。
    writeEntries(<String>[
      ...entry('alpha', beatMs: 0),
      ...entry('beta', beatMs: 8),
    ]);
    final PluginBus bus = newBus(const Duration(milliseconds: 40));
    await bus.start();
    expect(bus.instances(), hasLength(2));

    writeEntries(<String>[
      ...entry('alpha', beatMs: 0, enabled: false),
      ...entry('beta', beatMs: 8, enabled: false),
    ]);

    final Stopwatch elapsed = Stopwatch()..start();
    final PluginReconcileResult report = await bus.applyConfigs();
    elapsed.stop();

    expect(idsOf(report.stopped), <String>['alpha', 'beta']);
    expect(bus.instances(), isEmpty);
    // 没有 2s 硬超时、也没有"等退出"：两个赖着的进程都没把对账拖成秒级
    expect(
      elapsed.elapsed.inMilliseconds,
      lessThan(1500),
      reason: '对账耗时 ${elapsed.elapsedMilliseconds}ms：等退出会把串行对账拖成长跑',
    );
    expect(bus.reapingReadings(), hasLength(2));
    expect(bus.straysKilled, 0, reason: '刚断开，还没到判失活的拍数');
  });

  test('F 核心自己退出 ⇒ 赖着的进程被收尸，不留孤儿', () async {
    writeEntries(entry('alpha', beatMs: 8));
    final PluginBus bus = newBus(const Duration(milliseconds: 40));
    await bus.start();
    writeEntries(entry('alpha', beatMs: 8, enabled: false));
    await bus.applyConfigs();
    expect(bus.reapingReadings(), hasLength(1));
    expect(bus.straysKilled, 0);

    await bus.close();
    buses.remove(bus);

    expect(bus.straysKilled, 1, reason: '核心要退了 ⇒ 这是收尸，不是判超时');
    expect(bus.reapingReadings(), isEmpty);
    expect(bus.statePool.length, 0, reason: '核心退出即丢快照（D4 的代价，明写在池的注释里）');
  });
}
