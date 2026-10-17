import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 示例插件自建站点（`--self-station`）的端到端验证：
/// **真插件进程 + 真站点中枢**，确认「转发型订阅者」那条正解真的能跑起来。
///
/// 链路：插件的 `station/register`（自建广播站）→ `station/subscribe`
/// （用核心返回的 `station_id` 订自己）→ 站点上出现唯一订阅者。
///
/// 2026-10-17：这一份从 `examples/plugins/sample_plugin.py` 改跑插件仓的 Dart 入口
/// （**源码**，不是 `build/plugins/` 里的产物，理由同 `sample_plugin_layout_e2e_test`）。
/// 以前本机没有 Python 就整条静默跳过，现在只要有 Dart SDK 就真验一遍。
void main() {
  late Directory temp;

  /// 示例插件入口（插件仓里的 Dart 源码；测试 cwd = packages/tree_core）。
  final String sampleEntry = () {
    final String? repo = BuiltinPluginCatalog.repoRoot(Directory.current.path);
    return repo == null
        ? ''
        : p.normalize(p.join(repo, 'plugins', 'sample', 'sample_plugin.dart'));
  }();

  /// 插件仓未 clone（或没有这个入口）时才跳过。
  final String? missingEntry =
      sampleEntry.isEmpty || !File(sampleEntry).existsSync()
      ? '插件仓（tree-plugins）未 clone 或没有 plugins/sample/ 入口'
      : null;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_self_station_');
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上文件句柄可能还没释放，稍后重试
      }
    }
  });

  test('示例插件 --self-station：自建站点并订阅自己（id 由核心拼装）', () async {
    // 命令行用当前 Dart SDK 起插件源码（`dart <文件.dart>`）：这条用例要验的是
    // 「真插件进程 + 真站点中枢」，用产物 exe 就把依赖扩到了构建输出。
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 示例插件\n'
      '    command: "${_slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${_slash(sampleEntry)}", "--self-station", "--no-relay"]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n',
    );

    final List<String> logs = <String>[];
    final PluginBus bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
    addTearDown(bus.close);
    await bus.start();

    // 等插件把站建出来（插件起进程 → register → subscribe；最多 15s）
    const String expectedId = 'plugin.sample.broadcast.team_fanout';
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    StationInstance? station;
    while (DateTime.now().isBefore(deadline)) {
      station = bus.stations.station(expectedId);
      if (station != null && station.subscribers.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(
      station,
      isNotNull,
      reason: '插件应自建出 $expectedId；日志：${logs.join(' | ')}',
    );
    expect(station!.builtin, isFalse, reason: '自建站不是系统自带');
    expect(
      station.subscribers.single.pluginId,
      'sample',
      reason: '自建站的唯一订阅者就是建它的插件（转发型订阅者）',
    );
    expect(
      station.subscribers.single.scope.teamId,
      'team-1',
      reason: '订阅声明的归属来自 plugins.yaml',
    );
    // 自建站随中枢落盘（站点是持久化资源）
    expect(
      File(config.path.replaceAll('plugins.yaml', 'stations.yaml')).existsSync(),
      isTrue,
    );
  }, timeout: const Timeout(Duration(seconds: 90)), skip: missingEntry);
}

/// Windows 反斜杠转 `/`：yaml 里 `\\` 是转义，正斜杠两种平台都认。
String _slash(String path) => path.replaceAll(r'\', '/');
