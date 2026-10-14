import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/tool_call_card.dart';

/// 工具结果里的 **ANSI / VT 控制序列必须在显示时剥掉**（用户反馈：详情页里
/// pwsh / git 的彩色输出显示成乱码方块，`[32;1m` 还漏进正文）。
///
/// 口径是「执行层保留原始字节、展示层剥离」——喂给模型的文本与磁盘上的原始结果
/// 都不动，所以这里既测纯函数（剥离规则），也测详情页真正渲染出来的那一段
/// （顺带钉住代码块的字体回退栈，中英混排时中文不再落到随机系统字体）。
void main() {
  // 转义序列写成常量而不是内插，读用例时眼睛只落在正文上（ESC 本身不可见）
  const String boldGreen = '\x1b[32;1m';
  const String yellow = '\x1b[33m';
  const String reset = '\x1b[0m';
  const String csiNoParam = '\x1b[m';
  const String escSingleChar = '\x1bM'; // ESC + 强字符（两字符转义）
  const String oscSetTitle = '\x1b]0;窗口标题\x1b\\'; // OSC … ST

  group('extractReadableResult：显示前剥控制序列', () {
    test('CSI 颜色序列整段去掉，正文与换行保留', () {
      final String out = extractReadableResult('$boldGreen成功$reset\n第二行');
      expect(out, '成功\n第二行');
      expect(out.contains('\x1b'), isFalse, reason: 'ESC 不能留给界面');
    });

    test('OSC（设置标题 / 超链接）序列也剥掉', () {
      expect(extractReadableResult('$oscSetTitle正文'), '正文');
    });

    test('两字符转义（ESC + 强字符）与无参 CSI 都剥掉', () {
      expect(
        extractReadableResult('$csiNoParam$escSingleChar正文'),
        '正文',
      );
    });

    test('JSON 结果的字段提取不受影响（仍然取 output）', () {
      // JSON 规范不允许裸 ESC，所以真·JSON 结果里它是 \u001b 转义形式
      expect(
        extractReadableResult('{"output": "\\u001b[33m警告\\u001b[0m"}'),
        '警告',
      );
    });

    test('裸 ESC 混进 JSON 导致解不开时，仍然剥掉转义（不崩、不把 ESC 留给界面）', () {
      final String out = extractReadableResult(
        '{"output": "$yellow警告$reset"}',
      );
      expect(out, '{"output": "警告"}');
      expect(out.contains('\x1b'), isFalse);
    });

    test('不含转义时原样返回（不误伤正文）', () {
      expect(extractReadableResult('普通输出\n第二行'), '普通输出\n第二行');
    });
  });

  testWidgets('详情页「执行结果」渲染出的文本没有 ESC，且用统一的中文字体回退', (
    WidgetTester tester,
  ) async {
    final ChatMessage message = ChatMessage(
      id: 't1',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026, 10, 14, 9),
      kind: 'tool',
      toolName: 'terminal',
      toolArguments: <String, dynamic>{'command': 'git status'},
      toolResult: '${boldGreen}On branch desktop$reset\n工作区干净',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolDetail(message: message, workspaceId: ''),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final SelectableText result = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere(
          (SelectableText t) =>
              (t.data ?? t.textSpan?.toPlainText() ?? '').contains(
                'On branch desktop',
              ),
        );
    final String shown = result.data ?? result.textSpan!.toPlainText();
    expect(
      shown,
      'On branch desktop\n工作区干净',
      reason: '彩色标记被剥掉，正文与换行原样保留',
    );
    expect(
      result.style?.fontFamilyFallback,
      contains('Microsoft YaHei'),
      reason: '汉字要有回退项（Consolas 不含中文字形），与全局正文同一套中文字体',
    );
  });
}
