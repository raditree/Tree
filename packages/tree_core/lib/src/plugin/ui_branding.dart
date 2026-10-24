import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 品牌用途。
enum UiBrandingRole {
  /// 可执行文件 / 快捷方式图标（只允许 `.ico`）。
  exe,

  /// 窗口图标（`.png` / `.ico`，窗口图标要求 ≥32×32）。
  window,

  /// 托盘图标（`.png` / `.ico`）。
  tray;

  String get wire => name;

  static UiBrandingRole? parse(Object? value) {
    final String key = (value ?? '').toString().trim().toLowerCase();
    for (final UiBrandingRole role in UiBrandingRole.values) {
      if (role.name == key) return role;
    }
    return null;
  }
}

/// 一条生效品牌申报（按 plugin_id 记账）。
class UiBrandingEntry {
  const UiBrandingEntry({
    required this.pluginId,
    required this.iconPath,
    required this.role,
    required this.sizes,
    required this.sequence,
  });

  final String pluginId;

  /// 解析 symlink 后的绝对路径。
  final String iconPath;
  final UiBrandingRole role;

  /// 文件内容实际读出的尺寸（升序）。
  final List<int> sizes;

  /// 到达序号（越大越新；最后到达者生效）。
  final int sequence;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'plugin_id': pluginId,
    'icon': iconPath,
    'role': role.wire,
    'sizes': sizes,
  };
}

/// `system.collect.ui.branding` 的闸门与记账表。
///
/// 全部闸门都返回**可读中文原因**；`declare` 成功返回 null。
/// 核心**绝不改写 exe 的 PE 资源**：这里只读文件、只记账。
class UiBrandingRegistry {
  UiBrandingRegistry({Iterable<String> allowedDirs = const <String>[], this.log})
    : _allowedDirs = allowedDirs.where((String d) => d.trim().isNotEmpty).toList();

  /// 允许的插件目录（相对路径按这些目录解析；绝对路径必须落在其下）。
  final List<String> _allowedDirs;
  final void Function(String message)? log;

  /// 文件体积上限：256KB。
  static const int maxBytes = 256 * 1024;

  /// ICO 必须包含的尺寸。
  static const Set<int> requiredIcoSizes = <int>{16, 32, 48, 256};

  /// 窗口图标的最小边长。
  static const int minWindowSize = 32;

  final Map<String, UiBrandingEntry> _entries = <String, UiBrandingEntry>{};
  int _sequence = 0;

  /// 允许目录（观测 / 测试用）。
  List<String> get allowedDirs => List<String>.unmodifiable(_allowedDirs);

  /// 配置允许目录（核心启动 / 测试注入）。
  void configureAllowedDirs(Iterable<String> dirs) {
    _allowedDirs
      ..clear()
      ..addAll(dirs.where((String d) => d.trim().isNotEmpty));
  }

  /// 当前生效品牌；全部撤回 / 失效 ⇒ null（默认品牌）。
  UiBrandingEntry? get active =>
      _entries.isEmpty ? null : _entries.values.last;

  /// 按 plugin_id 的当前记账快照（顺序 = 到达顺序）。
  List<UiBrandingEntry> get entries =>
      List<UiBrandingEntry>.unmodifiable(_entries.values);

