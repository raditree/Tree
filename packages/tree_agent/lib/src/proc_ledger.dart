import 'dart:convert';
import 'dart:io';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 一条被 agent 托管的后台命令（协议 §3.4）。
///
/// 字段与 `<state>/procs.json` 一一对应；**agent 自己重启后要能读回它**——
/// 这是"跨日级稳定性"的落点之一：`exec.list` 永远给得出真相，不依赖任何内存态。
class ProcRecord {
  const ProcRecord({
    required this.id,
    required this.pid,
    required this.pgid,
    required this.command,
    required this.logPath,
    required this.cwd,
    required this.startedAtMs,
  });

  final String id;
  final int pid;

  /// 进程组 id（`setsid` ⇒ `pgid == pid`）。
  final int pgid;

  final String command;

  /// 日志落点（**工作空间内的绝对路径**由调用方给；受越界检查）。
  final String logPath;

  /// 命令的工作目录（绝对路径）。
  final String cwd;

  final int startedAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'pid': pid,
    'pgid': pgid,
    'command': command,
    'log_path': logPath,
    'cwd': cwd,
    'started_at_ms': startedAtMs,
  };

  /// 宽容解析（台账是**我们自己写的**，但坏一行不该让整个台账读不回来）。
  static ProcRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> map = raw.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    final String id = (map['id'] ?? '').toString();
    final int? pid = (map['pid'] as num?)?.toInt();
    if (id.isEmpty || pid == null) return null;
    return ProcRecord(
      id: id,
      pid: pid,
      pgid: (map['pgid'] as num?)?.toInt() ?? pid,
      command: (map['command'] ?? '').toString(),
      logPath: (map['log_path'] ?? '').toString(),
      cwd: (map['cwd'] ?? '').toString(),
      startedAtMs: (map['started_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 对账结果：`state ∈ {running, exited, gone}` + 可选的 `exit_code`。
class ProcStatus {
  const ProcStatus(this.state, [this.exitCode]);

  /// [BackgroundStates] 的取值。
  final String state;

  /// 只在 `exited` 时有值（**`gone` 不填、不猜** —— 协议 §3.4）。
  final int? exitCode;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'state': state,
    if (exitCode != null) 'exit_code': exitCode,
  };
}

/// "这个 pid 还活着吗"的探针（可注入 ⇒ 非 POSIX 也能单测对账逻辑）。
typedef PidAliveProbe = Future<bool> Function(int pid);

/// 缺省探针：POSIX 用 `kill -0`（dart:io 没有 signal 0，只能借 shell）。
///
/// 生产目标是 Linux；Windows 只是开发机（单测应注入探针），这里用 `tasklist` 尽力而为。
Future<bool> defaultPidAlive(int pid) async {
  if (pid <= 0) return false;
  if (Platform.isWindows) {
    try {
      final ProcessResult result = await Process.run('tasklist', <String>[
        '/FI',
        'PID eq $pid',
        '/NH',
      ]);
      return result.stdout.toString().contains('$pid');
    } on ProcessException {
      return false;
    }
  }
  try {
    final ProcessResult result = await Process.run('/bin/sh', <String>[
      '-c',
      'kill -0 "\$1" 2>/dev/null',
      'sh',
      '$pid',
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// **后台任务台账**：`<state>/procs.json`（**原子写**：先 `.tmp` 再 rename）。
///
/// 记录每个 id 的 `{id, pid, pgid, command, log_path, cwd, started_at_ms}`；
/// `exec.list` / `exec.query` 对每条记录**现算**状态（见 [reconcile]）。
class ProcLedger {
  ProcLedger({required this.stateDir, PidAliveProbe? aliveProbe})
    : _aliveProbe = aliveProbe ?? defaultPidAlive;

  final String stateDir;
  final PidAliveProbe _aliveProbe;

  final Map<String, ProcRecord> _byId = <String, ProcRecord>{};

  String get procsFilePath => '$stateDir/procs.json';

  String exitFilePath(String id) => '$stateDir/exit/$id';

  List<ProcRecord> get records => List<ProcRecord>.unmodifiable(_byId.values);

  ProcRecord? byId(String id) => _byId[id];

  /// 从磁盘读回台账（**agent 重启后的接续**）。文件缺失/坏掉 ⇒ 空台账（不抛）。
  Future<void> load() async {
    _byId.clear();
    final File file = File(procsFilePath);
    if (!await file.exists()) return;
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (_) {
      return;
    }
    final Object? list = decoded is Map ? decoded['procs'] : decoded;
    if (list is! List) return;
    for (final Object? raw in list) {
      final ProcRecord? record = ProcRecord.fromJson(raw);
      if (record != null) _byId[record.id] = record;
    }
  }

  /// 原子写台账：先写 `<state>/procs.json.tmp`，再 `rename` 覆盖（同一目录 ⇒ POSIX 原子）。
  Future<void> save() async {
    await Directory(stateDir).create(recursive: true);
    final Map<String, dynamic> payload = <String, dynamic>{
      'procs': <Map<String, dynamic>>[
        for (final ProcRecord record in _byId.values) record.toJson(),
      ],
    };
    final File tmp = File('$procsFilePath.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(procsFilePath);
  }

  /// 记一条（id 已存在则覆盖）并落盘。
  Future<void> add(ProcRecord record) async {
    _byId[record.id] = record;
    await save();
  }

  /// 移除一条并落盘（用于清理已经 `gone` 的记录；不影响磁盘上的退出码文件）。
  Future<bool> remove(String id) async {
    final ProcRecord? removed = _byId.remove(id);
    if (removed == null) return false;
    await save();
    return true;
  }

  /// 读退出码文件 `<state>/exit/<id>`；不存在 / 读不回来 ⇒ null。
  Future<int?> readExitCode(String id) async {
    final File file = File(exitFilePath(id));
    if (!await file.exists()) return null;
    try {
      return int.tryParse((await file.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  /// 对一条记录**对账**（协议 §3.4）：
  /// - 退出码文件在 ⇒ `exited` + `exit_code`；
  /// - 否则 `kill -0 <pid>` 活着 ⇒ `running`；
  /// - 否则 ⇒ `gone`（**`exit_code` 不填/不猜**）。
  Future<ProcStatus> reconcile(ProcRecord record) async {
    final int? exitCode = await readExitCode(record.id);
    if (exitCode != null) {
      return ProcStatus(BackgroundStates.exited, exitCode);
    }
    if (await _aliveProbe(record.pid)) {
      return ProcStatus(BackgroundStates.running);
    }
    return const ProcStatus(BackgroundStates.gone);
  }
}

/// 台账 / 运行产物（`run/<id>.{sh,out}`）用的 id 发生器。
///
/// 形状 `'<毫秒时间戳>-<自增序号>'`：单进程内唯一；跨重启因时间戳变化也不撞。
class AgentIdGen {
  AgentIdGen({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int _seq = 0;

  String next() {
    _seq += 1;
    return '${_clock().millisecondsSinceEpoch}-$_seq';
  }
}
