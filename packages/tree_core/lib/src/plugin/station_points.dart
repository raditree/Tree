import 'station_ids.dart';
import 'station_schema.dart';

/// **点位表**：内置站点的每个接入点（point）的类型 / 中文名 / 说明 / 介绍 / 命令 / 订阅别名。
///
/// 一个点位 = **一个独立的站点实例**（见 `station_ids.dart` 的库注释）。本表是点位的
/// **唯一定义处**：`StationHub` 按它懒创建与预建、`ExecuteStation` 按它取命令白名单、
/// `PluginBus` 按它做命令路由与 `station/subscribe` 的别名解析。
///
/// 为什么不写成散在各处的 switch：点位是**数据**不是行为——加一个点位只该改这张表
/// （外加 `StationHubIds` 一个常量），不该去动订阅、路由、预建、面板四段逻辑。
class StationPointSpec {
  const StationPointSpec({
    required this.id,
    required this.kind,
    required this.label,
    required this.description,
    required this.readme,
    required this.alias,
    this.maxSubscriptions = 32,
    this.commands = const <String>[],
  });

  /// 站点 id（= `StationHubIds` 里的常量）。
  final String id;

  /// 站点类型（四类之一）。
  final StationKind kind;

  /// 中文点位名（日志 / 面板 / 可读错误用）。
  final String label;

  /// 站点说明（落盘与快照里的 `description`）。
  final String description;

  /// **站点介绍**（落盘与快照里的 `readme`；面板的「站点详情页」读它）。
  ///
  /// 口径：**每个站点都必须有介绍**——插件自建站由 `station/register` 的 `readme`
  /// 参数必填（见 `PluginBus._handleStationRegister`），内置点位就是这里。
  /// 写法：这个站干什么 → 什么时候被触发 → 订阅者该怎么回 → 有什么限制。
  final String readme;

  /// 订阅别名（`station/subscribe` 的 `point` 参数取值，也接受完整 id 或 id 后缀）。
  ///
  /// 例如中转站 LLM 接管点的别名是 `llm.handle`——插件写
  /// `{station: 'relay', point: 'llm.handle'}` 比写完整 id 更抗改名。
  final String alias;

  /// 订阅上限（只有多订阅者站点用得上；中转站恒为 1，见 `RelayStation.scopeKeyUnique`）。
  final int maxSubscriptions;

  /// **执行站点位**拥有的命令白名单（其它类型恒为空）。
  final List<String> commands;

  /// 点位名（去掉 `system.<类型>.` 前缀）：`system.relay.tool.pre` → `tool.pre`。
  ///
  /// 经典点位（`system.broadcast` 这类没有点位后缀的）返回 id 本身。
  String get suffix {
    final String prefix = 'system.${kind.wire}.';
    return id.startsWith(prefix) ? id.substring(prefix.length) : id;
  }

  @override
  String toString() => 'StationPointSpec($id, ${kind.wire}, $label)';
}

