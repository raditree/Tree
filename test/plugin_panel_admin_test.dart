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
        'description': '核心自带的示例插件（Python）',
        'script': 'sample_plugin.py',
        'runtime': 'python',
        'granularity': 'team',
        'scope': <String, dynamic>{},
        'enabled': false,
        'configured': true,
        'config': <String, dynamic>{
          'id': 'sample',
          'name': '示例插件',
          'command': 'python',
          'args': <String>['C:/app/plugins/sample_plugin.py'],
          'enabled': false,
          'granularity': 'team',
          'scope': <String, dynamic>{},
          'builtin': true,
        },
        'resolution': <String, dynamic>{
          'ok': true,
          'command': 'python',
          'script_path': 'C:/app/plugins/sample_plugin.py',
        },
      },
    ],
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
  Future<Map<String, dynamic>> restartConfig(String id) async {
    calls.add('restart:$id');
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

void main() {
  testWidgets('插件实例分「内置 / 自定义」两组，每一项各有自己的开关', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

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
    // 清单真实路径与生效方式必须显示
    expect(
      find.textContaining('清单文件：C:/data/config/plugins.yaml'),
      findsOneWidget,
    );
    expect(find.textContaining('保存后立即热应用；热应用失败时重启核心生效'), findsOneWidget);
  });

  testWidgets('每项开关各自打各自的接口', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

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
    await tester.tap(find.byKey(const Key('plugin-switch-custom-demo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置已保存，但本次热应用失败，重启核心后生效'), findsOneWidget);
    expect(find.textContaining('新增条目'), findsOneWidget);
  });

  testWidgets('写操作失败：面板显示核心的可读原因', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin()..failWrite = '插件 demo 的 command 不能为空';
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);
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

    // 3) 填齐（参数每行一个 / 环境变量每行一个 / scope 留空 = 通配）→ 保存 → 二次确认
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
    expect(body['scope'], <String, String>{'session_id': 's1'});
    expect(body['granularity'], 'team');
    expect(body['enabled'], isTrue);
  });

  testWidgets('删除要二次确认，确认后才发请求', (WidgetTester tester) async {
    final _FakeAdmin admin = _FakeAdmin();
    await _pumpPanel(tester, svc: await _serviceWith(), admin: admin);

    await tester.tap(find.byKey(const Key('plugin-delete-demo')));
    await tester.pumpAndSettle();
    expect(find.text('删除插件？'), findsOneWidget);
    expect(admin.calls, isEmpty, reason: '确认之前不发请求');

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

    expect(find.textContaining('插件清单接口不可用'), findsOneWidget);
    expect(find.text('插件实例（1）'), findsOneWidget);
    expect(find.text('已注册'), findsOneWidget);
    expect(find.text('样例插件'), findsOneWidget);
  });
}
