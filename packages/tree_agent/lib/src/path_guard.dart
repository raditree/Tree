import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// **越界防护（agent 侧那一半）**：每个路径参数先 [normalizePosixPath]，再 [isWithinRoot]。
///
/// 为什么要有它：核心侧（`WorkspaceIO.resolve`）已经拒绝绝对路径 / 盘符 / `..` 逃逸，
/// 但 agent 是**另一个进程、另一条边界**——它的 stdio 只要握在谁手里，谁就能发任意
/// 绝对路径。双保险的另一半必须在这里（协议 §4）。
///
/// **不解析符号链接**（与 SFTP 层同口径：按链接本身操作）：因此"软链接指向 root 之外"
/// 读得到目标内容——这与今天 dartssh2/SFTP 的行为**一致**，不是本包引入的缺口。
class PathGuard {
  PathGuard(String root) : root = normalizePosixPath(root);

  /// 归一化后的工作空间根。
  final String root;

  /// 校验并归一化一个路径参数；越界抛 [RpcException]`-32001`（消息里带上那个路径）。
  ///
  /// [label] 只用于错误消息（`from` / `to` / `log_path` / `cwd` …），便于定位是哪一项越界。
  String check(Object? raw, {String label = 'path'}) {
    if (raw is! String || raw.isEmpty) {
      throw RpcException(
        RpcCodes.invalidParams,
        '$label 必须是非空字符串（收到 ${raw == null ? 'null' : raw.runtimeType}）',
      );
    }
    final String normalized = normalizePosixPath(raw);
    if (!isWithinRoot(normalized, root)) {
      throw RpcException(
        TunnelErrorCodes.pathOutOfRoot,
        '$label 越出工作空间根：$raw（root=$root）',
      );
    }
    return normalized;
  }

  /// **破坏性操作**额外要求：不许对工作空间根**自身**动手。
  ///
  /// 为什么（这是对协议的**加固**，不是协议条文）：`isWithinRoot(root, root)` 为真，
  /// 于是一条 `fs.remove{path:<root>, recursive:true}` 就能把**整个工作空间**删掉，
  /// 且不可恢复；而核心侧（`WorkspaceIO.resolve` 出来的都是相对路径）永远不会这么做。
  /// 宁可显式挡掉，也不留一条"一次 RPC 删库"的路。
  String checkDestructiveTarget(Object? raw, {String label = 'path'}) {
    final String normalized = check(raw, label: label);
    if (normalized == root) {
      throw RpcException(
        TunnelErrorCodes.pathOutOfRoot,
        '$label 指向工作空间根自身，拒绝破坏性操作：$raw（root=$root）',
      );
    }
    return normalized;
  }
}

/// 把 `dart:io` 在 Windows 上回给我们的**反斜杠路径**统一成正斜杠。
///
/// 本包的路径口径一律正斜杠（协议 §3 顶层：`fs.list` 用 POSIX 分隔符）；
/// `Directory.list()` 在 Windows 上给的是 `C:\…\a.txt`，直接用 `posixBasename`
/// 会把整条路径当成文件名 —— 必须在**边界**上转一次。
String posixify(String path) => path.replaceAll('\\', '/');

/// POSIX `dirname`（本包不许引 `package:path`，只写需要的最小版本）。
///
/// 入参应先经 [normalizePosixPath]（本包所有路径都是那个口径）。
String posixDirname(String path) {
  final String normalized = normalizePosixPath(path);
  final int slash = normalized.lastIndexOf('/');
  if (slash < 0) return '.';
  if (slash == 0) return '/';
  return normalized.substring(0, slash);
}

/// POSIX `basename`。
String posixBasename(String path) {
  final String stripped = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final int slash = stripped.lastIndexOf('/');
  return slash < 0 ? stripped : stripped.substring(slash + 1);
}

/// 把一个"POSIX 单引号字面量"用起来（`'` → `'\''`）——写 launcher 脚本时必须的转义。
///
/// 命令本身**不转义**（它本来就是 shell 命令串，协议 §3.3 说 agent 收到的是最终字符串）；
/// 这里只转义我们**自己注入**的路径。
String posixQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
