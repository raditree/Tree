import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// CLI 入口目前只打印自描述（M0b）；这里断言它依赖的核心包已接通，
/// 保证 `dart compile exe` 打包链路不会因路径依赖断裂而失败。
void main() {
  test('CLI 已接通 tree_core 依赖', () {
    expect(TreeCore.version, isNotEmpty);
    expect(TreeCore.describe(), contains('tree_core'));
  });
}
