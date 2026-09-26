import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'local_workspace_io.dart';
import 'ssh_liveness.dart';
import 'ssh_workspace_io.dart';

/// [SshTransport] 的 dartssh2 实现（M4b-2b）。
///
/// 刻意保持极薄：只负责“连上、搬字节、跑命令”。所有工作空间语义（相对路径
/// 约束、行范围、唯一匹配编辑、grep 排除、结果截断）都在 [SshWorkspaceIO] 里，
/// 而那部分已被内存假传输的单测覆盖。真链路由门控集成测试验证
/// （设置 TREE_SSH_TEST_HOST 才跑）。
///
/// M9 1.1：**没有静态总时长上限，只有心跳判据**（本文件是执行器里唯一可能藏
/// 超时的地方，逐条审计如下）：
/// - 建连 / 认证：原先各有 15s 硬超时，**已取消**（见 [connect]）——连接慢不等于
///   连接坏，判它坏不坏看心跳；
/// - 命令执行：原先 [_client.runWithResult] 外挂 120s 硬超时，**已取消**（见 [run]）；
///   命令跑多久都行，心跳丢了才由 [liveness] 判失活；
/// - SFTP 读写：本来就没有挂超时（分块流式推进），只在外面套活性守卫；
/// - 重试等待：本层没有重试循环，也就没有等待超时；
/// - 心跳：见 [_beat]，每 [SshLiveness.interval] 一次 keepalive，**窗口同样是
///   一个间隔**——窗口内没等到回包（成功/失败回包都算回）就记一次丢失，连续
///   [SshLiveness.maxMisses] 次判失活。丢的只是"判据"，不是时间本身。
class DartSshTransport implements SshTransport {
  DartSshTransport._(this._client, this._sftp, this._liveness);

  /// 建立连接。
  ///
  /// M9 1.1：这里**不设**建连/认证超时。本地执行场景不存在服务器上"多用户无限期
  /// 等待把资源耗光"的后果，而超时会把"慢但在推进"的连接直接判死（弱网/跳板机
  /// 上很常见）；连接活性改由心跳体现（[heartbeatInterval] × [maxMissedHeartbeats]），
  /// 心跳丢了也只标记失活、让在途操作显式失败，**不在这里杀连接**。
  static Future<DartSshTransport> connect({
    required String host,
    required int port,
    required String username,
    String password = '',
    String keyPath = '',
    String keyPassphrase = '',
    Duration heartbeatInterval = SshLiveness.defaultInterval,
    int maxMissedHeartbeats = SshLiveness.defaultMaxMisses,
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
      // 心跳改由本类自己发（见 [_beat]）：dartssh2 内置的 keepAliveInterval 也会
      // ping，但它的 SSHKeepAlive 把结果全吞了，观测不到"这一拍到底回没回"——
      // 而 1.1 要的正是这个。关掉内置的那份，避免重复发。
      keepAliveInterval: null,
    );
    try {
      await client.authenticated;
    } catch (error) {
      client.close();
      throw WorkspaceIoException('SSH 认证失败：$error');
    }
    final SftpClient sftp = await client.sftp();
    final DartSshTransport transport = DartSshTransport._(
      client,
      sftp,
      SshLiveness(interval: heartbeatInterval, maxMisses: maxMissedHeartbeats),
    );
    transport._startHeartbeat();
    return transport;
  }

  final SSHClient _client;
  final SftpClient _sftp;
  final SshLiveness _liveness;

  Timer? _heartbeat;
  bool _beating = false;

  /// 开始心跳：每 [SshLiveness.interval] 一拍，单拍窗口同样是一个间隔。
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_liveness.interval, (Timer _) => _beat());
  }

  /// 一拍心跳：发一次 keepalive 全局请求，窗口内拿到回包就算链路活着。
  ///
  /// 为什么是"窗口"而不是"总时长"：dartssh2 的 ping 内部 await 的是 keepalive
  /// 请求的回包（[SSH_Message_Request_Success] 与 [SSH_Message_Request_Failure]
  /// 都会唤醒它，所以任何合规服务端都算"回了"），对端真失联时它永远不完成。
  /// 窗口只度量**单次心跳有没有回**，与"这条命令总共跑了多久"无关——命令跑一天
  /// 也不会因此被杀，只有连续 [_liveness.maxMisses] 拍没回才判失活。
  Future<void> _beat() async {
    if (_beating) return; // 上一拍还没结束（慢链路）：不叠新的请求
    _beating = true;
    try {
      await _client.ping().timeout(_liveness.interval);
      _liveness.recordBeat();
    } catch (_) {
      // 窗口内没回包（或链路已断）：记一次丢失，达到阈值就唤醒在途操作。
      // **不在这里关连接**：可能只是抖了一下，下一拍回来就自动清零。
      _liveness.recordMiss();
    } finally {
      _beating = false;
    }
  }

  /// 链路活性快照（1.1）：最近心跳时间 / 连续丢失计数 / 是否失活。
  @override
  SshLiveness get liveness => _liveness;

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

  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    // M9 1.1：[timeout] 不再用于终止命令——远端命令跑多久就等多久（没有静态总时长
    // 上限）。真正会打断它的是心跳判据：连续丢心跳由 SshWorkspaceIO 的活性守卫
    // 让在途操作显式失败；链路断开时 runWithResult 自己也会抛错。
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
    _heartbeat?.cancel();
    _heartbeat = null;
    _client.close();
  }

  static String _quote(String value) =>
      "'${value.replaceAll("'", "'"
          r'\'
          "''")}'";
}
