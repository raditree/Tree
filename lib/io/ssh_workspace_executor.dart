import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_connection_manager.dart';

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

  SshWorkspaceExecutor(
    this.manager, {
    required this.teamId,
    required this.config,
  });

  /// 按操作类型分发执行，返回结果字典（结构对齐后端/本地执行器）。
  ///
  /// 失败时返回 ``{error}``；连接不存在/断开时尝试按配置重建。
  Future<Map<String, dynamic>> execute(
    String workspaceId,
    String op,
    Map<String, dynamic> data,
  ) async {
    if (teamId.isEmpty) {
      return <String, dynamic>{'error': '未选择顶部 agent'};
    }
    SSHClient client;
    try {
      client = await manager.connect(teamId, config);
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 连接失败: $e'};
    }
    try {
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
        default:
          return <String, dynamic>{'error': '未知 SSH 执行操作: $op'};
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
    return rel.isEmpty ? root : _posixNorm('$root/$rel');
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
    final String norm = _posixNorm('$root/$rel');
    final String baseNorm = _posixNorm(base);
    if (baseNorm.isEmpty || baseNorm == '/') {
      // base 未配置或为根目录：保持原有行为，视为允许
      return norm;
    }
    final String prefix = baseNorm.endsWith('/') ? baseNorm : '$baseNorm/';
    if (norm == baseNorm || norm.startsWith(prefix)) return norm;
    return null;
  }

  /// POSIX 路径归一化：折叠 ``.`` / ``..``，统一 ``/``。
  String _posixNorm(String path) {
    final List<String> parts = <String>[];
    for (final String part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
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
      int doneCount = 0;
      final Completer<void> allDone = Completer<void>();
      void onDone() {
        doneCount++;
        if (doneCount == 2 && !allDone.isCompleted) {
          allDone.complete();
        }
      }

      session.stdout.listen(out.add, onDone: onDone);
      session.stderr.listen(err.add, onDone: onDone);
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
      return <String, dynamic>{'exit_code': 1, 'files': <dynamic>[], 'error': '列出目录失败: ${e.message}'};
    } catch (e) {
      return <String, dynamic>{'exit_code': 1, 'files': <dynamic>[], 'error': '列出目录失败: $e'};
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
        return <String, dynamic>{'error': '文件不存在或无法读取: $path', 'exit_code': 1, 'stdout': ''};
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
        return <String, dynamic>{'error': '文件不存在或无法读取: $path', 'exit_code': 1, 'stdout': ''};
      }
      return <String, dynamic>{'error': 'SSH 读取失败: ${e.message}', 'exit_code': 1};
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 读取失败: $e', 'exit_code': 1};
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
        return <String, dynamic>{'error': '文件不存在或无法读取: $path', 'exit_code': 1};
      }
      return <String, dynamic>{
        'exit_code': 0,
        'content_base64': base64Encode(bytes),
      };
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) {
        return <String, dynamic>{'error': '文件不存在或无法读取: $path', 'exit_code': 1};
      }
      return <String, dynamic>{'error': 'SSH 读取失败: ${e.message}', 'exit_code': 1};
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 读取失败: $e', 'exit_code': 1};
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
      return <String, dynamic>{'error': 'SSH 写入失败: $e', 'file_path': path};
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
      return <String, dynamic>{'error': 'SSH 上传失败: $e', 'file_path': relPath};
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
      return <String, dynamic>{'error': '初始化分片上传失败: $e'};
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
    SSHClient client;
    try {
      client = await manager.connect(teamId, config);
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 连接失败: $e'};
    }
    final String cwd = _remotePath(workspaceId, '');
    final String full = 'cd ${_shQuote(cwd)} || exit 1; '
        'kill -TERM \$(cat ${_shQuote(pidfile)}) 2>/dev/null || true';
    return _exec(client, full, timeout: 10);
  }

  /// 在远端工作空间按模式递归搜索，返回 ``{exit_code, stdout}``。
  ///
  /// 支持参数：``pattern``（必填）、``path``（搜索范围，workspace 内相对
  /// 路径，缺省整个工作空间）、``regex``（是否正则，缺省 false 字面量）、
  /// ``ignore_case``（缺省 false）。
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
    final String full =
        'cd ${_shQuote(cwd)} && grep -rn${ic}I $mode --exclude-dir=.git '
        '-- ${_shQuote(pattern)} $target';
    return _exec(client, full);
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
