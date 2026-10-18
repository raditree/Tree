// 插件面板（M9 §4.2）的 widget 用例：分组 / 每项开关 / 表单校验 / 保存调用 / 错误展示。
//
// 断言的是"用户在界面上做了什么、面板往核心发了什么"——核心那边的落盘与热应用口径
// 由 packages/tree_core/test/plugin_config_api_test.dart 锁住，这里只管前端。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/plugin_monitor_service.dart';
import 'package:tree/ui/widgets/plugin_panel.dart';

/// 假的管理接口（不发网络请求，只记录调用）。
class _FakeAdmin implements PluginAdminClient {
  _FakeAdmin({Map<String, dynamic>? configs, Map<String, dynamic>? builtins})
    : configsResponse = configs ?? _defaultConfigs(),
      builtinsResponse = builtins ?? _defaultBuiltins();

  /// 调用流水（形如 custom:demo:off / builtin:sample:on / add / delete:demo）。
  final List<String> calls = <String>[];

  Map<String, dynamic> configsResponse;
  Map<String, dynamic> builtinsResponse;

  /// 写操作的统一返回体（用例按需改 notice / hot_apply_detail）。
  Map<String, dynamic> writeResponse = <String, dynamic>{
    'ok': true,
    'hot_applied': false,
    'notice': '',
    'hot_apply_detail': '',
  };

  /// 非空 = 清单接口失败（模拟旧核心没有这些端点）。
  String failConfigs = '';

  /// 非空 = 写操作失败（模拟核心的可读 400）。
  String failWrite = '';

  /// 最近一次新增的请求体（表单解析结果）。
  Map<String, dynamic>? lastCreateBody;

  /// 最近一次站点配置的 PATCH 体（站点详情页的写回）。
  Map<String, dynamic>? lastStationPatch;

  /// 非空 = 站点详情读不到（模拟核心 404 / 旧核心没有这个端点）。
  String failStationRead = '';

  /// 站点详情与写操作的返回体（核心成功时回**改后的完整详情**）。
  Map<String, dynamic> stationResponse = _defaultStation();

  // ── 发布仓库（阶段 5）的假数据 ──────────────────────────────────

  /// 发布清单：默认“本机还没缓存”。B 起面板打开会后台自动拉一次（读与拉分开记：
  /// 读进 [releaseFetches]，拉进 [calls]），这里给的是“拉之前/拉也没拉到”的那份。
  Map<String, dynamic> releaseResponse = <String, dynamic>{
    'ok': false,
    'error': '本机还没有发布索引的缓存：C:/data/plugins_release/plugin-index.json'
        '（请先点「刷新」拉一次最新 release）',
    'entries': <dynamic>[],
    'skipped': <dynamic>[],
    'tag': '',
    'index_path': 'C:/data/plugins_release/plugin-index.json',
    'online': false,
  };

  /// 刷新时的返回体（null = 沿用 [releaseResponse]；用例用它给出“刚拉到的一份清单”）。
  Map<String, dynamic>? refreshResponse;

  /// 刷新没成功时核心附上的“上一次那份”（面板要能列出它，而不是只剩错误）。
  Map<String, dynamic>? refreshCached;

  /// 非空 = fetchRelease / refreshRelease 抛错（模拟核心 503“没接下载器”）。
  String failRelease = '';

  /// 读缓存清单被调了几次。**read 不进 calls**（与 fetchConfigs / fetchBuiltins
  /// 同口径）：否则“面板打开后什么都没点”的用例会被一次读取弄成“已发请求”。
  int releaseFetches = 0;

  /// 装一条的返回体（形状 = 核心 install 的回包：写盘结果 + install 段）。
  Map<String, dynamic> installResponse = <String, dynamic>{
    'ok': true,
    'hot_applied': true,
    'notice': '',
    'hot_apply_detail': '',
    'install': <String, dynamic>{'ok': true, 'plugin_id': 'demo2', 'version': '1.2.0'},
  };

  static Map<String, dynamic> _defaultConfigs() => <String, dynamic>{
    'path': 'C:/data/config/plugins.yaml',
    'enabled': true,
    'configs': <dynamic>[
      <String, dynamic>{
        'id': 'demo',
        'name': '演示插件',
        'command': 'python',
        'args': <String>['demo.py'],
        'enabled': true,
        'granularity': 'team',
        'scope': <String, dynamic>{'team_id': 't1'},
      },
    ],
    'runtime': <String, dynamic>{
      'demo': <String, dynamic>{'running': true, 'health': 'ok', 'known': true},
    },
  };

