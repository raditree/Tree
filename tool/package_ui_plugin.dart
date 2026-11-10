import 'dart:convert';
import 'dart:io';

/// 把 Flutter Windows 发行目录打成 **UI 插件包**（U2）。
///
/// UI 已是 `runtime: ui` 插件，发布物不再是"桌面安装包"，而是树里的一份插件产物：
/// ```
/// tree-ui-default-{ver}.zip
///   tree_ui.exe          # 界面可执行体（打包链已把它从 Tree.exe 改名过来）
///   flutter_windows.dll
///   *.dll
///   data/
///   plugins/             # 插件开发指南（设置页入口用，可选）
///   plugin.json
/// ```
///
/// 用法（仓库根目录）：
///   dart run tool/package_ui_plugin.dart [--build]
///
/// 选项：
///   --build               先跑 `flutter build windows --release`（默认用已有产物）
///   --ui-dir DIR          UI 插件源码目录（默认 plugins/tree.ui.default）
///   --release-dir DIR     发行目录（默认 <ui-dir>/build/windows/x64/runner/Release）
///   --out DIR             产物目录（默认 dist，相对仓库根）
///   --index FILE          要合并进索引的文件（默认 build/plugins/plugin-index.json）
///   --no-index            只打包，不动发布索引
///   --version x.y.z       插件版本（默认取 UI 的 pubspec.yaml 的 `+` 之前部分）
///   --no-zip              只准备目录，不压缩
///
/// 排除：`*.pdb`、核心 `tree_core.exe`、引导壳（`Tree.exe` / `tree_launcher.exe`）
/// 与目标机 agent（`agents/`）。界面可执行体只收一份，固定叫 `tree_ui.exe`。
///
/// **索引条目（2026-11-01）**：UI 带 `data/` 与几十个 dll，扁平 `files[]` 装不下，
/// 所以这条以 `archive` 形态进索引（整包 zip + 包内 `plugin.json`）。装机端
/// `PluginDownloader` 认这个字段：下载整包 → `installFromZip` 解成 `plugins/<id>/`。
Future<void> main(List<String> args) async {
  try {
    await _package(args);
  } on _UsageError catch (usage) {
    if (usage.message.isNotEmpty) stderr.writeln(usage.message);
    exit(usage.code);
  } catch (error, stack) {
    stderr.writeln('打包失败：$error\n$stack');
    exit(1);
  }
}

const String kPluginId = 'tree.ui.default';
const String kPluginName = 'Tree 默认界面';
const String kTargetExe = 'tree_ui.exe';

/// UI 插件自己登记的领域依赖（**可选**）。
///
/// 为什么是 `optional: true`：`requires.plugins` 是启用前的硬闸门——写成必需就
/// 意味着"agent 没装 ⇒ 界面起不来"，等于把绝大多数人挡在门外。写成可选后：
/// 核心照常拉起界面，清单 / 详情页会显示这条依赖，安装或更新 UI 时也能一键补全。
const List<Map<String, dynamic>> kUiPluginDependencies = <Map<String, dynamic>>[
  <String, dynamic>{'id': 'tree.agent', 'version': '>=0.32.0', 'optional': true},
];

