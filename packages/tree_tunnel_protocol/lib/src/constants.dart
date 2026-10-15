/// 协议常量（三端共用的唯一真源）。
library;

/// 核心 ⇄ 插件 的协议版本。
///
/// 沿用既有插件协议的 `protocol: 1` 口径：`hello` 握手时三层都报它，
/// 不匹配即拒绝（插件报 `handshake_failed` ⇒ 核心回退内置 dartssh2）。
const int kTunnelProtocolVersion = 1;

/// 插件 ⇄ tree_agent 的协议版本。
///
/// **改了就必须同时改三端**（agent 的方法形状、插件的转发、核心的映射）；
/// 版本不匹配时 agent 回 `-32008 protocol_mismatch`，插件报 `handshake_failed`（回退类）。
const int kAgentProtocolVersion = 1;

/// tree_agent 的二进制版本（由 `tool/build_agent.dart` 用 `--define` 在编译时注入）。
///
/// 为什么要有它：插件按 `~/.tree/agent/<version>/tree_agent` 驻留 agent，
/// sha256 或版本不一致就重推 —— 版本号是"要不要重推"的判据之一（另一个是 sha256）。
const String kAgentVersion = String.fromEnvironment(
  'kAgentVersion',
  defaultValue: '0.0.0-dev',
);

/// 插件申报的能力名：核心据此判断"有没有中转站"。
const String kCapabilitySshExecutor = 'ssh-executor';

/// 中转站插件的**条目 id**（`plugins.yaml` 里的 id，也是内置目录里的 id）。
///
/// 核心不靠它认插件身份（认的是能力名），但**必须是同一个字符串**：
/// 面板的开关、内置目录的播种、`sshExecutorLookup()` 的解释文案都用它。
const String kSshExecutorPluginId = 'ssh_executor';

/// 中转站插件的可执行文件名（`BuiltinPluginSpec.kind == binary` 时按它解析）。
///
/// 与核心可执行文件同级放在 `plugins/`（发行包由 `tool/package_windows.dart` 复制）。
const String kSshExecutorBinaryName = 'tree_ssh_executor';

/// 单帧上限（16 MiB）。超限 ⇒ `frame_too_large`，**丢弃并报错**，不静默截断。
const int kMaxFrameBytes = 16 * 1024 * 1024;

/// `fs.read` 单次返回的原文字节上限（base64 后约 1.37 MiB）。
const int kReadChunkBytes = 1024 * 1024;

/// `exec.spawn` 的日志落点默认值（**相对于 `--root`**）。
///
/// 注意：核心总是显式传 `log_path`（工作空间内路径），这个常量只给"没传"的兜底。
const String kDefaultBackgroundLogDir = '.tree/background';

/// 目标机上 agent 的驻留目录（相对 `$HOME`）。
const String kAgentInstallDir = '.tree/agent';

/// 目标机上 agent 的**状态目录**（`procs.json` / `exit/<id>` / `run/<id>.{sh,out}`），相对 `$HOME`。
const String kAgentStateDir = '.tree/agent/state';

/// 核心 → 插件的方法名。
abstract final class TunnelMethods {
  /// 建立（或复用）一条到某主机的隧道；返回 `conn_id`。
  static const String ensure = 'tunnel.ensure';

  /// 把一次 L2 请求透传给 agent 并回传响应。
  static const String request = 'tunnel.request';

  /// 拉取隧道状态（**权威的判活证据面**）。
  static const String state = 'tunnel.state';

  /// 重置退避并立即重试（用户的「重连」按钮 / 执行站 `ssh.reconnect`）。
  static const String reconnect = 'tunnel.reconnect';

  /// 收掉一条隧道（**不杀** agent，其托管的后台任务照常跑）。
  static const String close = 'tunnel.close';

  /// 插件 → 核心的**通知**（state 跃迁 / PTY 数据面 / 退出面）。
  static const String event = 'tunnel/event';
}

