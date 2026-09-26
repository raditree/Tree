import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// CLI 端到端：真正启动子进程，验证"进程间契约"而不只是库函数。
///
/// 覆盖四类只有跑起来才暴露的问题：
/// 1. **stdout 协议纯净**：首行必须是单行握手 JSON，人类日志只能走 stderr；
/// 2. **信号兼容性**：Windows 无 SIGTERM，未捕获的 `SignalException` 会让
///    进程在打印握手后立即崩溃（父进程拿到端口却连不上）；
/// 3. **无 stdin 也能存活**：`Start-Process`/服务化/双击等启动方式下子进程
///    立刻读到 stdin EOF，若把 EOF 当退出信号，核心会刚启动就消失；
/// 4. **优雅退出**：父进程写一行 `shutdown` 后必须以 0 退出，否则应用退出
///    会留下孤儿核心进程。
void main() {
  test('CLI 启动核心：单行握手 + 鉴权 HTTP 可用 + shutdown 命令优雅退出', () async {
    // 显式隔离数据目录：绝不写真实用户的 %APPDATA%\Tree
    final Directory tempData = Directory.systemTemp.createTempSync('tree_cli_');
    final _CoreProcess core = await _CoreProcess.start(dataDir: tempData.path);
    addTearDown(core.dispose);
    addTearDown(() {
      if (tempData.existsSync()) tempData.deleteSync(recursive: true);
    });

    final CoreHandshake handshake = core.handshake;
    expect(handshake.port, greaterThan(0));
    expect(handshake.pid, greaterThan(0));
    expect(handshake.version, isNotEmpty);
    expect(handshake.token.length, greaterThanOrEqualTo(42));

    // 端口必须真的在监听：带 token 200、不带 token 401
    final (int, String) authorized = await core.get('/api/agents');
    expect(authorized.$1, 200, reason: authorized.$2);
    expect(jsonDecode(authorized.$2), <String, dynamic>{'agents': <dynamic>[]});

    final (int, String) unauthorized = await core.get(
      '/api/agents',
      withToken: false,
    );
    expect(unauthorized.$1, 401, reason: unauthorized.$2);

    // 未实现路径必须是明确的 501（前端有专门文案），而不是 404
    final (int, String) stub = await core.get('/api/files/ws_1');
    expect(stub.$1, 501, reason: stub.$2);

    // 控制通道：写一行 shutdown => 优雅退出（退出码 0）
    core.process.stdin.writeln('shutdown');
    await core.process.stdin.flush();
    final int exitCode = await core.process.exitCode.timeout(
      const Duration(seconds: 30),
    );
    expect(exitCode, 0);

    // stdout 只允许出现握手一行（协议纯净性）
    expect(
      core.stdoutLines.where((String line) => line.trim().isNotEmpty).toList(),
      hasLength(1),
      reason: 'stdout 被非协议输出污染：${core.stdoutLines}',
    );
    // 人类可读日志走 stderr（含数据目录提示）。
    // stderr 与 stdout 是两条独立管道，没有先后保证：必须轮询等待而不是立刻断言，
    // 否则偶发"日志还没到"就会误报失败。
    await _waitForStderr(core, 'listening on');
    final String stderrText = core.stderrLines.join('\n');
    expect(stderrText, contains('listening on'));
    expect(stderrText, contains('数据目录'));

    // 启动即建好 ~/.tree 目录骨架，方便用户直接打开查看/手改
    final String sep = Platform.pathSeparator;
    for (final String sub in <String>[
      'config',
      'config${sep}models',
      'agents',
      'data',
    ]) {
      expect(
        Directory('${tempData.path}$sep$sub').existsSync(),
        isTrue,
        reason: '缺少目录：$sub',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('stdin 关闭（无控制通道）不会终止核心进程', () async {
    final Directory tempData = Directory.systemTemp.createTempSync('tree_cli_');
    final _CoreProcess core = await _CoreProcess.start(dataDir: tempData.path);
    addTearDown(core.dispose);
    addTearDown(() {
      if (tempData.existsSync()) tempData.deleteSync(recursive: true);
    });
    // 模拟 Start-Process / 任务计划 / 双击：父进程不提供 stdin
    await core.process.stdin.close();
    // 给足退出时机：若 EOF 被当成退出信号，进程会在此窗口内消失
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      await _tryExitCode(core.process),
      isNull,
      reason: '核心不应因 stdin EOF 退出\nstderr：${core.stderrLines.join('\n')}',
    );
    final (int, String) res = await core.get('/api/agents');
    expect(res.$1, 200, reason: '控制通道关闭后仍须继续服务：${res.$2}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 轮询等待 stderr 出现某段文本（两条管道无顺序保证）。
Future<void> _waitForStderr(
  _CoreProcess core,
  String needle, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (core.stderrLines.join('\n').contains(needle)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 已启动并完成握手的核心子进程。
class _CoreProcess {
  _CoreProcess._(this.process, this.handshake, this.dataDir);

  final Process process;
  final CoreHandshake handshake;

  /// 传入的数据根目录（null = 平台默认，测试始终显式传入以避免写到真实用户目录）。
  final String? dataDir;
  final List<String> stdoutLines = <String>[];
  final List<String> stderrLines = <String>[];
  late final HttpClient _client;
  late final StreamSubscription<String> _outSub;
  late final StreamSubscription<String> _errSub;

  static Future<_CoreProcess> start({String? dataDir}) async {
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        'run',
        'bin/tree_core.dart',
        '--chunk-delay-ms',
        '0',
        '--no-heartbeat',
        if (dataDir != null) ...<String>['--data-dir', dataDir],
      ],
      workingDirectory: Directory.current.path,
    );
    final _CoreProcess core = _CoreProcess._(
      process,
      // 占位，随后被真实握手替换
      const CoreHandshake(port: 0, token: '', pid: 0, version: ''),
      dataDir,
    );
    core._outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(core.stdoutLines.add);
    core._errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(core.stderrLines.add);
    core._client = HttpClient();
    final CoreHandshake handshake = await _waitForHandshake(core);
    return _CoreProcess._(process, handshake, dataDir)
      ..stdoutLines.addAll(core.stdoutLines)
      ..stderrLines.addAll(core.stderrLines)
      .._outSub = core._outSub
      .._errSub = core._errSub
      .._client = core._client;
  }

  Future<(int, String)> get(String path, {bool withToken = true}) => _get(
    _client,
    '${handshake.httpBaseUrl}$path',
    token: withToken ? handshake.token : null,
  );

  Future<void> dispose() async {
    process.kill(ProcessSignal.sigkill);
    await _outSub.cancel();
    await _errSub.cancel();
    _client.close(force: true);
  }
}

Future<CoreHandshake> _waitForHandshake(_CoreProcess core) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    for (final String line in core.stdoutLines) {
      final CoreHandshake? handshake = CoreHandshake.decode(line);
      if (handshake != null) return handshake;
    }
    if (core.stdoutLines.isNotEmpty) {
      // 已有 stdout 输出但不是合法握手：直接失败，避免白等到超时
      if (CoreHandshake.decode(core.stdoutLines.first) == null) {
        throw StateError(
          'stdout 首行不是合法握手：${core.stdoutLines.first}\n'
          'stderr：${core.stderrLines.join('\n')}',
        );
      }
    }
    // 子进程已退出却没给握手：立即失败并带上 stderr
    final int? pending = await _tryExitCode(core.process);
    if (pending != null) {
      throw StateError(
        '核心进程提前退出（exit=$pending）\n'
        'stdout：${core.stdoutLines}\nstderr：${core.stderrLines.join('\n')}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
    '等待握手超时\nstdout：${core.stdoutLines}\n'
    'stderr：${core.stderrLines.join('\n')}',
  );
}

/// 非阻塞地取退出码：未退出返回 null。
Future<int?> _tryExitCode(Process process) async {
  try {
    return await process.exitCode.timeout(Duration.zero);
  } on TimeoutException {
    return null;
  }
}

Future<(int, String)> _get(
  HttpClient client,
  String url, {
  String? token,
}) async {
  final HttpClientRequest request = await client.getUrl(Uri.parse(url));
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  final HttpClientResponse response = await request.close();
  final String body = await utf8.decoder.bind(response).join();
  return (response.statusCode, body);
}
