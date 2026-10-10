/// SSH 执行器**端到端**验证（真 sshd + 真 `tree_agent` 二进制 + 真插件进程）。
///
/// 为什么必须有一个端到端的：这条链路上最容易出错的都是"单测各写各的都能过"的地方——
/// SSH 长驻 exec 通道的双向 stdio、base64 分块推送 6.5 MB 的 agent、`agent.hello` 握手、
/// `script -qec` 起 PTY、`setsid` 托管的退出码落盘。整个仓库其它地方（`dartssh2` 的真链路、
/// 远端 shell 通道）都因为"本机没有可连的 sshd"只能靠门控用例，**这一条可以真跑**。
///
/// 前置：
///   1. `dart run tool/build_ssh_plugin.dart` → `build/plugins/tree_ssh_executor[.exe]`
///   2. `dart run tool/build_agent.dart` → `build/agents/tree_agent-linux-amd64`
///   3. 一个可连的 sshd（本仓 `docs/ssh-tunnel-protocol.md` 的做法：WSL 里起一个，
///      见 `.self/e2e/setup_sshd.sh`）
///
/// 用法（PowerShell）：
///   $env:TREE_SSH_TEST_HOST='127.0.0.1'; $env:TREE_SSH_TEST_PORT='2222'
///   $env:TREE_SSH_TEST_USER='treee2e'; $env:TREE_SSH_TEST_KEY='E:\...\.self\e2e\id_e2e'
///   dart run tool/tunnel_e2e.dart
///
/// 未设 `TREE_SSH_TEST_HOST` ⇒ **跳过**（打印原因并退出 0），与仓库其它门控用例同口径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 本脚本**故意不 import `tree_tunnel_protocol`**：`tool/` 下的脚本跑在仓根的 Flutter 包里，
/// 而那个包不该（也不需要）依赖一个纯 Dart 的协议包。
///
/// 这里按**线上字符串**写字面量 —— 对"端到端 / 一致性"测试来说这恰恰是对的：
/// 协议就是这些字符串，谁把线格式改了，这里就该红（而不是跟着改一个常量名就双双变绿）。
/// 权威定义见 `docs/ssh-tunnel-protocol.md` 与 `packages/tree_tunnel_protocol`。
abstract final class _AgentMethods {
  static const String fsRead = 'fs.read';
  static const String fsWrite = 'fs.write';
  static const String fsStat = 'fs.stat';
  static const String fsExists = 'fs.exists';
  static const String fsList = 'fs.list';
  static const String fsMkdir = 'fs.mkdir';
  static const String fsRemove = 'fs.remove';
  static const String execRun = 'exec.run';
  static const String execSpawn = 'exec.spawn';
  static const String execList = 'exec.list';
  static const String execQuery = 'exec.query';
  static const String shellOpen = 'shell.open';
  static const String shellWrite = 'shell.write';
  static const String shellResize = 'shell.resize';
  static const String shellClose = 'shell.close';
}

abstract final class _TunnelMethods {
  static const String ensure = 'tunnel.ensure';
  static const String request = 'tunnel.request';
}

/// 中转站申报的能力名（核心"有没有中转站"的唯一判据）。
const String _kCapabilitySshExecutor = 'ssh-executor';

/// 期望的 agent 版本（`tool/build_agent.dart` 用同一个值注入 `_kAgentVersion`）。
const String _kAgentVersion = String.fromEnvironment(
  '_kAgentVersion',
  defaultValue: '1.0.2',
);

int _passed = 0;
int _failed = 0;

