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

  @override
  Future<int> sizeOf(String relativePath) async {
    _guard(relativePath);
    final List<int>? bytes = files[relativePath];
    if (bytes == null) throw WorkspaceIoException('文件不存在：$relativePath');
    return bytes.length;
  }

  @override
  Stream<List<int>> openRead(
    String relativePath, {
    int offset = 0,
    int? length,
  }) async* {
    _guard(relativePath);
    final List<int>? bytes = files[relativePath];
    if (bytes == null) throw WorkspaceIoException('文件不存在：$relativePath');
    final int end = length == null
        ? bytes.length
        : (offset + length > bytes.length ? bytes.length : offset + length);
    if (offset < end) yield bytes.sublist(offset, end);
  }

  @override
  Future<void> writeStream(String relativePath, Stream<List<int>> data) async {
    _guard(relativePath);
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in data) {
      builder.add(chunk);
    }
    files[relativePath] = builder.takeBytes();
    writes.add(relativePath);
  }

  // ── M11：结构改动（新建 / 重命名 / 删除） ──────────────────────────────

  /// 显式目录集合（[files] 只描述文件，空目录推不出来）。
  final Set<String> dirs = <String>{};

  bool _isDir(String rel) =>
      rel.isEmpty ||
      dirs.contains(rel) ||
      files.keys.any((String k) => k.startsWith('$rel/')) ||
      dirs.any((String d) => d.startsWith('$rel/'));

  bool _has(String rel) => files.containsKey(rel) || _isDir(rel);

  static String _parentOf(String rel) {
    final int slash = rel.lastIndexOf('/');
    return slash < 0 ? '' : rel.substring(0, slash);
  }

  @override
  Future<WorkspaceMutationResult> makeDirectory(String relativePath) async {
    _guard(relativePath);
    if (_has(relativePath)) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.alreadyExists,
        '目标已存在：$relativePath',
      );
    }
    final String parent = _parentOf(relativePath);
    if (!_isDir(parent)) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.parentMissing,
        '父目录不存在：$parent',
      );
    }
    dirs.add(relativePath);
    return const WorkspaceMutationResult.ok();
  }

  @override
  Future<WorkspaceMutationResult> rename(String from, String to) async {
    _guard(from);
    _guard(to);
    if (!_has(from)) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.notFound,
        '源路径不存在：$from',
      );
    }
    if (_has(to)) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.alreadyExists,
        '目标已存在（不覆盖）：$to',
      );
    }
    final String parent = _parentOf(to);
    if (!_isDir(parent)) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.parentMissing,
        '目标父目录不存在：$parent',
      );
    }
    final Map<String, List<int>> moved = <String, List<int>>{};
    for (final String key in files.keys.toList()) {
      if (key == from || key.startsWith('$from/')) {
        moved[to + key.substring(from.length)] = files.remove(key)!;
      }
    }
    files.addAll(moved);
    final List<String> movedDirs = <String>[];
    for (final String dir in dirs.toList()) {
      if (dir == from || dir.startsWith('$from/')) {
        dirs.remove(dir);
        movedDirs.add(to + dir.substring(from.length));
      }
    }
    dirs.addAll(movedDirs);
    return const WorkspaceMutationResult.ok();
  }

  @override
  Future<WorkspaceMutationResult> remove(
    String relativePath, {
    bool recursive = false,
  }) async {
    _guard(relativePath);
    if (!_has(relativePath)) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.notFound,
        '路径不存在：$relativePath',
      );
    }
    if (_isDir(relativePath) && !recursive) {
      final bool hasChildren =
          files.keys.any((String k) => k.startsWith('$relativePath/')) ||
          dirs.any(
            (String d) =>
                d != relativePath && d.startsWith('$relativePath/'),
          );
      if (hasChildren) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.notEmpty,
          '目录非空：$relativePath；请带 recursive=1',
        );
      }
    }
    files.removeWhere(
      (String k, List<int> _) =>
          k == relativePath || k.startsWith('$relativePath/'),
    );
    dirs.removeWhere(
      (String d) => d == relativePath || d.startsWith('$relativePath/'),
    );
    return const WorkspaceMutationResult.ok();
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

  /// [wireRemote] false = 核心没接远端后端（应给可读 400）。
  /// [backend] 可换成任意远端后端对象（Q4 的 Git 用例注入 LocalWorkspaceIO）。
  /// [ioFor] 显式的工作空间 IO 注入（Q4 的另一条接线，两条都要能走通）。
  Future<void> start({
    bool wireRemote = true,
    int? maxContentBytes,
    Object? backend,
    Future<WorkspaceIO?> Function(String agentId)? ioFor,
    int maxGitStatusEntries = 2000,
  }) async {
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
        remoteFilesFor: wireRemote
            ? (String _) async => backend ?? remote
            : null,
        ioFor: ioFor,
        maxContentBytes: maxContentBytes ?? 8 * 1024 * 1024,
        maxGitStatusEntries: maxGitStatusEntries,
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

  /// 造一个"跟随团队 TOP 的 SSH"的成员：自己没有 ssh 配置。
  CoreAgent addMemberFollower() {
    final CoreAgent member = CoreAgent(
      id: 'member_ssh',
      name: '成员甲',
      workspaceId: 'ws_member_ssh',
      teamId: agent.id,
      parentAgentId: agent.id,
      level: 1,
      createdAt: 1,
      updatedAt: 1,
    );
    store.putAgent(member);
    return member;
  }

  test('成员跟随 SSH leader：文件面板同样走远端（判据是有效 SSH）', () async {
    await start();
    addMemberFollower();
    // 列表必须来自远端后端（成员自己那份 sshConfig 是空的，只看它会落到本机目录）
    final _Res listed = await client.send('GET', '/api/files/ws_member_ssh');
    expect(listed.status, 200, reason: listed.raw);
    final List<dynamic> files = listed.json['files'] as List<dynamic>;
    expect(
      files.map((dynamic e) => (e as Map<String, dynamic>)['name']),
      containsAll(<String>['a.txt', 'sub']),
      reason: '成员的文件面板必须跟随 leader 的 SSH，不许去本机目录找',
    );
    // 写回也必须走远端：本用例只接了远端**文件**后端（没接 WorkspaceIO），
    // 因此必须明确回"远端 IO 不可用"——**绝不**落到本机目录去写。
    final _Res saved = await client.send(
      'PUT',
      // 写内容的路径走 **query**（PUT /content?path=），请求体只有 content/if_size
      '/api/files/ws_member_ssh/content?path=a.txt',
      body: <String, dynamic>{'content': '改过\n'},
    );
    expect(saved.status, 400, reason: saved.raw);
    expect(saved.raw, contains('远端（SSH）'));
    expect(remote.writes, isEmpty, reason: '不该有任何本机写入');
  });

  test('成员跟随 SSH leader 且核心没接远端后端：可读 400，不落到本机', () async {
    await start(wireRemote: false);
    addMemberFollower();
    final _Res res = await client.send('GET', '/api/files/ws_member_ssh');
    expect(res.status, 400, reason: res.raw);
    expect(res.raw, contains('远端（SSH）'));
  });

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

  test('大文件预览：先问大小，只读预览段并标注截断（M8c）', () async {
    await start(maxContentBytes: 16);
    remote.seedBytes(
      'sub/big.bin',
      List<int>.generate(100, (int i) => i % 256),
    );
    final _Res res = await client.send(
      'GET',
      '/api/files/${ws()}/content?path=sub/big.bin',
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['truncated'], true);
    expect(res.json['size'], 100);
    expect(res.json['preview_bytes'], 16);
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

  test('syncToLocal 支持子树与单文件：不再先走完整棵远端（M8b）', () async {
    await start();
    final Directory out = Directory.systemTemp.createTempSync('tree_ssh_sub_');
    addTearDown(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    final _Res sub = await client.send(
      'POST',
      '/api/files/${ws()}/syncToLocal',
      body: <String, dynamic>{'local_path': out.path, 'path': 'sub'},
    );
    expect(sub.status, 200, reason: sub.raw);
    expect(sub.json['files'], 1);
    expect(File('${out.path}/sub/b.md').existsSync(), isTrue);
    expect(
      File('${out.path}/a.txt').existsSync(),
      isFalse,
      reason: '只同步 sub 子树',
    );

    final _Res one = await client.send(
      'POST',
      '/api/files/${ws()}/syncToLocal',
      body: <String, dynamic>{'local_path': out.path, 'path': 'a.txt'},
    );
    expect(one.status, 200, reason: one.raw);
    expect(one.json['files'], 1);
    expect(File('${out.path}/a.txt').readAsStringSync(), 'hello\n世界\n');

    // 不存在的路径：404，而不是空成功
    expect(
      (await client.send(
        'POST',
        '/api/files/${ws()}/syncToLocal',
        body: <String, dynamic>{'local_path': out.path, 'path': 'nope'},
      )).status,
      404,
    );
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

  test('SSH Git：经 WorkspaceIO 的 exec 通道跑 git，返回既有 REST 形状（Q4）', () async {
    final Directory repo = Directory.systemTemp.createTempSync('tree_ssh_git_');
    addTearDown(() async {
      // git 在 Windows 上可能短暂持有句柄：重试几次再放弃
      for (int i = 0; i < 10 && repo.existsSync(); i++) {
        try {
          repo.deleteSync(recursive: true);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    Future<void> git(List<String> args) async {
      final ProcessResult result = await Process.run('git', <String>[
        '-C',
        repo.path,
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
    await git(<String>['commit', '-q', '--allow-empty', '-m', '远端初次提交']);

    // 远端后端就是「同一个 SSH 连接对象」：文件面板按 WorkspaceFiles 用，Git 按
    // WorkspaceIO 用。这里用 LocalWorkspaceIO 顶上（真机 SSH 由门控测试覆盖）。
    await start(backend: LocalWorkspaceIO(repo.path));

    final _Res log = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/log?limit=5',
    );
    expect(log.status, 200, reason: log.raw);
    final Map<String, dynamic> commit =
        (log.json['commits'] as List<dynamic>).first as Map<String, dynamic>;
    expect(commit['message'], '远端初次提交');
    expect(commit['author'], 'Tree Test');
    expect(commit['hash'], isNotEmpty);
    expect(commit['date'], isNotEmpty);

    final _Res branches = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/branches',
    );
    expect(branches.status, 200, reason: branches.raw);
    // REST 形状照旧：branches 是 [{name: ...}]（不是字符串数组）
    expect(
      (branches.json['branches'] as List<dynamic>).single['name'],
      isNotEmpty,
    );
    expect(branches.json['current'], isNotEmpty);
  });

  test('SSH Git：非仓库时返回 200 空列表（不再一律 400）', () async {
    final Directory empty = Directory.systemTemp.createTempSync(
      'tree_ssh_nogit_',
    );
    addTearDown(() {
      if (empty.existsSync()) empty.deleteSync(recursive: true);
    });
    // 这条走**显式 ioFor** 注入（上一条走 remoteFilesFor 的运行期窄化），两条路都覆盖
    await start(ioFor: (String _) async => LocalWorkspaceIO(empty.path));

    final _Res log = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/log',
    );
    expect(log.status, 200, reason: log.raw);
    expect(log.json['commits'], isEmpty);

    final _Res branches = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/branches',
    );
    expect(branches.status, 200, reason: branches.raw);
    expect(branches.json['branches'], isEmpty);
    expect(branches.json['current'], '');
  });

  Future<void> runGit(Directory repo, List<String> args) async {
    final ProcessResult result = await Process.run('git', <String>[
      '-C',
      repo.path,
      ...args,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'git ${args.join(' ')}: ${result.stderr}',
    );
  }

  /// 造一个真临时 git 仓库（本机没有 git 时返回 null，调用方自己跳过）。
  Future<Directory?> makeGitRepo() async {
    final ProcessResult probe = await Process.run('git', <String>['--version']);
    if (probe.exitCode != 0) return null;
    final Directory repo = Directory.systemTemp.createTempSync('tree_ssh_git_');
    addTearDown(() async {
      for (int i = 0; i < 10 && repo.existsSync(); i++) {
        try {
          repo.deleteSync(recursive: true);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    await runGit(repo, <String>['init', '-q']);
    await runGit(repo, <String>['config', 'user.email', 'test@example.com']);
    await runGit(repo, <String>['config', 'user.name', 'Tree Test']);
    return repo;
  }

  // ── M11：结构改动（远端走同一个 WorkspaceFiles 后端） ──────────────────

  test('远端 mkdir：成功 / 已存在 409 / 父目录不存在 400 / 逃逸 400', () async {
    await start();
    final _Res one = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建 目录'},
    );
    expect(one.status, 200, reason: one.raw);
    expect(one.json['success'], true);
    expect(one.json['path'], '新建 目录');
    expect(remote.dirs, contains('新建 目录'));

    final _Res deep = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建 目录/深'},
    );
    expect(deep.status, 200, reason: deep.raw);

    final _Res again = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建 目录'},
    );
    expect(again.status, 409, reason: again.raw);
    expect(again.raw, contains('已存在'));

    final _Res onFile = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': 'a.txt'},
    );
    expect(onFile.status, 409, reason: onFile.raw);

    final _Res parent = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': 'nope/deep'},
    );
    expect(parent.status, 400, reason: parent.raw);
    expect(parent.raw, contains('父目录不存在'));

    for (final String bad in <String>['', '.', '../escape', 'C:/x']) {
      final _Res res = await client.send(
        'POST',
        '/api/files/${ws()}/mkdir',
        body: <String, dynamic>{'path': bad},
      );
      expect(res.status, 400, reason: 'path=$bad: ${res.raw}');
    }
  });

  test('远端 rename：成功 / 源 404 / 目标 409（不覆盖）/ 父目录 400', () async {
    await start();
    final _Res ok = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'a.txt', 'to': 'sub/a.txt'},
    );
    expect(ok.status, 200, reason: ok.raw);
    expect(ok.json['from'], 'a.txt');
    expect(ok.json['to'], 'sub/a.txt');
    expect(remote.files.containsKey('sub/a.txt'), isTrue);
    expect(remote.files.containsKey('a.txt'), isFalse);

    final _Res missing = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'nope.txt', 'to': 'x.txt'},
    );
    expect(missing.status, 404, reason: missing.raw);
    expect(missing.raw, contains('不存在'));

    final _Res exists = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'sub/a.txt', 'to': 'doc.pdf'},
    );
    expect(exists.status, 409, reason: exists.raw);
    expect(exists.raw, contains('不覆盖'));
    expect(
      utf8.decode(remote.files['doc.pdf']!),
      startsWith('%PDF'),
      reason: '绝不覆盖目标',
    );

    final _Res parent = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'sub/a.txt', 'to': 'no/dir/a.txt'},
    );
    expect(parent.status, 400, reason: parent.raw);
    expect(parent.raw, contains('父目录不存在'));
    expect(remote.files.containsKey('no/dir/a.txt'), isFalse);

    final _Res same = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'sub/a.txt', 'to': 'sub/a.txt'},
    );
    expect(same.status, 400, reason: same.raw);
  });

  test('远端 delete：非空目录默认拒绝 / recursive / 空目录 / 缺失 / 根 400', () async {
    await start();
    final _Res notEmpty = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=sub',
    );
    expect(notEmpty.status, 409, reason: notEmpty.raw);
    expect(notEmpty.raw, contains('recursive=1'));
    expect(
      remote.files.containsKey('sub/b.md'),
      isTrue,
      reason: '拒绝时一个字节都不删',
    );

    final _Res recursive = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=sub&recursive=1',
    );
    expect(recursive.status, 200, reason: recursive.raw);
    expect(recursive.json['success'], true);
    expect(recursive.json['path'], 'sub');
    expect(remote.files.containsKey('sub/b.md'), isFalse);

    final _Res file = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=a.txt',
    );
    expect(file.status, 200, reason: file.raw);
    expect(remote.files.containsKey('a.txt'), isFalse);

    remote.dirs.add('empty');
    final _Res empty = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=empty',
    );
    expect(empty.status, 200, reason: empty.raw);
    expect(remote.dirs, isNot(contains('empty')));

    final _Res missing = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=missing.txt',
    );
    expect(missing.status, 404, reason: missing.raw);

    for (final String bad in <String>['', '.', 'a/..']) {
      final _Res res = await client.send(
        'DELETE',
        '/api/files/${ws()}?path=$bad',
      );
      expect(res.status, 400, reason: 'path=$bad: ${res.raw}');
    }
  });

  test('远端结构改动：核心没接远端文件后端时给可读 400，绝不落到本机', () async {
    await start(wireRemote: false);
    final _Res made = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': 'x'},
    );
    expect(made.status, 400, reason: made.raw);
    expect(made.raw, contains('远端（SSH）'));

    final _Res renamed = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'a.txt', 'to': 'b.txt'},
    );
    expect(renamed.status, 400, reason: renamed.raw);
    expect(renamed.raw, contains('远端（SSH）'));

    final _Res removed = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=a.txt',
    );
    expect(removed.status, 400, reason: removed.raw);
    expect(removed.raw, contains('远端（SSH）'));
  });

  // ── M11：远端 git-status ───────────────────────────────────────────────

  test('远端 git-status：经 WorkspaceIO 跑 git，M/U/A/D 与形状（M11）', () async {
    final Directory? repo = await makeGitRepo();
    if (repo == null) {
      markTestSkipped('本机没有 git，跳过');
      return;
    }
    File('${repo.path}/a.txt').writeAsStringSync('one');
    await runGit(repo, <String>['add', '-A']);
    await runGit(repo, <String>['commit', '-q', '-m', '初次提交']);

    File('${repo.path}/a.txt').writeAsStringSync('two');
    File('${repo.path}/added.txt').writeAsStringSync('n');
    await runGit(repo, <String>['add', 'added.txt']);
    File('${repo.path}/untracked 文件.txt').writeAsStringSync('u');

    await start(backend: LocalWorkspaceIO(repo.path));
    final _Res res = await client.send('GET', '/api/files/${ws()}/git-status');
    expect(res.status, 200, reason: res.raw);
    expect(res.json['is_repo'], true);
    expect(res.json['truncated'], false);
    final Map<String, String> byPath = <String, String>{
      for (final dynamic e in res.json['entries'] as List<dynamic>)
        (e as Map<String, dynamic>)['path'] as String:
            e['status'] as String,
    };
    expect(byPath['a.txt'], 'M');
    expect(byPath['added.txt'], 'A');
    expect(byPath['untracked 文件.txt'], 'U');
  });

  test('远端 git-status：条目上限触发 truncated', () async {
    final Directory? repo = await makeGitRepo();
    if (repo == null) {
      markTestSkipped('本机没有 git，跳过');
      return;
    }
    File('${repo.path}/a.txt').writeAsStringSync('one');
    File('${repo.path}/b.txt').writeAsStringSync('b');
    await runGit(repo, <String>['add', '-A']);
    await runGit(repo, <String>['commit', '-q', '-m', '初次提交']);
    File('${repo.path}/a.txt').writeAsStringSync('two');
    File('${repo.path}/b.txt').writeAsStringSync('b2');

    await start(
      backend: LocalWorkspaceIO(repo.path),
      maxGitStatusEntries: 1,
    );
    final _Res res = await client.send('GET', '/api/files/${ws()}/git-status');
    expect(res.status, 200, reason: res.raw);
    expect(res.json['is_repo'], true);
    expect((res.json['entries'] as List<dynamic>).length, 1);
    expect(res.json['truncated'], true);
  });

  test('远端 git-status：不是仓库 → 200 + is_repo=false 空列表（不是错误）', () async {
    final Directory empty = Directory.systemTemp.createTempSync(
      'tree_ssh_nostatus_',
    );
    addTearDown(() {
      if (empty.existsSync()) empty.deleteSync(recursive: true);
    });
    await start(ioFor: (String _) async => LocalWorkspaceIO(empty.path));
    final _Res res = await client.send('GET', '/api/files/${ws()}/git-status');
    expect(res.status, 200, reason: res.raw);
    expect(res.json['is_repo'], false);
    expect(res.json['entries'], isEmpty);
    expect(res.json['truncated'], false);
  });

  test('远端 git-status：核心没接远端工作空间 IO 时仍是可读 400', () async {
    await start(wireRemote: false);
    final _Res res = await client.send('GET', '/api/files/${ws()}/git-status');
    expect(res.status, 400, reason: res.raw);
    expect(res.json['detail'], contains('未接入远端 Git 后端'));
  });

  test('SSH Git：核心没接远端工作空间 IO 时仍是可读 400', () async {
    await start(wireRemote: false);
    final _Res log = await client.send(
      'GET',
      '/api/workspaces/${ws()}/git/log',
    );
    expect(log.status, 400);
    expect(log.json['detail'], contains('未接入远端 Git 后端'));
  });
}
