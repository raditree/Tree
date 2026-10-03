import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'local_workspace_io.dart';
import 'ssh_login_shell.dart';
import 'ssh_liveness.dart';
import 'ssh_shell_channel.dart';
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
  DartSshTransport._(
    this._client,
    this._sftp,
    this._liveness,
    this._loginShellTemplate,
    this._log,
  );

  /// 用户配的登录外壳模板（null = 内置候选；`''` = 关；非空 = 自定义）。
  final String? _loginShellTemplate;

  final void Function(String message)? _log;

  /// 登录外壳包装器（**懒**：探测要借 [_client] 跑一条远端命令，而它在构造之后才可用）。
  ///
  /// 见 `ssh_login_shell.dart`：工具命令走的是 exec 通道（非登录 shell），
  /// 不包一层登录外壳就看不到 `/etc/profile`、`~/.profile` 里的 PATH（用户实测：`nvcc`）。
  late final SshLoginShell _loginShell = SshLoginShell(
    template: _loginShellTemplate,
    log: _log,
    prober: _probeLoginShell,
  );

  /// 探测一次"远端跑不跑得动这个登录外壳"（走原始 exec，不能自套娃）。
  Future<bool> _probeLoginShell(String command) async {
    try {
      final SSHRunResult result = await _client.runWithResult(command);
      return (result.exitCode ?? -1) == 0;
    } catch (error) {
      _log?.call('探测登录外壳失败：$error');
      return false;
    }
  }

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
    String? loginShell,
    void Function(String message)? log,
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
      loginShell,
      log,
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

  /// 删除远端文件（rm -f：不存在也不报错，与 SFTP remove 语义一致但更宽容）。
  @override
  Future<void> delete(String absolutePath) async {
    await run('rm -f ${_quote(absolutePath)}');
  }

  /// 新建一个远端目录（M11）：SFTP 的 mkdir，**不建父目录**（父目录缺失时 SFTP
  /// 直接报错，正是契约要的 parentMissing 语义）。
  @override
  Future<void> makeDirectory(String absolutePath) async {
    try {
      await _sftp.mkdir(absolutePath);
    } catch (error) {
      throw WorkspaceIoException('远端新建目录失败：$absolutePath（$error）');
    }
  }

  /// 重命名 / 移动远端路径（M11）：SFTP 的 rename。
  ///
  /// 服务器支持 `posix-rename@openssh.com` 时 dartssh2 会走扩展请求——那是**覆盖**
  /// 语义，因此调用方（[SshWorkspaceIO]）必须先自检目标是否存在。
  @override
  Future<void> rename(String oldPath, String newPath) async {
    try {
      await _sftp.rename(oldPath, newPath);
    } catch (error) {
      throw WorkspaceIoException('远端重命名失败：$oldPath → $newPath（$error）');
    }
  }

  /// 路径是否是目录（M11）：SFTP 的 stat（O(1)），读不到一律当「不是」。
  @override
  Future<bool> isDirectory(String absolutePath) async {
    try {
      final SftpFileAttrs attrs = await _sftp.stat(absolutePath);
      return attrs.isDirectory;
    } catch (_) {
      return false;
    }
  }

  /// 删除远端文件 / 目录（M11）：文件走 SFTP remove，目录走 rmdir（非空报错），
  /// [recursive] 时自底向上递归删。
  @override
  Future<void> remove(String absolutePath, {bool recursive = false}) async {
    final SftpFileAttrs attrs;
    try {
      attrs = await _sftp.stat(absolutePath);
    } catch (_) {
      throw WorkspaceIoException('远端路径不存在或无法访问：$absolutePath');
    }
    try {
      if (!attrs.isDirectory) {
        await _sftp.remove(absolutePath);
        return;
      }
      if (recursive) {
        await _removeTree(absolutePath);
        return;
      }
      await _sftp.rmdir(absolutePath);
    } catch (error) {
      throw WorkspaceIoException('远端删除失败：$absolutePath（$error）');
    }
  }

  /// 自底向上删一整棵远端子树（M11）。
  ///
  /// 为什么不用 `rm -rf`：SFTP 本来没有 rmtree，而 shell 方案要处理引号 / 转义 /
  /// 远端有没有 coreutils；SFTP 递归的代价只是往返次数，语义却完全确定——按
  /// **链接本身**删（lstat 看到的类型），绝不跟着符号链接删穿出去。
  Future<void> _removeTree(String absolutePath) async {
    final List<SftpName> names = await _sftp.listdir(absolutePath);
    for (final SftpName entry in names) {
      final String name = entry.filename;
      if (name == '.' || name == '..') continue;
      final String child = '$absolutePath/$name';
      if (entry.attr.isDirectory) {
        await _removeTree(child);
      } else {
        await _sftp.remove(child);
      }
    }
    await _sftp.rmdir(absolutePath);
  }

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
    //
    // 默认再包一层**登录外壳**（见 ssh_login_shell.dart）：exec 通道是非登录 shell，
    // 不包就看得到用户 ssh 进来时有的工具（`nvcc` 那类 profile PATH）。探测失败会逐级
    // 回退到"原样发"，所以这里不需要 try/catch 兜底。
    final String wire = await _loginShell.wrap(command);
    try {
      final SSHRunResult result = await _client.runWithResult(wire);
      return SshExecResult(
        exitCode: result.exitCode ?? -1,
        stdout: LocalWorkspaceIO.decodeBytes(result.stdout),
        stderr: LocalWorkspaceIO.decodeBytes(result.stderr),
      );
    } catch (error) {
      throw WorkspaceIoException('远端命令执行失败：$error');
    }
  }

  /// 打开一条**远端 shell 通道**（真 PTY）：交互终端（Ctrl+J）的远端分支。
  ///
  /// 真实 dartssh2 API（4.1.0，已核对 pub 缓存源码，不是凭记忆）：
  /// - `SSHClient.shell({SSHPtyConfig? pty, ...})` → `SSHSession`：**没有 command 参数**，
  ///   起的是远端登录 shell，`pty-req` 由 `pty:` 保证；
  /// - `SSHClient.execute(command, {SSHPtyConfig? pty, ...})` → `SSHSession`：让远端的
  ///   **登录 shell 以 `-c` 执行该命令**（就是 `ssh -t host '<cmd>'` 的行为），PTY 同样
  ///   由 `pty:` 保证，退出码是**命令**的退出码；
  /// - `SSHSession`：`stdout` / `stderr`、`write(Uint8List)`、
  ///   `resizeTerminal(int, int, [int, int])`、`exitCode`（可空）、`done`、`close()`。
  ///
  /// 由真实 API 决定的语义：
  /// - [command] 为空 ⇒ `shell(pty:)`：远端登录 shell；
  /// - [command] 非空 ⇒ `execute(command, pty:)`。**为什么不把命令写进 shell 通道**：
  ///   写进去之后命令跑完 shell 还活着，`exitCode` 拿到的是 **shell 的**退出码，终端
  ///   也不会像本地 PTY 那样在命令结束时退出（`startPtySession` 跑完即退出）——那会让
  ///   "命令终端"的语义在远端与本地不一致。真实 dartssh2 的 `shell()` 也没有 command
  ///   参数，本来就没法"用 shell 通道执行命令"。
  /// - [workingDirectory] 非空 ⇒ 先切到该**远端**目录（与 [SshWorkspaceIO.exec] 同一套
  ///   单引号转义）：命令分支前缀 `cd '<dir>' && `；登录 shell 分支只能把 `cd` 作为
  ///   一行输入写进去（`shell` 请求没有 cwd 参数），代价是这一行会被远端 shell 回显。
  /// - 会话的「exitCode 一定收口 / close 幂等 / 不关整条连接」由
  ///   [_DartSshShellChannel] 保证，本方法只负责"把通道打开"。
  @override
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  }) async {
    final String dir = workingDirectory.trim();
    final String cmd = command.trim();
    final SSHPtyConfig pty = SSHPtyConfig(width: columns, height: rows);
    try {
      if (cmd.isEmpty) {
        final SSHSession session = await _client.shell(pty: pty);
        final _DartSshShellChannel channel = _DartSshShellChannel(
          session,
          'ssh',
          _liveness,
        );
        channel.start();
        if (dir.isNotEmpty) {
          await channel.write(utf8.encode('cd ${_quote(dir)}\n'));
        }
        return channel;
      }
      final String line = dir.isEmpty ? cmd : 'cd ${_quote(dir)} && $cmd';
      final SSHSession session = await _client.execute(line, pty: pty);
      final _DartSshShellChannel channel = _DartSshShellChannel(
        session,
        'ssh',
        _liveness,
      );
      channel.start();
      return channel;
    } catch (error) {
      throw WorkspaceIoException('远端 shell 打开失败：$error');
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

/// [SshShellChannel] 的 dartssh2 实现：包住一条 [SSHSession]（见 [SshTransport.openShell]）。
///
/// 关键取舍（都受真实 API 约束）：
/// - **输出合并 stdout + stderr**：PTY 模式下 stderr 通常为空（sshd 把子进程的 stderr
///   并进了 pty），但协议允许对端用 extended data 发 stderr；两路都原样灌进同一个
///   `output`（原始字节、不解码），两路都结束才关 `output`——一块字节都不丢；
/// - **exitCode 一定会完成**（绝不悬挂）：由 `session.done`（对端关会话 / 链路断开 /
///   我们 destroy）与 [close] 两条路径收口；`SSHSession.exitCode` 为 null（对端没报
///   退出状态、被信号杀死、或我们主动关）时给 **-1**，与 [DartSshTransport.run] 的
///   `?? -1` 同一口径；
/// - **close 幂等，且只关这一条通道**：调 `SSHChannel.close()`（发 EOF / CHANNEL_CLOSE），
///   **绝不**调 `SSHClient.close()`——那会把整条连接（SFTP / exec / 其他会话）一起拆掉。
///   同时主动摘掉本地订阅并关掉 `output`，因此不等对端回应也能立刻收口（对端可能永远
///   不回 CLOSE，close 不能为它悬挂）；
/// - **不另起心跳**：输出有数据流动时记一次 [SshLiveness.recordBeat]（"数据在动 = 链路
///   活着"，与 SshWorkspaceIO 的流式读取同一口径）；心跳本身仍由 [DartSshTransport]
///   的定时器负责，这里只是把"终端在动"这条证据也记上。
class _DartSshShellChannel implements SshShellChannel {
  _DartSshShellChannel(this._session, this._shell, this._liveness);

  final SSHSession _session;

  final String _shell;

  final SshLiveness _liveness;

  final StreamController<List<int>> _output = StreamController<List<int>>();

  final Completer<int> _exit = Completer<int>();

  StreamSubscription<Uint8List>? _stdout;

  StreamSubscription<Uint8List>? _stderr;

  bool _stdoutDone = false;

  bool _stderrDone = false;

  bool _closed = false;

  /// 接上输出与退出码（构造后调用一次）。
  void start() {
    _stdout = _session.stdout.listen(
      _emit,
      onError: _emitError,
      onDone: () => _markDone(stdout: true),
    );
    _stderr = _session.stderr.listen(
      _emit,
      onError: _emitError,
      onDone: () => _markDone(stdout: false),
    );
    // 会话结束（对端关 / 链路断开 / destroy）也把退出码收口：这是"不许永久悬挂"
    // 的主路径，不能只靠调用方主动 close。错误分支一并收口——这条链上没有别的
    // 监听者，漏掉它就是一个没人接的异步错误。
    unawaited(
      _session.done.then(
        (void _) => _settle(),
        onError: (Object _) => _settle(),
      ),
    );
  }

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  String get shell => _shell;

  @override
  Future<int> get exitCode => _exit.future;

  /// 远端有数据在动 = 链路活着：记一次心跳（复用既有 SshLiveness，不另起一套）。
  void _emit(Uint8List chunk) {
    _liveness.recordBeat();
    if (_output.isClosed || chunk.isEmpty) return;
    _output.add(chunk);
  }

  void _emitError(Object error) {
    if (_output.isClosed) return;
    _output.addError(error);
  }

  void _markDone({required bool stdout}) {
    if (stdout) {
      _stdoutDone = true;
    } else {
      _stderrDone = true;
    }
    if (_stdoutDone && _stderrDone && !_output.isClosed) {
      unawaited(_output.close());
    }
  }

  /// 退出码收口：拿不到退出状态就给 -1（见类文档）。
  void _settle() {
    if (_exit.isCompleted) return;
    _exit.complete(_session.exitCode ?? -1);
  }

  @override
  Future<void> write(List<int> data) async {
    if (_closed || data.isEmpty) return;
    try {
      _session.write(Uint8List.fromList(data));
    } catch (_) {
      // 会话已结束（对端走了 / 通道关了）：静默丢弃。键盘输入是高频操作，为它抛
      // 异常只会刷满日志，而且核心那边也拦不住（用户还在打字）。
    }
  }

  @override
  Future<void> resize(int columns, int rows) async {
    if (_closed) return;
    // 通道已结束时 dartssh2 会抛 SSHStateError：如实上抛，由核心的终端服务
    // 记日志（尺寸变化是高频可覆盖的操作，不值得在这里吞掉）。
    _session.resizeTerminal(columns, rows);
  }

  @override
  Future<void> close() async {
    if (_closed) return; // 幂等：已结束直接返回，不抛
    _closed = true;
    // 只发这条通道的 EOF / CLOSE；**不**碰 SSHClient（整条连接是 SFTP / exec 共用的）。
    // 不 await done：对端可能永远不回 CLOSE，而 close 必须立刻返回。
    unawaited(_session.channel.close().catchError((Object _) {}));
    // 本地订阅直接摘掉、output 立刻收口：不等对端回应也让上层拿到结束。
    unawaited(_stdout?.cancel() ?? Future<void>.value());
    unawaited(_stderr?.cancel() ?? Future<void>.value());
    if (!_output.isClosed) unawaited(_output.close());
    _settle();
  }
}
