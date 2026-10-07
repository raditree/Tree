import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 「链路级故障 → 后台重建」这条路的单测（2026-10-07）。
///
/// 现场：心跳（SSH global request，不占 channel）一直有回包 ⇒ 判活通过、
/// `isStale == false`；但服务端开始**拒绝新的 session 通道**
/// （`SSHChannelOpenError(2: open failed)`）。于是文件浏览（SFTP 通道建连时就已开、
/// 一直复用）还好，git 历史 / terminal 工具（每次**新开** exec 通道）全挂，
/// 而判死判据只看心跳 ⇒ 自动重连**永远不触发**，故障持续 5 小时到重启为止。
///
/// [SshLinkFaultRelay] 补的就是这一段。与 [SshReconnectPump] 一样是纯策略，
/// 所以这里能用假 attempt / 假 sleep 把「幂等 / 单飞 / 成功后清标记 / clear 后不再试 /
/// 失败按退避继续」全部钉死；真建连那几行照旧只能靠门控真机（边界同 ssh_reconnect_test）。
///
/// **注意**：这些用例**不自己调 `pump.start()`**——只调 `report` 再等后台循环自己跑完。
/// 否则「report 根本没拉起重连」也会绿，等于没钉住接线（把 report 里的 start 去掉必须变红）。
void main() {
  late SshLinkFaultRelay relay;
  late SshReconnectPump pump;
  late List<String> logs;
  late List<String> events;
  int attempts = 0;

  /// 沿用 `ssh_reconnect_test.dart` 的接缝：假 attempt + 假 sleep + 单拍退避。
  SshReconnectPump newPump(Future<void> Function() attempt) => SshReconnectPump(
    attempt: attempt,
    backoff: const <Duration>[Duration.zero],
    sleep: (Duration _) async {},
    // 与生产接线同构：stillNeeded 额外认「链路级故障标记」（生产里还有 isStale）。
    stillNeeded: () => relay.faulted,
    onEvent: events.add,
  );

  /// 等后台重连循环自己跑完（不等真时间——假 sleep 只在微任务上让出）。
  Future<void> drain() async {
    for (int i = 0; i < 200; i++) {
      if (!pump.running && !pump.inFlight) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('后台重连循环没有收敛（running=${pump.running} inFlight=${pump.inFlight}）');
  }

  setUp(() {
    attempts = 0;
    logs = <String>[];
    events = <String>[];
    pump = newPump(() async => attempts++);
    relay = SshLinkFaultRelay(pump: pump, log: logs.add);
  });

  test('一次上报就拉起重连；成功后清标记', () async {
    expect(relay.faulted, isFalse);
    relay.report(SSHChannelOpenError(2, 'open failed'));
    expect(relay.faulted, isTrue, reason: '上报之后必须进"故障中"状态');
    expect(relay.reports, 1);

    await drain(); // 只等 report 拉起的那个后台循环
    expect(attempts, 1, reason: 'report 必须自己把重连拉起来（不靠调用方补一刀）');
    expect(events.single, contains('成功'));

    // clear 由 DartSshTransport 在「换会话成功之后」调用（不是 relay 自己）。
    relay.clear();
    expect(relay.faulted, isFalse);
  });

  test('故障期间重复上报只记数，重建仍只有一次在途（不会被每次失败放大）', () async {
    relay.report(SSHChannelOpenError(2, 'open failed'));
    relay.report(SSHChannelOpenError(2, 'open failed'));
    relay.report(SSHChannelOpenError(2, 'open failed'));
    expect(relay.reports, 3);

    await drain();
    expect(attempts, 1, reason: '三次上报只能落成一次重建（单飞）');
  });

  test('首次失败不弃权：按退避继续试到成功', () async {
    pump = newPump(() async {
      attempts++;
      if (attempts < 3) throw StateError('建连失败');
    });
    relay = SshLinkFaultRelay(pump: pump, log: logs.add);

    relay.report(SSHChannelOpenError(2, 'open failed'));
    await drain();

    expect(attempts, 3);
    expect(events.where((String e) => e.contains('失败')), hasLength(2));
    expect(events.last, contains('成功'));
  });

  test('close 之后（pump.stop）不再拉起重建', () async {
    pump.stop();
    relay.report(SSHChannelOpenError(2, 'open failed'));
    await drain();
    expect(attempts, 0, reason: '关停后不该再建连');
  });

  test('clear 之后后台循环发现"不需要了"即退出，不再尝试', () async {
    relay.report(SSHChannelOpenError(2, 'open failed'));
    expect(relay.faulted, isTrue);
    relay.clear(); // 模拟"重建已在别处成功"
    expect(relay.faulted, isFalse);

    await drain();
    expect(attempts, 0);
  });

  test('日志只在首次上报时喊一次（不要每次失败都刷屏）', () {
    relay.report(SSHChannelOpenError(2, 'open failed'));
    relay.report(SSHChannelOpenError(2, 'open failed'));
    relay.report(SSHChannelOpenError(2, 'open failed'));
    expect(logs, hasLength(1));
    expect(logs.single, contains('链路级故障'));
    expect(logs.single, contains('open failed'));
  });
}