/// 内置点位表（顺序即面板展示顺序）。
abstract final class StationPoints {
  /// 广播站点位。
  static const List<StationPointSpec> broadcasts = <StationPointSpec>[
    StationPointSpec(
      id: StationHubIds.broadcast,
      kind: StationKind.broadcast,
      label: '通用主题',
      description: '广播站（系统自带）：插件发布 topic → 多订阅者接收 + 持久公告板',
      readme:
          '通用主题广播站：任何人 publish(topic, payload) 一次，全部匹配 scope 的订阅者'
          '各收到一条。适合“谁都需要、但谁都不必回”的事件通知（进度、变更提醒）。'
          '回包只当送达确认，内容不参与业务。本站同时是**持久公告板**：无订阅者也会入板，'
          '重启后仍可回看最近若干条。订阅者之间互不影响；scope 不匹配的会被显跳过。',
      alias: '',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastToolPre,
      kind: StationKind.broadcast,
      label: '工具调用前',
      description: '广播站·工具调用前：每次工具调用**开始**时广播一条（单向通知，不回填）',
      alias: 'tool.pre',
      readme:
          '工具调用**开始前**的单向通知：每次工具调用起点广播一条（载荷含工具名与参数摘要）。'
          '适合审计 / 计数 / UI 提醒。回包内容不会被使用，也不影响工具执行；'
          '要**改写参数**请订中转站的同名点位（tool.pre），而不是在这里回 payload。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastToolPost,
      kind: StationKind.broadcast,
      label: '工具调用后',
      description: '广播站·工具调用后：每次工具调用**结束**时广播一条（含结果，单向通知）',
      alias: 'tool.post',
      readme:
          '工具调用**结束后**的单向通知：每次调用完成广播一条（含结果与成败）。'
          '回包仅作送达确认；要**改写工具结果**请订中转站的 tool.post。'
          '与同名中转点位是两个独立实例：这里广播给所有订阅者，那里只给唯一处理者。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastToolTimeout,
      kind: StationKind.broadcast,
      label: '工具运行超时',
      description:
          '广播站·工具运行超时：一次工具运行**跨过阈值（默认 120s）时广播一次**'
          '（单向通知；载荷含 handle / tool / command / elapsed_ms，可用执行站 '
          'tool.close 显式关闭）',
      alias: 'tool.timeout',
      readme:
          '工具运行**跨过超时阈值（默认 120s）时广播一次**：不是周期心跳，一次运行最多一条。'
          '载荷含 handle / tool / command / elapsed_ms。收到它可以做什么：提醒用户、记录长任务，'
          '或用执行站工具族的 `tool.close`（带 handle）**显式关闭**这次运行。'
          '核心不会因为超阈值自己杀进程——关闭必须有人显式下令。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastPluginState,
      kind: StationKind.broadcast,
      label: '插件生命周期',
      description:
          '广播站·插件生命周期：每次阶段跃迁（booting / ready / restarting / suspended / '
          'failed / stopped）广播一条，失活标记也广播一条（单向通知；载荷含 plugin_id / '
          'lifecycle / generation / missed_heartbeats / reason / buffer）',
      alias: 'plugin.state',
      readme:
          '插件**生命周期阶段**的单向通知：发布点只有两处——生命周期的跃迁（集中在 '
          '`PluginBus.lifecycleOf` 的唯一写入口）与失活标记（与 `health` 同一个判定源 '
          '`LivenessTracker`，**不另造时钟**）。回包仅作送达确认，内容不参与业务。'
          '为什么需要它：重启窗口里插件对外仍是“正常状态”（不被路由真实任务，站点请求'
          '被有界暂存后重放），所以“现在到哪个阶段了”必须由核心推出来，而不是让前端'
          '靠“没回音”去猜。限制：**活性看 `health`、启停看 `status`、阶段看 `lifecycle`**，'
          '三者是独立的轴，谁也不得吃掉谁；要看某个插件的当前读数请下执行站命令 '
          '`plugin.state`（那是“问”，这里是“推”）。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastTurnDone,
      kind: StationKind.broadcast,
      label: '本轮结束',
      description:
          '广播站·本轮结束：agent 一轮生成**正常收尾**时广播一条（单向通知；载荷含 '
          'agent_id / session_id / team_id / content_chars / elapsed_ms / finish_reason / tool_rounds）',
      alias: 'turn.done',
      readme:
          '一轮生成**正常结束**时的单向通知：发布点在会话服务收尾那一处（与前端收到的 '
          'msg_end 同一时机）。适合做耗时统计、轮次上限、计费汇总。载荷**只有度量，不带正文**：'
          '正文的正经读处是会话存储与 REST，广播里塞全文等于把用户的内容复制进每一个插件。'
          '回包只当送达确认。与 turn.cancelled / turn.error **互斥**：同一轮只会出一条，'
          '统计口径因此不需要先判“到底有几个结束事件”。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastTurnCancelled,
      kind: StationKind.broadcast,
      label: '本轮取消',
      description:
          '广播站·本轮取消：一轮生成被**用户停止**或**被新消息插话**时广播一条（单向通知；'
          '载荷含 source = user_stop | interjection，与 turn.done 互斥）',
      alias: 'turn.cancelled',
      readme:
          '一轮被**取消**时的单向通知：用户按停止、或新消息插话打断本轮（插话会先停旧轮再开新轮）。'
          '为什么单独一个点位而不复用 turn.done 加个键：两种结局的统计口径完全不同（失败率、'
          '平均耗时都靠它），把它们挤在一条里就只能靠“读一个可选键”分家，而那种形状迟早漂移。'
          '`source` 固定两个取值（`user_stop` / `interjection`）：**插话不算“用户停了本轮”**。'
          '回包不参与业务，也不会因为广播改变取消语义（取消已发生，这里是通知）。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastTurnError,
      kind: StationKind.broadcast,
      label: '本轮失败',
      description:
          '广播站·本轮失败：一轮以可读错误文案收尾时广播一条（单向通知；载荷含 error / '
          'failed_after_tools；文案与用户看到的同一句）',
      alias: 'turn.error',
      readme:
          '一轮**错误终止**时的单向通知：载荷里的 `error` 就是核心已经发给用户那句可读文案'
          '（不另造一套说法），`failed_after_tools` 表示它是不是在工具循环中途坏的。'
          '取消与错误同时发生时**先报错误**：取消是用户意图，错误才是这一轮的实际结论。'
          '本点位**不能判死**也不改变重试：重试退避是传输层的事，插件在这里只能观察。'
          '广播是单向的：订阅者抛异常也不会让生成失败（与 turn.done 同一个派发入口）。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastAskPaused,
      kind: StationKind.broadcast,
      label: '提问暂停',
      description:
          '广播站·提问暂停：`ask_user_question` 落盘并推帧后、开始等作答时广播一条'
          '（单向通知；载荷含 question_id / question_count，**不带题面与选项**）',
      alias: 'ask.paused',
      readme:
          'agent **等人作答**这一刻的单向通知：发布点在提问回路把问题落盘、推帧之后，开始'
          '等待之前（不是工具执行前：那时还证明不了这个问题真的在等人）。适合做“长时间没人答”'
          '提醒、把待答问题转送到其它渠道。载荷**不带题面与选项**，只有 `question_id` 与'
          ' `question_count`：那是用户与 agent 之间的内容，审计只需要知道“谁在等、等几道”。'
          '回包**不会**替你答题：作答只有面板 / 右栏 / REST 那三条用户入口，'
          '插件代答会直接假成“用户说了话”。',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastConfigChanged,
      kind: StationKind.broadcast,
      label: '插件清单变更',
      description:
          '广播站·插件清单变更：`applyConfigs()` 逐条对账**完成后**每条动作广播一条'
          '（单向通知；action = started | stopped | restarted | failed，与 PluginReconcileKind 同源；'
          '**unchanged 不广播**）',
      alias: 'config.changed',
      readme:
          '插件**清单对账结果**的单向通知：面板改开关、REST 写条目、发布仓库装完都会走到'
          '同一条对账（`PluginBus.applyConfigs`），这里就在那一遍逐条结果之后发。载荷的 `action` '
          '与对账结论同源（started / stopped / restarted / failed），带 plugin_id / reason / generation。'
          '**unchanged 一律不发**：“没改动”不是变更；把它也广播出去，监听插件会被每次对账白叫醒'
          '一次，而它读到的状态与上一帧完全一样。回包不参与业务；**这个点位不能反过来改配置**'
          '（插件写 plugins.yaml 等于绕开面板那条用户入口，见不变量 29）。',
    ),
  ];

