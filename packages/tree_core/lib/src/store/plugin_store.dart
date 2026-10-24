import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tree_paths.dart';

/// 插件**命名空间存储**（`/api/store/{ns}/{key}` 的落盘实现）。
///
/// 设计口径（`docs/pluginization/ui-pluginization.md` §3.1 / §4.1）：
/// - **二进制原样存取**：核心不解析值内容，一个键一个文件；
/// - **命名空间隔离**：HTTP 层先判定调用方身份，`ns` 必须与调用方一致；本类只负责
///   落盘，不参与身份判定；
/// - **乐观锁**：每个值的内容哈希（FNV-1a 32 位）就是 etag；已存在的键必须带正确
///   etag 才能覆盖，`*` 表示无条件覆盖；不存在的键允许不带 etag 创建；
/// - **配额**：单值上限 [maxValueBytes]（1 MiB），每命名空间总量上限
///   [defaultNamespaceQuotaBytes]（64 MiB）；超限整次写入失败，不做部分写入；
/// - **落盘布局**：`<数据根>/store/<ns>/k_<base64url(key)>`。key 用 base64url 编码，
///   天然避开路径分隔符、`..`、Windows 保留名与盘符。
class PluginStore {
  PluginStore({
    required this.paths,
    this.namespaceQuotaBytes = defaultNamespaceQuotaBytes,
    this.maxValueBytes = defaultMaxValueBytes,
    this.maxKeyBytes = defaultMaxKeyBytes,
  });

  /// 路径布局（`<数据根>/store`）。
  final TreePaths paths;

  /// 每个命名空间的**总字节上限**（默认 64 MiB）。
  final int namespaceQuotaBytes;

  /// 单个值的**字节上限**（默认 1 MiB）。
  final int maxValueBytes;

  /// key 的 UTF-8 字节上限（默认 128；保证编码后的文件名不撞 Windows 260 字符路径）。
  final int maxKeyBytes;

  /// 默认命名空间配额：64 MiB。
  static const int defaultNamespaceQuotaBytes = 64 * 1024 * 1024;

  /// 默认单值上限：1 MiB。
  static const int defaultMaxValueBytes = 1024 * 1024;

  /// 默认 key 字节上限。
  static const int defaultMaxKeyBytes = 128;

  /// 列键的默认页大小。
  static const int defaultPageLimit = 100;

  /// 列键的最大页大小。
  static const int maxPageLimit = 1000;

  /// 核心自己的命名空间（主 token 调用方）。
  static const String coreNamespace = 'core';

  static const Set<String> _windowsReserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  /// 命名空间是否合法：只允许 `[A-Za-z0-9_.-]`、非 `.`/`..`、非 Windows 保留名。
  static bool isValidNamespace(String raw) {
    if (raw != raw.trim()) return false;
    // Windows 会把结尾的 `.`/空格静默裁掉，导致"校验的名字"与"落盘的名字"不一致。
    if (raw.endsWith('.') || raw.endsWith(' ')) return false;
    try {
      final String value = TreePaths.safeSegment(raw);
      return !_isWindowsReserved(value);
    } on ArgumentError {
      return false;
    }
  }

  /// key 是否合法：拒绝空串、路径分隔符、盘符/ADS 冒号、控制字符、`.`/`..`、
  /// Windows 保留名、首尾空白与结尾点号（Windows 会静默归一化）。
  bool isValidKey(String raw) {
    if (raw.isEmpty || raw != raw.trim()) return false;
    if (utf8.encode(raw).length > maxKeyBytes) return false;
    if (raw == '.' || raw == '..') return false;
    if (raw.contains('/') || raw.contains('\\') || raw.contains('\u0000')) {
      return false;
    }
    // 盘符（`C:`）与 NTFS 备用数据流（`a:b`）都靠冒号表达，一律禁止。
    if (raw.contains(':')) return false;
    for (final int unit in raw.codeUnits) {
      if (unit < 0x20 || unit == 0x7F) return false;
    }
    if (raw.endsWith('.') || raw.endsWith(' ')) return false;
    return !_isWindowsReserved(raw);
  }

  /// 某个命名空间的目录（调用前必须先通过 [isValidNamespace]）。
  String namespaceDir(String ns) => p.join(paths.storeDir, ns);

