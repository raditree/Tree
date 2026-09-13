import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'mcp_stdio_tunnel.dart';
import 'mcp_trust_store.dart';
import 'plugin_host_sessions.dart';
import 'ssh_connection_manager.dart';

/// 插件宿主会话（SSH 侧，M2 宿主通道）：跨请求持存于
/// [SshWorkspaceExecutor] 的静态会话表；记录远端 pidfile 与会话归属，
/// 供状态探测与回收（远端 kill）时重建执行器使用。
class _SshPluginHostSession {
  _SshPluginHostSession({
    required this.hostSessionId,
    required this.hostKey,
    required this.teamId,
    required this.pidFile,
    required this.manager,
    required this.config,
  });

  final String hostSessionId;
  final String hostKey;
  final String teamId;

  /// 远端 pidfile 绝对路径（``/tmp/tree_ph_<id>.pid``）。
  final String pidFile;

  /// 创建时的连接管理器与配置（回收时构造执行器执行远端 kill）。
  final SshConnectionManager manager;
  final Map<String, dynamic> config;

  /// 最近一次探测到的远端状态（``running`` / ``closed``）。
  String state = 'running';
}

/// SSH 工具执行器 - 在前端发起的 dartssh2 会话上执行后端委托的工具操作。
///
/// SSH 运行模式下，SSH 连接由**前端（Flutter + dartssh2）**发起，IP 相对前端
/// 机器；后端经反向 WebSocket 下发 ``tool_exec_request``，本执行器把工作空间
/// 内相对路径映射到远端绝对路径后在远端执行（SFTP 文件读写 / exec 命令），
/// 结果结构对齐后端与本地执行器。
///
/// 路径映射（对齐后端协同布局）：
/// - top 与团队成员的普通文件 / git / exec / 上传 cwd 统一为 ``remote_base_dir``
///   （成员不再落 ``remote_base_dir/workspaces/{workspace_id}`` 子工作区）；
/// - ``.self`` 令牌路径（=='.self' 或以 '.self/' 开头）按各自 workspace_id
///   分目录解析到 ``remote_base_dir/agentspace/{workspace_id}/.self``；
/// - 含穿越防护：拒绝以 ``/`` / ``\`` 开头的绝对路径与含 ``..`` 段的输入，
///   且归一化后的远端路径必须仍位于 ``remote_base_dir`` 之下。
///
/// 本类持有**请求级**的 team/config（构造时传入，不可变）：调用方按请求
/// payload 的 ``team_id`` 从 per-team 状态取配置构建实例，确保执行 A team
/// 请求时用 A 的配置与路径映射，不读任何全局槽位。
class SshWorkspaceExecutor {
  /// 顶层 agent 的 SSH 连接管理器（负责建连/缓存/重建）
  final SshConnectionManager manager;

  /// 当前请求所属的顶部 agent（team）ID（用于 SSH 连接管理与上传会话隔离）
  final String teamId;

  /// 当前请求的 SSH 配置（取 ``remote_base_dir`` 等字段）
  final Map<String, dynamic> config;

  /// 大文件分片上传会话：key = "$teamId|$uploadId"。
  ///
  /// [SshWorkspaceExecutor] 为请求级实例（每个 tool_exec_request 新建），
  /// 分片会话必须跨请求存活，因此按执行器类静态存储；会话持有打开的
  /// SFTP 通道与文件句柄（SFTP 句柄绑定其打开时的通道，chunk/complete
  /// 必须复用同一条通道），complete 时关闭并移除。
  static final Map<String, _SftpUploadSession> _uploadSessions =
      <String, _SftpUploadSession>{};

  /// 第三方 MCP 服务的 stdio 隧道会话：key = "$teamId|$sessionId"。
  ///
  /// 与分片上传同理，[SshWorkspaceExecutor] 为请求级实例，而一次 MCP 工具
  /// 调用会跨多个 ``mcp_stdio_*`` 请求（open → write/read 若干轮 → close），
  /// 会话必须跨请求存活，故按执行器类静态存储。远端进程由 SSH exec 通道
  /// （[SSHSession]）承载，会话经写管道闭包与 exitCode 回调持有该通道引用；
  /// close / 清理时 kill 远端进程并关闭通道。
  static final Map<String, McpStdioTunnelSession> _mcpSessions =
      <String, McpStdioTunnelSession>{};

  /// MCP 会话 id 自增序号（与时间戳拼接，避免同微秒内碰撞）
  static int _mcpSessionSeq = 0;

  /// 插件宿主会话（M2 宿主通道）：key = "$teamId|$hostSessionId"。
  ///
  /// 与 MCP 隧道同理跨请求存活（执行器为请求级实例）；本批仅生命周期三 op，
  /// 远端固定最小空转型（``sleep 3600``；安全收口不执行任意命令）。
  static final Map<String, _SshPluginHostSession> _pluginHostSessions =
      <String, _SshPluginHostSession>{};

  SshWorkspaceExecutor(
    this.manager, {
    required this.teamId,
    required this.config,
  });

  /// 按操作类型分发执行，返回结果字典（结构对齐后端/本地执行器）。
  ///
  /// 失败时返回 ``{error}``；连接不存在/断开时尝试按配置重建。执行中若
  /// 抛出 [SSHChannelOpenError]（连接上堆积的会话撞到 sshd 单连接通道上限
  /// ``MaxSessions``，表现为所有命令持续 ``open failed``），会丢弃并重建
  /// 连接后重试一次（自愈），避免整条连接被卡死后所有工具永久失败。
  Future<Map<String, dynamic>> execute(
    String workspaceId,
    String op,
    Map<String, dynamic> data,
  ) async {
    if (teamId.isEmpty) {
      return <String, dynamic>{'error': '未选择顶部 agent'};
    }
    Future<Map<String, dynamic>> run() => _guarded(
          (SSHClient client) => _runOnce(client, workspaceId, op, data),
        );
    // upload_chunk / upload_complete 复用 upload_init 建好的分片会话，不再
    // 新开通道：无需占并发槽位（且若排队可能等到超时）。其余操作都在同一
    // 条连接上新开会话型通道，走并发闸（超出排队）。
    //
    // 排队等待期间 ssh_executor_service 的 tool_exec_progress 心跳持续发送
    // （其周期 timer 覆盖整个 execute 期间），后端卡死检测不会误判超时；
    // 若排队超过闸的最大等待时限仍无槽位，闸会自行移除该项并抛超时，
    // 此处转成可读错误返回（不无限排队）。
    if (op == 'upload_chunk' || op == 'upload_complete') {
      return run();
    }
    try {
      return await manager.runWithSlot(teamId, run);
    } on TimeoutException {
      return <String, dynamic>{
        'error': 'SSH 执行排队超时：等待执行槽位超过 '
            '${SshConnectionManager.queueWaitTimeout.inMinutes} 分钟，请稍后重试',
      };
    }
  }

