import 'dart:async';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'tunnel.dart';
import 'tunnel_manager.dart';

/// 左栏面板（`activity` 槽位）的**槽位常量**。
///
/// `slot_key` 用固定常量而不是拼实例 id：一个插件条目 = **一个进程实例**
/// （`granularity` 只是声明性字段，见 `docs/plugin-development.md` §9），
/// 因此不存在"同一个脚本配成两个实例互相覆盖"的问题。
const String kUiSlotKey = 'ssh_executor.activity.1';

/// 槽位展示名（活动栏 tooltip + 左栏整页标题）。
const String kUiSlotTitle = 'SSH 执行器中转站';

/// 活动栏图标名（前端白名单内，未知名回退扩展图标，见 `lib/ui/widgets/plugin_ui_slots.dart`）。
const String kUiSlotIcon = 'link';

/// 同类型槽位内的排序权重（小的在前）。
const int kUiSlotOrder = 30;

/// `ui/manifest` / `ui/update` 两个通知的 method 名（核心按约定方法转成前端 UI 帧）。
const String kUiMethodManifest = 'ui/manifest';
const String kUiMethodUpdate = 'ui/update';

/// 面板动作的 `action_id`（前端按钮 `payload` 里带 `conn_id`）。
const String kUiActionRefresh = 'refresh';
const String kUiActionReconnect = 'reconnect';
const String kUiActionClose = 'close';
const String kUiActionCancelClose = 'cancel_close';

/// 核心**上行**给插件时的通知形状里那个判据键的值：
/// `{"method":"event","params":{"event":"plugin_ui_action", …}}`。
///
/// **判据必须写在 `params['event']` 上**——写成 `method == 'plugin_ui_action'`
/// 永远不命中且不报错（`docs/plugin-development.md` §10 常见坑 ⑥）。
const String kUiActionEvent = 'plugin_ui_action';

/// 面板刷新的最小间隔（状态跃迁可能连着来：connecting → booting → ready）。
///
/// 前端收到 `ui/update` 会**整块重建**左栏那一页，刷太勤只是闪。
const Duration kUiRefreshThrottle = Duration(milliseconds: 300);

/// 「确认关闭」的有效期：到点自动回到「关闭」（避免用户点了一次就走开，
/// 回来把它当成第一次再点一下 ⇒ 误关）。
const Duration kUiConfirmWindow = Duration(seconds: 20);

/// 面板一次最多渲染几条隧道（视图体积上限 64 KiB 的余量里取一个保守值）。
const int kUiMaxTunnels = 8;

/// 中转站插件的**左栏面板**（只读状态 + 两个动作）。
///
/// 设计口径（`packages/tree_ssh_plugin/README.md` 的不变量）：
/// - **只读**：视图全部来自 [TunnelManager.tunnels] / [Tunnel.stateJson] / [Tunnel.installPath]，
///   **绝不显示凭据**（那些字段本来就不在那里）；
/// - **两个动作**：`reconnect`（清零退避、必要时强拆重建）与 `close`（收掉这条隧道，**两段式确认**）；
/// - **fail-open**：视图构造与动作处理里任何异常都被吞掉并记日志——读循环与 `ping` 不能被它拖住
///   （插件三条铁律，见 [PluginLoop] 的 dartdoc）；
/// - 刷新**走 `ui/update`，不借 `tunnel/event`**：后者是核心与插件之间的内部数据面
///   （`plugin_bus.dart` 明确不把它降级成 `plugin_event`），拿它刷面板根本不生效。
class TunnelUiPanel {
  TunnelUiPanel({
    required this.send,
    required this.manager,
    this.slotKey = kUiSlotKey,
    this.throttle = kUiRefreshThrottle,
    this.confirmWindow = kUiConfirmWindow,
    this.maxTunnels = kUiMaxTunnels,
    TimerFactory? timerFactory,
    DateTime Function()? now,
    this.log,
  })  : _timers = timerFactory ?? defaultTimerFactory,
        _now = now ?? DateTime.now;

  /// 出帧口（`PluginLoop` 的 `send`：写 stdout，**只有协议帧**）。
  final void Function(Map<String, dynamic> message) send;

  /// 隧道台账（面板的唯一数据源）。
  final TunnelManager manager;

  /// 槽位键（默认 [kUiSlotKey]；测试注入独立值）。
  final String slotKey;

  /// 刷新节流窗口。
  final Duration throttle;

  /// 「确认关闭」的有效期。
  final Duration confirmWindow;

  /// 一次最多渲染几条隧道。
  final int maxTunnels;

