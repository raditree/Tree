import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/thinking_card.dart';

/// 巨型 thinking 的每帧成本封顶测试（分块增量渲染）
///
/// thinking 单段可到 10 万+ 字（实测 102,871），而它不走气泡路径：
/// 消息流里是一行 ThinkingCard、右栏是 ThinkingDetail。旧实现每来一截增量：
/// - thinkingSummary 对全文 split + 两遍正则（摘要只显示前 80 字）；
/// - ThinkingDetail 的 MarkdownBody 拿全量文本做全文重解析 + 重排版。
/// 现在：摘要只扫头部窗口；详情全量在场，但按 ~6000 字定居成缓存块，
/// 只有尾块每帧重画。这里钉住窗口口径、定居不变量与「历史一个字不丢」。
void main() {
  /// 旧实现（全文版）：窗口内的文本必须与新实现逐字一致
  String legacySummary(String text) {
    final String line = text
        .split('\n')
        .firstWhere((String l) => l.trim().isNotEmpty, orElse: () => text)
        .trim();
    final String cleaned = line
        .replaceAll(RegExp(r'[#*`>|-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned;
  }

  group('thinkingSummary：只扫头部窗口', () {
    test('窗口内的文本：与旧全文实现逐字一致', () {
      for (final String t in <String>[
        '第一行就是摘要',
        '\n\n  \n## 带标记的标题\n正文第二段',
        'x' * 500,
        '短首行\n' + 'y' * 400,
      ]) {
        expect(thinkingSummary(t), legacySummary(t), reason: '输入: $t');
      }
    });

    test('单行 10 万字巨型段：摘要 = 前 80 字 + …（与全文长度无关）', () {
      final String s = thinkingSummary('A' * 100000);
      expect(s, '${'A' * 80}…');
    });

    test('首行超窗口时只取窗口内的行：结果仍不超过 80 字 + …', () {
      final String s = thinkingSummary('${'B' * 600}\nC');
      expect(s, '${'B' * 80}…');
    });
  });

  group('ThinkingDetail：分块增量，历史全量在场', () {
    Future<void> pumpDetail(WidgetTester tester, ChatMessage m) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ThinkingDetail(message: m)),
          ),
        ),
      );
      await tester.pump();
    }

    List<String> bodies(WidgetTester tester) => tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .map((MarkdownBody b) => b.data!)
        .toList();

    ChatMessage thinking(
      String content, {
      required bool streaming,
      String id = 't',
    }) => ChatMessage(
      id: id,
      role: 'agent',
      content: content,
      timestamp: DateTime(2026, 10, 15),
      isStreaming: streaming,
      kind: 'thinking',
    );

    testWidgets('多行巨型段：切成多块，拼起来 = 全文（回滚可读，一个字不丢）', (
      WidgetTester tester,
    ) async {
      final String huge =
          List<String>.generate(2000, (int i) => '第${i}行 思考内容 xoxo').join('\n');
      await pumpDetail(tester, thinking(huge, streaming: true));
      final List<String> blocks = bodies(tester);
      expect(blocks.length, greaterThan(2), reason: '3.5 万字必须定居成多块');
      expect(
        blocks.map((String b) => b.length).reduce((int a, int b) => a > b ? a : b),
        lessThanOrEqualTo(ThinkingDetail.tailCharsCap + 100),
        reason: '每块（含每帧重画的尾块）封顶在常数',
      );
      expect(blocks.join(''), huge);
      expect(
        blocks.last,
        endsWith('第1999行 思考内容 xoxo'),
        reason: '尾块必须含最新到达的内容',
      );
    });

    testWidgets('单行 10 万字无换行：硬切成多块，且不切出半个字符', (
      WidgetTester tester,
    ) async {
      final String huge = '\u{1F600}' * 50000; // 10 万 code unit
      await pumpDetail(tester, thinking(huge, streaming: true));
      final List<String> blocks = bodies(tester);
      expect(blocks.length, greaterThan(2));
      expect(blocks.join(''), huge);
      for (final String b in blocks) {
        for (int i = 0; i < b.length; i++) {
          final int cu = b.codeUnitAt(i);
          if (cu >= 0xD800 && cu <= 0xDBFF) {
            expect(
              b.codeUnitAt(i + 1),
              inInclusiveRange(0xDC00, 0xDFFF),
              reason: '孤立高代理 @#$i',
            );
            i++;
          } else {
            expect(
              cu >= 0xDC00 && cu <= 0xDFFF,
              isFalse,
              reason: '孤立低代理 @$i（硬切点没让位）',
            );
          }
        }
      }
    });

    testWidgets('定居块 = 同一个 widget 实例：新内容到达不碰旧块', (
      WidgetTester tester,
    ) async {
      final ChatMessage m = thinking(
        List<String>.generate(2000, (int i) => '行$i').join('\n'),
        streaming: true,
      );
      await pumpDetail(tester, m);
      final List<MarkdownBody> first = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .toList();
      expect(first.length, greaterThan(1));
      m.content += '\n' + 'x' * ThinkingDetail.blockChars;
      await pumpDetail(tester, m);
      final List<MarkdownBody> second = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .toList();
      // 前 n-1 块实例同一（Flutter 对同实例短路 ⇒ 零重解析零重排版）；
      // 最后一块可能因「尾块转正」换实例，不在比较口径内。
      for (int i = 0; i < first.length - 1; i++) {
        expect(
          identical(first[i], second[i]),
          isTrue,
          reason: '第 $i 块定居后又被人动过',
        );
      }
    });

    testWidgets('围栏未闭合：不拿半截代码定居，全部留尾块', (
      WidgetTester tester,
    ) async {
      // 开围栏在头部，候选切点里围栏数是奇 → hold（remaining 未超 cap）
      final String body = 'a' * 500 + '\n```\n' + 'b' * ThinkingDetail.blockChars;
      final ChatMessage m = thinking('$body\n', streaming: true);
      await pumpDetail(tester, m);
      final List<String> blocks = bodies(tester);
      expect(blocks.length, 1, reason: 'remaining ≤ cap 且开围栏 ⇒ 不许定居');
      expect(blocks.single, '${m.content}');
    });

    testWidgets('巨型代码块冲破硬顶：强制定居，每块围栏数成对', (
      WidgetTester tester,
    ) async {
      final String code =
          List<String>.generate(5000, (int i) => 'code $i').join('\n');
      final ChatMessage m = thinking('```\n$code\n', streaming: true);
      await pumpDetail(tester, m);
      final List<String> blocks = bodies(tester);
      expect(blocks.length, greaterThan(2), reason: '超过 cap 必须硬制定居');
      // 定居块（除每帧重画的尾块）围栏必须自洽；尾块允许开着
      for (final String b in blocks.take(blocks.length - 1)) {
        int fences = 0;
        int i = b.indexOf('```');
        while (i >= 0) {
          fences++;
          i = b.indexOf('```', i + 3);
        }
        expect(fences.isEven, isTrue, reason: '块内围栏必须自洽：$fences 个');
      }
      // 合成围栏只影响渲染口径，正文一字不丢：抹掉围栏与换行后两边对拼
      String strip(String s) => s.replaceAll('```', '').replaceAll('\n', '');
      final String joined = blocks.join('');
      expect(strip(joined), strip(m.content));
    });

    testWidgets('封口：余量全部定居，再重建零重解析（实例全同一）', (
      WidgetTester tester,
    ) async {
      final ChatMessage m = thinking(
        List<String>.generate(1000, (int i) => '行$i').join('\n'),
        streaming: true,
      );
      await pumpDetail(tester, m);
      m.content += '\n最后一小截';
      m.isStreaming = false;
      await pumpDetail(tester, m);
      final List<MarkdownBody> sealed = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .toList();
      expect(
        find.text('思考中…（内容还在追加）'),
        findsNothing,
        reason: '封口即撤流式横幅',
      );
      await pumpDetail(tester, m);
      final List<MarkdownBody> again = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .toList();
      expect(again.length, sealed.length);
      for (int i = 0; i < again.length; i++) {
        expect(identical(again[i], sealed[i]), isTrue, reason: '第 $i 块被重画了');
      }
      expect(
        again.map((MarkdownBody b) => b.data!).join(''),
        m.content,
        reason: '全量内容都在，历史可读',
      );
    });

    testWidgets('切到另一条消息：缓存整体作废，不留上一段的块', (
      WidgetTester tester,
    ) async {
      final ChatMessage a = thinking(
        List<String>.generate(2000, (int i) => 'A行$i').join('\n'),
        streaming: false,
      );
      await pumpDetail(tester, a);
      expect(bodies(tester).length, greaterThan(1));
      final ChatMessage b = thinking('B 只有一小段', streaming: false, id: 'u');
      await pumpDetail(tester, b);
      final List<String> blocks = bodies(tester);
      expect(blocks.length, 1);
      expect(blocks.single, 'B 只有一小段');
    });

    testWidgets('短正文：就一块尾块，无多余定居', (WidgetTester tester) async {
      await pumpDetail(tester, thinking('想了一下下', streaming: true));
      final List<String> blocks = bodies(tester);
      expect(blocks.length, 1);
      expect(blocks.single, '想了一下下');
    });
  });
}
