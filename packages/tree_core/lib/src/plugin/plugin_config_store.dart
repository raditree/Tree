import 'dart:io';

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import 'station_scope.dart';

/// 「<数据根>/config/plugins.yaml」的**读写层**（M9 §4.2 插件开关）。
///
/// 为什么需要它（而不是直接用 PluginBus.load）：
/// - 插件总线的配置是**启动时读一次**进内存的（PluginBus.load 幂等），所以
///   "前端改了配置"必须有一层负责**落盘 + 校验**，再由调用方决定怎么热应用；
/// - 插件条目是**用户可直接手改**的 YAML：写回时必须保留未知键与其它条目
///   （用户在文件里加的自定义键、别的插件的条目、顶层未知键都不能被这次编辑吃掉），
///   否则"改一个开关"会把文件改瘦成核心认识的形状。
///
/// 因此本类**不用 PluginConfig.fromJson 做中转**（它会丢掉未知键），而是直接在
/// 原始 Map 上做"读 → 改 → 原子写"。PluginBus 仍按自己的口径解析这份文件。
///
/// 落盘是**原子写**（先写 .tmp 再改名，见 AtomicFile）：任何时刻磁盘上要么是
/// 旧内容、要么是新内容，不会是半截配置。
///
/// 校验口径（全部返回**可读中文原因**，不抛异常）：
/// - id：非空、唯一、只允许 [A-Za-z0-9_.-]（防止 id 被当成路径分段用）；
/// - command：非空（命令字段 = 可以用 UI 拉起任意进程，这是插件系统的固有能力）；
/// - granularity：team / agent / session；
/// - scope：键白名单 team_id / agent_id / session_id / mode_key，mode_key 属于 local / ssh；
/// - args：字符串数组；env：字符串到字符串的映射；enabled / builtin：布尔。
class PluginConfigStore {
  PluginConfigStore(this.path, {this.log});

  /// plugins.yaml 的绝对路径（由 PluginBus.configFile 或 TreePaths 给出）。
  final String path;

  /// 诊断日志（解析失败等；null = 不记录）。
  final void Function(String message)? log;

  /// 文件名（与 TreePaths.pluginsConfigFile 一致）。
  static const String fileName = 'plugins.yaml';

  /// 允许的实例粒度（与 PluginConfig.granularity 的契约一致）。
  static const Set<String> granularities = <String>{'team', 'agent', 'session'};

  /// scope 允许的键（白名单：多出来的键一律拒绝，避免用户以为"写了就生效"）。
  static const Set<String> scopeKeys = <String>{
    'team_id',
    'agent_id',
    'session_id',
    'mode_key',
  };

  /// 条目的规范字段顺序（写回时的排版；未知键排在后面且原样保留）。
  static const List<String> canonicalFields = <String>[
    'id',
    'name',
    'command',
    'args',
    'env',
    'enabled',
    'granularity',
    'scope',
  ];

  /// id 允许的字符集：与 TreePaths.safeSegment 同口径（不含路径分隔符与 ..）。
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

  // ── 读 ───────────────────────────────────────────────────────────────

  /// 读整份文档（**顶层未知键原样保留**；文件不存在 / 空文件 = 空文档）。
  Map<String, dynamic> readDocument() {
    final String? text = AtomicFile.readStringOrNullSync(path);
    if (text == null || text.trim().isEmpty) return <String, dynamic>{};
    try {
      return YamlCodec.decode(text);
    } catch (error) {
      // 文件被手工改坏：读不出内容就按空文档处理，但**必须可见**——
      // 静默当成空配置会让用户以为"我写的插件被吞了"。
      log?.call('插件配置解析失败（$path）：$error');
      return <String, dynamic>{};
    }
  }

  /// 总开关（顶层 enabled；缺省 true，与 PluginBus.load 同口径）。
  bool totalEnabled() {
    final Map<String, dynamic> doc = readDocument();
    return doc['enabled'] != false;
  }

