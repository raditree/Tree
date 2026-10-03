import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/git_status.dart';
import 'package:tree/ui/widgets/file_tree_icon.dart';

/// 文件树的**视觉映射纯函数**（VS Code 型彩色类型图标 + git 状态装饰色）。
///
/// 颜色/图标是"看一眼就知道类型"的那条观感断言，所以这里钉的是**字面值**
/// （不引 FileTreePalette 常量，否则改了色板测试跟着改，等于没钉）。
void main() {
  group('类型图标 + 颜色（纯函数）', () {
    test('目录：收起 folder / 展开 folder_open，都用 VS Code 那种暖黄', () {
      final FileTreeVisual closed = fileTreeVisualFor(
        'src',
        isDirectory: true,
      );
      expect(closed.kind, FileTreeKind.folderClosed);
      expect(closed.icon, Icons.folder);
      expect(closed.color, const Color(0xFFDCB67A));
      expect(closed.label, '文件夹');

      final FileTreeVisual open = fileTreeVisualFor(
        'src',
        isDirectory: true,
        expanded: true,
      );
      expect(open.kind, FileTreeKind.folderOpen);
      expect(open.icon, Icons.folder_open);
      expect(open.color, const Color(0xFFDCB67A), reason: '展开只换形状不换色');
      expect(open, isNot(closed));
    });

    test('扩展名 → 类型 + 固定颜色（一张表钉住）', () {
      final Map<String, (FileTreeKind, Color)> table =
          <String, (FileTreeKind, Color)>{
            'a.dart': (FileTreeKind.dart, const Color(0xFF00B4AB)),
            'a.md': (FileTreeKind.markdown, const Color(0xFF42A5F5)),
            'a.markdown': (FileTreeKind.markdown, const Color(0xFF42A5F5)),
            'a.mdx': (FileTreeKind.markdown, const Color(0xFF42A5F5)),
            'a.json': (FileTreeKind.json, const Color(0xFFCBCB41)),
            'a.yaml': (FileTreeKind.yaml, const Color(0xFFCBCB41)),
            'a.yml': (FileTreeKind.yaml, const Color(0xFFCBCB41)),
            'a.py': (FileTreeKind.python, const Color(0xFF4B8BBE)),
            'a.sh': (FileTreeKind.shell, const Color(0xFF89E051)),
            'a.png': (FileTreeKind.image, const Color(0xFFA074C4)),
            'a.pdf': (FileTreeKind.pdf, const Color(0xFFE5484D)),
            'a.zip': (FileTreeKind.archive, const Color(0xFFECA517)),
            'a.txt': (FileTreeKind.text, const Color(0xFFB0BEC5)),
            'a.xyz': (FileTreeKind.unknown, const Color(0xFF9E9E9E)),
          };
      table.forEach((String path, (FileTreeKind, Color) expected) {
        final FileTreeVisual visual = fileTreeVisualFor(path);
        expect(visual.kind, expected.$1, reason: path);
        expect(visual.color, expected.$2, reason: path);
      });
    });

    test('一族多扩展名：图片 / 压缩包 / 纯文本 / 其它源码', () {
      const List<String> images = <String>[
        'a.png',
        'a.jpg',
        'a.jpeg',
        'a.gif',
        'a.webp',
        'a.svg',
        'a.ico',
        'a.bmp',
        'a.avif',
      ];
      for (final String path in images) {
        expect(fileTreeVisualFor(path).kind, FileTreeKind.image, reason: path);
      }
      const List<String> archives = <String>[
        'a.zip',
        'a.tar',
        'a.tar.gz',
        'a.tgz',
        'a.7z',
        'a.rar',
        'a.whl',
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
      // 其余源码（高亮表认得、但不是上面点名的家族）：一类一色
      const List<String> code = <String>[
        'a.js',
        'a.ts',
        'a.go',
        'a.rs',
        'a.c',
        'a.cpp',
        'a.java',
        'a.html',
        'a.css',
        'a.sql',
        'a.ps1',
        'a.bat',
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

    test('无扩展名 / 点开头的隐藏文件 → 未知类型（灰），**不猜**', () {
      for (final String path in <String>[
        'LICENSE',
        'Makefile',
        '.gitignore',
        '.env',
        'noext',
      ]) {
        final FileTreeVisual visual = fileTreeVisualFor(path);
        expect(visual.kind, FileTreeKind.unknown, reason: path);
        expect(visual.color, const Color(0xFF9E9E9E), reason: path);
        expect(visual.icon, Icons.insert_drive_file_outlined);
      }
    });

    test('纯函数：同一输入给同一个结果，不同家族给不同图标/颜色', () {
      expect(
        fileTreeVisualFor('a.dart'),
        fileTreeVisualFor('a.dart'),
        reason: '可比较：值相等',
      );
      expect(
        fileTreeVisualFor('a.dart').icon,
        isNot(fileTreeVisualFor('a.py').icon),
      );
      // 点名的家族颜色两两不同（json 与 yaml 是同一族黄，故意相同）
      final List<Color> familyColors = <Color>[
        fileTreeVisualFor('a.dart').color,
        fileTreeVisualFor('a.md').color,
        fileTreeVisualFor('a.json').color,
        fileTreeVisualFor('a.py').color,
        fileTreeVisualFor('a.sh').color,
        fileTreeVisualFor('a.png').color,
        fileTreeVisualFor('a.pdf').color,
        fileTreeVisualFor('a.zip').color,
        fileTreeVisualFor('a.txt').color,
        fileTreeVisualFor('a.xyz').color,
        fileTreeVisualFor('src', isDirectory: true).color,
      ];
      expect(
        familyColors.toSet().length,
        familyColors.length,
        reason: '各家族必须是不同颜色，否则图标仍分不出来',
      );
    });
  });

  group('git 状态装饰色（纯函数）', () {
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