Future<void> _package(List<String> args) async {
  final _Options options = _Options.parse(args);
  final Directory root = Directory.current;
  // UI 源码住在插件仓（桌面仓的 plugins/ 是本地挂载点），不再是仓根 Flutter 工程。
  final Directory uiDir = Directory(_join(root.path, options.uiDir));
  final File pubspec = File(_join(uiDir.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    throw const _UsageError(
      '找不到 UI 工程的 pubspec.yaml：检查 --ui-dir（默认 plugins/tree.ui.default）'
      '或插件仓是否已 clone 到 plugins/',
      2,
    );
  }
  final Map<String, String> pubspecData = _readPubspec(pubspec);
  final String version =
      options.version ?? _versionOf(pubspecData['version'] ?? '0.0.0');
  final String appExeName = '${_binaryName(uiDir)}.exe';
  final Directory releaseDir = Directory(
    options.releaseDir ??
        _join(uiDir.path, 'build/windows/x64/runner/Release'),
  );

  if (options.build) {
    final int code = await _runLive(
      'flutter',
      <String>['build', 'windows', '--release', '--no-tree-shake-icons'],
      uiDir.path,
    );
    if (code != 0) {
      throw _UsageError('flutter build windows 失败（exit=$code）', code);
    }
  }

  final File appExe = File(_join(releaseDir.path, appExeName));
  // 打包链已把界面改名为 tree_ui.exe（见 package_windows.dart ①b）；直接用
  // `flutter build` 的目录则还是 Tree.exe，两种都收，落到包里统一叫 tree_ui.exe。
  final File uiSource = File(_join(releaseDir.path, kTargetExe));
  final File resolvedSource = uiSource.existsSync() ? uiSource : appExe;
  if (!resolvedSource.existsSync()) {
    throw _UsageError(
      '找不到界面可执行文件：$kTargetExe 或 $appExeName\n'
      '先构建或传 --release-dir（默认 build/windows/x64/runner/Release）。',
      3,
    );
  }

  final Directory outDir = Directory(_join(root.path, options.out));
  outDir.createSync(recursive: true);
  final Directory staging = Directory(_join(outDir.path, kPluginId));
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  stdout.writeln('== 收集 UI 产物 ==');
  int copied = 0;
  for (final FileSystemEntity entity in releaseDir.listSync()) {
    final String name = _basename(entity.path);
    final String lower = name.toLowerCase();
    if (entity is Directory) {
      // agents/ 是 ssh_executor 推到目标机的执行体，与 UI 无关。
      if (lower == 'agents') continue;
      _copyDirectory(entity, Directory(_join(staging.path, name)));
      copied += 1;
      stdout.writeln('   目录：$name');
      continue;
    }
    if (entity is! File) continue;
    if (lower.endsWith('.pdb')) continue;
    // 核心与**引导壳**都不是界面的一部分：Tree.exe / tree_launcher.exe 属 loader，
    // 打进插件包会被装机端装成“和引导壳同名”的东西（这正是要避免的那件事）。
    if (lower == 'tree_core.exe' ||
        lower == 'tree.exe' ||
        lower == 'tree_launcher.exe') {
      continue;
    }
    if (lower == 'plugin.json') continue; // 下面按本包的版本重写
    if (lower == kTargetExe) continue; // 界面可执行体在循环外单独收一次
    entity.copySync(_join(staging.path, name));
    copied += 1;
  }
  resolvedSource.copySync(_join(staging.path, kTargetExe));
  stdout.writeln('   可执行体：${_basename(resolvedSource.path)} → $kTargetExe');
  copied += 1;
  if (copied == 0) {
    throw _UsageError('发行目录是空的：${releaseDir.path}', 3);
  }

  final File manifest = File(_join(staging.path, 'plugin.json'));
  manifest.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(_manifest(version)),
  );
  stdout.writeln('   plugin.json（$kPluginId $version）');

  String? zipPath;
  if (options.noZip) {
    stdout.writeln('   目录：${staging.path}');
  } else {
    zipPath = _join(outDir.path, 'tree-ui-default-$version.zip');
    if (File(zipPath).existsSync()) File(zipPath).deleteSync();
    stdout.writeln('== 打包 zip（tar -a）==');
    final int code = await _runLive('tar', <String>[
      '-a',
      '-cf',
      zipPath,
      '-C',
      staging.path,
      '.',
    ], root.path);
    if (code != 0) {
      throw _UsageError('压缩失败（exit=$code）', code);
    }
    await _verifyZip(root, zipPath);
    stdout.writeln(
      '   产物：$zipPath'
      '（${(File(zipPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB）',
    );
    if (!options.noIndex) {
      final File indexFile = File(
        _join(root.path, options.index ?? 'build/plugins/plugin-index.json'),
      );
      final int added = _mergeIndex(
        indexFile,
        version,
        _basename(zipPath),
        File(zipPath).lengthSync(),
      );
      stdout.writeln(
        '   索引：${indexFile.path}（tree.ui.default ${added == 0 ? '已是最新' : '已写入'}）',
      );
    }
  }
}