  /// 执行站点位（按命令族）。
  static const List<StationPointSpec> executes = <StationPointSpec>[
    StationPointSpec(
      id: StationHubIds.executeFs,
      kind: StationKind.execute,
      label: '文件操作',
      description: '执行站·文件操作族：fs.read / fs.write / fs.list / fs.grep',
      alias: 'fs',
      readme:
          '文件操作族（fs.read / fs.write / fs.list / fs.grep）：**执行站不订阅、不触发插件**，'
          '它是插件主动下命令的入口。命令按目标 agent 落到它的工作空间（本地目录或远端），'
          '因此不需要自己拼路径，也不能跨 team 访问（scope 不成立会被显拒）。'
          '白名单外的命令一律报错，不会“看起来执行了”。',
      commands: <String>['fs.read', 'fs.write', 'fs.list', 'fs.grep'],
    ),
    StationPointSpec(
      id: StationHubIds.executeTerminal,
      kind: StationKind.execute,
      label: '终端执行',
      description: '执行站·终端族：terminal.exec（含后台任务 hook 模式）',
      alias: 'terminal',
      readme:
          '终端族（terminal.exec）：在目标 agent 的工作空间执行命令，前台等结果或以 hook 模式转后台任务。'
          '它与内置工具走同一条执行链，所以长任务同样会收到超时广播（广播站 tool.timeout），'
          '也可以用工具族的 `tool.close` 显式关闭。执行站不可订阅，只能下命令。',
      commands: <String>['terminal.exec'],
    ),
    StationPointSpec(
      id: StationHubIds.executeAgent,
      kind: StationKind.execute,
      label: 'Agent 操作',
      description: '执行站·Agent 族：agent.message / agent.stop / agent.compact（发起上下文压缩）',
      alias: 'agent',
      readme:
          'Agent 族（agent.message / agent.stop / agent.compact）：往会话里投一条消息、停下来、'
          '或显式发起一次上下文压缩。压缩结果仍由会话自已有：本站只负责“下令”，不直接改写历史。'
          '需要接管压缩本身（自己产出新上下文）请订中转站的 context.compact。',
      commands: <String>['agent.message', 'agent.stop', 'agent.compact'],
    ),
    StationPointSpec(
      id: StationHubIds.executeUi,
      kind: StationKind.execute,
      label: '前端推送',
      description: '执行站·前端推送族：ui.push（复用 4.1 card 槽位帧）',
      alias: 'ui',
      readme:
          '前端推送族（ui.push）：把一个卡片推到界面的约定槽位（slot_key）。'
          '帧形状与插件 UI 系统的 card 槽位完全一致，所以不需要额外注册 UI。'
          '推送是**尽力而为**：没连前端时命令会失败并回报原因，不会静默丢帧。',
      commands: <String>['ui.push'],
    ),
    StationPointSpec(
      id: StationHubIds.executeLlm,
      kind: StationKind.execute,
      label: 'LLM 调用',
      description: '执行站·LLM 族：llm.call（站点处硬设 API 返回形式为 json，复用目标 agent 的模型）',
      alias: 'llm',
      readme:
          'LLM 族（llm.call）：复用目标 agent 的模型发一次调用，站点处硬把返回形式设成 JSON。'
          '它与中转站的 llm.handle 区别在这里：**llm.call 是插件主动问一次**，'
          'llm.handle 是插件接管会话本身的那一跳。调用失败会把原文带回来（payload），'
          '便于本地修复重试，而不是丢掉已经付过费的那一次。',
      commands: <String>['llm.call'],
    ),
    StationPointSpec(
      id: StationHubIds.executeTool,
      kind: StationKind.execute,
      label: '工具调用',
      description:
          '执行站·工具族：tool.call（执行任意工具：内置 / MCP / 插件工具同一入口）、'
          'tool.close（显式关闭一次正在执行的工具运行，args {handle}）',
      alias: 'tool',
      readme:
          '工具族（tool.call / tool.close）：tool.call 执行**任意**工具（内置 / MCP / 插件工具'
          '同一个入口），tool.close 按 handle 显式关闭一次正在跑的工具运行。'
          '这是“工具”能力给插件的唯一入口：不要自己拼子进程去跑内置工具，'
          '否则权限与工作空间归属都绕过核心。关闭**不自动发生**，超阈值只广播警告。',
      commands: <String>['tool.call', 'tool.close'],
    ),
    StationPointSpec(
      id: StationHubIds.executeSession,
      kind: StationKind.execute,
      label: '会话重命名',
      description: '执行站·会话族：session.rename（与 REST 同一 store 实现）',
      alias: 'session',
      readme:
          '会话族（session.rename）：改一个会话的标题，与 REST 端点是同一个 store 实现。'
          '它只改名字，不动消息历史；找不到会话时显式报错。',
      commands: <String>['session.rename'],
    ),
    StationPointSpec(
      id: StationHubIds.executeSsh,
      kind: StationKind.execute,
      label: '链路重连',
      description:
          '执行站·SSH 族：ssh.reconnect（重建目标 agent 的远端链路；args {agent_id?}；与 REST 端点同一实现）',
      alias: 'ssh',
      readme:
          '链路族（ssh.reconnect）：重建目标 agent 的远端链路（可选 args {agent_id}）。'
          '口径与“心跳判活”分得很清楚：判死只认连续 N 拍心跳丢失，重连是判死**之后**的动作，'
          '不引入任何新的时长上限。不是 SSH 工作空间 / 配置不完整 ⇒ 直接拒并给原因。',
      commands: <String>['ssh.reconnect'],
    ),
    StationPointSpec(
      id: StationHubIds.executePlugin,
      kind: StationKind.execute,
      label: '插件管理',
      description:
          '执行站·插件族：plugin.list / plugin.restart / plugin.suspend / plugin.state /'
          ' plugin.stateDump / plugin.stateFetch（插件热重启的控制面入口）',
      alias: 'plugin',
      readme:
          '插件族（plugin.list / plugin.restart / plugin.suspend / plugin.state /'
          ' plugin.stateDump / plugin.stateFetch）：这一族管的是**插件自己**。'
          '它在插件调 `station/command` 时被触发，不在核心内部自动跑。'
          '回包口径：成功回 `{ok:true, ...结论}`，失败回可读中文原因（不假装做过）；'
          '`stateDump` / `stateFetch` 的回包额外带 `dump_id`，供下一次取回与消费对账。'
          '限制：`plugin.list` / `plugin.restart` / `plugin.state` 按请求 scope 判归属，'
          '证明不了 team 就拒；`plugin.stateDump` / `plugin.stateFetch` 是**团队级命令**'
          '（发起者是插件本身，没有 agent 归属），因此只认「只能动以发起者 pluginId '
          '开头的快照」这一条归属口径，且两者**不申报成 agent tool**——它们是生命周期'
          '原语，不是给模型使唤的能力。快照只进核心进程内存，不落盘。',
      commands: <String>[
        'plugin.list',
        'plugin.restart',
        'plugin.suspend',
        'plugin.state',
        'plugin.stateDump',
        'plugin.stateFetch',
      ],
    ),
  ];

