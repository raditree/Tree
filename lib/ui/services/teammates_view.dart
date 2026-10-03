/// teammates 窗口（「XX 的团队」）的两条**纯规则**：根节点是谁、名单里要不要滤掉自己。
///
/// 背景（用户 2026-10-03）：成员「凌川」的成员面板里出现了「凌川」自己，根卡片还写着
/// 「Level 0 · 团队负责人」。核心侧已修（`GET /api/agents/{id}/teammates` 只回该 agent
/// **自己的**下属子树，并回一份 `self` 描述符；见 [team/README.md] 不变量 14），
/// 前端这里留两条规则，理由与 [TeamScopeView](team_scope_view.dart) 一样：
///
/// 1. **滤掉自己**：核心即使是旧版本 / 数据修复期回了一份含自己的名单，界面也绝不把
///    「我」渲染成「我的成员」——这类自指显示骗人且不好解释；
/// 2. **根卡片如实**：判得出「我是成员」就绝不说自己是 Level 0 团队负责人，
///    副标题写「Level N 成员 · 隶属「TOP」」；拿不到描述符（旧核心）时用前端已有的
///    `agent.teamId` 兜底，宁缺勿假。
library;

/// 成员面板根节点（顶部那张卡片）要显示的东西。
class TeammatesRoot {
  const TeammatesRoot({
    required this.name,
    required this.level,
    required this.isMember,
    required this.topName,
  });

  final String name;

  /// 绝对层级（TOP = 0，成员按 yaml 里的 `level`）。
  final int level;

  /// 这个 agent 是不是团队成员（`team_id` 非空）。
  final bool isMember;

  /// 成员隶属的团队 TOP 名；TOP 自己为空串。
  final String topName;

  /// 根卡片的副标题。**成员不许显示成「Level 0 · 团队负责人」**。
  String get subtitle {
    if (!isMember) return 'Level 0 · 团队负责人';
    final String tail = topName.isEmpty ? '' : ' · 隶属「$topName」';
    return level > 0 ? 'Level $level 成员$tail' : '团队成员$tail';
  }
}

/// 解析 `GET /api/agents/{id}/teammates` 响应体里的 `self` 描述符。
///
/// [fallbackIsMember] 用于旧核心（没有 `self` 字段）：前端已经从 `agent.teamId`
/// 知道「我是不是成员」，不能因为核心没给描述符就退回「我是团队负责人」。
TeammatesRoot teammatesRoot({
  required Map<String, dynamic>? payload,
  required String fallbackName,
  required bool fallbackIsMember,
}) {
  final Map<String, dynamic>? self =
      (payload?['self'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
  if (self == null) {
    return TeammatesRoot(
      name: fallbackName,
      level: 0,
      isMember: fallbackIsMember,
      topName: '',
    );
  }
  return TeammatesRoot(
    name: (self['name'] ?? fallbackName).toString(),
    level: (self['level'] as num?)?.toInt() ?? 0,
    isMember: self['is_member'] as bool? ?? fallbackIsMember,
    topName: (self['top_agent_name'] ?? '').toString(),
  );
}

/// 响应体里的成员名单，**滤掉自己**（[selfId]）。
///
/// 核心已经只回自己的下属；这里是第二道闸：名单里出现自己一定是 bug（旧核心或
/// 数据修复期的中间态），界面不该把它显示出来。
List<Map<String, dynamic>> teammatesMembers({
  required Map<String, dynamic>? payload,
  required String selfId,
}) {
  final List<dynamic> raw =
      payload?['members'] as List<dynamic>? ?? const <dynamic>[];
  return raw
      .map((dynamic e) => (e as Map<dynamic, dynamic>).cast<String, dynamic>())
      .where((Map<String, dynamic> m) => (m['id'] ?? '').toString() != selfId)
      .toList(growable: false);
}
