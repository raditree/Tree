import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 片 E / 5.2–5.3 + 5.5 接线：引导页、会话 token 与品牌申报。
void main() {
  late Directory temp;
  late CoreServer server;
  late _Client client;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tree_bootstrap_');
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      dataDir: temp.path,
      // 显式指向仓库里的真实种子：测试进程的 cwd / exe 同级都探测不到它，
      // 否则会落到内置最小页（没有 var BOOTSTRAP_TICKET）。
      bootstrapSourcePath: '${_repoRoot()}/assets/bootstrap/index.html',
    );
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// 申请一张票据（主 token）。
  Future<String> ticket() async {
    final _Res res = await client.post(ApiPaths.bootstrapTicket);
    expect(res.status, 200, reason: '$res');
    return res.json['ticket'] as String;
  }

  /// 打开引导页并取出页面里注入的「换会话票据」。
  ///
  /// 两种注入形式都要认：完整页面替换占位符，被改过的页面走 `</body>` 前注入。
  String exchangeTicketOf(String html) {
    final RegExpMatch? match = RegExp(
      r'(?:var BOOTSTRAP_TICKET|window\.__TREE_BOOTSTRAP_TICKET__) = "([^"]+)"',
    ).firstMatch(html);
    expect(match, isNotNull, reason: '页面里必须注入换会话票据');
    return match!.group(1)!;
  }

  group('引导页（GET /bootstrap）', () {
    test('无票据 / 伪造票据 401，且原因可读', () async {
      final _Res missing = await client.get(ApiPaths.bootstrap);
      expect(missing.status, 401);
      expect(missing.json['detail'], contains('缺少引导票据'));

      final _Res forged = await client.get('${ApiPaths.bootstrap}?t=forged');
      expect(forged.status, 401);
      expect(forged.json['detail'], contains('无效、已使用或已过期'));
    });

    test('票据只能用一次：第二次 401', () async {
      final String t = await ticket();
      final _Res first = await client.get('${ApiPaths.bootstrap}?t=$t');
      expect(first.status, 200);
      expect(
        first.response.headers.contentType?.mimeType,
        'text/html',
        reason: '引导页必须是 text/html',
      );
      expect(first.response.headers.value('cache-control'), contains('no-store'));

      final _Res again = await client.get('${ApiPaths.bootstrap}?t=$t');
      expect(again.status, 401);
      expect(again.json['detail'], contains('已使用'));
    });

    test('种子化到数据根；之后每次重读磁盘（可独立更新）', () async {
      final File seed = File('${temp.path}/seed.html');
      seed.writeAsStringSync(
        '<html><body>SEED-1<script>var BOOTSTRAP_TICKET = '
        '"__BOOTSTRAP_TICKET__";</script></body></html>',
      );
      await server.close();
      client.close();
      server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
        dataDir: temp.path,
        bootstrapSourcePath: seed.path,
      );
      client = _Client(server);

      final _Res first = await client.get(
        '${ApiPaths.bootstrap}?t=${await ticket()}',
      );
      expect(first.status, 200);
      expect(first.text, contains('SEED-1'));
      expect(
        first.text,
        isNot(contains('__BOOTSTRAP_TICKET__')),
        reason: '占位符必须被替换',
      );
      final File local = File('${temp.path}/bootstrap/index.html');
      expect(local.existsSync(), isTrue, reason: '必须种子化到数据根');
      expect(
        local.readAsStringSync(),
        contains('__BOOTSTRAP_TICKET__'),
        reason: '磁盘上保留占位符，每次请求再注入新票据',
      );

      // 用户/更新器改掉磁盘上的页面 ⇒ 下一次请求必须读到新内容
      local.writeAsStringSync(
        '<html><body>UPDATED-2<script>var BOOTSTRAP_TICKET = '
        '"__BOOTSTRAP_TICKET__";</script></body></html>',
      );
      final _Res second = await client.get(
        '${ApiPaths.bootstrap}?t=${await ticket()}',
      );
      expect(second.status, 200);
      expect(second.text, contains('UPDATED-2'));
    });

    test('种子缺失 ⇒ 200 内置最小页（不是 500）', () async {
      await server.close();
      client.close();
      server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
        dataDir: temp.path,
        bootstrapSourcePath: '${temp.path}/definitely-missing.html',
      );
      client = _Client(server);

      final _Res res = await client.get(
        '${ApiPaths.bootstrap}?t=${await ticket()}',
      );
      expect(res.status, 200);
      expect(res.text, contains('内置最小页面'));
      expect(res.text, contains('assets/bootstrap/index.html'));
    });

    test('种子路径写不进去 ⇒ 仍返回 200 内置页', () async {
      // 让 `<数据根>/bootstrap` 是一个**文件**：种子化目录创建必然失败
      File('${temp.path}/bootstrap').writeAsStringSync('not a directory');
      final _Res res = await client.get(
        '${ApiPaths.bootstrap}?t=${await ticket()}',
      );
      expect(res.status, 200);
      expect(res.text, contains('内置最小页面'));
    });
  });

  group('引导会话 token', () {
    test('票据换会话（10 分钟），重复使用 401', () async {
      final _Res page = await client.get(
        '${ApiPaths.bootstrap}?t=${await ticket()}',
      );
      final String exchange = exchangeTicketOf(page.text);

      final _Res exchanged = await client.post(
        ApiPaths.bootstrapSession,
        body: <String, dynamic>{'ticket': exchange},
        omitAuth: true,
      );
      expect(exchanged.status, 200, reason: '$exchanged');
      expect(exchanged.json['scope'], 'plugin');
      expect(exchanged.json['expires_in'], 600);
      expect(exchanged.json['token'], isA<String>());

      final _Res reused = await client.post(
        ApiPaths.bootstrapSession,
        body: <String, dynamic>{'ticket': exchange},
        omitAuth: true,
      );
      expect(reused.status, 401);
      expect(reused.json['detail'], contains('已使用'));
    });

    test('票据不能直接当 Bearer 访问端点', () async {
      final String t = await ticket();
      final _Res res = await client.get(ApiPaths.meta, token: t);
      expect(res.status, 401, reason: '页面票据不等于授权');
    });

    test('只放行插件端点与 GET /api/meta，越权 403 可读', () async {
      final String session = server.tokens.issueBootstrapSession();

      final _Res meta = await client.get(ApiPaths.meta, token: session);
      expect(meta.status, 200, reason: '$meta');

      final _Res snapshot = await client.get(
        ApiPaths.pluginSnapshot,
        token: session,
      );
      expect(snapshot.status, 200);

      final _Res forbidden = await client.get(ApiPaths.agents, token: session);
      expect(forbidden.status, 403);
      expect(
        forbidden.json['detail'],
        contains('引导会话 token 只放行插件端点'),
      );

      final _Res files = await client.get('/api/files/ws-1', token: session);
      expect(files.status, 403);
    });

    test('过期后 401', () async {
      final String session = server.tokens.issueBootstrapSession(
        ttl: const Duration(milliseconds: 50),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final _Res res = await client.get(ApiPaths.meta, token: session);
      expect(res.status, 401);
    });
  });

  group('首个 ui.hello 成功后吊销会话 + 品牌申报', () {
    late Directory pluginRoot;
    late PluginBus bus;
    late CoreServer uiServer;

    setUp(() async {
      pluginRoot = await Directory.systemTemp.createTemp('tree_branding_');
      final File config = File('${pluginRoot.path}/plugins.yaml');
      config.writeAsStringSync('''
enabled: true
plugins:
  - id: ui.alpha
    name: Alpha UI
    command: dart
    runtime: ui
    enabled: false
''');
      bus = PluginBus(configFile: config.path, log: (_) {});
      uiServer = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
        pluginBus: bus,
        dataDir: pluginRoot.path,
      );
      // `CoreServer.start` 会按默认安装目录重设允许目录；测试插件目录必须在启动后
      // 再注入一次，否则闸门的「路径必须落在插件目录内」会拒收（不放宽闸门）。
      bus.configureBrandingDirs(<String>[pluginRoot.path]);
    });

    tearDown(() async {
      await uiServer.close();
      if (pluginRoot.existsSync()) await pluginRoot.delete(recursive: true);
    });

    Future<WebSocket> connectUi() async {
      final WebSocket socket = await WebSocket.connect(
        '${uiServer.handshake.wsBaseUrl}${CoreServer.wsPath}'
        '?token=${uiServer.token}',
      );
      addTearDown(() => socket.close());
      return socket;
    }

    void hello(WebSocket socket, {Map<String, dynamic>? branding}) {
      socket.add(
        jsonEncode(<String, dynamic>{
          'type': WsInboundType.uiHello,
          'data': <String, dynamic>{
            'plugin_id': 'ui.alpha',
            'version': '1.0.0',
            'capabilities': <String>['plugin.manage'],
            'branding': ?branding,
          },
        }),
      );
    }

    Future<void> until(
      Future<bool> Function() predicate,
      String reason,
    ) async {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (await predicate()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('超时等待：$reason');
    }

    test('首个 ui.hello 后会话 token 立即失效', () async {
      final String session = uiServer.tokens.issueBootstrapSession();
      expect(uiServer.tokens.liveSessionCount, 1);

      final WebSocket socket = await connectUi();
      hello(socket);
      await until(
        () async => uiServer.tokens.liveSessionCount == 0,
        'ui.hello 后吊销会话 token',
      );

      final _Client main = _Client(uiServer);
      addTearDown(main.close);
      final _Res res = await main.get(ApiPaths.meta, token: session);
      expect(res.status, 401);
    });

    test('品牌随 hello 申报，/api/meta 读到当前生效品牌；再 hello 不带即撤回', () async {
      final File icon = File('${pluginRoot.path}/app.ico');
      icon.writeAsBytesSync(_ico(<int>[16, 32, 48, 256]));

      final WebSocket socket = await connectUi();
      hello(
        socket,
        branding: <String, dynamic>{
          'icon': 'app.ico',
          'role': 'exe',
          'sizes': <int>[16, 32, 48, 256],
        },
      );

      final _Client main = _Client(uiServer);
      addTearDown(main.close);
      Map<String, dynamic>? branding;
      await until(() async {
        final _Res res = await main.get(ApiPaths.meta);
        branding = res.json['branding'] as Map<String, dynamic>?;
        return branding != null;
      }, '等待品牌生效');

      expect(branding!['plugin_id'], 'ui.alpha');
      expect(branding!['role'], 'exe');
      expect(branding!['icon'], endsWith('app.ico'));
      expect(branding!['sizes'], <int>[16, 32, 48, 256]);

      hello(socket, branding: null);
      await until(() async {
        final _Res res = await main.get(ApiPaths.meta);
        return res.json['branding'] == null;
      }, '撤回后 /api/meta.branding 回默认（null）');
    });
  });
}