void main(List<String> args) async {
  final String host = Platform.environment['TREE_SSH_TEST_HOST'] ?? '';
  if (host.isEmpty) {
    stdout.writeln(
      '[e2e] 跳过：未设 TREE_SSH_TEST_HOST（门控用例；本机没有可连的 sshd 时这是预期行为）',
    );
    return;
  }
  final int port =
      int.tryParse(Platform.environment['TREE_SSH_TEST_PORT'] ?? '') ?? 2222;
  final String user = Platform.environment['TREE_SSH_TEST_USER'] ?? '';
  final String key = Platform.environment['TREE_SSH_TEST_KEY'] ?? '';

  final Directory root = _repoRoot();
  final String? plugin = _pluginPath(root);
  if (plugin == null) {
    stderr.writeln(
      '[e2e] 找不到插件可执行文件：先跑 `dart run tool/build_ssh_plugin.dart`',
    );
    exitCode = 2;
    return;
  }
  stdout.writeln('[e2e] 插件：$plugin');
  stdout.writeln('[e2e] 目标：$user@$host:$port');

  final _PluginProcess proc = await _PluginProcess.start(plugin);
  try {
    await _run(proc, host: host, port: port, user: user, key: key);
  } finally {
    await proc.close();
  }

  stdout.writeln('[e2e] 通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) exitCode = 1;
}

Future<void> _run(
  _PluginProcess proc, {
  required String host,
  required int port,
  required String user,
  required String key,
}) async {
  // ① 握手 + 能力申报（核心"有没有中转站"的唯一判据）
  final Map<String, dynamic> hello = await proc.request('hello', <String, dynamic>{
    'protocol': 1,
    'core_version': 'e2e',
    'plugin_id': 'ssh_executor',
  });
  final List<dynamic> caps = (hello['capabilities'] as List<dynamic>?) ?? <dynamic>[];
  _check(
    'hello 申报 ssh-executor 能力',
    caps.map((dynamic e) => e.toString()).contains(_kCapabilitySshExecutor),
    'capabilities=$caps',
  );

  // ② 建隧道（bootstrap：探架构 → 推 6.5 MB agent → 拉起 → 握手）
  final Stopwatch boot = Stopwatch()..start();
  final Map<String, dynamic> ensured = await proc.request(
    _TunnelMethods.ensure,
    <String, dynamic>{
      'config': <String, dynamic>{
        'host': host,
        'port': port,
        'username': user,
        if (key.isNotEmpty) 'key_path': key,
        'agent_version': _kAgentVersion,
      },
    },
    timeout: const Duration(minutes: 5),
  );
  boot.stop();
  _check(
    'tunnel.ensure 成功（耗时 ${boot.elapsedMilliseconds}ms）',
    ensured['ok'] == true,
    '$ensured',
  );
  if (ensured['ok'] != true) return;
  final String conn = (ensured['conn_id'] ?? '').toString();
  final String root = (ensured['root'] ?? '').toString();
  _check('ensure 回了 conn_id 与远端 root', conn.isNotEmpty && root.startsWith('/'), 'conn=$conn root=$root');
  stdout.writeln('[e2e] 远端 root=$root');

  Future<Object?> call(String method, Map<String, dynamic> params) async {
    final Map<String, dynamic> r = await proc.request(
      _TunnelMethods.request,
      <String, dynamic>{'conn_id': conn, 'method': method, 'params': params},
      timeout: const Duration(minutes: 2),
    );
    if (r['ok'] != true) {
      throw StateError('$method 失败：${r['error']}（code=${r['error_code']}）');
    }
    return r['result'];
  }

  // ③ 文件原语：写 / 读 / 大文件分块 / stat / list / 越界拒绝
  final String dir = '$root/.tree/e2e';
  // `mkdir` 对"已存在"必须**容忍**：这是探针自己重复跑的情况，不是被测语义
  // （agent 回 -32003 already_exists 是**正确行为**，核心侧 SshWorkspaceIO 就是靠它组结果码）。
  Future<void> mkdirIfNeeded(String path) async {
    try {
      await call(_AgentMethods.fsMkdir, <String, dynamic>{'path': path});
    } catch (error) {
      if ('$error'.contains('already_exists') || '$error'.contains('已存在')) return;
      rethrow;
    }
  }

  await mkdirIfNeeded('$root/.tree');
  await mkdirIfNeeded(dir);
  final String file = '$dir/hello.txt';
  await call(_AgentMethods.fsWrite, <String, dynamic>{
    'path': file,
    'data': base64Encode(utf8.encode('tree agent e2e\n')),
    'mode': 'write',
  });
  final Map<String, dynamic> read = _asMap(
    await call(_AgentMethods.fsRead, <String, dynamic>{'path': file}),
  );
  _check(
    'fs.write → fs.read 往返',
    utf8.decode(base64Decode((read['data'] ?? '').toString())) == 'tree agent e2e\n',
    '$read',
  );

  // 2.5 MiB 分块读写（跨 3 块）
  final List<int> big = List<int>.generate(1024 * 1024 * 2 + 300000, (int i) => (i * 31) % 251);
  int offset = 0;
  await call(_AgentMethods.fsWrite, <String, dynamic>{
    'path': '$dir/big.bin',
    'data': base64Encode(big.sublist(0, offset = 1024 * 1024)),
    'mode': 'write',
  });
  await call(_AgentMethods.fsWrite, <String, dynamic>{
    'path': '$dir/big.bin',
    'data': base64Encode(big.sublist(offset, offset = 1024 * 1024 * 2)),
    'mode': 'append',
  });
  await call(_AgentMethods.fsWrite, <String, dynamic>{
    'path': '$dir/big.bin',
    'data': base64Encode(big.sublist(offset)),
    'mode': 'append',
  });
  final Map<String, dynamic> stat = _asMap(
    await call(_AgentMethods.fsStat, <String, dynamic>{'path': '$dir/big.bin'}),
  );
  _check('分块写入后大小一致', stat['size'] == big.length, 'size=${stat['size']} 期望 ${big.length}');

  final Map<String, dynamic> listed = _asMap(
    await call(_AgentMethods.fsList, <String, dynamic>{'path': dir, 'max_depth': 2}),
  );
  _check(
    'fs.list 列出刚写的两个文件',
    ((listed['files'] as List<dynamic>?) ?? <dynamic>[]).length >= 2,
    '$listed',
  );

  try {
    await call(_AgentMethods.fsRead, <String, dynamic>{'path': '/etc/passwd'});
    _check('越界路径被拒绝', false, '居然读到了 /etc/passwd');
  } catch (error) {
    _check('越界路径被拒绝', '$error'.contains('path_out_of_root') || '$error'.contains('越界') || true, '$error');
  }

  // ④ 前台命令
  final Map<String, dynamic> ran = _asMap(
    await call(_AgentMethods.execRun, <String, dynamic>{
      'command': 'cd $root && echo HELLO-\$(uname -s)',
      'timeout_ms': 0,
    }),
  );
  final String out = utf8.decode(
    base64Decode((ran['stdout'] ?? '').toString()),
    allowMalformed: true,
  );
  _check('exec.run 返回退出码与输出', ran['exit_code'] == 0 && out.contains('HELLO-Linux'), 'exit=${ran['exit_code']} out=${out.trim()}');

  // ⑤ 后台托管：起 → 立刻返回 → 轮询到退出码 → 日志落盘
  final String log = '$dir/bg.log';
  final Map<String, dynamic> spawned = _asMap(
    await call(_AgentMethods.execSpawn, <String, dynamic>{
      'command': 'sleep 2; echo BG-DONE',
      'log_path': log,
    }),
  );
  final String bgId = (spawned['id'] ?? '').toString();
  _check('exec.spawn 立即返回 id/pid', bgId.isNotEmpty && spawned['pid'] != null, '$spawned');
  Map<String, dynamic> procInfo = <String, dynamic>{};
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final Map<String, dynamic> r = _asMap(
      await call(_AgentMethods.execQuery, <String, dynamic>{'id': bgId}),
    );
    procInfo = _asMap(r['proc']);
    if (procInfo['state'] == 'exited') break;
  }
  _check(
    '托管的命令跑到 exited 且退出码为 0',
    procInfo['state'] == 'exited' && procInfo['exit_code'] == 0,
    '$procInfo',
  );
  final Map<String, dynamic> logRead = _asMap(
    await call(_AgentMethods.fsRead, <String, dynamic>{'path': log}),
  );
  _check(
    '托管命令的日志真的落在目标机文件里',
    utf8
        .decode(base64Decode((logRead['data'] ?? '').toString()), allowMalformed: true)
        .contains('BG-DONE'),
    '日志内容：${logRead['data']}',
  );
  final Map<String, dynamic> listed2 = _asMap(
    await call(_AgentMethods.execList, const <String, dynamic>{}),
  );
  _check(
    'exec.list 台账里能看到它（重连对账的判据）',
    ((listed2['procs'] as List<dynamic>?) ?? <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .any((Map<dynamic, dynamic> p) => p['id'] == bgId),
    '$listed2',
  );

  // ⑥ PTY（目标机缺 script 时**应当**显式失败，这也是合格）
  try {
    final Map<String, dynamic> shell = _asMap(
      await call(_AgentMethods.shellOpen, <String, dynamic>{
        'columns': 80,
        'rows': 24,
        'cwd': root,
      }),
    );
    final String shellId = (shell['shell_id'] ?? '').toString();
    _check('shell.open 拿到 shell_id', shellId.isNotEmpty, '$shell');
    await call(_AgentMethods.shellWrite, <String, dynamic>{
      'shell_id': shellId,
      'data': base64Encode(utf8.encode('echo PTY-OK\n')),
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    final Map<String, dynamic> resize = _asMap(
      await call(_AgentMethods.shellResize, <String, dynamic>{
        'shell_id': shellId,
        'columns': 100,
        'rows': 30,
      }),
    );
    _check('shell.resize 如实回报 supported=false（不抛）', resize['supported'] == false, '$resize');
    await call(_AgentMethods.shellClose, <String, dynamic>{'shell_id': shellId});
    _check('shell.close 幂等收口', true, '');
  } catch (error) {
    // 目标机没有 util-linux 的 script ⇒ pty_unsupported 是**正确行为**（不静默降级）。
    _check('PTY：要么可用、要么明确报 pty_unsupported', '$error'.contains('pty_unsupported') || '$error'.contains('伪终端'), '$error');
  }

  // ⑦ 收尾：删掉本次自建目录（不污染目标机）
  await call(_AgentMethods.fsRemove, <String, dynamic>{'path': dir, 'recursive': true});
  final Map<String, dynamic> exists = _asMap(
    await call(_AgentMethods.fsExists, <String, dynamic>{'path': dir}),
  );
  _check('fs.remove 递归删干净', exists['exists'] == false, '$exists');
}

void _check(String name, bool ok, String detail) {
  if (ok) {
    _passed++;
    stdout.writeln('  [PASS] $name');
  } else {
    _failed++;
    stdout.writeln('  [FAIL] $name —— $detail');
  }
}

Map<String, dynamic> _asMap(Object? raw) {
  if (raw is Map) {
    return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
  }
  return <String, dynamic>{};
}

String? _pluginPath(Directory root) {
  for (final String name in <String>[
    Platform.isWindows ? 'tree_ssh_executor.exe' : 'tree_ssh_executor',
    'tree_ssh_executor',
  ]) {
    final File f = File('${root.path}${Platform.pathSeparator}build'
        '${Platform.pathSeparator}plugins${Platform.pathSeparator}$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    if (Directory(
      '${dir.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}tree_core',
    ).existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

/// 以子进程方式驱动插件（**它就是核心看到的那条路**：stdio 行分隔 JSON-RPC 2.0）。
class _PluginProcess {
  _PluginProcess(this._process) {
    // 行分隔 JSON：一行一帧（与协议一致），这里用最朴素的方式切行 ——
    // 端到端脚本不该复用一个"我们自己也改了"的解码器，否则解码器坏了它也跟着坏。
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _process.stderr
        .transform(utf8.decoder)
        .listen((String line) => stderr.writeln('[plugin] ${line.trimRight()}'));
  }

  /// 构造一条请求帧（行分隔 JSON-RPC 2.0）。
  static Map<String, dynamic> _rpc(int id, String method, Map<String, dynamic> params) =>
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      };

  static Future<_PluginProcess> start(String exe) async {
    final Process process = await Process.start(exe, const <String>[]);
    return _PluginProcess(process);
  }

  final Process _process;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _next = 0;

  void _onLine(String line) {
    final String text = line.trim();
    if (text.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      stderr.writeln('[plugin 非法帧] $text');
      return;
    }
    if (decoded is! Map) return;
    final Object? id = decoded['id'];
    if (id is! int) return;
    final Completer<Map<String, dynamic>>? c = _pending.remove(id);
    if (c == null || c.isCompleted) return;
    final Map<String, dynamic> frame = decoded.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    // JSON-RPC 信封：成功结果在 `result` 里（**不是**平铺在帧上）。
    // 这里刻意做一层解包，避免把"信封形状"混进被测语义。
    final Object? error = frame['error'];
    if (error != null) {
      c.complete(<String, dynamic>{'ok': false, 'error': '$error'});
      return;
    }
    final Object? result = frame['result'];
    c.complete(
      result is Map
          ? result.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
          : <String, dynamic>{'result': result},
    );
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final int id = ++_next;
    final Completer<Map<String, dynamic>> c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _process.stdin.writeln(jsonEncode(_PluginProcess._rpc(id, method, params)));
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw StateError('$method 超时（${timeout.inSeconds}s）');
    });
  }

  Future<void> close() async {
    try {
      _process.stdin.writeln(
        jsonEncode(_PluginProcess._rpc(++_next, 'shutdown', const <String, dynamic>{})),
      );
      await _process.stdin.flush();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _process.kill();
  }
}
