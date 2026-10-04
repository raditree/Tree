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

import 'dart:typed_data';

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

/// 取 `[from, to)` 行的文本（**本机与 SSH 共用一份**：两端语义不许漂移）。
///
/// **保留结尾换行**：[FileContent.text] 是"文件内容"，不是"行拼接"——选区覆盖了末行、
/// 且原文以换行结尾时，把那个换行补回来，`write → read` 才保真。只取中段（没覆盖末行）
/// 时不补，避免凭空多出一个空行。
///
/// 为什么单列出来：[LineSplitter] 会把"结尾换行"吃掉（`'a\nb\n'` ⇒ `['a','b']`），
/// 直接 `join('\n')` 就丢了它——本机与远端各写一遍必然漂移，所以只留这一处规则。
String sliceFileLines(String text, List<String> lines, int from, int to) {
  final String selected = lines.sublist(from, to).join('\n');
  if (to <= from || to != lines.length) return selected;
  if (!text.endsWith('\n') && !text.endsWith('\r')) return selected;
  return '$selected\n';
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
    this.includeHidden = false,
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

  /// 是否连隐藏路径（以 `.` 开头，`.[!.]*` 那类，见 [isHiddenPathName]）一起搜。
  ///
  /// 缺省 false：绝大多数检索都不需要 `.git`/`.dart_tool`/`.self/results` 这类
  /// 机器目录，把它们排除掉既省一次全树读盘、也让命中不被噪声淹没。
  /// **可见的**依赖/构建目录（`node_modules` / `build` / `dist` …）仍然默认排除
  /// ——它们是硬黑名单，与这个开关无关。
  ///
  /// 显式把 [relativePath] 指到隐藏目录上时不受此开关影响（指向哪里搜哪里，
  /// 与既有的"path 指过去则不再排除"一致）。
  final bool includeHidden;
}

/// 是否是应当默认跳过的"隐藏"名字：以 `.` 开头，`.` 与 `..` 除外
/// （`.[!.]*` 想表达的那类隐藏名；`..foo` 这种怪名也一并算隐藏）。
///
/// 本地与 SSH 两套遍历共用这一份判据，保证"同一个工作空间、同一份默认口径"。
/// 只判**单个路径段**（basename / 目录名），不判整条路径。
bool isHiddenPathName(String name) =>
    name.length > 1 && name.startsWith('.') && name != '..';

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
///
/// M9（Q10）：除命中之外还要带回**扫描清单**与**生效的排除目录清单**——无匹配时
/// 上层靠它区分"真没有"与"被误排除"。两份清单都在遍历/读取过程中顺手记录
/// （只留 [maxScannedFilePaths] / [maxExcludedDirs] 条抽样），**不额外做一次全树扫描**。
class GrepOutcome {
  const GrepOutcome({
    required this.matches,
    required this.scannedFileCount,
    required this.truncated,
    this.scannedFilePaths = const <String>[],
    this.excludedDirs = const <String>[],
  });

  /// [scannedFilePaths] 的条数上限：扫描面可能上万，给模型一份**可读的抽样**即可。
  ///
  /// 2026-10-02 由 200 下调到 20：无匹配时的清单只用来回答"是不是被排除规则挡了"，
  /// 20 条足以判断；200 条会被 `join('、')` 拼成一行塞进工具结果（3~6k 字符），白烧 token。
  /// **与 [GrepQuery.maxResults] 不是同一个旋钮**——那个是**命中行数**上限、可由工具参数
  /// `max_results` 覆盖；两者默认值一度都是 200，极易混淆（本次就是这么踩进来的）。
  static const int maxScannedFilePaths = 20;

  /// [excludedDirs] 的条数上限。
  static const int maxExcludedDirs = 50;

  final List<GrepMatch> matches;

  /// 实际扫描（读过内容）的文件总数，可能远多于 [scannedFilePaths] 的条数。
  final int scannedFileCount;

  /// 实际扫描过的文件（工作空间相对路径，按扫描顺序，最多 [maxScannedFilePaths] 条）。
  final List<String> scannedFilePaths;

  /// **实际生效**的排除目录（工作空间相对路径，最多 [maxExcludedDirs] 条）。
  ///
  /// 只列真的存在、真的被跳过的目录（依赖/构建目录与 exclude glob 命中的），
  /// 不是把规则表照抄一遍——否则模型无法判断"目录不存在"与"被排除"。
  final List<String> excludedDirs;

  /// 是否因为 max_results 截断。
  final bool truncated;

