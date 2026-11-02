import 'dart:async';
import 'dart:io';

/// 测试用 **UI 插件进程**（片 D）：只做三件事——回显核心注入的环境变量、
/// 打一行 stderr、按参数保持存活 / 崩溃 / 正常退出。
///
/// 它**不读 stdin、不说 JSON-RPC**：UI 插件本来就不走 stdio 协议。
///
/// 参数：
/// - `hold`（默认）：一直活着，等测试用 stop / kill 结束；
/// - `crash`：立刻以 3 退出（模拟崩溃）；
/// - `exit0`：立刻以 0 退出（模拟插件自己正常退出）。
void main(List<String> args) {
  stdout.writeln('TREE_CORE_URL=${Platform.environment['TREE_CORE_URL'] ?? ''}');
  stdout.writeln(
    'TREE_CORE_TOKEN=${Platform.environment['TREE_CORE_TOKEN'] ?? ''}',
  );
  stdout.writeln(
    'TREE_UI_WINDOW_ID=${Platform.environment['TREE_UI_WINDOW_ID'] ?? ''}',
  );
  stdout.writeln(
    'TREE_DATA_ROOT=${Platform.environment['TREE_DATA_ROOT'] ?? ''}',
  );
  stdout.writeln('PROBE_ENV=${Platform.environment['PROBE_ENV'] ?? ''}');
  stderr.writeln('PROBE_STDERR_MARKER');

  final String mode = args.isEmpty ? 'hold' : args.first;
  if (mode == 'crash') exit(3);
  if (mode == 'exit0') exit(0);

  // 保持事件循环活着（不读 stdin：UI 插件不参与 stdio 协议）。
  stdin.listen((_) {});
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
