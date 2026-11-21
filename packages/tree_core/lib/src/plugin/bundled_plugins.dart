import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'plugin_config_store.dart';

/// 随包插件索引的文件名（与 `tool/build_plugins.dart` 的落点一致）。
const String kBundledPluginIndexName = 'plugin-index.json';

/// 随包插件条目的来源标记（展示用；与发布仓库安装的 `release` / 本地 zip 区分）。
const String kBundledPluginSourceValue = 'bundled';

/// 「全量版」安装包：把**已经在 exe 同级 `plugins/` 里的成品**登记进 `plugins.yaml`。
///
/// 为什么需要它：普通发行版刻意不带插件成品（装机后从发布仓库装）；全量版把成品与
/// `plugin-index.json` 一起放进 `plugins/`，但核心只认 `plugins.yaml` 里的条目——
/// 不登记的话，文件在盘上却永远不会被拉起，用户还以为“包是坏的”。
///
/// 触发条件全部是**本机事实**（不靠环境变量开关）：
/// - `<exeDir>/plugins/plugin-index.json` 存在（只有全量版会带它）；
/// - 该条目声明的每个 `files[].target` 都真在 `plugins/` 里，且字节数与索引一致
///   （打包链漏拷 / 半截文件 ⇒ 不写一条注定起不来的配置）；
/// - `plugins.yaml` 里**没有**这一条（用户的开关、env、手改一律优先，绝不覆盖）。
///
/// 幂等：重复调用（每次核心启动）只补缺失的条目，已有条目原样不动。返回本次真正
/// 写入的 id 列表（空 = 什么都没做）。
List<String> seedBundledPlugins({
  required PluginConfigStore store,
  String? executableDir,
  void Function(String message)? log,
}) {
  final String dir = p.join(
    executableDir ?? p.dirname(Platform.resolvedExecutable),
    'plugins',
  );
  final File indexFile = File(p.join(dir, kBundledPluginIndexName));
  if (!indexFile.existsSync()) return const <String>[];

  final Object? decoded;
  try {
    decoded = jsonDecode(indexFile.readAsStringSync());
  } catch (error) {
    log?.call('随包插件索引读不动（${indexFile.path}）：$error');
    return const <String>[];
  }
  if (decoded is! Map) {
    log?.call('随包插件索引格式不对（${indexFile.path}）：顶层不是对象');
    return const <String>[];
  }
  final Object? rawPlugins = decoded['plugins'];
  if (rawPlugins is! List) {
    log?.call('随包插件索引格式不对（${indexFile.path}）：缺少 plugins 数组');
    return const <String>[];
  }

  // 构建链按“一个产物一条”写索引，多文件插件会出现同 id 多条：先按 id 合并。
  final Map<String, _BundledEntry> byId = <String, _BundledEntry>{};
  for (final Object? item in rawPlugins) {
    if (item is! Map) continue;
    final _BundledEntry? entry = _BundledEntry.parse(item);
    if (entry == null) continue;
    byId.putIfAbsent(entry.id, () => entry).mergeFiles(item);
  }

  final List<String> seeded = <String>[];
  for (final _BundledEntry entry in byId.values) {
    if (entry.runtime == 'ui') continue; // 界面走 seedDesktopUiPlugin，不在这里登记
    if (store.readEntry(entry.id) != null) continue; // 已落盘（开或关）⇒ 尊重现状
    final String? missing = entry.missingArtifact(dir);
    if (missing != null) {
      log?.call('随包插件 ${entry.id} 跳过：$missing');
      continue;
    }
    final PluginStoreResult result = store.create(
      entry.toConfigEntry(dir, source: kBundledPluginSourceValue),
    );
    if (!result.ok) {
      log?.call('随包插件 ${entry.id} 登记失败：${result.error}');
      continue;
    }
    seeded.add(entry.id);
  }
  return seeded;
}

/// 索引里的一条（字段口径与 `PluginDownloader` 读发布索引完全一致）。
class _BundledEntry {
  _BundledEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.runtime,
    required this.command,
    required this.args,
    required this.granularity,
    required this.scope,
    required this.suspension,
    required this.requires,
    required this.files,
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final String runtime;
  final String command;
  final List<String> args;
  final String granularity;
  final Map<String, dynamic> scope;
  final String suspension;
  final Object? requires;

  /// target → 声明字节数（0 = 不校验）。
  final Map<String, int> files;

  static _BundledEntry? parse(Map<dynamic, dynamic> json) {
    final String id = '${json['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    return _BundledEntry(
      id: id,
      name: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      version: '${json['version'] ?? ''}',
      runtime: '${json['runtime'] ?? ''}',
      command: '${json['command'] ?? ''}',
      args: json['args'] is List
          ? (json['args'] as List<Object?>).map((Object? e) => '$e').toList()
          : const <String>[],
      granularity: '${json['granularity'] ?? 'team'}',
      scope: json['scope'] is Map
          ? (json['scope'] as Map<Object?, Object?>).map(
              (Object? k, Object? v) =>
                  MapEntry<String, dynamic>('$k', v),
            )
          : <String, dynamic>{},
      suspension: '${json['suspension'] ?? ''}',
      requires: json['requires'],
      files: _readFiles(json['files']),
    );
  }

  static Map<String, int> _readFiles(Object? raw) {
    final Map<String, int> out = <String, int>{};
    if (raw is! List) return out;
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final String target = '${item['target'] ?? ''}'.trim();
      if (target.isEmpty || target.contains('/') || target.contains('\\')) {
        continue;
      }
      out[target] = (item['bytes'] as num?)?.toInt() ?? 0;
    }
    return out;
  }

  /// 多文件插件的索引是“一个产物一条”：把后续条目里的 files 合并进来。
  void mergeFiles(Map<dynamic, dynamic> json) {
    files.addAll(_readFiles(json['files']));
  }

  /// 返回第一个不可用的原因（null = 成品齐且字节数对得上）。
  String? missingArtifact(String dir) {
    if (files.isEmpty) return '索引里没有 files 声明';
    if (command.isEmpty || !files.containsKey(command)) {
      return 'command（$command）不在 files 里';
    }
    for (final MapEntry<String, int> file in files.entries) {
      final File artifact = File(p.join(dir, file.key));
      if (!artifact.existsSync()) return '成品不在盘上：${file.key}';
      final int declared = file.value;
      if (declared > 0 && artifact.lengthSync() != declared) {
        return '成品字节数不符：${file.key}'
            '（${artifact.lengthSync()} ≠ $declared）';
      }
    }
    return null;
  }

  Map<String, dynamic> toConfigEntry(String dir, {required String source}) =>
      <String, dynamic>{
        'id': id,
        'name': name.isEmpty ? id : name,
        if (description.isNotEmpty) 'description': description,
        // 索引里的 command 是纯文件名（构建链已校验），落盘必须换成绝对路径：
        // 核心拉起插件时不经过 shell，相对路径会按“核心的工作目录”解析。
        'command': p.join(dir, command),
        'args': args,
        'env': <String, String>{},
        'enabled': true,
        'granularity': granularity,
        'scope': scope,
        if (suspension.isNotEmpty) 'suspension': suspension,
        if (requires != null) 'requires': requires,
        if (runtime.isNotEmpty) 'runtime': runtime,
        // 展示用来源标记：与发布仓库（release）/ 本地 zip 安装区分开。
        'source': source,
        if (version.isNotEmpty) 'repo_version': version,
      };
}
