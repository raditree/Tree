import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'plugin_config_store.dart';

/// 随包插件索引的文件名（与 `tool/build_plugins.dart` 的落点一致）。
const String kBundledPluginIndexName = 'plugin-index.json';

/// 随包插件条目的来源标记（展示用；与发布仓库安装的 `release` / 本地 zip 区分）。
const String kBundledPluginSourceValue = 'bundled';

/// 条目上记录「上次随包登记时的成品指纹」（文件长度 + 内容哈希）。
/// 版本号没变但重新构建了二进制时，靠它识别出字节变化。
const String kBundledDigestKey = 'bundled_digest';

/// 条目上记录「上次随包登记时的用户可改字段签名」（command / args / env / scope）。
/// 现状与它不一致 ⇒ 用户手改过 ⇒ 不覆盖。
const String kBundledSnapshotKey = 'bundled_snapshot';

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
/// - **目录形态**（带到 `data/` 与几十个 dll 的 UI 插件）：索引给 `archive` +
///   `archive_bytes`，本函数把压缩包解到 `plugins/<id>/` 再登记，命令指向解出来的
///   那份；`enabled` 默认 **false**（替代界面不该在用户没点过的情况下自己弹窗）。
/// - `plugins.yaml` 里**没有**这一条 ⇒ 新登记；已有 `source: bundled` 的条目按
///   「版本或成品指纹变化」**原地升级**；用户手改过的（签名对不上）与别的来源
///   （local / release）一律不动。
///
/// 升级只改核心生成的字段，`enabled` 保留用户当前开关；`args/env/scope/command`
/// 一旦被用户改过就整体跳过（签名不一致），不猜哪几个键该保留。
///
/// 幂等：重复调用（每次核心启动）在版本与指纹都没变时不写盘。首次遇到没有指纹的
/// 存量条目只记录基线（不升级），从下一次启动起参与升级判定。
/// 返回本次真正写入（新登记或原地升级）的 id 列表（空 = 什么都没做）。
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
    // 扁平 UI 条目（只有 exe、没有 data/ 与 dll）不是完整界面：默认界面由
    // seedDesktopUiPlugin 单独管，索引里误放也不在这里登记；目录形态（archive）
    // 才是可随包分发的替代界面（如飞书悬浮球），下面按「默认停用」登记。
    if (entry.runtime == 'ui' && entry.archive.isEmpty) continue;
    final Map<String, dynamic>? existing = store.readEntry(entry.id);
    if (existing == null) {
      final String? missing = entry.missingArtifact(dir);
      if (missing != null) {
        log?.call('随包插件 ${entry.id} 跳过：$missing');
        continue;
      }
      if (entry.archive.isNotEmpty) {
        final String? error = _installArchive(entry, dir);
        if (error != null) {
          log?.call('随包插件 ${entry.id} 跳过：$error');
          continue;
        }
      }
      final Map<String, dynamic> config = entry.toConfigEntry(
        dir,
        source: kBundledPluginSourceValue,
      );
      final String digest = _artifactDigest(entry, dir);
      config[kBundledDigestKey] = digest;
      config[kBundledSnapshotKey] = _entrySignature(config);
      final PluginStoreResult result = store.create(config);
      if (!result.ok) {
        log?.call('随包插件 ${entry.id} 登记失败：${result.error}');
        continue;
      }
      seeded.add(entry.id);
      continue;
    }

    // **路径失效修复**（不换版本、只改指向）：安装方式混用后最常见的一种死法 ——
    // 先按目录形态（`plugins/<id>/<exe>`）装过，后来全量包把成品换成扁平
    // （`plugins/<exe>`）并清掉了旧目录；`plugins.yaml` 仍指旧路，核心每次启动
    // 都只报「系统找不到指定的文件」，对用户来说就是“插件坏了”。
    //
    // 口径刻意收得比升级更紧：
    // - 只在**命令指向的文件真的不在盘上**时动手（可用路径一律不碰，含用户的
    //   `source: local` 自建版本）；
    // - 只在随包成品**齐且字节数对**时动手（不写一条注定起不来的配置）；
    // - 只在**版本一致**时动手：条目没写版本、或与随包版本不同，都说明“盘上那份
    //   不是这一条对应的成品”，替用户换就是在擅自升降级 —— 只留一行日志。
    // 修完不参与下面的随包升级判定（来源仍是用户/发布源的，核心不替它换代）。
    final String storedCommand = '${existing['command'] ?? ''}'.trim();
    if (storedCommand.isEmpty || !File(storedCommand).existsSync()) {
      final String storedVersion = '${existing['repo_version'] ?? ''}'.trim();
      final String? missing = entry.missingArtifact(dir);
      if (missing != null) {
        log?.call('插件 ${entry.id} 的命令已失效，随包成品也不可用：$missing');
      } else if (storedVersion.isEmpty || storedVersion != entry.version) {
        log?.call(
          '插件 ${entry.id} 的命令已失效，但版本无法确认'
          '（条目 ${storedVersion.isEmpty ? '未写' : storedVersion}'
          ' ≠ 随包 ${entry.version}）：不改它的路径',
        );
      } else {
        String? installError;
        if (entry.archive.isNotEmpty) {
          installError = _installArchive(entry, dir);
        }
        if (installError != null) {
          log?.call('插件 ${entry.id} 命令修复失败：$installError');
        } else {
          final String repaired = entry.commandPath(dir);
          final PluginStoreResult result = store.update(
            entry.id,
            <String, dynamic>{'command': repaired},
          );
          if (result.ok) {
            seeded.add(entry.id);
            log?.call('插件 ${entry.id} 的命令已失效，已重指到随包成品：$repaired');
          } else {
            log?.call('插件 ${entry.id} 命令修复失败：${result.error}');
          }
        }
      }
      continue;
    }

    // 只有「随包登记」的条目才参与原地升级：local / release 是用户自己的安装，
    // 命令指向哪、版本多少都由用户/发布源决定，核心不能替它换二进制。
    if ('${existing['source'] ?? ''}'.trim() != kBundledPluginSourceValue) {
      continue;
    }
    final String? missing = entry.missingArtifact(dir);
    if (missing != null) {
      log?.call('随包插件 ${entry.id} 跳过升级：$missing');
      continue;
    }
    final String digest = _artifactDigest(entry, dir);
    final String storedDigest = '${existing[kBundledDigestKey] ?? ''}'.trim();
    final String storedSnapshot = '${existing[kBundledSnapshotKey] ?? ''}'.trim();

    // 存量条目（本特性上线前登记的）没有基线：只记录基线，不冒然覆盖——
    // 没有历史签名就无法证明用户没手改过。本次不升级，从下次启动起参与判定。
    if (storedSnapshot.isEmpty) {
      final PluginStoreResult baseline = store.update(entry.id, <String, dynamic>{
        kBundledDigestKey: digest,
        kBundledSnapshotKey: _entrySignature(existing),
      });
      if (!baseline.ok) {
        log?.call('随包插件 ${entry.id} 记录升级基线失败：${baseline.error}');
      } else {
        log?.call('随包插件 ${entry.id} 已记录升级基线（本次不升级）');
      }
      continue;
    }
    // 用户手改过（命令 / 参数 / 环境变量 / scope 与上次登记时不一致）⇒ 原样不动。
    if (storedSnapshot != _entrySignature(existing)) {
      log?.call('随包插件 ${entry.id} 跳过升级：条目已被用户修改');
      continue;
    }

    final String version = '${existing['repo_version'] ?? ''}'.trim();
    final bool versionChanged =
        entry.version.isNotEmpty && entry.version != version;
    final bool bytesChanged = storedDigest != digest;
    if (!versionChanged && !bytesChanged) continue;

    if (entry.archive.isNotEmpty) {
      final String? error = _installArchive(entry, dir);
      if (error != null) {
        log?.call('随包插件 ${entry.id} 升级失败：$error');
        continue;
      }
    }
    final Map<String, dynamic> next = entry.toConfigEntry(
      dir,
      source: kBundledPluginSourceValue,
    );
    // 开关是用户状态，不是随包内容：升级时保留（停用的插件升级后仍停用）。
    next['enabled'] = existing['enabled'] != false;
    next[kBundledDigestKey] = digest;
    next[kBundledSnapshotKey] = _entrySignature(next);
    final PluginStoreResult result = store.upsert(next);
    if (!result.ok) {
      log?.call('随包插件 ${entry.id} 升级失败：${result.error}');
      continue;
    }
    seeded.add(entry.id);
    log?.call(
      '随包插件 ${entry.id} 已原地升级'
      '（${version.isEmpty ? '?' : version} → ${entry.version.isEmpty ? digest : entry.version}）',
    );
  }
  return seeded;
}

