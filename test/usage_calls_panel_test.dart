import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/usage_calls_panel.dart';

/// 「本轮调用列表」折叠面板：既锁**解析**（实时帧 usage map 与 usage.jsonl 行两种
/// 形态归一），也锁**渲染与交互**（默认折叠、点标题展开、null ≠ 0、千分位、
/// 秒/毫秒、估算标记、maxRows 截断）。
void main() {
  // —— 常用样本 ——
  // 实时帧形态：没有 source / model / at / duration_ms。
  final Map<String, dynamic> liveFrame = <String, dynamic>{
    'prompt_tokens': 4096,
    'completion_tokens': 128,
    'total_tokens': 4224,
    'max_tokens': 8192,
    'cached_tokens': 1024,
    'estimated': true,
    'trimmed_messages': 2,
  };
  // 落库形态（usage.jsonl 的一行）：cached_tokens 为 null = 端点没报这个字段。
  final Map<String, dynamic> storedRow = <String, dynamic>{
    'at': '2026-10-03T17:04:05.123Z',
    'source': 'compact',
    'model': 'claude-opus-4.7',
    'prompt_tokens': 12000,
    'cached_tokens': null,
    'completion_tokens': 800,
    'estimated': false,
    'duration_ms': 1830,
  };

  group('UsageCallView.fromUsage', () {
    test('实时帧形态：缺 source/model/at/duration_ms → turn/空串/null/null', () {
      final UsageCallView view = UsageCallView.fromUsage(liveFrame);
      expect(view.source, 'turn');
      expect(view.model, '');
      expect(view.promptTokens, 4096);
      expect(view.completionTokens, 128);
      expect(view.cachedTokens, 1024);
      expect(view.estimated, isTrue);
      expect(view.durationMs, isNull);
      expect(view.at, isNull);
    });

    test('实时帧没带 cached_tokens → null（不是 0）', () {
      final UsageCallView view = UsageCallView.fromUsage(<String, dynamic>{
        'prompt_tokens': 100,
        'completion_tokens': 5,
      });
      expect(view.cachedTokens, isNull);
      expect(view.estimated, isFalse);
    });

    test('usage.jsonl 行形态：at 解 ISO、cached_tokens null、duration_ms 保留', () {
      final UsageCallView view = UsageCallView.fromUsage(storedRow);
      expect(view.at, DateTime.utc(2026, 10, 3, 17, 4, 5, 123));
      expect(view.source, 'compact');
      expect(view.model, 'claude-opus-4.7');
      expect(view.promptTokens, 12000);
      expect(view.cachedTokens, isNull, reason: 'null 表示端点没报，不能变成 0');
      expect(view.completionTokens, 800);
      expect(view.estimated, isFalse);
      expect(view.durationMs, 1830);
    });

    test('source 缺失 / 为 null / 空白 → 一律 turn', () {
      expect(UsageCallView.fromUsage(<String, dynamic>{}).source, 'turn');
      expect(
        UsageCallView.fromUsage(<String, dynamic>{'source': null}).source,
        'turn',
      );
      expect(
        UsageCallView.fromUsage(<String, dynamic>{'source': '   '}).source,
        'turn',
      );
    });

    test('数值容错：int / double / 字符串数字 都能读', () {
      final UsageCallView view = UsageCallView.fromUsage(<String, dynamic>{
        'prompt_tokens': '1234',
        'completion_tokens': 12.0,
        'cached_tokens': ' 7 ',
        'duration_ms': '1800',
        'estimated': 'true',
      });
      expect(view.promptTokens, 1234);
      expect(view.completionTokens, 12);
      expect(view.cachedTokens, 7);
      expect(view.durationMs, 1800);
      expect(view.estimated, isTrue);
    });

    test('脏数据不抛异常：读不出一律退默认值', () {
      final UsageCallView view = UsageCallView.fromUsage(<String, dynamic>{
        'source': 7,
        'model': 42,
        'prompt_tokens': <String>[],
        'completion_tokens': null,
        'cached_tokens': '',
        'duration_ms': 'abc',
        'at': 'not-a-date',
        'estimated': <String>[],
      });
      expect(view.source, 'turn');
      expect(view.model, '');
      expect(view.promptTokens, 0);
      expect(view.completionTokens, 0);
      expect(view.cachedTokens, isNull);
      expect(view.durationMs, isNull);
      expect(view.at, isNull);
      expect(view.estimated, isFalse);
    });

    test('at 为 null / 缺失 → null', () {
      expect(
        UsageCallView.fromUsage(<String, dynamic>{'at': null}).at,
        isNull,
      );
      expect(UsageCallView.fromUsage(<String, dynamic>{}).at, isNull);
    });
  });

  group('UsageCallView.fromUsages', () {
    test('逐项解析并跳过非 Map 项（顺序保持不变）', () {
      final List<UsageCallView> views = UsageCallView.fromUsages(<Object?>[
        <String, dynamic>{'source': 'turn', 'prompt_tokens': 1},
        null,
        'oops',
        42,
        <dynamic, dynamic>{'source': 'plugin', 'prompt_tokens': 2},
      ]);
      expect(views.length, 2);
      expect(views[0].source, 'turn');
      expect(views[0].promptTokens, 1);
      expect(views[1].source, 'plugin');
      expect(views[1].promptTokens, 2);
    });

    test('空输入 → 空列表', () {
      expect(UsageCallView.fromUsages(const <Object?>[]), isEmpty);
    });
  });

  group('UsageCallsPanel', () {
    const UsageCallView turnCall = UsageCallView(
      source: 'turn',
      model: 'qwen3-coder',
      promptTokens: 1234,
      cachedTokens: 12,
      completionTokens: 345,
      durationMs: 832,
    );
    const UsageCallView pluginCall = UsageCallView(
      source: 'llm.call',
      model: 'gpt-5.5',
      promptTokens: 777,
      completionTokens: 88,
      estimated: true,
      durationMs: 1800,
    );

    Future<void> pumpPanel(
      WidgetTester tester, {
      required List<UsageCallView> calls,
      bool initiallyExpanded = false,
      int maxRows = 0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: UsageCallsPanel(
                calls: calls,
                initiallyExpanded: initiallyExpanded,
                maxRows: maxRows,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('默认折叠：行内容不可见，点标题后展开', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[turnCall, pluginCall],
      );

      expect(find.text('本轮调用列表（2 次）'), findsOneWidget);
      expect(find.text('来源'), findsNothing);
      expect(find.text('对话'), findsNothing);
      expect(find.text('暂无调用记录'), findsNothing);

      await tester.tap(find.textContaining('本轮调用列表'));
      await tester.pumpAndSettle();

      expect(find.text('来源'), findsNWidgets(2));
      expect(find.text('对话'), findsOneWidget);
      expect(find.text('插件 llm.call'), findsOneWidget);

      // 再点一次收起
      await tester.tap(find.textContaining('本轮调用列表'));
      await tester.pumpAndSettle();
      expect(find.text('来源'), findsNothing);
    });

    testWidgets('initiallyExpanded: true 直接可见', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[turnCall],
        initiallyExpanded: true,
      );
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('1,234'), findsOneWidget);
    });

    testWidgets('每行显示 来源/输入/缓存命中/输出/耗时 五项', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[turnCall, pluginCall],
        initiallyExpanded: true,
      );

      expect(find.text('来源'), findsNWidgets(2));
      expect(find.text('输入'), findsNWidgets(2));
      expect(find.text('缓存命中'), findsNWidgets(2));
      expect(find.text('输出'), findsNWidgets(2));
      expect(find.text('耗时'), findsNWidgets(2));

      // 第一条：输入千分位 / 缓存命中 12 / 输出 / 耗时毫秒
      expect(find.text('1,234'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('345'), findsOneWidget);
      expect(find.text('832ms'), findsOneWidget);
    });

    testWidgets('estimated: true 的行有可见「估算」标记', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[turnCall, pluginCall],
        initiallyExpanded: true,
      );
      // 只有 pluginCall 是估算，标记恰好一个
      expect(find.textContaining('估算'), findsOneWidget);
      expect(find.text('估算'), findsOneWidget);
    });

    testWidgets('cached_tokens: null 显示 —，cached_tokens: 12 显示 12', (
      WidgetTester tester,
    ) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[
          turnCall, // cached 12
          pluginCall, // cached null → —
        ],
        initiallyExpanded: true,
      );
      expect(find.text('12'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('耗时：>=1000ms 折成秒，null 显示 —', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[
          UsageCallView(
            source: 'turn',
            promptTokens: 1234567,
            cachedTokens: 7,
            durationMs: 1830,
          ),
          // 缓存命中与输入都给得出值，这样 `—` 只可能来自耗时
          UsageCallView(source: 'plugin', cachedTokens: 3, durationMs: null),
        ],
        initiallyExpanded: true,
      );
      expect(find.text('1,234,567'), findsOneWidget);
      expect(find.text('1.8s'), findsOneWidget);
      expect(find.text('—'), findsOneWidget); // 第二条的耗时（cached 是 7 / 3，不是 —）
    });

    testWidgets('来源文案映射：四种 + 未知原样', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[
          UsageCallView(source: 'turn'),
          UsageCallView(source: 'compact'),
          UsageCallView(source: 'llm.call'),
          UsageCallView(source: 'plugin'),
          UsageCallView(source: 'whatever'),
        ],
        initiallyExpanded: true,
      );
      expect(find.text('对话'), findsOneWidget);
      expect(find.text('内置压缩'), findsOneWidget);
      expect(find.text('插件 llm.call'), findsOneWidget);
      expect(find.text('插件接管'), findsOneWidget);
      expect(find.text('whatever'), findsOneWidget);
    });

    testWidgets('maxRows 截断：只显示最后 N 条并在标题里体现', (WidgetTester tester) async {
      final List<UsageCallView> calls = <UsageCallView>[
        for (int i = 1; i <= 5; i++)
          UsageCallView(
            source: 'turn',
            promptTokens: i * 100,
            completionTokens: i,
            durationMs: 100 * i,
          ),
      ];
      await pumpPanel(
        tester,
        calls: calls,
        maxRows: 3,
        initiallyExpanded: true,
      );

      expect(find.textContaining('本轮调用列表'), findsOneWidget);
      expect(find.textContaining('最近 3 次'), findsOneWidget);
      expect(find.text('共 5 次'), findsOneWidget);
      expect(find.text('来源'), findsNWidgets(3));

      // 最后三条（300/400/500）在，前两条不在
      expect(find.text('500'), findsOneWidget);
      expect(find.text('400'), findsOneWidget);
      expect(find.text('300'), findsOneWidget);
      expect(find.text('100'), findsNothing);
      expect(find.text('200'), findsNothing);
    });

    testWidgets('maxRows 大于条数时不截断、标题无「最近」', (WidgetTester tester) async {
      await pumpPanel(
        tester,
        calls: const <UsageCallView>[turnCall, pluginCall],
        maxRows: 5,
        initiallyExpanded: true,
      );
      expect(find.text('本轮调用列表（2 次）'), findsOneWidget);
      expect(find.textContaining('最近'), findsNothing);
      expect(find.text('来源'), findsNWidgets(2));
    });

    testWidgets('空列表：标题（0 次），展开后显示 暂无调用记录', (
      WidgetTester tester,
    ) async {
      await pumpPanel(tester, calls: const <UsageCallView>[]);

      expect(find.text('本轮调用列表（0 次）'), findsOneWidget);
      expect(find.text('暂无调用记录'), findsNothing, reason: '折叠时不该出现在树里');

      await tester.tap(find.textContaining('本轮调用列表'));
      await tester.pumpAndSettle();

      expect(find.text('暂无调用记录'), findsOneWidget);
      expect(find.text('来源'), findsNothing);
    });
  });
}
