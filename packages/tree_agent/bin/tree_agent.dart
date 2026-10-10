import 'dart:io';

import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// `tree_agent` 的入口。
///
/// ```
/// tree_agent --root <abs> --token <t> [--state-dir <abs>] [--idle-timeout-ms 0] [--version]
/// ```
///
/// 两条**硬纪律**：
/// 1. **日志一律 stderr**（带 `[tree_agent]` 前缀）—— 出问题时插件/人能看见，不污染协议；
/// 2. **stdout 只写协议帧**（一行一帧，[encodeFrame] 产物），别的什么都不写 ——
///    任何一行杂音都会让插件那侧的 [LineFrameDecoder] 报"非法 JSON 帧"。
///
/// 唯一例外是 `--version`：那是**独立模式**（打印一行版本后立刻退出，不会进入服务循环、
/// 也不会产生任何协议帧），所以它写 stdout —— 与命令行惯例一致。
Future<void> main(List<String> args) async {
  if (args.contains('--version') || args.contains('-v')) {
    stdout.writeln('tree_agent $kAgentVersion (protocol $kAgentProtocolVersion)');
    await stdout.flush();
    return;
  }

  final AgentConfig config;
  try {
    config = AgentConfig.parse(args);
  } on AgentConfigException catch (error) {
    _log(error.message);
    exitCode = 2;
    return;
  }

  final AgentServer server = AgentServer(config: config, log: _log);
  try {
    exitCode = await server.serve(
      input: stdin,
      emit: (List<int> bytes) async {
        stdout.add(bytes);
        await stdout.flush();
      },
    );
    await stdout.flush();
  } on Object catch (error, stack) {
    _log('致命错误：$error\n$stack');
    exitCode = 1;
  }
}

/// 所有日志走 **stderr**（绝不碰 stdout）。
void _log(String message) {
  stderr.writeln('[tree_agent] $message');
}
