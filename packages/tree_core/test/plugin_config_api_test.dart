// 插件清单 REST 面（M9 §4.2）的用例：CRUD + 每项开关 + 内置插件开关 + 热应用回报。
//
// 锁住的口径：
// 1. 读写的是**磁盘上的 plugins.yaml**（持久态），不是插件总线内存里的那一份；
// 2. 校验失败 = 400 + 可读中文原因，且**不落盘**（唯一性、不存在、类型 / 白名单）；
// 3. 热应用**如实回报**：本轮插件总线只在核心启动时读一次配置，因此"新增条目 /
//    新条目开关 / 运行中条目的停用"都会得到 hot_applied=false +
//    「配置已保存，但本次热应用失败，重启核心后生效」——不许假装成功；
//    唯一真生效的是"总线认识的条目的 restart"（心跳 degraded 后手动恢复用）。
// 4. 内置插件：清单常驻（未启用也可见）、enable 写一条带 builtin 标记的普通配置、
//    disable 把条目置 enabled:false 但**保留条目**；运行时 / 脚本缺失给可读错误。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/builtin_plugins.dart';
import 'package:tree_core/tree_core.dart';

/// 极简 HTTP 客户端（带 token，可发 GET / POST / PATCH / DELETE + JSON 体）。
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

  /// 可读错误文本（detail 字段）。
  String get detail => (json['detail'] ?? '').toString();
}

