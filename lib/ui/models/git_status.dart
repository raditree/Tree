/// 工作空间 git 状态（文件面板的 VS Code 型状态着色）。
///
/// 数据来源：核心 `GET /api/files/{workspaceId}/git-status`
/// → `{is_repo: bool, entries: [{path, status}], truncated: bool}`
/// （`is_repo=false` 时 entries 为空 ⇒ 完全不着色）。
///
/// 这一层只有**纯数据 + 纯函数**（状态码解析 / 路径归一化 / 目录聚合），
/// 配色与字母在 [ui/widgets/file_tree_icon.dart]，两边都能单测。
library;

/// 文件在 git 眼里的状态（只保留会引起"着色"的那几种）。
///
/// 核心只回一个字母（与 `git status --porcelain` 同一套）：
/// M 已修改 / U 未跟踪 / A 新增到暂存区 / D 已删除 / R 重命名 / I 被忽略。
enum GitFileStatus {
  modified,
  untracked,
  added,
  deleted,
  renamed,
  ignored,
}

/// 核心状态码 → 枚举。**不认识的码返回 null**（未知状态不着色：宁可不上色，
/// 也不要把没见过的状态猜成一个颜色）。
GitFileStatus? gitFileStatusFromCode(String code) {
  switch (code.trim().toUpperCase()) {
    case 'M':
      return GitFileStatus.modified;
    // '??' 是 porcelain 的未跟踪写法，核心契约给的是 'U'；两种都收
    case 'U':
    case '??':
      return GitFileStatus.untracked;
    case 'A':
      return GitFileStatus.added;
    case 'D':
      return GitFileStatus.deleted;
    case 'R':
      return GitFileStatus.renamed;
    case 'I':
    case '!':
      return GitFileStatus.ignored;
    default:
      return null;
  }
}

/// 状态 → 行尾字母 / 中文说明 / 聚合优先级
extension GitFileStatusInfo on GitFileStatus {
  /// 行尾那一个字母（VS Code 同款）
  String get letter => switch (this) {
    GitFileStatus.modified => 'M',
    GitFileStatus.untracked => 'U',
    GitFileStatus.added => 'A',
    GitFileStatus.deleted => 'D',
    GitFileStatus.renamed => 'R',
    GitFileStatus.ignored => 'I',
  };

  /// 悬停提示里的中文（"M" 对普通用户不是可读信息）
  String get label => switch (this) {
    GitFileStatus.modified => '已修改',
    GitFileStatus.untracked => '未跟踪',
    GitFileStatus.added => '已暂存的新增',
    GitFileStatus.deleted => '已删除',
    GitFileStatus.renamed => '已重命名',
    GitFileStatus.ignored => '被忽略',
  };

  /// 目录聚合时"取哪一个"：**越靠前越优先**。
  ///
  /// 删除 > 修改 > 未跟踪 > 新增 > 重命名 > 忽略：一个目录里既有删除又有忽略时，
  /// 该显示红（删除）——目录标记是给"这里有值得注意的改动"的信号，
  /// 被忽略的条目最不重要。
  int get priority => switch (this) {
    GitFileStatus.deleted => 6,
    GitFileStatus.modified => 5,
    GitFileStatus.untracked => 4,
    GitFileStatus.added => 3,
    GitFileStatus.renamed => 2,
    GitFileStatus.ignored => 1,
  };
}

/// 路径归一化：反斜杠 → 正斜杠、去掉尾部斜杠，空路径原样。
///
/// 为什么归一是纯函数：核心给的是工作空间相对路径（**正斜杠**），但 git 状态里
/// 目录条目可能带尾斜杠，测试夹具也可能用 Windows 分隔符——两边都归一化，
/// 比对就不会因为一个斜杠整棵树都不着色。
String normalizeGitPath(String path) {
  return path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
}

/// 一次 git 状态快照。
class GitStatusSnapshot {
  const GitStatusSnapshot({
    this.isRepo = false,
    this.byPath = const <String, GitFileStatus>{},
    this.truncated = false,
  });

  /// 不是 git 仓库（或状态拿不到时的安全默认值）：**完全不着色**
  static const GitStatusSnapshot none = GitStatusSnapshot();

  /// 工作空间是不是 git 仓库（false ⇒ 任何 statusFor 都返回 null）
  final bool isRepo;

  /// 工作空间相对路径（正斜杠）→ 状态
  final Map<String, GitFileStatus> byPath;

  /// 核心只回了前一段状态（超大仓库）
  final bool truncated;

  bool get hasChanges => isRepo && byPath.isNotEmpty;

  /// 某个**文件**的状态（路径不在表里 / 不是仓库 ⇒ null）
  GitFileStatus? statusFor(String path) {
    if (!isRepo) return null;
    return byPath[normalizeGitPath(path)];
  }

  /// 某个**目录**的聚合状态：名下（含自身）有改动时给最优先的那个（见
  /// [GitFileStatusInfo.priority]）。
  GitFileStatus? aggregateForDirectory(String dirPath) {
    if (!isRepo) return null;
    return aggregateGitStatus(dirPath, byPath);
  }
}

/// 核心响应 → 快照（纯函数，单测直接喂 Map）。
///
/// 宽容解析：未知状态码丢掉、缺 path 丢掉、多余字段忽略、entries 不是 List 当空——
/// 核心与前端协议漂移时宁可少上色，也不要抛异常把树变成错误页。
GitStatusSnapshot parseGitStatus(Map<String, dynamic> json) {
  final bool isRepo = json['is_repo'] == true;
  final Map<String, GitFileStatus> byPath = <String, GitFileStatus>{};
  final Object? rawEntries = json['entries'];
  if (rawEntries is List) {
    for (final Object? entry in rawEntries) {
      if (entry is! Map) continue;
      final String path = normalizeGitPath((entry['path'] as String? ?? ''));
      final GitFileStatus? status = gitFileStatusFromCode(
        entry['status'] as String? ?? '',
      );
      if (path.isEmpty || status == null) continue;
      byPath[path] = status;
    }
  }
  return GitStatusSnapshot(
    isRepo: isRepo,
    byPath: byPath,
    truncated: json['truncated'] == true,
  );
}

/// 目录聚合：目录自身或名下任一祖先路径命中时，取优先级最高的状态。
///
/// [dirPath] 为空 = 工作空间根（任何改动都算在根上）。
GitFileStatus? aggregateGitStatus(
  String dirPath,
  Map<String, GitFileStatus> byPath,
) {
  final String dir = normalizeGitPath(dirPath);
  final String prefix = dir.isEmpty ? '' : '$dir/';
  GitFileStatus? best;
  for (final MapEntry<String, GitFileStatus> entry in byPath.entries) {
    final String path = normalizeGitPath(entry.key);
    final bool hit = dir.isEmpty || path == dir || path.startsWith(prefix);
    if (!hit) continue;
    if (best == null || entry.value.priority > best.priority) {
      best = entry.value;
    }
  }
  return best;
}
