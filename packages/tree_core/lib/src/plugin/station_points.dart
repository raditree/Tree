import 'station_ids.dart';
import 'station_schema.dart';

/// **点位表**：内置站点的每个接入点（point）的类型 / 中文名 / 说明 / 命令 / 订阅别名。
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
      alias: '',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastToolPre,
      kind: StationKind.broadcast,
      label: '工具调用前',
      description: '广播站·工具调用前：每次工具调用**开始**时广播一条（单向通知，不回填）',
      alias: 'tool.pre',
    ),
    StationPointSpec(
      id: StationHubIds.broadcastToolPost,
      kind: StationKind.broadcast,
      label: '工具调用后',
      description: '广播站·工具调用后：每次工具调用**结束**时广播一条（含结果，单向通知）',
      alias: 'tool.post',
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
      commands: <String>['fs.read', 'fs.write', 'fs.list', 'fs.grep'],
    ),
    StationPointSpec(
      id: StationHubIds.executeTerminal,
      kind: StationKind.execute,
      label: '终端执行',
      description: '执行站·终端族：terminal.exec（含后台任务 hook 模式）',
      alias: 'terminal',
      commands: <String>['terminal.exec'],
    ),
    StationPointSpec(
      id: StationHubIds.executeAgent,
      kind: StationKind.execute,
      label: 'Agent 操作',
      description: '执行站·Agent 族：agent.message / agent.stop / agent.compact（发起上下文压缩）',
      alias: 'agent',
      commands: <String>['agent.message', 'agent.stop', 'agent.compact'],
    ),
    StationPointSpec(
      id: StationHubIds.executeUi,
      kind: StationKind.execute,
      label: '前端推送',
      description: '执行站·前端推送族：ui.push（复用 4.1 card 槽位帧）',
      alias: 'ui',
      commands: <String>['ui.push'],
    ),
    StationPointSpec(
      id: StationHubIds.executeLlm,
      kind: StationKind.execute,
      label: 'LLM 调用',
      description: '执行站·LLM 族：llm.call（站点处硬设 API 返回形式为 json，复用目标 agent 的模型）',
      alias: 'llm',
      commands: <String>['llm.call'],
    ),
    StationPointSpec(
      id: StationHubIds.executeTool,
      kind: StationKind.execute,
      label: '工具调用',
      description: '执行站·工具族：tool.call（执行任意工具：内置 / MCP / 插件工具同一入口）',
      alias: 'tool',
      commands: <String>['tool.call'],
    ),
    StationPointSpec(
      id: StationHubIds.executeSession,
      kind: StationKind.execute,
      label: '会话重命名',
      description: '执行站·会话族：session.rename（与 REST 同一 store 实现）',
      alias: 'session',
      commands: <String>['session.rename'],
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
    ),
    StationPointSpec(
      id: StationHubIds.relayToolPost,
      kind: StationKind.relay,
      label: '工具调用后',
      description: '中转站·工具调用后：拦截工具结果，插件可改写结果（fail-open）',
      alias: 'tool.post',
      maxSubscriptions: 1,
    ),
    StationPointSpec(
      id: StationHubIds.relayLlmHandle,
      kind: StationKind.relay,
      label: 'LLM 处理',
      description: '中转站·LLM 处理：插件接管这一跳的 LLM 响应（支持流式回填）；无订阅者走系统 LLM',
      alias: 'llm.handle',
      maxSubscriptions: 1,
    ),
    StationPointSpec(
      id: StationHubIds.relayLlmRequest,
      kind: StationKind.relay,
      label: '投入 LLM 前',
      description: '中转站·投入 LLM 前：改写即将投出的请求体（仅未被接管时触发）；无订阅者走原请求',
      alias: 'llm.request',
      maxSubscriptions: 1,
    ),
    StationPointSpec(
      id: StationHubIds.relayContextCompact,
      kind: StationKind.relay,
      label: '上下文压缩',
      description: '中转站·上下文压缩过程：插件产出摘要；无订阅者回退内置摘要器',
      alias: 'context.compact',
      maxSubscriptions: 1,
    ),
    StationPointSpec(
      id: StationHubIds.relayPromptSystem,
      kind: StationKind.relay,
      label: '系统提示词构造',
      description: '中转站·系统提示词构造过程：插件产出最终 system prompt；无订阅者用内置拼接结果',
      alias: 'prompt.system',
      maxSubscriptions: 1,
    ),
  ];

  /// 收集站点位（schema 由接入点决定，不在这里预建）。
  static const List<StationPointSpec> collects = <StationPointSpec>[
    StationPointSpec(
      id: StationHubIds.collect,
      kind: StationKind.collect,
      label: '插件工具定义',
      description: '收集站（系统自带）：插件按 schema 申报工具定义（名称/描述/参数/执行方式）',
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