/// 向上探仓库根（含 `packages/tree_core` 与 `assets/bootstrap/index.html`）。
String _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    final String candidate = dir.path;
    if (Directory('$candidate/packages/tree_core').existsSync() &&
        File('$candidate/assets/bootstrap/index.html').existsSync()) {
      return candidate;
    }
    final Directory parent = dir.parent;
    if (parent.path == candidate) break;
    dir = parent;
  }
  fail('找不到仓库根（需要同时存在 packages/tree_core 与 assets/bootstrap/index.html）');
}

/// 构造一个只含目录的最小 ICO（解析器只读目录）。
List<int> _ico(List<int> sizes) {
  final List<int> bytes = <int>[0, 0, 1, 0];
  final int count = sizes.length;
  bytes.addAll(<int>[count & 0xff, (count >> 8) & 0xff]);
  for (final int size in sizes) {
    final int side = size >= 256 ? 0 : size;
    bytes.addAll(<int>[
      side,
      side,
      0,
      0,
      1,
      0,
      32,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  }
  return bytes;
}

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> get(
    String path, {
    String? token,
    bool omitAuth = false,
  }) => _send('GET', path, token: token, omitAuth: omitAuth);

  Future<_Res> post(
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool omitAuth = false,
  }) => _send('POST', path, body: body, token: token, omitAuth: omitAuth);

  Future<_Res> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool omitAuth = false,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    if (!omitAuth) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${token ?? _server.token}',
      );
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(response, text);
  }

  void close() => _http.close(force: true);
}

class _Res {
  _Res(this.response, this.text);

  final HttpClientResponse response;
  final String text;

  int get status => response.statusCode;

  Map<String, dynamic> get json {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    final Object? decoded = jsonDecode(trimmed);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  @override
  String toString() => 'HTTP $status $text';
}
