import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ansi_code_page.dart';
import 'git_output.dart';
import 'local_workspace_io.dart';
import 'ssh_liveness.dart';
import 'ssh_shell_channel.dart';
import 'workspace_io.dart';

/// SSH 传输抽象：把"远端文件系统 + 远端命令执行"压成 6 个方法。
///
/// **为什么要这层**：真正的 dartssh2 调用无法在本机验证（本机没有 sshd），
/// 而工作空间语义（相对路径约束、行范围读取、唯一匹配编辑、grep 排除规则、
/// 结果截断）才是容易出错的部分。把传输抽出来后，[SshWorkspaceIO] 可以完全
/// 用内存假实现单测；dartssh2 实现只剩"搬运字节"的薄薄一层。
abstract interface class SshTransport {
  /// 读取文件（不存在抛 [WorkspaceIoException]）。
  Future<List<int>> read(String absolutePath);

  /// 写入文件（自动建父目录）。
  Future<void> write(String absolutePath, List<int> bytes);

  /// 文件字节数（不存在抛 [WorkspaceIoException]）。
  Future<int> size(String absolutePath);

  /// 读取字节流（[offset] 起、最多 [length] 字节；null = 读到结尾）。
  Stream<List<int>> readStream(
    String absolutePath, {
    int offset = 0,
    int? length,
  });

  /// 把字节流写入文件（自动建父目录）。
  Future<void> writeStream(String absolutePath, Stream<List<int>> data);

  /// 递归列出目录下的**文件**相对路径（POSIX 分隔符）。
  Future<List<String>> listFiles(String absolutePath, {int maxDepth});

  /// 列出**一层**目录（M7g 文件面板用）：名字/类型/大小/修改时间。
  ///
  /// 与 [listFiles] 的区别：那个是给 grep/工具层用的「文件路径清单」，不递归、
  /// 也不需要元信息；文件面板要显示大小与时间，用 SFTP 的 listdir 一次拿全。
  Future<List<SshFileEntry>> listEntries(String absolutePath, {int maxEntries});

  /// 路径是否存在且是文件/目录。
  Future<bool> exists(String absolutePath);

  /// 删除一个远端**文件**（不存在不报错）。
  Future<void> delete(String absolutePath);

  /// 新建一个远端目录（M11 文件面板；**父目录必须已存在**）。
  ///
  /// 走 SFTP 的 mkdir（dartssh2 `SftpClient.mkdir`），不起 shell——没有引号 /
  /// 转义 / 远端有没有 coreutils 这些问题。
  Future<void> makeDirectory(String absolutePath);

  /// 重命名 / 移动远端路径（M11 文件面板；走 SFTP 的 rename）。
  ///
  /// **注意**：OpenSSH 的 `posix-rename@openssh.com` 扩展是**覆盖**语义，因此
  /// 「目标已存在」必须由 [SshWorkspaceIO] 先自检，不能指望这一层报错。
  Future<void> rename(String oldPath, String newPath);

  /// 删除远端文件 / 目录（M11 文件面板）。
  ///
  /// 目录非空且 [recursive] 为 false 时抛 [WorkspaceIoException]（**不静默递归**）。
  Future<void> remove(String absolutePath, {bool recursive = false});

  /// 路径是否是目录（不存在 / 是文件 / 读不到都返回 false）。
  ///
  /// 用 SFTP 的 `stat`（O(1)）而不是「能不能列目录」：父目录可能是巨大的目录，
  /// 为了判个类型把整层列一遍不值当。
  Future<bool> isDirectory(String absolutePath);

  /// 执行命令，返回退出码与解码后的输出。
  ///
  /// [timeout] 是 M9 之前的**静态总时长**硬超时；1.1 修正后**不再按时间终止**
  /// 远端命令（本地执行，没有多服务器争抢资源的后果）——判据换成心跳：只要心跳
  /// 还在回，命令跑多久都等；心跳连续丢失才由 [liveness] 判失活并以显式错误
  /// 结束在途操作。参数保留只为不改调用方签名，已无实际作用。
  Future<SshExecResult> run(String command, {Duration timeout});

