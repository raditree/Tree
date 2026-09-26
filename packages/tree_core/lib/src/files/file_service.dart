import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
/// - 读：`list` / `content` / `readBytes` / `pdfInfo` / `gitLog` / `gitBranches`；
/// - 写（M7d-3）：`uploadInit`/`uploadChunk`/`uploadComplete` 分片上传、
///   `syncToLocal`（整棵工作空间复制到本机目录）、`archive`（目录打包 tar.gz）；
/// - **只支持本机工作空间**：配了 SSH 的 agent 其工作空间在远端，需要远端 IO
///   （`SshWorkspaceIO` 目前只有文本读写，二进制 SFTP 通道留给后续里程碑），
///   这里返回可读错误；
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
    this.chunkSize = 4 * 1024 * 1024,
    this.maxUploadBytes = 1024 * 1024 * 1024,
    this.maxArchiveBytes = 256 * 1024 * 1024,
    this.maxSyncFiles = 50000,
    this.uploadTimeout = const Duration(minutes: 30),
    this.archiveTimeout = const Duration(minutes: 2),
    this.tarCommand = 'tar',
  });

  final TreeStore store;

  /// 未配置 `workspace_dir` 时的默认目录（CLI 传 `TreePaths.defaultWorkspaceDir`）。
  final String Function(String agentId) defaultWorkspaceDir;

  final void Function(String message)? log;
  final int maxListEntries;
  final int maxContentBytes;
  final Duration gitTimeout;

  /// 服务端定标的分片大小（随 `upload_init` 返回，前端按这个值切片）。
  final int chunkSize;

  /// 单文件上传上限（分片累计字节数）。
  final int maxUploadBytes;

  /// 目录打包下载的**未压缩**大小上限：超过就拒绝，避免把整个工作空间读进内存。
  final int maxArchiveBytes;

  /// 「同步到本地」允许复制的文件数上限。
  final int maxSyncFiles;

  /// 未完成的分片会话存活时间（超时即作废并清理暂存文件）。
  final Duration uploadTimeout;

  /// 打包命令超时。
  final Duration archiveTimeout;

  /// 打包命令（默认 `tar`：Windows 10+ 自带 bsdtar，Linux/macOS 也有；测试可注入）。
  final String tarCommand;

  /// 进行中的分片上传会话（`upload_id` → 会话）。
  final Map<String, _UploadSession> _uploads = <String, _UploadSession>{};

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

  /// 读取原始字节（单文件下载）：`{bytes, name}` 或 `{error, status}`。
  ///
  /// 与 [content] 的区别：这里不做文本/图片分支、不设文本上限，纯粹把字节交给
  /// 前端落盘（下载按钮）。
  Map<String, dynamic> readBytes(String workspaceId, String path) {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (agent.sshConfig != null) {
      return _error('该工作空间在远端（SSH）：暂不支持远端文件下载', 400);
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
    try {
      return <String, dynamic>{
        'bytes': file.readAsBytesSync(),
        'name': p.basename(absolute),
      };
    } catch (error) {
      return _error('读取文件失败：$error', 500);
    }
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

  // ── 写路径（M7d-3）：分片上传 / 同步到本地 / 目录打包下载 ────────────────

  /// 建立分片上传会话（`POST /api/files/{id}/upload_init`）。
  ///
  /// 契约与旧后端一致，前端 `ApiService.uploadFileChunked` 无需改动：
  /// 请求 `{file_name, rel_path, total_size}` → 响应 `{upload_id, chunk_size}`。
  ///
  /// 落点固定为 `.input/{yyyymmdd}/{rel_path}/{file_name}`（沿用旧后端与前端的
  /// 提示口径）。会话只在内存里：[uploadTimeout] 内没完成的会被丢弃并删掉暂存
  /// 文件；进程重启只会留下系统临时目录里的残片，不会污染工作空间。
  Future<Map<String, dynamic>> uploadInit(
    String workspaceId, {
    required String fileName,
    String relPath = '',
    int totalSize = 0,
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final Map<String, dynamic>? blocked = _remoteBlocked(agent, '文件上传');
    if (blocked != null) return blocked;
    if (totalSize < 0) return _error('total_size 不能为负', 400);
    if (totalSize > maxUploadBytes) {
      return _error(
        '文件过大（$fileName）：$totalSize 字节 > 上限 $maxUploadBytes 字节',
        413,
      );
    }
    final String? name = _safeSegment(fileName);
    if (name == null) return _error('file_name 非法：$fileName', 400);
    final String? sub = _safeSubPath(relPath);
    if (sub == null) return _error('rel_path 非法：$relPath', 400);
    final String rel = sub.isEmpty ? name : '$sub/$name';
    final String target = '.input/${_dateStamp()}/$rel';
    final String root = rootFor(agent);
    final String absolute;
    try {
      // 目标路径提前过一遍安全边界：等 complete 才失败会让用户白传一整个文件
      absolute = resolve(root, target);
    } on FileServiceException catch (error) {
      return _error(error.message, 400);
    }

    await _pruneUploads();
    final Directory staging;
    final RandomAccessFile sink;
    try {
      staging = await Directory.systemTemp.createTemp('tree_upload_');
      sink = await File(p.join(staging.path, 'part.bin'))
          .open(mode: FileMode.write);
    } catch (error) {
      return _error('创建分片暂存区失败：$error', 500);
    }
    final String uploadId = _newUploadId();
    _uploads[uploadId] = _UploadSession(
      uploadId: uploadId,
      agentId: agent.id,
      relativePath: target,
      absolutePath: absolute,
      stagingDir: staging.path,
      sink: sink,
      totalSize: totalSize,
    );
    log?.call('分片上传开始：$uploadId → $target（$totalSize 字节）');
    return <String, dynamic>{
      'upload_id': uploadId,
      'chunk_size': chunkSize,
      'path': target,
    };
  }

  /// 追加一个分片（`POST /api/files/{id}/upload_chunk`）。
  ///
  /// 请求 `{upload_id, index, data(base64)}` → `{received, index}`。分片必须按序
  /// 到达（index 从 0 递增）：定标分片 + 顺序追加本来就不需要随机写，而"缺口"
  /// 一旦被容忍就会静默产出一个坏文件，所以乱序直接 400。
  Future<Map<String, dynamic>> uploadChunk(
    String workspaceId, {
    required String uploadId,
    required int index,
    required String data,
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final _UploadSession? session = _uploads[uploadId];
    if (session == null || session.agentId != agent.id) {
      return _error('分片会话不存在或已过期', 404);
    }
    if (index < 0) return _error('index 不能为负', 400);
    if (index != session.nextIndex) {
      return _error('分片顺序错误：期望 ${session.nextIndex}，收到 $index', 400);
    }
    final List<int> bytes;
    try {
      bytes = base64.decode(data);
    } on FormatException catch (error) {
      return _error('data 不是合法 base64：${error.message}', 400);
    }
    if (session.received + bytes.length > session.totalSize) {
      return _error('分片超过声明的总大小 ${session.totalSize} 字节', 400);
    }
    try {
      await session.sink.writeFrom(bytes);
    } catch (error) {
      await _discardUpload(session);
      return _error('写入分片失败：$error', 500);
    }
    session.received += bytes.length;
    session.nextIndex++;
    session.touchedAt = DateTime.now();
    return <String, dynamic>{
      'received': true,
      'index': index,
      'received_bytes': session.received,
      'total_size': session.totalSize,
    };
  }

  /// 组装分片并落到 `.input/{日期}/`（`POST .../upload_complete`）。
  ///
  /// 只有分片收齐（数量与字节数都对得上）才会落盘，成功后删掉暂存目录；
  /// 空文件（`total_size = 0`、零分片）同样合法，会创建一个 0 字节文件。
  Future<Map<String, dynamic>> uploadComplete(
    String workspaceId, {
    required String uploadId,
    int? totalChunks,
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final _UploadSession? session = _uploads[uploadId];
    if (session == null || session.agentId != agent.id) {
      return _error('分片会话不存在或已过期', 404);
    }
    if (totalChunks != null && totalChunks != session.nextIndex) {
      return _error('分片不完整：已收到 ${session.nextIndex} 个，声明 $totalChunks 个', 400);
    }
    if (session.received != session.totalSize) {
      return _error(
        '分片不完整：已收到 ${session.received}/${session.totalSize} 字节',
        400,
      );
    }
    try {
      await session.sink.close();
    } catch (error) {
      await _discardUpload(session);
      return _error('关闭分片文件失败：$error', 500);
    }
    _uploads.remove(uploadId);
    final File staged = File(p.join(session.stagingDir, 'part.bin'));
    final File target = File(session.absolutePath);
    try {
      await target.parent.create(recursive: true);
      await _moveFile(staged, target);
    } catch (error) {
      await _deleteQuietly(Directory(session.stagingDir));
      return _error('保存文件失败：$error', 500);
    }
    await _deleteQuietly(Directory(session.stagingDir));
    log?.call('分片上传完成：${session.relativePath}（${session.received} 字节）');
    return <String, dynamic>{
      'success': true,
      'path': session.relativePath,
      'size': session.received,
    };
  }

  /// 把整棵工作空间复制到本机目录（`POST /api/files/{id}/syncToLocal`）。
  ///
  /// 桌面端核心与前端同机，所以这里是**直接复制**，不再走旧后端那套
  /// "容器内打包 → base64 → 前端解包"。语义与旧后端一致：保留相对层级、
  /// 覆盖同名文件、排除 `.git`、目标目录不存在则创建。
  ///
  /// 先做一遍有界统计再复制：超限时**一个文件都不写**，而不是复制一半才报错。
  Future<Map<String, dynamic>> syncToLocal(
    String workspaceId,
    String localPath,
  ) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final Map<String, dynamic>? blocked = _remoteBlocked(agent, '同步到本地');
    if (blocked != null) return blocked;
    final String raw = localPath.trim();
    if (raw.isEmpty) return _error('local_path 不能为空', 400);
    final String root = p.normalize(rootFor(agent));
    if (!Directory(root).existsSync()) {
      return _error('工作空间目录不存在：$root', 404);
    }
    final String target = p.normalize(p.absolute(raw));
    // 目标落在工作空间内部会"边写边遍历"（刚写入的文件又被下一次遍历读到）
    if (target == root || p.isWithin(root, target)) {
      return _error('目标目录不能是工作空间本身或它的子目录：$raw', 400);
    }
    final List<_WalkEntry> entries = _enumerate(root, Directory(root));
    if (entries.length > maxSyncFiles) {
      return _error(
        '工作空间文件过多（${entries.length} > $maxSyncFiles），请改用文件夹打包下载',
        413,
      );
    }
    final Set<String> created = <String>{};
    int copied = 0;
    int bytes = 0;
    try {
      for (final _WalkEntry entry in entries) {
        final String destination = p.joinAll(<String>[
          target,
          ...p.posix.split(entry.relativePath),
        ]);
        final String parent = p.dirname(destination);
        if (created.add(parent)) {
          await Directory(parent).create(recursive: true);
        }
        await File(entry.absolutePath).copy(destination);
        copied++;
        bytes += entry.size;
      }
    } catch (error) {
      return _error('同步失败（已复制 $copied 个文件）：$error', 500);
    }
    log?.call('同步到本地：$root → $target（$copied 个文件）');
    return <String, dynamic>{
      'success': true,
      'local_path': target,
      'files': copied,
      'bytes': bytes,
    };
  }

  /// 目录（或单文件）打包为 tar.gz（`POST .../download_folder`）。
  ///
  /// 用系统 `tar` 从 stdout 取压缩字节：Windows 10+ 自带 bsdtar、Linux/macOS 也有，
  /// 因此不必为了打包给纯 Dart 核心引入第三方依赖。`--exclude=.git` 由 tar 自己
  /// 递归生效（顶层与嵌套的 `.git` 都不会进包）。先有界统计未压缩大小，
  /// 超过 [maxArchiveBytes] 直接拒绝。
  Future<Map<String, dynamic>> archive(String workspaceId, String path) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final Map<String, dynamic>? blocked = _remoteBlocked(agent, '目录打包下载');
    if (blocked != null) return blocked;
    final String root = p.normalize(rootFor(agent));
    final String absolute;
    try {
      absolute = resolve(root, path, allowRoot: true);
    } on FileServiceException catch (error) {
      return _error(error.message, 400);
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(absolute);
    if (type == FileSystemEntityType.notFound) {
      return _error('目录不存在：${path.isEmpty ? '/' : path}');
    }
    final bool isDirectory = type == FileSystemEntityType.directory;
    if (!isDirectory && type != FileSystemEntityType.file) {
      return _error('不支持打包该类型：$path', 400);
    }
    final List<_WalkEntry> entries;
    if (isDirectory) {
      entries = _enumerate(root, Directory(absolute));
    } else {
      final int size = File(absolute).lengthSync();
      entries = <_WalkEntry>[
        _WalkEntry(
          absolutePath: absolute,
          relativePath: _relative(root, absolute),
          size: size,
        ),
      ];
    }
    final int total = entries.fold<int>(
      0,
      (int sum, _WalkEntry entry) => sum + entry.size,
    );
    if (total > maxArchiveBytes) {
      return _error(
        '目录过大（${total ~/ (1024 * 1024)} MB > 上限 '
        '${maxArchiveBytes ~/ (1024 * 1024)} MB），请分批下载',
        413,
      );
    }
    final String rel = path.trim().isEmpty ? '.' : _relative(root, absolute);
    final Directory temp;
    final File archiveFile;
    final ProcessResult result;
    try {
      // **让 tar 写临时文件、再整体读回**，不要从 stdout 取二进制：Windows 上
      // bsdtar 经管道写出的字节会被做 \n → \r\n 文本转换（实测），gzip 流直接
      // 损坏——这个坑只有真跑一次才会发现，所以测试按"能 gzip 解开"来断言。
      temp = await Directory.systemTemp.createTemp('tree_tar_');
      archiveFile = File(p.join(temp.path, 'out.tar.gz'));
      result = await Process.run(tarCommand, <String>[
        '-czf',
        archiveFile.path,
        '--exclude=.git',
        '-C',
        root,
        rel,
      ], stderrEncoding: utf8).timeout(archiveTimeout);
    } on ProcessException catch (error) {
      return _error('系统 $tarCommand 不可用：$error', 500);
    } catch (error) {
      return _error('打包失败：$error', 500);
    }
    if (result.exitCode != 0) {
      await _deleteQuietly(temp);
      return _error('打包失败：${_tail(result.stderr)}', 500);
    }
    try {
      final List<int> bytes = await archiveFile.readAsBytes();
      // gzip 魔数自检：宁可在核心报"打包结果异常"，也不要让用户存下一个坏压缩包
      if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
        return _error('打包结果不是 gzip（${bytes.length} 字节）：$tarCommand 行为异常', 500);
      }
      return <String, dynamic>{
        'bytes': bytes,
        'name': '${p.basename(absolute)}.tar.gz',
        'entries': entries.length,
        'size': bytes.length,
      };
    } catch (error) {
      return _error('读取打包结果失败：$error', 500);
    } finally {
      await _deleteQuietly(temp);
    }
  }

  /// 远端（SSH）工作空间的统一拒绝：读写远端文件需要 SFTP 二进制通道，
  /// 属于后续里程碑；这里给可读错误，而不是假装成功。
  Map<String, dynamic>? _remoteBlocked(CoreAgent agent, String feature) {
    if (agent.sshConfig == null) return null;
    return _error(
      '该工作空间在远端（SSH）：暂不支持$feature（需要 SFTP 二进制通道），'
      '请用终端工具或本地挂载盘',
      400,
    );
  }

  /// 枚举目录下所有文件（跳过 `.git` 与符号链接），相对路径统一用 `/` 分隔。
  List<_WalkEntry> _enumerate(String root, Directory dir) {
    final List<_WalkEntry> entries = <_WalkEntry>[];
    void walk(Directory current) {
      final List<FileSystemEntity> children;
      try {
        children = current.listSync(followLinks: false);
      } catch (error) {
        log?.call('遍历目录失败（${current.path}）：$error');
        return;
      }
      for (final FileSystemEntity entity in children) {
        final String name = p.basename(entity.path);
        if (name == '.git') continue;
        if (entity is Directory) {
          walk(entity);
        } else if (entity is File) {
          final int size;
          try {
            size = entity.lengthSync();
          } catch (error) {
            log?.call('读取文件大小失败（${entity.path}）：$error');
            continue;
          }
          entries.add(
            _WalkEntry(
              absolutePath: entity.path,
              relativePath: _relative(root, entity.path),
              size: size,
            ),
          );
        }
      }
    }

    walk(dir);
    return entries;
  }

  /// 丢弃超时未完成的分片会话（每次新建会话时顺手清理）。
  Future<void> _pruneUploads() async {
    final DateTime now = DateTime.now();
    for (final _UploadSession session in _uploads.values.toList()) {
      if (now.difference(session.touchedAt) <= uploadTimeout) continue;
      _uploads.remove(session.uploadId);
      log?.call('分片上传超时作废：${session.uploadId}');
      await _discardUpload(session);
    }
  }

  /// 关掉会话的文件句柄并删掉暂存目录（幂等，失败不抛）。
  Future<void> _discardUpload(_UploadSession session) async {
    try {
      await session.sink.close();
    } catch (_) {
      // 已关闭或写入失败：这里只关心把暂存目录删掉
    }
    await _deleteQuietly(Directory(session.stagingDir));
  }

  /// 删除目录，失败静默（Windows 上句柄释放有延迟，残片留给系统临时目录清理）。
  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // 见上：不作为错误上报
    }
  }

  /// 把暂存文件移到目标位置；跨卷（系统临时目录 → 工作空间）时退回复制。
  static Future<void> _moveFile(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      await source.copy(target.path);
    }
  }

  /// 32 位十六进制 upload_id（与旧后端 uuid4().hex 的形状一致）。
  static String _newUploadId() {
    final Random random = Random.secure();
    return List<String>.generate(
      16,
      (int _) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// 日期目录名（`yyyymmdd`，与旧后端一致）。
  static String _dateStamp([DateTime? now]) {
    final DateTime time = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}';
  }

  /// 校验单个文件名（不含分隔符）；非法返回 null。
  static String? _safeSegment(String raw) {
    final String name = raw.trim();
    if (name.isEmpty || name == '.' || name == '..') return null;
    if (name.contains('/') || name.contains('\\')) return null;
    if (RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name)) return null;
    return name;
  }

  /// 校验相对子目录（`a/b`）：非法返回 null，空串或 `.` 返回 `''`。
  static String? _safeSubPath(String raw) {
    final String normalized = raw.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized == '.') return '';
    if (normalized.startsWith('~') ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      return null;
    }
    final List<String> segments = <String>[];
    for (final String segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      final String? safe = _safeSegment(segment);
      if (safe == null) return null;
      segments.add(safe);
    }
    return segments.join('/');
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

