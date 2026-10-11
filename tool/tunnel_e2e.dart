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
  static const String ping = 'agent.ping';
}

abstract final class _TunnelMethods {
  static const String ensure = 'tunnel.ensure';
  static const String request = 'tunnel.request';
  static const String state = 'tunnel.state';
  static const String reconnect = 'tunnel.reconnect';
  static const String close = 'tunnel.close';
}

/// 中转站申报的能力名（核心"有没有中转站"的唯一判据）。
const String _kCapabilitySshExecutor = 'ssh-executor';

/// 请求里带的 agent 版本**提示**（2026-10-11 用户裁决 B 之后，核心不再声明版本，
/// 插件一律用**自己编译期注入的那个**）。这里故意送一个不存在的版本：用来钉住
/// "提示不决定安装目录"（见 ②b）。
const String _kAgentVersionHint = '0.0.0-e2e-hint';

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
        'agent_version': _kAgentVersionHint,
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

  /// 拉一次 `tunnel.state` 并取出这条隧道的快照（断连用例里要反复看 state）。
  Future<Map<String, dynamic>> stateOf() async {
    final Map<String, dynamic> st = await proc.request(
      _TunnelMethods.state,
      <String, dynamic>{'conn_id': conn},
      timeout: const Duration(seconds: 60),
    );
    final List<dynamic> tunnels = (st['tunnels'] as List<dynamic>?) ?? <dynamic>[];
    return tunnels
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) => m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
        .firstWhere(
          (Map<String, dynamic> m) => m['conn_id'] == conn,
          orElse: () => <String, dynamic>{},
        );
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

  // ⑦ 关停/接续语义（用户点名的四条，也是这次改动的全部卖点）
  //
  // 为什么必须在这条真机 e2e 里钉：这四条里有三条**只在真链路上才成立** ——
  // `setsid` 是否真的让托管任务脱离 agent、agent 被 kill 后插件会不会自动重拉、
  // 重拉的 agent 能不能只靠磁盘台账认出"上一世"起的任务。单测只能钉形状。
  //
  // 用同一条 ssh（就是插件用的那套凭据）去动目标机，**不经过被测链路**，
  // 这样"我杀了它"这件事不依赖被测代码自述。
  Future<String> sshRun(String command) async {
    final ProcessResult r = await Process.run('ssh', <String>[
      '-i', key,
      '-p', '$port',
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=10',
      '$user@$host',
      command,
    ]);
    return '${r.stdout}'.trim();
  }

  // ②b agent 版本口径（2026-10-11 用户裁决 B）：请求里那个版本只是**提示**，
  //    安装目录与推进去的都是插件**自己编进去**的那一版 ⇒ 不该在提示那个名字下留东西。
  //    （放在这里只是因为它要用上面那条独立 ssh；语义上仍属于 ② 建隧道。）
  final String home = (await sshRun('printf %s "\$HOME"')).trim();
  final String hintProbe = await sshRun(
    '[ -f "$home/.tree/agent/$_kAgentVersionHint/tree_agent-linux-amd64" ] '
    '&& echo YES || echo NO',
  );
  _check(
    '请求里的版本提示**不**决定安装目录（版本由插件自报）',
    hintProbe.trim() == 'NO',
    '竟然在 ~/.tree/agent/$_kAgentVersionHint/ 下找到了 agent',
  );

  // ⑦a 起一条**长**任务：它必须活着穿过"执行器被杀 + 重建"这一整段。
  final Map<String, dynamic> survivor = _asMap(
    await call(_AgentMethods.execSpawn, <String, dynamic>{
      'command': 'sleep 25; echo BG-SURVIVED',
      'log_path': '$dir/survivor.log',
    }),
  );
  final String svId = (survivor['id'] ?? '').toString();
  final int? svPid = (survivor['pid'] as num?)?.toInt();
  _check(
    '起了一条长任务（拿到 pid，供存活探针用）',
    svId.isNotEmpty && svPid != null,
    '$survivor',
  );

  // ⑦b 杀掉**执行器本身**（真·agent 进程死亡）
  //
  // 两个坑（都踩过）：
  // 1. `pgrep -f tree_agent` 会**自匹配**运行它的那条 `bash -lc` 包装 shell（cmdline 里有这个词）
  //    ⇒ 用 `[t]ree_agent` 方括号技巧：正则能匹配 "tree_agent"，而包装 shell 的 cmdline 里
  //    是字面量 "[t]ree_agent"，不匹配；
  // 2. 插件**会在 1~4s 内自动重连并重拉一个新 agent**（这是好事，不是"杀不死"）⇒
  //    断言必须是"**旧的那个 pid** 不在了"，而不是"一个 agent 都不剩"。
  const String agentPat = '[t]ree_agent-linux';
  final String agentPidsBefore = await sshRun('pgrep -f "$agentPat" | tr \'\\n\' \' \'');
  final List<String> oldAgentPids = agentPidsBefore
      .split(RegExp(r'\s+'))
      .where((String s) => s.isNotEmpty)
      .toList();
  _check(
    '杀之前目标机上确有 tree_agent 在跑',
    oldAgentPids.isNotEmpty,
    'pgrep -f "$agentPat" ⇒ "$agentPidsBefore"',
  );
  await sshRun('pkill -f "$agentPat"');
  await Future<void>.delayed(const Duration(seconds: 2));
  final String survivedOld = await sshRun(
    'for p in ${oldAgentPids.join(' ')}; do '
    'if kill -0 \$p 2>/dev/null; then echo -n "\$p "; fi; done',
  );
  _check(
    '旧执行器进程都没了（用 pid 判定，避开自动重拉带来的假阴性）',
    survivedOld.trim().isEmpty,
    'pkill 后仍活着的旧 pid：${survivedOld.trim()}（原为 ${oldAgentPids.join(' ')}）',
  );

  // ⑦c **核心断言**：在跑的后台进程**不受影响**（`setsid` 真的让它脱离了 agent）
  final String alive = await sshRun(
    'if kill -0 $svPid 2>/dev/null; then echo ALIVE; else echo DEAD; fi',
  );
  _check(
    '执行器死了，**在跑的后台进程仍然活着**（这条是"跨日稳定"的根）',
    alive == 'ALIVE',
    'kill -0 $svPid ⇒ "$alive"',
  );

  // ⑦d 重建：`tunnel.reconnect` = 重置退避 + 一次立即尝试（插件会重新推送/拉起 agent）
  await proc.request(
    _TunnelMethods.reconnect,
    <String, dynamic>{'conn_id': conn},
    timeout: const Duration(minutes: 3),
  );
  String state = '';
  for (int i = 0; i < 30; i++) {
    final Map<String, dynamic> st = await proc.request(
      _TunnelMethods.state,
      <String, dynamic>{'conn_id': conn},
    );
    final List<dynamic> tunnels = (st['tunnels'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> mine = tunnels
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) => m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
        .firstWhere((Map<String, dynamic> m) => m['conn_id'] == conn, orElse: () => <String, dynamic>{});
    state = (mine['state'] ?? '').toString();
    if (state == 'ready') break;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  _check('执行器被重建后隧道回到 ready', state == 'ready', 'state="$state"');

  // ⑦e **重启后接上**：新一世的 agent 只靠磁盘台账认出上一世起的任务
  final Map<String, dynamic> relisted = _asMap(
    await call(_AgentMethods.execList, const <String, dynamic>{}),
  );
  final Map<String, dynamic> svNow = ((relisted['procs'] as List<dynamic>?) ?? <dynamic>[])
      .whereType<Map<dynamic, dynamic>>()
      .map((Map<dynamic, dynamic> m) => m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
      .firstWhere(
        (Map<String, dynamic> p) => p['id'] == svId,
        orElse: () => <String, dynamic>{},
      );
  _check(
    '重建后的 agent 从台账里认出了那条任务（重启接上）',
    svNow.isNotEmpty && svNow['command'] == 'sleep 25; echo BG-SURVIVED',
    'exec.list 里 $svId ⇒ $svNow',
  );

  // ⑦f 跑完并收尾：退出码 + 日志都来自**落盘**（与它中途死过一次无关）
  final Stopwatch wait = Stopwatch()..start();
  Map<String, dynamic> svFinal = <String, dynamic>{};
  while (wait.elapsed < const Duration(seconds: 90)) {
    final Map<String, dynamic> q = _asMap(
      await call(_AgentMethods.execQuery, <String, dynamic>{'id': svId}),
    );
    svFinal = _asMap(q['proc']);
    if (svFinal['state'] == 'exited') break;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  _check(
    '跨过"执行器被杀+重建"仍拿到退出码 0（真相在目标机磁盘上）',
    svFinal['state'] == 'exited' && svFinal['exit_code'] == 0,
    '$svFinal',
  );
  final Map<String, dynamic> svLog = _asMap(
    await call(_AgentMethods.fsRead, <String, dynamic>{'path': '$dir/survivor.log'}),
  );
  _check(
    '它的日志也照常落盘（BG-SURVIVED）',
    utf8
        .decode(base64Decode((svLog['data'] ?? '').toString()), allowMalformed: true)
        .contains('BG-SURVIVED'),
    '${svLog['data']}',
  );

  // ⑦g 收尾：删掉本次自建目录（**必须在关隧道之前**——关掉 conn 之后就没有可用的 execut 通道了）
  await call(_AgentMethods.fsRemove, <String, dynamic>{'path': dir, 'recursive': true});
  final Map<String, dynamic> exists = _asMap(
    await call(_AgentMethods.fsExists, <String, dynamic>{'path': dir}),
  );
  _check('fs.remove 递归删干净', exists['exists'] == false, '$exists');

  // ⑧ **断连完整性**（2026-10-11 用户真机症状的正面复现）
  //
  // 用户原话："我主动物理断网模拟网络抖动时立即向 agent 返回了 hook 的失败，而且在重新恢复
  // 网络连接后直接在目标主机另起了执行器进程"。这一节从**服务端**制造两种断连，逐条钉住修法。
  //
  // ⑧a 执行器的命令行必须带 `--root`（越界基线）与 `--idle-timeout-ms`（静默自救上限）。
  final Map<String, dynamic> live = await stateOf();
  final Map<String, dynamic> liveAgent = _asMap(live['agent']);
  final int? livePid = (liveAgent['pid'] as num?)?.toInt();
  final String liveCmdline = livePid == null
      ? ''
      : await sshRun("tr '\\0' ' ' < /proc/$livePid/cmdline 2>/dev/null");
  _check(
    '执行器命令行带 --root（agent 的越界基线）',
    liveCmdline.contains('--root'),
    'pid=$livePid cmdline="$liveCmdline"',
  );
  _check(
    '执行器命令行带 --idle-timeout-ms（物理断网时它靠这条自己优雅退出）',
    liveCmdline.contains('--idle-timeout-ms 90000'),
    'pid=$livePid cmdline="$liveCmdline"',
  );

  // ⑧b **从服务端掐断这条常驻通道**（客户端立刻看到通道断，而在跑的后台任务不受影响）
  //     ⇒ 插件进 `reconnecting`，此时**新发起**的请求必须回 `tunnel_not_ready`（**没执行过**）——
  //     绝不许回 `tunnel_down`（那会让核心判死 + 回退内置，正是"一次抖动就让 hook 立刻失败"的根因）。
  //
  // 怎么掐：**顺着 agent 的父进程**找那条会话，杀它。
  // 为什么不用 `pkill -f 'sshd: ...'` 按名字杀（踩过两次）：
  //   ① 新版 OpenSSH 的会话进程叫 `sshd-session: <user>@notty`（不是 `sshd:`）；
  //   ② `[t]` 方括号防自匹配的写法要求方括号套在**第一个**字符上，
  //      用户名是 `treee2e` 时正确写法是 `[t]reee2e`，写成 `[t]treee2e` 会去匹配 `ttreee2e`（永不命中，
  //      而且命令成功返回 ⇒ 失败是静默的）。
  // 顺 agent 的父进程则与被杀进程的名字无关，稳。
  final String cutSession = livePid == null
      ? ''
      : await sshRun(
          'SES=\$(ps -o ppid= -p $livePid 2>/dev/null | tr -d " "); '
          'if [ -n "\$SES" ]; then kill "\$SES" 2>/dev/null && echo "killed \$SES" '
          '|| echo "kill-failed \$SES"; else echo "no-session"; fi',
        );
  _check(
    '掐断动作真的打到了那条会话（否则下面两条断言毫无意义）',
    cutSession.startsWith('killed'),
    'agent=$livePid ⇒ $cutSession',
  );
  String cutState = '';
  final Stopwatch cutWait = Stopwatch()..start();
  while (cutWait.elapsed < const Duration(seconds: 30)) {
    cutState = (await stateOf())['state'].toString();
    if (cutState == 'reconnecting') break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  _check('通道被掐断后插件进入 reconnecting', cutState == 'reconnecting', 'state="$cutState"');
  final Map<String, dynamic> duringCut = _asMap(
    await proc.request(_TunnelMethods.request, <String, dynamic>{
      'conn_id': conn,
      'method': _AgentMethods.ping,
      'params': <String, dynamic>{},
    }),
  );
  _check(
    '重连中的请求回 tunnel_not_ready（**不是**判死的 tunnel_down）',
    duringCut['ok'] == false && duringCut['error_kind'] == 'tunnel_not_ready',
    '$duringCut',
  );

  // ⑧c 自动重连（1s 退避第一拍 + 重新 bootstrap）⇒ 回 ready，且目标机上**只剩一个**执行器。
  String backState = '';
  final Stopwatch backWait = Stopwatch()..start();
  while (backWait.elapsed < const Duration(minutes: 3)) {
    backState = (await stateOf())['state'].toString();
    if (backState == 'ready') break;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  _check('通道断后**自动**重连回 ready（不需要手动 reconnect）', backState == 'ready', 'state="$backState"');
  final String pidsNow = await sshRun('pgrep -f "$agentPat" | tr \'\\n\' \' \'');
  final List<String> pidsList = pidsNow.split(RegExp(r'\s+')).where((String s) => s.isNotEmpty).toList();
  _check(
    '重建后目标机上只有一个执行器（不累积）',
    pidsList.length == 1,
    'pgrep -f "$agentPat" ⇒ "$pidsNow"',
  );
  if (livePid != null) {
    final String oldAlive = await sshRun(
      'if kill -0 $livePid 2>/dev/null; then echo ALIVE; else echo GONE; fi',
    );
    _check('上一世执行器已经退掉', oldAlive == 'GONE', 'kill -0 $livePid ⇒ "$oldAlive"');
  }

  // ⑧d **卡死**（进程在、但不回帧）：SIGSTOP 之后插件应当靠保活把它换掉，并**收掉**它。
  //     这条要走满 3 拍保活（20s 间隔 + 10s 窗口 ⇒ 约 90s），是本节最慢的一条。
  final Map<String, dynamic> ready2 = await stateOf();
  final int? hungPid = ((_asMap(ready2['agent']))['pid'] as num?)?.toInt();
  if (hungPid != null) {
    await sshRun('kill -STOP $hungPid');
    int? newPid = hungPid;
    final Stopwatch hungWait = Stopwatch()..start();
    while (hungWait.elapsed < const Duration(minutes: 4)) {
      final Map<String, dynamic> st = await stateOf();
      newPid = ((_asMap(st['agent']))['pid'] as num?)?.toInt();
      if (st['state'] == 'ready' && newPid != null && newPid != hungPid) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    _check(
      '卡死的执行器被换掉（新 pid 起来、状态回 ready）',
      newPid != null && newPid != hungPid,
      'hung=$hungPid 现在=$newPid',
    );
    final String hungAlive = await sshRun(
      'if kill -0 $hungPid 2>/dev/null; then echo ALIVE; else echo GONE; fi',
    );
    _check(
      '卡死的旧执行器被收掉（重建前 token 守卫的 kill 生效）',
      hungAlive == 'GONE',
      'kill -0 $hungPid ⇒ "$hungAlive"',
    );
    // 收尾：万一它还在（STOP 着的进程收不到 TERM 之外的信号），显式 KILL 掉别留垃圾。
    await sshRun('kill -9 $hungPid 2>/dev/null || true');
  }

  // ⑦h 关隧道 ⇒ **执行器立刻关**（核心关 ⇒ 插件收手 ⇒ 通道断 ⇒ agent 退）
  //    同样按 pid 判定：先记下当时活着的 agent pid，关掉后再看它们是否还在。
  final String agentPidsAtClose = await sshRun('pgrep -f "$agentPat" | tr \'\\n\' \' \'');
  final List<String> liveAgentPids = agentPidsAtClose
      .split(RegExp(r'\s+'))
      .where((String s) => s.isNotEmpty)
      .toList();
  _check(
    '关隧道前确有执行器在跑（否则这条断言没有意义）',
    liveAgentPids.isNotEmpty,
    'pgrep -f "$agentPat" ⇒ "$agentPidsAtClose"',
  );
  await proc.request(_TunnelMethods.close, <String, dynamic>{'conn_id': conn});
  await Future<void>.delayed(const Duration(seconds: 3));
  final String agentStill = await sshRun(
    'for p in ${liveAgentPids.join(' ')}; do '
    'if kill -0 \$p 2>/dev/null; then echo -n "\$p "; fi; done',
  );
  _check(
    '隧道关掉后执行器立即退出（不留孤儿）',
    agentStill.trim().isEmpty,
    '关隧道后仍活着的 pid：${agentStill.trim()}（原为 ${liveAgentPids.join(' ')}）',
  );
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