/// 把 `tree.ui.default` 合并进发布索引（`schema: 1` + `plugins[]`）。
///
/// 为什么用 **archive** 而不是 `files[]`：索引对每项 `target` 要求纯文件名，而 UI
/// 包里有 `data/…` 与几十个 dll；`files[]` 表达不了目录，装上去只会缺文件。
/// 整包形态在装机端由 `PluginDownloader._installArchive` 落到 `plugins/<id>/`。
///
/// 返回本次写入的条数（0 = 已经有一条同版本的，什么都没改）。
int _mergeIndex(File indexFile, String version, String archive, int bytes) {
  Map<String, dynamic> document = <String, dynamic>{
    'schema': 1,
    'plugins': <dynamic>[],
  };
  if (indexFile.existsSync()) {
    try {
      final Object? decoded = jsonDecode(indexFile.readAsStringSync());
      if (decoded is Map) {
        document = decoded.map(
          (Object? k, Object? v) => MapEntry(k.toString(), v),
        );
      }
    } catch (error) {
      // 索引是发布合同：读不动就**直接失败**，绝不覆盖成“只有 UI 一条”的清单。
      throw _UsageError('现有索引读不动（${indexFile.path}）：$error', 4);
    }
  }
  final Object? rawPlugins = document['plugins'];
  final List<dynamic> plugins = rawPlugins is List
      ? List<dynamic>.of(rawPlugins)
      : <dynamic>[];
  final Map<String, dynamic> entry = <String, dynamic>{
    'id': kPluginId,
    'name': kPluginName,
    'version': version,
    'description': 'Tree 的默认图形界面（runtime: ui）。',
    'runtime': 'ui',
    'command': kTargetExe,
    'args': <String>[],
    'granularity': 'team',
    'scope': <String, dynamic>{},
    'requires': <String, dynamic>{
      'api': '>=1.0 <2.0',
      'plugins': kUiPluginDependencies,
    },
    'archive': archive,
    'archive_bytes': bytes,
  };
  final int index = plugins.indexWhere(
    (Object? item) => item is Map && '${item['id']}'.trim() == kPluginId,
  );
  if (index >= 0) {
    final Map<String, dynamic> previous = (plugins[index] as Map)
        .map((Object? k, Object? v) => MapEntry(k.toString(), v));
    if ('${previous['version']}' == version &&
        '${previous['archive']}' == archive &&
        (previous['archive_bytes'] as num?)?.toInt() == bytes) {
      return 0;
    }
    plugins[index] = entry;
  } else {
    plugins.add(entry);
  }
  document['schema'] = 1;
  document['plugins'] = plugins;
  indexFile.parent.createSync(recursive: true);
  indexFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(document)}\n',
  );
  return 1;
}

Map<String, dynamic> _manifest(String version) => <String, dynamic>{
  'id': kPluginId,
  'name': kPluginName,
  'version': version,
  'description': 'Tree 的默认图形界面（runtime: ui）。',
  'runtime': 'ui',
  'command': kTargetExe,
  'args': <String>[],
  // UI 插件的"只跑一个实例"由 UiHost 保证（每个插件 id 一个宿主进程）；
  // granularity 只影响 headless 的实例编组，这里沿用契约内的默认值。
  'granularity': 'team',
  'scope': <String, dynamic>{},
  'requires': <String, dynamic>{
    'api': '>=1.0 <2.0',
    'plugins': kUiPluginDependencies,
  },
  'files': <String>['**'],
};

/// 校验 zip 里**必须有** `tree_ui.exe` 与 `plugin.json`，且**不能有**被排除项。
Future<void> _verifyZip(Directory root, String zipPath) async {
  final ProcessResult result = await Process.run('tar', <String>[
    '-tf',
    zipPath,
  ], workingDirectory: root.path);
  if (result.exitCode != 0) {
    throw _UsageError('读不出压缩包内容（exit=${result.exitCode}）', result.exitCode);
  }
  final List<String> names = const LineSplitter()
      .convert((result.stdout as String).trim())
      .map((String line) => line.replaceFirst(RegExp(r'^\./'), ''))
      .toList();
  final Set<String> roots = names
      .map((String name) => name.split('/').first)
      .where((String name) => name.isNotEmpty)
      .toSet();
  for (final String required in <String>[kTargetExe, 'plugin.json']) {
    if (!roots.contains(required)) {
      throw _UsageError('压缩包缺少 $required（内容：${roots.join(', ')}）', 4);
    }
  }
  for (final String banned in <String>[
    'tree_core.exe',
    'tree.exe',
    'Tree.exe',
  ]) {
    if (roots.contains(banned)) {
      throw _UsageError('压缩包不应包含 $banned', 4);
    }
  }
  if (names.any((String name) => name.toLowerCase().endsWith('.pdb'))) {
    throw _UsageError('压缩包不应包含调试符号（*.pdb）', 4);
  }
}

