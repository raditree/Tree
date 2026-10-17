/// 编译 **`plugins/` 仓里的全部插件**到 `build/plugins/`，并按发布合同产出索引。
///
/// 用法：
///   dart run tool/build_plugins.dart                 # 全编 + 逐个 --selftest + 写索引
///   dart run tool/build_plugins.dart --only compact  # 只编一个（开发回路）
///   dart run tool/build_plugins.dart --skip-selftest # 只编译（CI 里先验编译面）
///   dart run tool/build_plugins.dart --out 目录 --index 文件  # 改产物目录 / 索引落地
///
/// 为什么要有这一份，而不是每个插件一个 `build_<id>.dart`：
/// `plugins/README.md` 那份合同把"一个目录 = 一个插件"写成了形状，而形状要有**一个
/// 读者**——手工维护 N 份构建脚本，就会出现"新增插件忘了加进打包链"（面板上看不到它，
/// 归因要翻到打包脚本里，那正是最难查的一类）。这里改成读 `plugins/*/plugin.json`：
/// 新增一个插件只需要建目录 + 写 plugin.json + 写 `<id>_plugin.dart`，构建链自动跟上。
///
/// 三条硬规矩（都在代码里，不写在文档里靠人守）：
///   1. **字段先过合同再编译**：`id` 必须等于目录名、`command` 必须在 `files` 里、
///      `runtime` / `suspension` / `granularity` 值域固定——与装机端 `PluginDownloader`
///      读的是同一份规则，两边不一致的结局是"列清单时被跳过"或"装上去起不来"。
///   2. **产物必须自检过**：编出来的 exe 立刻跑 `<exe> --selftest`，非 0 就整个构建
///      失败。"能编译"不等于"协议对"，而协议错在用户机器上的表现是"插件起不来"。
///   3. **索引里的 `bytes` 是真字节数**：装机端拿它核对下载完整性，填错等于"不落地"。
library;

import 'dart:convert';
import 'dart:io';

const String _pluginRepoDir = 'plugins';
const String _kitDirName = '_kit';
const String _manifestName = 'plugin.json';

Future<void> main(List<String> args) async {
  final Directory root = _repoRoot();
  final Directory pluginRepo = Directory(_join(root.path, _pluginRepoDir));
  if (!pluginRepo.existsSync()) {
    stderr.writeln(
      '[build_plugins] 找不到插件仓：${pluginRepo.path}\n'
      '  它是独立仓库（raditree/tree-plugins），装在桌面仓的 plugins/ 目录下。',
    );
    exitCode = 2;
    return;
  }
  final Directory outDir = Directory(
    _arg(args, '--out') ?? _join(root.path, 'build', 'plugins'),
  )..createSync(recursive: true);
  final File indexFile = File(
    _arg(args, '--index') ?? _join(outDir.path, 'plugin-index.json'),
  );
  final bool skipSelfTest = args.contains('--skip-selftest');
  final String only = _arg(args, '--only') ?? '';

  final List<_PluginManifest> manifests = _readManifests(
    pluginRepo,
    only: only,
  );
  if (manifests.isEmpty) {
    stderr.writeln(
      only.isEmpty
          ? '[build_plugins] 插件仓里一个 plugin.json 都没有：${pluginRepo.path}'
          : '[build_plugins] 没有 id=$only 的插件（检查 plugins/$only/$_manifestName）',
    );
    exitCode = 2;
    return;
  }

  final List<String> failures = <String>[];
  final List<Map<String, dynamic>> indexEntries = <Map<String, dynamic>>[];

  for (final _PluginManifest manifest in manifests) {
    final String? invalid = manifest.validate(dirName: manifest.dirName);
    if (invalid != null) {
      failures.add('${manifest.id}：$invalid');
      stderr.writeln('[build_plugins] 跳过 ${manifest.id}：$invalid');
      continue;
    }
    final List<String> built = <String>[];
    bool ok = true;
    for (final _PluginFile file in manifest.files) {
      final File artifact = File(_join(outDir.path, file.target));
      if (manifest.runtime == 'binary' && file.isCommand) {
        final String? entrySource = manifest.dartEntry;
        if (entrySource == null) {
          failures.add(
            '${manifest.id}：runtime=binary 但找不到入口源 '
            '（约定 plugins/${manifest.id}/${manifest.id}_plugin.dart）',
          );
          ok = false;
          continue;
        }
        final int code = await _compile(root, entrySource, artifact.path);
        if (code != 0) {
          failures.add('${manifest.id}：编译失败（exit=$code）');
          ok = false;
          continue;
        }
        stdout.writeln(
          '[build_plugins] ${manifest.id} → ${_relative(root, artifact.path)}'
          '（${(artifact.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB）',
        );
        if (!skipSelfTest) {
          final int selfTestCode = await _selfTest(artifact.path);
          if (selfTestCode != 0) {
            failures.add(
              '${manifest.id}：产物自检失败（exit=$selfTestCode）——'
              '"能编译"不等于"协议对"',
            );
            ok = false;
            continue;
          }
          stdout.writeln('[build_plugins] ${manifest.id} 产物自检通过');
        }
      } else {
        // 非编译产物（python 脚本 / 随包数据文件）：从源目录原样取。
        final File source = File(_join(manifest.dirPath, file.source));
        if (!source.existsSync()) {
          failures.add('${manifest.id}：files 里列的 ${file.source} 不在源目录里');
          ok = false;
          continue;
        }
        source.copySync(artifact.path);
      }
      built.add(file.target);
      indexEntries.add(
        manifest.indexEntry(target: file.target, artifact: artifact),
      );
    }
    if (!ok) continue;
    if (built.isEmpty) {
      failures.add('${manifest.id}：files 是空的（合同要求至少一个）');
    }
  }

  indexFile.parent.createSync(recursive: true);
  indexFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{'schema': 1, 'plugins': indexEntries})}\n',
    encoding: utf8,
  );
  stdout.writeln(
    '[build_plugins] 索引已写出：${_relative(root, indexFile.path)}'
    '（${indexEntries.length} 条 / ${manifests.length} 个插件目录）',
  );
  stdout.writeln(
    '[build_plugins] 发布：gh release create v<版本> ${_relative(root, indexFile.path)} '
    '${indexEntries.map((Map<String, dynamic> e) => _assetName(e)).join(' ')}',
  );

  if (failures.isNotEmpty) {
    stderr.writeln('[build_plugins] 失败 ${failures.length} 条：');
    for (final String failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
  }
}

