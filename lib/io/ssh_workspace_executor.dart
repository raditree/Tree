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
/// 路径映射（复刻原后端 `SSHWorkspaceIO` 语义，避免行为回归）：
/// - 顶部 agent（workspace_id == 当前顶部 agent id）→ ``remote_base_dir``；
/// - 团队成员 → ``remote_base_dir/workspaces/{workspace_id}``；
/// - 含穿越防护：拒绝以 ``/`` / ``\`` 开头的绝对路径与含 ``..`` 段的输入，
///   且归一化后的远端路径必须仍位于 ``remote_base_dir`` 之下。
class SshWorkspaceExecutor {
  /// 顶层 agent 的 SSH 连接管理器（负责建连/缓存/重建）
  final SshConnectionManager manager;

  /// 当前顶部 agent 的 SSH 配置提供者（取 ``remote_base_dir`` 等字段）
  final Map<String, dynamic> Function() configProvider;

  /// 当前顶部 agent ID 提供者（用于判定顶部 / 成员路径映射）
  final String Function() topAgentIdProvider;

  SshWorkspaceExecutor(
    this.manager, {
    required this.configProvider,
    required this.topAgentIdProvider,
  });

  /// 按操作类型分发执行，返回结果字典（结构对齐后端/本地执行器）。
  ///
  /// 失败时返回 ``{error}``；连接不存在/断开时尝试按配置重建。
  Future<Map<String, dynamic>> execute(
    String workspaceId,
    String op,
    Map<String, dynamic> data,
  ) async {
    final String topAgentId = topAgentIdProvider();
    final Map<String, dynamic> config = configProvider();
    if (topAgentId.isEmpty) {
      return <String, dynamic>{'error': '未选择顶部 agent'};
    }
    SSHClient client;
    try {
      client = await manager.connect(topAgentId, config);
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
        ((configProvider()['remote_base_dir'] as String?) ?? '').trim();
    if (base.isEmpty) return '/';
    return base.replaceAll(RegExp(r'/+$'), '');
  }

  /// 把工作空间内相对路径映射为远端绝对路径（不做穿越校验，供 exec cwd 等）。
  String _remotePath(String workspaceId, String path) {
    final String base = _resolveBase();
    final String rel = path.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
    final String root = workspaceId == topAgentIdProvider()
        ? base
        : '$base/workspaces/$workspaceId';
    return rel.isEmpty ? root : _posixNorm('$root/$rel');
  }

  /// 映射远端绝对路径并做穿越防护；非法路径返回 null（调用方据此返回错误）。
  String? _sanitizeRemotePath(String workspaceId, String path) {
    final String p = path.replaceAll('\\', '/');
    if (p.startsWith('/')) return null; // 拒绝绝对路径
    if (p.split('/').contains('..')) return null; // 拒绝含 .. 段
    final String base = _resolveBase();
    final String rel = p.replaceFirst(RegExp(r'^/+'), '');
    final String root = workspaceId == topAgentIdProvider()
        ? base
        : '$base/workspaces/$workspaceId';
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
  /// [timeout] 为 Dart 侧等待上限（秒）；null / <=0 表示不设超时（由后端
  /// 120s 响应上限兜底，与旧 paramiko 行为一致）。
  Future<Map<String, dynamic>> _exec(
    SSHClient client,
    String command, {
    int? timeout,
  }) async {
    try {
      final SSHSession session = await client.execute(command);
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
        await allDone.future.timeout(Duration(seconds: timeout));
      }
      return <String, dynamic>{
        'exit_code': session.exitCode ?? 0,
        'stdout': utf8.decode(out.takeBytes(), allowMalformed: true),
        'stderr': utf8.decode(err.takeBytes(), allowMalformed: true),
      };
    } catch (e) {
      return <String, dynamic>{'error': 'SSH 执行失败: $e'};
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
  Future<Map<String, dynamic>> _execArgv(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final List<dynamic> raw = (data['argv'] as List<dynamic>?) ?? <dynamic>[];
    if (raw.isEmpty) {
      return <String, dynamic>{'error': 'exec_argv 缺少 argv'};
    }
    final int timeout = ((data['timeout'] as num?) ?? 0).toInt();
    final String cwd = _remotePath(workspaceId, '');
    final String full =
        'cd ${_shQuote(cwd)} && ${raw.map((dynamic e) => _shQuote(e.toString())).join(' ')}';
    return _exec(client, full, timeout: timeout > 0 ? timeout : null);
  }

  /// 在远端以 hook 模式执行长命令（无 Dart 侧超时上限，命令结束后回传退出码）。
  ///
  /// SSHWorkspaceIO 继承 LocalWorkspaceIO，hook 任务经 ``exec_shell_hook`` 委托
  /// 到前端；命令已含 ``> output_file 2>&1`` 重定向，本实现仅需在远端执行并
  /// 等待退出，语义与云端/SSH 的后端线程执行一致（不设超时）。
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
    final String full = 'cd ${_shQuote(cwd)} && $command';
    return _exec(client, full);
  }

  /// 在远端工作空间按字面量模式递归搜索，返回 ``{exit_code, stdout}``。
  Future<Map<String, dynamic>> _grepSearch(
    SSHClient client,
    String workspaceId,
    Map<String, dynamic> data,
  ) async {
    final String pattern = (data['pattern'] as String?) ?? '';
    if (pattern.isEmpty) {
      return <String, dynamic>{'error': 'grep_search 缺少 pattern'};
    }
    final String cwd = _remotePath(workspaceId, '');
    final String full =
        'cd ${_shQuote(cwd)} && grep -rnI --exclude-dir=.git -- ${_shQuote(pattern)} .';
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
