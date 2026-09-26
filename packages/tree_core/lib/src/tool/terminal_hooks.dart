import 'dart:async';
import 'dart:io';

import 'package:tree_local_exec/tree_local_exec.dart';

/// 一个后台（hook 模式）任务。
class HookTask {
  HookTask({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.command,
    required this.logRelative,
    required this.logAbsolute,
    required this.process,
    required this.startedAt,
    this.detached = false,
    this.note = '',
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String command;

  /// 日志路径（工作空间相对 / 绝对）。
  final String logRelative;
  final String logAbsolute;

  /// 本机进程句柄；null = 这个任务不是在**本机**起的（见 [detached]）。
  final Process? process;
  final DateTime startedAt;

  /// 是否是「会话失联后转来的」后台任务（[TerminalHooks.adoptDetached]）。
  ///
  /// 这类任务：不新起进程、也没有输出重定向，远端命令可能仍在跑；本机既不能等它、
  /// 也不能杀它，只记下「何时、为什么转的后台」供模型查询/续看。
  final bool detached;

  /// 转后台的原因（detached 时给模型看的说明）。
  final String note;

  /// 退出码（null = 仍在运行）。
  int? exitCode;

  /// 是否被用户/agent 主动取消。
  bool cancelled = false;

  bool get running => exitCode == null;

  /// 运行时长（已结束则取结束时刻）。
  Duration get elapsed => DateTime.now().difference(startedAt);
}

/// 后台长任务管理器（terminal 的 hook 模式）。
///
/// 设计要点：
/// - **输出直接由 shell 重定向进日志文件**（`>> log 2>&1`），核心进程只保留一个
///   进程句柄——这样即便核心进程重启，日志也不会丢；也少一层管道缓冲。
/// - 任务结束（含被取消）后写一行结束标记到日志，并回调 [onFinished]，
///   由上层把「[terminal hook] 完成」提示注入会话并唤醒 agent。
/// - 关停时杀掉全部在途任务（进程不可随应用退出存活）。
class TerminalHooks {
  TerminalHooks({this.log, this.maxTailChars = 4000});

  /// 可读日志。
  final void Function(String message)? log;

  /// status 动作回传的日志尾部字符数。
  final int maxTailChars;

  /// 任务结束回调（用于唤醒 agent）。
  void Function(HookTask task, int exitCode)? onFinished;

  final Map<String, HookTask> _tasks = <String, HookTask>{};
  int _seq = 0;

  /// 当前在途任务数。
  int get runningCount => _tasks.values.where((HookTask t) => t.running).length;

  /// 全部任务（自检用）。
  List<HookTask> get tasks => List<HookTask>.unmodifiable(_tasks.values);

  /// 按 id 取任务。
  HookTask? task(String id) => _tasks[id];

  /// 启动后台任务并立即返回。
  Future<HookTask> start({
    required WorkspaceIO io,
    required String agentId,
    required String sessionId,
    required String command,
    String? outputFile,
  }) async {
    _seq++;
    final String id = 'hook_${DateTime.now().millisecondsSinceEpoch}_$_seq';
    final String relative = (outputFile == null || outputFile.trim().isEmpty)
        ? '.output/$id.log'
        : outputFile.trim();
    // resolve 会拒绝越界路径：hook 的日志同样只能落在工作空间内
    final String absolute = io.resolve(relative);
    final File file = File(absolute);
    await file.parent.create(recursive: true);
    final DateTime startedAt = DateTime.now();
    await file.writeAsString(
      '# [terminal hook] $command\n'
      '# started ${startedAt.toIso8601String()}  (cwd=${io.root})\n\n',
      flush: true,
    );

    // **用脚本文件而不是把命令塞进 Process.start 的参数**：
    // Windows 下 Dart 按 C 运行时规则转义参数里的引号（\"），而 cmd.exe 的引号
    // 规则不同，带引号的命令（例如重定向路径）会被解析坏——实测表现为命令立刻
    // 以退出码 1 失败。写成 `.cmd`/`.sh` 由 shell 自己解析，彻底绕开这层转义，
    // 顺带把"到底跑了什么"留在磁盘上可复查。
    final bool windows = Platform.isWindows;
    final String scriptPath =
        '${absolute.substring(0, absolute.length - 4)}${windows ? '.cmd' : '.sh'}';
    final String script = windows
        ? '@echo off\r\nchcp 65001 >nul\r\n'
              '$command${Shell.redirectTo(absolute)}\r\n'
              'exit /b %ERRORLEVEL%\r\n'
        : '#!/bin/sh\n'
              '$command${Shell.redirectTo(absolute)}\n'
              'exit \$?\n';
    await File(scriptPath).writeAsString(script, flush: true);

    // Windows 上并发创建进程偶发失败（"拒绝访问"），重试一次即可稳定；
    // 这是进程创建的瞬时失败，不是命令本身的问题，因此不当作工具错误上报。
    Process process;
    try {
      process = await _spawn(io.root, scriptPath, windows);
    } on ProcessException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      process = await _spawn(io.root, scriptPath, windows);
    }
    // 输出已由 shell 重定向进文件，这里的管道只用于防止子进程写阻塞
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final HookTask task = HookTask(
      id: id,
      agentId: agentId,
      sessionId: sessionId,
      command: command,
      logRelative: relative,
      logAbsolute: absolute,
      process: process,
      startedAt: startedAt,
    );
    _tasks[id] = task;
    unawaited(process.exitCode.then((int code) => _finish(task, code)));
    log?.call('后台任务已启动 $id（$command）→ $relative');
    return task;
  }

  static Future<Process> _spawn(
    String workingDirectory,
    String scriptPath,
    bool windows,
  ) => Process.start(
    windows ? 'cmd.exe' : '/bin/sh',
    <String>[windows ? '/c' : scriptPath, if (windows) scriptPath],
    workingDirectory: workingDirectory,
    runInShell: false,
  );

  /// 把一个**已经不在本机等待**的命令登记为后台任务（terminal 软超时 → hook 模式）。
  ///
  /// 与 [start] 的区别：不新起进程、也不重跑命令——远端那条可能还在跑，重跑会重复
  /// 副作用。日志文件里只记录转后台的时间、命令与原因：输出抓不回来了（执行器判
  /// 失活时只是「不再等它」，那条通道上的输出没有落到本机），所以如实写明，不假装
  /// 有日志可看。
  Future<HookTask> adoptDetached({
    required WorkspaceIO io,
    required String agentId,
    required String sessionId,
    required String command,
    required String reason,
    String? outputFile,
  }) async {
    _seq++;
    final String id = 'hook_${DateTime.now().millisecondsSinceEpoch}_$_seq';
    final String relative = (outputFile == null || outputFile.trim().isEmpty)
        ? '.output/$id.log'
        : outputFile.trim();
    // resolve 会拒绝越界路径：转后台的日志同样只能落在工作空间内
    final String absolute = io.resolve(relative);
    final DateTime startedAt = DateTime.now();
    final File file = File(absolute);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '# [terminal hook] 会话失联后转后台（未终止远端进程、未重跑命令）'
      '\n# command: $command'
      '\n# reason: $reason'
      '\n# at ${startedAt.toIso8601String()}'
      '\n\n远端命令可能仍在执行；本机已不再等待它，因此拿不到它的退出码与输出。'
      '\n链路恢复后请用 terminal 重新确认远端进程与产物，不要直接重跑。'
      '\n',
      flush: true,
    );
    final HookTask task = HookTask(
      id: id,
      agentId: agentId,
      sessionId: sessionId,
      command: command,
      logRelative: relative,
      logAbsolute: absolute,
      process: null,
      detached: true,
      note: reason,
      startedAt: startedAt,
    );
    _tasks[id] = task;
    log?.call('会话失联：命令转后台 $id（$command）→ $relative');
    return task;
  }

