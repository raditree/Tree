/// SSH 执行器「中转站」插件（`ssh_executor`）的对外 API。
///
/// 三层一句话：
/// - **L1（核心 ⇄ 本插件）**：stdio 行分隔 JSON-RPC 2.0，核心是客户端，[PluginLoop] 是服务端；
///   `hello` 回 `capabilities: ['ssh-executor']`（核心"有没有中转站"的唯一判据）。
/// - **bootstrap**：一次 SSH（dartssh2）探架构 → 推 `tree_agent` → `chmod +x` → 以一条
///   **常驻 exec 通道**拉起它 → 握手（[runBootstrap]）。
/// - **L2（本插件 ⇄ tree_agent）**：这条常驻通道上的行分隔 JSON-RPC 2.0（[AgentClient]），
///   由 [Tunnel] 转发；通道断 ⇒ 退避重连（重跑 bootstrap），退避耗尽 ⇒ `down`。
library;

export 'src/agent_binary.dart';
export 'src/agent_client.dart';
export 'src/backoff.dart';
export 'src/bootstrap.dart';
export 'src/login_shell.dart';
export 'src/plugin_loop.dart';
export 'src/sha256.dart';
export 'src/ssh_dialer.dart';
export 'src/tunnel.dart';
export 'src/tunnel_config.dart';
export 'src/tunnel_manager.dart';