void main() {
  late Directory temp;
  late String script;
  late String configFile;
  late String pluginDir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_cfg_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    pluginDir = p.join(temp.path, 'plugins');
    Directory(pluginDir).createSync(recursive: true);
    // 内置插件的脚本：内容无关紧要（用例只解析路径，不真跑 python）
    File(p.join(pluginDir, 'sample_plugin.py')).writeAsStringSync('# 示例\n');
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

  /// 假的内置插件目录：脚本目录指向临时 plugins/，探测器把 python 判为可用。
  BuiltinPluginCatalog catalog({bool python = true, String? roots}) =>
      BuiltinPluginCatalog(
        scriptRoots: <String>[roots ?? pluginDir],
        probe: (String command, List<String> args) async =>
            python && command == 'python',
        isWindows: true,
      );

  /// 假插件的启动命令行（真跑 dart test/fixtures/fake_plugin.dart）。
  List<String> fakePluginYaml(String id) => <String>[
    '  - id: $id',
    '    name: 样例插件',
    '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"',
    '    args: ["${script.replaceAll('\\', '/')}"]',
  ];

  /// 起一个带插件总线的核心（content = 落盘的 plugins.yaml 内容）。
  Future<({CoreServer server, _Client client, PluginBus bus})> serve(
    String content, {
    BuiltinPluginCatalog? builtins,
  }) async {
    final File file = File(configFile);
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
    final PluginBus bus = PluginBus(
      configFile: configFile,
      heartbeatInterval: const Duration(seconds: 30),
    );
    await bus.start();
    final CoreServer server = await CoreServer.start(
      pluginBus: bus,
      builtinPlugins: builtins ?? catalog(),
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    return (server: server, client: _Client(server), bus: bus);
  }

  /// 落盘清单（直接读 yaml，避免依赖被测代码）。
  List<Map<String, dynamic>> diskPlugins() {
    final Map<String, dynamic> doc = YamlCodec.decode(
      File(configFile).readAsStringSync(),
    );
    final Object? raw = doc['plugins'];
    return <Map<String, dynamic>>[
      if (raw is List)
        for (final Object? item in raw)
          if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Map<String, dynamic> diskEntry(String id) => diskPlugins().firstWhere(
    (Map<String, dynamic> e) => e['id'] == id,
    orElse: () => <String, dynamic>{},
  );

  test('核心启动即接线 agent 工具调用事件（Q8：轮次上限交给插件）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    expect(
      ctx.server.conversation.agentEvents.enabled,
      isTrue,
      reason: '未接线的话示例插件收不到 agent.tool_call，也就无法用 agent.stop 兜轮次',
    );
  });

  test('GET /api/plugin/configs：持久态清单 + 运行态 + 真实路径', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          <String>[
            'enabled: true',
            'plugins:',
            ...fakePluginYaml('sample'),
            '',
          ].join('\n'),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    expect(ctx.bus.instances(), hasLength(1), reason: '启动时拉起假插件');

    final _Res res = await ctx.client.send('GET', '/api/plugin/configs');
    expect(res.status, 200);
    expect(res.json['path'], contains('plugins.yaml'));
    expect(res.json['enabled'], isTrue);
    final List<dynamic> configs = res.json['configs'] as List<dynamic>;
    expect(configs, hasLength(1), reason: '数据源是磁盘，不是总线内存');
    expect((configs.single as Map<String, dynamic>)['id'], 'sample');
    final Map<String, dynamic> runtime =
        res.json['runtime'] as Map<String, dynamic>;
    // 这一条是总线启动时读到的（known=true），运行态由总线探针给
    expect((runtime['sample'] as Map<String, dynamic>)['known'], isTrue);
    expect((runtime['sample'] as Map<String, dynamic>)['running'], isTrue);
  });

  test('POST /api/plugin/configs：写盘成功 + 热应用失败如实回报（新增条目）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{
        'id': 'demo',
        'name': '演示',
        'command': 'python',
        'args': <String>['demo.py'],
        'env': <String, String>{'A': '1'},
        'granularity': 'session',
        'scope': <String, dynamic>{'team_id': '', 'session_id': 's1'},
      },
    );
    expect(res.status, 200);
    expect(res.json['ok'], isTrue);
    expect(res.json['hot_applied'], isFalse, reason: '新增条目总线运行期不认识');
    expect(res.json['notice'], '配置已保存，但本次热应用失败，重启核心后生效');
    expect(res.json['hot_apply_detail'], contains('新增条目'));
    // 落盘形状（含规范化后的键）
    final Map<String, dynamic> entry = diskEntry('demo');
    expect(entry['enabled'], isTrue);
    expect(entry['args'], <String>['demo.py']);
    expect(entry['env'], <String, String>{'A': '1'});
    expect(entry['granularity'], 'session');
    expect(entry['scope'], <String, dynamic>{
      'team_id': '',
      'session_id': 's1',
    });
  });

  test('POST 校验：唯一性 / 必填 / 白名单都给可读 400，且不落盘', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins:\n  - id: demo\n    command: python\n',
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final _Res dup = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{'id': 'demo', 'command': 'python3'},
    );
    expect(dup.status, 400);
    expect(dup.detail, contains('已存在'));

    final _Res blank = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{'id': 'x', 'command': '  '},
    );
    expect(blank.status, 400);
    expect(blank.detail, contains('command 不能为空'));

    final _Res scope = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{
        'id': 'x',
        'command': 'python',
        'scope': <String, dynamic>{'team': 't1'},
      },
    );
    expect(scope.status, 400);
    expect(scope.detail, contains('未知键'));

    final _Res granularity = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{
        'id': 'x',
        'command': 'python',
        'granularity': 'global',
      },
    );
    expect(granularity.status, 400);
    expect(granularity.detail, contains('granularity'));

    expect(diskPlugins(), hasLength(1), reason: '被拒的请求一律不落盘');
    expect(diskEntry('demo')['command'], 'python');
  });

  test('PATCH / DELETE：改开关与删除都写盘；不存在 404', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          <String>[
            'enabled: true',
            'plugins:',
            ...fakePluginYaml('sample'),
            '',
          ].join('\n'),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final _Res off = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/sample',
      body: <String, dynamic>{'enabled': false},
    );
    expect(off.status, 200);
    expect(diskEntry('sample')['enabled'], isFalse);
    expect(diskPlugins(), hasLength(1), reason: '停用 = 条目保留');
    // 总线内存里这一条是 enabled:true 且在跑：没有单插件断开入口 ⇒ 如实回报失败
    expect(off.json['hot_applied'], isFalse);
    expect(off.json['hot_apply_detail'], contains('无法只停它一个'));
    expect(off.json['notice'], '配置已保存，但本次热应用失败，重启核心后生效');

    final _Res missing = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/nope',
      body: <String, dynamic>{'enabled': true},
    );
    expect(missing.status, 404);
    expect(missing.detail, contains('不存在'));

    final _Res removed = await ctx.client.send(
      'DELETE',
      '/api/plugin/configs/sample',
    );
    expect(removed.status, 200);
    expect(diskPlugins(), isEmpty);
    expect(
      (await ctx.client.send('DELETE', '/api/plugin/configs/sample')).status,
      404,
    );
  });

  test('PATCH 开关：新条目的停用无需断开（热应用成功）；重启未知条目 400', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{'id': 'demo', 'command': 'python'},
    );
    final _Res off = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/demo',
      body: <String, dynamic>{'enabled': false},
    );
    expect(off.status, 200);
    expect(off.json['hot_applied'], isTrue, reason: '本来就没跑起来，无需断开');
    expect(off.json['hot_apply_detail'], contains('未在运行'));

    final _Res restart = await ctx.client.send(
      'POST',
      '/api/plugin/configs/demo/restart',
    );
    expect(restart.status, 400);
    expect(restart.detail, contains('不在本次核心启动时读取的配置里'));
  });

  test('POST …/restart：总线认识的条目会被真正重启（心跳 degraded 的恢复入口）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          <String>[
            'enabled: true',
            'plugins:',
            ...fakePluginYaml('sample'),
            '',
          ].join('\n'),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    expect(ctx.bus.instances(), hasLength(1), reason: '启动时已拉起假插件');

    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/configs/sample/restart',
    );
    expect(res.status, 200, reason: res.detail);
    expect(res.json['running'], isTrue);
    expect(ctx.bus.instances(), hasLength(1));

    expect(
      (await ctx.client.send(
        'POST',
        '/api/plugin/configs/nope/restart',
      )).status,
      404,
    );
  });

  test('内置插件：清单常驻 + enable 写带 builtin 标记的配置 + disable 保留条目', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });

    final _Res list = await ctx.client.send('GET', '/api/plugin/builtins');
    expect(list.status, 200);
    final List<dynamic> builtins = list.json['builtins'] as List<dynamic>;
    expect(builtins, isNotEmpty, reason: '静态清单至少一项（sample）');
    final Map<String, dynamic> sample = builtins
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> e) => e['id'] == 'sample');
    expect(sample['name'], isNotEmpty);
    expect(sample['description'], isNotEmpty);
    expect(sample['enabled'], isFalse, reason: '未启用也必须在清单里可见');
    expect(
      (sample['resolution'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '注入的探测器把 python 判为可用',
    );

    final _Res on = await ctx.client.send(
      'POST',
      '/api/plugin/builtins/sample/enable',
    );
    expect(on.status, 200, reason: on.detail);
    expect(on.json['hot_applied'], isFalse);
    expect(on.json['notice'], '配置已保存，但本次热应用失败，重启核心后生效');
    final Map<String, dynamic> entry = diskEntry('sample');
    expect(entry['builtin'], isTrue, reason: 'UI 靠它把这一条分到「内置」组');
    expect(entry['command'], 'python');
    expect(entry['args'], <String>[p.join(pluginDir, 'sample_plugin.py')]);
    expect(entry['enabled'], isTrue);

    final _Res afterEnable = await ctx.client.send(
      'GET',
      '/api/plugin/builtins',
    );
    final Map<String, dynamic> enabledSample =
        (afterEnable.json['builtins'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((Map<String, dynamic> e) => e['id'] == 'sample');
    expect(enabledSample['enabled'], isTrue);
    expect(enabledSample['configured'], isTrue);

    final _Res off = await ctx.client.send(
      'POST',
      '/api/plugin/builtins/sample/disable',
    );
    expect(off.status, 200, reason: off.detail);
    expect(diskEntry('sample')['enabled'], isFalse);
    expect(diskPlugins(), hasLength(1), reason: '停用 = 条目保留（面板显示已停用）');

    expect(
      (await ctx.client.send(
        'POST',
        '/api/plugin/builtins/unknown/enable',
      )).status,
      404,
    );
  });

  test('内置插件 id 被保护：新增同 id 与删除内置条目都被可读拒绝', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res create = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{'id': 'sample', 'command': 'python'},
    );
    expect(create.status, 400);
    expect(create.detail, contains('是内置插件'));
    expect(diskPlugins(), isEmpty, reason: '被拒的请求不落盘');

    // 打开内置插件后：删除被拒（只给停用），条目必须保留
    expect(
      (await ctx.client.send(
        'POST',
        '/api/plugin/builtins/sample/enable',
      )).status,
      200,
    );
    final _Res remove = await ctx.client.send(
      'DELETE',
      '/api/plugin/configs/sample',
    );
    expect(remove.status, 400);
    expect(remove.detail, contains('不提供删除'));
    expect(diskPlugins(), hasLength(1), reason: '条目仍然在');
  });

  test('内置插件：运行时缺失 / 脚本缺失都给可读 400（不静默、不落盘）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) noPython =
        await serve(
          'enabled: true\nplugins: []\n',
          builtins: catalog(python: false),
        );
    addTearDown(() async {
      noPython.client.close();
      await noPython.server.close();
    });
    final _Res runtime = await noPython.client.send(
      'POST',
      '/api/plugin/builtins/sample/enable',
    );
    expect(runtime.status, 400);
    expect(runtime.detail, contains('未检测到 Python'));

    final ({CoreServer server, _Client client, PluginBus bus}) noScript =
        await serve(
          'enabled: true\nplugins: []\n',
          builtins: catalog(roots: p.join(temp.path, 'empty')),
        );
    addTearDown(() async {
      noScript.client.close();
      await noScript.server.close();
    });
    final _Res script = await noScript.client.send(
      'POST',
      '/api/plugin/builtins/sample/enable',
    );
    expect(script.status, 400);
    expect(script.detail, contains('找不到内置插件脚本'));
    expect(diskPlugins(), isEmpty, reason: '解析失败不落盘');
  });

  test('未接入插件总线：插件管理端点 503 + 可读原因（快照仍 200 空集）', () async {
    final CoreServer bare = await CoreServer.start(
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    final _Client client = _Client(bare);
    addTearDown(() async {
      client.close();
      await bare.close();
    });
    final _Res res = await client.send('GET', '/api/plugin/configs');
    expect(res.status, 503);
    expect(res.detail, contains('插件总线尚未接入核心'));
    expect((await client.send('GET', '/api/plugin/snapshot')).status, 200);
  });
}