  /// 中转站点位（每个点位各自唯一订阅者）。
  static const List<StationPointSpec> relays = <StationPointSpec>[
    StationPointSpec(
      id: StationHubIds.relayToolPre,
      kind: StationKind.relay,
      label: '工具调用前',
      description: '中转站·工具调用前：拦截 tool_call 报文，插件可改写参数（fail-open）',
      alias: 'tool.pre',
      maxSubscriptions: 1,
      readme:
          '工具调用**前**的中转点：拦下 tool_call 报文，订阅者可以改写参数。'
          '与同名广播点位是两回事：这里**只有一个处理者**（先到先得），改写会真得生效。'
          '回包语义：回字符串 / 对象 / 数组 = **整体替换**原数据；回空 = 不改动（建议同时回一个'
          'reason 说明为什么没接管）。本站 **fail-open**：无订阅者 / 心跳丢 / 回包非法一律放行原数据'
          '并记录原因，绝不因插件失败而中断工具。',
    ),
    StationPointSpec(
      id: StationHubIds.relayToolPost,
      kind: StationKind.relay,
      label: '工具调用后',
      description: '中转站·工具调用后：拦截工具结果，插件可改写结果（fail-open）',
      alias: 'tool.post',
      maxSubscriptions: 1,
      readme:
          '工具调用**后**的中转点：拦下工具结果，订阅者可以改写结果文本（典型：脱敏 / 精简 / 补充上下文）。'
          '全站唯一处理者，回包语义与 fail-open 口径同工具前点位（替换 / 不改动 / 放行原值）。'
          '只想“看一眼结果”请订广播站的 tool.post，不要占住这个唯一位置。',
    ),
    StationPointSpec(
      id: StationHubIds.relayLlmHandle,
      kind: StationKind.relay,
      label: 'LLM 处理',
      description: '中转站·LLM 处理：插件接管这一跳的 LLM 响应（支持流式回填）；无订阅者走系统 LLM',
      alias: 'llm.handle',
      maxSubscriptions: 1,
      readme:
          'LLM **响应接管点**：订上它，会话里这一跳的 LLM 响应就归你算（可以用自己的模型 / 自己的代理），'
          '支持边生成边 `station/stream` 流式回填。无订阅者时走系统 LLM，这也是“关掉插件会话照常工作”的原因。'
          '全站唯一处理者：想接管就显式 `replace`，接管后请自己按 team / agent 转发，'
          '不要让多个插件各抢一份（抢不到的那个会静默失效）。',
    ),
    StationPointSpec(
      id: StationHubIds.relayLlmRequest,
      kind: StationKind.relay,
      label: '投入 LLM 前',
      description: '中转站·投入 LLM 前：改写即将投出的请求体（仅未被接管时触发）；无订阅者走原请求',
      alias: 'llm.request',
      maxSubscriptions: 1,
      readme:
          '投入 LLM **之前**改写请求体（拼 history / 改系统提示之外的部分 / 注入工具列表）。'
          '只在 llm.handle **没被接管**时触发——已经被接管的会话不会再走这里（否则两处都改会让结果无法归因）。'
          'fail-open：不改就原样投出；回包类型非法会显式记录并放行原请求。',
    ),
    StationPointSpec(
      id: StationHubIds.relayContextCompact,
      kind: StationKind.relay,
      label: '上下文压缩',
      description: '中转站·上下文压缩过程：插件产出整份新上下文（规划也归它）；无订阅者走系统内置 compact',
      alias: 'context.compact',
      maxSubscriptions: 1,
      readme:
          '上下文压缩接管点：订阅者自己产出**整份新上下文**（摘要 + 必读文件 + todo 快照都算它的），'
          '而不只是“压缩一下”。无订阅者走核心内置 compact。'
          '任何一步失败（心跳丢 / 回包非法 / 自己报失败）都会退回内置压缩，**不会丢历史**——'
          '把会话弄坏这条红线由站点层兜住，不由插件兜住。',
    ),
    StationPointSpec(
      id: StationHubIds.relayPromptSystem,
      kind: StationKind.relay,
      label: '系统提示词构造',
      description: '中转站·系统提示词构造过程：插件产出最终 system prompt；无订阅者用内置拼接结果',
      alias: 'prompt.system',
      maxSubscriptions: 1,
      readme:
          '系统提示词构造接管点：订阅者返回最终 system prompt（整串替换）。'
          '无订阅者就用核心拼好的内置结果。只想“追一段”也要回整串：'
          '本站是替换语义，不是追加语义，回空会被当成“不改动”而不是“没要求”。',
    ),
    StationPointSpec(
      id: StationHubIds.relaySshExecute,
      kind: StationKind.relay,
      label: 'SSH 执行',
      description:
          '中转站·SSH 执行：核心每次将一条 SSH 工作空间操作交给插件（建隧道/读写/命令/PTY/…），'
          '插件自己完成到目标机的通信；无订阅者回退内置 dartssh2（fail-open）',
      alias: 'ssh.execute',
      maxSubscriptions: 1,
      readme:
          'SSH 执行中转点：核心在需要读写远端文件 / 执行远端命令 / 建或销隧道 / 拉心跳 / '
          '开 PTY 时，把一次操作投给本站。订阅者（ssh_executor 插件）自己持 dartssh2 + '
          'tree_agent 通道，处理完毕后以同一形状的 payload 回包。\n'
          '与同名旧体系的关系：插件同时保留 hello.capabilities 与 tunnel.* 方法（向后兼容），'
          '核心侧任信号命中即认「有中转站」——热切换窗口两种启动顺序都稳定。\n'
          'fail-open：无订阅者 / 心跳丢 / 回包非法 ⇒ 核心回退内置 dartssh2，写可读原因，'
          '绝不因插件失败而“SSH 不可用”。本站只有一个订阅者（中转站 scopeKeyUnique）。',
    ),
  ];

