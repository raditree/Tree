/// SSH 执行器「中转站」协议的共享定义。
///
/// 唯一真源：方法名 / 错误码 / 帧编解码 / 版本常量都在这里，三端（目标机 `tree_agent`、
/// 中转站 `tree_ssh_plugin`、核心传输层 `TunnelSshTransport`）共用，**不允许各处手写字符串**
/// （手写必然漂移，而这类漂移只在真机上才暴露，代价极高）。
///
/// 系统性说明见 `docs/ssh-tunnel-protocol.md`。
library;

export 'src/constants.dart';
export 'src/frame.dart';
export 'src/rpc.dart';
