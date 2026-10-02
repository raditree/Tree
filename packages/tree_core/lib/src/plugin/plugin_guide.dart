import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import 'builtin_plugins.dart';

/// 插件开发指南（`plugin-development.md`）在**工作空间内**的落点。
///
/// 为什么要有这个副本：工作空间类工具（`read` / `grep` / …）只认工作空间相对路径
/// （`WorkspaceIO.resolve` 拒绝绝对路径、盘符、UNC 与 `..`），而指南原件住在**核心
/// 所在机器**上——发行布局在应用目录的 `plugins/`（`tool/package_windows.dart` 拷进去的），
/// 开发态在仓库的 `docs/`。工作空间不是仓库时，agent 一个都读不到。于是选中
/// `plugin-creator` 规范时把原件复制到工作空间里，让 `read` 看得见
/// （接线见 `../spec/builtin_spec_assets.dart`）。
const String kPluginGuideWorkspacePath = '.self/docs/plugin-development.md';

/// 指南文件名：应用目录与仓库里同名，也是前端 `PluginDocs` 认的**专有文件名**
/// （它不用泛化的 `README.md`，避免把用户送到一份无关文档上）。
const String kPluginGuideFileName = 'plugin-development.md';

/// 一次播种的结果（工具回包、日志与测试都用它，别靠 error 字符串猜状态）。
class PluginGuideSeed {
  const PluginGuideSeed({
    required this.action,
    this.workspacePath = kPluginGuideWorkspacePath,
    this.sourcePath = '',
    this.bytes = 0,
    this.error = '',
    this.searched = const <String>[],
  });

  /// `created` 新播种 / `updated` 覆盖了旧副本 / `unchanged` 已是最新 /
  /// `missing` 核心所在机器上找不到原件 / `failed` 读原件或写工作空间失败。
  final String action;

  /// 工作空间相对路径（agent 用 `read` 时填这个）。
  final String workspacePath;

  /// 核心所在机器上的原件绝对路径（`missing` 时为空）。
  final String sourcePath;

  /// 写入的字节数（UTF-8）。
  final int bytes;

  /// 可读原因（`missing` / `failed` 时非空）。
  final String error;

  /// 找原件时探过的目录（`missing` 时给出"我都找过哪儿"，别让失败静默）。
  final List<String> searched;

  bool get ok => action != 'missing' && action != 'failed';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'action': action,
    'ok': ok,
    'path': workspacePath,
    if (sourcePath.isNotEmpty) 'source_path': sourcePath,
    'bytes': bytes,
    if (error.isNotEmpty) 'error': error,
    if (searched.isNotEmpty) 'searched': searched,
  };
}

/// 指南原件的**候选目录**（按优先级；与前端 `PluginDocs.candidatePaths` 同序，
/// 两端不共享代码，改一处要同步另一处）：
///
/// 1. [overrideDir]：显式指定（测试 / 将来加设置项）；
/// 2. **可执行文件同级** `plugins/`：发行布局（`Tree.exe` / `tree_core.exe` 与
///    `plugins/` 同级）；
/// 3. **仓根**的 `docs/`：开发态。锚定仓根而不是 cwd，理由同内置插件脚本
///    （桌面壳以构建产物目录为 cwd 拉起核心，相对 cwd 的回退一个都命中不了）；
/// 4. [currentDir] 的 `docs/`：`dart run` 兜底。
///
/// [executableDir] / [currentDir] 都是**测试注入**用（null = 真实的可执行文件目录 /
/// 进程当前工作目录）——不注入就没法在测试里复现"核心跑在构建产物目录下"这类布局。
List<String> pluginGuideSearchDirs({
  String? executableDir,
  String? overrideDir,
  String? currentDir,
}) {
  final String exeDir =
      executableDir ?? p.dirname(Platform.resolvedExecutable);
  final String? repo = BuiltinPluginCatalog.repoRoot(exeDir);
  final String cwd = currentDir ?? Directory.current.path;
  final List<String> raw = <String>[
    if (overrideDir != null && overrideDir.trim().isNotEmpty) overrideDir.trim(),
    p.join(exeDir, 'plugins'),
    if (repo != null) p.join(repo, 'docs'),
    p.join(cwd, 'docs'),
  ];
  final List<String> dirs = <String>[];
  for (final String dir in raw) {
    final String normalized = p.normalize(dir);
    if (!dirs.contains(normalized)) dirs.add(normalized);
  }
  return dirs;
}

