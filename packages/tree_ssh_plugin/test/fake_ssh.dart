import 'dart:async';
import 'dart:convert';

import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 测试用的「假远端机器」：记录每一条执行过的命令，并维护一个**极小**的虚拟文件系统。
///
/// 为什么值得写这么一层：`dartssh2` 在单测里连不上真机，而本插件最容易出错的地方
/// 恰恰是**命令形状**（`sha256sum` 对账、base64 分块、`chmod +x`、拉起命令行）。
/// 把假远端写成"只认识这些形状、别的形状直接抛"，任何形状漂移都会让用例变红。
class FakeRemote {
  FakeRemote({
    this.home = '/home/tester',
    this.machine = 'x86_64',
    this.agentVersion = '1.2.3',
  });

  /// 远端 `$HOME`。
  String home;

  /// `uname -m` 的输出。
  String machine;

  /// 当前测试关心的 agent 版本（决定安装路径）。
  String agentVersion;

  /// 虚拟文件系统（绝对路径 → 字节）。
  final Map<String, List<int>> files = <String, List<int>>{};

  /// `mkdir -p` 过的目录。
  final Set<String> dirs = <String>{};

  /// 执行过的每一条命令（**顺序**，断言形状用）。
  final List<String> commands = [];

  /// `command -v <x>` 能成功的名字（登录外壳探测）。
  final Set<String> availableCommands = <String>{'bash', 'sh'};

  /// 打开过几次常驻通道、通道上收到的命令行。
  final List<String> spawned = <String>[];

  /// 建连次数（去重/重连用例断言）。
  int dials = 0;

  /// 最后一次建起来的常驻通道（用例拿它模拟"链路断掉"）。
  FakeSshChannel? lastChannel;

  /// 这些方法假 agent **不回包**（用来制造"在途请求"）。
  final Set<String> silentMethods = <String>{};

  /// 上一世 agent 清理命令（重建前"按 token 精确收掉"）针对过的 pid。
  final List<int> reapedPids = <int>[];

  /// 清理命令的应答覆盖（null = 按"spawn 记录里有没有这个 token"自动答 reaped / gone）。
  String? Function(int pid, String token)? reapResponder;

  /// 被关掉的连接次数。
  int closed = 0;

  /// 命令里含这个子串就抛（模拟链路/执行失败）。
  String? failCommandsContaining;

  /// 常驻通道起不来（模拟 spawn 失败）。
  bool failSpawn = false;

  /// 常驻通道的退出码（默认一直活着）。
  int channelExitCode = -1;

  /// 常驻通道上"假 agent"的握手协议版本（≠ 1 用来测 `handshake_failed`）。
  int helloProtocol = kAgentProtocolVersion;

  /// 假 agent 自报的架构。
  String helloArch = 'x86_64';

  /// 假 agent 对某个 L2 方法的自定义响应（默认回 `{'ok': true}`）。
  Map<String, dynamic> Function(String method, Map<String, dynamic> params)?
      handler;

  /// 假 agent 对某个 L2 方法回**错误**（`{code, message}`）；优先于 [handler]。
  Map<String, dynamic>? Function(String method, Map<String, dynamic> params)?
      errorHandler;

  /// 远端某条命令的执行记录（断言"用了哪个形状"）。
  String get lastCommand => commands.isEmpty ? '' : commands.last;

  /// 拼出 agent 在目标机上的路径。
  String agentPath(String binaryName) =>
      '$home/$kAgentInstallDir/$agentVersion/$binaryName';

  FakeSshConnection connect() {
    dials++;
    return FakeSshConnection(this);
  }

  /// 预置一个远端文件（"已经推过了"的场景）。
  void putFile(String path, List<int> bytes) {
    files[path] = List<int>.of(bytes);
  }

