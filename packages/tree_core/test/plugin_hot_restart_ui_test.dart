// UI 插件**热重启**（`docs/pluginization/ui-hot-restart-recon.md` §4.3 / §4.4）。
//
// 跑的是**真子进程 + 真核心 WS**：假 UI 插件自己 `ui.hello`、收 `plugin.suspend`
// 回切片然后退出、新世收 `plugin.resume`。所有结论来自进程写下的事件日志与核心
// 侧读数——不靠"看起来重启成功了"。
//
// 钉住的七件事（对应计划 §6 的 tree_core 行）：
// 1. suspend → ack → **旧进程退出之后**才拉起 → 同一 `w1` 重拉 → 切片被新世取走；
// 2. 没声明 `suspension: keep` ⇒ 冷重启，且原因不是「实例本来不在跑」；
// 3. hello 没带 `ui.lifecycle` ⇒ 冷重启（不发 plugin.suspend）；
// 4. ack 超时（窗口卡住）⇒ 到宽限 kill，本次冷启动；
// 5. 切片超限 ⇒ 冷启动 + 可读原因（不截断、不落盘）；
// 6. 多窗口：两个窗口各自取回自己的切片，**窗口号不变**（不增长成 w3）；
// 7. `plugin.state.running` 对 UI 按活窗口为 true；迟到 hello 被拒。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late PluginBus bus;
  late CoreServer server;
  late List<String> logs;
  late String probe;

  setUpAll(() {
    probe = p
        .join(
          Directory.current.path,
          'test',
          'fixtures',
          'ui_lifecycle_probe.dart',
        )
        .replaceAll('\\', '/');
    expect(File(probe).existsSync(), isTrue, reason: 'UI 探针必须存在');
  });

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_ui_hot_restart_');
    logs = <String>[];
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync('enabled: true\nplugins: []\n');
    bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      // 宽限压到 300ms：本文件的题是「等不等退出 / 切不切片」，不是真实用户等待。
      uiSuspendGrace: const Duration(milliseconds: 300),
      uiHelloWindow: const Duration(seconds: 6),
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
    bus.pluginLog = (String id, String line, String stream) => logs.add(line);
    server = await CoreServer.start(
      store: MemoryStore(),
      pluginBus: bus,
      enableHeartbeat: false,
    );
  });

  tearDown(() async {
    await server.close();
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

  String eventLogOf(String id) => p.join(temp.path, '$id.events.jsonl');

  List<Map<String, dynamic>> events(String id) {
    final File file = File(eventLogOf(id));
    if (!file.existsSync()) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final String line in file.readAsLinesSync())
        if (line.trim().isNotEmpty)
          jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  List<Map<String, dynamic>> eventsOf(String id, String kind) =>
      events(id).where((Map<String, dynamic> e) => e['kind'] == kind).toList();

  Future<List<Map<String, dynamic>>> waitForEvents(
    String id,
    String kind,
    int atLeast,
  ) async {
    for (int i = 0; i < 300; i++) {
      final List<Map<String, dynamic>> hit = eventsOf(id, kind);
      if (hit.length >= atLeast) return hit;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('等 $id 的「$kind」事件等到 300 轮仍不足 $atLeast 条；当前：${events(id)}');
  }

  Future<void> waitFor(
    bool Function() predicate, {
    String reason = '等待条件超时',
  }) async {
    for (int i = 0; i < 300; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('$reason；日志尾：${logs.reversed.take(8).toList()}');
  }

  /// 一条 UI 插件条目（默认声明 `suspension: keep`）。
  List<String> entry(
    String id, {
    bool suspension = true,
    String mode = 'lifecycle',
  }) {
    final String dart = Platform.resolvedExecutable.replaceAll('\\', '/');
    return <String>[
      '  - id: $id',
      '    name: $id 插件',
      '    command: "$dart"',
      '    args: ["$probe", "--id", "$id", "--events", '
          '"${eventLogOf(id).replaceAll('\\', '/')}", "--mode", "$mode"]',
      '    enabled: true',
      '    runtime: ui',
      if (suspension) '    suspension: keep',
      '    scope: {team_id: team-1}',
    ];
  }

  void writePlugins(List<String> entries) {
    File(bus.configFile).writeAsStringSync(
      <String>['enabled: true', 'plugins:', ...entries, ''].join('\n'),
    );
  }

  /// 启动并等到第一世的 `ui.hello` 落地（窗口出现 + hello 事件）。
  ///
  /// [expectResume] 只对声明了 `ui.lifecycle` 的构建为真：`plugin.resume` 只发给
  /// 带该能力的连接（`StationWsBridge.pushResume`），未声明能力的窗口收不到，
  /// 也不该收到——那不是失败，是「这一代不参与握手」。
  Future<void> startPlugin(String id, {bool expectResume = true}) async {
    await bus.start();
    await waitFor(
      () => bus.uiWindows().any(
        (Map<String, dynamic> w) => w['plugin_id'] == id && w['alive'] == true,
      ),
      reason: '插件 $id 应有 1 个活窗口',
    );
    await waitForEvents(id, 'start', 1);
    if (expectResume) {
      // 第一次 hello 后核心会推一条 `plugin.resume`（has_snapshot:false）——
      // 这是「首帧前先等一等」的确定性信号，冷启动也必须有。
      await waitForEvents(id, 'resume', 1);
    }
  }

  test('热重启：suspend→ack→旧进程退出→同一 w1 重拉→新世取回切片', () async {
    writePlugins(entry('ui.alpha'));
    await startPlugin('ui.alpha');

    expect(bus.generationOf('ui.alpha'), 1);
    final Map<String, dynamic> first = eventsOf('ui.alpha', 'start').single;
    expect(
      eventsOf('ui.alpha', 'resume').single['has_snapshot'],
      isFalse,
      reason: '第一世没有快照 ⇒ 冷启动信号',
    );

    final PluginHotRestartResult result = await bus.hotRestart('ui.alpha');
    expect(result.ok, isTrue, reason: result.reason);
    expect(
      result.resumed,
      isTrue,
      reason: '${result.reason}\n日志：\n${logs.join('\n')}',
    );
    expect(result.dumpId, 'ui.alpha#1');
    expect(result.generation, 2);
    expect(result.windows, hasLength(1));
    expect(result.windows.single['window_id'], 'w1');
    expect(result.windows.single['resumed'], isTrue);
    expect(result.windows.single['bytes'], greaterThan(0));

    // 真的换了世：两个不同的 pid，且**新进程在旧进程退出之后**才起（事件时刻比较）
    final List<Map<String, dynamic>> starts = eventsOf('ui.alpha', 'start');
    expect(starts, hasLength(2));
    expect(starts[0]['pid'], isNot(starts[1]['pid']));
    final Map<String, dynamic> exited = eventsOf('ui.alpha', 'exit').single;
    expect(
      (starts[1]['at'] as int) >= (exited['at'] as int),
      isTrue,
      reason: '旧进程未退出前不得拉起新进程',
    );

    // 新世取回的正是第一世写的那一份（payload 里带第一世 pid）
    final List<Map<String, dynamic>> resumes = await waitForEvents(
      'ui.alpha',
      'resume',
      2,
    );
    expect(resumes[1]['has_snapshot'], isTrue);
    expect(
      (resumes[1]['payload'] as Map<String, dynamic>)['era_pid'],
      first['pid'],
    );
    expect((resumes[1]['payload'] as Map<String, dynamic>)['window'], 'w1');

    // 窗口号复用：仍然只有 w1（不增长成 w2）
    expect(bus.uiWindows(), hasLength(1));
    expect(bus.uiWindows().single['window_id'], 'w1');
    // plugin.state.running 对 UI 按活窗口为 true（旧口径恒 false）
    final Map<String, dynamic> state = await bus.handlePluginCommand(
      command: 'plugin.state',
      pluginId: 'ui.alpha',
      sourcePluginId: '',
    );
    expect(state['running'], isTrue);
    expect(state['status'], 'registered');
    // 一份快照只喂一世：池里已被消费
    expect(bus.statePool.length, 0);
    expect(bus.generationOf('ui.alpha'), 2);
  });

  test('没声明 suspension: keep ⇒ 冷重启，原因不是「实例本来不在跑」', () async {
    writePlugins(entry('ui.cold', suspension: false));
    await startPlugin('ui.cold');

    final PluginHotRestartResult result = await bus.hotRestart('ui.cold');
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isFalse);
    expect(result.reason, contains('没声明 suspension: keep'));
    expect(result.reason, isNot(contains('实例本来不在跑')));
    expect(eventsOf('ui.cold', 'suspend'), isEmpty);

    await waitForEvents('ui.cold', 'start', 2);
    expect(eventsOf('ui.cold', 'resume').last['has_snapshot'], isFalse);
  });

  test('hello 没带 ui.lifecycle ⇒ 冷重启（不发 plugin.suspend）', () async {
    writePlugins(entry('ui.nocap', mode: 'nocap'));
    await startPlugin('ui.nocap', expectResume: false);

    final PluginHotRestartResult result = await bus.hotRestart('ui.nocap');
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isFalse);
    expect(result.reason, contains('没有窗口声明 ui.lifecycle'));
    expect(eventsOf('ui.nocap', 'suspend'), isEmpty);
    await waitForEvents('ui.nocap', 'start', 2);
  });

  test('ack 超时（窗口卡住）⇒ 宽限到点 kill，本次按冷启动', () async {
    writePlugins(entry('ui.hang', mode: 'hang'));
    await startPlugin('ui.hang');

    final Stopwatch watch = Stopwatch()..start();
    final PluginHotRestartResult result = await bus.hotRestart('ui.hang');
    watch.stop();
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isFalse);
    expect(result.reason, contains('没有交出切片'));
    expect(watch.elapsed, greaterThan(const Duration(milliseconds: 250)));
    // 卡住的进程被收掉，新世起来了
    await waitFor(() => bus.uiWindows().length == 1, reason: '新世应有 1 个窗口');
    await waitForEvents('ui.hang', 'start', 2);
  });

  test('切片超限 ⇒ 冷启动 + 可读原因（不截断、不落盘）', () async {
    writePlugins(entry('ui.big', mode: 'oversize'));
    await startPlugin('ui.big');

    final PluginHotRestartResult result = await bus.hotRestart('ui.big');
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isFalse);
    expect(result.dumpId, isEmpty);
    expect(result.reason, contains('转储过大'));
    await waitForEvents('ui.big', 'start', 2);
    expect(eventsOf('ui.big', 'resume').last['has_snapshot'], isFalse);
  });

  test('多窗口：两个窗口各自取回自己的切片，窗口号不变', () async {
    writePlugins(entry('ui.multi'));
    await startPlugin('ui.multi');
    await bus.startUiWindow('ui.multi');
    await waitFor(() => bus.uiWindows().length == 2, reason: '应有 w1/w2 两个窗口');
    expect(
      bus.uiWindows().map((Map<String, dynamic> w) => w['window_id']).toSet(),
      <String>{'w1', 'w2'},
    );
    await waitForEvents('ui.multi', 'resume', 2);

    final PluginHotRestartResult result = await bus.hotRestart('ui.multi');
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isTrue, reason: result.reason);
    expect(
      result.windows.map((Map<String, dynamic> w) => w['window_id']).toSet(),
      <String>{'w1', 'w2'},
    );
    expect(
      result.windows.every((Map<String, dynamic> w) => w['resumed'] == true),
      isTrue,
      reason: '${result.windows}',
    );
    expect(
      bus.uiWindows().map((Map<String, dynamic> w) => w['window_id']).toSet(),
      <String>{'w1', 'w2'},
      reason: '重启后窗口号不得增长成 w3',
    );
    // 每个窗口的切片都带自己的窗口号（切片按窗口分，不串）
    final List<Map<String, dynamic>> resumes = await waitForEvents(
      'ui.multi',
      'resume',
      4,
    );
    final List<Map<String, dynamic>> snapshotted = resumes
        .where((Map<String, dynamic> e) => e['has_snapshot'] == true)
        .toList();
    expect(
      snapshotted
          .map(
            (Map<String, dynamic> e) =>
                (e['payload'] as Map<String, dynamic>)['window'],
          )
          .toSet(),
      <String>{'w1', 'w2'},
    );
  });

  test('迟到 hello（窗口号不在当前活窗口表里）被拒，并记一行日志', () async {
    writePlugins(entry('ui.late'));
    await startPlugin('ui.late');
    final int before = bus.uiWindows().length;
    bus.noteUiHello('ui.late', windowId: 'w9');
    expect(bus.uiWindows().length, before);
    expect(
      logs.any((String line) => line.contains('迟到 hello')),
      isTrue,
      reason: '迟到 hello 必须被拒并留痕：${logs.reversed.take(5).toList()}',
    );
  });
}
