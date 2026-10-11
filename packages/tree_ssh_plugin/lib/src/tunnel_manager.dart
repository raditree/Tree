import 'dart:math';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'agent_binary.dart';
import 'backoff.dart';
import 'bootstrap.dart';
import 'ssh_dialer.dart';
import 'tunnel.dart';
import 'tunnel_config.dart';

/// 多隧道的**台账**：`Map<conn_id, Tunnel>` + 按 key 去重 + 收口。
///
/// 去重键 = `host|port|username|root|login_shell`（任务书口径）：同一个工作空间被多处
/// IO 同时解析时，只建一条 SSH 连接、只拉一个 agent（协议 §2：`tunnel.ensure` 是
/// "建立**或复用**"）。
class TunnelManager {
  TunnelManager({
    required this.dialer,
    required this.loadBinary,
    this.timerFactory,
    this.now,
    this.onEvent,
    this.log,
    this.backoffFactory = Backoff.new,
    this.chunkBytes = kPushChunkBytes,
    this.random,
  });

  /// SSH 连接工厂（透传给每条隧道；单测注入假 dialer）。
  final SshDialer dialer;

  /// 随包 agent 二进制的装载器（透传；单测注入假字节）。
  final AgentBinaryLoader loadBinary;

  /// 定时器工厂（透传；单测注入假时钟）。
  final TimerFactory? timerFactory;

  /// 当前时间（透传；可注入）。
  final DateTime Function()? now;

  /// 事件出口（状态跃迁 / PTY 数据面；转成 L1 `tunnel/event`）。
  final void Function(Map<String, dynamic> event)? onEvent;

  final void Function(String message)? log;

  /// 每条隧道一份**独立**的退避账本（一条耗尽不影响另一条）。
  final Backoff Function() backoffFactory;

  /// agent 推送分块大小（透传；单测改小）。
  final int chunkBytes;

  /// 随机源（透传；单测注入可复现的种子）。
  final Random? random;

  final Map<String, Tunnel> _tunnels = <String, Tunnel>{};
  int _seq = 0;

  /// 本进程的 `conn_id` 前缀（随机；理由见 [_create]）。
  late final String _connPrefix = _prefixOf(random);

  static String _prefixOf(Random? random) {
    final Random r = random ?? Random.secure();
    return r.nextInt(1 << 20).toRadixString(36).padLeft(4, '0');
  }

  /// 全部隧道（按创建顺序）。
  List<Tunnel> get tunnels => List<Tunnel>.unmodifiable(_tunnels.values);

  /// 按 id 取（不存在 = null）。
  Tunnel? byId(String connId) => _tunnels[connId];

  /// `tunnel.ensure`：建一条或复用它。
  ///
  /// 失败面的 `error_kind` 就是核心"回退 vs 如实报错"的判据（协议 §5）：
  /// - `config_incomplete` ⇒ 连隧道都不建（回退也一样连不上）；
  /// - `arch_unsupported` / `handshake_failed` ⇒ 隧道标记 `down`（不可调和）；
  /// - 其它 ⇒ 隧道进退避重连，核心此次如实报错并回退。
  Future<Map<String, dynamic>> ensure(Map<String, dynamic> request) async {
    final TunnelConfig? config = TunnelConfig.parse(request['config']);
    if (config == null) {
      return _ensureFailure(
        TunnelErrorKinds.configIncomplete,
        'config 不完整：缺少 host（或 config 不是对象）',
      );
    }
    if (!config.isComplete) {
      return _ensureFailure(
        TunnelErrorKinds.configIncomplete,
        'config 不完整：缺少 ${config.missingFields.join('、')}',
      );
    }
    // 版本以**插件自报**为准（协议 §2 / §6，2026-10-11 用户裁决 B）：
    // 只有插件知道它随包带的是哪个二进制；请求里若带版本，只用来对账并留痕。
    final AgentRequest agent = AgentRequest.parse(request['agent'], log: log);
    final String key = config.dedupeKey;

    Tunnel? tunnel = _existingByKey(key);
    if (tunnel == null) {
      tunnel = _create(config, agent);
      log?.call('新建隧道 ${tunnel.connId}（${config.label}）');
    } else {
      log?.call('复用同 key 隧道 ${tunnel.connId}（${config.label}）');
      if (tunnel.state == TunnelStates.down) {
        // 上次退避已经耗尽 ⇒ 这次是**新的**一次机会：清零退避，重新开始一轮。
        log?.call('隧道 ${tunnel.connId} 之前已 down，本次 ensure 重新给一轮机会');
        tunnel.backoff.reset();
      }
    }

    final bool ready = await tunnel.ensureReady();
    if (!ready) {
      return _ensureFailure(
        tunnel.lastErrorKind ?? TunnelErrorKinds.tunnelDown,
        tunnel.lastError ?? '隧道建立失败（state=${tunnel.state}）',
      );
    }
    return <String, dynamic>{
      'ok': true,
      'conn_id': tunnel.connId,
      'root': tunnel.root,
      'agent': tunnel.hello?.toJson() ?? const <String, dynamic>{},
    };
  }

