import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'workspace_io.dart';

/// 工具层把 IO 失败翻成"模型可读的错误结果"时使用的异常。
class WorkspaceIoException implements Exception {
  WorkspaceIoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [WorkspaceIO] 的**本地**实现（`dart:io`）。
///
/// Windows 上踩过的坑（M0b 迁移清单要求原样保留）：
/// - 命令走 `cmd.exe /c` 并**前置 `chcp 65001`**：否则 cmd 内建命令（dir/type…）
///   按 GBK 输出，中文全是乱码；
/// - 输出解码**严格 UTF-8 失败后回退 latin1**（不抛异常、不丢字节）；
/// - 超时杀进程要用 `taskkill /T` 杀**整棵进程树**，否则 `cmd` 死了子进程还在跑。
///
/// 路径安全：一切工具参数都是工作空间相对路径，[resolve] 拒绝绝对路径/盘符/UNC
/// 以及 `..` 越界。注意符号链接可以绕过（本机单用户场景接受该风险，已在文档中
/// 记录；真要防需要 O_NOFOLLOW 级别的处理，Dart 标准库不提供）。
class LocalWorkspaceIO implements WorkspaceIO {
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

  @override
  Future<int> writeFile(String relativePath, String content) async {
    final String absolute = resolve(relativePath);
    final File file = File(absolute);
    await file.parent.create(recursive: true);
    final List<int> bytes = utf8.encode(content);
    await file.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

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
    final String original = decodeBytes(await file.readAsBytes());
    // 换行兼容：模型给的片段可能是 LF，而文件是 CRLF（Windows 常见）
    final bool fileUsesCrlf = original.contains('\r\n');
    final String haystack = fileUsesCrlf
        ? original.replaceAll('\r\n', '\n')
        : original;
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
    final List<int> bytes = utf8.encode(restored);
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
      scannedFiles: scanned,
      truncated: truncated,
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
    Duration timeout = const Duration(seconds: 120),
    int maxOutputBytes = 200 * 1024,
  }) async {
    final String trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw WorkspaceIoException('command 不能为空');
    }
    await Directory(root).create(recursive: true);
    final bool windows = Platform.isWindows;
    // Windows：前置 chcp 65001 让 cmd 内建命令也输出 UTF-8
    final String executable = windows ? 'cmd.exe' : '/bin/sh';
    final List<String> args = windows
        ? <String>['/c', 'chcp 65001 >nul && $trimmed']
        : <String>['-c', trimmed];

    final Process process = await Process.start(
      executable,
      args,
      workingDirectory: root,
      runInShell: false,
    );
    final _OutputCollector out = _OutputCollector(
      maxOutputBytes: maxOutputBytes,
    );
    final _OutputCollector err = _OutputCollector(
      maxOutputBytes: maxOutputBytes,
    );
    final Future<void> outDone = process.stdout
        .listen(out.add)
        .asFuture<void>();
    final Future<void> errDone = process.stderr
        .listen(err.add)
        .asFuture<void>();

    bool timedOut = false;
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      await _killTree(process.pid);
      exitCode = -1;
    }
    // 给输出流一点时间收尾（进程已退出但管道可能还有缓冲）
    await Future.wait<void>(<Future<void>>[outDone, errDone])
        .timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);

    final List<int> stdoutBytes = out.bytes;
    final List<int> stderrBytes = err.bytes;
    return ExecOutcome(
      exitCode: exitCode,
      stdout: out.text,
      stderr: err.text,
      timedOut: timedOut,
      truncated: out.truncated || err.truncated,
      shell: windows ? 'cmd.exe' : '/bin/sh',
      // 严格 UTF-8 解不开 → 用了 latin1 兜底 → 中文可能乱码，如实标注
      nonUtf8Output:
          _isStrictUtf8(stdoutBytes) == false ||
          _isStrictUtf8(stderrBytes) == false,
    );
  }

  @override
  Future<void> close() async {}

  // ── 内部工具 ─────────────────────────────────────────────────────────

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

  /// 严格 UTF-8，失败则回退 latin1（不抛异常、不丢字节）。
  ///
  /// **已知限制**：Windows 上 cmd 内建命令（dir/type/echo）与部分系统错误信息
  /// 在管道输出时使用**系统 ANSI 代码页**（中文机器上是 GBK/CP936），
  /// 而且 `chcp 65001` **管不住管道输出**（实测：加不加 chcp，echo 中文都是 GBK
  /// 字节）。此时 latin1 兜底能保住字节但显示为乱码，[ExecOutcome.nonUtf8Output]
  /// 会把它标出来让工具层提示使用者。
  /// 真正的修复要按系统代码页解码（Windows 上是 `MultiByteToWideChar` + FFI），
  /// 属于后续增强项，不在本里程碑内。
  static String decodeBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// 是否严格合法的 UTF-8（空字节串视为合法）。
  static bool _isStrictUtf8(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 用 `taskkill /T` 杀整棵进程树（Windows 上只杀 cmd 会留下子进程）。
  static Future<void> _killTree(int pid) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
      } catch (_) {
        // 尽力而为
      }
      return;
    }
    Process.killPid(pid, ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    Process.killPid(pid, ProcessSignal.sigkill);
  }

  /// 递归遍历；[maxDepth] 为 0 表示不限。
  static void _walk(
    Directory dir,
    int maxDepth,
    void Function(FileSystemEntity entity) visit, {
    required Set<String> excludedDirs,
    required List<String> extraExcludes,
    required bool respectExclusion,
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
        if (excludedDirs.contains(name)) continue;
        if (extraExcludes.any((String glob) => _matchesGlob(name, glob))) {
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

/// 有上限的输出收集器：超限时保留**头 60% + 尾 40%**（错误往往在末尾）。
class _OutputCollector {
  _OutputCollector({required this.maxOutputBytes});

  final int maxOutputBytes;
  final BytesBuilder _head = BytesBuilder();
  final BytesBuilder _tail = BytesBuilder();
  bool truncated = false;

  void add(List<int> chunk) {
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

  /// 原始字节（用于判断编码是否可信）。
  List<int> get bytes => <int>[..._head.toBytes(), ..._tail.toBytes()];

  String get text {
    final String head = LocalWorkspaceIO.decodeBytes(_head.toBytes());
    final String tail = LocalWorkspaceIO.decodeBytes(_tail.toBytes());
    if (!truncated) return head;
    return '$head\n…（输出过长已截断）…\n$tail';
  }
}
