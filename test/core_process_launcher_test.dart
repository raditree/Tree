import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/core_process_launcher.dart';

/// 陈旧核心判定的单元测试。
///
/// 为什么值得测：这个判定是"界面新、核心旧"这类问题的唯一自证手段；判错方向
/// （把正常的同批构建报成陈旧、或把陈旧产物放过）都会直接损害信任。
void main() {
  final DateTime app = DateTime(2026, 9, 26, 17, 24);

  String? warn(DateTime core, {Duration tol = const Duration(seconds: 60)}) =>
      CoreProcessLauncher.staleCoreWarningFor(
        coreMtime: core,
        appMtime: app,
        coreName: 'tree_core.exe',
        appName: 'Tree.exe',
        coreExecutableName: 'tree_core.exe',
        tolerance: tol,
      );

  test('核心明显更旧 ⇒ 给出告警，且文案含两个产物名与修复命令', () {
    final String? w = warn(DateTime(2026, 9, 26, 10, 38));
    expect(w, isNotNull);
    expect(w, contains('tree_core.exe'));
    expect(w, contains('Tree.exe'));
    expect(w, contains('2026-09-26 10:38'));
    expect(w, contains('2026-09-26 17:24'));
    expect(w, contains('tool/build_core.dart'));
  });

  test('同一批构建（60s 容差内）⇒ 不打扰用户', () {
    expect(warn(app.subtract(const Duration(seconds: 30))), isNull);
    expect(warn(app), isNull);
    expect(warn(app.add(const Duration(minutes: 5))), isNull);
  });

  test('恰好越过容差 ⇒ 告警（边界）', () {
    expect(warn(app.subtract(const Duration(seconds: 59))), isNull);
    expect(warn(app.subtract(const Duration(seconds: 61))), isNotNull);
  });

  test('容差可配（调用方按需放宽）', () {
    final DateTime core = app.subtract(const Duration(minutes: 10));
    expect(warn(core), isNotNull);
    expect(warn(core, tol: const Duration(hours: 1)), isNull);
  });
}