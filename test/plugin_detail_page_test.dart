// 插件 / 站点**详情页**的 widget 用例：点进右栏能看到什么、写操作发的是什么请求。
//
// 这一层锁的是"界面上讲的话"与"界面发出去的形状"：
// - 详情页 C 起经 DetailSelection **注入右栏 DetailPanel**（不再 Navigator push）：
//   断言注入可见、关闭按钮清空注入态；
// - 插件页的管理按钮（启用 / 停用 / 重启 / 热重启 / 卸载）+ A+ 起的发布仓库安装按钮
//   （断言 refresh → install 的顺序与就地失败原因、卸载的确认对话框与关闭时机）；
// - 站点页有写操作，所以断言的是 **PATCH / POST 的 body 形状**（禁用订阅者发的是
//   `disabled: true` 而不是"退订"；改配置发的类型不能把 int 变成 "8"；
//   站点启用停用发的是 `enabled` 单键）；
// 核心侧的落盘与判定规则由 packages/tree_core/test/plugin_api_test.dart 锁住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/plugin_monitor_service.dart';
import 'package:tree/ui/services/detail_selection.dart';
import 'package:tree/ui/widgets/detail_panel.dart';
import 'package:tree/ui/widgets/plugin_detail_page.dart';
import 'package:tree/ui/widgets/plugin_panel.dart';

/// 假的管理接口：记录调用流水，站点详情返回可替换的 describe() 形状。
class _FakeAdmin implements PluginAdminClient {
  _FakeAdmin({required this.stationResponses});

  /// stationId → 详情返回体；缺失的 id 表示"核心说这个站点不存在"。
  final Map<String, Map<String, dynamic>> stationResponses;

  final List<String> calls = <String>[];
  Map<String, dynamic>? lastStationPatch;
  String failRead = '';
  String failWrite = '';

  /// 清单响应（默认那一条**没有**来源键 = 本机自己写的条目；用例可换成带
  /// `source` / `repo_version` 的那一条，用来钉详情页的「来源」行）。
  Map<String, dynamic> configsResponse = _configs();

  static Map<String, dynamic> _configs() => <String, dynamic>{
    'path': 'C:/data/config/plugins.yaml',
    'configs': <dynamic>[
      <String, dynamic>{
        'id': 'demo',
        'name': '演示插件',
        'description': '把工具公告转发给队友，并把执行结果收回来',
        'command': 'python',
        'args': <String>['demo.py'],
        'enabled': true,
        'granularity': 'team',
        'scope': <String, dynamic>{'team_id': 't1'},
      },
      // 2026-10-18 用户定稿：内置项装进来后就是一条**普通条目**——面板把它当普通
      // 插件列（同一种 key / 同一套按钮），"内置"这层身份只在详情页按 id 现查补上。
      <String, dynamic>{
        'id': 'sample',
        'name': '示例插件',
        'description': '核心自带的示例插件（Python）',
        'command': 'python',
        'args': <String>['sample.py'],
        'enabled': true,
        'granularity': 'team',
        'scope': <String, dynamic>{},
        'builtin': true,
      },
    ],
    'runtime': <String, dynamic>{
      'demo': <String, dynamic>{'running': true, 'health': 'ok', 'known': true},
    },
  };

  static Map<String, dynamic> _builtins() => <String, dynamic>{
    'builtins': <dynamic>[
      <String, dynamic>{
        'id': 'sample',
        'name': '示例插件',
        'description': '核心自带的示例插件（Python）',
        'enabled': true,
        'configured': true,
        'resolution': <String, dynamic>{'ok': false, 'error': '本机没装 Python'},
      },
    ],
  };

  /// 内置目录响应（可赋值：用例用它换 resolution，钉按钮的第二种文案「从仓库更新」）。
  Map<String, dynamic> builtinsResponse = _builtins();

  @override
  Future<Map<String, dynamic>> fetchConfigs() async => configsResponse;

  @override
  Future<Map<String, dynamic>> fetchBuiltins({bool refresh = false}) async =>
      builtinsResponse;

