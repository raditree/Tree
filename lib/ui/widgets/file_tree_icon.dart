import 'package:flutter/material.dart';

import '../models/git_status.dart';
import '../services/code_highlight.dart';

/// 文件树条目的**视觉映射纯函数**（VS Code 型资源管理器）。

/// 口径（用户 2026-10-04 看图定稿）：**图标一律中性、跟主题走**，颜色只留给 git 状态。
///
/// 1. **类型图标是单色的**（[fileTreeIconColor] = `colorScheme.onSurfaceVariant`）：
///    VS Code 默认图标主题就是这个样子——灰色描边文件夹 + 单色图标，靠**形状**区分
///    类型，靠**左侧箭头**区分展开 / 收起。此前那张"暖黄文件夹 / 青色 Dart / 蓝色 md"
///    的写死色板**已被推翻**（用户："文件为什么是这种橙色"）；
/// 2. **git 状态装饰色**是这里唯一保留的颜色：整行名字染色 + 行尾字母（M/U/A/D/R/I），
///    用 VS Code 的 gitDecoration 配色，"被忽略"额外压暗（VS Code 也是"更淡"而不是换色）。
///
/// 全是纯函数（路径 / 是否目录 / 是否展开 / 状态 → 图标 + 类型名 / 颜色），
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

/// 树里唯一的色板：**git 状态装饰色**（VS Code gitDecoration 口径）。
///
/// 类型图标不再有自己的颜色（见 [fileTreeIconColor]）：色板越小，越不会跟主题打架。
abstract final class FileTreePalette {
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

/// 类型图标的颜色：**跟主题走的单色**（深浅色主题各自取 `onSurfaceVariant`）。
///
/// 为什么不写死色板（旧口径）：写死色板在深色主题下会把整棵树变成一坨高饱和色块，
/// 而"这条文件改没改"才是资源管理器真正要靠颜色表达的信息（VS Code 也是如此）。
Color fileTreeIconColor(ColorScheme scheme) => scheme.onSurfaceVariant;

/// 一个条目要显示的图标 + 类型名（可直接比较，便于单测）
@immutable
class FileTreeVisual {
  const FileTreeVisual({
    required this.kind,
    required this.icon,
    required this.label,
  });

  final FileTreeKind kind;
  final IconData icon;

  /// 类型的中文名（悬停提示里给用户看的"这是什么"）
  final String label;

  @override
  bool operator ==(Object other) =>
      other is FileTreeVisual &&
      other.kind == kind &&
      other.icon == icon &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, icon, label);

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

/// 路径 → 类型图标（**纯函数**，不带颜色：颜色跟主题走，见 [fileTreeIconColor]）。
///
/// [isDirectory] 为真时只看 [expanded]（收起 / 展开是**两个 kind**，但图标同为描边文件夹——
/// 状态由左侧箭头表达，与 VS Code 一致）；[path] 可以是完整相对路径（只用最后一段判扩展名，
/// Windows 反斜杠也接受）。认不出的扩展名、以及 `.gitignore` 这种"点开头的隐藏文件"
/// （没有扩展名）都给 [FileTreeKind.unknown] 的通用文件图标——**不猜**。
FileTreeVisual fileTreeVisualFor(
  String path, {
  bool isDirectory = false,
  bool expanded = false,
}) {
  if (isDirectory) {
    return FileTreeVisual(
      kind: expanded ? FileTreeKind.folderOpen : FileTreeKind.folderClosed,
      icon: Icons.folder_outlined,
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
      icon: Icons.image_outlined,
      label: '图片',
    );
  }
  if (ext == 'pdf') {
    return const FileTreeVisual(
      kind: FileTreeKind.pdf,
      icon: Icons.picture_as_pdf_outlined,
      label: 'PDF',
    );
  }
  if (_archiveExtensions.contains(ext)) {
    return const FileTreeVisual(
      kind: FileTreeKind.archive,
      icon: Icons.folder_zip_outlined,
      label: '压缩包',
    );
  }
  if (ext == 'md' || ext == 'markdown' || ext == 'mdx') {
    return const FileTreeVisual(
      kind: FileTreeKind.markdown,
      icon: Icons.description_outlined,
      label: 'Markdown',
    );
  }
  if (_textExtensions.contains(ext)) {
    return const FileTreeVisual(
      kind: FileTreeKind.text,
      icon: Icons.text_snippet_outlined,
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
        label: 'Dart 文件',
      );
    case 'python':
      return const FileTreeVisual(
        kind: FileTreeKind.python,
        icon: Icons.code,
        label: 'Python',
      );
    case 'shell':
      return const FileTreeVisual(
        kind: FileTreeKind.shell,
        icon: Icons.terminal,
        label: 'Shell 脚本',
      );
    case 'json':
      return const FileTreeVisual(
        kind: FileTreeKind.json,
        icon: Icons.data_object,
        label: 'JSON',
      );
    case 'yaml':
      return const FileTreeVisual(
        kind: FileTreeKind.yaml,
        icon: Icons.settings_outlined,
        label: 'YAML',
      );
    case 'plain':
      return const FileTreeVisual(
        kind: FileTreeKind.unknown,
        icon: Icons.insert_drive_file_outlined,
        label: '未知类型',
      );
    default:
      // 其它源码（js/ts/go/rs/c/java/html/css/sql/bat/powershell…）：同一枚图标
      return const FileTreeVisual(
        kind: FileTreeKind.code,
        icon: Icons.code,
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
