import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'websocket_service.dart';

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
/// 本地模式按顶部 agent 单独控制：开关与工作目录以顶部 agent 为单位持久化，
/// 通过 [setCurrentTopAgent] 指定当前操作的顶部 agent；[register] 会把
/// ``top_agent_id`` 一并发送给后端，使不同顶部 agent 可分别处于本地/云端模式。
///
/// 工作空间路径映射（与后端 ``docker_manager._local_workspace_path`` 一致）：
/// - 顶级 agent（workspace_id == "top"）→ 用户选择的工作目录 <baseDir>
/// - 其他 agent → <baseDir>/workspaces/{workspace_id}
class LocalExecutorService extends ChangeNotifier {
  LocalExecutorService._();

  /// 全局单例
  static final LocalExecutorService instance = LocalExecutorService._();

  /// 当前选中的顶部 agent ID（本地模式按此单独控制）
  String _currentTopAgentId = '';

  /// SharedPreferences 键前缀（后接顶部 agent ID，实现按顶部 agent 持久化）
  static const String _kEnabledPrefix = 'local_exec_enabled_';
  static const String _kWorkDirPrefix = 'local_exec_working_dir_';

  static String _kEnabledKey(String topAgentId) => '$_kEnabledPrefix$topAgentId';
  static String _kWorkDirKey(String topAgentId) => '$_kWorkDirPrefix$topAgentId';

  /// 承载当前 WebSocket 通道的服务（用于接收请求与回传结果）
  WebSocketService? _ws;

  /// 当前顶部 agent 的本地工作目录
  String _baseDir = '';

  /// 当前顶部 agent 的本地执行模式是否启用（持久化）
  bool _enabled = false;
  bool get enabled => _enabled;

  /// 当前顶部 agent 的工作目录（持久化）
  String get workingDirectory => _baseDir;

  /// 当前顶部 agent 是否已注册本地执行器
  bool _registered = false;
  bool get registered => _registered;

  /// 切换当前操作的顶部 agent，并重置其本地状态（下次 [loadSettings] 后生效）。
  ///
  /// 不会自动注销上一个顶部 agent——各顶部 agent 的本地模式相互独立，
  /// 注销只发生在用户显式关闭该 agent 的本地模式时。
  void setCurrentTopAgent(String topAgentId) {
    if (topAgentId == _currentTopAgentId) return;
    _currentTopAgentId = topAgentId;
    _enabled = false;
    _baseDir = '';
    _registered = false;
    notifyListeners();
  }

