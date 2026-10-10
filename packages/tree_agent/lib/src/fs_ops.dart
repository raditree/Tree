import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'path_guard.dart';

/// `fs.*` 的默认遍历上限（协议 §3.2 的缺省值）。
const int kDefaultListMaxDepth = 8;
const int kDefaultListMaxEntries = 20000;
const int kDefaultListEntriesMaxEntries = 5000;

/// 目标机文件系统的**真正干活那一端**（协议 §3.2 的 11 个 `fs.*`）。
///
/// 路径一律**正斜杠字符串**（Windows 也接受正斜杠）⇒ 单测能在 Windows 开发机上跑，
/// 而生产是 Linux（`dart:io` 在两侧语义一致）。
///
/// 字节口径（协议 §3.3 / 不变量 17 的前提）：`fs.read` / `fs.write` 的 `data` 一律
/// **base64 原文**，不做任何解码 / 清洗 ⇒ 分块读写拼接后与原文逐字节相等。
class FsOps {
  FsOps(this.guard);

  final PathGuard guard;

  // ── fs.read ──────────────────────────────────────────────────────────

  /// `{path, offset?:int=0, length?:int}` → `{data:base64, size, offset, eof}`。
  ///
  /// **单次最多 [kReadChunkBytes] 原文**（协议硬约束）；`length` 缺省 = 到结尾，仍分块。
  Future<Map<String, dynamic>> read(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final int offset = _optionalInt(params['offset']) ?? 0;
    final int? length = _optionalInt(params['length']);

    final FileStat stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw RpcException(TunnelErrorCodes.notFound, '文件不存在：$path');
    }
    if (stat.type != FileSystemEntityType.file) {
      throw RpcException(TunnelErrorCodes.notFound, '目标不是普通文件，不能读取：$path');
    }

    final int size = stat.size;
    final int start = offset <= 0 ? 0 : math.min(offset, size);
    int want = kReadChunkBytes;
    if (length != null && length >= 0) want = math.min(want, length);
    want = math.min(want, size - start);
    if (want < 0) want = 0;

