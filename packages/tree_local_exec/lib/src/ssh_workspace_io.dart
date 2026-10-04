import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ansi_code_page.dart';
import 'background_exec.dart';
import 'git_output.dart';
import 'local_workspace_io.dart';
import 'ssh_liveness.dart';
import 'ssh_login_shell.dart';
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
  /// [timeout] 是 **2026-10-03 恢复的软超时**：由 [SshWorkspaceIO.exec] 兑现
  /// （到点**不再等**，以 [SshExecStillRunning] 交出仍在跑的远端命令）。
  /// 本层仍然**不按时间终止**任何命令：M9 1.1 的判据是活性——只要心跳还在回，
  /// 远端命令跑多久都等；心跳连续丢失才由 [liveness] 判失活，让在途操作以显式错误
  /// （[SshLinkStaleException]）结束，而不是静默挂起。因此这个参数只是**透传**给
  /// 实现层做记录，本层不拿它切时间。
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

/// 软超时到点、远端命令**仍在运行**（没有终止、也没有重跑）。
///
/// 由 [SshWorkspaceIO.exec] 抛出：调用方（terminal 的 hook 模式）拿到 [running] 后
/// 把它登记成后台任务即可——SSH 通道仍然开着，远端那条命令照常跑完，
/// [RunningSshExec.result] 会在它真正结束时给出退出码与完整输出。
///
/// 与本地 [LocalExecStillRunning] 是**同一套语义、同一套命名**（`command` /
/// `running` / `elapsed` / `message`），差别只在句柄（[RunningSshExec]）：远端进程不
/// 归本机管——没有 pid、也没有可以杀的进程树。
class SshExecStillRunning implements Exception {
  SshExecStillRunning(this.command, this.running, this.elapsed);

  /// 原命令。
  final String command;

  /// 仍在运行的远端命令句柄。
  final RunningSshExec running;

  /// 已经等了多久（≈ 软超时值）。
  final Duration elapsed;

  String get message =>
      '远端命令已运行 ${elapsed.inSeconds}s 仍未结束'
      '（**没有终止它**：远端进程未被杀，SSH 通道也没关）';

  @override
  String toString() => message;
}

/// 一条**仍在运行**的远端命令（软超时交接用）。
///
/// 与本地 [RunningLocalExec] 对齐的成员：原命令 [command]、退出码 [exitCode]、
/// 输出快照 [snapshotText]；差别只有一处——远端 exec 是**一次性回包**（命令跑完才把
/// 输出交回来），所以命令结束前没有输出快照可给；远端进程也不在本机手上，杀不掉。
///
/// 命令**没有被终止**、SSH 通道也**没有关**：[result] 会在它真正结束时完成；
/// 链路被判失活（心跳连续丢失）时以 [SshLinkStaleException] 显式失败——与既有口径
/// 一致，既不静默挂起，也不假装知道远端的状态。
class RunningSshExec {
  RunningSshExec._(this.command, this.result) {
    // 记下结束时的结果供 [snapshotText] 用。失活错误由 [result] 自己如实上抛，
    // 这里只是登记（不是第二个错误出口）。
    unawaited(
      result.then<void>(
        (SshExecResult value) => _done = value,
        onError: (Object _) {},
      ),
    );
  }

  /// 原命令。
  final String command;

  /// 远端命令**真正结束**时的结果（退出码 + 完整输出，未截断）。
  final Future<SshExecResult> result;

  SshExecResult? _done;

  /// 它真正退出时的退出码（还在跑时不会完成；链路判失活时以
  /// [SshLinkStaleException] 失败）。
  Future<int> get exitCode => result.then((SshExecResult r) => r.exitCode);

