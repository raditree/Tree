/// 编译 `self_updater`（**框架自迭代插件**，binary 型内置插件）到仓根 `build/plugins/`。
///
/// 用法：
///   dart run tool/build_self_updater.dart [--out <dir>]
///
/// 产出的是**自机平台**的可执行文件（插件跑在用户本机、与核心同级）：
///   Windows → build/plugins/tree_self_updater.exe
///   Linux/macOS → build/plugins/tree_self_updater
///
/// 为什么也是二进制而不是 Python 脚本：它与 SSH 执行器同属"随包必须在场"的能力，
/// 用户机器上**不需要任何运行时**（不探测 Python），且核心侧按
/// `BuiltinPluginSpec.kind == binary` 解析它（见 `builtin_plugins.dart`）。
/// 形状逐字段照 `tool/build_ssh_plugin.dart`：两处不一致时，打包链只拷得到一个、
/// 装机后另一个就在面板上"解析失败"——那是最难归因的一类差异（看起来像功能没做）。
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  final Directory root = _repoRoot();
  final String out = _arg(args, '--out') ?? _join(root.path, 'build', 'plugins');
  final String entry = _join(
    root.path,
    _join(
      'packages',
      _join('tree_self_updater', _join('bin', 'tree_self_updater.dart')),
    ),
  );
  if (!File(entry).existsSync()) {
    stderr.writeln('[build_self_updater] 找不到 $entry（package 尚未创建？）');
    exitCode = 2;
    return;
  }
  final Directory target = Directory(out)..createSync(recursive: true);
  final String output = _join(
    target.path,
    Platform.isWindows ? 'tree_self_updater.exe' : 'tree_self_updater',
  );
  // 版本从**根 pubspec** 注入（唯一真源）：插件自报的 version 必须能被"当前装机是哪一版"
  // 对上号，否则重启排障时只能猜。与 build_ssh_plugin / build_agent 同一条规则；
  // 它由 `SelfUpdaterIdentity.version` 以 String.fromEnvironment 接住（不是注释里写着用、
  // 实际没人读 —— 那种注入只会造出一个“看起来供了版本”的假象）。
  final String version = _readAppVersion(root) ?? '0.0.0';
  stdout.writeln('[build_self_updater] 编译 → $output（版本=$version）');
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>[
      'compile',
      'exe',
      '-DkSelfUpdaterVersion=$version',
      entry,
      '-o',
      output,
    ],
    workingDirectory: root.path,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('[build_self_updater] 编译失败（exit=${result.exitCode}）');
    exitCode = result.exitCode;
    return;
  }
  final int size = File(output).lengthSync();
  stdout.writeln(
    '[build_self_updater] 完成：${_relative(root, output)}'
    '（${(size / 1024 / 1024).toStringAsFixed(1)} MB）',
  );
}

String? _arg(List<String> args, String name) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}

/// 从仓根 `pubspec.yaml` 读应用版本（`version: 1.0.4+1` → `1.0.4`）。
///
/// 拿 `+` **之前**那一段：构建号每打一次包都变，用它当插件版本会让"这一世是第几代"
/// 与"这是哪一版"混成一团，重启排障时对不上号。
String? _readAppVersion(Directory root) {
  final File pubspec = File(_join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  for (final String line in pubspec.readAsLinesSync()) {
    if (!line.startsWith('version:')) continue;
    final String raw = line.substring('version:'.length).trim();
    final int plus = raw.indexOf('+');
    return plus > 0 ? raw.substring(0, plus) : raw;
  }
  return null;
}

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    if (Directory(
      _join(dir.path, _join('packages', 'tree_core')),
    ).existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

/// 用平台分隔符拼接路径（最多 4 段；本脚本够用，避免引 `package:path`）。
String _join(String a, [String? b, String? c, String? d]) =>
    <String>[a, ?b, ?c, ?d].join(Platform.pathSeparator);

String _relative(Directory root, String path) =>
    path.startsWith(root.path) ? path.substring(root.path.length + 1) : path;
