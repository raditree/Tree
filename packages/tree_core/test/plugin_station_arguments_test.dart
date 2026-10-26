import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 租约边界：调用方不能让执行器用自己的 root。
void main() {
  test('station/command 参数清洗：调用方 root/workspace_root 必须被丢弃', () {
    final Map<String, dynamic> args = PluginBus.sanitizeStationArguments(
      <String, dynamic>{
        'root': r'C:\Windows',
        'workspace_root': '/etc',
        'path': 'a.txt',
        'lease_id': 'lease-1',
      },
    );
    expect(args.containsKey('root'), isFalse);
    expect(args.containsKey('workspace_root'), isFalse);
    expect(args['path'], 'a.txt');
    expect(args['lease_id'], 'lease-1');
  });

  test('非 Map 参数按空对象处理', () {
    expect(PluginBus.sanitizeStationArguments(null), isEmpty);
    expect(PluginBus.sanitizeStationArguments('x'), isEmpty);
  });
}
