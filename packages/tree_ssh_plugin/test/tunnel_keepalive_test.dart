import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'fake_ssh.dart';

/// **断连完整性**（2026-10-11 用户裁决的四条口径）：
/// ① 失败面分类（"还没好" ≠ "判死"）；② 保活与"卡死强拆"；③ spawn 必带静默上限；
/// ④ 重建前按一次性 token 收掉上一世 agent。
///
/// 为什么这些钉子重要：用户真机上"物理断网 ⇒ hook 立即失败 + 目标机多出一个执行器"
/// 两个症状，全都落在这一层（详见 `.self/plan/20261011-tunnel-disconnect-integrity/`）。
void main() {
  late FakeRemote remote;
  late FakeDialer dialer;
  late FakeTimers timers;

  setUp(() {
    remote = FakeRemote();
    dialer = FakeDialer(remote);
    timers = FakeTimers();
  });

  Tunnel build() => Tunnel(
    connId: 'conn-1',
    config: TunnelConfig.parse(configJson())!,
    agent: const AgentRequest(version: '1.2.3'),
    dialer: dialer.call,
    loadBinary: memoryBinary(List<int>.filled(64, 1)),
    backoff: Backoff(maxTotal: const Duration(minutes: 30)),
    timerFactory: timers.factory,
    chunkBytes: 64,
  );

  void firePing() {
    timers.pending
        .firstWhere((FakeTimer t) => t.duration == kAgentPingInterval)
        .fire();
  }

  void firePingTimeout() {
    timers.pending
        .firstWhere((FakeTimer t) => t.duration == kAgentPingTimeout)
        .fire();
  }

  /// 触发**一拍保活**：先到 ping 间隔（发 ping），再到 ping 超时（假 agent 不回包）。
  Future<void> beatWithNoResponse() async {
    firePing();
    await pump(6);
    firePingTimeout();
    await pump(6);
  }

  group('失败面分类：核心据此决定"等它回来"还是"判死"', () {
    test('还没建好（connecting）⇒ tunnel_not_ready（**不是** tunnel_down）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.fsRead,
        <String, dynamic>{'path': '/ws/a'},
      );
      expect(result['ok'], isFalse);
      expect(
        result['error_kind'],
        TunnelErrorKinds.tunnelNotReady,
        reason: '把"重连中"报成 tunnel_down 正是用户那个"一次抖动就判死"的根因',
      );
      expect(result['tunnel_state'], TunnelStates.connecting);
      expect(TunnelErrorKinds.fallbackKinds.contains(TunnelErrorKinds.tunnelNotReady), isFalse);
    });

    test('断连重连中（reconnecting）⇒ 仍旧 tunnel_not_ready', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      remote.lastChannel!.kill(); // 链路断
      await pump(6);
      expect(tunnel.state, TunnelStates.reconnecting);
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.execQuery,
        <String, dynamic>{'id': 'x'},
      );
      expect(result['error_kind'], TunnelErrorKinds.tunnelNotReady);
      expect(result['tunnel_state'], TunnelStates.reconnecting);
    });

    test('已判死（退避耗尽类）⇒ tunnel_down', () async {
      remote.machine = 'riscv64'; // arch_unsupported ⇒ 直接 down
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      expect(await tunnel.ensureReady(), isFalse);
      expect(tunnel.state, TunnelStates.down);
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.fsRead,
        <String, dynamic>{'path': '/ws/a'},
      );
      expect(result['error_kind'], TunnelErrorKinds.tunnelDown);
    });

    test('已关闭 ⇒ tunnel_down', () async {
      final Tunnel tunnel = build();
      await tunnel.ensureReady();
      await tunnel.close();
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.fsRead,
        <String, dynamic>{'path': '/ws/a'},
      );
      expect(result['error_kind'], TunnelErrorKinds.tunnelDown);
    });
  });

  group('spawn 命令行：执行器必须能"自觉结束"', () {
    test('总是显式带 --idle-timeout-ms（不由 agent 的缺省 0=永不 决定）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      expect(remote.spawned.single, contains('--idle-timeout-ms $kAgentIdleTimeoutMs'));
    });

    test('静默上限必须大于 ping 间隔（否则健康通道也会被饿死）', () {
      expect(
        kAgentIdleTimeoutMs,
        greaterThan(kAgentPingInterval.inMilliseconds),
        reason: 'agent 每收到一帧就重置静默计时，而插件一直在 ping；'
            '上限小于间隔就会出现"健康的 agent 被自己饿死"',
      );
    });
  });

  group('保活：agent 卡死（进程在、不回帧）', () {
    test('通道健康 ⇒ ping 有响应，永不重建', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      expect(remote.dials, 1);

      for (int i = 0; i < 5; i++) {
        firePing();
        await pump(6);
      }
      expect(remote.dials, 1, reason: '健康通道不该被打散');
      expect(tunnel.state, TunnelStates.ready);
      // 每拍成功都排下一拍（保活是"自调度"，不是一次性的）
      expect(timers.pending.any((FakeTimer t) => t.duration == kAgentPingInterval), isTrue);
    });

    test('连续 $kAgentPingMissLimit 拍无响应 ⇒ 拆掉重建（后台任务不受影响）', () async {
      remote.silentMethods.add(AgentMethods.ping);
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      expect(remote.dials, 1);

      await beatWithNoResponse();
      await beatWithNoResponse();
      expect(remote.dials, 1, reason: '不到限额不重建（容忍抖动）');
      await beatWithNoResponse();
      await pump(6);

      // 到额 ⇒ 判通道已死 ⇒ 退避首拍
      expect(tunnel.state, TunnelStates.reconnecting);
      timers.fireNext();
      await pump(10);
      expect(remote.dials, 2, reason: '卡死的通道必须被真的换掉');
      expect(tunnel.state, TunnelStates.ready);
    });

    test('reconnect：ready 但 agent 不回帧 ⇒ **真的**重建（不再是 no-op）', () async {
      remote.silentMethods.add(AgentMethods.ping);
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      expect(remote.dials, 1);

      final Future<void> done = tunnel.reconnect();
      await pump(6);
      // 探针 ping 发出去没人回 ⇒ 等它超时
      firePingTimeout();
      await pump(10);
      await done;

      expect(remote.dials, 2, reason: '核心判失活后调 reconnect，必须能换掉卡死的 agent');
      expect(tunnel.state, TunnelStates.ready);
    });

    test('reconnect：通道健康 ⇒ 不动它（显式重连 ≠ 强制重建）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      await tunnel.reconnect();
      expect(remote.dials, 1);
      expect(tunnel.state, TunnelStates.ready);
    });
  });

  group('重建前收掉上一世 agent（用户：不该在目标机上累积）', () {
    test('链路断后重连 ⇒ 按一次性 token 核对并 kill 上一世 pid', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      expect(remote.spawned.length, 1);

      remote.lastChannel!.kill();
      await pump(6);
      expect(tunnel.state, TunnelStates.reconnecting);
      timers.fireNext(); // 退避首拍
      await pump(10);

      expect(remote.dials, 2);
      expect(
        remote.reapedPids,
        contains(4242),
        reason: '假 agent 的 hello 自报 pid=4242；重建前应当收掉它',
      );
    });

    test('清理命令**永远**带 token 守卫（不存在无条件 kill）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      remote.lastChannel!.kill();
      await pump(6);
      timers.fireNext();
      await pump(10);

      final List<String> kills = remote.commands
          .where((String c) => c.contains('kill 4242'))
          .toList();
      expect(kills, isNotEmpty);
      for (final String command in kills) {
        expect(command, contains('/proc/4242/cmdline'));
        expect(
          command,
          contains('grep -qF --'),
          reason: '零误杀：核对不上就不许杀（pid 可能已被别的进程复用）',
        );
      }
    });

    test('token 核对不上 ⇒ 假远端回 not-ours，插件只记日志（不重试、不报错）', () async {
      remote.reapResponder = (int pid, String token) => 'not-ours';
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      remote.lastChannel!.kill();
      await pump(6);
      timers.fireNext();
      await pump(10);
      expect(tunnel.state, TunnelStates.ready, reason: '清理失败不该影响重建');
      expect(remote.dials, 2);
    });
  });
}