  /// 某个键的落盘文件（调用前必须先通过 [isValidKey]）。
  String fileForKey(String ns, String key) =>
      p.join(namespaceDir(ns), 'k_${_encodeKey(key)}');

  /// 列键（分页：按 key 升序，`cursor` 是上一页最后一条 key）。
  Future<StorePage> list(
    String ns, {
    int limit = defaultPageLimit,
    String? cursor,
  }) async {
    final int pageLimit = limit <= 0
        ? defaultPageLimit
        : limit.clamp(1, maxPageLimit);
    final Directory dir = Directory(namespaceDir(ns));
    if (!await dir.exists()) {
      return const StorePage(entries: <StoreEntry>[], nextCursor: null);
    }
    final List<StoreEntry> all = <StoreEntry>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (!name.startsWith('k_')) continue;
      final String? key = _decodeKey(name.substring(2));
      if (key == null) continue;
      final File file = File(entity.path);
      try {
        final FileStat stat = await file.stat();
        final List<int> bytes = await file.readAsBytes();
        all.add(
          StoreEntry(
            key: key,
            size: stat.size,
            etag: etagOfBytes(bytes),
            updatedAt: stat.modified.toUtc(),
          ),
        );
      } on FileSystemException {
        // 并发删除：跳过，不让一次列举整体失败。
        continue;
      }
    }
    all.sort((StoreEntry a, StoreEntry b) => a.key.compareTo(b.key));
    final String from = (cursor ?? '').trim();
    final List<StoreEntry> remaining = from.isEmpty
        ? all
        : all.where((StoreEntry entry) => entry.key.compareTo(from) > 0).toList();
    final List<StoreEntry> page = remaining.take(pageLimit).toList();
    final String? next = remaining.length > page.length ? page.last.key : null;
    return StorePage(entries: page, nextCursor: next);
  }

  /// 取值；键不存在返回 null。
  Future<StoreValue?> read(String ns, String key) async {
    final File file = File(fileForKey(ns, key));
    if (!await file.exists()) return null;
    final List<int> bytes = await file.readAsBytes();
    final FileStat stat = await file.stat();
    return StoreValue(
      bytes: bytes,
      etag: etagOfBytes(bytes),
      modified: stat.modified.toUtc(),
    );
  }

  /// 写值（乐观锁语义见类注释）。
  ///
  /// [expectedEtag] 为 null 表示调用方没带 etag；`*` 表示无条件覆盖。
  Future<StorePutResult> put(
    String ns,
    String key,
    List<int> bytes, {
    String? expectedEtag,
  }) async {
    if (bytes.length > maxValueBytes) {
      return StorePutResult(
        status: StorePutStatus.tooLarge,
        message: '单值超过上限 $maxValueBytes 字节（本次 ${bytes.length} 字节）',
      );
    }
    final File file = File(fileForKey(ns, key));
    final bool exists = await file.exists();
    int oldSize = 0;
    String? currentEtag;
    if (exists) {
      oldSize = await file.length();
      currentEtag = etagOfBytes(await file.readAsBytes());
    }
    final String? expected = _normalizeEtag(expectedEtag);
    if (!exists) {
      if (expected != null && expected != '*') {
        return const StorePutResult(
          status: StorePutStatus.conflict,
          message: '键不存在；创建新键时请不要带 etag（或使用 "*"）',
        );
      }
    } else if (expected == null) {
      return const StorePutResult(
        status: StorePutStatus.conflict,
        message: '键已存在，覆盖必须带正确的 etag（If-Match / ?etag= / X-Tree-Etag）',
      );
    } else if (expected != '*' && expected != currentEtag) {
      return StorePutResult(
        status: StorePutStatus.conflict,
        message: 'etag 不匹配（当前为 "$currentEtag"），请重新读取后再写',
      );
    }
    final int used = await _namespaceBytes(ns);
    if (used - oldSize + bytes.length > namespaceQuotaBytes) {
      return StorePutResult(
        status: StorePutStatus.quotaExceeded,
        message:
            '命名空间 "$ns" 配额已满（上限 $namespaceQuotaBytes 字节，'
            '当前已用 ${used - oldSize}，本次 ${bytes.length}）',
      );
    }
    await _writeAtomic(file, bytes);
    return StorePutResult(
      status: exists ? StorePutStatus.updated : StorePutStatus.created,
      etag: etagOfBytes(bytes),
      size: bytes.length,
    );
  }

  /// 删除；键不存在返回 notFound（由 HTTP 层回可读 404）。
  Future<StoreDeleteResult> delete(String ns, String key) async {
    final File file = File(fileForKey(ns, key));
    if (!await file.exists()) {
      return const StoreDeleteResult(
        status: StoreDeleteStatus.notFound,
        message: '键不存在',
      );
    }
    final int size = await file.length();
    await file.delete();
    return StoreDeleteResult(
      status: StoreDeleteStatus.deleted,
      freedBytes: size,
    );
  }

  /// 命名空间当前占用字节数（只统计键文件，忽略写入中的临时文件）。
  Future<int> namespaceBytes(String ns) => _namespaceBytes(ns);

  /// 值内容的 etag（FNV-1a 32 位十六进制）。
  static String etagOfBytes(List<int> bytes) {
    int hash = 0x811C9DC5;
    for (final int byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 规整客户端带来的 etag：去掉 `W/` 与两侧引号；`*` 原样保留。
  static String? _normalizeEtag(String? raw) {
    String value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    if (value == '*') return '*';
    if (value.startsWith('W/')) value = value.substring(2).trim();
    if (value.length >= 2 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value.isEmpty ? null : value;
  }

  Future<int> _namespaceBytes(String ns) async {
    final Directory dir = Directory(namespaceDir(ns));
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      if (!p.basename(entity.path).startsWith('k_')) continue;
      try {
        total += await entity.length();
      } on FileSystemException {
        continue;
      }
    }
    return total;
  }

  /// 原子写：临时文件 flush 后改名覆盖（Windows 上改名已存在目标失败时先删再改）。
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final File temp = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    }
  }

  static bool _isWindowsReserved(String name) {
    final String first = name.split('.').first.toUpperCase();
    return _windowsReserved.contains(first);
  }

  /// key → 文件名分段（base64url、无填充；只含 `[A-Za-z0-9_-]`）。
  static String _encodeKey(String key) =>
      base64Url.encode(utf8.encode(key)).replaceAll('=', '');

  /// 文件名分段 → key；不是合法 base64 / UTF-8 时返回 null（跳过坏文件）。
  static String? _decodeKey(String encoded) {
    try {
      final String padded = encoded.padRight(
        encoded.length + (4 - encoded.length % 4) % 4,
        '=',
      );
      return utf8.decode(base64Url.decode(padded));
    } on FormatException {
      return null;
    }
  }
}