  /// 到目前为止捕获到的输出（stdout/stderr 分段标注）。
  ///
  /// 远端 exec 是**一次性回包**：命令结束前拿不到任何输出，这里如实说明；
  /// 结束之后给出完整输出（与 [result] 同源，不另存一份字节）。
  String snapshotText() {
    final SshExecResult? done = _done;
    final StringBuffer buffer = StringBuffer();
    if (done == null) {
      buffer.writeln('（远端命令仍在运行：输出要等它结束才一次性回来）');
      return buffer.toString().trimRight();
    }
    final String stdout = done.stdout;
    final String stderr = done.stderr;
    if (stdout.trim().isNotEmpty) {
      buffer
        ..writeln('--- stdout ---')
        ..writeln(stdout.trimRight());
    }
    if (stderr.trim().isNotEmpty) {
      buffer
        ..writeln('--- stderr ---')
        ..writeln(stderr.trimRight());
    }
    if (stdout.trim().isEmpty && stderr.trim().isEmpty) {
      buffer.writeln('（暂无输出）');
    }
    return buffer.toString().trimRight();
  }
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
class SshWorkspaceIO implements WorkspaceIO, WorkspaceFiles, BackgroundExecHost {
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
    Duration timeout = Duration.zero,
    int maxOutputBytes = 200 * 1024,
  }) async {
    // [timeout] 的语义（2026-10-03 修订；与本地实现同一套，见 workspace_io.dart）：
    // - `Duration.zero`（默认，或任何 ≤ zero 的值）= **永不软超时**：老行为——远端
    //   命令跑多久就等多久，活性判据是心跳，链路判失活时以 [SshLinkStaleException]
    //   显式失败（M9 1.1）；
    // - `> zero` = **软超时**：到点仍在跑就**不杀远端进程、不重跑、不关通道、不丢
    //   输出**，以 [SshExecStillRunning] 把仍在跑的远端命令交出来，由调用方
    //   （terminal 的 hook 模式）登记成后台任务继续收尾。
    // 硬超时（按时间杀命令）依然**不存在**：这里到点只是"不再等"，那条命令在远端照常
    // 跑完——它的输出与退出码只能由接手方（[RunningSshExec]）收，所以交接方必须接手。
    final String trimmed = command.trim();
    if (trimmed.isEmpty) throw WorkspaceIoException('command 不能为空');
    final Future<SshExecResult> pending = _link.guard(
      () => _transport.run('cd ${_quote(root)} && $trimmed', timeout: timeout),
    );
    if (timeout <= Duration.zero) {
      return _outcome(await pending, maxOutputBytes);
    }
    final Stopwatch watch = Stopwatch()..start();
    final Completer<void> reached = Completer<void>();
    final Timer timer = Timer(timeout, () {
      if (!reached.isCompleted) reached.complete();
    });
    // 谁先到：远端命令真的结束（照常收尾），还是软超时（把命令交出去）
    final bool finished = await Future.any(<Future<bool>>[
      pending.then((SshExecResult _) => true),
      reached.future.then((void _) => false),
    ]);
    timer.cancel();
    if (!finished) {
      throw SshExecStillRunning(
        trimmed,
        RunningSshExec._(trimmed, pending),
        watch.elapsed,
      );
    }
    return _outcome(await pending, maxOutputBytes);
  }

  /// 把一次远端 exec 的原始结果翻成 [ExecOutcome]（截断与 shell 标注沿用既有口径）。
  ExecOutcome _outcome(SshExecResult result, int maxOutputBytes) => ExecOutcome(
    exitCode: result.exitCode,
    stdout: _truncate(result.stdout, maxOutputBytes),
    stderr: _truncate(result.stderr, maxOutputBytes),
    timedOut: result.timedOut,
    truncated: result.stdout.length + result.stderr.length > maxOutputBytes,
    shell: 'ssh',
  );

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

  // ── 后台执行（terminal 的 hook=true，远端分支）────────────────────────────
  //
  // 与本地实现同一套语义（见 background_exec.dart），差别都是远端固有的、且**如实**：
  // - 命令在**远端**跑（`nohup`），日志是**远端**文件；
  // - 退出码靠"包装子 shell 结束时把 $? 写进哨兵文件 + 本机按间隔轮询"取回；
  // - 远端进程不归本机管：`cancel` 只能尽力（拿不到 pid 就返回 false），关停**不杀**
  //   （关应用不该杀掉远端训练），由下次启动的 [attachBackground] 接续。

  /// 退出码哨兵的工作空间相对路径：`<日志去扩展名>.exit`。
  ///
  /// 规则固定在这里：接续（[attachBackground]）用同一条规则重算，落盘台账因此只需记
  /// 日志相对路径，不必另存哨兵路径。
  String exitMarkerRelativePath(String logRelativePath) {
    final String log = logRelativePath.trim();
    final int slash = log.lastIndexOf('/');
    final int dot = log.lastIndexOf('.');
    final String base = dot > slash ? log.substring(0, dot) : log;
    return '$base.exit';
  }

  @override
  Future<BackgroundExecHandle> startBackground({
    required String command,
    required String logRelativePath,
  }) async {
    final String trimmed = command.trim();
    if (trimmed.isEmpty) throw WorkspaceIoException('command 不能为空');
    final String logAbsolute = resolve(logRelativePath);
    final String markerAbsolute = resolve(
      exitMarkerRelativePath(logRelativePath),
    );
    // 包装命令（整条再经 [SshTransport.run] 的登录外壳包装）：
    //
    //   mkdir -p <log 父目录> && cd <root> \
    //     && { nohup sh -c '<cmd> ; printf %s $? > <marker>' \
    //            > <log> 2>&1 < /dev/null ; } & echo $!
    //
    // - 三路重定向 + `< /dev/null` ⇒ SSH exec 通道能**立刻**收工（远端没有东西再写通道）；
    // - `nohup` 让命令免疫会话结束时的 SIGHUP（关掉连接后照常跑完）；
    // - `{ ... ; } &` 把整条链放到后台，`echo $!` 给出包装子 shell 的 pid；
    // - 命令结束时由子 shell 把 `$?` 写进哨兵文件，本机因此能拿到退出码。
    //
    // 内层用 `sh -c`（POSIX）：远端不一定有 bash（登录外壳是**探测 + 回退**出来的，
    // 见 ssh_login_shell.dart），所以这里只依赖 POSIX。代价如实记录：后台命令跑在
    // `sh -c` 里，与同步执行的登录外壳（`bash -lc`）在 bash 专有语法上有差异。
    final String shellCommand =
        'mkdir -p ${_quote(p.posix.dirname(logAbsolute))} '
        '&& cd ${_quote(root)} '
        '&& { nohup sh -c '
        '${posixSingleQuote('$trimmed ; printf %s \$? > ${posixSingleQuote(markerAbsolute)}')} '
        '> ${_quote(logAbsolute)} 2>&1 < /dev/null ; } & echo \$!';
    final SshExecResult started = await _runRaw(shellCommand);
    final int? pid = _parsePid(started.stdout);
    return _SshBackgroundExec(
      host: this,
      logAbsolute: logAbsolute,
      markerAbsolute: markerAbsolute,
      remotePid: pid,
    );
  }

  @override
  Future<BackgroundExecHandle> attachBackground({
    required String command,
    required String logRelativePath,
    int? pid,
  }) async {
    // **不重跑、不新起**：远端那条命令照常在跑，这里只是重新挂上"等它结束"的那条路
    // （哨兵轮询）。首次探测在 [BackgroundExecHandle.exitCode] 被取用时立刻发生，
    // 因此"重启时它其实已经跑完"这种情况会马上收尾。
    return _SshBackgroundExec(
      host: this,
      logAbsolute: resolve(logRelativePath),
      markerAbsolute: resolve(exitMarkerRelativePath(logRelativePath)),
      remotePid: pid,
    );
  }

  @override
  Future<void> appendLog(String relativePath, String text) async {
    if (text.isEmpty) return;
    try {
      final String absolute = resolve(relativePath);
      await _runRaw(
        'mkdir -p ${_quote(p.posix.dirname(absolute))} '
        '&& printf %s ${posixSingleQuote(text)} >> ${_quote(absolute)}',
      );
    } catch (_) {
      // 约定：日志写不进去不抛（失败不该害死任务本身）。
    }
  }

  @override
  Future<String?> readTail(String relativePath, int maxChars) async {
    try {
      final String absolute = resolve(relativePath);
      // 多读 1 字节以便判断"是否被截断"，然后在 Dart 侧裁到 maxChars。
      final SshExecResult result = await _runRaw(
        'tail -c ${maxChars + 1} ${_quote(absolute)} 2>/dev/null',
      );
      if (result.exitCode != 0) return null;
      final String text = result.stdout;
      if (text.isEmpty) return null;
      return text.length <= maxChars
          ? text
          : text.substring(text.length - maxChars);
    } catch (_) {
      // 读不到就返回 null（调用方据此不显示日志尾部），不抛。
      return null;
    }
  }

  /// 后台任务用的一条远端命令（轮询 / kill / 日志读写都走它）；过活性守卫。
  Future<SshExecResult> _runRaw(String command) =>
      _link.guard(() => _transport.run(command, timeout: Duration.zero));

  /// 从 `echo $!` 的输出里取 pid（远端 profile 可能往 stdout 打欢迎语，取最后一行数字）。
  static int? _parsePid(String stdout) {
    final List<String> lines = stdout
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
    for (final String line in lines.reversed) {
      final int? value = int.tryParse(line);
      if (value != null && value > 0) return value;
    }
    return null;
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

/// 一条**仍在远端跑**的后台命令句柄（[SshWorkspaceIO.startBackground] /
/// [SshWorkspaceIO.attachBackground] 的返回值）。
///
/// 为什么是轮询而不是"进程句柄"：远端 exec 是一次性回包，SSH 通道上没有 `Process`
/// 这种东西。所以包装命令在**结束时**把 `$?` 写进哨兵文件，这里按
/// [_SshBackgroundExec.pollInterval] 轮询一条远端命令把它读回来。
///
/// 轮询同时判 pid（`kill -0`）：进程已消失但哨兵缺失（被 `kill -9`、机器重启等）⇒
/// 给可辨退出码 [BackgroundExecHandle.goneExitCode]，**不假装是正常退出**。
/// 链路判失活时 [exitCode] 以显式错误结束（同 `RunningSshExec` 的口径）。
class _SshBackgroundExec implements BackgroundExecHandle {
  _SshBackgroundExec({
    required this.host,
    required this.logAbsolute,
    required this.markerAbsolute,
    required this.remotePid,
  });

  /// 轮询间隔：结束唤醒的最坏延迟就是它。
  static const Duration pollInterval = Duration(seconds: 3);

  static const String _runningToken = '__TREE_RUNNING__';
  static const String _goneToken = '__TREE_GONE__';

  /// 提供远端执行与本工作空间根的宿主（轮询 / kill / 日志读写都经它）。
  final SshWorkspaceIO host;

  /// 远端日志 / 哨兵的绝对路径。
  final String logAbsolute;
  final String markerAbsolute;

  /// 包装子 shell 的远端 pid（拿不到时为 null ⇒ 只按哨兵判结束、cancel 如实失败）。
  final int? remotePid;

  final Completer<int> _exit = Completer<int>();
  Timer? _poll;
  bool _closed = false;

  @override
  int? get pid => remotePid;

  @override
  bool get remote => true;

  @override
  Future<int> get exitCode {
    _startPolling();
    return _exit.future;
  }

  @override
  Future<bool> cancel() async {
    final int? target = remotePid;
    // 没有 pid ⇒ **如实**说杀不掉（远端进程不归本机管，别假装成功）。
    if (target == null) return false;
    try {
      // 先按**进程组**（远端命令常有自己的子进程），再退回单进程——都是尽力而为。
      // 返回 true 只表示"终止信号确实发出去了"，不代表远端一定收干净。
      final SshExecResult result = await host._runRaw(
        'kill -TERM -$target 2>/dev/null; kill -TERM $target 2>/dev/null; '
        'echo done',
      );
      return result.exitCode == 0 && result.stdout.contains('done');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    // 远端**不杀**：关掉桌面应用不该杀掉远端正在跑的训练/构建。只停本机轮询，
    // 远端任务由下次启动的接续逻辑接管。
    _closed = true;
    _poll?.cancel();
    _poll = null;
  }

  void _startPolling() {
    if (_poll != null || _closed || _exit.isCompleted) return;
    // 立刻查一次：接续场景下"重启时其实已经跑完"要马上收尾，不等第一个间隔。
    unawaited(_probe());
    _poll = Timer.periodic(pollInterval, (Timer _) => unawaited(_probe()));
  }

  String _probeCommand() {
    final String marker = markerAbsolute.replaceAll("'", "'\\''");
    final int? target = remotePid;
    if (target == null) {
      // 没有 pid：只能看哨兵；没有哨兵就当"仍在跑"（不猜）。
      return "if [ -f '$marker' ]; then cat '$marker'; "
          'else echo $_runningToken; fi';
    }
    return "if [ -f '$marker' ]; then cat '$marker'; "
        'elif kill -0 $target 2>/dev/null; then echo $_runningToken; '
        'else echo $_goneToken; fi';
  }

  Future<void> _probe() async {
    if (_exit.isCompleted || _closed) return;
    try {
      final SshExecResult result = await host._runRaw(_probeCommand());
      if (_exit.isCompleted || _closed) return;
      final String out = result.stdout.trim();
      if (out.contains(_runningToken)) return;
      if (out.contains(_goneToken)) {
        _finish(BackgroundExecHandle.goneExitCode);
        return;
      }
      final int? code = _lastInt(out);
      if (code != null) {
        _finish(code);
        return;
      }
      // 输出不是预期形状（远端 shell 噪声）：继续轮询，**不猜**。
    } catch (error) {
      // 链路判失活等：以显式错误结束（调用方据此记 remoteFailureExitCode 并如实标注）。
      _fail(error);
    }
  }

  void _finish(int code) {
    _poll?.cancel();
    _poll = null;
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void _fail(Object error) {
    _poll?.cancel();
    _poll = null;
    if (!_exit.isCompleted) {
      _exit.completeError(
        error is Exception ? error : WorkspaceIoException('$error'),
      );
    }
  }

  /// 取最后一行可解析为整数的文本（远端 profile 可能往 stdout 打欢迎语）。
  static int? _lastInt(String text) {
    for (final String line in text.split('\n').reversed) {
      final int? value = int.tryParse(line.trim());
      if (value != null) return value;
    }
    return null;
  }
}
