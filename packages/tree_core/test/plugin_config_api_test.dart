// 插件清单 REST 面（M9 §4.2）的用例：CRUD + 每项开关 + 内置插件开关 + 热应用回报。
//
// 锁住的口径：
// 1. 读写的是**磁盘上的 plugins.yaml**（持久态），不是插件总线内存里的那一份；
// 2. 校验失败 = 400 + 可读中文原因，且**不落盘**（唯一性、不存在、类型 / 白名单）；
// 3. 热应用**立刻生效**：插件总线按磁盘配置对账（PluginBus.applyConfigs），所以
//    "新增 / 启用 / 停用 / 删除"都得到 hot_applied=true；只有**这个插件这次没起来**
//    （命令不存在等）才回 hot_applied=false +
//    「配置已保存，但本次热应用失败，重启核心后生效」+ 可读原因——不许假装成功。
// 4. 内置插件：清单常驻（未启用也可见）、enable 写一条带 builtin 标记的普通配置、
//    disable 把条目置 enabled:false 但**保留条目**；运行时 / 脚本缺失给可读错误。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
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

/// 假的**发布仓库**（不发网络）：形状与 GitHub Releases API 一致。
///
/// 为什么整条链要能离线跑（用户 2026-10-16：「plugins 里是插件代码，插件管理只拉
/// release」）：真正难钉的是“索引是不是那张合同”“字节数不符就不能缓存”“旧文件在
/// 闸门没开时一字未动”，这些都不需要网络。
class _Repo {
  final Map<String, List<int>> assets = <String, List<int>>{};
  Map<String, dynamic>? release;
  final List<String> urls = <String>[];

  Future<PluginFetchResult> fetch(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    urls.add(url.toString());
    if (url.path.endsWith('/releases/latest')) {
      final Map<String, dynamic>? meta = release;
      if (meta == null) {
        return PluginFetchResult(statusCode: 404, error: 'HTTP 404');
      }
      return PluginFetchResult(
        statusCode: 200,
        bytes: utf8.encode(jsonEncode(meta)),
      );
    }
    final String name = Uri.decodeComponent(url.pathSegments.last);
    final List<int>? bytes = assets[name];
    if (bytes == null) {
      return PluginFetchResult(statusCode: 404, error: 'HTTP 404');
    }
    return PluginFetchResult(statusCode: 200, bytes: bytes);
  }

  /// 把索引与已在 [assets] 里的每个文件一起挂成这一版 release 的资产。
  void publish({
    String tag = 'v0.1.0',
    required List<Map<String, dynamic>> plugins,
  }) {
    assets[kPluginIndexAsset] = utf8.encode(
      jsonEncode(<String, dynamic>{
        'schema': kPluginIndexSchema,
        'plugins': plugins,
      }),
    );
    release = <String, dynamic>{
      'tag_name': tag,
      'assets': <Map<String, dynamic>>[
        for (final MapEntry<String, List<int>> e in assets.entries)
          <String, dynamic>{
            'name': e.key,
            'size': e.value.length,
            'browser_download_url': 'https://downloads.example/${e.key}',
          },
      ],
    };
  }
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
    // 内置插件的随包产物：内容无关紧要（用例只解析路径，不真跑那个假 exe）
    File(p.join(pluginDir, 'tree_sample.exe')).writeAsStringSync('placeholder');
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