/// 列键结果。
class StorePage {
  const StorePage({required this.entries, required this.nextCursor});

  final List<StoreEntry> entries;
  final String? nextCursor;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'keys': <Map<String, dynamic>>[
      for (final StoreEntry entry in entries) entry.toJson(),
    ],
    'next_cursor': nextCursor,
  };
}

/// 单个键的元数据。
class StoreEntry {
  const StoreEntry({
    required this.key,
    required this.size,
    required this.etag,
    required this.updatedAt,
  });

  final String key;
  final int size;
  final String etag;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'size': size,
    'etag': etag,
    'updated_at': updatedAt.toIso8601String(),
  };
}

/// 取到的值（原样字节）。
class StoreValue {
  const StoreValue({
    required this.bytes,
    required this.etag,
    required this.modified,
  });

  final List<int> bytes;
  final String etag;
  final DateTime modified;
}

/// 写入结果状态。
enum StorePutStatus { created, updated, conflict, tooLarge, quotaExceeded }

/// 写入结果。
class StorePutResult {
  const StorePutResult({
    required this.status,
    this.message,
    this.etag,
    this.size,
  });

  final StorePutStatus status;
  final String? message;
  final String? etag;
  final int? size;

  bool get ok =>
      status == StorePutStatus.created || status == StorePutStatus.updated;
}

/// 删除结果状态。
enum StoreDeleteStatus { deleted, notFound }

/// 删除结果。
class StoreDeleteResult {
  const StoreDeleteResult({
    required this.status,
    this.message,
    this.freedBytes = 0,
  });

  final StoreDeleteStatus status;
  final String? message;
  final int freedBytes;
}
