// PluginStore 的单元测试（配额 / 路径编码）。
//
// 存储 API（`/api/store/*`）已于 2026-11-08 随核心面收窄删除（界面与插件仓零调用）；
// 这里保留对 `PluginStore` 落盘实现的单元覆盖，类本身仍在 tree_core 中供平台能力复用。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tree-plugin-store-');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('PluginStore 单元（配额 / 路径编码）', () {
    test('命名空间配额超限 ⇒ 413 语义，且不做部分写入', () async {
      final TreePaths paths = TreePaths(temp.path);
      final PluginStore store = PluginStore(
        paths: paths,
        namespaceQuotaBytes: 10,
      );
      final StorePutResult first = await store.put(
        'core',
        'a',
        List<int>.filled(6, 1),
      );
      expect(first.ok, isTrue);
      final StorePutResult second = await store.put(
        'core',
        'b',
        List<int>.filled(6, 2),
      );
      expect(second.status, StorePutStatus.quotaExceeded);
      // 没有部分写入：b 完全不存在。
      expect(await store.read('core', 'b'), isNull);
      expect(await store.namespaceBytes('core'), 6);
    });

    test('单值上限与 key 编码可逆', () async {
      final PluginStore store = PluginStore(
        paths: TreePaths(temp.path),
        maxValueBytes: 4,
      );
      final StorePutResult tooLarge = await store.put(
        'core',
        'a',
        List<int>.filled(5, 0),
      );
      expect(tooLarge.status, StorePutStatus.tooLarge);

      final StorePutResult ok = await store.put(
        'core',
        '中文 key-1',
        utf8.encode('值'),
      );
      expect(ok.ok, isTrue);
      final StorePage page = await store.list('core');
      expect(page.entries.single.key, '中文 key-1');
      // 落盘文件名是 base64url，不含分隔符 / 原字符。
      final List<String> names = Directory(
        store.namespaceDir('core'),
      ).listSync().map((FileSystemEntity e) => p.basename(e.path)).toList();
      expect(names.single, startsWith('k_'));
      expect(names.single, isNot(contains('中文')));
    });
  });
}
