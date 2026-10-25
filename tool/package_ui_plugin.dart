import 'dart:convert';
import 'dart:io';

/// 把 Flutter Windows 发行目录打成 **UI 插件包**（U2）。
///
/// UI 已是 `runtime: ui` 插件，发布物不再是"桌面安装包"，而是树里的一份插件产物：
/// ```
/// tree-ui-default-{ver}.zip
///   tree_ui.exe          # 由 Tree.exe 改名，避免与不可卸载的 loader 同名
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
///   --release-dir DIR     发行目录（默认 build/windows/x64/runner/Release）
///   --out DIR             产物目录（默认 dist）
///   --version x.y.z       插件版本（默认取 pubspec.yaml 的 `+` 之前部分）
///   --no-zip              只准备目录，不压缩
///
/// 排除：`*.pdb`、核心 `tree_core.exe`、目标机 agent（`agents/`）与旧 `Tree.exe`
/// （改名成 `tree_ui.exe`，不重复带一份）。
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

Future<void> _package(List<String> args) async {
  final _Options options = _Options.parse(args);
  final Directory root = Directory.current;
  final File pubspec = File(_join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    throw const _UsageError('请在仓库根目录运行（找不到 pubspec.yaml）', 2);
  }
  final Map<String, String> pubspecData = _readPubspec(pubspec);
  final String version =
      options.version ?? _versionOf(pubspecData['version'] ?? '0.0.0');
  final String appExeName = '${_binaryName(root)}.exe';
  final Directory releaseDir = Directory(
    options.releaseDir ??
        _join(root.path, 'build/windows/x64/runner/Release'),
  );

  if (options.build) {
    final int code = await _runLive(
      'flutter',
      <String>['build', 'windows', '--release', '--no-tree-shake-icons'],
      root.path,
    );
    if (code != 0) {
      throw _UsageError('flutter build windows 失败（exit=$code）', code);
    }
  }

  final File appExe = File(_join(releaseDir.path, appExeName));
  if (!appExe.existsSync()) {
    throw _UsageError(
      '找不到应用可执行文件：${appExe.path}\n'
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
    if (lower == 'tree_core.exe') continue;
    if (lower == appExeName.toLowerCase() || lower == 'tree.exe') {
      entity.copySync(_join(staging.path, kTargetExe));
      stdout.writeln('   可执行体：$name → $kTargetExe');
      copied += 1;
      continue;
    }
    entity.copySync(_join(staging.path, name));
    copied += 1;
  }
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
  }
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
  'requires': <String, dynamic>{'api': '>=1.0 <2.0'},
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
  );
  return process.exitCode;
}

String _join(String left, String right) => '$left${Platform.pathSeparator}$right';

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

class _Options {
  const _Options({
    required this.build,
    required this.noZip,
    required this.out,
    this.version,
    this.releaseDir,
  });

  final bool build;
  final bool noZip;
  final String out;
  final String? version;
  final String? releaseDir;

  static _Options parse(List<String> args) {
    bool build = false;
    bool noZip = false;
    String out = 'dist';
    String? version;
    String? releaseDir;
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
        case '--out':
          out = value();
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
      out: out,
      version: version,
      releaseDir: releaseDir,
    );
  }
}

class _UsageError implements Exception {
  const _UsageError(this.message, this.code);

  final String message;
  final int code;
}
