import 'dart:io';

import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';

/// 插件入口：**stdio 上的 JSON-RPC 2.0** 服务端（in-process 无参数）。
///
/// 三条铁律的落点：
/// - **stdout 只有协议帧**（[frameBytes] 出来的行分隔 JSON）；
/// - **日志走 stderr**（核心收进插件日志缓冲，绝不污染协议面）；
/// - **不在 main 里做业务**：全部交给 [PluginLoop]（它保证 `ping` 不被慢活堵住）。
///
/// 无参数、不依赖 cwd：核心按 `plugins.yaml` 里的 command/args 直接拉起即可
/// （binary 型内置插件由核心 spawn，见协议 §0）。
Future<void> main(List<String> args) async {
  final PluginLoop loop = PluginLoop(
    dialer: const DartSshDialer().call,
    send: _writeFrame,
    log: (String message) => stderr.writeln('[tree_ssh_executor] $message'),
  );
  final int code = await loop.run(stdin);
  try {
    // 退出前把管道里剩下的字节冲出去（stdout 已被 `exit` 之外的路径收手时这里可能抛，忽略即可）。
    await stdout.flush();
  } catch (_) {
    // 通道已经断了：刷不出去不算错误（核心已不听了）。
  }
  exit(code);
}

/// 写一帧到 stdout。
///
/// **刻意不在每帧后 `flush()`**：`stdout.flush()` 会把底层 sink 标成 "bound"，
/// 之后同一批到达的多帧（读循环一次 `add` 里解出好几条请求）再 `add` 时就会抛
/// `Bad state: StreamSink is bound to a stream` —— 实测在**编译成 exe、stdin 是管道、
/// 三条帧一次到齐**时必现（见 `test/executor_process_test.dart` 的"一次塞多帧"用例）。
/// Dart 的 stdout 本身不做行缓冲，`add` 即写，所以每帧 flush 并非必要。
void _writeFrame(Map<String, dynamic> frame) {
  try {
    stdout.add(frameBytes(frame));
  } catch (error) {
    // stdout 断了（核心已死 / 管道被关）：**不把异常抛回读循环**，只留痕。
    stderr.writeln('[tree_ssh_executor] 写 stdout 失败：$error');
  }
}
