/// 工作空间 IO 抽象：agent 能"看到与改动"的全部世界。
///
/// 设计要点：
/// - **相对路径 + 根目录约束**：工具参数一律是工作空间相对路径；[WorkspaceIO.resolve]
///   负责把它解析成绝对路径并**拒绝越界**（绝对路径/盘符/`..` 逃逸）。这条不变量
///   是所有文件类工具的安全边界，因此测试单独覆盖。
/// - **与具体后端无关**：本地实现（\`LocalWorkspaceIO\`）与将来的 SSH 实现共用本接口，
///   内置工具因此只写一份。
/// - **结果自带诊断信息**：截断、扫描文件数、退出码、超时——模型需要这些来判断
///   "是不是还有更多"，而不是看到一份被悄悄截断的结果。
library;

/// 路径越界/非法（工具层会把它翻成模型可读的错误结果）。
class WorkspacePathException implements Exception {
  WorkspacePathException(this.relativePath, this.reason);

  /// 触发出错的原始（相对）路径。
  final String relativePath;

  /// 可读原因。
  final String reason;

  @override
  String toString() => '路径非法（$relativePath）：$reason';
}

/// 读取结果。
class FileContent {
  const FileContent({
    required this.path,
    required this.text,
    this.base64,
    this.totalLines = 0,
    this.startLine = 1,
    this.truncated = false,
    this.language = '',
  });

  /// 工作空间相对路径。
  final String path;

  /// 文本内容（二进制文件为空串）。
  final String text;

  /// 图像等二进制内容（base64；非二进制为 null）。
  final String? base64;

  /// 文件总行数（文本）。
  final int totalLines;

  /// 本次返回的起始行号（1 基）。
  final int startLine;

  /// 是否因 line_count 而只返回了部分行。
  final bool truncated;

  /// 语法高亮提示（扩展名推导，前端可选使用）。
  final String language;
}

/// 编辑结果。
class EditOutcome {
  const EditOutcome({
    required this.path,
    required this.replacements,
    required this.bytesWritten,
  });

  final String path;

  /// 实际替换处数。
  final int replacements;

  final int bytesWritten;
}

/// 一次 grep 查询。
class GrepQuery {
  const GrepQuery({
    required this.pattern,
    this.regex = false,
    this.ignoreCase = false,
    this.relativePath = '.',
    this.maxDepth = 0,
    this.maxResults = 200,
    this.exclude = const <String>[],
  });

  final String pattern;

  /// pattern 是否为正则（false = 字面量）。
  final bool regex;

  final bool ignoreCase;

  /// 搜索范围（工作空间相对路径）。
  final String relativePath;

  /// 递归层数（0 = 不限）。
  final int maxDepth;

  /// 返回命中行数上限。
  final int maxResults;

  /// 追加排除的 glob（按 basename 匹配，如 `*.g.dart`）。
  final List<String> exclude;
}

/// grep 单条命中。
class GrepMatch {
  const GrepMatch({
    required this.path,
    required this.lineNumber,
    required this.line,
  });

  final String path;
  final int lineNumber;
  final String line;
}

/// grep 结果。
class GrepOutcome {
  const GrepOutcome({
    required this.matches,
    required this.scannedFiles,
    required this.truncated,
  });

  final List<GrepMatch> matches;

  /// 实际扫描的文件数。
  final int scannedFiles;

  /// 是否因为 max_results 截断。
  final bool truncated;
}

/// 命令执行结果。
class ExecOutcome {
  const ExecOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.truncated = false,
    this.shell = '',
    this.nonUtf8Output = false,
  });

  /// 退出码（超时被杀为 -1）。
  final int exitCode;

  final String stdout;
  final String stderr;

  /// 是否因超时被终止。
  final bool timedOut;

  /// 输出是否被截断（保留头尾）。
  final bool truncated;

  /// 实际使用的 shell 描述（诊断用）。
  final String shell;

  /// 输出不是合法 UTF-8（Windows 非 UTF-8 代码页下 cmd 内建命令的已知限制，
  /// 此时文本是 latin1 兜底解码，中文可能显示为乱码）。
  final bool nonUtf8Output;

  bool get ok => exitCode == 0 && !timedOut;
}

/// 工作空间 IO。
abstract interface class WorkspaceIO {
  /// 工作空间根目录（绝对路径）。
  String get root;

  /// 把工作空间相对路径解析为绝对路径；越界/非法时抛 [WorkspacePathException]。
  String resolve(String relativePath);

  /// 读取文件（可选行范围；图像返回 base64）。
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  });

  /// 写入文件（自动创建父目录），返回写入字节数。
  Future<int> writeFile(String relativePath, String content);

  /// 精确字符串替换；[oldText] 必须唯一匹配（除非 [replaceAll]）。
  Future<EditOutcome> editFile(
    String relativePath, {
    required String oldText,
    required String newText,
    bool replaceAll = false,
  });

  /// 按模式搜索文件内容。
  Future<GrepOutcome> grep(GrepQuery query);

  /// 列出目录（相对路径，含目录尾斜杠标记）。
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  });

  /// 执行 shell 命令（cwd = 工作空间根）。
  Future<ExecOutcome> exec(
    String command, {
    Duration timeout,
    int maxOutputBytes,
  });

  /// 释放资源（幂等）。
  Future<void> close();
}
