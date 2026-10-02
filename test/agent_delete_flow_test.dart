import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 删除 agent 的前端接线（2026-10-02 核心加了「两道闸门」之后的口径）。
///
/// 核心侧：有下级成员必须显式 `?cascade=1`（否则 409 + `cascade_required`），
/// 正在运行的 agent 拒绝删除（409 + `running`）。前端必须**看得懂这两条**，
/// 否则用户只会看到「删除失败（HTTP 409）」——不知道为什么、也不知道该怎么办。
void main() {
  final String api = File('lib/io/api_service.dart').readAsStringSync();
  final String page = File('lib/ui/pages/main_page.dart').readAsStringSync();

  test('deleteAgent：结构化 409（下级清单 / 运行中）而不是只留状态码', () {
    expect(api.contains('class AgentDeleteBlocked implements Exception'), isTrue);
    expect(api.contains("'cascade_required'"), isTrue);
    expect(api.contains("'running'"), isTrue);
    expect(api.contains('?cascade=1'), isTrue, reason: '级联删除要带查询参数');
    expect(
      api.contains("throw Exception('删除失败（HTTP "),
      isFalse,
      reason: '旧实现把响应体丢掉、只剩状态码，正是要修掉的行为',
    );
  });

  test('UI：先按无级联删，409 摊开下级清单，确认后带 cascade 重试', () {
    expect(page.contains('on AgentDeleteBlocked catch (blocked)'), isTrue);
    expect(page.contains('ApiService.deleteAgent(agent.id, cascade: true)'), isTrue);
    expect(page.contains('blocked.cascadeRequired'), isTrue);
    expect(page.contains('连同下级成员一并删除？'), isTrue);
  });

  test('UI：删成员不清插件作用域（只有删团队 TOP 才回落）', () {
    final RegExp call = RegExp(r'_setTeamScope\(null\)');
    expect(call.allMatches(page).length, 1, reason: '只保留 TOP 删除那一处回落');
    expect(page.contains('if (agent.teamId.isEmpty) _setTeamScope(null);'), isTrue);
  });
}
