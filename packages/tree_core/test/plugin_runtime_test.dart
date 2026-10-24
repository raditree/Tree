import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 片 D：运行形态**只有** `ui` / `headless` 两档。
///
/// 旧清单里的 `binary` / `python` 以及空串、任意未知值一律归一化成 `headless`，
/// 并标记 legacy；核心不按语言枚举做分支（只认归一化结果）。
void main() {
  group('PluginRuntime.parse', () {
    test('ui / headless 是新口径（大小写与空白无关）', () {
      for (final String raw in <String>['ui', 'UI', ' Ui ']) {
        final PluginRuntimeInfo info = PluginRuntime.parse(raw);
        expect(info.kind, PluginRuntimeKind.ui, reason: raw);
        expect(info.legacy, isFalse, reason: raw);
        expect(info.value, 'ui');
      }
      final PluginRuntimeInfo headless = PluginRuntime.parse('headless');
      expect(headless.kind, PluginRuntimeKind.headless);
      expect(headless.legacy, isFalse);
      expect(headless.value, 'headless');
    });

    test('空串 / binary / python / 任意未知值 ⇒ headless + legacy', () {
      for (final String raw in <String>[
        '',
        '  ',
        'binary',
        'Python',
        'python',
        'node',
        'dart',
      ]) {
        final PluginRuntimeInfo info = PluginRuntime.parse(raw);
        expect(info.kind, PluginRuntimeKind.headless, reason: raw);
        expect(info.legacy, isTrue, reason: raw);
        expect(info.value, 'headless', reason: '对外只暴露归一化值');
        expect(info.raw, raw, reason: '原始值仍保留给展示 / 待升级');
      }
    });
  });

  group('PluginConfig 归一化结果', () {
    test('legacy 清单：runtimeInfo / toApiJson 只增键，原值不丢', () {
      final PluginConfig config = PluginConfig.fromJson(<String, dynamic>{
        'id': 'legacy.python',
        'command': 'python',
        'runtime': 'python',
      });
      expect(config.runtimeKind, PluginRuntimeKind.headless);
      expect(config.runtimeIsLegacy, isTrue);
      expect(config.runtime, 'python', reason: '磁盘原值不被回改');

      final Map<String, dynamic> api = config.toApiJson();
      expect(api['runtime'], 'headless');
      expect(api['runtime_legacy'], isTrue);
      expect(api['plugin_id'], 'legacy.python');
      expect(api['requires'], <String, dynamic>{'plugins': <dynamic>[]});
    });

    test('新清单 ui：runtime 归一化值 = ui，legacy = false', () {
      final PluginConfig config = PluginConfig.fromJson(<String, dynamic>{
        'id': 'tree.ui.default',
        'command': 'tree_ui.exe',
        'runtime': 'ui',
      });
      expect(config.runtimeKind, PluginRuntimeKind.ui);
      expect(config.runtimeIsLegacy, isFalse);
      expect(config.toApiJson()['runtime'], 'ui');
      expect(config.toApiJson()['runtime_legacy'], isFalse);
    });

    test('runtime 缺失 ⇒ headless + legacy（旧配置不需要批量改）', () {
      final PluginConfig config = PluginConfig.fromJson(<String, dynamic>{
        'id': 'plain',
        'command': 'dart',
      });
      expect(config.runtimeKind, PluginRuntimeKind.headless);
      expect(config.runtimeIsLegacy, isTrue);
    });
  });

  group('ui.hello 身份闸门', () {
    test('只有归一化 ui 被接受；binary / python / 空 / 未知一律拒绝', () {
      expect(StationWsBridge.isUiRuntime('ui'), isTrue);
      expect(StationWsBridge.isUiRuntime(' UI '), isTrue);
      for (final String raw in <String>[
        'headless',
        'binary',
        'python',
        '',
        'node',
      ]) {
        expect(StationWsBridge.isUiRuntime(raw), isFalse, reason: raw);
      }
    });
  });
}