  /// 在已连接的 [client] 上按 op 分发执行一次（不处理连接级错误）。
  ///
  /// 连接建立 / 通道开失败等连接级问题由 [_guarded] 统一负责。
  Future<Map<String, dynamic>> _runOnce(
    SSHClient client,
    String workspaceId,
    String op,
    Map<String, dynamic> data,
  ) async {
    switch (op) {
      case 'list_files':
        return _listFiles(client, workspaceId, data);
      case 'read_file':
        return _readFile(client, workspaceId, data);
      case 'read_file_bytes':
        return _readFileBytes(client, workspaceId, data);
      case 'write_file':
        return _writeFile(client, workspaceId, data);
      case 'upload_file':
        return _uploadFile(client, workspaceId, data);
      case 'upload_init':
        return _uploadInit(client, workspaceId, data);
      case 'upload_chunk':
        return _uploadChunk(data);
      case 'upload_complete':
        return _uploadComplete(data);
      case 'exec_shell':
        return _execShell(client, workspaceId, data);
      case 'exec_shell_hook':
        return _execShellHook(client, workspaceId, data);
      case 'exec_argv':
        return _execArgv(client, workspaceId, data);
      case 'grep_search':
        return _grepSearch(client, workspaceId, data);
      case 'git_log':
        return _gitLog(client, workspaceId, data);
      case 'git_branches':
        return _gitBranches(client, workspaceId, data);
      // 第三方 MCP 服务的 stdio 隧道（不涉及工作空间目录）
      case 'mcp_stdio_open':
        return _mcpStdioOpen(client, data);
      case 'mcp_stdio_write':
        return _mcpStdioWrite(data);
      case 'mcp_stdio_read':
        return _mcpStdioRead(data);
      case 'mcp_stdio_close':
        return _mcpStdioClose(data);
      // 插件宿主会话（M2 宿主通道；与本地执行器同构）
      case 'plugin_host_start':
        return _pluginHostStart(client, workspaceId, data);
      case 'plugin_host_stop':
        return _pluginHostStop(client, data);
      case 'plugin_host_status':
        return _pluginHostStatus(client, data);
      default:
        return <String, dynamic>{'error': '未知 SSH 执行操作: $op'};
    }
  }

  /// 带通道错误自愈的一次执行：先按配置建连/复用连接，再执行 [action]。
  ///
  /// - 建连失败返回 ``SSH 连接失败``；
  /// - 执行抛出 [SSHChannelOpenError] 时视为连接级通道饱和/卡死：关闭并
  ///   丢弃该连接，重建后**再执行一次**；仍失败则返回执行错误（单次重试，
  ///   避免连不上时反复建连造成主机侧连接风暴）。
  Future<Map<String, dynamic>> _guarded(
    Future<Map<String, dynamic>> Function(SSHClient client) action,
  ) async {
    SSHClient client;
    try {
      client = await manager.connect(teamId, config);
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 连接失败: $e'};
    }
    try {
      return await action(client);
    } on SSHChannelOpenError {
      await manager.close(teamId);
      try {
        final SSHClient fresh = await manager.connect(teamId, config);
        try {
          return await action(fresh);
        } catch (e) {
          return <String, dynamic>{'error': 'SSH 执行失败: $e'};
        }
      } catch (e) {
        return <String, dynamic>{'error': 'SSH 重连失败: $e'};
      }
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 执行失败: $e'};
    }
  }

  // ------------------------------------------------------------------
  // 路径映射（复刻原后端 SSHWorkspaceIO）
  // ------------------------------------------------------------------

  /// 返回该顶部 agent 的远端基础目录（默认 ``/``，去掉尾部 ``/``）。
  String _resolveBase() {
    final String base =
        ((config['remote_base_dir'] as String?) ?? '').trim();
    if (base.isEmpty) return '/';
    return base.replaceAll(RegExp(r'/+$'), '');
  }

  /// 判断工作空间内相对路径是否为 ``.self`` 私人空间令牌
  /// （``== '.self'`` 或以 ``'.self/'`` 开头，兼容 ``\`` 分隔符）。
  bool _isSelfToken(String path) {
    final String p = path.replaceAll('\\', '/');
    return p == '.self' || p.startsWith('.self/');
  }

  /// 把工作空间内相对路径映射为远端绝对路径（不做穿越校验，供 exec cwd 等）。
  ///
  /// 协同语义：top 与成员的普通路径（含空路径 cwd）统一映射到 base；
  /// ``.self`` 令牌路径按各自 workspace_id 分目录解析到
  /// ``$base/agentspace/{workspace_id}`` 下（相对令牌保留 ``.self`` 前缀，
  /// 最终物理落点 ``$base/agentspace/{workspace_id}/.self/...``）。
  String _remotePath(String workspaceId, String path) {
    final String base = _resolveBase();
    final String rel = path.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
    final String root =
        _isSelfToken(rel) ? '$base/agentspace/$workspaceId' : base;
    return rel.isEmpty ? root : posixNormPath('$root/$rel');
  }

  /// 映射远端绝对路径并做穿越防护；非法路径返回 null（调用方据此返回错误）。
  ///
  /// top 与成员的普通路径映射到 base；``.self`` 令牌路径按各自 workspace_id
  /// 分目录映射到 base/agentspace/{workspace_id}/.self；穿越校验仍以 base 为界。
  String? _sanitizeRemotePath(String workspaceId, String path) {
    final String p = path.replaceAll('\\', '/');
    if (p.startsWith('/')) return null; // 拒绝绝对路径
    if (p.split('/').contains('..')) return null; // 拒绝含 .. 段
    final String base = _resolveBase();
    final String rel = p.replaceFirst(RegExp(r'^/+'), '');
    final String root =
        _isSelfToken(rel) ? '$base/agentspace/$workspaceId' : base;
    if (rel.isEmpty) return root;
    final String norm = posixNormPath('$root/$rel');
    final String baseNorm = posixNormPath(base);
    if (baseNorm.isEmpty || baseNorm == '/') {
      // base 未配置或为根目录：保持原有行为，视为允许
      return norm;
    }
    final String prefix = baseNorm.endsWith('/') ? baseNorm : '$baseNorm/';
    if (norm == baseNorm || norm.startsWith(prefix)) return norm;
    return null;
  }

