/// 站点隔离四元组（M9 §1.2 硬要求）。
///
/// 所有站点消息（广播站广播、执行站命令、中转站回填、收集站请求与回包）都必须
/// **携带并校验**：
/// ${''}(team_id, agent_id, session_id, mode_key)   // mode_key ∈ {local, ssh}
///
/// 判定方向一律 **fail-closed**（不能证明归属即拒绝）：
/// 1. **消息信封**必须可证明归属：`team_id` 非空 + `mode_key` 合法（local | ssh）；
/// 2. 「消息 ↔ 订阅者」的 **team + mode 必须相容**：订阅者声明了就必须精确相等，
///    **为空 = 这一维不设条件（通配）**——空 team 的订阅者作用于**所有 team**，
///    空 mode 的订阅者对 local / ssh 都收（与事件派发 `dispatchAgentEvent` 的
///    「scope 里为空的维度不设条件」同一口径）；
/// 3. agent_id / session_id 允许**订阅者更细**（订阅可声明「只订阅某 agent」），
///    但非空值必须与消息一致，**不得放大**；
/// 4. 消息字段为空（未知）而订阅者要求该字段 ⇒ 不投递。
///
/// **站点实例不再参与 team/mode 判定**（站点已全局化：每类站一个实例，
/// 本身不绑 team、不绑 mode）。scope 只存在于两处：
/// - **消息**：每次交互携带的信封（由运行期解析得出，见 `StationScopeContext`）；
/// - **订阅声明**：订阅者自述的作用范围上限。
///
/// 因此 `checkMessageScope` 只自校验消息信封是否**可证明归属**（team 非空 +
/// mode 合法），不做任何比对；真正的投递判定在 `checkSubscriber`。
///
/// **空字段的两套语义（最容易混的一点）**：
/// - 消息侧：空 = **未知 / 不可证明** ⇒ 拒绝投递；
/// - 订阅侧：空 = **不设条件（通配）** ⇒ 空 team 作用于所有 team、空 mode 两种
///   工作面都收（订阅者只表达"我要哪些"，不承担证明义务）。
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

  /// 是否具备最小归属（team 非空 + mode 合法）——**消息信封**的口径。
  bool get isValid =>
      teamId.trim().isNotEmpty && StationModeKey.isValid(modeKey);

  /// 是否可作为**订阅声明**（空维度 = 通配，不要求 team 非空）。
  ///
  /// 订阅侧的唯一非法情况是 mode 填了非法值（拼错要报出来），team / agent /
  /// session 为空都合法 = 该维不设条件。空 scope 的插件因此能订阅站点并作用于
  /// **所有 team**（用户定稿：为空默认作用于所有 team）。
  bool get isValidSubscriber => modeKey.isEmpty || StationModeKey.isValid(modeKey);

  /// team 维是否通配（空 = 不限团队，作用于所有 team）。
  bool get teamIsWildcard => teamId.trim().isEmpty;

  /// mode 维是否通配（空 = local / ssh 都收）。
  bool get modeIsWildcard => modeKey.trim().isEmpty;

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

  /// 宽容解析（缺失字段归一化为空串）。
  ///
  /// `mode_key` **缺失保持为空**（= 通配 / 未知），不再兜底成 `local`：兜底会把
  /// 「没声明模式」伪装成「只收本地模式」，于是 SSH 团队的订阅永远收不到消息
  /// （消息侧 mode=ssh，与订阅的 local 精确匹配失败）。需要"只收本地"就显式写
  /// `mode_key: local`。
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
      modeKey: field('mode_key'),
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

/// **调用点上下文**（M9 Wave 3-I）：站点四元组里 team / agent / session 的
/// **运行期**来源。
///
/// 站点全局化后，这里是 scope 的**唯一来源**：站点实例不再持有 team/mode，
/// 「这一次是谁在问」全部由调用点带进来——工具表刷新、执行站下命令、中转拦截
/// 都先经这里解析出消息信封，再交给订阅者匹配。
///
/// - [modeKey] 一般情况下**留空**：mode 由 `PluginBus.agentModeKeyResolver` 从
///   **目标 agent 的工作空间模式**解析（local | ssh），否则 SSH 团队的命令会打到
///   本地工作空间（plan §1.2）；显式给值 = 调用点已经知道模式，作为覆盖。
class StationScopeContext {
  const StationScopeContext({
    this.teamId = '',
    this.agentId = '',
    this.sessionId = '',
    this.modeKey = '',
  });

  /// 当前 team（空 = 调用点没有 team 上下文）。
  final String teamId;

  /// 当前 agent（空 = 无）。
  final String agentId;

  /// 当前会话（空 = 无）。
  final String sessionId;

  /// 显式 mode_key 覆盖（空 = 交给 agent 的工作空间模式解析）。
  final String modeKey;

  /// 是否完全没有上下文（四个字段都空）。
  bool get isEmpty =>
      teamId.trim().isEmpty &&
      agentId.trim().isEmpty &&
      sessionId.trim().isEmpty &&
      modeKey.trim().isEmpty;

  /// 转四元组（空字段保留为空串 = 不限定，交由调用方按方向校验）。
  ///
  /// `modeKey` **不再兜底为 local**：调用点没给出模式时保留空串，让解析器
  /// （`agentModeKeyResolver`）按目标 agent 的工作空间定；硬塞 local 会把
  /// 「模式未知」伪装成「本地模式」。
  StationScope toScope() => StationScope(
    teamId: teamId,
    agentId: agentId,
    sessionId: sessionId,
    modeKey: StationModeKey.isValid(modeKey) ? modeKey : '',
  );

