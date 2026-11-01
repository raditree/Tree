// F3 显示/详细两分（规格 §3.1.2/§3.1.3）：
//  - 列表端点回轻量**显示行**：tool_arguments/tool_result/usage/attachments 全空，
//    行正文靠写入侧预生成的 `preview`，寻址坐标 `agent_id/session_id` 随行；
//  - 右栏详情**点击即查**详情端点，快照升级为全量副本、**不缓存不回写**，
//    已查过的详情不许被 refresh 降级回显示行；
//  - 空正文的思考显示行要有可读的占位文案（不许渲染成空白行）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/services/detail_selection.dart';
import 'package:tree/ui/widgets/detail_panel.dart';
import 'package:tree/ui/widgets/thinking_card.dart';
import 'package:tree/ui/widgets/tool_call_card.dart';

/// 一条**工具显示行**：没有参数表、没有结果，只有 preview 与寻址坐标
ChatMessage toolDisplayRow({
  String id = 't1',
  String preview = 'lib/main.dart',
  String agentId = 'a1',
  String sessionId = 'session_default',
}) =>
    ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026, 11, 1),
      kind: 'tool',
      toolName: 'read',
      toolResult: '',
      preview: preview,
      agentId: agentId,
      sessionId: sessionId,
    );

/// 一条**思考显示行**：正文不随列表下发
ChatMessage thinkingDisplayRow({String id = 'k1'}) => ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026, 11, 1),
      kind: 'thinking',
      agentId: 'a1',
      sessionId: 'session_default',
    );

/// 全量详情副本（详情端点的响应形状）
Map<String, dynamic> toolDetailJson(String id) => <String, dynamic>{
      'id': id,
      'role': 'assistant',
      'content': '',
      'timestamp': DateTime(2026, 11, 1).millisecondsSinceEpoch,
      'kind': 'tool',
      'tool_name': 'read',
      'tool_arguments': <String, dynamic>{'file_path': 'lib/main.dart'},
      'tool_result': '第一行结果\n第二行结果',
      'agent_id': 'a1',
      'session_id': 'session_default',
    };

void main() {
  late Future<Map<String, dynamic>> Function(String, String, String)
      originalFetcher;

  setUp(() {
    originalFetcher = DetailSelection.detailFetcher;
    DetailSelection.instance.clear();
  });

  tearDown(() {
    DetailSelection.detailFetcher = originalFetcher;
    DetailSelection.instance.clear();
  });

  group('显示行解析与渲染', () {
    test('fromJson 解析 preview / agent_id / session_id（显示行的三件套）', () {
      final ChatMessage m = ChatMessage.fromJson(<String, dynamic>{
        'id': 't9',
        'role': 'assistant',
        'content': '',
        'timestamp': DateTime(2026, 11, 1).millisecondsSinceEpoch,
        'kind': 'tool',
        'tool_name': 'read',
        'preview': 'lib/main.dart',
        'agent_id': 'a1',
        'session_id': 'session_7',
      });
      expect(m.preview, 'lib/main.dart');
      expect(m.agentId, 'a1');
      expect(m.sessionId, 'session_7');
      // 显示行没有重负载字段
      expect(m.toolArguments, anyOf(isNull, isEmpty));
      expect(m.toolResult, isEmpty);
    });

    test('toolLineValue：显示行（无参数表）直接用 preview 当行正文', () {
      expect(toolLineValue(toolDisplayRow()), 'lib/main.dart',
          reason: '写入侧预生成的 preview 前移到渲染层（规格 §3.1.2）');
    });

    testWidgets('空正文的思考显示行渲染成「点击查看详情」占位（不留空白行）',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: <Widget>[
            ThinkingCard(message: thinkingDisplayRow()),
          ]),
        ),
      ));
      expect(find.text('点击查看详情'), findsOneWidget);
    });
  });

  group('点击即查详情（不缓存）', () {
    testWidgets('选中显示行 → 详情落地后快照升级成全量副本', (WidgetTester tester) async {
      final List<List<String>> calls = <List<String>>[];
      DetailSelection.detailFetcher = (String a, String id, String s) async {
        calls.add(<String>[a, id, s]);
        return toolDetailJson(id);
      };
      final ChatMessage row = toolDisplayRow();
      DetailSelection.instance.toggle(row);
      await tester.pumpAndSettle();

      expect(calls, <List<String>>[
        <String>['a1', 't1', 'session_default'],
      ], reason: '寻址坐标取自显示行本身（agent_id/messageId/session_id）');
      final ChatMessage? snapshot = DetailSelection.instance.message;
      expect(snapshot, isNotNull);
      expect(snapshot!.toolArguments, isNotNull, reason: '快照已升级为全量详情');
      expect(snapshot.toolResult, contains('第一行结果'));
    });

    testWidgets('已查详情的快照：refresh 不许把它降级回显示行', (WidgetTester tester) async {
      DetailSelection.detailFetcher =
          (String a, String id, String s) async => toolDetailJson(id);
      final ChatMessage row = toolDisplayRow();
      DetailSelection.instance.toggle(row);
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.message!.toolResult, isNotEmpty);

      // 消息流又刷了一帧：槽位表里它仍是显示行
      DetailSelection.instance.refresh(<ChatMessage>[row]);
      expect(DetailSelection.instance.message!.toolResult, isNotEmpty,
          reason: '用户正在看的详情不能被显示行顶掉（§3.1.3 不降级）');
    });

    testWidgets('再点一次取消选中：不残留、不再查', (WidgetTester tester) async {
      int calls = 0;
      DetailSelection.detailFetcher = (String a, String id, String s) async {
        calls++;
        return toolDetailJson(id);
      };
      final ChatMessage row = toolDisplayRow();
      DetailSelection.instance.toggle(row);
      await tester.pumpAndSettle();
      expect(calls, 1);

      DetailSelection.instance.toggle(row); // 再点 = 取消
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.message, isNull);
      expect(calls, 1, reason: '取消不该触发第二次查询');
    });

    testWidgets('在途消息（流式/工具在跑）不查库：内存里本来就是全量',
        (WidgetTester tester) async {
      int calls = 0;
      DetailSelection.detailFetcher = (String a, String id, String s) async {
        calls++;
        return toolDetailJson(id);
      };
      // 工具在跑
      DetailSelection.instance.toggle(ChatMessage(
        id: 'r1',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026, 11, 1),
        kind: 'tool',
        toolName: 'read',
        toolRunning: true,
        agentId: 'a1',
      ));
      // 流式思考
      DetailSelection.instance.toggle(ChatMessage(
        id: 'r2',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026, 11, 1),
        kind: 'thinking',
        isStreaming: true,
        agentId: 'a1',
      ));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: '查库反而拿旧快照顶掉实时内容（§3.1.3）');
    });

    testWidgets('查询失败静默停在显示行：不清空选中、不弹错', (WidgetTester tester) async {
      DetailSelection.detailFetcher =
          (String a, String id, String s) async => throw Exception('404');
      final ChatMessage row = toolDisplayRow();
      DetailSelection.instance.toggle(row);
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.message?.id, 't1',
          reason: '保持显示行快照（右栏显示头部与空正文）');
    });

    testWidgets('详情页把升级后的完整结果摊开', (WidgetTester tester) async {
      DetailSelection.detailFetcher =
          (String a, String id, String s) async => toolDetailJson(id);
      DetailSelection.instance.toggle(toolDisplayRow());
      await tester.pumpAndSettle();

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: DetailPanel())),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('第一行结果'), findsWidgets,
          reason: '右栏详情显示的是即查回来的全量正文');
    });
  });
}
