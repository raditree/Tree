import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  test('骨架自描述可用且协议已挂载', () {
    expect(TreeCore.version, isNotEmpty);
    expect(TreeCore.keptApiPathCount, greaterThan(0));
    expect(TreeCore.describe(), contains('tree_core'));
  });
}
