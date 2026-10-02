import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 启动期外设预热（MCP / 插件）的三条硬语义：**并行**、**有界**、**绝不抛**。
///
/// 为什么值得单独测：核心进程的握手被外设拖住时，用户看到的是
/// 「核心进程未能启动（等待握手超时 25s）」——现场在用户机器上，日志在 stderr，
/// 没有这几条断言就只能靠猜。见 docs/known-issues.md #13。
void main() {
  test('并行：总时长取最大，而不是各任务求和', () async {
    final Stopwatch sw = Stopwatch()..start();
    final List<String> log = <String>[];
    final WarmUpReport report = await warmUpPeripherals(
      <WarmUpTask>[
        (
          name: 'A',
          run: () => Future<void>.delayed(const Duration(milliseconds: 200)),
        ),
        (
          name: 'B',
          run: () => Future<void>.delayed(const Duration(milliseconds: 200)),
        ),
        (
          name: 'C',
          run: () => Future<void>.delayed(const Duration(milliseconds: 200)),
        ),
      ],
      budget: const Duration(seconds: 5),
      log: log.add,
    );
    sw.stop();
    expect(report.complete, isTrue);
    expect(report.settled, hasLength(3));
    expect(report.pending, isEmpty);
    expect(report.failures, isEmpty);
    // 串行会是 600ms 起；给足调度余量后仍必须明显低于它（并行才有这个结果）
    expect(
      sw.elapsedMilliseconds,
      lessThan(550),
      reason: '外设预热没有并行：\${sw.elapsedMilliseconds}ms',
    );
    expect(log.where((String m) => m.contains('就绪')), hasLength(3));
  });

  test('有界：超预算立即返回，未结束的任务继续在后台跑', () async {
    final Completer<void> never = Completer<void>();
    final List<String> log = <String>[];
    final Stopwatch sw = Stopwatch()..start();
    final WarmUpReport report = await warmUpPeripherals(
      <WarmUpTask>[
        (
          name: '快',
          run: () => Future<void>.delayed(const Duration(milliseconds: 20)),
        ),
        (name: '慢', run: () => never.future),
      ],
      budget: const Duration(milliseconds: 150),
      log: log.add,
    );
    sw.stop();
    expect(report.complete, isFalse);
    expect(report.pending, <String>['慢']);
    expect(report.settled, <String>['快']);
    expect(
      sw.elapsedMilliseconds,
      lessThan(1200),
      reason: '超预算没有立即返回：\${sw.elapsedMilliseconds}ms',
    );
    expect(
      log.any((String m) => m.contains('预算') && m.contains('慢')),
      isTrue,
      reason: '超预算必须显式记日志：\$log',
    );
    // 后台任务结束时照常打自己的日志（不是被丢弃的野 future）
    never.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(log.where((String m) => m.contains('慢 就绪')), hasLength(1));
  });

  test('绝不抛：单个任务失败只记日志，不影响其它任务', () async {
    final List<String> log = <String>[];
    final WarmUpReport report = await warmUpPeripherals(
      <WarmUpTask>[
        (name: '坏插件', run: () => Future<void>.error(StateError('协议不认'))),
        (
          name: '好插件',
          run: () => Future<void>.delayed(const Duration(milliseconds: 20)),
        ),
      ],
      budget: const Duration(seconds: 5),
      log: log.add,
    );
    expect(report.complete, isTrue);
    expect(report.failures['坏插件'], contains('协议不认'));
    expect(report.settled, hasLength(2));
    expect(log.any((String m) => m.contains('坏插件') && m.contains('预热失败')), isTrue);
    expect(log.any((String m) => m.contains('好插件 就绪')), isTrue);
  });

  test('空清单：不报错、不等待', () async {
    final WarmUpReport report = await warmUpPeripherals(const <WarmUpTask>[]);
    expect(report.complete, isTrue);
    expect(report.settled, isEmpty);
  });
}
