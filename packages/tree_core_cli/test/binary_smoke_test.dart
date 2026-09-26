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

  test('真 exe：文件写路径贯通（分片上传 → tar.gz 打包下载 → 同步到本地）', () async {
    if (exe.isEmpty) {
      markTestSkipped('未设置 TREE_CORE_EXE，跳过真可执行文件文件写路径测试');
      return;
    }
    expect(File(exe).existsSync(), isTrue, reason: 'TREE_CORE_EXE 指向的文件不存在');
    final Directory dataDir = Directory.systemTemp.createTempSync('tree_exe_');
    final Directory workspace = Directory.systemTemp.createTempSync(
      'tree_exe_ws_',
    );
    final Directory syncOut = Directory.systemTemp.createTempSync(
      'tree_exe_sync_',
    );
    final (Process process, CoreHandshake handshake, _Exe client) =
        await _startExe(exe, dataDir);
    // 失败路径也要收干净：泄漏的核心进程会干扰同一批次里的其它用例
    addTearDown(() async {
      client.close();
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
      for (final Directory dir in <Directory>[dataDir, workspace, syncOut]) {
        for (int i = 0; i < 5; i++) {
          try {
            if (dir.existsSync()) dir.deleteSync(recursive: true);
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    });

    // ① 建模型 + agent，并把工作空间指到临时目录（顺带验证配置写路径在 exe 里可用）
    final (int modelStatus, Map<String, dynamic> model) = await client.postJson(
      ApiPaths.models,
      <String, dynamic>{
        'model_id': 'smoke-model',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-smoke',
      },
    );
    expect(modelStatus, 200, reason: '建模型失败：$model');
    final (int createStatus, Map<String, dynamic> created) = await client
        .postJson(ApiPaths.agents, <String, dynamic>{
          'name': '冒烟',
          'model_id': 'smoke-model',
        });
    expect(createStatus, 200, reason: '建档失败：$created');
    // 前端形态的键是 `id`（见 CoreAgent.toApiJson）
    final String agentId =
        (created['agent'] as Map<String, dynamic>)['id'] as String;
    final (int patchStatus, Map<String, dynamic> patched) = await client
        .patchJson(
          ApiPaths.agent.replaceAll('{agentId}', agentId),
          <String, dynamic>{'workspace_dir': workspace.path},
        );
    expect(patchStatus, 200, reason: '设置工作空间失败：$patched');

    // ② 分片上传：700 字节拆两块（第二块故意小于定标分片大小）
    final List<int> payload = List<int>.generate(700, (int i) => i % 256);
    String path(String template) =>
        template.replaceAll('{workspaceId}', agentId);
    final (int initStatus, Map<String, dynamic> init) = await client.postJson(
      path(ApiPaths.fileUploadInit),
      <String, dynamic>{
        'file_name': '冒烟.bin',
        'rel_path': '资料',
        'total_size': payload.length,
      },
    );
    expect(initStatus, 200, reason: 'upload_init 失败：$init');
    final String uploadId = init['upload_id'] as String;
    for (int i = 0; i < 2; i++) {
      final List<int> part = i == 0
          ? payload.sublist(0, 400)
          : payload.sublist(400);
      final (int status, Map<String, dynamic> chunk) = await client.postJson(
        path(ApiPaths.fileUploadChunk),
        <String, dynamic>{
          'upload_id': uploadId,
          'index': i,
          'data': base64Encode(part),
        },
      );
      expect(status, 200, reason: 'upload_chunk 失败：$chunk');
    }
    final (int doneStatus, Map<String, dynamic> done) = await client.postJson(
      path(ApiPaths.fileUploadComplete),
      <String, dynamic>{'upload_id': uploadId, 'total_chunks': 2},
    );
    expect(doneStatus, 200, reason: 'upload_complete 失败：$done');
    final String rel = done['path'] as String;
    final File saved = File(
      '${workspace.path}/${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(saved.existsSync(), isTrue, reason: '上传后文件没有落盘：$rel');
    expect(saved.readAsBytesSync(), payload);

    // ③ 打包下载：真 exe 必须能起得动系统 tar（安装器里 PATH 是高风险点）。
    //    上传落点是 `.input/{日期}/资料/冒烟.bin`，所以打包的是它的父目录。
    final String folder = rel.substring(0, rel.lastIndexOf('/'));
    final (int folderStatus, List<int> archive) = await client.postRaw(
      path(ApiPaths.fileDownloadFolder),
      <String, dynamic>{'path': folder},
    );
    expect(folderStatus, 200);
    expect(archive.take(2).toList(), <int>[
      0x1f,
      0x8b,
    ], reason: 'tar.gz 必须以 gzip 魔数开头（否则是文本模式把二进制改坏了）');
    final String listing = utf8.decode(
      gzip.decode(archive),
      allowMalformed: true,
    );
    expect(listing, contains('冒烟.bin'));

    // ④ 同步到本地：整棵工作空间复制过去
    final (int syncStatus, Map<String, dynamic> sync) = await client.postJson(
      path(ApiPaths.fileSyncToLocal),
      <String, dynamic>{'local_path': syncOut.path},
    );
    expect(syncStatus, 200, reason: 'syncToLocal 失败：$sync');
    expect(sync['files'], greaterThanOrEqualTo(1));
    final File localCopy = File(
      '${syncOut.path}/${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(localCopy.existsSync(), isTrue, reason: '同步后本地缺文件：$rel');

    // ⑤ 优雅退出
    process.stdin.writeln('shutdown');
    await process.stdin.flush();
    expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 启动真 exe 并等出握手；同时准备 HTTP 客户端。
Future<(Process, CoreHandshake, _Exe)> _startExe(
  String exe,
  Directory dataDir,
) async {
  final Process process = await Process.start(exe, <String>[
    '--data-dir',
    dataDir.path,
    '--no-heartbeat',
    // 请求级日志：失败信息里能直接看到核心给这个请求回了什么状态码
    '--verbose',
  ]);
  final List<String> stderrLines = <String>[];
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(stderrLines.add);
  final String firstLine = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 30));
  final CoreHandshake? handshake = CoreHandshake.decode(firstLine);
  expect(handshake, isNotNull, reason: '第一行必须是握手：$firstLine');
  return (process, handshake!, _Exe(handshake, stderrLines));
}

/// 最小 HTTP 客户端：带 token 的 JSON POST/PATCH 与原始字节 POST。
///
/// 任何请求失败都把核心的 stderr 拼进异常：真 exe 的问题（起不动 tar、AOT 不
/// 支持的 API）只有核心自己的日志说得清，光看 "Connection closed" 无从下手。
class _Exe {
  _Exe(this.handshake, this.stderrLines) : _client = HttpClient();

  final CoreHandshake handshake;
  final List<String> stderrLines;
  final HttpClient _client;

  Future<(int, Map<String, dynamic>)> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final (int status, List<int> bytes) = await _send('POST', path, body);
    return (status, _asJson(bytes));
  }

  Future<(int, Map<String, dynamic>)> patchJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final (int status, List<int> bytes) = await _send('PATCH', path, body);
    return (status, _asJson(bytes));
  }

  Future<(int, List<int>)> postRaw(String path, Map<String, dynamic> body) =>
      _send('POST', path, body);

  Future<(int, List<int>)> _send(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final HttpClientRequest request = await _client.openUrl(
        method,
        Uri.parse('${handshake.httpBaseUrl}$path'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${handshake.token}',
      );
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final HttpClientResponse response = await request.close();
      final List<int> bytes = await response.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      return (response.statusCode, bytes);
    } catch (error) {
      throw StateError(
        '$method $path 失败：$error\n'
        '核心 stderr：\n${stderrLines.join('\n')}',
      );
    }
  }

  static Map<String, dynamic> _asJson(List<int> bytes) {
    final String text = utf8.decode(bytes, allowMalformed: true);
    if (text.trim().isEmpty) return <String, dynamic>{};
    final Object? decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  void close() => _client.close(force: true);
}
