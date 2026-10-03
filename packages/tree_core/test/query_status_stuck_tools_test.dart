import 'package:test/test.dart';
// 刻意只 import 用到的 src 文件（本仓库测试的既有做法）：本轮有别的同事在并行改
// `core_server.dart` / `execute_mounts.dart`，走 `package:tree_core/tree_core.dart`
// 的聚合入口会把他们的中间态编译错误算到本测试头上。
import 'package:tree_core/src/settings/core_settings.dart';
import 'package:tree_core/src/store/memory_store.dart';
import 'package:tree_core/src/store/records.dart';
import 'package:tree_core/src/team/team_service.dart';
import 'package:tree_core/src/tool/tool_run_registry.dart';

/// `query_status.stuck_tools`（plan §4 步骤 6 / §6）：
/// **只回报 `over_threshold` 的在途工具**，且**按被查成员过滤**。
///
/// 时钟口径（避免 flaky）：登记表注入假时钟 `now: () => _fakeNow` + 阈值 30 ms，
/// 用**推进假时钟**制造"已超阈值"，一次真实 `Future.delayed` 都不用；
/// 阈值判定是 `elapsedMs >= threshold.ms`，所以 `_fakeNow += 30` 即为恰好到点。
void main() {
  late MemoryStore store;
  late CoreSettings settings;
  late ToolRunRegistry registry;
  late TeamService service;
  late CoreAgent top;
  late String member;
  int fakeNow = 0;

  setUp(() {
    fakeNow = 1000;
    store = MemoryStore();
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
      'max_output_tokens': 4096,
    });
    // 阈值 30 ms + 假时钟：测试显式注入自己的登记表（不用全局 instance）。
    registry = ToolRunRegistry(
      threshold: const Duration(milliseconds: 30),
      now: () => fakeNow,
    );
    addTearDown(registry.shutdown);
    service = TeamService(store: store, settings: settings, toolRuns: registry);
    top = store.createAgent(
      name: '队长',
      modelId: 'demo',
      maxLevel: 3,
      maxMembersPerLevel: 7,
    );
    member =
        service.createMember(top.id, <String, dynamic>{
              'action': 'create_member',
              'member_name': '成员甲',
            })['member_id']
            as String;
  });

  /// 以 TOP 身份查某成员的实时状态（`queryStatus` 要求目标成员存在）。
  Map<String, dynamic> status(String target) =>
      service.queryStatus(top.id, <String, dynamic>{'target_member_id': target});

  List<dynamic> stuckOf(String target) =>
      status(target)['stuck_tools'] as List<dynamic>;

  test('无在跑工具：stuck_tools 是空列表（形状是 list，不是 null / 缺键）', () {
    final Map<String, dynamic> payload = status(member);
    expect(payload.containsKey('stuck_tools'), isTrue);
    expect(payload['stuck_tools'], isA<List<dynamic>>());
    expect(payload['stuck_tools'], isEmpty);
    expect(
      payload['hint'],
      contains('日志路径'),
      reason: '原有 hint（日志路径那句）口径不变，另加 stuck_tools 这一层',
    );
  });

  test('已超阈值的运行：恰好 1 项，字段键集与取值为冻结口径', () {
    final ToolRun run = registry.start(
      tool: 'terminal',
      arguments: <String, dynamic>{'command': 'sleep 300'},
      agentId: member,
      sessionId: 'sess-1',
    );
    fakeNow += 100; // 阈值 30 ms ⇒ 已超阈值

    final List<dynamic> stuck = stuckOf(member);
    expect(stuck, hasLength(1));
    final Map<String, dynamic> item = stuck.single as Map<String, dynamic>;
    expect(item.keys.toSet(), <String>{
      'handle',
      'tool',
      'elapsed_ms',
      'command',
      'hint',
    });
    expect(item['handle'], run.handle);
    expect(item['handle'], startsWith('toolrun_'));
    expect(item['tool'], 'terminal');
    expect(item['elapsed_ms'], greaterThanOrEqualTo(30));
    expect(item['command'], 'sleep 300');
    expect(item['command'], isNotEmpty);
    expect((item['hint'] as String), isNotEmpty);
    expect(item['hint'], contains('tool.close'));
  });

  test('全根扫描防呆：find 命令的 hint 含 find 与 tool.close（plan §4.6 口径）', () {
    registry.start(
      tool: 'terminal',
      arguments: <String, dynamic>{
        'command': 'find /mnt/space -name "*.md"',
      },
      agentId: member,
      sessionId: 'sess-1',
    );
    fakeNow += 200;

    final Map<String, dynamic> item =
        stuckOf(member).single as Map<String, dynamic>;
    expect(item['hint'], contains('find'));
    expect(item['hint'], contains('tool.close'));
  });

  test('未超阈值的运行不出现（到了阈值才出现，>= 口径）', () {
    registry.start(
      tool: 'terminal',
      arguments: <String, dynamic>{'command': 'echo hi'},
      agentId: member,
      sessionId: 'sess-1',
    );
    expect(registry.list(), hasLength(1), reason: '登记项在表里，只是没超阈值');
    expect(stuckOf(member), isEmpty, reason: '刚 start（elapsed=0）不得出现在 stuck_tools');

    fakeNow += 30; // 恰好到阈值（elapsedMs >= threshold.ms）
    expect(stuckOf(member), hasLength(1), reason: '到点即算 over_threshold');
  });

  test('按成员过滤：别的 agent 的超阈值运行不出现在被查成员的 stuck_tools 里', () {
    registry.start(
      tool: 'terminal',
      arguments: <String, dynamic>{'command': 'sleep 1'},
      agentId: member,
      sessionId: 'sess-a',
    );
    final CoreAgent other = store.createAgent(name: '别的队');
    registry.start(
      tool: 'terminal',
      arguments: <String, dynamic>{'command': 'sleep 2'},
      agentId: other.id,
      sessionId: 'sess-b',
    );
    fakeNow += 100;

    expect(registry.stuckFor(member), hasLength(1));
    final List<dynamic> stuck = stuckOf(member);
    expect(stuck, hasLength(1));
    expect((stuck.single as Map<String, dynamic>)['command'], 'sleep 1');
  });
}
