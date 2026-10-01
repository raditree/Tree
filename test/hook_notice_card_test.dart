import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/hook_notice_card.dart';

/// 后台任务（terminal hook）提示的**解析**与**专用渲染**。
///
/// 正文形态由核心的 `hookNotice()` 决定（`terminal_hooks.dart`），这里既锁解析
/// 结果，也锁"默认折叠、点开才看日志尾部"的交互——那正是它从"一坨等宽文本"
/// 变成可读卡片的关键。
void main() {
  const String successNotice =
      '[terminal hook] 后台命令已结束：cd packages/tree_core; dart test foo.dart\n'
      'task_id: hook_1790843170049_1｜退出码 0\n'
      '日志文件：.output/v9_full2_hook.log（用 read 查看完整输出）\n'
      '--- 日志尾部 ---\n'
      '00:32 +709 ~1: All tests passed!\n'
      '[terminal hook] 结束：退出码 0，耗时 36s';

  const String failureNotice =
      '[terminal hook] 后台命令已结束：npm run build\n'
      'task_id: hook_1｜退出码 1\n'
      '日志文件：.self/hooks/build.log（用 read 查看完整输出）';

  group('parseHookNotice', () {
    test('成功提示：命令 / task_id / 退出码 / 日志路径 / 日志尾部', () {
      final HookNotice n = parseHookNotice(successNotice);
      expect(n.finished, isTrue);
      expect(n.command, 'cd packages/tree_core; dart test foo.dart');
      expect(n.taskId, 'hook_1790843170049_1');
      expect(n.exitCode, 0);
      expect(n.cancelled, isFalse);
      expect(n.logPath, '.output/v9_full2_hook.log', reason: '要去掉括号里的说明');
      expect(n.tail, contains('All tests passed!'));
      expect(n.tail, contains('耗时 36s'));
      expect(n.summary, '[terminal hook] 结束：退出码 0，耗时 36s');
    });

    test('失败提示：退出码 1，无日志尾部时 summary 退回命令行', () {
      final HookNotice n = parseHookNotice(failureNotice);
      expect(n.finished, isTrue);
      expect(n.exitCode, 1);
      expect(n.tail, isEmpty);
      expect(n.summary, 'npm run build');
    });

    test('已取消：退出码与「（已取消）」都认得', () {
      final HookNotice n = parseHookNotice(
        '[terminal hook] 后台命令已结束：sleep 100\n'
        'task_id: hook_2｜退出码 -1（已取消）\n'
        '日志文件：.self/hooks/a.log（用 read 查看完整输出）',
      );
      expect(n.finished, isTrue);
      expect(n.exitCode, -1);
      expect(n.cancelled, isTrue);
    });

    test('不是 hook 形态（例如别的系统提示）：finished=false，正文原样保留', () {
      final HookNotice n = parseHookNotice('模型端点返回 HTTP 400：xxx');
      expect(n.finished, isFalse);
      expect(n.raw, '模型端点返回 HTTP 400：xxx');
      expect(n.command, isEmpty);
    });
  });

  group('HookNoticeCard 渲染', () {
    ChatMessage message(String content) => ChatMessage(
      id: 'm1',
      role: 'agent',
      content: content,
      timestamp: DateTime(2026, 10, 1, 16, 26),
      kind: 'notice',
    );

    Future<void> pump(WidgetTester tester, String content) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HookNoticeCard(message: message(content)),
            ),
          ),
        ),
      );
    }

    testWidgets('成功：状态头 + 一行摘要；日志尾部默认不展开', (WidgetTester tester) async {
      await pump(tester, successNotice);

      expect(find.text('后台任务已完成（退出码 0）'), findsOneWidget);
      expect(
        find.text('cd packages/tree_core; dart test foo.dart'),
        findsOneWidget,
      );
      expect(find.text('[terminal hook] 结束：退出码 0，耗时 36s'), findsOneWidget);
      expect(find.text('日志尾部'), findsNothing, reason: '默认折叠：正文不该占屏');
      expect(find.textContaining('All tests passed!'), findsNothing);
    });

    testWidgets('点击展开：出现命令全文、日志尾部与 task_id/日志路径', (WidgetTester tester) async {
      await pump(tester, successNotice);

      await tester.tap(find.text('后台任务已完成（退出码 0）'));
      await tester.pumpAndSettle();

      expect(find.text('日志尾部'), findsOneWidget);
      expect(find.textContaining('All tests passed!'), findsOneWidget);
      expect(find.text('task_id: hook_1790843170049_1'), findsOneWidget);
      expect(find.text('日志：.output/v9_full2_hook.log'), findsOneWidget);
    });

    testWidgets('失败：红色语义的状态头（退出码 1）', (WidgetTester tester) async {
      await pump(tester, failureNotice);
      expect(find.text('后台任务失败（退出码 1）'), findsOneWidget);
    });

    testWidgets('已取消：状态头说"已取消"', (WidgetTester tester) async {
      await pump(
        tester,
        '[terminal hook] 后台命令已结束：sleep 100\n'
        'task_id: hook_2｜退出码 -1（已取消）\n'
        '日志文件：.self/hooks/a.log（用 read 查看完整输出）',
      );
      expect(find.text('后台任务已取消（退出码 -1）'), findsOneWidget);
    });

    testWidgets('解析不出的系统提示：退化成"原文 + 复制"，信息不丢', (WidgetTester tester) async {
      await pump(
        tester,
        '模型端点返回 HTTP 400：reasoning_content must be passed back',
      );
      expect(find.text('系统提示'), findsOneWidget);
      expect(
        find.textContaining('reasoning_content must be passed back'),
        findsOneWidget,
      );
      expect(find.text('复制'), findsOneWidget);
    });
  });
}
