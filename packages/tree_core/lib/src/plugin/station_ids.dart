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

  /// 广播站·插件生命周期（**单向通知**，无回填）。
  ///
  /// 20261015-hot-restart 阶段 2 新增：重启 / 挂起期间插件对外仍是“正常状态”，
  /// 所以前端与审计插件不能靠“没回音”去猜它到哪个阶段了——阶段跃迁得有人主动说出来。
  /// 载荷 = `{plugin_id, lifecycle, generation, missed_heartbeats, reason, buffer}`；
  /// 判定源与 `health` 同一个（`LivenessTracker`），**不另造一套时钟**。
  ///
  /// ⚠ 与执行站命令 `plugin.state` **不是同一个东西**：这里是“核心推给你”，
  /// 那里是“你去问一次”。两套寻址空集不重叠（广播点位靠 station+point，
  /// 执行命令靠 command 名），但名字相近，写插件时别看错。
  static const String broadcastPluginState = 'system.broadcast.plugin.state';

  /// 广播站·本轮正常结束（**单向通知**，无回填）。
  ///
  /// 20261015-hot-restart 阶段 6（A 级点位批）新增：投递口不是「要新建」，而是
  /// `ConversationService` 本轮收尾那一处（它已经把 `msg_end` 帧发给前端了）。
  /// 载荷 = `{point, agent_id, session_id, team_id, content_chars, elapsed_ms, finish_reason, tool_rounds}`；
  /// **不带正文**（正文有会话与 REST 两个正经读处，广播里塞全文等于把隐私复制进每个插件）。
  static const String broadcastTurnDone = 'system.broadcast.turn.done';

  /// 广播站·本轮被取消（**单向通知**，无回填）。
  ///
  /// 与 [broadcastTurnDone] **互斥**：同一轮只出一条（取消的轮不算正常结束）。
  /// 载荷额外带 `source`（`interjection` = 被新消息插话，`user_stop` = 用户按停止）
  /// 与会话/临时员工归属——不变量 5 的两种取消在审计里必须分得开（插话不该被记成
  /// “用户停了这一轮”），否则「谁停的」这个问题又只能靠猜。
  static const String broadcastTurnCancelled = 'system.broadcast.turn.cancelled';

  /// 广播站·本轮错误终止（**单向通知**，无回填）。
  ///
  /// 载荷 = `{point, agent_id, session_id, team_id, error, failed_after_tools}`。
  /// `error` 就是核心已经发给用户那句**可读文案**（不变量 6），不另造一套说法。
  /// 取消与错误同时发生时**先报错误**：取消是用户意图，错误才是这一轮的实际结论。
  static const String broadcastTurnError = 'system.broadcast.turn.error';

  /// 广播站·提问暂停（**单向通知**，无回填）。
  ///
  /// 触发点 = `QuestionBroker.ask` 把问题**落盘并推帧之后**、开始等待作答的那一刻
  /// （不是工具执行前：那时还证明不了这个问题真的在等人）。
  /// 载荷 = `{point, agent_id, session_id, team_id, question_id, question_count}`；
  /// **不带题面与选项**（那是用户与 agent 之间的内容，审计只需要知道「谁在等、等几道」）。
  static const String broadcastAskPaused = 'system.broadcast.ask.paused';

  /// 广播站·插件清单对账结果（**单向通知**，无回填）。
  ///
  /// 触发点 = `PluginBus.applyConfigs()` 逐条对账**完成后**，每条一个动作一个 topic
  /// `config.changed`；载荷的 `action` 取值与 `PluginReconcileKind` 同源（
  /// `started` / `stopped` / `restarted` / `failed`）。**`unchanged` 一律不广播**：
  /// 没改动的对账是噪声（面板插件会被白叫醒，而它读到的状态与上一帧完全一样）。
  static const String broadcastConfigChanged = 'system.broadcast.config.changed';

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

  /// 执行站·SSH 族：`ssh.reconnect`（重建目标 agent 的远端链路）。
  static const String executeSsh = 'system.execute.ssh';

  /// 执行站·插件族：`plugin.list` / `plugin.restart` / `plugin.suspend` /
  /// `plugin.state` / `plugin.stateDump` / `plugin.stateFetch`。
  ///
  /// 2026-10-15 插件热重启（阶段 1）新增：插件管理动作从「只能由核心自己触发」
  /// 变成「插件与 agent 可以下命令」，走的仍是执行站那套白名单 + scope 校验，
  /// 不新增 RPC method（D10）。其中 `plugin.stateDump` / `plugin.stateFetch` 是
  /// **插件对自己快照**的存取：归属校验只许操作以发起者 pluginId 开头的键，
  /// 且这两条**不申报成 agent tool**（D9：它们是生命周期原语，不是给模型使唤的能力）。
  static const String executePlugin = 'system.execute.plugin';

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

  /// 中转站·SSH 执行（2026-10-15 新增）：**SSH 工作空间的中转执行点**。
  ///
  /// 定位：中转站不再只是「数据拦截-回填」的拓展点位，而是「**处理拓展点位**」——
  /// 只要核心把一次工作交给点位、订阅者接管并回填结果，就是同一套语义。SSH 执行
  /// 因此与 LLM 接管 / 工具改写 / 上下文压缩走同一套 fail-open / scope / stream 规则：
  /// - 无订阅者 ⇒ 核心回退内置 `dartssh2`（红线不变）；
  /// - 有订阅者 ⇒ 核心每次 SSH 操作（ensure / request / state / reconnect / close /
  ///   shell.* 等）都投成一次 `station/request`，插件自己完成到目标机的通信；
  /// - 心跳丢失 / 未回填 / 回包非法 ⇒ fail-open（回退内置）并写可读原因；
  /// - 唯一订阅者（中转站 `scopeKeyUnique`）。
  ///
  /// 兼容：SSH 插件仍同时保留 `hello.capabilities = ['ssh-executor']` 与既有
  /// `tunnel.*` 方法（旧核心与新核心都能对话）；核心侧读 `available` 时任一信号成立
  /// 即认「有中转站」，让**热切换窗口**（先订上站点 vs 先跑起 tunnel 方法）两种顺序都稳定。
  static const String relaySshExecute = 'system.relay.ssh.execute';

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
    broadcastPluginState,
    broadcastTurnDone,
    broadcastTurnCancelled,
    broadcastTurnError,
    broadcastAskPaused,
    broadcastConfigChanged,
    executeFs,
    executeTerminal,
    executeAgent,
    executeUi,
    executeLlm,
    executeTool,
    executeSession,
    executeSsh,
    executePlugin,
    relayToolPre,
    relayToolPost,
    relayLlmHandle,
    relayLlmRequest,
    relayContextCompact,
    relayPromptSystem,
    relaySshExecute,
    collect,
  };

  /// 退役 id 集合（迁移判定用；它们不再出现在 [all] 里）。
  static const Set<String> retired = <String>{legacyRelay, legacyExecute};
}
