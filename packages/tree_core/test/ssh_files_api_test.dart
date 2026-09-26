import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

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

/// 内存版远端文件系统（M7g）：只实现文件面板需要的三个操作。
class _FakeRemote implements WorkspaceFiles {
  final Map<String, List<int>> files = <String, List<int>>{};

  /// 写入过的相对路径（断言 SFTP 落点用）。
  final List<String> writes = <String>[];

  void seed(String rel, String content) => files[rel] = utf8.encode(content);

  void seedBytes(String rel, List<int> bytes) => files[rel] = bytes;

  void _guard(String rel) {
    if (rel.startsWith('/') || rel.startsWith('~') || rel.contains('..')) {
      throw WorkspacePathException(rel, '越出工作空间根目录');
    }
  }

  @override
  Future<List<WorkspaceEntry>> listEntries(
    String relativePath, {
    int maxEntries = 2000,
  }) async {
    _guard(relativePath);
    final String prefix = relativePath.isEmpty ? '' : '$relativePath/';
    final Map<String, WorkspaceEntry> byName = <String, WorkspaceEntry>{};
    final DateTime stamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    for (final MapEntry<String, List<int>> entry in files.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final String rest = entry.key.substring(prefix.length);
      if (rest.isEmpty) continue;
      final int slash = rest.indexOf('/');
      final String name = slash < 0 ? rest : rest.substring(0, slash);
      byName[name] = WorkspaceEntry(
        name: name,
        relativePath: '$prefix$name',
        isDirectory: slash >= 0,
        size: slash >= 0 ? 0 : entry.value.length,
        modified: stamp,
      );
    }
    if (byName.isEmpty && relativePath.isNotEmpty) {
      // 真实 SFTP listdir 在目录不存在时会报错（不会给空列表），这里照做，
      // 免得测试把「目录不存在」当成「空目录」放过去
      throw WorkspaceIoException('目录不存在：$relativePath');
    }
    final List<WorkspaceEntry> out = byName.values.toList()
      ..sort((WorkspaceEntry a, WorkspaceEntry b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    return out.length > maxEntries ? out.sublist(0, maxEntries) : out;
  }

  @override
  Future<Uint8List> readBytes(String relativePath) async {
    _guard(relativePath);
    final List<int>? bytes = files[relativePath];
    if (bytes == null) {
      throw WorkspaceIoException('文件不存在：$relativePath');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    _guard(relativePath);
    files[relativePath] = List<int>.of(bytes);
    writes.add(relativePath);
  }
}

/// SSH 工作空间的文件面板 REST 面（M7g）：用内存远端后端验证分流与语义。
///
/// 真 dartssh2/SFTP 那一层由 ssh_files_integration_test.dart 门控真机测试覆盖；
/// 这里覆盖的是"配了 ssh 的 agent 走远端后端"这条接线，以及本地路径零回归。
void main() {
  late MemoryStore store;
  late CoreAgent agent;
  late _FakeRemote remote;
  late CoreServer server;
  late _Client client;

  Future<void> start({bool wireRemote = true}) async {
    store = MemoryStore();
    agent = store.createAgent(name: '远端用例', modelId: 'demo');
    agent.sshConfig = const SshConfig(
      host: 'remote.example.com',
      port: 22,
      username: 'open',
      keyPath: '/home/open/.ssh/id_ed25519',
    );
    agent.workspaceDir = '/mnt/space/project';
    store.putAgent(agent);
    remote = _FakeRemote()
      ..seed('a.txt', 'hello\n世界\n')
      ..seed('sub/b.md', '# 标题')
      ..seedBytes('pixel.png', <int>[137, 80, 78, 71])
      ..seed(
        'doc.pdf',
        '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
            '2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >> endobj\n'
            '3 0 obj << /Type /Page >> endobj\n'
            '4 0 obj << /Type /Page >> endobj\n',
      );
    server = await CoreServer.start(
      store: store,
      fileService: FileService(
        store: store,
        defaultWorkspaceDir: (String _) => '/mnt/space/project',
        remoteFilesFor: wireRemote ? (String _) async => remote : null,
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
  });

  String ws() => agent.workspaceId;

  test('list：远端一层目录，字段与本地口径一致', () async {
    await start();
    final _Res res = await client.send('GET', '/api/files/${ws()}');
    expect(res.status, 200, reason: res.raw);
    final List<dynamic> files = res.json['files'] as List<dynamic>;
    final List<String> names = files
        .map((dynamic e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
    expect(names.first, 'sub', reason: '目录在前');
    expect(
      names,
      containsAll(<String>['a.txt', 'doc.pdf', 'pixel.png', 'sub']),
    );
    final Map<String, dynamic> txt = files.firstWhere(
      (dynamic e) => (e as Map<String, dynamic>)['name'] == 'a.txt',
    ) as Map<String, dynamic>;
    expect(txt['type'], 'file');
    expect(txt['size'], greaterThan(0));
    expect(txt['path'], 'a.txt');
    expect(txt['modified'], isNotEmpty);
  });

  test('content / download / pdf_info：远端字节读回后与本地同解析', () async {
    await start();
    final _Res text = await client.send(
      'GET',
      '/api/files/${ws()}/content?path=a.txt',
    );
    expect(text.json['content'], 'hello\n世界\n');
    expect(text.json['encoding'], 'utf-8');

    final _Res image = await client.send(
      'GET',
      '/api/files/${ws()}/content?path=pixel.png',
    );
    expect(image.json['encoding'], 'base64');
    expect(base64Decode(image.json['content'] as String), <int>[
      137,
      80,
      78,
      71,
    ]);

    final _Res download = await client.send(
      'POST',
      '/api/files/${ws()}/download',
      body: <String, dynamic>{'path': 'a.txt'},
    );
    expect(download.status, 200);
    expect(download.raw, contains('hello'));

    final _Res pdf = await client.send(
      'GET',
      '/api/files/${ws()}/pdf_info?path=doc.pdf',
    );
    expect(pdf.status, 200, reason: pdf.raw);
    expect(pdf.json['total_pages'], 2);
    expect(pdf.json['pages_source'], 'count');
  });

  test('路径逃逸与缺文件：远端同样只有可读错误', () async {
    await start();
    expect(
      (await client.send(
        'GET',
        '/api/files/${ws()}/content?path=../escape.txt',
      )).status,
      400,
    );
    expect(
      (await client.send(
        'GET',
        '/api/files/${ws()}/content?path=missing.txt',
      )).status,
      404,
    );
    expect(
      (await client.send('GET', '/api/files/${ws()}?path=missing')).status,
      404,
      reason: '远端目录不存在与本地同口径，不假装是空目录',
    );
  });

  test('分片上传：本地暂存，complete 时一次写远端 .input/', () async {
    await start();
    final List<int> payload = List<int>.generate(300, (int i) => i % 256);
    final _Res init = await client.send(
      'POST',
      '/api/files/${ws()}/upload_init',
      body: <String, dynamic>{
        'file_name': 'big.bin',
        'rel_path': '资料',
        'total_size': payload.length,
      },
    );
    expect(init.status, 200, reason: init.raw);
    final String uploadId = init.json['upload_id'] as String;
    for (int i = 0; i < 2; i++) {
      final List<int> part = i == 0
          ? payload.sublist(0, 100)
          : payload.sublist(100);
      final _Res chunk = await client.send(
        'POST',
        '/api/files/${ws()}/upload_chunk',
        body: <String, dynamic>{
          'upload_id': uploadId,
          'index': i,
          'data': base64Encode(part),
        },
      );
      expect(chunk.status, 200, reason: chunk.raw);
    }
    final _Res done = await client.send(
      'POST',
      '/api/files/${ws()}/upload_complete',
      body: <String, dynamic>{'upload_id': uploadId, 'total_chunks': 2},
    );
    expect(done.status, 200, reason: done.raw);
    final String rel = done.json['path'] as String;
    expect(rel, startsWith('.input/'));
    expect(remote.writes, <String>[rel], reason: 'complete 时才写一次远端');
    expect(remote.files[rel], payload);
  });

  test('download_folder：远端子树拉回本地再打包，gzip 可解', () async {
    await start();
    final _Res res = await client.send(
      'POST',
      '/api/files/${ws()}/download_folder',
      body: <String, dynamic>{'path': 'sub'},
    );
    expect(res.status, 200, reason: res.raw);
    final String listing = utf8.decode(
      gzip.decode(res.bytes),
      allowMalformed: true,
    );
    expect(listing, contains('sub/b.md'));
  });

  test('syncToLocal：远端 → 本机目录（保留层级）', () async {
    await start();
    final Directory out = Directory.systemTemp.createTempSync('tree_ssh_sync_');
    addTearDown(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });
    final _Res res = await client.send(
      'POST',
      '/api/files/${ws()}/syncToLocal',
      body: <String, dynamic>{'local_path': out.path},
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['files'], 4);
    expect(File('${out.path}/a.txt').readAsStringSync(), 'hello\n世界\n');
    expect(File('${out.path}/sub/b.md').existsSync(), isTrue);
  });

  test('配了 ssh 但核心没接远端后端：可读 400，不假装成功', () async {
    await start(wireRemote: false);
    final _Res res = await client.send('GET', '/api/files/${ws()}');
    expect(res.status, 400);
    expect(jsonEncode(res.json), contains('远端'));
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/syncToLocal',
        body: <String, dynamic>{'local_path': 'C:/tmp/out'},
      )).status,
      400,
    );
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/download_folder',
        body: <String, dynamic>{'path': ''},
      )).status,
      400,
    );
  });
}
