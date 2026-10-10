import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'path_guard.dart';
import 'proc_ledger.dart';
import 'shell_launcher.dart';

/// `exec.run` 单条流**内联回传**的原文字节上限（4 MiB / 流）。
///
/// 为什么要有上限：一条响应就是一帧，而单帧上限是 [kMaxFrameBytes]（16 MiB）。
/// 16 MiB 原文字节 base64 后是 21.3 MiB —— 直接超帧。两条流各留 4 MiB ⇒ base64 后
/// 最多 ≈ 10.7 MiB，离 16 MiB 还有余量。**超出不是丢弃**：置 `truncated:true`，
/// 并把完整输出续写 `<state>/run/<id>.out`（协议 §3.3 的口径）。
const int kExecRunMaxStreamBytes = 4 * 1024 * 1024;

/// `exec.*` 的**真正干活那一端**（协议 §3.3 前台 + §3.4 后台）。
///
/// 前台（[run]）：用可注入的 [ShellLauncher] 起 `/bin/sh -c <command>`，收原始字节；
/// 软超时**不杀进程**（全仓口径：没有"到点自动杀"）。
///
/// 后台（[spawn]/[list]/[query]/[kill]）：`setsid` 起命令 ⇒ 自成会话/进程组
/// （`pgid == pid`），日志直写调用方给的工作空间内 `log_path`，退出码落
/// `<state>/exit/<id>`，台账落 `<state>/procs.json`（原子写）—— 于是 agent 死、
/// SSH 通道断、应用退出都不影响它，重连后 [list] 对账即可给出真相。
class ExecOps {
  ExecOps({
    required this.guard,
    required this.root,
    required this.stateDir,
    required this.launcher,
    required this.ledger,
    AgentIdGen? ids,
    this.log,
  }) : _ids = ids ?? AgentIdGen();

  final PathGuard guard;
  final String root;
  final String stateDir;
  final ShellLauncher launcher;
  final ProcLedger ledger;
  final AgentIdGen _ids;

  /// 诊断日志出口（`bin` 里接 stderr；缺省什么都不做）。
  final void Function(String message)? log;

  // ── exec.run ─────────────────────────────────────────────────────────

