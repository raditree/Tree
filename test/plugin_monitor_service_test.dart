// 插件监控服务单元测试（M1 右栏「插件」面板数据源）。
//
// 覆盖三个兼容性关注点（与知遥矩阵 CP1/CP2/CP3、§7 对齐）：
// - CP1 未知事件类型忽略：WS 消息中的未知/畸形载荷喂入 → 零状态变化、零异常；
// - CP2 缺字段/未知 status 容错：快照与 status 的防御式解析（坏条目跳过）；
// - CP3 断连态 vs 空态区分：连接态为显式字段；重连自动重拉快照；错误不丢旧数据。
// 说明：start()/stop() 依赖真实 WS 与登录态，不做单测（由知遥 E2E 清单兜底）；
// 本文件直接驱动 handleMessage / handleConnectionChange / refresh 三个接缝。
// 运行方式（项目根目录）：
//   flutter test test/plugin_monitor_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/plugin_monitor_service.dart';

/// 构造一份最小可用快照数据（含 1 个实例）。
Map<String, dynamic> _snapshotData() => <String, dynamic>{
      'enabled': true,
      'instances': <dynamic>[
        <String, dynamic>{
          'plugin_id': 'demo.a',
          'granularity': 'agent',
          'scope': <String, dynamic>{
            'user_id': 'u1',
            'team_id': 't1',
            'agent_id': 'a1',
            'session_id': '',
          },
          'status': 'registered',
        },
      ],
      'stations': <dynamic>[],
      'watchdog': <String, dynamic>{'active_runs': 0, 'judged_dead': 0},
    };

/// 构造一个已注入 [data] 并完成一次刷新的测试服务。
Future<PluginMonitorService> _serviceWithSnapshot(
  Map<String, dynamic> data, {
  String teamId = '',
}) async {
  final PluginMonitorService svc = PluginMonitorService.forTesting();
  if (teamId.isNotEmpty) {
    svc.setTeam(teamId);
  }
  svc.snapshotFetcher = ({String? teamId}) async => data;
  await svc.refresh();
  return svc;
}

