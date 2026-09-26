/// 站点隔离四元组（M9 §1.2 硬要求）。
///
/// 所有站点消息（广播站广播、执行站命令、中转站回填、收集站请求与回包）都必须
/// **携带并校验**：
/// ${''}(team_id, agent_id, session_id, mode_key)   // mode_key ∈ {local, ssh}
///
/// 判定方向一律 **fail-closed**（不能证明归属即拒绝）：
/// 1. 「team + mode」三方（站点实例 / 消息 / 订阅者）必须**精确相等**且非空——
///    跨 team、跨 local/ssh 一律不投递（否则 SSH 团队的插件命令会打到本地工作空间）；
/// 2. agent_id / session_id 允许**订阅者更细**（订阅可声明「只订阅某 agent」），
///    但非空值必须与消息一致，**不得放大**；
/// 3. 消息字段为空（未知）而订阅者/站点要求该字段 ⇒ 不投递。
library;

/// mode_key 取值（与 plan §1.2 一致）。
abstract final class StationModeKey {
  /// 本地模式。
  static const String local = 'local';

  /// SSH 远程模式。
  static const String ssh = 'ssh';

  /// 合法取值集合。
  static const Set<String> all = <String>{local, ssh};

  /// 是否合法（非法值一律拒绝投递）。
  static bool isValid(String value) => all.contains(value);
}

/// 站点隔离四元组（不可变值对象；空串 = 不限定/未知，由校验方向决定语义）。
class StationScope {
  const StationScope({
    this.teamId = '',
    this.agentId = '',
    this.sessionId = '',
    this.modeKey = StationModeKey.local,
  });

  /// 团队 id（隔离主键；站点消息必须非空）。
  final String teamId;

  /// agent id（可为空 = 不限定）。
  final String agentId;

  /// 会话 id（可为空 = 不限定）。
  final String sessionId;

  /// 模式键（local | ssh）。
  final String modeKey;

  /// 是否具备最小归属（team 非空 + mode 合法）。
  bool get isValid =>
      teamId.trim().isNotEmpty && StationModeKey.isValid(modeKey);

  /// 精确相等（四元组全等）。
  bool exactEquals(StationScope other) =>
      teamId == other.teamId &&
      agentId == other.agentId &&
      sessionId == other.sessionId &&
      modeKey == other.modeKey;

  /// 键位串（站 × scope 唯一键位、订阅去重键）。
  String get key => '$teamId|$agentId|$sessionId|$modeKey';

  /// 声明精度（非空字段数；中转站「最细粒度优先」解析用）。
  int get specificity =>
      (teamId.isEmpty ? 0 : 1) +
      (agentId.isEmpty ? 0 : 1) +
      (sessionId.isEmpty ? 0 : 1) +
      (modeKey.isEmpty ? 0 : 1);

  /// 宽容解析（缺失字段归一化为空串；mode_key 缺失按 local 兜底，
  /// 与既有配置只有 team_id 时的语义一致）。
  static StationScope parse(Object? raw) {
    if (raw is! Map) return const StationScope();
    String field(String key, [String fallback = '']) {
      final Object? value = raw[key];
      if (value == null) return fallback;
      final String text = value.toString().trim();
      return text.isEmpty ? fallback : text;
    }

    return StationScope(
      teamId: field('team_id'),
      agentId: field('agent_id'),
      sessionId: field('session_id'),
      modeKey: field('mode_key', StationModeKey.local),
    );
  }

  /// 序列化（落盘 / 帧载荷共用；四字段全写，便于人读与手改）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'team_id': teamId,
    'agent_id': agentId,
    'session_id': sessionId,
    'mode_key': modeKey,
  };

  /// 带说明的字符串（日志 / 可读错误用）。
  String describe() {
    final String team = teamId.isEmpty ? '?' : teamId;
    final List<String> parts = <String>['team=$team'];
    if (agentId.isNotEmpty) parts.add('agent=$agentId');
    if (sessionId.isNotEmpty) parts.add('session=$sessionId');
    parts.add('mode=$modeKey');
    return parts.join(', ');
  }

  @override
  String toString() => 'StationScope($key)';
}

/// 隔离校验结论（fail-closed：ok == false 时 reason 必须是可读中文原因）。
class StationIsolationVerdict {
  const StationIsolationVerdict.ok() : ok = true, reason = '';

  const StationIsolationVerdict.rejected(this.reason) : ok = false;

  /// 是否放行。
  final bool ok;

  /// 拒绝原因（可读中文；放行时为空串）。
  final String reason;
}

