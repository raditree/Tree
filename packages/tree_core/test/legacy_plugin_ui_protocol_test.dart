import 'dart:io';

import 'package:test/test.dart';

/// 片 E / 5.6：旧 UI 面板协议的**零残留**断言。
///
/// 扫描范围 = 代码与随包资源（`lib/`、`test/`、`packages/`、`tool/`、`assets/`）；
/// 历史文档（`docs/archive`、`CHANGELOG`、设计/验收文档）按惯例保留"曾经存在"的
/// 记述，不在此列。`build/`、`.output/`、`.dart_tool/` 是产物目录，必须跳过。
void main() {
  test('全仓代码与资源里没有旧 UI 面板协议的任何标识', () async {
    final Directory root = _repoRoot();
    final List<String> patterns = <String>[
      'plugin${'_'}ui_manifest',
      'plugin${'_'}ui_update',
      'plugin${'_'}ui_action',
      'Plugin${'Ui'}Registry',
      'Plugin${'Ui'}View',
      'plugin${'_'}ui_view',
      'plugin${'_'}ui_slots',
    ];
    const Set<String> allowedExtensions = <String>{
      '.dart',
      '.html',
      '.js',
      '.yaml',
      '.yml',
      '.json',
      '.md',
    };
    const Set<String> skippedDirs = <String>{
      'build',
      '.output',
      '.dart_tool',
      '.git',
      '.trae',
      'dist',
      'docs',
      'windows',
      'linux',
      'macos',
      'ios',
      'android',
      'node_modules',
    };

    final List<String> hits = <String>[];
    Future<void> scan(Directory dir) async {
      await for (final FileSystemEntity entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final List<String> segments = entity.path
            .split(Platform.pathSeparator)
            .map((String s) => s.toLowerCase())
            .toList();
        if (segments.any(skippedDirs.contains)) continue;
        final int dot = entity.path.lastIndexOf('.');
        if (dot < 0 ||
            !allowedExtensions.contains(
              entity.path.substring(dot).toLowerCase(),
            )) {
          continue;
        }
        final String text = await entity.readAsString();
        for (final String pattern in patterns) {
          if (text.contains(pattern)) {
            hits.add('${entity.path} ⇒ $pattern');
          }
        }
      }
    }

    for (final String name in <String>[
      'lib',
      'test',
      'packages',
      'tool',
      'assets',
    ]) {
      final Directory dir = Directory('${root.path}/$name');
      if (dir.existsSync()) await scan(dir);
    }

    expect(hits, isEmpty, reason: '旧 UI 面板协议仍有残留：\n${hits.join('\n')}');
  });
}

/// 从当前工作目录向上找到仓库根（同时含 `packages/tree_core` 与 `lib`）。
Directory _repoRoot() {
  Directory cursor = Directory.current;
  for (int i = 0; i < 8; i++) {
    if (Directory('${cursor.path}/packages/tree_core').existsSync() &&
        Directory('${cursor.path}/lib').existsSync()) {
      return cursor;
    }
    final Directory parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }
  throw StateError('找不到仓库根（当前目录：${Directory.current.path}）');
}