/// 读插件仓里的清单（顶层目录 + 有 plugin.json 才算一个插件；`_kit` 与 `.git` 跳过）。
List<_PluginManifest> _readManifests(Directory repo, {String only = ''}) {
  final List<_PluginManifest> found = <_PluginManifest>[];
  final List<Directory> dirs =
      repo
          .listSync()
          .whereType<Directory>()
          .where(
            (Directory d) =>
                !d.path.endsWith('.git') && !_basename(d.path).startsWith('.'),
          )
          .toList()
        ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
  for (final Directory dir in dirs) {
    final String dirName = _basename(dir.path);
    if (dirName == _kitDirName) continue; // 公共骨架，不是插件
    final File manifest = File(_join(dir.path, _manifestName));
    if (!manifest.existsSync()) continue; // 没有 plugin.json ⇒ 不是插件
    if (only.isNotEmpty && only != dirName) continue;
    try {
      found.add(
        _PluginManifest.parse(
          dirName: dirName,
          dirPath: dir.path,
          json: asJson(manifest.readAsStringSync()),
        ),
      );
    } catch (error) {
      stderr.writeln('[build_plugins] ${dir.path}/$_manifestName 解析失败：$error');
    }
  }
  return found;
}

Map<String, dynamic> asJson(String text) => (json.decode(text) as Map).map(
  (Object? key, Object? value) =>
      MapEntry<String, dynamic>(key.toString(), value),
);

Future<int> _compile(Directory root, String entry, String output) async {
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>['compile', 'exe', entry, '-o', output],
    workingDirectory: root.path,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  return result.exitCode;
}

/// 产物自检：**真进程**跑一遍（这就是"编译出来的那个东西"，不是源文件）。
Future<int> _selfTest(String executable) async {
  final ProcessResult result = await Process.run(executable, const <String>[
    '--selftest',
  ]);
  stderr.write(result.stderr);
  return result.exitCode;
}

/// 索引条目里的资产名（只用于打印发布命令）。
String _assetName(Map<String, dynamic> entry) {
  final Object? files = entry['files'];
  if (files is! List || files.isEmpty) return entry['id']?.toString() ?? '?';
  final Object? first = files.first;
  if (first is Map) return '${first['asset']}';
  return '?';
}

