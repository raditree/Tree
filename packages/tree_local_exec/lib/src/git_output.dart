import 'dart:convert';

import 'workspace_io.dart';

/// git 命令与输出解析：**本地与 SSH 共用同一份**（M9 Q4）。
///
/// 为什么单独抽出来：两端都要求"解析结果与旧实现一致"，那命令与解析就不能各写
/// 一份——SSH 侧把 [logArgs] 拼成远端 shell 命令，本地侧把同一组参数直接交给
/// Process.run，两边不可能漂移。解析规则照旧实现：
/// - log 每行是 hash / 作者 / ISO 日期 / 标题，TAB 分隔，**标题本身可以含 tab**
///   （只按 tab 切分，余下的整体归 message）；
/// - branch 每行一个分支名，`* ` 前缀是当前分支（当前分支同样进列表）。
///
/// 非仓库 / 没有 git 时调用方**不抛异常**，只把 git 的退出码原样带回去。
abstract final class GitOutput {
  /// log 的单行格式：hash / 作者 / ISO 日期 / 标题，TAB 分隔（与旧实现一字不差）。
  static const String logPretty = '%H%x09%an%x09%ad%x09%s';

  /// 本地连 git 可执行文件都找不到时的退出码（远端由远端 shell 返回 127）。
  static const int missingGitExitCode = 127;

  /// 提交条数上限（与旧 SSH 实现一致：下限 1、上限 1000）。
  static int clampLimit(int limit) => limit.clamp(1, 1000);

  /// log 的参数向量（不含可执行文件名）。
  static List<String> logArgs(int limit) => <String>[
    'log',
    '--pretty=format:$logPretty',
    '--date=iso',
    '-n',
    '$limit',
  ];

  /// branch 的参数向量（-a = 含远端分支，与旧实现一致）。
  static List<String> branchArgs() => <String>['branch', '-a'];

  /// 把参数向量拼成远端 shell 命令（只给 SSH exec 通道用）。
  ///
  /// 参数里没有需要引用的字符：格式串固定，limit 由 [clampLimit] 夹成整数。
  static String logCommand(int limit) => 'git ${logArgs(limit).join(' ')}';

  static String get branchCommand => 'git ${branchArgs().join(' ')}';

  // ── status（M11 文件面板：改动高亮） ────────────────────────────────

  /// status 的参数向量（不含可执行文件名）。
  ///
  /// `-z` 是刻意的：路径以 NUL 分隔且**不被引号包裹**，带空格 / 中文 / 引号的
  /// 路径不会碎（非 -z 时 git 会把它们写成 `"a\tb"` 那种 C 风格转义，解析方
  /// 还得再实现一遍 git 的 quote 规则）。
  ///
  /// [ignored] 打开才带 `--ignored`（`!!` 条目）。默认关：大仓库里列被忽略文件
  /// 既慢又吵。
  static List<String> statusArgs({bool ignored = false}) => <String>[
    'status',
    '--porcelain=v1',
    '-z',
    if (ignored) '--ignored',
  ];

  static String statusCommand({bool ignored = false}) =>
      'git ${statusArgs(ignored: ignored).join(' ')}';

  /// 面板口径的单字母状态（porcelain 的 `XY` 两位 → 一个字母）。
  ///
  /// 契约（与前端一致）：
  /// - `??` → `U`（未跟踪）、`!!` → `I`（被忽略）；
  /// - 同一路径同时有暂存与工作区改动时取**更显眼**的那个：`M` 优先于 `A`
  ///   （`AM` = 新文件暂存后又改过 → `M`），`A` 优先于 `D`；
  /// - 任一侧是 `U`（未合并冲突）→ `U`；`C`（复制）与 `R` 同归 `R`；
  /// - 认不出的组合返回 null：调用方**跳过**，宁可少一条也不猜。
  static String? reduceStatus(String x, String y) {
    if (x == '!' || y == '!') return 'I';
    if (x == '?' || y == '?') return 'U';
    if (x == 'U' || y == 'U') return 'U';
    if (x == 'M' || y == 'M' || x == 'T' || y == 'T') return 'M';
    if (x == 'A' || y == 'A') return 'A';
    if (x == 'R' || y == 'R' || x == 'C' || y == 'C') return 'R';
    if (x == 'D' || y == 'D') return 'D';
    return null;
  }