    List<int> data = const <int>[];
    if (want > 0) {
      final RandomAccessFile handle = await File(path).open();
      try {
        await handle.setPosition(start);
        data = await handle.read(want);
      } finally {
        await handle.close();
      }
    }
    final int end = start + data.length;
    return <String, dynamic>{
      'data': base64Encode(data),
      'size': size,
      'offset': start,
      'eof': end >= size,
    };
  }

  // ── fs.write ─────────────────────────────────────────────────────────

  /// `{path, data:base64, mode:'write'|'append'=write, flush?:bool}` → `{size}`。
  Future<Map<String, dynamic>> write(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final Object? rawData = params['data'];
    if (rawData is! String) {
      throw RpcException(RpcCodes.invalidParams, 'data 必须是 base64 字符串');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(rawData);
    } on FormatException catch (error) {
      throw RpcException(RpcCodes.invalidParams, 'data 不是合法 base64：${error.message}');
    }
    final String mode = (params['mode'] ?? 'write').toString();
    if (mode != 'write' && mode != 'append') {
      throw RpcException(RpcCodes.invalidParams, "mode 只能是 'write' 或 'append'（收到 $mode）");
    }
    final bool flush = params['flush'] == true;

    // 自动建父目录（协议 §3.2）。path 已归一化且在 root 内 ⇒ 其父目录也在 root 内。
    final String parent = posixDirname(path);
    await Directory(parent).create(recursive: true);
    final File file = File(path);
    try {
      await file.writeAsBytes(
        bytes,
        mode: mode == 'append' ? FileMode.append : FileMode.write,
        flush: flush,
      );
    } on FileSystemException catch (error) {
      throw mapFileSystemException(error, path);
    }
    return <String, dynamic>{'size': bytes.length};
  }

  // ── fs.stat ──────────────────────────────────────────────────────────

  /// `{path}` → `{type:'file'|'dir'|'missing', size, mtime_ms?, mode?}`。
  ///
  /// **不存在返回 `type:'missing'`，不抛**（协议 §3.2 的字面形状）；核心
  /// `TunnelSshTransport._statOf` 两条路都收（它也兼容 `-32002`）。
  Future<Map<String, dynamic>> stat(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final FileStat stat = await File(path).stat();
    switch (stat.type) {
      case FileSystemEntityType.file:
        return <String, dynamic>{
          'type': 'file',
          'size': stat.size,
          'mtime_ms': stat.modified.millisecondsSinceEpoch,
          'mode': stat.mode,
        };
      case FileSystemEntityType.directory:
        return <String, dynamic>{
          'type': 'dir',
          'size': 0,
          'mtime_ms': stat.modified.millisecondsSinceEpoch,
          'mode': stat.mode,
        };
      default:
        return <String, dynamic>{'type': 'missing', 'size': 0};
    }
  }

  // ── fs.exists / fs.isDir ─────────────────────────────────────────────

  /// `{path}` → `{exists, is_dir}`（跟随符号链接：与 SFTP `stat` 一致）。
  Future<Map<String, dynamic>> exists(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: true,
    );
    return <String, dynamic>{
      'exists': type != FileSystemEntityType.notFound,
      'is_dir': type == FileSystemEntityType.directory,
    };
  }

  /// `{path}` → `{is_dir}`（不存在 / 是文件 / 读不到都 false —— 与
  /// `SshTransport.isDirectory` 同口径）。
  Future<Map<String, dynamic>> isDir(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: true,
    );
    return <String, dynamic>{'is_dir': type == FileSystemEntityType.directory};
  }

  // ── fs.list（递归，只列文件）─────────────────────────────────────────

  /// `{path, max_depth?:int=8, max_entries?:int=20000}`
  /// → `{files:[相对 `path` 的文件路径…], truncated, scanned}`。
  ///
  /// **只列文件**（与 `SshTransport.listFiles` 的消费方一致）；相对路径用 POSIX 分隔符；
  /// **不内建排除表**（排除规则的唯一真源在核心 `SshWorkspaceIO`，不变量 4 —— 两边各写
  /// 一份必然漂移）。
  ///
  /// [scanned] = 遍历过的**目录条目数**（诊断用；`files.length` 可能因上限而更小）。
  Future<Map<String, dynamic>> list(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final int maxDepth = _positiveOr(params['max_depth'], kDefaultListMaxDepth);
    final int maxEntries = _positiveOr(
      params['max_entries'],
      kDefaultListMaxEntries,
    );

    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: true,
    );
    if (type == FileSystemEntityType.notFound) {
      throw RpcException(TunnelErrorCodes.notFound, '目录不存在：$path');
    }
    if (type != FileSystemEntityType.directory) {
      throw RpcException(TunnelErrorCodes.notFound, '目标不是目录，无法列出：$path');
    }

    final List<String> files = <String>[];
    int scanned = 0;
    bool truncated = false;

    Future<void> walk(String dir, String prefix, int depth) async {
      if (truncated) return;
      final List<FileSystemEntity> children;
      try {
        children = await Directory(dir).list(followLinks: false).toList();
      } on FileSystemException {
        return; // 单个目录读不动（权限等）不该让整轮列出失败
      }
      // 稳定顺序（诊断 / 测试友好）：按路径排序。
      children.sort((FileSystemEntity a, FileSystemEntity b) =>
          a.path.compareTo(b.path));
      for (final FileSystemEntity child in children) {
        if (truncated) return;
        scanned++;
        // dart:io 在 Windows 上给的是反斜杠路径 ⇒ 在边界上转成正斜杠（本包的口径）。
        final String childPath = posixify(child.path);
        final String name = posixBasename(childPath);
        final String relative = prefix.isEmpty ? name : '$prefix/$name';
        final FileSystemEntityType childType = await FileSystemEntity.type(
          childPath,
          followLinks: false,
        );
        if (childType == FileSystemEntityType.directory) {
          if (depth < maxDepth) await walk(childPath, relative, depth + 1);
          continue;
        }
        if (childType == FileSystemEntityType.link) {
          // 按链接本身操作：链接**目录**不跟着穿（防环），链接**文件**算文件。
          final FileSystemEntityType target = await FileSystemEntity.type(
            childPath,
            followLinks: true,
          );
          if (target != FileSystemEntityType.file) continue;
        }
        if (files.length >= maxEntries) {
          truncated = true;
          return;
        }
        files.add(relative);
      }
    }

    await walk(path, '', 1);
    return <String, dynamic>{
      'files': files,
      'truncated': truncated,
      'scanned': scanned,
    };
  }

  // ── fs.listEntries（一层，带元信息）──────────────────────────────────

  /// `{path, max_entries?:int=5000}` → `{entries:[{name, type, size, mtime_ms?}]}`。
  ///
  /// `type ∈ file|dir|link|other`（**不跟随链接**：链接本身报 `link`，与文件面板一致）。
  Future<Map<String, dynamic>> listEntries(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final int maxEntries = _positiveOr(
      params['max_entries'],
      kDefaultListEntriesMaxEntries,
    );
    final Directory dir = Directory(path);
    if (!await dir.exists()) {
      throw RpcException(TunnelErrorCodes.notFound, '目录不存在：$path');
    }
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    await for (final FileSystemEntity child in dir.list(followLinks: false)) {
      if (entries.length >= maxEntries) break;
      final FileStat stat = await child.stat();
      final String type;
      switch (child) {
        case Directory():
          type = 'dir';
        case Link():
          type = 'link';
        case File():
          type = 'file';
        default:
          type = 'other';
      }
      final bool sizeable = type == 'file' || type == 'link';
      entries.add(<String, dynamic>{
        'name': posixBasename(posixify(child.path)),
        'type': type,
        'size': sizeable ? stat.size : 0,
        if (stat.type != FileSystemEntityType.notFound &&
            stat.modified.millisecondsSinceEpoch > 0)
          'mtime_ms': stat.modified.millisecondsSinceEpoch,
      });
    }
    return <String, dynamic>{'entries': entries};
  }

  // ── fs.mkdir ─────────────────────────────────────────────────────────

  /// `{path, recursive?:bool=false}` → `{}`。
  ///
  /// 非递归时：**父目录必须已存在**（否则 `-32005 parent_missing`）；**已存在**
  /// 回 `-32003 already_exists`。都用显式预检（不靠 errno）⇒ Windows 单测同分支。
  Future<Map<String, dynamic>> mkdir(Map<String, dynamic> params) async {
    final String path = guard.check(params['path']);
    final bool recursive = params['recursive'] == true;
    if (recursive) {
      try {
        await Directory(path).create(recursive: true);
      } on FileSystemException catch (error) {
        throw mapFileSystemException(error, path);
      }
      return <String, dynamic>{};
    }
    final String parent = posixDirname(path);
    final FileSystemEntityType parentType = await FileSystemEntity.type(
      parent,
      followLinks: true,
    );
    if (parentType != FileSystemEntityType.directory) {
      throw RpcException(TunnelErrorCodes.parentMissing, '父目录不存在：$parent');
    }
    final FileSystemEntityType target = await FileSystemEntity.type(
      path,
      followLinks: false,
    );
    if (target != FileSystemEntityType.notFound) {
      throw RpcException(TunnelErrorCodes.alreadyExists, '目标已存在：$path');
    }
    try {
      await Directory(path).create();
    } on FileSystemException catch (error) {
      throw mapFileSystemException(error, path);
    }
    return <String, dynamic>{};
  }

  // ── fs.rename ────────────────────────────────────────────────────────

  /// `{from, to}` → `{}`。**两个路径都查越界**（协议 §4）。
  ///
  /// 源不存在 ⇒ `-32002 not_found`；目标已存在 ⇒ `-32003 already_exists`
  /// （**绝不覆盖**：`rename(2)` 本身是覆盖语义，必须自检）。
  Future<Map<String, dynamic>> rename(Map<String, dynamic> params) async {
    final String from = guard.checkDestructiveTarget(
      params['from'],
      label: 'from',
    );
    final String to = guard.check(params['to'], label: 'to');

    final FileSystemEntityType sourceType = await FileSystemEntity.type(
      from,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      throw RpcException(TunnelErrorCodes.notFound, '源路径不存在：$from');
    }
    final FileSystemEntityType targetType = await FileSystemEntity.type(
      to,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound) {
      throw RpcException(TunnelErrorCodes.alreadyExists, '目标已存在：$to');
    }
    final String parent = posixDirname(to);
    if (await FileSystemEntity.type(parent, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw RpcException(TunnelErrorCodes.parentMissing, '目标父目录不存在：$parent');
    }
    try {
      if (sourceType == FileSystemEntityType.directory) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
    } on FileSystemException catch (error) {
      throw mapFileSystemException(error, to);
    }
    return <String, dynamic>{};
  }

  // ── fs.remove ────────────────────────────────────────────────────────

  /// `{path, recursive?:bool=false}` → `{}`。
  ///
  /// 目录非空且 `recursive=false` ⇒ `-32004 not_empty`（**不静默递归**）；
  /// 递归删除**自底向上**、**按链接本身删**（不跟着符号链接删穿 —— 不变量 12）。
  Future<Map<String, dynamic>> remove(Map<String, dynamic> params) async {
    final String path = guard.checkDestructiveTarget(params['path']);
    final bool recursive = params['recursive'] == true;
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      throw RpcException(TunnelErrorCodes.notFound, '路径不存在：$path');
    }
    try {
      if (type == FileSystemEntityType.directory) {
        final bool empty = await Directory(path).list().isEmpty;
        if (!empty && !recursive) {
          throw RpcException(TunnelErrorCodes.notEmpty, '目录非空（recursive=false）：$path');
        }
        if (recursive) {
          await _removeRecursive(path);
        } else {
          await Directory(path).delete();
        }
      } else {
        // 文件 / 符号链接：按链接本身删。
        await File(path).delete();
      }
    } on FileSystemException catch (error) {
      throw mapFileSystemException(error, path);
    }
    return <String, dynamic>{};
  }

  Future<void> _removeRecursive(String path) async {
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory) {
      await File(path).delete();
      return;
    }
    // 自底向上：先把孩子删干净，再删自己。`followLinks: false` ⇒ 符号链接当叶子。
    await for (final FileSystemEntity child in Directory(
      path,
    ).list(followLinks: false)) {
      await _removeRecursive(child.path);
    }
    await Directory(path).delete();
  }

  // ── fs.delete ────────────────────────────────────────────────────────

  /// `{path}` → `{}`（**文件**；不存在**不报错**，与 `SshTransport.delete` 同口径）。
  Future<Map<String, dynamic>> delete(Map<String, dynamic> params) async {
    final String path = guard.checkDestructiveTarget(params['path']);
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return <String, dynamic>{};
    if (type == FileSystemEntityType.directory) {
      throw RpcException(TunnelErrorCodes.notFound, '目标是目录，fs.delete 只删文件：$path');
    }
    try {
      await File(path).delete();
    } on FileSystemException catch (error) {
      throw mapFileSystemException(error, path);
    }
    return <String, dynamic>{};
  }
}

