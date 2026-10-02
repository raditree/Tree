import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 轻量 HTTP 客户端（与 files_api_test.dart 同一套写法；这里多支持 PUT）。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final HttpClientResponse response = await request.close();
    final List<int> raw = await response.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final String text = utf8.decode(raw, allowMalformed: true);
    Object? decoded;
    try {
      decoded = text.trim().isEmpty ? null : jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    return _Res(
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
      text,
      raw,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json, this.raw, this.bytes);
  final int status;
  final Map<String, dynamic> json;
  final String raw;
  final List<int> bytes;
}

/// 「写文本文件」的 REST 面（PUT /api/files/{id}/content）。
///
/// 本机走本机工作空间 IO、远端走 WorkspaceIO（用假后端，**绝不真连 SSH**）；
/// 覆盖契约里的成功 / 冲突 / 各类 400 / 上限 / 目标不存在。
void main() {
  /// 回车换行用 char code 构造，源码里不出现转义写法，读断言时看变量名即可。
  final String lf = String.fromCharCodes(<int>[10]);
  final String crlf = String.fromCharCodes(<int>[13, 10]);

  late Directory temp;
  late MemoryStore store;
  late CoreAgent agent;
  late CoreServer server;
  late _Client client;

  /// [wireRemote] false = 配了 ssh 但核心没接远端后端（应给可读 400）。
  /// [backend] 可换成任意远端后端对象（这里注入 LocalWorkspaceIO 当假 SSH）。
  Future<void> start({
    bool ssh = false,
    bool wireRemote = true,
    Object? backend,
    int? maxWriteBytes,
  }) async {
    temp = Directory.systemTemp.createTempSync('tree_write_');
    File('${temp.path}/a.txt').writeAsStringSync('hello$lf世界$lf');
    File(
      '${temp.path}/crlf.txt',
    ).writeAsStringSync('第一行$crlf第二行$crlf');
    File(
      '${temp.path}/pixel.png',
    ).writeAsBytesSync(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
    File('${temp.path}/doc.pdf').writeAsStringSync('%PDF-1.4$lf');
    File('${temp.path}/book.docx').writeAsBytesSync(<int>[80, 75, 3, 4]);
    File('${temp.path}/pack.zip').writeAsBytesSync(<int>[80, 75, 3, 4]);
    File('${temp.path}/nul.txt').writeAsBytesSync(<int>[104, 0, 105]);
    store = MemoryStore();
    agent = store.createAgent(name: '写文件用例');
    agent.workspaceDir = temp.path;
    if (ssh) {
      agent.sshConfig = const SshConfig(
        host: 'remote.example.com',
        username: 'u',
        password: 'p',
      );
    }
    store.putAgent(agent);
    server = await CoreServer.start(
      store: store,
      fileService: FileService(
        store: store,
        defaultWorkspaceDir: (String _) => temp.path,
        remoteFilesFor: ssh && wireRemote ? (String _) async => backend : null,
        maxWriteBytes: maxWriteBytes ?? FileService.defaultMaxWriteBytes,
      ),
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    client = _Client(server);
  }

  tearDown(() async {
    client.close();
    await server.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String ws() => agent.workspaceId;

  /// 写接口的完整 URL（路径按查询串编码，中文名也安全）。
  String contentUrl(String path, {String extra = ''}) =>
      '/api/files/${ws()}/content?path=${Uri.encodeQueryComponent(path)}$extra';

  test('本机写成功：中文 UTF-8、CRLF 原样、读回一致、size/written 正确', () async {
    await start();
    final String text = '你好，世界$crlf第二行$crlf';
    final _Res res = await client.send(
      'PUT',
      contentUrl('源码/新建.md'),
      body: <String, dynamic>{'content': text},
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['success'], true);
    expect(res.json['path'], '源码/新建.md');
    expect(res.json['size'], utf8.encode(text).length);
    expect(res.json['written'], utf8.encode(text).length);

    final File saved = File('${temp.path}/源码/新建.md');
    expect(saved.existsSync(), isTrue);
    expect(
      saved.readAsBytesSync(),
      utf8.encode(text),
      reason: 'UTF-8 字节、CRLF 不被规范化、不补尾换行',
    );

    final _Res back = await client.send(
      'GET',
      '/api/files/${ws()}/content?path=${Uri.encodeQueryComponent('源码/新建.md')}',
    );
    expect(back.status, 200, reason: back.raw);
    expect(back.json['content'], text, reason: '写完读回必须一模一样');
    expect(back.json['size'], utf8.encode(text).length);

    // 覆盖已有 UTF-8 文件：同样保留 CRLF，且不补尾换行
    final String over = '一$crlf二';
    final _Res again = await client.send(
      'PUT',
      contentUrl('crlf.txt'),
      body: <String, dynamic>{
        'content': over,
        'if_size': utf8.encode('第一行$crlf第二行$crlf').length,
      },
    );
    expect(again.status, 200, reason: again.raw);
    expect(File('${temp.path}/crlf.txt').readAsBytesSync(), utf8.encode(over));
  });

  test('远端没有可用后端：可读 400，落不到本机工作目录', () async {
    await start(ssh: true, wireRemote: false);
    final _Res res = await client.send(
      'PUT',
      contentUrl('a.txt'),
      body: <String, dynamic>{'content': '不该写进去'},
    );
    expect(res.status, 400, reason: res.raw);
    expect(jsonEncode(res.json), contains('远端'));
    expect(res.json['detail'], isNotEmpty);
    expect(
      File('${temp.path}/a.txt').readAsStringSync(),
      'hello$lf世界$lf',
      reason: '远端不可用时不能偷偷写到本机目录',
    );
  });

  test('远端有后端：走 WorkspaceIO.writeFile 落盘（假后端，不真连 SSH）', () async {
    final Directory remoteDir = Directory.systemTemp.createTempSync(
      'tree_write_remote_',
    );
    addTearDown(() {
      if (remoteDir.existsSync()) remoteDir.deleteSync(recursive: true);
    });
    final String old = '远端旧内容$lf';
    File('${remoteDir.path}/a.txt').writeAsStringSync(old);
    await start(ssh: true, backend: LocalWorkspaceIO(remoteDir.path));

    final String text = '远端新内容$crlf第二行';
    final _Res res = await client.send(
      'PUT',
      contentUrl('a.txt'),
      body: <String, dynamic>{
        'content': text,
        'if_size': utf8.encode(old).length,
      },
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['size'], utf8.encode(text).length);
    expect(File('${remoteDir.path}/a.txt').readAsBytesSync(), utf8.encode(text));

    final _Res back = await client.send(
      'GET',
      '/api/files/${ws()}/content?path=a.txt',
    );
    expect(back.json['content'], text);
  });

  test('图片 / PDF / Office / 压缩包 / 含 NUL 的文件一律拒绝', () async {
    await start();
    final List<(String, String)> probes = <(String, String)>[
      ('pixel.png', '图片'),
      ('doc.pdf', 'PDF'),
      ('book.docx', 'Office'),
      ('pack.zip', '压缩包'),
      ('nul.txt', '含 NUL 的文本'),
    ];
    for (final (String, String) probe in probes) {
      final _Res res = await client.send(
        'PUT',
        contentUrl(probe.$1),
        body: <String, dynamic>{'content': '覆盖成文本'},
      );
      expect(
        res.status,
        400,
        reason: '${probe.$1}（${probe.$2}）→ ${res.raw}',
      );
      expect(res.json['error'], isNotEmpty);
      expect(res.json['detail'], isNotEmpty);
    }
    expect(
      File('${temp.path}/pixel.png').readAsBytesSync(),
      <int>[137, 80, 78, 71, 13, 10, 26, 10],
      reason: '被拒绝的文件必须原样保留',
    );
    expect(File('${temp.path}/nul.txt').readAsBytesSync(), <int>[104, 0, 105]);
  });

  test('空路径 / .. 逃逸 / 盘符 / 绝对路径：一律 400', () async {
    await start();
    final List<String> bad = <String>[
      '',
      '../escape.txt',
      'C:/windows/win.ini',
      '/etc/passwd',
    ];
    for (final String path in bad) {
      final _Res res = await client.send(
        'PUT',
        contentUrl(path),
        body: <String, dynamic>{'content': 'x'},
      );
      expect(res.status, 400, reason: '$path 应当拒绝 → ${res.raw}');
      expect(res.json['detail'], isNotEmpty);
    }
    expect(File('${temp.path}/../escape.txt').existsSync(), isFalse);
  });

  test('if_size 不符 → 409 + 当前 size；force=1 跳过检查', () async {
    await start();
    final int current = File('${temp.path}/a.txt').lengthSync();
    final _Res conflict = await client.send(
      'PUT',
      contentUrl('a.txt'),
      body: <String, dynamic>{'content': '新内容', 'if_size': current + 5},
    );
    expect(conflict.status, 409, reason: conflict.raw);
    expect(conflict.json['error'], 'conflict');
    expect(conflict.json['size'], current);
    expect(conflict.json['detail'], contains('外部修改'));
    expect(
      File('${temp.path}/a.txt').readAsStringSync(),
      'hello$lf世界$lf',
      reason: '冲突时绝不能落盘',
    );

    final _Res ok = await client.send(
      'PUT',
      contentUrl('a.txt'),
      body: <String, dynamic>{'content': '新内容', 'if_size': current},
    );
    expect(ok.status, 200, reason: ok.raw);
    expect(File('${temp.path}/a.txt').readAsStringSync(), '新内容');

    final _Res forced = await client.send(
      'PUT',
      contentUrl('a.txt', extra: '&force=1'),
      body: <String, dynamic>{'content': '强制覆盖', 'if_size': 999999},
    );
    expect(forced.status, 200, reason: forced.raw);
    expect(File('${temp.path}/a.txt').readAsStringSync(), '强制覆盖');
  });

  test('新内容超过 maxWriteBytes 拒绝；刚好等于上限可以写', () async {
    await start(maxWriteBytes: 64);
    expect(
      FileService.defaultMaxWriteBytes,
      4 * 1024 * 1024,
      reason: '默认上限是 4 MB',
    );

    final _Res tooBig = await client.send(
      'PUT',
      contentUrl('big.txt'),
      body: <String, dynamic>{
        'content': List<String>.filled(65, 'a').join(),
      },
    );
    expect(tooBig.status, 400, reason: tooBig.raw);
    expect(tooBig.json['error'], 'too_large');
    expect(tooBig.json['detail'], contains('上限'));
    expect(File('${temp.path}/big.txt').existsSync(), isFalse);

    final _Res atLimit = await client.send(
      'PUT',
      contentUrl('big.txt'),
      body: <String, dynamic>{
        'content': List<String>.filled(64, 'a').join(),
      },
    );
    expect(atLimit.status, 200, reason: atLimit.raw);
    expect(atLimit.json['written'], 64);
  });

  test('目标文件不存在：不带 if_size 直接创建；带 if_size 算冲突', () async {
    await start();
    final _Res created = await client.send(
      'PUT',
      contentUrl('新目录/新文件.txt'),
      body: <String, dynamic>{'content': '新文件'},
    );
    expect(created.status, 200, reason: created.raw);
    expect(created.json['path'], '新目录/新文件.txt');
    expect(created.json['size'], utf8.encode('新文件').length);
    expect(File('${temp.path}/新目录/新文件.txt').readAsStringSync(), '新文件');

    final _Res conflict = await client.send(
      'PUT',
      contentUrl('不存在.txt'),
      body: <String, dynamic>{'content': 'x', 'if_size': 0},
    );
    expect(conflict.status, 409, reason: conflict.raw);
    expect(conflict.json['error'], 'conflict');
    expect(
      conflict.json.containsKey('size'),
      isFalse,
      reason: '文件已不存在时不带 size：前端据此判定 missing（currentSize == null）',
    );
    expect(conflict.json['detail'], contains('不存在'));
    expect(File('${temp.path}/不存在.txt').existsSync(), isFalse);

    final _Res forced = await client.send(
      'PUT',
      contentUrl('不存在.txt', extra: '&force=1'),
      body: <String, dynamic>{'content': 'x', 'if_size': 0},
    );
    expect(forced.status, 200, reason: forced.raw);
    expect(File('${temp.path}/不存在.txt').readAsStringSync(), 'x');
  });

  test('请求体缺 content：可读 400 且不落盘', () async {
    await start();
    final _Res res = await client.send(
      'PUT',
      contentUrl('a.txt'),
      body: <String, dynamic>{'if_size': 1},
    );
    expect(res.status, 400, reason: res.raw);
    expect(res.json['error'], 'invalid_body');
    expect(
      File('${temp.path}/a.txt').readAsStringSync(),
      'hello$lf世界$lf',
    );
  });
}
