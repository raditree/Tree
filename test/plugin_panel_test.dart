// 插件面板（左侧活动栏「插件」页）的站点段文案与卡片渲染。
//
// 背景（用户实机截图）：面板显示「处理站（0）／暂无处理站订阅」「插件实例（0）／
// 暂无插件实例」。核查结论是三条：
//   a) 内置站原本**懒创建**，没配插件就永远没有实例（核心侧已改为启动即预建）；
//   b) 插件来自 <数据根>/config/plugins.yaml，没配插件就是 0 实例——正常，
//      但面板得说清"插件配在哪"；
//   c) 面板还写着旧名「处理站」，空状态也没说清"按需创建 / 内置站"。
// 这个文件锁住 (b)(c) 两条前端修复：站点段改名 + 可操作空态 + 卡片用核心给的
// kind / kind_label / subscriber_count / scope / builtin。
//
// 运行方式（项目根目录）：
//   flutter test test/plugin_panel_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/plugin_monitor_service.dart';
import 'package:tree/ui/widgets/plugin_panel.dart';

/// 构造一个已注入快照数据的测试服务（不共享单例状态）。
Future<PluginMonitorService> _serviceWith(Map<String, dynamic> data) async {
  final PluginMonitorService svc = PluginMonitorService.forTesting();
  svc.snapshotFetcher = ({String? teamId}) async => data;
  await svc.refresh();
  return svc;
}

