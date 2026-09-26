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
