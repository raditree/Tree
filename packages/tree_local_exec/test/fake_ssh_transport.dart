import 'dart:async';
import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_ssh_shell_channel.dart';

/// 内存假传输：把 [SshWorkspaceIO] 的全部语义测试从"真 SSH"里解耦出来。
///
/// 真 dartssh2 那一层只负责搬运字节（[dartssh_transport.dart]），语义全部落在
/// [SshWorkspaceIO]；因此这里用假实现覆盖路径约束、行范围、唯一匹配编辑、
/// grep 排除规则、结果截断等真正容易出错的部分。
class FakeSshTransport implements SshTransport {
  final Map<String, List<int>> files = <String, List<int>>{};
  final List<String> commands = <String>[];
  final List<Duration> timeouts = <Duration>[];
  SshExecResult Function(String command)? onRun;
  bool closed = false;

  void seed(String path, String content) => files[path] = utf8.encode(content);

  void seedBytes(String path, List<int> bytes) => files[path] = bytes;

  /// 读某文件前的钩子（测试用：模拟"读到一半链路失活"）。
  Future<void> Function(String absolutePath)? beforeRead;

  @override
  Future<List<int>> read(String absolutePath) async {
    if (beforeRead != null) await beforeRead!(absolutePath);
    final List<int>? bytes = files[absolutePath];
    if (bytes == null) throw StateError('no such file: $absolutePath');
    return bytes;
  }

  @override
  Future<void> write(String absolutePath, List<int> bytes) async {
    files[absolutePath] = List<int>.of(bytes);
  }

  @override
  Future<int> size(String absolutePath) async {
    final List<int>? bytes = files[absolutePath];
    if (bytes == null) throw StateError('no such file: $absolutePath');
    return bytes.length;
  }

  /// 让读流永不产出（模拟"远端半天不给下一块"）。
  bool stallReadStream = false;

  @override
  Stream<List<int>> readStream(
    String absolutePath, {
    int offset = 0,
    int? length,
  }) async* {
    if (stallReadStream) await Completer<void>().future;
    final List<int>? bytes = files[absolutePath];
    if (bytes == null) throw StateError('no such file: $absolutePath');
    final int end = length == null
        ? bytes.length
        : (offset + length > bytes.length ? bytes.length : offset + length);
    if (offset < end) yield bytes.sublist(offset, end);
  }

  @override
  Future<void> writeStream(String absolutePath, Stream<List<int>> data) async {
    final List<int> out = <int>[];
    await for (final List<int> chunk in data) {
      out.addAll(chunk);
    }
    files[absolutePath] = out;
  }

  @override
  Future<List<String>> listFiles(
    String absolutePath, {
    int maxDepth = 2,
  }) async {
    final String prefix = absolutePath.endsWith('/')
        ? absolutePath
        : '$absolutePath/';
    final List<String> out = <String>[];
    for (final String path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final String rel = path.substring(prefix.length);
      if (maxDepth > 0 && rel.split('/').length > maxDepth) continue;
      out.add(rel);
    }
    out.sort();
    return out;
  }

  /// 显式声明的空目录（[files] 只描述文件，空目录推不出来）。
  final Set<String> dirs = <String>{};

  @override
  Future<List<SshFileEntry>> listEntries(
    String absolutePath, {
    int maxEntries = 2000,
  }) async {
    final String prefix = absolutePath.endsWith('/')
        ? absolutePath
        : '$absolutePath/';
    final Map<String, SshFileEntry> byName = <String, SshFileEntry>{};
    final DateTime stamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    for (final String dir in dirs) {
      if (!dir.startsWith(prefix)) continue;
      final String rest = dir.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      byName[rest] = SshFileEntry(
        name: rest,
        isDirectory: true,
        modified: stamp,
      );
    }
    for (final MapEntry<String, List<int>> entry in files.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final String rest = entry.key.substring(prefix.length);
      if (rest.isEmpty) continue;
      final int slash = rest.indexOf('/');
      final String name = slash < 0 ? rest : rest.substring(0, slash);
      byName[name] = SshFileEntry(
        name: name,
        isDirectory: slash >= 0,
        size: slash >= 0 ? 0 : entry.value.length,
        modified: stamp,
      );
    }
    final List<SshFileEntry> out = byName.values.toList();
    return out.length > maxEntries ? out.sublist(0, maxEntries) : out;
  }