  /// 简易的命令解析：只认 bootstrap / 探测会发的形状。
  Future<ExecOutcome> run(String command) async {
    commands.add(command);
    final String? fail = failCommandsContaining;
    if (fail != null && command.contains(fail)) {
      throw SshDialException('假远端拒绝了命令：$command');
    }
    if (command == 'uname -m') {
      return ExecOutcome(exitCode: 0, stdout: utf8.encode('$machine\n'));
    }
    if (command.startsWith('printf $kHomeMarker%s')) {
      return ExecOutcome(exitCode: 0, stdout: utf8.encode('$kHomeMarker$home'));
    }
    final RegExpMatch? mkdir = RegExp(r"^mkdir -p '(.+)'$").firstMatch(command);
    if (mkdir != null) {
      dirs.add(mkdir.group(1)!);
      return const ExecOutcome(exitCode: 0);
    }
    final RegExpMatch? shaCheck = RegExp(
      "^if \\[ -f '(.+)' \\]; then sha256sum '(.+)'; "
      'else echo $kMissingMarker; fi\$',
    ).firstMatch(command);
    if (shaCheck != null) {
      final String path = shaCheck.group(1)!;
      final List<int>? bytes = files[path];
      if (bytes == null) {
        return ExecOutcome(exitCode: 0, stdout: utf8.encode('$kMissingMarker\n'));
      }
      return ExecOutcome(
        exitCode: 0,
        stdout: utf8.encode('${sha256Hex(bytes)}  $path\n'),
      );
    }
    final RegExpMatch? push = RegExp(
      r"^printf %s '([A-Za-z0-9+/=]*)' \| base64 -d (>>?) '(.+)'$",
    ).firstMatch(command);
    if (push != null) {
      final List<int> chunk = base64.decode(push.group(1)!);
      final bool append = push.group(2) == '>>';
      final String path = push.group(3)!;
      if (append) {
        files.putIfAbsent(path, () => <int>[]).addAll(chunk);
      } else {
        files[path] = List<int>.of(chunk);
      }
      return const ExecOutcome(exitCode: 0);
    }
    final RegExpMatch? chmodMv = RegExp(
      r"^chmod \+x '(.+)' && mv -f '(.+)' '(.+)'$",
    ).firstMatch(command);
    if (chmodMv != null) {
      final String from = chmodMv.group(2)!;
      final String to = chmodMv.group(3)!;
      final List<int>? bytes = files.remove(from);
      if (bytes == null) {
        return const ExecOutcome(exitCode: 1);
      }
      files[to] = bytes;
      return const ExecOutcome(exitCode: 0);
    }
    final RegExpMatch? chmod = RegExp(r"^chmod \+x '(.+)'$").firstMatch(command);
    if (chmod != null) {
      return ExecOutcome(exitCode: files.containsKey(chmod.group(1)) ? 0 : 1);
    }
    final RegExpMatch? shaOne = RegExp(
      r"^sha256sum '(.+)'$",
    ).firstMatch(command);
    if (shaOne != null) {
      final List<int>? bytes = files[shaOne.group(1)!];
      if (bytes == null) return const ExecOutcome(exitCode: 1);
      return ExecOutcome(
        exitCode: 0,
        stdout: utf8.encode('${sha256Hex(bytes)}  ${shaOne.group(1)}\n'),
      );
    }
    final RegExpMatch? check =
        RegExp(r'^command -v (\S+)$').firstMatch(command);
    if (check != null) {
      final bool ok = availableCommands.contains(check.group(1));
      return ExecOutcome(
        exitCode: ok ? 0 : 1,
        stdout: ok ? utf8.encode('/usr/bin/${check.group(1)}\n') : const <int>[],
      );
    }
    // 自定义登录外壳模板的探活：`zsh -lc 'true'` 这类。
    if (command.endsWith("'true'") || command.endsWith('true')) {
      final String shell = command.split(' ').first;
      return ExecOutcome(
        exitCode: availableCommands.contains(shell) ? 0 : 1,
      );
    }
    // 上一世 agent 清理（形状见 `tunnel.dart` 的 `_reapPreviousAgent`）：
    // 真语义是"在 /proc/<pid>/cmdline 里按一次性 token 核对，是它才 kill"。
    // 这里只做"认得出这条命令 + 记下 pid"，应答由 [reapResponder] 或 spawn 记录推断。
    if (command.contains('/proc/') && command.contains('grep -qF --')) {
      final RegExpMatch pidMatch =
          RegExp(r'/proc/(\d+)/cmdline').firstMatch(command)!;
      final RegExpMatch tokenMatch =
          RegExp(r"grep -qF -- '([^']*)'").firstMatch(command)!;
      final int pid = int.parse(pidMatch.group(1)!);
      final String token = tokenMatch.group(1)!;
      reapedPids.add(pid);
      final String? custom = reapResponder?.call(pid, token);
      if (custom != null) {
        return ExecOutcome(exitCode: 0, stdout: utf8.encode('$custom\n'));
      }
      final bool ours = spawned.any((String s) => s.contains(token));
      return ExecOutcome(
        exitCode: 0,
        stdout: utf8.encode(ours ? 'reaped\n' : 'gone\n'),
      );
    }
    throw StateError('假远端不认识这条命令（形状漂移了？）：$command');
  }
}

