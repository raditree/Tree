import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ansi_code_page.dart';
import 'git_output.dart';
import 'shell.dart';
import 'workspace_io.dart';

/// 工具层把 IO 失败翻成"模型可读的错误结果"时使用的异常。
class WorkspaceIoException implements Exception {
  WorkspaceIoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 软超时到点、命令**仍在本地运行**（没有终止、也没有重跑）。
///
/// 由 [LocalWorkspaceIO.exec] 抛出：调用方（terminal 的 hook 模式）拿到 [running]
/// 后把它登记成后台任务即可——进程与输出订阅都还活着，照常收尾（退出码、输出、
/// 取消、唤醒 agent）。**不登记就等于把这条命令的输出留在内存里**，所以要么交给
/// hook，要么自己用 [RunningLocalExec.exitCode] 收尾。
class LocalExecStillRunning implements Exception {
  LocalExecStillRunning(this.command, this.running, this.elapsed);

  /// 原命令。
  final String command;

  /// 仍在运行的进程句柄（含到目前为止的输出）。
  final RunningLocalExec running;

  /// 已经等了多久（≈ 软超时值）。
  final Duration elapsed;

  String get message =>
      '命令已运行 ${elapsed.inSeconds}s 仍未结束（pid=${running.pid}）';

  @override
  String toString() => message;
}

/// 一条**仍在运行**的本机命令（软超时交接用）。
///
/// 进程没被杀、输出订阅也还在收字节：[exitCode] 会在它真正退出时完成，
/// [snapshotText] 给出"到目前为止"的输出（走执行器同一条解码链）。
///
/// 为什么不需要持有订阅：`Stream.listen` 的订阅由流本身持有，而流由 [process]
/// 持有（我们一直引用着它），所以订阅不会被 GC 掉，交接后照常收字节。
class RunningLocalExec {
  RunningLocalExec._(this.process, this.command, this._out, this._err);

  /// 本机进程句柄（要主动终止用 `Shell.killProcessTree(process.pid)`）。
  final Process process;

  /// 原命令。
  final String command;

  final _OutputCollector _out;
  final _OutputCollector _err;

  int get pid => process.pid;

  /// 它真正退出时的退出码（还在跑时不会完成）。
  Future<int> get exitCode => process.exitCode;

