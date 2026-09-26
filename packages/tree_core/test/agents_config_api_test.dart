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
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
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

/// agent 的工作空间与 SSH 配置 REST（M7c 的前端"运行模式"入口）。
///
/// 桌面端的「本地 / SSH 模式」不再是前端执行器开关，而是**写进 agent 配置**
/// （核心据此决定工具在哪跑）。因此这两个字段的语义必须精确：字段缺失 = 不改、
/// 显式空值 = 清空、密码永不回显。
void main() {
  late Directory temp;
  late FileTreeStore store;
  late CoreServer server;
  late _Client client;
  late CoreAgent agent;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_agent_cfg_');
    store = FileTreeStore(TreePaths(temp.path));
    server = await CoreServer.start(
      store: store,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    agent = store.createAgent(name: '配置用例');
    client = _Client(server);
  });

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

  Future<_Res> patch(Map<String, dynamic> body) =>
      client.send('PATCH', '/api/agents/${agent.id}', body: body);

  test('workspace_dir：绝对路径可设可清；相对路径 400', () async {
    expect(
      (await client.send(
        'GET',
        '/api/agents/${agent.id}',
      )).json.containsKey('ssh'),
      isFalse,
      reason: '未配置 SSH 时不返回 ssh 段',
    );

    final _Res relative = await patch(<String, dynamic>{
      'workspace_dir': 'relative/dir',
    });
    expect(relative.status, 400);

    final _Res set = await patch(<String, dynamic>{'workspace_dir': temp.path});
    expect(set.status, 200);
    expect(set.json['agent']['workspace_dir'], temp.path);
    expect(store.agent(agent.id)!.workspaceDir, temp.path);

    final _Res cleared = await patch(<String, dynamic>{'workspace_dir': ''});
    expect(cleared.status, 200);
    expect(cleared.json['agent']['workspace_dir'], '');
  });

  test('ssh：写入非机密字段回显、密码永不回显、缺凭据 400、null 清空', () async {
    final _Res missing = await patch(<String, dynamic>{
      'ssh': <String, dynamic>{'host': 'h', 'username': 'u'},
    });
    expect(missing.status, 400);
    expect(missing.raw, contains('password 或 key_path'));

    final _Res created = await patch(<String, dynamic>{
      'ssh': <String, dynamic>{
        'host': 'remote.example.com',
        'port': 2222,
        'username': 'deploy',
        'password': 'top-secret',
        'root': '~/proj',
      },
    });
    expect(created.status, 200);
    expect(created.json['agent']['has_ssh'], isTrue);
    final Map<String, dynamic> ssh =
        created.json['ssh'] as Map<String, dynamic>;
    expect(ssh['host'], 'remote.example.com');
    expect(ssh['port'], 2222);
    expect(ssh['username'], 'deploy');
    expect(ssh['auth'], 'password');
    expect(ssh['root'], '~/proj');
    expect(created.raw, isNot(contains('top-secret')), reason: 'API 响应绝不回显口令');

    // PATCH 语义：未提供 password 键 → 保留原口令（auth 仍是 password）
    final _Res updated = await patch(<String, dynamic>{
      'ssh': <String, dynamic>{
        'host': 'other.example.com',
        'username': 'deploy',
      },
    });
    expect(updated.status, 200);
    expect(
      (updated.json['ssh'] as Map<String, dynamic>)['host'],
      'other.example.com',
    );
    expect((updated.json['ssh'] as Map<String, dynamic>)['auth'], 'password');
    expect(store.agent(agent.id)!.sshConfig!.password, 'top-secret');

    final _Res cleared = await patch(<String, dynamic>{'ssh': null});
    expect(cleared.status, 200);
    expect(cleared.json['agent']['has_ssh'], isFalse);
    expect(store.agent(agent.id)!.sshConfig, isNull);

    final _Res badType = await patch(<String, dynamic>{'ssh': 'not-a-map'});
    expect(badType.status, 400);
  });

  test('落盘：workspace_dir 与 ssh 写进 agents/<id>.yaml（用户可手改）', () async {
    await patch(<String, dynamic>{
      'workspace_dir': temp.path,
      'ssh': <String, dynamic>{
        'host': 'h.example.com',
        'username': 'u',
        'key_path': '~/.ssh/id_ed25519',
      },
    });
    await store.flush();
    final String yaml = File(TreePaths(temp.path).agentFile(agent.id))
        .readAsStringSync();
    expect(yaml, contains('workspace_dir'));
    expect(yaml, contains('h.example.com'));
    expect(yaml, contains('id_ed25519'));

    final FileTreeStore reloaded = FileTreeStore(TreePaths(temp.path));
    final CoreAgent? restored = reloaded.agent(agent.id);
    expect(restored!.sshConfig!.host, 'h.example.com');
    expect(restored.sshConfig!.keyPath, '~/.ssh/id_ed25519');
    await reloaded.close();
  });
}
