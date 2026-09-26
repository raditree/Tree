import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **真可执行文件**冒烟测试（M7a）：门控运行。
///
/// 设 `TREE_CORE_EXE` 指向 `dart compile exe` 的产物即执行，否则跳过。
/// 单测已覆盖核心内部逻辑；这里验证的是"编译产物本身"：能启动、能在 stdout 打出
/// 单行握手、能用握手里的 token 访问回环 HTTP、能靠 stdin 的 shutdown 优雅退出。
/// 打包路径出问题（AOT 不支持某 API、工作目录差异、stdout 被污染）只有这一步能发现。
void main() {
  final String exe = Platform.environment['TREE_CORE_EXE'] ?? '';

  test('真 exe：握手 → HTTP 鉴权访问 → shutdown 优雅退出', () async {
    if (exe.isEmpty) {
      markTestSkipped('未设置 TREE_CORE_EXE，跳过真可执行文件冒烟测试');
      return;
    }
    expect(File(exe).existsSync(), isTrue, reason: 'TREE_CORE_EXE 指向的文件不存在');
    final Directory dataDir = Directory.systemTemp.createTempSync('tree_exe_');
    final Process process = await Process.start(exe, <String>[
      '--data-dir',
      dataDir.path,
      '--no-heartbeat',
    ]);
    // 失败路径也要收干净：泄漏的核心进程会干扰同一批次里的其它用例
    bool exited = false;
    addTearDown(() async {
      if (exited) return;
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    });
    final List<String> stderrLines = <String>[];
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);

    // 1) stdout 第一行必须是握手 JSON（stdout 是进程间协议，不能混日志）
    final String firstLine = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    final CoreHandshake? handshake = CoreHandshake.decode(firstLine);
    expect(handshake, isNotNull, reason: '第一行必须是握手：$firstLine');

    // 2) 握手里的 token 能访问回环 HTTP
    final HttpClient http = HttpClient();
    final HttpClientRequest request = await http.getUrl(
      Uri.parse('${handshake!.httpBaseUrl}${ApiPaths.agents}'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${handshake.token}',
    );
    final HttpClientResponse response = await request.close();
    final String body = await utf8.decoder.bind(response).join();
    expect(response.statusCode, 200, reason: '响应体：$body');
    expect(jsonDecode(body), isA<Map<String, dynamic>>());
    http.close(force: true);

    // 3) stdin 写 shutdown → 优雅退出（0）
    process.stdin.writeln('shutdown');
    await process.stdin.flush();
    final int code = await process.exitCode.timeout(
      const Duration(seconds: 30),
    );
    exited = true;
    expect(code, 0, reason: 'stderr：${stderrLines.join('\n')}');
    for (int i = 0; i < 5; i++) {
      try {
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