  /// 取消任务（杀整棵进程树）。返回是否真的发出了终止。
  ///
  /// detached 任务没有本机进程句柄（会话失联时转的），这里**只能返回 false**：
  /// 远端进程不归本机管，别假装杀成功了。
  Future<bool> cancel(String id) async {
    final HookTask? task = _tasks[id];
    if (task == null) return false;
    if (!task.running) return false;
    final Process? process = task.process;
    if (process == null) return false;
    task.cancelled = true;
    await Shell.killProcessTree(process.pid);
    return true;
  }

  /// 关停：杀掉全部在途任务。
  Future<void> close() async {
    for (final HookTask task in _tasks.values.toList()) {
      final Process? process = task.process;
      if (task.running && process != null) {
        task.cancelled = true;
        await Shell.killProcessTree(process.pid);
      }
    }
    _tasks.clear();
  }

  /// status 动作的回传文本：状态 + 退出码 + 耗时 + 日志尾部。
  String renderStatus(HookTask task) {
    final StringBuffer buffer = StringBuffer()..writeln('task_id: ${task.id}');
    if (task.detached) {
      // 会话失联转来的任务：远端状态本机看不到，如实说清楚，不要假装知道退出码
      buffer
        ..writeln('状态：已转后台（会话失联；远端命令可能仍在运行，本机无法确认也无法终止）')
        ..writeln('原因：${task.note}');
    } else {
      buffer.writeln(
        '状态：${task.running ? '运行中' : '已结束'}'
        '${task.running ? '' : '（退出码 ${task.exitCode}${task.cancelled ? '，已被取消' : ''}）'}'
        '｜耗时 ${task.elapsed.inSeconds}s',
      );
    }
    buffer.writeln('日志：${task.logRelative}');
    final String? tail = _tail(task.logAbsolute);
    if (tail != null && tail.trim().isNotEmpty) {
      buffer
        ..writeln('--- 日志尾部 ---')
        ..write(tail.trimRight());
    }
    return buffer.toString().trimRight();
  }

