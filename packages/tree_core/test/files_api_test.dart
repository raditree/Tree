import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

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
    // 下载/打包接口返回**原始字节**：先按字节收全再宽松解码成文本
    // （tar.gz 不是合法 UTF-8，严格解码会直接抛异常）。
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
      response.headers.value('content-disposition') ?? '',
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json, this.raw, this.bytes, this.disposition);
  final int status;
  final Map<String, dynamic> json;

  /// 宽松解码后的文本（断言用；二进制响应用 [bytes]）。
  final String raw;

  /// 原始响应字节（下载 / tar.gz 用）。
  final List<int> bytes;

  /// 下载响应头 `content-disposition`（空串 = 没有）。
  final String disposition;
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

  test('POST download：原始字节落盘（含子目录与路径逃逸拒绝）', () async {
    await start();
    final _Res res = await client.send(
      'POST',
      '/api/files/${ws()}/download',
      body: <String, dynamic>{'path': 'a.txt'},
    );
    expect(res.status, 200);
    // 下载返回的是原始字节（不是 JSON）：这里用 raw 字符串核对内容
    expect(res.raw, contains('hello'));

    final _Res nested = await client.send(
      'POST',
      '/api/files/${ws()}/download',
      body: <String, dynamic>{'path': 'sub/b.md'},
    );
    expect(nested.status, 200);
    expect(nested.raw, contains('标题'));

    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/download',
        body: <String, dynamic>{'path': '../escape.txt'},
      )).status,
      400,
    );
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/download',
        body: <String, dynamic>{'path': 'missing.bin'},
      )).status,
      404,
    );

    // 中文文件名：HTTP 头只能是 ASCII，必须走 RFC 5987 的 filename*=UTF-8''...
    // （直接塞中文会被 dart:io 以 FormatException 拒绝——真 exe 冒烟测试才暴露）
    File('${temp.path}/说明.txt').writeAsStringSync('你好');
    final _Res chinese = await client.send(
      'POST',
      '/api/files/${ws()}/download',
      body: <String, dynamic>{'path': '说明.txt'},
    );
    expect(chinese.status, 200, reason: chinese.raw);
    expect(chinese.raw, contains('你好'));
    expect(chinese.disposition, contains("filename*=UTF-8''"));
    expect(
      chinese.disposition,
      contains(Uri.encodeComponent('说明.txt')),
      reason: 'ASCII 回退名之外的百分号编码要带完整原名',
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

  test('POST upload_init/chunk/complete：分片顺序追加并真实落盘', () async {
    await start();
    final List<int> payload = List<int>.generate(700, (int i) => i % 256);
    final _Res init = await client.send(
      'POST',
      '/api/files/${ws()}/upload_init',
      body: <String, dynamic>{
        'file_name': '大文件.bin',
        'rel_path': '资料/2026',
        'total_size': payload.length,
      },
    );
    expect(init.status, 200);
    expect(init.json['chunk_size'], isA<int>());
    final String uploadId = init.json['upload_id'] as String;
    expect(uploadId, hasLength(32), reason: 'upload_id 形状与旧后端一致（uuid4().hex）');

    // 两块：第一块 400 字节，第二块是剩下的（故意不等于定标分片大小）
    final List<List<int>> parts = <List<int>>[
      payload.sublist(0, 400),
      payload.sublist(400),
    ];
    for (int i = 0; i < parts.length; i++) {
      final _Res chunk = await client.send(
        'POST',
        '/api/files/${ws()}/upload_chunk',
        body: <String, dynamic>{
          'upload_id': uploadId,
          'index': i,
          'data': base64Encode(parts[i]),
        },
      );
      expect(chunk.status, 200, reason: chunk.raw);
      expect(chunk.json['received'], true);
      expect(chunk.json['received_bytes'], i == 0 ? 400 : payload.length);
    }

    final _Res done = await client.send(
      'POST',
      '/api/files/${ws()}/upload_complete',
      body: <String, dynamic>{'upload_id': uploadId, 'total_chunks': 2},
    );
    expect(done.status, 200, reason: done.raw);
    expect(done.json['success'], true);
    expect(done.json['size'], payload.length);
    final String rel = done.json['path'] as String;
    expect(rel, startsWith('.input/'));
    expect(rel, contains('资料/2026/大文件.bin'));
    final File saved = File(
      '${temp.path}/${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(saved.existsSync(), isTrue);
    expect(saved.readAsBytesSync(), payload, reason: '落盘字节必须一模一样');

    // 会话用完即删：同一个 upload_id 再 complete 一次必须是 404
    final _Res again = await client.send(
      'POST',
      '/api/files/${ws()}/upload_complete',
      body: <String, dynamic>{'upload_id': uploadId},
    );
    expect(again.status, 404);
  });

  test('上传写路径：乱序 / 坏 base64 / 超声明大小 / 非法路径都要拒绝', () async {
    await start();
    Future<_Res> init({String name = 'x.bin', String rel = '', int size = 4}) =>
        client.send(
          'POST',
          '/api/files/${ws()}/upload_init',
          body: <String, dynamic>{
            'file_name': name,
            'rel_path': rel,
            'total_size': size,
          },
        );
    Future<_Res> chunk(String id, int index, String data) => client.send(
      'POST',
      '/api/files/${ws()}/upload_chunk',
      body: <String, dynamic>{'upload_id': id, 'index': index, 'data': data},
    );

    final _Res good = await init();
    final String id = good.json['upload_id'] as String;
    expect(
      (await chunk(id, 1, base64Encode(<int>[1, 2]))).status,
      400,
      reason: '分片必须按序到达',
    );
    expect(
      (await chunk(id, -1, base64Encode(<int>[1, 2]))).status,
      400,
      reason: 'index 不能为负',
    );
    expect((await chunk(id, 0, '不是 base64!!')).status, 400);
    expect(
      (await chunk(id, 0, base64Encode(<int>[1, 2, 3, 4, 5]))).status,
      400,
      reason: '超过声明总大小',
    );
    expect(
      (await chunk('deadbeef', 0, base64Encode(<int>[1]))).status,
      404,
      reason: '会话不存在或已过期',
    );
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/upload_complete',
        body: <String, dynamic>{'upload_id': id, 'total_chunks': 0},
      )).status,
      400,
      reason: '声明 0 片但一个字节都没收到',
    );

    expect((await init(rel: '../escape')).status, 400, reason: 'rel_path 逃逸');
    expect((await init(rel: 'C:/windows')).status, 400, reason: '盘符');
    expect((await init(rel: 'a/../../b')).status, 400);
    expect((await init(name: '../x.bin')).status, 400, reason: '文件名带分隔符');
    expect((await init(name: 'a/b.bin')).status, 400);
    expect(
      (await init(size: 2 * 1024 * 1024 * 1024)).status,
      413,
      reason: '超过单文件上限',
    );
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/upload_init',
        body: <String, dynamic>{'file_name': 'x.bin', 'total_size': '4'},
      )).status,
      200,
      reason: '整数字段宽容解析（前端偶发字符串化）',
    );

    // 空文件（total_size = 0、零分片）同样合法
    final _Res empty = await init(name: 'empty.txt', size: 0);
    final _Res emptyDone = await client.send(
      'POST',
      '/api/files/${ws()}/upload_complete',
      body: <String, dynamic>{
        'upload_id': empty.json['upload_id'],
        'total_chunks': 0,
      },
    );
    expect(emptyDone.status, 200, reason: emptyDone.raw);
    final File emptyFile = File(
      '${temp.path}/${(emptyDone.json['path'] as String).replaceAll('/', Platform.pathSeparator)}',
    );
    expect(emptyFile.existsSync(), isTrue);
    expect(emptyFile.lengthSync(), 0);
  });

  test('POST syncToLocal：整棵工作空间复制到本机目录（排除 .git）', () async {
    await start();
    Directory('${temp.path}/.git').createSync();
    File('${temp.path}/.git/config').writeAsStringSync('x');
    final Directory out = Directory.systemTemp.createTempSync('tree_sync_out_');
    addTearDown(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    final _Res res = await client.send(
      'POST',
      '/api/files/${ws()}/syncToLocal',
      body: <String, dynamic>{'local_path': out.path},
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['success'], true);
    expect(res.json['files'], greaterThanOrEqualTo(4));
    expect(res.json['bytes'], greaterThan(0));
    expect(File('${out.path}/a.txt').readAsStringSync(), 'hello\n世界\n');
    expect(File('${out.path}/sub/b.md').existsSync(), isTrue);
    expect(
      Directory('${out.path}/.git').existsSync(),
      isFalse,
      reason: '.git 不参与同步',
    );

    // 目标是工作空间本身或它的子目录 → 400（否则会边写边遍历）
    for (final String target in <String>[
      temp.path,
      '${temp.path}/backup',
      '   ',
    ]) {
      expect(
        (await client.send(
          'POST',
          '/api/files/${ws()}/syncToLocal',
          body: <String, dynamic>{'local_path': target},
        )).status,
        400,
        reason: '目标目录非法：$target',
      );
    }
  });

  test('POST syncToLocal：只同步 path 指定的子树（M8b 按需加载）', () async {
    await start();
    final Directory out = Directory.systemTemp.createTempSync('tree_sync_sub_');
    addTearDown(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    final _Res res = await client.send(
      'POST',
      '/api/files/${ws()}/syncToLocal',
      body: <String, dynamic>{'local_path': out.path, 'path': 'sub'},
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['path'], 'sub');
    expect(File('${out.path}/sub/b.md').existsSync(), isTrue);
    expect(
      File('${out.path}/a.txt').existsSync(),
      isFalse,
      reason: '只同步 sub 子树，根下的 a.txt 不该被复制',
    );

    // 越界的 path 要拒绝，不能被当成"根下某个名字"糊弄过去
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/syncToLocal',
        body: <String, dynamic>{'local_path': out.path, 'path': '../x'},
      )).status,
      400,
    );
  });

  test('POST download_folder：真实 tar.gz（gzip 可解、排除 .git、越界拒绝）', () async {
    await start();
    Directory('${temp.path}/.git').createSync();
    File('${temp.path}/.git/config').writeAsStringSync('x');
    Directory('${temp.path}/sub/.git').createSync();
    File('${temp.path}/sub/.git/config').writeAsStringSync('y');
    Directory('${temp.path}/资料').createSync();
    File('${temp.path}/资料/备注.txt').writeAsStringSync('中文目录');

    final _Res res = await client.send(
      'POST',
      '/api/files/${ws()}/download_folder',
      body: <String, dynamic>{'path': 'sub'},
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json, isEmpty, reason: 'tar.gz 不是 JSON，不应被当成 JSON 解析');
    final String listing = utf8.decode(
      gzip.decode(res.bytes),
      allowMalformed: true,
    );
    expect(listing, contains('sub/b.md'));
    expect(listing, isNot(contains('.git')), reason: '嵌套 .git 也要排除');

    // 整根打包：成员名以 ./ 开头，顶层 .git 同样排除
    final _Res root = await client.send(
      'POST',
      '/api/files/${ws()}/download_folder',
      body: <String, dynamic>{'path': ''},
    );
    expect(root.status, 200, reason: root.raw);
    final String rootListing = utf8.decode(
      gzip.decode(root.bytes),
      allowMalformed: true,
    );
    expect(rootListing, contains('./a.txt'));
    expect(rootListing, isNot(contains('.git')));

    // 中文目录名：Content-Disposition 同样必须走 RFC 5987（见 writeBytes 注释）
    final _Res cnFolder = await client.send(
      'POST',
      '/api/files/${ws()}/download_folder',
      body: <String, dynamic>{'path': '资料'},
    );
    expect(cnFolder.status, 200, reason: cnFolder.raw);
    expect(cnFolder.disposition, contains("filename*=UTF-8''"));
    expect(
      utf8.decode(gzip.decode(cnFolder.bytes), allowMalformed: true),
      contains('备注.txt'),
    );

    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/download_folder',
        body: <String, dynamic>{'path': '../escape'},
      )).status,
      400,
    );
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/download_folder',
        body: <String, dynamic>{'path': 'missing'},
      )).status,
      404,
    );
  });

  test('SSH 工作空间与未接入文件服务：可读错误而不是假装成功', () async {
    await start(ssh: true);
    final _Res res = await client.send('GET', '/api/files/${ws()}');
    expect(res.status, 400);
    expect(jsonEncode(res.json), contains('远端'));

    // 写路径同样只给可读错误：远端文件需要 SFTP 二进制通道（后续里程碑）
    for (final (String, Map<String, dynamic>) probe
        in <(String, Map<String, dynamic>)>[
          (
            'upload_init',
            <String, dynamic>{'file_name': 'x.bin', 'total_size': 1},
          ),
          ('syncToLocal', <String, dynamic>{'local_path': 'C:/tmp/tree_out'}),
          ('download_folder', <String, dynamic>{'path': ''}),
        ]) {
      final _Res denied = await client.send(
        'POST',
        '/api/files/${ws()}/${probe.$1}',
        body: probe.$2,
      );
      expect(denied.status, 400, reason: '${probe.$1} → ${denied.raw}');
      expect(jsonEncode(denied.json), contains('远端'));
    }

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