  /// 申报 / 覆盖申报。成功返回 null，失败返回可读原因。
  ///
  /// 失败**不会**破坏该插件上一条有效申报（避免一次坏更新把可用品牌打掉）。
  Future<String?> declare(String pluginId, Object? payload) async {
    final String id = pluginId.trim();
    if (id.isEmpty) return '申报缺少 plugin_id';
    if (payload is! Map) return '申报必须是对象：{icon, role, sizes}';
    final Object? iconValue = payload['icon'];
    if (iconValue is! String || iconValue.trim().isEmpty) {
      return '缺少 icon 路径（相对插件目录或绝对路径）';
    }
    final String rawIcon = iconValue.trim();
    final UiBrandingRole? role = UiBrandingRole.parse(payload['role']);
    if (role == null) return 'role 必须是 exe / window / tray';
    final String lower = rawIcon.toLowerCase();
    if (lower.contains('://') ||
        lower.startsWith('data:') ||
        lower.contains('base64,')) {
      return 'icon 只能是本地文件路径，禁止 URL / base64';
    }
    final String ext = p.extension(rawIcon).toLowerCase();
    if (ext != '.ico' && ext != '.png') {
      return '图标扩展名必须是 .ico 或 .png（收到 ${ext.isEmpty ? '无扩展名' : ext}）';
    }
    if (role == UiBrandingRole.exe && ext != '.ico') {
      return 'role=exe 的图标必须是 .ico（Windows 快捷方式只认 .ico）';
    }
    final List<int>? declaredSizes = _declaredSizes(payload['sizes']);
    if (payload['sizes'] != null && declaredSizes == null) {
      return 'sizes 必须是像素边长的数字数组';
    }

    final String? pathError = await _checkFile(
      rawIcon: rawIcon,
      role: role,
      ext: ext,
    );
    if (pathError != null) return pathError;

    final String resolved = await _resolve(rawIcon);
    final File file = File(resolved);
    final Uint8List bytes = await file.readAsBytes();
    final _IconMeta? meta = _readMeta(ext, bytes);
    if (meta == null) {
      return '图标文件损坏：无法解析 ${ext == '.ico' ? 'ICO 目录' : 'PNG 头'}';
    }
    if (ext == '.ico' && !requiredIcoSizes.every(meta.sizes.contains)) {
      return 'ICO 必须包含 16/32/48/256 四种尺寸（实际：${meta.sizes.join('/')}）';
    }
    if (role == UiBrandingRole.window && !meta.hasAtLeast(minWindowSize)) {
      return '窗口图标必须 ≥32×32（实际最大：${meta.maxSize}×${meta.maxSize}）';
    }
    if (declaredSizes != null &&
        declaredSizes.isNotEmpty &&
        !declaredSizes.every(meta.sizes.contains)) {
      return 'sizes 申报与文件内容不一致（文件实际：${meta.sizes.join('/')}）';
    }

    _entries.remove(id);
    _sequence += 1;
    _entries[id] = UiBrandingEntry(
      pluginId: id,
      iconPath: resolved,
      role: role,
      sizes: meta.sizes,
      sequence: _sequence,
    );
    return null;
  }

  /// 撤回某个插件的申报（停用 / 声明空对象）。
  void retract(String pluginId) {
    _entries.remove(pluginId.trim());
  }

  /// 只保留这些插件（停用 / 卸载后由核心调用）。
  void retainOnly(Set<String> pluginIds) {
    _entries.removeWhere((String id, _) => !pluginIds.contains(id));
  }

  /// 清空（全部撤回 ⇒ 默认品牌）。
  void clear() => _entries.clear();

  /// 应用前重校验：从最新一条往前找第一条仍存在且可读的申报。
  ///
  /// 失效条目会被移除并记一条可读日志（**不静默保留旧图**）；全失效 ⇒ null。
  Future<UiBrandingEntry?> revalidateActive() async {
    final List<UiBrandingEntry> ordered = _entries.values.toList()
      ..sort((UiBrandingEntry a, UiBrandingEntry b) => b.sequence - a.sequence);
    for (final UiBrandingEntry entry in ordered) {
      final String? error = await _checkFile(
        rawIcon: entry.iconPath,
        role: entry.role,
        ext: p.extension(entry.iconPath).toLowerCase(),
        skipRootCheck: false,
      );
      if (error == null) return entry;
      _entries.remove(entry.pluginId);
      log?.call(
        '[core:branding] 品牌失效（${entry.pluginId}）：$error；已回退'
        '${_entries.isEmpty ? '默认品牌' : '上一条申报'}',
      );
    }
    if (_entries.isEmpty) return null;
    return active;
  }

  List<int>? _declaredSizes(Object? value) {
    if (value == null) return const <int>[];
    if (value is! Iterable) return null;
    final List<int> sizes = <int>[];
    for (final Object? item in value) {
      if (item is num) {
        sizes.add(item.toInt());
      } else {
        return null;
      }
    }
    return sizes;
  }

