import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// [SshLiveness] 的单测（M9 1.1 判据修正）。
///
/// 判据是"心跳丢了"而不是"任务总时长超了"：这里用注入的时钟与手工的
/// recordMiss/recordBeat 把两种情形钉死——跑得久但心跳在 = 活着；心跳连续丢 =
/// 失活（在途操作显式失败，不静默、不永久挂起）。
void main() {
  test('默认 I=10s、N=3，且都可配', () {
    final SshLiveness link = SshLiveness();
    expect(link.interval, const Duration(seconds: 10));
    expect(link.maxMisses, 3);
    expect(link.isAlive, isTrue, reason: '刚建立时按活着算');
    expect(link.lastBeatAt, isNull);
    expect(link.missedCount, 0);

    final SshLiveness custom = SshLiveness(
      interval: const Duration(seconds: 2),
      maxMisses: 5,
    );
    expect(custom.interval, const Duration(seconds: 2));
    expect(custom.maxMisses, 5);
  });

  test('连续 N 次丢失才判失活；成功一次立刻清零', () {
    final SshLiveness link = SshLiveness(maxMisses: 3);
    expect(link.recordMiss(), isFalse);
    expect(link.recordMiss(), isFalse);
    expect(link.isStale, isFalse, reason: '还没到阈值');
    expect(link.recordMiss(), isTrue);
    expect(link.isStale, isTrue);
    expect(link.missedCount, 3);

    link.recordBeat();
    expect(link.isStale, isFalse);
    expect(link.missedCount, 0);
    expect(link.lastBeatAt, isNotNull);
  });

  test('lastBeatAt 可观测：注入时钟决定取值', () {
    final DateTime stamp = DateTime(2026, 1, 2, 3, 4, 5);
    final SshLiveness link = SshLiveness(clock: () => stamp);
    link.recordBeat();
    expect(link.lastBeatAt, stamp);
  });

  test('ensureAlive：活着不抛，失活抛带"心跳丢失"的显式错误', () {
    final SshLiveness link = SshLiveness(maxMisses: 1);
    link.ensureAlive();
    link.recordMiss();
    expect(
      link.ensureAlive,
      throwsA(
        isA<SshLinkStaleException>().having(
          (SshLinkStaleException e) => e.message,
          'message',
          allOf(contains('心跳丢失'), contains('链路失活')),
        ),
      ),
    );
  });

  test('guard：在途操作遇失活以显式错误失败，不永久挂起', () async {
    final SshLiveness link = SshLiveness(maxMisses: 2);
    final Completer<void> never = Completer<void>();
    final Future<void> pending = link.guard(() => never.future);
    link.recordMiss();
    link.recordMiss();
    await expectLater(pending, throwsA(isA<SshLinkStaleException>()));
    expect(link.isStale, isTrue);
    expect(never.isCompleted, isFalse, reason: '底层操作不被取消，只是不再等待');
  });

  test('guard：操作先完成则正常返回并记一次心跳', () async {
    final SshLiveness link = SshLiveness(maxMisses: 2);
    link.recordMiss();
    final int value = await link.guard(() async => 42);
    expect(value, 42);
    expect(link.missedCount, 0, reason: '成功的读/写响应也算心跳');
    expect(link.lastBeatAt, isNotNull);
  });

  test('guard：已失活时立刻失败，且根本不发起操作', () async {
    final SshLiveness link = SshLiveness(maxMisses: 1);
    link.recordMiss();
    bool started = false;
    await expectLater(
      link.guard(() async {
        started = true;
        return 1;
      }),
      throwsA(isA<SshLinkStaleException>()),
    );
    expect(started, isFalse);
  });

  test('watchStale：失活时唤醒在途信号，注销后不再被唤醒', () async {
    final SshLiveness link = SshLiveness(maxMisses: 1);
    final Completer<void> kept = link.watchStale();
    final Completer<void> dropped = link.watchStale();
    link.unwatchStale(dropped);
    link.recordMiss();
    await kept.future;
    expect(kept.isCompleted, isTrue);
    expect(dropped.isCompleted, isFalse, reason: '注销过的信号不该再被唤醒');
  });

  test('reset：重连成功后清除失活标记与心跳时间', () {
    final SshLiveness link = SshLiveness(maxMisses: 1);
    link.recordBeat();
    link.recordMiss();
    expect(link.isStale, isTrue);
    link.reset();
    expect(link.isStale, isFalse);
    expect(link.lastBeatAt, isNull);
    link.ensureAlive();
  });

  test('失活后心跳恢复：操作重新可用（不主动关连接）', () async {
    final SshLiveness link = SshLiveness(maxMisses: 1);
    link.recordMiss();
    expect(
      () => link.guard(() async => 1),
      throwsA(isA<SshLinkStaleException>()),
    );
    link.recordBeat();
    expect(await link.guard(() async => 7), 7);
  });

  test('onStale：跨过阈值那一拍通知一次，连续丢失不重复通知', () {
    int notified = 0;
    final SshLiveness link = SshLiveness(
      maxMisses: 3,
      onStale: () => notified++,
    );
    link.recordMiss();
    link.recordMiss();
    expect(notified, 0, reason: '还没到阈值');
    link.recordMiss();
    expect(notified, 1, reason: '判失活的那一拍通知（传输层据此起重连）');
    link.recordMiss();
    link.recordMiss();
    expect(notified, 1, reason: '同一次失活只通知一次，否则会反复起循环');
    link.recordBeat();
    link.recordMiss();
    link.recordMiss();
    expect(notified, 1);
    link.recordMiss();
    expect(notified, 2, reason: '恢复之后再次跨过阈值要能再通知一次');
  });

  test('onStale 可在建好后挂载（connect() 里就是这么挂的）', () {
    int notified = 0;
    final SshLiveness link = SshLiveness(maxMisses: 1);
    link.onStale = () => notified++;
    link.recordMiss();
    expect(notified, 1);
  });

  test('staleMessage：如实说"不会自行恢复"（旧连接不会自己活回来）', () {
    final SshLiveness link = SshLiveness(maxMisses: 3);
    for (int i = 0; i < 3; i++) {
      link.recordMiss();
    }
    final String message = link.staleMessage;
    expect(message, contains('心跳丢失'));
    expect(message, contains('链路失活'));
    expect(message, contains('不会自行恢复'));
    expect(message, contains('重连'));
    expect(
      message,
      isNot(contains('自动恢复')),
      reason: '旧文案"心跳恢复后自动恢复"是误导：2026-10-05 现场连丢 1325 拍、远端可达却再没恢复过',
    );
  });
}