/// 一个进行中的分片上传会话（进程内内存态，重启即失效）。
class _UploadSession {
  _UploadSession({
    required this.uploadId,
    required this.agentId,
    required this.relativePath,
    required this.absolutePath,
    required this.stagingDir,
    required this.sink,
    required this.totalSize,
  });

  final String uploadId;
  final String agentId;

  /// 工作空间内相对路径（`.input/yyyymmdd/...`，落盘与回包都用它）。
  final String relativePath;

  /// 目标绝对路径（已过 [FileService.resolve] 边界检查）。
  final String absolutePath;

  /// 系统临时目录里的暂存目录。
  final String stagingDir;

  /// 顺序追加写的句柄。
  final RandomAccessFile sink;

  /// 前端声明的文件总大小。
  final int totalSize;

  /// 已写入字节数。
  int received = 0;

  /// 下一个期望的分片下标。
  int nextIndex = 0;

  /// 最后一次活动时刻（用于超时清理）。
  DateTime touchedAt = DateTime.now();
}

/// 遍历到的一个文件（打包与同步共用）。
class _WalkEntry {
  const _WalkEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.size,
  });

  final String absolutePath;
  final String relativePath;
  final int size;
}

/// 文件服务的可读错误。
class FileServiceException implements Exception {
  FileServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