  /// `{command, cwd?, timeout_ms?:int=0, stdin_b64?}`
  /// → `{exit_code, stdout:base64, stderr:base64, truncated, timed_out}`。
  ///
  /// - `cwd` 缺省 = **工作空间根**（与本地后端 `workingDirectory: root` 同口径）；
  /// - `stdin_b64` 缺省时**立刻关掉 stdin**（不变量 5：否则等输入的命令永久挂住）；
  /// - `timeout_ms <= 0` = **永不软超时**；`> 0` 到点**不杀进程、不重跑**，
  ///   返回已经拿到的输出 + `timed_out:true`，并把完整输出续写 `<state>/run/<id>.out`。
  Future<Map<String, dynamic>> run(Map<String, dynamic> params) async {
    final String command = _requireString(params, 'command');
    final String cwd = params['cwd'] == null
        ? root
        : guard.check(params['cwd'], label: 'cwd');
    final int timeoutMs = _optionalInt(params['timeout_ms']) ?? 0;
    final Object? stdinRaw = params['stdin_b64'];

    final Process process;
    try {
      process = await launcher.start(command, workingDirectory: cwd);
    } on ProcessException catch (error) {
      throw RpcException(
        TunnelErrorCodes.execFailed,
        '命令起不来（${launcher.description}，cwd=$cwd）：${error.message}',
      );
    }

    // stdin：显式给了就打进去；**无论给没给都关掉**（不变量 5）。
    if (stdinRaw is String && stdinRaw.isNotEmpty) {
      try {
        process.stdin.add(base64Decode(stdinRaw));
      } on FormatException {
        log?.call('exec.run 的 stdin_b64 不是合法 base64，已忽略');
      }
    }
    try {
      await process.stdin.close();
    } on Object catch (error) {
      log?.call('关闭子进程 stdin 失败（忽略）：$error');
    }

    final String runId = _ids.next();
    final _Tee out = _Tee(kExecRunMaxStreamBytes);
    final _Tee err = _Tee(kExecRunMaxStreamBytes);
    _RunFileSink? runFile;

    /// 开始把"完整输出"续写 `<state>/run/<id>.out`（[overflow] 是**触发这一下的那一块
    /// 里超内联上限的部分**，必须跟着补进文件，否则会丢一段）。
    void ensureRunFile(List<int> overflow) {
      if (runFile == null) {
        final String path = _runFilePath(runId);
        try {
          // openWrite 不建目录；本动作可能在流回调里**同步**触发 ⇒ 用 createSync。
          Directory(posixDirname(path)).createSync(recursive: true);
        } on FileSystemException catch (error) {
          log?.call('建 $path 的父目录失败：$error');
        }
        runFile = _RunFileSink(path, File(path).openWrite(), log);
        // 先把"已经拿到的"补进文件，文件才是**完整**输出。
        // 传**拷贝**：这两个 List 之后还会被 addAll 继续增长，不能让 sink 拿着活引用。
        runFile!.add(List<int>.of(out.bytes));
        runFile!.add(List<int>.of(err.bytes));
        out.file = runFile;
        err.file = runFile;
      }
      runFile!.add(overflow);
    }

    out.onTruncate = ensureRunFile;
    err.onTruncate = ensureRunFile;

    final Completer<void> streamsDone = Completer<void>();
    int pending = 2;
    void streamFinished() {
      pending -= 1;
      if (pending <= 0 && !streamsDone.isCompleted) streamsDone.complete();
    }

    // 显式持有订阅引用（不读也不丢：流还没结束时订阅必须活着）。
    final List<StreamSubscription<List<int>>> subscriptions =
        <StreamSubscription<List<int>>>[
          process.stdout.listen(
            out.add,
            onDone: streamFinished,
            onError: (Object error) {
              log?.call('exec.run stdout 读取出错（忽略）：$error');
              streamFinished();
            },
          ),
          process.stderr.listen(
            err.add,
            onDone: streamFinished,
            onError: (Object error) {
              log?.call('exec.run stderr 读取出错（忽略）：$error');
              streamFinished();
            },
          ),
        ];

    final Completer<int> exitDone = Completer<int>();
    unawaited(
      process.exitCode.then((int code) {
        if (!exitDone.isCompleted) exitDone.complete(code);
      }),
    );

    int? exitCode;
    bool timedOut = false;
    if (timeoutMs <= 0) {
      exitCode = await exitDone.future;
      await streamsDone.future;
    } else {
      final _Race race = await Future.any<_Race>(<Future<_Race>>[
        exitDone.future.then<_Race>(_Race.exited),
        Future<void>.delayed(
          Duration(milliseconds: timeoutMs),
        ).then<_Race>((void _) => const _Race.timedOut()),
      ]);
      if (race.timedOut) {
        timedOut = true;
      } else {
        exitCode = race.exitCode;
        await streamsDone.future;
      }
    }

    if (timedOut) {
      // 到点**不杀**：把完整输出继续落盘（已在跑的流订阅照旧，进程照旧）。
      ensureRunFile(const <int>[]);
      unawaited(
        exitDone.future.then((int _) async {
          await streamsDone.future;
          await runFile?.close();
        }),
      );
    } else {
      await runFile?.close();
      for (final StreamSubscription<List<int>> subscription in subscriptions) {
        await subscription.cancel();
      }
    }

    return <String, dynamic>{
      'exit_code': exitCode ?? -1,
      'stdout': base64Encode(out.bytes),
      'stderr': base64Encode(err.bytes),
      'truncated': out.truncated || err.truncated,
      'timed_out': timedOut,
    };
  }

  String _runFilePath(String id) => '$stateDir/run/$id.out';

  // ── exec.spawn ───────────────────────────────────────────────────────