  /// 假的内置插件目录：产物目录指向临时 plugins/（里面那条 tree_sample.exe 是夹具写的）。
  ///
  /// [probe] 装一个会记录调用的探测器：用来证明 **binary 型根本不该跑探测**。
  BuiltinPluginCatalog catalog({
    bool python = true,
    String? roots,
    void Function(String command)? probe,
  }) => BuiltinPluginCatalog(
    scriptRoots: <String>[roots ?? pluginDir],
    probe: (String command, List<String> args) async {
      probe?.call(command);
      return python && command == 'python';
    },
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
  ///
  /// [downloader] = 接上发布仓库（阶段 5）；不传 ⇒ 三个 release 路由回可读 503。
  Future<({CoreServer server, _Client client, PluginBus bus})> serve(
    String content, {
    BuiltinPluginCatalog? builtins,
    PluginDownloader? downloader,
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
      pluginDownloader: downloader,
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

  test('POST /api/plugin/configs：写盘成功 + 新增条目**立刻热启动**', () async {
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
        'command': Platform.resolvedExecutable,
        'args': <String>[script],
        'env': <String, String>{'A': '1'},
        'granularity': 'session',
        'scope': <String, dynamic>{'team_id': '', 'session_id': 's1'},
      },
    );
    expect(res.status, 200);
    expect(res.json['ok'], isTrue);
    expect(res.json['hot_applied'], isTrue, reason: '对账后新增条目会被真正拉起来');
    expect(res.json['notice'], '', reason: '真的生效了就不该说"重启后生效"');
    expect(res.json['hot_apply_detail'], contains('启动'));
    expect(
      ctx.bus.instances().map((i) => i.pluginId),
      contains('demo'),
      reason: '实例真的在跑（不是只写了个盘）',
    );
    // 落盘形状（含规范化后的键）
    final Map<String, dynamic> entry = diskEntry('demo');
    expect(entry['enabled'], isTrue);
    expect(entry['args'], <String>[script]);
    expect(entry['env'], <String, String>{'A': '1'});
    expect(entry['granularity'], 'session');
    expect(entry['scope'], <String, dynamic>{
      'team_id': '',
      'session_id': 's1',
    });
  });

  test('POST：命令不存在 ⇒ hot_applied=false + 具体原因（不假成功），且不牵连同级', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          <String>[
            'enabled: true',
            'plugins:',
            ...fakePluginYaml('good'),
            '',
          ].join('\n'),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    expect(ctx.bus.instances(), hasLength(1), reason: '启动时已拉起好的那一个');

    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{
        'id': 'broken',
        'command': 'definitely-not-an-executable-xyz',
      },
    );
    expect(res.status, 200, reason: '配置**已经写盘**，所以不是 4xx');
    expect(res.json['hot_applied'], isFalse, reason: '起不来就必须如实说没生效');
    expect(res.json['notice'], '配置已保存，但本次热应用失败，重启核心后生效');
    expect(res.json['hot_apply_detail'], contains('未能就绪'));
    expect(ctx.bus.instances().map((i) => i.pluginId), <String>[
      'good',
    ], reason: '一个插件起不来不影响另一个（失败隔离）');
    expect(ctx.bus.toolsOf('good'), isNotEmpty, reason: '好的插件照常注册工具');
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

    expect(ctx.bus.instances(), hasLength(1), reason: '启动时已拉起假插件');

    // 停用：写盘 **并且真的断开**（条目保留，面板显示"已停用"）
    final _Res off = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/sample',
      body: <String, dynamic>{'enabled': false},
    );
    expect(off.status, 200);
    expect(diskEntry('sample')['enabled'], isFalse);
    expect(diskPlugins(), hasLength(1), reason: '停用 = 条目保留');
    expect(off.json['hot_applied'], isTrue, reason: '停用现在会真的断开实例');
    expect(off.json['hot_apply_detail'], contains('条目已停用'));
    expect(off.json['notice'], '');
    expect(ctx.bus.instances(), isEmpty, reason: '实例列表里不再有它');
    expect(ctx.bus.toolsOf('sample'), isEmpty, reason: '工具定义一并注销');

