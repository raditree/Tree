import 'dart:convert';

import 'package:path/path.dart' as p;

import 'local_workspace_io.dart';
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

  /// 递归列出目录下的**文件**相对路径（POSIX 分隔符）。
  Future<List<String>> listFiles(String absolutePath, {int maxDepth});

  /// 路径是否存在且是文件/目录。
  Future<bool> exists(String absolutePath);

  /// 执行命令，返回退出码与解码后的输出。
  Future<SshExecResult> run(String command, {Duration timeout});

  /// 释放连接。
  Future<void> close();
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
  final SshExecResult result = await transport.run(r'printf %s "$HOME"');
  final String home = result.stdout.trim();
  if (result.exitCode != 0 || !home.startsWith('/')) {
    throw WorkspaceIoException('无法解析远端 HOME（exit=${result.exitCode}，输出：$home）');
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
/// - exec 不做 `chcp`（远端不是 cmd）。
class SshWorkspaceIO implements WorkspaceIO {
  SshWorkspaceIO(this.root, this._transport);

  @override
  final String root;

  final SshTransport _transport;

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
    final List<int> bytes = utf8.encode(content);
    await _transport.write(absolute, bytes);
    return bytes.length;
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
    final String original = LocalWorkspaceIO.decodeBytes(
      await _read(absolute, relativePath),
    );
    final bool crlf = original.contains('\r\n');
    final String haystack = crlf ? original.replaceAll('\r\n', '\n') : original;
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
    final List<int> bytes = utf8.encode(
      crlf ? updated.replaceAll('\n', '\r\n') : updated,
    );
    await _transport.write(absolute, bytes);
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
    final List<String> relativeFiles = await _transport.listFiles(
      start,
      maxDepth: query.maxDepth,
    );
    final List<GrepMatch> matches = <GrepMatch>[];
    int scanned = 0;
    bool truncated = false;
    for (final String rel in relativeFiles) {
      if (matches.length >= query.maxResults) {
        truncated = true;
        break;
      }
      final String name = p.posix.basename(rel);
      if (defaultExcludedDirs.contains(name)) continue;
      if (query.exclude.any((String glob) => _matchesGlob(name, glob))) {
        continue;
      }
      final List<int> bytes;
      try {
        bytes = await _transport.read(p.posix.join(start, rel));
      } catch (_) {
        continue;
      }
      if (bytes.contains(0)) continue;
      scanned++;
      int lineNumber = 0;
      for (final String line in const LineSplitter().convert(
        LocalWorkspaceIO.decodeBytes(bytes),
      )) {
        lineNumber++;
        if (!pattern.hasMatch(line)) continue;
        matches.add(
          GrepMatch(
            path: p.posix
                .join(relativize(start), rel)
                .replaceFirst(RegExp(r'^\./'), ''),
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
    final String trimmed = command.trim();
    if (trimmed.isEmpty) throw WorkspaceIoException('command 不能为空');
    final SshExecResult result = await _transport.run(
      'cd ${_quote(root)} && $trimmed',
      timeout: timeout,
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

  @override
  Future<void> close() => _transport.close();

  Future<List<int>> _read(String absolute, String relativePath) async {
    try {
      return await _transport.read(absolute);
    } on WorkspaceIoException {
      rethrow;
    } catch (error) {
      throw WorkspaceIoException('读取失败（$relativePath）：$error');
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