/// 假连接：每次 [SshConnection.exec] 都转发给 [FakeRemote]，[openChannel] 起假通道。
class FakeSshConnection implements SshConnection {
  FakeSshConnection(this.remote);

  final FakeRemote remote;
  bool closed = false;

  @override
  Future<ExecOutcome> exec(String command) => remote.run(command);

  @override
  Future<SshChannel> openChannel(String command) async {
    if (remote.failSpawn) {
      throw SshDialException('假远端：起不来常驻通道');
    }
    remote.spawned.add(command);
    final FakeSshChannel channel = FakeSshChannel(
      remote,
      exitCode: remote.channelExitCode,
    );
    remote.lastChannel = channel;
    return channel;
  }

  @override
  Future<void> close() async {
    closed = true;
    remote.closed++;
  }
}

/// 假常驻通道 + 一个**极小的假 agent**（自动回 `agent.hello`，其余按 [FakeRemote.handler]）。
class FakeSshChannel implements SshChannel {
  FakeSshChannel(this.remote, {int exitCode = -1}) {
    _decoder = LineFrameDecoder(onFrame: _onFrame);
    if (exitCode >= 0) {
      // 直接给出退出码 = 通道一出生就结束。
      scheduleMicrotask(() {
        if (!_exit.isCompleted) _exit.complete(exitCode);
      });
    }
  }

  final FakeRemote remote;
  final StreamController<List<int>> _stdout =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderr =
      StreamController<List<int>>.broadcast();

  /// 收到的每一帧（断言"插件发了什么"）。
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];

  final List<List<int>> rawWrites = <List<int>>[];
  late final LineFrameDecoder _decoder;
  final Completer<int> _exit = Completer<int>();
  bool _closed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(List<int> bytes) {
    rawWrites.add(bytes);
    _decoder.add(bytes);
  }

  /// 让假 agent 主动推一段原始字节（通知 / 坏帧）。
  void emitRaw(List<int> bytes) {
    if (!_stdout.isClosed) _stdout.add(bytes);
  }

  /// 让假 agent 推一条通知。
  void emitFrame(Map<String, dynamic> frame) => emitRaw(encodeFrame(frame));

  /// 让假 agent 写一段 stderr（只该进日志）。
  void emitStderr(List<int> bytes) {
    if (!_stderr.isClosed) _stderr.add(bytes);
  }

  /// 推一条 L2 通知（如 `shell.data` / `shell.exit`）。
  void emitNotification(String method, Map<String, dynamic> params) =>
      emitFrame(rpcNotification(method, params));

  /// 通道断了（模拟 SSH 链路掉线）：退出码 + 关流。
  void kill() {
    if (!_exit.isCompleted) _exit.complete(-1);
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    kill();
  }

  /// 帧分发（假 agent 的行为）。
  void _onFrame(Map<String, dynamic> frame) {
    received.add(frame);
    final Object? id = frame['id'];
    if (frame['method'] == null || id == null) return; // 不处理响应/通知
    final String method = frame['method'] as String;
    final Map<String, dynamic> params = frame['params'] is Map
        ? (frame['params'] as Map).map(
            (dynamic k, dynamic v) => MapEntry('$k', v),
          )
        : <String, dynamic>{};
    if (remote.silentMethods.contains(method)) return; // 故意不回包

    final Map<String, dynamic>? Function(String, Map<String, dynamic>)?
        onError = remote.errorHandler;
    final Map<String, dynamic>? failure = onError?.call(method, params);
    if (failure != null) {
      emitFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': failure,
      });
      return;
    }

    if (method == AgentMethods.hello) {
      _respond(id, <String, dynamic>{
        'protocol': remote.helloProtocol,
        'ok': true,
        'agent_version': remote.agentVersion,
        'os': 'linux',
        'arch': remote.helloArch,
        'home': remote.home,
        'root': params['root'] ?? remote.home,
        'pid': 4242,
      });
      return;
    }

    final Map<String, dynamic> Function(String, Map<String, dynamic>)? custom =
        remote.handler;
    _respond(id, custom == null
        ? <String, dynamic>{'ok': true}
        : custom(method, params));
  }

  void _respond(Object? id, Map<String, dynamic> result) {
    emitFrame(rpcResult(id ?? 0, result));
  }
}

