import 'dart:io';

/// 构建脚本：把核心进程编译成单文件可执行（`dart compile exe`）。
///
/// 用法：`dart run tool/build_core.dart [--out dist/tree_core.exe]`
///
/// 为什么要有脚本而不是手敲命令：打包路径、`--no-pub` 前提、产物命名都要一致，
/// 否则"我本地能跑"会在安装器里变成找不到文件。
Future<void> main(List<String> args) async {
  String out = 'dist/tree_core.exe';
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == '--out') out = args[i + 1];
  }
  final String entry = 'packages/tree_core_cli/bin/tree_core.dart';
  if (!File(entry).existsSync()) {
    stderr.writeln('找不到入口 $entry（请在仓库根目录运行）');
    exit(1);
  }
  final Directory dir = Directory(File(out).parent.path);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  stdout.writeln('编译 $entry → $out ...');
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>['compile', 'exe', entry, '-o', out],
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('编译失败（exit=${result.exitCode}）');
    exit(result.exitCode);
  }
  final int size = File(out).lengthSync();
  stdout.writeln('完成：$out（${(size / 1024 / 1024).toStringAsFixed(1)} MB）');
}