/// 渲染面板（数据源注入；面板自身在 initState 还会再刷一次，走同一个 fetcher）。
Future<void> _pumpPanel(WidgetTester tester, PluginMonitorService svc) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 900,
          child: PluginPanel(service: svc, showHeader: false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 站点快照条目（形状与核心 StationInstance.describe() 一致）。
Map<String, dynamic> _station(
  String id,
  String kind,
  String label, {
  bool builtin = true,
  int subscriberCount = 0,
  Map<String, dynamic> subscribersByTeam = const <String, dynamic>{},
}) => <String, dynamic>{
  'station_id': id,
  'kind': kind,
  'kind_label': label,
  'description': '$label（系统自带）：职责说明',
  // 站点全局化后仍带 scope 字段（兼容旧核心），但它不再参与展示；
  // team 视角走 subscribers_by_team。
  'scope': <String, dynamic>{
    'team_id': '',
    'agent_id': '',
    'session_id': '',
    'mode_key': '',
  },
  'builtin': builtin,
  'subscriber_count': subscriberCount,
  'subscriptions': <dynamic>[],
  'subscribers_by_team': subscribersByTeam,
  'counts': <String, dynamic>{'requests': 2},
  'gauges': <String, dynamic>{'waits_in_flight': 1},
};

void main() {
  testWidgets('站点段按四类分组列出，标题计数是"已建 N/4 类"', (
    WidgetTester tester,
  ) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[
        _station('system.broadcast', 'broadcast', '广播站'),
        _station('system.execute', 'execute', '执行站'),
        _station('system.relay', 'relay', '中转站'),
      ],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    // 计数不能是裸实例数：三站是实建数，体系本身是四类
    expect(find.text('站点（已建 3/4 类）'), findsOneWidget);
    expect(find.text('站点（3）'), findsNothing, reason: '裸实例数会被读成"只有三类站"');
    expect(find.textContaining('处理站'), findsNothing);
    // 分组头 + 卡片类型标签各出现一次（四类都要有分组头，含未创建的收集站）
    expect(find.text('广播站'), findsNWidgets(2));
    expect(find.text('执行站'), findsNWidgets(2));
    expect(find.text('中转站'), findsNWidgets(2));
    expect(
      find.text('收集站'),
      findsOneWidget,
      reason: '收集站未创建也要列出该类（按需创建，不是不存在）',
    );
    expect(
      find.text('未创建（该类站点按需创建）'),
      findsOneWidget,
      reason: '空类必须写明未创建，不能让用户以为该类站点不存在',
    );
    expect(find.text('内置'), findsNWidgets(3));
    // 站点 id 是全局常量（不再带 @team@mode 后缀）
    expect(find.text('system.broadcast'), findsOneWidget);
    expect(find.textContaining('@team-1@local'), findsNothing);
    // 订阅数用核心给的 subscriber_count；计数 pill 照旧
    expect(find.textContaining('订阅（0）'), findsNWidgets(3));
    expect(find.textContaining('requests: 2'), findsNWidgets(3));
    // 没有订阅者 ⇒ 不显示团队分组行
    expect(find.textContaining('团队:'), findsNothing);
  });

  testWidgets('四类站齐全时计数为 4/4，且没有"未创建"提示', (WidgetTester tester) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[
        _station('system.broadcast', 'broadcast', '广播站'),
        _station('system.execute', 'execute', '执行站'),
        _station('system.relay', 'relay', '中转站'),
        _station('plugin.tool.define', 'collect', '收集站', builtin: false),
      ],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    expect(find.text('站点（已建 4/4 类）'), findsOneWidget);
    expect(find.text('收集站'), findsNWidgets(2), reason: '分组头 + 卡片标签');
    expect(find.text('未创建（该类站点按需创建）'), findsNothing);
  });

  testWidgets('类型认不出的站点归入「其他」，不丢站点', (WidgetTester tester) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[
        // 旧核心不给 kind（空串）/ 将来新增的类型：都必须仍然显示出来
        _station('legacy.station', '', ''),
        _station('future.station', 'quantum', '量子站'),
      ],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    expect(find.text('其他（类型未知）'), findsOneWidget);
    expect(find.text('legacy.station'), findsOneWidget);
    expect(find.text('future.station'), findsOneWidget);
    expect(find.text('站点（已建 0/4 类）'), findsOneWidget, reason: '四类都没建');
  });

  testWidgets('站点卡片：订阅者按 team 分组显示（team 视角落在订阅声明上）', (
    WidgetTester tester,
  ) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[
        _station(
          'system.relay',
          'relay',
          '中转站',
          subscriberCount: 1,
          subscribersByTeam: <String, dynamic>{
            'team-1': <String, dynamic>{
              'count': 1,
              'plugin_ids': <String>['sample'],
            },
          },
        ),
      ],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    expect(find.text('团队: team-1（1）'), findsOneWidget);
  });

  testWidgets('站点卡片：订阅数与类型标签随核心字段变化（执行站不订阅）', (WidgetTester tester) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[
        _station(
          'system.broadcast@team-1@local',
          'broadcast',
          '广播站',
          subscriberCount: 2,
        ),
        _station(
          'system.execute@team-1@local',
          'execute',
          '执行站',
          subscriberCount: 0,
        ),
      ],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    expect(find.textContaining('订阅（2）'), findsOneWidget);
    expect(find.textContaining('订阅（0）'), findsOneWidget);
    expect(find.text('内置'), findsNWidgets(2));
  });

  testWidgets('站点段空态：说清四站全局各一个 + 插件配置路径', (WidgetTester tester) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    expect(find.text('站点（已建 0/4 类）'), findsOneWidget);
    expect(find.textContaining('内置四站（广播 / 执行 / 中转 / 收集）'), findsOneWidget);
    expect(find.textContaining('全局各一个'), findsOneWidget);
    expect(
      find.textContaining('team / session / agent 随每次交互携带'),
      findsOneWidget,
      reason: '口径改为"站点不分 team"',
    );
    expect(
      find.textContaining('插件配置：C:/data/config/plugins.yaml'),
      findsOneWidget,
    );
  });

  testWidgets('插件实例空态：给出插件配置路径与"保存后重启核心生效"', (WidgetTester tester) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[],
      'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
    });
    await _pumpPanel(tester, svc);

    expect(find.text('插件实例（0）'), findsOneWidget);
    expect(
      find.textContaining('插件配置在 C:/data/config/plugins.yaml（可直接编辑，保存后重启核心生效）'),
      findsOneWidget,
    );
  });

  testWidgets('缺插件配置路径（旧核心）：退回原句，不臆测路径', (WidgetTester tester) async {
    final PluginMonitorService svc = await _serviceWith(<String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[],
      'stations': <dynamic>[],
    });
    await _pumpPanel(tester, svc);

    // 段内空态 + 折叠区提示都会出现「暂无插件实例」（两处文案同一个短句）
    expect(find.text('暂无插件实例'), findsWidgets);
    expect(find.textContaining('插件配置在'), findsNothing);
    expect(find.textContaining('内置四站'), findsOneWidget, reason: '站点段空态仍给说明');
    expect(find.textContaining('插件配置：'), findsNothing, reason: '没有路径就不显示那一行');
  });
}