  final TimerFactory _timers;
  final DateTime Function() _now;

  final void Function(String message)? log;

  DateTime? _lastPushAt;
  DelayTimer? _pendingPush;

  /// 处于「待确认关闭」的那条隧道（null = 没有）。
  String? _pendingClose;
  DelayTimer? _confirmTimer;

  /// **上一次面板动作的结果**（一行；失败与成功都要看得见 —— 只写 stderr 等于没反馈）。
  String _lastActionNote = '';

  /// 待确认关闭的隧道 id（诊断 / 测试用）。
  String? get pendingClose => _pendingClose;

  /// 上一次动作的结果行（诊断 / 测试用；空串 = 还没点过任何动作）。
  String get lastActionNote => _lastActionNote;

  // ───────────────────────── 出帧 ─────────────────────────

  /// 发**一条** `ui/manifest`：声明 `activity` 槽位并带初始视图。
  ///
  /// 只发一次就够：前端后连 / 重连 / 插件比前端先就绪这三种时序由核心的
  /// `PluginUiCache` + 补放兜住（`docs/known-issues.md` 记过这条是怎么修的），
  /// 之后的每次刷新走 [refresh]。
  ///
  /// 槽位条目**不带** `plugin_id` / `team_id`：归属由核心按实例 id 与
  /// `plugins.yaml` 的 `scope.team_id` 兜底，空归属 = 任何 team 下都可见
  /// （`lib/ui/services/plugin_ui_registry.dart` 的 `_visible`）。
  void declare() {
    try {
      send(
        rpcNotification(kUiMethodManifest, <String, dynamic>{
          'slots': <Map<String, dynamic>>[
            <String, dynamic>{
              'slot_key': slotKey,
              'slot': 'activity',
              'title': kUiSlotTitle,
              'icon': kUiSlotIcon,
              'order': kUiSlotOrder,
              'view': buildView(),
            },
          ],
        }),
      );
    } catch (error) {
      log?.call('面板声明失败（忽略；插件功能不受影响）：$error');
    }
  }

  /// 发 `ui/update`（整块替换该槽位视图）。
  ///
  /// [force] = 绕过节流（按钮回调这类"用户正等着看"的刷新）。
  void refresh({bool force = false}) {
    try {
      if (force) {
        _cancelPendingPush();
        _push();
        return;
      }
      final DateTime now = _now();
      final DateTime? last = _lastPushAt;
      final Duration since = last == null
          ? throttle
          : now.difference(last);
      if (since >= throttle) {
        _cancelPendingPush();
        _push();
        return;
      }
      // 窗口内已经有了待发帧就不重复排：多次跃迁合并成**一帧**。
      if (_pendingPush != null) return;
      _pendingPush = _timers(throttle - since, () {
        _pendingPush = null;
        _push();
      });
    } catch (error) {
      log?.call('面板刷新失败（忽略）：$error');
    }
  }

  void _push() {
    try {
      _lastPushAt = _now();
      send(
        rpcNotification(kUiMethodUpdate, <String, dynamic>{
          'slot_key': slotKey,
          'view': buildView(),
        }),
      );
    } catch (error) {
      log?.call('面板更新帧发送失败（忽略）：$error');
    }
  }

  void _cancelPendingPush() {
    _pendingPush?.cancel();
    _pendingPush = null;
  }

  // ───────────────────────── 动作 ─────────────────────────

