import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  test('设置了显式 AUMID 之后能原样读回', () {
    applyAppUserModelId();
    expect(currentAppUserModelId(), kAppUserModelId);
  }, skip: Platform.isWindows ? false : 'AUMID 只在 Windows 生效');

  test('空白 id 不覆盖已有值（空操作）', () {
    applyAppUserModelId();
    applyAppUserModelId('   ');
    expect(currentAppUserModelId(), kAppUserModelId);
  }, skip: Platform.isWindows ? false : 'AUMID 只在 Windows 生效');

  test('非 Windows 平台读回空串（调用方无需分支）', () {
    if (Platform.isWindows) return;
    applyAppUserModelId();
    expect(currentAppUserModelId(), '');
  });

  test('环境变量名与核心口径一致', () {
    expect(kAppUserModelIdEnv, 'TREE_APP_USER_MODEL_ID');
    expect(kAppUserModelId, 'Tree.Desktop');
  });
}
