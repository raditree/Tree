/// 插件的**生命周期状态**（20261015-hot-restart 阶段 1，D11）。
///
/// **为什么要新增这个枚举，而不是把 `health` 字符串改一改**：
/// 现状里"这个插件到哪一步了"散在四处各说各话——`PluginHost.isClosed` / `_exitCode`
/// （存活位）、`host.liveness.isStale`（活性）、对外 `health`（`ok/degraded/unavailable`）、
/// 以及配置对账结果 `PluginReconcileKind`。挂起、续跑、重启期保活都需要一个**路由判据**
/// （"这次请求该暂存还是该直投"），拿这四份里任意一份当判据都会出现
/// "health 说 ok、其实正在重启"这种自相矛盾。
///
/// **但这两件事仍然归它们管，本枚举不接管**（D11 的向后兼容底线）：
/// - **活性看 `health`**：`ok` / `degraded` / `unavailable` 的产出规则一字不改——
///   它回答"还听得见吗"，是心跳台账的投影；
/// - **启停看 `status`**：`registered` / `disabled` 一字不改——它回答"配置上要不要跑"。
/// 本枚举回答的是第三件事：**处在生命周期的哪一段**。
///
/// 因此落盘/帧侧只允许**加一个可选字段** `lifecycle`（见 `PluginBus` 的快照产出），
/// 老前端与老插件读不到它就按"不知道生命周期"处理，绝不影响既有展示。
///
/// **映射函数必须集中一处**（`PluginBus._lifecycleOf`）：这个枚举有六个值、四份来源，
/// 分散推导必然出现不同产出点各算一套的情况——那正是本枚举要消灭的东西。
enum PluginLifecycleState {
  /// 没在跑（未启动 / 已停用 / 配置里已删除）。
  stopped('stopped'),

  /// 进程已拉起、握手或首次 `tools/list` 还没完成。
  ///
  /// 与 [ready] 分开是有意的：这一段里插件**还不能**接站点请求，
  /// 把它算作 ready 会把请求投进一个还没订完站点的进程。
  booting('booting'),

  /// 就绪：握手完成、工具表已申报、站点订阅已生效。
  ready('ready'),

  /// **重启中**：热重启已经开始，旧实例正在转储或已退出、新实例还没就绪。
  ///
  /// 这一态是阶段 2「重启期保活」的路由依据——处于本态时站点请求进暂存队列，
  /// 对外仍算"正常状态"（不变量 15：请求级失败与暂时不可用都不等于判死）。
  restarting('restarting'),

  /// 已挂起：进程**已经退出**，但可续跑状态已转储到核心内存池、等下一世取回。
  ///
  /// 与 [stopped] 的区别只有一件事：有没有一份等着被取回的快照。所以判死口径不变，
  /// 只是这次"没了"是被安排的、不是事故。
  suspended('suspended'),

  /// 失败：启动失败 / 通道断裂 / 判死。
  ///
  /// 注意本态**不承诺**"进程一定没了"（通道断了进程可能还活着），也不授权自动强杀。
  failed('failed');

  const PluginLifecycleState(this.wire);

  /// 线上形态（写进快照与 `plugin_status` 帧的 `lifecycle` 字段值）。
  final String wire;

  /// 宽容解析：认不出 ⇒ null（调用方按"不知道生命周期"处理，绝不抛异常）。
  ///
  /// 为什么必须有这个宽容口：帧是跨进程跨版本的，老核心发的帧里没有 `lifecycle`，
  /// 新前端也可能收到未来值——两边都不能因为"读到一个没见过的词"就崩。
  static PluginLifecycleState? tryParse(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return null;
    for (final PluginLifecycleState state in PluginLifecycleState.values) {
      if (state.wire == value) return state;
    }
    return null;
  }

  /// 是否处于"进程当下不可用，但工作安排上是暂时性的"这一段（阶段 2 的暂存判据）。
  bool get isTemporarilyUnavailable =>
      this == PluginLifecycleState.restarting ||
      this == PluginLifecycleState.suspended ||
      this == PluginLifecycleState.booting;

  /// 是否**绝不**该把真实任务投过去（这一段没有接收方）。
  bool get rejectsWork =>
      this == PluginLifecycleState.stopped ||
      this == PluginLifecycleState.failed;
}
