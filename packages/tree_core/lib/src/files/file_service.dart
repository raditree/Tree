import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/tree_store.dart';

/// 工作空间文件服务（M7d）：给前端文件面板 / 查看器 / Git 面板提供数据。
///
/// 桌面端工作空间就在本机，但前端**仍然只经 REST 读文件**（不直接读盘），
/// 因此这里是唯一的**路径安全边界**：一律工作空间内相对路径，绝对路径 / 盘符 /
/// `..` 逃逸一律拒绝。
///
/// 范围（明确写清，避免"以为都支持"）：
/// - `list` / `content` / `gitLog` / `gitBranches` / `pdfInfo` 已实现；
/// - **只支持本机工作空间**：配了 SSH 的 agent 其工作空间在远端，需要远端 IO
///   （`SshWorkspaceIO` 已具备读能力，接线留给后续里程碑），这里返回可读错误；
/// - `pdf_preview`（把 PDF 某页渲染成图片）**未实现**：纯 Dart 进程没有 PDF 光栅化
///   能力，需要引入渲染依赖（或改成前端渲染），属于待用户决策项。
class FileService {
  FileService({
    required this.store,
    required this.defaultWorkspaceDir,
    this.log,
    this.maxListEntries = 2000,
    this.maxContentBytes = 8 * 1024 * 1024,
    this.gitTimeout = const Duration(seconds: 10),
  });

  final TreeStore store;

  /// 未配置 `workspace_dir` 时的默认目录（CLI 传 `TreePaths.defaultWorkspaceDir`）。
  final String Function(String agentId) defaultWorkspaceDir;

  final void Function(String message)? log;
  final int maxListEntries;
  final int maxContentBytes;
  final Duration gitTimeout;

  /// `workspace_id` → agent：先按 `agent.workspaceId` 匹配，其次把 id 当 agent id。
  CoreAgent? agentFor(String workspaceId) {
    final String id = workspaceId.trim();
    if (id.isEmpty) return null;
    for (final CoreAgent agent in store.agents()) {
      if (agent.workspaceId == id) return agent;
    }
    return store.agent(id);
  }

  /// 某 agent 的工作空间根目录（本机绝对路径）。
  String rootFor(CoreAgent agent) {
    final String configured = agent.workspaceDir.trim();
    return configured.isNotEmpty ? configured : defaultWorkspaceDir(agent.id);
  }