  static Map<String, dynamic> _defaultBuiltins() => <String, dynamic>{
    'path': 'C:/data/config/plugins.yaml',
    'builtins': <dynamic>[
      <String, dynamic>{
        'id': 'sample',
        'name': '示例插件',
        'description': '核心自带的示例插件（随包二进制）',
        'script': 'tree_sample',
        'runtime': 'binary',
        'granularity': 'team',
        'scope': <String, dynamic>{},
        'enabled': false,
        'configured': true,
        'config': <String, dynamic>{
          'id': 'sample',
          'name': '示例插件',
          'command': 'C:/app/plugins/tree_sample.exe',
          'args': <String>[],
          'enabled': false,
          'granularity': 'team',
          'scope': <String, dynamic>{},
          'builtin': true,
        },
        'resolution': <String, dynamic>{
          'ok': true,
          'command': 'C:/app/plugins/tree_sample.exe',
          'script_path': '',
        },
      },
    ],
  };

  /// 一个典型的**插件自建站**详情（字段形状 = 核心 `StationInstance.describe()`）。
  static Map<String, dynamic> _defaultStation() => <String, dynamic>{
    'station_id': 'plugin.sample.relay.audit',
    'kind': 'relay',
    'kind_label': '中转站',
    'description': '把工具公告按 team 再分发一次',
    'readme': '自建中转站：收到公告后单向改写再投递，白名单内的插件都能触发。',
    'scope': <String, dynamic>{},
    'builtin': false,
    'max_subscriptions': 8,
    'shared': true,
    'allowed_plugins': <String>['demo'],
    'config': <String, dynamic>{'route': 'audit', 'route_limit': 8},
    'subscriber_count': 2,
    'subscriptions': <dynamic>[
      <String, dynamic>{
        'subscriber': 'sample|',
        'plugin_id': 'sample',
        'granularity': 'team',
        'scope': <String, dynamic>{},
        'disabled': false,
      },
      <String, dynamic>{
        'subscriber': 'demo|t1|||local',
        'plugin_id': 'demo',
        'granularity': 'team',
        'scope': <String, dynamic>{'team_id': 't1', 'mode_key': 'local'},
        'disabled': true,
      },
    ],
    'subscribers_by_team': <String, dynamic>{'t1': 1},
    'counts': <String, dynamic>{'requests': 3, 'skipped_disabled': 1},
    'gauges': <String, dynamic>{'waits_in_flight': 0},
  };

  @override
  Future<Map<String, dynamic>> fetchConfigs() async {
    if (failConfigs.isNotEmpty) throw Exception(failConfigs);
    return configsResponse;
  }

  @override
  Future<Map<String, dynamic>> fetchBuiltins({bool refresh = false}) async {
    if (failConfigs.isNotEmpty) throw Exception(failConfigs);
    if (refresh) calls.add('refresh-builtins');
    return builtinsResponse;
  }

  @override
  Future<Map<String, dynamic>> createConfig(Map<String, dynamic> body) async {
    calls.add('add');
    lastCreateBody = body;
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return writeResponse;
  }

  @override
  Future<Map<String, dynamic>> updateConfig(
    String id,
    Map<String, dynamic> patch,
  ) async {
    calls.add('custom:$id:${patch['enabled'] == false ? 'off' : 'edit'}');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return writeResponse;
  }

  @override
  Future<Map<String, dynamic>> deleteConfig(String id) async {
    calls.add('delete:$id');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return writeResponse;
  }

  @override
  Future<Map<String, dynamic>> restartConfig(
    String id, {
    String mode = 'cold',
    bool keepState = true,
  }) async {
    // 记下的 mode 就是本文件那两条新用例的证据面：界面到底把哪三种做法发给了核心。
    calls.add('restart:$id:$mode');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return writeResponse;
  }

  @override
  Future<Map<String, dynamic>> setBuiltinEnabled(
    String id, {
    required bool enabled,
  }) async {
    calls.add('builtin:$id:${enabled ? 'on' : 'off'}');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return writeResponse;
  }

  @override
  Future<Map<String, dynamic>> stationDetail(String stationId) async {
    calls.add('station-detail:$stationId');
    if (failStationRead.isNotEmpty) throw Exception(failStationRead);
    return stationResponse;
  }

  @override
  Future<Map<String, dynamic>> patchStationConfig(
    String stationId,
    Map<String, dynamic> patch,
  ) async {
    calls.add('station-patch:$stationId:${patch.keys.join('+')}');
    lastStationPatch = patch;
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return stationResponse;
  }

