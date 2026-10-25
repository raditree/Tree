import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 片 C：REST 委派（`system.collect.api.routes` + `api/delegate`）端到端测试。
///
/// 全程用**真插件进程**（test/fixtures/fake_plugin.dart），不 mock 总线：
/// - 申报：插件按 schema 回 `{routes: [{method, pattern}]}`；
/// - 执行：核心把命中请求转成 `api/delegate` RPC，回包原样写回 REST。
///
/// 大体积用例不直接断言 RSS：测试与被测核心同进程，Dart VM 的堆/RSS 会互相污染，
/// CI 上不稳定。改用**可观测的结构断言**：上传必须是 `body_path`（信封里不能有
/// `body`）且插件读到的文件大小精确；下载必须是 `result_path` 流式返回且字节数
/// 精确、结束文件被清理。这两条已经能证明核心没有把整块 body 驻留内存。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_delegated_rest_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
  });

  tearDown(() async {
    for (int i = 0; i < 10; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
  });

  /// 生成一份插件配置。`plugins` 里每项是 (id, args)。
  String yamlFor(
    List<({String id, List<String> args})> plugins, {
    bool enabled = true,
  }) {
    final StringBuffer buffer = StringBuffer('enabled: $enabled\nplugins:\n');
    for (final ({String id, List<String> args}) plugin in plugins) {
      buffer.write(
        '  - id: ${plugin.id}\n'
        '    name: ${plugin.id}\n'
        '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
        '    args: ['
        // YAML 双引号串里的反斜杠必须转义，否则 `C:\Users...` 会被当成非法转义
        // 让整份 plugins.yaml 解析失败（Windows 路径下必踩）。
        '${<String>['"${script.replaceAll('\\', '/')}"', ...plugin.args.map((String a) => '"${a.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"')].join(', ')}'
        ']\n'
        '    granularity: team\n'
        '    scope: {team_id: team-1, mode_key: local}\n',
      );
    }
    return buffer.toString();
  }

  void writeYaml(String yaml) {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
  }

  Future<({CoreServer server, _Client client, PluginBus bus})> serve(
    List<({String id, List<String> args})> plugins, {
    Duration delegateTimeout = const Duration(milliseconds: 250),
  }) async {
    writeYaml(yamlFor(plugins));
    final MemoryStore store = MemoryStore();
    store.putAgent(
      CoreAgent(
        id: 'ag1',
        name: '甲',
        createdAt: 1,
        updatedAt: 1,
        teamId: 'team-1',
        workspaceDir: p.join(temp.path, 'workspace'),
      ),
    );
    final PluginBus bus = PluginBus(
      configFile: p.join(temp.path, 'config', 'plugins.yaml'),
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      apiDelegateTimeout: delegateTimeout,
    );
    await bus.start();
    final CoreServer server = await CoreServer.start(
      pluginBus: bus,
      store: store,
      dataDir: temp.path,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    // 接线完成（bindDelegatedRouter + invalidate）后再刷新一次：这一趟才会把
    // `system.collect.api.routes` 的申报写进归属表。
    await bus.ensureToolTableFresh();
    return (server: server, client: _Client(server), bus: bus);
  }

  const String gitStatus = '/api/files/{workspaceId}/git-status';

  test('正常委派：状态码 / 响应体 / Content-Type 原样透传，且带四元组与只读上下文', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (id: 'sample', args: <String>['--api-route', 'POST:$gitStatus']),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    // 用 POST 是刻意的：GET 这条核心自己已经实现（片 C 不删实现，见 SubTask 3.6），
    // 委派必须让位；POST 只有 501 桩，归委派接。
    final _Response res = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status?ignored=1&tag=a&tag=b',
      headers: <String, String>{'X-Secret': 'nope', 'Accept': 'application/json'},
    );
    expect(res.status, 200);
    expect(res.headers['content-type'], contains('application/json'));
    final Map<String, dynamic> envelope =
        jsonDecode(res.text) as Map<String, dynamic>;
    // 四元组 / 只读上下文
    expect(envelope['method'], 'POST');
    expect(envelope['path'], '/api/files/ag1/git-status');
    expect(envelope['params'], <String, dynamic>{'workspaceId': 'ag1'});
    expect(envelope['query'], <String, dynamic>{
      'ignored': '1',
      'tag': <String>['a', 'b'],
    });
    expect(envelope['agent_id'], 'ag1');
    expect(envelope['team_id'], 'team-1');
    expect(envelope['workspace_dir'], p.join(temp.path, 'workspace'));
    expect(envelope['data_dir'], temp.path);
    expect(envelope['scope']['mode_key'], StationModeKey.local);
    // 请求头白名单：自定义头与凭证头不出去
    final Map<String, dynamic> headers =
        envelope['headers'] as Map<String, dynamic>;
    expect(headers['accept'], 'application/json');
    expect(headers.containsKey('x-secret'), isFalse);
    expect(headers.containsKey('authorization'), isFalse);
    // 白名单路径出现在 /api/meta.routes 里，归属可查
    final _Response meta = await ctx.client.send('GET', '/api/meta');
    expect(meta.status, 200);
    final List<dynamic> routes =
        (meta.json['routes'] as List<dynamic>?) ?? <dynamic>[];
    expect(
      routes,
      contains(
        allOf(
          containsPair('method', 'POST'),
          containsPair('pattern', gitStatus),
          containsPair('owner', 'sample'),
        ),
      ),
    );
  });

  test('result_path：合法路径按字节流式回写，结束后临时文件被清理', () async {
    final String resultPath = p.join(
      temp.path,
      'tmp',
      'api-delegate',
      'result.bin',
    );
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'POST:$gitStatus',
            '--api-delegate-mode',
            'result',
            '--api-result-size',
            '32',
            '--api-result-path',
            resultPath,
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final _Response res = await ctx.client.send('POST', '/api/files/ag1/git-status');
    expect(res.status, 200);
    expect(res.bytes.length, 32, reason: '插件回的 result 文件 32 字节，原样透传');
    expect(res.headers['content-type'], contains('application/octet-stream'));
    await _waitGone(File(resultPath));
  });

  test('未申报的委派路径只回 404（不是 503，也不是 501）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (id: 'sample', args: <String>['--api-route', 'GET:$gitStatus']),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    // 白名单内、但没人申报：归属表为空 ⇒ 404（没有 503 的"归属"可言）。
    final _Response unowned = await ctx.client.send(
      'DELETE',
      '/api/files/ag1/pdf-info',
    );
    expect(unowned.status, 404);
    // 白名单外：即使插件想申报也会被拒收，请求仍然是 404。
    final _Response unknown = await ctx.client.send(
      'GET',
      '/api/plugin/snapshot',
    );
    expect(unknown.status, 200, reason: '已实现路由永远优先');
  });

  test('归属插件被停用 / 下线 ⇒ 503 且有可读 reason（不是 404）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (id: 'sample', args: <String>['--api-route', 'POST:$gitStatus']),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    // 停用（配置还在）：归属表不销账 ⇒ 503。
    writeYaml(
      yamlFor(
        <({String id, List<String> args})>[
          (id: 'sample', args: <String>['--api-route', 'POST:$gitStatus']),
        ],
        enabled: false,
      ),
    );
    await ctx.bus.applyConfigs();
    final _Response disabled = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(disabled.status, 503);
    expect((disabled.json['reason'] ?? '').toString(), contains('已停用'));

    // 下线但仍在清单里（close 让插件停机、配置条目不动）：仍然 503。
    await ctx.bus.close();
    final _Response stopped = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(stopped.status, 503);
    expect((stopped.json['reason'] ?? '').toString(), isNotEmpty);
  });

  test('归属插件从清单删除 ⇒ 按 plugin_id 销账，请求回到 404', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (id: 'sample', args: <String>['--api-route', 'POST:$gitStatus']),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    writeYaml(yamlFor(const <({String id, List<String> args})>[]));
    await ctx.bus.applyConfigs();
    final _Response res = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(res.status, 404, reason: '插件不在清单里 = 归属销账，按无归属处理');
    expect(ctx.server.delegatedRouter.routeCount, 0);
  });

  test('超时 ⇒ 504 且 reason 可读', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'POST:$gitStatus',
            '--api-delegate-mode',
            'timeout',
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Response timeout = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(timeout.status, 504);
    expect((timeout.json['reason'] ?? '').toString(), contains('超时'));
  });

  test('回包非法 ⇒ 502 且 reason 可读', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'POST:$gitStatus',
            '--api-delegate-mode',
            'invalid',
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Response invalid = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(invalid.status, 502);
    expect((invalid.json['reason'] ?? '').toString(), contains('回包非法'));
  });

  test('同一 method+pattern 双家申报 ⇒ 整条拒收（与启动顺序无关）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (id: 'sample-a', args: <String>['--api-route', 'POST:$gitStatus']),
        (id: 'sample-b', args: <String>['--api-route', 'POST:$gitStatus']),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    expect(ctx.server.delegatedRouter.routeCount, 0);
    expect(ctx.server.delegatedRouter.conflictCount, 1);
    expect(
      ctx.server.delegatedRouter.notes.join('\n'),
      contains('路由冲突'),
    );
    final _Response res = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(res.status, 404, reason: '冲突条目不择一，不能被任何一家承接');
    final _Response meta = await ctx.client.send('GET', '/api/meta');
    expect(meta.status, 200);
    expect(meta.json['routes'], isEmpty);
  });

  test('已实现路由：申报被接受并标 shadowed，HTTP 仍由核心承接（双跑期）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (id: 'sample', args: <String>['--api-route', 'GET:$gitStatus']),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    // 双跑期（A2~A4）：插件必须先申报、后交接。同键已被核心实现时**接受**申报
    // （归属表里有它、/api/meta 能看到），但 notes 写明暂由核心承接；核心删掉
    // 该实现后同一申报自动生效——不能再拒收，否则「先申报后交接」就死锁了。
    expect(ctx.server.delegatedRouter.routeCount, 1);
    expect(
      ctx.server.delegatedRouter.notes.join('\n'),
      allOf(contains('核心仍在实现'), contains('shadowed')),
      reason: '接受申报必须留一条可读记录：核心仍在承接',
    );
    final _Response meta = await ctx.client.send('GET', '/api/meta');
    expect(
      meta.json['routes'],
      contains(
        allOf(
          containsPair('method', 'GET'),
          containsPair('pattern', '/api/files/{workspaceId}/git-status'),
          containsPair('owner', 'sample'),
        ),
      ),
    );

    // 已实现路由（GET 未接 FileService，核心自己的回答是 501 文件服务尚未接入）。
    final _Response implemented = await ctx.client.send(
      'GET',
      '/api/files/ag1/git-status',
    );
    expect(implemented.status, 501);
    expect(implemented.text, contains('文件服务'));
  });

  test('自造 /api 路由可申报并承接（L-28 去静态白名单）', () async {
    const String custom = '/api/sample/tree-info';
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'GET:$custom',
            '--api-delegate-mode',
            'text',
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    expect(
      ctx.server.delegatedRouter.routeCount,
      1,
      reason: '自造路径不需要改核心（不再有静态白名单）',
    );
    expect(ctx.server.delegatedRouter.notes, isEmpty);

    final _Response meta = await ctx.client.send('GET', '/api/meta');
    expect(meta.status, 200);
    expect(
      meta.json['routes'],
      contains(
        allOf(
          containsPair('method', 'GET'),
          containsPair('pattern', custom),
          containsPair('owner', 'sample'),
        ),
      ),
    );

    final _Response res = await ctx.client.send('GET', custom);
    expect(res.status, 200);
    expect(res.text, contains('plugin:GET $custom'));
  });

  test('保留前缀 / 核心永久面 / 非 /api 前缀 ⇒ 申报阶段可读拒收', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'GET:/api/plugin/snapshot',
            '--api-route',
            'GET:/api/settings/frame-rate',
            '--api-route',
            'GET:/bootstrap',
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    expect(ctx.server.delegatedRouter.routeCount, 0);
    expect(ctx.server.delegatedRouter.conflictCount, 0);
    final String notes = ctx.server.delegatedRouter.notes.join('\n');
    expect(notes, contains('核心保留面'), reason: '/api/plugin 是保留前缀');
    expect(notes, contains('核心永久面'), reason: '平台设置属于 coreOwned');
    expect(notes, contains('必须以 /api/ 开头'), reason: '/bootstrap 不是 /api 命名空间');
    final _Response meta = await ctx.client.send('GET', '/api/meta');
    expect(meta.json['routes'], isEmpty);
  });

  test('桩路由被委派覆盖后返回插件结果而不是 501', () async {
    // 同一个 pattern 的 DELETE 核心没有实现；桩先登记，再让插件申报。
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'DELETE:$gitStatus',
            '--api-delegate-mode',
            'text',
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    ctx.server.stubRouter.add(
      'DELETE',
      gitStatus,
      (HttpRequest request, Map<String, String> _) async {
        request.response.statusCode = 501;
        request.response.write('STUB');
        await request.response.close();
      },
    );
    final _Response delegated = await ctx.client.send(
      'DELETE',
      '/api/files/ag1/git-status',
    );
    expect(delegated.status, 200, reason: '委派优先于桩，不能永远 501');
    expect(delegated.text, contains('plugin:DELETE'));
  });

  test('result_path 越界 ⇒ 502（路径归属校验）', () async {
    final String outside = p.join(temp.path, '..', 'outside-result.bin');
    File(outside).writeAsBytesSync(<int>[1, 2, 3]);
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'POST:$gitStatus',
            '--api-delegate-mode',
            'escape',
            '--api-result-path',
            outside,
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
      try {
        File(outside).deleteSync();
      } catch (_) {
        // 已清理
      }
    });

    final _Response res = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
    );
    expect(res.status, 502);
    expect((res.json['reason'] ?? '').toString(), contains('越界'));
  });

  test('100MiB 上传只给 body_path（不把整块 body 塞信封）', () async {
    const int size = 100 << 20; // 100 MiB
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'POST:$gitStatus',
            '--api-delegate-mode',
            'envelope',
          ],
        ),
      ],
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    // 客户端同样分块写：测试进程自己也不整块持有 100MiB。
    final _Response uploaded = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
      streamBytes: size,
      contentType: ContentType.binary,
    );
    expect(uploaded.status, 200);
    final Map<String, dynamic> envelope =
        jsonDecode(uploaded.text) as Map<String, dynamic>;
    expect(envelope.containsKey('body'), isFalse);
    expect(envelope['body_path'], isA<String>());
    expect(envelope['body_size'], size);
    expect(envelope['body_path_exists'], isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('100MiB 下载走 result_path 流式回写，结束后清理', () async {
    const int size = 100 << 20; // 100 MiB
    final String resultPath = p.join(
      temp.path,
      'tmp',
      'api-delegate',
      'big-result.bin',
    );
    final ({CoreServer server, _Client client, PluginBus bus}) ctx = await serve(
      <({String id, List<String> args})>[
        (
          id: 'sample',
          args: <String>[
            '--api-route',
            'POST:$gitStatus',
            '--api-delegate-mode',
            'result',
            '--api-result-size',
            '$size',
            '--api-result-path',
            resultPath,
          ],
        ),
      ],
      // 假插件要先落 100MiB 再回包，默认 250ms 一定判超时。
      delegateTimeout: const Duration(minutes: 2),
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Response downloaded = await ctx.client.send(
      'POST',
      '/api/files/ag1/git-status',
      countOnly: true,
    );
    expect(downloaded.status, 200);
    expect(downloaded.countedBytes, size);
    await _waitGone(File(resultPath));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 等结果文件被核心清掉（Windows 上删文件与客户端收完响应之间有毫秒级错位）。
Future<void> _waitGone(File file) async {
  for (int i = 0; i < 40; i++) {
    if (!file.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(file.existsSync(), isFalse, reason: '流式回写结束后核心必须清理结果文件');
}

/// 极简 HTTP 客户端：支持 JSON / 大体积分块上传 / 大体积流式计数。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Response> send(
    String method,
    String path, {
    Map<String, String>? headers,
    int? streamBytes,
    ContentType? contentType,
    bool countOnly = false,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    headers?.forEach((String name, String value) {
      request.headers.set(name, value);
    });
    if (streamBytes != null) {
      request.headers.contentType = contentType ?? ContentType.binary;
      request.contentLength = streamBytes;
      const int chunk = 1 << 20;
      final List<int> block = List<int>.filled(chunk, 3);
      int remaining = streamBytes;
      while (remaining > 0) {
        final int n = remaining < chunk ? remaining : chunk;
        request.add(n == chunk ? block : block.sublist(0, n));
        remaining -= n;
      }
    }
    final HttpClientResponse response = await request.close();
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      responseHeaders[name.toLowerCase()] = values.join(', ');
    });
    if (countOnly) {
      int total = 0;
      await for (final List<int> chunk in response) {
        total += chunk.length;
      }
      return _Response(
        statusCode: response.statusCode,
        headers: responseHeaders,
        bytes: const <int>[],
        text: '',
        countedBytes: total,
      );
    }
    final List<int> bytes = await response.fold<List<int>>(
      <int>[],
      (List<int> all, List<int> chunk) => all..addAll(chunk),
    );
    return _Response(
      statusCode: response.statusCode,
      headers: responseHeaders,
      bytes: bytes,
      text: utf8.decode(bytes, allowMalformed: true),
    );
  }

  void close() => _http.close(force: true);
}

class _Response {
  const _Response({
    required this.statusCode,
    required this.headers,
    required this.bytes,
    required this.text,
    this.countedBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> bytes;
  final String text;

  /// `countOnly` 模式下**只计数不落内存**的响应字节数。
  final int? countedBytes;

  int get status => statusCode;

  Map<String, dynamic> get json => text.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
}