  /// 兼容旧字段名：M9 之前这个名字指的就是上面的 **int 计数**，语义不变
  /// （tree_core 工具层仍按计数使用）；扫描路径清单是 [scannedFilePaths]。
  int get scannedFiles => scannedFileCount;
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
    this.garbledOutput = false,
  });

  /// 退出码（进程根本没能启动等异常情况下为 -1）。
  final int exitCode;

  final String stdout;
  final String stderr;

  /// 是否因超时被终止。
  ///
  /// M9 1.1 起执行器**取消的是"静态总时长"判据**（不是取消超时本身）：只要活性
  /// 还在就永不判超时——本地看进程是否存活（OS 层），SSH 看心跳有没有丢——因此
  /// 这个字段**恒为 false**（留着是为了不改动调用方：tree_core 的 terminal 工具
  /// 仍按它拼提示）。**软超时也不算"超时被终止"**：本地/SSH 到点都只是"不再等"
  /// （见 [exec] 与 [LocalExecStillRunning] / [SshExecStillRunning]），命令本身一步
  /// 都没被动过，所以这里照样是 false。SSH 侧心跳连续丢失时，在途操作会以
  /// [SshLinkStaleException] 显式失败，而不是靠静默丢弃。
  final bool timedOut;

  /// 输出是否被截断（保留头尾）。
  final bool truncated;

  /// 实际使用的 shell 描述（诊断用）。
  final String shell;

  /// 输出不是合法 UTF-8：**已尝试按系统 ANSI 代码页解码**（Windows 上 cmd 内建命令
  /// 写管道用的就是系统代码页，中文机器 = GBK/CP936；非 Windows 不参与代码页解码）。
  ///
  /// 语义修订（字段名/类型/构造参数/默认值都不变，老调用方不受影响）：它现在只表示
  /// "走了非 UTF-8 解码路径"，**不再等于"中文一定是乱码"**——是否真的解不开由
  /// [garbledOutput] 区分。
  final bool nonUtf8Output;

  /// 真乱码：输出既不是合法 UTF-8，也不是合法的**系统 ANSI 代码页**字节序列，
  /// 只能用 latin1 逐字节兜底（**字节不丢**、可原样还原，但中文不可读）。
  ///
  /// 恒有 `garbledOutput → nonUtf8Output`。非 Windows 上不尝试代码页解码，凡是非
  /// UTF-8 输出都会落到这里（平台限制，不是解码 bug）。
  final bool garbledOutput;

  bool get ok => exitCode == 0 && !timedOut;
}

/// 一条 Git 提交（M9 Q4）。
class GitCommit {
  const GitCommit({
    required this.hash,
    required this.author,
    required this.date,
    required this.message,
  });

  final String hash;
  final String author;

  /// 提交时间：git log --date=iso 的原文（形如 2026-01-02 03:04:05 +0800）。
  final String date;

  /// 提交标题（**可以含 tab**——解析时只按 tab 切分，余下的都归 message）。
  final String message;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'hash': hash,
    'author': author,
    'date': date,
    'message': message,
  };
}

/// git log 的结果（M9 Q4）。
///
/// 非仓库 / 没有 git 时**不抛异常**：[commits] 为空、[exitCode] 是 git 的非零
/// 退出码（本地连可执行文件都找不到时是 127），上层据此显示空态而不是 400。
class GitLogOutcome {
  const GitLogOutcome({required this.commits, required this.exitCode});

  final List<GitCommit> commits;

  /// git 的退出码（0 = 正常）。
  final int exitCode;

  /// REST / 工具层的 JSON 形状（键名沿用旧后端的下划线风格）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'commits': commits.map((GitCommit c) => c.toJson()).toList(),
    'exit_code': exitCode,
  };
}

/// git branch -a 的结果（M9 Q4）。
class GitBranchesOutcome {
  const GitBranchesOutcome({
    required this.branches,
    required this.current,
    required this.exitCode,
  });

  /// 全部分支名（含当前分支；远端分支形如 remotes/origin/main）。
  final List<String> branches;

  /// 当前分支；分离头指针时是 git 给的描述文本，取不到为空串。
  final String current;

  /// git 的退出码（0 = 正常）。
  final int exitCode;

  /// REST / 工具层的 JSON 形状：branches 是字符串数组（前端同时兼容
  /// {name: ...} 形状，见 git_history.dart），exit_code 与旧后端一致。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'branches': branches,
    'current': current,
    'exit_code': exitCode,
  };
}

/// 一条 Git 工作区状态（M11 文件面板：改动高亮）。
class GitStatusEntry {
  const GitStatusEntry({required this.path, required this.status});

  /// 工作空间相对路径（重命名取**新名**；未跟踪目录去掉 git 补的尾斜杠）。
  final String path;

