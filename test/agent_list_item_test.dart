import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/widgets/agent_list_format.dart';

void main() {
  group('previewOf', () {
    test('剥离 markdown 标记：标题 / 列表 / 引用 / 强调 / 行内代码 / 链接', () {
      expect(previewOf('## 标题\n- 项 1\n- 项 2'), '标题 项 1 项 2');
      expect(previewOf('**加粗** 与 `代码`'), '加粗 与 代码');
      expect(previewOf('[链接](https://x)'), '链接');
      expect(previewOf('> 引用'), '引用');
    });

    test('代码块围栏被剥掉，正文保留', () {
      expect(previewOf('```\ncode\n``` 正文'), '正文');
    });

    test('空串 / 纯空白 → 暂无消息', () {
      expect(previewOf(''), '暂无消息');
      expect(previewOf('   \n  '), '暂无消息');
    });
  });

  group('relativeTime', () {
    // 固定参考时刻，避免用例随时间漂移
    final DateTime now = DateTime(2026, 10, 6, 14, 0, 0);

    test('null → 空串', () {
      expect(relativeTime(null, now: now), '');
    });

    test('未来 / 一分钟以内 → 刚刚', () {
      expect(relativeTime(now.add(const Duration(minutes: 1)), now: now), '刚刚');
      expect(relativeTime(now.subtract(const Duration(seconds: 30)), now: now), '刚刚');
    });

    test('一小时以内 → N 分钟前', () {
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5 分钟前');
      expect(relativeTime(now.subtract(const Duration(minutes: 59)), now: now), '59 分钟前');
    });

    test('同一天 → HH:MM', () {
      expect(relativeTime(DateTime(2026, 10, 6, 9, 5), now: now), '09:05');
    });

    test('昨天 → 昨天', () {
      expect(relativeTime(DateTime(2026, 10, 5, 20, 0), now: now), '昨天');
    });

    test('一周内 → 周X', () {
      // 2026-10-03 是周六
      expect(relativeTime(DateTime(2026, 10, 3, 12, 0), now: now), '周六');
    });

    test('今年更早 → M/D', () {
      expect(relativeTime(DateTime(2026, 8, 15, 12, 0), now: now), '8/15');
    });

    test('往年 → YYYY/M/D', () {
      expect(relativeTime(DateTime(2025, 12, 1, 12, 0), now: now), '2025/12/1');
    });
  });

  group('teamColorFor', () {
    test('同一 teamId 永远同色（不变量，别断言具体色值）', () {
      expect(teamColorFor('team-a'), teamColorFor('team-a'));
      expect(teamColorFor(''), teamColorFor(''));
    });

    test('不同 teamId 通常落到不同色', () {
      expect(teamColorFor('team-a'), isNot(teamColorFor('team-b')));
    });
  });
}