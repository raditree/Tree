import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/mode_switch.dart';

/// Q2：运行模式两态（local / ssh）。
///
/// cloud 从菜单、图标与文案里彻底消失；local 是默认态（绿色电源图标）。
void main() {
  Future<void> pumpSwitch(
    WidgetTester tester, {
    required String mode,
    required List<String> selected,
    bool locked = false,
    bool showLocal = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ModeSwitchButton(
            mode: mode,
            locked: locked,
            showLocal: showLocal,
            onSelect: selected.add,
          ),
        ),
      ),
    ));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('菜单只剩「本地执行」与「SSH 执行」，没有云端项', (WidgetTester tester) async {
    final List<String> selected = <String>[];
    await pumpSwitch(tester, mode: 'local', selected: selected);
    await openMenu(tester);

    expect(find.text('本地执行（本机目录）'), findsOneWidget);
    expect(find.text('SSH 执行（远端主机）'), findsOneWidget);
    expect(find.textContaining('云端'), findsNothing);

    await tester.tap(find.text('SSH 执行（远端主机）'));
    await tester.pumpAndSettle();
    expect(selected, <String>['ssh']);
  });

  testWidgets('local 用电源图标（绿），ssh 用 DNS 图标（橙）', (WidgetTester tester) async {
    await pumpSwitch(tester, mode: 'local', selected: <String>[]);
    expect(find.byIcon(Icons.power), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);

    await pumpSwitch(tester, mode: 'ssh', selected: <String>[]);
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    expect(find.byIcon(Icons.power), findsNothing);
  });

  testWidgets('移动端隐藏「本地执行」项：菜单只剩 SSH', (WidgetTester tester) async {
    await pumpSwitch(
      tester,
      mode: 'local',
      selected: <String>[],
      showLocal: false,
    );
    await openMenu(tester);

    expect(find.text('本地执行（本机目录）'), findsNothing);
    expect(find.text('SSH 执行（远端主机）'), findsOneWidget);
  });

  testWidgets('对话已开始时开关不可点', (WidgetTester tester) async {
    final List<String> selected = <String>[];
    await pumpSwitch(
      tester,
      mode: 'local',
      selected: selected,
      locked: true,
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('SSH 执行（远端主机）'), findsNothing);
    expect(selected, isEmpty);
  });
}
