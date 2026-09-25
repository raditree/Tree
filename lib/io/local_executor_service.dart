import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mcp_stdio_tunnel.dart';
import 'mcp_trust_store.dart';
import 'platform_support.dart';
import 'plugin_host_sessions.dart';
import 'ssh_executor_service.dart';
import 'websocket_service.dart';

/// 判断路径是否属于 Unix/WSL 风格目录（而非 Windows 盘符目录）。
///
/// 供本地执行器选择 shell 使用：Windows 上的 WSL 挂载目录（如
/// /mnt/e/...、\\wsl$\...）需要通过 bash / wsl.exe 才能访问，而
/// 纯 Windows 目录（如 C:\...）应继续使用 cmd /c。
///
/// 判定规则：
/// - 含 Windows 盘符（^[A-Za-z]:）→ 纯 Windows 目录（false）；
/// - 以 `/` 开头且无盘符 → Unix 风格（/mnt/...、/home/...、/usr/...）；
/// - 包含 /mnt/、/wsl、/usr/ 等特征 → Unix/WSL（覆盖 \\wsl$\UNC 形式）。
bool isUnixLikePath(String path) {
  final String p = path.trim();
  if (p.isEmpty) return false;
  final String normalized = p.replaceAll('\\', '/');
  if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return false;
  if (normalized.startsWith('/')) return true;
  return normalized.contains('/mnt/') ||
      normalized.contains('/wsl') ||
      normalized.contains('/usr/') ||
      normalized.contains('/home/') ||
      normalized.contains('/tmp/');
}

/// 为工作目录解析应使用的 shell 名（纯函数，便于单元测试）。
///
/// - Unix/WSL 目录 → 'bash'（Windows 平台执行时自动回退 wsl.exe）
/// - 纯 Windows 目录 → 'cmd'
String? resolveShellForDir(String path) {
  if (path.isEmpty) return null;
  return isUnixLikePath(path) ? 'bash' : 'cmd';
}

/// Windows 下 cmd 会话的 UTF-8 代码页切换前缀（纯函数，供 [_execShell] 与
/// hook 临时 bat 复用；单元测试可验证拼接结果）。
///
/// Windows 的 cmd 内置命令（dir/type/findstr 等）按当前代码页输出字节
/// （中文系统默认 GBK），后端按 UTF-8 严格解码会抛 FormatException 导致
/// 工具失败。以 `chcp.com 65001 >nul 2>&1 & ` 前缀执行，使同一 cmd 会话的
/// 输出统一为 UTF-8（子进程输出经环境变量 PYTHONUTF8=1 强开 UTF-8）。
String windowsCmdUtf8Prefix() => 'chcp.com 65001 >nul 2>&1 & ';

/// 本地宿主进程启动器（M2 `plugin_host_*`）：包装 [Process] 为句柄。
///
/// 本批固定最小空转进程（安全收口：不执行取自 payload 的任意命令）；
/// 进程形态由 [defaultIdleArgv] 决定（Windows ping / Unix sleep；
/// WSL 目录经 bash 进入）。stdout 排空（宿主会话不需要其内容）；stderr
/// 交由 [PluginHostSessionManager] 聚合尾部。
Future<PluginHostProcessHandle> spawnLocalPluginHostProcess(
  PluginHostSpawnRequest request,
) async {
  final bool isWindows = Platform.isWindows;
  final List<String> argv = defaultIdleArgv(
    isWindows: isWindows,
    unixLike: request.unixLike,
    workingDirectory: request.workingDirectory,
  );
  final Process process = (isWindows && request.unixLike)
      // WSL/Unix 风格目录：Windows API 无法作为 cwd，argv 已含 cd（同上）
      ? await Process.start(argv[0], argv.sublist(1))
      : await Process.start(
          argv[0],
          argv.sublist(1),
          workingDirectory: request.workingDirectory,
        );
  // 排空 stdout，避免管道背压（宿主会话不消费 stdout）
  process.stdout.listen((List<int> _) {}, onError: (Object _) {});
  return PluginHostProcessHandle(
    pid: process.pid,
    exitCode: process.exitCode,
    stderr: process.stderr,
    kill: () => process.kill(),
  );
}