/// 把索引声明的压缩包解到 `plugins/<id>/`（目录形态的插件，主要是 UI）。
///
/// 先解到临时目录再整体换位：解包失败时旧目录保持原样（Windows 上正在运行的
/// 插件会锁 exe/dll，替换失败就留到下次启动再试，绝不接受半截目录）。
/// 返回 null = 成功且 command 已在解出来的目录里；否则是可读原因。
String? _installArchive(_BundledEntry entry, String dir) {
  final File zip = File(p.join(dir, entry.archive));
  final Directory target = Directory(p.join(dir, entry.id));
  final Directory staging = Directory(p.join(dir, '.${entry.id}.installing'));
  try {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final Archive archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    for (final ArchiveFile file in archive) {
      if (!file.isFile) continue;
      final String? name = _normalizeArchiveName(file.name);
      if (name == null) return '压缩包里有越界路径：${file.name}';
      final File out = File(p.join(staging.path, name));
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(file.content as List<int>);
    }
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
  } catch (error) {
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清不掉不影响主流程：下次启动会先清再解。
    }
    return '解包失败（${entry.archive}）：$error';
  }
  if (entry.command.isEmpty) return '索引没有声明 command';
  final File command = File(p.join(target.path, entry.command));
  if (!command.existsSync()) return '压缩包里没有 command：${entry.command}';
  return null;
}

