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
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json, this.raw);
  final int status;
  final Map<String, dynamic> json;
  final String raw;
}

/// 文件面板的**结构改动** REST 面（M11）：本机分支（临时目录）+ 真临时 git 仓库。
///
/// 远端分支（`_FakeRemote implements WorkspaceFiles`）在 ssh_files_api_test.dart。
void main() {
  late Directory temp;
  late MemoryStore store;
  late CoreAgent agent;
  late CoreServer server;
  late _Client client;

  /// [workspaceDir] 指到别处（真 git 仓库用例），[maxGitStatusEntries] 注入条目上限。
  Future<void> start({
    String? workspaceDir,
    int maxGitStatusEntries = 2000,
  }) async {
    temp = Directory.systemTemp.createTempSync('tree_mutate_');
    Directory('${temp.path}/sub').createSync(recursive: true);
    File('${temp.path}/a.txt').writeAsStringSync('hello');
    File('${temp.path}/sub/b.md').writeAsStringSync('# 标题');
    final String dir = workspaceDir ?? temp.path;
    store = MemoryStore();
    agent = store.createAgent(name: '结构改动用例');
    agent.workspaceDir = dir;
    store.putAgent(agent);
    server = await CoreServer.start(
      store: store,
      fileService: FileService(
        store: store,
        defaultWorkspaceDir: (String _) => dir,
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
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  String ws() => agent.workspaceId;

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

  // ── mkdir ──────────────────────────────────────────────────────────────

  test('mkdir：成功 / 已存在 409 / 父目录不存在 400 / 根与逃逸 400', () async {
    await start();
    final _Res parent = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建/深'},
    );
    expect(parent.status, 400, reason: parent.raw);
    expect(parent.raw, contains('父目录不存在'));
    expect(Directory('${temp.path}/新建').existsSync(), isFalse, reason: '不自动建父目录');

    final _Res one = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建'},
    );
    expect(one.status, 200, reason: one.raw);
    expect(one.json['success'], true);
    expect(one.json['path'], '新建');
    expect(Directory('${temp.path}/新建').existsSync(), isTrue);

    final _Res deep = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建/深'},
    );
    expect(deep.status, 200, reason: deep.raw);
    expect(Directory('${temp.path}/新建/深').existsSync(), isTrue);

    final _Res again = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': '新建'},
    );
    expect(again.status, 409, reason: again.raw);
    expect(again.raw, contains('已存在'));

    final _Res onFile = await client.send(
      'POST',
      '/api/files/${ws()}/mkdir',
      body: <String, dynamic>{'path': 'a.txt'},
    );
    expect(onFile.status, 409, reason: onFile.raw);
    expect(File('${temp.path}/a.txt').readAsStringSync(), 'hello');

    for (final String bad in <String>['', '.', '../escape', 'C:/x', '/abs']) {
      final _Res res = await client.send(
        'POST',
        '/api/files/${ws()}/mkdir',
        body: <String, dynamic>{'path': bad},
      );
      expect(res.status, 400, reason: 'path=$bad: ${res.raw}');
    }
  });

  // ── rename ─────────────────────────────────────────────────────────────

  test('rename：成功（文件 / 目录）/ 目标已存在 409 / 源不存在 404 / 父目录 400', () async {
    await start();
    final _Res ok = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'a.txt', 'to': 'sub/a.txt'},
    );
    expect(ok.status, 200, reason: ok.raw);
    expect(ok.json['success'], true);
    expect(ok.json['from'], 'a.txt');
    expect(ok.json['to'], 'sub/a.txt');
    expect(File('${temp.path}/sub/a.txt').readAsStringSync(), 'hello');
    expect(File('${temp.path}/a.txt').existsSync(), isFalse);

    final _Res dir = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'sub', 'to': 'sub2'},
    );
    expect(dir.status, 200, reason: dir.raw);
    expect(File('${temp.path}/sub2/a.txt').existsSync(), isTrue);
    expect(File('${temp.path}/sub2/b.md').readAsStringSync(), '# 标题');

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
      body: <String, dynamic>{'from': 'sub2/a.txt', 'to': 'sub2/b.md'},
    );
    expect(exists.status, 409, reason: exists.raw);
    expect(exists.raw, contains('不覆盖'));
    expect(
      File('${temp.path}/sub2/b.md').readAsStringSync(),
      '# 标题',
      reason: '绝不覆盖目标',
    );

    final _Res parent = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'sub2/a.txt', 'to': 'no/dir/a.txt'},
    );
    expect(parent.status, 400, reason: parent.raw);
    expect(parent.raw, contains('父目录不存在'));
    expect(Directory('${temp.path}/no').existsSync(), isFalse);

    final _Res same = await client.send(
      'POST',
      '/api/files/${ws()}/rename',
      body: <String, dynamic>{'from': 'sub2/a.txt', 'to': 'sub2/a.txt'},
    );
    expect(same.status, 400, reason: same.raw);

    for (final List<String> pair in <List<String>>[
      <String>['.', 'x'],
      <String>['sub2/a.txt', '../x'],
      <String>['', 'x'],
    ]) {
      final _Res res = await client.send(
        'POST',
        '/api/files/${ws()}/rename',
        body: <String, dynamic>{'from': pair[0], 'to': pair[1]},
      );
      expect(res.status, 400, reason: '${pair[0]} → ${pair[1]}: ${res.raw}');
    }
  });

  // ── delete ─────────────────────────────────────────────────────────────

  test('delete：非空目录默认拒绝 / recursive / 空目录 / 缺失 404 / 根 400', () async {
    await start();
    final _Res notEmpty = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=sub',
    );
    expect(notEmpty.status, 409, reason: notEmpty.raw);
    expect(notEmpty.raw, contains('recursive=1'));
    expect(
      File('${temp.path}/sub/b.md').existsSync(),
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
    expect(Directory('${temp.path}/sub').existsSync(), isFalse);

    final _Res file = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=a.txt',
    );
    expect(file.status, 200, reason: file.raw);
    expect(File('${temp.path}/a.txt').existsSync(), isFalse);

    Directory('${temp.path}/empty').createSync();
    final _Res empty = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=empty',
    );
    expect(empty.status, 200, reason: empty.raw);
    expect(Directory('${temp.path}/empty').existsSync(), isFalse);

    final _Res missing = await client.send(
      'DELETE',
      '/api/files/${ws()}?path=missing.txt',
    );
    expect(missing.status, 404, reason: missing.raw);

    for (final String bad in <String>['', '.', 'a/..', '../escape', '/abs']) {
      final _Res res = await client.send(
        'DELETE',
        '/api/files/${ws()}?path=$bad',
      );
      expect(res.status, 400, reason: 'path=$bad: ${res.raw}');
    }
    expect(temp.existsSync(), isTrue, reason: '工作空间根必须还在');
  });

  // ── git-status ─────────────────────────────────────────────────────────

  test('git-status：不是仓库 → 200 + is_repo=false 空列表（不是错误）', () async {
    await start();
    final _Res res = await client.send('GET', '/api/files/${ws()}/git-status');
    expect(res.status, 200, reason: res.raw);
    expect(res.json['is_repo'], false);
    expect(res.json['entries'], isEmpty);
    expect(res.json['truncated'], false);
  });

  test('git-status：真临时仓库的 M / U / A / D 与形状', () async {
    await start();
    final ProcessResult probe = await Process.run('git', <String>['--version']);
    if (probe.exitCode != 0) {
      markTestSkipped('本机没有 git，跳过');
      return;
    }
    await runGit(temp, <String>['init', '-q']);
    await runGit(temp, <String>['config', 'user.email', 'test@example.com']);
    await runGit(temp, <String>['config', 'user.name', 'Tree Test']);
    await runGit(temp, <String>['add', '-A']);
    await runGit(temp, <String>['commit', '-q', '-m', '初次提交']);

    // 工作区改动（M）、删除（D）、新增并暂存（A）、未跟踪（U，带空格与中文）
    File('${temp.path}/a.txt').writeAsStringSync('changed');
    File('${temp.path}/sub/b.md').deleteSync();
    File('${temp.path}/added.txt').writeAsStringSync('new');
    await runGit(temp, <String>['add', 'added.txt']);
    File('${temp.path}/untracked 文件.txt').writeAsStringSync('u');

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
    expect(byPath['sub/b.md'], 'D');
    expect(byPath['added.txt'], 'A');
    expect(byPath['untracked 文件.txt'], 'U');
  });

  test('git-status：条目上限触发 truncated: true', () async {
    final Directory repo = Directory.systemTemp.createTempSync('tree_cap_git_');
    addTearDown(() {
      for (int i = 0; i < 10 && repo.existsSync(); i++) {
        try {
          repo.deleteSync(recursive: true);
        } catch (_) {
          return;
        }
      }
    });
    final ProcessResult probe = await Process.run('git', <String>['--version']);
    if (probe.exitCode != 0) {
      markTestSkipped('本机没有 git，跳过');
      return;
    }
    File('${repo.path}/a.txt').writeAsStringSync('one');
    await runGit(repo, <String>['init', '-q']);
    await runGit(repo, <String>['config', 'user.email', 'test@example.com']);
    await runGit(repo, <String>['config', 'user.name', 'Tree Test']);
    await runGit(repo, <String>['add', '-A']);
    await runGit(repo, <String>['commit', '-q', '-m', '初次提交']);
    File('${repo.path}/a.txt').writeAsStringSync('two');
    File('${repo.path}/b.txt').writeAsStringSync('b');

    await start(workspaceDir: repo.path, maxGitStatusEntries: 1);
    final _Res capped = await client.send(
      'GET',
      '/api/files/${ws()}/git-status',
    );
    expect(capped.status, 200, reason: capped.raw);
    expect(capped.json['is_repo'], true);
    expect((capped.json['entries'] as List<dynamic>).length, 1);
    expect(capped.json['truncated'], true);
  });

  test('git-status：ignored 默认不列，ignored=1 才出现 I', () async {
    final Directory repo = Directory.systemTemp.createTempSync('tree_ign_git_');
    addTearDown(() {
      for (int i = 0; i < 10 && repo.existsSync(); i++) {
        try {
          repo.deleteSync(recursive: true);
        } catch (_) {
          return;
        }
      }
    });
    final ProcessResult probe = await Process.run('git', <String>['--version']);
    if (probe.exitCode != 0) {
      markTestSkipped('本机没有 git，跳过');
      return;
    }
    File('${repo.path}/a.txt').writeAsStringSync('one');
    File('${repo.path}/.gitignore').writeAsStringSync('ignored.txt\n');
    File('${repo.path}/ignored.txt').writeAsStringSync('i');
    await runGit(repo, <String>['init', '-q']);
    await runGit(repo, <String>['config', 'user.email', 'test@example.com']);
    await runGit(repo, <String>['config', 'user.name', 'Tree Test']);
    await runGit(repo, <String>['add', '-A']);
    await runGit(repo, <String>['commit', '-q', '-m', '初次提交']);
    File('${repo.path}/a.txt').writeAsStringSync('two');

    await start(workspaceDir: repo.path);
    List<String> statuses(Map<String, dynamic> json) => <String>[
      for (final dynamic e in json['entries'] as List<dynamic>)
        (e as Map<String, dynamic>)['status'] as String,
    ];

    final _Res plain = await client.send('GET', '/api/files/${ws()}/git-status');
    expect(plain.status, 200, reason: plain.raw);
    expect(plain.json['is_repo'], true);
    expect(statuses(plain.json), contains('M'));
    expect(
      statuses(plain.json),
      isNot(contains('I')),
      reason: '默认不带 --ignored：大仓库里列被忽略文件既慢又吵',
    );

    final _Res withIgnored = await client.send(
      'GET',
      '/api/files/${ws()}/git-status?ignored=1',
    );
    expect(withIgnored.status, 200, reason: withIgnored.raw);
    expect(
      statuses(withIgnored.json),
      contains('I'),
      reason: 'ignored=1 时被忽略文件映射成 I',
    );
  });
}
