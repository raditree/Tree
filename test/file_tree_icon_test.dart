import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/git_status.dart';
import 'package:tree/ui/widgets/file_tree_icon.dart';

/// 文件树的**视觉映射纯函数**（中性类型图标 + git 状态装饰色）。
///
/// 用户 2026-10-04 看图定稿（"文件为什么是这种橙色"）：图标**一律中性、跟主题走**
/// （[fileTreeIconColor]），类型靠**形状**区分、展开 / 收起靠**左侧箭头**区分；
/// 颜色只留给 git 状态。旧的"暖黄文件夹 / 青色 Dart / 蓝色 md"写死色板已被推翻，
/// 所以这里不再钉任何类型颜色——钉的是图标形状、kind 与 git 色（字面值）。
void main() {
  group('类型图标（纯函数，不带类型色）', () {
    test('目录：收起 / 展开是两个 kind，但都是描边文件夹图标', () {
      final FileTreeVisual closed = fileTreeVisualFor(
        'src',
        isDirectory: true,
      );
      expect(closed.kind, FileTreeKind.folderClosed);
      expect(closed.icon, Icons.folder_outlined);
      expect(closed.label, '文件夹');

      final FileTreeVisual open = fileTreeVisualFor(
        'src',
        isDirectory: true,
        expanded: true,
      );
      expect(open.kind, FileTreeKind.folderOpen);
      expect(
        open.icon,
        Icons.folder_outlined,
        reason: '形状不变（状态由左侧箭头表达，与 VS Code 一致）',
      );
      expect(open, isNot(closed), reason: 'kind 仍然分得开（聚合 / 语义要用）');
    });

    test('扩展名 → kind + 图标（一张表钉住）', () {
      final Map<String, (FileTreeKind, IconData)> table =
          <String, (FileTreeKind, IconData)>{
            'a.dart': (FileTreeKind.dart, Icons.flutter_dash),
            'a.md': (FileTreeKind.markdown, Icons.description_outlined),
            'a.markdown': (FileTreeKind.markdown, Icons.description_outlined),
            'a.mdx': (FileTreeKind.markdown, Icons.description_outlined),
            'a.json': (FileTreeKind.json, Icons.data_object),
            'a.yaml': (FileTreeKind.yaml, Icons.settings_outlined),
            'a.yml': (FileTreeKind.yaml, Icons.settings_outlined),
            'a.py': (FileTreeKind.python, Icons.code),
            'a.sh': (FileTreeKind.shell, Icons.terminal),
            'a.png': (FileTreeKind.image, Icons.image_outlined),
            'a.pdf': (FileTreeKind.pdf, Icons.picture_as_pdf_outlined),
            'a.zip': (FileTreeKind.archive, Icons.folder_zip_outlined),
            'a.txt': (FileTreeKind.text, Icons.text_snippet_outlined),
            'a.xyz': (FileTreeKind.unknown, Icons.insert_drive_file_outlined),
          };
      table.forEach((String path, (FileTreeKind, IconData) expected) {
        final FileTreeVisual visual = fileTreeVisualFor(path);
        expect(visual.kind, expected.$1, reason: path);
        expect(visual.icon, expected.$2, reason: path);
      });
    });

    test('一族多扩展名：图片 / 压缩包 / 纯文本 / 其它源码', () {
      const List<String> images = <String>[
        'a.png', 'a.jpg', 'a.jpeg', 'a.gif', 'a.webp', 'a.svg', 'a.ico',
        'a.bmp', 'a.avif',
      ];
      for (final String path in images) {
        expect(fileTreeVisualFor(path).kind, FileTreeKind.image, reason: path);
      }
      const List<String> archives = <String>[
        'a.zip', 'a.tar', 'a.tar.gz', 'a.tgz', 'a.7z', 'a.rar', 'a.whl',
      ];
      for (final String path in archives) {
        expect(
          fileTreeVisualFor(path).kind,
          FileTreeKind.archive,
          reason: path,
        );
      }
      const List<String> texts = <String>['a.txt', 'a.log', 'a.csv', 'a.rst'];
      for (final String path in texts) {
        expect(fileTreeVisualFor(path).kind, FileTreeKind.text, reason: path);
      }
      // 其余源码（高亮表认得、但不是上面点名的家族）
      const List<String> code = <String>[
        'a.js', 'a.ts', 'a.go', 'a.rs', 'a.c', 'a.cpp', 'a.java', 'a.html',
        'a.css', 'a.sql', 'a.ps1', 'a.bat',
      ];
      for (final String path in code) {
        expect(fileTreeVisualFor(path).kind, FileTreeKind.code, reason: path);
      }
    });

    test('大小写不敏感；完整路径只看最后一段；Windows 反斜杠也认', () {
      expect(fileTreeVisualFor('A.DART').kind, FileTreeKind.dart);
      expect(fileTreeVisualFor('lib/ui/main.dart').kind, FileTreeKind.dart);
      expect(fileTreeVisualFor('lib\\ui\\main.dart').kind, FileTreeKind.dart);
      expect(fileTreeVisualFor('docs/README.MD').kind, FileTreeKind.markdown);
    });

    test('无扩展名 / 点开头的隐藏文件 → 未知类型，**不猜**', () {
      for (final String path in <String>[
        'LICENSE',
        'Makefile',
        '.gitignore',
        '.env',
        'noext',
      ]) {
        final FileTreeVisual visual = fileTreeVisualFor(path);
        expect(visual.kind, FileTreeKind.unknown, reason: path);
        expect(visual.icon, Icons.insert_drive_file_outlined, reason: path);
      }
    });

    test('纯函数：同一输入给同一个结果；各家族靠**形状**两两分得开', () {
      expect(
        fileTreeVisualFor('a.dart'),
        fileTreeVisualFor('a.dart'),
        reason: '可比较：值相等',
      );
      expect(
        fileTreeVisualFor('a.dart').icon,
        isNot(fileTreeVisualFor('a.py').icon),
      );
      // 点名的家族里，形状必须两两不同——否则"只有颜色能分"，而颜色现在统一中性
      final List<IconData> familyIcons = <IconData>[
        fileTreeVisualFor('src', isDirectory: true).icon,
        fileTreeVisualFor('a.md').icon,
        fileTreeVisualFor('a.json').icon,
        fileTreeVisualFor('a.yaml').icon,
        fileTreeVisualFor('a.png').icon,
        fileTreeVisualFor('a.pdf').icon,
        fileTreeVisualFor('a.zip').icon,
        fileTreeVisualFor('a.txt').icon,
        fileTreeVisualFor('a.xyz').icon,
      ];
      expect(
        familyIcons.toSet().length,
        familyIcons.length,
        reason: '各家族的图标形状必须不同（颜色已统一，只能靠形状认）',
      );
    });
  });

  group('图标颜色：一律跟主题走（不再有类型色板）', () {
    test('深浅两套主题各取自己的 onSurfaceVariant', () {
      final ColorScheme light = ColorScheme.fromSeed(
        seedColor: const Color(0xFF00904A),
      );
      final ColorScheme dark = ColorScheme.fromSeed(
        seedColor: const Color(0xFF00904A),
        brightness: Brightness.dark,
      );
      expect(fileTreeIconColor(light), light.onSurfaceVariant);
      expect(fileTreeIconColor(dark), dark.onSurfaceVariant);
      expect(
        fileTreeIconColor(light),
        isNot(fileTreeIconColor(dark)),
        reason: '深浅主题下必须各取各的（跟主题走，而不是写死一种灰）',
      );
    });
  });

  group('git 状态装饰色（纯函数，唯一保留的颜色）', () {
    test('每个状态一个固定色：M 黄橙 / U·A·R 绿 / D 红 / I 灰', () {
      expect(gitStatusColor(GitFileStatus.modified), const Color(0xFFE2A03F));
      expect(gitStatusColor(GitFileStatus.untracked), const Color(0xFF73C991));
      expect(gitStatusColor(GitFileStatus.added), const Color(0xFF73C991));
      expect(gitStatusColor(GitFileStatus.deleted), const Color(0xFFE05252));
      expect(gitStatusColor(GitFileStatus.renamed), const Color(0xFF73C991));
      expect(gitStatusColor(GitFileStatus.ignored), const Color(0xFF7A7A7A));
    });

    test('「被忽略」压暗（更淡），其余不透明度 1.0', () {
      expect(gitStatusOpacity(GitFileStatus.ignored), lessThan(1.0));
      for (final GitFileStatus status in GitFileStatus.values) {
        if (status == GitFileStatus.ignored) continue;
        expect(gitStatusOpacity(status), 1.0, reason: status.name);
      }
    });
  });
}