  /// 收集站点位（schema 由接入点决定，不在这里预建）。
  static const List<StationPointSpec> collects = <StationPointSpec>[
    StationPointSpec(
      id: StationHubIds.collect,
      kind: StationKind.collect,
      label: '插件工具定义',
      description: '收集站（系统自带）：插件按 schema 申报工具定义（名称/描述/参数/执行方式）',
      readme:
          '工具定义收集站：核心刷新工具表时向**全部订阅者**发一次采集请求（附带信息可选），'
          '每个订阅者按站点 schema 回自己的工具定义。产出不过 schema 校验的只丢掉那一个并显式列出，'
          '不影响其他人（部分结果语义）。工具真正被执行时走执行站工具族的 tool.call。',
      alias: '',
    ),
  ];

  /// 全部内置点位（顺序：广播 → 执行 → 中转 → 收集）。
  static const List<StationPointSpec> all = <StationPointSpec>[
    ...broadcasts,
    ...executes,
    ...relays,
    ...collects,
  ];

  /// 按 id 取点位定义（不存在返回 null）。
  static StationPointSpec? byId(String id) {
    final String key = id.trim();
    if (key.isEmpty) return null;
    for (final StationPointSpec spec in all) {
      if (spec.id == key) return spec;
    }
    return null;
  }