/// 站点体系的 JSON-RPC method 名（核心 ⇄ 插件；中转站投递走这一条，不再用顶层 `tunnel.*`）。
///
/// 2026-10-15：SSH 执行迁移到「处理拓展点位」后，核心把一次 SSH 操作投成
/// `station/request`、插件用 `station/subscribe` 订上点位。方法名在此收敛为唯一真源
/// （核心侧历史上用字面量，此处供插件侧引用；两边字符串必须一致）。
abstract final class StationMethods {
  /// 插件 → 核心：订阅某个站点（`{station, point?, replace?}`）。
  static const String subscribe = 'station/subscribe';

  /// 核心 → 插件：把一次站点请求交给订阅者（`{station_id, request_id, payload, ...}`）。
  static const String request = 'station/request';
}

/// 「SSH 执行中转站点位」的共享常量（阶段 B/C：核心与插件都引用这一份）。
///
/// 定位：中转站不只是「数据拦截-回填」，更是「处理拓展点位」——核心把整块 SSH 工作
/// 交给点位，订阅者（本插件）处理并回填，与工具改写同构。`action` 取值与 [TunnelMethods]
/// 去掉 `tunnel.` 前缀后同名（`ensure` / `request` / `state` / `reconnect` / `close`），
/// 便于插件内部直接分发到 `TunnelManager`；`tunnel/event`（PTY 数据面）**仍是通知**，
/// 不并进请求/回包（中转站只做一问一答）。
abstract final class SshExecuteStation {
  /// 点位的订阅别名（`station/subscribe` 的 `point`）。
  static const String alias = 'ssh.execute';

  /// 点位完整 id（`station/request` 的 `station_id`；与核心 `StationHubIds.relaySshExecute` 同串）。
  static const String pointId = 'system.relay.ssh.execute';

  /// 站点类型别名（`station/subscribe` 的 `station`）。
  static const String kind = 'relay';

  static const String ensure = 'ensure';
  static const String request = 'request';
  static const String state = 'state';
  static const String reconnect = 'reconnect';
  static const String close = 'close';
}

/// 插件 → 核心 `tunnel/event` 通知的 `kind`。
abstract final class TunnelEventKind {
  static const String state = 'state';
  static const String shellData = 'shell.data';
  static const String shellExit = 'shell.exit';
}

/// 插件 → tree_agent 的方法名。
abstract final class AgentMethods {
  static const String hello = 'agent.hello';
  static const String ping = 'agent.ping';
  static const String info = 'agent.info';

  static const String fsRead = 'fs.read';
  static const String fsWrite = 'fs.write';
  static const String fsStat = 'fs.stat';
  static const String fsExists = 'fs.exists';
  static const String fsList = 'fs.list';
  static const String fsListEntries = 'fs.listEntries';
  static const String fsMkdir = 'fs.mkdir';
  static const String fsRename = 'fs.rename';
  static const String fsRemove = 'fs.remove';
  static const String fsDelete = 'fs.delete';
  static const String fsIsDir = 'fs.isDir';

  static const String execRun = 'exec.run';
  static const String execSpawn = 'exec.spawn';
  static const String execList = 'exec.list';
  static const String execQuery = 'exec.query';
  static const String execKill = 'exec.kill';

  static const String shellOpen = 'shell.open';
  static const String shellWrite = 'shell.write';
  static const String shellResize = 'shell.resize';
  static const String shellClose = 'shell.close';

  /// agent → 插件通知：PTY 输出（原始字节，base64）。
  static const String shellData = 'shell.data';

  /// agent → 插件通知：PTY 结束（`exit_code`，拿不到给 -1）。
  static const String shellExit = 'shell.exit';
}

/// 本协议专用错误码（JSON-RPC `error.code`）。
///
/// 标准码：`-32700` 解析错 / `-32600` 非法请求 / `-32601` 方法不存在 /
/// `-32602` 参数非法 / `-32603` 内部错 —— 见 [RpcCodes]。
abstract final class TunnelErrorCodes {
  static const int pathOutOfRoot = -32001;
  static const int notFound = -32002;
  static const int alreadyExists = -32003;
  static const int notEmpty = -32004;
  static const int parentMissing = -32005;
  static const int ptyUnsupported = -32006;
  static const int handshakeFailed = -32007;
  static const int protocolMismatch = -32008;
  static const int permissionDenied = -32009;
  static const int execFailed = -32010;
  static const int frameTooLarge = -32011;
  static const int busy = -32012;
}

/// JSON-RPC 标准错误码。
abstract final class RpcCodes {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
}