  /// 处理一条核心上行的 `plugin_ui_action` 通知（`params` 是通知的 `params`）。
  ///
  /// 分派只看 `action_id` + `payload['conn_id']`；未知动作 / 缺 `conn_id` 只记日志，
  /// **不抛、不崩**（fail-open）。
  ///
  /// **每次动作的结果都写进面板**（[lastActionNote]，渲染成一行 caption）：用户 2026-10-11
  /// 真机反馈"点了没反应"——第一版只把结果写进 stderr，界面上什么都看不到（等于没反馈）。
  Future<void> handleAction(Map<String, dynamic> params) async {
    try {
      final String actionId = (params['action_id'] ?? '').toString();
      final Object? rawPayload = params['payload'];
      final Map<String, dynamic> payload = rawPayload is Map
          ? rawPayload.map((dynamic k, dynamic v) => MapEntry('$k', v))
          : <String, dynamic>{};
      final String connId = (payload['conn_id'] ?? '').toString().trim();
      switch (actionId) {
        case kUiActionRefresh:
          _note('已刷新（重新读一次隧道台账）');
          refresh(force: true);
          return;
        case kUiActionReconnect:
          if (connId.isEmpty) {
            _note('重连失败：这一行没带上 conn_id（已忽略）');
            refresh(force: true);
            return;
          }
          final Map<String, dynamic> result = await manager.reconnect(connId);
          if (result['ok'] != true) {
            _note(
              '重连 $connId 未成功：${result['error'] ?? '未知原因'}'
              '（这条隧道可能已被关闭；核心下次使用这个工作空间时会重建）',
            );
            log?.call('面板重连 $connId 未成功：${result['error'] ?? '未知原因'}');
          } else {
            _note('已重连 $connId：state=${result['state']}');
            log?.call('面板重连 $connId：state=${result['state']}');
          }
          refresh(force: true);
          return;
        case kUiActionClose:
          if (connId.isEmpty) {
            _note('关闭失败：这一行没带上 conn_id（已忽略）');
            refresh(force: true);
            return;
          }
          if (_pendingClose != connId) {
            _armConfirm(connId);
            _note('已按下「关闭」：再点一次「确认关闭」才会真关掉 $connId（20 秒内有效）');
            refresh(force: true);
            return;
          }
          _clearConfirm();
          await manager.closeTunnel(connId);
          _note(
            '已关闭 $connId。核心仍持有这条连接，会在**下次使用这个工作空间时**判死并重建'
            '（或按既有口径回退内置 dartssh2，日志与右栏会明示）；'
            '目标机上在跑的后台任务不受影响。',
          );
          log?.call('面板关闭隧道 $connId');
          refresh(force: true);
          return;
        case kUiActionCancelClose:
          _clearConfirm();
          _note('已取消关闭');
          refresh(force: true);
          return;
        default:
          _note('未知的面板动作（已忽略）：$actionId');
          log?.call('面板动作未知（忽略）：$actionId');
          refresh(force: true);
          return;
      }
    } catch (error) {
      _note('面板动作处理异常（已忽略，fail-open）：$error');
      log?.call('面板动作处理异常（已忽略，fail-open）：$error');
      refresh(force: true);
    }
  }

  /// 记下"上一次动作的结果"（下一帧视图会带出去）。
  void _note(String message) => _lastActionNote = message;

  void _armConfirm(String connId) {
    _confirmTimer?.cancel();
    _pendingClose = connId;
    _confirmTimer = _timers(confirmWindow, () {
      // 到点自动回到「关闭」：避免"点了一次就走开，回来又点一下"变成误关。
      _pendingClose = null;
      _confirmTimer = null;
      _note('「确认关闭」$connId 已过期（20 秒内没确认），按钮回到「关闭」');
      log?.call('「确认关闭」$connId 已过期，按钮回到「关闭」');
      refresh(force: true);
    });
  }