  /// 打开一条**远端 shell 通道**（真 PTY）：交互终端（Ctrl+J）的远端分支。
  ///
  /// 与 [run]（一次性 exec，命令跑完才回包、没有 TTY）是**互补的两条路**：
  /// 这条通道持续双向、能改尺寸、能拿退出码，因此 vim / top / Ctrl+C 都能工作
  /// （形状与语义见 [SshShellChannel]）。
  ///
  /// - [command] 为空 ⇒ 远端**登录 shell**；非空 ⇒ 让远端 shell 执行该命令
  ///   （真实现走 `exec` + `pty-req`，理由见 dartssh_transport.dart）；
  /// - [workingDirectory] 是**远端**绝对路径（空 = 远端登录 HOME）：远端只认远端
  ///   路径，调用方绝不能把本机路径传进来（[SshWorkspaceIO.openShell] 传的就是
  ///   本工作空间的远端根）；
  /// - 失败抛 [WorkspaceIoException]（可读中文），不返回一个半死的通道。
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  });

  /// 链路活性快照：最近一次心跳时间、连续丢失计数、是否失活（1.1 的心跳判据）。
  ///
  /// 给上层做重连决策与 UI 展示用；心跳丢失期间**不会**主动关连接。
  SshLiveness get liveness;

  /// 释放连接。
  Future<void> close();
}

/// 远端一层目录条目（M7g）。
class SshFileEntry {
  const SshFileEntry({
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.modified,
  });

  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
}

/// 远端命令执行结果。
class SshExecResult {
  const SshExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// 是否因超时被终止；M9 1.1 起恒为 false（字段留着不改调用方）。
  final bool timedOut;
}

/// 把用户填写的远端工作空间根目录解析成**绝对路径**。
///
/// 远端只认绝对路径：SFTP 不展开 `~`（那是 shell 的活），也不会跟着登录 shell 的
/// cwd 走。因此这里先问远端要一次 `$HOME`，再把 `~` / 相对路径拼上去；已是绝对路径
/// 的只做 POSIX 归一化（去掉尾斜杠——尾斜杠会让 [SshWorkspaceIO] 的越界判断出错）。
///
/// 只发一条 `printf`（不读取远端 shell 配置），也不需要远端有任何额外工具。
Future<String> resolveRemoteRoot(
  SshTransport transport,
  String root, {
  String fallback = '.',
}) async {
  final String raw = root.trim();
  final String candidate = raw.isEmpty ? fallback : raw;
  if (candidate.startsWith('/')) return p.posix.normalize(candidate);
  final SshExecResult result = await transport.liveness.guard(
    // 带**标记**取 $HOME：登录外壳（见 ssh_login_shell.dart）会读远端 profile，
    // profile 里若往 stdout 打欢迎语，整段 trim 出来的 home 就被污染了。
    () => transport.run(r'printf __TREE_HOME__%s "$HOME"'),
  );
  final int markerAt = result.stdout.lastIndexOf('__TREE_HOME__');
  final String home;
  if (markerAt >= 0) {
    home = result.stdout
        .substring(markerAt + '__TREE_HOME__'.length)
        .split(RegExp(r'\s'))
        .first
        .trim();
  } else {
    // 没有标记（老实现 / 假实现直接给 HOME）时退回"最后一行非空"：
    // profile 的欢迎语一般各占一行，最后一行仍是 HOME。
    final List<String> lines = result.stdout
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
    home = lines.isEmpty ? '' : lines.last;
  }
  if (result.exitCode != 0 || !home.startsWith('/')) {
    throw WorkspaceIoException('无法解析远端 HOME（exit=${result.exitCode}，输出：${result.stdout.trim()}）');
  }
  final String joined = candidate == '~'
      ? home
      : (candidate.startsWith('~/')
            ? '$home/${candidate.substring(2)}'
            : '$home/$candidate');
  return p.posix.normalize(joined);
}

