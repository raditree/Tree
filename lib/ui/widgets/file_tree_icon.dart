import 'package:flutter/material.dart';

import '../models/git_status.dart';
import '../services/code_highlight.dart';

/// 文件树条目的**视觉映射纯函数**（VS Code 型资源管理器）。
///
/// 两件事都在这里，且都**不跟主题色**：
/// 1. **类型图标 + 固定配色**：VS Code 的资源管理器图标本来就是彩色的（暖黄文件夹、
///    青色 Dart、蓝色 Markdown、黄色 JSON/YAML…）。跟 `cs.primary`（本仓库主题的
///    深绿）走会让整棵树变成一坨同色——那正是"简陋"的来源，所以色板写死；
/// 2. **git 状态装饰色**：整行名字染色 + 行尾字母（M/U/A/D/R/I）用 VS Code 的
///    gitDecoration 配色，「被忽略」额外压暗（VS Code 也是"更淡"而不是另一种颜色）。
///
/// 全是纯函数（路径 / 是否目录 / 是否展开 / 状态 → 图标 + 颜色），
/// 单测见 test/file_tree_icon_test.dart 与 test/workspace_git_status_test.dart。
enum FileTreeKind {
  folderClosed,
  folderOpen,
  dart,
  markdown,
  json,
  yaml,
  python,
  shell,
  image,
  pdf,
  archive,
  text,
  code,
  unknown,
}

/// 图标与状态的色板（写死；明暗主题共用一份——图标是"类型标识"，不是主题语义色）
abstract final class FileTreePalette {
  /// 文件夹：VS Code 默认图标主题那种暖黄（收起 / 展开同色，只有图标形状变）
  static const Color folder = Color(0xFFDCB67A);

  /// .dart：Dart 品牌青
  static const Color dart = Color(0xFF00B4AB);

  /// .md：蓝
  static const Color markdown = Color(0xFF42A5F5);

  /// .json / .yaml：黄（用户 2026-10-03 的分组要求：两者都黄，靠图标形状区分）
  static const Color json = Color(0xFFCBCB41);
  static const Color yaml = Color(0xFFCBCB41);

  /// .py：Python 蓝（"蓝黄"两色一个 IconData 表达不了，取主色蓝，见 lib/README.md）
  static const Color python = Color(0xFF4B8BBE);
  static const Color shell = Color(0xFF89E051);
  static const Color image = Color(0xFFA074C4);
  static const Color pdf = Color(0xFFE5484D);
  static const Color archive = Color(0xFFECA517);
  static const Color text = Color(0xFFB0BEC5);
  static const Color code = Color(0xFF8AA1B1);
  static const Color unknown = Color(0xFF9E9E9E);

  // ── git 状态装饰色（VS Code gitDecoration 口径） ──
  /// 已修改：黄 / 橙
  static const Color gitModified = Color(0xFFE2A03F);

  /// 未跟踪 / 新增到暂存区 / 重命名：绿
  static const Color gitUntracked = Color(0xFF73C991);
  static const Color gitAdded = Color(0xFF73C991);
  static const Color gitRenamed = Color(0xFF73C991);

  /// 已删除：红
  static const Color gitDeleted = Color(0xFFE05252);

  /// 被忽略：灰（渲染时再乘 [gitStatusOpacity] 压暗）
  static const Color gitIgnored = Color(0xFF7A7A7A);
}

/// 一个条目要显示的图标 + 颜色 + 类型名（可直接比较，便于单测）
@immutable
class FileTreeVisual {
  const FileTreeVisual({
    required this.kind,
    required this.icon,
    required this.color,
    required this.label,
  });

  final FileTreeKind kind;
  final IconData icon;
  final Color color;

  /// 类型的中文名（悬停提示里给用户看的"这是什么"）
  final String label;

  @override
  bool operator ==(Object other) =>
      other is FileTreeVisual &&
      other.kind == kind &&
      other.icon == icon &&
      other.color == color &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, icon, color, label);

  @override
  String toString() => 'FileTreeVisual($kind, $label)';
}

const Set<String> _imageExtensions = <String>{
  'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico', 'svg', 'avif', 'tif', 'tiff',
  'heic', 'psd',
};

const Set<String> _archiveExtensions = <String>{
  'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', '7z', 'rar', 'jar', 'war', 'whl',
  'deb', 'rpm', 'dmg', 'iso',
};

const Set<String> _textExtensions = <String>{
  'txt', 'log', 'text', 'csv', 'tsv', 'rst',
};