  /// 面板口径的单字母状态：`M` 修改 / `U` 未跟踪或冲突 / `A` 新增 / `D` 删除 /
  /// `R` 重命名或复制 / `I` 被忽略（映射规则见 `GitOutput.parseStatus`）。
  final String status;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'status': status,
  };
}

/// `git status` 的结果（M11）。
///
/// **不是仓库 / 没有 git 时不是错误**：[isRepo] 为 false、[entries] 为空，面板显示
/// 空态而不是 400（与 [GitLogOutcome] 同一口径）。
class GitStatusOutcome {
  const GitStatusOutcome({
    required this.isRepo,
    required this.entries,
    required this.truncated,
    required this.exitCode,
  });

  /// 该工作空间是否是一个 git 仓库（= `git status` 退出码为 0）。
  final bool isRepo;

  final List<GitStatusEntry> entries;

  /// 条目数触顶被截断（大仓库不把核心拖死）。
  final bool truncated;

  /// git 的退出码（0 = 正常）。
  final int exitCode;

  /// REST 形状（前端文件面板直接用）：`{is_repo, entries, truncated}`。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'is_repo': isRepo,
    'entries': entries.map((GitStatusEntry e) => e.toJson()).toList(),
    'truncated': truncated,
  };
}

/// 新建 / 重命名 / 删除这类**结构改动**的结果码（M11）。
///
/// 为什么用结果码而不是异常：三种操作各自的失败语义不同，上层要按语义映射
/// 409（已存在 / 目录非空）/ 404（源不存在）/ 400（目标父目录不存在）。异常类型
/// 会把这些差异藏进字符串里，结果码则把语义钉在类型上（本地与 SSH 同一套）。
enum WorkspaceMutationStatus {
  ok,

  /// 目标已存在（新建 / 重命名时，**重命名绝不覆盖**）。
  alreadyExists,

  /// 源不存在（重命名 / 删除时）。
  notFound,

  /// 目标父目录不存在（**不自动创建**——静默建目录会把写错路径变成「成功」）。
  parentMissing,

  /// 目录非空且调用方没有要求递归（删除时）。
  notEmpty,
}

/// [WorkspaceMutationStatus] 的载体：带回**可读原因**（上层原样展示给用户）。
class WorkspaceMutationResult {
  const WorkspaceMutationResult(this.status, [this.message = '']);

  const WorkspaceMutationResult.ok()
    : status = WorkspaceMutationStatus.ok,
      message = '';

  final WorkspaceMutationStatus status;

  /// 可读原因（成功时为空）。UI 要能直接显示这句话，不许是英文异常文本。
  final String message;

  bool get ok => status == WorkspaceMutationStatus.ok;
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

  /// 删除一个**文件**（返回是否真的删除了；不存在返回 false）。
  ///
  /// 只服务「重置到默认」这类维护动作（备份后清掉旧文件 / 重新播种），
  /// 不是通用工具能力——工具层仍没有 delete 工具。目录一律拒绝（显式报错）。
  Future<bool> deleteFile(String relativePath);

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
  ///
  /// [timeout] 的语义（2026-10-02 起本地可用、2026-10-03 起 SSH 同样兑现；参数名与
  /// 默认值对调用方透明）：
  /// - `Duration.zero`（默认，或任何 ≤ zero 的值）= **永不软超时**：老行为——判据是
  ///   活性（本地"进程还活着"、SSH"心跳没丢"），命令跑多久都等，**绝不因为"太久"
  ///   杀命令**；
  /// - `> zero` = **软超时（两端同口径）**：到点仍在跑就**不杀进程、不重跑、不丢
  ///   输出**，把仍活着的命令交出来——本地抛 [LocalExecStillRunning]（句柄
  ///   [RunningLocalExec]，输出订阅还活着、进程杀得掉）、SSH 抛
  ///   [SshExecStillRunning]（句柄 [RunningSshExec]，远端进程不归本机管，退出码与
  ///   输出要等命令自己结束才回来）；由调用方登记成后台任务（terminal 的 hook 模式）
  ///   继续收尾并唤醒 agent。
  ///
  /// 硬超时（按时间杀进程）依然**不存在**；SSH 判失活仍走心跳
  /// （[SshLinkStaleException] 显式失败，不是按时间杀）。
  Future<ExecOutcome> exec(
    String command, {
    Duration timeout,
    int maxOutputBytes,
  });

  /// Git 提交历史。
  ///
  /// 非仓库 / 没有 git **不抛异常**：返回空列表 + 退出码，由上层显示空态。
  Future<GitLogOutcome> gitLog({int limit = 50});

  /// Git 分支列表（含当前分支）；非仓库 / 没有 git 同样只回空列表 + 退出码。
  Future<GitBranchesOutcome> gitBranches();