  /// `tunnel.request`：把一次 L2 请求转给对应隧道的 agent。
  Future<Map<String, dynamic>> request(
    String connId,
    String method,
    Map<String, dynamic> params,
  ) async {
    final Tunnel? tunnel = _tunnels[connId];
    if (tunnel == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '隧道不存在：$connId',
        'error_kind': TunnelErrorKinds.tunnelDown,
      };
    }
    return tunnel.request(method, params);
  }

  /// `tunnel.state`：**权威的判活面**（`conn_id` 缺省 = 全部）。
  Map<String, dynamic> state([String? connId]) {
    if (connId == null || connId.isEmpty) {
      return <String, dynamic>{
        'ok': true,
        'tunnels': <Map<String, dynamic>>[
          for (final Tunnel tunnel in _tunnels.values) tunnel.stateJson(),
        ],
      };
    }
    final Tunnel? tunnel = _tunnels[connId];
    return <String, dynamic>{
      'ok': true,
      // 查不到就是空列表（核心据此知道"这条隧道没了"）；**不假装**它还在。
      'tunnels': <Map<String, dynamic>>[
        if (tunnel != null) tunnel.stateJson(),
      ],
    };
  }

  /// `tunnel.reconnect`：清零退避并立即重试。
  Future<Map<String, dynamic>> reconnect(String connId) async {
    final Tunnel? tunnel = _tunnels[connId];
    if (tunnel == null) {
      return <String, dynamic>{'ok': false, 'error': '隧道不存在：$connId'};
    }
    await tunnel.reconnect();
    return <String, dynamic>{'ok': true, 'state': tunnel.state};
  }

  /// `tunnel.close`：收掉一条（**幂等**：不存在也回 ok）。
  Future<Map<String, dynamic>> closeTunnel(String connId) async {
    final Tunnel? tunnel = _tunnels.remove(connId);
    if (tunnel == null) return <String, dynamic>{'ok': true};
    await tunnel.close();
    log?.call('隧道 $connId 已关闭');
    return <String, dynamic>{'ok': true};
  }

  /// 全部收掉（`shutdown` 用）。
  Future<void> closeAll() async {
    final List<Tunnel> all = _tunnels.values.toList(growable: false);
    _tunnels.clear();
    for (final Tunnel tunnel in all) {
      try {
        await tunnel.close();
      } catch (error) {
        log?.call('关闭隧道 ${tunnel.connId} 时出错（忽略）：$error');
      }
    }
  }

  Tunnel _create(TunnelConfig config, AgentRequest agent) {
    final Tunnel tunnel = Tunnel(
      // `conn_id` 带**进程内随机前缀**：插件重启（停用→启用 / 崩溃被重拉）后序号会从 1 重来，
      // 而核心侧可能还留着"旧会话"（它绑的是**旧实例**）——拿旧 `conn_id` 去新实例问状态，
      // 就可能命中新实例的**另一条**隧道（root 可能不同）⇒ 静默跨 root 操作（踩红线）。
      // 判死口径修好之后旧会话很快会被停用，随机前缀让它**不可能发生**，而不是"很快收敛"。
      connId: 'conn-$_connPrefix-${++_seq}',
      config: config,
      agent: agent,
      dialer: dialer,
      loadBinary: loadBinary,
      backoff: backoffFactory(),
      timerFactory: timerFactory ?? defaultTimerFactory,
      now: now ?? DateTime.now,
      onEvent: onEvent,
      log: log,
      chunkBytes: chunkBytes,
      random: random,
    );
    _tunnels[tunnel.connId] = tunnel;
    return tunnel;
  }

  Tunnel? _existingByKey(String key) {
    for (final Tunnel tunnel in _tunnels.values) {
      if (tunnel.isClosed) continue;
      if (tunnel.config.dedupeKey == key) return tunnel;
    }
    return null;
  }

  static Map<String, dynamic> _ensureFailure(String kind, String message) =>
      <String, dynamic>{'ok': false, 'error': message, 'error_kind': kind};
}