  /// 解析 `git status --porcelain=v1 -z` 的输出。
  ///
  /// `-z` 的字段规则（真 git 的输出实测，不是凭文档）：每条记录是 `XY <path>`，
  /// 记录之间以 NUL 分隔；**重命名 / 复制**的记录后面紧跟着**一条原始（旧）路径**
  /// 字段——它是上一条记录的补充，不是独立条目（解析时必须消费掉）。
  ///
  /// 只在 git 退出码为 0 时调用（非仓库时 stdout 是报错文本，硬解析只会造垃圾）。
  /// 非法 / 不完整输入**不抛异常**：认不出的记录直接跳过。
  /// 条目数达到 [maxEntries] 即停止并置 `truncated: true`（大仓库不把核心拖死）。
  static ({List<GitStatusEntry> entries, bool truncated}) parseStatus(
    String stdout, {
    int maxEntries = 2000,
  }) {
    final List<GitStatusEntry> entries = <GitStatusEntry>[];
    if (stdout.isEmpty) return (entries: entries, truncated: false);
    final List<String> fields = stdout.split('\u0000');
    bool truncated = false;
    int index = 0;
    while (index < fields.length) {
      final String field = fields[index++];
      // 最短的合法记录是 `XY ` + 一个字符的路径；末尾那个空字段（-z 输出以 NUL
      // 结尾）也在这里被跳过。
      if (field.length < 4 || field[2] != ' ') continue;
      final String x = field[0];
      final String y = field[1];
      final String rawPath = field.substring(3);
      // 重命名 / 复制：下一条字段是**旧路径**，不是新条目。
      if (x == 'R' || x == 'C') {
        if (index < fields.length) index++;
      }
      final String? status = reduceStatus(x, y);
      if (status == null) continue;
      final String path = _stripTrailingSlash(rawPath);
      if (path.isEmpty) continue;
      if (entries.length >= maxEntries) {
        truncated = true;
        break;
      }
      entries.add(GitStatusEntry(path: path, status: status));
    }
    return (entries: entries, truncated: truncated);
  }

  /// 去掉 git 给未跟踪**目录**补的尾斜杠（`?? build/` → `build`），让面板口径里
  /// 的路径都是「不带尾斜杠的相对路径」。
  static String _stripTrailingSlash(String path) {
    String out = path;
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// 解析 git log 输出。
  ///
  /// 只在 git 退出码为 0 时调用（旧实现就是这么做的）：非仓库时 stdout 里是
  /// git 的报错文本，硬解析只会造出垃圾提交。
  static List<GitCommit> parseLog(String stdout) {
    final List<GitCommit> commits = <GitCommit>[];
    for (final String raw in const LineSplitter().convert(stdout)) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      final List<String> parts = line.split('\t');
      if (parts.length < 4) continue;
      commits.add(
        GitCommit(
          hash: parts[0],
          author: parts[1],
          date: parts[2],
          message: parts.sublist(3).join('\t'),
        ),
      );
    }
    return commits;
  }

  /// 解析 git branch -a 输出。
  static ({List<String> branches, String current}) parseBranches(
    String stdout,
  ) {
    final List<String> branches = <String>[];
    String current = '';
    for (final String raw in const LineSplitter().convert(stdout)) {
      final String name = raw.trim();
      if (name.isEmpty) continue;
      if (name.startsWith('* ')) {
        current = name.substring(2).trim();
        branches.add(current);
      } else {
        branches.add(name);
      }
    }
    return (branches: branches, current: current);
  }
}
