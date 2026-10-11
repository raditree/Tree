import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'fake_ssh.dart';

/// **中转站插件的左栏面板**（2026-10-11 用户要求）：
/// 只读状态 + 两个动作（重连 / 关闭，关闭是两段式）。
///
/// 这些用例钉的是**帧形状**与**分派口径**（面板是插件的唯一 UI 面，写错了前端就"点了没反应"）：
/// - `ui/manifest` 只发一次、槽位是 `activity`、`slot_key` 固定、不带 `team_id`（空归属 = 任何 team 可见）；
/// - 视图只用**受限控件集**（写了别的类型前端只渲染"不支持的控件"占位）；
/// - 刷新走 `ui/update` 且有 300ms 节流；
/// - 动作判据在 `params['event']` 上（写成 `method == 'plugin_ui_action'` 永远不命中）；
/// - 面板**不出现任何凭据**；任何异常都不许冒泡（fail-open）。
void main() {
  late FakeRemote remote;
  late FakeDialer dialer;
  late FakeTimers tunnelTimers;
  late FakeTimers uiTimers;
  late List<Map<String, dynamic>> sent;
  late List<String> logs;
  late TunnelManager manager;
  late TunnelUiPanel panel;

  setUp(() {
    remote = FakeRemote();
    dialer = FakeDialer(remote);
    tunnelTimers = FakeTimers();
    uiTimers = FakeTimers();
    sent = <Map<String, dynamic>>[];
    logs = <String>[];
    manager = TunnelManager(
      dialer: dialer.call,
      loadBinary: memoryBinary(List<int>.filled(64, 1)),
      timerFactory: tunnelTimers.factory,
      chunkBytes: 64,
    );
    panel = TunnelUiPanel(
      send: sent.add,
      manager: manager,
      timerFactory: uiTimers.factory,
      log: logs.add,
    );
  });

  tearDown(() async {
    await manager.closeAll();
  });

  /// 建一条隧道（真走 FakeRemote 的 bootstrap）。
  Future<String> openTunnel({Map<String, dynamic>? config}) async {
    final Map<String, dynamic> result = await manager.ensure(<String, dynamic>{
      'config': config ?? configJson(),
    });
    return (result['conn_id'] ?? '').toString();
  }

  Map<String, dynamic> manifestFrame() =>
      sent.firstWhere((Map<String, dynamic> f) => f['method'] == kUiMethodManifest);

  List<Map<String, dynamic>> updateFrames() => sent
      .where((Map<String, dynamic> f) => f['method'] == kUiMethodUpdate)
      .toList(growable: false);

  /// 一帧里携带的**全部视图**：`ui/update` 在 `params.view`；
  /// `ui/manifest` 在每个槽位条目的 `view` 上。
  List<Object?> viewsIn(Map<String, dynamic> frame) {
    final Map<String, dynamic> params =
        (frame['params'] as Map).map((dynamic k, dynamic v) => MapEntry('$k', v));
    if (frame['method'] == kUiMethodUpdate) {
      return <Object?>[params['view']];
    }
    final List<Object?> slots = (params['slots'] as List<Object?>?) ?? <Object?>[];
    return <Object?>[
      for (final Object? slot in slots)
        if (slot is Map) slot['view'],
    ];
  }

  /// 递归收集视图里出现过的节点类型（容器与叶子都算）。
  Set<String> nodeTypesOf(Object? view) {
    final Set<String> out = <String>{};
    void walk(Object? node) {
      if (node is List) {
        for (final Object? item in node) {
          walk(item);
        }
        return;
      }
      if (node is! Map) return;
      final Object? type = node['type'];
      if (type is String) out.add(type);
      walk(node['children']);
      walk(node['items']);
    }

    walk(view);
    return out;
  }

  group('声明与视图形状', () {
    test('declare 发**一条** ui/manifest：activity 槽位 + 固定 slot_key + 初始视图 + 空归属', () {
      panel.declare();
      expect(sent.length, 1);
      final Map<String, dynamic> frame = manifestFrame();
      final Map<String, dynamic> params =
          (frame['params'] as Map).map((dynamic k, dynamic v) => MapEntry('$k', v));
      final List<Object?> slots = params['slots'] as List<Object?>;
      expect(slots.length, 1);
      final Map<String, dynamic> slot =
          (slots.single! as Map).map((dynamic k, dynamic v) => MapEntry('$k', v));
      expect(slot['slot'], 'activity');
      expect(slot['slot_key'], kUiSlotKey);
      expect(slot['title'], kUiSlotTitle);
      expect(slot['icon'], kUiSlotIcon);
      expect(slot['order'], kUiSlotOrder);
      // 归属交给核心按实例 id / plugins.yaml 兜底：自带 team_id 反而可能被跨 team 校验拒掉。
      expect(slot.containsKey('team_id'), isFalse);
      expect(slot.containsKey('plugin_id'), isFalse);
      expect(slot['view'], isA<Map<dynamic, dynamic>>());
    });

    test('视图只用受限控件集（否则前端渲染成「不支持的控件」占位）', () async {
      await openTunnel();
      panel.declare();
      panel.refresh(force: true);
      final Set<String> allowed = <String>{
        'text',
        'list',
        'table',
        'form',
        'progress',
        'actions',
        'row',
        'column',
      };
      for (final Map<String, dynamic> frame in <Map<String, dynamic>>[
        manifestFrame(),
        ...updateFrames(),
      ]) {
        for (final Object? view in viewsIn(frame)) {
          final Set<String> used = nodeTypesOf(view);
          expect(
            used.difference(allowed),
            isEmpty,
            reason: '视图里出现了受限控件集之外的节点：${used.difference(allowed)}',
          );
        }
      }
    });

    test('没有隧道时面板仍有内容（指路文案，而不是一片空白）', () {
      panel.declare();
      final String text = jsonEncode(manifestFrame());
      expect(text, contains('还没有隧道'));
      expect(text, contains(kUiSlotTitle));
    });

    test('有隧道时列出 label / state / agent 版本 / 安装路径 / 两个按钮', () async {
      await openTunnel();
      panel.refresh(force: true);
      final String text = jsonEncode(updateFrames().last);
      expect(text, contains('10.0.0.1:22/tester'), reason: 'TunnelConfig.label');
      expect(text, contains(TunnelStates.ready));
      expect(text, contains('/home/tester'), reason: '权威 root');
      expect(text, contains('1.2.3'), reason: 'agent 自报版本（来自 agent.hello）');
      expect(text, contains('tree_agent'), reason: '目标机上的安装路径');
      expect(text, contains(kUiActionReconnect));
      expect(text, contains(kUiActionClose));
    });

    test('面板视图不出现任何凭据（口令 / 私钥路径 / 握手 token）', () async {
      await openTunnel(
        config: <String, dynamic>{
          ...configJson(password: 'hunter2'),
          'key_path': '/home/tester/.ssh/id_ed25519_super_secret',
          'key_passphrase': 'topsecret',
        },
      );
      panel.declare();
      panel.refresh(force: true);
      final String all = jsonEncode(sent);
      expect(all, isNot(contains('hunter2')));
      expect(all, isNot(contains('topsecret')));
      expect(all, isNot(contains('id_ed25519_super_secret')));
    });
  });

  group('刷新节流', () {
    test('首帧立即发；窗口内的后续刷新合并成一帧（300ms 后补发）', () {
      panel.refresh(force: true);
      expect(sent.length, 1);
      panel.refresh();
      panel.refresh();
      panel.refresh();
      expect(sent.length, 1, reason: '窗口内不许连发（前端会整块重建左栏那一页）');
      expect(uiTimers.pending.length, 1, reason: '多次跃迁只排一个补发定时器');
      uiTimers.fireNext();
      expect(sent.length, 2);
    });

    test('force 绕过节流（按钮回调这类"用户正等着看"的刷新）', () {
      panel.refresh(force: true);
      panel.refresh(force: true);
      expect(sent.length, 2);
      expect(uiTimers.pending, isEmpty);
    });
  });

  group('动作：重连 / 关闭（两段式）', () {
    test('重连按钮：健康通道上不打散（探针答得上就是 no-op），但会刷新面板', () async {
      final String conn = await openTunnel();
      final int dialsBefore = remote.dials;
      final int framesBefore = sent.length;
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionReconnect,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      expect(remote.dials, dialsBefore, reason: '健康通道不该被显式重连打散（协议口径）');
      expect(manager.byId(conn)!.state, TunnelStates.ready);
      expect(sent.length, greaterThan(framesBefore), reason: '动作后要刷新');
    });

    test('重连按钮：通道断了 ⇒ 真的重建（dial 次数增加、回到 ready）', () async {
      final String conn = await openTunnel();
      remote.lastChannel!.kill();
      await pump(6);
      final int dialsBefore = remote.dials;
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionReconnect,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      await pump(6);
      expect(remote.dials, dialsBefore + 1, reason: '断了的通道点重连要真的重建');
      expect(manager.byId(conn)!.state, TunnelStates.ready);
    });

    test('关闭按钮两段式：第一下只进确认态（不真关），第二下才收掉隧道', () async {
      final String conn = await openTunnel();
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      expect(panel.pendingClose, conn);
      expect(manager.byId(conn), isNotNull, reason: '第一下绝不许真关');
      expect(jsonEncode(updateFrames().last), contains('确认关闭'));

      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      expect(panel.pendingClose, isNull);
      expect(manager.byId(conn), isNull, reason: '第二下才真关');
      expect(jsonEncode(updateFrames().last), isNot(contains('确认关闭')));
    });

    test('取消按钮回到「关闭」，隧道不动', () async {
      final String conn = await openTunnel();
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionCancelClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      expect(panel.pendingClose, isNull);
      expect(manager.byId(conn), isNotNull);
      expect(jsonEncode(updateFrames().last), isNot(contains('确认关闭')));
    });

    test('确认态 20s 后自动过期（避免"点一下就走开，回头再点一下"变成误关）', () async {
      final String conn = await openTunnel();
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      expect(panel.pendingClose, conn);
      final FakeTimer expiry = uiTimers.pending.firstWhere(
        (FakeTimer t) => t.duration == kUiConfirmWindow,
      );
      expiry.fire();
      expect(panel.pendingClose, isNull);
      expect(manager.byId(conn), isNotNull, reason: '过期只是取消确认，不许顺手关掉');
      // 「过期」也要在面板上有反馈（口径：动作结果一律当行显示）。
      expect(panel.lastActionNote, contains('已过期'));
    });

    test('未知 action_id / 缺 conn_id ⇒ 不抛不崩，且**面板上看得到**（fail-open + 反馈可见）', () async {
      final int framesBefore = sent.length;
      await panel.handleAction(<String, dynamic>{'action_id': 'nope'});
      expect(
        sent.length,
        greaterThan(framesBefore),
        reason: '失败也要刷新一帧 —— 只写 stderr 等于用户什么都看不到（2026-10-11 真机反馈）',
      );
      expect(jsonEncode(updateFrames().last), contains('未知的面板动作'));
      await panel.handleAction(<String, dynamic>{'action_id': kUiActionClose});
      expect(jsonEncode(updateFrames().last), contains('没带上 conn_id'));
      await panel.handleAction(<String, dynamic>{'action_id': kUiActionReconnect});
      expect(jsonEncode(updateFrames().last), contains('没带上 conn_id'));
      expect(logs, isNotEmpty);
      expect(panel.pendingClose, isNull, reason: '缺 conn_id 不许进入确认态');
    });

    test('关闭成功后：面板上留一行说明（核心下次使用这个工作空间时会重建）', () async {
      final String conn = await openTunnel();
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionClose,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      final String text = jsonEncode(updateFrames().last);
      expect(text, contains('已关闭 $conn'));
      expect(text, contains('下次使用'));
      expect(panel.lastActionNote, contains('已关闭'));
    });

    test('重连一条已被关闭的隧道 ⇒ 失败原因当行显示（不再"点了没反应"）', () async {
      final String conn = await openTunnel();
      for (int i = 0; i < 2; i++) {
        await panel.handleAction(<String, dynamic>{
          'action_id': kUiActionClose,
          'payload': <String, dynamic>{'conn_id': conn},
        });
      }
      await panel.handleAction(<String, dynamic>{
        'action_id': kUiActionReconnect,
        'payload': <String, dynamic>{'conn_id': conn},
      });
      final String text = jsonEncode(updateFrames().last);
      expect(text, contains('未成功'));
      expect(text, contains(conn));
    });
  });

  group('PluginLoop 接线', () {
    late StreamController<List<int>> input;
    late PluginLoop loop;
    late List<Map<String, dynamic>> frames;

    setUp(() {
      frames = <Map<String, dynamic>>[];
      input = StreamController<List<int>>();
      loop = PluginLoop(
        dialer: dialer.call,
        loadBinary: memoryBinary(List<int>.filled(64, 1)),
        send: frames.add,
        timerFactory: tunnelTimers.factory,
        log: logs.add,
        chunkBytes: 64,
      );
      unawaited(loop.run(input.stream));
    });

    tearDown(() async {
      await loop.shutdown();
      await input.close();
    });

    test('run() 起手就声明左栏槽位（前端后连由核心缓存补发）', () {
      final List<Map<String, dynamic>> manifests = frames
          .where((Map<String, dynamic> f) => f['method'] == kUiMethodManifest)
          .toList(growable: false);
      expect(manifests.length, 1);
      expect(jsonEncode(manifests.single), contains(kUiSlotKey));
    });

    test('隧道状态跃迁自动刷面板（ui/update），PTY 数据面不刷', () async {
      input.add(
        encodeFrame(
          rpcRequest(1, TunnelMethods.ensure, <String, dynamic>{
            'config': configJson(),
          }),
        ),
      );
      await pump(8);
      expect(
        frames.where((Map<String, dynamic> f) => f['method'] == kUiMethodUpdate),
        isNotEmpty,
        reason: '建隧道（connecting→booting→ready）必须让面板跟着动',
      );
      final int before = frames
          .where((Map<String, dynamic> f) => f['method'] == kUiMethodUpdate)
          .length;
      remote.lastChannel!.emitNotification(
        AgentMethods.shellData,
        <String, dynamic>{'shell_id': 's1', 'data': 'x'},
      );
      await pump(4);
      expect(
        frames.where((Map<String, dynamic> f) => f['method'] == kUiMethodUpdate).length,
        before,
        reason: 'PTY 数据面与面板无关，不许拿它刷面板',
      );
    });

    test('面板动作：判据在 params[\'event\'] 上（method 直写不生效）', () async {
      input.add(
        encodeFrame(
          rpcRequest(1, TunnelMethods.ensure, <String, dynamic>{
            'config': configJson(),
          }),
        ),
      );
      await pump(8);
      int updates() => frames
          .where((Map<String, dynamic> f) => f['method'] == kUiMethodUpdate)
          .length;
      final int before = updates();

      // ① 正确形状（核心上行就是这一种）⇒ 被分派、立刻刷新。
      input.add(
        encodeFrame(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': PluginMethods.event,
          'params': <String, dynamic>{'event': kUiActionEvent, 'action_id': kUiActionRefresh},
        }),
      );
      await pump(6);
      expect(updates(), greaterThan(before), reason: 'params[\'event\'] 判据必须命中');

      // ② 指南点名的坑：把 action 名当 method 写 ⇒ 永远不命中（我们至少不能崩）。
      final int afterCorrect = updates();
      input.add(
        encodeFrame(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': kUiActionEvent,
          'params': <String, dynamic>{'action_id': kUiActionRefresh},
        }),
      );
      await pump(6);
      expect(updates(), afterCorrect, reason: 'method 直写不该被当成面板动作');
      expect(logs.any((String l) => l.contains('不消费')), isTrue);
    });
  });
}