/// 假的 dialer（可注入 [Tunnel] / [TunnelManager] / [PluginLoop]）。
class FakeDialer {
  FakeDialer(this.remote, {this.delay = Duration.zero});

  final FakeRemote remote;

  /// 每次建连的耗时（模拟慢网络；并发用例用）。
  Duration delay;

  /// 被调用过几次（含失败的尝试）。
  int calls = 0;

  /// 每次建连后的"钩子"（例如让某次建连就失败）。
  SshDialException? Function(int attempt)? failWith;

  Future<SshConnection> call(TunnelConfig config) async {
    final int attempt = calls + 1;
    calls++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final SshDialException? failure = failWith?.call(attempt);
    if (failure != null) throw failure;
    return remote.connect();
  }
}

/// 假的定时器工厂（退避用例不真等 30 分钟）。
class FakeTimers {
  final List<FakeTimer> timers = <FakeTimer>[];

  /// 被排过期的间隔（按顺序）。
  List<Duration> get delays =>
      timers.map((FakeTimer t) => t.duration).toList(growable: false);

  /// 还活着的定时器（未取消的）。
  List<FakeTimer> get pending =>
      timers.where((FakeTimer t) => !t.cancelled && !t.fired).toList();

  DelayTimer factory(Duration duration, void Function() callback) {
    final FakeTimer timer = FakeTimer(duration, callback);
    timers.add(timer);
    return timer;
  }

  /// 触发**最新**一个未触发的定时器（退避到点）。
  bool fireNext() {
    for (final FakeTimer timer in timers) {
      if (!timer.cancelled && !timer.fired) {
        timer.fire();
        return true;
      }
    }
    return false;
  }
}

class FakeTimer implements DelayTimer {
  FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool cancelled = false;
  bool fired = false;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    callback();
  }

  @override
  void cancel() => cancelled = true;
}

/// 让所有已排队的微任务/事件转一圈（异步断言前的"泵"）。
Future<void> pump([int rounds = 4]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 一个够用的 L1 `tunnel.ensure` config。
Map<String, dynamic> configJson({
  String host = '10.0.0.1',
  int port = 22,
  String username = 'tester',
  String password = 'secret',
  String root = '',
  Object? loginShell,
  String agentsDir = '',
}) => <String, dynamic>{
  'host': host,
  'port': port,
  'username': username,
  if (password.isNotEmpty) 'password': password,
  if (root.isNotEmpty) 'root': root,
  'login_shell': ?loginShell,
  if (agentsDir.isNotEmpty) 'agents_dir': agentsDir,

};

/// 直接用内存字节当"随包 agent"（避免单测依赖真文件）。
AgentBinaryLoader memoryBinary(
  List<int> bytes, {
  String name = 'tree_agent-linux-amd64',
}) => (AgentRequest request, String arch) async => AgentBinary(
  path: '/local/assets/$name',
  name: name,
  bytes: bytes,
);
