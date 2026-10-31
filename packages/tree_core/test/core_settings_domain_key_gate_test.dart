import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// L-22 落地门禁（2026-11-01 用户拍板，比文档更有约束力）：
/// **核心 `CoreSettings.toMap()` 不得包含任何领域键**。
///
/// 黑名单显式列全：`token_acquisition_rate`（token 速率）、`models` / `model_*`
/// （模型池）、`fallback_max_seqlen`。同时扫核心 `lib/src/settings` 源码字面量，
/// 防"换个名字又加回来"。
void main() {
  const Set<String> domainKeys = <String>{
    'token_acquisition_rate',
    'models',
    'fallback_max_seqlen',
  };

  bool isDomainKey(String key) =>
      domainKeys.contains(key) ||
      key.startsWith('model_') ||
      key.endsWith('_token_rate');

  test('toMap() 的键集不含领域键（平台键与用户未知键除外）', () {
    final CoreSettings settings = CoreSettings();
    settings.applyMap(<String, dynamic>{
      'frame_rate': 45,
      'heartbeat_interval': 10,
      'missed_heartbeat_limit': 3,
      'data_collection_enabled': true,
      'user_keep_me': '保留',
    });
    final Map<String, dynamic> map = settings.toMap();
    expect(map.keys.where(isDomainKey).toList(), isEmpty);
    expect(map['frame_rate'], 45);
    expect(map['user_keep_me'], '保留');
  });

  test('手写 yaml 里的领域键被消耗，不透传写回', () {
    final CoreSettings settings = CoreSettings();
    settings.applyMap(<String, dynamic>{
      'token_acquisition_rate': 240,
      'models': <String, dynamic>{'m1': <String, dynamic>{}},
      'fallback_max_seqlen': 64000,
    });
    expect(settings.toMap().keys.where(isDomainKey).toList(), isEmpty);
    expect(settings.extra.keys.where(isDomainKey).toList(), isEmpty);
  });

  test('核心 settings 源码不再出现领域键的写入字面量', () {
    final Directory dir = Directory('lib/src/settings');
    expect(dir.existsSync(), isTrue, reason: '用例必须从包根跑');
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String name = entity.uri.pathSegments.last;
      final String source = entity.readAsStringSync();
      if (name == 'core_settings.dart') {
        // CoreSettings 本体保留的是"消耗"（..remove 旧键），不是"读写"。
        expect(
          source.contains('tokenAcquisitionRate'),
          isFalse,
          reason: '领域 getter/setter 已随 L-22 删除',
        );
      }
      // 任何文件都不允许把领域键**写进** map 字面量（消耗式 ..remove 不算）。
      for (final String key in <String>[
        'token_acquisition_rate',
        'models',
        'fallback_max_seqlen',
      ]) {
        expect(
          source.contains("'$key':"),
          isFalse,
          reason: '$name 里出现了领域键写入字面量：$key',
        );
      }
    }
  });
}