  void _clearConfirm() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _pendingClose = null;
  }

  // ───────────────────────── 视图 ─────────────────────────

  /// 构造面板视图（**受限控件集**：只有 `column` / `text` / `actions`）。
  ///
  /// 视图是"当前态的快照"：每次 `ui/manifest` / `ui/update` 重新构造一遍。
  Map<String, dynamic> buildView() {
    final List<Map<String, dynamic>> children = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': kUiSlotTitle, 'style': 'title'},
    ];
    List<Tunnel> tunnels;
    try {
      tunnels = manager.tunnels
          .where((Tunnel t) => !t.isClosed)
          .toList(growable: false);
    } catch (error) {
      log?.call('面板读取隧道台账失败（视图降级为空）：$error');
      tunnels = const <Tunnel>[];
    }
    final int ready = tunnels.where((Tunnel t) => t.state == TunnelStates.ready).length;
    children.add(<String, dynamic>{
      'type': 'text',
      'text': tunnels.isEmpty
          ? '还没有隧道：核心第一次用 SSH 工作空间时会建一条'
          : '共 ${tunnels.length} 条隧道（就绪 $ready）；'
              '断开按退避重连，退避耗尽后核心自动回退内置 dartssh2 并在日志/右栏明示',
      'style': 'caption',
    });

    // 上一次动作的结果（成功/失败都要看得见：只写 stderr 等于没有反馈）。
    if (_lastActionNote.isNotEmpty) {
      children.add(<String, dynamic>{
        'type': 'text',
        'text': '上次动作：$_lastActionNote',
        'style': 'caption',
      });
    }

    if (tunnels.isEmpty) {
      children.add(<String, dynamic>{
        'type': 'text',
        'text': '这个面板只做两件事：看每条隧道现在什么状态、需要时重连或关掉它。'
            '它不显示任何凭据（口令 / 私钥 / 握手 token 都不在面板数据里）。',
        'style': 'caption',
      });
    }

    final List<Tunnel> shown = tunnels.take(maxTunnels).toList(growable: false);
    for (final Tunnel tunnel in shown) {
      children.addAll(_tunnelNodes(tunnel));
    }
    if (tunnels.length > shown.length) {
      children.add(<String, dynamic>{
        'type': 'text',
        'text': '还有 ${tunnels.length - shown.length} 条未显示（面板一次最多列 $maxTunnels 条）',
        'style': 'caption',
      });
    }

    children.add(<String, dynamic>{
      'type': 'actions',
      'buttons': <Map<String, dynamic>>[
        <String, dynamic>{
          'action_id': kUiActionRefresh,
          'label': '刷新',
          'style': 'secondary',
        },
      ],
    });

    return <String, dynamic>{
      'type': 'column',
      'gap': 6,
      'children': children,
    };
  }

  /// 一条隧道对应的视图节点（标题 + 明细 + 动作）。
  List<Map<String, dynamic>> _tunnelNodes(Tunnel tunnel) {
    final Map<String, dynamic> state = tunnel.stateJson();
    final Map<String, dynamic> hello = tunnel.hello?.toJson() ?? const <String, dynamic>{};
    final List<Map<String, dynamic>> nodes = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'text',
        'text': '${tunnel.config.label}（${tunnel.connId}）',
        'style': 'body',
      },
      <String, dynamic>{
        'type': 'text',
        'text': 'state=${state['state']} · 尝试 ${state['attempt']} 次 · '
            '已连 ${_secondsOf(state['elapsed_ms'])}s'
            '${(state['root'] ?? '').toString().isEmpty ? '' : ' · root=${state['root']}'}',
        'style': 'caption',
      },
    ];
    if (hello.isNotEmpty || tunnel.installPath.isNotEmpty) {
      final String version = (hello['version'] ?? '').toString();
      final String os = (hello['os'] ?? '').toString();
      final String arch = (hello['arch'] ?? '').toString();
      final String platform = <String>[os, arch].where((String s) => s.isNotEmpty).join('/');
      nodes.add(<String, dynamic>{
        'type': 'text',
        'text': 'agent ${version.isEmpty ? '（未知）' : version}'
            '${platform.isEmpty ? '' : '（$platform）'}'
            '${tunnel.installPath.isEmpty ? '' : ' · ${tunnel.installPath}'}',
        'style': 'mono',
      });
    }
    final String lastError = (state['last_error'] ?? '').toString();
    if (lastError.isNotEmpty) {
      nodes.add(<String, dynamic>{
        'type': 'text',
        'text': '最近一次失败：$lastError',
        'style': 'caption',
      });
    }
    final bool confirming = _pendingClose == tunnel.connId;
    if (confirming) {
      nodes.add(<String, dynamic>{
        'type': 'text',
        'text': '再点一次「确认关闭」就会收掉这条隧道；'
            '在跑的后台任务不受影响（它们在目标机独立跑、退出码落盘），'
            '但正在进行的远端操作会中断——核心下次用这个工作空间时会重建。',
        'style': 'caption',
      });
      nodes.add(<String, dynamic>{
        'type': 'actions',
        'buttons': <Map<String, dynamic>>[
          <String, dynamic>{
            'action_id': kUiActionClose,
            'label': '确认关闭',
            'style': 'danger',
            'payload': <String, dynamic>{'conn_id': tunnel.connId},
          },
          <String, dynamic>{
            'action_id': kUiActionCancelClose,
            'label': '取消',
            'style': 'secondary',
            'payload': <String, dynamic>{'conn_id': tunnel.connId},
          },
        ],
      });
    } else {
      nodes.add(<String, dynamic>{
        'type': 'actions',
        'buttons': <Map<String, dynamic>>[
          <String, dynamic>{
            'action_id': kUiActionReconnect,
            'label': '重连',
            'style': 'secondary',
            'payload': <String, dynamic>{'conn_id': tunnel.connId},
          },
          <String, dynamic>{
            'action_id': kUiActionClose,
            'label': '关闭',
            'style': 'danger',
            'payload': <String, dynamic>{'conn_id': tunnel.connId},
          },
        ],
      });
    }
    return nodes;
  }

  static String _secondsOf(Object? elapsedMs) =>
      ((elapsedMs is num ? elapsedMs.toInt() : 0) ~/ 1000).toString();
}