/// 解码进程输出字节：严格 UTF-8 优先，失败回退 latin1 逐字节（不抛异常）。
///
/// Windows 下少量程序仍按 GBK 输出（chcp 65001 后基本消除），latin1 兜底
/// 保证工具成功返回（个别字符可能显示为扩展拉丁字符，但不中断任务）。
/// 纯函数，供 [_runProcess] / [_readFile] / [_searchFile] 复用与单测。
String decodeProcessBytes(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  final List<int> bytes = value is List<int> ? value : <int>[];
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// grep 命中行回传的单行最大字符数（与后端 GrepTool.DEFAULT_MAX_LINE_CHARS 一致）。
const int kGrepMaxLineChars = 2000;

/// 超长行截断时在命中点前后保留的上下文宽度（与后端 GrepTool 一致）。
const int kGrepMatchContextChars = 1000;

/// grep 结果回传的总字符上限（与后端 GrepTool.DEFAULT_MAX_TOTAL_CHARS 一致）。
const int kGrepMaxTotalChars = 100000;

/// 发送端截断单条 grep 命中行：取「命中点 ± 上下文」窗口，被裁掉处标 `…`。
///
/// 本地 grep 的结果要经反向 WS 单帧回传给后端，而 jsonl / SQLite 库这类文件
/// 单行可达数百万字符，整行回传会把单帧撑到数十 MB。uvicorn 的 ``ws_max_size``
/// 默认为 16MiB，超限帧会被**静默**关闭连接（不产生 WARNING/ERROR 日志），连带
/// 注销执行器注册、把在途工具调用全部打断。后端 GrepTool 的同名上限只在"收到
/// 之后"才生效，救不了已经超限的帧，因此截断必须在发送端完成。
///
/// 窗口宽度与后端 ``_truncate_line`` 对齐，区别是把 `…` 标记也算进
/// [kGrepMaxLineChars] 预算内，保证回传行长度不超过该值、不会被后端二次截断。
///
/// :param line: 待检查的命中行
/// :param pattern: 搜索模式（用于定位命中点；正则非法时退化为行首窗口）
/// :param regex: pattern 是否为正则
/// :param ignoreCase: 是否忽略大小写
/// :return: 截断后的文本；未超长时返回 null（调用方保留原文即可）
///
/// 纯函数，供 [_searchFile] 与单测复用。
String? truncateGrepLine(
  String line,
  String pattern, {
  bool regex = false,
  bool ignoreCase = false,
}) {
  if (line.length <= kGrepMaxLineChars) return null;

  int start = -1;
  if (regex) {
    try {
      final RegExpMatch? m =
          RegExp(pattern, caseSensitive: !ignoreCase).firstMatch(line);
      if (m != null) start = m.start;
    } on FormatException {
      start = -1;
    }
  } else {
    final String key = ignoreCase ? line.toLowerCase() : line;
    final String needle = ignoreCase ? pattern.toLowerCase() : pattern;
    start = key.indexOf(needle);
  }
  if (start < 0) start = 0;

  int begin = start - kGrepMatchContextChars;
  if (begin < 0) begin = 0;
  int end = begin + kGrepMaxLineChars;
  if (end > line.length) {
    end = line.length;
    begin = end - kGrepMaxLineChars;
    if (begin < 0) begin = 0;
  }
  final bool head = begin > 0;
  final bool tail = end < line.length;
  // 省略号也占预算：只从"被裁掉的那一侧"收缩（该侧已被裁剪、有余量），
  // 保证命中点始终落在窗口内，且最终长度不超过 kGrepMaxLineChars
  int over = (end - begin) + (head ? 1 : 0) + (tail ? 1 : 0) -
      kGrepMaxLineChars;
  while (over > 0) {
    if (head) {
      begin++;
      over--;
    }
    if (over > 0 && tail) {
      end--;
      over--;
    }
  }
  return '${head ? '…' : ''}${line.substring(begin, end)}${tail ? '…' : ''}';
}

/// grep 命中的发送端收集器：逐行按 [truncateGrepLine] 截断，并在累计字符数
/// 达到 [kGrepMaxTotalChars] 后停止收集（``full`` 为真，遍历随之终止）。
///
/// 上限取值与后端 GrepTool 的同名常量一致，保证"前端截一刀、后端不再截"
/// 的语义可预期：结果总量受控，`truncated` / `line_truncated` 由本类产生并
/// 随 ``tool_exec_response`` 回传。
class _GrepCollector {
  _GrepCollector({
    required this.pattern,
    required this.regex,
    required this.ignoreCase,
  });

  /// 搜索模式（用于定位超长行的命中点）
  final String pattern;

  /// pattern 是否为正则
  final bool regex;

  /// 是否忽略大小写
  final bool ignoreCase;

  /// 已收集的 ``路径:行号:内容`` 行
  final List<String> lines = <String>[];

  /// 累计字符数（含换行符）
  int _chars = 0;

  /// 是否已达总量上限（后续命中全部丢弃）
  bool truncated = false;

  /// 是否至少有一行被按命中点截断
  bool lineTruncated = false;

  /// 是否已达总量上限（遍历据此提前收敛）
  bool get full => truncated;

  /// 记录一条命中；超过总量上限时置 [truncated] 并丢弃该行。
  void add(String filePath, int lineNo, String line) {
    if (truncated) return;
    final String? cut = truncateGrepLine(
      line,
      pattern,
      regex: regex,
      ignoreCase: ignoreCase,
    );
    if (cut != null) lineTruncated = true;
    final String entry = '$filePath:$lineNo:${cut ?? line}';
    final int addLen = entry.length + 1; // +1 记换行符
    if (_chars > 0 && _chars + addLen > kGrepMaxTotalChars) {
      truncated = true;
      return;
    }
    lines.add(entry);
    _chars += addLen;
  }
}

/// 本地执行器服务 - 在本地运行模式下执行后端推送的工具请求
///
/// 本地运行模式：后端完整运行在云端，但工具调用环境转移到用户本机。
/// 后端把工具调用包装成 ``tool_exec_request`` 推送到前端，本服务在
/// 用户选择的工作目录中执行 read / write / exec_shell / exec_argv /
/// grep_search 等操作，并把结果通过 ``tool_exec_response`` 回传后端。
///
/// 本服务同时负责本地执行模式的开关与工作目录的持久化（替代已废弃的
/// LocalBackendService）：切换开关只改变"工具执行位置"，不再启动任何
/// 本地 Python 后端进程。
///
/// 本地模式按顶部 agent（team）单独控制：开关与工作目录以顶部 agent 为单位
/// 持久化，内部状态为 per-team 的 ``Map<teamId, _LocalTeamState>``；所有执行
/// 路径按请求 payload 的 ``team_id`` 查找对应状态，与"当前选中 agent"解耦。
/// 注册由懒激活驱动：消息发送前 [ensureTeam] 幂等地加载并注册已启用的 team，
/// WS 重连后 [syncRegisteredTeams] 恢复"已注册且启用"team 的注册。
///
/// 工作空间路径映射（与后端协同布局保持一致）：
/// - 顶级 agent 与团队成员的工作根统一为用户选择的工作目录 <baseDir>；
/// - 各 agent 的私人记忆空间（``.self`` 令牌路径）按 workspace_id
///   分目录落 <baseDir>/agentspace/{workspace_id}/.self（workspace_id =
///   顶层的 teamId / 成员的 member_id）。

/// 大文件分片上传会话状态（本地执行器）。
///
/// 后端分片通道（upload_init/chunk/complete）按 upload_id 关联：init 打开
/// 文件句柄并记录分片/总大小，chunk 按偏移追加，complete 关闭句柄并校验。
class _LocalUploadSession {
  _LocalUploadSession({
    required this.raf,
    required this.relPath,
    required this.fullPath,
    this.chunkSize = 4 * 1024 * 1024,
    this.totalSize = 0,
  });

  /// 已打开的本地文件句柄（FileMode.write，截断写）
  final RandomAccessFile raf;

  /// 工作空间内相对路径（如 ``.input/20260906/big.bin``）
  final String relPath;

  /// 本机绝对路径（complete 后校验大小用）
  final String fullPath;

  /// 分片大小（后端 upload_init 下发，chunk 偏移 = index × chunkSize）
  final int chunkSize;

  /// 期望总大小（complete 时校验；0 表示不校验）
  final int totalSize;

  /// 已接收字节数（记录用）
  int received = 0;
}

/// 单个顶部 agent（team）的本地执行器状态。
class _LocalTeamState {
  _LocalTeamState({required this.teamId});

  /// 顶部 agent（team）ID
  final String teamId;

  /// 本地执行模式是否启用（持久化）
  bool enabled = false;

  /// 本地工作目录（持久化）
  String baseDir = '';

  /// 是否已向后端注册本地执行器
  bool registered = false;
}

/// 第三方 MCP 服务的 stdio 隧道（本地模式）。
///
/// local 模式下后端不直接接触 MCP 服务进程：由本端按 ``mcp_stdio_open`` 拉起
/// 子进程，后端写出的 JSON-RPC 帧经 ``mcp_stdio_write`` 写入其 stdin，子进程
/// stdout 上按换行分隔的完整帧经 ``mcp_stdio_read`` 原样（base64）回传，直至
/// ``mcp_stdio_close`` 终止会话。一次工具调用对应一个会话（open → call →
/// close），与后端直连 stdio 的语义一致；会话语义（行缓冲 / 挂起读取 / 退出
/// 感知）由 [McpStdioTunnelSession] 提供并与 SSH 宿主共用，本地侧只补上
/// "本机子进程"这一管道。
///
/// 会话 id 由本端生成（时间戳 + 自增序号），在 [_mcpSessions] 中与子进程一一
/// 对应；子进程退出或会话关闭时回收。
class LocalExecutorService extends ChangeNotifier {
  LocalExecutorService._();

  /// 全局单例
  static final LocalExecutorService instance = LocalExecutorService._();

  /// SharedPreferences 键前缀（后接团队 ID，实现按顶部 agent 持久化）
  static const String _kEnabledPrefix = 'local_exec_enabled_';
  static const String _kWorkDirPrefix = 'local_exec_working_dir_';

  static String _kEnabledKey(String teamId) => '$_kEnabledPrefix$teamId';
  static String _kWorkDirKey(String teamId) => '$_kWorkDirPrefix$teamId';

  /// 同步工具执行期间的进度上报间隔。
  ///
  /// 后端等待响应时以"距最近一次进度上报"做卡死判定：只要前端还在执行就
  /// 周期上报 ``tool_exec_progress`` 续期，真正在干活的长任务（grep 数分钟 /
  /// terminal 360s+）不会被后端等待窗口误杀；本间隔应明显小于后端的
  /// _STALL_WITHOUT_PROGRESS_SECONDS（60s），留足网络/调度余量。
  static const Duration _kToolProgressInterval = Duration(seconds: 10);

  /// 承载当前 WebSocket 通道的服务（用于接收请求与回传结果）
  WebSocketService? _ws;

  /// hook 模式分离进程集合：tool_id -> Process（可被 kill 终止）。
  ///
  /// 本地模式长任务（terminal hook）由 [Process.start] 托管句柄，进程退出时
  /// 回传 ``tool_exec_response``；取消时经 ``tool_exec_cancel`` 触发 [killProcess]。
  final Map<String, Process> _hookProcesses = <String, Process>{};

  /// 大文件分片上传会话：upload_id -> 上传状态（已打开文件句柄 + 已写入偏移）。
  ///
  /// 后端 REST 分片通道（init/chunk/complete）按 upload_id 转发到本端，
  /// init 时打开文件句柄，chunk 按 offset 追加，complete 时关闭并校验。
  final Map<String, _LocalUploadSession> _uploadSessions =
      <String, _LocalUploadSession>{};

  /// 第三方 MCP 服务的 stdio 隧道会话：session_id -> 会话状态。
  ///
  /// 后端每发起一次 MCP 工具调用就 open 一个会话并驱动其 stdin/stdout，
  /// 调用结束后 close；本表仅在会话存活期间持有子进程句柄（经 [Process] 的
  /// 写管道闭包与退出回调维持引用）。
  final Map<String, McpStdioTunnelSession> _mcpSessions =
      <String, McpStdioTunnelSession>{};

  /// MCP 会话 id 自增序号（与时间戳拼接，避免同微秒内碰撞）
  int _mcpSessionSeq = 0;

  /// 插件宿主会话管理器（M2：`plugin_host_*` 通道，契约 v1.3 §14）。
  ///
  /// 启动器 = [spawnLocalPluginHostProcess]（本机 Process；测试可注入 fake）。
  late PluginHostSessionManager _pluginHosts = PluginHostSessionManager(
    spawn: spawnLocalPluginHostProcess,
    notify: _send,
  );

  /// 测试注入口：替换宿主会话管理器（fake 启动器，避免真进程）。
  @visibleForTesting
  void debugSetPluginHostManager(PluginHostSessionManager manager) {
    _pluginHosts = manager;
  }

  /// per-team 状态：team_id -> 本地执行器状态。
  ///
  /// 所有执行路径按请求 payload 的 ``team_id`` 查找状态，与"当前选中
  /// agent"解耦；条目由 [loadTeamSettings] / [ensureTeam] 懒创建。
  final Map<String, _LocalTeamState> _states = <String, _LocalTeamState>{};

  /// 指定 team 的本地执行模式是否已启用（无状态时视为未启用，供 UI 显示）
  bool isTeamEnabled(String teamId) => _states[teamId]?.enabled ?? false;

  /// 指定 team 的本地工作目录（无状态时返回空串，供 UI 显示）
  String teamWorkingDirectory(String teamId) => _states[teamId]?.baseDir ?? '';

  /// 读取指定 team 的持久化设置到内存状态（不触发注册，供 UI 显示/预填）。
  Future<void> loadTeamSettings(String teamId) async {
    if (teamId.isEmpty) return;
    final _LocalTeamState state =
        _states.putIfAbsent(teamId, () => _LocalTeamState(teamId: teamId));
    await _loadTeamSettings(state);
  }

  /// 从 SharedPreferences 恢复单个 team 的设置。
  ///
  /// 竞态防护：等待期间该条目可能已被 [deactivateTeam] 移除或替换，
  /// 丢弃过期恢复结果（否则已删除 team 的设置会被写回内存态）。
  Future<void> _loadTeamSettings(_LocalTeamState state) async {
    final String id = state.teamId;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!identical(_states[id], state)) return;
    state.enabled = prefs.getBool(_kEnabledKey(id)) ?? false;
    state.baseDir = prefs.getString(_kWorkDirKey(id)) ?? '';
  }

  /// 懒激活指定 team 的本地执行器（幂等）。
  ///
  /// - 状态不存在：创建并从 SharedPreferences 恢复设置；
  /// - 已启用且配置了工作目录但未注册：执行注册流程；
  /// - 未启用 / 未配置目录：静默返回（后端按"无执行器"回落云端执行）。
  Future<void> ensureTeam(String teamId) async {
    if (teamId.isEmpty) return;
    _LocalTeamState? state = _states[teamId];
    if (state == null) {
      final _LocalTeamState created = _LocalTeamState(teamId: teamId);
      _states[teamId] = created;
      await _loadTeamSettings(created);
      state = _states[teamId];
      if (state == null) return; // 等待期间被 deactivateTeam 移除
    }
    if (isMobile) return; // 移动端不支持本地执行模式，不注册
    if (state.enabled && state.baseDir.isNotEmpty && !state.registered) {
      _registerTeam(state);
    }
  }

  /// 注销指定 team 的本地执行器并移除其状态（删除顶部 agent 时调用）：
  /// 通知后端该 team 恢复云端执行，并清理内存状态。
  void deactivateTeam(String teamId) {
    if (teamId.isEmpty) return;
    _disposeMcpSessionsOf(teamId);
    // 级联回收该 team 的插件宿主会话（M2 §14.3.2）
    _pluginHosts.recycleTeam(teamId);
    if (_states.remove(teamId) == null) return;
    _sendUnregister(teamId);
    notifyListeners();
  }

  /// 启用/禁用指定 team 的本地执行模式（模式切换弹窗调用）。
  ///
  /// 开启时若已有工作目录立即注册本地执行器；关闭时注销并恢复云端执行。
  /// 不启动任何本地进程——工具执行位置由后端通过反向 WS 转发决定。
  /// 移动端（Android/iOS）无桌面文件系统访问能力，禁止开启。
  Future<void> setTeamEnabled(String teamId, bool value) async {
    if (teamId.isEmpty) return;
    if (isMobile && value) return; // 移动端不支持本地执行模式
    if (!value) {
      // 关闭本地模式：插件宿主会话不再可用，立即级联回收（M2 §14.3.2）
      _pluginHosts.recycleTeam(teamId);
    }
    final _LocalTeamState state =
        _states.putIfAbsent(teamId, () => _LocalTeamState(teamId: teamId));
    if (value == state.enabled) {
      // 状态一致但连接可能已重建，重新确保注册/注销
      if (value && state.baseDir.isNotEmpty) {
        _registerTeam(state);
      } else if (!value && state.registered) {
        _unregisterTeam(state);
      }
      return;
    }
    state.enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey(teamId), value);
    if (value) {
      if (state.baseDir.isNotEmpty) _registerTeam(state);
    } else {
      _unregisterTeam(state);
    }
    notifyListeners();
  }

  /// 设置指定 team 的工作目录并持久化
  Future<void> setTeamWorkingDirectory(String teamId, String path) async {
    if (teamId.isEmpty) return;
    final _LocalTeamState state =
        _states.putIfAbsent(teamId, () => _LocalTeamState(teamId: teamId));
    state.baseDir = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kWorkDirKey(teamId), path);
    notifyListeners();
  }

  /// WS 重连/首连后恢复注册：仅对"已注册且启用"的 team 重新发送注册消息。
  ///
  /// 后端在 WS 断连时按连接自动清理注册，重连后需要恢复；未激活的 team
  /// （未启用 / 未配置目录）不注册，后端按"无执行器"回落云端。
  void syncRegisteredTeams() {
    // WS（重）连：宿主会话先全部标记失联，重注册后按"本端可继续承载"对账回收
    _pluginHosts.markAllLost();
    for (final _LocalTeamState state in _states.values) {
      if (state.enabled && state.baseDir.isNotEmpty && state.registered) {
        _registerTeam(state);
      }
    }
    _pluginHosts.reconcileAfterReconnect(
      (String teamId) =>
          _states[teamId]?.enabled == true &&
          _states[teamId]?.registered == true,
    );
  }

  /// 处理后端 ``registration_lost`` 通知：该 team 的执行器注册已被后端清除
  /// （WS 断连清理 / 连续超时自动停用）。
  ///
  /// 复位 registered=false，使后续 [ensureTeam]（发消息/作答/重连自动补注册）
  /// 不会因 stale registered=true 而跳过——否则后端已注销执行器、前端仍以为
  /// 注册在册，工具调用会一直"前端执行器未启用"无法自愈。启用开关与工作目录
  /// 等持久化设置不受影响。
  void handleRegistrationLost(String teamId) {
    if (teamId.isEmpty) return;
    // 注册丢失：该 team 宿主会话标记失联（不 kill；重连后对账，M2 §14.3.3）
    _pluginHosts.markTeamLost(teamId);
    final _LocalTeamState? state = _states[teamId];
    if (state != null && state.registered) {
      state.registered = false;
      debugPrint(
        '[LocalExecutor] 后端通知执行器注册已丢失(team=$teamId)，'
        '将在下次动作时自动重注册',
      );
    }
  }

  /// 绑定 WebSocket 服务并接管 ``tool_exec_request`` / ``tool_exec_cancel``。
  ///
  /// 每个 WebSocket 连接建立后都应调用一次（本地模式）。内部只接管
  /// 工具执行请求与取消消息，其余消息仍正常派发给页面。
  void attach(WebSocketService ws) {
    _ws = ws;
    ws.addToolExecRequestHandler(_handleToolExecRequest);
    ws.addToolExecCancelHandler(_handleToolExecCancel);
  }

  /// 处理 ``tool_exec_cancel``：终止对应 hook 分离进程（payload 中的
  /// pidfile 为 SSH 模式字段，本地模式忽略）。
  void _handleToolExecCancel(Map<String, dynamic> message) {
    final Map<String, dynamic> data =
        (message['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String toolId = (data['tool_id'] as String?) ?? '';
    if (toolId.isEmpty) return;
    killProcess(toolId);
  }

  /// 终止指定 hook 分离进程（尽力终止）。
  ///
  /// 取消后进程退出仍会经 ``tool_exec_response`` 回传，后端据此将任务标记
  /// 为 cancelled。进程未运行/已退出时静默忽略。
  void killProcess(String toolId) {
    _hookProcesses.remove(toolId)?.kill();
  }

  /// 注册单个 team 的本地执行器：通知后端把该 team 的工具请求转发到本端。
  void _registerTeam(_LocalTeamState state) {
    if (state.teamId.isEmpty) return;
    if (isMobile) return; // 移动端不支持本地执行模式，不注册
    state.registered = true;
    _send(<String, dynamic>{
      'type': 'register_local_executor',
      'data': <String, dynamic>{
        'base_dir': state.baseDir,
        'team_id': state.teamId,
      },
    });
  }

  /// 注销单个 team 的本地执行器：通知后端该 team 恢复云端执行。
  void _unregisterTeam(_LocalTeamState state) {
    state.registered = false;
    _sendUnregister(state.teamId);
  }

  /// 向后端发送注销指定顶部 agent 的本地执行器消息。
  void _sendUnregister(String teamId) {
    if (teamId.isEmpty) return;
    _send(<String, dynamic>{
      'type': 'unregister_local_executor',
      'data': <String, dynamic>{'team_id': teamId},
    });
  }

  /// 应用退出 / 页面销毁时清理资源。
  ///
  /// 替代已废弃的 LocalBackendService.dispose()：本服务不常驻本地后端进程，
  /// 只需通知后端注销本地执行器（避免后端残留注册导致工具请求被错误路由）、
  /// 回收存活的 MCP 隧道子进程，并释放 WebSocket 引用、复位注册状态。清理后
  /// 下次连接会通过 [attach] + [syncRegisteredTeams] 按状态恢复注册。
  void cleanup() {
    for (final _LocalTeamState state in _states.values) {
      if (state.registered) {
        _sendUnregister(state.teamId);
        state.registered = false;
      }
    }
    // 回收所有残留的 MCP 隧道子进程（调用中途退出时后端不再回 close）
    for (final McpStdioTunnelSession session
        in _mcpSessions.values.toList(growable: false)) {
      session.dispose();
    }
    _mcpSessions.clear();
    // 回收全部插件宿主会话（M2；本地进程不可随应用退出存活，直接终止）
    _pluginHosts.recycleAll();
    _ws?.removeToolExecRequestHandler(_handleToolExecRequest);
    _ws?.removeToolExecCancelHandler(_handleToolExecCancel);
    _ws = null;
  }

  /// 解析工具请求的工作目录（与后端本地路径映射保持一致）。
  ///
  /// 协同语义：
  /// - 所有 agent（顶层 agent 与团队成员）的工作文件都在工作目录
  ///   <baseDir> 中读写执行，实现全队协同工作——因此非记忆路径一律返回 base。
  /// - 每个 agent 的私人记忆文件（``.self`` 开头的路径，相对令牌 ``.self/xxx``）
  ///   按各自的 workspace_id 解析到 <baseDir>/agentspace/{workspace_id} 下
  ///   （相对令牌仍保留 ``.self`` 前缀，最终物理落点为
  ///   <baseDir>/agentspace/{workspace_id}/.self/xxx）。
  Directory _resolveWorkspaceDir(
    String baseDir,
    String workspaceId, [
    String path = '',
  ]) {
    final String base = baseDir.isEmpty ? Directory.current.path : baseDir;
    if (_isPrivatePath(path)) {
      return Directory('$base${Platform.pathSeparator}agentspace'
          '${Platform.pathSeparator}$workspaceId');
    }
    return Directory(base);
  }

  /// 判断路径是否属于 agent 的私人记忆空间（``.self`` 开头的路径）。
  bool _isPrivatePath(String path) {
    final String p = path.replaceAll('\\', '/').trim();
    return p == '.self' || p.startsWith('.self/');
  }

  /// 发送消息到后端
  void _send(Map<String, dynamic> message) {
    _ws?.send(message);
  }

  /// 处理 ``tool_exec_request``，异步执行后回传 ``tool_exec_response``。
  ///
  /// 返回 `true` 表示已接管该请求（工具执行请求在本地模式下发到本端时
  /// 总是由本处理者执行）；请求不属于本前端已注册且启用的 team、或该 team
  /// 处于 SSH 模式时返回 `false`，把请求放行给 SSH 执行器 / 其他实例处理。
  bool _handleToolExecRequest(Map<String, dynamic> message) {
    final Map<String, dynamic> data =
        (message['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String toolId = (data['tool_id'] as String?) ?? '';
    final String reqTeam = (data['team_id'] as String?) ?? '';
    // payload 校验：tool_id 缺失时后端 pending 无法定位、本端无法回包，放行
    if (toolId.isEmpty) return false;
    // team_id 缺失：直接快速失败回包，避免后端 pending 空等 120s
    if (reqTeam.isEmpty) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'success': false,
        'error': 'missing team_id/tool_id',
      });
      return true;
    }
    // SSH 模式守卫（按 team 粒度）：同一 team 启用了 SSH 模式时让位给
    // SSH 执行器（SSH 优先），由后者接管该请求——本端"本地不可执行"并不
    // 等于该请求无人处理，故必须先于下面的回错分支判断，否则会截断
    // SSH 执行器的接管（返回 true 后不再派发给后续处理者）。
    if (SshExecutorService.instance.isTeamEnabled(reqTeam)) {
      return false;
    }
    // 归属校验（集合化）：仅接管"本前端已注册且启用本地模式"的 team——按
    // 请求 payload 的 team_id 查 per-team 状态，不读"当前选中 agent"槽位。
    // 后端按注册连接定向投递（``targeted=true``），请求落到本端即说明后端
    // 认定本端是该 team 的执行器——此时本地却不可执行（刚被 registration_lost
    // 复位 / 已关闭本地模式 / 状态不一致），必须明确回传错误：否则后端会空等
    // 满卡死窗口（60s）后误判"前端卡死"并自动停用执行器注册。
    // ``targeted=false``（后端未记录注册连接的广播兜底）下保持静默放行：同用户
    // 其他实例可能才是真正的执行器，抢先回错会占位并丢弃对方的成功结果
    // （见 LocalExecutorClient.resolve 取首个响应即唤醒等待方）。
    final _LocalTeamState? state = _states[reqTeam];
    if (state == null || !state.enabled || !state.registered) {
      if ((data['targeted'] as bool?) ?? false) {
        _sendToolExecResponse(toolId, <String, dynamic>{
          'error': '本地执行器当前不可用（未注册或未启用本地模式），'
              '请重新开启该 agent 的本地模式后重试',
        });
        return true;
      }
      return false;
    }
    // 已启用但未选择工作目录：明确报错，禁止用 Directory.current 兜底
    // （打包运行时的当前目录是 exe 所在目录，工具会在错误位置执行）
    if (state.baseDir.isEmpty) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': '本地模式未选择工作目录，请在标题栏选择目录后重试',
        'exit_code': -1,
      });
      return true;
    }
    final String workspaceId = (data['workspace_id'] as String?) ?? '';
    final String op = (data['op'] as String?) ?? '';

    // hook 模式：分离进程后台执行，进程退出时再回传（不在此处立即响应）
    if (op == 'exec_shell_hook') {
      final String path = (data['output_file'] as String?) ?? '';
      final Directory wsDir =
          _resolveWorkspaceDir(state.baseDir, workspaceId, path);
      _execShellHookDeferred(wsDir, toolId, data);
      return true;
    }

    // 同步工具执行：执行期间每 _kToolProgressInterval 上报一次进度，让后端
    // 的卡死检测续期——长任务（grep / terminal 等）只要在跑就不会被误判为
    // 超时；执行结束/出错即取消定时器并回传结果。
    // （hook 分支已在上方 return，此处必为同步执行，定时器必然创建）
    final Timer progressTimer = Timer.periodic(
      _kToolProgressInterval,
      (_) => _sendToolProgress(toolId, reqTeam),
    );
    _execute(workspaceId, op, data, state.baseDir, reqTeam)
        .then((Map<String, dynamic> result) {
      _sendToolExecResponse(toolId, result);
    }).catchError((Object error) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': error.toString(),
      });
    }).whenComplete(() => progressTimer.cancel());
    return true;
  }

  /// 上报一次工具执行进度（``tool_exec_progress``，供后端卡死检测续期）。
  void _sendToolProgress(String toolId, String teamId) {
    _send(<String, dynamic>{
      'type': 'tool_exec_progress',
      'data': <String, dynamic>{
        'tool_id': toolId,
        'team_id': teamId,
      },
    });
  }

  /// 回传一次工具执行结果（``tool_exec_response``）。
  void _sendToolExecResponse(String toolId, Map<String, dynamic> result) {
    _send(<String, dynamic>{
      'type': 'tool_exec_response',
      'data': <String, dynamic>{
        'tool_id': toolId,
        'result': result,
      },
    });
  }

  /// hook 模式：分离进程后台执行长命令，输出实时写入 output_file。
  ///
  /// 与 [_execShell] 相同的 shell 解析（Unix/WSL= bash，Windows=cmd），但用
  /// [Process.start] 托管句柄（可被 [killProcess] 终止）且**不设超时**；进程
  /// 退出后回传真实退出码（不受后端 120s 等待上限约束）。启动失败立即回传
  /// 错误，避免后端挂起。
  ///
  /// 输出落盘：**不依赖 shell 重定向**——命令内 `cd` 会改变 cmd/bash 工作
  /// 目录，后端拼的相对路径（.output/hook_x.log）会解析到错误位置导致空
  /// 日志；本端改用绝对路径流式写入（stdout/stderr 管道 → 文件）。
  Future<void> _execShellHookDeferred(
    Directory wsDir,
    String toolId,
    Map<String, dynamic> data,
  ) async {
    final String command = (data['command'] as String?) ?? '';
    if (command.isEmpty) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': 'exec_shell_hook 缺少 command',
        'exit_code': -1,
      });
      return;
    }
    // 解析输出重定向文件绝对路径并确保父目录存在（后端已创建占位文件）
    final String outputFile = (data['output_file'] as String?) ?? '';
    String fullOut = '';
    try {
      if (outputFile.isNotEmpty) {
        fullOut = _resolveInWorkspace(wsDir, outputFile);
        await File(fullOut).parent.create(recursive: true);
      }
    } catch (e) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': '输出文件路径非法: $e',
        'exit_code': -1,
      });
      return;
    }
    final String workDir = wsDir.path;
    try {
      // 以绝对路径打开输出 sink（覆盖写：丢弃后端占位文件的空内容）
      final IOSink? sink = fullOut.isEmpty
          ? null
          : File(fullOut).openWrite();
      Process process;
      if (isUnixLikePath(workDir)) {
        // Unix/WSL 工作目录：Windows API 无法识别，改用 bash -lc "cd .. && .."
        final String bashBody = "cd '$workDir' && $command";
        process = await Process.start('bash', <String>['-lc', bashBody]);
      } else if (Platform.isWindows) {
        // Windows：命令写入临时 .bat 再执行——绕开 cmd /c 命令行对引号/
        // 重定向/&& 的解析坑（Dart 进程参数引号处理会导致带引号命令的
        // stdout 丢失，表现为 hook 日志为空），确保输出可靠进入管道
        final String batPath =
            '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'hook_${toolId}_exec.bat';
        // 先 chcp 65001 再执行命令：与 _execShell 同步路径一致，确保管道/
        // 输出文件中的字节为 UTF-8（后端按 UTF-8 读取 hook 日志）。
        await File(batPath).writeAsString(
          '@echo off\r\n${windowsCmdUtf8Prefix()}\r\n$command\r\n',
        );
        process = await Process.start(
          'cmd',
          <String>['/d', '/s', '/c', batPath],
          workingDirectory: workDir,
        );
        // 进程退出后清理临时 bat（尽力而为，失败不影响任务）
        process.exitCode.whenComplete(() {
          try {
            File(batPath).deleteSync();
          } catch (_) {
            // 忽略：临时文件残留无碍
          }
        });
      } else {
        process = await Process.start(
          'sh',
          <String>['-c', command],
          workingDirectory: workDir,
        );
      }
      _hookProcesses[toolId] = process;
      // 实时把 stdout/stderr 写入输出文件（不依赖 shell 重定向）。
      // outputFile 为空时也无碍（hook_manager 总会生成），此处仍兜底。
      final StringBuffer memOut = StringBuffer();
      final Completer<void> outDone = Completer<void>();
      final Completer<void> errDone = Completer<void>();
      // 实时把 stdout/stderr 写入输出文件（不依赖 shell 重定向）。
      // onDone 记录流结束，用于等待管道 EOF（进程退出时剩余数据仍在
      // 事件循环队列中，过早关闭 sink 会丢失尾部输出）。
      process.stdout.listen((List<int> chunk) {
        if (sink != null) {
          sink.add(chunk);
        } else {
          memOut.write(String.fromCharCodes(chunk));
        }
      }, onDone: () {
        if (!outDone.isCompleted) outDone.complete();
      }, cancelOnError: true);
      process.stderr.listen((List<int> chunk) {
        if (sink != null) {
          sink.add(chunk);
        } else {
          memOut.write(String.fromCharCodes(chunk));
        }
      }, onDone: () {
        if (!errDone.isCompleted) errDone.complete();
      }, cancelOnError: true);
      process.exitCode.then((int code) async {
        _hookProcesses.remove(toolId);
        // 等待 stdout/stderr 流 EOF 后再落盘回传：避免后端立刻读取
        // 输出文件读到未刷新/缺失尾部的内容
        try {
          await Future.wait(<Future<void>>[outDone.future, errDone.future]);
          if (sink != null) {
            await sink.flush();
            await sink.close();
          }
        } catch (_) {
          if (sink != null) sink.close();
        }
        _sendToolExecResponse(toolId, <String, dynamic>{
          'exit_code': code,
          'stdout': sink != null ? '' : memOut.toString(),
          'stderr': '',
        });
      });
    } on ProcessException catch (e) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': '启动命令失败: ${e.message}',
        'exit_code': -1,
      });
    } catch (e) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': '启动命令失败: $e',
        'exit_code': -1,
      });
    }
  }

  /// 按操作类型分发执行
  Future<Map<String, dynamic>> _execute(
    String workspaceId,
    String op,
    Map<String, dynamic> data,
    String baseDir,
    String teamId,
  ) async {
    // 携带操作路径，按路径路由：.self 记忆 → 私人空间；其余 → 工作目录 base
    final String path = (data['path'] as String?) ?? '';
    final Directory wsDir = _resolveWorkspaceDir(baseDir, workspaceId, path);
    switch (op) {
      case 'list_files':
        return _listFiles(wsDir, data);
      case 'read_file':
        return _readFile(wsDir, data);
      case 'read_file_bytes':
        return _readFileBytes(wsDir, data);
      case 'write_file':
        return _writeFile(wsDir, data);
      case 'upload_file':
        return _uploadFile(wsDir, data);
      case 'upload_init':
        return _uploadInit(wsDir, data);
      case 'upload_chunk':
        return _uploadChunk(data);
      case 'upload_complete':
        return _uploadComplete(data);
      case 'exec_shell':
        return _execShell(wsDir, data);
      case 'exec_argv':
        return _execArgv(wsDir, data);
      case 'grep_search':
        return _grepSearch(wsDir, data);
      case 'git_log':
        return _gitLog(wsDir, data);
      case 'git_branches':
        return _gitBranches(wsDir, data);
      // 第三方 MCP 服务的 stdio 隧道（不涉及工作空间目录）
      case 'mcp_stdio_open':
        return _mcpStdioOpen(data, teamId);
      case 'mcp_stdio_write':
        return _mcpStdioWrite(data);
      case 'mcp_stdio_read':
        return _mcpStdioRead(data);
      case 'mcp_stdio_close':
        return _mcpStdioClose(data);
      // 插件宿主会话（M2 宿主通道，契约 v1.3 §14；与 SSH 侧同构）
      case 'plugin_host_start':
        return _pluginHosts.start(
          hostKey: (data['host_key'] as String?) ?? '',
          teamId: teamId,
          workingDirectory: baseDir,
          unixLike: isUnixLikePath(baseDir),
          payload: data['payload'] is Map<String, dynamic>
              ? data['payload'] as Map<String, dynamic>
              : null,
        );
      case 'plugin_host_stop':
        return _pluginHosts.stop(
          hostSessionId: (data['host_session_id'] as String?) ?? '',
          teamId: teamId,
        );
      case 'plugin_host_status':
        return _pluginHosts.status(
          hostSessionId: (data['host_session_id'] as String?) ?? '',
          teamId: teamId,
        );
      default:
        return <String, dynamic>{'error': '未知本地执行操作: $op'};
    }
  }

  /// 列出工作空间目录（支持子路径），返回 ``{exit_code, files}`` 或 ``{error}``。
  ///
  /// 结果结构与后端 ``ls -la`` 解析一致：每项 ``{name, path, size, type,
  /// modified}``，其中 ``path`` 为相对工作空间根的路径，``type`` 为
  /// ``"dir"`` / ``"file"``，``modified`` 为 ``"YYYY-MM-DD HH:mm"``。
  Future<Map<String, dynamic>> _listFiles(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    try {
      final Directory dir = path.isEmpty
          ? wsDir
          : Directory(_resolveInWorkspace(wsDir, path));
      if (!await dir.exists()) {
        // 工作空间目录尚未创建（尚未开始对话/尚无文件），按空目录处理
        return <String, dynamic>{'exit_code': 0, 'files': <dynamic>[]};
      }
      final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
      await for (final FileSystemEntity entity in dir.list()) {
        final String name = _basename(entity.path);
        final bool isDir = entity is Directory;
        // 隐藏 .git 与 workspaces/agentspace（私人记忆空间容器），避免在共享工作目录中互相暴露
        if (name == '.git' || name == 'workspaces' || name == 'agentspace') {
          continue;
        }
        int size = 0;
        String modified = '';
        try {
          final FileStat stat = await entity.stat();
          size = stat.size;
          final DateTime m = stat.modified.toLocal();
          modified =
              '${m.year.toString().padLeft(4, '0')}-'
              '${m.month.toString().padLeft(2, '0')}-'
              '${m.day.toString().padLeft(2, '0')} '
              '${m.hour.toString().padLeft(2, '0')}:'
              '${m.minute.toString().padLeft(2, '0')}';
        } catch (_) {
          // stat 失败时保留默认值
        }
        files.add(<String, dynamic>{
          'name': name,
          'path': _joinPath(path, name),
          'size': size,
          'type': isDir ? 'dir' : 'file',
          'modified': modified,
        });
      }
      return <String, dynamic>{'exit_code': 0, 'files': files};
    } catch (e) {
      return <String, dynamic>{'error': '列出目录失败: $e'};
    }
  }

  /// 读取文件，返回 ``{exit_code, stdout, stderr, content}`` 或 ``{error}``。
  Future<Map<String, dynamic>> _readFile(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    if (path.isEmpty) {
      return <String, dynamic>{'error': 'read_file 缺少 path'};
    }
    final String encoding = (data['encoding'] as String?) ?? 'utf-8';
    try {
      final String full = _resolveInWorkspace(wsDir, path);
      final File file = File(full);
      if (!await file.exists()) {
        return <String, dynamic>{
          'error': '文件不存在或无法读取: $path',
          'exit_code': 1,
          'stdout': '',
        };
      }
      final String content =
          await _readTextWithFallback(file, encoding);
      return <String, dynamic>{
        'exit_code': 0,
        'stdout': content,
        'stderr': '',
        'content': content,
      };
    } catch (e) {
      return <String, dynamic>{'error': '读取文件失败: $e'};
    }
  }

  /// 按指定编码读取文本；UTF-8 解码失败时回退 latin1 逐字节（GBK 文件兜底）。
  ///
  /// 旧实现 ``readAsString(encoding: utf8)`` 对 GBK/ANSI 文件（Windows 常见
  /// 产物）抛 ``Failed to decode data using encoding 'utf-8'``，read 工具
  /// 整条失败；回退后能返回内容（中文可能显示为扩展拉丁字符，但不中断）。
  Future<String> _readTextWithFallback(
    File file,
    String encoding,
  ) async {
    final Encoding enc = _encoding(encoding);
    if (enc == utf8) {
      // 默认 UTF-8：先按字节严格解码，失败回退 latin1（不抛异常）
      final List<int> bytes = await file.readAsBytes();
      return _decodeProcessBytes(bytes);
    }
    return file.readAsString(encoding: enc);
  }

  /// 读取文件原始字节（base64 编码回传），用于本地模式下的文件下载与 PDF 预览。
  ///
  /// 返回 ``{exit_code, content_base64}`` 或 ``{error}``。
  Future<Map<String, dynamic>> _readFileBytes(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    if (path.isEmpty) {
      return <String, dynamic>{'error': 'read_file_bytes 缺少 path'};
    }
    try {
      final String full = _resolveInWorkspace(wsDir, path);
      final File file = File(full);
      if (!await file.exists()) {
        return <String, dynamic>{
          'error': '文件不存在或无法读取: $path',
          'exit_code': 1,
        };
      }
      // 可选偏移读取：跨工作空间文件中转按块拉取，避免整文件驻留内存。
      // 缺省（offset/length 均为 0）保持原语义——一次读回整个文件。
      final int offset = ((data['offset'] as num?) ?? 0).toInt();
      final int length = ((data['length'] as num?) ?? 0).toInt();
      if (offset > 0 || length > 0) {
        final RandomAccessFile raf = await file.open();
        try {
          final int size = await raf.length();
          final int start = offset.clamp(0, size);
          final int want = length > 0 ? length : size - start;
          await raf.setPosition(start);
          final Uint8List chunk = await raf.read(want.clamp(0, size - start));
          return <String, dynamic>{
            'exit_code': 0,
            'content_base64': base64Encode(chunk),
          };
        } finally {
          await raf.close();
        }
      }
      final List<int> bytes = await file.readAsBytes();
      return <String, dynamic>{
        'exit_code': 0,
        'content_base64': base64Encode(bytes),
      };
    } catch (e) {
      return <String, dynamic>{'error': '读取文件失败: $e'};
    }
  }

  /// 在本机工作空间执行 ``git log``，返回 ``{exit_code, commits}`` 或 ``{error}``。
  ///
  /// 只做读取，不做任何写入/初始化操作，因此不会覆盖本机已有仓库。
  /// 目录尚未成为 git 仓库时按空历史处理；git 命令不可用时返回明确错误。
  Future<Map<String, dynamic>> _gitLog(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    if (!await wsDir.exists()) {
      return <String, dynamic>{'exit_code': 0, 'commits': <dynamic>[]};
    }
    final int limit =
        ((data['limit'] as num?) ?? 50).toInt().clamp(1, 1000);
    try {
      final ProcessResult result = await Process.run(
        'git',
        <String>[
          'log',
          '--all',
          '-n',
          '$limit',
          '--pretty=format:%H%x1f%an%x1f%aI%x1f%s',
        ],
        workingDirectory: wsDir.path,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) {
        final String err = _decode(result.stderr).trim();
        // 目录还不是 git 仓库：按空历史处理（避免每次查看都报错）
        if (err.contains('not a git repository') ||
            err.contains('not a git repo')) {
          return <String, dynamic>{'exit_code': 0, 'commits': <dynamic>[]};
        }
        return <String, dynamic>{
          'error': 'git log 失败: $err',
          'exit_code': result.exitCode,
        };
      }
      final List<Map<String, dynamic>> commits = <Map<String, dynamic>>[];
      for (final String line in _decode(result.stdout).split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final List<String> parts = trimmed.split('\u001f');
        commits.add(<String, dynamic>{
          'hash': parts.isNotEmpty ? parts[0] : '',
          'author': parts.length > 1 ? parts[1] : '',
          'date': parts.length > 2 ? parts[2] : '',
          'message': parts.length > 3 ? parts[3] : '',
        });
      }
      return <String, dynamic>{'exit_code': 0, 'commits': commits};
    } on ProcessException catch (e) {
      return <String, dynamic>{
        'error': 'git 命令不可用: ${e.message}',
        'exit_code': 1,
      };
    } catch (e) {
      return <String, dynamic>{'error': '执行 git log 失败: $e'};
    }
  }

  /// 在本机工作空间执行 ``git branch -a``，返回
  /// ``{exit_code, branches, current}`` 或 ``{error}``。
  Future<Map<String, dynamic>> _gitBranches(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    if (!await wsDir.exists()) {
      return <String, dynamic>{'exit_code': 0, 'branches': <dynamic>[], 'current': ''};
    }
    try {
      final ProcessResult result = await Process.run(
        'git',
        <String>['branch', '-a'],
        workingDirectory: wsDir.path,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) {
        final String err = _decode(result.stderr).trim();
        if (err.contains('not a git repository') ||
            err.contains('not a git repo')) {
          return <String, dynamic>{
            'exit_code': 0,
            'branches': <dynamic>[],
            'current': '',
          };
        }
        return <String, dynamic>{
          'error': 'git branch 失败: $err',
          'exit_code': result.exitCode,
        };
      }
      final List<String> branches = <String>[];
      String current = '';
      for (final String line in _decode(result.stdout).split('\n')) {
        final String stripped = line.trim();
        if (stripped.isEmpty) continue;
        if (stripped.startsWith('* ')) {
          current = stripped.substring(2).trim();
          branches.add(current);
        } else {
          branches.add(stripped);
        }
      }
      return <String, dynamic>{
        'exit_code': 0,
        'branches': branches,
        'current': current,
      };
    } on ProcessException catch (e) {
      return <String, dynamic>{
        'error': 'git 命令不可用: ${e.message}',
        'exit_code': 1,
      };
    } catch (e) {
      return <String, dynamic>{'error': '执行 git branch 失败: $e'};
    }
  }

  /// 写入文件（自动创建父目录），返回 ``{success, file_path}`` 或 ``{error}``。
  Future<Map<String, dynamic>> _writeFile(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    final String content = (data['content'] as String?) ?? '';
    try {
      final String full = _resolveInWorkspace(wsDir, path);
      final File file = File(full);
      await file.parent.create(recursive: true);
      final String lower = path.toLowerCase();
      if (lower.endsWith('.ps1') ||
          lower.endsWith('.bat') ||
          lower.endsWith('.cmd')) {
        // Windows PowerShell 5.1 / cmd.exe 读取无 BOM 的脚本文件时按
        // ANSI（中文系统为 GBK）解码，会破坏 UTF-8 中文（如 git commit 消息
        // 双重乱码）；加 UTF-8 BOM 强制按 UTF-8 解析。
        await file.writeAsBytes(utf8.encode('\uFEFF$content'), flush: true);
      } else {
        await file.writeAsString(content, flush: true);
      }
      return <String, dynamic>{'success': true, 'file_path': path};
    } catch (e) {
      return <String, dynamic>{'error': '写入文件失败: $e', 'file_path': path};
    }
  }

  /// 单请求上传文件（base64 内容直接落盘），返回 ``{success, file_path}``。
  ///
  /// 小文件通道：后端把整个文件 base64 后转发到本端，写入工作空间
  /// ``.input/yyyymmdd/`` 目录（与云端/SSH 模式语义一致）。
  Future<Map<String, dynamic>> _uploadFile(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String relPath = (data['rel_path'] as String?) ?? '';
    final String dataB64 = (data['data_base64'] as String?) ?? '';
    if (relPath.isEmpty) {
      return <String, dynamic>{'error': 'upload_file 缺少 rel_path'};
    }
    try {
      final String full = _resolveInWorkspace(wsDir, relPath);
      final File file = File(full);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(dataB64), flush: true);
      return <String, dynamic>{'success': true, 'file_path': relPath};
    } catch (e) {
      return <String, dynamic>{'error': '上传文件失败: $e', 'file_path': relPath};
    }
  }

  /// 初始化分片上传会话：打开本地文件句柄（截断写），按 upload_id 记录。
  ///
  /// 返回 ``{success, file_path}``；同名会话已存在时先关闭旧句柄（重复 init
  /// 视为重新上传）。
  Future<Map<String, dynamic>> _uploadInit(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String uploadId = (data['upload_id'] as String?) ?? '';
    final String relPath = (data['rel_path'] as String?) ?? '';
    if (uploadId.isEmpty || relPath.isEmpty) {
      return <String, dynamic>{'error': 'upload_init 缺少 upload_id/rel_path'};
    }
    try {
      final String full = _resolveInWorkspace(wsDir, relPath);
      final File file = File(full);
      await file.parent.create(recursive: true);
      final RandomAccessFile raf = await file.open(mode: FileMode.write);
      // 重复 init：关闭旧句柄，避免句柄泄漏
      final _LocalUploadSession? old = _uploadSessions.remove(uploadId);
      if (old != null) {
        try {
          await old.raf.close();
        } catch (_) {
          // 旧句柄关闭失败无碍
        }
      }
      _uploadSessions[uploadId] = _LocalUploadSession(
        raf: raf,
        relPath: relPath,
        fullPath: full,
        // 后端 init 下发的分片定标与期望总大小：chunk 偏移定位与 complete
        // 校验都依赖这两个值，缺省时偏移会错位且跳过大小校验
        chunkSize: ((data['chunk_size'] as num?) ?? 4 * 1024 * 1024).toInt(),
        totalSize: ((data['total_size'] as num?) ?? 0).toInt(),
      );
      return <String, dynamic>{'success': true, 'file_path': relPath};
    } catch (e) {
      return <String, dynamic>{'error': '初始化分片上传失败: $e'};
    }
  }

  /// 追加一个分片：按 index × chunk_size 偏移定位写入。
  ///
  /// 返回 ``{success, received}``；会话不存在（未 init / 已完成）时报错。
  Future<Map<String, dynamic>> _uploadChunk(
    Map<String, dynamic> data,
  ) async {
    final String uploadId = (data['upload_id'] as String?) ?? '';
    final int index = ((data['index'] as num?) ?? -1).toInt();
    final String dataB64 = (data['data_base64'] as String?) ?? '';
    if (uploadId.isEmpty) {
      return <String, dynamic>{'error': 'upload_chunk 缺少 upload_id'};
    }
    final _LocalUploadSession? session = _uploadSessions[uploadId];
    if (session == null) {
      return <String, dynamic>{'error': '分片会话不存在或已完成', 'exit_code': 1};
    }
    if (index < 0) {
      return <String, dynamic>{'error': 'upload_chunk index 非法'};
    }
    try {
      final Uint8List chunk = base64Decode(dataB64);
      await session.raf.setPosition(index * session.chunkSize);
      await session.raf.writeFrom(chunk);
      session.received += chunk.length;
      return <String, dynamic>{'success': true, 'received': chunk.length};
    } catch (e) {
      return <String, dynamic>{'error': '写入分片失败: $e'};
    }
  }

  /// 完成分片上传：flush + 关闭句柄，按 init 的 total_size 校验大小。
  ///
  /// 返回 ``{success, path, size}``；会话不存在时报错。
  Future<Map<String, dynamic>> _uploadComplete(
    Map<String, dynamic> data,
  ) async {
    final String uploadId = (data['upload_id'] as String?) ?? '';
    if (uploadId.isEmpty) {
      return <String, dynamic>{'error': 'upload_complete 缺少 upload_id'};
    }
    final _LocalUploadSession? session = _uploadSessions.remove(uploadId);
    if (session == null) {
      return <String, dynamic>{'error': '分片会话不存在或已完成', 'exit_code': 1};
    }
    try {
      await session.raf.flush();
      await session.raf.close();
    } catch (e) {
      return <String, dynamic>{'error': '关闭上传文件失败: $e'};
    }
    int actual = 0;
    try {
      actual = await File(session.fullPath).length();
    } catch (_) {
      // 长度读取失败不阻塞完成流程
    }
    if (session.totalSize > 0 && actual != session.totalSize) {
      return <String, dynamic>{
        'error': '分片上传大小校验失败：期望 ${session.totalSize} 字节，实际 $actual 字节',
      };
    }
    return <String, dynamic>{
      'success': true,
      'path': session.relPath,
      'size': actual,
    };
  }

  /// 执行 shell 命令（使用本机原生 shell）。
  Future<Map<String, dynamic>> _execShell(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String command = (data['command'] as String?) ?? '';
    if (command.isEmpty) {
      return <String, dynamic>{'error': 'exec_shell 缺少 command'};
    }
    final int timeout = ((data['timeout'] as num?) ?? 30).toInt();
    final String workDir = wsDir.path;
    // Unix/WSL 工作目录：Windows API 无法把该路径作为 workingDirectory，
    // 改用 bash -lc "cd <dir> && <command>"（或 wsl.exe --cd 兜底）。
    if (isUnixLikePath(workDir)) {
      return _runUnixShellInDir(workDir, command, timeout: timeout);
    }
    // 纯 Windows 目录：保持 cmd /c 行为，向后兼容。
    // 先 chcp 65001 切换代码页为 UTF-8：cmd 内置命令（dir/type/findstr 等）
    // 与子进程输出均以 UTF-8 字节写入管道，后端按 UTF-8 严格解码不再触发
    // FormatException（GBK 字节被误当 UTF-8 解析是中文乱码/报错的根因）。
    final bool isWindows = Platform.isWindows;
    return _runProcess(
      wsDir,
      isWindows
          ? <String>['cmd', '/c', '${windowsCmdUtf8Prefix()}$command']
          : <String>['sh', '-c', command],
      timeout: timeout,
    );
  }

  /// 在 Unix 风格工作目录（WSL 挂载路径等）中执行 shell 命令。
  ///
  /// Windows API 无法把 Unix 路径作为 Process.run 的 workingDirectory，
  /// 因此优先执行 `bash -lc "cd <dir> && <command>"`；bash 不可用（进程
  /// 无法启动）时回退 `wsl.exe --cd <dir> bash -lc <command>`；两者均不可
  /// 用则返回明确错误（不静默返回空）。
  Future<Map<String, dynamic>> _runUnixShellInDir(
    String workDir,
    String command, {
    int timeout = 30,
  }) async {
    // 真正的工作目录访问交给 bash 的 cd 完成（当前目录进程可启动即可）。
    final String bashBody = "cd '$workDir' && $command";
    final Map<String, dynamic> bashResult = await _runProcess(
      Directory('.'),
      <String>['bash', '-lc', bashBody],
      timeout: timeout,
    );
    if (!_isShellMissing(bashResult)) return bashResult;

    // bash 不可用 => wsl.exe 兜底（--cd 由 wsl 解析 Unix 路径）。
    final Map<String, dynamic> wslResult = await _runProcess(
      Directory('.'),
      <String>['wsl.exe', '--cd', workDir, 'bash', '-lc', command],
      timeout: timeout,
    );
    if (!_isShellMissing(wslResult)) return wslResult;

    return <String, dynamic>{
      'error': 'bash 不可用，请检查 WSL（wsl.exe 与 bash 均无法调用）',
      'exit_code': -1,
      'stdout': '',
      'stderr': '',
    };
  }

  /// 判断 [result] 是否表示 shell 本身不可用（而非命令本身失败）。
  bool _isShellMissing(Map<String, dynamic> result) {
    final Object? err = result['error'];
    if (err == null) return false;
    final String msg = err.toString().toLowerCase();
    return msg.contains('not found') ||
        msg.contains('cannot run program') ||
        msg.contains('system cannot find') ||
        msg.contains('not recognized') ||
        msg.contains('不是内部或外部命令');
  }

  /// 执行 argv 形式的命令（不经 shell 包装）。
  Future<Map<String, dynamic>> _execArgv(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final List<dynamic> raw = (data['argv'] as List<dynamic>?) ?? <dynamic>[];
    if (raw.isEmpty) {
      return <String, dynamic>{'error': 'exec_argv 缺少 argv'};
    }
    final List<String> argv = raw.map((dynamic e) => e.toString()).toList();
    final int timeout =
        ((data['timeout'] as num?) ?? 0).toInt();
    return _runProcess(wsDir, argv, timeout: timeout);
  }

  /// 执行本地进程并返回 ``{exit_code, stdout, stderr}`` 或 ``{error}``。
  ///
  /// [workingDirectory] 可覆盖工作目录；缺省时若 [wsDir] 为 Unix/WSL
  /// 风格路径（Windows API 无法识别）则不传 workingDirectory（用当前目录），
  /// 由调用方以 `bash -lc "cd .. && ..."` 等内嵌方式进入；否则用 [wsDir]。
  ///
  /// 编码策略：
  /// - 注入 ``PYTHONUTF8=1/PYTHONIOENCODING=utf-8``（Windows 下 Python 默认按
  ///   GBK 代码页输出中文，强开 UTF-8 后与全链路 UTF-8 约定一致）；
  /// - stdout/stderr 以原始字节获取（``stdoutEncoding: null``），经
  ///   [_decodeProcessBytes] 先严格 UTF-8、失败回退 latin1 逐字节解码，
  ///   任何编码的意外字节都不会抛出 FormatException 导致整条命令失败。
  Future<Map<String, dynamic>> _runProcess(
    Directory wsDir,
    List<String> argv, {
    int timeout = 0,
    String? workingDirectory,
  }) async {
    if (argv.isEmpty) {
      return <String, dynamic>{'error': '缺少可执行命令'};
    }
    final String? cwd = workingDirectory ??
        (isUnixLikePath(wsDir.path) ? null : wsDir.path);
    try {
      // 显式 utf8 解码 stdout/stderr：Windows 下 Process.run 默认按系统编码
      // （GBK/cp936）解码，UTF-8 字节（如 Python 中文输出）会被错误转码，
      // 导致工具结果中文乱码（本地模式全链路 UTF-8 约定）。
      final Future<ProcessResult> future = cwd == null
          ? Process.run(
              argv.first,
              argv.sublist(1),
              environment: <String, String>{
                'PYTHONUTF8': '1',
                'PYTHONIOENCODING': 'utf-8',
              },
              stdoutEncoding: null,
              stderrEncoding: null,
            )
          : Process.run(
              argv.first,
              argv.sublist(1),
              workingDirectory: cwd,
              environment: <String, String>{
                'PYTHONUTF8': '1',
                'PYTHONIOENCODING': 'utf-8',
              },
              stdoutEncoding: null,
              stderrEncoding: null,
            );
      final ProcessResult result = timeout > 0
          ? await future.timeout(Duration(seconds: timeout))
          : await future;
      return <String, dynamic>{
        'exit_code': result.exitCode,
        'stdout': decodeProcessBytes(result.stdout),
        'stderr': decodeProcessBytes(result.stderr),
      };
    } on TimeoutException {
      return <String, dynamic>{
        'error': '命令执行超时',
        'exit_code': 124,
        'stdout': '',
        'stderr': '',
      };
    } catch (e) {
      return <String, dynamic>{
        'error': '命令执行失败: $e',
        'exit_code': -1,
        'stdout': '',
        'stderr': '',
      };
    }
  }

  /// 解码进程输出字节：严格 UTF-8 优先，失败回退 latin1 逐字节（不抛异常）。
  ///
  /// Windows 下少量程序仍按 GBK 输出（chcp 65001 后基本消除），latin1 兜底
  /// 保证工具成功返回（个别字符可能显示为扩展拉丁字符，但不中断任务）。
  String _decodeProcessBytes(dynamic value) => decodeProcessBytes(value);

  /// 拉起第三方 MCP 服务子进程（``mcp_stdio_open``），返回 ``{session_id}``。
  ///
  /// 只负责启动与登记会话，不做协议握手：JSON-RPC 的 initialize / tools/list /
  /// tools/call 全部由后端经 ``mcp_stdio_write`` / ``mcp_stdio_read`` 驱动，
  /// 与后端直连 stdio 的语义完全一致。
  ///
  /// 启动前按后端下发的 ``needs_confirmation`` 校验本端信任指纹（见
  /// [McpTrustStore]）：非可信启动器的服务未经用户确认时拒绝启动，返回可读
  /// 错误由「MCP 配置」面板引导确认。
  Future<Map<String, dynamic>> _mcpStdioOpen(
    Map<String, dynamic> data,
    String teamId,
  ) async {
    final String command = ((data['command'] as String?) ?? '').trim();
    if (command.isEmpty) {
      return <String, dynamic>{'error': 'mcp_stdio_open 缺少 command'};
    }
    final List<String> args = ((data['args'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic e) => e.toString())
        .toList();
    final Map<String, String> env = <String, String>{};
    final Object? rawEnv = data['env'];
    if (rawEnv is Map) {
      rawEnv.forEach((dynamic key, dynamic value) {
        env[key.toString()] = value.toString();
      });
    }
    final String? denied = await McpTrustStore.checkLaunch(
      command,
      args,
      needsConfirmation: (data['needs_confirmation'] as bool?) ?? false,
    );
    if (denied != null) {
      return <String, dynamic>{'error': denied};
    }
    try {
      final Process process = await _startMcpProcess(command, args, env);
      _mcpSessionSeq++;
      final McpStdioTunnelSession tunnel = McpStdioTunnelSession(
        id: '${DateTime.now().microsecondsSinceEpoch}-$_mcpSessionSeq',
        teamId: teamId,
        write: (Uint8List data) => process.stdin.add(data),
        kill: () {
          try {
            process.kill();
          } catch (_) {
            // 进程已退出：忽略
          }
        },
      );
      tunnel.bindStreams(process.stdout, process.stderr);
      _mcpSessions[tunnel.id] = tunnel;
      // 子进程退出：标记会话已结束并唤醒挂起中的读取请求，让后端立刻失败，
      // 而不是把剩余等待窗口耗完。
      process.exitCode.then((int code) => tunnel.markExited(code));
      return <String, dynamic>{'session_id': tunnel.id};
    } on ProcessException catch (e) {
      return <String, dynamic>{'error': '启动 MCP 服务失败: ${e.message}'};
    } catch (e) {
      return <String, dynamic>{'error': '启动 MCP 服务失败: $e'};
    }
  }

  /// 启动 MCP 服务子进程。
  ///
  /// Windows 下 `npx` / `uvx` 等常见启动器是 ``.cmd`` / ``.bat`` 脚本，
  /// ``CreateProcess`` 无法直接执行（报"系统找不到指定的文件"）；首次尝试失败
  /// 后经 ``runInShell`` 由 cmd.exe 启动一次。参数由 Dart 按 CreateProcess
  /// 规则转义，实测带空格/引号的参数在 shell 回退路径下不被破坏。
  ///
  /// 环境变量：沿用父进程环境并追加 ``PYTHONUTF8`` / ``PYTHONIOENCODING``
  /// （与 [_runProcess] 一致，避免 Windows 下 Python 类启动器按 GBK 输出），
  /// 服务自定义 env 优先级最高。
  Future<Process> _startMcpProcess(
    String command,
    List<String> args,
    Map<String, String> env,
  ) async {
    final Map<String, String> environment = <String, String>{
      'PYTHONUTF8': '1',
      'PYTHONIOENCODING': 'utf-8',
      ...env,
    };
    try {
      return await Process.start(command, args, environment: environment);
    } on ProcessException {
      if (!Platform.isWindows) rethrow;
      return Process.start(
        command,
        args,
        environment: environment,
        runInShell: true,
      );
    }
  }

  /// 把后端写出的一帧 JSON-RPC 报文写入子进程 stdin（``mcp_stdio_write``）。
  Future<Map<String, dynamic>> _mcpStdioWrite(
    Map<String, dynamic> data,
  ) async {
    final String sessionId = (data['session_id'] as String?) ?? '';
    final McpStdioTunnelSession? session = _mcpSessions[sessionId];
    if (session == null) {
      return <String, dynamic>{'error': 'MCP 隧道会话不存在或已关闭'};
    }
    final String encoded = (data['data'] as String?) ?? '';
    if (encoded.isEmpty) return <String, dynamic>{'ok': true};
    Uint8List payload;
    try {
      payload = base64Decode(encoded);
    } catch (e) {
      return <String, dynamic>{'error': 'MCP 隧道报文不是合法 base64: $e'};
    }
    try {
      session.writeBytes(payload);
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return <String, dynamic>{'error': '写入 MCP 服务 stdin 失败: $e'};
    }
  }

  /// 取走子进程 stdout 上的一条完整帧（``mcp_stdio_read``，base64 回传）。
  ///
  /// 等待窗口（后端下发 ``timeout`` 秒）内没有整行时返回空串，由后端续等——
  /// 数分钟的 tools/call 因此不会被单次等待上限截断；子进程此时已退出则返回
  /// 错误，让后端立刻判定隧道中断。
  Future<Map<String, dynamic>> _mcpStdioRead(Map<String, dynamic> data) async {
    final String sessionId = (data['session_id'] as String?) ?? '';
    final McpStdioTunnelSession? session = _mcpSessions[sessionId];
    if (session == null) {
      return <String, dynamic>{'error': 'MCP 隧道会话不存在或已关闭'};
    }
    final double seconds = ((data['timeout'] as num?) ?? 10).toDouble();
    final List<int>? line = await session.takeLine(
      Duration(milliseconds: (seconds * 1000).round().clamp(1, 60000)),
    );
    if (line == null) {
      if (session.closed) {
        return <String, dynamic>{'error': session.exitedMessage()};
      }
      return <String, dynamic>{'data': ''};
    }
    return <String, dynamic>{'data': base64Encode(line)};
  }

  /// 关闭 MCP 隧道会话并终止子进程（``mcp_stdio_close``，幂等）。
  Future<Map<String, dynamic>> _mcpStdioClose(Map<String, dynamic> data) async {
    final String sessionId = (data['session_id'] as String?) ?? '';
    _mcpSessions.remove(sessionId)?.dispose();
    return <String, dynamic>{'ok': true};
  }

  /// 回收指定 team 的全部 MCP 隧道会话（顶部 agent 被删除时调用）。
  void _disposeMcpSessionsOf(String teamId) {
    final List<String> owned = _mcpSessions.entries
        .where((MapEntry<String, McpStdioTunnelSession> e) =>
            e.value.teamId == teamId)
        .map((MapEntry<String, McpStdioTunnelSession> e) => e.key)
        .toList();
    for (final String id in owned) {
      _mcpSessions.remove(id)?.dispose();
    }
  }

  /// 在工作空间内按模式递归搜索（排除 .git 与二进制文件），
  /// 返回 ``{exit_code, stdout}``，无命中时 exit_code 为 1（与 grep 一致）。
  ///
  /// 支持参数：``pattern``（必填）、``path``（搜索范围，工作空间内相对路径，
  /// 缺省整个工作空间）、``regex``（是否正则，缺省 false 字面量）、
  /// ``ignore_case``（是否忽略大小写，缺省 false）、``max_depth``（递归深度
  /// 上限，1=仅目标目录本层，缺省 0 不限）、``exclude``（逗号分隔的排除
  /// glob，仅按文件/目录名称（basename）匹配、支持 * 与 ?；带路径的模式由
  /// 工具层 GrepTool._parse_exclude 拒绝）。
  ///
  /// 结果在**发送端**按 [_GrepCollector] 截断（单行窗口 + 总量上限）后才回传：
  /// 超限的单帧会被 WS 服务端静默关闭连接（见 [truncateGrepLine]）。
  Future<Map<String, dynamic>> _grepSearch(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String pattern = (data['pattern'] as String?) ?? '';
    if (pattern.isEmpty) {
      return <String, dynamic>{'error': 'grep_search 缺少 pattern'};
    }
    final String path = (data['path'] as String?) ?? '';
    final bool regex = (data['regex'] as bool?) ?? false;
    final bool ignoreCase = (data['ignore_case'] as bool?) ?? false;
    final int maxDepth = _parseMaxDepth(data['max_depth']);
    final List<String> exclude = _parseExclude(data['exclude']);
    final _GrepCollector out = _GrepCollector(
      pattern: pattern,
      regex: regex,
      ignoreCase: ignoreCase,
    );
    try {
      final RegExp? re = regex
          ? RegExp(pattern, caseSensitive: !ignoreCase)
          : null;
      if (path.isEmpty) {
        await _walkSearch(
          wsDir,
          pattern,
          out,
          re: re,
          ignoreCase: ignoreCase,
          maxDepth: maxDepth,
          exclude: exclude,
        );
      } else {
        // path 可能是目录或文件：文件走单文件搜索，目录才递归遍历。
        // 若一律按 Directory 处理（旧实现），传文件路径会在 Windows 上
        // 报 "Directory listing failed"（Dart 对文件路径执行 list 无效）。
        final String full = _resolveInWorkspace(wsDir, path);
        final FileSystemEntityType type =
            FileSystemEntity.typeSync(full, followLinks: false);
        if (type == FileSystemEntityType.file) {
          if (!_isExcluded(_basename(full), exclude)) {
            await _searchFile(
              File(full),
              pattern,
              out,
              re: re,
              ignoreCase: ignoreCase,
            );
          }
        } else {
          await _walkSearch(
            Directory(full),
            pattern,
            out,
            re: re,
            ignoreCase: ignoreCase,
            maxDepth: maxDepth,
            exclude: exclude,
          );
        }
      }
    } on FormatException {
      return <String, dynamic>{'error': '非法正则表达式: $pattern'};
    } catch (e) {
      return <String, dynamic>{'error': '搜索失败: $e'};
    }
    if (out.lines.isEmpty) {
      return <String, dynamic>{'exit_code': 1, 'stdout': ''};
    }
    return <String, dynamic>{
      'exit_code': 0,
      'stdout': out.lines.join('\n'),
      // 发送端已截断：标记随结果回传，避免模型把部分命中当成全量
      'truncated': out.truncated,
      'line_truncated': out.lineTruncated,
    };
  }

  /// 解析 ``max_depth``：非数字/缺省为 0（不限），负值归零、上限 100。
  int _parseMaxDepth(dynamic raw) {
    int depth = 0;
    if (raw is num) {
      depth = raw.toInt();
    } else if (raw is String) {
      depth = int.tryParse(raw.trim()) ?? 0;
    }
    if (depth < 0) return 0;
    return depth > 100 ? 100 : depth;
  }

  /// 解析 ``exclude``：兼容字符串（逗号分隔）与数组两种载荷形式，
  /// 去空白、去空项、去重。
  List<String> _parseExclude(dynamic raw) {
    final List<String> items = <String>[];
    if (raw is String) {
      items.addAll(raw.split(','));
    } else if (raw is List) {
      for (final dynamic item in raw) {
        if (item != null) items.add(item.toString());
      }
    }
    final List<String> patterns = <String>[];
    for (final String item in items) {
      final String pat = item.trim();
      if (pat.isNotEmpty && !patterns.contains(pat)) patterns.add(pat);
    }
    return patterns;
  }

  /// 名称是否命中任一排除 glob（按名称匹配，不区分大小写）。
  bool _isExcluded(String name, List<String> patterns) {
    for (final String pat in patterns) {
      if (_globMatch(pat, name)) return true;
    }
    return false;
  }

  /// glob（``*`` / ``?``）匹配单个名称，不跨路径分隔符。
  bool _globMatch(String pattern, String name) {
    final StringBuffer re = StringBuffer('^');
    for (final int rune in pattern.runes) {
      final String ch = String.fromCharCode(rune);
      if (ch == '*') {
        re.write('.*');
      } else if (ch == '?') {
        re.write('.');
      } else {
        re.write(RegExp.escape(ch));
      }
    }
    re.write(r'$');
    return RegExp(re.toString(), caseSensitive: false).hasMatch(name);
  }

  /// 在单个文件中匹配 [pattern]，命中行以 ``绝对路径:行号:内容`` 追加到 [out]。
  ///
  /// 读取字节后按 [_decodeProcessBytes] 解码（UTF-8 严格优先，latin1 回退），
  /// 与 [_walkSearch] 的编码策略一致：GBK 文件不会因解码失败被整文件跳过。
  /// [out] 达到总量上限（``out.full``）后立即停止本文件的后续匹配。
  Future<void> _searchFile(
    File file,
    String pattern,
    _GrepCollector out, {
    RegExp? re,
    bool ignoreCase = false,
  }) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      final String content = _decodeProcessBytes(bytes);
      final List<String> fileLines = content.split('\n');
      final String lowerPattern = ignoreCase ? pattern.toLowerCase() : pattern;
      for (int i = 0; i < fileLines.length; i++) {
        final String line = fileLines[i];
        final bool hit = re != null
            ? re.hasMatch(line)
            : ignoreCase
                ? line.toLowerCase().contains(lowerPattern)
                : line.contains(pattern);
        if (hit) {
          // 与 grep -n 一致：输出 path:行号:内容（行号从 1 起）
          out.add(file.path, i + 1, line);
          if (out.full) return;
        }
      }
    } catch (_) {
      // 忽略二进制 / 不可读文件
    }
  }

  /// 递归遍历目录，收集包含 [pattern] 的行（[re] 非空时按正则匹配）。
  ///
  /// [maxDepth] > 0 时限制下钻层数（1=仅当前目录本层文件）；[exclude]
  /// 为按名称匹配的排除 glob。另始终跳过 ``.git`` / ``workspaces`` /
  /// ``agentspace``。[out] 达到总量上限（``out.full``）后立即停止遍历。
  Future<void> _walkSearch(
    Directory dir,
    String pattern,
    _GrepCollector out, {
    RegExp? re,
    bool ignoreCase = false,
    int maxDepth = 0,
    List<String> exclude = const <String>[],
    int depth = 1,
  }) async {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (out.full) return;
      if (entity is Directory) {
        final String name = _basename(entity.path);
        if (name == '.git' || name == 'workspaces' || name == 'agentspace') {
          continue;
        }
        if (_isExcluded(name, exclude)) continue;
        if (maxDepth > 0 && depth >= maxDepth) continue; // 达深度上限，不再下钻
        await _walkSearch(
          entity,
          pattern,
          out,
          re: re,
          ignoreCase: ignoreCase,
          maxDepth: maxDepth,
          exclude: exclude,
          depth: depth + 1,
        );
      } else if (entity is File) {
        if (_isExcluded(_basename(entity.path), exclude)) continue;
        await _searchFile(
          entity,
          pattern,
          out,
          re: re,
          ignoreCase: ignoreCase,
        );
      }
    }
  }

  /// 将工作空间内相对路径解析为绝对路径，越出工作空间时抛出异常。
  String _resolveInWorkspace(Directory wsDir, String rel) {
    final String base = _normalizePath(wsDir.absolute.path);
    final String joined = _normalizePath(
      '$base${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    if (joined != base && !joined.startsWith('$base${Platform.pathSeparator}')) {
      throw ArgumentError('路径越出工作空间: $rel');
    }
    return joined;
  }

  /// 规范化路径：折叠 ``.`` / ``..``，统一分隔符。
  String _normalizePath(String path) {
    final List<String> parts = <String>[];
    for (final String part in path.split(RegExp(r'[\\/]'))) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join(Platform.pathSeparator);
  }

  /// 提取路径的末级名称（兼容 / 与 \）。
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  /// 拼接相对工作空间根的路径（[base] 为空时直接返回 [name]）。
  String _joinPath(String base, String name) {
    return base.isEmpty ? name : '$base/$name';
  }

  /// 将编码名映射为 [Encoding] 实例。
  Encoding _encoding(String name) {
    switch (name.toLowerCase()) {
      case 'utf-8':
      case 'utf8':
        return utf8;
      case 'latin-1':
      case 'latin1':
      case 'iso-8859-1':
        return latin1;
      case 'ascii':
        return ascii;
      default:
        return utf8;
    }
  }

  /// 解码进程输出（兼容 bytes / String）。
  String _decode(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is List<int>) return utf8.decode(value, allowMalformed: true);
    return value.toString();
  }
}