  Future<String?> _checkFile({
    required String rawIcon,
    required UiBrandingRole role,
    required String ext,
    bool skipRootCheck = false,
  }) async {
    final String resolved = await _resolve(rawIcon);
    final File file = File(resolved);
    if (!await file.exists()) return '图标文件不存在：$rawIcon';
    if (!await _isFile(file)) return '图标路径不是文件：$rawIcon';
    final int length = await file.length();
    if (length <= 0) return '图标文件为空：$rawIcon';
    if (length > maxBytes) {
      return '图标超过 256KB（实际 ${(length / 1024).ceil()}KB）：$rawIcon';
    }
    if (!skipRootCheck) {
      final String? rootError = await _checkInsideRoots(resolved);
      if (rootError != null) return rootError;
    }
    // 可读性：真正读一次文件（权限 / 占用 / 损坏都会在这里暴露）。
    try {
      await file.readAsBytes();
    } catch (error) {
      return '图标文件不可读：$rawIcon（$error）';
    }
    return null;
  }

  Future<bool> _isFile(File file) async {
    try {
      return await FileSystemEntity.type(file.path) ==
          FileSystemEntityType.file;
    } catch (_) {
      return false;
    }
  }

  Future<String> _resolve(String rawIcon) async {
    final String? absolute = await _absoluteExisting(rawIcon);
    if (absolute == null) return rawIcon;
    try {
      return await File(absolute).resolveSymbolicLinks();
    } catch (_) {
      return p.normalize(p.absolute(absolute));
    }
  }

  Future<String?> _absoluteExisting(String rawIcon) async {
    if (p.isAbsolute(rawIcon)) return rawIcon;
    for (final String root in _allowedDirs) {
      final String candidate = p.join(root, rawIcon);
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<String?> _checkInsideRoots(String resolved) async {
    if (_allowedDirs.isEmpty) {
      // 没配置插件目录 = 无从证明归属，按"目录外"拒收（fail-closed）。
      return '核心未配置插件目录，无法确认图标归属';
    }
    for (final String root in _allowedDirs) {
      String rootPath = root;
      try {
        rootPath = await Directory(root).resolveSymbolicLinks();
      } catch (_) {
        rootPath = p.normalize(p.absolute(root));
      }
      if (_isUnder(resolved, rootPath)) return null;
    }
    return '图标路径必须落在插件目录内（解析 symlink 后复查）：$resolved';
  }

  static bool _isUnder(String child, String parent) {
    final bool windows = Platform.isWindows;
    final String a = windows ? child.toLowerCase() : child;
    final String b = windows ? parent.toLowerCase() : parent;
    final String normalizedParent = b.endsWith(p.separator) ? b : '$b${p.separator}';
    return a == b || a.startsWith(normalizedParent);
  }
}

class _IconMeta {
  const _IconMeta({required this.sizes, required this.maxSize});

  final List<int> sizes;
  final int maxSize;

  bool hasAtLeast(int minimum) => maxSize >= minimum;
}

/// 解析 ICO 目录 / PNG IHDR。
///
/// ICO：头 6 字节（reserved/type/count），目录项 16 字节；宽高为 0 表示 256。
/// PNG：签名 8 字节 + 长度 4 + `IHDR` + 宽 4 + 高 4（大端）。
_IconMeta? _readMeta(String ext, Uint8List bytes) {
  if (ext == '.png') return _readPngMeta(bytes);
  return _readIcoMeta(bytes);
}

_IconMeta? _readPngMeta(Uint8List bytes) {
  if (bytes.length < 24) return null;
  const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  for (int i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  final int width = _u32(bytes, 16);
  final int height = _u32(bytes, 20);
  final int side = width < height ? width : height;
  return _IconMeta(sizes: <int>[side], maxSize: side);
}

_IconMeta? _readIcoMeta(Uint8List bytes) {
  if (bytes.length < 6) return null;
  final int reserved = _u16(bytes, 0);
  final int type = _u16(bytes, 2);
  final int count = _u16(bytes, 4);
  if (reserved != 0 || type != 1 || count <= 0) return null;
  if (bytes.length < 6 + count * 16) return null;
  final List<int> sizes = <int>[];
  int maxSize = 0;
  for (int i = 0; i < count; i++) {
    final int offset = 6 + i * 16;
    final int width = bytes[offset] == 0 ? 256 : bytes[offset];
    final int height = bytes[offset + 1] == 0 ? 256 : bytes[offset + 1];
    final int side = width < height ? width : height;
    if (!sizes.contains(side)) sizes.add(side);
    if (side > maxSize) maxSize = side;
  }
  sizes.sort();
  return _IconMeta(sizes: sizes, maxSize: maxSize);
}

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
