import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

/// 每个 agent 的**私有状态目录**（工作空间相对路径，`<agent>` 是 **agent id**）。
///
/// 为什么需要它：团队成员与 leader **共享同一个工作目录**（[TeamWorkspace]），但 `.self/`
/// 装的都是"这个 agent 自己的东西"——系统提示词、规范文件、规范附带文档、超长工具结果的
/// 落点、活动日志、计划/侦察笔记……共享一个根就会互相覆盖（实测：成员的
/// `[start(成员)]/[done(成员)]` 与 leader 的条目混进同一个 `.self/activity.log`）。
/// 因此在共享根下按 agent 分栏：
///
/// ```
/// <共享工作目录>/
///   <项目文件…>            所有成员共用（leader 与成员看到同一份）
///   .input/<日期>/…        共享输入（附件上传落点）
///   .tree/<agent_id>/.self/   ← 本函数：这个 agent 的私有状态
/// ```
String privateSelfDir(String agentId) => '.tree/$agentId/.self';

/// 把**模型口径**的相对路径翻译成真实的工作空间相对路径：只翻 `.self` 这一族。
///
/// 内置规范与工具提示里写的都是 `.self/plan/…`、`.self/results/…`（模型的口径），
/// 磁盘上却必须按 agent 分栏，两者由本函数单向翻译：
/// - 入参（读/写/编辑/搜索/列目录/resolve）`.self/…` → `.tree/<agent_id>/.self/…`；
/// - 其它路径（含已经是真实路径的 `.tree/<agent_id>/.self/…`）原样返回 ⇒ **两种写法都是
///   合法入参**，工具结果里回显的真实路径可以继续拿来用。
///
/// 只做"前缀替换"、不做 `..` 解析：越界判定仍然全部交给 IO 的 `resolve`。
String mapPrivatePath(String relativePath, String agentId) {
  String path = relativePath.trim();
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  if (path == '.self') return privateSelfDir(agentId);
  const String prefix = '.self/';
  if (path.startsWith(prefix)) {
    return '${privateSelfDir(agentId)}/${path.substring(prefix.length)}';
  }
  return relativePath;
}

/// 一次性迁移：把旧的 `<工作空间>/.self` 搬到 `.tree/<agent_id>/.self`（幂等）。
///
/// 为什么需要：2026-10-02 起私有状态按 agent 分栏，旧工作空间的 `.self` 里可能装着
/// 用户改过的系统提示词、自定义规范、计划笔记（这些**只在本机**，丢了就找不回来）。
/// 只在**目标还不存在**时搬；搬不动（跨卷 / 占用）就记日志、不阻断启动。
///
/// 只应由"该工作空间的主人"（团队 TOP）调用：团队成员与 leader 共享目录，旧 `.self`
/// 不可能是成员留下的（成员以前有自己的目录，那份留在原地）。
void migrateLegacySelfDir({
  required String workspaceDir,
  required String agentId,
  void Function(String message)? log,
}) {
  final Directory legacy = Directory(p.join(workspaceDir, '.self'));
  final Directory target = Directory(
    p.join(workspaceDir, '.tree', agentId, '.self'),
  );
  if (!legacy.existsSync() || target.existsSync()) return;
  try {
    target.parent.createSync(recursive: true);
    legacy.renameSync(target.path);
    log?.call('私有状态已迁移到 ${privateSelfDir(agentId)}（$workspaceDir）');
  } catch (error) {
    log?.call('私有状态迁移失败（$workspaceDir）：$error');
  }
}