  /// 全部条目（只取 Map 项；坏条目跳过，但写回时**不会**丢它们，见 [_rawEntries]）。
  List<Map<String, dynamic>> readEntries() {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Object? item in _rawEntries(readDocument())) {
      if (item is Map) out.add(_asMap(item));
    }
    return out;
  }

  /// 单条条目（原始 Map，未知键保留）；不存在返回 null。
  Map<String, dynamic>? readEntry(String id) {
    final String wanted = id.trim();
    for (final Object? item in _rawEntries(readDocument())) {
      if (item is! Map) continue;
      final Map<String, dynamic> entry = _asMap(item);
      if ((entry['id'] ?? '').toString() == wanted) return entry;
    }
    return null;
  }

  // ── 写（全部返回可读结果，不抛异常） ──────────────────────────────────

  /// 新增一条（id 必须唯一）。
  PluginStoreResult create(Map<String, dynamic> input) {
    // 校验必须在**规范化之前**：规范化会把 args / env 的取值转成字符串，
    // 先规范化就等于把"类型写错了"洗成"类型正确"，用户永远看不到那条错误。
    final String? invalid = validateEntry(input);
    if (invalid != null) return PluginStoreResult.failure(invalid);
    final Map<String, dynamic> entry = _normalize(input);

    final Map<String, dynamic> doc = readDocument();
    final List<Object?> raw = _rawEntries(doc);
    for (final Object? item in raw) {
      if (item is! Map) continue;
      if ((_asMap(item)['id'] ?? '').toString() == entry['id']) {
        return PluginStoreResult.failure(
          '插件 id 已存在：${entry['id']}（如需修改请用编辑，或换一个 id）',
        );
      }
    }
    raw.add(entry);
    return _commit(doc, raw, entry);
  }

  /// 局部更新一条（只覆盖 [patch] 里出现的键；未知键与其它条目原样保留）。
  PluginStoreResult update(String id, Map<String, dynamic> patch) {
    final String wanted = id.trim();
    final Map<String, dynamic> doc = readDocument();
    final List<Object?> raw = _rawEntries(doc);
    final int index = _indexOf(raw, wanted);
    if (index < 0) return PluginStoreResult.failure('插件不存在：$wanted');

    final Map<String, dynamic> merged = _asMap(raw[index]);
    final Object? newId = patch['id'];
    if (newId != null && newId.toString() != wanted) {
      // id 是条目的身份（站点订阅 / 工具命名空间 / 运行实例都以它为准），
      // 允许改名会留下"旧实例还在跑"的悬空状态，所以直接拒绝。
      return PluginStoreResult.failure('不能修改插件 id（$wanted → $newId）：请删除后重新添加');
    }
    for (final MapEntry<String, dynamic> e in patch.entries) {
      if (e.key == 'id') continue;
      merged[e.key] = e.value;
    }
    final String? invalid = validateEntry(merged);
    if (invalid != null) return PluginStoreResult.failure(invalid);
    final Map<String, dynamic> entry = _normalize(merged);

    raw[index] = entry;
    return _commit(doc, raw, entry);
  }

  /// 删除一条。
  PluginStoreResult remove(String id) {
    final String wanted = id.trim();
    final Map<String, dynamic> doc = readDocument();
    final List<Object?> raw = _rawEntries(doc);
    final int index = _indexOf(raw, wanted);
    if (index < 0) return PluginStoreResult.failure('插件不存在：$wanted');
    raw.removeAt(index);
    return _commit(doc, raw, null);
  }

  /// 置某条的启用态（**条目保留**——面板要显示「已停用」而不是让它消失）。
  PluginStoreResult setEnabled(String id, bool enabled) =>
      update(id, <String, dynamic>{'enabled': enabled});

  /// 写入 / 覆盖一条**由核心生成**的条目（内置插件开关用；同名条目整体替换，
  /// 但保留原有条目里的未知键，例如用户自己加的备注）。
  PluginStoreResult upsert(Map<String, dynamic> input) {
    final String? invalid = validateEntry(input);
    if (invalid != null) return PluginStoreResult.failure(invalid);
    final Map<String, dynamic> entry = _normalize(input);

    final Map<String, dynamic> doc = readDocument();
    final List<Object?> raw = _rawEntries(doc);
    final int index = _indexOf(raw, entry['id'].toString());
    if (index < 0) {
      raw.add(entry);
    } else {
      final Map<String, dynamic> merged = _asMap(raw[index]);
      for (final MapEntry<String, dynamic> e in entry.entries) {
        merged[e.key] = e.value;
      }
      raw[index] = _normalize(merged);
    }
    return _commit(doc, raw, entry);
  }

  // ── 校验 ─────────────────────────────────────────────────────────────

  /// 校验单条条目；通过返回 null，否则返回可读中文原因（供 REST 直接回给前端）。
  static String? validateEntry(Map<String, dynamic> entry) {
    final String id = (entry['id'] ?? '').toString().trim();
    if (id.isEmpty) return '插件 id 不能为空';
    if (id == '.' || id == '..' || !_idPattern.hasMatch(id)) {
      return '插件 id 只允许字母、数字、下划线、点和连字符：$id';
    }
    final String command = (entry['command'] ?? '').toString();
    if (command.trim().isEmpty) {
      return '插件 $id 的 command 不能为空（这是要拉起的可执行文件）';
    }
    final Object? name = entry['name'];
    if (name != null && name is! String) {
      return '插件 $id 的 name 必须是字符串';
    }

    final Object? enabled = entry['enabled'];
    if (enabled != null && enabled is! bool) {
      return '插件 $id 的 enabled 必须是布尔值';
    }
    final Object? builtin = entry['builtin'];
    if (builtin != null && builtin is! bool) {
      return '插件 $id 的 builtin 必须是布尔值';
    }

    final String granularity = (entry['granularity'] ?? 'team').toString();
    if (!granularities.contains(granularity)) {
      final String allowed = granularities.join(' / ');
      return '插件 $id 的 granularity 必须是 $allowed 之一，当前是「$granularity」';
    }

    final Object? args = entry['args'];
    if (args != null) {
      if (args is! List) {
        return '插件 $id 的 args 必须是字符串数组（每行一个参数）';
      }
      for (final Object? a in args) {
        if (a is! String) {
          return '插件 $id 的 args 必须是字符串数组（发现非字符串项：$a）';
        }
      }
    }

    final Object? env = entry['env'];
    if (env != null) {
      if (env is! Map) {
        return '插件 $id 的 env 必须是字符串映射（KEY=VALUE）';
      }
      for (final MapEntry<Object?, Object?> e in env.entries) {
        if (e.key is! String || e.value is! String) {
          return '插件 $id 的 env 必须是字符串到字符串的映射（KEY=VALUE），'
              '发现「${e.key}」的类型不合法';
        }
      }
    }

    final Object? scope = entry['scope'];
    if (scope != null) {
      if (scope is! Map) {
        return '插件 $id 的 scope 必须是映射（空映射 = 不限定归属）';
      }
      final String allowed = scopeKeys.join(' / ');
      for (final MapEntry<Object?, Object?> e in scope.entries) {
        final String key = e.key.toString();
        if (!scopeKeys.contains(key)) {
          return '插件 $id 的 scope 含未知键「$key」：'
              '只允许 $allowed（各键留空 = 不限定）';
        }
        final Object? rawValue = e.value;
        final String value = rawValue?.toString() ?? '';
        if (key == 'mode_key' &&
            value.isNotEmpty &&
            !StationModeKey.isValid(value)) {
          return '插件 $id 的 scope.mode_key 只能是 local / ssh，当前是「$value」';
        }
        if (rawValue != null && rawValue is! String) {
          return '插件 $id 的 scope.$key 必须是字符串（留空 = 不限定）';
        }
      }
    }
    return null;
  }

  // ── 内部 ─────────────────────────────────────────────────────────────

  /// 原始 plugins 列表（**保持磁盘上的原样**：非 Map 的坏条目也在里面，
  /// 这样"编辑一条"不会顺手把用户写的其它东西删掉）。
  static List<Object?> _rawEntries(Map<String, dynamic> doc) {
    final Object? raw = doc['plugins'];
    if (raw is List) return List<Object?>.of(raw);
    return <Object?>[];
  }

  static Map<String, dynamic> _asMap(Object? item) {
    if (item is Map) {
      return item.map((Object? k, Object? v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  /// 按 id 找下标（找不到 -1）。
  static int _indexOf(List<Object?> raw, String id) {
    for (int i = 0; i < raw.length; i++) {
      final Object? item = raw[i];
      if (item is! Map) continue;
      if ((_asMap(item)['id'] ?? '').toString() == id) return i;
    }
    return -1;
  }

  /// 规范化：补齐缺省值、键按 [canonicalFields] 排序，**未知键原样保留**。
  static Map<String, dynamic> _normalize(Map<String, dynamic> input) {
    final Map<String, dynamic> src = _asMap(input);
    final Map<String, dynamic> out = <String, dynamic>{};
    out['id'] = (src['id'] ?? '').toString().trim();
    out['name'] = (src['name'] ?? '').toString();
    out['command'] = (src['command'] ?? '').toString();
    final Object? rawArgs = src['args'];
    out['args'] = rawArgs is List
        ? <String>[for (final Object? a in rawArgs) a.toString()]
        : <String>[];
    final Object? rawEnv = src['env'];
    out['env'] = rawEnv is Map
        ? <String, String>{
            for (final MapEntry<Object?, Object?> e in rawEnv.entries)
              e.key.toString(): e.value?.toString() ?? '',
          }
        : <String, String>{};
    out['enabled'] = src['enabled'] != false;
    out['granularity'] = (src['granularity'] ?? 'team').toString();
    final Map<String, dynamic> scope = <String, dynamic>{};
    final Object? rawScope = src['scope'];
    if (rawScope is Map) {
      for (final MapEntry<Object?, Object?> e in rawScope.entries) {
        scope[e.key.toString()] = e.value ?? '';
      }
    }
    out['scope'] = scope;
    // 未知键（含 builtin 标记、用户自己加的备注）排在规范字段之后
    for (final MapEntry<String, dynamic> e in src.entries) {
      if (canonicalFields.contains(e.key)) continue;
      out[e.key] = e.value;
    }
    return out;
  }

  /// 落盘 + 返回结果。写文件是**原子写**；写失败如实返回可读原因。
  PluginStoreResult _commit(
    Map<String, dynamic> doc,
    List<Object?> raw,
    Map<String, dynamic>? entry,
  ) {
    final Map<String, dynamic> out = <String, dynamic>{
      'enabled': doc['enabled'] != false,
      'plugins': raw,
    };
    // 其它顶层未知键原样保留
    for (final MapEntry<String, dynamic> e in doc.entries) {
      if (e.key == 'enabled' || e.key == 'plugins') continue;
      out[e.key] = e.value;
    }
    try {
      AtomicFile.writeStringAtomicSync(
        path,
        YamlCodec.encode(out, header: _header),
      );
    } on FileSystemException catch (error) {
      return PluginStoreResult.failure('写入插件配置失败：${error.message}（$path）');
    }
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    for (final Object? item in raw) {
      if (item is Map) entries.add(_asMap(item));
    }
    return PluginStoreResult.success(entry, entries);
  }

  /// 写回时的文件头（说明这份文件是什么、怎么改、怎么生效）。
  static const String _header =
      'Tree 插件清单（M9 §4.2：内置与自定义插件各有一个开关）\n'
      'enabled: 插件系统总开关（与每个插件各自的 enabled 是两层）。\n'
      'plugins: 每个插件一项；enabled=false 表示停用但**条目保留**。\n'
      'builtin: true 的条目由核心的内置插件清单生成（在界面上开关内置插件时写入），\n'
      '        可以改，但下次在界面上开关该内置插件时会被重新解析覆盖。\n'
      '本文件可手工编辑；界面上的改动保存后会立即热应用，热应用失败时重启核心生效。';
}

/// 一次写操作的结果：成功 = 落盘后的条目与全部条目；失败 = 可读中文原因。
class PluginStoreResult {
  const PluginStoreResult._(this.ok, this.error, this.entry, this.entries);

  /// 成功（[entry] 为本次写入的条目；[entries] 为落盘后的全部条目）。
  factory PluginStoreResult.success(
    Map<String, dynamic>? entry,
    List<Map<String, dynamic>> entries,
  ) => PluginStoreResult._(true, '', entry, entries);

  /// 失败（[error] 为可直接回给前端的中文原因）。
  factory PluginStoreResult.failure(String error) =>
      PluginStoreResult._(false, error, null, const <Map<String, dynamic>>[]);

  final bool ok;
  final String error;
  final Map<String, dynamic>? entry;
  final List<Map<String, dynamic>> entries;
}
