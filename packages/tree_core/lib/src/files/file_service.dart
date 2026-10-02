import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/tree_store.dart';
import '../team/team_workspace.dart';

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
/// - 写文本（M10）：`writeContent`（`PUT /api/files/{id}/content`）：源码编辑器保存，
///   本机与 SSH 都走工作空间 IO 抽象按 UTF-8 覆盖写，并保留换行风格；
/// - **本机与 SSH 都要支持**（M7g）：配了 `ssh:` 的 agent 走 [remoteFilesFor] 拿到
///   [WorkspaceFiles]（SFTP 实现），本机走 dart:io；两条路径共用同一套安全边界与
///   REST 语义。远端上传仍然是"本地暂存分片 → complete 时一次 SFTP 写"（不需要
///   远端追加写）；远端 `archive` 是"先把子树拉回本地临时目录，再用本地 tar 打包"
///   （远端不一定有 tar，且这样只需一条代码路径）；
/// - **远端 Git 也支持**（M9 Q4）：SSH agent 的 `gitLog`/`gitBranches` 经 [WorkspaceIO]
///   的 exec 通道跑 git（命令与解析在 `tree_local_exec` 的 GitOutput 里，与本地共用），
///   非仓库 / 远端没有 git 时返回空列表 + 退出码，面板显示空态而不是 400；
/// - PDF 预览：M7e 起由**前端**渲染（核心只给字节），因此这里没有 `pdf_preview`。
class FileService {
  FileService({
    required this.store,
    required this.defaultWorkspaceDir,
    this.log,
    this.remoteFilesFor,
    this.ioFor,
    this.maxListEntries = 2000,
    this.maxContentBytes = 8 * 1024 * 1024,
    this.maxWriteBytes = defaultMaxWriteBytes,
    this.gitTimeout = const Duration(seconds: 10),
    this.chunkSize = 4 * 1024 * 1024,
    this.maxArchiveBytes = 256 * 1024 * 1024,
    this.maxSyncFiles = 50000,
    this.maxSyncBytes = 2 * 1024 * 1024 * 1024,
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

  /// 「按内容写文件」允许的**新内容**上限（UTF-8 字节数），默认 4 MB。
  ///
  /// 源码编辑器保存是"整段内容一次写"（内容已在内存里），必须有上限才不会
  /// 被一个误操作的文件塞爆内存；更大的文件请走分片上传那条通道。
  static const int defaultMaxWriteBytes = 4 * 1024 * 1024;
  final int maxWriteBytes;

  /// 拒绝按文本写回的扩展名：图片 / PDF / Office / 压缩包。
  ///
  /// 与前端 `lib/ui/widgets/attachment_preview.dart` 的口径一致——那些类型在
  /// 前端本来就不当文本呈现，核心更不该把它们当文本覆盖写（保存一次就毁掉原文件）。
  static const Set<String> nonTextExtensions = <String>{
    // 图片
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'ico',
    'tif',
    'tiff',
    // PDF
    'pdf',
    // Office
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    // 压缩包
    'zip',
    'rar',
    '7z',
    'tar',
    'gz',
    'bz2',
    'xz',
  };

  /// 二进制探测的头部长度：与前端 `attachment_preview.dart` 的 `_looksBinary`
  /// 同口径（前 4 KB 里出现 NUL 就当二进制）。
  static const int binaryProbeBytes = 4096;

  final Duration gitTimeout;

  /// 服务端定标的分片大小（随 `upload_init` 返回，前端按这个值切片）。
  final int chunkSize;

  /// 目录打包下载的**未压缩**大小上限：超过就拒绝，避免把整个工作空间读进内存。
  final int maxArchiveBytes;

  /// 「同步到本地」允许复制的文件数上限。
  final int maxSyncFiles;

  /// 「同步到本地」允许复制的总字节上限。
  ///
  /// 光有条数上限挡不住"目录不大但每个文件都巨大"（远端根甚至可能是整个数据盘），
  /// 真机验收时就在一个巨大的远端根上把 3 分钟测试跑超时了——先统计再决定要不要拉。
  final int maxSyncBytes;

  /// 未完成的分片会话存活时间（超时即作废并清理暂存文件）。
  final Duration uploadTimeout;

  /// 打包命令超时。
  final Duration archiveTimeout;

  /// 打包命令（默认 `tar`：Windows 10+ 自带 bsdtar，Linux/macOS 也有；测试可注入）。
  final String tarCommand;

  /// 取某 agent 的**远端后端**（M7g → M9 Q4）；null = 该 agent 的工作空间不在远端，
  /// 或核心没接线（此时远端 agent 会拿到可读 400 而不是假装成功）。
  ///
  /// 返回类型是 [Object] 而不是 [WorkspaceFiles]：SSH 后端（`SshWorkspaceIO`）同时
  /// 实现了 [WorkspaceFiles]（文件面板）与 [WorkspaceIO]（Git 面板要经它跑 exec），
  /// 两者是**同一个连接对象**。宽类型让调用方各取所需地窄化（[remoteFor] /
  /// [remoteIoFor]），既不必为 Git 再建一条连接，也不必再加一个工厂。
  final Future<Object?> Function(String agentId)? remoteFilesFor;

  /// 取某 agent 的**工作空间 IO**（M9 Q4：远端 Git 经它跑 git）。
  ///
  /// 两条路都行：显式传 `ioFor`（CLI 里就是 `tools.ioFor`）最直白；不传时从
  /// [remoteFilesFor] 返回的同一个 SSH 连接对象按运行期类型窄化（`SshWorkspaceIO`
  /// 同时实现两个接口）。都拿不到就返回可读 400，不假装成功。
  final Future<WorkspaceIO?> Function(String agentId)? ioFor;

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
  ///
  /// 成员跟随团队 TOP 的目录（[TeamWorkspace]，2026-10-02 定夺）：成员不再各自
  /// `workspaces/<member_id>`。TOP 自身口径不变（owner == 它自己）。
  String rootFor(CoreAgent agent) {
    final TeamWorkspace shared = teamWorkspaceFor(agent, store.agent);
    return shared.configuredDir.isNotEmpty
        ? shared.configuredDir
        : defaultWorkspaceDir(shared.owner.id);
  }

  /// 取该 agent 的远端文件面板后端；本机 agent 恒为 null。
  ///
  /// 为什么要 await：SSH 连接是懒建的（首次用到才连），与工具层共用同一个
  /// `ioFor` 工厂，避免"文件面板一条连接、工具又一条"。
  Future<WorkspaceFiles?> remoteFor(CoreAgent agent) async {
    final Object? backend = await _remoteBackendFor(agent);
    return backend is WorkspaceFiles ? backend : null;
  }

  /// 取该 agent 的远端**工作空间 IO**（M9 Q4：远端 Git 面板经它跑 git）。
  ///
  /// 本机 agent 恒为 null（本机 Git 直接 `Process.run`）；远端后端不是 [WorkspaceIO]
  /// 时也返回 null，由调用方给可读 400 而不是假装成功。
  Future<WorkspaceIO?> remoteIoFor(CoreAgent agent) async {
    final Future<WorkspaceIO?> Function(String agentId)? explicit = ioFor;
    if (explicit != null) return explicit(agent.id);
    final Object? backend = await _remoteBackendFor(agent);
    return backend is WorkspaceIO ? backend : null;
  }

  /// 该 agent 的文件/工具**实际**跑在远端吗？判据是**有效 SSH**（[teamSshConfigFor]：
  /// 成员自己没有 `ssh:` 时跟随团队 TOP），不是 `agent.sshConfig`。
  ///
  /// 为什么不能只看 agent 自己那份：SSH leader 的成员自己那份是空的，只看它会把成员的
  /// 文件面板判成"本机"——而它的工具其实在远端跑（成员跟随 leader 的 SSH 是团队不变量，
  /// 见 team/README.md 不变量 3），于是面板会拿一个**远端路径**去本机找目录：要么报一个
  /// 莫名其妙的"目录不存在"，要么读到本机同名路径（更糟）。
  bool _isRemote(CoreAgent agent) =>
      teamSshConfigFor(agent, store.agent) != null;

  /// 远端后端对象（未窄化）：[remoteFor] / [remoteIoFor] 各自按需窄化。
  Future<Object?> _remoteBackendFor(CoreAgent agent) async {
    if (!_isRemote(agent)) return null;
    final Future<Object?> Function(String agentId)? factory = remoteFilesFor;
    if (factory == null) return null;
    return factory(agent.id);
  }

  /// 列出目录（`path` 为空 = 根）。目录在前，各自按名字排序。
  Future<Map<String, dynamic>> list(
    String workspaceId, {
    String path = '',
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (remote != null) return _listRemote(remote, path);
    if (_isRemote(agent)) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端，请用终端工具查看', 400);
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

  /// 远端目录列举（M7g）：与本地同一份 JSON 形状，前端零改动。
  Future<Map<String, dynamic>> _listRemote(
    WorkspaceFiles remote,
    String path,
  ) async {
    final List<WorkspaceEntry> entries;
    try {
      entries = await remote.listEntries(path, maxEntries: maxListEntries);
    } on WorkspacePathException catch (error) {
      return _error(error.toString(), 400);
    } on WorkspaceIoException catch (error) {
      // 目录不存在/无权限：与本地实现同样报 404，前端提示口径一致
      return _error(error.message, 404);
    } catch (error) {
      return _error('读取远端目录失败：$error', 500);
    }
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[
      for (final WorkspaceEntry entry in entries)
        <String, dynamic>{
          'name': entry.name,
          'size': entry.isDirectory ? 0 : entry.size,
          'type': entry.isDirectory ? 'dir' : 'file',
          'modified': entry.modified?.toIso8601String() ?? '',
          'path': entry.relativePath,
        },
    ];
    return <String, dynamic>{
      'files': files,
      'path': path,
      'total': files.length,
      if (files.length >= maxListEntries) 'truncated': true,
    };
  }

  /// 远端文件内容（图片 base64，其余文本）。
  Future<Map<String, dynamic>> _contentRemote(
    WorkspaceFiles remote,
    String path,
  ) async {
    final int size;
    final Uint8List bytes;
    try {
      // 先问大小：超过预览上限就只读前一段，别为了一次预览把整文件拉回来（M8c）
      size = await remote.sizeOf(path);
      bytes = size > maxContentBytes
          ? await _collect(
              remote.openRead(path, offset: 0, length: maxContentBytes),
            )
          : await remote.readBytes(path);
    } on WorkspacePathException catch (error) {
      return _error(error.toString(), 400);
    } on WorkspaceIoException catch (error) {
      return _error(error.message, 404);
    } catch (error) {
      return _error('读取远端文件失败：$error', 500);
    }
    final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return _previewJson(path, bytes, size: size, extension: ext);
  }

  /// 远端原始字节下载。
  Future<Map<String, dynamic>> _readBytesRemote(
    WorkspaceFiles remote,
    String path,
  ) async {
    try {
      final Uint8List bytes = await remote.readBytes(path);
      return <String, dynamic>{'bytes': bytes, 'name': p.posix.basename(path)};
    } on WorkspacePathException catch (error) {
      return _error(error.toString(), 400);
    } on WorkspaceIoException catch (error) {
      return _error(error.message, 404);
    } catch (error) {
      return _error('读取远端文件失败：$error', 500);
    }
  }

  /// 远端 PDF 基本信息：读回字节后走与本地同一套启发式解析。
  Future<Map<String, dynamic>> _pdfInfoRemote(
    WorkspaceFiles remote,
    String path,
  ) async {
    try {
      final int size = await remote.sizeOf(path);
      if (size <= _pdfFullReadBytes) {
        return pdfInfoFromBytes(await remote.readBytes(path));
      }
      final List<int> head = await _collect(
        remote.openRead(path, offset: 0, length: _pdfHeadBytes),
      );
      final List<int> tail = await _collect(
        remote.openRead(
          path,
          offset: size - _pdfTailBytes,
          length: _pdfTailBytes,
        ),
      );
      return pdfInfoFromSlices(head, tail);
    } on WorkspacePathException catch (error) {
      return _error(error.toString(), 400);
    } on WorkspaceIoException catch (error) {
      return _error(error.message, 404);
    } catch (error) {
      return _error('读取远端文件失败：$error', 500);
    }
  }

  /// 字节 → 前端文件内容 JSON（图片 base64，其余文本解码）。
  static Map<String, dynamic> _contentJson(
    String path,
    List<int> bytes, {
    String extension = '',
  }) {
    if (LocalWorkspaceIO.imageExtensions.contains(extension)) {
      return <String, dynamic>{
        'content': base64Encode(bytes),
        'path': path,
        'size': bytes.length,
        'encoding': 'base64',
      };
    }
    return <String, dynamic>{
      'content': LocalWorkspaceIO.decodeBytes(bytes),
      'path': path,
      'size': bytes.length,
      'encoding': 'utf-8',
    };
  }

  /// 大文件预览 JSON：内容只回传前一段，但**如实标注**真实大小与截断（M8c）。
  ///
  /// 为什么不再 413：单文件在用户自己的桌面/远端盘上，一个"看不了"的硬上限只会
  /// 逼用户去开终端。前端拿到 `truncated` 后提示"仅预览前 N MB，完整内容请下载"，
  /// 下载那条路走流式、不设上限。
  static Map<String, dynamic> _previewJson(
    String path,
    List<int> bytes, {
    required int size,
    required String extension,
  }) {
    return <String, dynamic>{
      ..._contentJson(path, bytes, extension: extension),
      'size': size,
      'truncated': size > bytes.length,
      if (size > bytes.length) 'preview_bytes': bytes.length,
    };
  }

  /// 把（已显式限长的）字节流收进内存。
  static Future<Uint8List> _collect(Stream<List<int>> stream) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 按**完整文本**覆盖写一个文件（PUT /api/files/{id}/content?path=）。
  ///
  /// 前端源码编辑器保存用：请求体给整段内容，这里按工作空间相对路径覆盖写。
  /// 落盘一律走已有的**工作空间 IO 抽象**（本机 LocalWorkspaceIO、远端
  /// remoteIoFor 拿到的 WorkspaceIO），不自己写盘、不自己起 ssh。
  ///
  /// 语义：
  /// - 路径守卫与读路径同一口径（[resolve]）：空 / 绝对路径 / 盘符 / ~ / .. 逃逸一律 400；
  /// - 新内容按 **UTF-8** 编码写；换行风格**原样保留**（不把 CRLF 规范化成 LF、不补尾换行）；
  /// - 图片 / PDF / Office / 压缩包按扩展名拒绝；现有文件头部出现 NUL 也拒绝
  ///   （与前端 attachment_preview.dart 同一口径：不是纯文本，写回去只会损坏它）；
  /// - 新内容超过 [maxWriteBytes] 拒绝（整段内容一次写，更大的文件走分片上传）；
  /// - [ifSize]（前端加载时看到的字节数）与当前字节数不符 → **409 冲突** + 当前 size，
  ///   目标文件已不存在同样算冲突；[force] 为 true 时跳过该检查；
  /// - 远端取不到可用的 SSH 工作空间 IO 时可读 400，**绝不假装成功**。
  Future<Map<String, dynamic>> writeContent(
    String workspaceId, {
    required String path,
    required String content,
    int? ifSize,
    bool force = false,
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');

    final String root = rootFor(agent);

    // 1) 路径守卫（与读路径同一口径）：越界 / 空路径一律 400
    final String absolute;
    try {
      absolute = resolve(root, path);
    } on FileServiceException catch (error) {
      return _writeError('invalid_path', error.message);
    }
    final String relative = _relative(root, absolute);

    // 2) 扩展名黑名单：图片 / PDF / Office / 压缩包一律不是文本
    final String ext = p.extension(absolute).replaceFirst('.', '').toLowerCase();
    if (nonTextExtensions.contains(ext)) {
      return _writeError('not_text', '该文件不是纯文本（.$ext），不能作为文本保存：$path');
    }

    // 3) 新内容上限：按 UTF-8 字节数判断（写进去的就是这些字节）
    final int newBytes = utf8.encode(content).length;
    if (newBytes > maxWriteBytes) {
      final String over = _mbText(newBytes);
      final String limit = _mbText(maxWriteBytes);
      return _writeError(
        'too_large',
        '内容过大（$over > 上限 $limit），请改用上传通道保存：$path',
      );
    }

    // 4) 选后端：远端走 remoteIoFor（拿不到就如实 400），本机用本机 IO
    final bool remote = _isRemote(agent);
    final WorkspaceIO io;
    if (remote) {
      final WorkspaceIO? remoteIo = await remoteIoFor(agent);
      if (remoteIo == null) {
        return _writeError(
          'remote_unavailable',
          '该工作空间在远端（SSH）：核心未接入远端文件后端（工作空间 IO 不可用），无法保存',
        );
      }
      io = remoteIo;
    } else {
      io = LocalWorkspaceIO(root);
    }

    // 5) 探测现有文件（大小 + 头部）：只为判冲突与二进制，不参与落盘。
    //    SSH 后端同时实现 WorkspaceFiles，复用同一个连接对象，不再建第二条连接。
    WorkspaceFiles? probe;
    if (remote) {
      // SSH 后端同时实现两个接口：能从 IO 对象窄化就用它，别用另一个可能
      // 指向不同后端的 remoteFor 结果去探测。
      final Object backend = io;
      probe = backend is WorkspaceFiles ? backend : await remoteFor(agent);
    }
    final _ExistingFile existing = remote
        ? await _probeRemote(probe, relative)
        : _probeLocal(File(absolute));

    // 6) 冲突：if_size 与当前字节数不符（目标已不存在也算）→ 409 + 当前 size
    if (ifSize != null && !force) {
      if (!existing.known) {
        // 只能接 WorkspaceIO、没有 WorkspaceFiles 的远端后端：不知道就别撒谎说
        // 冲突，但也绝不静默放过——如实 400（可读原因）。
        return _writeError(
          'probe_unavailable',
          '远端文件后端不完整，无法校验文件是否被外部修改；请刷新后重试：$path',
        );
      }
      if (!existing.exists) {
        // 文件已不存在：**不带 size**——前端 FileWriteConflict 以 size 缺失
        // （currentSize == null）判定 missing，带了 0 会被当成「存在且为空文件」。
        return _writeError(
          'conflict',
          '文件已不存在，请刷新后再保存：$path',
          status: 409,
        );
      }
      if (existing.size != ifSize) {
        return _writeError(
          'conflict',
          '文件已被外部修改，请刷新后再保存',
          status: 409,
          size: existing.size,
        );
      }
    }

    // 7) 现有文件头部含 NUL = 二进制，拒绝按文本覆盖
    if (existing.exists && _hasNul(existing.head)) {
      return _writeError('not_text', '该文件不是纯文本（含 NUL），不能作为文本保存：$path');
    }

    // 8) 落盘：工作空间 IO 抽象（本机 / 远端同一份实现），UTF-8、换行原样
    final int written;
    try {
      written = await io.writeFile(relative, content);
    } on WorkspacePathException catch (error) {
      final String reason = error.reason;
      return _writeError('invalid_path', '$reason：$path');
    } on WorkspaceIoException catch (error) {
      final String message = error.message;
      return _writeError('write_failed', '保存失败：$message');
    } catch (error) {
      return _writeError('write_failed', '保存失败：$error', status: 500);
    }
    log?.call('保存文本文件：$relative（$written 字节）');
    return <String, dynamic>{
      'success': true,
      'path': relative,
      'size': written,
      'written': written,
    };
  }

  /// 读取文件内容：图片返回 base64，其余按文本解码（UTF-8 失败退 latin1）。
  Future<Map<String, dynamic>> content(String workspaceId, String path) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (remote != null) return _contentRemote(remote, path);
    if (_isRemote(agent)) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端，请用 read 工具', 400);
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
    final String ext = p
        .extension(absolute)
        .replaceFirst('.', '')
        .toLowerCase();
    final List<int> bytes;
    try {
      if (size > maxContentBytes) {
        // 大文件只读预览那一段：先问大小再读，不再"读完再 413"（M8c）
        final RandomAccessFile raf = await file.open();
        try {
          bytes = await raf.read(maxContentBytes);
        } finally {
          await raf.close();
        }
      } else {
        bytes = await file.readAsBytes();
      }
    } catch (error) {
      return _error('读取文件失败：$error', 500);
    }
    return _previewJson(path, bytes, size: size, extension: ext);
  }

  /// 读取原始字节（单文件下载）：`{bytes, name}` 或 `{error, status}`。
  ///
  /// 与 [content] 的区别：这里不做文本/图片分支、不设文本上限，纯粹把字节交给
  /// 前端落盘（下载按钮）。
  Future<Map<String, dynamic>> readBytes(
    String workspaceId,
    String path,
  ) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (remote != null) return _readBytesRemote(remote, path);
    if (_isRemote(agent)) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端，请用 read 工具', 400);
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

  /// 单文件**流式**下载（M8c）：返回字节流 + 文件名 + 大小。
  ///
  /// 与 [readBytes] 的区别：那个把整个文件读进内存（`/download` 的兼容路径）；
  /// 这里把流直接交给 HTTP 响应，本地文件与远端 SFTP 都不设大小上限，
  /// 内存占用只与块大小有关。
  Future<Map<String, dynamic>> openDownload(
    String workspaceId,
    String path,
  ) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (remote != null) {
      try {
        final int size = await remote.sizeOf(path);
        return <String, dynamic>{
          'stream': remote.openRead(path),
          'name': p.posix.basename(path),
          'size': size,
        };
      } on WorkspacePathException catch (error) {
        return _error(error.toString(), 400);
      } on WorkspaceIoException catch (error) {
        return _error(error.message, 404);
      } catch (error) {
        return _error('读取远端文件失败：$error', 500);
      }
    }
    if (_isRemote(agent)) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端，请用 read 工具', 400);
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
    return <String, dynamic>{
      'stream': file.openRead(),
      'name': p.basename(absolute),
      'size': file.lengthSync(),
    };
  }

  /// PDF 基本信息（总页数 / 标题 / 作者）。
  ///
  /// **页数是启发式的**：优先取页树 `/Count` 的最大值（根节点即总数），取不到
  /// 再数 `/Type /Page` 的出现次数。返回值里带 `pages_source` 说明来源，不假装
  /// 这是权威解析（真正的解析器需要引入 PDF 库，属于待决策项）。
  Future<Map<String, dynamic>> pdfInfo(String workspaceId, String path) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (remote != null) return _pdfInfoRemote(remote, path);
    if (_isRemote(agent)) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端', 400);
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
    if (size <= _pdfFullReadBytes) {
      return pdfInfoFromBytes(file.readAsBytesSync());
    }
    // 大 PDF 只读头尾（M8c）：整读几百 MB 只为看页数/标题不值得
    final RandomAccessFile raf = await file.open();
    try {
      final List<int> head = await raf.read(_pdfHeadBytes);
      await raf.setPosition(size - _pdfTailBytes);
      final List<int> tail = await raf.read(_pdfTailBytes);
      return pdfInfoFromSlices(head, tail);
    } on FileSystemException catch (error) {
      return _error('读取 PDF 失败：$error', 500);
    } finally {
      await raf.close();
    }
  }

  /// PDF 基本信息（总页数 / 标题 / 作者）——**页数是启发式的**。
  ///
  /// 本地与远端共用（远端先把字节读回来）：优先取页树 `/Count` 的最大值（根节点
  /// 即总数），取不到再数 `/Type /Page` 的出现次数；`pages_source` 说明来源，
  /// 不假装这是权威解析（真正的解析器要引入 PDF 库）。
  static Map<String, dynamic> pdfInfoFromBytes(List<int> bytes) {
    final String text = latin1.decode(bytes, allowInvalid: true);
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

  /// 大 PDF 的启发式信息：只拿头尾两段解析（M8c）。
  ///
  /// 页数本来就是启发式（见 [pdfInfoFromBytes]），为它整读一个几百 MB 的文件
  /// 不划算；头尾覆盖了线性化文件的 xref（头部）与多数文件的 trailer/Info（尾部）。
  /// `scanned` 字段如实标注只扫了头尾，不假装修过整份文档。
  static Map<String, dynamic> pdfInfoFromSlices(
    List<int> head,
    List<int> tail,
  ) {
    return <String, dynamic>{
      ...pdfInfoFromBytes(<int>[...head, ...tail]),
      'scanned': 'head+tail',
    };
  }

  /// 小 PDF 直接整读；超过这个值就走头尾扫描。
  static const int _pdfFullReadBytes = 4 * 1024 * 1024;
  static const int _pdfHeadBytes = 64 * 1024;
  static const int _pdfTailBytes = 512 * 1024;

  /// Git 提交历史（`GET /api/workspaces/{id}/git/log`）。
  ///
  /// 本机直接 `Process.run`；SSH agent 经 [WorkspaceIO] 的 exec 通道（M9 Q4），
  /// 返回体保持既有的 `{commits: [{hash, author, date, message}]}` 形状。
  Future<Map<String, dynamic>> gitLog(
    String workspaceId, {
    int limit = 50,
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (_isRemote(agent)) return _gitLogRemote(agent, limit);
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
  ///
  /// 返回体保持既有的 `{branches: [{name: ...}], current}` 形状（前端 `git_history.dart`
  /// 与 `files_api_test.dart` 都按这个断言）。
  Future<Map<String, dynamic>> gitBranches(String workspaceId) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    if (_isRemote(agent)) return _gitBranchesRemote(agent);
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

  /// 远端（SSH）Git 历史（M9 Q4）：经该 agent 的 [WorkspaceIO] exec 通道跑 git。
  ///
  /// 非仓库 / 远端没有 git 时 [GitLogOutcome] 是**空列表 + 退出码**（执行层不抛异常），
  /// 面板显示空态——这正是 Q4 要修的行为（以前一律 400）。
  Future<Map<String, dynamic>> _gitLogRemote(CoreAgent agent, int limit) async {
    final WorkspaceIO? io = await remoteIoFor(agent);
    if (io == null) {
      return _error('该工作空间在远端（SSH）：核心未接入远端 Git 后端（工作空间 IO 不可用）', 400);
    }
    final GitLogOutcome outcome;
    try {
      outcome = await io.gitLog(limit: limit);
    } on WorkspaceIoException catch (error) {
      // 链路失活/读失败必须显式报错，不能返回空列表——空列表会被误读成「仓库没有提交」
      return _error('读取远端 Git 历史失败：${error.message}', 500);
    } catch (error) {
      return _error('读取远端 Git 历史失败：$error', 500);
    }
    return <String, dynamic>{
      'commits': outcome.commits.map((GitCommit c) => c.toJson()).toList(),
    };
  }

  /// 远端（SSH）Git 分支（M9 Q4）。
  Future<Map<String, dynamic>> _gitBranchesRemote(CoreAgent agent) async {
    final WorkspaceIO? io = await remoteIoFor(agent);
    if (io == null) {
      return _error('该工作空间在远端（SSH）：核心未接入远端 Git 后端（工作空间 IO 不可用）', 400);
    }
    final GitBranchesOutcome outcome;
    try {
      outcome = await io.gitBranches();
    } on WorkspaceIoException catch (error) {
      return _error('读取远端 Git 分支失败：${error.message}', 500);
    } catch (error) {
      return _error('读取远端 Git 分支失败：$error', 500);
    }
    return <String, dynamic>{
      // REST 形状照旧：branches 是 [{name: ...}]（不是 GitBranchesOutcome 的字符串数组），
      // 前端 git_history.dart 两种都认，但 files_api_test 与既有前端按对象形态取用
      'branches': <Map<String, dynamic>>[
        for (final String name in outcome.branches)
          <String, dynamic>{'name': name},
      ],
      'current': outcome.current,
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
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (_isRemote(agent) && remote == null) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端', 400);
    }
    if (totalSize < 0) return _error('total_size 不能为负', 400);
    final String? name = _safeSegment(fileName);
    if (name == null) return _error('file_name 非法：$fileName', 400);
    final String? sub = _safeSubPath(relPath);
    if (sub == null) return _error('rel_path 非法：$relPath', 400);
    final String rel = sub.isEmpty ? name : '$sub/$name';
    final String target = '.input/${_dateStamp()}/$rel';
    final String root = rootFor(agent);
    final String absolute;
    if (remote != null) {
      // 远端：分片仍暂存在本机，complete 时一次 SFTP 写过去（远端不需要追加写）。
      // 目标路径已由 _safeSubPath/_safeSegment 校验，且远端根由工作空间 IO 约束，
      // 因此这里不需要（也不能）用本机根目录去 resolve。
      absolute = '';
    } else {
      try {
        // 目标路径提前过一遍安全边界：等 complete 才失败会让用户白传一整个文件
        absolute = resolve(root, target);
      } on FileServiceException catch (error) {
        return _error(error.message, 400);
      }
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
      remote: remote != null,
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
    try {
      if (session.remote) {
        final WorkspaceFiles? remote = await remoteFor(agent);
        if (remote == null) {
          throw StateError('远端文件后端不可用（连接可能已断开）');
        }
        // 流式写：分片暂存文件边读边推给 SFTP，本机不再把整个文件读进内存（M8c）
        await remote.writeStream(session.relativePath, staged.openRead());
      } else {
        final File target = File(session.absolutePath);
        await target.parent.create(recursive: true);
        await _moveFile(staged, target);
      }
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

  /// 把工作空间（或其中一棵子树）复制到本机目录
  /// （`POST /api/files/{id}/syncToLocal`）。
  ///
  /// 桌面端核心与前端同机，所以这里是**直接复制**，不再走旧后端那套
  /// "容器内打包 → base64 → 前端解包"。语义：保留相对层级、覆盖同名文件、
  /// 排除 `.git`、目标目录不存在则创建。
  ///
  /// M8b：支持 [path]（工作空间相对路径，空 = 根）。文件面板逐层懒加载，
  /// 因此同步的是**用户当前所在的那一层**，不再默认整棵根——真机验收时在
  /// 巨大远端根上"同步整棵树"曾被拖到超时。
  ///
  /// 遍历**边走边复制**：不再先全树统计一遍再复制。上限只作兜底，超限时报告
  /// 已复制的进度（而不是安静地走完整棵树再拒绝）。
  Future<Map<String, dynamic>> syncToLocal(
    String workspaceId,
    String localPath, {
    String path = '',
  }) async {
    final CoreAgent? agent = agentFor(workspaceId);
    if (agent == null) return _error('工作空间不存在：$workspaceId');
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (_isRemote(agent) && remote == null) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端', 400);
    }
    final String raw = localPath.trim();
    if (raw.isEmpty) return _error('local_path 不能为空', 400);
    final String target = p.normalize(p.absolute(raw));
    // 远端工作空间：本机目录不可能"落在远端工作空间内部"，直接拉取
    if (remote != null) return _syncRemoteToLocal(remote, target, path: path);
    final String root = p.normalize(rootFor(agent));
    if (!Directory(root).existsSync()) {
      return _error('工作空间目录不存在：$root', 404);
    }
    // 目标落在工作空间内部会"边写边遍历"（刚写入的文件又被下一次遍历读到）
    if (target == root || p.isWithin(root, target)) {
      return _error('目标目录不能是工作空间本身或它的子目录：$raw', 400);
    }
    final String source;
    try {
      source = resolve(root, path, allowRoot: true);
    } on FileServiceException catch (error) {
      return _error(error.message, 400);
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.notFound) {
      return _error('目录不存在：${path.isEmpty ? '/' : path}');
    }
    final _CopyCounters counters = _CopyCounters(
      maxFiles: maxSyncFiles,
      maxBytes: maxSyncBytes,
    );
    try {
      if (type == FileSystemEntityType.directory) {
        await _copyLocalTree(Directory(source), root, target, counters);
      } else {
        await _copyLocalFile(
          File(source),
          _relative(root, source),
          target,
          counters,
        );
      }
    } catch (error) {
      return _error('同步失败（已复制 ${counters.files} 个文件）：$error', 500);
    }
    if (counters.limitHit) return _limitError('同步', counters);
    log?.call('同步到本地：$source → $target（${counters.files} 个文件）');
    return <String, dynamic>{
      'success': true,
      'local_path': target,
      'path': path,
      'files': counters.files,
      'bytes': counters.bytes,
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
    final WorkspaceFiles? remote = await remoteFor(agent);
    if (_isRemote(agent) && remote == null) {
      return _error('该工作空间在远端（SSH）：核心未接入远端文件后端', 400);
    }
    if (remote != null) return _archiveRemote(remote, path);
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
    return _tarGz(
      root: root,
      rel: rel,
      name: '${p.basename(absolute)}.tar.gz',
      entries: entries.length,
    );
  }

  /// 跑一次本地 tar 打包并读回字节（本地与远端共用：远端先把子树拉回本地）。
  Future<Map<String, dynamic>> _tarGz({
    required String root,
    required String rel,
    required String name,
    required int entries,
  }) async {
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
        'name': name,
        'entries': entries,
        'size': bytes.length,
      };
    } catch (error) {
      return _error('读取打包结果失败：$error', 500);
    } finally {
      await _deleteQuietly(temp);
    }
  }

  /// 远端路径是否目录（M8b）。
  ///
  /// SFTP 的 listdir 对"文件"与"不存在"都报错，因此这里用"能不能列"来判类型：
  /// 单文件下载/打包与子树遍历共用一条入口，不必再为文件单独加 stat。
  Future<bool> _remoteIsDirectory(WorkspaceFiles remote, String rel) async {
    if (rel.trim().isEmpty) return true;
    try {
      await remote.listEntries(rel, maxEntries: 1);
      return true;
    } on WorkspaceIoException {
      return false;
    }
  }

  /// 递归把远端目录拉到 [destinationRoot]（保留工作空间相对层级）。
  ///
  /// **增量**：列一层就复制一层，不再先全树统计。计数与上限边走边算，
  /// 触顶立刻停下（[counters].limitHit），不会安静地把整棵巨树走完。
  Future<void> _copyRemoteTree(
    WorkspaceFiles remote,
    String dir,
    String destinationRoot,
    _CopyCounters counters,
  ) async {
    // 空串就是根：两个实现都自己把空路径归一成 '.'，这里不要替它们转
    final List<WorkspaceEntry> entries = await remote.listEntries(
      dir,
      maxEntries: maxListEntries,
    );
    for (final WorkspaceEntry entry in entries) {
      if (counters.limitHit) return;
      if (entry.name == '.git') continue;
      if (entry.isDirectory) {
        await _copyRemoteTree(
          remote,
          entry.relativePath,
          destinationRoot,
          counters,
        );
        continue;
      }
      await _copyRemoteFile(
        remote,
        entry.relativePath,
        destinationRoot,
        counters,
      );
    }
  }

  /// 拉单个远端文件到 [destinationRoot] 下的工作空间相对路径处。
  Future<void> _copyRemoteFile(
    WorkspaceFiles remote,
    String rel,
    String destinationRoot,
    _CopyCounters counters,
  ) async {
    final String destination = p.joinAll(<String>[
      destinationRoot,
      ...p.posix.split(rel),
    ]);
    await Directory(p.dirname(destination)).create(recursive: true);
    // 流式拷：一个文件一块一块地过，峰值内存与文件大小无关（M8c）
    final IOSink sink = File(destination).openWrite();
    int size = 0;
    try {
      await for (final List<int> chunk in remote.openRead(rel)) {
        sink.add(chunk);
        size += chunk.length;
      }
    } finally {
      await sink.close();
    }
    counters.add(size);
  }

  /// 远端工作空间（或子树）→ 本机目录（`syncToLocal` 的 SSH 分支）。
  ///
  /// M8b：边走边拉，不再先 `_walkRemote` 全树统计；[path] 为空 = 整棵根。
  Future<Map<String, dynamic>> _syncRemoteToLocal(
    WorkspaceFiles remote,
    String target, {
    required String path,
  }) async {
    final _CopyCounters counters = _CopyCounters(
      maxFiles: maxSyncFiles,
      maxBytes: maxSyncBytes,
    );
    try {
      if (await _remoteIsDirectory(remote, path)) {
        await _copyRemoteTree(remote, path, target, counters);
      } else {
        await _copyRemoteFile(remote, path, target, counters);
      }
    } on WorkspacePathException catch (error) {
      return _error(error.toString(), 400);
    } on WorkspaceIoException catch (error) {
      return _error(error.message, 404);
    } catch (error) {
      return _error('读取远端工作空间失败：$error', 500);
    }
    if (counters.limitHit) return _limitError('同步', counters);
    log?.call('同步到本地（SSH）：${counters.files} 个文件 → $target');
    return <String, dynamic>{
      'success': true,
      'local_path': target,
      'path': path,
      'files': counters.files,
      'bytes': counters.bytes,
    };
  }

  /// 走量超限时的统一 413：**报进度**而不是一句"太大了"。
  Map<String, dynamic> _limitError(String action, _CopyCounters counters) {
    return _error(
      '$action中断：已处理 ${counters.files} 个文件 / '
      '${counters.bytes ~/ (1024 * 1024)} MB，超过上限（'
      '${counters.maxFiles} 个 / ${counters.maxBytes ~/ (1024 * 1024)} MB）。'
      '请改用文件夹打包下载，或分目录/分批处理',
      413,
    );
  }

  /// 远端目录打包（`archive` 的 SSH 分支）：先把子树拉回本地临时目录，再本地 tar。
  ///
  /// 为什么不遥控远端 tar：① 远端不一定有 tar/bsdtar；② 二进制经 exec 的 stdout
  /// 会被当成文本解码（本机那条路径已经踩过一次：bsdtar 经管道还会把 \n 变 \r\n），
  /// 传回来还得走 base64；③ 各发行版 tar 行为不一致。拉回来再打包只有一条代码路径，
  /// 也复用了同一份 gzip 校验。
  ///
  /// M8b：与同步共用**增量**遍历（边拉边算），不再先全树统计；上限按未压缩字节
  /// 计，触顶就删掉临时目录并报已拉取的进度。[path] 也可以指向单个文件。
  Future<Map<String, dynamic>> _archiveRemote(
    WorkspaceFiles remote,
    String path,
  ) async {
    final String trimmed = path.trim();
    final Directory temp;
    try {
      temp = await Directory.systemTemp.createTemp('tree_remote_tar_');
    } catch (error) {
      return _error('创建临时目录失败：$error', 500);
    }
    final _CopyCounters counters = _CopyCounters(
      maxFiles: maxSyncFiles,
      maxBytes: maxArchiveBytes,
    );
    try {
      if (await _remoteIsDirectory(remote, trimmed)) {
        // 按**工作空间相对路径**铺开（不额外套一层目录名）：这样 tar 的 -C + rel 与
        // 本地打包完全同构，包内成员名也与工作空间里看到的一致。
        await _copyRemoteTree(remote, trimmed, temp.path, counters);
      } else {
        await _copyRemoteFile(remote, trimmed, temp.path, counters);
      }
    } on WorkspacePathException catch (error) {
      await _deleteQuietly(temp);
      return _error(error.toString(), 400);
    } on WorkspaceIoException catch (error) {
      await _deleteQuietly(temp);
      return _error(error.message, 404);
    } catch (error) {
      await _deleteQuietly(temp);
      return _error('拉取远端目录失败：$error', 500);
    }
    if (counters.limitHit) {
      await _deleteQuietly(temp);
      return _limitError('打包', counters);
    }
    final String baseName = trimmed.isEmpty
        ? 'workspace'
        : p.posix.basename(p.posix.normalize(trimmed));
    try {
      return await _tarGz(
        root: temp.path,
        rel: trimmed.isEmpty ? '.' : trimmed,
        name: '$baseName.tar.gz',
        entries: counters.files,
      );
    } finally {
      await _deleteQuietly(temp);
    }
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

  /// 递归复制本地子树（M8b）：**边走边复制**，`.git` 不参与。
  ///
  /// 与 [`_enumerate`] 的区别：那个是"先枚举后打包"（本地 tar 需要知道总量），
  /// 这里同步只在复制途中走量，列一层复制一层。
  Future<void> _copyLocalTree(
    Directory dir,
    String root,
    String target,
    _CopyCounters counters,
  ) async {
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (error) {
      log?.call('遍历目录失败（${dir.path}）：$error');
      return;
    }
    for (final FileSystemEntity entity in children) {
      if (counters.limitHit) return;
      final String name = p.basename(entity.path);
      if (name == '.git') continue;
      if (entity is Directory) {
        await _copyLocalTree(entity, root, target, counters);
      } else if (entity is File) {
        await _copyLocalFile(
          entity,
          _relative(root, entity.path),
          target,
          counters,
        );
      }
    }
  }

  /// 复制单个本地文件到 [target] 下的工作空间相对路径处。
  Future<void> _copyLocalFile(
    File file,
    String relativePath,
    String target,
    _CopyCounters counters,
  ) async {
    final String destination = p.joinAll(<String>[
      target,
      ...p.posix.split(relativePath),
    ]);
    final String parent = p.dirname(destination);
    if (counters.created.add(parent)) {
      await Directory(parent).create(recursive: true);
    }
    final int size = await file.length();
    await file.copy(destination);
    counters.add(size);
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

  /// 「按内容写文件」的失败结果：error（机器码）+ detail（可直接展示的中文原因）。
  ///
  /// 与读路径的 [_error]（只有 error）不同：写接口的错误体要同时给机器码与中文原因，
  /// 冲突还要带上当前 size（前端据此提示「刷新后再保存」）。
  static Map<String, dynamic> _writeError(
    String code,
    String detail, {
    int status = 400,
    int? size,
  }) {
    final Map<String, dynamic> result = <String, dynamic>{
      'error': code,
      'detail': detail,
      'status': status,
    };
    if (size != null) result['size'] = size;
    return result;
  }

  /// 字节数的人读文本（错误提示里报上限用）。
  static String _mbText(int bytes) {
    final String text = (bytes / (1024 * 1024)).toStringAsFixed(1);
    return '$text MB';
  }

  /// 头部是否含 NUL（文本里不该出现 NUL）：只看前 [binaryProbeBytes] 字节，
  /// 与前端 attachment_preview.dart 的 _looksBinary 同一口径。
  static bool _hasNul(List<int> bytes) {
    final int n = bytes.length > binaryProbeBytes
        ? binaryProbeBytes
        : bytes.length;
    for (int i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  /// 本机探测现有文件（大小 + 头部字节）：只读，不参与落盘。
  static _ExistingFile _probeLocal(File file) {
    if (!file.existsSync()) return _ExistingFile.missing;
    final RandomAccessFile raf;
    try {
      raf = file.openSync();
    } catch (_) {
      return _ExistingFile.unknown;
    }
    try {
      final int size = raf.lengthSync();
      final int count = size > binaryProbeBytes ? binaryProbeBytes : size;
      final List<int> head = count <= 0 ? <int>[] : raf.readSync(count);
      return _ExistingFile(known: true, exists: true, size: size, head: head);
    } catch (_) {
      return _ExistingFile.unknown;
    } finally {
      try {
        raf.closeSync();
      } catch (_) {
        // 关不掉就算了：这是一次只读探测
      }
    }
  }

  /// 远端探测现有文件（大小 + 头部字节）：走 [WorkspaceFiles]（与文件面板同一条
  /// SSH 连接对象）。拿不到探测后端时返回 unknown，由调用方如实报错。
  Future<_ExistingFile> _probeRemote(WorkspaceFiles? files, String rel) async {
    if (files == null) return _ExistingFile.unknown;
    final int size;
    try {
      size = await files.sizeOf(rel);
    } on WorkspacePathException {
      return _ExistingFile.unknown;
    } on WorkspaceIoException {
      return _ExistingFile.missing;
    } catch (_) {
      return _ExistingFile.unknown;
    }
    if (size <= 0) {
      return const _ExistingFile(known: true, exists: true);
    }
    try {
      final List<int> head = await _collect(
        files.openRead(rel, offset: 0, length: binaryProbeBytes),
      );
      return _ExistingFile(known: true, exists: true, size: size, head: head);
    } on WorkspacePathException {
      return _ExistingFile.unknown;
    } catch (_) {
      // 头部读不到不影响冲突判断：大小已经有了，NUL 探测退化为「没探测到」
      return _ExistingFile(known: true, exists: true, size: size);
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
    required this.remote,
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

  /// 目标是否在远端（true 时 [absolutePath] 无意义，落盘走 SFTP 写）。
  final bool remote;

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

/// 同步/打包的走量与上限（M8b）：**边走边算**，不再先全树统计一遍。
class _CopyCounters {
  _CopyCounters({required this.maxFiles, required this.maxBytes});

  final int maxFiles;
  final int maxBytes;

  int files = 0;
  int bytes = 0;

  /// 是否已触顶（触顶后调用方应立即停下）。
  bool limitHit = false;

  /// 已创建过的父目录（避免每个文件都 create 一次）。
  final Set<String> created = <String>{};

  void add(int size) {
    files++;
    bytes += size;
    if (files > maxFiles || bytes > maxBytes) limitHit = true;
  }
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

/// 写入前对**现有文件**的只读探测结果（大小 + 头部字节）。
///
/// 三种状态必须分开，语义不同：
/// - [unknown]：探测后端起不来（远端只接了 [WorkspaceIO] 而没有 [WorkspaceFiles]）——
///   不能把「不知道」当成「没冲突」，由调用方如实报错；
/// - [missing]：确定不存在（带了 if_size 算冲突，没带就直接创建）；
/// - 其余：存在，带 [size] 与 [head]（head 用来探 NUL）。
class _ExistingFile {
  const _ExistingFile({
    required this.known,
    required this.exists,
    this.size = 0,
    this.head = const <int>[],
  });

  static const _ExistingFile unknown = _ExistingFile(
    known: false,
    exists: false,
  );

  static const _ExistingFile missing = _ExistingFile(
    known: true,
    exists: false,
  );

  final bool known;
  final bool exists;
  final int size;
  final List<int> head;
}

/// 文件服务的可读错误。
class FileServiceException implements Exception {
  FileServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
