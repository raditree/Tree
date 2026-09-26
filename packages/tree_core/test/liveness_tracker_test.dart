import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// [LivenessTracker] 的单测（M9 规约 1.1：取消静态时间超时，改「心跳丢失」判超时）。
///
/// 判据是「心跳丢了」而不是「总时长超了」：这里用注入时钟与手工的 recordMiss /
/// recordBeat 把两种情形钉死——跑得久但心跳在 = 活着；心跳连续丢 = 失活
/// （在途操作显式失败，不静默、不永久挂起）。
void main() {
  test('默认 I=10s、N=3，且都可配', () {
    final LivenessTracker link = LivenessTracker();
    expect(link.interval, const Duration(seconds: 10));
    expect(link.maxMisses, 3);
    expect(link.isAlive, isTrue, reason: '刚建立时按活着算');
    expect(link.lastBeatAt, isNull);
    expect(link.missedCount, 0);
    expect(
      link.staleWindow,
      const Duration(seconds: 30),
      reason: '判活窗口 = I × N',
    );

    final LivenessTracker custom = LivenessTracker(
      label: 'WS 连接',
      interval: const Duration(seconds: 2),
      maxMisses: 5,
    );
    expect(custom.interval, const Duration(seconds: 2));
    expect(custom.maxMisses, 5);
    expect(custom.staleWindow, const Duration(seconds: 10));
    expect(custom.label, 'WS 连接');
  });

  test('连续 N 次丢失才判失活；成功一次立刻清零', () {
    final LivenessTracker link = LivenessTracker(maxMisses: 3);
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
    final LivenessTracker link = LivenessTracker(clock: () => stamp);
    link.recordBeat();
    expect(link.lastBeatAt, stamp);
    // 显式传入的时间优先（多路心跳汇总时用）
    final DateTime other = DateTime(2026, 6, 1);
    link.recordBeat(other);
    expect(link.lastBeatAt, other);
  });

  test('ensureAlive：活着不抛，失活抛带「心跳丢失」「链路失活」的显式错误', () {
    final LivenessTracker link = LivenessTracker(maxMisses: 1);
    link.ensureAlive();
    link.recordMiss();
    expect(
      link.ensureAlive,
      throwsA(
        isA<LivenessLostException>().having(
          (LivenessLostException e) => e.message,
          'message',
          allOf(contains('心跳丢失'), contains('链路失活'), contains('心跳间隔 10s')),
        ),
      ),
    );
  });

  group('guard 三分支', () {
    test('在途操作遇失活：以显式错误失败，不永久挂起', () async {
      final LivenessTracker link = LivenessTracker(maxMisses: 2);
      final Completer<void> never = Completer<void>();
      final Future<void> pending = link.guard(() => never.future);
      link.recordMiss();
      link.recordMiss();
      await expectLater(pending, throwsA(isA<LivenessLostException>()));
      expect(link.isStale, isTrue);
      expect(never.isCompleted, isFalse, reason: '底层操作不被取消，只是不再等待');
    });

    test('操作先完成：正常返回并记一次心跳', () async {
      final LivenessTracker link = LivenessTracker(maxMisses: 2);
      link.recordMiss();
      final int value = await link.guard(() async => 42);
      expect(value, 42);
      expect(link.missedCount, 0, reason: '成功的响应也算心跳');
      expect(link.lastBeatAt, isNotNull);
    });

    test('已失活：立刻失败，且根本不发起操作', () async {
      final LivenessTracker link = LivenessTracker(maxMisses: 1);
      link.recordMiss();
      bool started = false;
      await expectLater(
        link.guard(() async {
          started = true;
          return 1;
        }),
        throwsA(isA<LivenessLostException>()),
      );
      expect(started, isFalse);
    });
  });

  test('watchStale：失活时唤醒在途信号，注销后不再被唤醒', () async {
    final LivenessTracker link = LivenessTracker(maxMisses: 1);
    final Completer<void> kept = link.watchStale();
    final Completer<void> dropped = link.watchStale();
    link.unwatchStale(dropped);
    link.recordMiss();
    await kept.future;
    expect(kept.isCompleted, isTrue);
    expect(dropped.isCompleted, isFalse, reason: '注销过的信号不该再被唤醒');
  });

  test('reset：清除失活标记与心跳时间（重连接管）', () {
    final LivenessTracker link = LivenessTracker(maxMisses: 1);
    link.recordBeat();
    link.recordMiss();
    expect(link.isStale, isTrue);
    link.reset();
    expect(link.isStale, isFalse);
    expect(link.lastBeatAt, isNull);
    link.ensureAlive();
  });

  test('失活后心跳恢复：操作重新可用（不主动中断）', () async {
    final LivenessTracker link = LivenessTracker(maxMisses: 1);
    link.recordMiss();
    await expectLater(
      link.guard(() async => 1),
      throwsA(isA<LivenessLostException>()),
    );
    link.recordBeat();
    expect(await link.guard(() async => 7), 7);
  });

  test('心跳正常的长操作：跑得远超判活窗口也不被打断', () async {
    // I=40ms、N=3 ⇒ 判活窗口 120ms；操作跑 240ms（两个窗口），期间每 10ms 一拍心跳
    final LivenessTracker link = LivenessTracker(
      interval: const Duration(milliseconds: 40),
      maxMisses: 3,
    );
    final Timer beats = Timer.periodic(
      const Duration(milliseconds: 10),
      (Timer _) => link.recordBeat(),
    );
    addTearDown(beats.cancel);

    final String result = await link.guard(() async {
      await Future<void>.delayed(const Duration(milliseconds: 240));
      return '跑完了';
    });
    expect(result, '跑完了');
    expect(link.isStale, isFalse, reason: '心跳一直在 ⇒ 跑多久都不算超时');
    expect(link.missedCount, 0);
  });
}
