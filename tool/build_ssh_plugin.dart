/// 编译 `ssh_executor`（SSH 执行器**中转站插件**）到仓根 `build/plugins/`。
///
/// 用法：
///   dart run tool/build_ssh_plugin.dart [--out <dir>]
///
/// 它产出的是**自机平台**的可执行文件（插件跑在用户本机、与核心同级）：
///   Windows → build/plugins/tree_ssh_executor.exe
///   Linux/macOS → build/plugins/tree_ssh_executor
///
/// 为什么是二进制而不是 Python 脚本：它要 `dartssh2` 维持一条常驻 SSH 通道，
/// 并做 base64 分块推送 agent —— 用 Dart 编译成单文件后，用户机器上**不需要任何运行时**，
/// 也与核心同栈（将来还能共享协议类型）。核心侧按
/// `BuiltinPluginSpec.kind == binary` 解析它（见 `builtin_plugins.dart`）。
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  final Directory root = _repoRoot();
  final String out = _arg(args, '--out') ?? _join(root.path, 'build', 'plugins');
  final String entry = _join(
    root.path,
    _join(
      'packages',
      _join(
        'tree_ssh_plugin',
        _join('bin', 'tree_ssh_executor.dart'),
      ),
    ),
  );
  if (!File(entry).existsSync()) {
    stderr.writeln('[build_ssh_plugin] 找不到 $entry（package 尚未创建？）');
    exitCode = 2;
    return;
  }
  final Directory target = Directory(out)..createSync(recursive: true);
  final String output = _join(
    target.path,
    Platform.isWindows ? 'tree_ssh_executor.exe' : 'tree_ssh_executor',
  );
  // **必须一起注入 agent 版本**：插件用 `kAgentVersion` 说"我要哪个版本的 tree_agent"，
  // 而 `tool/build_agent.dart` 用同一个值给二进制打标。两处不一致时插件会在日志里
  // 抱怨版本不匹配（功能仍能靠 sha256 判据工作，但那是一条本可以避免的噪音与误判源）。
  final String version = _readAppVersion(root) ?? '0.0.0';
  stdout.writeln('[build_ssh_plugin] 编译 → $output（kAgentVersion=$version）');
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>[
      'compile',
      'exe',
      '-DkAgentVersion=$version',
      entry,
      '-o',
      output,
    ],
    workingDirectory: root.path,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('[build_ssh_plugin] 编译失败（exit=${result.exitCode}）');
    exitCode = result.exitCode;
    return;
  }
  final int size = File(output).lengthSync();
  stdout.writeln(
    '[build_ssh_plugin] 完成：${_relative(root, output)}'
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

/// 从仓根 `pubspec.yaml` 读应用版本（`version: 1.0.2+6` → `1.0.2`）。
///
/// 与 `tool/build_agent.dart` 用**同一条规则**：拿 `+` 之前那一段（语义版本）。
/// 构建号每打一次包都变，拿它当 agent 版本会导致每次都重推 6.5 MB。
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