// ── 参数助手 ────────────────────────────────────────────────────────────

int? _optionalInt(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

int _positiveOr(Object? raw, int fallback) {
  final int? value = _optionalInt(raw);
  if (value == null || value <= 0) return fallback;
  return value;
}

/// 把 `dart:io` 的 [FileSystemException] 翻成协议错误码（协议 §5）。
///
/// 业务语义（already_exists / parent_missing / not_empty）在调用点用**显式预检**表达，
/// 这里的 errno 映射只是兜底（真机上仍可能撞到），因此同时认 POSIX 与 Windows 的码。
RpcException mapFileSystemException(FileSystemException error, String path) {
  final int code = error.osError?.errorCode ?? 0;
  final String message = '${error.message}（$path）';
  switch (code) {
    case 2: // ENOENT
    case 3: // ENOENT (windows ERROR_PATH_NOT_FOUND)
    case 20: // ENOTDIR
    case 21: // EISDIR
      return RpcException(TunnelErrorCodes.notFound, message);
    case 1: // EPERM
    case 13: // EACCES
    case 5: // windows ERROR_ACCESS_DENIED
      return RpcException(TunnelErrorCodes.permissionDenied, message);
    case 17: // EEXIST
    case 183: // windows ERROR_ALREADY_EXISTS
      return RpcException(TunnelErrorCodes.alreadyExists, message);
    case 39: // ENOTEMPTY
    case 66: // ENOTEMPTY (BSD)
    case 145: // windows ERROR_DIR_NOT_EMPTY
      return RpcException(TunnelErrorCodes.notEmpty, message);
    default:
      return RpcException(RpcCodes.internalError, message);
  }
}
