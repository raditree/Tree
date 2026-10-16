import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(String method, String path, {Object? body}) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    if (body != null) {
      // PATCH / POST 都是 JSON 体：核心用 readJsonBody 读，非法 JSON 回 400（不留到 500）。
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
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
    // （广播 10 + 执行 11 + 中转 12 = 33；收集站不预建）+ 该插件申报时现建的**两个**收集站。
    final List<dynamic> stations = res.json['stations'] as List<dynamic>;
    final List<String> prebuiltPoints =
        StationPoints.all
            .where((StationPointSpec spec) => spec.kind != StationKind.collect)
            .map((StationPointSpec spec) => spec.id)
            .toList()
          ..sort();
    expect(
      stations
          .map((dynamic s) => (s as Map<String, dynamic>)['station_id'])
          .toList(),
      <String>[
        StationHubIds.collectCapability,
        StationHubIds.collect,
        ...prebuiltPoints,
      ],
      reason: '每个接入点（point）是一个独立站点实例，id 不含 team / mode；按 id 字典序',
    );
    final Map<String, dynamic> collectStation = stations.firstWhere(
      (dynamic s) =>
          (s as Map<String, dynamic>)['station_id'] == StationHubIds.collect,
    ) as Map<String, dynamic>;
    expect(collectStation['station_id'], StationHubIds.collect);
    expect(collectStation['kind'], 'collect');
    // 阶段 6 的点位申报收集站也在快照里（同一个插件同时挂两个收集站）
    final Map<String, dynamic> capabilityStation = stations.firstWhere(
      (dynamic s) =>
          (s as Map<String, dynamic>)['station_id'] ==
          StationHubIds.collectCapability,
    ) as Map<String, dynamic>;
    expect(capabilityStation['kind'], 'collect');
    expect(capabilityStation['subscriber_count'], 1);
    // 该插件声明里没有 scope ⇒ **通配订阅**（空 team = 作用于所有 team）：
    // 空 scope 也是合法订阅声明，不再被 fail-closed 拒绝（用户定稿）。
    expect(
      collectStation['subscriber_count'],
      1,
      reason: '空 scope = 通配订阅：挂上收集站（工具仍走 tools/list 路径注册）',
    );
    expect(collectStation['subscribers_by_team'], <String, dynamic>{
      '': <String, dynamic>{
        'count': 1,
        'plugin_ids': <String>['sample'],
      },
    }, reason: '空 team 归到空串键（前端渲染成「全部 team（未限定）」= 作用于所有 team）');
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

  // ── 站点详情页的 REST 面（介绍 / 配置 / 订阅者禁用）─────────────────────
  //
  // 这一组只验**路由层**：能不能取到、能不能改、改错了给不给可读原因。
  // 判定口径本身（内置能改什么、禁用不等于退订）在 plugin_station_test.dart
  // 与 plugin_request_test.dart 里对着 StationHub / 总线验，这里不重复。

  /// 带 `--station-client` 的插件：它能主动发 station/register / subscribe。
  String stationClientYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--station-client"]\n'
      '    granularity: team\n';

  /// 让假插件**主动**发一条站点请求（自建站、订阅都走这个入口）。
  Future<Map<String, dynamic>> pluginRequest(
    PluginBus bus, {
    String pluginId = 'sample',
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
  }) async {
    final PluginCallResult called = await bus.callTool(
      'plugin__${pluginId}__request_station',
      <String, dynamic>{'method': method, 'params': params},
    );
    expect(called.isError, isFalse, reason: called.text);
    return jsonDecode(called.text) as Map<String, dynamic>;
  }

  /// 自建一个广播站，返回它的 id（面板上「插件内置站点」就是这一条）。
  Future<String> registerSelfStation(
    PluginBus bus, {
    String name = 'fanout',
    String readme = '自建广播站：把工具公告按 team 再分发一次',
  }) async {
    final Map<String, dynamic> created = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': name,
        'readme': readme,
      },
    );
    final Map<String, dynamic> result =
        created['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    return result['station_id'] as String;
  }

  test('GET /api/plugin/stations/{id}：详情给得出介绍与配置；未知 id ⇒ 404 可读原因', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(stationClientYaml());
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    // ① 内置点位：详情页要读的字段一个都不能缺
    final String builtin = Uri.encodeComponent(StationHubIds.relayToolPre);
    final _Res res = await ctx.client.send(
      'GET',
      '/api/plugin/stations/$builtin',
    );
    expect(res.status, 200);
    expect(res.json['station_id'], StationHubIds.relayToolPre);
    expect(
      res.json['readme'],
      isNotEmpty,
      reason: '内置点位的介绍来自点位表（缺了回落 description），面板不留空白',
    );
    expect(res.json['builtin'], isTrue);
    expect(res.json['max_subscriptions'], isA<int>());
    expect(res.json['shared'], isFalse, reason: '内置站对插件不开触发通道');
    expect(res.json['allowed_plugins'], isEmpty);
    expect(res.json['config'], isEmpty);
    expect(res.json['subscriptions'], isA<List<dynamic>>());

    // ② 自建站同样取得到（断言 1 的面向面板那一半）
    final String selfId = await registerSelfStation(ctx.bus);
    final _Res self = await ctx.client.send(
      'GET',
      '/api/plugin/stations/${Uri.encodeComponent(selfId)}',
    );
    expect(self.status, 200);
    expect(self.json['builtin'], isFalse);
    expect(self.json['readme'], '自建广播站：把工具公告按 team 再分发一次');

    // ③ 不存在的站点 ⇒ 404 + 原因（不给空对象让前端渲染一张空白详情页）
    final _Res gone = await ctx.client.send(
      'GET',
      '/api/plugin/stations/plugin.sample.broadcast.nope',
    );
    expect(gone.status, 404);
    expect(gone.json['detail'].toString(), contains('站点不存在'));
  });

  test('PATCH /api/plugin/stations/{id}/config：内置只改上限，自建站改介绍与配置', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(stationClientYaml());
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    String configPath(String id) =>
        '/api/plugin/stations/${Uri.encodeComponent(id)}/config';

    // ① 内置站：介绍改不了（点位表才是定义处），上限改得动
    final String builtin = StationHubIds.relayToolPre;
    final _Res builtinReadme = await ctx.client.send(
      'PATCH',
      configPath(builtin),
      body: <String, dynamic>{'readme': '想改内置站的介绍'},
    );
    expect(builtinReadme.status, 400);
    expect(builtinReadme.json['detail'].toString(), contains('内置站点'));

    final _Res builtinMax = await ctx.client.send(
      'PATCH',
      configPath(builtin),
      body: <String, dynamic>{'max_subscriptions': 7},
    );
    expect(builtinMax.status, 200, reason: '${builtinMax.json}');
    expect(builtinMax.json['max_subscriptions'], 7);

    // ② 自建站：共享声明与自定义配置都能改，且**没发的键不改动**（PATCH = 局部更新）
    final String selfId = await registerSelfStation(ctx.bus);
    final _Res patched = await ctx.client.send(
      'PATCH',
      configPath(selfId),
      body: <String, dynamic>{
        'shared': true,
        'allowed_plugins': <String>['other'],
        'config': <String, dynamic>{'route': 'team'},
      },
    );
    expect(patched.status, 200, reason: '${patched.json}');
    expect(patched.json['shared'], isTrue);
    expect(patched.json['allowed_plugins'], <String>['other']);
    expect(
      (patched.json['config'] as Map<String, dynamic>)['route'],
      'team',
      reason: '「其他（站点自定义配置）」区改完要能读回来',
    );
    expect(patched.json['readme'], '自建广播站：把工具公告按 team 再分发一次');

    // ③ 改完再 GET：读的是同一份实例（落盘了，面板重开还是这些值）
    final _Res detail = await ctx.client.send(
      'GET',
      '/api/plugin/stations/${Uri.encodeComponent(selfId)}',
    );
    expect(detail.json['shared'], isTrue);
    expect((detail.json['config'] as Map<String, dynamic>)['route'], 'team');
    expect(
      File(ctx.bus.stations.storePath).readAsStringSync(),
      contains('route'),
      reason: '面板上改的站点配置必须落盘（stations.yaml），否则重启就丢',
    );

    // ④ 值类型不对 ⇒ 400 + 原因（不悄悄忽略多余的键）
    final _Res bad = await ctx.client.send(
      'PATCH',
      configPath(selfId),
      body: <String, dynamic>{'max_subscriptions': '很多'},
    );
    expect(bad.status, 400);
    expect(bad.json['detail'].toString(), contains('整数'));

    // ⑤ 空 PATCH ⇒ 400（而不是“成功”什么都没改）
    final _Res none = await ctx.client.send(
      'PATCH',
      configPath(selfId),
      body: <String, dynamic>{},
    );
    expect(none.status, 400);
    expect(none.json['detail'].toString(), contains('至少要给一个'));

    // ⑥ 不存在的站点 ⇒ 404
    final _Res gone = await ctx.client.send(
      'PATCH',
      configPath('system.nope'),
      body: <String, dynamic>{'max_subscriptions': 1},
    );
    expect(gone.status, 404);
  });

  test('POST .../subscribers/{key}：禁用不删订阅，disabled 写进详情；找不到 ⇒ 404', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(stationClientYaml());
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final String selfId = await registerSelfStation(ctx.bus);
    final Map<String, dynamic> subscribed = await pluginRequest(
      ctx.bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': selfId},
    );
    expect(
      (subscribed['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${subscribed['result']}',
    );

    final _Res before = await ctx.client.send(
      'GET',
      '/api/plugin/stations/${Uri.encodeComponent(selfId)}',
    );
    final List<dynamic> subs = before.json['subscriptions'] as List<dynamic>;
    expect(subs, hasLength(1));
    // 键位形如 plugin_id|scope（里面带 `|`，必须编码后拼进路径）
    final String key =
        (subs.single as Map<String, dynamic>)['subscriber'] as String;
    expect(key, startsWith('sample|'));
    final String subPath =
        '/api/plugin/stations/${Uri.encodeComponent(selfId)}/subscribers'
        '/${Uri.encodeComponent(key)}';

    // ① 禁用：订阅关系保留，只是 disabled = true
    final _Res off = await ctx.client.send(
      'POST',
      subPath,
      body: <String, dynamic>{'disabled': true},
    );
    expect(off.status, 200, reason: '${off.json}');
    expect(off.json['subscriber_count'], 1, reason: '禁用不是退订');
    final Map<String, dynamic> disabled =
        (off.json['subscriptions'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(disabled['disabled'], isTrue, reason: '详情页要能看出这一条被关了');

    // ② 启用回去
    final _Res on = await ctx.client.send(
      'POST',
      subPath,
      body: <String, dynamic>{'disabled': false},
    );
    expect(on.status, 200);
    expect(
      ((on.json['subscriptions'] as List<dynamic>).single
          as Map<String, dynamic>)['disabled'],
      isFalse,
    );

    // ③ body 不是布尔 ⇒ 400（不默认成 true 或 false）
    final _Res notBool = await ctx.client.send(
      'POST',
      subPath,
      body: <String, dynamic>{'disabled': 'yes'},
    );
    expect(notBool.status, 400);
    expect(notBool.json['detail'].toString(), contains('布尔'));

    // ④ 键位不存在 ⇒ 404 + 原因（已退订 / 插件下线的情况要说清）
    final _Res gone = await ctx.client.send(
      'POST',
      '/api/plugin/stations/${Uri.encodeComponent(selfId)}/subscribers'
          '/${Uri.encodeComponent('nobody|')}',
      body: <String, dynamic>{'disabled': true},
    );
    expect(gone.status, 404);
    expect(gone.json['detail'].toString(), contains('订阅者不存在'));
  });

  test('插件介绍与工具跟着快照与清单走（详情页的数据源）', () async {
    final ({CoreServer server, _Client client, PluginBus bus})
    ctx = await serve(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    description: 把工具公告按 team 再分发，并提供一个只能读文件的工具\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--station-client"]\n'
      '    granularity: team\n',
    );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    // ① 快照的实例段：介绍 + 工具（插件未启动时工具就该是空表，不臆测能力）
    final _Res snap = await ctx.client.send('GET', '/api/plugin/snapshot');
    expect(snap.status, 200);
    final Map<String, dynamic> instance =
        (snap.json['instances'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(instance['description'], '把工具公告按 team 再分发，并提供一个只能读文件的工具');
    expect(
      (instance['tools'] as List<dynamic>)
          .map((dynamic t) => (t as Map<String, dynamic>)['name'])
          .toList(),
      ctx.bus
          .toolsOf('sample')
          .map((PluginToolInfo tool) => tool.name)
          .toList(),
      reason: '面板列的工具必须与总线的工具表同源（不能两边各自数一遍）',
    );

    // ② 清单面（持久态）也读得到：介绍能回填到编辑区
    final _Res configs = await ctx.client.send('GET', '/api/plugin/configs');
    expect(
      (configs.json['configs'] as List<dynamic>).single['description'],
      instance['description'],
    );

    // ③ PATCH 改介绍 ⇒ 落盘 + 清单读回新值（插件详情页的「改介绍」就走这条路）
    const String rewritten = '改写后的介绍：只服务 team-1 的工具公告';
    final _Res patched = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/sample',
      body: <String, dynamic>{'description': rewritten},
    );
    expect(patched.status, 200, reason: '${patched.json}');
    final _Res again = await ctx.client.send('GET', '/api/plugin/configs');
    expect(
      (again.json['configs'] as List<dynamic>).single['description'],
      rewritten,
    );

    // ④ 把介绍清掉 ⇒ 键真的消失（不留 description: "" 这种噪声）
    await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/sample',
      body: <String, dynamic>{'description': ''},
    );
    final _Res cleared = await ctx.client.send('GET', '/api/plugin/configs');
    expect(
      (cleared.json['configs'] as List<dynamic>).single.containsKey(
        'description',
      ),
      isFalse,
    );
  });
}
