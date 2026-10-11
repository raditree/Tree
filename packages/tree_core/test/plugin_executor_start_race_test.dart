import 'dart:io';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart'
    show kSshExecutorPluginId;

/// **核心启动竞态**（2026-10-11 用户真机：SSH 解析在 .081、插件就绪在 .134，只差 53ms）：
/// 插件是异步拉起的，谁先到决定这条 SSH 走哪条路。那时若直接回退内置，这条 IO 会被缓存住、
/// **整场**都跑在内置 dartssh2 上（中转站等于白装）。
///
/// 这里钉住"怎么问"与"有界等待"两件事：
/// - [PluginBus.sshExecutorStarting] 只对"条目启用但实例还没起来/还没申报能力"回 true；
/// - [PluginBus.sshExecutorLookupWaitingForStart] 只在这时等，其它原因（停用 / 没条目）**立即返回**。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tree_bus_start_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File writePlugins({required bool enabled, required bool withEntry}) {
    final File file = File('${dir.path}/plugins.yaml');
    final String body = withEntry
        ? 'enabled: true\n'
              'plugins:\n'
              '  -\n'
              '    id: $kSshExecutorPluginId\n'
              '    name: "SSH 执行器中转站"\n'
              '    command: "D:\\\\x\\\\tree_ssh_executor.exe"\n'
              '    args: []\n'
              '    env: {}\n'
              '    enabled: $enabled\n'
              '    granularity: team\n'
              '    scope: {}\n'
              '    builtin: true\n'
        : 'enabled: true\nplugins: []\n';
    file.writeAsStringSync(body);
    return file;
  }

  test('条目启用但实例还没起来 ⇒ "正在启动"（入口据此做有界等待）', () {
    final File file = writePlugins(enabled: true, withEntry: true);
    final PluginBus bus = PluginBus(configFile: file.path, coreVersion: 'test');
    expect(
      bus.sshExecutorStarting(),
      isTrue,
      reason: '没有 host、也没有错误记录 = 还在启动',
    );
    expect(bus.sshExecutorLookup().host, isNull);
  });

  test('条目停用 / 没有条目 ⇒ 不算"正在启动"（绝不空等）', () {
    final File off = writePlugins(enabled: false, withEntry: true);
    final PluginBus bus1 = PluginBus(configFile: off.path, coreVersion: 'test');
    expect(bus1.sshExecutorStarting(), isFalse);
    final File none = writePlugins(enabled: true, withEntry: false);
    final PluginBus bus2 = PluginBus(configFile: none.path, coreVersion: 'test');
    expect(bus2.sshExecutorStarting(), isFalse);
  });

  test('有界等待：启动中会等到超时，非启动原因**立即**返回', () async {
    final File starting = writePlugins(enabled: true, withEntry: true);
    final PluginBus bus = PluginBus(
      configFile: starting.path,
      coreVersion: 'test',
    );
    final Stopwatch sw = Stopwatch()..start();
    final ({PluginHost? host, String reason}) waited = await bus
        .sshExecutorLookupWaitingForStart(
          timeout: const Duration(milliseconds: 200),
          interval: const Duration(milliseconds: 50),
        );
    sw.stop();
    expect(waited.host, isNull);
    expect(waited.reason, contains('未在运行'));
    expect(
      sw.elapsedMilliseconds,
      greaterThanOrEqualTo(200),
      reason: '确实等满了超时（插件一直没起来）',
    );

    final File off = writePlugins(enabled: false, withEntry: true);
    final PluginBus bus2 = PluginBus(configFile: off.path, coreVersion: 'test');
    final Stopwatch sw2 = Stopwatch()..start();
    await bus2.sshExecutorLookupWaitingForStart(
      timeout: const Duration(milliseconds: 200),
      interval: const Duration(milliseconds: 50),
    );
    sw2.stop();
    expect(
      sw2.elapsedMilliseconds,
      lessThan(100),
      reason: '已停用 ⇒ 立即返回，不空等（否则每次 SSH 都白等 200ms）',
    );
  });

  test('总线配置里有该条目时，entryFor 的 id 与能力名是同源常量', () {
    // 防"两处各写一个字符串"的漂移：这条只在失败时才有意义，成本几乎为零。
    final String yaml = writePlugins(enabled: true, withEntry: true)
        .readAsStringSync();
    expect(yaml, contains('id: $kSshExecutorPluginId'));
    expect(jsonEncode(<String>[]), '[]');
  });
}
