import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/ssh_connection_manager.dart';

/// 并发闸（SshConnectionManager.runWithSlot / _TeamGate）行为验证：
///
/// 1. 并发上限：同时执行数不超过注入上限，其余排队，最终全部执行完成；
/// 2. 排队超时自清理：槽位被长期占用时，排队项超时自动移出队列并抛
///    TimeoutException（不永久驻留）；释放槽位后新的请求可立即拿到槽位
///    （证明超时项没有残留占用队列/槽位）。
void main() {
  group('SshConnectionManager.runWithSlot 并发闸', () {
    test('超过并发上限时排队，且不超出上限、全部执行完成', () async {
      final SshConnectionManager manager = SshConnectionManager();
      const String team = 'gate-test-cap';
      const int max = 3;
      const int total = 9;
      int running = 0;
      int peakRunning = 0;
      int finished = 0;
      final List<Completer<void>> barriers = <Completer<void>>[];

      final List<Future<void>> tasks = List<Future<void>>.generate(total, (i) {
        final Completer<void> barrier = Completer<void>();
        barriers.add(barrier);
        return manager.runWithSlot(
          team,
          () async {
            running++;
            if (running > peakRunning) {
              peakRunning = running;
            }
            await barrier.future;
            running--;
            finished++;
            return;
          },
          maxConcurrent: max,
        );
      });

      // 等第一批到达后，逐个放行，观察并发被限制在 max 内
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(running, lessThanOrEqualTo(max));
      // 逐个放行直到全部结束（第 i 个完成才会轮到第 i+3 个）
      for (final Completer<void> barrier in barriers) {
        barrier.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      await Future.wait(tasks);
      expect(finished, total);
      expect(peakRunning, lessThanOrEqualTo(max));
    });

    test('排队超时自动移出队列：不永久驻留，释放槽位后新请求立即可执行', () async {
      final SshConnectionManager manager = SshConnectionManager();
      const String team = 'gate-test-timeout';
      final Completer<void> release = Completer<void>();

      // 占用唯一槽位（长期不释放）
      final Future<String> busy = manager.runWithSlot(
        team,
        () async {
          await release.future;
          return 'busy-done';
        },
        maxConcurrent: 1,
        queueWait: const Duration(milliseconds: 150),
      );

      // 排队项在 queueWait 内拿不到槽位 → 应抛 TimeoutException 而非永久等待
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        manager.runWithSlot(
          team,
          () async => 'should-not-run',
          maxConcurrent: 1,
          queueWait: const Duration(milliseconds: 150),
        ),
        throwsA(isA<TimeoutException>()),
      );

      // 释放槽位后，新请求应立刻拿到槽位并执行（说明超时项已从队列移除，
      // 没有残留 waiter 在释放时抢先/占位）
      release.complete();
      final String result = await manager.runWithSlot(
        team,
        () async => 'fresh-ok',
        maxConcurrent: 1,
        queueWait: const Duration(milliseconds: 150),
      );
      expect(result, 'fresh-ok');
      expect(await busy, 'busy-done');
    });
    test('让位不会造成并发能力永久衰减（多波满额验证无漂移）', () async {
      final SshConnectionManager manager = SshConnectionManager();
      const String team = 'gate-test-no-drift';
      const int max = 3;
      const int waves = 10;

      for (int w = 0; w < waves; w++) {
        int running = 0;
        int peak = 0;
        final Completer<void> barrier = Completer<void>();
        final List<Future<void>> tasks = List<Future<void>>.generate(max, (_) {
          return manager.runWithSlot(
            team,
            () async {
              running++;
              if (running > peak) peak = running;
              await barrier.future;
              running--;
              return;
            },
            maxConcurrent: max,
          );
        });
        await Future<void>.delayed(const Duration(milliseconds: 60));
        // 每一波都应能立即满额并发：若让位导致 _active 漂移（每让位一次永久
        // -1），后续波次的并发能力会逐波下降，峰值将 < max（排队者因 barrier
        // 阻塞无法启动）
        expect(peak, max, reason: '第 $w 波并发峰值应保持满额 $max');
        barrier.complete();
        await Future.wait(tasks);
        expect(running, 0);
      }

      // 全部结束后闸应回到空闲：新请求立即执行，不受历史让位次数影响
      final DateTime start = DateTime.now();
      await manager.runWithSlot(team, () async {}, maxConcurrent: max);
      expect(DateTime.now().difference(start).inMilliseconds,
          lessThan(200));
    });

    test('纯让位链计数不漂移（max=1 连续让位后容量恢复）', () async {
      final SshConnectionManager manager = SshConnectionManager();
      const String team = 'gate-test-handoff-chain';
      const int max = 1;
      const int cycles = 20;

      for (int i = 0; i < cycles; i++) {
        final Completer<void> barrier = Completer<void>();
        // 占住唯一槽位
        final Future<void> holder = manager.runWithSlot(
          team,
          () async {
            await barrier.future;
            return;
          },
          maxConcurrent: max,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // 此刻必然排队（槽位已满），构成一次真实"让位"
        final Future<void> queued = manager.runWithSlot(
          team,
          () async {},
          maxConcurrent: max,
          queueWait: const Duration(seconds: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        barrier.complete(); // holder 让位给 queued
        await Future.wait(<Future<void>>[holder, queued]);
      }

      // 若让位导致 _active 漂移（无论 +1 还是 -1），20 次后空闲闸将无法恢复：
      // 新请求会排队或能力受损。验证新的请求立即可执行。
      final DateTime start = DateTime.now();
      await manager.runWithSlot(team, () async {}, maxConcurrent: max);
      expect(DateTime.now().difference(start).inMilliseconds,
          lessThan(200));
    });
  });
}