/// 路径 → 类型图标 + 颜色（**纯函数**）。
///
/// [isDirectory] 为真时只看 [expanded]（收起 = folder / 展开 = folder_open）；
/// [path] 可以是完整相对路径（只用最后一段判扩展名，Windows 反斜杠也接受）。
/// 认不出的扩展名、以及 `.gitignore` 这种"点开头的隐藏文件"（没有扩展名）都给
/// [FileTreeKind.unknown] 的灰图标——**不猜**。
FileTreeVisual fileTreeVisualFor(
  String path, {
  bool isDirectory = false,
  bool expanded = false,
}) {
  if (isDirectory) {
    return expanded
        ? const FileTreeVisual(
            kind: FileTreeKind.folderOpen,
            icon: Icons.folder_open,
            color: FileTreePalette.folder,
            label: '文件夹',
          )
        : const FileTreeVisual(
            kind: FileTreeKind.folderClosed,
            icon: Icons.folder,
            color: FileTreePalette.folder,
            label: '文件夹',
          );
  }
  final String name = _baseName(path);
  final int dot = name.lastIndexOf('.');
  // dot <= 0：没有扩展名，或 `.gitignore` 这类"点开头"的名字（不是扩展名）
  final String ext = dot <= 0 ? '' : name.substring(dot + 1);

  if (_imageExtensions.contains(ext)) {
    return const FileTreeVisual(
      kind: FileTreeKind.image,
      icon: Icons.image,
      color: FileTreePalette.image,
      label: '图片',
    );
  }
  if (ext == 'pdf') {
    return const FileTreeVisual(
      kind: FileTreeKind.pdf,
      icon: Icons.picture_as_pdf,
      color: FileTreePalette.pdf,
      label: 'PDF',
    );
  }
  if (_archiveExtensions.contains(ext)) {
    return const FileTreeVisual(
      kind: FileTreeKind.archive,
      icon: Icons.folder_zip,
      color: FileTreePalette.archive,
      label: '压缩包',
    );
  }
  if (ext == 'md' || ext == 'markdown' || ext == 'mdx') {
    return const FileTreeVisual(
      kind: FileTreeKind.markdown,
      icon: Icons.description,
      color: FileTreePalette.markdown,
      label: 'Markdown',
    );
  }
  if (_textExtensions.contains(ext)) {
    return const FileTreeVisual(
      kind: FileTreeKind.text,
      icon: Icons.text_snippet_outlined,
      color: FileTreePalette.text,
      label: '文本',
    );
  }
  // 源码类**复用 code_highlight 的语言表**（单一事实来源：高亮认得的语言，
  // 图标也认得；不再抄第二张扩展名表，免得两边漂移）
  switch (languageForPath(path).id) {
    case 'dart':
      return const FileTreeVisual(
        kind: FileTreeKind.dart,
        icon: Icons.flutter_dash,
        color: FileTreePalette.dart,
        label: 'Dart 文件',
      );
    case 'python':
      return const FileTreeVisual(
        kind: FileTreeKind.python,
        icon: Icons.code,
        color: FileTreePalette.python,
        label: 'Python',
      );
    case 'shell':
      return const FileTreeVisual(
        kind: FileTreeKind.shell,
        icon: Icons.terminal,
        color: FileTreePalette.shell,
        label: 'Shell 脚本',
      );
    case 'json':
      return const FileTreeVisual(
        kind: FileTreeKind.json,
        icon: Icons.data_object,
        color: FileTreePalette.json,
        label: 'JSON',
      );
    case 'yaml':
      return const FileTreeVisual(
        kind: FileTreeKind.yaml,
        icon: Icons.settings,
        color: FileTreePalette.yaml,
        label: 'YAML',
      );
    case 'plain':
      return const FileTreeVisual(
        kind: FileTreeKind.unknown,
        icon: Icons.insert_drive_file_outlined,
        color: FileTreePalette.unknown,
        label: '未知类型',
      );
    default:
      // 其它源码（js/ts/go/rs/c/java/html/css/sql/bat/powershell…）：一类一色
      return const FileTreeVisual(
        kind: FileTreeKind.code,
        icon: Icons.code,
        color: FileTreePalette.code,
        label: '源码',
      );
  }
}

/// git 状态的装饰色（整行名字 + 行尾字母）
Color gitStatusColor(GitFileStatus status) => switch (status) {
  GitFileStatus.modified => FileTreePalette.gitModified,
  GitFileStatus.untracked => FileTreePalette.gitUntracked,
  GitFileStatus.added => FileTreePalette.gitAdded,
  GitFileStatus.deleted => FileTreePalette.gitDeleted,
  GitFileStatus.renamed => FileTreePalette.gitRenamed,
  GitFileStatus.ignored => FileTreePalette.gitIgnored,
};

/// 「被忽略」压暗（VS Code 里 git 忽略项就是"更淡"）：其余状态不透明度 1.0
double gitStatusOpacity(GitFileStatus status) =>
    status == GitFileStatus.ignored ? 0.55 : 1.0;

/// 取路径最后一段并小写（Windows 反斜杠也接受）
String _baseName(String path) =>
    path.replaceAll('\\', '/').split('/').last.toLowerCase();