  /// `{command, log_path, cwd?, label?}`
  /// → `{id, pid, pgid, log_path, started_at_ms}`，**立即返回**，不等命令结束。
  Future<Map<String, dynamic>> spawn(Map<String, dynamic> params) async {
    final String command = _requireString(params, 'command');
    final String logPath = guard.check(params['log_path'], label: 'log_path');
    final String cwd = params['cwd'] == null
        ? root
        : guard.check(params['cwd'], label: 'cwd');
    final String id = _ids.next();
    final String runDir = '$stateDir/run';
    final String exitDir = '$stateDir/exit';
    final String scriptPath = '$runDir/$id.sh';
    final String exitFile = '$exitDir/$id';

    await Directory(runDir).create(recursive: true);
    await Directory(exitDir).create(recursive: true);
    await Directory(posixDirname(logPath)).create(recursive: true);

    final String script = buildLauncherScript(
      command: command,
      cwd: cwd,
      logPath: logPath,
      exitFile: exitFile,
    );
    await File(scriptPath).writeAsString(script, flush: true);

    final int pid;
    try {
      // `setsid` 让命令**自成会话/进程组**（pgid == pid）⇒ agent 死、通道断、
      // 应用退出都不影响它；`& echo $!` 放进同一条 sh 里 ⇒ 包装 sh 立刻退出、
      // 我们立刻拿到 pid（协议 §3.4；旧形状 `{ … } & echo $!` 会握到命令结束）。
      final Process wrapper = await Process.start('/bin/sh', <String>[
        '-c',
        'setsid /bin/sh "\$0" </dev/null >/dev/null 2>&1 & echo \$!',
        scriptPath,
      ]);
      final String raw = await _readAll(wrapper.stdout);
      await wrapper.exitCode;
      final int? parsed = int.tryParse(raw.trim());
      if (parsed == null || parsed <= 0) {
        throw RpcException(
          TunnelErrorCodes.execFailed,
          '后台命令起不来（包装 shell 没回 pid，收到 "${raw.trim()}"）',
        );
      }
      pid = parsed;
    } on ProcessException catch (error) {
      throw RpcException(
        TunnelErrorCodes.execFailed,
        '后台命令起不来（/bin/sh、setsid 不可用？）：${error.message}',
      );
    }

    final ProcRecord record = ProcRecord(
      id: id,
      pid: pid,
      pgid: pid,
      command: command,
      logPath: logPath,
      cwd: cwd,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await ledger.add(record);
    log?.call('后台任务 $id 已起：pid=$pid pgid=$pid log=$logPath');
    return <String, dynamic>{
      'id': id,
      'pid': pid,
      'pgid': pid,
      'log_path': logPath,
      'started_at_ms': record.startedAtMs,
    };
  }

  // ── exec.list / exec.query ───────────────────────────────────────────

  /// `{}` → `{procs:[{…记录…, state, exit_code?}]}`（逐条现算状态）。
  Future<Map<String, dynamic>> list(Map<String, dynamic> params) async {
    final List<Map<String, dynamic>> procs = <Map<String, dynamic>>[];
    for (final ProcRecord record in ledger.records) {
      final ProcStatus status = await ledger.reconcile(record);
      procs.add(<String, dynamic>{...record.toJson(), ...status.toJson()});
    }
    return <String, dynamic>{'procs': procs};
  }

  /// `{id}` → `{proc:{…}}`；没有这条 ⇒ `-32002 not_found`。
  Future<Map<String, dynamic>> query(Map<String, dynamic> params) async {
    final String id = _requireString(params, 'id');
    final ProcRecord? record = ledger.byId(id);
    if (record == null) {
      throw RpcException(TunnelErrorCodes.notFound, '没有这条后台任务：$id');
    }
    final ProcStatus status = await ledger.reconcile(record);
    return <String, dynamic>{
      'proc': <String, dynamic>{...record.toJson(), ...status.toJson()},
    };
  }

  // ── exec.kill ────────────────────────────────────────────────────────

  /// `{id, signal?:'TERM'|'KILL'=TERM}` → `{killed:bool}`。
  ///
  /// 发 `kill -s <SIG> -- -<pgid>`（杀**整个进程组**，与 `setsid` 对齐）；
  /// 拿不到 pid/pgid ⇒ `{killed:false}` —— **不假装**（协议 §3.4）。
  Future<Map<String, dynamic>> kill(Map<String, dynamic> params) async {
    final String id = _requireString(params, 'id');
    final ProcRecord? record = ledger.byId(id);
    if (record == null) return <String, dynamic>{'killed': false};
    final String requested = (params['signal'] ?? 'TERM').toString().toUpperCase();
    final String signal = requested == 'KILL' ? 'KILL' : 'TERM';
    if (record.pgid <= 0) return <String, dynamic>{'killed': false};
    try {
      final ProcessResult result = await Process.run('/bin/sh', <String>[
        '-c',
        'kill -s "\$1" -- -"\$2" 2>/dev/null',
        'sh',
        signal,
        '${record.pgid}',
      ]);
      return <String, dynamic>{'killed': result.exitCode == 0};
    } on ProcessException catch (error) {
      log?.call('exec.kill 失败（$id）：$error');
      return <String, dynamic>{'killed': false};
    }
  }
}

/// **launcher 脚本**（协议 §3.4 的"内容大意"）。
///
/// ```
/// cd '<cwd>' || { printf %s 127 > '<exit>'; exit 127; }
/// { <command> ; } >> '<log_path>' 2>&1 < /dev/null
/// printf '%s' $? > '<exit>'
/// ```
///
/// 与协议原文的一处**加固**：原文是 `cd '<cwd>' || exit 127`——那样 `cd` 失败时
/// **不写退出码文件**，对账只能落到 `gone`（丢掉 127 这个真相）。这里在失败分支里
/// 也把 127 写进退出码文件，`exec.list` 于是能如实报 `exited/127`。
///
/// 注入的路径一律 POSIX 单引号转义；`command` **不转义**（它本来就是 shell 命令串，
/// 协议 §3.3 说 agent 收到的是最终字符串）。
String buildLauncherScript({
  required String command,
  required String cwd,
  required String logPath,
  required String exitFile,
}) {
  final StringBuffer script = StringBuffer();
  script.writeln(
    'cd ${posixQuote(cwd)} || { printf %s 127 > ${posixQuote(exitFile)}; exit 127; }',
  );
  script.writeln('{ $command ; } >> ${posixQuote(logPath)} 2>&1 < /dev/null');
  script.writeln("printf '%s' \$? > ${posixQuote(exitFile)}");
  return script.toString();
}

// ── 内部 ────────────────────────────────────────────────────────────────

class _Race {
  const _Race.exited(this.exitCode) : timedOut = false;
  const _Race.timedOut() : exitCode = null, timedOut = true;

