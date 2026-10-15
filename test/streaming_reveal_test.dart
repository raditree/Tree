import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 流式平滑揭示（_MessageBubble 的 Ticker 时钟）行为测试
///
/// 用户 2026-10-15 报告：生成方一慢，界面更新帧率就跟着掉——旧实现「来一帧画
/// 一次」，显示帧率被钉死在增量到达帧率上。新实现把揭示进度交给 Ticker 逐帧
/// 追赶：这里钉住三件事——
/// ① 一次性到达的增量**不整块跳出**，后续帧里逐帧生长；
/// ② 积压会在有限时间内收敛到全量（不许永久滞后）；
/// ③ 中途挂上直接给全、封口后停时钟并交还 markdown 渲染。
void main() {
  Future<GlobalKey<_RevealHarnessState>> pumpHarness(
    WidgetTester tester,
    ChatMessage message,
  ) async {
    final GlobalKey<_RevealHarnessState> key = GlobalKey<_RevealHarnessState>();
    await tester.pumpWidget(_RevealHarness(key: key, message: message));
    // 第一拍只建立时钟基准（不出字），第二拍起才推进揭示
    await tester.pump(const Duration(milliseconds: 16));
    return key;
  }

  /// 取流式气泡正文（RichText 第一个 span；光标独显阶段返回空串）
  String streamedBody(WidgetTester tester) {
    for (final RichText rt in tester.widgetList<RichText>(find.byType(RichText))) {
      final InlineSpan span = rt.text;
      if (span is TextSpan && span.children?.length == 2) {
        return (span.children![0] as TextSpan).text ?? '';
      }
    }
    // 尚未揭示出任何字符：只剩光标位（Text('|') / Text(' ')）
    return '';
  }

  testWidgets('慢速 trickle：正文逐帧生长，而不是在增量到达那一帧整块跳出', (
    WidgetTester tester,
  ) async {
    final ChatMessage msg = ChatMessage(
      id: 'slow',
      role: 'agent',
      content: '',
      timestamp: DateTime(2026, 10, 15),
      isStreaming: true,
    );
    final GlobalKey<_RevealHarnessState> key = await pumpHarness(tester, msg);

    // 一次性到达 20 字（模拟生成方憋了很久才吐出一大截）
    key.currentState!.append('一二三四五六七八九十十一十二十三十四');
    await tester.pump(const Duration(milliseconds: 16));
    final String afterFirst = streamedBody(tester);
    expect(
      afterFirst.length,
      lessThan(20),
      reason: '增量到达后第一帧就该把没揭示的部分继续留在账上逐帧放',
    );

    // 再打几帧：正文确实在逐帧生长（显示更新不靠下一截增量来催）
    await tester.pump(const Duration(milliseconds: 112));
    expect(streamedBody(tester).length, greaterThan(afterFirst.length));

    // 有限时间内收敛到全量：不许形成永久滞后
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(streamedBody(tester), '一二三四五六七八九十十一十二十三十四');
  });

  testWidgets('中途挂上：已到达的正文全量显示，只对之后的增量做追赶', (
    WidgetTester tester,
  ) async {
    final ChatMessage msg = ChatMessage(
      id: 'resume',
      role: 'agent',
      content: '切走期间已经写好的正文',
      timestamp: DateTime(2026, 10, 15),
      isStreaming: true,
    );
    final GlobalKey<_RevealHarnessState> key = await pumpHarness(tester, msg);
    expect(
      streamedBody(tester),
      msg.content,
      reason: '重切回来不把整段话重打一遍打字机',
    );

    // 挂上之后的新增量才走逐帧揭示
    key.currentState!.append('新到的一截');
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      streamedBody(tester).length,
      lessThan(msg.content.length),
      reason: '新到的那截要从揭示进度里逐帧放出来',
    );
  });

  testWidgets('封口（msg_end）：立即全量交还，不再有光标/揭示时钟', (
    WidgetTester tester,
  ) async {
    final ChatMessage msg = ChatMessage(
      id: 'seal',
      role: 'agent',
      content: '',
      timestamp: DateTime(2026, 10, 15),
      isStreaming: true,
    );
    final GlobalKey<_RevealHarnessState> key = await pumpHarness(tester, msg);
    key.currentState!.append('收尾正文收尾正文收尾正文');
    // 不收口，让积压还在账上，然后直接封口
    key.currentState!.seal();
    await tester.pump();

    // 光标形态（正文 + 光标两个 span 的 RichText）应当消失：封口后走 markdown
    bool cursorSpanAlive = false;
    for (final RichText rt in tester.widgetList<RichText>(find.byType(RichText))) {
      final InlineSpan span = rt.text;
      if (span is TextSpan && span.children?.length == 2) {
        cursorSpanAlive = true;
      }
    }
    expect(
      cursorSpanAlive,
      isFalse,
      reason: '封口即全量显示并交还 markdown 渲染，揭示时钟必须停表',
    );
    // Ticker 停表后没有常驻帧：pumpAndSettle 能收敛（若时钟还在会永远转不完）
    await tester.pumpAndSettle();
  });
}

/// 测试宿主：持有一条流式消息，提供增量追加 / 封口两个动作
class _RevealHarness extends StatefulWidget {
  const _RevealHarness({super.key, required this.message});

  final ChatMessage message;

  @override
  State<_RevealHarness> createState() => _RevealHarnessState();
}

class _RevealHarnessState extends State<_RevealHarness> {
  int _revision = 0;

  /// 模拟面板的 msg_chunk：原地追加正文（与 message_panel 的写入口径一致）
  void append(String chunk) {
    setState(() {
      widget.message.content += chunk;
      _revision++;
    });
  }

  /// 模拟面板的 msg_end：封口
  void seal() {
    setState(() {
      widget.message.isStreaming = false;
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: MessageList(
          slots: <ChatMessage?>[widget.message],
          revision: _revision,
        ),
      ),
    );
  }
}