    // 再打开：同一条目立刻恢复（新进程）
    final _Res on = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/sample',
      body: <String, dynamic>{'enabled': true},
    );
    expect(on.status, 200);
    expect(on.json['hot_applied'], isTrue);
    expect(diskEntry('sample')['enabled'], isTrue);
    expect(ctx.bus.instances(), hasLength(1), reason: '打开 = 立刻回来');

    final _Res missing = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/nope',
      body: <String, dynamic>{'enabled': true},
    );
    expect(missing.status, 404);
    expect(missing.detail, contains('不存在'));

    // 删除：写盘 + 断开并忘掉（实例与配置都不该留下）
    final _Res removed = await ctx.client.send(
      'DELETE',
      '/api/plugin/configs/sample',
    );
    expect(removed.status, 200);
    expect(removed.json['hot_applied'], isTrue, reason: '删除要真的断开');
    expect(removed.json['hot_apply_detail'], contains('已删除'));
    expect(diskPlugins(), isEmpty);
    expect(ctx.bus.instances(), isEmpty);
    expect(ctx.bus.config('sample'), isNull);
    expect(
      (await ctx.client.send('DELETE', '/api/plugin/configs/sample')).status,
      404,
    );
  });

  test('PATCH 开关：没在跑的条目停用无需断开；restart 按磁盘配置重来', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    // 一个必然起不来的条目（命令不存在）：POST 那一刻就如实回报过失败
    final _Res created = await ctx.client.send(
      'POST',
      '/api/plugin/configs',
      body: <String, dynamic>{
        'id': 'demo',
        'command': 'definitely-not-an-executable-xyz',
      },
    );
    expect(created.json['hot_applied'], isFalse);
    expect(ctx.bus.instances(), isEmpty, reason: '没起来就是没起来');

    final _Res off = await ctx.client.send(
      'PATCH',
      '/api/plugin/configs/demo',
      body: <String, dynamic>{'enabled': false},
    );
    expect(off.status, 200);
    expect(off.json['hot_applied'], isTrue, reason: '本来就没跑起来，无需断开');
    expect(off.json['hot_apply_detail'], contains('条目已停用'));
    expect(off.json['notice'], '');

    // restart 不再要求"核心启动时读到过这一条"：它按磁盘上的配置重新拉起，
    // 起不来就回可读原因（命令不存在这种错误不该被吞成一句"重启后未就绪"）
    final _Res restart = await ctx.client.send(
      'POST',
      '/api/plugin/configs/demo/restart',
    );
    expect(restart.status, 400);
    expect(restart.detail, contains('重启失败'));
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

  test('POST …/restart：核心启动后手工加进 plugins.yaml 的条目也能被拉起来', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    // 用户直接手改文件（不经过任何 REST 写接口）：总线运行期还没对过账
    File(configFile).writeAsStringSync(
      <String>[
        'enabled: true',
        'plugins:',
        ...fakePluginYaml('manual'),
        '',
      ].join('\n'),
    );
    expect(ctx.bus.config('manual'), isNull, reason: '还没对账，总线不认识它');

    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/configs/manual/restart',
    );
    expect(res.status, 200, reason: res.detail);
    expect(res.json['running'], isTrue);
    expect(
      ctx.bus.instances().map((i) => i.pluginId),
      contains('manual'),
      reason: 'restart 会先按磁盘对一次账，而不是误报"要重启核心"',
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
      reason: '夹具的 plugins/ 里就放着那条 tree_sample.exe（binary 型只看产物在不在）',
    );

    final _Res on = await ctx.client.send(
      'POST',
      '/api/plugin/builtins/sample/enable',
    );
    expect(on.status, 200, reason: on.detail);
    // 这个内置条目的命令是夹具里那个**占位文件**（名字对、内容不是真 exe）：握手必然失败。
    // 用例在这里锁的是"回报自洽"——真起来了就必须 hot_applied=true，没起来就必须带
    // 「重启核心后生效」+ 可读原因，不许含糊。
    final bool hot = on.json['hot_applied'] as bool;
    expect(hot, isFalse, reason: '占位文件不是真产物，起不来');
    expect(on.json['notice'], hot ? '' : '配置已保存，但本次热应用失败，重启核心后生效');
    expect(on.json['hot_apply_detail'], isNotEmpty);
    final Map<String, dynamic> entry = diskEntry('sample');
    expect(entry['builtin'], isTrue, reason: 'UI 靠它把这一条分到「内置」组');
    // 换代后的命令就是那个二进制本身：**不再有解释器**，也**不该多一个空参**。
    expect(entry['command'], p.join(pluginDir, 'tree_sample.exe'));
    expect(entry['args'], isEmpty);
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

  test('内置插件：产物缺失给可读 400；binary 型根本不跑解释器探测', () async {
    // ① binary 型不探测运行时：开机多起两个进程去问 python 在不在，对一条
    //    `tree_sample.exe` 没有任何意义（而“探测”这件事以前是每个内置项都要跑一遍的）。
    final List<String> probed = <String>[];
    final ({CoreServer server, _Client client, PluginBus bus}) withBinary =
        await serve(
          'enabled: true\nplugins: []\n',
          builtins: catalog(probe: probed.add),
        );
    addTearDown(() async {
      withBinary.client.close();
      await withBinary.server.close();
    });
    final _Res ok = await withBinary.client.send(
      'POST',
      '/api/plugin/builtins/sample/enable',
    );
    expect(ok.status, 200, reason: ok.detail);
    expect(probed, isEmpty, reason: 'binary 型不得碰解释器探测器：一次都不行');

    // ② 产物不在 ⇒ 400 + 可读原因 + 不落盘（静默失败在界面上就是“点了开关没反应”）。
    final ({CoreServer server, _Client client, PluginBus bus}) noBinary =
        await serve(
          'enabled: true\nplugins: []\n',
          builtins: catalog(roots: p.join(temp.path, 'empty')),
        );
    addTearDown(() async {
      noBinary.client.close();
      await noBinary.server.close();
    });
    final _Res script = await noBinary.client.send(
      'POST',
      '/api/plugin/builtins/sample/enable',
    );
    expect(script.status, 400);
    expect(script.detail, contains('找不到内置插件可执行文件'));
    expect(script.detail, contains('tree_sample.exe'));
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

  // ── 发布仓库的三个路由（阶段 5：只拉 GitHub Release 资产）──────────────

  /// 一条脚本型索引条目（资产 = 那个**真能跑**的假插件源码）。
  Map<String, dynamic> releaseEntry({
    String id = 'released',
    String version = '1.2.0',
    String target = 'fake_plugin.dart',
  }) => <String, dynamic>{
    'id': id,
    'name': '发布版假插件',
    'version': version,
    'runtime': 'python',
    'command': target,
    'files': <Map<String, dynamic>>[
      <String, dynamic>{'asset': target, 'target': target},
    ],
    'suspension': PluginSuspension.keep,
    'granularity': 'team',
    'scope': <String, dynamic>{},
  };

  /// 指向临时目录的下载器（安装目标 = 临时 plugins/，与内置项查找路径同源）。
  PluginDownloader releaseDownloader(_Repo repo) => PluginDownloader(
    cacheDir: p.join(temp.path, 'plugins_release'),
    installDir: pluginDir,
    fetcher: repo.fetch,
    nonce: () => 'api',
    // 脚本型的解释器：用真 dart 可执行文件扮 python（资产内容是那个假插件源码）
    runtimeResolver: () async => BuiltinRuntime(Platform.resolvedExecutable),
  );

  test('没接下载器：三个 release 路由都回 503 + 可读原因（不默默空转）', () async {
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve('enabled: true\nplugins: []\n');
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res list = await ctx.client.send('GET', '/api/plugin/release');
    expect(list.status, 503);
    expect(list.detail, contains('没接发布仓库下载器'));
    expect(
      (await ctx.client.send('POST', '/api/plugin/release/refresh')).status,
      503,
    );
    final _Res install = await ctx.client.send(
      'POST',
      '/api/plugin/release/released/install',
    );
    expect(install.status, 503);
  });

  test('GET /api/plugin/release：只读本地缓存 ⇒ 一个 URL 都不碰', () async {
    final _Repo repo = _Repo();
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res res = await ctx.client.send('GET', '/api/plugin/release');
    expect(res.status, 200, reason: '读列表不是网络动作 ⇒ 不因“没缓存”而 4xx');
    expect(res.json['ok'], isFalse);
    expect(res.json['error'], contains('请先点「刷新」'));
    expect(
      (res.json['index_path'] ?? '').toString(),
      contains(kPluginIndexAsset),
    );
    expect(repo.urls, isEmpty, reason: '面板打开不该自己去联网');
  });

  test('POST /api/plugin/release/refresh：拉索引 + 缓存落盘，下一次 GET 读的就是这份', () async {
    final _Repo repo = _Repo();
    repo.assets['fake_plugin.dart'] = File(script).readAsBytesSync();
    repo.publish(plugins: <Map<String, dynamic>>[releaseEntry()]);
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res refreshed = await ctx.client.send(
      'POST',
      '/api/plugin/release/refresh',
    );
    expect(refreshed.status, 200);
    expect(refreshed.json['ok'], isTrue, reason: refreshed.json['error']);
    expect(refreshed.json['online'], isTrue);
    expect(refreshed.json['tag'], 'v0.1.0');
    expect(refreshed.json['entries'], hasLength(1));
    expect(
      File(p.join(temp.path, 'plugins_release', kPluginIndexAsset))
          .existsSync(),
      isTrue,
    );
    repo.urls.clear();
    final _Res cached = await ctx.client.send('GET', '/api/plugin/release');
    expect(cached.json['ok'], isTrue);
    expect(cached.json['online'], isFalse, reason: '离线不许看起来像最新');
    expect(cached.json['entries'], hasLength(1));
    expect(repo.urls, isEmpty);
  });

  test('refresh 失败：200 + ok:false + 原因 + 缓存那一份（不把限流显示成“仓库没插件”）', () async {
    final _Repo repo = _Repo();
    repo.assets['fake_plugin.dart'] = File(script).readAsBytesSync();
    repo.publish(plugins: <Map<String, dynamic>>[releaseEntry()]);
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    // 先刷成功一次（让缓存里有一份），再把仓库抹成“没有 release”
    expect(
      (await ctx.client.send('POST', '/api/plugin/release/refresh')).status,
      200,
    );
    repo.release = null;
    final _Res failed = await ctx.client.send(
      'POST',
      '/api/plugin/release/refresh',
    );
    expect(failed.status, 200, reason: '失败仍然要把列表递到面板上');
    expect(failed.json['ok'], isFalse);
    expect(failed.json['error'], contains('还没有 release'));
    final Map<String, dynamic> cached =
        failed.json['cached'] as Map<String, dynamic>;
    expect(cached['ok'], isTrue, reason: '上一次那份还能装就要递出去');
    expect(cached['online'], isFalse);
    expect(cached['entries'], hasLength(1));
  });

  test('POST …/install：放置文件 + 写条目（带来源标记）+ 立刻热应用', () async {
    final _Repo repo = _Repo();
    final List<int> source = File(script).readAsBytesSync();
    repo.assets['fake_plugin.dart'] = source;
    repo.publish(plugins: <Map<String, dynamic>>[releaseEntry()]);
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/release/released/install',
    );
    expect(res.status, 200, reason: res.detail);
    expect((res.json['install'] as Map<String, dynamic>)['swapped'], isTrue);
    expect(
      File(p.join(pluginDir, 'fake_plugin.dart')).readAsBytesSync(),
      source,
      reason: '文件要真落到可执行文件同级的那个 plugins/',
    );
    final Map<String, dynamic> entry = diskEntry('released');
    expect(entry['source'], kRepoSourceValue);
    expect(entry['repo_version'], '1.2.0');
    expect(entry['command'], Platform.resolvedExecutable);
    expect(entry['args'], <String>[p.join(pluginDir, 'fake_plugin.dart')]);
    expect(entry['suspension'], PluginSuspension.keep);
    expect(res.json['hot_applied'], isTrue, reason: '装上的东西该立刻被拉起来');
    expect(ctx.bus.config('released'), isNotNull);
    expect(ctx.bus.instances(), hasLength(1));
  });

  test('install 先过闸门：正在跑的旧一世被**优雅停掉**，才换文件再拉新一世', () async {
    final _Repo repo = _Repo();
    final List<int> source = File(script).readAsBytesSync();
    repo.assets['fake_plugin.dart'] = <int>[
      ...source,
      ...utf8.encode('\n// 这一版发布里多的一行\n'),
    ];
    repo.publish(plugins: <Map<String, dynamic>>[releaseEntry()]);
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          <String>[
            'enabled: true',
            'plugins:',
            ...fakePluginYaml('released'),
            '',
          ].join('\n'),
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    expect(ctx.bus.instances(), hasLength(1), reason: '旧的那一世在跑');
    final int before = ctx.bus.generationOf('released');

    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/release/released/install',
    );
    expect(res.status, 200, reason: res.detail);
    expect(
      res.json['hot_applied'],
      isTrue,
      reason: res.json['hot_apply_detail'],
    );
    expect(
      ctx.bus.generationOf('released'),
      greaterThan(before),
      reason: '闸门开过（旧进程已确认退出）才换的文件，换完重新拉起一世',
    );
    expect(
      File(p.join(pluginDir, 'fake_plugin.dart')).readAsBytesSync(),
      isNot(source),
      reason: '旧文件已被新版覆盖',
    );
  });

  test('install 不给盖内置 id（就算还没落盘）：400 + 原因，文件与条目都不动', () async {
    final _Repo repo = _Repo();
    repo.assets['fake_plugin.dart'] = File(script).readAsBytesSync();
    repo.publish(plugins: <Map<String, dynamic>>[releaseEntry(id: 'sample')]);
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/release/sample/install',
    );
    expect(res.status, 400);
    expect(res.detail, contains('已由核心内置提供'));
    expect(
      File(p.join(pluginDir, 'fake_plugin.dart')).existsSync(),
      isFalse,
      reason: '拒绝发生在任何磁盘动作之前',
    );
    expect(diskPlugins(), isEmpty);
  });

  test('索引想把 plugins/ 里的内置成品盖掉 ⇒ 列表当场跳过，install 拿不到这一条', () async {
    // 与上一条不同的防线：上一条管“id 撞内置”，这一条管“**文件名**撞内置”。
    // plugins/ 里放的是插件源码与随包成品，两者靠文件名区分 ⇒ 发布仓库只能装自己的成品。
    final _Repo repo = _Repo();
    // 受保护名按**本机口径**算（下载器读的就是这一份集合）：写死一个平台名
    // 就会在另一个平台上假绿。
    final String target = BuiltinPluginCatalog.binaryFileName(
      BuiltinPluginCatalog.specOf(kSamplePluginId)!,
      isWindows: Platform.isWindows,
    );
    repo.assets[target] = File(script).readAsBytesSync();
    repo.publish(
      plugins: <Map<String, dynamic>>[
        releaseEntry(id: 'overwrite', target: target),
      ],
    );
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res refreshed = await ctx.client.send(
      'POST',
      '/api/plugin/release/refresh',
    );
    expect(refreshed.status, 200);
    expect(refreshed.json['ok'], isTrue, reason: '索引本身是合法的');
    expect(refreshed.json['entries'], isEmpty);
    expect(
      (refreshed.json['skipped'] as List<dynamic>).cast<String>().single,
      contains('不盖 plugins/ 里的插件源码'),
      reason: '面板要能直接告诉用户为什么列不出来',
    );
    final _Res install = await ctx.client.send(
      'POST',
      '/api/plugin/release/overwrite/install',
    );
    expect(install.status, 400);
    expect(
      File(p.join(pluginDir, target)).readAsStringSync(),
      'placeholder',
      reason: '随包成品一字未动（被跳过的条目连一个字节都不许写进 plugins/）',
    );
    expect(diskPlugins(), isEmpty);
  });

  test('install 一个索引里没有的 id：400 + 现在能装的是哪几条', () async {
    final _Repo repo = _Repo();
    repo.assets['fake_plugin.dart'] = File(script).readAsBytesSync();
    repo.publish(
      plugins: <Map<String, dynamic>>[
        releaseEntry(),
        releaseEntry(id: 'second'),
      ],
    );
    final ({CoreServer server, _Client client, PluginBus bus}) ctx =
        await serve(
          'enabled: true\nplugins: []\n',
          downloader: releaseDownloader(repo),
        );
    addTearDown(() async {
      ctx.client.close();
      await ctx.server.close();
    });
    final _Res res = await ctx.client.send(
      'POST',
      '/api/plugin/release/ghost/install',
    );
    expect(res.status, 400);
    expect(res.detail, contains('没有插件 ghost'));
    expect(res.detail, contains('released'));
    expect(res.detail, contains('second'));
    expect(diskPlugins(), isEmpty, reason: '没装成就一个字段也不写');
  });
}