  @override
  Future<Map<String, dynamic>> createConfig(Map<String, dynamic> body) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> updateConfig(
    String id,
    Map<String, dynamic> patch,
  ) async {
    calls.add('update:$id:${patch['enabled'] == false ? 'off' : 'edit'}');
    return <String, dynamic>{'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteConfig(String id) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> restartConfig(
    String id, {
    String mode = 'cold',
    bool keepState = true,
  }) async {
    calls.add('restart:$id:$mode');
    return <String, dynamic>{'ok': true};
  }

  @override
  Future<Map<String, dynamic>> stationDetail(String stationId) async {
    calls.add('detail:$stationId');
    if (failRead.isNotEmpty) throw Exception(failRead);
    final Map<String, dynamic>? body = stationResponses[stationId];
    if (body == null) {
      throw Exception('站点不存在：$stationId');
    }
    return body;
  }

  @override
  Future<Map<String, dynamic>> patchStationConfig(
    String stationId,
    Map<String, dynamic> patch,
  ) async {
    calls.add('patch:$stationId:${patch.keys.join('+')}');
    lastStationPatch = patch;
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    // 核心回**改后的完整详情**：把这一个键合并进去（形状与 describe() 一致），
    // 页面才能拿回包刷新出新值（站点启用停用的 Switch 靠它翻面）。
    return <String, dynamic>{...stationResponses[stationId]!, ...patch};
  }

  @override
  Future<Map<String, dynamic>> setSubscriberDisabled(
    String stationId,
    String subscriberKey, {
    required bool disabled,
  }) async {
    calls.add('sub:$stationId|$subscriberKey|disabled=$disabled');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return stationResponses[stationId]!;
  }

  // ── 发布仓库：详情页的「从仓库装它 / 从仓库更新」（A+）──────────────────

  /// 刷新的返回体（null = 没有索引的旧口径回包：ok:false「没有缓存」+ 空条目）。
  Map<String, dynamic>? refreshResponse;

  /// 刷新没成功时核心附上的“上一次那份”（里面**有**这一条就还能装）。
  Map<String, dynamic>? refreshCached;

  /// install 的返回体（形状 = 核心回包里的 install 段，用来钉成功话术里的版本号）。
  Map<String, dynamic> installResponse = <String, dynamic>{
    'ok': true,
    'install': <String, dynamic>{'ok': true, 'plugin_id': 'sample', 'version': '1.2.0'},
  };

  @override
  Future<Map<String, dynamic>> fetchRelease() async => <String, dynamic>{
    'ok': false,
    'error': '没有缓存',
    'entries': <dynamic>[],
  };

  @override
  Future<Map<String, dynamic>> refreshRelease() async {
    calls.add('release:refresh');
    return <String, dynamic>{
      ...(refreshResponse ?? <String, dynamic>{
        'ok': false,
        'error': '没有缓存',
        'entries': <dynamic>[],
      }),
      if (refreshCached != null) 'cached': refreshCached,
    };
  }

  @override
  Future<Map<String, dynamic>> installRelease(String id) async {
    calls.add('release-install:$id');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return installResponse;
  }

  /// 卸载的返回体（成功关详情；非空 [failWrite] 时抛出，钉就地错误显示）。
  Map<String, dynamic> uninstallResponse = <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> uninstallRelease(String id) async {
    calls.add('uninstall:$id');
    if (failWrite.isNotEmpty) throw Exception(failWrite);
    return uninstallResponse;
  }
}

/// 自建站详情（字段形状 = 核心 `StationInstance.describe()`）。
Map<String, dynamic> _selfBuiltStation() => <String, dynamic>{
  'station_id': 'plugin.demo.relay.audit',
  'kind': 'relay',
  'kind_label': '中转站',
  'description': '把公告按 team 再分发一次',
  'readme': '自建中转站：收到公告后单向改写再投递，白名单内的插件都能触发它。',
  'scope': <String, dynamic>{},
  'builtin': false,
  'max_subscriptions': 8,
  'shared': true,
  'allowed_plugins': <String>['sample'],
  'config': <String, dynamic>{'route': 'audit', 'route_limit': 8},
  'subscriber_count': 2,
  'subscriptions': <dynamic>[
    <String, dynamic>{
      'subscriber': 'demo|',
      'plugin_id': 'demo',
      'granularity': 'team',
      'scope': <String, dynamic>{},
      'disabled': false,
    },
    <String, dynamic>{
      'subscriber': 'sample|t1|||local',
      'plugin_id': 'sample',
      'granularity': 'team',
      'scope': <String, dynamic>{'team_id': 't1', 'mode_key': 'local'},
      'disabled': true,
    },
  ],
  'subscribers_by_team': <String, dynamic>{'t1': 1},
  'counts': <String, dynamic>{'requests': 3, 'skipped_disabled': 1},
  'gauges': <String, dynamic>{'waits_in_flight': 0},
};

/// 内置站详情：**只有可订阅数量能改**（介绍与配置在核心的点位表里）。
Map<String, dynamic> _builtinStation() => <String, dynamic>{
  'station_id': 'system.broadcast',
  'kind': 'broadcast',
  'kind_label': '广播站',
  'description': '把工具公告投递给订阅者',
  'readme': '内置广播站：全局唯一一个点位。',
  'scope': <String, dynamic>{},
  'builtin': true,
  'max_subscriptions': 32,
  'config': <String, dynamic>{'fanout': 'team'},
  'subscriber_count': 1,
  'subscriptions': <dynamic>[
    <String, dynamic>{
      'subscriber': 'demo|t1',
      'plugin_id': 'demo',
      'granularity': 'team',
      'scope': <String, dynamic>{'team_id': 't1'},
      'disabled': false,
    },
  ],
  'counts': <String, dynamic>{'requests': 5},
  'gauges': <String, dynamic>{'waits_in_flight': 1},
};

Map<String, dynamic> _snapshot() => <String, dynamic>{
  'enabled': true,
  'instances': <dynamic>[
    <String, dynamic>{
      'plugin_id': 'demo',
      'name': '演示插件',
      'description': '把工具公告转发给队友，并把执行结果收回来',
      'status': 'registered',
      'granularity': 'team',
      'health': 'ok',
      'last_heartbeat': 0,
      'tools': <dynamic>[
        <String, dynamic>{'name': 'demo.echo', 'description': '回显一句话'},
        <String, dynamic>{'name': 'demo.collect'},
      ],
    },
  ],
  'stations': <dynamic>[_selfBuiltStation(), _builtinStation()],
  'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
};

Future<PluginMonitorService> _service() async {
  final PluginMonitorService svc = PluginMonitorService.forTesting();
  svc.snapshotFetcher = ({String? teamId}) async => _snapshot();
  await svc.refresh();
  return svc;
}

Future<void> _pump(
  WidgetTester tester, {
  required PluginMonitorService svc,
  required _FakeAdmin admin,
}) async {
  tester.view.physicalSize = const Size(1560, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // C 起详情页不再 push 全屏：面板与 DetailPanel **并排**（右栏那一格），
  // 点卡片后 DetailSelection 注入，由 DetailPanel 显示。
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 2200,
          width: 1560,
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 860,
                child: PluginPanel(
                  service: svc,
                  admin: admin,
                  showHeader: false,
                ),
              ),
              const SizedBox(width: 700, child: DetailPanel()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 切到指定栏（三栏面板：卡片各归各栏，点之前先让它可见）。
Future<void> _showTab(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  // 注入态是全局单例：每个用例从干净状态开始、结束时清掉，
  // 否则上一个用例开着的详情页会被下一个用例看见。
  setUp(() => DetailSelection.instance.clear());
  tearDown(() => DetailSelection.instance.clear());

  testWidgets('点自定义插件卡片进详情页：介绍、工具、它建的与它订阅的站点', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    // 介绍（清单里那句 description，卡片上只显示一行，详情页给全文）
    expect(find.textContaining('把工具公告转发给队友，并把执行结果收回来'), findsWidgets);
    // 基本信息（命令一行面板卡片也在显示：并排后不再被全屏路由遮住 ⇒ 按详情页范围查）
    expect(find.text('基本信息'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PluginDetailPage),
        matching: find.textContaining('python demo.py'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('team_id=t1'), findsWidgets);
    // 详情页里不能出现"内置"归属（卡片列表在路由下方，所以按详情页范围查）
    final Finder detail = find.byType(PluginDetailPage);
    expect(
      find.descendant(of: detail, matching: find.text('内置插件')),
      findsNothing,
      reason: '这一项是自定义插件',
    );
    expect(
      find.descendant(of: detail, matching: find.text('自定义插件')),
      findsOneWidget,
    );
    // 工具表（按插件对账的运行态，两条都在）
    expect(find.text('提供的工具（2）'), findsOneWidget);
    expect(find.text('demo.echo'), findsOneWidget);
    expect(find.text('回显一句话'), findsOneWidget);
    // 它建的站点 / 它订阅的站点：audit 这条既是 demo 建的、也被 demo 订阅 ⇒ 两个区块各列一次；
    // demo 还订阅了内置广播站 ⇒ 订阅那一栏是 2 条。全部限定在详情页内（面板还在路由下方）。
    expect(
      find.descendant(of: detail, matching: find.text('它建的站点（1）')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detail, matching: find.text('它订阅的站点（2）')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: detail,
        matching: find.text('plugin.demo.relay.audit'),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: detail, matching: find.text('system.broadcast')),
      findsOneWidget,
    );
    expect(
      find.text(
        '这个插件没有写介绍。点卡片上的「编辑」，在「介绍」里补一段（落盘 plugins.yaml 的 description）。',
      ),
      findsNothing,
    );
  });

  testWidgets('点已安装的内置项进详情页：按 id 现查补出「内置插件」身份与运行时', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-sample')));
    await tester.pumpAndSettle();

    expect(find.text('核心自带的示例插件（Python）'), findsWidgets);
    expect(find.text('归属'), findsOneWidget);
    expect(find.text('内置插件'), findsOneWidget);
    // 运行时没就绪：详情必须显示核心给的原因（不显示就等于骗用户"能跑"）
    expect(find.text('内置运行时'), findsOneWidget);
    // 面板卡片也显示同一句（并排后不再被路由遮住）⇒ 按详情页范围查
    expect(
      find.descendant(
        of: find.byType(PluginDetailPage),
        matching: find.textContaining('运行时未就绪：本机没装 Python'),
      ),
      findsOneWidget,
    );
    // 没有运行实例 ⇒ 不假装有能力
    expect(find.text('提供的工具（0）'), findsOneWidget);
    expect(find.textContaining('未提供工具'), findsOneWidget);
  });

  testWidgets('卡片上的开关不会误跳详情页（点开关 = 只发开关请求）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-switch-custom-demo')));
    await tester.pumpAndSettle();