  final int? exitCode;
  final bool timedOut;
}

/// 把一条流的字节"内联缓存（带上限）+ 可选地续写文件"。
///
/// [bytes] 是**原始字节**（供 base64 回传）；超过 [cap] 之后置 [truncated]，
/// 并把"这一块里没能进缓冲区的部分"交给 [onTruncate] —— 由 [ExecOps] 挂上
/// "开始落盘"的动作（**必须带上这段溢出**，否则文件不是"完整输出"）。
///
/// 合并流的先后：stdout / stderr 本来是两条独立管道，逐字节交织不可得；
/// 文件里在"开始落盘"的接缝处是近似的（先补历史缓冲、再按到达顺序续写）。
class _Tee {
  _Tee(this.cap);

  final int cap;
  final List<int> _buffer = <int>[];

  bool truncated = false;
  _RunFileSink? file;
  void Function(List<int> overflow)? onTruncate;

  List<int> get bytes => _buffer;

  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    if (file != null) {
      // 已经在落盘：整块追加，再按剩余额度吸收进缓冲区（供响应内联）。
      file!.add(chunk);
      _absorb(chunk);
      return;
    }
    final int room = cap - _buffer.length;
    if (chunk.length <= room) {
      _buffer.addAll(chunk);
      return;
    }
    final int take = room < 0 ? 0 : room;
    _buffer.addAll(chunk.sublist(0, take));
    truncated = true;
    onTruncate?.call(chunk.sublist(take));
  }

  void _absorb(List<int> chunk) {
    final int room = cap - _buffer.length;
    if (room <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length <= room) {
      _buffer.addAll(chunk);
      return;
    }
    _buffer.addAll(chunk.sublist(0, room));
    truncated = true;
  }
}

/// `<state>/run/<id>.out` 的写入端（stdout/stderr **共用一个 sink** ⇒ 不会互踩偏移）。
class _RunFileSink {
  _RunFileSink(this.path, this._sink, this.log);

  final String path;
  final IOSink _sink;
  final void Function(String message)? log;
  bool _closed = false;

  void add(List<int> chunk) {
    if (_closed || chunk.isEmpty) return;
    try {
      _sink.add(chunk);
    } on Object catch (error) {
      log?.call('写入 $path 失败（忽略）：$error');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink.flush();
    } on Object catch (_) {
      // 忽略：文件写不进去不该影响命令本身的收尾
    }
    try {
      await _sink.close();
    } on Object catch (_) {
      // 同上
    }
  }
}

String _requireString(Map<String, dynamic> params, String key) {
  final Object? raw = params[key];
  if (raw is! String || raw.trim().isEmpty) {
    throw RpcException(RpcCodes.invalidParams, '$key 必须是非空字符串');
  }
  return raw;
}

int? _optionalInt(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

Future<String> _readAll(Stream<List<int>> stream) async {
  final List<int> bytes = <int>[];
  await for (final List<int> chunk in stream) {
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes, allowMalformed: true);
}
