import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';

void main() {
  group('Backoff 节奏', () {
    test('1s → 2s → 4s → … → 封顶 60s/次', () {
      final Backoff backoff = Backoff();
      final List<int> seconds = <int>[
        for (int i = 0; i < 8; i++) backoff.take()!.inSeconds,
      ];
      expect(seconds, <int>[1, 2, 4, 8, 16, 32, 60, 60]);
      expect(backoff.attempt, 8);
      expect(backoff.spent.inSeconds, 1 + 2 + 4 + 8 + 16 + 32 + 60 + 60);
    });

    test('延迟只由 attempt 决定（delayFor 与 take 一致）', () {
      final Backoff backoff = Backoff();
      expect(backoff.delayFor(0), const Duration(seconds: 1));
      expect(backoff.delayFor(5), const Duration(seconds: 32));
      expect(backoff.delayFor(9), const Duration(seconds: 60));
      expect(backoff.delayFor(-1), Duration.zero);
    });
  });

  group('Backoff 累计上限', () {
    test('再等一拍会顶破 maxTotal ⇒ 返回 null（调用方据此标 down）', () {
      final Backoff backoff = Backoff(maxTotal: const Duration(seconds: 10));
      expect(backoff.take(), const Duration(seconds: 1));
      expect(backoff.take(), const Duration(seconds: 2));
      expect(backoff.take(), const Duration(seconds: 4));
      // 累计 7s；下一拍 8s ⇒ 15s > 10s
      expect(backoff.take(), isNull);
      expect(backoff.spent, const Duration(seconds: 7));
      // 已经耗尽：再问还是 null（不会"悄悄又多等一次"）
      expect(backoff.take(), isNull);
    });

    test('默认上限 = 30 分钟：拍数有限、总时长不越界', () {
      final Backoff backoff = Backoff();
      int rounds = 0;
      while (backoff.take() != null) {
        rounds++;
        expect(rounds, lessThan(100), reason: '退避不该无限延续');
      }
      expect(backoff.spent, lessThanOrEqualTo(const Duration(minutes: 30)));
      // 30 分钟 / 60s ≈ 30 拍上下（前面几拍还是 1/2/4/8/16/32）
      expect(rounds, inInclusiveRange(30, 35));
    });
  });

  group('Backoff.reset', () {
    test('清零 attempt / spent（tunnel.reconnect 与建连成功都会调）', () {
      final Backoff backoff = Backoff(maxTotal: const Duration(seconds: 10));
      backoff.take();
      backoff.take();
      expect(backoff.take(), const Duration(seconds: 4));
      backoff.reset();
      expect(backoff.attempt, 0);
      expect(backoff.spent, Duration.zero);
      expect(backoff.take(), const Duration(seconds: 1));
    });

    test('maxTotal = 0 表示不设累计上限', () {
      final Backoff backoff = Backoff(maxTotal: Duration.zero);
      for (int i = 0; i < 50; i++) {
        expect(backoff.take(), isNotNull);
      }
      expect(backoff.spent.inMinutes, greaterThan(30));
    });
  });
}
