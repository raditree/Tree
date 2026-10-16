import 'dart:io';

import 'package:tree_self_updater/tree_self_updater.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart'
    show encodeFrame;

/// 插件入口：**stdio 上的 JSON-RPC 2.0** 服务端（二进制型内置插件，无参数）。
///
/// 三条铁律的落点（与 `tree_ssh_plugin` 的入口同构）：
/// - **stdout 只有协议帧**（[encodeFrame] 出来的行分隔 JSON）；
/// - **日志走 stderr**（核心收进插件日志缓冲，绝不污染协议面）；
/// - **不在 main 里做业务**：全部交给 [SelfUpdaterLoop]（它保证 `ping` 不被慢活堵住）。
///
/// `--selftest` 是随包自检：拿一条**脚本化的假核心**在进程内走一遍握手 / 申报 /
/// 执行 / 转储取回，打印逐条结论（装机后端到端验证读它的退出码，不看"有没有报错"）。
Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    // 自检的输出走 stderr："stdout 只有协议帧" 这条规则**不因模式而变**
    // （写进 stdout 迟早会和真协议面混在一起，而那正是最难查的一类脏输出）。
    exitCode = await runSelfTest(emit: (String line) => stderr.writeln(line));
    return;
  }
  final SelfUpdaterLoop loop = SelfUpdaterLoop(
    send: _writeFrame,
    log: (String message) => stderr.writeln('[tree_self_updater] $message'),
  );
  final int code = await loop.run(stdin);
  try {
    // 退出前把管道里剩下的字节冲出去（stdout 已被对端关掉时这里会抛，忽略即可）。
    await stdout.flush();
  } catch (_) {
    // 通道已经断了：刷不出去不算错误（核心已不听了）。
  }
  exit(code);
}

/// 写一帧到 stdout。
///
/// **刻意不在每帧后 `flush()`**：`stdout.flush()` 会把底层 sink 标成 "bound"，
/// 同一批到达的多帧再 `add` 时就会抛 `Bad state: StreamSink is bound to a stream`
/// （`tree_ssh_plugin` 实测过：编译成 exe、stdin 是管道、多帧一次到齐时必现）。
void _writeFrame(Map<String, dynamic> frame) {
  try {
    stdout.add(encodeFrame(frame));
  } catch (error) {
    // stdout 断了（核心已死 / 管道被关）：**不把异常抛回读循环**，只留痕。
    stderr.writeln('[tree_self_updater] 写 stdout 失败：$error');
  }
}