  @override
  Future<Map<String, dynamic>> setSubscriberDisabled(
    String stationId,
    String subscriberKey, {
    required bool disabled,
  }) async {
    calls.add(
      'station-sub:$stationId|$subscriberKey|${disabled ? 'off' : 'on'}',
    );
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return stationResponse;
  }

  @override
  Future<Map<String, dynamic>> fetchRelease() async {
    releaseFetches++;
    if (failRelease.isNotEmpty) throw Exception(failRelease);
    return releaseResponse;
  }

  @override
  Future<Map<String, dynamic>> refreshRelease() async {
    calls.add('release:refresh');
    if (failRelease.isNotEmpty) throw Exception(failRelease);
    return <String, dynamic>{
      ...(refreshResponse ?? releaseResponse),
      if (refreshCached != null) 'cached': refreshCached,
    };
  }

  @override
  Future<Map<String, dynamic>> installRelease(String id) async {
    calls.add('release:install:$id');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return installResponse;
  }

  @override
  Future<Map<String, dynamic>> uninstallRelease(String id) async {
    calls.add('release:uninstall:$id');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return <String, dynamic>{'ok': true};
  }
}

/// 注入快照的服务（不共享单例状态）。
Future<PluginMonitorService> _serviceWith([Map<String, dynamic>? data]) async {
  final PluginMonitorService svc = PluginMonitorService.forTesting();
  svc.snapshotFetcher = ({String? teamId}) async =>
      data ??
      <String, dynamic>{
        'enabled': true,
        'instances': <dynamic>[],
        'stations': <dynamic>[],
        'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
      };
  await svc.refresh();
  return svc;
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required PluginMonitorService svc,
  required PluginAdminClient admin,
  Size size = const Size(1000, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: size.height,
          width: size.width,
          child: PluginPanel(service: svc, admin: admin, showHeader: false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 切到指定栏（三栏面板：卡片与区块各归各栏，点之前先让它可见）。
Future<void> _showTab(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

/// 发布索引清单的回包（形状 = 核心 `PluginReleaseListing.toJson()`）。
Map<String, dynamic> _releaseListing({
  bool ok = true,
  String error = '',
  String tag = 'v0.1.0',
  bool online = true,
  List<Map<String, dynamic>> entries = const <Map<String, dynamic>>[],
  List<String> skipped = const <String>[],
}) => <String, dynamic>{
  'ok': ok,
  'error': error,
  'tag': tag,
  'online': online,
  'index_path': 'C:/data/plugins_release/plugin-index.json',
  'count': entries.length,
  'entries': entries,
  'skipped': skipped,
};

/// 一条索引条目（关键键与核心 `PluginRepoEntry.toJson()` 一致）。
Map<String, dynamic> _releaseEntry({
  String id = 'demo2',
  String name = '发布版演示插件',
  String version = '1.2.0',
  String installed = '',
  bool hasUpdate = true,
}) => <String, dynamic>{
  'plugin_id': id,
  'name': name,
  'version': version,
  'installed_version': installed,
  'has_update': hasUpdate,
  'runtime': 'binary',
};

void main() {
  testWidgets('插件实例分「内置 / 自定义」两组，每一项各有自己的开关', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    expect(find.text('插件实例（2）'), findsOneWidget);
    expect(find.text('内置插件（1）'), findsOneWidget);
    expect(find.text('自定义插件（1）'), findsOneWidget);
    expect(find.text('示例插件'), findsOneWidget);
    expect(find.text('演示插件'), findsOneWidget);
    // 每一项一个开关（不是统一开关）
    final Finder builtinSwitch = find.byKey(
      const Key('plugin-switch-builtin-sample'),
    );
    final Finder customSwitch = find.byKey(
      const Key('plugin-switch-custom-demo'),
    );
    expect(builtinSwitch, findsOneWidget);
    expect(customSwitch, findsOneWidget);
    expect(
      tester.widget<Switch>(builtinSwitch).value,
      isFalse,
      reason: '内置项未启用',
    );
    expect(tester.widget<Switch>(customSwitch).value, isTrue);
    // 内置项不给删除，只给停用（开关）+ 编辑
    expect(find.byKey(const Key('plugin-delete-sample')), findsNothing);
    expect(find.textContaining('内置插件不可删除'), findsOneWidget);
    // 自定义项有 编辑 / 删除 / 重启
    expect(find.byKey(const Key('plugin-edit-demo')), findsOneWidget);
    expect(find.byKey(const Key('plugin-delete-demo')), findsOneWidget);
    expect(find.byKey(const Key('plugin-restart-demo')), findsOneWidget);
    // 阶段 3：热重启（保留状态）与强制停止与「重启」并列，不是替掉它
    expect(find.byKey(const Key('plugin-hot-restart-demo')), findsOneWidget);
    expect(find.byKey(const Key('plugin-force-stop-demo')), findsOneWidget);
    // 清单真实路径与生效方式必须显示
    expect(
      find.textContaining('清单文件：C:/data/config/plugins.yaml'),
      findsOneWidget,
    );
    expect(find.textContaining('保存后立即热应用；热应用失败时重启核心生效'), findsOneWidget);
  });

  testWidgets('热重启把 mode=hot 发给核心，resumed=true 时说清“续到了第几代”', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..writeResponse = <String, dynamic>{
        'ok': true,
        'resumed': true,
        'generation': 3,
      };
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    await tester.tap(find.byKey(const Key('plugin-hot-restart-demo')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('restart:demo:hot'));
    expect(find.textContaining('状态续到了第 3 代'), findsOneWidget);
  });

  testWidgets('热重启遇到 resumed=false ⇒ 说“按冷启动”，不当成功报（那确实没续上）', (WidgetTester tester) async {
    // 单独一个用例而不是同一个里连点两次：SnackBar 是**排队**的，第二句要等第一句
    // 自己消完才出现（而测试里的时长不会自己流逝）—— 这不是被测代码的毛病，
    // 但把它当成“验一验能验两条”的陷阱写在一个用例里，就只能靠 pump 时长去猜。
    final _FakeAdmin admin = _FakeAdmin()
      ..writeResponse = <String, dynamic>{'ok': true, 'resumed': false};
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    await tester.tap(find.byKey(const Key('plugin-hot-restart-demo')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('restart:demo:hot'));
    expect(find.textContaining('按冷启动'), findsOneWidget);
    expect(find.textContaining('状态确实没续上'), findsOneWidget);
    expect(
      find.textContaining('状态续到了'),
      findsNothing,
      reason: '没续上就不许说成续上了（那会把一次冷启动报成好事）',
    );
  });

  testWidgets('强制停止要先确认，确认后才是 mode=force_stop（取消就什么都不发）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..writeResponse = <String, dynamic>{'ok': true, 'killed': 1};
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    await tester.tap(find.byKey(const Key('plugin-force-stop-demo')));
    await tester.pumpAndSettle();
    expect(find.text('强制停止这个插件？'), findsOneWidget);
    // 取消：一个写请求也不该发出去（强杀是唯一能 kill 用户进程的按钮）。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(admin.calls, isNot(contains('restart:demo:force_stop')));

    await tester.tap(find.byKey(const Key('plugin-force-stop-demo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plugin-force-stop-confirm')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('restart:demo:force_stop'));
    expect(find.textContaining('显式 kill'), findsOneWidget);
  });

  testWidgets('内置项解析不到 ⇒ 明说“去从发布仓库更新装它”，而不是只留一行红色的“未就绪”', (WidgetTester tester) async {
    // 2026-10-18：插件成品不再随安装包 ⇒ 新装机上内置项一律解析不到，那是**常态**不是故障。
    // 光有“运行时未就绪：在 … 找不到 tree_sample.exe”会让用户以为装坏了，而他真正需要的
    // 是一句“去下面那一节装它”。原始错误仍然留着（它列了查找路径，是诊断信息）。
    final Map<String, dynamic> missing = _FakeAdmin._defaultBuiltins();
    (
      (missing['builtins'] as List<dynamic>).single as Map<String, dynamic>
    )['resolution'] = <String, dynamic>{
      'ok': false,
      'error': '在 C:/app/plugins 找不到 tree_sample.exe',
    };
    final _FakeAdmin admin = _FakeAdmin(builtins: missing);
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    expect(find.textContaining('运行时未就绪'), findsOneWidget);
    expect(
      find.byKey(const Key('plugin-builtin-needs-repo-sample')),
      findsOneWidget,
      reason: '要指到卡片上那颗「从仓库装它」按钮（A+ 起按钮就地，不用再指到下面那一节）',
    );
    expect(
      (find
              .byKey(const Key('plugin-builtin-needs-repo-sample'))
              .evaluate()
              .single
              .widget
          as Text)
      .data,
      contains('从仓库装它'),
      reason: 'A+ 起指引直接指到卡片上那颗按钮（按钮就在同一张卡上，不再指向下面那一节）',
    );

    // 反过来：成品在（默认夹具 resolution.ok=true）⇒ 不许出现这一行“待装”提示。
    // 写成**另一条** testWidgets 而不是在本条里再 pump 一次：同一个位置的同类 widget
    // 会被复用 State，而面板只在 initState 里拉数据 —— 第二次 pump 看到的还是上面那份
    // “解析不到”的旧状态（实测过一次，断言假红）。
  });

  testWidgets('内置项成品在 ⇒ 不许出现“去仓库装”那一行（也不许染成错误色）', (WidgetTester tester) async {
    final _FakeAdmin shipped = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: shipped);
    await _showTab(tester, 'plugin-tab-installed');
    expect(
      find.byKey(const Key('plugin-builtin-needs-repo-sample')),
      findsNothing,
    );
    expect(find.textContaining('运行时未就绪'), findsNothing);
    // A+：成品在 ⇒ 同一颗按钮换文案（不消失：有更新时它就是更新入口）。
    expect(
      find.text('从仓库更新'),
      findsOneWidget,
      reason: '已装/有更新时按钮显示「从仓库更新」（同一颗按钮两种文案）',
    );
  });

  testWidgets('卡片「从仓库装它」：点它先自动刷新索引再 install，成功后就地清错误', (WidgetTester tester) async {
    // 缺成品（解析不到）+ 索引里**有**这一条 ⇒ 一次点击走完 refresh → install。
    final Map<String, dynamic> missing = _FakeAdmin._defaultBuiltins();
    (
      (missing['builtins'] as List<dynamic>).single as Map<String, dynamic>
    )['resolution'] = <String, dynamic>{
      'ok': false,
      'error': '在 C:/app/plugins 找不到 tree_sample.exe',
    };
    final _FakeAdmin admin = _FakeAdmin(builtins: missing)
      ..refreshResponse = _releaseListing(
        entries: <Map<String, dynamic>>[
          _releaseEntry(id: 'sample', name: '示例插件'),
        ],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    expect(find.text('从仓库装它'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plugin-builtin-repo-sample')));
    await tester.pumpAndSettle();

    expect(admin.calls, contains('release:refresh'), reason: '先刷新索引（用户不该手动先去点刷新）');
    expect(admin.calls, contains('release:install:sample'), reason: '索引里有这一条 ⇒ 接着 install');
    expect(
      admin.calls.indexOf('release:refresh'),
      lessThan(admin.calls.indexOf('release:install:sample')),
      reason: '顺序必须是 refresh → install（装机端要的是最新索引）',
    );
    expect(
      find.text('已从发布仓库安装 sample（1.2.0）'),
      findsOneWidget,
      reason: '装了哪一版要说出来',
    );
    expect(
      find.byKey(const Key('plugin-builtin-repo-error-sample')),
      findsNothing,
      reason: '成功了就不该还挂着错误',
    );
  });

  testWidgets('卡片「从仓库装它」：索引里没有这一条 ⇒ 就地显示原因，不发 install', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(entries: <Map<String, dynamic>>[]);
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    await tester.tap(find.byKey(const Key('plugin-builtin-repo-sample')));
    await tester.pumpAndSettle();

    expect(admin.calls, contains('release:refresh'));
    expect(
      admin.calls,
      isNot(contains('release:install:sample')),
      reason: '索引里没这一条时 install 必然 404，就地说明比发一次注定失败的请求好',
    );
    expect(
      find.byKey(const Key('plugin-builtin-repo-error-sample')),
      findsOneWidget,
      reason: '失败原因就地显示在卡片上（不只是一条转瞬即逝的 snack）',
    );
    expect(
      find.textContaining('索引里没有 sample 这一条'),
      findsOneWidget,
    );
  });

  testWidgets('每项开关各自打各自的接口', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    await tester.tap(find.byKey(const Key('plugin-switch-builtin-sample')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('builtin:sample:on'));

    await tester.tap(find.byKey(const Key('plugin-switch-custom-demo')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('custom:demo:off'));
  });

  testWidgets('热应用失败：面板如实显示核心给的 notice', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..writeResponse = <String, dynamic>{
        'ok': true,
        'hot_applied': false,
        'notice': '配置已保存，但本次热应用失败，重启核心后生效',
        'hot_apply_detail': '该条目不在核心启动时读取的配置里（新增条目）',
      };
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-switch-custom-demo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置已保存，但本次热应用失败，重启核心后生效'), findsOneWidget);
    expect(find.textContaining('新增条目'), findsOneWidget);
  });

  testWidgets('写操作失败：面板显示核心的可读原因', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()..failWrite = '插件 demo 的 command 不能为空';
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-switch-custom-demo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('操作失败：插件 demo 的 command 不能为空'), findsOneWidget);
  });

  testWidgets('添加插件：表单校验 + 二次确认 + 请求体解析', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    await tester.tap(find.byKey(const Key('plugin-add')));
    await tester.pumpAndSettle();
    expect(find.text('添加插件'), findsWidgets);

    // 0) scope 的说明文案必须与核心真实行为一致：
    //    team_id 留空 = **不进站点体系**（旧 tools/list 路径、对所有 team 可见），
    //    而不是"通配到站点里"；mode_key 由核心按目标 agent 工作空间自动解析。
    //    这几句是对用户的口径承诺，措辞漂移会让用户按错的方式配 scope。
    expect(
      find.textContaining('team_id 留空 = 不进站点体系'),
      findsOneWidget,
      reason: '旧的「留空 = 通配；四元组是站点隔离的判据」是错的（站点已全局化）',
    );
    expect(
      find.textContaining('mode_key 现由核心按目标 agent 的工作空间自动解析'),
      findsOneWidget,
    );
    expect(
      find.textContaining('留空 = 通配'),
      findsNothing,
      reason: '这句已不成立，不得回潮',
    );

    // 1) 什么都不填：id / 命令都报可读错误
    await tester.tap(find.byKey(const Key('plugin-editor-save')));
    await tester.pumpAndSettle();
    expect(find.text('请填写插件 id'), findsOneWidget);
    expect(find.text('请填写要拉起的命令'), findsOneWidget);

    // 2) 环境变量格式错误
    await tester.enterText(find.byKey(const Key('plugin-editor-id')), 'mydemo');
    await tester.enterText(
      find.byKey(const Key('plugin-editor-command')),
      'python',
    );
    await tester.enterText(
      find.byKey(const Key('plugin-editor-env')),
      'A=1\nBROKEN',
    );
    await tester.tap(find.byKey(const Key('plugin-editor-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('环境变量必须是 KEY=VALUE'), findsOneWidget);

    // 3) 填齐（参数每行一个 / 环境变量每行一个 / scope 只填 session）→ 保存 → 二次确认
    await tester.enterText(
      find.byKey(const Key('plugin-editor-args')),
      'demo.py\n--flag',
    );
    await tester.enterText(
      find.byKey(const Key('plugin-editor-env')),
      'A=1\nB=x=y',
    );
    await tester.enterText(
      find.byKey(const Key('plugin-editor-session')),
      's1',
    );
    // 介绍（详情页正文的唯一来源）：弹窗里必须能写，否则介绍永远只能改 yaml
    expect(
      find.textContaining('详情页」正文就读这里'),
      findsOneWidget,
      reason: '介绍输入框要写明去处，用户才知道写这儿有什么用',
    );
    await tester.enterText(
      find.byKey(const Key('plugin-editor-desc')),
      '把工具公告转发给队友  ',
    );
    await tester.tap(find.byKey(const Key('plugin-editor-save')));
    await tester.pumpAndSettle();
    expect(find.text('确认保存并尝试启动？'), findsOneWidget);
    expect(
      find.textContaining('可以用界面拉起任意进程'),
      findsWidgets,
      reason: '安全提示必须写明（弹窗内 + 二次确认里各一处）',
    );
    expect(find.textContaining('即将执行：python demo.py --flag'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plugin-editor-confirm')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('add'));
    final Map<String, dynamic> body = admin.lastCreateBody!;
    expect(body['id'], 'mydemo');
    expect(body['command'], 'python');
    expect(body['args'], <String>['demo.py', '--flag']);
    expect(body['env'], <String, String>{'A': '1', 'B': 'x=y'});
    expect(body['description'], '把工具公告转发给队友');
    expect(body['scope'], <String, String>{'session_id': 's1'});
    expect(body['granularity'], 'team');
    expect(body['enabled'], isTrue);
  });

  testWidgets('删除要二次确认，确认后才发请求', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    await tester.tap(find.byKey(const Key('plugin-delete-demo')));
    await tester.pumpAndSettle();
    expect(find.text('删除插件？'), findsOneWidget);
    expect(
      admin.calls.where((String c) => !c.startsWith('release:')),
      isEmpty,
      reason: '确认之前不发写请求（release:refresh 是 B 进页面的后台索引刷新，不算）',
    );

    await tester.tap(find.byKey(const Key('plugin-delete-confirm')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('delete:demo'));
  });

  testWidgets('旧核心（清单接口不可用）：退回只读实例列表并说明原因', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()..failConfigs = '功能开发中';
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[
        <String, dynamic>{
          'plugin_id': 'sample',
          'name': '样例插件',
          'status': 'registered',
          'granularity': 'team',
          'last_heartbeat': 0,
        },
      ],
      'stations': <dynamic>[],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc: svc, admin: admin);
    await _showTab(tester, 'plugin-tab-installed');

    expect(find.textContaining('插件清单接口不可用'), findsOneWidget);
    expect(find.text('插件实例（1）'), findsOneWidget);
    expect(find.text('已注册'), findsOneWidget);
    expect(find.text('样例插件'), findsOneWidget);
  });

  // ── 发布仓库（阶段 5：插件管理只拉 GitHub Release 资产，不拉源码）──────

  testWidgets('发布仓库：进页面先读缓存，再后台自动拉（失败不阻塞、不弹 snack）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    expect(admin.releaseFetches, 1, reason: '打开先读本地缓存：那一刻就有东西可列');
    expect(
      admin.calls,
      contains('release:refresh'),
      reason: 'B 覆盖阶段 5「面板打开不联网」：索引进页面后台自动拉（GET 本身仍只读缓存）',
    );
    expect(find.textContaining('只读 GitHub Release 资产'), findsOneWidget);
    expect(
      find.textContaining('本机还没有发布索引的缓存'),
      findsOneWidget,
      reason: '没缓存也写明原因（后台自动拉失败同样只写这一行，不转全屏圈）',
    );
    expect(
      find.textContaining('本地缓存（还没拉过）'),
      findsOneWidget,
      reason: '自动拉没成功 ⇒ 按缓存那份标清 online:false，不冒充最新',
    );
    expect(
      find.textContaining('刷新失败'),
      findsNothing,
      reason: '后台动作失败不弹 snack 抢注意力（用户手动点「刷新」失败才弹）',
    );
    // 失败不阻塞：其它栏照常可进，内容不等这次网络动作。
    await _showTab(tester, 'plugin-tab-installed');
    expect(find.text('插件实例（2）'), findsOneWidget);
  });

  testWidgets('发布仓库：后台自动拉失败也照列缓存那份（一个按钮都没点）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        ok: false,
        error: '取最新 release 失败：HTTP 403（GitHub API 限流）',
        tag: '',
      )
      ..refreshCached = _releaseListing(
        online: false,
        tag: 'v0.0.9',
        entries: <Map<String, dynamic>>[
          _releaseEntry(id: 'cached1', name: '缓存里那条', installed: '1.0.0'),
        ],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    expect(admin.calls, contains('release:refresh'), reason: '进页面的后台自动拉已跑过');
    expect(
      find.text('缓存里那条'),
      findsOneWidget,
      reason: '拉失败不等于“仓库里没插件”：缓存那份照列',
    );
    expect(find.textContaining('本地缓存（release v0.0.9，不是最新）'), findsOneWidget);
    expect(
      find.textContaining('取最新 release 失败'),
      findsOneWidget,
      reason: '失败原因就地写进区块里那一行',
    );
    expect(find.textContaining('刷新失败'), findsNothing, reason: '后台失败不弹 snack');
  });

  testWidgets('三栏：默认停在「未安装」，插件实例与站点各归各栏', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    // 默认 = 未安装：索引区块 + 添加自定义插件入口在，已装 / 站点内容不在
    expect(find.text('从发布仓库更新'), findsOneWidget);
    expect(
      find.byKey(const Key('plugin-add')),
      findsOneWidget,
      reason: '「未安装」栏带添加自定义插件入口',
    );
    expect(find.text('插件实例（2）'), findsNothing, reason: '已装内容不在未安装栏');
    expect(find.textContaining('站点（已建'), findsNothing);

    await _showTab(tester, 'plugin-tab-installed');
    expect(find.text('插件实例（2）'), findsOneWidget);
    expect(find.text('看门狗'), findsOneWidget);
    expect(find.text('从发布仓库更新'), findsNothing);

    await _showTab(tester, 'plugin-tab-stations');
    expect(find.text('站点（已建 0/4 类）'), findsOneWidget);
    expect(find.text('插件实例（2）'), findsNothing);
  });

  testWidgets('「未安装」栏按名字 / id 检索：过滤索引条目，检索不到写明', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        entries: <Map<String, dynamic>>[
          _releaseEntry(id: 'alpha', name: '阿尔法工具'),
          _releaseEntry(id: 'beta', name: '贝塔采集器'),
        ],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    expect(find.text('阿尔法工具'), findsOneWidget);
    expect(find.text('贝塔采集器'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('plugin-tab-search')), 'alpha');
    await tester.pumpAndSettle();
    expect(find.text('阿尔法工具'), findsOneWidget, reason: '按 id 检索命中');
    expect(find.text('贝塔采集器'), findsNothing);

    await tester.enterText(find.byKey(const Key('plugin-tab-search')), '贝塔');
    await tester.pumpAndSettle();
    expect(find.text('阿尔法工具'), findsNothing);
    expect(find.text('贝塔采集器'), findsOneWidget, reason: '按名字检索命中');

    await tester.enterText(find.byKey(const Key('plugin-tab-search')), 'zzz');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('没有匹配「zzz」'),
      findsOneWidget,
      reason: '检索不到要写明，不留白（不让人以为索引里真的一条都没有）',
    );
    expect(find.text('阿尔法工具'), findsNothing);
  });

  testWidgets('发布仓库：刷新后列出条目，并把跳过的条目与原因写出来', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        entries: <Map<String, dynamic>>[_releaseEntry()],
        skipped: <String>['bad：version 必须是三段数字 x.y.z（当前：1.2）'],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    await tester.tap(find.byKey(const Key('plugin-release-refresh')));
    await tester.pumpAndSettle();

    expect(admin.calls, contains('release:refresh'));
    expect(find.text('发布版演示插件'), findsOneWidget);
    expect(find.textContaining('发布 1.2.0 · 本机未装'), findsOneWidget);
    expect(find.textContaining('刚拉的索引（release v0.1.0）'), findsOneWidget);
    expect(
      find.textContaining('跳过：bad：version'),
      findsOneWidget,
      reason: '坏条目要能说“为什么没出现”，不静默也不带走整份清单',
    );
  });

  testWidgets('发布仓库：点「安装」只把 id 发出去，成功后显示版本', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        entries: <Map<String, dynamic>>[_releaseEntry()],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await tester.tap(find.byKey(const Key('plugin-release-refresh')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-release-install-demo2')));
    await tester.pumpAndSettle();

    expect(admin.calls, contains('release:install:demo2'));
    expect(
      find.text('已从发布仓库安装 demo2（1.2.0）'),
      findsOneWidget,
      reason: '装了哪一版要说出来，只说“成功”等于没说',
    );
  });

  testWidgets('发布仓库：闸门拦住时原样显示核心的原因（旧文件没动）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        entries: <Map<String, dynamic>>[_releaseEntry()],
      )
      ..failWrite =
          '插件 demo2 的进程还没确认退出 ⇒ 这次不替换文件，旧文件一个都没动';
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await tester.tap(find.byKey(const Key('plugin-release-refresh')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-release-install-demo2')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('旧文件一个都没动'),
      findsOneWidget,
      reason: '“现在换不了”与“换坏了”是两回事，核心那句话得原样递到用户眼前',
    );
  });

  testWidgets('发布仓库：刷新失败仍列出上一次那份，并标清这不是最新', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        ok: false,
        error: '取最新 release 失败：HTTP 403（GitHub API 限流）',
        tag: '',
      )
      ..refreshCached = _releaseListing(
        online: false,
        tag: 'v0.0.9',
        entries: <Map<String, dynamic>>[
          _releaseEntry(id: 'cached1', name: '缓存里那条', installed: '1.0.0'),
        ],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    await tester.tap(find.byKey(const Key('plugin-release-refresh')));
    await tester.pumpAndSettle();

    expect(
      find.text('缓存里那条'),
      findsOneWidget,
      reason: '刷新失败不等于“仓库里没插件”：缓存那份还能装就要列出来',
    );
    expect(find.textContaining('本地缓存（release v0.0.9，不是最新）'), findsOneWidget);
  });

  testWidgets('发布仓库：已是最新时按钮禁用而不是消失', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()
      ..refreshResponse = _releaseListing(
        entries: <Map<String, dynamic>>[
          _releaseEntry(id: 'same', installed: '1.2.0', hasUpdate: false),
        ],
      );
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
    await tester.tap(find.byKey(const Key('plugin-release-refresh')));
    await tester.pumpAndSettle();

    final Finder button = find.byKey(const Key('plugin-release-install-same'));
    expect(button, findsOneWidget, reason: '隐藏会让人以为这一条不能装');
    expect(tester.widget<TextButton>(button).onPressed, isNull);
  });
}