  /// 取某类型的全部点位。
  static List<StationPointSpec> ofKind(StationKind kind) => all
      .where((StationPointSpec spec) => spec.kind == kind)
      .toList(growable: false);

  /// **命令 → 所属执行站点位**（`station/command` 的分发依据）。
  ///
  /// 返回 null = 命令不在任何点位里（白名单外，由执行站显式拒绝）。
  static StationPointSpec? ownerOfCommand(String command) {
    final String key = command.trim();
    if (key.isEmpty) return null;
    for (final StationPointSpec spec in executes) {
      if (spec.commands.contains(key)) return spec;
    }
    return null;
  }

  /// 全部执行站命令（白名单并集；站点层与挂载位置复核共用）。
  static Set<String> get allCommands => <String>{
    for (final StationPointSpec spec in executes) ...spec.commands,
  };

  /// **订阅别名解析**（`station/subscribe` 的 `{station, point?}`）。
  ///
  /// - `station` = 类型线名（relay / broadcast；execute 不可订阅）；
  /// - `point` = 点位别名（[StationPointSpec.alias]）、完整 id、或 id 后缀；
  ///   **留空 = 该类下的"经典点位"**——中转站留空是**工具前 + 工具后两个点位**
  ///   （老插件写 `station: 'relay'` 即一次订两个，行为与点位化之前等价），
  ///   广播站留空是通用主题 `system.broadcast`。
  ///
  /// 返回命中的点位（可能多个）；空列表 = 解析不出来（调用方给可读错误）。
  static List<StationPointSpec> resolveAlias({
    required String kindWire,
    String point = '',
  }) {
    final StationKind? kind = StationKind.fromWire(kindWire);
    if (kind == null || !kind.subscribable) return const <StationPointSpec>[];
    final List<StationPointSpec> pool = ofKind(kind);
    final String key = point.trim();
    if (key.isEmpty) {
      return switch (kind) {
        // 中转站：留空 = 工具前 / 工具后两个点位（点位化之前就是一个实例收两段）
        StationKind.relay => relays
            .where(
              (StationPointSpec spec) =>
                  spec.id == StationHubIds.relayToolPre ||
                  spec.id == StationHubIds.relayToolPost,
            )
            .toList(growable: false),
        _ => <StationPointSpec>[pool.first],
      };
    }
    for (final StationPointSpec spec in pool) {
      if (spec.id == key || spec.suffix == key || spec.alias == key) {
        return <StationPointSpec>[spec];
      }
    }
    return const <StationPointSpec>[];
  }

  /// 订阅别名解析的可读提示（错误文案里列出可用点位）。
  static String describeAliases(StationKind kind) => ofKind(kind)
      .map(
        (StationPointSpec spec) =>
            spec.alias.isEmpty ? spec.id : '${spec.alias}（${spec.id}）',
      )
      .join('、');
}
