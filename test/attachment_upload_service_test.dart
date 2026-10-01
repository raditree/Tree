// 附件上传（输入框 → agent 工作空间）的前端请求形状。
//
// 用一个假的"核心进程"（本机 HttpServer）验证：附件走的是协议声明的分片上传
// 三段式，请求体字段与核心校验口径一致，且整理出来的附件元数据（工作空间相对
// 路径 + 文件名 + 大小 + 类型）正是核心要写进提示词、也是文件工具接受的口径。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/io/attachment_upload_service.dart';

/// 假核心：实现分片上传三端点并记录收到的全部请求。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  final List<
    ({String method, String path, String query, Map<String, dynamic> body})
  >
  requests =
      <
        ({
          String method,
          String path,
          String query,
          Map<String, dynamic> body,
        })
      >[];

  /// 本次 upload_complete 是否成功（用例可切成失败态）。
  bool completeOk = true;

  /// 上传的字节数（用于断言分片内容确实是文件内容）。
  final List<int> uploadedBytes = <int>[];

  /// 最近一次 upload_init 收到的文件名（complete 时要回显成落盘路径）。
  String lastInitName = '';

  static Future<_FakeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeCore core = _FakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String rawBody = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = rawBody.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(rawBody) as Map<String, dynamic>;
    requests.add((
      method: request.method,
      path: request.uri.path,
      query: request.uri.query,
      body: body,
    ));

    final String path = request.uri.path;
    Map<String, dynamic> payload;
    int status = 200;
    if (path.endsWith('/upload_init')) {
      lastInitName = (body['file_name'] ?? '').toString();
      payload = <String, dynamic>{
        'upload_id': 'up_1',
        'chunk_size': 4,
        'path': '.input/20261001/$lastInitName',
      };
    } else if (path.endsWith('/upload_chunk')) {
      uploadedBytes.addAll(base64Decode(body['data'] as String));
      payload = <String, dynamic>{
        'received': true,
        'index': body['index'],
      };
    } else if (path.endsWith('/upload_complete')) {
      if (!completeOk) {
        status = 400;
        payload = <String, dynamic>{'detail': '分片不完整：已收到 0/5 字节'};
      } else {
        payload = <String, dynamic>{
          'success': true,
          'path': '.input/20261001/$lastInitName',
          'size': uploadedBytes.length,
        };
      }
    } else {
      status = 404;
      payload = <String, dynamic>{'detail': '未知路径：$path'};
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

void main() {
  late _FakeCore core;
  late Directory tempDir;

  setUp(() async {
    // flutter_test 默认装了 HttpOverrides：请求会被拦成 400、不真发出去。
    // 这里要打本机假核心（真 socket 往返），所以摘掉它。
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    tempDir = Directory.systemTemp.createTempSync('tree_attach_');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 造一个本机文件并返回路径。
  String writeLocal(String name, String content) {
    final File file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file.path;
  }

  test('纯函数：文件名（兼容 / 与 \\）与扩展名', () {
    expect(AttachmentUploadService.baseNameOf(r'C:\tmp\a\图片.PNG'), '图片.PNG');
    expect(AttachmentUploadService.baseNameOf('/tmp/a/b.tar.gz'), 'b.tar.gz');
    expect(AttachmentUploadService.extensionOf('图片.PNG'), 'png');
    expect(AttachmentUploadService.extensionOf('README'), '');
    expect(AttachmentUploadService.extensionOf('a.'), '');
  });

  test('上传单个文件：init → chunk(按 chunk_size 分片) → complete，返回工作空间相对路径', () async {
    final String local = writeLocal('a.txt', '0123456789'); // 10 字节，chunk_size=4 ⇒ 3 片
    final List<Map<String, dynamic>> result =
        await AttachmentUploadService.uploadAll('ws_1', <String>[local], teamId: 'agt_1');

    expect(result, hasLength(1));
    expect(result.single['name'], 'a.txt');
    expect(result.single['path'], '.input/20261001/a.txt');
    expect(result.single['size'], 10);
    expect(result.single['type'], 'txt');

    final List<String> steps = core.requests
        .map((({String method, String path, String query, Map<String, dynamic> body}) r) =>
            '${r.method} ${r.path.split('/').last}')
        .toList();
    expect(steps, <String>[
      'POST upload_init',
      'POST upload_chunk',
      'POST upload_chunk',
      'POST upload_chunk',
      'POST upload_complete',
    ], reason: '所有大小的文件都走同一条分片通道');

    // 请求体字段与核心口径一致
    final Map<String, dynamic> init = core.requests.first.body;
    expect(init['file_name'], 'a.txt');
    expect(init['rel_path'], '');
    expect(init['total_size'], 10);
    expect(core.requests.first.query, 'team_id=agt_1');
    expect(core.requests.last.body['total_chunks'], 3);
    expect(core.uploadedBytes.length, 10, reason: '分片内容应拼回原始字节');
  });

  test('多文件按顺序上传，元数据一项一个', () async {
    final String a = writeLocal('a.txt', 'aaa');
    final String b = writeLocal('b.png', 'bbbb');
    final List<Map<String, dynamic>> result =
        await AttachmentUploadService.uploadAll('ws_1', <String>[a, b]);

    expect(result.map((Map<String, dynamic> m) => m['name']).toList(), <String>[
      'a.txt',
      'b.png',
    ]);
    expect(result.map((Map<String, dynamic> m) => m['type']).toList(), <String>[
      'txt',
      'png',
    ]);
    expect(
      core.requests.where((({String method, String path, String query, Map<String, dynamic> body}) r) =>
          r.path.endsWith('/upload_init')).length,
      2,
    );
  });

  test('onFile 进度回调按文件粒度上报', () async {
    final String a = writeLocal('a.txt', 'x');
    final String b = writeLocal('b.txt', 'y');
    final List<String> progress = <String>[];
    await AttachmentUploadService.uploadAll(
      'ws_1',
      <String>[a, b],
      onFile: (int index, int total, String name) =>
          progress.add('$index/$total:$name'),
    );
    expect(progress, <String>['1/2:a.txt', '2/2:b.txt']);
  });

  test('上传失败：把核心的 detail 抛给调用方（面板据此不发消息、保留草稿）', () async {
    core.completeOk = false;
    final String local = writeLocal('a.txt', '0123456789');
    await expectLater(
      AttachmentUploadService.uploadAll('ws_1', <String>[local]),
      throwsA(
        predicate(
          (Object e) => e.toString().contains('分片不完整'),
          '异常里应带核心返回的 detail',
        ),
      ),
    );
  });
}