  /// 列出目录（`path` 为空 = 根）。目录在前，各自按名字排序。
  Map<String, dynamic> list(String workspaceId, {String path = ''}) {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (agent.sshConfig != null) {
      return _error('该工作空间在远端（SSH）：文件面板暂不支持远端目录，请用终端工具查看', 400);
    }
    final String root = rootFor(agent);
    final Directory dir;
    try {
      dir = Directory(resolve(root, path, allowRoot: true));
    } on FileServiceException catch (error) {
      return _error(error.message, 400);
    }
    if (!dir.existsSync()) return _error('目录不存在：${path.isEmpty ? '/' : path}');

    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    try {
      for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
        if (entries.length >= maxListEntries) break;
        final String name = p.basename(entity.path);
        final FileStat stat = entity.statSync();
        final bool isDir = stat.type == FileSystemEntityType.directory;
        entries.add(<String, dynamic>{
          'name': name,
          'size': isDir ? 0 : stat.size,
          'type': isDir ? 'dir' : 'file',
          'modified': stat.modified.toIso8601String(),
          'path': _relative(root, entity.path),
        });
      }
    } catch (error) {
      return _error('读取目录失败：$error', 500);
    }
    entries.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final bool aDir = a['type'] == 'dir';
      final bool bDir = b['type'] == 'dir';
      if (aDir != bDir) return aDir ? -1 : 1;
      return (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      );
    });
    return <String, dynamic>{
      'files': entries,
      'path': path,
      'total': entries.length,
      if (entries.length >= maxListEntries) 'truncated': true,
    };
  }

  /// 读取文件内容：图片返回 base64，其余按文本解码（UTF-8 失败退 latin1）。
  Map<String, dynamic> content(String workspaceId, String path) {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (agent.sshConfig != null) {
      return _error('该工作空间在远端（SSH）：文件面板暂不支持远端文件内容，请用 read 工具', 400);
    }
    final String root = rootFor(agent);
    final String absolute;
    try {
      absolute = resolve(root, path);
    } on FileServiceException catch (error) {
      return _error(error.message, 400);
    }
    final File file = File(absolute);
    if (!file.existsSync()) return _error('文件不存在：$path');
    final int size = file.lengthSync();
    if (size > maxContentBytes) {
      return _error(
        '文件过大（${size ~/ 1024} KB > ${maxContentBytes ~/ 1024} KB），请用终端/工具处理',
      );
    }
    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } catch (error) {
      return _error('读取文件失败：$error', 500);
    }
    final String ext = p
        .extension(absolute)
        .replaceFirst('.', '')
        .toLowerCase();
    if (LocalWorkspaceIO.imageExtensions.contains(ext)) {
      return <String, dynamic>{
        'content': base64Encode(bytes),
        'path': path,
        'size': size,
        'encoding': 'base64',
      };
    }
    return <String, dynamic>{
      'content': LocalWorkspaceIO.decodeBytes(bytes),
      'path': path,
      'size': size,
      'encoding': 'utf-8',
    };
  }

  /// PDF 基本信息（总页数 / 标题 / 作者）。
  ///
  /// **页数是启发式的**：优先取页树 `/Count` 的最大值（根节点即总数），取不到
  /// 再数 `/Type /Page` 的出现次数。返回值里带 `pages_source` 说明来源，不假装
  /// 这是权威解析（真正的解析器需要引入 PDF 库，属于待决策项）。
  Map<String, dynamic> pdfInfo(String workspaceId, String path) {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (agent.sshConfig != null) {
      return _error('该工作空间在远端（SSH）：暂不支持远端 PDF 信息', 400);
    }
    final String root = rootFor(agent);
    final String absolute;
    try {
      absolute = resolve(root, path);
    } on FileServiceException catch (error) {
      return _error(error.message, 400);
    }
    final File file = File(absolute);
    if (!file.existsSync()) return _error('文件不存在：$path');
    final String text = latin1.decode(
      file.readAsBytesSync(),
      allowInvalid: true,
    );

    int pages = 0;
    String source = '';
    for (final RegExpMatch match in RegExp(
      r'/Count\s+(\d+)',
    ).allMatches(text)) {
      final int value = int.tryParse(match.group(1) ?? '') ?? 0;
      if (value > pages) {
        pages = value;
        source = 'count';
      }
    }
    if (pages <= 0) {
      pages = RegExp(r'/Type\s*/Page(?![s])').allMatches(text).length;
      source = 'scan';
    }
    return <String, dynamic>{
      'total_pages': pages,
      'title': _pdfString(text, 'Title'),
      'author': _pdfString(text, 'Author'),
      'pages_source': source,
    };
  }

  /// Git 提交历史（`GET /api/workspaces/{id}/git/log`）。
  Future<Map<String, dynamic>> gitLog(
    String workspaceId, {
    int limit = 50,
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (agent.sshConfig != null) {
      return _error('该工作空间在远端（SSH）：暂不支持远端 Git 历史', 400);
    }
    final String root = rootFor(agent);
    if (!Directory(root).existsSync()) return _error('工作空间目录不存在：$root');
    final ProcessResult result = await _git(root, <String>[
      'log',
      '-n',
      '${limit.clamp(1, 500)}',
      '--pretty=format:%H%x1f%an%x1f%aI%x1f%s',
    ]);
    if (result.exitCode != 0) {
      return _error('git log 失败：${_tail(result.stderr)}', 500);
    }
    final List<Map<String, dynamic>> commits = <Map<String, dynamic>>[];
    for (final String line in '${result.stdout}'.split('\n')) {
      if (line.trim().isEmpty) continue;
      final List<String> parts = line.split('\u001f');
      if (parts.length < 4) continue;
      commits.add(<String, dynamic>{
        'hash': parts[0],
        'author': parts[1],
        'date': parts[2],
        'message': parts[3],
      });
    }
    return <String, dynamic>{'commits': commits};
  }

  /// Git 分支列表（`GET /api/workspaces/{id}/git/branches`）。
  Future<Map<String, dynamic>> gitBranches(String workspaceId) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (agent.sshConfig != null) {
      return _error('该工作空间在远端（SSH）：暂不支持远端 Git 分支', 400);
    }
    final String root = rootFor(agent);
    if (!Directory(root).existsSync()) return _error('工作空间目录不存在：$root');
    final ProcessResult branches = await _git(root, <String>[
      'branch',
      '--format=%(refname:short)',
    ]);
    if (branches.exitCode != 0) {
      return _error('git branch 失败：${_tail(branches.stderr)}', 500);
    }
    final ProcessResult current = await _git(root, <String>[
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    return <String, dynamic>{
      'branches': '${branches.stdout}'
          .split('\n')
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .map((String name) => <String, dynamic>{'name': name})
          .toList(),
      'current': current.exitCode == 0 ? '${current.stdout}'.trim() : '',
    };
  }

  /// 解析工作空间内相对路径。
  ///
  /// 拒绝：空以外的绝对路径 / 盘符 / `~` / 任何 `..` 逃逸。`allowRoot` 允许 `.`。
  String resolve(String root, String relativePath, {bool allowRoot = false}) {
    final String raw = relativePath.trim().replaceAll('\\', '/');
    if (raw.isEmpty) {
      if (allowRoot) return p.normalize(root);
      throw FileServiceException('路径不能为空');
    }
    if (raw.startsWith('~') ||
        p.posix.isAbsolute(raw) ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
      throw FileServiceException('必须是工作空间内的相对路径：$relativePath');
    }
    final String normalizedRoot = p.normalize(root);
    final String absolute = p.normalize(p.join(normalizedRoot, raw));
    if (absolute != normalizedRoot && !p.isWithin(normalizedRoot, absolute)) {
      throw FileServiceException('越出工作空间根目录：$relativePath');
    }
    return absolute;
  }

  Future<ProcessResult> _git(String dir, List<String> args) async {
    try {
      return await Process.run(
        'git',
        <String>['-C', dir, ...args],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(gitTimeout);
    } catch (error) {
      log?.call('git 执行失败（$dir）：$error');
      return ProcessResult(0, -1, '', '$error');
    }
  }

  String _relative(String root, String absolute) =>
      p.posix.joinAll(p.split(p.relative(absolute, from: root)));

  static String _tail(Object? stderr) {
    final String text = '${stderr ?? ''}'.trim();
    return text.length <= 200 ? text : text.substring(text.length - 200);
  }

  /// 从 PDF 的 Info 字典取字符串（字面串 `(x)` 或十六进制 `<hex>`）。
  static String _pdfString(String text, String key) {
    final RegExpMatch? literal = RegExp('/$key\\s*\\(([^)]*)\\)')
        .firstMatch(text);
    if (literal != null) {
      // 字面串按字节还原：很多工具把 UTF-8 直接写进 PDF 字符串（严格说应转义），
      // 先试 UTF-8，失败再退 latin1——两种都能读到，不猜。
      final List<int> bytes = (literal.group(1) ?? '').codeUnits;
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return latin1.decode(bytes);
      }
    }
    final RegExpMatch? hex = RegExp('/$key\\s*<([0-9A-Fa-f]+)>')
        .firstMatch(text);
    if (hex == null) return '';
    final String raw = hex.group(1) ?? '';
    if (raw.length.isOdd) return '';
    try {
      final List<int> bytes = <int>[];
      for (int i = 0; i < raw.length; i += 2) {
        bytes.add(int.parse(raw.substring(i, i + 2), radix: 16));
      }
      // PDF 的 UTF-16BE BOM（FE FF）在标题里很常见
      if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return String.fromCharCodes(<int>[
          for (int i = 2; i + 1 < bytes.length; i += 2)
            (bytes[i] << 8) | bytes[i + 1],
        ]);
      }
      return latin1.decode(bytes);
    } catch (_) {
      return '';
    }
  }

  static Map<String, dynamic> _error(String message, [int status = 404]) =>
      <String, dynamic>{'error': message, 'status': status};
}

/// 文件服务的可读错误。
class FileServiceException implements Exception {
  FileServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
