import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

void main() {
  group('ApiMeta 编解码', () {
    test('发现面全字段往返', () {
      final Map<String, dynamic> json = <String, dynamic>{
        'core_version': '1.0.4',
        'api_version': '1.0',
        'ui_contract': treeUiContractVersion,
        'ui': <Map<String, dynamic>>[
          <String, dynamic>{
            'plugin_id': 'tree_ui_default',
            'version': '1.0.0',
            'capabilities': <String>['plugin.manage'],
            'connections': 2,
          },
        ],
        'can_manage_plugins': true,
        'routes': <Map<String, dynamic>>[
          <String, dynamic>{
            'method': 'GET',
            'pattern': '/api/files/{ws}',
            'owner': 'files',
          },
        ],
        'stations': <Map<String, dynamic>>[
          <String, dynamic>{
            'station_id': 'system.broadcast',
            'point': 'system.broadcast',
            'owner_plugin_id': 'core',
            'description': '通用公告板',
          },
        ],
        'capabilities': <Object?>[
          <String, dynamic>{'name': 'remote-ui', 'since': 1},
        ],
      };

      final ApiMeta meta = ApiMeta.fromJson(json);
      expect(meta.coreVersion, '1.0.4');
      expect(meta.apiVersion, '1.0');
      expect(meta.uiContract, treeUiContractVersion);
      expect(meta.ui, hasLength(1));
      expect(meta.ui.single.pluginId, 'tree_ui_default');
      expect(meta.ui.single.version, '1.0.0');
      expect(meta.ui.single.capabilities, <String>['plugin.manage']);
      expect(meta.ui.single.connections, 2);
      expect(meta.canManagePlugins, isTrue);
      expect(meta.routes.single.method, 'GET');
      expect(meta.routes.single.pattern, '/api/files/{ws}');
      expect(meta.routes.single.owner, 'files');
      expect(meta.stations.single.stationId, 'system.broadcast');
      expect(meta.stations.single.point, 'system.broadcast');
      expect(meta.stations.single.ownerPluginId, 'core');
      expect(meta.stations.single.description, '通用公告板');
      expect(meta.capabilities, hasLength(1));

      expect(meta.toJson(), json);
    });

    test('空回包取默认值（老核心 / 尚未聚合）', () {
      final ApiMeta meta = ApiMeta.fromJson(<String, dynamic>{});
      expect(meta.coreVersion, '');
      expect(meta.apiVersion, '');
      expect(meta.uiContract, '', reason: '老核心没给 ui_contract 时留空串');
      expect(meta.ui, isEmpty);
      expect(meta.canManagePlugins, isFalse);
      expect(meta.routes, isEmpty);
      expect(meta.stations, isEmpty);
      expect(meta.capabilities, isEmpty);

      expect(meta.toJson(), <String, dynamic>{
        'core_version': '',
        'api_version': '',
        'ui_contract': '',
        'ui': <Map<String, dynamic>>[],
        'can_manage_plugins': false,
        'routes': <Map<String, dynamic>>[],
        'stations': <Map<String, dynamic>>[],
        'capabilities': <Object?>[],
      });
    });

    test('未知字段忽略，坏列表条目跳过', () {
      final ApiMeta meta = ApiMeta.fromJson(<String, dynamic>{
        'core_version': '2.0.0',
        'future_field': 'ignored',
        'ui': <Object?>[
          'not-a-map',
          <String, dynamic>{'plugin_id': 'ui_a'},
        ],
        'routes': 'not-a-list',
        'capabilities': <Object?>[
          <String, dynamic>{'x': 1},
          null,
          'plain',
        ],
      });

      expect(meta.coreVersion, '2.0.0');
      expect(meta.ui, hasLength(1));
      expect(meta.ui.single.pluginId, 'ui_a');
      expect(meta.routes, isEmpty);
      // capability 原样透传（不转换、不丢弃元素）。
      expect(meta.capabilities, <Object?>[
        <String, dynamic>{'x': 1},
        null,
        'plain',
      ]);

      final Map<String, dynamic> out = meta.toJson();
      expect(out.containsKey('future_field'), isFalse);
    });

    test('can_manage_plugins 只认 true，其它值一律 false', () {
      expect(
        ApiMeta.fromJson(<String, dynamic>{'can_manage_plugins': 1})
            .canManagePlugins,
        isFalse,
      );
      expect(
        ApiMeta.fromJson(<String, dynamic>{'can_manage_plugins': true})
            .canManagePlugins,
        isTrue,
      );
    });

    test('station 可选字段缺省时序列化省略', () {
      const ApiMetaStation station = ApiMetaStation(
        stationId: 'system.broadcast',
      );
      expect(station.toJson(), <String, dynamic>{
        'station_id': 'system.broadcast',
      });
      expect(
        ApiMetaStation.fromJson(station.toJson()).stationId,
        'system.broadcast',
      );
    });
  });
}