void main() {
  group('快照防御式解析（CP2）', () {
    test('完整快照解析：实例/站/看门狗/配置', () {
      final PluginSnapshot s = PluginSnapshot.fromJson(<String, dynamic>{
        'enabled': true,
        'generated_at': 1789290000.0,
        'instances': <dynamic>[
          <String, dynamic>{
            'plugin_id': 'demo.read_station',
            'name': '读站示范',
            'granularity': 'agent',
            'scope': <String, dynamic>{
              'user_id': 'u1',
              'team_id': 't1',
              'agent_id': 'a1',
              'session_id': '',
            },
            'status': 'registered',
            'last_heartbeat': 1789290000.0,
            'queue_depth': 2,
            'disabled_reason': '',
          },
        ],
        'stations': <dynamic>[
          <String, dynamic>{
            'station_id': 'tool.read.result',
            'subscriptions': <dynamic>[
              <String, dynamic>{
                'subscriber': 'demo.read_station|t1|a1|',
                'plugin_id': 'demo.read_station',
                'granularity': 'agent',
                'scope': <String, dynamic>{},
                'timeout_s': 30.0,
              },
            ],
            'counts': <String, dynamic>{'requests': 3, 'responded': 2},
            'gauges': <String, dynamic>{'waits_in_flight': 1},
          },
        ],
        'watchdog': <String, dynamic>{'active_runs': 1, 'judged_dead': 0},
        'config': <String, dynamic>{'station_timeout_s': 30},
      });
      expect(s.enabled, isTrue);
      expect(s.instances, hasLength(1));
      expect(s.instances.first.name, '读站示范');
      expect(s.instances.first.queueDepth, 2);
      expect(s.stations, hasLength(1));
      expect(s.stations.first.counts['requests'], 3);
      expect(s.stations.first.waitsInFlight, 1);
      expect(s.stations.first.subscriptions, hasLength(1));
      expect(s.watchdog?.activeRuns, 1);
      expect(s.config['station_timeout_s'], 30);
    });

    test('缺字段/错误类型/空对象 → 默认值，不抛错', () {
      final PluginSnapshot s = PluginSnapshot.fromJson(<String, dynamic>{});
      expect(s.enabled, isFalse);
      expect(s.generatedAt, isNull);
      expect(s.instances, isEmpty);
      expect(s.stations, isEmpty);
      expect(s.watchdog, isNull);
      expect(s.config, isEmpty);

      final PluginSnapshot s2 = PluginSnapshot.fromJson(<String, dynamic>{
        'enabled': 'yes', // 非 bool：按 false
        'instances': 'oops', // 非 List：空
        'stations': <dynamic>[42, 'x'], // 坏条目跳过
        'watchdog': 'oops', // 非 Map → null
        'config': 7, // 非 Map → 空
      });
      expect(s2.enabled, isFalse);
      expect(s2.instances, isEmpty);
      expect(s2.stations, isEmpty);
      expect(s2.watchdog, isNull);
      expect(s2.config, isEmpty);
    });

    test('实例坏条目跳过；缺 plugin_id 丢弃；未知字段忽略', () {
      final PluginSnapshot s = PluginSnapshot.fromJson(<String, dynamic>{
        'instances': <dynamic>[
          <String, dynamic>{'plugin_id': ''}, // 空 id 丢弃
          <String, dynamic>{'name': '无名'}, // 缺 id 丢弃
          'not-a-map', // 非 Map 丢弃
          <String, dynamic>{
            'plugin_id': 'ok',
            'unknown_field': <String, dynamic>{'deep': true}, // 未知字段忽略
          },
        ],
      });
      expect(s.instances, hasLength(1));
      expect(s.instances.first.pluginId, 'ok');
      expect(s.instances.first.granularity, '');
      expect(s.instances.first.lastHeartbeat, isNull);
    });

    test('counts 混入非数值键值 → 仅保留数值项', () {
      final PluginStationInfo? st =
          PluginStationInfo.tryParse(<String, dynamic>{
        'station_id': 'tool.read.result',
        'counts': <dynamic, dynamic>{
          'requests': 1,
          'weird': 'text',
          'timeout': 2.0,
          3: 4, // 非字符串键：忽略
        },
      });
      expect(st, isNotNull);
      expect(st!.counts['requests'], 1);
      expect(st.counts['timeout'], 2);
      expect(st.counts.containsKey('weird'), isFalse);
    });

    test('实例键组合：不同 scope 不混淆', () {
      final String k1 = PluginInstanceInfo.keyOf(
        'p',
        <String, dynamic>{'team_id': 't', 'agent_id': 'a1'},
      );
      final String k2 = PluginInstanceInfo.keyOf(
        'p',
        <String, dynamic>{'team_id': 't', 'agent_id': 'a2'},
      );
      expect(k1, isNot(k2));
    });
  });

  group('status 增量合并（CP1/CP2）', () {
    test('registered：新增实例', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        <String, dynamic>{'enabled': true, 'instances': <dynamic>[]},
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.b',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a2'},
          'status': 'registered',
          'ts': 1789290100.0,
        },
      });
      expect(svc.snapshot!.instances, hasLength(1));
      expect(svc.snapshot!.instances.first.pluginId, 'demo.b');
      expect(svc.snapshot!.instances.first.status, 'registered');
      expect(svc.snapshot!.instances.first.lastHeartbeat, 1789290100.0);
    });

    test('registered：已存在实例不重复添加（按实例键对齐）', () async {
      final PluginMonitorService svc =
          await _serviceWithSnapshot(_snapshotData());
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{
            'team_id': 't1',
            'agent_id': 'a1',
            'session_id': '',
          },
          'status': 'registered',
        },
      });
      expect(svc.snapshot!.instances, hasLength(1));
    });

    test('disabled：更新状态与原因', () async {
      final PluginMonitorService svc =
          await _serviceWithSnapshot(_snapshotData());
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'disabled',
          'reason': '连续失败',
        },
      });
      expect(svc.snapshot!.instances.first.status, 'disabled');
      expect(svc.snapshot!.instances.first.disabledReason, '连续失败');
    });

    test('destroyed：移除实例', () async {
      final PluginMonitorService svc =
          await _serviceWithSnapshot(_snapshotData());
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'destroyed',
        },
      });
      expect(svc.snapshot!.instances, isEmpty);
    });

    test('未知消息类型/未知 status/畸形 data → 忽略且不抛错（CP1/CP2）', () async {
      final PluginMonitorService svc =
          await _serviceWithSnapshot(_snapshotData());
      svc.handleMessage(<String, dynamic>{'type': 'plugin_event'}); // 未知类型
      svc.handleMessage(<String, dynamic>{'type': 'msg_chunk'});
      svc.handleMessage(<String, dynamic>{'type': 42}); // 非字符串 type
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': 'oops', // 畸形 data
      });
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{'plugin_id': '', 'status': 'registered'},
      }); // 空 id
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{'plugin_id': 'demo.a', 'status': 'melted'},
      }); // 未知 status
      expect(svc.snapshot!.instances, hasLength(1)); // 零状态变化
      expect(svc.snapshot!.instances.first.status, 'registered');
    });

    test('快照未就绪时忽略增量（以快照为准）', () {
      final PluginMonitorService svc = PluginMonitorService.forTesting();
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{'plugin_id': 'demo.b', 'status': 'registered'},
      });
      expect(svc.snapshot, isNull);
    });

    test('团队过滤：teamId 已设置时忽略其他团队事件；缺 team_id 不拒绝', () async {
      final PluginMonitorService svc =
          await _serviceWithSnapshot(_snapshotData(), teamId: 't1');
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.z',
          'scope': <String, dynamic>{'team_id': 't2'},
          'status': 'registered',
        },
      });
      expect(svc.snapshot!.instances, hasLength(1)); // 跨团队被忽略
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{'plugin_id': 'demo.y', 'status': 'registered'},
      });
      expect(svc.snapshot!.instances, hasLength(2)); // 缺失不拒绝
    });
  });

  group('连接态与三态区分（CP3）', () {
    test('初始未连接；连接/断开状态显式切换', () {
      final PluginMonitorService svc = PluginMonitorService.forTesting();
      expect(svc.connected, isFalse); // 断连态（与空态区分）
      svc.handleConnectionChange(true);
      expect(svc.connected, isTrue);
      svc.handleConnectionChange(false);
      expect(svc.connected, isFalse);
    });

    test('重连（false→true）自动重拉快照；首连不重复拉', () async {
      final PluginMonitorService svc = PluginMonitorService.forTesting();
      int calls = 0;
      svc.snapshotFetcher = ({String? teamId}) async {
        calls++;
        return <String, dynamic>{'enabled': true, 'instances': <dynamic>[]};
      };
      svc.handleConnectionChange(true); // 首连：由 start() 负责拉取，此处不拉
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 0);

      svc.handleConnectionChange(false);
      svc.handleConnectionChange(true); // 重连：自动重拉
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1);
      expect(svc.snapshot, isNotNull);
    });

    test('拉取失败 → error 置位且保留旧快照（错误态不丢数据）', () async {
      final PluginMonitorService svc = PluginMonitorService.forTesting();
      svc.snapshotFetcher = ({String? teamId}) async => _snapshotData();
      await svc.refresh();
      expect(svc.snapshot, isNotNull);
      expect(svc.error, isNull);

      svc.snapshotFetcher = ({String? teamId}) async {
        throw Exception('后端未启动');
      };
      await svc.refresh();
      expect(svc.error, contains('后端未启动'));
      expect(svc.snapshot, isNotNull); // 旧数据保留
      expect(svc.snapshot!.instances, hasLength(1));

      svc.snapshotFetcher =
          ({String? teamId}) async => <String, dynamic>{
                'enabled': false,
                'instances': <dynamic>[],
              };
      await svc.refresh();
      expect(svc.error, isNull); // 成功清空错误
      expect(svc.snapshot!.enabled, isFalse);
    });

    test('断连态与空态可由 (connected, snapshot) 组合区分', () async {
      final PluginMonitorService svc = PluginMonitorService.forTesting();
      svc.snapshotFetcher = ({String? teamId}) async => <String, dynamic>{
            'enabled': true,
            'instances': <dynamic>[],
            'stations': <dynamic>[],
          };
      await svc.refresh();
      expect(svc.connected, isFalse); // 断连态：未连接（即使已有快照）
      expect(svc.snapshot, isNotNull);
      svc.handleConnectionChange(true);
      expect(svc.connected, isTrue); // 空态：连接正常 + 空数据
      expect(svc.snapshot!.instances, isEmpty);
      expect(svc.snapshot!.stations, isEmpty);
    });
  });
}