/// [WorkspaceIO] 的 SSH 实现：语义与 [LocalWorkspaceIO] 完全一致，只是字节
/// 从远端来/去。
///
/// 与本地实现的差异（都是远端固有的）：
/// - 路径用 **POSIX** 规则（`p.posix`），Windows 盘符/UNC 判断不适用；
/// - grep/list 需要一次远端遍历（[SshTransport.listFiles]），因此默认排除目录
///   与深度上限同样生效，避免把 node_modules 拉下来；
/// - exec 不做 `chcp`（远端不是 cmd）；
/// - **每次传输都过一遍活性守卫**（M9 1.1）：先查 [SshTransport.liveness]，在途
///   操作与"链路被判失活"的信号赛跑，成功则记一次心跳。因此远端半天不响应时
///   操作会以"心跳丢失"的显式错误结束，而不是永久挂起；正常链路上零行为变化。
class SshWorkspaceIO implements WorkspaceIO, WorkspaceFiles {
  SshWorkspaceIO(this.root, this._transport);

  @override
  final String root;

  final SshTransport _transport;

  /// 链路活性（M9 1.1）：所有传输都从这里过一遍守卫。
  SshLiveness get _link => _transport.liveness;

  /// 与本地实现共用同一套排除目录（依赖/构建产物）。
  static Set<String> get defaultExcludedDirs =>
      LocalWorkspaceIO.defaultExcludedDirs;

  @override
  String resolve(String relativePath) {
    final String raw = relativePath.trim();
    if (raw.isEmpty) {
      throw WorkspacePathException(relativePath, '路径不能为空');
    }
    if (raw.startsWith('~') ||
        p.posix.isAbsolute(raw) ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
      throw WorkspacePathException(relativePath, '必须是工作空间内的相对路径');
    }
    final String absolute = p.posix.normalize(p.posix.join(root, raw));
    if (absolute != root && !p.posix.isWithin(root, absolute)) {
      throw WorkspacePathException(relativePath, '越出工作空间根目录');
    }
    return absolute;
  }