  /// POSIX 路径归一化：折叠 ``.`` / ``..``、统一 ``/``，并**保留绝对路径的开头 ``/``**。
  ///
  /// 若丢弃根标记，绝对路径会被还原成相对路径：SFTP 等以服务端 cwd 为基准的
  /// 通道（如 sftp-server 默认落在用户 home）会把 ``home/open/CodeStudio/x``
  /// 解析到错误位置而报 ``No such file``，故此处必须保留。
  ///
  /// 公开为静态方法（不依赖实例），便于单元测试覆盖路径归一化语义。
  static String posixNormPath(String path) {
    final bool rooted = path.startsWith('/');
    final List<String> parts = <String>[];
    for (final String part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    if (parts.isEmpty) return rooted ? '/' : '';
    return rooted ? '/${parts.join('/')}' : parts.join('/');
  }

  // ------------------------------------------------------------------
  // SFTP 工具
  // ------------------------------------------------------------------

  /// 打开文件读取字节，返回 ``{bytes, error}``。
  Future<Uint8List?> _sftpReadBytes(
    SftpClient sftp,
    String remote,
  ) async {
    final SftpFile file = await sftp.open(remote, mode: SftpFileOpenMode.read);
    try {
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  /// 递归创建远端目录（已存在则跳过，等价 mkdir -p）。
  Future<void> _sftpMkdirP(SftpClient sftp, String remoteDir) async {
    final List<String> parts = remoteDir.split('/');
    String cur = '';
    for (final String part in parts) {
      if (part.isEmpty) continue;
      cur = cur.isEmpty ? '/$part' : '$cur/$part';
      try {
        await sftp.stat(cur);
      } catch (_) {
        try {
          await sftp.mkdir(cur);
        } catch (_) {
          // 目录可能已由并发创建，忽略
        }
      }
    }
  }

  // ------------------------------------------------------------------
  // 命令执行
  // ------------------------------------------------------------------

  /// 在远端执行 [command]，返回 ``{exit_code, stdout, stderr}`` 或 ``{error}``。
  ///
  /// [timeout] 为 Dart 侧等待上限（秒）；null / <=0 表示不设超时（hook 等
  /// 长任务专用）。超时时尽力终止远端进程（先发 ``signal`` 请求，服务端可能
  /// 拒绝；随后关闭通道，由 sshd 对远端会话挂断兜底）并返回超时错误——否则
  /// 远端进程 + 通道双泄漏（后端 120s 响应上限后即放弃等待）。任何路径
  /// （正常/超时/异常）都在 finally 中关闭 session，防止通道泄漏。
  Future<Map<String, dynamic>> _exec(
    SSHClient client,
    String command, {
    int? timeout,
  }) async {
    SSHSession? session;
    try {
      session = await client.execute(command);
      final BytesBuilder out = BytesBuilder(copy: false);
      final BytesBuilder err = BytesBuilder(copy: false);
      bool outEnded = false;
      bool errEnded = false;
      final Completer<void> allDone = Completer<void>();
      void checkDone() {
        if (outEnded && errEnded && !allDone.isCompleted) {
          allDone.complete();
        }
      }
      // stdout/stderr 的 onError 同样按"流结束"处理：连接/通道异常时任一
      // 一路流可能只有 error 没有 done，若只等 done 会让 hook/exec 无限
      // 等待并把会话一直占住（通道泄漏、最终撞上 sshd 通道上限的来源之一）。
      session.stdout.listen(
        out.add,
        onDone: () {
          outEnded = true;
          checkDone();
        },
        onError: (Object _) {
          outEnded = true;
          checkDone();
        },
      );
      session.stderr.listen(
        err.add,
        onDone: () {
          errEnded = true;
          checkDone();
        },
        onError: (Object _) {
          errEnded = true;
          checkDone();
        },
      );
      if (timeout == null || timeout <= 0) {
        await allDone.future;
      } else {
        try {
          await allDone.future.timeout(Duration(seconds: timeout));
        } on TimeoutException {
          // 超时：尽力终止远端进程（signal 请求可能被服务端拒绝，关闭通道
          // 后 sshd 会向远端会话进程组挂断兜底），返回超时错误（对齐本地
          // 执行器语义：exit_code 124）
          try {
            session.kill(SSHSignal.TERM);
          } catch (_) {
            // 服务端拒绝 signal 请求时忽略，靠关闭通道兜底
          }
          return <String, dynamic>{
            'error': '命令执行超时',
            'exit_code': 124,
            'stdout': '',
            'stderr': '',
          };
        }
      }
      return <String, dynamic>{
        'exit_code': session.exitCode ?? 0,
        'stdout': utf8.decode(out.takeBytes(), allowMalformed: true),
        'stderr': utf8.decode(err.takeBytes(), allowMalformed: true),
      };
    } on SSHChannelOpenError {
      // 连接级通道上限/卡死：不在本层吞掉，交由 _guarded 丢弃连接并重试
      rethrow;
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 执行失败: $e'};
    } finally {
      try {
        session?.close();
      } catch (_) {
        // 关闭失败无碍（通道随连接生命周期回收）
      }
    }
  }

  /// POSIX shell 单引号转义（等价后端 shlex.quote 的最小实现）。
  String _shQuote(String s) {
    if (s.isEmpty) return "''";
    if (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(s)) return s;
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  /// SFTP 错误上下文后缀：把「尝试的远端绝对路径 / base 映射 / 连接对象」
  /// 固化进错误信息，便于审查与复现（此前仅返回服务端一句话，难以判断是
  /// 路径错、映射错还是通道错）。
  String _sftpCtx(String remote) {
    return ' (remote=$remote, base=${_resolveBase()}, '
        'host=${config['host'] ?? ''}, user=${config['username'] ?? ''})';
  }

  /// 格式化 SFTP 服务端状态错误：``描述(code=数值)``，数值比文本更便于核对。
  String _sftpErrText(SftpStatusError e) => '${e.message} (code=${e.code})';

  /// 用 exec（与 SFTP 同一连接）探测远端路径是否存在：SFTP 报 No such file 时
  /// 交叉核验，区分「远端确实不存在」与「SFTP 与 exec 文件系统视图不一致」。
  ///
  /// 返回三态：true=exec 可见；false=exec 亦不可见；null=探测本身失败
  /// （如通道异常，``_exec`` 对 ``SSHChannelOpenError`` 是 rethrow 的），
  /// 由调用方如实上报，避免把「通道异常」误报成「远端不存在」。
  Future<bool?> _remoteExistsViaExec(SSHClient client, String remote) async {
    try {
      final Map<String, dynamic> r = await _exec(
        client,
        'test -e -- ${_shQuote(remote)} && printf exists',
      );
      return r['exit_code'] == 0 &&
          (r['stdout'] as String? ?? '').contains('exists');
    } catch (_) {
      return null;
    }
  }

  /// read 系列遇 SFTP No such file 时，按 exec 交叉核验结果生成可读提示。
  String _noSuchFileHint(String userPath, String remote, bool? viaExec) {
    final String tail = _sftpCtx(remote);
    if (viaExec == true) {
      return '文件读取失败: SFTP 报不存在但 exec 侧可见同一绝对路径，'
          '疑似 SFTP 视图/路径映射不一致: $userPath$tail';
    }
    if (viaExec == false) {
      return '文件不存在或无法读取（exec 侧亦不存在）: $userPath$tail';
    }
    return '文件不存在或无法读取（exec 侧交叉核验失败，请检查 SSH 通道）: '
        '$userPath$tail';
  }

  // ------------------------------------------------------------------
  // 操作实现
  // ------------------------------------------------------------------

  /// 列出远端工作空间目录（支持子路径），返回 ``{exit_code, files}``。
  ///
  /// 目录不存在时按空目录处理（与本地执行器一致）；结果每项
  /// ``{name, path, size, type, modified}``，``modified`` 为
  /// ``"YYYY-MM-DD HH:mm"``。
  Future<Map<String, dynamic>> _listFiles(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    final String? target = _sanitizeRemotePath(workspaceId, path);
    if (target == null) {
      return <String, dynamic>{'exit_code': 1, 'files': <dynamic>[], 'error': '非法文件路径'};
    }
    final SftpClient sftp = await client.sftp();
    try {
      final List<SftpName> names = await sftp.listdir(target);
      final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
      for (final SftpName n in names) {
        if (n.filename == '.' || n.filename == '..') continue;
        final bool isDir = n.attr.isDirectory;
        files.add(<String, dynamic>{
          'name': n.filename,
          'path': _joinPath(path, n.filename),
          'size': n.attr.size ?? 0,
          'type': isDir ? 'dir' : 'file',
          'modified': _formatModified(n.attr.modifyTime),
        });
      }
      return <String, dynamic>{'exit_code': 0, 'files': files};
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) {
        // 工作空间目录尚未创建，按空目录处理
        return <String, dynamic>{'exit_code': 0, 'files': <dynamic>[]};
      }
      return <String, dynamic>{
        'exit_code': 1,
        'files': <dynamic>[],
        'error': '列出目录失败: ${_sftpErrText(e)}${_sftpCtx(target)}',
      };
    } catch (e) {
      return <String, dynamic>{
        'exit_code': 1,
        'files': <dynamic>[],
        'error': '列出目录失败: $e${_sftpCtx(target)}',
      };
    } finally {
      sftp.close();
    }
  }

  /// 读取远端文件文本，返回 ``{exit_code, stdout, stderr, content}`` 或 ``{error}``。
  Future<Map<String, dynamic>> _readFile(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    if (path.isEmpty) {
      return <String, dynamic>{'error': 'read_file 缺少 path'};
    }
    final String encoding = (data['encoding'] as String?) ?? 'utf-8';
    final String? remote = _sanitizeRemotePath(workspaceId, path);
    if (remote == null) {
      return <String, dynamic>{'error': '非法文件路径', 'exit_code': 1};
    }
    final SftpClient sftp = await client.sftp();
    try {
      final Uint8List? bytes = await _sftpReadBytes(sftp, remote);
      if (bytes == null) {
        return <String, dynamic>{
          'error': '远端不存在该文件或目录: $path${_sftpCtx(remote)}',
          'exit_code': 1,
          'stdout': '',
        };
      }
      final String content = _decodeText(bytes, encoding);
      return <String, dynamic>{
        'exit_code': 0,
        'stdout': content,
        'stderr': '',
        'content': content,
      };
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) {
        final bool? viaExec = await _remoteExistsViaExec(client, remote);
        return <String, dynamic>{
          'error': _noSuchFileHint(path, remote, viaExec),
          'exit_code': 1,
          'stdout': '',
        };
      }
      return <String, dynamic>{
        'error': 'SSH 读取失败: ${_sftpErrText(e)}${_sftpCtx(remote)}',
        'exit_code': 1,
      };
    } catch (e) {
      return <String, dynamic>{
        'error': 'SSH 读取失败: $e${_sftpCtx(remote)}',
        'exit_code': 1,
      };
    } finally {
      sftp.close();
    }
  }

  /// 读取远端文件原始字节（base64 编码回传），返回 ``{exit_code, content_base64}``。
  Future<Map<String, dynamic>> _readFileBytes(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    if (path.isEmpty) {
      return <String, dynamic>{'error': 'read_file_bytes 缺少 path'};
    }
    final String? remote = _sanitizeRemotePath(workspaceId, path);
    if (remote == null) {
      return <String, dynamic>{'error': '非法文件路径', 'exit_code': 1};
    }
    final SftpClient sftp = await client.sftp();
    try {
      final Uint8List? bytes = await _sftpReadBytes(sftp, remote);
      if (bytes == null) {
        return <String, dynamic>{
          'error': '远端不存在该文件或目录: $path${_sftpCtx(remote)}',
          'exit_code': 1,
        };
      }
      return <String, dynamic>{
        'exit_code': 0,
        'content_base64': base64Encode(bytes),
      };
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) {
        final bool? viaExec = await _remoteExistsViaExec(client, remote);
        return <String, dynamic>{
          'error': _noSuchFileHint(path, remote, viaExec),
          'exit_code': 1,
        };
      }
      return <String, dynamic>{
        'error': 'SSH 读取失败: ${_sftpErrText(e)}${_sftpCtx(remote)}',
        'exit_code': 1,
      };
    } catch (e) {
      return <String, dynamic>{
        'error': 'SSH 读取失败: $e${_sftpCtx(remote)}',
        'exit_code': 1,
      };
    } finally {
      sftp.close();
    }
  }

  /// 写入远端文件（自动创建父目录），返回 ``{success, file_path}`` 或 ``{error}``。
  Future<Map<String, dynamic>> _writeFile(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String path = (data['path'] as String?) ?? '';
    final String content = (data['content'] as String?) ?? '';
    final String? remote = _sanitizeRemotePath(workspaceId, path);
    if (remote == null) {
      return <String, dynamic>{'error': '非法文件路径', 'file_path': path};
    }
    final SftpClient sftp = await client.sftp();
    try {
      await _sftpMkdirP(sftp, _posixDirname(remote));
      final SftpFile file = await sftp.open(
        remote,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(Uint8List.fromList(utf8.encode(content)));
      } finally {
        await file.close();
      }
      return <String, dynamic>{'success': true, 'file_path': path};
    } catch (e) {
      final String detail = e is SftpStatusError ? _sftpErrText(e) : '$e';
      return <String, dynamic>{
        'error': 'SSH 写入失败: $detail${_sftpCtx(remote)}',
        'file_path': path,
      };
    } finally {
      sftp.close();
    }
  }

  /// 单请求上传文件（base64 内容经 SFTP 落盘），返回 ``{success, file_path}``。
  ///
  /// 小文件通道：后端把整个文件 base64 后转发到本端，写入远端工作空间
  /// ``.input/yyyymmdd/`` 目录（与云端/本地模式语义一致）。
  Future<Map<String, dynamic>> _uploadFile(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String relPath = (data['rel_path'] as String?) ?? '';
    final String dataB64 = (data['data_base64'] as String?) ?? '';
    if (relPath.isEmpty) {
      return <String, dynamic>{'error': 'upload_file 缺少 rel_path'};
    }
    final String? remote = _sanitizeRemotePath(workspaceId, relPath);
    if (remote == null) {
      return <String, dynamic>{'error': '非法文件路径', 'file_path': relPath};
    }
    final SftpClient sftp = await client.sftp();
    try {
      await _sftpMkdirP(sftp, _posixDirname(remote));
      final SftpFile file = await sftp.open(
        remote,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(base64Decode(dataB64));
      } finally {
        await file.close();
      }
      return <String, dynamic>{'success': true, 'file_path': relPath};
    } catch (e) {
      final String detail = e is SftpStatusError ? _sftpErrText(e) : '$e';
      return <String, dynamic>{
        'error': 'SSH 上传失败: $detail${_sftpCtx(remote)}',
        'file_path': relPath,
      };
    } finally {
      sftp.close();
    }
  }

  /// 初始化分片上传会话：SFTP 打开远端文件（截断写），按 upload_id 记录。
  ///
  /// 会话持有 SFTP 通道与文件句柄（SFTP 句柄绑定打开时的通道，后续
  /// chunk/complete 必须复用同一条通道）；同名会话已存在时先关闭旧会话。
  Future<Map<String, dynamic>> _uploadInit(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String uploadId = (data['upload_id'] as String?) ?? '';
    final String relPath = (data['rel_path'] as String?) ?? '';
    if (uploadId.isEmpty || relPath.isEmpty) {
      return <String, dynamic>{'error': 'upload_init 缺少 upload_id/rel_path'};
    }
    final String? remote = _sanitizeRemotePath(workspaceId, relPath);
    if (remote == null) {
      return <String, dynamic>{'error': '非法文件路径', 'file_path': relPath};
    }
    // 重复 init：先关闭旧会话，避免通道/句柄泄漏
    final _SftpUploadSession? old = _uploadSessions.remove('$teamId|$uploadId');
    if (old != null) {
      await _closeSession(old);
    }
    final SftpClient sftp = await client.sftp();
    SftpFile? file;
    try {
      await _sftpMkdirP(sftp, _posixDirname(remote));
      file = await sftp.open(
        remote,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      _uploadSessions['$teamId|$uploadId'] = _SftpUploadSession(
        sftp: sftp,
        file: file,
        relPath: relPath,
        chunkSize: ((data['chunk_size'] as num?) ?? 4 * 1024 * 1024).toInt(),
        totalSize: ((data['total_size'] as num?) ?? 0).toInt(),
      );
      return <String, dynamic>{'success': true, 'file_path': relPath};
    } catch (e) {
      try {
        await file?.close();
      } catch (_) {
        // 关闭失败无碍
      }
      sftp.close();
      final String detail = e is SftpStatusError ? _sftpErrText(e) : '$e';
      return <String, dynamic>{
        'error': '初始化分片上传失败: $detail${_sftpCtx(remote)}',
      };
    }
  }

  /// 追加一个分片：在会话持有的通道/句柄上按 index × chunk_size 偏移写入。
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
    final _SftpUploadSession? session = _uploadSessions['$teamId|$uploadId'];
    if (session == null) {
      return <String, dynamic>{'error': '分片会话不存在或已完成', 'exit_code': 1};
    }
    if (index < 0) {
      return <String, dynamic>{'error': 'upload_chunk index 非法'};
    }
    try {
      final Uint8List chunk = base64Decode(dataB64);
      await session.file.writeBytes(
        chunk,
        offset: index * session.chunkSize,
      );
      session.received += chunk.length;
      return <String, dynamic>{'success': true, 'received': chunk.length};
    } catch (e) {
      return <String, dynamic>{'error': '写入分片失败: $e'};
    }
  }

  /// 完成分片上传：关闭句柄与通道，按 init 的 total_size 校验大小。
  ///
  /// 返回 ``{success, path, size}``；会话不存在时报错。
  Future<Map<String, dynamic>> _uploadComplete(
    Map<String, dynamic> data,
  ) async {
    final String uploadId = (data['upload_id'] as String?) ?? '';
    if (uploadId.isEmpty) {
      return <String, dynamic>{'error': 'upload_complete 缺少 upload_id'};
    }
    final _SftpUploadSession? session =
        _uploadSessions.remove('$teamId|$uploadId');
    if (session == null) {
      return <String, dynamic>{'error': '分片会话不存在或已完成', 'exit_code': 1};
    }
    await _closeSession(session);
    if (session.totalSize > 0 && session.received != session.totalSize) {
      return <String, dynamic>{
        'error':
            '分片上传大小校验失败：期望 ${session.totalSize} 字节，实际 ${session.received} 字节',
      };
    }
    return <String, dynamic>{
      'success': true,
      'path': session.relPath,
      'size': session.received,
    };
  }

  /// 关闭上传会话的文件句柄与 SFTP 通道（尽力而为，失败不抛出）。
  Future<void> _closeSession(_SftpUploadSession session) async {
    try {
      await session.file.close();
    } catch (_) {
      // 关闭失败无碍
    }
    session.sftp.close();
  }

  /// 在远端工作空间执行 shell 命令，返回 ``{exit_code, stdout, stderr}``。
  Future<Map<String, dynamic>> _execShell(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String command = (data['command'] as String?) ?? '';
    if (command.isEmpty) {
      return <String, dynamic>{'error': 'exec_shell 缺少 command'};
    }
    final int timeout = ((data['timeout'] as num?) ?? 30).toInt().clamp(1, 3600);
    final String cwd = _remotePath(workspaceId, '');
    final String full =
        'cd ${_shQuote(cwd)} && timeout $timeout sh -c ${_shQuote(command)}';
    return _exec(client, full, timeout: timeout + 5);
  }

  /// 在远端工作空间执行 argv 形式的命令（不经 shell 包装）。
  ///
  /// 超时语义对齐本地执行器：payload 未指定（0/null）时取默认兜底 120s
  /// （与后端 ``tool_exec_request`` 响应上限一致）——远端进程不能无限存活，
  /// 否则后端超时放弃后远端进程 + 通道双泄漏。超时经远端 ``timeout N``
  /// 杀进程（退出码 124），Dart 侧再等 5s 兜底后关 session 返回超时错误。
  Future<Map<String, dynamic>> _execArgv(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final List<dynamic> raw = (data['argv'] as List<dynamic>?) ?? <dynamic>[];
    if (raw.isEmpty) {
      return <String, dynamic>{'error': 'exec_argv 缺少 argv'};
    }
    final int requested = ((data['timeout'] as num?) ?? 0).toInt();
    final int timeout =
        requested > 0 ? requested.clamp(1, 3600).toInt() : 120;
    final String cwd = _remotePath(workspaceId, '');
    final String full = 'cd ${_shQuote(cwd)} && timeout $timeout '
        '${raw.map((dynamic e) => _shQuote(e.toString())).join(' ')}';
    return _exec(client, full, timeout: timeout + 5);
  }

  /// 在远端以 hook 模式执行长命令（无 Dart 侧超时上限，命令结束后回传退出码）。
  ///
  /// 后端 hook_manager 对 SSH 生成的 wrapped 命令已含（cd 由本端拼接，因
  /// 远端 workspace 绝对路径仅前端可知）：
  /// - ``<command> > <output_file> 2>&1``：输出重定向落盘（前端不流式写
  ///   输出文件，与本地执行器的管道写文件方式不同）；
  /// - ``& echo $! > <output_file>.pid``：记录后台进程 pid（workspace 相对
  ///   路径 pidfile），供取消时 ``kill -TERM``（见 [cancelHook]）；
  /// - ``wait``：等待后台命令退出，shell 退出码即命令退出码。
  ///
  /// 本端用 ``;``（cd 失败 ``exit 1``）而非 ``&&`` 衔接 cd 与 wrapped：``&&``
  /// 会把 cd 与后台命令并成一个异步列表，``$!`` 记录到列表子 shell 而非命令
  /// 本身，导致取消时 kill 不到目标进程。完成后回传真实退出码，hook 完成
  /// 回执语义与本地执行器一致。
  Future<Map<String, dynamic>> _execShellHook(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String command = (data['command'] as String?) ?? '';
    if (command.isEmpty) {
      return <String, dynamic>{'error': 'exec_shell_hook 缺少 command', 'exit_code': -1};
    }
    final String cwd = _remotePath(workspaceId, '');
    final String full = 'cd ${_shQuote(cwd)} || exit 1; $command';
    return _exec(client, full);
  }

  /// 取消远端 hook 后台任务（``tool_exec_cancel`` 的执行体）。
  ///
  /// hook 启动时 wrapped 命令把后台进程 pid 写入 ``<output_file>.pid``；
  /// 本方法经 SSH 会话执行 ``kill -TERM $(cat <pidfile>)``（尽力终止，不
  /// 保证杀掉全部孙进程）。不立即回执：远端 wrapped 命令的 wait 在进程退出
  /// 后返回，hook 请求随即回传退出码，后端据此把任务落定为 cancelled（与
  /// 本地执行器 kill 后经进程退出回执的语义一致）。
  Future<Map<String, dynamic>> cancelHook(
    String workspaceId,
    String pidfile,
  ) async {
    if (pidfile.isEmpty) {
      return <String, dynamic>{'error': '取消 hook 失败: 缺少 pidfile'};
    }
    final String cwd = _remotePath(workspaceId, '');
    final String full = 'cd ${_shQuote(cwd)} || exit 1; '
        'kill -TERM \$(cat ${_shQuote(pidfile)}) 2>/dev/null || true';
    // 同样经 _guarded：取消时若连接已被卡死（通道开不出），先重建连接再执行
    return _guarded(
      (SSHClient client) => _exec(client, full, timeout: 10),
    );
  }

  // -- 插件宿主会话（M2 宿主通道，契约 v1.3 §14；本批生命周期三 op） --------

  /// 按 host_key 查本 team 的宿主会话（幂等复用索引；线性扫描够用）。
  _SshPluginHostSession? _findHostByKey(String hostKey) {
    for (final _SshPluginHostSession session in _pluginHostSessions.values) {
      if (session.teamId == teamId && session.hostKey == hostKey) {
        return session;
      }
    }
    return null;
  }

  /// 启动远端宿主会话（``plugin_host_start``，本批固定最小空转型）。
  ///
  /// 远端后台常驻（``nohup sleep 3600``），pid 写入 ``/tmp`` pidfile；会话
  /// 记录持存于类静态表（跨请求）。幂等：同 host_key 且远端存活 → 复用；
  /// 已失活 → 回收旧记录后重建。
  Future<Map<String, dynamic>> _pluginHostStart(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String hostKey = (data['host_key'] as String?) ?? '';
    if (hostKey.isEmpty) {
      return <String, dynamic>{'error': 'plugin_host_start 缺少 host_key'};
    }
    final _SshPluginHostSession? existing = _findHostByKey(hostKey);
    if (existing != null) {
      String probe = 'running';
      try {
        probe = await _pluginHostProbe(client, existing.pidFile);
      } catch (_) {
        // 探测不可达：按复用处理（避免重复起进程；后端重试幂等兜底）
      }
      if (probe == 'running') {
        return <String, dynamic>{'host_session_id': existing.hostSessionId};
      }
      _pluginHostSessions
          .remove('${existing.teamId}|${existing.hostSessionId}');
    }
    final String id = newPluginHostSessionId();
    final String pidFile = '/tmp/tree_ph_$id.pid';
    final String cwd = _remotePath(workspaceId, '');
    final String full = buildRemoteHostStartCommand(cwd: cwd, pidFile: pidFile);
    final Map<String, dynamic> result = await _exec(client, full, timeout: 10);
    final Object? exitCode = result['exit_code'];
    if (result['error'] != null || (exitCode is int && exitCode != 0)) {
      return <String, dynamic>{
        'error': 'plugin_host_start 远端启动失败: '
            '${result['error'] ?? 'exit_code=$exitCode'}',
      };
    }
    _pluginHostSessions['$teamId|$id'] = _SshPluginHostSession(
      hostSessionId: id,
      hostKey: hostKey,
      teamId: teamId,
      pidFile: pidFile,
      manager: manager,
      config: config,
    );
    return <String, dynamic>{'host_session_id': id};
  }

  /// 停止远端宿主会话（``plugin_host_stop``，幂等；尽力而为，失败仅记日志）。
  Future<Map<String, dynamic>> _pluginHostStop(
    SSHClient client,
    Map<String, dynamic> data,
  ) async {
    final String hostSessionId = (data['host_session_id'] as String?) ?? '';
    if (hostSessionId.isEmpty) {
      return <String, dynamic>{'error': 'plugin_host_stop 缺少 host_session_id'};
    }
    final _SshPluginHostSession? session =
        _pluginHostSessions.remove('$teamId|$hostSessionId');
    if (session == null) {
      // 幂等：已回收 / 从未存在的会话视为已停止
      return <String, dynamic>{'ok': true};
    }
    try {
      await _exec(
        client,
        buildRemoteHostStopCommand(pidFile: session.pidFile),
        timeout: 10,
      );
    } catch (_) {
      // 尽力而为：远端 kill 失败仅忽略（契约 §14.2 stop 语义）
    }
    return <String, dynamic>{'ok': true};
  }

  /// 查询远端宿主会话状态（``plugin_host_status``）。
  ///
  /// 本批远端不采集 exit_code / stderr_tail（无持续 watcher；拿不到留缺省）。
  Future<Map<String, dynamic>> _pluginHostStatus(
    SSHClient client,
    Map<String, dynamic> data,
  ) async {
    final String hostSessionId = (data['host_session_id'] as String?) ?? '';
    if (hostSessionId.isEmpty) {
      return <String, dynamic>{
        'error': 'plugin_host_status 缺少 host_session_id',
      };
    }
    final _SshPluginHostSession? session =
        _pluginHostSessions['$teamId|$hostSessionId'];
    if (session == null) {
      return <String, dynamic>{'error': '宿主会话不存在（可能已回收）'};
    }
    try {
      session.state = await _pluginHostProbe(client, session.pidFile);
    } catch (_) {
      // 探测不可达：保留原状态（后端重连对账兜底）
    }
    return <String, dynamic>{'state': session.state};
  }

  /// 远端状态探测：返回 ``running`` / ``closed``；命令级失败抛错由调用方转译。
  Future<String> _pluginHostProbe(SSHClient client, String pidFile) async {
    final Map<String, dynamic> result = await _exec(
      client,
      buildRemoteHostStatusCommand(pidFile: pidFile),
      timeout: 10,
    );
    if (result['error'] != null) {
      throw StateError('${result['error']}');
    }
    return parseRemoteHostStatusOutput((result['stdout'] as String?) ?? '');
  }

  /// 远端 kill 宿主会话（供静态回收复用；尽力而为）。
  Future<void> killHost(String pidFile) async {
    if (pidFile.isEmpty) return;
    await _guarded(
      (SSHClient client) => _exec(
        client,
        buildRemoteHostStopCommand(pidFile: pidFile),
        timeout: 10,
      ),
    );
  }

  /// 在远端工作空间按模式递归搜索，返回 ``{exit_code, stdout}``。
  ///
  /// 支持参数：``pattern``（必填）、``path``（搜索范围，workspace 内相对
  /// 路径，缺省整个工作空间）、``regex``（是否正则，缺省 false 字面量）、
  /// ``ignore_case``（缺省 false）、``max_depth``（递归深度上限，1=仅目标
  /// 目录本层，缺省 0 不限）、``exclude``（逗号分隔的排除 glob，仅按文件/
  /// 目录名称（basename）匹配、支持 * 与 ?；带路径的模式由工具层拒绝）。
  ///
  /// 路径穿越防护：path 经 [_sanitizeRemotePath] 校验（对齐本地执行器
  /// ``_resolveInWorkspace`` 语义——拒绝绝对路径与 ``..`` 段，解析后必须仍在
  /// workspace 根内），非法时返回错误结果而非在远端任意目录执行 grep。
  Future<Map<String, dynamic>> _grepSearch(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String pattern = (data['pattern'] as String?) ?? '';
    if (pattern.isEmpty) {
      return <String, dynamic>{'error': 'grep_search 缺少 pattern'};
    }
    final bool regex = (data['regex'] as bool?) ?? false;
    final bool ignoreCase = (data['ignore_case'] as bool?) ?? false;
    final String path = (data['path'] as String?) ?? '';
    final int maxDepth = _parseMaxDepth(data['max_depth']);
    final List<String> exclude = _parseExclude(data['exclude']);
    String? targetRemote;
    if (path.isNotEmpty) {
      targetRemote = _sanitizeRemotePath(workspaceId, path);
      if (targetRemote == null) {
        return <String, dynamic>{'error': '非法文件路径', 'exit_code': 1};
      }
    }
    final String cwd = _remotePath(workspaceId, '');
    // -F 固定字符串 / -E 扩展正则；-- 后为位置参数，pattern 以 - 开头也不会被当选项
    final String mode = regex ? '-E' : '-F';
    final String ic = ignoreCase ? 'i' : '';
    final String target = targetRemote == null ? '.' : _shQuote(targetRemote);
    // 排除项统一按「名称(basename)」匹配：递归分支用 grep --exclude/--exclude-dir
    // （-r 下均按基名匹配）；深度分支改由 find 过滤——GNU grep 对命令行文件采用
    // 「路径后缀」匹配（--exclude=lib/*.dart 会命中 ./lib/a.dart），沿用会让同一
    // exclude 在不同分支行为不一致。
    final StringBuffer excl = StringBuffer('--exclude-dir=.git');
    for (final String pat in exclude) {
      excl.write(' --exclude=${_shQuote(pat)} --exclude-dir=${_shQuote(pat)}');
    }
    String full;
    if (maxDepth > 0) {
      // GNU grep 无目录深度选项：用 find -maxdepth 枚举文件后交给 grep
      // （xargs 无文件时不执行；grep -H 保证输出仍带文件名前缀）
      final StringBuffer findExcl =
          StringBuffer(' -not -path ${_shQuote('*/.git/*')}');
      for (final String pat in exclude) {
        // -not -path 排除同名目录下的文件；-not -name 排除同名文件/目录本身
        findExcl.write(' -not -path ${_shQuote('*/$pat/*')}');
        findExcl.write(' -not -name ${_shQuote(pat)}');
      }
      full = 'cd ${_shQuote(cwd)} && find $target -maxdepth $maxDepth -type f'
          '$findExcl -print0 2>/dev/null | xargs -0 -r grep -nH${ic}I $mode '
          '-- ${_shQuote(pattern)}';
    } else {
      full = 'cd ${_shQuote(cwd)} && grep -rn${ic}I $mode $excl '
          '-- ${_shQuote(pattern)} $target';
    }
    final Map<String, dynamic> result = await _exec(client, full);
    // find 管道下 xargs 在 grep 无命中时返回 123，归一为 grep 语义的 1
    if (maxDepth > 0 && result['exit_code'] == 123) {
      result['exit_code'] = 1;
    }
    return result;
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

  /// 查看远端工作空间 git 提交历史，返回 ``{exit_code, commits}``。
  Future<Map<String, dynamic>> _gitLog(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final int limit = ((data['limit'] as num?) ?? 50).toInt().clamp(1, 1000);
    final String cwd = _remotePath(workspaceId, '');
    final String full =
        'cd ${_shQuote(cwd)} && git log --pretty=format:%H%x09%an%x09%ad%x09%s --date=iso -n $limit';
    final Map<String, dynamic> result = await _exec(client, full);
    final List<Map<String, dynamic>> commits = <Map<String, dynamic>>[];
    if (result['error'] == null && (result['exit_code'] as int?) == 0) {
      for (final String line
          in ((result['stdout'] as String?) ?? '').split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final List<String> parts = trimmed.split('\t');
        if (parts.length >= 4) {
          commits.add(<String, dynamic>{
            'hash': parts[0],
            'author': parts[1],
            'date': parts[2],
            'message': parts.sublist(3).join('\t'),
          });
        }
      }
    }
    return <String, dynamic>{
      'commits': commits,
      'exit_code': result['exit_code'] ?? 0,
    };
  }

  /// 查看远端工作空间所有分支，返回 ``{exit_code, branches, current}``。
  Future<Map<String, dynamic>> _gitBranches(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String cwd = _remotePath(workspaceId, '');
    final String full = 'cd ${_shQuote(cwd)} && git branch -a';
    final Map<String, dynamic> result = await _exec(client, full);
    final List<String> branches = <String>[];
    String current = '';
    if (result['error'] == null && (result['exit_code'] as int?) == 0) {
      for (final String line
          in ((result['stdout'] as String?) ?? '').split('\n')) {
        final String s = line.trim();
        if (s.isEmpty) continue;
        if (s.startsWith('* ')) {
          current = s.substring(2).trim();
          branches.add(current);
        } else {
          branches.add(s);
        }
      }
    }
    return <String, dynamic>{
      'branches': branches,
      'current': current,
      'exit_code': result['exit_code'] ?? 0,
    };
  }

  // ------------------------------------------------------------------
  // 第三方 MCP 服务的 stdio 隧道（远端宿主）
  // ------------------------------------------------------------------

  /// 在远端拉起 MCP 服务子进程（``mcp_stdio_open``），返回 ``{session_id}``。
  ///
  /// SSH 模式下第三方 MCP 服务的子进程必须跑在**远端主机**（与工作文件同处），
  /// 因此后端不直连其 stdio，而是把 JSON-RPC 帧经反向 WS 下发到本端、由本端
  /// 经 SSH exec 通道搬运。本方法只负责启动进程，不参与协议握手：initialize /
  /// tools/list / tools/call 全部由后端经 write/read 驱动，与后端直连 stdio 及
  /// 本地模式隧道的语义一致。
  ///
  /// 远端命令形如 ``env KEY=VAL <command> <args...>``：环境变量内联进命令行，
  /// 不依赖 sshd 的 ``AcceptEnv``（多数主机未配置，单独的 ``sendEnv`` 会被静默
  /// 丢弃）。不开 pty（[SSHClient.execute] 默认）：pty 会回显输入并把 ``\n``
  /// 转成 ``\r\n``，破坏 JSON-RPC 的换行分帧。
  ///
  /// 启动前按后端下发的 ``needs_confirmation`` 校验本端信任指纹（见
  /// [McpTrustStore]）：与本地宿主共用同一校验，确保两侧拒绝语义一致。
  Future<Map<String, dynamic>> _mcpStdioOpen(
    SSHClient client,
    Map<String, dynamic> data,
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
    final StringBuffer line = StringBuffer();
    if (env.isNotEmpty) {
      line.write('env');
      env.forEach((String key, String value) {
        line.write(' ${_shQuote('$key=$value')}');
      });
      line.write(' ');
    }
    line.write(_shQuote(command));
    for (final String arg in args) {
      line.write(' ${_shQuote(arg)}');
    }
    try {
      final SSHSession session = await client.execute(line.toString());
      _mcpSessionSeq++;
      final McpStdioTunnelSession tunnel = McpStdioTunnelSession(
        id: '${DateTime.now().microsecondsSinceEpoch}-$_mcpSessionSeq',
        teamId: teamId,
        write: (Uint8List payload) => session.stdin.add(payload),
        kill: () {
          try {
            session.kill(SSHSignal.TERM);
            session.close();
          } catch (_) {
            // 通道已关闭：忽略
          }
        },
      );
      tunnel.bindStreams(session.stdout, session.stderr);
      _mcpSessions['$teamId|${tunnel.id}'] = tunnel;
      // 远端进程退出（通道关闭）：唤醒挂起读取，让后端立刻失败而不是耗完等待窗口
      unawaited(
        session.done.then(
          (_) => tunnel.markExited(session.exitCode),
          onError: (Object _) => tunnel.markExited(session.exitCode),
        ),
      );
      return <String, dynamic>{'session_id': tunnel.id};
    } on SSHChannelOpenError {
      // 连接级通道上限/卡死：交由 _guarded 丢弃连接并重试
      rethrow;
    } catch (e) {
      return <String, dynamic>{'error': '启动远端 MCP 服务失败: $e'};
    }
  }

  /// 把后端写出的一帧 JSON-RPC 报文写入远端子进程 stdin（``mcp_stdio_write``）。
  Future<Map<String, dynamic>> _mcpStdioWrite(
    Map<String, dynamic> data,
  ) async {
    final McpStdioTunnelSession? session = _mcpLookup(data);
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
      return <String, dynamic>{'error': '写入远端 MCP 服务 stdin 失败: $e'};
    }
  }

  /// 取走远端子进程 stdout 上的一条完整帧（``mcp_stdio_read``，base64 回传）。
  ///
  /// 等待窗口（后端下发 ``timeout`` 秒）内没有整行时返回空串，由后端续等；
  /// 远端子进程此时已退出则返回错误，让后端立刻判定隧道中断。
  Future<Map<String, dynamic>> _mcpStdioRead(Map<String, dynamic> data) async {
    final McpStdioTunnelSession? session = _mcpLookup(data);
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

  /// 关闭 MCP 隧道会话并终止远端子进程（``mcp_stdio_close``，幂等）。
  Future<Map<String, dynamic>> _mcpStdioClose(Map<String, dynamic> data) async {
    final String sessionId = (data['session_id'] as String?) ?? '';
    _mcpSessions.remove('$teamId|$sessionId')?.dispose();
    return <String, dynamic>{'ok': true};
  }

  /// 按 payload 的 session_id 取本 team 的隧道会话（跨请求共享，见 [_mcpSessions]）。
  McpStdioTunnelSession? _mcpLookup(Map<String, dynamic> data) {
    final String sessionId = (data['session_id'] as String?) ?? '';
    return _mcpSessions['$teamId|$sessionId'];
  }

  /// 回收指定 team 的全部 MCP 隧道会话（删除顶部 agent 时调用）。
  static void disposeMcpSessionsOf(String teamId) {
    final List<String> owned = _mcpSessions.keys
        .where((String key) => key.startsWith('$teamId|'))
        .toList();
    for (final String key in owned) {
      _mcpSessions.remove(key)?.dispose();
    }
  }

  /// 回收全部 MCP 隧道会话（应用退出 / 清理时调用）。
  static void disposeAllMcpSessions() {
    for (final McpStdioTunnelSession session
        in _mcpSessions.values.toList(growable: false)) {
      session.dispose();
    }
    _mcpSessions.clear();
  }

  /// 回收指定 team 的全部插件宿主会话（删 agent / 关闭模式时调用）。
  ///
  /// 远端 kill 依赖通道，须在连接关闭之前调用（调用方保证）；失败仅吞掉，
  /// 不阻塞清理流程。
  static Future<void> disposePluginHostSessionsOf(String teamId) async {
    final List<_SshPluginHostSession> owned = _pluginHostSessions.values
        .where((_SshPluginHostSession s) => s.teamId == teamId)
        .toList(growable: false);
    for (final _SshPluginHostSession session in owned) {
      _pluginHostSessions.remove('${session.teamId}|${session.hostSessionId}');
      await _killRemoteHostSession(session);
    }
  }

  /// 回收全部插件宿主会话（应用退出 / 清理时调用）。
  static Future<void> disposeAllPluginHostSessions() async {
    final List<_SshPluginHostSession> all =
        _pluginHostSessions.values.toList(growable: false);
    _pluginHostSessions.clear();
    for (final _SshPluginHostSession session in all) {
      await _killRemoteHostSession(session);
    }
  }

  /// 重连对账：team 不可用（未注册 / 未启用）→ 回收（§14.3.3，尽力而为）。
  static Future<void> reconcilePluginHostSessions(Set<String> usableTeams) async {
    final List<_SshPluginHostSession> stale = _pluginHostSessions.values
        .where((_SshPluginHostSession s) => !usableTeams.contains(s.teamId))
        .toList(growable: false);
    for (final _SshPluginHostSession session in stale) {
      _pluginHostSessions.remove('${session.teamId}|${session.hostSessionId}');
      await _killRemoteHostSession(session);
    }
  }

  /// 经会话记录重建执行器，执行远端 kill（best-effort；异常吞掉）。
  static Future<void> _killRemoteHostSession(
    _SshPluginHostSession session,
  ) async {
    try {
      await SshWorkspaceExecutor(session.manager,
              teamId: session.teamId, config: session.config)
          .killHost(session.pidFile);
    } catch (_) {
      // 尽力而为：远端不可达仅忽略，不阻塞清理流程
    }
  }

  // ------------------------------------------------------------------
  // 工具函数
  // ------------------------------------------------------------------

  /// 拼接相对工作空间根的路径（[base] 为空时直接返回 [name]）。
  String _joinPath(String base, String name) {
    return base.isEmpty ? name : '$base/$name';
  }

  /// 取 POSIX 路径的父目录（不含尾部 ``/``）。
  String _posixDirname(String path) {
    final String normalized = path.replaceAll(RegExp(r'/+$'), '');
    final int idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '/';
    return normalized.substring(0, idx);
  }

  /// 按编码名解码字节（与本地执行器的编码映射保持一致，默认 UTF-8）。
  String _decodeText(List<int> bytes, String encoding) {
    switch (encoding.toLowerCase()) {
      case 'latin-1':
      case 'latin1':
      case 'iso-8859-1':
        return latin1.decode(bytes, allowInvalid: true);
      case 'ascii':
        return ascii.decode(bytes, allowInvalid: true);
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 将 SFTP 修改时间（epoch 秒，可空）格式化为 ``"YYYY-MM-DD HH:mm"``。
  String _formatModified(int? epochSeconds) {
    if (epochSeconds == null || epochSeconds <= 0) return '';
    final DateTime m =
        DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${m.year.toString().padLeft(4, '0')}-${two(m.month)}-'
        '${two(m.day)} ${two(m.hour)}:${two(m.minute)}';
  }
}

/// 大文件分片上传会话状态（SSH 执行器）。
///
/// SFTP 文件句柄绑定其打开时的 SFTP 通道，因此会话同时持有通道与句柄，
/// chunk/complete 复用同一条通道；complete（或重复 init）时关闭并移除。
class _SftpUploadSession {
  _SftpUploadSession({
    required this.sftp,
    required this.file,
    required this.relPath,
    this.chunkSize = 4 * 1024 * 1024,
    this.totalSize = 0,
  });

  /// 打开文件句柄时所在的 SFTP 通道（chunk/complete 必须复用）
  final SftpClient sftp;

  /// 已打开的远端文件句柄（write | create | truncate）
  final SftpFile file;

  /// 工作空间内相对路径（如 ``.input/20260906/big.bin``）
  final String relPath;

  /// 分片大小（后端 upload_init 下发，chunk 偏移 = index × chunkSize）
  final int chunkSize;

  /// 期望总大小（complete 时校验；0 表示不校验）
  final int totalSize;

  /// 已接收字节数（complete 校验与回传用）
  int received = 0;
}