/// **按 agent 分栏的工作空间 IO**：把 [WorkspaceIO] / [WorkspaceFiles] 的入参路径过一手
/// [mapPrivatePath]，其余一律透传给内层实现（本地或 SSH 都用同一份）。
///
/// 为什么用装饰器而不是改各个调用点：`.self` 这条口径散落在规范文本、工具描述、结果门控与
/// 若干常量里（`SpecService.specDir` / `SystemPromptStore.promptPath` /
/// `kPluginGuideWorkspacePath` / `ToolResultGate.resultsDir`），装饰器让它们**一个都不用改**；
/// 而 `WorkspaceToolRunner.ioFor` 是所有 .self 使用者的唯一入口（工具、Spec、系统提示词、
/// 结果门控、插件文档播种），包在那里就全都生效。
///
/// 注意：**终端命令不经过这里**（`exec` 直接在根下跑 shell），所以提示词里要如实告诉模型
/// 私有目录的真实路径。
class PrivateWorkspaceIO
    implements WorkspaceIO, WorkspaceFiles, BackgroundExecHost {
  PrivateWorkspaceIO(this.inner, this.agentId);

  final WorkspaceIO inner;
  final String agentId;

  String _map(String relativePath) => mapPrivatePath(relativePath, agentId);

  /// 文件面板那一层接口（只有 SSH 后端同时实现两个接口；本机后端走 dart:io，
  /// 不经过这里）。缺支持时显式报错，不静默假装成功。
  WorkspaceFiles get _files {
    final WorkspaceIO target = inner;
    if (target is WorkspaceFiles) return target as WorkspaceFiles;
    throw WorkspaceIoException('该工作空间后端不支持文件面板操作');
  }

  // ── WorkspaceIO ──────────────────────────────────────────────────────

  @override
  String get root => inner.root;

  @override
  String resolve(String relativePath) => inner.resolve(_map(relativePath));

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) => inner.readFile(
    _map(relativePath),
    startLine: startLine,
    lineCount: lineCount,
    maxBytes: maxBytes,
  );

  @override
  Future<int> writeFile(String relativePath, String content) =>
      inner.writeFile(_map(relativePath), content);

  @override
  Future<bool> deleteFile(String relativePath) =>
      inner.deleteFile(_map(relativePath));

  @override
  Future<EditOutcome> editFile(
    String relativePath, {
    required String oldText,
    required String newText,
    bool replaceAll = false,
  }) => inner.editFile(
    _map(relativePath),
    oldText: oldText,
    newText: newText,
    replaceAll: replaceAll,
  );

  @override
  Future<GrepOutcome> grep(GrepQuery query) => inner.grep(
    GrepQuery(
      pattern: query.pattern,
      regex: query.regex,
      ignoreCase: query.ignoreCase,
      relativePath: _map(query.relativePath),
      maxDepth: query.maxDepth,
      maxResults: query.maxResults,
      exclude: query.exclude,
      includeHidden: query.includeHidden,
    ),
  );

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) => inner.listFiles(
    relativePath: _map(relativePath),
    maxDepth: maxDepth,
    maxEntries: maxEntries,
  );

  @override
  Future<ExecOutcome> exec(
    String command, {
    Duration timeout = Duration.zero,
    int maxOutputBytes = 200 * 1024,
  }) => inner.exec(command, timeout: timeout, maxOutputBytes: maxOutputBytes);

  @override
  Future<GitLogOutcome> gitLog({int limit = 50}) => inner.gitLog(limit: limit);

  @override
  Future<GitBranchesOutcome> gitBranches() => inner.gitBranches();

  @override
  Future<GitStatusOutcome> gitStatus({
    int maxEntries = 2000,
    bool ignored = false,
  }) => inner.gitStatus(maxEntries: maxEntries, ignored: ignored);

  // ── BackgroundExecHost（terminal 的 hook=true；本机与 SSH 后端都实现）──────────

  /// 后台执行那一层接口（沿用 [_files] 的模式：内层不支持时显式报错，不静默假装）。
  BackgroundExecHost get _background {
    final WorkspaceIO target = inner;
    if (target is BackgroundExecHost) return target as BackgroundExecHost;
    throw WorkspaceIoException('该工作空间后端不支持后台执行（terminal 的 hook 模式）');
  }

  @override
  Future<BackgroundExecHandle> startBackground({
    required String command,
    required String logRelativePath,
  }) => _background.startBackground(
    command: command,
    logRelativePath: _map(logRelativePath),
  );

  @override
  Future<BackgroundExecHandle> attachBackground({
    required String command,
    required String logRelativePath,
    int? pid,
  }) => _background.attachBackground(
    command: command,
    logRelativePath: _map(logRelativePath),
    pid: pid,
  );

  @override
  Future<void> appendLog(String relativePath, String text) =>
      _background.appendLog(_map(relativePath), text);

  @override
  Future<String?> readTail(String relativePath, int maxChars) =>
      _background.readTail(_map(relativePath), maxChars);

  @override
  Future<void> close() => inner.close();

  // ── WorkspaceFiles（SSH 后端同时实现两者；文件面板按同一口径看私有目录）────

  @override
  Future<List<WorkspaceEntry>> listEntries(
    String relativePath, {
    int maxEntries = 2000,
  }) => _files.listEntries(_map(relativePath), maxEntries: maxEntries);

  @override
  Future<Uint8List> readBytes(String relativePath) =>
      _files.readBytes(_map(relativePath));

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) =>
      _files.writeBytes(_map(relativePath), bytes);

  @override
  Future<int> sizeOf(String relativePath) => _files.sizeOf(_map(relativePath));

  @override
  Stream<List<int>> openRead(
    String relativePath, {
    int offset = 0,
    int? length,
  }) => _files.openRead(_map(relativePath), offset: offset, length: length);

  @override
  Future<void> writeStream(String relativePath, Stream<List<int>> data) =>
      _files.writeStream(_map(relativePath), data);

  @override
  Future<WorkspaceMutationResult> makeDirectory(String relativePath) =>
      _files.makeDirectory(_map(relativePath));

  @override
  Future<WorkspaceMutationResult> rename(String from, String to) =>
      _files.rename(_map(from), _map(to));

  @override
  Future<WorkspaceMutationResult> remove(
    String relativePath, {
    bool recursive = false,
  }) => _files.remove(_map(relativePath), recursive: recursive);
}