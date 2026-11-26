import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../util/app_user_model.dart';
import '../util/win_job.dart';
import 'plugin_host.dart' show PluginConfig, PluginException;

/// UI 插件的进程宿主（片 D）。
///
/// 和 [PluginHost]（无头 / stdio）**刻意不同**：
/// - 不做 stdio 握手、不发 `tools/list`、不注册工具、不进入站点通道；
/// - `stdout` / `stderr` 只收进日志环形缓冲（进程自己的协议走 WS / HTTP，
///   不经过核心的 stdin）；
/// - 启动时注入 `TREE_CORE_URL`（核心 ws 基址）与 `TREE_CORE_TOKEN`（核心 token），
///   其余环境变量口径与 [PluginHost] 一致（`config.env` + `runInShell`）。
///
/// 判活：UI 插件没有 stdio 心跳，判据就是**进程是否退出**；连接窗口内的
/// `ui.hello` 由 `PluginBus` 另记（窗口内没连上只降级，不杀进程）。
class UiHost {
  UiHost._(
    this.config,
    this._process,
    this.coreUrl, {
    this.windowId = '',
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
  }) {
    // 纯 UTF-8、坏字节只顶替不中断（与 PluginHost 的 stdout 口径一致）。
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) {
            _stdout.add(line);
            onStdoutLine?.call(line);
          },
          onError: (Object _) {},
          onDone: () {},
        );
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) {
            _stderr.add(line);
            onStderrLine?.call(line);
          },
          onError: (Object _) {},
          onDone: () {},
        );
    _process.exitCode.then((int code) {
      _exitCode = code;
      if (!_exited.isCompleted) _exited.complete(code);
    });
  }

  /// 拉起 UI 插件进程。
  ///
  /// [coreUrl] 为核心对插件暴露的基址（`ws://127.0.0.1:<port>`）；
  /// [coreToken] 为当前核心 token。二者都会写进子进程环境变量。
  static Future<UiHost> start(
    PluginConfig config, {
    required String coreUrl,
    required String coreToken,
    String windowId = '',
    String dataRoot = '',
    void Function(String line)? onStdoutLine,
    void Function(String line)? onStderrLine,
    void Function(String message)? log,
  }) async {
    if (config.command.trim().isEmpty) {
      throw PluginException('插件 ${config.id} 未配置 command');
    }
    if (coreUrl.trim().isEmpty || coreToken.trim().isEmpty) {
      throw PluginException(
        '插件 ${config.id} 是 UI 插件，但核心端点（TREE_CORE_URL / '
        'TREE_CORE_TOKEN）尚未接线',
      );
    }
    final Process process;
    try {
      process = await Process.start(
        config.command,
        config.args,
        environment: <String, String>{
          // 与 [PluginHost] 同口径：先把按登录口径重建的环境交给界面进程
          // （界面里起的子进程 / 打开的终端才不会丢用户 PATH），再叠配置与核心端点。
          ...await cachedLoginEnvironment(log: log),
          ...config.env,
          // 统一应用标识：界面进程按它设置 AUMID，多窗口才会归到同一个
          // 任务栏按钮（AUMID 是进程内 API，核心只能把 id 交下去）。
          kAppUserModelIdEnv: kAppUserModelId,
          'TREE_CORE_URL': coreUrl,
          'TREE_CORE_TOKEN': coreToken,
          // 数据根：UI 的用量账本 / 核心日志入口靠它拼路径（`<数据根>/data/...`）。
          // 空串 = 未接线（老口径），此时 UI 显示"拿不到核心数据根"，**不猜路径**。
          // 空也必须写：见 plugin_host.dart 同一处注释——不写这个键的话，插件会
          // 从核心进程继承到父进程的 `TREE_DATA_ROOT`（`Process.start` 默认继承父
          // 环境），界面就会认一个核心根本没接线的数据根。
          'TREE_DATA_ROOT': dataRoot.trim(),
          // 窗口身份：同一 UI 插件可以拉起多个窗口，进程靠它区分自己
          // （窗口级状态键 / ui.hello.window_id）。空串 = 单窗口口径，不注入。
          if (windowId.isNotEmpty) 'TREE_UI_WINDOW_ID': windowId,
        },
        runInShell: Platform.isWindows && _needsShell(config.command),
      );
    } catch (error) {
      throw PluginException('启动 UI 插件 ${config.id} 失败：$error');
    }
    // 无豁免：界面进程同样进作业。核心异常退出时界面一起收走，不留一个连不上
    // 核心、token 已失效的孤儿窗口（启动器检测到界面消失会重开引导页）。
    assignPluginProcessToJob(process.pid, log: log);
    return UiHost._(
      config,
      process,
      coreUrl,
      windowId: windowId,
      onStdoutLine: onStdoutLine,
      onStderrLine: onStderrLine,
    );
  }

  final PluginConfig config;
  final Process _process;
  final String coreUrl;

  /// 窗口 id（`w1` / `w2`…）；空串 = 老口径（未分配窗口身份）。
  final String windowId;

  final _BoundedLog _stdout = _BoundedLog();
  final _BoundedLog _stderr = _BoundedLog();

  int? _exitCode;
  bool _stopRequested = false;
  String _killReason = '';

  final Completer<int> _exited = Completer<int>();

  int get pid => _process.pid;

  /// 进程退出码；null = 仍在运行。
  int? get exitCode => _exitCode;

  /// 进程是否已经退出。
  bool get isClosed => _exitCode != null;

  /// 是否由核心发起停止（stop / kill）。用于区分「正常停止」与「崩溃」。
  bool get stopRequested => _stopRequested;

  String get killReason => _killReason;

  /// 退出完成信号（等待进程真正收尸时用）。
  Future<int> get exited => _exited.future;

  /// 最近的标准输出（环形缓冲；日志展示用）。
  String get stdoutTail => _stdout.tail();

  /// 最近的标准错误（截断口径与 [PluginHost.stderrTail] 一致：尾部 2000 字符）。
  String get stderrTail => _stderr.tail();

  /// 只等**进程退出事件**，超时返回 false（**不 kill**）。
  ///
  /// 这是热重启的「等旧世真的没了」那一步：托盘归属、单实例锁、sidecar、
  /// `TREE_UI_WINDOW_ID` 都必须等这一事件，不能靠「杀完就拉起」赌运气。
  /// [grace] 是**退出宽限**，不是判活时钟（UI 没有心跳）；到点由调用方决定 kill。
  Future<bool> awaitExit(Duration grace) async {
    if (_exitCode != null) return true;
    try {
      await _exited.future.timeout(grace);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// 请求正常停止。
  ///
  /// UI 插件没有 stdio shutdown，只能发终止信号；Windows 上 [Process.kill] 即
  /// 结束进程，POSIX 上先发 SIGTERM 给插件一个收尾机会。
  Future<void> stop() async {
    if (_exitCode != null) return;
    _stopRequested = true;
    if (!Platform.isWindows) {
      try {
        _process.kill(ProcessSignal.sigterm);
        return;
      } catch (_) {
        // 退回到强杀
      }
    }
    _process.kill();
  }

  /// 强制结束（崩溃兜底 / 卸载确认）。
  Future<void> kill([String reason = '强制结束']) async {
    if (_exitCode != null) return;
    _stopRequested = true;
    _killReason = reason;
    _process.kill(ProcessSignal.sigkill);
  }

  /// 停止并（可选）等待进程退出。
  ///
  /// [gracefulFirst] 只给热重启：先**等它自己退**（宽限 [grace]），到点才 kill。
  /// 其余调用方行为逐字不变（默认 `stop()` → 等 3s → kill）。
  ///
  /// 为什么多这一档：`stop()` 在 Windows 上是 `Process.kill()`，界面拿不到任何
  /// 收尾机会——草稿、sidecar、单实例锁、托盘归属全都没有落地时刻。热重启必须
  /// 先让旧世自己把状态交出来再退（计划 §4.4）。
  Future<void> close({
    bool waitForExit = true,
    bool gracefulFirst = false,
    Duration? grace,
  }) async {
    if (gracefulFirst && _exitCode == null) {
      final Duration window = grace ?? const Duration(seconds: 5);
      if (await awaitExit(window)) return;
      await kill('挂起后 ${window.inSeconds}s 内未退出（已交出切片则会话仍续上）');
      return;
    }
    await stop();
    if (!waitForExit || _exitCode != null) return;
    try {
      await _exited.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      await kill('停止后 3s 内未退出');
    }
  }

  static bool _needsShell(String command) {
    final String lower = command.toLowerCase();
    return lower.endsWith('.cmd') ||
        lower.endsWith('.bat') ||
        lower == 'npx' ||
        lower == 'npm' ||
        lower == 'pnpm' ||
        lower == 'yarn';
  }
}

/// 有界日志环形缓冲（只留最近若干行，避免 UI 插件刷屏吃内存）。
class _BoundedLog {
  static const int _maxLines = 200;

  final List<String> _lines = <String>[];

  void add(String line) {
    _lines.add(line);
    if (_lines.length > _maxLines) _lines.removeAt(0);
  }

  String tail() {
    final String text = _lines.join('\n');
    return text.length <= 2000 ? text : text.substring(text.length - 2000);
  }
}