  @override
  String toString() =>
      'StationScopeContext(team=$teamId, agent=$agentId, '
      'session=$sessionId, mode=${modeKey.isEmpty ? '（按 agent 工作空间解析）' : modeKey})';
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
  /// 自校验**消息信封**：这次交互是否具备可证明的归属。
  ///
  /// 站点全局化后不再有「站点绑定 scope」可比，所以站点实例的第一道闸从
  /// 「站点与消息相容」变成「消息自身是否完整」：
  /// - `team_id` 必须非空：解析不出归属的消息谁都投不进去（fail-closed）；
  /// - `mode_key` 必须合法（local | ssh）：它决定这次操作打本地还是 SSH 工作空间。
  ///
  /// 这里**不比对**任何订阅者：投递判定统一在 [checkSubscriber]。
  static StationIsolationVerdict checkMessageScope(StationScope message) {
    if (message.teamId.trim().isEmpty) {
      return const StationIsolationVerdict.rejected(
        '消息缺少 team_id，拒绝投递（fail-closed：无法证明归属）',
      );
    }
    if (!StationModeKey.isValid(message.modeKey)) {
      return StationIsolationVerdict.rejected(
        '消息的 mode_key=${message.modeKey} 非法（只能是 local | ssh），拒绝投递',
      );
    }
    return const StationIsolationVerdict.ok();
  }

  /// 校验**执行站命令**的 scope（插件 → 核心）。
  ///
  /// 与 [checkMessageScope]（数据面消息）的差别只有一处：**team 允许为空 =
  /// 通配所有 team**（用户定稿：为空默认作用于所有 team）——团队级命令（如
  /// `ui.push` 推一张对所有 team 都可见的卡片）本来就没有单一 team。
  ///
  /// 真正需要"落到实处"的命令（写文件 / 跑终端 / 操作 agent）由**挂载位置**自己
  /// fail-closed：`execute_mounts._resolveTarget` 要求 team 非空、agent 可解析、
  /// 且 scope 的 team / mode 与目标 agent 的真实归属精确相等，缺一即拒绝执行。
  /// 闸门放在该放的地方，命令解析这一层不必也不该替它兜底。
  static StationIsolationVerdict checkCommandScope(StationScope command) {
    if (!StationModeKey.isValid(command.modeKey)) {
      return StationIsolationVerdict.rejected(
        '命令 scope 的 mode_key=${command.modeKey} 非法（只能是 local | ssh）：拒绝执行',
      );
    }
    return const StationIsolationVerdict.ok();
  }

  /// 校验「消息 → 订阅者」：订阅者可比消息更细，但不得放大。
  ///
  /// **这是唯一的投递门禁**（站点不再参与判定）：订阅者声明了的维度必须与消息
  /// 精确相等；**订阅者未声明的维度（空）不设条件**（team 空 = 所有 team、
  /// mode 空 = local / ssh 都收）；消息侧必须可证明归属（见 [checkMessageScope]）。
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

  /// 完整投递判定：消息信封自校验 + 订阅者粒度。
  ///
  /// 站点实例已全局唯一、不带 scope，故等价于 [checkMessageScope] +
  /// [checkSubscriber]；保留本方法作为调用方的一处入口（语义自证）。
  static StationIsolationVerdict deliver({
    required StationScope message,
    required StationScope subscriber,
  }) {
    final StationIsolationVerdict onMessage = checkMessageScope(message);
    if (!onMessage.ok) return onMessage;
    return checkSubscriber(message: message, subscriber: subscriber);
  }

  /// 空串占位（可读错误里用 ? 表示「未知/缺失」）。
  static String _or(String value) => value.isEmpty ? '?' : value;

  /// team + mode 的相容判定（消息 ↔ 订阅者，站点全局化后唯一的比对方向）。
  ///
  /// **订阅者侧为空 = 通配**（不设条件）；**消息侧为空 = 不可证明 ⇒ 拒绝**
  /// （方向不对称是刻意的：订阅者表达"我要哪些"，消息必须自证归属）。
  static StationIsolationVerdict _checkTeamAndMode({
    required StationScope owner,
    required StationScope other,
    required String ownerLabel,
    required String otherLabel,
  }) {
    if (!owner.isValidSubscriber) {
      return StationIsolationVerdict.rejected(
        '$ownerLabel 的 mode_key=${owner.modeKey} 非法（只能是 local | ssh，或留空表示通配）',
      );
    }
    if (other.teamId.trim().isEmpty) {
      return StationIsolationVerdict.rejected(
        '$otherLabel 缺少 team_id，拒绝投递（fail-closed）',
      );
    }
    if (owner.teamId.trim().isNotEmpty && owner.teamId != other.teamId) {
      return StationIsolationVerdict.rejected(
        '跨 team 不投递：$ownerLabel team=${owner.teamId}，$otherLabel team=${other.teamId}',
      );
    }
    if (!StationModeKey.isValid(other.modeKey)) {
      return StationIsolationVerdict.rejected(
        '$otherLabel 的 mode_key=${other.modeKey} 非法（只能是 local | ssh）',
      );
    }
    if (owner.modeKey.trim().isNotEmpty && owner.modeKey != other.modeKey) {
      return StationIsolationVerdict.rejected(
        '跨模式不投递：$ownerLabel mode=${owner.modeKey}，$otherLabel mode=${other.modeKey}'
        '（SSH 团队的命令不得打到本地工作空间；订阅方要两种都收就留空 mode_key）',
      );
    }
    return const StationIsolationVerdict.ok();
  }
}