String _basename(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    if (Directory(_join(dir.path, 'packages', 'tree_core')).existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

String? _arg(List<String> args, String name) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}

String _join(String a, [String? b, String? c]) =>
    <String>[a, ?b, ?c].join(Platform.pathSeparator);

String _relative(Directory root, String path) =>
    path.startsWith(root.path) ? path.substring(root.path.length + 1) : path;

/// 一条 `plugin.json`（**开发期元数据**，字段与 plugins/README.md 的表一一对应）。
class _PluginManifest {
  _PluginManifest({
    required this.dirName,
    required this.dirPath,
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.runtime,
    required this.fileNames,
    required this.command,
    required this.args,
    required this.suspension,
    required this.granularity,
    required this.scope,
  });

  final String dirName;
  final String dirPath;
  final String id;
  final String name;
  final String version;
  final String description;
  final String runtime;
  final List<String> fileNames;
  final String command;
  final List<String> args;
  final String suspension;
  final String granularity;
  final Map<String, dynamic> scope;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.-]+$');
  static final RegExp _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

  factory _PluginManifest.parse({
    required String dirName,
    required String dirPath,
    required Map<String, dynamic> json,
  }) {
    final Object? files = json['files'];
    return _PluginManifest(
      dirName: dirName,
      dirPath: dirPath,
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      version: '${json['version'] ?? ''}',
      description: '${json['description'] ?? ''}',
      runtime: '${json['runtime'] ?? 'binary'}',
      fileNames: files is List
          ? files.map((Object? e) => '$e').toList()
          : const <String>[],
      command: '${json['command'] ?? ''}',
      args: json['args'] is List
          ? (json['args'] as List).map((Object? e) => '$e').toList()
          : const <String>[],
      suspension: '${json['suspension'] ?? ''}',
      granularity: '${json['granularity'] ?? 'team'}',
      scope: json['scope'] is Map
          ? (json['scope'] as Map).map(
              (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
            )
          : <String, dynamic>{},
    );
  }

  /// 合同的字段纪律（**逐条给人话理由**：构建失败的原因要能直接拿去改 plugin.json）。
  String? validate({required String dirName}) {
    if (id.isEmpty) return '缺少 id';
    if (id != dirName) return 'id（$id）必须等于目录名（$dirName）';
    if (!_idPattern.hasMatch(id) || id == '.' || id == '..') {
      return 'id「$id」字符集非法（只许 A-Za-z0-9_.-，且不能是 . / ..）';
    }
    if (name.trim().isEmpty) return '缺少 name';
    if (!_versionPattern.hasMatch(version)) {
      return 'version（$version）必须是三段数字 x.y.z';
    }
    if (runtime != 'binary' && runtime != 'python') {
      return 'runtime（$runtime）只能是 binary / python';
    }
    if (fileNames.isEmpty) return 'files 至少要有一个';
    if (command.trim().isEmpty) return '缺少 command（装完要知道拉哪个）';
    if (!fileNames.contains(command)) {
      return 'command（$command）必须出现在 files 里';
    }
    if (suspension.isNotEmpty && suspension != 'keep') {
      return 'suspension（$suspension）值域只有空与 keep';
    }
    if (!const <String>['team', 'agent', 'session'].contains(granularity)) {
      return 'granularity（$granularity）只能是 team / agent / session';
    }
    for (final String fileName in fileNames) {
      if (fileName.contains('/') ||
          fileName.contains('\\') ||
          fileName.contains('..')) {
        return 'files 里的「$fileName」必须是纯文件名（防路径穿越）';
      }
    }
    return null;
  }

  /// 要产出的文件清单。
  ///
  /// 非 Windows 平台把 `.exe` 后缀剥掉（合同里写的是 Windows 资产名，而核心解析
  /// binary 时按平台补后缀，见 `BuiltinPluginCatalog.findBinary`）。
  /// `command` 那一条是**编译产物**（源 = [dartEntry]）；其余条目是随包数据文件，
  /// 从源目录原样取。
  List<_PluginFile> get files {
    final String commandBase = _stripExe(command);
    final List<_PluginFile> out = <_PluginFile>[];
    for (final String name in fileNames) {
      final bool isCommand = _stripExe(name) == commandBase;
      out.add(
        _PluginFile(
          target: Platform.isWindows ? name : _stripExe(name),
          // command 那一条的“源”就是 Dart 入口（下面主循环会编译它）；
          // 其余条目是随包数据文件，名字就是源目录里的文件名。
          source: isCommand ? '${id}_plugin.dart' : name,
          isCommand: isCommand,
        ),
      );
    }
    return out;
  }

  /// Dart 入口（约定：`plugins/<id>/<id>_plugin.dart`）；不存在返回 null。
  String? get dartEntry {
    final String path = _join(dirPath, '${id}_plugin.dart');
    return File(path).existsSync() ? path : null;
  }

  /// 发布索引里的一条（**字段与装机端 `PluginDownloader` 读的完全一致**）。
  Map<String, dynamic> indexEntry({
    required String target,
    required File artifact,
  }) => <String, dynamic>{
    'id': id,
    'name': name,
    'version': version,
    if (description.isNotEmpty) 'description': description,
    'runtime': runtime,
    'command': Platform.isWindows ? command : _stripExe(command),
    'args': args,
    'files': <Map<String, dynamic>>[
      <String, dynamic>{
        'asset': target,
        'target': target,
        'bytes': artifact.existsSync() ? artifact.lengthSync() : 0,
      },
    ],
    if (suspension.isNotEmpty) 'suspension': suspension,
    'granularity': granularity,
    'scope': scope,
  };

  static String _stripExe(String name) =>
      name.endsWith('.exe') ? name.substring(0, name.length - 4) : name;
}

class _PluginFile {
  _PluginFile({
    required this.target,
    required this.source,
    required this.isCommand,
  });
  final String target;
  final String source;
  final bool isCommand;
}
