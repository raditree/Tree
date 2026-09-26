import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'ws_harness.dart';

/// WS 发送路径的**心跳判活**用例（M9 规约 1.1：发送不做静态超时）。
///
/// 口径：`send` 写就写、不等 ack，也不设 TTL；判活看**连接心跳**（收到任意入站帧
/// 即续期，前端的 30s 保活帧就是最典型的一拍）。心跳丢失 ⇒ 判失活：显式上报
/// （错误日志）+ 关连接（触发前端自动重连）+ **断开期间的帧登记补发**，
/// 重连后原样补出去——绝不静默丢帧。
void main() {
  /// 轮询直到条件成立（超时给出可读原因）。
  Future<void> until(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 5),
    String reason = '条件',
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('超时等待$reason');
  }

  test('心跳丢失：显式上报 + 关连接（触发重连）+ 断开期间的帧登记补发（无静态 TTL）', () async {
    final List<String> logs = <String>[];
    final CoreServer server = await CoreServer.start(
      enableHeartbeat: true,
      heartbeatInterval: const Duration(milliseconds: 60),
      heartbeatMissLimit: 2,
      streamChunkDelay: Duration.zero,
    );
    addTearDown(server.close);
    server.errorLog = logs.add;
    final LivenessWsHub hub = server.hub as LivenessWsHub;
    expect(hub.interval, const Duration(milliseconds: 60));

    // 一个"在线但一声不吭"的客户端：连续 2 拍（≈120ms）被判失活
    final TestWs first = await TestWs.connect(server);
    addTearDown(first.close);
    await until(() => hub.staleConnectionCount >= 1, reason: '判失活（心跳丢失）');
    // 连接被判死后会被关掉；最后一个连接注销时全体台账同步判失活
    await until(() => hub.linkLiveness.isStale, reason: '全体连接台账失活');
    // 显式上报：不是静默地把连接扔掉
    expect(
      logs.any((String line) => line.contains('心跳丢失')),
      isTrue,
      reason: '判死必须写错误日志（可被主控/UI 看见）：$logs',
    );

    // 断开期间广播的帧：登记补发，而不是随连接一起消失
    hub.broadcast(<String, dynamic>{'type': 'message', 'content': '心跳丢了也不能丢我'});
    await until(() => hub.pendingResendCount >= 1, reason: '帧进入待补发队列');

    // 等远超判活窗口：补发队列**没有静态 TTL**，攒着不会过期作废
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(hub.pendingResendCount, greaterThanOrEqualTo(1));

    // 前端重连（新连接）：注册即补发
    final TestWs second = await TestWs.connect(server);
    second.record();
    addTearDown(second.close);
    await second.until(
      (Map<String, dynamic> f) =>
          f['type'] == 'message' && f['content'] == '心跳丢了也不能丢我',
      reason: '补发帧',
    );
    expect(hub.pendingResendCount, 0, reason: '补发完队列清空');
    expect(hub.totalFramesResent(), greaterThanOrEqualTo(1));
    expect(hub.linkLiveness.isAlive, isTrue, reason: '新连接注册即恢复');
  });

  test('心跳正常的空闲连接：不误判失活，帧立即可达（没有静态发送超时）', () async {
    final CoreServer server = await CoreServer.start(
      enableHeartbeat: true,
      heartbeatInterval: const Duration(milliseconds: 60),
      heartbeatMissLimit: 2,
      streamChunkDelay: Duration.zero,
    );
    addTearDown(server.close);
    final LivenessWsHub hub = server.hub as LivenessWsHub;

    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    // 模拟前端自己的保活（真实前端 30s 一拍；这里压到 30ms 让测试快）
    final Timer beats = Timer.periodic(
      const Duration(milliseconds: 30),
      (Timer _) => ws.send(<String, dynamic>{'type': 'heartbeat'}),
    );
    addTearDown(beats.cancel);
    ws.send(<String, dynamic>{'type': 'heartbeat'});

    // 跑过 5 个判活窗口：心跳一直在 ⇒ 永不判死（"总时长"不是判据）
    await Future<void>.delayed(const Duration(milliseconds: 320));
    expect(hub.staleConnectionCount, 0);
    expect(hub.pendingResendCount, 0, reason: '活链路上的帧不入队，直接写出去');
    expect(hub.connectionCount, 1);

    hub.broadcast(<String, dynamic>{'type': 'message', 'content': '立即送达'});
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == 'message' && f['content'] == '立即送达',
      reason: '正常帧',
    );
  });

  test('从未有前端连接：不累计丢失、不判失活（headless 不被卡住）', () async {
    final CoreServer server = await CoreServer.start(
      enableHeartbeat: true,
      heartbeatInterval: const Duration(milliseconds: 50),
      heartbeatMissLimit: 2,
      streamChunkDelay: Duration.zero,
    );
    addTearDown(server.close);
    final LivenessWsHub hub = server.hub as LivenessWsHub;

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hub.linkLiveness.isAlive, isTrue, reason: '没人在听 ≠ 心跳丢了');
    expect(hub.linkLiveness.lastBeatAt, isNull);
    expect(hub.pendingResendCount, 0);
  });

  test('关闭保活（enableHeartbeat: false）时行为与旧版一致：不判活、不入队', () async {
    final CoreServer server = await CoreServer.start(
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    addTearDown(server.close);
    final LivenessWsHub hub = server.hub as LivenessWsHub;

    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(hub.staleConnectionCount, 0);
    expect(hub.pendingResendCount, 0);
    hub.broadcast(<String, dynamic>{'type': 'message', 'content': '照常'});
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == 'message' && f['content'] == '照常',
      reason: '正常帧',
    );
  });
}
