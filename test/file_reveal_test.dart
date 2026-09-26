import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/download_center.dart';
import 'package:tree/ui/services/file_reveal.dart';
import 'package:tree/ui/widgets/download_panel.dart';

/// Q7：下载列表「打开文件所在位置」。
///
/// 这里只覆盖**不依赖真实文件管理器**的分支：空路径、路径不存在（这两条都必须
/// 给可见提示），以及面板行上确实挂了动作按钮。真正拉起 explorer 的行为留给
/// 手工回归——测试里弹窗会污染桌面。
void main() {
  final DownloadCenter center = DownloadCenter.instance;

  setUp(() {
    for (final DownloadTask task in center.tasks) {
      center.remove(task);
    }
  });

  tearDown(() {
    for (final DownloadTask task in center.tasks) {
      center.remove(task);
    }
  });

  test('空路径返回可展示的提示，而不是静默成功', () async {
    expect(await FileReveal.reveal(''), isNotNull);
  });

  test('路径不存在时返回提示（不会去拉文件管理器）', () async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    final String missing = '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}tree_reveal_missing_'
        '${DateTime.now().microsecondsSinceEpoch}.txt';
    final String? error = await FileReveal.reveal(missing);
    expect(error, isNotNull);
    expect(error, contains('不存在'));
  });

  testWidgets('每行都有「打开文件所在位置」动作；路径为空时弹 SnackBar 提示',
      (WidgetTester tester) async {
    // 文件夹任务：保存的产物是 tar.gz，savePath 就是压缩包完整路径
    final DownloadTask done = center.begin(
      kind: DownloadKind.folder,
      name: 'assets.tar.gz',
      sourceTeam: '团队A',
      sourceTeamId: 'agt_1',
    );
    center.complete(done, localPath: '');
    // 未落盘的任务：savePath 仍为空 → 必须给可见提示
    final DownloadTask pending = center.begin(
      kind: DownloadKind.file,
      name: 'pending.bin',
      sourceTeam: '团队A',
      sourceTeamId: 'agt_1',
    );
    expect(pending.savePath, isEmpty);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DownloadPanel()),
    ));

    expect(find.byIcon(Icons.folder_open), findsNWidgets(2));
    expect(find.text('assets.tar.gz'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.folder_open).first);
    // 进行中的任务带不确定进度条动画，pumpAndSettle 永远等不到静止，
    // 因此按固定帧推进：一帧处理点击，一帧取回 Future 结果并插入 SnackBar
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('该任务还没有保存路径'), findsOneWidget);
  });
}
