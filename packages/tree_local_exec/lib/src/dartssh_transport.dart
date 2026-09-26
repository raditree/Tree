import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'local_workspace_io.dart';
import 'ssh_workspace_io.dart';

/// [SshTransport] 的 dartssh2 实现（M4b-2b）。
///
/// 刻意保持极薄：只负责“连上、搬字节、跑命令”。所有工作空间语义（相对路径
/// 约束、行范围、唯一匹配编辑、grep 排除、结果截断）都在 [SshWorkspaceIO] 里，
/// 而那部分已被内存假传输的单测覆盖。真链路由门控集成测试验证
/// （设置 TREE_SSH_TEST_HOST 才跑）。
///
/// M9 1.1 的硬超时审计结论（本文件就是执行器里唯一可能藏超时的地方）：
/// - 建连 / 认证：原先各有 15s 硬超时，**已取消**（见 [connect]）；
/// - 命令执行：原先 [_client.runWithResult] 外挂 120s 硬超时，**已取消**（见 [run]）；
/// - SFTP 读写（read/write/readStream/writeStream/size/listEntries）：本来就
///   没有挂超时，是分块流式推进，无需改动；
/// - 重试等待：本层没有重试循环，也就没有等待超时。
/// 链路活性统一由 keepalive 心跳体现，心跳缺失只用于上层的健康度/重连决策。
class DartSshTransport implements SshTransport {
  DartSshTransport._(this._client, this._sftp);

  /// 建立连接。
  ///
  /// M9 1.1：这里**不设**建连/认证超时。本地执行场景不存在服务器上"多用户无限期
  /// 等待把资源耗光"的后果，而超时会把"慢但在推进"的连接直接判死（弱网/跳板机
  /// 上很常见）；连接活性改由 keepalive 心跳体现，心跳丢了也只影响上层的健康度
  /// 与重连决策，不在这里杀连接。
  static Future<DartSshTransport> connect({
    required String host,
    required int port,
    required String username,
    String password = '',
    String keyPath = '',
    String keyPassphrase = '',
  }) async {
    List<SSHKeyPair>? identities;
    if (keyPath.isNotEmpty) {
      final File keyFile = File(keyPath);
      if (!keyFile.existsSync()) {
        throw WorkspaceIoException('私钥文件不存在：$keyPath');
      }
      identities = SSHKeyPair.fromPem(
        keyFile.readAsStringSync(),
        keyPassphrase.isEmpty ? null : keyPassphrase,
      );
    }
    final SSHSocket socket = await SSHSocket.connect(host, port);
    final SSHClient client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: password.isEmpty ? null : () => password,
      // 心跳（1.1）：dartssh2 的默认值也是 10s，这里显式写出来——长命令在远端
      // 跑着的时候靠它续命，免得中间设备把空闲连接掐掉。只发心跳，不因为心跳
      // 缺失在这里关连接。
      keepAliveInterval: const Duration(seconds: 10),
    );
    try {
      await client.authenticated;
    } catch (error) {
      client.close();
      throw WorkspaceIoException('SSH 认证失败：$error');
    }
    final SftpClient sftp = await client.sftp();
    return DartSshTransport._(client, sftp);
  }

  final SSHClient _client;
  final SftpClient _sftp;

  @override
  Future<List<int>> read(String absolutePath) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in readStream(absolutePath)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> write(String absolutePath, List<int> bytes) =>
      writeStream(absolutePath, Stream<List<int>>.value(bytes));

  /// 远端文件大小（M8c：大文件预览/下载先问大小，不再先整读再判上限）。
  @override
  Future<int> size(String absolutePath) async {
    try {
      final SftpFileAttrs attrs = await _sftp.stat(absolutePath);
      return attrs.size ?? 0;
    } catch (error) {
      throw WorkspaceIoException('远端文件不存在或无法读取：$absolutePath');
    }
  }

  /// 远端字节流：dartssh2 的 [SftpFile.read] 自带分块与乱序重排，
  /// 这里**逐块 yield**，调用方（HTTP 响应 / 本地落盘）拿到一块处理一块。
  @override
  Stream<List<int>> readStream(
    String absolutePath, {
    int offset = 0,
    int? length,
  }) async* {
    final SftpFile file;
    try {
      file = await _sftp.open(absolutePath, mode: SftpFileOpenMode.read);
    } catch (error) {
      throw WorkspaceIoException('远端文件不存在或无法读取：$absolutePath');
    }
    try {
      yield* file.read(offset: offset, length: length);
    } finally {
      await file.close();
    }
  }

  /// 把字节流直接写进远端文件：SFTP 侧边收边写，本机不再把整个文件读进内存。
  @override
  Future<void> writeStream(String absolutePath, Stream<List<int>> data) async {
    final int slash = absolutePath.lastIndexOf('/');
    if (slash > 0) {
      await run('mkdir -p ${_quote(absolutePath.substring(0, slash))}');
    }
    final SftpFile file = await _sftp.open(
      absolutePath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.write(data.map(Uint8List.fromList)).done;
    } finally {
      await file.close();
    }
  }

  @override
  Future<List<String>> listFiles(
    String absolutePath, {
    int maxDepth = 0,
  }) async {
    final String depth = maxDepth > 0 ? ' -maxdepth $maxDepth' : '';
    final SshExecResult result = await run(
      'find ${_quote(absolutePath)}$depth -type f',
    );
    final List<String> out = <String>[];
    for (final String raw in const LineSplitter().convert(result.stdout)) {
      final String line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      out.add(
        line.startsWith('$absolutePath/')
            ? line.substring(absolutePath.length + 1)
            : line,
      );
    }
    return out;
  }

  @override
  Future<List<SshFileEntry>> listEntries(
    String absolutePath, {
    int maxEntries = 2000,
  }) async {
    final List<SftpName> names;
    try {
      names = await _sftp.listdir(absolutePath);
    } catch (error) {
      throw WorkspaceIoException('远端目录不存在或无法读取：$absolutePath');
    }
    final List<SshFileEntry> out = <SshFileEntry>[];
    for (final SftpName entry in names) {
      if (out.length >= maxEntries) break;
      final String name = entry.filename;
      if (name == '.' || name == '..') continue;
      final SftpFileAttrs attr = entry.attr;
      final int? mtime = attr.modifyTime;
      out.add(
        SshFileEntry(
          name: name,
          isDirectory: attr.isDirectory,
          size: attr.size ?? 0,
          // dartssh2 给的是 epoch 秒
          modified: mtime == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
        ),
      );
    }
    return out;
  }

  @override
  Future<bool> exists(String absolutePath) async {
    final SshExecResult result = await run('test -e ${_quote(absolutePath)}');
    return result.exitCode == 0;
  }

  /// 连接是否还活着（心跳/重连决策用的状态标记；不在这里动连接）。
  @override
  bool get isConnected => !_client.isClosed;

  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    // M9 1.1：[timeout] 不再用于终止命令——远端命令跑多久就等多久。链路断了
    // runWithResult 自己会抛错（那时连接状态也由 isConnected 反映出来），
    // 而"慢"不该被判死。
    try {
      final SSHRunResult result = await _client.runWithResult(command);
      return SshExecResult(
        exitCode: result.exitCode ?? -1,
        stdout: LocalWorkspaceIO.decodeBytes(result.stdout),
        stderr: LocalWorkspaceIO.decodeBytes(result.stderr),
      );
    } catch (error) {
      throw WorkspaceIoException('远端命令执行失败：$error');
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }

  static String _quote(String value) =>
      "'${value.replaceAll("'", "'"
          r'\'
          "''")}'";
}