/// zip 条目名归一化：只接受相对路径，丢掉 `./` 与空段，拒绝 `..` / 盘符 / 绝对路径。
String? _normalizeArchiveName(String raw) {
  final String name = raw.replaceAll('\\', '/');
  if (name.isEmpty || name.startsWith('/') || name.contains(':')) return null;
  final List<String> parts = <String>[];
  for (final String part in name.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') return null;
    parts.add(part);
  }
  if (parts.isEmpty) return null;
  return parts.join('/');
}

/// 成品指纹：按 target 排序后对每个文件取「长度 + 内容哈希」。
///
/// 只读随包目录里的成品（几 MB），在「已有 source: bundled 条目」时才计算；
/// 用 FNV-1a 32 位而不是引入 crypto 依赖：这里只需要“变了没有”，不需要密码学强度。
String _artifactDigest(_BundledEntry entry, String dir) {
  if (entry.archive.isNotEmpty) {
    final File zip = File(p.join(dir, entry.archive));
    final List<int> bytes = zip.readAsBytesSync();
    return '${entry.archive}:${bytes.length}:${_fnvHex(bytes)};';
  }
  final List<String> targets = entry.files.keys.toList()..sort();
  final StringBuffer out = StringBuffer();
  for (final String target in targets) {
    final File file = File(p.join(dir, target));
    final List<int> bytes = file.readAsBytesSync();
    out.write('$target:${bytes.length}:${_fnvHex(bytes)};');
  }
  return out.toString();
}

/// 用户可改字段的签名：command / args / env / scope。
///
/// 只挑这四个键，是因为它们是用户最可能手改的（换成本地构建、加参数、改环境、
/// 限定 scope）；name/description/requires 属于随包声明，升级时理应跟着索引走。
/// 键顺序、map 顺序全部规范化，避免 YAML 重排造成“看起来改了”。
String _entrySignature(Map<String, dynamic> entry) {
  final Object? rawArgs = entry['args'];
  final List<String> args = rawArgs is List
      ? <String>[for (final Object? a in rawArgs) '$a']
      : const <String>[];
  final Map<String, String> env = _stringMap(entry['env']);
  final Map<String, String> scope = _stringMap(entry['scope']);
  return _fnvHex(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'command': '${entry['command'] ?? ''}',
        'args': args,
        'env': <String, String>{
          for (final String k in (env.keys.toList()..sort())) k: env[k]!,
        },
        'scope': <String, String>{
          for (final String k in (scope.keys.toList()..sort())) k: scope[k]!,
        },
      }),
    ),
  );
}

Map<String, String> _stringMap(Object? raw) => raw is Map
    ? <String, String>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': '${e.value ?? ''}',
      }
    : <String, String>{};

String _fnvHex(List<int> bytes) {
  int hash = 0x811c9dc5;
  for (final int b in bytes) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
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
    this.archive = '',
    this.archiveBytes = 0,
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

  /// 目录形态的插件包（UI 带 `data/` 与几十个 dll，扁平装不下）：
  /// 压缩包放在 `plugins/` 下，解到 `plugins/<id>/` 后 command 再指向里面。
  final String archive;
  final int archiveBytes;

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
      archive: '${json['archive'] ?? ''}'.trim(),
      archiveBytes: (json['archive_bytes'] as num?)?.toInt() ?? 0,
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
    if (archive.isNotEmpty) {
      final File zip = File(p.join(dir, archive));
      if (!zip.existsSync()) return '插件包不在盘上：$archive';
      if (archiveBytes > 0 && zip.lengthSync() != archiveBytes) {
        return '插件包字节数不符：$archive'
            '（${zip.lengthSync()} ≠ $archiveBytes）';
      }
      if (command.isEmpty) return '索引没有声明 command';
      return null;
    }
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

  /// 配置里 command 该落的绝对路径：目录形态在 `plugins/<id>/` 里，扁平就在 `plugins/`。
  String commandPath(String dir) =>
      archive.isNotEmpty ? p.join(dir, id, command) : p.join(dir, command);

  Map<String, dynamic> toConfigEntry(String dir, {required String source}) =>
      <String, dynamic>{
        'id': id,
        'name': name.isEmpty ? id : name,
        if (description.isNotEmpty) 'description': description,
        // 索引里的 command 是纯文件名（构建链已校验），落盘必须换成绝对路径：
        // 核心拉起插件时不经过 shell，相对路径会按“核心的工作目录”解析。
        'command': commandPath(dir),
        'args': args,
        'env': <String, String>{},
        // 替代界面（runtime: ui）随包登记时默认停用：全量包不该在用户没点过
        // 的情况下多弹一个窗口/悬浮球。无头插件维持“装了就能用”的既有口径。
        'enabled': runtime != 'ui',
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
