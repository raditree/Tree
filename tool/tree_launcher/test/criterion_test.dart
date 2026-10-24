import 'package:test/test.dart';
import 'package:tree_launcher/src/criterion.dart';

void main() {
  Map<String, dynamic> meta(List<Map<String, dynamic>> ui) => <String, dynamic>{
    'ui': ui,
  };

  Map<String, dynamic> uiEntry({
    String id = 'editor',
    int connections = 1,
    List<String> capabilities = const <String>['plugin.manage'],
  }) => <String, dynamic>{
    'plugin_id': id,
    'connections': connections,
    'capabilities': capabilities,
  };

  group('引导壳判据（纯函数）', () {
    test('零连接 ⇒ 开引导页', () {
      expect(needsBootstrap(meta(const <Map<String, dynamic>>[])), isTrue);
      expect(needsBootstrap(<String, dynamic>{}), isTrue);
      expect(needsBootstrap(null), isTrue);
    });

    test('只剩不具备 plugin.manage 的 UI ⇒ 开引导页', () {
      expect(
        needsBootstrap(meta(<Map<String, dynamic>>[
          uiEntry(capabilities: <String>['viewer']),
        ])),
        isTrue,
      );
    });

    test('有存活且声明 plugin.manage 的 UI ⇒ 不开', () {
      expect(needsBootstrap(meta(<Map<String, dynamic>>[uiEntry()])), isFalse);
    });

    test('连接数为 0 的 plugin.manage 条目不算存活', () {
      expect(
        needsBootstrap(meta(<Map<String, dynamic>>[uiEntry(connections: 0)])),
        isTrue,
      );
    });

    test('能力条目被停用 ⇒ 开引导页（即使还挂着连接）', () {
      expect(
        needsBootstrap(
          meta(<Map<String, dynamic>>[uiEntry()]),
          disabledPluginIds: <String>{'editor'},
        ),
        isTrue,
      );
      expect(
        needsBootstrap(
          meta(<Map<String, dynamic>>[
            uiEntry(),
            uiEntry(id: 'second'),
          ]),
          disabledPluginIds: <String>{'editor'},
        ),
        isFalse,
      );
    });

    test('坏数据按零连接处理（fail-open 到引导页）', () {
      expect(
        needsBootstrap(<String, dynamic>{
          'ui': <Object?>[null, 'x', <String, dynamic>{'connections': 'many'}],
        }),
        isTrue,
      );
    });

    test('从 snapshot 配置收集被停用插件 id', () {
      final Set<String> disabled = disabledPluginIdsOf(<String, dynamic>{
        'config': <String, dynamic>{
          'plugins': <Object?>[
            <String, dynamic>{'id': 'a', 'enabled': false},
            <String, dynamic>{'id': 'b', 'enabled': true},
            <String, dynamic>{'id': 'c'},
          ],
        },
      });
      expect(disabled, <String>{'a'});
    });

    test('停用信息缺失 ⇒ 空集合', () {
      expect(disabledPluginIdsOf(null), isEmpty);
      expect(disabledPluginIdsOf(<String, dynamic>{}), isEmpty);
    });

    test('快捷方式只接受 role=exe 的 .ico 本地路径', () {
      final Map<String, dynamic> metaJson = <String, dynamic>{
        'branding': <String, dynamic>{
          'role': 'exe',
          'icon': r'C:\plugins\ui\brand.ico',
        },
      };
      expect(shortcutIconOf(metaJson), r'C:\plugins\ui\brand.ico');
      expect(
        shortcutIconOf(<String, dynamic>{
          'branding': <String, dynamic>{
            'role': 'exe',
            'icon': r'C:\plugins\ui\brand.png',
          },
        }),
        isNull,
        reason: '快捷方式只认 ico',
      );
      expect(
        shortcutIconOf(<String, dynamic>{
          'branding': <String, dynamic>{
            'role': 'window',
            'icon': r'C:\plugins\ui\brand.ico',
          },
        }),
        isNull,
        reason: '窗口图标由 UI 自己应用，不走快捷方式',
      );
      expect(shortcutIconOf(null), isNull);
      expect(shortcutIconOf(<String, dynamic>{}), isNull);
    });
  });
}