/// 解析指南原件：返回**第一个存在**的绝对路径，都没有返回 null。
String? resolvePluginGuideSource({
  String? executableDir,
  String? overrideDir,
  String? currentDir,
}) {
  for (final String dir in pluginGuideSearchDirs(
    executableDir: executableDir,
    overrideDir: overrideDir,
    currentDir: currentDir,
  )) {
    final String candidate = p.join(dir, kPluginGuideFileName);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// 把指南原件播种进工作空间（**幂等**：内容一致就不写）。
///
/// **走 [io]**：本地工作空间写本机，SSH 工作空间写远端——副本必须出现在 **agent
/// 看得见的那一侧**（工具读的是工作空间 IO 那一侧的文件系统），否则播了等于没播。
/// 因此本函数既不拼本地路径、也不假设本机。
///
/// 失败**不抛**：返回 `missing` / `failed` + 可读原因，由调用方决定怎么回报
/// （规范正文里写了兜底流程：向用户索取原件）。
///
/// 语义：**核心维护这份副本**——内容与原件不一致就覆盖（`updated`），所以用户在
/// 副本上改的东西不会保留（规范正文已写明别手改）。
Future<PluginGuideSeed> seedPluginGuide(
  WorkspaceIO io, {
  String? executableDir,
  String? overrideDir,
  String? currentDir,
  void Function(String)? log,
  int maxBytes = 8 << 20,
}) async {
  final List<String> dirs = pluginGuideSearchDirs(
    executableDir: executableDir,
    overrideDir: overrideDir,
    currentDir: currentDir,
  );
  final String? source = resolvePluginGuideSource(
    executableDir: executableDir,
    overrideDir: overrideDir,
    currentDir: currentDir,
  );
  if (source == null) {
    final String reason =
        '核心所在机器上没找到 $kPluginGuideFileName（找过：${dirs.join('、')}）';
    log?.call('插件开发指南未播种：$reason');
    return PluginGuideSeed(
      action: 'missing',
      error: reason,
      searched: dirs,
    );
  }

  final String guide;
  try {
    guide = _normalizeNewlines(await File(source).readAsString());
  } catch (error) {
    final String reason = '读指南原件失败（$source）：$error';
    log?.call('插件开发指南未播种：$reason');
    return PluginGuideSeed(
      action: 'failed',
      sourcePath: source,
      error: reason,
      searched: dirs,
    );
  }

  // 先比内容再决定写不写：`unchanged` 时不写，避免每次 select 都刷一次 mtime。
  // `maxBytes` 放宽是为了**别把大文件按行截断**——截断会让比较永远不等，白写一遍。
  String? existing;
  try {
    existing = _normalizeNewlines(
      (await io.readFile(kPluginGuideWorkspacePath, maxBytes: maxBytes)).text,
    );
  } catch (_) {
    existing = null; // 不存在 / 不可读 / 是二进制：一律按"需要写"处理
  }
  final String action = existing == null
      ? 'created'
      : (_sameContent(existing, guide) ? 'unchanged' : 'updated');
  final int bytes = utf8.encode(guide).length;
  if (action == 'unchanged') {
    return PluginGuideSeed(
      action: action,
      sourcePath: source,
      bytes: bytes,
    );
  }
  try {
    await io.writeFile(kPluginGuideWorkspacePath, guide);
  } catch (error) {
    final String reason = '写工作空间失败（$kPluginGuideWorkspacePath）：$error';
    log?.call('插件开发指南未播种：$reason');
    return PluginGuideSeed(
      action: 'failed',
      sourcePath: source,
      bytes: bytes,
      error: reason,
    );
  }
  log?.call(
    '插件开发指南已播种到工作空间：$kPluginGuideWorkspacePath（$action，$bytes 字节，源 $source）',
  );
  return PluginGuideSeed(action: action, sourcePath: source, bytes: bytes);
}

/// 统一换行，让"内容是否一致"的比较不受 CRLF/LF 影响（仓库里是 LF，Windows 上
/// 手改过的副本可能是 CRLF——那不该被当成"内容变了"）。
String _normalizeNewlines(String text) => text.replaceAll('\r\n', '\n');

/// 两份内容是否**逐行相同**。
///
/// 为什么不直接比字符串：`WorkspaceIO.readFile` 把行 `join('\n')` 返回（**结尾换行
/// 被丢掉**，见 `local_workspace_io.dart` / `ssh_workspace_io.dart`），直接比字符串
/// 会永远不等——于是每次都白写一遍，也永远报不出 `unchanged`。
bool _sameContent(String a, String b) {
  final List<String> left = const LineSplitter().convert(_normalizeNewlines(a));
  final List<String> right = const LineSplitter().convert(_normalizeNewlines(b));
  if (left.length != right.length) return false;
  for (int i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
