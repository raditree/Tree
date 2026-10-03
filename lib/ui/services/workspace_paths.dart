/// 工作空间相对路径的**纯函数**工具 + 条目名校验。
///
/// 为什么单独一层：路径口径（正斜杠、相对工作空间根、空串 = 根）是文件树、查看器、
/// 「同步到本地」作用域共用的约定，散在控件里迟早漂移；而且它们全是纯函数，
/// 可以逐条钉住（见 test/workspace_paths_test.dart）。
library;

/// 归一化：反斜杠 → 正斜杠、去掉首尾斜杠（路径永远相对工作空间根）
String workspacePathNormalize(String path) {
  String normalized = path.replaceAll('\\', '/');
  while (normalized.startsWith('/')) {
    normalized = normalized.substring(1);
  }
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// 拼路径：[dir] 为空（根）时直接给名字
String workspacePathJoin(String dir, String name) {
  final String base = workspacePathNormalize(dir);
  final String leaf = workspacePathNormalize(name);
  if (base.isEmpty) return leaf;
  if (leaf.isEmpty) return base;
  return '$base/$leaf';
}

/// 父目录（根下的一级路径、以及根本身的父都是根 = 空串）
String workspacePathParent(String path) {
  final String normalized = workspacePathNormalize(path);
  final int at = normalized.lastIndexOf('/');
  return at < 0 ? '' : normalized.substring(0, at);
}

/// 最后一段名字
String workspacePathName(String path) {
  final String normalized = workspacePathNormalize(path);
  final int at = normalized.lastIndexOf('/');
  return at < 0 ? normalized : normalized.substring(at + 1);
}

/// [path] 是不是 [ancestor] 本身或它的后代（同一套相对路径口径）。
///
/// 根（空串）是一切路径的祖先——删除根在动作层就被拦住，这里只保证语义一致。
bool workspacePathAtOrUnder(String path, String ancestor) {
  final String target = workspacePathNormalize(path);
  final String base = workspacePathNormalize(ancestor);
  if (base.isEmpty) return true;
  return target == base || target.startsWith('$base/');
}

/// 把 [from]（本身或整棵子树）换成 [to]：改名之后把内存里的键一起搬过去
/// （展开状态 / 已加载的目录 / 选中项都按这套走）。
String workspacePathRemap(String path, String from, String to) {
  final String target = workspacePathNormalize(path);
  final String source = workspacePathNormalize(from);
  final String destination = workspacePathNormalize(to);
  if (source.isEmpty) return target;
  if (target == source) return destination;
  if (target.startsWith('$source/')) {
    final String rest = target.substring(source.length);
    return '$destination$rest';
  }
  return target;
}

/// Windows 保留设备名（改名成 CON / NUL 这种在 Windows 上会失败）
final RegExp _reservedDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);

/// 控制字符
final RegExp _controlChars = RegExp(r'[\x00-\x1f]');

/// 条目名字里的非法字符（Windows 口径）
final RegExp _illegalNameChars = RegExp(r'[<>:"|?*]');

/// 新建 / 重命名共用的名字校验：合法返回 null，否则返回可直接显示的中文原因。
///
/// 为什么前端也要校验一份：核心的 PUT 写文本**没有"仅新建"语义**（同名会静默覆盖），
/// 重命名的 409/404 倒是由核心兜底——所以这里挡的是"用户一眼就该知道的错"
/// （空名字、路径分隔符、非法字符、Windows 保留名、同名），核心的报错仍然原样显示。
///
/// [siblings] 是目标目录已有的名字（同名比对**不分大小写**：Windows / macOS 上
/// A.txt 与 a.txt 是同一个文件）；[originalName] 是重命名时条目自己的名字，
/// 比对时跳过它、并且"没改名字"单独给原因。
String? validateEntryName(
  String raw, {
  required Iterable<String> siblings,
  String? originalName,
}) {
  final String name = raw.trim();
  if (name.isEmpty) return '名字不能为空';
  if (name == '.' || name == '..') return '名字不能是 . 或 ..';
  if (name.contains('/') || name.contains('\\')) {
    return '名字里不能有路径分隔符（/ 或 \\）';
  }
  if (_illegalNameChars.hasMatch(name)) {
    return '名字里不能包含 < > : " | ? * 这几个字符';
  }
  if (_controlChars.hasMatch(name)) return '名字里不能有控制字符';
  if (name.endsWith('.') || name.endsWith(' ')) return '名字不能以点或空格结尾';
  if (name.length > 128) return '名字太长（最多 128 个字符）';
  if (_reservedDeviceName.hasMatch(name)) {
    return '这是 Windows 保留设备名（CON / NUL 这类），请换一个';
  }
  if (originalName != null && name == originalName) return '名字没有变化';
  for (final String sibling in siblings) {
    final String existing = sibling.toLowerCase();
    if (originalName != null && existing == originalName.toLowerCase()) {
      continue;
    }
    if (existing == name.toLowerCase()) return '同名条目已存在：$name';
  }
  return null;
}

/// 行内重命名默认选中"名字本体"（不含扩展名），与 VS Code 一致：
/// a.txt → 1；.gitignore → 10（点开头不是扩展名）；dir → 3
int entryNameSelectionLength(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0) return name.length;
  return dot;
}
