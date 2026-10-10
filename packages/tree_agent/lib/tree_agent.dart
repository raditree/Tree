/// 跑在目标机（Linux）上的执行体 `tree_agent`。
///
/// 它经 **stdio 行分隔 JSON-RPC 2.0** 被「中转站插件」调用，真正执行文件读写与命令
/// （协议全文见 `docs/ssh-tunnel-protocol.md`，常量与方法名的唯一真源是
/// `packages/tree_tunnel_protocol`）。
///
/// 三层落点：
/// - [AgentConfig]：命令行 → 配置（root / token / state-dir / idle-timeout）；
/// - [AgentServer]：帧的收、分发、发（含 `agent.hello` 握手与通知通道）；
/// - [FsOps] / [ExecOps] / [ShellOps]：真正干活的那三块（`fs.*` / `exec.*` / `shell.*`）。
///
/// 越界防护在 [PathGuard]（双保险的另一半，协议 §4）。
library;

export 'src/agent_config.dart';
export 'src/agent_server.dart';
export 'src/exec_ops.dart';
export 'src/fs_ops.dart';
export 'src/path_guard.dart';
export 'src/proc_ledger.dart';
export 'src/shell_launcher.dart';
export 'src/shell_ops.dart';
