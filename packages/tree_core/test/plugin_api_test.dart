import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
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

/// 插件快照的 REST 面（右栏「插件」面板）。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_api_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<PluginBus> busWith(String yaml) async {
    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      heartbeatInterval: const Duration(seconds: 30),
    );
    await bus.start();
    return bus;
  }

  Future<({CoreServer server, _Client client, PluginBus bus})> serve(
    String yaml,
  ) async {
    final PluginBus bus = await busWith(yaml);
    final CoreServer server = await CoreServer.start(
      pluginBus: bus,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    return (server: server, client: _Client(server), bus: bus);
  }

  test('GET /api/plugin/snapshot：就绪插件呈现 registered + 工具与配置', () async {
    final ({CoreServer server, _Client client, PluginBus bus})
    ctx = await serve(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}"]\n'
      '    granularity: team\n',
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final _Res res = await ctx.client.send(
      'GET',
      '/api/plugin/snapshot?team_id=team-1',
    );
    expect(res.status, 200);
    expect(res.json['enabled'], isTrue);
    final Map<String, dynamic> instance =
        (res.json['instances'] as List<dynamic>).single as Map<String, dynamic>;
    expect(instance['plugin_id'], 'sample');
    expect(instance['status'], 'registered');
    expect(instance['disabled_reason'], '');
    expect(instance['granularity'], 'team');
    expect(instance['last_heartbeat'], isA<int>());
    // 站点段**不再按 team 过滤**（站点全局唯一，过滤恒真）：快照恒看到**全部内置点位**
    // （广播 4 + 执行 7 + 中转 6 = 17；收集站不预建）+ 该插件申报时现建的收集站。
    final List<dynamic> stations = res.json['stations'] as List<dynamic>;
    final List<String> prebuiltPoints = StationPoints.all
        .where((StationPointSpec spec) => spec.kind != StationKind.collect)
        .map((StationPointSpec spec) => spec.id)
        .toList()
      ..sort();
    expect(
      stations
          .map((dynamic s) => (s as Map<String, dynamic>)['station_id'])
          .toList(),
      <String>[StationHubIds.collect, ...prebuiltPoints],
      reason: '每个接入点（point）是一个独立站点实例，id 不含 team / mode；按 id 字典序',
    );
    final Map<String, dynamic> collectStation = stations.first
        as Map<String, dynamic>;
    expect(collectStation['station_id'], StationHubIds.collect);
    expect(collectStation['kind'], 'collect');
    // 该插件声明里没有 scope ⇒ **通配订阅**（空 team = 作用于所有 team）：
    // 空 scope 也是合法订阅声明，不再被 fail-closed 拒绝（用户定稿）。
    expect(
      collectStation['subscriber_count'],
      1,
      reason: '空 scope = 通配订阅：挂上收集站（工具仍走 tools/list 路径注册）',
    );
    expect(
      collectStation['subscribers_by_team'],
      <String, dynamic>{
        '': <String, dynamic>{
          'count': 1,
          'plugin_ids': <String>['sample'],
        },
      },
      reason: '空 team 归到空串键（前端渲染成「全部 team（未限定）」= 作用于所有 team）',
    );
    final Map<String, dynamic> config =
        res.json['config'] as Map<String, dynamic>;
    expect((config['plugins'] as List<dynamic>).single['plugin_id'], 'sample');
    expect(config['path'], contains('plugins.yaml'));
  });

  test('GET /api/plugin/snapshot：坏插件呈现 disabled + 原因；未接入总线返回空集', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\n'
          'plugins:\n'
          '  - id: broken\n'
          '    command: definitely-not-an-executable-xyz\n',
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res res = await ctx.client.send('GET', '/api/plugin/snapshot');
    final Map<String, dynamic> instance =
        (res.json['instances'] as List<dynamic>).single as Map<String, dynamic>;
    expect(instance['status'], 'disabled');
    expect(instance['disabled_reason'], isNotEmpty);
    expect((res.json['watchdog'] as Map<String, dynamic>)['disabled_count'], 1);

    // 未接入总线：200 + enabled:false 空集（前端渲染空态而不是报错）
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
    final _Res empty = await bareClient.send('GET', '/api/plugin/snapshot');
    expect(empty.status, 200);
    expect(empty.json['enabled'], isFalse);
    expect(empty.json['instances'], isEmpty);
  });
}
