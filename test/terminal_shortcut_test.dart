import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/pages/main_page.dart';
import 'package:tree/ui/services/terminal_toggle_request.dart';
import 'package:tree/ui/widgets/message_panel.dart';

/// Ctrl+J 的**全局**唤起（用户 2026-10-03 要求：焦点不在输入框时也要能开终端）。
///
/// 为什么以前不行：Ctrl+J 只挂在 MessagePanel 里，而按键是沿**当前焦点**向父级冒泡的
/// ——焦点被文件面板 / 右栏 / 消息列表里的可选文本拿走之后就再也冒不到那一层。
/// 现在 MainPage 在三栏共同祖先上挂了一个 Focus(canRequestFocus: false) 当事件驿站，
/// 由它广播 TerminalToggleRequest；真正切换终端的逻辑仍归消息面板。
///
/// 说明：无核心夹具 ⇒ 选不出 agent ⇒ 这里断言的是「请求有没有被广播出来」（以及内层
/// 会不会重复触发），终端真正出现由 panel 侧的行为决定。
void main() {
  Finder station() => find.byKey(const ValueKey<String>('main-global-shortcuts'));

  /// 主焦点是否还在中栏（MessagePanel）里面。
  bool focusInsidePanel() {
    final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorWidgetOfExactType<MessagePanel>() != null;
  }

  /// pump 出真实的三栏布局：**必须先把窗口调到桌面尺寸**——默认 800x600 会命中
  /// MainPage 的「窗口太小」提示页，MessagePanel 根本不会建，焦点用例自然测不到东西
  /// （第一次写这个用例就踩了：断言焦点在中栏里，实际中栏压根没被构建）。
  Future<void> pumpMainPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: MainPage()));
    await tester.pump();
  }

  Future<void> pressCtrlJ(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  test('请求是广播：request() 自增计数并通知监听者', () {
    final int before = TerminalToggleRequest.instance.revision;
    int notified = 0;
    void listener() => notified++;
    TerminalToggleRequest.instance.addListener(listener);
    addTearDown(() => TerminalToggleRequest.instance.removeListener(listener));
    TerminalToggleRequest.instance.request();
    expect(TerminalToggleRequest.instance.revision, before + 1);
    expect(notified, 1);
  });

  testWidgets('MainPage 装了全局驿站，且它的 Ctrl+J 直接指向请求', (WidgetTester tester) async {
    await pumpMainPage(tester);
    expect(station(), findsOneWidget, reason: '三栏共同祖先上必须有这个事件驿站');
    final CallbackShortcuts shortcuts = tester.widget<CallbackShortcuts>(station());
    // 注意：索引表达式里不能写尾随逗号（`list[x,]` 不是合法 Dart）
    final VoidCallback? action = shortcuts
        .bindings[const SingleActivator(LogicalKeyboardKey.keyJ, control: true)];
    expect(action, isNotNull, reason: '驿站必须绑定 Ctrl+J');
    final int before = TerminalToggleRequest.instance.revision;
    action!.call();
    expect(
      TerminalToggleRequest.instance.revision,
      before + 1,
      reason: '驿站的回调就是广播一次请求（真正切换归消息面板）',
    );
  });

  testWidgets('焦点在中栏里：内层先消费，不重复切换', (WidgetTester tester) async {
    await pumpMainPage(tester);
    expect(focusInsidePanel(), isTrue, reason: '中栏的 autofocus 应当先拿到焦点');
    final int before = TerminalToggleRequest.instance.revision;
    await pressCtrlJ(tester);
    expect(
      TerminalToggleRequest.instance.revision,
      before,
      reason: '面板自己那层 CallbackShortcuts 会先吃掉按键，全局驿站不该再触发一次',
    );
  });

  testWidgets('焦点离开中栏：全局驿站仍把 Ctrl+J 转成请求', (WidgetTester tester) async {
    await pumpMainPage(tester);
    // 用 Tab 走焦点遍历把焦点挪出中栏（找不到可聚焦控件时不硬撑，直接判失败并说明）
    int guard = 0;
    while (focusInsidePanel() && guard < 30) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      guard++;
    }
    expect(
      focusInsidePanel(),
      isFalse,
      reason: 'Tab $guard 次都没能离开中栏：焦点结构变了（或没有别处可聚焦），请更新本用例',
    );
    final int before = TerminalToggleRequest.instance.revision;
    await pressCtrlJ(tester);
    expect(
      TerminalToggleRequest.instance.revision,
      before + 1,
      reason: '焦点不在中栏时也必须能唤起终端（用户 2026-10-03 的要求）',
    );
  });
}