/// 隧道状态（`tunnel.state` 的 `state` 字段）。
abstract final class TunnelStates {
  /// 正在建立 SSH 连接 / 解析凭据。
  static const String connecting = 'connecting';

  /// 正在推送 agent / 拉起 / 握手。
  static const String booting = 'booting';

  /// 可用（稳态）。
  static const String ready = 'ready';

  /// 断了，正在退避重连。
  static const String reconnecting = 'reconnecting';

  /// 退避耗尽 / 不可调和 ⇒ 核心视其为「无中转站」。
  static const String down = 'down';
}

/// 核心据以决定「回退 vs 如实暴露」的失败分类（`tunnel.ensure` 的 `error_kind`）。
abstract final class TunnelErrorKinds {
  static const String agentUnreachable = 'agent_unreachable';
  static const String pushFailed = 'push_failed';
  static const String spawnFailed = 'spawn_failed';
  static const String handshakeFailed = 'handshake_failed';
  static const String archUnsupported = 'arch_unsupported';

  /// **不回退**：配置本身不完整，回退也一样连不上 ⇒ 如实报错。
  static const String configIncomplete = 'config_incomplete';

  /// 隧道**暂时**不可用（`connecting` / `booting` / `reconnecting`），但**没判死**。
  ///
  /// 关键区别（2026-10-11 修，用户口径）：这种失败**只说明"这一次请求没被转发给 agent"**，
  /// 不等于"退避耗尽"。核心据此**等隧道回来再发**（`tunnel_not_ready` 的请求**确定未执行**，
  /// 因此重发不是"重放"），而**不是**判死/回退内置。
  ///
  /// 修复前 `connecting`/`reconnecting` 也报 [tunnelDown]，核心把"重连中"当成"判死"⇒
  /// 一次网络抖动就让后台 hook 立刻失败（还提前回退内置），用户 2026-10-11 报的就是它。
  static const String tunnelNotReady = 'tunnel_not_ready';

  /// 隧道**已判死**：退避耗尽（累计上限）或不可调和，或已被显式关闭。
  static const String tunnelDown = 'tunnel_down';

  /// 这些 kind ⇒ 核心**回退内置 dartssh2**（并明示）。
  ///
  /// [tunnelNotReady] **刻意不在**这里：它只是"还没好"，等它就是了，回退反而把
  /// 一条正在重连的隧道白扔掉。
  static const Set<String> fallbackKinds = <String>{
    agentUnreachable,
    pushFailed,
    spawnFailed,
    handshakeFailed,
    archUnsupported,
    tunnelDown,
  };
}

/// 后台任务状态（`exec.list` 的 `state` 字段）。
abstract final class BackgroundStates {
  static const String running = 'running';
  static const String exited = 'exited';
  static const String gone = 'gone';
}

/// 不依赖 `dart:io` 的路径归一化（POSIX）。
///
/// 为什么手写而不是用 `package:path`：`p.posix.normalize` 在 Windows 上仍然按 POSIX 规则跑
/// （它是对的），但本包要在**目标机 Linux** 与 **Windows 上的开发机测试**之间保持一致行为，
/// 手写一份最小的规则可以避免"测试在 Windows 跑、生产在 Linux 跑"时的隐性差异。
/// 规则与 `p.posix.normalize` 对齐：折叠 `.`/`//`、消解 `..`（不越过根）、保留尾斜杠的语义位。
String normalizePosixPath(String input) {
  if (input.isEmpty) return '.';
  final bool absolute = input.startsWith('/');
  final List<String> out = <String>[];
  for (final String part in input.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!absolute) {
        out.add('..');
      }
      continue;
    }
    out.add(part);
  }
  final String joined = out.join('/');
  if (absolute) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

/// 判断 [path] 是否落在 [root] 之内（含等于 root）。
///
/// 两侧都先 [normalizePosixPath]；**不解析符号链接**（与 SFTP 层同口径：按链接本身操作）。
bool isWithinRoot(String path, String root) {
  final String p = normalizePosixPath(path);
  final String r = normalizePosixPath(root);
  if (p == r) return true;
  final String prefix = r.endsWith('/') ? r : '$r/';
  return p.startsWith(prefix);
}
