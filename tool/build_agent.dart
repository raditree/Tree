/// 交叉编译 `tree_agent`（**目标机 Linux 二进制**）到仓根 `build/agents/`。
///
/// 用法：
///   dart run tool/build_agent.dart [--out <dir>] [--version <v>] [--arch x64,arm64]
///
/// 为什么在 Windows 上也能产出 Linux 二进制：`dart compile exe` 支持
/// `--target-os` / `--target-arch`（本仓 Dart 3.13.4 **已实测可用**；首次会下载目标端
/// AOT 产物，约 2 分钟）。因此分发不需要 Linux 构建机。
///
/// 产出物（`tool/package_windows.dart` 会复制进发行包）：
///   build/agents/tree_agent-linux-amd64
///   build/agents/tree_agent-linux-arm64
///
/// `--version` 通过 `--define` 注入 `kAgentVersion`：它是"要不要把 agent 重推到目标机"
/// 的判据之一（另一个是 sha256），所以**必须与随包版本一起变**。
library;

import 'dart:io';

/// 目标三元组：`--target-arch` 的值 → 文件名里那个可读的架构名。
const Map<String, String> _archNames = <String, String>{
  'x64': 'amd64',
  'arm64': 'arm64',
};

Future<void> main(List<String> args) async {
  final Directory root = _repoRoot();
  final String out = _arg(args, '--out') ?? _join(root.path, 'build', 'agents');
  final String version =
      _arg(args, '--version') ?? _readAppVersion(root) ?? '0.0.0';
  final List<String> arches = (_arg(args, '--arch') ?? 'x64,arm64')
      .split(',')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  final String entry = _join(
    root.path,
    _join('packages', _join('tree_agent', _join('bin', 'tree_agent.dart'))),
  );
  if (!File(entry).existsSync()) {
    stderr.writeln('[build_agent] 找不到 $entry（package 尚未创建？）');
    exitCode = 2;
    return;
  }

  final Directory target = Directory(out)..createSync(recursive: true);
  final List<String> produced = <String>[];
  for (final String arch in arches) {
    final String? suffix = _archNames[arch];
    if (suffix == null) {
      stderr.writeln('[build_agent] 不支持的架构：$arch（支持 ${_archNames.keys.join('/')}）');
      exitCode = 2;
      return;
    }
    final String output = _join(target.path, 'tree_agent-linux-$suffix');
    stdout.writeln('[build_agent] 编译 linux/$arch → $output（version=$version）');
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>[
        'compile',
        'exe',
        '--target-os=linux',
        '--target-arch=$arch',
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
      stderr.writeln('[build_agent] linux/$arch 编译失败（exit=${result.exitCode}）');
      exitCode = result.exitCode;
      return;
    }
    produced.add(output);
  }

  stdout.writeln('[build_agent] 完成：');
  for (final String path in produced) {
    final int size = File(path).lengthSync();
    stdout.writeln(
      '  ${_relative(root, path)}（${(size / 1024 / 1024).toStringAsFixed(1)} MB）',
    );
  }
  stdout.writeln(
    '下一步：把它交给发行包（tool/package_windows.dart 会把 build/agents/ 复制到 agents/）。',
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
/// 用 `+` 之前那一段：它是**语义版本**（agent 的驻留目录按它分版），
/// 构建号（`+6`）每打一次包都变，拿它当 agent 版本会导致每次都重推。
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