  /// 与真实现同口径（`test -e`）：文件、**目录**、以及任何子项的祖先都算存在。
  @override
  Future<bool> exists(String absolutePath) async =>
      files.containsKey(absolutePath) ||
      files.keys.any((String k) => k.startsWith('$absolutePath/')) ||
      dirs.contains(absolutePath) ||
      dirs.any((String d) => d.startsWith('$absolutePath/'));

  @override
  Future<void> delete(String absolutePath) async {
    files.remove(absolutePath);
  }

  /// 路径是否是目录：显式声明的 [dirs] 或「有子项的隐含目录」。
  @override
  Future<bool> isDirectory(String absolutePath) async =>
      dirs.contains(absolutePath) ||
      files.keys.any((String k) => k.startsWith('$absolutePath/')) ||
      dirs.any((String d) => d.startsWith('$absolutePath/'));

  @override
  Future<void> makeDirectory(String absolutePath) async {
    if (await exists(absolutePath) || await isDirectory(absolutePath)) {
      throw WorkspaceIoException('目录已存在：$absolutePath');
    }
    dirs.add(absolutePath);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (!await exists(oldPath) && !await isDirectory(oldPath)) {
      throw WorkspaceIoException('源不存在：$oldPath');
    }
    final Map<String, List<int>> moved = <String, List<int>>{};
    for (final String key in files.keys.toList()) {
      if (key == oldPath || key.startsWith('$oldPath/')) {
        moved[newPath + key.substring(oldPath.length)] = files.remove(key)!;
      }
    }
    files.addAll(moved);
    final List<String> movedDirs = <String>[];
    for (final String dir in dirs.toList()) {
      if (dir == oldPath || dir.startsWith('$oldPath/')) {
        dirs.remove(dir);
        movedDirs.add(newPath + dir.substring(oldPath.length));
      }
    }
    dirs.addAll(movedDirs);
  }

  @override
  Future<void> remove(String absolutePath, {bool recursive = false}) async {
    final bool present =
        files.containsKey(absolutePath) ||
        files.keys.any((String k) => k.startsWith('$absolutePath/')) ||
        dirs.contains(absolutePath);
    if (!present) throw WorkspaceIoException('路径不存在：$absolutePath');
    if (!await isDirectory(absolutePath)) {
      files.remove(absolutePath);
      return;
    }
    final bool hasChildren =
        files.keys.any((String k) => k.startsWith('$absolutePath/')) ||
        dirs.any(
          (String d) => d != absolutePath && d.startsWith('$absolutePath/'),
        );
    if (hasChildren && !recursive) {
      throw WorkspaceIoException('目录非空：$absolutePath');
    }
    files.removeWhere(
      (String k, List<int> _) =>
          k == absolutePath || k.startsWith('$absolutePath/'),
    );
    dirs.removeWhere(
      (String d) => d == absolutePath || d.startsWith('$absolutePath/'),
    );
  }

  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    commands.add(command);
    // timeout 只记录下来：M9 1.1 的判据是心跳不是总时长，测试据此确认
    // "签名还在、按时间终止没了"。
    timeouts.add(timeout);
    if (pendingRun != null) return pendingRun!.future; // 在途命令：由测试决定何时结束
    return onRun?.call(command) ??
        const SshExecResult(exitCode: 0, stdout: '', stderr: '');
  }

  /// 活性：真实现由心跳循环驱动，假传输由测试直接喂（recordMiss/recordBeat）。
  @override
  final SshLiveness liveness = SshLiveness();

  /// 假传输上的"在途操作"：由测试决定什么时候完成（null = 立刻成功返回）。
  Completer<SshExecResult>? pendingRun;

  /// openShell 收到的参数（交互终端的 SSH 分支：每开一次记一条）。
  final List<({int columns, int rows, String command, String workingDirectory})>
  shellOpens =
      <({int columns, int rows, String command, String workingDirectory})>[];

  /// 最后一次 openShell 交出去的假通道（测试用它灌输出 / 断言 close）。
  FakeSshShellChannel? lastShell;

  @override
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  }) async {
    shellOpens.add((
      columns: columns,
      rows: rows,
      command: command,
      workingDirectory: workingDirectory,
    ));
    final FakeSshShellChannel channel = FakeSshShellChannel();
    lastShell = channel;
    return channel;
  }

  @override
  Future<void> close() async => closed = true;
}
