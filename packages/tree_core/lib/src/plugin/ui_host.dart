import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  UiHost._(this.config, this._process, this.coreUrl) {
    // 纯 UTF-8、坏字节只顶替不中断（与 PluginHost 的 stdout 口径一致）。
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) => _stdout.add(line),
          onError: (Object _) {},
          onDone: () {},
        );
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) => _stderr.add(line),
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
          ...config.env,
          'TREE_CORE_URL': coreUrl,
          'TREE_CORE_TOKEN': coreToken,
        },
        runInShell: Platform.isWindows && _needsShell(config.command),
      );
    } catch (error) {
      throw PluginException('启动 UI 插件 ${config.id} 失败：$error');
    }
    return UiHost._(config, process, coreUrl);
  }

  final PluginConfig config;
  final Process _process;
  final String coreUrl;

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
  Future<void> close({bool waitForExit = true}) async {
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