  /// 从 SharedPreferences 恢复当前顶部 agent 的本地执行模式设置
  Future<void> loadSettings() async {
    final String id = _currentTopAgentId;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabledKey(id)) ?? false;
    _baseDir = prefs.getString(_kWorkDirKey(id)) ?? '';
  }

  /// 设置当前顶部 agent 的本地执行模式开关。
  ///
  /// 开启时若已有工作目录立即注册本地执行器；关闭时注销并恢复云端执行。
  /// 不启动任何本地进程——工具执行位置由后端通过反向 WS 转发决定。
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) {
      // 状态一致但连接可能已重建，重新确保注册/注销
      if (value && _baseDir.isNotEmpty) {
        register(_baseDir);
      } else if (!value && _registered) {
        unregister();
      }
      return;
    }
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey(_currentTopAgentId), value);
    if (value) {
      if (_baseDir.isNotEmpty) register(_baseDir);
    } else {
      unregister();
    }
    notifyListeners();
  }

  /// 设置当前顶部 agent 的工作目录并持久化
  Future<void> setWorkingDirectory(String path) async {
    _baseDir = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kWorkDirKey(_currentTopAgentId), path);
    notifyListeners();
  }

  /// 按当前顶部 agent 的本地模式同步注册/注销（切换顶部 agent / 重连后调用）。
  void syncRegistration() {
    if (_currentTopAgentId.isEmpty) return;
    if (_enabled && _baseDir.isNotEmpty) {
      register(_baseDir);
    } else if (_registered) {
      unregister();
    }
  }

  /// 绑定 WebSocket 服务并接管 ``tool_exec_request`` 消息。
  ///
  /// 每个 WebSocket 连接建立后都应调用一次（本地模式）。内部只接管
  /// 工具执行请求，其余消息仍正常派发给页面。
  void attach(WebSocketService ws) {
    _ws = ws;
    ws.onToolExecRequest = _handleToolExecRequest;
  }

  /// 注册当前顶部 agent 的本地执行器：设置工作目录并通知后端转发工具请求。
  void register(String baseDir) {
    if (_currentTopAgentId.isEmpty) return;
    _baseDir = baseDir;
    _registered = true;
    _send(<String, dynamic>{
      'type': 'register_local_executor',
      'data': <String, dynamic>{
        'base_dir': baseDir,
        'top_agent_id': _currentTopAgentId,
      },
    });
  }

  /// 注销当前顶部 agent 的本地执行器：通知后端该 agent 恢复云端执行。
  void unregister() {
    if (_currentTopAgentId.isEmpty) return;
    _registered = false;
    _send(<String, dynamic>{
      'type': 'unregister_local_executor',
      'data': <String, dynamic>{'top_agent_id': _currentTopAgentId},
    });
  }

  /// 解析工具请求的工作目录（与后端本地路径映射保持一致）。
  ///
  /// 新的协同语义：
  /// - 所有 agent（顶层 agent 与团队成员）的工作文件都在工作目录
  ///   <baseDir> 中读写执行，实现全队协同工作——因此非记忆路径一律返回 base。
  /// - 每个 agent 的私人记忆文件（``.self`` 开头的路径）存放于各自的私人空间
  ///   <baseDir>/workspaces/{workspace_id}，与共享工作目录隔离，互不泄露。
  Directory _resolveWorkspaceDir(String workspaceId, [String path = '']) {
    final String base =
        _baseDir.isEmpty ? Directory.current.path : _baseDir;
    if (_isPrivatePath(path)) {
      return Directory('$base${Platform.pathSeparator}workspaces'
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
  void _handleToolExecRequest(Map<String, dynamic> message) {
    final Map<String, dynamic> data =
        (message['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String execId = (data['exec_id'] as String?) ?? '';
    if (execId.isEmpty) return;
    final String workspaceId = (data['workspace_id'] as String?) ?? '';
    final String op = (data['op'] as String?) ?? '';

    _execute(workspaceId, op, data).then((Map<String, dynamic> result) {
      _send(<String, dynamic>{
        'type': 'tool_exec_response',
        'data': <String, dynamic>{
          'exec_id': execId,
          'result': result,
        },
      });
    }).catchError((Object error) {
      _send(<String, dynamic>{
        'type': 'tool_exec_response',
        'data': <String, dynamic>{
          'exec_id': execId,
          'result': <String, dynamic>{'error': error.toString()},
        },
      });
    });
  }

  /// 按操作类型分发执行
  Future<Map<String, dynamic>> _execute(
    String workspaceId,
    String op,
    Map<String, dynamic> data,
  ) async {
    // 携带操作路径，按路径路由：.self 记忆 → 私人空间；其余 → 工作目录 base
    final String path = (data['path'] as String?) ?? '';
    final Directory wsDir = _resolveWorkspaceDir(workspaceId, path);
    switch (op) {
      case 'list_files':
        return _listFiles(wsDir, data);
      case 'read_file':
        return _readFile(wsDir, data);
      case 'read_file_bytes':
        return _readFileBytes(wsDir, data);
      case 'write_file':
        return _writeFile(wsDir, data);
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
        // 隐藏 .git 与 workspaces（私人记忆空间），避免在共享工作目录中互相暴露
        if (name == '.git' || name == 'workspaces') continue;
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
      final String content = await file.readAsString(encoding: _encoding(encoding));
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
      await file.writeAsString(content);
      return <String, dynamic>{'success': true, 'file_path': path};
    } catch (e) {
      return <String, dynamic>{'error': '写入文件失败: $e', 'file_path': path};
    }
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
    final bool isWindows = Platform.isWindows;
    return _runProcess(
      wsDir,
      isWindows
          ? <String>['cmd', '/c', command]
          : <String>['sh', '-c', command],
      timeout: timeout,
    );
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
  Future<Map<String, dynamic>> _runProcess(
    Directory wsDir,
    List<String> argv, {
    int timeout = 0,
  }) async {
    if (argv.isEmpty) {
      return <String, dynamic>{'error': '缺少可执行命令'};
    }
    try {
      final Future<ProcessResult> future = Process.run(
        argv.first,
        argv.sublist(1),
        workingDirectory: wsDir.path,
      );
      final ProcessResult result = timeout > 0
          ? await future.timeout(Duration(seconds: timeout))
          : await future;
      return <String, dynamic>{
        'exit_code': result.exitCode,
        'stdout': _decode(result.stdout),
        'stderr': _decode(result.stderr),
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

  /// 在工作空间内按字面量模式递归搜索（排除 .git 与二进制文件），
  /// 返回 ``{exit_code, stdout}``，无命中时 exit_code 为 1（与 grep 一致）。
  Future<Map<String, dynamic>> _grepSearch(
    Directory wsDir,
    Map<String, dynamic> data,
  ) async {
    final String pattern = (data['pattern'] as String?) ?? '';
    if (pattern.isEmpty) {
      return <String, dynamic>{'error': 'grep_search 缺少 pattern'};
    }
    final List<String> lines = <String>[];
    try {
      await _walkSearch(wsDir, pattern, lines);
    } catch (e) {
      return <String, dynamic>{'error': '搜索失败: $e'};
    }
    if (lines.isEmpty) {
      return <String, dynamic>{'exit_code': 1, 'stdout': ''};
    }
    return <String, dynamic>{
      'exit_code': 0,
      'stdout': lines.join('\n'),
    };
  }

  /// 递归遍历目录，收集包含 [pattern]（字面量）的行。
  Future<void> _walkSearch(
    Directory dir,
    String pattern,
    List<String> out,
  ) async {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        final String name = _basename(entity.path);
        if (name == '.git' || name == 'workspaces') continue;
        await _walkSearch(entity, pattern, out);
      } else if (entity is File) {
        try {
          final String content = await entity.readAsString(encoding: utf8);
          final List<String> fileLines = content.split('\n');
          for (final String line in fileLines) {
            if (line.contains(pattern)) {
              out.add('${entity.path}:$line');
            }
          }
        } catch (_) {
          // 忽略二进制 / 不可解码文件
        }
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