  /// Git 工作区状态（`git status --porcelain=v1 -z` 解析结果，M11）。
  ///
  /// 非仓库 / 没有 git **不抛异常**：返回 [GitStatusOutcome.isRepo] = false + 空
  /// 列表，由上层显示空态。[maxEntries] 是条目上限（超出置 truncated）。
  ///
  /// [ignored] 为 true 时带 `--ignored`（`!!` 条目才会出现）。默认**不带**：
  /// 大仓库里列被忽略文件既慢又吵，按需再开。
  Future<GitStatusOutcome> gitStatus({
    int maxEntries = 2000,
    bool ignored = false,
  });

  /// 释放资源（幂等）。
  Future<void> close();
}

/// 文件面板的一层目录条目（M7g）。
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    this.size = 0,
    this.modified,
  });

  /// 名字（不含路径）。
  final String name;

  /// 工作空间内相对路径（POSIX 分隔符）。
  final String relativePath;

  final bool isDirectory;

  /// 文件字节数（目录恒为 0）。
  final int size;

  /// 修改时间（远端/本地都可能拿不到，故可空）。
  final DateTime? modified;
}

/// 文件面板需要的三个操作（M7g）：列一层目录、读原始字节、写原始字节。
///
/// 与 [WorkspaceIO] 分开的理由：工具层只需要"读一个文件 / 写一个文件 / 列出一批
/// 路径"，而文件面板要的是**一层目录的元信息**（名字/类型/大小/时间）与原始字节
/// （图片、PDF、压缩包都不能当文本走）。本地实现是 dart:io 的薄封装，SSH 实现走
/// SFTP；`FileService` 只依赖本接口，因此两条路径共用同一套 REST 语义与安全边界。
abstract interface class WorkspaceFiles {
  /// 列出一层目录（不递归）；越界/非法路径抛 [WorkspacePathException]。
  Future<List<WorkspaceEntry>> listEntries(
    String relativePath, {
    int maxEntries = 2000,
  });

  /// 读取原始字节（不存在抛 [WorkspaceIoException]）。
  Future<Uint8List> readBytes(String relativePath);

  /// 写入原始字节（自动创建父目录）。
  Future<void> writeBytes(String relativePath, List<int> bytes);

  /// 文件字节数（不存在抛 [WorkspaceIoException]）。
  ///
  /// M8c：大文件要**先问大小再决定读多少**——旧实现是"先读回整个文件，再拿
  /// 长度去判上限"，对几百 MB 的 PDF 既费内存又白跑一趟。
  Future<int> sizeOf(String relativePath);

  /// 读取原始字节流（[offset] 起、最多 [length] 字节；null = 读到结尾）。
  ///
  /// **流式**是"单文件不设上限"的代价：调用方按块消费（HTTP 响应 / SFTP 写 /
  /// 本地文件），不要在内存里攒整文件。
  Stream<List<int>> openRead(
    String relativePath, {
    int offset = 0,
    int? length,
  });

  /// 把字节流写入文件（自动创建父目录）。
  Future<void> writeStream(String relativePath, Stream<List<int>> data);

  /// 新建**一层**目录（M11 文件面板：新建文件夹）。
  ///
  /// 语义（本地与 SSH 完全一致）：
  /// - 目标已存在（文件或目录）→ [WorkspaceMutationStatus.alreadyExists]；
  /// - 父目录不存在 → [WorkspaceMutationStatus.parentMissing]（**不自动建父目录**）；
  /// - 路径越界 / 非法 → [WorkspacePathException]（与读路径同一套边界）。
  Future<WorkspaceMutationResult> makeDirectory(String relativePath);

  /// 重命名 / 移动（M11 文件面板）。
  ///
  /// 语义：
  /// - 源不存在 → [WorkspaceMutationStatus.notFound]；
  /// - 目标已存在 → [WorkspaceMutationStatus.alreadyExists]（**绝不覆盖**：SFTP 的
  ///   `posix-rename@openssh.com` 扩展本身就是覆盖语义，所以实现必须**先自检**）；
  /// - 目标父目录不存在 → [WorkspaceMutationStatus.parentMissing]。
  Future<WorkspaceMutationResult> rename(String from, String to);

  /// 删除文件或目录（M11 文件面板）。
  ///
  /// 语义：
  /// - 不存在 → [WorkspaceMutationStatus.notFound]；
  /// - 目录非空且 [recursive] 为 false → [WorkspaceMutationStatus.notEmpty]
  ///   （**默认拒绝**，绝不静默递归删掉一整棵树）；
  /// - [recursive] 为 true 时递归删整棵子树。
  Future<WorkspaceMutationResult> remove(
    String relativePath, {
    bool recursive = false,
  });
}
