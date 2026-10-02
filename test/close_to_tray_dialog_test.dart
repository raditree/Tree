import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/widgets/close_to_tray_dialog.dart';

/// 首次关闭窗口时的说明框：两个动作各自的返回值，以及"记住我的选择"默认勾上。
///
/// 返回值决定了真实行为（隐藏 / 退出 / 是否记成默认），所以这里必须钉住——
/// 一旦返回值反了，用户点的"退出"会变成"收进托盘"。
void main() {
  Future<CloseToTrayChoice?> openDialog(
    WidgetTester tester,
    void Function(CloseToTrayChoice?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                final CloseToTrayChoice? choice =
                    await showDialog<CloseToTrayChoice>(
                      context: context,
                      builder: (BuildContext context) =>
                          const CloseToTrayDialog(),
                    );
                onResult(choice);
              },
              child: const Text('关闭窗口'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('关闭窗口'));
    await tester.pumpAndSettle();
    return null;
  }

  testWidgets('文案说清后果：后台运行 + 怎么恢复 + 怎么真退出', (WidgetTester tester) async {
    await openDialog(tester, (CloseToTrayChoice? _) {});
    expect(find.text('关闭窗口后继续在后台运行？'), findsOneWidget);
    expect(find.textContaining('系统托盘'), findsOneWidget);
    expect(find.textContaining('双击托盘图标恢复窗口'), findsOneWidget);
    expect(find.text('后台运行（推荐）'), findsOneWidget);
    expect(find.text('退出 Tree'), findsOneWidget);
  });

  testWidgets('点「后台运行」：隐藏到托盘、记住选择（复选框默认勾上）', (WidgetTester tester) async {
    CloseToTrayChoice? result;
    bool answered = false;
    await openDialog(tester, (CloseToTrayChoice? choice) {
      result = choice;
      answered = true;
    });
    expect(
      tester.widget<CheckboxListTile>(
        find.byKey(const Key('close_to_tray_remember')),
      ).value,
      isTrue,
      reason: '默认勾上：用户已经表态过就不该每次关闭都被问',
    );

    await tester.tap(find.text('后台运行（推荐）'));
    await tester.pumpAndSettle();

    expect(answered, isTrue);
    expect(result!.hideToTray, isTrue);
    expect(result!.remember, isTrue);
  });

  testWidgets('点「退出 Tree」：现在退出；取消勾选后不记成默认', (WidgetTester tester) async {
    CloseToTrayChoice? result;
    await openDialog(tester, (CloseToTrayChoice? choice) => result = choice);
    await tester.tap(find.byKey(const Key('close_to_tray_remember')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出 Tree'));
    await tester.pumpAndSettle();

    expect(result!.hideToTray, isFalse);
    expect(result!.remember, isFalse, reason: '没勾"记住"就下次还问');
  });
}
