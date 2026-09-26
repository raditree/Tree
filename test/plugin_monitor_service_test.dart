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
      final PluginStationInfo? st = PluginStationInfo.tryParse(
        <String, dynamic>{
          'station_id': 'tool.read.result',
          'counts': <dynamic, dynamic>{
            'requests': 1,
            'weird': 'text',
            'timeout': 2.0,
            3: 4, // 非字符串键：忽略
          },
        },
      );
      expect(st, isNotNull);
      expect(st!.counts['requests'], 1);
      expect(st.counts['timeout'], 2);
      expect(st.counts.containsKey('weird'), isFalse);
    });

    test(
      '站点字段（M9 §3）：kind / kind_label / builtin / subscriber_count / scope',
      () {
        final PluginStationInfo? st = PluginStationInfo.tryParse(
          <String, dynamic>{
            'station_id': 'system.broadcast@team-1@local',
            'kind': 'broadcast',
            'kind_label': '广播站',
            'description': '广播站（系统自带）：插件发布 topic → 多订阅者接收 + 持久公告板',
            'scope': <String, dynamic>{
              'team_id': 'team-1',
              'agent_id': '',
              'session_id': '',
              'mode_key': 'local',
            },
            'builtin': true,
            'subscriber_count': 0,
            'subscriptions': <dynamic>[],
          },
        );
        expect(st, isNotNull);
        expect(st!.kind, 'broadcast');
        expect(st.kindLabel, '广播站');
        expect(st.displayKindLabel, '广播站');
        expect(st.builtin, isTrue);
        expect(st.subscriberCount, 0);
        expect(st.description, contains('持久公告板'));
        expect(st.scope['mode_key'], 'local');
      },
    );

    test('站点旧核心兼容：缺 kind_label 按线名兜底、subscriber_count 回退订阅数、未知 kind 不臆测', () {
      final PluginStationInfo? relay = PluginStationInfo.tryParse(
        <String, dynamic>{
          'station_id': 'system.relay@team-1@ssh',
          'kind': 'relay',
          'scope': <String, dynamic>{'team_id': 'team-1', 'mode_key': 'ssh'},
          'subscriptions': <dynamic>[
            <String, dynamic>{'subscriber': 'p1|team-1||ssh'},
          ],
        },
      );
      expect(relay!.kindLabel, isEmpty, reason: '老核心没有 kind_label');
      expect(relay.displayKindLabel, '中转站', reason: '按线名兜底出中文名');
      expect(relay.builtin, isFalse, reason: '缺失按 false，不臆测"内置"');
      expect(relay.subscriberCount, 1, reason: '缺失回退订阅列表长度');

      final PluginStationInfo? unknown = PluginStationInfo.tryParse(
        <String, dynamic>{'station_id': 'x', 'kind': 'future_kind'},
      );
      expect(unknown!.displayKindLabel, isEmpty, reason: '认不出的类型不猜中文名');
    });

    test('插件配置路径：config.path 优先，顶层 plugin_config 兜底，缺失为空串', () {
      final PluginSnapshot withConfig = PluginSnapshot.fromJson(
        <String, dynamic>{
          'config': <String, dynamic>{'path': 'C:/data/config/plugins.yaml'},
        },
      );
      expect(withConfig.pluginConfigPath, 'C:/data/config/plugins.yaml');

      final PluginSnapshot legacy = PluginSnapshot.fromJson(<String, dynamic>{
        'plugin_config': 'D:/tree/config/plugins.yaml',
      });
      expect(legacy.pluginConfigPath, 'D:/tree/config/plugins.yaml');

      final PluginSnapshot none = PluginSnapshot.fromJson(<String, dynamic>{});
      expect(none.pluginConfigPath, isEmpty);
      // copyWith（增量合并路径）不得把路径丢掉
      expect(
        none.copyWith(instances: const <PluginInstanceInfo>[]).pluginConfigPath,
        isEmpty,
      );
      expect(
        withConfig
            .copyWith(instances: const <PluginInstanceInfo>[])
            .pluginConfigPath,
        'C:/data/config/plugins.yaml',
      );
    });

    test('实例键组合：不同 scope 不混淆', () {
      final String k1 = PluginInstanceInfo.keyOf('p', <String, dynamic>{
        'team_id': 't',
        'agent_id': 'a1',
      });
      final String k2 = PluginInstanceInfo.keyOf('p', <String, dynamic>{
        'team_id': 't',
        'agent_id': 'a2',
      });
      expect(k1, isNot(k2));
    });

    test('健康度解析（M9 §1.1）：degraded 是心跳丢失，不是停用', () {
      final PluginSnapshot s = PluginSnapshot.fromJson(<String, dynamic>{
        'enabled': true,
        'instances': <dynamic>[
          <String, dynamic>{
            'plugin_id': 'demo.deaf',
            'scope': <String, dynamic>{'team_id': 't1'},
            'status': 'registered',
            'health': 'degraded',
            'missed_heartbeats': 3,
            'heartbeat_interval_s': 10.0,
            'degraded_reason': '心跳丢失：连续 3 拍未达',
            'disabled_reason': '',
          },
          <String, dynamic>{
            'plugin_id': 'demo.ok',
            'scope': <String, dynamic>{'team_id': 't1'},
            'status': 'registered',
            'health': 'ok',
            'missed_heartbeats': 0,
            'heartbeat_interval_s': 10.0,
          },
        ],
        'watchdog': <String, dynamic>{
          'active_runs': 0,
          'judged_dead': 0,
          'degraded_count': 1,
          'interval_s': 10,
          'miss_threshold': 3,
        },
      });
      expect(s.instances, hasLength(2));
      final PluginInstanceInfo deaf = s.instances.first;
      expect(deaf.status, 'registered'); // 降级 ≠ 停用
      expect(deaf.health, PluginInstanceInfo.healthDegraded);
      expect(deaf.isDegraded, isTrue);
      expect(deaf.missedHeartbeats, 3);
      expect(deaf.heartbeatIntervalS, 10.0);
      expect(deaf.degradedReason, contains('心跳丢失'));
      expect(deaf.disabledReason, isEmpty); // 不得落到"停用原因"
      expect(s.instances[1].isDegraded, isFalse);
      expect(s.watchdog?.degradedCount, 1);
      expect(s.watchdog?.missThreshold, 3);
    });

    test('缺健康度字段 → 未知（hasHealth=false），不臆测降级', () {
      final PluginSnapshot s = PluginSnapshot.fromJson(<String, dynamic>{
        'instances': <dynamic>[
          <String, dynamic>{'plugin_id': 'legacy', 'status': 'registered'},
          <String, dynamic>{
            'plugin_id': 'bad-type',
            'status': 'registered',
            'health': 42, // 非字符串：视为缺失
            'missed_heartbeats': 'oops',
            'heartbeat_interval_s': null,
          },
        ],
      });
      for (final PluginInstanceInfo e in s.instances) {
        expect(e.hasHealth, isFalse);
        expect(e.isDegraded, isFalse);
        expect(e.health, '');
        expect(e.missedHeartbeats, isNull);
        expect(e.heartbeatIntervalS, isNull);
      }
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
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
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
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
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
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
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
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
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
        'data': <String, dynamic>{
          'plugin_id': 'demo.b',
          'status': 'registered',
        },
      });
      expect(svc.snapshot, isNull);
    });

    test('团队过滤：teamId 已设置时忽略其他团队事件；缺 team_id 不拒绝', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
        teamId: 't1',
      );
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
        'data': <String, dynamic>{
          'plugin_id': 'demo.y',
          'status': 'registered',
        },
      });
      expect(svc.snapshot!.instances, hasLength(2)); // 缺失不拒绝
    });

    test('registered + health=degraded：status 仍是 registered（不误判停用）', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered', // 核心口径：降级不改 status
          'health': 'degraded',
          'reason': '心跳丢失：连续 3 拍未达',
          'missed_heartbeats': 3,
          'heartbeat_interval_s': 10.0,
          'ts': 1789290200.0,
        },
      });
      final PluginInstanceInfo e = svc.snapshot!.instances.first;
      expect(e.status, 'registered');
      expect(e.isDegraded, isTrue);
      expect(e.health, 'degraded');
      expect(e.missedHeartbeats, 3);
      expect(e.heartbeatIntervalS, 10.0);
      expect(e.degradedReason, contains('心跳丢失'));
      expect(e.disabledReason, isEmpty); // reason 不得误落成停用原因
      // 实例键不变：没有变成第二条实例
      expect(svc.snapshot!.instances, hasLength(1));
    });

    test('degraded 增量新建未知实例：带健康度落库（status 仍 registered）', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        <String, dynamic>{'enabled': true, 'instances': <dynamic>[]},
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.new',
          'scope': <String, dynamic>{'team_id': 't1'},
          'status': 'registered',
          'health': 'degraded',
          'reason': '连续 3 拍未达',
          'missed_heartbeats': 4,
          'heartbeat_interval_s': 10.0,
        },
      });
      final PluginInstanceInfo e = svc.snapshot!.instances.single;
      expect(e.status, 'registered');
      expect(e.isDegraded, isTrue);
      expect(e.missedHeartbeats, 4);
      expect(e.degradedReason, '连续 3 拍未达');
    });

    test('registered + health=ok：降级恢复，角标与计数清零', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered',
          'health': 'degraded',
          'reason': '连续 3 拍未达',
          'missed_heartbeats': 3,
        },
      });
      expect(svc.snapshot!.instances.first.isDegraded, isTrue);
      // 心跳恢复（核心的恢复增量：degraded=false、missed=0）
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered',
          'health': 'ok',
          'missed_heartbeats': 0,
        },
      });
      final PluginInstanceInfo e = svc.snapshot!.instances.first;
      expect(e.status, 'registered');
      expect(e.isDegraded, isFalse);
      expect(e.health, 'ok');
      expect(e.degradedReason, isEmpty); // 不残留
      expect(e.missedHeartbeats, 0);
    });

    test('registered 增量缺 health：保持原健康度（不臆测、不清零）', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered',
          'health': 'degraded',
          'reason': '连续 3 拍未达',
          'missed_heartbeats': 5,
        },
      });
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered', // 没有 health 字段
        },
      });
      final PluginInstanceInfo e = svc.snapshot!.instances.first;
      expect(e.isDegraded, isTrue);
      expect(e.missedHeartbeats, 5); // 保持
      expect(e.degradedReason, '连续 3 拍未达');
    });

    test('disabled：清降级标记并按快照口径落 unavailable', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered',
          'health': 'degraded',
          'reason': '连续 3 拍未达',
          'missed_heartbeats': 3,
        },
      });
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'disabled',
          'reason': '启动失败',
        },
      });
      final PluginInstanceInfo e = svc.snapshot!.instances.first;
      expect(e.status, 'disabled');
      expect(e.disabledReason, '启动失败');
      expect(e.isDegraded, isFalse);
      expect(e.degradedReason, isEmpty);
      expect(e.health, PluginInstanceInfo.healthUnavailable);
    });

    test('未知 health 值原样保留、不崩（防御式）', () async {
      final PluginMonitorService svc = await _serviceWithSnapshot(
        _snapshotData(),
      );
      svc.handleMessage(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
          'status': 'registered',
          'health': 'melted',
        },
      });
      final PluginInstanceInfo e = svc.snapshot!.instances.first;
      expect(e.health, 'melted');
      expect(e.isDegraded, isFalse); // 未知值 ≠ 降级
      expect(e.status, 'registered');
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

      svc.snapshotFetcher = ({String? teamId}) async => <String, dynamic>{
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
