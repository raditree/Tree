import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

void main() {
  test('IO 原语清单覆盖 WorkspaceIO 抽象', () {
    expect(TreeLocalExec.backendCount, greaterThan(0));
    expect(TreeLocalExec.ioPrimitives, contains('read_file'));
    expect(TreeLocalExec.ioPrimitives, contains('list_files'));
  });
}
