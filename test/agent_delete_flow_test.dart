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

  test('UI：插件 UI 作用域随旧面板协议退役（不再有 _setTeamScope 接线）', () {
    // 片 E 删掉了旧的插件 UI 注册表与它的团队作用域回落；主页面不该再留任何
    // 残留接线（否则删成员 / 删团队的分支里会冒出未定义方法）。
    expect(RegExp(r'_setTeamScope\(').hasMatch(page), isFalse);
    // 字符串拼接避免本条用例自己成为“残留引用”的假阳性（全仓扫描会读 test/）。
    expect(page.contains('PluginUi' 'Registry'), isFalse);
  });
}