  /// 到目前为止捕获到的输出（stdout/stderr 分段标注）。
  ///
  /// 取的是**快照**：采纳时写一次进 hook 日志，命令结束时再写一次完整版。
  String snapshotText() {
    final StringBuffer buffer = StringBuffer();
    final String stdout = _out.decoded.text;
    final String stderr = _err.decoded.text;
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

/// [WorkspaceIO] 的**本地**实现（`dart:io`）。
///
/// Windows 上踩过的坑（M0b 迁移清单要求原样保留）：
/// - 命令走 PowerShell（优先 pwsh，其次系统自带 Windows PowerShell，都没才回退 cmd，
///   见 [Shell]）：cmd 内建命令（dir/type…）的管道输出是**系统 ANSI 代码页**（GBK）字节，
///   `chcp` 管不住管道——所以下面那级按代码页解码必须保留；
/// - 输出解码走**严格 UTF-8 → 系统 ANSI 代码页（Windows = CP_ACP）→ latin1 兜底**：
///   cmd 内建命令写管道用的就是系统代码页，chcp 管不住（详见 [decodeBytes]）；
///   只有连代码页也解不开时才落到 latin1 保字节兜底，并标成"真乱码"；
/// - 超时杀进程要用 `taskkill /T` 杀**整棵进程树**，否则 `cmd` 死了子进程还在跑。
///
/// 路径安全：一切工具参数都是工作空间相对路径，[resolve] 拒绝绝对路径/盘符/UNC
/// 以及 `..` 越界。注意符号链接可以绕过（本机单用户场景接受该风险，已在文档中
/// 记录；真要防需要 O_NOFOLLOW 级别的处理，Dart 标准库不提供）。
class LocalWorkspaceIO implements WorkspaceIO, WorkspaceFiles {
  LocalWorkspaceIO(this.root, {this.maxReadBytes = 512 * 1024});

  @override
  final String root;

  /// 无行范围限定时单次读取的字节上限（超过则截断并标记）。
  final int maxReadBytes;

  /// 图像扩展名（返回 base64 而不是文本）。
  static const Set<String> imageExtensions = <String>{
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
  };

  /// grep / list 默认排除的目录名（依赖与构建产物）。
  ///
  /// 这是**硬黑名单**：即便 [GrepQuery.includeHidden] 打开（grep 去搜隐藏路径），
  /// 名单里的目录仍然会被跳过——`.git` 这类默认永不检索是有意的。
  /// 其余隐藏路径（不在名单里的）由 [isHiddenPathName] 那套默认口径处理。
  static const Set<String> defaultExcludedDirs = <String>{
    '.git',
    '.venv',
    'venv',
    'node_modules',
    '.pub-cache',
    '.dart_tool',
    'build',
    'dist',
    '__pycache__',
    '.mypy_cache',
    '.pytest_cache',
    '.ruff_cache',
    '.tox',
  };

  @override
  String resolve(String relativePath) {
    final String raw = relativePath.trim();
    if (raw.isEmpty) {
      throw WorkspacePathException(relativePath, '路径不能为空');
    }
    if (raw.startsWith('~') ||
        p.isAbsolute(raw) ||
        raw.startsWith('/') ||
        raw.startsWith(r'\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
      throw WorkspacePathException(relativePath, '必须是工作空间内的相对路径（禁止绝对路径、盘符与 ~）');
    }
    final String absolute = p.normalize(p.join(root, raw));
    if (!_isInsideRoot(absolute)) {
      throw WorkspacePathException(relativePath, '越出工作空间根目录');
    }
    return absolute;
  }

  bool _isInsideRoot(String absolute) {
    final String base = p.normalize(root);
    final String a = Platform.isWindows ? base.toLowerCase() : base;
    final String b = Platform.isWindows ? absolute.toLowerCase() : absolute;
    return a == b || p.isWithin(a, b);
  }

  /// 工作空间相对路径（把绝对路径转回去，供工具输出用）。
  ///
  /// Windows 上 `p.relative` 用反斜杠分隔，统一成正斜杠：工具输出里的路径要
  /// 跨平台一致，模型也更容易照着写进后续参数。
  String relativize(String absolute) {
    final String rel = p.relative(absolute, from: root);
    return rel.replaceAll('\\', '/');
  }

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) async {
    final String absolute = resolve(relativePath);
    final File file = File(absolute);
    if (!await file.exists()) {
      throw WorkspaceIoException('文件不存在：$relativePath');
    }
    final FileStat stat = await file.stat();
    if (stat.type == FileSystemEntityType.directory) {
      throw WorkspaceIoException('这是一个目录，不是文件：$relativePath');
    }
    final String ext = p
        .extension(absolute)
        .replaceFirst('.', '')
        .toLowerCase();
    final int limit = maxBytes ?? maxReadBytes;

    if (imageExtensions.contains(ext)) {
      final List<int> bytes = await file.readAsBytes();
      return FileContent(
        path: relativePath,
        text: '',
        base64: base64Encode(bytes),
        language: ext,
      );
    }

    final List<int> bytes = await file.readAsBytes();
    if (_looksBinary(bytes)) {
      throw WorkspaceIoException(
        '这是二进制文件（${bytes.length} 字节），无法作为文本读取：$relativePath',
      );
    }
    String text = decodeBytes(bytes);
    bool truncated = false;
    if (startLine == null && text.length > limit) {
      // 无行范围的大文件：按行截断，避免一次把整份日志塞进上下文
      final List<String> lines = const LineSplitter().convert(text);
      final StringBuffer buffer = StringBuffer();
      for (final String line in lines) {
        if (buffer.length + line.length + 1 > limit) {
          truncated = true;
          break;
        }
        buffer.writeln(line);
      }
      text = buffer.toString();
    }

    final List<String> allLines = const LineSplitter().convert(text);
    final int totalLines = allLines.length;
    final int start = (startLine == null || startLine < 1) ? 1 : startLine;
    if (start > totalLines && totalLines > 0) {
      throw WorkspaceIoException(
        'start_line=$start 超出文件总行数（$totalLines）：$relativePath',
      );
    }
    final int from = start - 1;
    final int to = (lineCount == null || lineCount <= 0)
        ? totalLines
        : (from + lineCount > totalLines ? totalLines : from + lineCount);
    final String selected = allLines.sublist(from, to).join('\n');
    return FileContent(
      path: relativePath,
      text: selected,
      totalLines: totalLines,
      startLine: start,
      truncated: truncated || to < totalLines,
      language: ext,
    );
  }

  /// 覆盖写时"嗅探原编码"的体积上限：超过它就只按 UTF-8 写。
  ///
  /// 取舍：写工具是**整段替换**，为保编码把超大文件整读一遍不值当；1 MiB 以内读一遍
  /// 换"不把用户的 GBK 文件悄悄转成 UTF-8"，值。
  static const int encodingSniffMaxBytes = 1024 * 1024;

  @override
  Future<int> writeFile(String relativePath, String content) async {
    final String absolute = resolve(relativePath);
    final File file = File(absolute);
    await file.parent.create(recursive: true);
    final List<int> bytes = await _encodeForExisting(
      file,
      content,
      relativePath,
    );
    await file.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

  @override
  Future<bool> deleteFile(String relativePath) async {
    final String absolute = resolve(relativePath);
    final FileSystemEntityType type = await FileSystemEntity.type(absolute);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw WorkspaceIoException('目标不是文件（拒绝删除目录）：$relativePath');
    }
    await File(absolute).delete();
    return true;
  }

  /// 覆盖写时尽量沿用**已有文件的编码**（[PlatformTextDecoder.encodeLike]）。
  ///
  /// - 文件不存在 / 空文件 / 超过 [_encodingSniffMaxBytes]：按 UTF-8 写（write 的默认语义）；
  /// - 已有文件是 UTF-8：按 UTF-8 写；
  /// - 已有文件是非 UTF-8：用**同一个代码页**写回；编不回去就**显式拒绝**，
  ///   绝不静默转成 UTF-8——那等于替用户改文件编码。
  Future<List<int>> _encodeForExisting(
    File file,
    String content,
    String relativePath,
  ) async {
    if (!await file.exists()) return utf8.encode(content);
    final int size = await file.length();
    if (size == 0 || size > encodingSniffMaxBytes) return utf8.encode(content);
    final DecodedText existing = PlatformTextDecoder.decode(
      await file.readAsBytes(),
    );
    if (existing.isUtf8) return utf8.encode(content);
    final List<int>? bytes = PlatformTextDecoder.encodeLike(existing, content);
    if (bytes == null) {
      throw WorkspaceIoException(
        '该文件不是 UTF-8（检测为 ${decodingLabel(existing.decoding)}），'
        '新内容里有原编码表示不了的字符，按原编码写回会损坏文件；'
        '请改写内容，或先用工具把文件转成 UTF-8：$relativePath',
      );
    }
    return bytes;
  }

  /// 解码路径的中文标签：错误信息里要能说清"检测成什么编码"。
  static String decodingLabel(TextDecoding decoding) => switch (decoding) {
    TextDecoding.utf8 => 'UTF-8',
    TextDecoding.utf8Malformed => 'UTF-8（含非法字节）',
    TextDecoding.systemCodePage =>
      '系统代码页 CP${AnsiCodePage.systemCodePage ?? '?'}',
    TextDecoding.latin1Fallback => 'latin1（既不是 UTF-8 也不是合法系统代码页）',
  };

  @override
  Future<EditOutcome> editFile(
    String relativePath, {
    required String oldText,
    required String newText,
    bool replaceAll = false,
  }) async {
    if (oldText.isEmpty) {
      throw WorkspaceIoException('old_text 不能为空');
    }
    final String absolute = resolve(relativePath);
    final File file = File(absolute);
    if (!await file.exists()) {
      throw WorkspaceIoException('文件不存在：$relativePath');
    }
    final List<int> rawBytes = await file.readAsBytes();
    // 解码结果连同"走的哪条路径"一起留着：写回必须用同一条路径编码，否则就是静默转码
    final DecodedText original = PlatformTextDecoder.decode(rawBytes);
    // 换行兼容：模型给的片段可能是 LF，而文件是 CRLF（Windows 常见）
    final bool fileUsesCrlf = original.text.contains('\r\n');
    final String haystack = fileUsesCrlf
        ? original.text.replaceAll('\r\n', '\n')
        : original.text;
    final String needle = oldText.replaceAll('\r\n', '\n');
    final String replacement = newText.replaceAll('\r\n', '\n');

    final int occurrences = _countOccurrences(haystack, needle);
    if (occurrences == 0) {
      throw WorkspaceIoException(
        '未找到 old_text 的内容（已做 LF/CRLF 兼容匹配）：$relativePath；'
        '请先用 read 确认原文',
      );
    }
    if (occurrences > 1 && !replaceAll) {
      throw WorkspaceIoException(
        'old_text 在文件中出现 $occurrences 次，无法唯一定位：$relativePath；'
        '请提供更长的唯一片段，或设置 replace_all=true',
      );
    }
    final String updated = haystack.replaceAll(needle, replacement);
    final String restored = fileUsesCrlf
        ? updated.replaceAll('\n', '\r\n')
        : updated;
    // 保编码写回（[encodeForWriteBack]）：非 UTF-8 文件按原代码页写回，且要求逐字节可还原；
    // 做不到就**显式拒绝**——绝不静默把 GBK 文件转成 UTF-8 写下去。
    final List<int>? bytes = encodeForWriteBack(original, rawBytes, restored);
    if (bytes == null) {
      throw WorkspaceIoException(
        '该文件不是 UTF-8（检测为 ${decodingLabel(original.decoding)}），'
        '按原编码写回无法逐字节还原（新内容里有该编码表示不了的字符，或重新编码会改动'
        '未触碰的字节），已拒绝编辑：$relativePath；请先用工具把文件转成 UTF-8',
      );
    }
    await file.writeAsBytes(bytes, flush: true);
    return EditOutcome(
      path: relativePath,
      replacements: replaceAll ? occurrences : 1,
      bytesWritten: bytes.length,
    );
  }

  @override
  Future<GrepOutcome> grep(GrepQuery query) async {
    final String start = resolve(query.relativePath);
    final bool startIsFile = FileSystemEntity.isFileSync(start);
    final Directory startDir = startIsFile
        ? Directory(p.dirname(start))
        : Directory(start);
    final RegExp pattern = _buildPattern(query);
    final List<String> extras = query.exclude;
    final List<GrepMatch> matches = <GrepMatch>[];
    // Q10：扫描清单与"实际生效的排除目录"在遍历/读取过程中顺手记录，
    // 复用下面这一次遍历与这一轮读取，不额外扫一遍树。
    final List<String> scannedPaths = <String>[];
    final List<String> excludedDirs = <String>[];
    int scanned = 0;
    bool truncated = false;

    final List<File> files = <File>[];
    if (startIsFile) {
      files.add(File(start));
    } else {
      _walk(
        startDir,
        query.maxDepth,
        (FileSystemEntity entity) {
          if (entity is File) files.add(entity);
        },
        excludedDirs: defaultExcludedDirs,
        extraExcludes: extras,
        respectExclusion: true,
        skipHidden: !query.includeHidden,
        onExcludedDir: (Directory dir) {
          if (excludedDirs.length >= GrepOutcome.maxExcludedDirs) return;
          excludedDirs.add(relativize(dir.path));
        },
      );
    }

    for (final File file in files) {
      if (matches.length >= query.maxResults) {
        truncated = true;
        break;
      }
      final List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        continue;
      }
      if (_looksBinary(bytes)) continue;
      scanned++;
      if (scannedPaths.length < GrepOutcome.maxScannedFilePaths) {
        scannedPaths.add(relativize(file.path));
      }
      final String text = decodeBytes(bytes);
      int lineNumber = 0;
      for (final String line in const LineSplitter().convert(text)) {
        lineNumber++;
        if (!pattern.hasMatch(line)) continue;
        matches.add(
          GrepMatch(
            path: relativize(file.path),
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

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) async {
    final String start = resolve(relativePath);
    if (!FileSystemEntity.isDirectorySync(start)) {
      throw WorkspaceIoException('不是目录：$relativePath');
    }
    final List<String> entries = <String>[];
    _walk(
      Directory(start),
      maxDepth,
      (FileSystemEntity entity) {
        if (entries.length >= maxEntries) return;
        final String rel = relativize(entity.path);
        if (rel.isEmpty) return;
        entries.add(entity is Directory ? '$rel/' : rel);
      },
      excludedDirs: defaultExcludedDirs,
      extraExcludes: const <String>[],
      respectExclusion: true,
      onDirectory: true,
    );
    return entries;
  }

  @override
  Future<ExecOutcome> exec(
    String command, {
    Duration timeout = Duration.zero,
    int maxOutputBytes = 200 * 1024,
  }) async {
    // [timeout] 的语义（2026-10-02 修订）：
    // - `Duration.zero`（默认）= **永不软超时**：老行为——本地执行的活性判据就是
    //   进程还活着（OS 层），进程活着就一直等，绝不因为"太久"去杀它（M9 1.1）；
    // - `> zero` = **软超时**：到点仍在跑就**不杀进程、不丢输出**，带着活着的进程
    //   抛 [LocalExecStillRunning]，由调用方（terminal 的 hook 模式）登记成后台
    //   任务继续收尾。硬超时（按时间杀进程）依然**不存在**。
    final String trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw WorkspaceIoException('command 不能为空');
    }
    await Directory(root).create(recursive: true);
    final Process process = await Process.start(
      Shell.executable,
      Shell.argsFor(trimmed),
      workingDirectory: root,
      runInShell: false,
    );
    // 子进程的 stdin 立刻关掉。
    //
    // 它是 Dart 侧的管道，我们**永远不会往里写**；只要它开着，任何"等输入"的子进程
    // 就会一直等下去：PowerShell 的参数提示（例如裸 `echo` 缺 `-InputObject`）、
    // Read-Host、git 的凭据提示、pause/choice、交互式 REPL……而下面 M9 1.1 说明的
    // 活性判据是"进程还活着"，于是整轮会话永久卡死——2026-10-02 实机事故正是如此
    // （agent 写了 `…; echo; echo "=== …"`，卡了十几分钟不动）。关掉之后这类等待
    // 立刻拿到 EOF：报错/继续，而不是静默挂住。
    await process.stdin.close();
    final _OutputCollector out = _OutputCollector(
      maxOutputBytes: maxOutputBytes,
    );
    final _OutputCollector err = _OutputCollector(
      maxOutputBytes: maxOutputBytes,
    );
    final Completer<void> outDone = Completer<void>();
    final Completer<void> errDone = Completer<void>();
    // onDone 与 onError 都可能在同一个流上触发（出错后流不一定立刻结束），
    // 所以两边都先看 isCompleted，别让第二次 complete 抛"已经完成"。
    final StreamSubscription<List<int>> outSub = process.stdout.listen(
      out.add,
      onDone: () {
        if (!outDone.isCompleted) outDone.complete();
      },
      onError: (Object _) {
        if (!outDone.isCompleted) outDone.complete();
      },
    );
    final StreamSubscription<List<int>> errSub = process.stderr.listen(
      err.add,
      onDone: () {
        if (!errDone.isCompleted) errDone.complete();
      },
      onError: (Object _) {
        if (!errDone.isCompleted) errDone.complete();
      },
    );

    // M9 1.1：本地执行的活性判据就是**进程还活着**（OS 层）——不去按静态时间杀
    // 它（本地执行，不存在服务器上"多用户无限期等待把资源耗光"的后果）。
    // Shell.killProcessTree 因此不在这里用（它仍服务于 terminal 的后台取消）。
    //
    // 2026-10-02：软超时（[timeout] > 0）时**到点就不再等**，把活着的进程交出去
    // （[LocalExecStillRunning]）。这是"命令卡在等输入 / 跑得太久"时唯一能让工具
    // 调用返回的出口，而进程本身一步都没被动过（没杀、没重跑、输出没丢）。
    if (timeout > Duration.zero) {
      final Stopwatch watch = Stopwatch()..start();
      final Completer<void> reached = Completer<void>();
      final Timer timer = Timer(timeout, () {
        if (!reached.isCompleted) reached.complete();
      });
      // 谁先到：进程真的退出（照常收尾），还是软超时（交接给 hook）
      final bool exited = await Future.any(<Future<bool>>[
        process.exitCode.then((int _) => true),
        reached.future.then((void _) => false),
      ]);
      timer.cancel();
      if (!exited) {
        throw LocalExecStillRunning(
          trimmed,
          RunningLocalExec._(process, trimmed, out, err),
          watch.elapsed,
        );
      }
    }
    final int exitCode = await process.exitCode;
    await _drainOutput(
      out,
      err,
      outDone.future,
      errDone.future,
      outSub,
      errSub,
    );

    // 文本与"走了哪条解码路径"来自同一次解码，标注不会和文本对不上。
    final DecodedText outDecoded = out.decoded;
    final DecodedText errDecoded = err.decoded;
    return ExecOutcome(
      exitCode: exitCode,
      stdout: outDecoded.text,
      stderr: errDecoded.text,
      timedOut: false,
      truncated: out.truncated || err.truncated,
      shell: Shell.executable,
      // nonUtf8Output 只说"不是 UTF-8、走了非 UTF-8 解码路径"——Windows 上 cmd
      // 内建命令的管道输出通常已按系统 ANSI 代码页解成可读中文；只有连代码页也
      // 解不开（latin1 保字节兜底）时才是真乱码，由 garbledOutput 如实区分。
      nonUtf8Output: !outDecoded.isUtf8 || !errDecoded.isUtf8,
      garbledOutput: outDecoded.isGarbled || errDecoded.isGarbled,
    );
  }

  // ── Git（M9 Q4）：命令与解析与 SSH 侧共用 git_output.dart ──────────────

  @override
  Future<GitLogOutcome> gitLog({int limit = 50}) async {
    final ProcessResult? result = await _runGit(
      GitOutput.logArgs(GitOutput.clampLimit(limit)),
    );
    if (result == null) {
      return const GitLogOutcome(
        commits: <GitCommit>[],
        exitCode: GitOutput.missingGitExitCode,
      );
    }
    // 非仓库时 git 退出码非 0（且 stdout 是报错文本）：空列表 + 退出码，
    // 不抛异常、也不拿报错文本硬解析出垃圾提交。
    return GitLogOutcome(
      commits: result.exitCode == 0
          ? GitOutput.parseLog('${result.stdout}')
          : const <GitCommit>[],
      exitCode: result.exitCode,
    );
  }

  @override
  Future<GitBranchesOutcome> gitBranches() async {
    final ProcessResult? result = await _runGit(GitOutput.branchArgs());
    if (result == null) {
      return const GitBranchesOutcome(
        branches: <String>[],
        current: '',
        exitCode: GitOutput.missingGitExitCode,
      );
    }
    final ({List<String> branches, String current}) parsed =
        result.exitCode == 0
        ? GitOutput.parseBranches('${result.stdout}')
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
    final ProcessResult? result = await _runGit(
      GitOutput.statusArgs(ignored: ignored),
    );
    if (result == null) {
      return const GitStatusOutcome(
        isRepo: false,
        entries: <GitStatusEntry>[],
        truncated: false,
        exitCode: GitOutput.missingGitExitCode,
      );
    }
    // 非仓库 / 没有 git：退出码非 0、stdout 是报错文本。**不是错误**——
    // isRepo=false + 空列表，面板显示空态（绝不拿报错文本硬解析出垃圾条目）。
    if (result.exitCode != 0) {
      return GitStatusOutcome(
        isRepo: false,
        entries: const <GitStatusEntry>[],
        truncated: false,
        exitCode: result.exitCode,
      );
    }
    final ({List<GitStatusEntry> entries, bool truncated}) parsed =
        GitOutput.parseStatus('${result.stdout}', maxEntries: maxEntries);
    return GitStatusOutcome(
      isRepo: true,
      entries: parsed.entries,
      truncated: parsed.truncated,
      exitCode: 0,
    );
  }

  /// 跑一次 git（cwd = 工作空间根）。
  ///
  /// 本机没有 git 可执行文件（或工作空间目录不存在）时返回 null：调用方按
  /// "没有 git" 处理（空列表 + 127），而不是把 ProcessException 抛给工具层。
  Future<ProcessResult?> _runGit(List<String> args) async {
    try {
      return await Process.run(
        'git',
        args,
        workingDirectory: root,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException {
      return null;
    }
  }

  // ── 文件面板（M7g）：列一层目录 + 原始字节读写 ─────────────────────────

  @override
  Future<List<WorkspaceEntry>> listEntries(
    String relativePath, {
    int maxEntries = 2000,
  }) async {
    final String absolute = resolve(
      relativePath.trim().isEmpty ? '.' : relativePath,
    );
    final Directory dir = Directory(absolute);
    if (!await dir.exists()) {
      throw WorkspaceIoException('目录不存在：$relativePath');
    }
    final List<WorkspaceEntry> out = <WorkspaceEntry>[];
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (out.length >= maxEntries) break;
      FileStat stat;
      try {
        stat = await entity.stat();
      } catch (_) {
        // 列目录途中被删/无权限：跳过这一条，不让整个列举失败
        continue;
      }
      final bool isDir = stat.type == FileSystemEntityType.directory;
      out.add(
        WorkspaceEntry(
          name: p.basename(entity.path),
          relativePath: relativize(entity.path),
          isDirectory: isDir,
          size: isDir ? 0 : stat.size,
          modified: stat.modified,
        ),
      );
    }
    _sortEntries(out);
    return out;
  }

  @override
  Future<Uint8List> readBytes(String relativePath) async {
    final String absolute = resolve(relativePath);
    final File file = File(absolute);
    if (!await file.exists()) {
      throw WorkspaceIoException('文件不存在：$relativePath');
    }
    return file.readAsBytes();
  }

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    final String absolute = resolve(relativePath);
    await File(absolute).parent.create(recursive: true);
    await File(absolute).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<int> sizeOf(String relativePath) async {
    final File file = File(resolve(relativePath));
    if (!await file.exists()) {
      throw WorkspaceIoException('文件不存在：$relativePath');
    }
    return file.length();
  }

  @override
  Stream<List<int>> openRead(
    String relativePath, {
    int offset = 0,
    int? length,
  }) {
    // dart:io 的 openRead(start, end) 里 end 是**排他**上界；null 表示读到结尾
    final int? end = length == null ? null : offset + length;
    return File(resolve(relativePath)).openRead(offset, end);
  }

  @override
  Future<void> writeStream(String relativePath, Stream<List<int>> data) async {
    final File file = File(resolve(relativePath));
    await file.parent.create(recursive: true);
    final IOSink sink = file.openWrite();
    try {
      await sink.addStream(data);
    } finally {
      await sink.close();
    }
  }

  // ── 文件面板的结构改动（M11）：新建目录 / 重命名 / 删除 ─────────────────

  @override
  Future<WorkspaceMutationResult> makeDirectory(String relativePath) async {
    final String absolute = resolve(relativePath);
    final FileSystemEntityType type = await FileSystemEntity.type(absolute);
    if (type != FileSystemEntityType.notFound) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.alreadyExists,
        '目标已存在：$relativePath',
      );
    }
    final Directory parent = Directory(p.dirname(absolute));
    if (!await parent.exists()) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.parentMissing,
        '父目录不存在（不会自动创建）：${relativize(parent.path)}',
      );
    }
    try {
      // 不 recursive：父目录已确认存在，多建层级一定是路径写错了。
      await Directory(absolute).create();
    } on FileSystemException catch (error) {
      throw WorkspaceIoException('新建目录失败（$relativePath）：${error.message}');
    }
    return const WorkspaceMutationResult.ok();
  }

  @override
  Future<WorkspaceMutationResult> rename(String from, String to) async {
    final String source = resolve(from);
    final String target = resolve(to);
    final FileSystemEntityType sourceType = await FileSystemEntity.type(source);
    if (sourceType == FileSystemEntityType.notFound) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.notFound,
        '源路径不存在：$from',
      );
    }
    // 先自检目标：Windows 上文件改名到已存在的名字会直接抛，行为因平台而异，
    // 这里统一成契约里的 alreadyExists（**绝不覆盖**）。
    final FileSystemEntityType targetType = await FileSystemEntity.type(target);
    if (targetType != FileSystemEntityType.notFound) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.alreadyExists,
        '目标已存在（重命名不覆盖）：$to',
      );
    }
    final Directory parent = Directory(p.dirname(target));
    if (!await parent.exists()) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.parentMissing,
        '目标父目录不存在（不会自动创建）：${relativize(parent.path)}',
      );
    }
    try {
      if (sourceType == FileSystemEntityType.directory) {
        await Directory(source).rename(target);
      } else {
        await File(source).rename(target);
      }
    } on FileSystemException catch (error) {
      throw WorkspaceIoException('重命名失败（$from → $to）：${error.message}');
    }
    return const WorkspaceMutationResult.ok();
  }

  @override
  Future<WorkspaceMutationResult> remove(
    String relativePath, {
    bool recursive = false,
  }) async {
    final String absolute = resolve(relativePath);
    final FileSystemEntityType type = await FileSystemEntity.type(absolute);
    if (type == FileSystemEntityType.notFound) {
      return WorkspaceMutationResult(
        WorkspaceMutationStatus.notFound,
        '路径不存在：$relativePath',
      );
    }
    try {
      if (type == FileSystemEntityType.directory) {
        final Directory dir = Directory(absolute);
        if (!recursive && dir.listSync(followLinks: false).isNotEmpty) {
          return WorkspaceMutationResult(
            WorkspaceMutationStatus.notEmpty,
            '目录非空（默认不递归删除）：$relativePath；确要删除请带 recursive=1',
          );
        }
        await dir.delete(recursive: recursive);
      } else {
        await File(absolute).delete();
      }
    } on FileSystemException catch (error) {
      throw WorkspaceIoException('删除失败（$relativePath）：${error.message}');
    }
    return const WorkspaceMutationResult.ok();
  }

  /// 目录在前，各自按名字（不区分大小写）排序——与前端文件树一致。
  static void _sortEntries(List<WorkspaceEntry> entries) {
    entries.sort((WorkspaceEntry a, WorkspaceEntry b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  @override
  Future<void> close() async {}

  // ── 内部工具 ─────────────────────────────────────────────────────────

  /// [exec] 输出收尾的检查节奏、"静默"阈值与兜底上限。
  ///
  /// **只作用于"进程已经退出之后"的残余管道读取**，不参与命令执行时长的判断，
  /// 也不杀任何进程——所以它不是 1.1 要取消的那种"静态总时长超时"。
  static const Duration _drainTick = Duration(milliseconds: 100);
  static const int _drainIdleTicks = 3; // ≈300ms 没有新字节 = 输出已静默
  static const int _drainMaxTicks = 30; // 兜底 ≈3s

  /// 进程退出后的输出收尾（M9 1.1）。
  ///
  /// 进程正常退出时管道会立刻关闭，这里即时返回。收尾判据按"数据还在不在动"：
  /// 连续 [_drainIdleTicks] 次检查都没有新字节就认为输出已经静默。
  ///
  /// 为什么还要一个 [_drainMaxTicks] 兜底：命令派生的后台进程可能一边攥着管道
  /// 写端、一边**持续**输出（典型是 start /b 拉起的 ping 之类），"静默"就永远
  /// 不会到来——那已经不是这条命令的输出了，工具调用不该被它永久挂住。进程已死
  /// 即命令结束，这里只把残余缓冲收干净，超时就取消订阅返回（1.1 要求"不要永久
  /// 挂起"）。
  static Future<void> _drainOutput(
    _OutputCollector out,
    _OutputCollector err,
    Future<void> outDone,
    Future<void> errDone,
    StreamSubscription<List<int>> outSub,
    StreamSubscription<List<int>> errSub,
  ) async {
    bool closed = false;
    Future.wait<void>(<Future<void>>[outDone, errDone])
        .then((void _) => closed = true, onError: (Object _) => closed = true);
    int idleTicks = 0;
    int ticks = 0;
    int seen = out.receivedBytes + err.receivedBytes;
    while (!closed && idleTicks < _drainIdleTicks && ticks < _drainMaxTicks) {
      ticks++;
      await Future<void>.delayed(_drainTick);
      final int now = out.receivedBytes + err.receivedBytes;
      if (now != seen) {
        seen = now;
        idleTicks = 0;
      } else {
        idleTicks++;
      }
    }
    if (!closed) {
      await outSub.cancel();
      await errSub.cancel();
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

  /// 保编码写回：把 [text] 按 [original] 当初的解码路径编回去，**并且**要求原文本能
  /// 逐字节还原（[originalBytes]）。
  ///
  /// 返回 null = **不能安全写回**：可能是编不回去（新文本里有该代码页表示不了的字符），
  /// 也可能是重新编码会改动我们没碰过的字节（代码页里的重复映射）。两种情况都必须由
  /// 调用方**显式拒绝**，绝不能退回 UTF-8 写下去——那是破坏用户文件。
  ///
  /// 本地与 SSH 两条写回路径共用这一份逻辑。
  static List<int>? encodeForWriteBack(
    DecodedText original,
    List<int> originalBytes,
    String text,
  ) {
    if (!original.isUtf8) {
      final List<int>? identity = PlatformTextDecoder.encodeLike(
        original,
        original.text,
      );
      if (identity == null || !_sameBytes(identity, originalBytes)) return null;
    }
    return PlatformTextDecoder.encodeLike(original, text);
  }

  /// 逐字节相等（保编码自检用；不用 ListEquality 免得为一个工具函数引依赖）。
  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _countOccurrences(String haystack, String needle) {
    int count = 0;
    int index = haystack.indexOf(needle);
    while (index >= 0) {
      count++;
      index = haystack.indexOf(needle, index + needle.length);
    }
    return count;
  }

  /// 二进制判定：前 8000 字节里出现 NUL 字节即视为二进制。
  static bool _looksBinary(List<int> bytes) {
    final int limit = bytes.length < 8000 ? bytes.length : 8000;
    for (int i = 0; i < limit; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  /// 统一解码链：**严格 UTF-8 →（Windows）系统 ANSI 代码页 → latin1 兜底**。
  ///
  /// 为什么要按系统代码页解一次：Windows 上 cmd 内建命令（dir/type/echo）与部分
  /// 系统错误信息写到**管道**时用的是**系统 ANSI 代码页**（中文机器 = GBK/CP936），
  /// 而 `chcp 65001` **管不住管道输出**（实测：加不加 chcp，echo 中文都是 GBK 字节）。
  /// 以前严格 UTF-8 解不开就直接 latin1——字节不丢但中文是乱码；现在中间加一级
  /// [AnsiCodePage]（dart:ffi → kernel32 `MultiByteToWideChar(CP_ACP)`，仅 Windows），
  /// 只有"既不是 UTF-8、也不是合法的系统代码页字节序列"时才落到 latin1 兜底。
  ///
  /// 不抛异常、不丢字节：非 Windows / FFI 不可用 / 代码页解不开，一律降级到 latin1
  /// （逐字节映射，可原样还原）。需要区分"已按系统代码页解开"与"真乱码"的调用方，
  /// 用 [PlatformTextDecoder.decode] 取 [DecodedText.decoding]。
  static String decodeBytes(List<int> bytes) =>
      PlatformTextDecoder.decodeToString(bytes);

  /// 递归遍历；[maxDepth] 为 0 表示不限。
  ///
  /// [onExcludedDir] 只在**目录**被排除规则真的跳过时回调（Q10 的排除清单）；
  /// 名字撞上排除规则的普通文件不算"被排除的目录"。
  ///
  /// [skipHidden] 打开时，[isHiddenPathName] 命中的文件/目录与 [excludedDirs]
  /// 同等对待（目录同样进排除清单），列表层因此不需要各自再判一次。
  /// 注意：只判**子项**，起点目录本身不判——调用方显式指到 `.self` 就该搜 `.self`。
  static void _walk(
    Directory dir,
    int maxDepth,
    void Function(FileSystemEntity entity) visit, {
    required Set<String> excludedDirs,
    required List<String> extraExcludes,
    required bool respectExclusion,
    bool skipHidden = false,
    void Function(Directory dir)? onExcludedDir,
    bool onDirectory = false,
    int depth = 0,
  }) {
    if (maxDepth > 0 && depth >= maxDepth) return;
    List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final FileSystemEntity entity in children) {
      final String name = p.basename(entity.path);
      if (respectExclusion) {
        final bool excluded =
            (skipHidden && isHiddenPathName(name)) ||
            excludedDirs.contains(name) ||
            extraExcludes.any((String glob) => _matchesGlob(name, glob));
        if (excluded) {
          if (entity is Directory) onExcludedDir?.call(entity);
          continue;
        }
      }
      if (entity is Directory) {
        if (onDirectory) visit(entity);
        _walk(
          entity,
          maxDepth,
          visit,
          excludedDirs: excludedDirs,
          extraExcludes: extraExcludes,
          respectExclusion: respectExclusion,
          skipHidden: skipHidden,
          onExcludedDir: onExcludedDir,
          onDirectory: onDirectory,
          depth: depth + 1,
        );
      } else if (entity is File) {
        visit(entity);
      }
    }
  }

  /// basename 维度的 glob 匹配（只支持 `*` 与 `?`）。
  static bool _matchesGlob(String name, String glob) {
    final String pattern = RegExp.escape(glob)
        .replaceAll(r'\*', '.*')
        .replaceAll(r'\?', '.');
    // 用相邻字符串字面量拼结尾锚点：直接写 '^$pattern$' 会因末尾 `$'` 被当成
    // 插值起始而报错（Dart 的 $ 后必须跟标识符或 {）
    return RegExp(
      '^$pattern'
      r'$',
    ).hasMatch(name);
  }
}

/// 取两者里"更差"的解码路径（顺序：UTF-8 < 系统代码页 < 有顶替 < 真乱码）。
///
/// 不能直接用 enum 的 index：容错解码（utf8Malformed）是在 latin1Fallback 之后追加的，
/// 声明顺序不再等于严重程度。
TextDecoding _worseDecoding(TextDecoding a, TextDecoding b) =>
    _decodingRank(a) >= _decodingRank(b) ? a : b;

int _decodingRank(TextDecoding decoding) => switch (decoding) {
  TextDecoding.utf8 => 0,
  TextDecoding.systemCodePage => 1,
  TextDecoding.utf8Malformed => 2,
  TextDecoding.latin1Fallback => 3,
};

/// 有上限的输出收集器：超限时保留**头 60% + 尾 40%**（错误往往在末尾）。
class _OutputCollector {
  _OutputCollector({required this.maxOutputBytes});

  final int maxOutputBytes;
  final BytesBuilder _head = BytesBuilder();
  final BytesBuilder _tail = BytesBuilder();
  bool truncated = false;

  /// 累计收到的字节数（**单调递增**）：[_head]/[_tail] 会被截断，长度反映不了
  /// "还有没有新数据在动"，收尾判据只能看这个。
  int receivedBytes = 0;

  void add(List<int> chunk) {
    receivedBytes += chunk.length;
    // 未截断前全部进头部；一旦超出预算，之后**只**保留尾部（错误通常在末尾），
    // 绝不把截断点之后的内容再拼回头部（那会造出乱序输出）
    if (!truncated && _head.length + chunk.length <= maxOutputBytes) {
      _head.add(chunk);
      return;
    }
    truncated = true;
    _tail.add(chunk);
    final int tailBudget = (maxOutputBytes * 0.4).round();
    if (_tail.length > tailBudget) {
      final List<int> bytes = _tail.takeBytes();
      _tail.add(bytes.sublist(bytes.length - tailBudget));
    }
  }

  /// 文本 + 实际走的解码路径。
  ///
  /// 头/尾**各自解码**（截断点是拼接出来的，中间可能切开一个多字节字符），路径取两者
  /// 里"最差"的那条：任何一段降级了，整份输出就按降级如实标注。
  DecodedText get decoded {
    final DecodedText head = PlatformTextDecoder.decode(_head.toBytes());
    if (!truncated) return head;
    final DecodedText tail = PlatformTextDecoder.decode(_tail.toBytes());
    return DecodedText(
      text: '${head.text}\n…（输出过长已截断）…\n${tail.text}',
      decoding: _worseDecoding(head.decoding, tail.decoding),
      byteLength: head.byteLength + tail.byteLength,
    );
  }
}
