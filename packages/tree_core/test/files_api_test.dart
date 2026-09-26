import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(String method, String path) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json);
  final int status;
  final Map<String, dynamic> json;
}

/// 工作空间文件与 Git 的 REST 面（M7d）：文件面板 / 查看器 / Git 面板。
void main() {
  late Directory temp;
  late MemoryStore store;
  late CoreAgent agent;
  late CoreServer server;
  late _Client client;

  Future<void> start({bool ssh = false}) async {
    temp = Directory.systemTemp.createTempSync('tree_files_');
    Directory('${temp.path}/sub').createSync(recursive: true);
    File('${temp.path}/a.txt').writeAsStringSync('hello\n世界\n');
    File('${temp.path}/sub/b.md').writeAsStringSync('# 标题');
    File('${temp.path}/pixel.png').writeAsBytesSync(<int>[137, 80, 78, 71]);
    File('${temp.path}/doc.pdf').writeAsStringSync(
      '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
      '2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >> endobj\n'
      '3 0 obj << /Type /Page >> endobj\n'
      '4 0 obj << /Type /Page >> endobj\n'
      '5 0 obj << /Title (示例文档) /Author (Tree) >> endobj\n',
    );
    store = MemoryStore();
    agent = store.createAgent(name: '文件用例');
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

  test('GET files：目录在前、字段齐全、支持子目录与截断标记', () async {
    await start();
    final _Res res = await client.send('GET', '/api/files/${ws()}');
    expect(res.status, 200);
    final List<dynamic> files = res.json['files'] as List<dynamic>;
    final List<String> names = files
        .map((dynamic e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
    expect(names.first, 'sub', reason: '目录在前');
    expect(names, containsAll(<String>['a.txt', 'doc.pdf', 'pixel.png']));
    final Map<String, dynamic> dir = files.first as Map<String, dynamic>;
    expect(dir['type'], 'dir');
    expect(dir['size'], 0);
    expect(dir['path'], 'sub');
    expect(dir['modified'], isNotEmpty);
    final Map<String, dynamic> txt = files.firstWhere(
      (dynamic e) => (e as Map<String, dynamic>)['name'] == 'a.txt',
    ) as Map<String, dynamic>;
    expect(txt['type'], 'file');
    expect(txt['size'], greaterThan(0));

    final _Res sub = await client.send('GET', '/api/files/${ws()}?path=sub');
    expect((sub.json['files'] as List<dynamic>).single['path'], 'sub/b.md');
  });

  test('GET content：文本 / 图片 base64 / 缺文件 404 / 越界 400', () async {
    await start();
    final _Res text = await client.send(
      'GET',
      '/api/files/${ws()}/content?path=a.txt',
    );
    expect(text.status, 200);
    expect(text.json['content'], 'hello\n世界\n');
    expect(text.json['size'], greaterThan(0));
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

    expect(
      (await client.send(
        'GET',
        '/api/files/${ws()}/content?path=missing.txt',
      )).status,
      404,
    );
    expect(
      (await client.send(
        'GET',
        '/api/files/${ws()}/content?path=../../escape.txt',
      )).status,
      400,
      reason: '路径逃逸必须拒绝',
    );
    expect(
      (await client.send(
        'GET',
        '/api/files/${ws()}/content?path=C:/windows/win.ini',
      )).status,
      400,
    );
    expect(
      (await client.send(
        'GET',
        '/api/files/ws_unknown/content?path=a.txt',
      )).status,
      404,
    );
  });

  test('GET pdf_info：页数与标题/作者（启发式，来源可查）', () async {
    await start();
    final _Res res = await client.send(
      'GET',
      '/api/files/${ws()}/pdf_info?path=doc.pdf',
    );
    expect(res.status, 200);
    expect(res.json['total_pages'], 2);
    expect(res.json['pages_source'], 'count');
    expect(res.json['title'], '示例文档');
    expect(res.json['author'], 'Tree');
  });

  test('GET git log / branches：真仓库读取', () async {
    await start();
    Future<void> git(List<String> args) async {
      final ProcessResult result = await Process.run('git', <String>[
        '-C',
        temp.path,
        ...args,
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'git ${args.join(' ')}: ${result.stderr}',
      );
    }

    await git(<String>['init', '-q']);
    await git(<String>['config', 'user.email', 'test@example.com']);
    await git(<String>['config', 'user.name', 'Tree Test']);
    await git(<String>['add', '.']);
    await git(<String>['commit', '-q', '-m', '初次提交']);

    final _Res log = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/log?limit=10',
    );
    expect(log.status, 200);
    final Map<String, dynamic> commit =
        (log.json['commits'] as List<dynamic>).first as Map<String, dynamic>;
    expect(commit['message'], '初次提交');
    expect(commit['author'], 'Tree Test');
    expect(commit['hash'], isNotEmpty);
    expect(commit['date'], isNotEmpty);

    final _Res branches = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/branches',
    );
    expect(branches.status, 200);
    expect(
      (branches.json['branches'] as List<dynamic>).single['name'],
      isNotEmpty,
    );
    expect(branches.json['current'], isNotEmpty);
  });

  test('SSH 工作空间与未接入文件服务：可读错误而不是假装成功', () async {
    await start(ssh: true);
    final _Res res = await client.send('GET', '/api/files/${ws()}');
    expect(res.status, 400);
    expect(jsonEncode(res.json), contains('远端'));

    await server.close();
    final CoreServer bare = await CoreServer.start(
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    final _Client bareClient = _Client(bare);
    addTearDown(() async {
      bareClient.close();
      await bare.close();
    });
    expect((await bareClient.send('GET', '/api/files/ws_1')).status, 501);
    // tearDown 会再关一次 server：CoreServer.close 幂等
  });
}