/// 隔离校验规则（唯一定义处；站点的所有投递路径都必须过这里）。
abstract final class StationIsolation {
  /// 校验「消息 → 站点实例」：站点绑定 scope 与消息 scope 必须相容。
  ///
  /// - team + mode 精确相等（站点未绑定 team ⇒ 拒绝一切消息，不静默放行）；
  /// - 站点非空的 agent/session 必须与消息一致（站点为空 = 不限定）。
  static StationIsolationVerdict checkMessage({
    required StationScope station,
    required StationScope message,
  }) {
    final StationIsolationVerdict base = _checkTeamAndMode(
      owner: station,
      other: message,
      ownerLabel: '站点实例',
      otherLabel: '消息',
    );
    if (!base.ok) return base;
    if (station.agentId.isNotEmpty && station.agentId != message.agentId) {
      return StationIsolationVerdict.rejected(
        '站点绑定 agent=${station.agentId}，消息 agent=${_or(message.agentId)} 不一致（跨 scope 不投递）',
      );
    }
    if (station.sessionId.isNotEmpty &&
        station.sessionId != message.sessionId) {
      return StationIsolationVerdict.rejected(
        '站点绑定 session=${station.sessionId}，消息 session=${_or(message.sessionId)} 不一致（跨 scope 不投递）',
      );
    }
    return const StationIsolationVerdict.ok();
  }

  /// 校验「消息 → 订阅者」：订阅者可比消息更细，但不得放大。
  static StationIsolationVerdict checkSubscriber({
    required StationScope message,
    required StationScope subscriber,
  }) {
    final StationIsolationVerdict base = _checkTeamAndMode(
      owner: subscriber,
      other: message,
      ownerLabel: '订阅者',
      otherLabel: '消息',
    );
    if (!base.ok) return base;
    if (subscriber.agentId.isNotEmpty) {
      if (message.agentId.isEmpty || subscriber.agentId != message.agentId) {
        return StationIsolationVerdict.rejected(
          '订阅者限定 agent=${subscriber.agentId}，消息 agent=${_or(message.agentId)} 不匹配（不能证明即拒绝）',
        );
      }
    }
    if (subscriber.sessionId.isNotEmpty) {
      if (message.sessionId.isEmpty ||
          subscriber.sessionId != message.sessionId) {
        return StationIsolationVerdict.rejected(
          '订阅者限定 session=${subscriber.sessionId}，消息 session=${_or(message.sessionId)} 不匹配（不能证明即拒绝）',
        );
      }
    }
    return const StationIsolationVerdict.ok();
  }

  /// 完整投递判定：站点绑定 + 订阅者粒度（两条都过才投递）。
  static StationIsolationVerdict deliver({
    required StationScope station,
    required StationScope message,
    required StationScope subscriber,
  }) {
    final StationIsolationVerdict onStation = checkMessage(
      station: station,
      message: message,
    );
    if (!onStation.ok) return onStation;
    return checkSubscriber(message: message, subscriber: subscriber);
  }

  /// 空串占位（可读错误里用 ? 表示「未知/缺失」）。
  static String _or(String value) => value.isEmpty ? '?' : value;

  /// team + mode 的精确匹配（三方共同前提）。
  static StationIsolationVerdict _checkTeamAndMode({
    required StationScope owner,
    required StationScope other,
    required String ownerLabel,
    required String otherLabel,
  }) {
    if (owner.teamId.trim().isEmpty) {
      return StationIsolationVerdict.rejected(
        '$ownerLabel 缺少 team_id，拒绝投递（fail-closed）',
      );
    }
    if (other.teamId.trim().isEmpty) {
      return StationIsolationVerdict.rejected(
        '$otherLabel 缺少 team_id，拒绝投递（fail-closed）',
      );
    }
    if (owner.teamId != other.teamId) {
      return StationIsolationVerdict.rejected(
        '跨 team 不投递：$ownerLabel team=${owner.teamId}，$otherLabel team=${other.teamId}',
      );
    }
    if (!StationModeKey.isValid(owner.modeKey)) {
      return StationIsolationVerdict.rejected(
        '$ownerLabel 的 mode_key=${owner.modeKey} 非法（只能是 local | ssh）',
      );
    }
    if (!StationModeKey.isValid(other.modeKey)) {
      return StationIsolationVerdict.rejected(
        '$otherLabel 的 mode_key=${other.modeKey} 非法（只能是 local | ssh）',
      );
    }
    if (owner.modeKey != other.modeKey) {
      return StationIsolationVerdict.rejected(
        '跨模式不投递：$ownerLabel mode=${owner.modeKey}，$otherLabel mode=${other.modeKey}',
      );
    }
    return const StationIsolationVerdict.ok();
  }
}