    expect(find.text('基本信息'), findsNothing, reason: '点开关不该跳到详情页');
    expect(find.text('提供的工具（2）'), findsNothing);
  });

  testWidgets('点站点卡片进详情页：介绍 + 可订阅数量 + 订阅管理 + 其他', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    // 详情页一定去 GET 一次（卡片那份是节流的快照，写操作要落在当前真值上）
    expect(admin.calls, contains('detail:plugin.demo.relay.audit'));
    // 介绍 = readme（不是那一行 description）
    expect(find.textContaining('自建中转站：收到公告后单向改写再投递'), findsOneWidget);
    expect(find.text('站点介绍'), findsOneWidget);
    // 可订阅插件数量
    expect(find.text('站点可订阅插件数量'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('station-detail-max')))
          .controller!
          .text,
      '8',
    );
    expect(find.textContaining('2 个订阅者（其中 1 个已禁用）'), findsOneWidget);
    // 已订阅插件管理：两条订阅都在（禁用的那条不消失）
    expect(find.text('已订阅插件管理（2）'), findsOneWidget);
    expect(find.text('已禁用'), findsOneWidget);
    expect(find.text('投递中'), findsOneWidget);
    expect(
      find.byKey(const Key('station-detail-sub-sample|t1|||local')),
      findsOneWidget,
    );
    // 其他（站点自定义配置）：两个键都能改
    expect(find.text('其他（站点自定义配置）'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('station-detail-config-route')),
          )
          .controller!
          .text,
      'audit',
    );
    expect(find.byKey(const Key('station-detail-save-config')), findsOneWidget);
    // 跨插件共享（白名单）
    expect(find.textContaining('限白名单：sample'), findsOneWidget);
  });

  testWidgets('禁用订阅者：发的是 disabled=true（禁用不是退订）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    // 未禁用那条（demo|）：关掉 ⇒ disabled: true
    await tester.tap(find.byKey(const Key('station-detail-sub-demo|')));
    await tester.pumpAndSettle();
    expect(
      admin.calls,
      contains('sub:plugin.demo.relay.audit|demo||disabled=true'),
    );

    // 已禁用那条（sample|t1|||local）：打开 ⇒ disabled: false（恢复投递）
    await tester.tap(
      find.byKey(const Key('station-detail-sub-sample|t1|||local')),
    );
    await tester.pumpAndSettle();
    expect(
      admin.calls,
      contains('sub:plugin.demo.relay.audit|sample|t1|||local|disabled=false'),
    );
    // 列表没有因为禁用而少一条
    expect(find.text('已订阅插件管理（2）'), findsOneWidget);
  });

  testWidgets('可订阅数量：整数写回；非整数被拦住且不发请求', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('station-detail-max')), 'abc');
    await tester.tap(find.byKey(const Key('station-detail-save-max')));
    await tester.pumpAndSettle();
    expect(
      admin.calls.where((String c) => c.startsWith('patch:plugin.demo.relay.audit')),
      isEmpty,
    );
    expect(find.textContaining('要写整数'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('station-detail-max')), '0');
    await tester.tap(find.byKey(const Key('station-detail-save-max')));
    await tester.pumpAndSettle();
    expect(admin.lastStationPatch, <String, dynamic>{'max_subscriptions': 0});
  });

  testWidgets('改站点自定义配置：没动的键保持原类型，动过的按字面量重识别', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('station-detail-config-route_limit')),
      '12',
    );
    await tester.enterText(
      find.byKey(const Key('station-detail-config-route')),
      'audit2',
    );
    await tester.tap(find.byKey(const Key('station-detail-save-config')));
    await tester.pumpAndSettle();

    final Map<String, dynamic> config =
        admin.lastStationPatch!['config'] as Map<String, dynamic>;
    expect(config['route_limit'], 12, reason: '数字不能被发成字符串（插件按 int 读它就会静默失效）');
    expect(config['route'], 'audit2');
  });

  testWidgets('删配置项与加配置项都发**整个 config**（核心是整体替换语义）', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('station-detail-remove-route')));
    await tester.pumpAndSettle();
    Map<String, dynamic> config =
        admin.lastStationPatch!['config'] as Map<String, dynamic>;
    expect(config.containsKey('route'), isFalse);
    expect(config['route_limit'], 8, reason: '没动的键要原样带上（否则等于顺手删了别人的配置）');

    await tester.enterText(
      find.byKey(const Key('station-detail-new-key')),
      'topic_prefix',
    );
    await tester.enterText(
      find.byKey(const Key('station-detail-new-value')),
      'audit.',
    );
    await tester.tap(find.byKey(const Key('station-detail-add-config')));
    await tester.pumpAndSettle();
    config = admin.lastStationPatch!['config'] as Map<String, dynamic>;
    expect(config['topic_prefix'], 'audit.');
  });

  testWidgets('内置站点：只有可订阅数量能改，介绍与配置只读并写明原因', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(find.byKey(const Key('station-detail-system.broadcast')));
    await tester.pumpAndSettle();

    expect(find.textContaining('内置广播站：全局唯一一个点位。'), findsOneWidget);
    expect(find.text('插件自建站'), findsNothing);
    // 上限照常能改
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('station-detail-max')))
          .controller!
          .text,
      '32',
    );
    // 配置区只读：没有保存按钮、没有输入框，且说清为什么
    expect(find.byKey(const Key('station-detail-save-config')), findsNothing);
    expect(find.byKey(const Key('station-detail-config-fanout')), findsNothing);
    expect(find.textContaining('内置站点的介绍与自定义配置在核心的点位表里'), findsOneWidget);
  });

  testWidgets('站点详情读不到（有快照那份）：顶部红条写明失败，不假装是当前真值', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    // 卡片来自快照，但核心这边这个站点已经不在了（例如插件注销了自建站）
    admin.stationResponses.remove('plugin.demo.relay.audit');
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('站点详情刷新失败：站点不存在'), findsOneWidget);
    // 面板自己的“连接断开…（下方为最近一次数据）”横幅同一时段也在台上 ⇒ 按站点页范围查
    expect(
      find.descendant(
        of: find.byType(StationDetailPage),
        matching: find.textContaining('下方为最近一次数据'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('站点详情完全读不到（没有快照那份）：说清原因 + 给重试，不渲染空白详情页', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StationDetailPage(
          stationId: 'plugin.demo.relay.gone',
          admin: admin,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('读不到站点 plugin.demo.relay.gone：站点不存在'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('station-detail-retry')), findsOneWidget);
    expect(find.text('站点介绍'), findsNothing, reason: '不能拿空数据渲染一张空白详情页');

    // 重试真的再读一次（不是把错误条藏起来）
    admin.stationResponses['plugin.demo.relay.gone'] = _selfBuiltStation();
    await tester.tap(find.byKey(const Key('station-detail-retry')));
    await tester.pumpAndSettle();
    expect(find.text('站点介绍'), findsOneWidget);
    expect(admin.calls, contains('detail:plugin.demo.relay.gone'));
  });

  testWidgets('写操作被核心拒绝：原因原样显示（不把 400 咽掉）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    admin.failWrite = '内置站点 system.broadcast 不提供修改 readme：界面上可改的只有「可订阅插件数量」';
    await tester.enterText(find.byKey(const Key('station-detail-max')), '4');
    await tester.tap(find.byKey(const Key('station-detail-save-max')));
    await tester.pumpAndSettle();
    expect(find.textContaining('操作失败：内置站点'), findsOneWidget);
  });

  // ── 发布仓库来源（阶段 5）：详情页要说清“这一条是从哪里装的”──────────

  /// 一条带来源标记的落盘条目（形状 = 核心 install 后写进 plugins.yaml 的那一条）。
  Map<String, dynamic> releasedConfigs({
    bool withSource = true,
  }) => <String, dynamic>{
    'path': 'C:/data/config/plugins.yaml',
    'configs': <dynamic>[
      <String, dynamic>{
        'id': 'demo',
        'name': '演示插件',
        'description': '从发布仓库装的那一条',
        'command': 'C:/app/plugins/tree_demo.exe',
        'args': <String>[],
        'enabled': true,
        'granularity': 'team',
        'scope': <String, dynamic>{},
        if (withSource) 'source': 'release',
        if (withSource) 'repo_version': '1.2.0',
      },
    ],
    'runtime': <String, dynamic>{
      'demo': <String, dynamic>{'running': true, 'health': 'ok', 'known': true},
    },
  };

  testWidgets('来源行：发布仓库装的条目写明来源与已装版本', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )..configsResponse = releasedConfigs();
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    final Finder detail = find.byType(PluginDetailPage);
    expect(
      find.descendant(
        of: detail,
        matching: find.textContaining('发布仓库（只拉 GitHub Release 资产） · 已装 1.2.0'),
      ),
      findsOneWidget,
      reason: '“这一条是从发布仓库装的、装的是哪一版”必须看得到',
    );
  });

  testWidgets('来源行：本机自己写的条目不渲染这一行（而不是一个空值）', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )..configsResponse = releasedConfigs(withSource: false);
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    final Finder detail = find.byType(PluginDetailPage);
    expect(
      find.descendant(of: detail, matching: find.text('来源')),
      findsNothing,
      reason: '没有来源键就整行不渲染：显示一个空值会被当成 bug',
    );
  });

  // ── A+：详情页的「从仓库装它 / 从仓库更新」────────────────────────────

  /// 一条索引条目（键与核心 `PluginRepoEntry.toJson()` 一致）。
  Map<String, dynamic> releaseEntry({String id = 'sample'}) =>
      <String, dynamic>{
        'plugin_id': id,
        'name': '示例插件',
        'version': '1.2.0',
        'installed_version': '',
        'has_update': true,
        'runtime': 'binary',
      };

  testWidgets('详情页发布仓库：缺成品给「从仓库装它」，点了先刷新索引再 install', (
    WidgetTester tester,
  ) async {
    // 默认夹具 resolution.ok=false（本机没装 Python）⇒ needsArtifact ⇒ 装它。
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )..refreshResponse = <String, dynamic>{
      'ok': true,
      'error': '',
      'tag': 'v0.1.0',
      'online': true,
      'index_path': 'C:/data/plugins_release/plugin-index.json',
      'entries': <dynamic>[releaseEntry()],
      'skipped': <dynamic>[],
    };
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-sample')));
    await tester.pumpAndSettle();

    final Finder detail = find.byType(PluginDetailPage);
    expect(find.text('发布仓库'), findsOneWidget);
    final Finder button = find.byKey(const Key('plugin-detail-repo-sample'));
    expect(
      find.descendant(of: detail, matching: button),
      findsOneWidget,
      reason: '详情页是缺成品时的第二个入口（卡片在面板上，详情页就地也能装）',
    );
    expect(find.descendant(of: detail, matching: find.text('从仓库装它')), findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(admin.calls, contains('release:refresh'), reason: '先自动刷新索引');
    expect(admin.calls, contains('release-install:sample'), reason: '索引里有这一条 ⇒ 接着 install');
    expect(
      admin.calls.indexOf('release:refresh'),
      lessThan(admin.calls.indexOf('release-install:sample')),
      reason: '顺序必须是 refresh → install（装机端要的是最新索引）',
    );
    expect(
      find.text('已从发布仓库安装 sample（1.2.0）'),
      findsOneWidget,
      reason: '装了哪一版要说出来',
    );
    expect(
      find.byKey(const Key('plugin-detail-repo-error-sample')),
      findsNothing,
      reason: '成功后不该还挂着错误',
    );
  });

  testWidgets('详情页发布仓库：成品在 ⇒ 同一颗按钮显示「从仓库更新」', (
    WidgetTester tester,
  ) async {
    final Map<String, dynamic> resolvable = _FakeAdmin._builtins();
    (
      (resolvable['builtins'] as List<dynamic>).single as Map<String, dynamic>
    )['resolution'] = <String, dynamic>{
      'ok': true,
      'command': 'C:/app/plugins/tree_sample.exe',
      'script_path': '',
    };
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )..builtinsResponse = resolvable;
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-sample')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(PluginDetailPage),
        matching: find.text('从仓库更新'),
      ),
      findsOneWidget,
      reason: '已装/有更新时同一颗按钮换文案（不消失：它就是更新入口）',
    );
  });

  testWidgets('详情页发布仓库：索引里没有这一条 ⇒ 就地显示原因，不发 install', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )..refreshResponse = <String, dynamic>{
      'ok': true,
      'error': '',
      'tag': 'v0.1.0',
      'online': true,
      'index_path': 'C:/data/plugins_release/plugin-index.json',
      'entries': <dynamic>[], // 刷新成功了，但索引里没有 sample
      'skipped': <dynamic>[],
    };
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-sample')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plugin-detail-repo-sample')));
    await tester.pumpAndSettle();

    expect(admin.calls, contains('release:refresh'));
    expect(
      admin.calls,
      isNot(contains('release-install:sample')),
      reason: '索引里没这一条时 install 必然失败，就地说明比发一次注定失败的请求好',
    );
    expect(
      find.byKey(const Key('plugin-detail-repo-error-sample')),
      findsOneWidget,
      reason: '失败原因就地显示在按钮下方（不只是一条转瞬即逝的 snack）',
    );
    expect(find.textContaining('索引里没有 sample 这一条'), findsOneWidget);
  });

  testWidgets('详情页发布仓库：install 被核心拒绝 ⇒ 原因就地显示', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )
      ..refreshResponse = <String, dynamic>{
        'ok': true,
        'error': '',
        'tag': 'v0.1.0',
        'online': true,
        'index_path': 'C:/data/plugins_release/plugin-index.json',
        'entries': <dynamic>[releaseEntry()],
        'skipped': <dynamic>[],
      }
      ..failWrite = '插件 sample 的进程还没确认退出 ⇒ 这次不替换文件，旧文件一个都没动';
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-sample')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plugin-detail-repo-sample')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('plugin-detail-repo-error-sample')),
      findsOneWidget,
    );
    expect(
      find.textContaining('旧文件一个都没动'),
      findsOneWidget,
      reason: '核心那句话得原样递到用户眼前（“现在换不了”与“换坏了”是两回事）',
    );
  });

  testWidgets('自定义插件详情页不渲染发布仓库区块（那是内置项缺成品的入口）', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await _pump(tester, svc: await _service(), admin: admin);

    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(PluginDetailPage),
        matching: find.text('发布仓库'),
      ),
      findsNothing,
      reason: '自定义插件没有“缺成品”这一说（它的命令是用户自己填的）',
    );
    expect(
      find.byKey(const Key('plugin-detail-repo-demo')),
      findsNothing,
    );
  });

  // ── C：注入右栏 + 管理按钮 + 站点启用停用 ────────────────────────────────

  testWidgets('详情页注入右栏 DetailPanel：管理按钮齐全，关闭按钮清空注入态', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    // 点卡片 = 注入右栏那一格，不是压在面板上的全屏路由
    expect(DetailSelection.instance.injected, isNotNull);
    expect(
      find.descendant(
        of: find.byType(DetailPanel),
        matching: find.byType(PluginDetailPage),
      ),
      findsOneWidget,
      reason: '详情页显示在 DetailPanel 里（C：不再 Navigator.push）',
    );
    // 管理按钮区：插件 = 启用/停用 · 重启 · 热重启 · 编辑 · 卸载
    final Finder detail = find.byType(PluginDetailPage);
    for (final String key in <String>[
      'plugin-detail-toggle-demo',
      'plugin-detail-restart-demo',
      'plugin-detail-hot-restart-demo',
      'plugin-detail-edit-demo',
      'plugin-detail-uninstall-demo',
    ]) {
      expect(
        find.descendant(of: detail, matching: find.byKey(Key(key))),
        findsOneWidget,
        reason: '详情页要有 $key',
      );
    }

    // 关闭（注入态没有路由可返回，只能显式 ×）：清空注入、DetailPanel 回到空态
    await tester.tap(find.byKey(const Key('plugin-detail-close')));
    await tester.pumpAndSettle();
    expect(DetailSelection.instance.injected, isNull);
    expect(find.byType(PluginDetailPage), findsNothing);
    expect(find.text('点中栏的工具调用或思考'), findsOneWidget);
  });

  testWidgets('管理按钮：停用发 PATCH enabled、重启与热重启各发各的 mode', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    // 自定义项（当前已启用）：点「停用」⇒ updateConfig(id, enabled:false)
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('plugin-detail-toggle-demo')),
              matching: find.byType(Text),
            ),
          )
          .data,
      '停用',
    );
    await tester.tap(find.byKey(const Key('plugin-detail-toggle-demo')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('update:demo:off'));

    await tester.tap(find.byKey(const Key('plugin-detail-restart-demo')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('restart:demo:cold'));

    await tester.tap(find.byKey(const Key('plugin-detail-hot-restart-demo')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('restart:demo:hot'));
  });

  testWidgets('内置项装进来后与自定义同一条命：开关走 PATCH（不再打内置专属端点）', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    // 面板把它当**普通条目**列（同一种 key）；内置身份由详情页按 id 现查补上
    await tester.tap(find.byKey(const Key('plugin-detail-custom-sample')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-detail-toggle-sample')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('update:sample:off'));
    expect(
      admin.calls.any((String c) => c.startsWith('builtin:')),
      isFalse,
      reason: '面板不再打内置专属端点（那条端点留着给别的调用方，UI 不再用）',
    );
  });

  testWidgets('卸载：先确认（不点确认不发请求），成功后关掉详情页', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-detail-uninstall-demo')));
    await tester.pumpAndSettle();
    expect(find.text('卸载这个插件？'), findsOneWidget);
    expect(
      admin.calls.where((String c) => c.startsWith('uninstall')),
      isEmpty,
      reason: '没点确认就一个请求都不发',
    );

    await tester.tap(find.byKey(const Key('plugin-detail-uninstall-confirm')));
    await tester.pumpAndSettle();
    expect(admin.calls, contains('uninstall:demo'));
    // 成功 ⇒ 条目没了，这一页没有对象：直接关掉（注入态没有路由，只能 clear）
    expect(find.byType(PluginDetailPage), findsNothing);
    expect(DetailSelection.instance.injected, isNull);
  });

  testWidgets('卸载被核心拒（等不到退出确认）⇒ 原因就地显示，详情页不关', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{},
    )..failWrite = '插件 demo 的进程还没确认退出 ⇒ 这次不删任何文件';
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-installed');
    await tester.tap(find.byKey(const Key('plugin-detail-custom-demo')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plugin-detail-uninstall-demo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plugin-detail-uninstall-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('plugin-detail-manage-error-demo')),
      findsOneWidget,
      reason: '失败原因就地留在屏幕上（不是一条转瞬即逝的 snack）',
    );
    expect(find.textContaining('还没确认退出'), findsOneWidget);
    expect(find.byType(PluginDetailPage), findsOneWidget, reason: '失败不关页');
  });

  testWidgets('站点启用/停用：只发 enabled 单键，开关随回包翻面', (
    WidgetTester tester,
  ) async {
    final _FakeAdmin admin = _FakeAdmin(
      stationResponses: <String, Map<String, dynamic>>{
        'plugin.demo.relay.audit': _selfBuiltStation(),
        'system.broadcast': _builtinStation(),
      },
    );
    await _pump(tester, svc: await _service(), admin: admin);
    await _showTab(tester, 'plugin-tab-stations');
    await tester.tap(
      find.byKey(const Key('station-detail-plugin.demo.relay.audit')),
    );
    await tester.pumpAndSettle();

    final Finder toggle = find.byKey(const Key('station-detail-toggle'));
    expect(tester.widget<Switch>(toggle).value, isTrue, reason: '缺键 = 默认启用');

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(admin.lastStationPatch, <String, dynamic>{'enabled': false});
    expect(
      tester.widget<Switch>(toggle).value,
      isFalse,
      reason: '写成功后用核心回的改后详情刷新（开关当场翻面）',
    );
    expect(find.textContaining('已停用（触发以可读原因跳过'), findsOneWidget);
  });
}
