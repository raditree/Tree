import 'package:test/test.dart';
import 'package:tree_launcher/src/criterion.dart';

void main() {
  Map<String, dynamic> snapshot(List<Object?> plugins) => <String, dynamic>{
    'config': <String, dynamic>{'plugins': plugins},
  };

  // 快照里 `config.plugins[]` 的 id 键名是 `plugin_id`（核心 `toApiJson()`），
  // 夹具按**真实形状**造，避免判据读错键名还能“测绿”。
  Map<String, dynamic> plugin({
    String id = 'tree.ui.default',
    String runtime = 'ui',
    bool? enabled,
  }) => <String, dynamic>{
    'plugin_id': id,
    'runtime': runtime,
    if (enabled != null) 'enabled': enabled,
  };

  group('引导壳判据（配置口径）', () {
    test('有启用的 ui 插件 ⇒ 不开引导页', () {
      expect(needsBootstrapByConfig(snapshot(<Object?>[plugin()])), isFalse);
    });

    test('老口径的 `id` 键也要认得（兼容手写清单/旧快照）', () {
      expect(
        needsBootstrapByConfig(
          snapshot(<Object?>[
            <String, dynamic>{'id': 'tree.ui.default', 'runtime': 'ui'},
          ]),
        ),
        isFalse,
      );
    });

    test('ui 插件被停用 ⇒ 开引导页（已下载但停用也算“不存在”）', () {
      expect(
        needsBootstrapByConfig(
          snapshot(<Object?>[plugin(enabled: false)]),
        ),
        isTrue,
      );
    });

    test('只有 headless 插件 ⇒ 开引导页', () {
      expect(
        needsBootstrapByConfig(
          snapshot(<Object?>[plugin(runtime: 'headless', id: 'compact')]),
        ),
        isTrue,
      );
    });

    test('多个条目里只要有一条启用的 ui ⇒ 不开', () {
      expect(
        needsBootstrapByConfig(
          snapshot(<Object?>[
            plugin(runtime: 'headless', id: 'compact'),
            plugin(id: 'second', enabled: false),
            plugin(id: 'third'),
          ]),
        ),
        isFalse,
      );
    });

    test('runtime 大小写与空白不影响判定', () {
      expect(
        needsBootstrapByConfig(snapshot(<Object?>[plugin(runtime: ' UI ')])),
        isFalse,
      );
    });

    test('读不到 config.plugins ⇒ 判据不下结论（返回 false，交给重试）', () {
      expect(needsBootstrapByConfig(null), isFalse);
      expect(needsBootstrapByConfig(<String, dynamic>{}), isFalse);
      expect(
        needsBootstrapByConfig(<String, dynamic>{
          'config': <String, dynamic>{},
        }),
        isFalse,
      );
      expect(snapshotReady(null), isFalse);
    });

    test('空清单是“读到了” ⇒ 开引导页', () {
      expect(snapshotReady(snapshot(const <Object?>[])), isTrue);
      expect(needsBootstrapByConfig(snapshot(const <Object?>[])), isTrue);
    });

    test('坏条目跳过，不影响好条目', () {
      expect(
        needsBootstrapByConfig(
          snapshot(<Object?>[null, 'x', <String, dynamic>{'runtime': 'ui'} , plugin()]),
        ),
        isFalse,
      );
    });

    test('收集启用中的 ui 插件 id', () {
      expect(
        enabledUiPluginIdsOf(
          snapshot(<Object?>[
            plugin(),
            plugin(id: 'second', enabled: false),
            plugin(runtime: 'headless', id: 'compact'),
          ]),
        ),
        <String>{'tree.ui.default'},
      );
      expect(enabledUiPluginIdsOf(null), isEmpty);
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