  Future<void> _finish(HookTask task, int code) async {
    task.exitCode = code;
    try {
      final File file = File(task.logAbsolute);
      await file.writeAsString(
        '\n# [terminal hook] 结束：退出码 $code'
        '${task.cancelled ? '（已取消）' : ''}，耗时 ${task.elapsed.inSeconds}s\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      log?.call('写 hook 结束标记失败：$error');
    }
    log?.call(
      '后台任务结束 ${task.id}：exit=$code elapsed=${task.elapsed.inSeconds}s',
    );
    // 回调放在日志尾部写完之后：消费方（唤醒 agent）读日志尾部时能看到结束标记。
    // 注意 task.running 在写入前就已为 false，因此**要等回调、不要只轮询 running**。
    onFinished?.call(task, code);
  }

  String? _tail(String path) {
    final String? text = readTailSync(path, maxTailChars);
    return text;
  }

  /// 读文件尾部（同步；hook status 是交互路径，文件小）。
  static String? readTailSync(String path, int maxChars) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    final String text = file.readAsStringSync();
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  }
}

/// 组装「后台任务完成」提示（注入会话并唤醒 agent）。
String hookNotice(HookTask task, int exitCode) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('[terminal hook] 后台命令已结束：${task.command}')
    ..writeln(
      'task_id: ${task.id}｜退出码 $exitCode'
      '${task.cancelled ? '（已取消）' : ''}',
    )
    ..writeln('日志文件：${task.logRelative}（用 read 查看完整输出）');
  final String? tail = TerminalHooks.readTailSync(task.logAbsolute, 1500);
  if (tail != null && tail.trim().isNotEmpty) {
    buffer
      ..writeln('--- 日志尾部 ---')
      ..write(tail.trimRight());
  }
  return buffer.toString().trimRight();
}
