import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/message_window.dart';

/// 中栏窗口坐标（用户 2026-10-03：「计算当前窗口在整个历史中的坐标，右侧拇指位置按坐标计算」）：
/// - [MessageWindowCoordinate]：视口在整份历史里的坐标（滑块几何 + 补页/淘汰的唯一口径）；
/// - [pixelOffsetForIndex]：坐标 → 滚动像素（以视口第一条为锚点，占位区 88px/条）；
/// - [MessageSeekCorrection]：拖拽落点的反馈校正（占位区精确、已加载区靠观测收误差）；
/// - [splitGapAtViewportTop]：缺口横跨视口顶时切开（否则上方长高会把视口推走）。
void main() {
  group('MessageWindowCoordinate', () {
    test('未知坐标：视口条数为 0，不指任何下标', () {
      const MessageWindowCoordinate c = MessageWindowCoordinate.unknown;
      expect(c.known, isFalse);
      expect(c.visible, 0);
      expect(c.containsIndex(0), isFalse);
      expect(c.lastSeekable, 0);
    });

    test('可见条数与"能指到的最靠后下标"（看到末尾 = 贴底）', () {
      const MessageWindowCoordinate c = MessageWindowCoordinate(
        first: 90,
        last: 99,
        total: 100,
      );
      expect(c.visible, 10);
      expect(c.lastSeekable, 90, reason: 'total - 看得见的条数');
      expect(c.containsIndex(90), isTrue);
      expect(c.containsIndex(89), isFalse);
    });

    test('总条数比视口还小时：lastSeekable 夹在表内', () {
      const MessageWindowCoordinate c = MessageWindowCoordinate(
        first: 0,
        last: 3,
        total: 4,
      );
      expect(c.lastSeekable, 0);
    });

    test('相等性按三个字段（去重上报靠它）', () {
      const MessageWindowCoordinate a = MessageWindowCoordinate(
        first: 1,
        last: 5,
        total: 10,
      );
      expect(
        a,
        const MessageWindowCoordinate(first: 1, last: 5, total: 10),
      );
      expect(
        a == const MessageWindowCoordinate(first: 1, last: 6, total: 10),
        isFalse,
      );
    });
  });

  group('pixelOffsetForIndex（坐标 → 像素）', () {
    const MessageWindowCoordinate at = MessageWindowCoordinate(
      first: 100,
      last: 110,
      total: 1000,
    );

    test('以视口第一条为锚点：往更早的下标走 = 减去步长', () {
      expect(
        pixelOffsetForIndex(
          index: 100,
          at: at,
          anchorPixels: 8800,
          step: 88,
        ),
        8800,
      );
      expect(
        pixelOffsetForIndex(
          index: 50,
          at: at,
          anchorPixels: 8800,
          step: 88,
        ),
        8800 - 50 * 88,
      );
      expect(
        pixelOffsetForIndex(
          index: 120,
          at: at,
          anchorPixels: 8800,
          step: 88,
        ),
        8800 + 20 * 88,
      );
    });

    test('坐标未知时退回朴素的 下标 × 步长', () {
      expect(
        pixelOffsetForIndex(
          index: 300,
          at: MessageWindowCoordinate.unknown,
          anchorPixels: 12345,
          step: 88,
        ),
        300 * 88,
      );
    });
  });

  group('MessageSeekCorrection（落点反馈校正）', () {
    test('已经落在容差内：直接收工，不再跳', () {
      final MessageSeekCorrection c = MessageSeekCorrection(target: 500, step: 88);
      expect(c.observe(landed: 502, pixels: 44000), isNull);
      expect(c.finished, isTrue);
      expect(c.attempts, 0);
    });

    test('步长正确时：一次校正即到位', () {
      final MessageSeekCorrection c = MessageSeekCorrection(target: 500, step: 88);
      // 当前落在 460，目标 500 ⇒ 还差 40 条 = 3520px
      final double? next = c.observe(landed: 460, pixels: 40480);
      expect(next, 40480 + 40 * 88);
      // 按它跳过去之后落在目标上了
      expect(c.observe(landed: 500, pixels: next!), isNull);
      expect(c.finished, isTrue);
    });

    test('步长估错时：用两点反推真实步长（已加载区 ≈ 真实高度）', () {
      final MessageSeekCorrection c = MessageSeekCorrection(target: 500, step: 88);
      // 第一次：按 88/条 估，跳过去只落到 470（真实步长 150/条）
      final double? first = c.observe(landed: 400, pixels: 35200);
      expect(first, 35200 + 100 * 88);
      // 观测到"请求 44000 却落在 470" ⇒ 反推真实步长 (44000-35200)/(470-400) = 125.7
      final double? second = c.observe(landed: 470, pixels: 35200 + 100 * 88);
      expect(second, isNotNull);
      expect(c.step, closeTo((44000 - 35200) / 70, 0.001));
      // 第二次跳完落在 500（在第二次观测里给出来）
      expect(c.observe(landed: 500, pixels: second!), isNull);
      expect(c.finished, isTrue);
    });

    test('跳不动了（落点与像素都没变）：收手，不空转', () {
      final MessageSeekCorrection c = MessageSeekCorrection(target: 500, step: 88);
      expect(c.observe(landed: 300, pixels: 26400), isNotNull);
      expect(c.observe(landed: 300, pixels: 26400), isNull);
      expect(c.finished, isTrue);
    });

    test('最多校正 maxAttempts 次', () {
      final MessageSeekCorrection c = MessageSeekCorrection(
        target: 500,
        step: 88,
        maxAttempts: 2,
      );
      expect(c.observe(landed: 100, pixels: 8800), isNotNull);
      expect(c.observe(landed: 200, pixels: 26400), isNotNull);
      expect(c.observe(landed: 300, pixels: 44000), isNull, reason: '第三次不再跳');
      expect(c.attempts, 2);
      expect(c.finished, isTrue);
    });
  });

  group('splitGapAtViewportTop（缺口按视口顶切开）', () {
    test('缺口横跨视口顶：先补视口及以下，再补视口上方', () {
      expect(
        splitGapAtViewportTop(const MessageRange(300, 721), 500),
        <MessageRange>[
          const MessageRange(500, 721),
          const MessageRange(300, 500),
        ],
      );
    });

    test('整段在视口上方 / 下方 / 与视口顶重合：不切', () {
      expect(
        splitGapAtViewportTop(const MessageRange(100, 500), 500),
        <MessageRange>[const MessageRange(100, 500)],
      );
      expect(
        splitGapAtViewportTop(const MessageRange(600, 900), 500),
        <MessageRange>[const MessageRange(600, 900)],
      );
      expect(
        splitGapAtViewportTop(const MessageRange(500, 900), 500),
        <MessageRange>[const MessageRange(500, 900)],
      );
    });

    test('空缺口：丢掉（不产出空请求）', () {
      expect(
        splitGapAtViewportTop(const MessageRange(5, 5), 3),
        isEmpty,
      );
    });
  });
}