  /// 远端绝对路径 → 工作空间相对路径（工具输出用）。
  String relativize(String absolute) => p.posix.relative(absolute, from: root);

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) async {
    final String absolute = resolve(relativePath);
    final List<int> bytes = await _read(absolute, relativePath);
    final String ext = p.posix
        .extension(absolute)
        .replaceFirst('.', '')
        .toLowerCase();
    if (LocalWorkspaceIO.imageExtensions.contains(ext)) {
      return FileContent(
        path: relativePath,
        text: '',
        base64: base64Encode(bytes),
        language: ext,
      );
    }
    if (bytes.contains(0)) {
      throw WorkspaceIoException('这是二进制文件，无法作为文本读取：$relativePath');
    }
    final String text = LocalWorkspaceIO.decodeBytes(bytes);
    final List<String> all = const LineSplitter().convert(text);
    final int total = all.length;
    final int start = (startLine == null || startLine < 1) ? 1 : startLine;
    if (total > 0 && start > total) {
      throw WorkspaceIoException(
        'start_line=$start 超出文件总行数（$total）：$relativePath',
      );
    }
    final int from = start - 1;
    final int to = (lineCount == null || lineCount <= 0)
        ? total
        : (from + lineCount > total ? total : from + lineCount);
    return FileContent(
      path: relativePath,
      text: all.sublist(from, to).join('\n'),
      totalLines: total,
      startLine: start,
      truncated: to < total,
      language: ext,
    );
  }

  @override
  Future<int> writeFile(String relativePath, String content) async {
    final String absolute = resolve(relativePath);
    final List<int> bytes = await _encodeForExisting(
      absolute,
      relativePath,
      content,
    );
    await _link.guard(() => _transport.write(absolute, bytes));
    return bytes.length;
  }

  @override
  Future<bool> deleteFile(String relativePath) async {
    final String absolute = resolve(relativePath);
    final bool present = await _link.guard(() => _transport.exists(absolute));
    if (!present) return false;
    await _link.guard(() => _transport.delete(absolute));
    return true;
  }

  /// 覆盖写时尽量沿用**远端已有文件的编码**（与本地 [LocalWorkspaceIO.writeFile] 同一套取舍）。
  ///
  /// 注意：按系统代码页解码用的是**本机**的 ANSI 代码页（远端可能是 Linux）。这里要的性质
  /// 只是"解码与编码用同一个代码页 ⇒ 字节级可逆"，代码页本身对不对不影响这个性质；
  /// 编不回去就**显式拒绝**，绝不静默把远端文件转成 UTF-8。
  Future<List<int>> _encodeForExisting(
    String absolute,
    String relativePath,
    String content,
  ) async {
    final List<int> existing;
    try {
      existing = await _read(absolute, relativePath);
    } catch (_) {
      return utf8.encode(content); // 文件不存在 / 读不到：按新文件写 UTF-8
    }
    if (existing.isEmpty ||
        existing.length > LocalWorkspaceIO.encodingSniffMaxBytes) {
      return utf8.encode(content);
    }
    final DecodedText decoded = PlatformTextDecoder.decode(existing);
    if (decoded.isUtf8) return utf8.encode(content);
    final List<int>? bytes = LocalWorkspaceIO.encodeForWriteBack(
      decoded,
      existing,
      content,
    );
    if (bytes == null) {
      throw WorkspaceIoException(
        '该文件不是 UTF-8（检测为 ${LocalWorkspaceIO.decodingLabel(decoded.decoding)}），'
        '按原编码写回无法逐字节还原，已拒绝覆盖写：$relativePath；'
        '请改用 UTF-8 能表示的内容，或先用工具把文件转成 UTF-8',
      );
    }
    return bytes;
  }

  @override
  Future<EditOutcome> editFile(
    String relativePath, {
    required String oldText,
    required String newText,
    bool replaceAll = false,
  }) async {
    if (oldText.isEmpty) throw WorkspaceIoException('old_text 不能为空');
    final String absolute = resolve(relativePath);
    final List<int> rawBytes = await _read(absolute, relativePath);
    final DecodedText original = PlatformTextDecoder.decode(rawBytes);
    final bool crlf = original.text.contains('\r\n');
    final String haystack = crlf
        ? original.text.replaceAll('\r\n', '\n')
        : original.text;
    final String needle = oldText.replaceAll('\r\n', '\n');
    final int occurrences = _count(haystack, needle);
    if (occurrences == 0) {
      throw WorkspaceIoException(
        '未找到 old_text 的内容（已做 LF/CRLF 兼容匹配）：$relativePath',
      );
    }
    if (occurrences > 1 && !replaceAll) {
      throw WorkspaceIoException(
        'old_text 出现 $occurrences 次，无法唯一定位：$relativePath；'
        '请给更长的唯一片段或设置 replace_all=true',
      );
    }
    final String updated = haystack.replaceAll(
      needle,
      newText.replaceAll('\r\n', '\n'),
    );
    // 保编码写回：远端文件不是 UTF-8 时按原编码写回，且要求逐字节可还原；
    // 做不到就显式拒绝（绝不静默把远端 GBK 文件转成 UTF-8）
    final List<int>? bytes = LocalWorkspaceIO.encodeForWriteBack(
      original,
      rawBytes,
      crlf ? updated.replaceAll('\n', '\r\n') : updated,
    );
    if (bytes == null) {
      throw WorkspaceIoException(
        '该文件不是 UTF-8（检测为 ${LocalWorkspaceIO.decodingLabel(original.decoding)}），'
        '按原编码写回无法逐字节还原，已拒绝编辑：$relativePath；'
        '请先用工具把文件转成 UTF-8',
      );
    }
    await _link.guard(() => _transport.write(absolute, bytes));
    return EditOutcome(
      path: relativePath,
      replacements: replaceAll ? occurrences : 1,
      bytesWritten: bytes.length,
    );
  }

  @override
  Future<GrepOutcome> grep(GrepQuery query) async {
    final String start = resolve(query.relativePath);
    final RegExp pattern = _buildPattern(query);
    // 隐藏路径（`.[!.]*`）默认不搜：远端只给"文件相对路径"，没有目录事件，
    // 所以判据必须同时落在"路径段"（_excludedAncestor）与"文件 basename"上。
    final bool skipHidden = !query.includeHidden;
    final List<String> relativeFiles = await _link.guard(
      () => _transport.listFiles(start, maxDepth: query.maxDepth),
    );
    final List<GrepMatch> matches = <GrepMatch>[];
    // Q10：扫描清单与"实际生效的排除目录"在下面这一轮里顺手记录，
    // 复用同一次 listFiles + read，不额外扫一遍远端。
    final List<String> scannedPaths = <String>[];
    final List<String> excludedDirs = <String>[];
    final Set<String> seenExcludedDirs = <String>{};
    int scanned = 0;
    bool truncated = false;
    String relPath(String child) => p.posix
        .join(relativize(start), child)
        .replaceFirst(RegExp(r'^\./'), '');
    for (final String rel in relativeFiles) {
      if (matches.length >= query.maxResults) {
        truncated = true;
        break;
      }
      // 先看路径上有没有被排除的目录：命中就整棵子树跳过。远端 listFiles 只列
      // 文件，只按文件 basename 判是拦不住 node_modules/... 里的文件的——本地
      // _walk 是剪枝，这里必须一致，排除清单也才名副其实。
      final String? excludedDir = _excludedAncestor(
        rel,
        extraExcludes: query.exclude,
        skipHidden: skipHidden,
      );
      if (excludedDir != null) {
        final String dir = relPath(excludedDir);
        if (seenExcludedDirs.add(dir) &&
            excludedDirs.length < GrepOutcome.maxExcludedDirs) {
          excludedDirs.add(dir);
        }
        continue;
      }
      final String name = p.posix.basename(rel);
      if ((skipHidden && isHiddenPathName(name)) ||
          defaultExcludedDirs.contains(name)) {
        continue;
      }
      if (query.exclude.any((String glob) => _matchesGlob(name, glob))) {
        continue;
      }
      final List<int> bytes;
      try {
        bytes = await _read(p.posix.join(start, rel), rel);
      } on SshLinkStaleException {
        // 心跳丢了不是"这个文件读不到"：整轮如实失败，不要静默跳过剩下的文件
        rethrow;
      } catch (_) {
        continue;
      }
      if (bytes.contains(0)) continue;
      scanned++;
      if (scannedPaths.length < GrepOutcome.maxScannedFilePaths) {
        scannedPaths.add(relPath(rel));
      }
      int lineNumber = 0;
      for (final String line in const LineSplitter().convert(
        LocalWorkspaceIO.decodeBytes(bytes),
      )) {
        lineNumber++;
        if (!pattern.hasMatch(line)) continue;
        matches.add(
          GrepMatch(
            path: relPath(rel),
            lineNumber: lineNumber,
            line: line.length > 500 ? '${line.substring(0, 500)}…' : line,
          ),
        );
        if (matches.length >= query.maxResults) {
          truncated = true;
          break;
        }
      }
    }
    return GrepOutcome(
      matches: matches,
      scannedFileCount: scanned,
      truncated: truncated,
      scannedFilePaths: scannedPaths,
      excludedDirs: excludedDirs,
    );
  }

  /// 相对搜索根的路径 [rel] 上第一个命中的排除目录（不含自身的文件名）；
  /// 没有则 null。
  ///
  /// 远端给的是"文件相对路径"，排除目录只能从前缀反推：
  /// node_modules/pkg/a.js 的 node_modules 就是被剪掉的目录。
  ///
  /// [skipHidden] 打开时隐藏目录段（`.git` …）也算命中——与本地 `_walk` 的剪枝
  /// 对齐，否则远端会读进整棵被本地跳过的子树。
  static String? _excludedAncestor(
    String rel, {
    required List<String> extraExcludes,
    required bool skipHidden,
  }) {
    final List<String> parts = rel.split('/');
    // 最后一段是文件名，只判它前面的目录段
    for (int i = 0; i < parts.length - 1; i++) {
      final String name = parts[i];
      if ((skipHidden && isHiddenPathName(name)) ||
          defaultExcludedDirs.contains(name) ||
          extraExcludes.any((String glob) => _matchesGlob(name, glob))) {
        return parts.sublist(0, i + 1).join('/');
      }
    }
    return null;
  }

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) async {
    final String start = resolve(relativePath);
    final List<String> files = await _transport.listFiles(
      start,
      maxDepth: maxDepth,
    );
    final List<String> out = <String>[];
    for (final String rel in files) {
      if (out.length >= maxEntries) break;
      final String name = p.posix.basename(rel);
      if (defaultExcludedDirs.contains(name)) continue;
      out.add(rel);
    }
    return out;
  }

  @override
  Future<ExecOutcome> exec(
    String command, {
    Duration timeout = const Duration(seconds: 120),
    int maxOutputBytes = 200 * 1024,
  }) async {
    // [timeout] 只有本地实现在用（软超时 → LocalExecStillRunning）；SSH 侧忽略：
    // 活性判据是心跳，链路判失活时以 SshLinkStaleException 显式失败（M9 1.1）。
    final String trimmed = command.trim();
    if (trimmed.isEmpty) throw WorkspaceIoException('command 不能为空');
    final SshExecResult result = await _link.guard(
      () => _transport.run('cd ${_quote(root)} && $trimmed', timeout: timeout),
    );
    return ExecOutcome(
      exitCode: result.exitCode,
      stdout: _truncate(result.stdout, maxOutputBytes),
      stderr: _truncate(result.stderr, maxOutputBytes),
      timedOut: result.timedOut,
      truncated: result.stdout.length + result.stderr.length > maxOutputBytes,
      shell: 'ssh',
    );
  }

  // ── Git（M9 Q4）：走 exec 通道跑 git，命令与解析与本地共用 git_output.dart ─

  @override
  Future<GitLogOutcome> gitLog({int limit = 50}) async {
    final SshExecResult result = await _link.guard(
      () => _transport.run(
        'cd ${_quote(root)} && '
        '${GitOutput.logCommand(GitOutput.clampLimit(limit))}',
      ),
    );
    // 非仓库 / 远端没有 git：退出码非 0，stdout 是报错文本 → 空列表 + 退出码，
    // 不抛异常（面板显示空态而不是 400）。
    return GitLogOutcome(
      commits: result.exitCode == 0
          ? GitOutput.parseLog(result.stdout)
          : const <GitCommit>[],
      exitCode: result.exitCode,
    );
  }

  @override
  Future<GitBranchesOutcome> gitBranches() async {
    final SshExecResult result = await _link.guard(
      () => _transport.run('cd ${_quote(root)} && ${GitOutput.branchCommand}'),
    );
    final ({List<String> branches, String current}) parsed =
        result.exitCode == 0
        ? GitOutput.parseBranches(result.stdout)
        : (branches: const <String>[], current: '');
    return GitBranchesOutcome(
      branches: parsed.branches,
      current: parsed.current,
      exitCode: result.exitCode,
    );
  }

  @override
  Future<GitStatusOutcome> gitStatus({
    int maxEntries = 2000,
    bool ignored = false,
  }) async {
    final SshExecResult result = await _link.guard(
      () => _transport.run(
        'cd ${_quote(root)} && ${GitOutput.statusCommand(ignored: ignored)}',
      ),
    );
    // 非仓库 / 远端没有 git：退出码非 0、stdout 是报错文本。**不是错误**——
    // isRepo=false + 空列表，面板显示空态。
    if (result.exitCode != 0) {
      return GitStatusOutcome(
        isRepo: false,
        entries: const <GitStatusEntry>[],
        truncated: false,
        exitCode: result.exitCode,
      );
    }
    final ({List<GitStatusEntry> entries, bool truncated}) parsed =
        GitOutput.parseStatus(result.stdout, maxEntries: maxEntries);
    return GitStatusOutcome(
      isRepo: true,
      entries: parsed.entries,
      truncated: parsed.truncated,
      exitCode: 0,
    );
  }

  // ── 文件面板（M7g）：列一层目录 + 原始字节读写 ─────────────────────────

  @override
  Future<List<WorkspaceEntry>> listEntries(
    String relativePath, {
    int maxEntries = 2000,
  }) async {
    final String start = resolve(
      relativePath.trim().isEmpty ? '.' : relativePath,
    );
    final List<SshFileEntry> entries;
    try {
      entries = await _link.guard(
        () => _transport.listEntries(start, maxEntries: maxEntries),
      );
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('列目录失败（$relativePath）：$error');
    }
    final String base = relativize(start);
    final List<WorkspaceEntry> out = <WorkspaceEntry>[];
    for (final SshFileEntry entry in entries) {
      out.add(
        WorkspaceEntry(
          name: entry.name,
          relativePath: p.posix
              .join(base, entry.name)
              .replaceFirst(RegExp(r'^\./'), ''),
          isDirectory: entry.isDirectory,
          size: entry.isDirectory ? 0 : entry.size,
          modified: entry.modified,
        ),
      );
    }
    out.sort((WorkspaceEntry a, WorkspaceEntry b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Future<Uint8List> readBytes(String relativePath) async {
    final String absolute = resolve(relativePath);
    return Uint8List.fromList(await _read(absolute, relativePath));
  }

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    final String absolute = resolve(relativePath);
    try {
      await _link.guard(() => _transport.write(absolute, bytes));
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('写入失败（$relativePath）：$error');
    }
  }

  @override
  Future<int> sizeOf(String relativePath) async {
    final String absolute = resolve(relativePath);
    try {
      return await _link.guard(() => _transport.size(absolute));
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('读取失败（$relativePath）：$error');
    }
  }

  @override
  Stream<List<int>> openRead(
    String relativePath, {
    int offset = 0,
    int? length,
  }) {
    final String absolute = resolve(relativePath);
    return _guardStream(
      _transport.readStream(absolute, offset: offset, length: length),
    );
  }

  @override
  Future<void> writeStream(String relativePath, Stream<List<int>> data) async {
    final String absolute = resolve(relativePath);
    try {
      await _link.guard(() => _transport.writeStream(absolute, data));
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('写入失败（$relativePath）：$error');
    }
  }

  // ── 文件面板的结构改动（M11）：新建目录 / 重命名 / 删除（全部走 SFTP） ────

  @override
  Future<WorkspaceMutationResult> makeDirectory(String relativePath) async {
    final String absolute = resolve(relativePath);
    try {
      if (await _link.guard(() => _transport.exists(absolute))) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.alreadyExists,
          '目标已存在：$relativePath',
        );
      }
      final String parent = p.posix.dirname(absolute);
      if (!await _link.guard(() => _transport.isDirectory(parent))) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.parentMissing,
          '父目录不存在（不会自动创建）：${relativize(parent)}',
        );
      }
      await _link.guard(() => _transport.makeDirectory(absolute));
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('新建远端目录失败（$relativePath）：$error');
    }
    return const WorkspaceMutationResult.ok();
  }

  @override
  Future<WorkspaceMutationResult> rename(String from, String to) async {
    final String source = resolve(from);
    final String target = resolve(to);
    try {
      if (!await _link.guard(() => _transport.exists(source))) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.notFound,
          '源路径不存在：$from',
        );
      }
      // 先自检目标：SFTP 的 posix-rename 扩展**默认覆盖**目标，契约要求「已存在 →
      // 409 且绝不覆盖」，靠远端报错是不可靠的。
      if (await _link.guard(() => _transport.exists(target))) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.alreadyExists,
          '目标已存在（重命名不覆盖）：$to',
        );
      }
      final String parent = p.posix.dirname(target);
      if (!await _link.guard(() => _transport.isDirectory(parent))) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.parentMissing,
          '目标父目录不存在（不会自动创建）：${relativize(parent)}',
        );
      }
      await _link.guard(() => _transport.rename(source, target));
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('远端重命名失败（$from → $to）：$error');
    }
    return const WorkspaceMutationResult.ok();
  }

  @override
  Future<WorkspaceMutationResult> remove(
    String relativePath, {
    bool recursive = false,
  }) async {
    final String absolute = resolve(relativePath);
    try {
      if (!await _link.guard(() => _transport.exists(absolute))) {
        return WorkspaceMutationResult(
          WorkspaceMutationStatus.notFound,
          '路径不存在：$relativePath',
        );
      }
      if (!recursive &&
          await _link.guard(() => _transport.isDirectory(absolute))) {
        // 只取一条就够判断「空不空」：大目录也不怕（不列全）。
        final List<SshFileEntry> entries = await _link.guard(
          () => _transport.listEntries(absolute, maxEntries: 1),
        );
        if (entries.isNotEmpty) {
          return WorkspaceMutationResult(
            WorkspaceMutationStatus.notEmpty,
            '目录非空（默认不递归删除）：$relativePath；确要删除请带 recursive=1',
          );
        }
      }
      await _link.guard(
        () => _transport.remove(absolute, recursive: recursive),
      );
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('远端删除失败（$relativePath）：$error');
    }
    return const WorkspaceMutationResult.ok();
  }

  /// 打开一条远端 shell 通道（交互终端的 SSH 分支）。
  ///
  /// 透传给 [SshTransport.openShell]，**workingDirectory 用本工作空间的远端根**：
  /// 核心那边只有"本机路径"的概念（它的 `PtyStarter` 要一个 `workingDirectory`），
  /// 而远端根只有 [SshWorkspaceIO] 知道（`resolveRemoteRoot` 的结果存在 [root] 里）。
  /// 因此远端工作目录在这一层解决，核心**不参与**、也不会把本机路径透给远端。
  ///
  /// 过一遍活性守卫（与其余传输同一口径）：链路已判失活时立刻以显式错误失败，
  /// 不在一条判死的链路上开新会话。守卫只看"通道是否打开成功"，不管会话本身跑多久。
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
  }) {
    return _link.guard(
      () => _transport.openShell(
        columns: columns,
        rows: rows,
        command: command,
        workingDirectory: root,
      ),
    );
  }

  @override
  Future<void> close() => _transport.close();

  Future<List<int>> _read(String absolute, String relativePath) async {
    try {
      return await _link.guard(() => _transport.read(absolute));
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('读取失败（$relativePath）：$error');
    }
  }

  /// 流式读取的活性守卫（M9 1.1）。
  ///
  /// 流没法用 [SshLiveness.guard] 包（它返回的是 Stream 不是 Future），但"远端
  /// 半天不给下一块"正是最容易永久挂住的地方：这里逐块与"链路被判失活"的信号
  /// 赛跑，失活就以显式的心跳丢失错误结束这个流，而不是让下载一直等下去。
  /// 每拿到一块都记一次心跳（数据在动 = 链路活着），正常链路上零行为变化。
  Stream<List<int>> _guardStream(Stream<List<int>> source) async* {
    final SshLiveness link = _link;
    link.ensureAlive();
    final StreamIterator<List<int>> iterator = StreamIterator<List<int>>(
      source,
    );
    try {
      while (true) {
        final Completer<void> stale = link.watchStale();
        final Future<bool> next = Future.any<bool>(<Future<bool>>[
          iterator.moveNext(),
          stale.future.then<bool>(
            (void _) => throw SshLinkStaleException(link.staleMessage),
          ),
        ]);
        // 信号用完必须注销：失活信号只唤醒"当时在途"的操作。两条分支都显式
        // 处理，别派生出一个"没人接错误"的 future（那会变成未捕获异常）。
        next.then(
          (bool _) => link.unwatchStale(stale),
          onError: (Object _) => link.unwatchStale(stale),
        );
        final bool hasNext = await next;
        if (!hasNext) return;
        link.recordBeat();
        yield iterator.current;
      }
    } finally {
      // 取消订阅但**不 await**：源流卡在"永远不来的下一块"上时，cancel 的 future
      // 也永远不会完成（async* 生成器停在 await 上没法被终止），而这里要的是把
      // 显式错误立刻交给调用方——1.1 明确要求"不要永久挂起"。
      unawaited(iterator.cancel().catchError((Object _) {}));
    }
  }

  static RegExp _buildPattern(GrepQuery query) {
    final String source = query.regex
        ? query.pattern
        : RegExp.escape(query.pattern);
    try {
      return RegExp(source, caseSensitive: !query.ignoreCase, multiLine: true);
    } on FormatException catch (error) {
      throw WorkspaceIoException('正则表达式非法：${error.message}');
    }
  }

  static int _count(String haystack, String needle) {
    int count = 0;
    int index = haystack.indexOf(needle);
    while (index >= 0) {
      count++;
      index = haystack.indexOf(needle, index + needle.length);
    }
    return count;
  }

  static bool _matchesGlob(String name, String glob) {
    final String pattern = RegExp.escape(glob)
        .replaceAll(r'\*', '.*')
        .replaceAll(r'\?', '.');
    return RegExp(
      '^$pattern'
      r'$',
    ).hasMatch(name);
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static String _truncate(String text, int maxBytes) {
    if (text.length <= maxBytes) return text;
    final int head = (maxBytes * 0.6).round();
    final int tail = maxBytes - head;
    return '${text.substring(0, head)}\n…（输出过长已截断）…\n'
        '${text.substring(text.length - tail)}';
  }
}
