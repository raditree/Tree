import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 片 D：UI 插件宿主（[UiHost]）的进程口径。
///
/// 与无头宿主刻意不同的地方都在这里钉住：注入 `TREE_CORE_URL` /
/// `TREE_CORE_TOKEN`、只采集 stdout/stderr、判活 = 进程是否退出。
void main() {
  late String probe;

  setUpAll(() {
    probe = p.join(Directory.current.path, 'test', 'fixtures', 'ui_probe.dart');
  });

  PluginConfig configFor({String command = '', List<String> args = const <String>[]}) =>
      PluginConfig(
        id: 'ui.probe',
        command: command.isEmpty ? Platform.resolvedExecutable : command,
        args: command.isEmpty ? <String>[probe, ...args] : args,
        env: <String, String>{'PROBE_ENV': 'marker-1'},
      );

  Future<void> waitUntil(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 10),
    String reason = '等待条件超时',
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    while (!predicate()) {
      if (watch.elapsed > timeout) fail('$reason（已等 ${watch.elapsed.inMilliseconds}ms）');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  final List<UiHost> hosts = <UiHost>[];
  tearDown(() async {
    for (final UiHost host in hosts) {
      if (!host.isClosed) {
        await host.kill('测试清理');
        await host.exited.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      }
    }
    hosts.clear();
  });

  Future<UiHost> startHost({
    List<String> args = const <String>[],
    String coreUrl = 'ws://127.0.0.1:12345',
    String coreToken = 'secret-token',
  }) async {
    final UiHost host = await UiHost.start(
      configFor(args: args),
      coreUrl: coreUrl,
      coreToken: coreToken,
    );
    hosts.add(host);
    return host;
  }

  test('启动注入 TREE_CORE_URL / TREE_CORE_TOKEN，其余 env 不丢；只收日志', () async {
    final UiHost host = await startHost();
    await waitUntil(
      () => host.stdoutTail.contains('PROBE_ENV=marker-1'),
      reason: 'UI 插件应能读到注入的环境变量',
    );
    expect(host.stdoutTail, contains('TREE_CORE_URL=ws://127.0.0.1:12345'));
    expect(host.stdoutTail, contains('TREE_CORE_TOKEN=secret-token'));
    expect(host.stdoutTail, contains('PROBE_ENV=marker-1'));
    await waitUntil(
      () => host.stderrTail.contains('PROBE_STDERR_MARKER'),
      reason: 'stderr 也要收进日志缓冲',
    );
    expect(host.isClosed, isFalse);
    expect(host.exitCode, isNull);
  });

  test('输出回调逐行触发：stdout / stderr 各走自己的回调（日志落盘接线用）', () async {
    final List<String> stdoutLines = <String>[];
    final List<String> stderrLines = <String>[];
    final UiHost host = await UiHost.start(
      configFor(),
      coreUrl: 'ws://127.0.0.1:12345',
      coreToken: 'secret-token',
      onStdoutLine: stdoutLines.add,
      onStderrLine: stderrLines.add,
    );
    hosts.add(host);
    await waitUntil(
      () => stdoutLines.any((String l) => l.contains('PROBE_ENV=marker-1')),
      reason: 'stdout 回调应逐行收到',
    );
    await waitUntil(
      () => stderrLines.any((String l) => l.contains('PROBE_STDERR_MARKER')),
      reason: 'stderr 回调应逐行收到',
    );
    // 回调是**副本**：环形缓冲的行为不变。
    expect(host.stdoutTail, contains('PROBE_ENV=marker-1'));
    expect(host.stderrTail, contains('PROBE_STDERR_MARKER'));
  });

  test('stop：核心发起停止 ⇒ stopRequested=true，进程真的退出', () async {
    final UiHost host = await startHost();
    await waitUntil(() => host.pid > 0);
    await host.stop();
    final int code = await host.exited.timeout(const Duration(seconds: 10));
    expect(host.isClosed, isTrue, reason: 'exit=$code');
    expect(host.stopRequested, isTrue);
  });

  test('kill：记录强制原因，进程退出但不算“正常停止”的自我退出', () async {
    final UiHost host = await startHost();
    await waitUntil(() => host.pid > 0);
    await host.kill('测试显式强杀');
    await host.exited.timeout(const Duration(seconds: 10));
    expect(host.isClosed, isTrue);
    expect(host.stopRequested, isTrue);
    expect(host.killReason, '测试显式强杀');
  });

  test('崩溃：非零退出码且 stopRequested=false（留给总线判 failed）', () async {
    final UiHost host = await startHost(args: const <String>['crash']);
    final int code = await host.exited.timeout(const Duration(seconds: 10));
    expect(code, 3);
    expect(host.exitCode, 3);
    expect(host.isClosed, isTrue);
    expect(host.stopRequested, isFalse, reason: '不是核心让它停的');
  });

  test('插件自己正常退出：exit 0，stopRequested=false', () async {
    final UiHost host = await startHost(args: const <String>['exit0']);
    final int code = await host.exited.timeout(const Duration(seconds: 10));
    expect(code, 0);
    expect(host.stopRequested, isFalse);
  });

  test('缺 command / 未接核心端点 ⇒ 可读失败，不拉起进程', () async {
    await expectLater(
      UiHost.start(PluginConfig(id: 'ui.empty', command: ''), coreUrl: 'ws://x', coreToken: 't'),
      throwsA(isA<PluginException>()),
    );
    await expectLater(
      UiHost.start(configFor(), coreUrl: '', coreToken: 't'),
      throwsA(isA<PluginException>()),
    );
    await expectLater(
      UiHost.start(configFor(), coreUrl: 'ws://x', coreToken: ''),
      throwsA(isA<PluginException>()),
    );
  });
}