void _copyDirectory(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final FileSystemEntity entity in source.listSync()) {
    final String name = _basename(entity.path);
    if (entity is File) {
      if (name.toLowerCase().endsWith('.pdb')) continue;
      entity.copySync(_join(target.path, name));
    } else if (entity is Directory) {
      _copyDirectory(entity, Directory(_join(target.path, name)));
    }
  }
}

Map<String, String> _readPubspec(File file) {
  final Map<String, String> values = <String, String>{};
  for (final String line in file.readAsLinesSync()) {
    final int colon = line.indexOf(':');
    if (colon <= 0 || line.startsWith(' ') || line.startsWith('#')) continue;
    values[line.substring(0, colon).trim()] = line
        .substring(colon + 1)
        .trim()
        .replaceAll(RegExp(r'''^['"]|['"]$'''), '');
  }
  return values;
}

String _versionOf(String raw) {
  final int plus = raw.indexOf('+');
  return plus < 0 ? raw : raw.substring(0, plus);
}

/// 应用可执行体名来自 `windows/CMakeLists.txt` 的 `BINARY_NAME`。
String _binaryName(Directory root) {
  final File cmake = File(_join(root.path, 'windows/CMakeLists.txt'));
  if (cmake.existsSync()) {
    final RegExpMatch? match = RegExp(
      r'set\(BINARY_NAME\s+"?([^"\)\s]+)"?\)',
    ).firstMatch(cmake.readAsStringSync());
    if (match != null) return match.group(1)!;
  }
  return 'Tree';
}

Future<int> _runLive(String exe, List<String> args, String workingDirectory) async {
  stdout.writeln('   \$ $exe ${args.join(' ')}');
  final Process process = await Process.start(
    exe,
    args,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
    // Windows 上 `flutter` 是 .bat，必须经 shell 解析才能找到。
    runInShell: Platform.isWindows,
  );
  return process.exitCode;
}

String _join(String left, String right) => '$left${Platform.pathSeparator}$right';

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

class _Options {
  const _Options({
    required this.build,
    required this.noZip,
    required this.noIndex,
    required this.out,
    this.version,
    this.releaseDir,
    this.index,
    this.uiDir = 'plugins/tree.ui.default',
  });

  final bool build;
  final bool noZip;
  final bool noIndex;
  final String out;
  final String? version;
  final String? releaseDir;
  final String? index;

  /// UI 插件源码目录（相对仓库根）。
  final String uiDir;

  static _Options parse(List<String> args) {
    bool build = false;
    bool noZip = false;
    bool noIndex = false;
    String out = 'dist';
    String? version;
    String? releaseDir;
    String? index;
    String uiDir = 'plugins/tree.ui.default';
    for (int i = 0; i < args.length; i++) {
      final String arg = args[i];
      String value() {
        if (i + 1 >= args.length) {
          throw _UsageError('$arg 缺少参数值', 2);
        }
        return args[++i];
      }

      switch (arg) {
        case '--build':
          build = true;
        case '--no-zip':
          noZip = true;
        case '--no-index':
          noIndex = true;
        case '--out':
          out = value();
        case '--index':
          index = value();
        case '--ui-dir':
          uiDir = value();
        case '--version':
          version = value();
        case '--release-dir':
          releaseDir = value();
        case '-h':
        case '--help':
          throw const _UsageError('', 0);
        default:
          throw _UsageError('未知参数：$arg', 2);
      }
    }
    return _Options(
      build: build,
      noZip: noZip,
      noIndex: noIndex,
      out: out,
      version: version,
      releaseDir: releaseDir,
      index: index,
      uiDir: uiDir,
    );
  }
}

class _UsageError implements Exception {
  const _UsageError(this.message, this.code);

  final String message;
  final int code;
}
