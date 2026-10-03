/// 内置站点的**全局常量 id**（M9 §3；点位化语义见 `station_points.dart`）。
///
/// 站点 = 拦截点 / 触发点。**站点类型只有四种**（广播 / 执行 / 中转 / 收集），
/// 但每类下面有若干**点位（point）**——每个点位是**一个独立的站点实例**：
/// 各自唯一订阅者（中转）、各自计数、各自挂载位置、面板各自一行。
///
/// 为什么点位要各自成实例（用户 2026-10-01 定稿）：
/// - 中转站是 `scopeKeyUnique`（全站唯一订阅者）：若所有拦截点共用一个实例，
///   "接管 LLM"的插件会顺带垄断"系统提示词构造""上下文压缩"……「职责交给插件、
///   无订阅者才回退系统默认」就退化成"只能有一个插件、还得自己过滤 payload"；
/// - 执行站按**命令族**拆实例后，每个族有独立的挂载位置集合（未来的执行器可以
///   只接管一族，不碰别的族）；命令名寻址对插件零影响（仍是 `station/command`）；
/// - 广播站按主题族拆实例后，订阅 `tool.pre` 的插件不会收到 `tool.post`。
///
/// **id 仍然不含 team / mode**：team / agent / session / mode 是**每次交互携带的信封**
/// （消息 scope）与**订阅声明**，只在投递时用于匹配订阅者。
///
/// 本文件只放**常量**（谁都要引、不能有依赖）；点位的类型 / 说明 / 命令 / 别名表在
/// [station_points.dart]，那里依赖 `StationKind`。
library;

/// 内置站点与点位的 id。
abstract final class StationHubIds {
  // ── 广播站（多订阅者；发布-订阅读 + 持久公告板） ──────────────────────

  /// 广播站·通用主题（插件与核心自定 topic 的落点）。
  static const String broadcast = 'system.broadcast';

  /// 广播站·工具调用前（单向通知，无回填）。
  static const String broadcastToolPre = 'system.broadcast.tool.pre';

  /// 广播站·工具调用后（单向通知，无回填）。
  static const String broadcastToolPost = 'system.broadcast.tool.post';

  /// 广播站·工具运行超时（单向通知，无回填）：一次运行**跨过阈值时广播一次**。
  ///
  /// 点位名由 plan §10 D4 冻结（**不带** `system.broadcast.` 前缀）；订阅同既有
  /// `system.*` 点位：`{station: 'broadcast', point: 'tool.timeout'}`。
  static const String broadcastToolTimeout = 'system.tool.timeout';

  // ── 执行站（插件主动下命令；按命令族拆点位） ────────────────────────────

  /// 执行站·文件操作族：`fs.read` / `fs.write` / `fs.list` / `fs.grep`。
  static const String executeFs = 'system.execute.fs';

  /// 执行站·终端族：`terminal.exec`。
  static const String executeTerminal = 'system.execute.terminal';

  /// 执行站·Agent 族：`agent.message` / `agent.stop` / `agent.compact`。
  static const String executeAgent = 'system.execute.agent';

  /// 执行站·前端推送族：`ui.push`。
  static const String executeUi = 'system.execute.ui';

  /// 执行站·LLM 族：`llm.call`（硬设 JSON 返回形式，复用目标 agent 的模型）。
  static const String executeLlm = 'system.execute.llm';

  /// 执行站·工具族：`tool.call`（执行任意工具）。
  static const String executeTool = 'system.execute.tool';

  /// 执行站·会话族：`session.rename`（会话重命名）。
  static const String executeSession = 'system.execute.session';

  // ── 中转站（拦截-回填；每个点位各自唯一订阅者） ──────────────────────────

  /// 中转站·工具调用前（可改参数）。
  static const String relayToolPre = 'system.relay.tool.pre';

  /// 中转站·工具调用后（可改结果）。
  static const String relayToolPost = 'system.relay.tool.post';

  /// 中转站·LLM 处理（接管：插件产出这一跳的 LLM 响应，支持流式回填）。
  static const String relayLlmHandle = 'system.relay.llm.handle';

  /// 中转站·投入 LLM 前（改写请求体；仅"未被接管"时触发）。
  static const String relayLlmRequest = 'system.relay.llm.request';

  /// 中转站·上下文压缩过程（插件产出整份新上下文；无订阅者走系统内置 compact）。
  static const String relayContextCompact = 'system.relay.context.compact';

  /// 中转站·系统提示词构造过程（插件产出最终 system prompt）。
  static const String relayPromptSystem = 'system.relay.prompt.system';

  // ── 收集站（一对多收集 + 汇聚；不回填原数据流） ──────────────────────────

  /// 收集站·插件定义 tool（系统自带；收集站的接入点）。
  static const String collect = 'plugin.tool.define';

  // ── 退役 id（**只用于读侧迁移**，不再是实例 id） ─────────────────────────

  /// 退役：旧中转站（工具前/后共用、靠 payload.phase 区分）。
  ///
  /// 迁移规则：它的订阅**复制**到 [relayToolPre] 与 [relayToolPost]——原订阅者
  /// 行为等价（照样 pre / post 都收到），想只收一个的自己退订另一个。
  static const String legacyRelay = 'system.relay';

  /// 退役：旧执行站（九条命令共用）。执行站不可订阅，所以**没有订阅需要迁移**。
  static const String legacyExecute = 'system.execute';

  /// 全部**内置点位 id**（含收集站）。
  ///
  /// **新增内置点位必须加进来**：`PluginBus._subscribeToStation` 用它判定"这是内置站，
  /// 插件可以订阅"，不在集合里会被当成别人的自建站、被归属校验收掉。
  static const Set<String> all = <String>{
    broadcast,
    broadcastToolPre,
    broadcastToolPost,
    broadcastToolTimeout,
    executeFs,
    executeTerminal,
    executeAgent,
    executeUi,
    executeLlm,
    executeTool,
    executeSession,
    relayToolPre,
    relayToolPost,
    relayLlmHandle,
    relayLlmRequest,
    relayContextCompact,
    relayPromptSystem,
    collect,
  };

  /// 退役 id 集合（迁移判定用；它们不再出现在 [all] 里）。
  static const Set<String> retired = <String>{legacyRelay, legacyExecute};
}
