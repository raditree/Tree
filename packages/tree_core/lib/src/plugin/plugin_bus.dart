import 'dart:async';
import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart' show PluginRpcMethods;
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import '../agent/agent_engine.dart';
import '../agent/compaction_service.dart';
import '../llm/llm_types.dart';
import '../llm/openai_codec.dart';
import '../store/atomic_file.dart';
import '../store/tree_store.dart';
import '../store/yaml_codec.dart';
import '../util/liveness.dart';
import 'agent_events.dart';
import 'execute_mounts.dart';
import 'plugin_capability.dart';
import 'plugin_host.dart';
import 'plugin_lifecycle.dart';
import 'plugin_restart_buffer.dart';
import 'plugin_state_pool.dart';
import 'plugin_tool_definition.dart';
import 'plugin_ui_bridge.dart';
import 'station_ids.dart';
import 'station_instance.dart';
import 'station_points.dart';
import 'station_runtime.dart';
import 'station_schema.dart';
import 'station_scope.dart';
import 'station_store.dart';
import 'stations.dart';

/// 站点四元组的**运行期**解析器：插件配置 + 调用点上下文 → 四元组。
///
/// 见 [PluginBus.stationScopeResolver]（主控可在核心启动后注入）。
typedef RuntimeStationScopeResolver = StationScope Function(
  PluginConfig config,
  StationScopeContext context,
);

/// 一次压缩请求里捎给插件的**最近用量行**（`<会话目录>/usage.jsonl`）。
///
/// 为什么需要这条路：逐调用用量落在**数据根**下的会话目录里，而插件（`fs.read`
/// 只在工作空间作用域内）**读不到数据根**——于是"这次压缩花了多少 token""内置
/// 兜底那次花了多少"在插件面板上永远是空白。核心能同时够到账本与插件，所以在
/// 压缩中转 payload 里捎上"最近 N 行"，插件不必也不该去猜文件在哪。
///
/// [path] 只作排障用（插件拿到的只是一个字符串）；[calls] 是**解析后的对象**，
/// 形状 = `UsageCall.toJson()`（即 `usage.jsonl` 的行）。
class PluginUsageRecent {
  const PluginUsageRecent({required this.path, required this.calls});

  /// 账本文件路径（`<数据根>/data/<agent>/<session>/usage.jsonl`）。
  final String path;

  /// 最近的调用（**早 → 晚**，最多 [PluginBus.maxRecentUsageLines] 行）。
  final List<Map<String, dynamic>> calls;
}

/// 「最近用量行」提供者（**接线注入**，与 [PluginBus.log] /
/// [PluginBus.compactionSkipSink] 同范式）。
///
/// 返回 null = 这条通路没接（payload 里就不会出现 `recent_usage`）；
/// 抛异常 / 读不到文件 ⇒ 由 [PluginBus.relayCompaction] 收敛成"不带这个键"——
/// 用量是**遥测**，它出问题绝不该影响一次压缩（fail-open）。
typedef PluginUsageRecentProvider = Future<PluginUsageRecent?> Function(
  String agentId,
  String sessionId,
);

/// 中转点 `tool.probe` 的**三档答案**（阶段 6）。
///
/// 为什么不是一个 `String?`：“没接管”与“接管了、肯定没有”在调用方那里是两个
/// 完全不同的动作（前者继续查库，后者直接停在等显式取消），一个 null 分不出这两件事。
final class StationToolProbeVerdict {
  const StationToolProbeVerdict({required this.found, this.text = ''});

  /// 插件说这次调用**已有结果**（true 时 [text] 就是那段原文）。
  final bool found;

  /// 结果原文（[found]=false 时为空）。
  final String text;
}

/// 插件总线（M6b + M9 Wave 3-F）：配置、实例生命周期、事件分发、工具聚合、
/// **站点体系**与**心跳判活**。
///
/// 配置是**用户可直接手改**的 <数据根>/config/plugins.yaml：
///
///   enabled: true
///   plugins:
///     - id: sample
///       command: dart
///       args: [run, plugins/sample.dart]
///       granularity: team
///       scope: {team_id: team-1, mode_key: local}
///
/// 与 MCP 一样是"本机直跑"：一个插件崩了只体现在它自己的状态与错误里
/// （status: disabled + disabled_reason），不影响其它插件与核心。
///
/// **心跳判活（M9 §1.1）**：取消静态总时长上限；看门狗每过一拍（I=10s）ping 一次，
/// 连续 N=3 拍没有心跳 ⇒ 标记 health: degraded + 前端可见，**不自动终止插件**
/// （插件长任务跑多久都不因时间被杀），心跳恢复后自动清除；用户可显式 [restart]。
class PluginBus {
  PluginBus({
    required this.configFile,
    this.hostFactory,
    this.log,
    this.connectTimeout = const Duration(seconds: 20),
    this.heartbeatInterval = LivenessTracker.defaultInterval,
    this.missThreshold = LivenessTracker.defaultMaxMisses,
    this.coreVersion = '',
    this.broadcast,
    StationHub? stations,
    PluginUiBridge? uiBridge,
    this.stationScopeResolver,
    this.agentModeKeyResolver,
    this.callSiteContext,
    this.toolTableRefreshHook,
    this.restartBufferMaxPerPlugin = 32,
    this.restartBufferMaxTotalBytes = 1 << 20,
  }) : uiBridge = uiBridge ?? PluginUiBridge(),
       restartBuffer = PluginRestartBuffer(
         maxPerPlugin: restartBufferMaxPerPlugin,
         maxTotalBytes: restartBufferMaxTotalBytes,
       ),
       stations =
           stations ??
           StationHub(
             storePath: StationStore.pathFor(configFile),
             log: log,
             frameSink: broadcast,
             heartbeatInterval: heartbeatInterval,
             missThreshold: missThreshold,
           ) {
    // 活性探针：站点等回包时用它判「订阅者心跳还在不在」。
    this.stations.livenessProbe = _livenessOf;
    // 快照池的降级原因必须走同一条日志出口：超上限 / LRU 丢弃 / 归属不符都是
    // 用户要能查到的事，不能只进 stderr（不变量 6）。
    statePool.log = log;
    // 暂存队列的溢出与丢弃同理：每一条都直接写日志，不靠调用方去猜。
    restartBuffer.log = log;
    // **所有**前端下行帧（含执行站 ui.push 的 card 槽位）都在这里过一遍再广播，
    // 缓存因此自动收全，不需要每个发射点各自记得记一笔。
    if (broadcast != null) {
      final void Function(Map<String, dynamic> frame) sink = broadcast!;
      _outbound = (Map<String, dynamic> frame) {
        uiCache.record(frame); // 非 UI 帧由 record 自行忽略
        sink(frame);
      };
      this.stations.frameSink = _outbound;
    }
  }

  /// 包了缓存记一笔的广播出口（[broadcast] 为空时也是空）。
  void Function(Map<String, dynamic> frame)? _outbound;

  /// 前端下行帧的实际出口（[broadcast] 的包装；见构造器）。
  ///
  /// 放在唯一的出口处（而不是每个发射点）是刻意的：发射点会随功能增加，漏一个就
  /// 等于"那个面板重连后回不来"，而出口只有一个。
  void Function(Map<String, dynamic> frame)? get outbound =>
      _outbound ?? broadcast;

  final String configFile;

  /// 宿主工厂（测试注入假宿主；生产走 [PluginHost.start]）。
  final Future<PluginHost> Function(PluginConfig config)? hostFactory;

  final void Function(String message)? log;

  /// **建连窗口**（只覆盖 hello 握手与首次 tools/list；不是任务总时长上限）。
  final Duration connectTimeout;

  /// 心跳间隔 I（默认 10s；看门狗节拍与单拍窗口都用它）。
  final Duration heartbeatInterval;

  /// **重启期暂存的每插件条数上限**（默认 32，保守值；测试可缩小）。
  ///
  /// 为什么要把上限做成参数而不是写死：溢出行为本身（fail-open + 可读原因）必须
  /// 能被用例**真的跑到**，而不是只能读代码。默认值仍按保守定，不由调用方负责想清楚。
  final int restartBufferMaxPerPlugin;

  /// 重启期暂存的**全局字节上限**（估算值；默认 1 MiB）。与上面同口径。
  final int restartBufferMaxTotalBytes;

  /// 连续丢失阈值 N（默认 3）：连续 N 拍没有心跳 ⇒ degraded。
  final int missThreshold;

  final String coreVersion;

  /// WS 下行广播（plugin_status / plugin_event / 插件 UI 帧）；null = 不推。
  final void Function(Map<String, dynamic> frame)? broadcast;

  /// 站点中枢（四站、订阅、落盘；落点 = <数据根>/config/stations.yaml）。
  final StationHub stations;

  /// 插件通知 → 前端 UI 帧的桥（Q12 生产端；见 [PluginUiBridge]）。
  ///
  /// 可注入只为测试换阈值（槽位上限 / 视图字节上限），生产用默认即可。
  final PluginUiBridge uiBridge;

  /// 插件 UI 帧的当前态缓存（**前端后连 / 重连时的重放来源**；见 [PluginUiCache]）。
  ///
  /// 插件只在启动时声明一次槽位，而广播是"当下有谁在听就发给谁"：没有这份缓存，
  /// 前端刷新 / 重连 / 启动竞态错过的槽位就**永远回不来**（要等插件进程重启）。
  final PluginUiCache uiCache = PluginUiCache();

  /// 插件配置 → 站点四元组的**运行期接线点**（M9 Wave 3-I）。
  ///
  /// 入参 = 插件配置 + [StationScopeContext]（调用点上下文：当前 team / agent /
  /// session）。未接线时走默认解析：team 只认插件自己的声明（**不**用调用点团队替
  /// 插件认领归属，否则无归属插件会被跨 team 放大），agent / session 取声明（更细）
  /// 或调用点上下文，mode_key 由 [agentModeKeyResolver] 从 agent 的工作空间模式解析。
  RuntimeStationScopeResolver? stationScopeResolver;

  /// agent → **工作空间模式**（local | ssh）：mode_key 的运行期来源（plan §1.2）。
  ///
  /// 核心侧注入 store.agent(id)?.sshConfig != null ? ssh : local；未接线时退回
  /// 插件声明里的 mode_key（缺省 local，与既有配置语义一致）。
  String Function(String agentId)? agentModeKeyResolver;

  /// **调用点上下文**解析（当前 agent / 会话 → team / agent / session）。
  ///
  /// 核心侧注入「从 agent 的团队归属取 team_id」；未接线时调用点只带 agent /
  /// session（team 为空 = 工具表不做 team 过滤，行为与 M9 之前一致）。
  StationScopeContext Function(String agentId, String sessionId)?
  callSiteContext;

  /// 工具表刷新时的**观测钩子**（测试 / 日志用：记录收集站真的被触发了几次）。
  void Function(StationScope? scope)? toolTableRefreshHook;

  /// 压缩中转点「**为什么没接管**」的原因出口（可写字段，与 [log] 同范式）。
  ///
  /// [relayCompaction] 的**每一处**"不接管"分支都回调一次，带一句给用户看的人话、
  /// 外加 [hasSubscriber] 这个**分级位**：
  /// - `false` = **早退**（总开关关 / 作用域不匹配 / 无点位 / 无订阅者）：压根没有
  ///   插件在这条路上，只是"没人干这事"；
  /// - `true` = **有订阅者但没接管**（没回包 / 原数据放行 / 回包非法 / 越界 / 异常）：
  ///   插件在场却没交出可用结果，这才是用户真正要追的。
  ///
  /// 为什么必须分级：REST 响应要**全量**（排障），而会话历史里的通知只该写"插件在场
  /// 却没接管"——否则没装压缩插件的用户，每条压缩通知都多一句"没有插件订阅该点位"。
  ///
  /// 为什么需要它：这些原因以前**只进 stderr**（有几条连日志都没有），于是"我装了
  /// 压缩插件，为什么没生效"只能靠猜。接线方（`CoreServer._wirePluginRelayPoints`）
  /// 把它接到 `CompactionService.noteRelaySkip` ⇒ 原因随压缩结论上行（REST 可选键
  /// `relay_skip_reason`）并按分级决定要不要落成会话提示。
  void Function(
    String agentId,
    String sessionId,
    String reason, {
    required bool hasSubscriber,
  })?
  compactionSkipSink;

  /// “这句原因能不能由插件写得更准”的**回写口**（阶段 6，中转点位
  /// `compact.skip.reason`）：接线方接到 `CompactionService.annotateRelaySkip`。
  ///
  /// 只能改**文案**：内置那句已经先记账（可读性不依赖插件），分级位 `has_subscriber`
  /// 与“到底有没有接管”那个判据都在核心里。未接线 ⇒ 插件回了也没人接（不报错）。
  void Function(String agentId, String sessionId, String reason)?
  compactionSkipAnnotator;

  /// 一次压缩请求里捎给插件的**最近用量行**（见 [PluginUsageRecent]）：
  /// 接线注入，未接线时压缩载荷里不会出现 `recent_usage` / `usage_file`。
  PluginUsageRecentProvider? usageRecentProvider;

  /// 压缩载荷里最多捎多少行用量（滚动的"最近一批"；账本本身会随会话一直长）。
  static const int maxRecentUsageLines = 50;

  bool enabled = true;

  final List<PluginConfig> _configs = <PluginConfig>[];
  final Map<String, PluginHost> _hosts = <String, PluginHost>{};

  /// 每个**正在运行的实例**是按哪一份配置拉起来的（[applyConfigs] 判断"启动参数
  /// 有没有变"的唯一依据）。
  ///
  /// 为什么不能拿 `_configs` 里的那一份比：对账会重读磁盘并**整体覆盖** `_configs`，
  /// 旧配置当场就没了；而"这个进程当时是按什么参数起来的"才是"要不要重启"的判据。
  final Map<String, PluginConfig> _spawnedConfigs = <String, PluginConfig>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, int> _queueDepth = <String, int>{};

  /// 已被判 degraded 的插件（用于只在**跃迁**时通知前端）。
  final Set<String> _degraded = <String>{};

  /// 已广播过 `disabled` 的"进程已退出"插件（心跳巡检每拍都跑，只在跃迁时推一次）。
  final Set<String> _dead = <String>{};

  /// **可续跑状态快照的内存池**（20261015-hot-restart 阶段 1，D4：只进内存、不落盘）。
  ///
  /// 为什么放在总线而不是宿主里：快照要活过**宿主实例本身**（宿主随进程一起没了，
  /// 而快照正是为了让下一世能接着跑），所以它的持有者必须是跨实例的那一方。
  /// 上限保守、超限按 LRU 丢最旧并写可读原因（见 [PluginStatePool]）。
  final PluginStatePool statePool = PluginStatePool();

  /// **重启期保活的有界暂存队列**（20261015-hot-restart 阶段 2）。
  ///
  /// 为什么放在总线而不是宿主里：保活要跨**宿主实例**——旧进程已经没了、新进程还没
  /// 就绪，这段时间里替插件把站点请求接住的必须是那个跨实例的持有者（与 [statePool]
  /// 同一个理由）。上限、溢出、重放与收尾的口径全部见 [PluginRestartBuffer]；
  /// 上限由构造参数 [restartBufferMaxPerPlugin] / [restartBufferMaxTotalBytes] 定。
  final PluginRestartBuffer restartBuffer;

  /// 重启窗口里**暂时不注销**其站点订阅的插件（见 [_disconnect]）。
  ///
  /// 为什么必须留着：订阅一注销，重启窗口里到达的请求根本走不到这个插件的回包函数，
  /// 「暂存」就没有入口。留着订阅 = 请求能落到队列里；代价是本轮启动最终失败时
  /// 必须补一次注销（见 [_setLifecycle] 的 stopped/failed 分支），不能让它悬着。
  final Set<String> _stationKept = <String>{};

  /// 在等某插件跃出保活窗口的工具调用方（见 [_awaitLifecycleSettled]）。
  ///
  /// 为什么不是时长轮询也不是定时重试：那又回到“拿时长判定”（不变量 4 / D8）。
  /// 生命周期跃迁就是唯一真实存在的事件，而它一定发生（要么 ready 要么 stopped/failed）。
  final Map<String, List<Completer<void>>> _lifecycleWaiters =
      <String, List<Completer<void>>>{};

  /// 代际计数与生命周期台账（两者的读写都集中在下面的几个方法里）。
  final Map<String, int> _generations = <String, int>{};

  /// 每个插件当前的生命周期。**只能由 [_setLifecycle] 写**（映射集中一处，
  /// 四个产出点各算各的就会让面板与 REST 对不上同一个插件）。
  final Map<String, PluginLifecycleState> _lifecycle =
      <String, PluginLifecycleState>{};

  /// 已发起关闭、但**还没确认进程退出**的宿主（"收尸"台账）。
  ///
  /// 为什么需要它：[PluginHost.close] 默认不再等退出（否则一个赖着不退的插件会拖住
  /// 整轮串行对账），但赖着不退的进程也不能无限期活着。看门狗对这里的条目
  /// **只记丢拍、不 ping**（stdin 已关，ping 必定假），判失活后才强杀（见 [watchdog]）。
  ///
  /// 用 `Set<PluginHost>` 而不是按插件 id 索引：同一个插件可以在旧进程还没退时
  /// 就被拉起新一世，按 id 存会把旧那个「忘」在台账外（句柄泄漏），而集合按实例走。
  final Set<PluginHost> _reaping = <PluginHost>{};

  /// 正在等某插件把快照递进来的等待者（热重启用，以**心跳/退出**为界，不用时长）。
  final Map<String, Completer<String?>> _dumpWaiters =
      <String, Completer<String?>>{};

  /// 动态工具表（**触发方** = 工具表刷新处；由收集站收集后注册）。
  final PluginToolDefinitionTable _definitions = PluginToolDefinitionTable();

  /// 模型工具表（插件部分）的**按 scope 缓存**（M9 Wave 3-I）。
  ///
  /// 缓存的意义：工具表在每个 agent 每轮生成前都要拼一次（WorkspaceToolRunner 的
  /// specsFor），若每次都全量触发收集站，插件会被高频打扰。失效点 = **插件生命周期
  /// 事件**（上线 / 下线 / 重启 / 一次收集完成），只有脏了才在后台补一次收集。
  final Map<String, List<({String pluginId, PluginToolInfo tool})>>
  _toolTableCache = <String, List<({String pluginId, PluginToolInfo tool})>>{};

  /// 工具表是否需要重新收集（失效标记）。
  bool _toolTableDirty = true;

  /// 是否已有一次收集在途（防止同一拍里重复触发）。
  bool _toolTableRefreshing = false;

  /// 收集站被真正触发的次数（观测 / 测试用；缓存命中不增加）。
  int toolTableRefreshCount = 0;

  /// 最近一次收集的结论（[ensureToolTableFresh] 在不脏时返回它）。
  ToolDefinitionRefresh? _lastToolTableRefresh;

  /// 插件申报的**自定义点位**（收集站 `plugin.capability.define`，阶段 6）。
  /// 每轮工具表刷新**整表重建**（键 = plugin_id）。
  final Map<String, List<PluginCapability>> _capabilitiesByPlugin =
      <String, List<PluginCapability>>{};

  /// 上一轮点位申报里**被丢掉的那几条**（含未响应），显式列出不静默。
  List<String> _capabilityNotes = const <String>[];

  /// 在册的插件自定义点位（只读；传 [pluginId] 只看那一个插件）。
  ///
  /// 注意这里只是**描述**：核心不认识的 event 不会因为被申报就开始投递（否则一个
  /// 字符串就能骗过订阅者）。
  List<Map<String, dynamic>> capabilityDeclarations({String pluginId = ''}) {
    final String key = pluginId.trim();
    final Iterable<PluginCapability> rows = key.isEmpty
        ? <PluginCapability>[
            for (final List<PluginCapability> list
                in _capabilitiesByPlugin.values)
              ...list,
          ]
        : (_capabilitiesByPlugin[key] ?? const <PluginCapability>[]);
    return <Map<String, dynamic>>[
      for (final PluginCapability row in rows) row.toJson(),
    ];
  }

  /// 上一轮点位申报的丢弃原因（与 [capabilityDeclarations] 同轮）。
  List<String> get capabilitySkipNotes => _capabilityNotes;

  int _lastWatchdogRun = 0;
  Timer? _watchdogTimer;
  bool _loaded = false;

  /// 读配置（**幂等**；文件不存在按"无插件"）。
  ///
  /// 幂等 = 配置只在核心启动时进内存一次。这条口径不能丢：[configs] / [config]
  /// 在热路径上（每次模型工具表拼装都会问一次"有哪些插件"），每次调用都读盘会把
  /// 工具表刷新拖成磁盘 IO。运行期的增删改走 [applyConfigs]（它先调 [_reloadConfigs]）。
  void load() {
    if (_loaded) return;
    _reloadConfigs();
  }

  /// **强制重读** <数据根>/config/plugins.yaml 到内存（[applyConfigs] 的读盘口）。
  ///
  /// 为什么需要它：load() 幂等意味着"用户在盘上改了配置"在运行期没有任何落点，
  /// 于是每个插件开关都得等重启核心。返回 null = 读盘成功（内存被磁盘整体覆盖；
  /// 先解析到临时列表、成功才替换，所以重复调用幂等）；返回可读原因 = 解析失败，
  /// 此时内存配置与运行实例**保持原样**：把用户手改坏的文件当成"没有插件"会顺手
  /// 停掉全部在跑的插件，那是把一次拼写错误放大成一次全量停机。
  String? _reloadConfigs() {
    _loaded = true;
    final String? text = AtomicFile.readStringOrNullSync(configFile);
    final List<PluginConfig> parsed = <PluginConfig>[];
    bool totalEnabled = true;
    if (text != null && text.trim().isNotEmpty) {
      try {
        final Map<String, dynamic> data = YamlCodec.decode(text);
        totalEnabled = data['enabled'] != false;
        final Object? raw = data['plugins'];
        if (raw is List<dynamic>) {
          for (final dynamic item in raw) {
            if (item is! Map) continue;
            final PluginConfig config = PluginConfig.fromJson(
              item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
            );
            if (config.id.trim().isEmpty) continue;
            parsed.add(config);
          }
        }
      } catch (error) {
        log?.call('插件配置解析失败（$configFile）：$error');
        return '插件配置解析失败（$configFile）：$error';
      }
    }
    // 成功解析才整体替换内存配置（追加式更新会让删掉的条目阴魂不散）
    _configs
      ..clear()
      ..addAll(parsed);
    enabled = totalEnabled;
    return null;
  }

  /// 全部插件配置（按配置顺序）。
  List<PluginConfig> configs() {
    load();
    return List<PluginConfig>.unmodifiable(_configs);
  }

  PluginConfig? config(String id) {
    load();
    for (final PluginConfig config in _configs) {
      if (config.id == id) return config;
    }
    return null;
  }

  /// 已启动的实例（id → 宿主）。
  List<({String pluginId, PluginHost host})> instances() =>
      <({String pluginId, PluginHost host})>[
        for (final MapEntry<String, PluginHost> entry in _hosts.entries)
          (pluginId: entry.key, host: entry.value),
      ];

  /// 某插件当前注册的工具（来自动态工具表 = 收集站收集到的定义）。
  List<PluginToolInfo> toolsOf(String pluginId) => _definitions
      .definitions()
      .where((PluginToolDefinition d) => d.pluginId == pluginId)
      .map((PluginToolDefinition d) => d.toToolInfo())
      .toList(growable: false);

  /// 某插件最近一次失败原因（注册失败 / 调用失败）。
  String? errorOf(String pluginId) => _errors[pluginId];

  /// **SSH 中转站**的通知出口（`tunnel/event`）——**旧 `tunnel.*` 路径**（单消费者）。
  ///
  /// 只有一条路：`sshIoFactory` 选路时建起来的 `PluginTunnelLink` 会挂上它。
  /// 为 null 时通知被丢弃并记日志 —— PTY 的数据面丢一帧不该把核心搞崩。
  ///
  /// 2026-10-15：SSH 迁移到「处理拓展点位」后，站点路径（`StationTunnelLink`）与这条
  /// 旧路径**并存**——二者都靠 `tunnel/event` 拿 PTY 字节。故新增下面的监听器列表：
  /// 本字段仍由 `PluginTunnelLink` 独占（**行为不变、不改它**），站点路径注册进
  /// [_tunnelEventListeners]。派发时两条都发，各自按自己认领的 `conn_id` 分流，
  /// 不属于自己就丢弃——`conn_id` 带进程内随机前缀全局唯一，不会串隧道。
  void Function(String pluginId, Map<String, dynamic> params)? onTunnelEvent;

  /// `tunnel/event` 的**多消费者**出口（站点路径用；与 [onTunnelEvent] 并列派发）。
  final List<void Function(String pluginId, Map<String, dynamic> params)>
  _tunnelEventListeners =
      <void Function(String pluginId, Map<String, dynamic> params)>[];

  /// 登记一个 `tunnel/event` 消费者（`StationTunnelLink` 构造时调用）。
  void addTunnelEventListener(
    void Function(String pluginId, Map<String, dynamic> params) listener,
  ) => _tunnelEventListeners.add(listener);

  /// 注销一个 `tunnel/event` 消费者（链路对象回收时调用，避免监听器堆积）。
  void removeTunnelEventListener(
    void Function(String pluginId, Map<String, dynamic> params) listener,
  ) => _tunnelEventListeners.remove(listener);

  /// 找**可用的 SSH 中转站**（`ssh_executor` 插件）。
  ///
  /// 判据 = **能力**而不是写死 id（与 `docs/ssh-tunnel-protocol.md` §6 同口径）：
  /// 插件系统总开关开着、该条目 enabled、进程在跑、`hello` 申报了
  /// `ssh-executor` 能力、且心跳未 degraded。
  ///
  /// 返回 `(host, reason)`：`host == null` 时 [reason] 是**可读的"为什么没有"**
  /// （直接进日志 / 右栏，用户看得懂）；`host != null` 时 reason 为空串。
  /// 刻意**不抛异常**也不回 null-only：判空失败必须有话可说，否则就是"点了开关没反应"。
  ({PluginHost? host, String reason}) sshExecutorLookup() {
    load();
    if (!enabled) {
      return (host: null, reason: '插件系统总开关为关（plugins.yaml 顶层 enabled: false）');
    }
    bool sawEntry = false;
    bool sawEnabled = false;
    for (final PluginConfig config in _configs) {
      if (config.id != kSshExecutorPluginId) continue;
      sawEntry = true;
      if (!config.enabled) continue;
      sawEnabled = true;
      final PluginHost? host = _hosts[config.id];
      if (host == null) {
        return (
          host: null,
          reason:
              '中转站插件「${config.name.isEmpty ? config.id : config.name}」'
              '未在运行（${_errors[config.id] ?? '尚未启动'}）',
        );
      }
      if (host.isClosed) {
        return (
          host: null,
          reason: '中转站插件通道已断（${host.channelError ?? '进程已退出'}）',
        );
      }
      if (!host.capabilities.contains(kCapabilitySshExecutor)) {
        return (
          host: null,
          reason:
              '中转站插件未申报 ssh-executor 能力'
              '（申报的是：${host.capabilities.isEmpty ? '无' : host.capabilities.join('、')}）',
        );
      }
      if (host.liveness.isStale) {
        return (host: null, reason: '中转站插件心跳丢失（degraded，可显式重启）');
      }
      return (host: host, reason: '');
    }
    if (!sawEntry) {
      return (host: null, reason: '没有内置的 ssh_executor 插件条目（未随包分发？）');
    }
    return (
      host: null,
      reason: sawEnabled ? '中转站插件不可用' : '中转站插件条目已停用（enabled: false）',
    );
  }

  /// 中转站插件**正在启动**（条目启用、但实例还没起来 / 还没申报能力）。
  ///
  /// 为什么单独问这一个问题：核心启动时插件是**异步**拉起的，实测有一段几十~几百毫秒的窗口
  /// ——用户机器 2026-10-11 的日志就是 `09:35:00.081` 解析 SSH、`09:35:00.134` 插件就绪
  /// （**只差 53ms**）。那时若直接回退内置 dartssh2，这条 SSH 会**整场都跑在内置后端上**
  /// （工作空间 IO 会被缓存、不会自己回切），中转站等于白装一次。
  ///
  /// 与"没有中转站"的其它原因**刻意分开**：条目停用 / 启动失败（[_errors] 里有原因）/
  /// 通道断了 —— 这些都不该让调用方空等。
  bool sshExecutorStarting() {
    load();
    if (!enabled) return false;
    for (final PluginConfig config in _configs) {
      if (config.id != kSshExecutorPluginId) continue;
      if (!config.enabled) return false;
      final PluginHost? host = _hosts[config.id];
      if (host == null) {
        // 尚无实例：**没有错误记录**才算"还在启动"，有错误就是启动失败了。
        return (_errors[config.id] ?? '').isEmpty;
      }
      if (host.isClosed) return false;
      return !host.capabilities.contains(kCapabilitySshExecutor);
    }
    return false;
  }

  /// 同 [sshExecutorLookup]，但"插件正在启动"时**有界等待**它起来。
  ///
  /// 只用于跨越核心启动那段窗口（见 [sshExecutorStarting] 的注释）：
  /// 非"正在启动"的原因（已停用 / 崩溃 / 能力未申报）**立即返回**，绝不空等。
  /// 等待期间每 [interval] 探一次，总时长不超过 [timeout]。
  Future<({PluginHost? host, String reason})> sshExecutorLookupWaitingForStart({
    Duration timeout = const Duration(seconds: 1),
    Duration interval = const Duration(milliseconds: 100),
  }) async {
    ({PluginHost? host, String reason}) lookup = sshExecutorLookup();
    if (lookup.host != null || timeout <= Duration.zero) return lookup;
    if (!sshExecutorStarting()) return lookup;
    final Stopwatch elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      await Future<void>.delayed(interval);
      lookup = sshExecutorLookup();
      if (lookup.host != null || !sshExecutorStarting()) return lookup;
    }
    return lookup;
  }

  /// 某插件的健康度快照（心跳判活；degraded **不等于**死亡）。
  Map<String, dynamic> healthOf(String pluginId) {
    final PluginHost? host = _hosts[pluginId];
    if (host == null) {
      return <String, dynamic>{
        'plugin_id': pluginId,
        'health': 'unavailable',
        'degraded': false,
        'missed_heartbeats': 0,
        'reason': _errors[pluginId] ?? '未启动',
      };
    }
    final LivenessTracker tracker = host.liveness;
    return <String, dynamic>{
      'plugin_id': pluginId,
      'health': tracker.isStale ? 'degraded' : 'ok',
      'degraded': tracker.isStale,
      'missed_heartbeats': tracker.missedCount,
      'miss_threshold': tracker.maxMisses,
      'heartbeat_interval_s': tracker.interval.inMilliseconds / 1000,
      'last_heartbeat':
          (tracker.lastBeatAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
      if (tracker.isStale) 'reason': tracker.staleMessage,
    };
  }

  /// 全部**可用**插件工具（带插件 id）。
  ///
  /// [scope] 非空时按**站点四元组**过滤（plan §1.2）：只保留归属该 team 的定义，
  /// 定义里更细的 agent / session 也必须与调用点一致；无 team 归属的老式定义
  /// （tools/list 路径）不受站点过滤影响，保持既有行为。
  List<({String pluginId, PluginToolInfo tool})> allTools({
    StationScope? scope,
  }) {
    final List<({String pluginId, PluginToolInfo tool})> out =
        <({String pluginId, PluginToolInfo tool})>[];
    for (final PluginConfig config in configs()) {
      if (!config.enabled) continue;
      for (final PluginToolDefinition definition in _definitionList(
        config.id,
      )) {
        if (!_visible(definition, scope)) continue;
        out.add((pluginId: config.id, tool: definition.toToolInfo()));
      }
    }
    return out;
  }

  /// 某插件的工具定义（**带 scope**，过滤 / 调试用）。
  List<PluginToolDefinition> _definitionList(String pluginId) => _definitions
      .definitions()
      .where((PluginToolDefinition d) => d.pluginId == pluginId)
      .toList(growable: false);

  /// 一条定义是否对调用点 scope 可见（fail-closed：证明了不一致就不给看）。
  static bool _visible(PluginToolDefinition definition, StationScope? scope) {
    if (scope == null) return true;
    final StationScope declared = definition.scope;
    // 无 team 归属 = 老式 tools/list 申报路径：不做站点过滤（保持既有行为）
    if (declared.teamId.trim().isEmpty) return true;
    // 调用点没有 team 信息：不过滤（M9 之前的行为）
    if (scope.teamId.trim().isEmpty) return true;
    if (declared.teamId != scope.teamId) return false;
    if (declared.agentId.isNotEmpty && declared.agentId != scope.agentId) {
      return false;
    }
    if (declared.sessionId.isNotEmpty &&
        declared.sessionId != scope.sessionId) {
      return false;
    }
    return true;
  }

  /// 已注册的工具定义（按命名空间名；调用路由用）。
  PluginToolDefinition? definitionOf(String namespacedName) =>
      _definitions.byNamespacedName(namespacedName);

  /// 启动全部启用插件（幂等；单个失败只记录不抛出），随后触发一次工具定义收集。
  Future<void> start() async {
    load();
    if (!enabled) return;
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      await _startOne(config);
    }
    // **触发时机在调用方**：插件启动完成 = 工具表刷新点，这里触发收集站。
    await refreshToolDefinitions();
    _watchdogTimer ??= Timer.periodic(heartbeatInterval, (Timer _) {
      unawaited(watchdog());
    });
  }

  Future<void> _startOne(
    PluginConfig config, {
    String resumeDumpId = '',
  }) async {
    if (_hosts.containsKey(config.id)) return;
    // **代际在拉起之前**就定下来：快照的索引键靠它，而「这一世是谁」必须在进程还
    // 没起来时就确定（否则转储与取回会各自猜一个号，两边对不上）。
    final int generation = (_generations[config.id] ?? 0) + 1;
    _generations[config.id] = generation;
    _setLifecycle(config.id, PluginLifecycleState.booting);
    try {
      final PluginHost host = await _spawn(config, resumeDumpId: resumeDumpId);
      // **插件 → 核心请求通道**（M9 §3）：插件主动下命令（station/command）在这里
      // 接线。生产路径已在 _spawn 里接好（建连即生效），这里再设一次是为了覆盖
      // hostFactory 注入的宿主（测试 / 自定义宿主）。
      host.onPluginRequest = (String method, Map<String, dynamic> params) =>
          _handlePluginRequest(config, method, params);
      _hosts[config.id] = host;
      // 记下"这个实例是按哪一份配置起来的"：对账时据此判断启动参数有没有变
      _spawnedConfigs[config.id] = config;
      _errors.remove(config.id);
      _queueDepth[config.id] = 0;
      _dead.remove(config.id); // 重新起来 = 可以再次报告"进程已退出"
      host.liveness.recordBeat();
      if (!_scopeOf(config).isValid) {
        // 无 team 归属的插件进不了站点体系（隔离要求四元组）：
        // 走既有 tools/list 直接申报，保证工具仍可用（显式路径，不是静默降级）
        _registerLegacyTools(
          config.id,
          await host.listTools(timeout: connectTimeout),
        );
      }
      // 插件上线 = 工具表失效点（下次工具表刷新点会重新收集它的申报）
      invalidateToolTable(reason: '插件 ${config.id} 上线');
      log?.call('插件 ${config.id} 就绪（第 $generation 代）');
      _setLifecycle(config.id, PluginLifecycleState.ready);
      _emitStatus(config, 'registered', degraded: false);
    } catch (error) {
      _errors[config.id] = '$error';
      log?.call('插件 ${config.id} 不可用：$error');
      await _disconnect(config.id);
      // 顺序有意义：先断开（里面会记 stopped），再置 failed——
      // 「没起来」与「被我关掉了」在面板上是两回事。
      _setLifecycle(config.id, PluginLifecycleState.failed);
      _emitStatus(config, 'disabled', reason: '$error');
    }
  }

  /// 推一条 plugin_status 增量（前端按 plugin_id + scope 合并）。
  ///
  /// 心跳降级时 **status 仍是 registered**（插件活着），健康度走 health 字段——
  /// 这样前端的增量合并不会把它当成"停用"。
  ///
  /// **D11/D3 向后兼容口径**：`lifecycle` 是**新增的可选键**（从台账读，不在此反推）；
  /// `status` 与 `health` 的取值集合一个字没改。旧前端看不到 lifecycle 也不受影响。
  void _emitStatus(
    PluginConfig config,
    String status, {
    String reason = '',
    bool? degraded,
  }) {
    final PluginHost? host = _hosts[config.id];
    outbound?.call(<String, dynamic>{
      'type': 'plugin_status',
      'data': <String, dynamic>{
        'plugin_id': config.id,
        'name': config.name,
        'granularity': config.granularity,
        'scope': config.scope,
        'status': status,
        // 可选字段：生命周期阶段（与 status/health 是三个独立轴，见 plugin_lifecycle.dart）
        'lifecycle': lifecycleOf(config.id).wire,
        'generation': generationOf(config.id),
        if (reason.isNotEmpty) 'reason': reason,
        if (degraded != null) 'health': degraded ? 'degraded' : 'ok',
        if (host != null) ...<String, dynamic>{
          'missed_heartbeats': host.liveness.missedCount,
          'heartbeat_interval_s': host.liveness.interval.inMilliseconds / 1000,
          'last_heartbeat':
              (host.liveness.lastBeatAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        },
        // **水位（只增键，阶段 6 稳定性项）**：快照池与重启暂存队列都是“超限就丢”
        // 的有界结构，光有“丢”这个动作不够——得让前端/审计看得见它现在多大、上限多少、
        // 已经拒过多少次，否则“我的快照为什么不见了”又是一次靠猜的排障。
        // 这里只报数，不报内容（池里存的是插件内部状态）。
        'state_pool': <String, dynamic>{
          'entries': statePool.length,
          'bytes': statePool.totalBytes,
          'denied': statePool.deniedCount,
          'max_entries': statePool.maxEntries,
          'max_total_bytes': statePool.maxTotalBytes,
        },
        'restart_buffer': <String, dynamic>{
          'buffered_for_this_plugin': restartBuffer.lengthOf(config.id),
          'max_per_plugin': restartBufferMaxPerPlugin,
          'max_total_bytes': restartBufferMaxTotalBytes,
          // 两种“没了”必须分开：overflow = 超限当场拒收（背压），
          // dropped = 重启没成 / 插件下线后主动弃（调用点各自 fail-open 兜底）
          'overflow': restartBuffer.overflowCount,
          'dropped': restartBuffer.droppedCount,
          'replayed': restartBuffer.replayedCount,
        },
        // 插件自己申报的点位（阶段 6，只增键）：只是描述，不产生投递路。
        'capabilities': capabilityDeclarations(pluginId: config.id),
        'ts': _nowSeconds(),
      },
    });
  }

  /// 推一条 plugin_event（插件主动通知：log / event）。
  ///
  /// **Q12 插件布局的生产端**：约定 method `ui/manifest` / `ui/update` 的通知在这里
  /// 被转成前端 UI 帧（`plugin_ui_manifest` / `plugin_ui_update`），其余 method 维持
  /// 原样 `plugin_event`——插件因此能用同一个 stdio 通知通道声明槽位，
  /// 不需要新协议方法（面板里不执行任何插件 JS，视图只能是受限控件集的 JSON）。
  void _emitPluginEvent(String pluginId, Map<String, dynamic> notification) {
    final String method = (notification['method'] ?? '').toString();
    final Object? rawParams = notification['params'];
    final Map<String, dynamic> params = rawParams is Map
        ? rawParams.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    if (method == PluginRpcMethods.stationStream) {
      // 流式回填的数据面：插件推 delta / done / error（见 [_handleStationStream]）
      _handleStationStream(pluginId, params);
      return;
    }
    if (method == TunnelMethods.event) {
      // SSH 执行器的**内部数据面**（隧道状态跃迁 / PTY 字节与退出）。
      // 刻意**不**降级成 `plugin_event` 推给前端：这不是"插件事件"，是核心自己
      // 选路时建起来的那条隧道的私有通道（前端看隧道状态走执行器自己的错误面）。
      // 两条路径都靠它拿 PTY：旧 `PluginTunnelLink`（[onTunnelEvent] 字段）与新
      // `StationTunnelLink`（监听器列表）并存；各自按 conn_id 认领，不属于自己就丢弃。
      onTunnelEvent?.call(pluginId, params);
      for (final void Function(String, Map<String, dynamic>) listener
          in List<void Function(String, Map<String, dynamic>)>.of(
            _tunnelEventListeners,
          )) {
        listener(pluginId, params);
      }
      return;
    }
    if (uiBridge.handles(method)) {
      final PluginConfig? config = this.config(pluginId);
      final String declaredTeam = (config?.scope['team_id'] ?? '')
          .toString()
          .trim();
      final Map<String, dynamic>? frame = uiBridge.frameFor(
        pluginId: pluginId,
        declaredTeamId: declaredTeam,
        method: method,
        params: params,
        onRejected: (String reason) =>
            log?.call('插件 $pluginId 的 UI 声明被拒：$reason'),
      );
      if (frame != null) {
        // 出口自带缓存记录（见构造器里的 _outbound）：重连时按缓存重放，
        // 「前端后连」也能拿到同一份当前态
        outbound?.call(frame);
        return;
      }
      // 非法声明已经记过可读原因，**不再**降级成 plugin_event（避免前端收到半成品）
      return;
    }
    outbound?.call(<String, dynamic>{
      'type': 'plugin_event',
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'method': method,
        'params': params,
        'ts': _nowSeconds(),
      },
    });
  }

  /// 把一个总线事件分发给订阅的插件实例，返回收到的实例数。
  int dispatch(Map<String, dynamic> event) {
    load();
    if (!enabled) return 0;
    int delivered = 0;
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      final PluginHost? host = _hosts[config.id];
      if (host == null || host.isClosed) continue;
      if (!_subscribes(config, event)) continue;
      host.dispatchEvent(event);
      _queueDepth[config.id] = (_queueDepth[config.id] ?? 0) + 1;
      delivered++;
    }
    return delivered;
  }

  /// agent 事件名 → **广播站点位**的分流表（阶段 6：A 级点位批）。
  ///
  /// 为什么分出去就**不再**走下面的 [dispatch]：那一路是「scope 命中就收」（插件不订阅
  /// 也收），而点位语义是「订了才投」。同一条事件走两处 = 订了站点的插件收到两份，
  /// 没订的插件被塞了新事件（后者才是真正会漂移的地方）。`agent.tool_call` 保持原路
  /// 不变：已有插件靠它数轮次（Q8），改它的投递口径就是改一个已经上线的行为。
  static const Map<String, String> _agentEventPoints = <String, String>{
    AgentEvents.turnDone: StationHubIds.broadcastTurnDone,
    AgentEvents.turnCancelled: StationHubIds.broadcastTurnCancelled,
    AgentEvents.turnError: StationHubIds.broadcastTurnError,
    AgentEvents.askPaused: StationHubIds.broadcastAskPaused,
  };

  /// 广播点位 id 的前缀（topic 由 id 推导用）。
  static const String _broadcastIdPrefix = 'system.broadcast.';

  /// 点位的 **topic** = 去掉前缀的点位名（`system.broadcast.turn.done` → `turn.done`）。
  ///
  /// 由 id 推导而不是再记一张表：别名改了 topic 跟着改，不会出现两处不同名。
  static String _broadcastTopicOf(String pointId) =>
      pointId.startsWith(_broadcastIdPrefix)
      ? pointId.substring(_broadcastIdPrefix.length)
      : pointId;

  /// 把一条 agent 事件投到它对应的**广播站点位**（只给订阅者，单向不回填）。
  ///
  /// 与 [announceToolCall] 同口径：`unawaited`、没人订阅就走快路径零开销、投递失败
  /// 只记日志。不同点只有一处：**证明不了归属时不静默**（记一行为什么没发），
  /// 因为这类事件只有会话层在发，发不出来说明接线与 agent 归属对不上。
  int _announceAgentPoint(String pointId, Map<String, dynamic> event) {
    final BroadcastStation? station = stations.broadcastPointFor(pointId);
    if (station == null) return 0;
    if (station.subscribers.isEmpty) return 0; // 快路径：没人订阅，零开销
    final StationScope scope = runtimeScopeFor(
      agentId: (event[AgentEvents.fieldAgentId] ?? '').toString(),
      sessionId: (event[AgentEvents.fieldSessionId] ?? '').toString(),
    );
    if (!scope.isValid) {
      log?.call(
        'agent 广播 ${event[AgentEvents.fieldEvent]} 未投递（${scope.describe()} '
        '不能证明归属，fail-closed）',
      );
      return 0;
    }
    final String topic = _broadcastTopicOf(pointId);
    unawaited(
      station
          .publish(
            topic: topic,
            scope: scope,
            payload: <String, dynamic>{'point': station.id, ...event},
            meta: <String, dynamic>{
              'point': station.id,
              'agent_id': (event[AgentEvents.fieldAgentId] ?? '').toString(),
              'session_id': (event[AgentEvents.fieldSessionId] ?? '')
                  .toString(),
            },
          )
          .then((StationPublishResult result) {
            if (result.deliveries.any((StationDelivery d) => !d.ok)) {
              log?.call('agent 广播 $topic ${result.describe()}');
            }
          })
          .catchError((Object error) {
            log?.call('agent 广播 $topic 异常（已忽略，不影响生成）：$error');
          }),
    );
    return station.subscribers.length;
  }

  /// **agent 事件派发**（M9 追加）：把会话服务发布的 agent 侧事件（如
  /// `agent.tool_call`）按**既有订阅口径**投给插件实例。
  ///
  /// 「既有口径」= [_subscribes]：`config.scope` 里为空即通配，非空则精确匹配
  /// `team_id` / `agent_id` / `session_id`（**不发明新的订阅语法**）；插件声明得
  /// 更细（agent / session 级）就只收该更细范围的事件，声明 team 就收该 team 的事件。
  ///
  /// 与 [dispatch] 的区别只在**取数与兜底**（agent 数据面的唯一入口）：
  /// - 事件名取 `event` 字段：缺失 / 空 ⇒ **拒发并记日志**（不静默丢一条无名字的事件）；
  /// - 补一个 `ts`（epoch 秒）便于插件与自己日志对时间（已有则原样保留）；
  /// - **绝不抛异常**：本方法在生成循环里被调用（工具调用处），插件侧的任何问题都不该
  ///   让生成失败——异常一律收敛成日志 + 返回 0。
  int dispatchAgentEvent(Map<String, dynamic> event) {
    final String name = (event['event'] ?? '').toString().trim();
    if (name.isEmpty) {
      log?.call('agent 事件缺少 event 名称，未派发：$event');
      return 0;
    }
    try {
      final String? pointId = _agentEventPoints[name];
      if (pointId != null) {
        // 分流到广播点位（订了才投），不再走下面那一路「不订阅也收」的既有事件流。
        return _announceAgentPoint(pointId, <String, dynamic>{
          ...event,
          'event': name,
          if (!event.containsKey('ts')) 'ts': _nowSeconds(),
        });
      }
      return dispatch(<String, dynamic>{
        ...event,
        'event': name,
        if (!event.containsKey('ts')) 'ts': _nowSeconds(),
      });
    } catch (error) {
      log?.call('agent 事件 $name 派发失败（已忽略，不影响生成）：$error');
      return 0;
    }
  }

  bool _subscribes(PluginConfig config, Map<String, dynamic> event) {
    bool matches(String key) {
      final String wanted = (config.scope[key] ?? '').toString();
      if (wanted.isEmpty) return true;
      return wanted == (event[key] ?? '').toString();
    }

    return matches('team_id') && matches('agent_id') && matches('session_id');
  }

  /// 调用插件工具（接受命名空间名，或 pluginId + 裸工具名）。
  ///
  /// **按来源 plugin_id 路由**：先查动态工具表（收集站注册的定义），命中则用定义里的
  /// 来源插件与执行名（唯一权威）；否则退回既有的命名空间解析。
  /// **无静态超时**：插件跑多久都等（判活靠心跳，见 [watchdog]）。
  /// [agentId] / [sessionId] = **调用点**身份：随 `tools/call` 下发给插件
  /// （单实例插件据此做归属判断）。留空 = 不带 scope（老调用方行为不变）。
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    String pluginId = '',
    String agentId = '',
    String sessionId = '',
  }) async {
    load();
    String targetPlugin = pluginId;
    String targetTool = toolName;
    final PluginToolDefinition? definition = _definitions.byNamespacedName(
      toolName,
    );
    if (definition != null) {
      targetPlugin = definition.pluginId;
      targetTool = definition.resolvedExecutionName;
    } else {
      final ({String pluginId, String tool})? parsed =
          parseNamespacedPluginTool(toolName);
      if (parsed != null) {
        targetPlugin = parsed.pluginId;
        targetTool = parsed.tool;
      } else if (targetPlugin.isEmpty) {
        for (final PluginConfig config in _configs) {
          if (toolsOf(config.id)
              .any((PluginToolInfo t) => t.name == toolName)) {
            targetPlugin = config.id;
            break;
          }
        }
      }
    }
    if (targetPlugin.isEmpty) {
      return PluginCallResult(text: '未找到插件工具: $toolName', isError: true);
    }
    PluginHost? host = _hosts[targetPlugin];
    if (host == null || host.isClosed) {
      // **重启窗口里的工具调用不当场失败**（阶段 2 的路由判据）：等它跃出「暂时
      // 不可用」那一段再投一次。等的是**事件**（生命周期跃迁）而不是时长（不变量 4 /
      // D8）；跃迁一定会发生（ready 或 stopped/failed），因此不会无界挂住。
      // 为什么值得多这一手：不这样的话，“agent 在插件重启那几百毫秒里调了一下工具”
      // 就是一次真失败（而重启正是插件自己用 agent tool 发起的，见阶段 3）。
      if (_isKeepaliveWindow(targetPlugin)) {
        await _awaitLifecycleSettled(targetPlugin);
        final PluginHost? again = _hosts[targetPlugin];
        if (again != null && !again.isClosed) host = again;
      }
    }
    if (host == null || host.isClosed) {
      return PluginCallResult(
        text: '插件 $targetPlugin 不可用：${_unavailabilityReason(targetPlugin)}',
        isError: true,
      );
    }
    final PluginCallResult result = await host.callTool(
      targetTool,
      arguments,
      scope: _callIdentity(agentId, sessionId),
    );
    if (result.isError) {
      _errors[targetPlugin] = result.text;
    } else {
      _errors.remove(targetPlugin);
      host.liveness.recordBeat();
    }
    return result;
  }

  /// 一个插件「现在为什么接不了活」的可读原因（按生命周期分化）。
  ///
  /// 为什么不是一句「不可用：未启动」到底：重启中的插件明明会回来，却对用户报成
  /// 像坏了（不变量 6：失败要可读，而「可读」包含**能不能重试**）。三个轴仍各自
  /// 保持原语义：这里只解释**为什么这次没投出去**，不改 status/health 也不判死。
  String _unavailabilityReason(String pluginId) {
    final String error = _errors[pluginId] ?? '';
    return switch (lifecycleOf(pluginId)) {
      PluginLifecycleState.restarting ||
      PluginLifecycleState.suspended ||
      PluginLifecycleState.booting =>
        '正在 ${lifecycleOf(pluginId).wire}（第 ${generationOf(pluginId)} 代还没就绪）'
            '⇒ 这次调用没有投出去，就绪后重试即可（不是故障，也不是判死）',
      PluginLifecycleState.failed => error.isEmpty ? '本轮启动失败' : '本轮启动失败：$error',
      PluginLifecycleState.ready => error.isEmpty ? '进程已退出' : error,
      PluginLifecycleState.stopped => error.isEmpty ? '未启动' : error,
    };
  }

  /// 等某插件跃出保活窗口（**只由生命周期跃迁唤醒**，不设时长；已跃出则立即返回）。
  Future<void> _awaitLifecycleSettled(String pluginId) {
    if (!_isKeepaliveWindow(pluginId)) return Future<void>.value();
    final Completer<void> waiter = Completer<void>();
    _lifecycleWaiters
        .putIfAbsent(pluginId, () => <Completer<void>>[])
        .add(waiter);
    return waiter.future;
  }

  /// 唤醒某插件全部在等它就绪的调用方（跃迁 / 核心退出两条路径都会走到）。
  void _wakeLifecycleWaiters(String pluginId) {
    final List<Completer<void>>? waiters = _lifecycleWaiters.remove(pluginId);
    if (waiters == null) return;
    for (final Completer<void> waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// 核心退出：把所有还在等就绪的调用方放回去（否则会话挂在一条永远不会回来的工具
  /// 调用上；不变量 6）。
  void _wakeAllLifecycleWaiters() {
    for (final String pluginId in _lifecycleWaiters.keys.toList(
      growable: false,
    )) {
      _wakeLifecycleWaiters(pluginId);
    }
    _lifecycleWaiters.clear();
  }

  /// 核心 → 插件 `tools/call` 的身份四元组（Q2）。
  ///
  /// 与 `station/command` 同一口径：team 取调用点 agent 的团队归属、mode 取目标
  /// agent 的工作空间模式；两者都解析不出来时退化为只带 agent/session（插件侧
  /// 自己决定是否要求更完整的身份）。agent 与 session 都为空 = 不带 scope。
  Map<String, dynamic>? _callIdentity(String agentId, String sessionId) {
    final String agent = agentId.trim();
    final String session = sessionId.trim();
    if (agent.isEmpty && session.isEmpty) return null;
    final StationScopeContext context =
        callSiteContext?.call(agent, session) ??
        StationScopeContext(agentId: agent, sessionId: session);
    final String mode = (agentModeKeyResolver?.call(agent) ?? '').trim();
    return <String, dynamic>{
      'team_id': context.teamId.trim(),
      'agent_id': agent,
      'session_id': session,
      if (StationModeKey.isValid(mode)) 'mode_key': mode,
    };
  }

  /// 停止心跳巡检定时器（关停 / 测试用；显式 [watchdog] 仍可手动跑一拍）。
  ///
  /// 起停**只影响探活节拍**，不影响任何任务：插件跑多久都不会因为这里被中止。
  void pauseHeartbeat() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  /// 心跳巡检（M9 §1.1）：**只标健康度，不终止插件**。
  ///
  /// - ping 成功（或插件有任意入站报文，见 PluginHost 的 _onLine）⇒ 记一次心跳；
  /// - 连续 N 拍未达 ⇒ 标记 degraded + 前端可见（status 仍是 registered）；
  /// - degraded **不杀进程**：插件长任务继续跑，恢复后自动清除（用户口径）。
  Future<void> watchdog() async {
    load();
    _lastWatchdogRun = _nowSeconds();
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      final PluginHost? host = _hosts[pluginId];
      final PluginConfig? pluginConfig = config(pluginId);
      if (host == null || pluginConfig == null) continue;
      final bool alive = await host.ping();
      if (alive) {
        host.liveness.recordBeat();
        if (_degraded.remove(pluginId)) {
          log?.call('插件 $pluginId 心跳恢复（degraded 已清除）');
          _emitStatus(pluginConfig, 'registered', degraded: false);
          // 失活标记与解除各推一条（与本点位 readme 逐字一致）：**与 degraded 同一个
          // 判定源**（就是上面那个 `host.liveness`，不另造时钟），只是这里报的是“又听见了”。
          announcePluginState(
            pluginId,
            from: lifecycleOf(pluginId),
            to: lifecycleOf(pluginId),
            reason: '心跳恢复（degraded 已清除）',
            missedHeartbeats: host.liveness.missedCount,
          );
        }
        continue;
      }
      if (host.isClosed) {
        // **进程真的退出了**（不是"心跳丢了但还活着"）：快照口径本来就把 `isClosed`
        // 记成 `disabled`（见 snapshot 的 status 计算），这里把**增量**补上——
        // 否则前端只能等下一次快照 / 重启，而它声明过的卡片与面板会一直留在界面上
        // （真机反馈："关闭后卡片、面板均被保留"）。
        _degraded.remove(pluginId);
        // **进程真的没了 ⇒ 生命周期进 stopped**（不能让台账停在 ready：面板与
        // `plugin.state` 会一起说“就绪”，而它已经没了）。这一句同时把该插件的
        // 暂存队列以可读失败收尾（见 [_setLifecycle] 的 stopped 分支）。
        // 这**不是新增一个判死来源**：用的仍是 `PluginHost.isClosed`（快照本来就把
        // isClosed 记成 disabled），只是把同一个事实也写进生命周期台账（不变量 15）。
        _setLifecycle(pluginId, PluginLifecycleState.stopped);
        if (_dead.add(pluginId)) {
          log?.call('插件 $pluginId 进程已退出 ⇒ 广播 disabled（其声明的 UI 槽位应随之注销）');
          _emitStatus(pluginConfig, 'disabled', reason: '插件进程已退出');
        }
        continue;
      }
      host.liveness.recordMiss();
      if (host.liveness.isStale && _degraded.add(pluginId)) {
        log?.call(
          '插件 $pluginId 心跳丢失 ⇒ degraded（不自动终止，可显式重启）：'
          '${host.liveness.staleMessage}',
        );
        _emitStatus(
          pluginConfig,
          'registered',
          degraded: true,
          reason: host.liveness.staleMessage,
        );
        // 失活标记广播（发布点之二）：带的就是 degraded 那个判定源自己的丢失拍数，
        // **不另起时钟**；lifecycle 一字不改（它是 ready 还是 degraded 是两回事）。
        announcePluginState(
          pluginId,
          from: lifecycleOf(pluginId),
          to: lifecycleOf(pluginId),
          reason: host.liveness.staleMessage,
          missedHeartbeats: host.liveness.missedCount,
        );
      }
    }
    _reapStragglers();
  }

  /// 累计收尸（强杀）次数——“本核心到底杀了几个赖着不退的插件”这个总数必须能看见。
  int _straysKilled = 0;
  int get straysKilled => _straysKilled;

  /// **收尸**：把「已被要求关闭、但进程还没确认退出」的宿主按心跳判据收尾。
  ///
  /// 为什么这里刻意**不 ping**：stdin 已经关了，ping 写不出去 ⇒ 得到的「丢拍」是假的。
  /// 所以只用真实入站证据（[PluginHost] 收到任意一行即 [LivenessTracker.recordBeat]）
  /// 加每拍一次 [LivenessTracker.recordMiss]：慢转储 / 慢慢退的插件因此
  /// **不会因为时长被杀**（D8），只有连续 N 拍彻底沉默才收尸。
  ///
  /// 不单独起定时器：看门狗就是节拍本身，两套时钟会打架（D8 的定型理由）。
  void _reapStragglers() {
    for (final PluginHost host in _reaping.toList(growable: false)) {
      if (host.exitedConfirmed) {
        // 退出已确认 ⇒ 从台账里销账（不管它是自己退的还是被收的）
        _reaping.remove(host);
        continue;
      }
      if (host.killReason.isNotEmpty) continue; // 已经收过尸，等它确认退出
      host.liveness.recordMiss();
      if (!host.liveness.isStale) continue;
      final String reason =
          '插件 ${host.config.id} 被要求关闭后连续 ${host.liveness.missedCount} 拍'
          '没有心跳证据 ⇒ 收尸（强杀）。这是判失活后的收尸，'
          '不是拿时长判定（D8）：中间只要发过东西就不会走到这一行。';
      log?.call(reason);
      host.killStray(reason);
      _straysKilled++;
      // 刻意**不立刻移出台账**：一直留到确认退出为止，否则“这个进程到底有没有被收掉”
      // 在读数上直接消失（不变量 6：发生过的事必须看得见）。
    }
  }

  /// **收尸台账的读数**（只给观测与用例，不能拿来驱动行为：驱动只在
  /// [_reapStragglers] 一处）。
  ///
  /// 为什么需要它：被收尸的宿主已经不在 `_hosts` 里，`plugin.state` 看不见它——
  /// 而“这个赖着不退的进程到底有没有被杀、为什么被杀”必须能被看见（不变量 6/10）。
  List<Map<String, dynamic>> reapingReadings() => <Map<String, dynamic>>[
    for (final PluginHost host in _reaping)
      <String, dynamic>{
        'plugin_id': host.config.id,
        'missed_heartbeats': host.liveness.missedCount,
        'stale': host.liveness.isStale,
        'exited': host.exitedConfirmed,
        'killed': host.killReason.isNotEmpty,
        'kill_reason': host.killReason,
      },
  ];

  /// **显式重启**插件（心跳 degraded 之后由用户 / 上层决定，**不自动做**）。
  ///
  /// 这是**冷重启**：直接断开再拉起，不做转储。能挂起的插件请用
  /// [hotRestart]（它才会把可续跑状态递下一世）。
  Future<bool> restart(String pluginId) async {
    load();
    final PluginConfig? pluginConfig = config(pluginId);
    if (pluginConfig == null) return false;
    _setLifecycle(pluginId, PluginLifecycleState.restarting);
    await _disconnect(pluginId);
    await _startOne(pluginConfig);
    await refreshToolDefinitions();
    return _hosts.containsKey(pluginId);
  }

  /// **用户显式强制停止**一个插件实例：全项目里唯一能“因为有人按了按钮”而 `kill()`
  /// 的入口（D8）。
  ///
  /// 顺序刻意是“先走优雅那条路、再补一刀”：直接 kill 会留下一堆指向死进程的东西
  /// （站点订阅、工具表、UI 槽位、在途请求）。[_disconnect] 负责把那些一次收干净；
  /// 只有它没等到进程自己走完时，才强杀 —— 原因写进日志与读数（谁杀的、为什么）。
  ///
  /// **不得接成任何自动动作**：判死只看心跳与进程不可用两处（不变量 15），“跑得太久”
  /// 不是理由。也不能当作“停用”：对账看见 `enabled: true` 且没在跑就会再拉起来；
  /// 想彻底不跑请关开关（那才是停用）。
  ///
  /// 等的仍是**事件**而不是时长：kill 之后等“退出已确认”，没杀成就不等。
  Future<Map<String, dynamic>> forceStop(String pluginId) async {
    load();
    // 目标包括“已在实例表里”与“已在收尸台账里”两处：后者是上一世赖着不退的那个，
    // 只处理前一处会让“强制停止”对真正卡住的那个进程一无所获。
    final List<PluginHost> targets = <PluginHost>[
      ?_hosts[pluginId],
      for (final PluginHost host in _reaping)
        if (host.config.id == pluginId) host,
    ];
    await _disconnect(pluginId);
    int killed = 0;
    for (final PluginHost host in targets) {
      if (host.exitedConfirmed) continue;
      if (host.killReason.isEmpty) {
        host.killStray('用户显式强制停止插件 $pluginId');
        killed++;
        log?.call(
          '插件 $pluginId 被用户强制停止 ⇒ 显式 kill（这是唯一的用户强杀入口；'
          '不是时长判死，也不是看门狗收尸）',
        );
      }
      // 等“退出已确认”这个事件（close 已关过，这里只是把退出递回来）。
      await host.close(waitForExit: true);
    }
    return <String, dynamic>{
      'ok': true,
      'plugin_id': pluginId,
      'killed': killed,
      // 退出确认逐个数：没有目标（本来就没在跑）也算干净，否则面板会报“停不掉”。
      'exited': targets.every((PluginHost host) => host.exitedConfirmed),
      'lifecycle': lifecycleOf(pluginId).wire,
      'generation': generationOf(pluginId),
      // 原因从**目标宿主本身**读：`_disconnect` 已经把实例从表里摸掉了，
      // 再走 [_pluginState] 那条路只会拿到空串（“杀了但说不清为什么杀的”）。
      'kill_reason': targets
          .map((PluginHost host) => host.killReason)
          .firstWhere((String reason) => reason.isNotEmpty, orElse: () => ''),
      'note':
          '强制停止只结束这一世：条目仍是启用时，下一次对账会把它再拉起来'
          '（想不再跑请关掉开关）',
    };
  }

  /// 换文件前的**闸门**（阶段 5：从发布仓库装一条插件时由安装方调用）。
  ///
  /// 返回空串 = 这个插件的进程**已确认退出**，`plugins/` 里那些文件现在可以替换；
  /// 否则回**为什么现在不能换**的可读原因，调用方据此一个旧文件都不碰。
  ///
  /// 与 [forceStop] 的分工是刻意的：这里**绝不 kill**。「为了让新文件落地就强杀一个
  /// 正在干活的插件」= 核心替用户做了本该用户拍板的动作；这里只发优雅关闭通知，
  /// 然后等「退出已确认」这个**事件**（对照 D8：按失活心跳赛跑，不按墙钟赛跑）。
  /// 插件赖着不退就说「现在换不了」，由用户自己选「强制停止」那条显式路。
  ///
  /// 为什么把 [_reaping] 里同 id 的未确认实例也算进来：那是上一世赖着不退的进程，
  /// 它**同样锁着文件**——只看实例表会让闸门在明明还锁着的时候放行。
  ///
  /// 停下来的这一世是 `stopped`（不是 `restarting`）：换文件期间没有「下一世一定会回来」
  /// 的保证（安装可能失败），所以站点请求该按 stopped 的判据不投递，而不是暂存后重放
  /// 一个装不上的新版。
  Future<String> quiesceForSwap(String pluginId) async {
    load();
    final String id = pluginId.trim();
    final PluginHost? live = _hosts[id];
    final List<PluginHost> stragglers = <PluginHost>[
      for (final PluginHost host in _reaping)
        if (host.config.id == id && !host.exitedConfirmed) host,
    ];
    if (live == null && stragglers.isEmpty) {
      // 没有在跑的实例、也没有待收尸的残留 ⇒ 这台核心没在持那些文件，可以放置。
      // 注意这里**不看条目是否存在**：一条 `enabled: false` 的条目照样可能刚刚被
      // 强制停止留下残留，那已经由上面两个集合覆盖。
      return '';
    }
    if (live != null) {
      // 优雅关闭 + 把状态推给前端（面板要看得见「它停了」，不然用户以为没点上）。
      await _stopPlugin(id, '为替换插件文件而停止（发布仓库安装；没有强杀）');
    }
    final List<PluginHost> pending = <PluginHost>[
      if (live != null && !live.exitedConfirmed) live,
      ...stragglers,
    ];
    for (final PluginHost host in pending) {
      final Completer<void> stale = host.liveness.watchStale();
      try {
        // 两个事件赛跑：进程确认退出（可以换）/ 心跳判失活（换不了，且不许强杀）。
        await Future.any<void>(<Future<void>>[host.exited, stale.future]);
      } finally {
        host.liveness.unwatchStale(stale);
      }
      if (!host.exitedConfirmed) {
        return '插件 $id 的进程还没确认退出（优雅关闭已发出，它还在收尾或已失联）'
            '⇒ 这次**不替换文件**，旧文件一个都没动。'
            '等它退出后重试，或在面板上对它「强制停止」（那是唯一会强杀的动作）';
      }
    }
    return '';
  }

  // ── 生命周期映射（集中一处）─────────────────────────────────────────

  /// 某插件当前的**代际**（每次 [_startOne] +1；从未启动过 = 0）。
  int generationOf(String pluginId) => _generations[pluginId] ?? 0;

  /// 某插件当前的生命周期（未记录 = [PluginLifecycleState.stopped]）。
  ///
  /// 这是**唯一**的读入口：面板、REST 快照、`plugin_status` 帧、执行站
  /// `plugin.state` 全部从这里取。为什么不从 host 状态反推（isClosed / liveness /
  /// _errors 四个源各自算）：反推会得到四个互相矛盾的结论（“heartbeat 在但进程
  /// 退了”、“进程在但握手没成”……），而面板只能显示一个。台账显式写、只有一处写。
  PluginLifecycleState lifecycleOf(String pluginId) =>
      _lifecycle[pluginId] ?? PluginLifecycleState.stopped;

  /// 生命周期的**唯一写入口**：只在真的跃迁时记台账 + 写日志 + 驱动保活。
  ///
  /// 这里**故意不推 `plugin_status` 帧**：帧的产出点仍是原有的那几个（就绪 / 下线 /
  /// degraded），它们都改成从这里读 `lifecycle`。阶段 2 的状态跃迁走**自己的点位**
  /// （广播站 `plugin.state`，见 [announcePluginState]），不混进增量里。
  ///
  /// 为什么暂存队列的**收尾也挂在这里**（而不是挂在 hotRestart / restart 里）：
  /// 跃迁点有四处（启动 / 就绪 / 失败 / 下线），把收尾分散到四个调用方一定会漏一处；
  /// 漏掉的那一处就是「会话永远等一条不会被投递的请求」——那是比失败更难查的东西。
  void _setLifecycle(String pluginId, PluginLifecycleState state) {
    final PluginLifecycleState previous =
        _lifecycle[pluginId] ?? PluginLifecycleState.stopped;
    if (previous == state) return;
    _lifecycle[pluginId] = state;
    log?.call('插件 $pluginId 生命周期：${previous.wire} → ${state.wire}');
    // 跃出保活窗口 ⇒ 把在等就绪的工具调用方放回去（上面那个 future 的唯一完成来路）。
    if (!state.isTemporarilyUnavailable) _wakeLifecycleWaiters(pluginId);
    switch (state) {
      case PluginLifecycleState.ready:
        // ready **不清代管台账**：订阅申报常常晚于 ready 到达（插件收到 hello 回包
        // 才发 station/subscribe），在这里清掉就等于让 [_subscribeToStation] 看不出
        // 「这条声明是上一世留下的」，旧归属会和新归属同时挂在同一个点上。
        // 代管只有三条销账路：新实例重新申报（见 _subscribeToStation）、落到
        // stopped/failed（下面两个分支补注销）、核心退出（close 里整张清）。
        // 重放点仍在 ready：队列与申报路径是两件事，重放不依赖订阅台账。
        unawaited(_replayBuffered(pluginId));
        break;
      case PluginLifecycleState.stopped:
      case PluginLifecycleState.failed:
        final String why = state == PluginLifecycleState.failed
            ? '插件 $pluginId 本轮启动失败'
            : '插件 $pluginId 已下线';
        if (_stationKept.remove(pluginId)) {
          stations.unsubscribePlugin(pluginId);
          log?.call('$why ⇒ 补上重启窗口里押后的订阅注销（不再保活）');
        }
        _abandonBuffered(pluginId, '$why ⇒ 这些请求不再等待，各自的调用点按既有 fail-open 兜底');
        break;
      case PluginLifecycleState.booting:
      case PluginLifecycleState.restarting:
      case PluginLifecycleState.suspended:
        // 这三态都是「暂时不可用」：不重放也不收尾，新到的请求继续入队（有界）。
        break;
    }
    announcePluginState(pluginId, from: previous, to: state);
  }

  // ── 重启期保活：暂存 / 重放 / 收尾（阶段 2）──────────────────────

  /// 把一条站点请求**真的投出去**（重放与直投共用，不另开一条投递路径）。
  ///
  /// 宿主按插件 id **延迟解析**：重放时必须拿到新一世那个进程，而不是入队时那个
  /// （已经退掉了）。这与订阅时回包函数的延迟解析是同一个口径（见 [_subscribeToStation]）。
  Future<StationReply> _deliverStationRequest(
    String pluginId,
    StationRequest request,
  ) async {
    final PluginHost? host = _hosts[pluginId];
    if (host == null || host.isClosed) {
      return StationReply.failed('插件 $pluginId 未运行，无法处理站点请求');
    }
    return host.requestStation(request);
  }

  /// 某插件处于「暂时不可用」的哪一段（站点投递的分流判据）。
  ///
  /// 为什么以 **lifecycle** 而不是 `_hosts` 为判据：`_hosts` 只能回答「有没有进程」，
  /// 而重启窗口里真正的问题是「这个插件对外还算不算正常」（阶段 2 的命题）。
  /// 旧宿主在 `restarting` 的开头几毫秒可能还在表里，把它递一个正在转储的进程
  /// 等于亲手制造一次失败。
  bool _isKeepaliveWindow(String pluginId) =>
      lifecycleOf(pluginId).isTemporarilyUnavailable;

  /// 新一世**重新申报**订阅时，把上一世被保活代管的那份声明当场作废。
  ///
  /// 保活窗口里 [_disconnect] 刻意不注销订阅（注销了，窗口里到达的请求连暂存的
  /// 入口都没有）。留着它的代价是**可证明的**：若这一世改了归属（`scope.team_id`
  /// 变了），新声明会以**不同的键**再挂一份到同一个点上，旧那条 `team-1` 的声明
  /// 不会自己消失 —— 于是 team-1 的请求会被递给一个已经不属于 team-1 的进程：
  /// 那是隔离被绕过，不是「快照多一条读数」。归属声明只能有一份。
  ///
  /// 为什么两条申报路都要接（插件侧 station/subscribe + 核心侧工具表收集）：
  /// 收集站的订阅是 [refreshToolDefinitions] 自己下的，插件一行代码都不用写；
  /// 只堵插件那一路，改了 `scope` 的配置对账就会留下旧归属（对账用例直接可观测）。
  ///
  /// 只在「确实代管着」时动手（平时零开销）；注销后新一世会照常重新申报，
  /// 中间那个极短的缝隙按既有 fail-open 兜底，不谎报成成功。
  void _supersedeCarriedSubscriptions(String pluginId) {
    if (!_stationKept.remove(pluginId)) return;
    stations.unsubscribePlugin(pluginId);
    log?.call('插件 $pluginId 新一世重新申报订阅 ⇒ 注销上一世被保活代管的那份站点声明');
  }

  /// ready 后重放某插件的暂存请求（失败只写日志，绝不抛出：重放不能把就绪弄成失败）。
  Future<void> _replayBuffered(String pluginId) async {
    if (restartBuffer.lengthOf(pluginId) == 0) return;
    final int before = restartBuffer.replayedCount;
    await restartBuffer.replay(
      pluginId,
      deliver: (StationRequest request) =>
          _deliverStationRequest(pluginId, request),
      stillValid: (QueuedStationRequest item) =>
          _bufferedRequestStillValid(pluginId, item),
    );
    final int delivered = restartBuffer.replayedCount - before;
    if (delivered > 0) {
      log?.call('插件 $pluginId 就绪 ⇒ 重放重启窗口里暂存的 $delivered 条站点请求（FIFO）');
    }
  }

  /// 重放前的逐条复查（为什么不能无条件重放见 [PluginRestartBuffer.replay]）。
  ///
  /// 两条判据都**沿用已有台账**，不另造一套记录：
  /// - `request_id` 已收尾（done / error / 取消 / 活性窗口判无回）⇒ 按「迟到无害」丢，
  ///   与 [_handleStationStream] 对迟到增量的处置同一口径（用的就是同一个 [_closedStreamIds]）；
  /// - scope 与这个插件现在的声明不再相容 ⇒ 丢（fail-closed：宁可让调用点放行原数据，
  ///   也不把 A 工作面的请求递到 B 工作面上）。
  bool _bufferedRequestStillValid(String pluginId, QueuedStationRequest item) {
    if (_closedStreamIds.contains(item.request.requestId)) {
      log?.call(
        '重放前丢弃 ${item.request.requestId}：它的发起方已经收尾（迟到无害），'
        '不再递第二条给插件 ${item.request.stationId}',
      );
      return false;
    }
    final PluginConfig? cfg = config(pluginId);
    if (cfg == null) {
      log?.call('重放前丢弃一条请求：插件 $pluginId 已不在配置里（对账把它删了）');
      return false;
    }
    final StationIsolationVerdict verdict = StationIsolation.checkSubscriber(
      message: item.request.scope,
      subscriber: _scopeOf(cfg),
    );
    if (!verdict.ok) {
      log?.call(
        '重放前丢弃一条 ${item.request.stationId} 请求（归属不再相容）：${verdict.reason}',
      );
      return false;
    }
    return true;
  }

  /// 以可读失败收尾某插件的暂存队列（返回被结掉的条数）。
  int _abandonBuffered(String pluginId, String reason) =>
      restartBuffer.abandon(pluginId, reason);

  /// 暂存队列的水位（面板 / 广播载荷 / 用例都从这里读数，不另取一份）。
  Map<String, dynamic> restartBufferReadings() => restartBuffer.readings();

  /// **广播站点位「插件生命周期」**（`system.broadcast.plugin.state`，阶段 2 新增）。
  ///
  /// 发布点只有两处（与本点位 readme 逐字一致）：这里（生命周期的唯一写入口）与
  /// [watchdog] 的失活标记——后者与 `health` 用**同一个判定源** `LivenessTracker`，
  /// 不另造时钟（两套时钟必飘）。载荷含 `plugin_id` / `lifecycle` / `generation` /
  /// `missed_heartbeats` / `reason` / `buffer`。
  ///
  /// 与 [announceToolCall] 同口径：**单向通知**（`unawaited`，不等回包，投递结果
  /// 不回灌）——插件重启不该因为「有人在听广播」而多等一拍。
  ///
  /// 为什么需要它：重启窗口里插件对外仍是「正常状态」（不被路由真实任务、站点请求
  /// 被有界暂存后重放），所以「现在到哪个阶段了」必须由核心推出来，而不是让前端
  /// 靠「没回音」去猜（猜 = 把暂时不可用误报成挂了）。
  void announcePluginState(
    String pluginId, {
    required PluginLifecycleState from,
    required PluginLifecycleState to,
    String reason = '',
    int missedHeartbeats = 0,
  }) {
    load();
    if (!enabled) return;
    final BroadcastStation? station = stations.broadcastPointFor(
      StationHubIds.broadcastPluginState,
    );
    if (station == null) return;
    if (station.subscribers.isEmpty) return; // 快路径：没人订阅，零开销
    final PluginConfig? cfg = config(pluginId);
    if (cfg == null) return;
    final StationScope scope = _broadcastScopeOf(cfg);
    if (!scope.isValid) {
      // 不静默：为什么这条广播没发出去必须能查到（不变量 6）。
      log?.call(
        '插件生命周期广播跳过（$pluginId 的 ${scope.describe()} 不能证明归属，'
        'fail-closed）：${from.wire} → ${to.wire}',
      );
      return;
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'plugin_id': pluginId,
      'lifecycle': to.wire,
      'previous': from.wire,
      'generation': generationOf(pluginId),
      'missed_heartbeats': missedHeartbeats,
      if (reason.isNotEmpty) 'reason': reason,
      'buffer': restartBuffer.readings(),
    };
    _pluginStateBroadcasts++;
    unawaited(
      station
          .publish(
            topic: 'plugin.state',
            scope: scope,
            payload: payload,
            meta: <String, dynamic>{
              'plugin_id': pluginId,
              'lifecycle': to.wire,
            },
          )
          .then((StationPublishResult result) {
            if (result.deliveries.any((StationDelivery d) => !d.ok)) {
              log?.call('插件生命周期广播 ${result.describe()}');
            }
          })
          .catchError((Object error) {
            log?.call('插件生命周期广播异常（已忽略，不影响重启）：$error');
          }),
    );
  }

  /// **广播站点位「插件清单变更」**（`system.broadcast.config.changed`，阶段 6 新增）。
  ///
  /// 载荷 = `{point, plugin_id, action, reason, generation}`：`action` 直接取
  /// `PluginReconcileKind.name`（与 `applyConfigs` 的结论同源，不发明第二套词汇）。
  /// 与 [announcePluginState] 同口径：**单向通知**、没人订阅就零开销、投递失败只记日志；
  /// 对账不会因为「有人在听」而多等一拍。generation 取不到时不带（不发一个假的 0）。
  void _announceConfigChanged(PluginReconcileAction action) {
    load();
    if (!enabled) return;
    final BroadcastStation? station = stations.broadcastPointFor(
      StationHubIds.broadcastConfigChanged,
    );
    if (station == null) return;
    if (station.subscribers.isEmpty) return; // 快路径：没人订阅，零开销
    final PluginConfig? cfg = config(action.pluginId);
    final StationScope scope = cfg == null
        ? const StationScope()
        : _broadcastScopeOf(cfg);
    if (!scope.isValid) {
      // 条目已经被删除时对账仍会给 stopped —— 那时候插件自己证明不了归属，
      // 只能用核心已经解析出的那一份声明；证明不了就不发，但要说得出口。
      log?.call(
        '清单变更广播跳过（${action.pluginId} 的 ${scope.describe()} 不能证明归属，'
        'fail-closed）：${action.kind.name}',
      );
      return;
    }
    final int generation = generationOf(action.pluginId);
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'plugin_id': action.pluginId,
      'action': action.kind.name,
      'action_label': action.kind.label,
      'reason': action.reason,
      if (generation > 0) 'generation': generation,
    };
    unawaited(
      station
          .publish(
            topic: _broadcastTopicOf(station.id),
            scope: scope,
            payload: payload,
            meta: <String, dynamic>{
              'plugin_id': action.pluginId,
              'action': action.kind.name,
            },
          )
          .then((StationPublishResult result) {
            if (result.deliveries.any((StationDelivery d) => !d.ok)) {
              log?.call('清单变更广播 ${result.describe()}');
            }
          })
          .catchError((Object error) {
            log?.call('清单变更广播异常（已忽略，不影响对账）：$error');
          }),
    );
  }

  /// 广播载荷的**消息**四元组：以插件自己的声明为 team，mode 解析不出来时退回它的
  /// agent 的工作面（与 [_scopeOf] 同源，不自己猜）。
  ///
  /// 为什么不能像工具广播那样用调用点上下文：插件的生命周期不属于某个会话，它是
  /// 这个插件实例自己的事；拿声明做信封才能回答「这件事归哪个 team」。
  StationScope _broadcastScopeOf(PluginConfig cfg) {
    final StationScope declared = _scopeOf(cfg);
    if (StationModeKey.isValid(declared.modeKey)) return declared;
    final String agent = declared.agentId;
    if (agent.isEmpty) return declared;
    final String mode = agentModeKeyResolver?.call(agent) ?? '';
    return StationModeKey.isValid(mode)
        ? StationScope(
            teamId: declared.teamId,
            agentId: declared.agentId,
            sessionId: declared.sessionId,
            modeKey: mode,
          )
        : declared;
  }

  /// 已发出的生命周期广播条数（用例与面板用；与点位 readme 的「每个跃迁一条」对照）。
  int _pluginStateBroadcasts = 0;
  int get pluginStateBroadcasts => _pluginStateBroadcasts;

  // ── 热重启（阶段 1 的产出点）───────────────────────────────────────

  /// **热重启**：优雅转储 → 退出 → 新实例取回续跑。全程无磁盘转储、无时长误杀。
  ///
  /// 为什么不是“另建一套生命周期”：这里只复用 [_disconnect] + [_startOne]，在它们
  /// **之间**插入“转储/取回”两步。因此握手、工具申报、站点订阅、失败隔离与
  /// 冷启动 / 对账走的是同一条路径（不复制一套生命周期 = 不制造第二套会漂移的语义）。
  ///
  /// 流程与卡点（D8 / D4 / D3）：
  /// 1. 一进来就置 `restarting`（**早于** close：重启窗口内对外就该是这个阶段）；
  /// 2. [PluginHost.requestSuspend] 拿 ack（它与心跳判失活赛跑，不等时长）；
  /// 3. 等 `plugin.stateDump` 落池——与“进程确认退出”“心跳判失活”两个**事件**赛跑；
  /// 4. [_disconnect]（默认不等退出）→ [_startOne] 并带上 `resumeDumpId`；
  /// 5. 新实例用 `plugin.stateFetch` 取回（取回时 core 自己算“上一世”的代际）。
  ///
  /// 任何一步不成都**不报错**，而是降级成冷启动并带回可读原因（不变量 10）：
  /// “没声明 suspension”的插件本来就该冷重启（D3）。
  Future<PluginHotRestartResult> hotRestart(
    String pluginId, {
    bool keepState = true,
  }) async {
    load();
    final PluginConfig? pluginConfig = config(pluginId);
    if (pluginConfig == null) {
      return PluginHotRestartResult(
        pluginId: pluginId,
        ok: false,
        reason: '没有插件条目 $pluginId（plugins.yaml 里找不到 ⇒ 无从重启）',
      );
    }
    _setLifecycle(pluginId, PluginLifecycleState.restarting);
    final PluginHost? host = _hosts[pluginId];
    String dumpId = '';
    String reason = '';
    if (host == null) {
      reason = '实例本来不在跑 ⇒ 直接按冷启动拉起（无得可转储）';
    } else if (!keepState) {
      reason = '调用方显式不要状态（keep_state=false）⇒ 冷重启';
    } else {
      final ({bool ok, String reason}) ack = await host.requestSuspend();
      if (!ack.ok) {
        reason = ack.reason;
      } else {
        final String? waited = await _awaitDump(host, pluginId);
        dumpId = waited ?? '';
        reason = waited == null
            ? '插件 ack 了挂起，但没有把快照递进来 ⇒ 下一世按冷启动继续'
            : '快照已入池（$waited）';
      }
    }
    await _disconnect(pluginId);
    await _startOne(pluginConfig, resumeDumpId: dumpId);
    await refreshToolDefinitions();
    final bool ok = _hosts.containsKey(pluginId);
    final int generation = generationOf(pluginId);
    final String outcome = ok
        ? '插件 $pluginId 已热重启至第 $generation 代'
        : '插件 $pluginId 热重启后没能就绪（按失败隔离处理，不牵连其它插件）';
    log?.call('$outcome：$reason');
    return PluginHotRestartResult(
      pluginId: pluginId,
      ok: ok,
      resumed: ok && dumpId.isNotEmpty,
      dumpId: dumpId,
      generation: generation,
      lifecycle: lifecycleOf(pluginId).wire,
      reason: reason.isEmpty ? outcome : '$outcome（$reason）',
    );
  }

  /// 等一份快照落池：与「进程确认退出」「心跳判失活」赛跑，**不与时长赛跑**（D8）。
  ///
  /// 为什么不需要定时轮询也不用超时：三个事件里任何一个都能给出确定结论——
  /// 快照到了（成功）、进程退了（不会有了）、心跳判死（不再等）。插件“装死”最多
  /// 拖到连续 N 拍无入站证据，而真在忙（还在发东西）的插件永远不会被误判。
  Future<String?> _awaitDump(PluginHost host, String pluginId) async {
    final String? already = _dumpIdOfCurrentGeneration(pluginId);
    if (already != null) return already;
    final Completer<String?> waiter = Completer<String?>();
    _dumpWaiters[pluginId] = waiter;
    final Completer<void> stale = host.liveness.watchStale();
    String? hit;
    try {
      hit = await Future.any<String?>(<Future<String?>>[
        waiter.future,
        host.exited.then<String?>((void _) => null),
        stale.future.then<String?>((void _) => null),
      ]);
    } finally {
      host.liveness.unwatchStale(stale);
      if (identical(_dumpWaiters[pluginId], waiter)) {
        _dumpWaiters.remove(pluginId);
      }
    }
    // 退出 / 失活信号可能比落池动作早一个微任务：再读一次池，以事实为准。
    return hit ?? _dumpIdOfCurrentGeneration(pluginId);
  }

  /// 当前代际里这个插件那份**未消费**的快照 id（没有 = null）。
  String? _dumpIdOfCurrentGeneration(String pluginId) {
    final int generation = generationOf(pluginId);
    for (final PluginStateReading reading in statePool.readings()) {
      if (reading.pluginId == pluginId &&
          reading.generation == generation &&
          !reading.consumed) {
        return reading.dumpId;
      }
    }
    return null;
  }

  /// 执行站 `station.*` 族的**入口**（阶段 6：`station.list` / `station.state`）。
  ///
  /// 为什么控制面必须先能「看」：agent 要热重启**任何**插件（阶段 4 的 tool），得先
  /// 问得出「谁接管了哪个点位」——订走 `relay.llm.handle` 的那个插件被停掉，整条 LLM
  /// 就回退内置实现；看不见这层关系就只能靠猜（而猜错的代价是停在正在干活的插件上）。
  ///
  /// 归属口径（只有一条，且**不放大**）：
  /// - **内置点位对任何 team 可见**：它们是系统接口（名字、类型、谁订了它），不是
  ///   某个人的私有数据；
  /// - **插件自建站只对订阅者所在 team 可见**：别人的站里写着别人的 topic 与配置，
  ///   连「它存在」都不该漏出去；
  /// - team 证明不了 ⇒ 整条命令拒（fail-closed，与 `plugin.*` 控制面同口径）。
  ///
  /// 只**读**不改：接管权易手仍然走 `station/subscribe`（那套 replace 规则已经在
  /// 钉住的不变量里），这里不提供「把谁从点位上摘下来」的第二条路。
  Future<Map<String, dynamic>> handleStationQuery({
    required String command,
    required String teamId,
    Map<String, dynamic>? arguments,
    String sourcePluginId = '',
  }) async {
    load();
    final String team = teamId.trim();
    if (team.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error':
            '命令 $command 的 scope 缺少 team_id：证明不了归属 ⇒ 拒绝执行'
            '（fail-closed）',
      };
    }
    if (command == 'station.state') {
      final String requested = _stationArgId(arguments);
      if (requested.isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error':
              '命令 station.state 需要 arguments.station_id（或 point 别名，'
              '如 llm.handle）：要看哪个点位的当前读数',
        };
      }
      final String? id = _resolveStationId(requested);
      if (id == null) {
        return <String, dynamic>{
          'ok': false,
          'error': '找不到站点 $requested（内置点位可用别名，自建站要用完整 id）',
        };
      }
      final Map<String, dynamic> described = stations.snapshot().firstWhere(
        (Map<String, dynamic> s) => s['station_id'] == id,
        orElse: () => <String, dynamic>{},
      );
      if (described.isEmpty) {
        return <String, dynamic>{'ok': false, 'error': '站点 $id 不在当前快照里'};
      }
      if (!_stationVisibleToTeam(described, team)) {
        return <String, dynamic>{
          'ok': false,
          'error':
              '站点 $id 不属于 team $team：插件自建站只对它的订阅者所在 team 可见'
              '（跨 team 一律拒，不透露它存不存在）',
        };
      }
      return <String, dynamic>{
        'ok': true,
        'team_id': team,
        'station': described,
      };
    }
    if (command != 'station.list') {
      return <String, dynamic>{
        'ok': false,
        'error': '命令 $command 不在 station 族里（可用：station.list / station.state）',
      };
    }
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      for (final Map<String, dynamic> described in stations.snapshot())
        if (_stationVisibleToTeam(described, team))
          _stationRow(described, team),
    ];
    return <String, dynamic>{
      'ok': true,
      'team_id': team,
      'count': rows.length,
      'stations': rows,
      if (sourcePluginId.isNotEmpty) 'asked_by': sourcePluginId,
    };
  }

  /// 取 `station.state` 的目标 id（`station_id` 优先，允许写点位别名 `point`）。
  static String _stationArgId(Map<String, dynamic>? arguments) {
    final String explicit = (arguments?['station_id'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final String point = (arguments?['point'] ?? '').toString().trim();
    return point;
  }

  /// 把别名 / 后缀 / 完整 id 解析成内置点位 id；不是内置点位时原样当自建站 id。
  ///
  /// 为什么不能只认完整 id：插件作者手上写的是订阅时那套别名（`llm.handle`），
  /// 问读数却要求换一种写法就会造出「订得到、问不到」这种自相矛盾的面。
  static String? _resolveStationId(String requested) {
    final String want = requested.trim();
    if (want.isEmpty) return null;
    if (StationHubIds.all.contains(want)) return want;
    for (final StationPointSpec spec in StationPoints.all) {
      if (spec.alias == want) return spec.id;
      if (spec.suffix == want) return spec.id;
      if (spec.id.endsWith('.$want')) return spec.id;
    }
    // 自建站：没有别名概念，id 就是注册时那一个（看不见也回可读失败，不猜）。
    return want;
  }

  /// 这个站点对该 team 可见吗（内置恒可见；自建站要能看到订阅者或归属）。
  static bool _stationVisibleToTeam(
    Map<String, dynamic> described,
    String team,
  ) {
    if (described['builtin'] == true) return true;
    final Object? byTeam = described['subscribers_by_team'];
    if (byTeam is Map && byTeam.containsKey(team)) return true;
    // 自建站注册时把 owner 的 scope 记在站点自己的 scope 上（它没订阅者也要能被
    // 归属者看到，否则注册完就再也问不到了）。
    final Object? scope = described['scope'];
    if (scope is Map && '${scope['team_id']}'.trim() == team) return true;
    return false;
  }

  /// `station.list` 的一行（**投影**，不整份递 describe）。
  ///
  /// 为什么不递整份：`readme` / `board_latest` / `config` 里可能有别人的数据，而列表
  /// 的用途是「谁订了哪个点位 / 哪个点位已接管」。要看细节请对那一个点位下
  /// `station.state`（那里按可见性整份递，看得明明白白）。
  static Map<String, dynamic> _stationRow(
    Map<String, dynamic> described,
    String team,
  ) {
    final String kind = '${described['kind']}';
    final List<Object?> subscriptions =
        (described['subscriptions'] as List?) ?? const <Object>[];
    final List<Map<String, dynamic>> subscribers = <Map<String, dynamic>>[
      for (final Object? item in subscriptions)
        if (item is Map<String, dynamic>)
          <String, dynamic>{
            'plugin_id': item['plugin_id'],
            'team_id': (item['scope'] is Map
                ? '${(item['scope'] as Map)['team_id'] ?? ''}'
                : ''),
            'disabled': item['disabled'] == true,
          },
    ];
    return <String, dynamic>{
      'station_id': described['station_id'],
      'kind': kind,
      'kind_label': described['kind_label'],
      'builtin': described['builtin'] == true,
      'description': described['description'],
      'subscriber_count': subscribers.length,
      'subscribers': subscribers,
      // 中转站唯一处理者：这就是「谁接管了这一跳」的那一个读数。
      if (kind == 'relay')
        'handled_by': subscribers.isEmpty
            ? ''
            : '${subscribers.first['plugin_id']}',
      if (kind == 'execute') 'commands': described['commands'],
      'counts': described['counts'],
    };
  }

  /// 执行站 `plugin.*` 族的**入口**（挂载位置转进来）：干活 + 留审计。
  ///
  /// 为什么审计挂在这里而不是调用方：“热重启一个插件”是可以把别人在跑的会话
  /// 拍掉的动作，**谁、何时、对哪个插件、结果如何**必须事后查得到（不变量 6/10）。
  /// 挂在四个调用点（REST / agent tool / 看门狗 / UI）上就一定会漏一个，而漏掉的那个
  /// 恰好是最需要它的那一个。只记结论，不记载荷（快照内容不归日志管）。
  Future<Map<String, dynamic>> handlePluginCommand({
    required String command,
    required String pluginId,
    required String sourcePluginId,
    Map<String, dynamic>? arguments,
  }) async {
    final Map<String, dynamic> result = await _runPluginCommand(
      command: command,
      pluginId: pluginId,
      sourcePluginId: sourcePluginId,
      arguments: arguments,
    );
    if (PluginToolSurface.auditedCommands.contains(command)) {
      final String who = sourcePluginId.isEmpty ? '核心' : '插件 $sourcePluginId';
      final Object? ok = result['ok'];
      // 自重启那一条**没有布尔结论**（结论在下一回合）：审计里不许写成「成功」，
      // 否则事后查日志的人会以为重启已经完成，而它当时才刚排进事件循环。
      final String outcome = result['deferred'] == true
          ? '已受理（先应答再动手，结论见紧随其后的「自重启收尾」行）'
          : ok is bool
          ? (ok ? '成功' : '失败：${result['error'] ?? result['reason'] ?? '未给出原因'}')
          : '已受理（命令没给布尔结论）';
      log?.call(
        '插件控制面审计｜$_auditStamp｜$who ⇒ $command 目标=${pluginId.isEmpty ? '（全部）' : pluginId}｜$outcome',
      );
    }
    return result;
  }

  /// 审计行里的时间戳（到秒，带 ±HH:MM 偏移）：够定位“哪一次重启”，又不多到把日志搞脏。
  String get _auditStamp {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    // 偏移必须自己拼成 ±HH:MM：`Duration.toString()` 给的是 `8:00:00`，直接拼在秒后面
    // 就成了 `11:47:278:00:00` —— 而审计的唯一价值就是事后能读、能 grep。
    final Duration offset = now.timeZoneOffset;
    final int absMinutes = offset.inMinutes.abs();
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '${offset.inMinutes < 0 ? '-' : '+'}'
        '${two(absMinutes ~/ 60)}:${two(absMinutes % 60)}';
  }

  /// 执行站 `plugin.*` 族的实现（由 `ExecuteStationMounts.pluginManager` 转进来）。
  ///
  /// 「插件只能动自己的快照」已在挂载位置层校过一道（`_pluginCommand`）；这里再钉
  /// 一件更重的事：**键一律由核心拼**（`pluginId#generation`）。插件递来的
  /// `dump_id` 只做一致性复核，不许直接当键用——否则 A 插件可以靠猜 id 取走 B 的快照。
  ///
  /// **自重启不许挂死**（D2 的核心卡点）：`plugin.restart` / `plugin.suspend` 要回头
  /// 跟插件讲话（`suspend` 是核心→插件的请求）。如果发起者正是目标，那就成了
  /// 「正在等回包的进程被要求先回一条别的包」——单读循环的插件会当场卡住。
  /// 所以这两条命令在**目标 == 发起者**时先应答、后动手：用 [Timer.run] 排到
  /// 下一个事件循环回合（而不是 microtask：回包本身就在当前回合的微任务队列里，
  /// 抢在它前面写 suspend 就等于没修）。这是“核心代答”的最小形态；窗口内的
  /// 暂存重放是阶段 2 的活。
  Future<Map<String, dynamic>> _runPluginCommand({
    required String command,
    required String pluginId,
    required String sourcePluginId,
    Map<String, dynamic>? arguments,
  }) async {
    final Map<String, dynamic> args = arguments ?? const <String, dynamic>{};
    switch (command) {
      case 'plugin.list':
        return <String, dynamic>{
          'ok': true,
          'plugins': <Map<String, dynamic>>[
            for (final PluginConfig cfg in configs())
              <String, dynamic>{
                'plugin_id': cfg.id,
                'name': cfg.name,
                'enabled': cfg.enabled,
                'running': _isRunning(cfg.id),
                'lifecycle': lifecycleOf(cfg.id).wire,
                'generation': generationOf(cfg.id),
                'suspendable': cfg.canSuspend,
                'health': healthOf(cfg.id)['health'],
              },
          ],
        };
      case 'plugin.state':
        return _pluginState(pluginId);
      case 'plugin.restart':
        final bool keepState = args['keep_state'] != false;
        if (pluginId.isNotEmpty && pluginId == sourcePluginId) {
          // 先应答，下一回合再真动手（见上面注释里为什么必须是 Timer）。
          Timer.run(() {
            unawaited(
              hotRestart(pluginId, keepState: keepState).then(
                (PluginHotRestartResult result) =>
                    log?.call('自重启收尾：${result.reason}'),
              ),
            );
          });
          return <String, dynamic>{
            'ok': true,
            'deferred': true,
            'plugin_id': pluginId,
            'note':
                '重启目标就是发起者 ⇒ 核心先应答再动手（否则你会在等一条'
                '永远不会来的回包）；结果以插件下一世取回快照时的读数为准',
          };
        }
        final PluginHotRestartResult result = await hotRestart(
          pluginId,
          keepState: keepState,
        );
        return result.toJson();
      case 'plugin.suspend':
        return await _pluginSuspend(
          pluginId,
          deferred: pluginId.isNotEmpty && pluginId == sourcePluginId,
        );
      case 'plugin.stateDump':
        return _pluginStateDump(pluginId, args);
      case 'plugin.stateFetch':
        return _pluginStateFetch(pluginId, args);
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '插件命令 $command 没有实现（执行站 plugin.* 白名单内的命令才会走到这里）',
        };
    }
  }

  /// `plugin.state`：一个插件的完整运行态读数（只读，不改任何东西）。
  Map<String, dynamic> _pluginState(String pluginId) {
    final PluginConfig? cfg = config(pluginId);
    if (cfg == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '没有插件条目 $pluginId（plugins.yaml 里找不到）',
      };
    }
    final PluginHost? host = _hosts[pluginId];
    final Map<String, dynamic> health = healthOf(pluginId);
    return <String, dynamic>{
      'ok': true,
      'plugin_id': pluginId,
      'name': cfg.name,
      'enabled': cfg.enabled,
      'running': host != null && !host.isClosed,
      'status': host != null && !host.isClosed && cfg.enabled
          ? 'registered'
          : 'disabled',
      'lifecycle': lifecycleOf(pluginId).wire,
      'generation': generationOf(pluginId),
      'suspendable': cfg.canSuspend,
      'health': health['health'],
      'missed_heartbeats': health['missed_heartbeats'],
      'last_error': _errors[pluginId] ?? '',
      // 池里的快照只报水位，不报内容（面板也不该拿到插件内部状态）。
      'snapshots': <Map<String, dynamic>>[
        for (final PluginStateReading reading in statePool.readings())
          if (reading.pluginId == pluginId) reading.toJson(),
      ],
      'kill_reason': host?.killReason ?? '',
      // 重启窗口里为它暂存的站点请求条数（保活水位）；全局上限与溢出计数见
      // [restartBufferReadings]（广播载荷的 `buffer` 里带的就是它）。
      'buffered_station_requests': restartBuffer.lengthOf(pluginId),
    };
  }

  /// `plugin.suspend`：请求挂起（转储 + 记 `suspended`），**不代为退出也不拉起下一世**。
  ///
  /// 为什么这样切：`suspend` 是“把可续跑状态交出来”这个动作，而“换一世”是 restart
  /// 的职责。两个强绑在一起的话，“我只想看一下快照多大”也会把插件弄掉。
  Future<Map<String, dynamic>> _pluginSuspend(
    String pluginId, {
    required bool deferred,
  }) async {
    Future<Map<String, dynamic>> run() async {
      final PluginHost? host = _hosts[pluginId];
      if (host == null) {
        return <String, dynamic>{
          'ok': false,
          'error': '插件 $pluginId 没有在跑 ⇒ 无得可挂起（要看它的状态请用 plugin.state）',
        };
      }
      final ({bool ok, String reason}) ack = await host.requestSuspend();
      if (!ack.ok) {
        return <String, dynamic>{'ok': false, 'error': ack.reason};
      }
      final String? dumpId = await _awaitDump(host, pluginId);
      _setLifecycle(pluginId, PluginLifecycleState.suspended);
      return <String, dynamic>{
        'ok': true,
        'plugin_id': pluginId,
        'suspended': true,
        'dump_id': dumpId,
        'generation': generationOf(pluginId),
        'note': dumpId == null
            ? '插件 ack 了挂起，但没有递快照进来（下一世按冷启动继续）'
            : '快照已入池；本命令**不代为退出**，要换一世请用 plugin.restart',
      };
    }

    if (!deferred) return run();
    // 目标就是发起者：同 plugin.restart 那条路径，先应答再动手。
    Timer.run(() {
      unawaited(
        run().then((Map<String, dynamic> result) {
          log?.call('自挂起收尾：${result['dump_id'] ?? result['error'] ?? ''}');
        }),
      );
    });
    return <String, dynamic>{
      'ok': true,
      'deferred': true,
      'plugin_id': pluginId,
      'note': '挂起目标就是发起者 ⇒ 核心先应答再发 suspend（避免自己等自己）',
    };
  }

  /// `plugin.stateDump`：收一份快照入池（D4：只进内存，不落盘）。
  Map<String, dynamic> _pluginStateDump(
    String pluginId,
    Map<String, dynamic> args,
  ) {
    final PluginConfig? cfg = config(pluginId);
    if (cfg == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '没有插件条目 $pluginId ⇒ 快照无处归属，拒收',
      };
    }
    final Object? rawPayload = args['payload'];
    if (rawPayload is! Map) {
      return <String, dynamic>{
        'ok': false,
        'error':
            'plugin.stateDump 需要 arguments.payload（JSON 对象）：转储的内容就是它，'
            '核心不猜、也不空收一条“没内容的快照”',
      };
    }
    final int generation = generationOf(pluginId);
    if (generation < 1) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $pluginId 还没有任何一世（代际 = 0）⇒ 快照无处归属，拒收',
      };
    }
    final PluginStatePutResult put = statePool.put(
      pluginId: pluginId,
      generation: generation,
      payload: Map<String, dynamic>.from(rawPayload),
      // 写入归属 = **配置声明**（不是请求里带的 scope）：取回时用的是同一个推导，
      // 两边才能逐字相等。拿请求里的值写会造出“插件自己声明什么就能取什么”。
      scope: StationScope.parse(cfg.scope),
    );
    if (!put.accepted) {
      return <String, dynamic>{'ok': false, 'error': put.error};
    }
    final String? dumpId = put.dumpId;
    // 热重启那边的等待者以事件方式拿到结果（不轮询、不定时）。
    final Completer<String?>? waiter = _dumpWaiters.remove(pluginId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(dumpId);
    int bytes = 0;
    for (final PluginStateReading reading in statePool.readings()) {
      if (reading.dumpId == dumpId) bytes = reading.bytes;
    }
    return <String, dynamic>{
      'ok': true,
      'dump_id': dumpId,
      'plugin_id': pluginId,
      'generation': generation,
      'bytes': bytes,
      'pool_entries': statePool.length,
      'pool_bytes': statePool.totalBytes,
    };
  }

  /// `plugin.stateFetch`：取回**上一世**的快照并消费（一份快照只喂一世）。
  ///
  /// 代际由**核心自己算**（当前代 − 1），而不是让插件报“我要拿哪一世”：
  /// 注入宿主（测试）与自定义宿主拿不到 `hello` 参数，靠它传 dump_id 会把
  /// “取回续跑”这条主路卡在测试假宿主上；而“上一世是谁”本来就是核心的事实。
  Map<String, dynamic> _pluginStateFetch(
    String pluginId,
    Map<String, dynamic> args,
  ) {
    final PluginConfig? cfg = config(pluginId);
    if (cfg == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '没有插件条目 $pluginId ⇒ 无从确定快照归属',
      };
    }
    final int current = generationOf(pluginId);
    final int wanted = current - 1;
    final String expectedDumpId = '$pluginId#$wanted';
    // **点名核对排在“有没有上一世”之前**：插件报了一个对不上号的 dump_id，即使
    // 这一世本来就没有可取的东西也必须当场拒——那说明它对代际的理解与核心不一致，
    // 这句提醒比回一句“没有快照”有用得多（fail-closed 优先于客气）。
    final Object? rawWanted = args['dump_id'];
    if (rawWanted != null && rawWanted.toString().trim().isNotEmpty) {
      final String given = rawWanted.toString().trim();
      if (given != expectedDumpId) {
        return <String, dynamic>{
          'ok': false,
          'error':
              '插件 $pluginId 要求取回快照 $given，但它的上一世是 $expectedDumpId：'
              '快照键由核心拼，不接受指定别人的键',
        };
      }
    }
    if (wanted < 1) {
      return <String, dynamic>{
        'ok': true,
        'plugin_id': pluginId,
        'has_snapshot': false,
        'generation': current,
        'reason': '这是第 $current 代（没有上一世）⇒ 按冷启动继续',
      };
    }
    final int deniedBefore = statePool.deniedCount;
    final PluginStateSnapshot? snapshot = statePool.take(
      pluginId: pluginId,
      generation: wanted,
      scope: StationScope.parse(cfg.scope),
    );
    final bool denied = statePool.deniedCount > deniedBefore;
    if (snapshot == null) {
      return <String, dynamic>{
        'ok': true,
        'plugin_id': pluginId,
        'has_snapshot': false,
        'generation': current,
        'reason': denied
            ? '归属不符 ⇒ 不给取回（快照写在另一个工作面，不因为“换了进程”就放宽）'
            : '上一世没有留下可用快照（未转储 / 已被取走 / 超过存活时长）⇒ 按冷启动继续',
      };
    }
    return <String, dynamic>{
      'ok': true,
      'plugin_id': pluginId,
      'has_snapshot': true,
      'dump_id': snapshot.dumpId,
      'generation': snapshot.generation,
      'bytes': snapshot.bytes,
      'payload': snapshot.payload,
    };
  }

  /// **配置对账**（M9 §4.2「开关立刻有用」的核心入口）：重读磁盘配置，把运行中的
  /// 实例调整到与文件一致，并返回**结构化**的逐条结论。
  ///
  /// 为什么必须单独有这个方法：`load()` 幂等 = 配置只在核心启动时进内存，运行期
  /// 没有任何落点——于是前端改了开关也只能回"重启核心后生效"。这里把"磁盘 vs
  /// 运行实例"的差量算清楚，并**复用既有的 [_startOne] / [_disconnect]**（不复制一套
  /// 生命周期逻辑：握手、工具申报、站点订阅、状态广播、失败隔离因此与核心启动时
  /// 走的是同一条路径）。
  ///
  /// 判定口径：
  /// - 文件里**新增**且 enabled ⇒ 启动（started）；
  /// - **在跑且启动参数未变**（command / args / env / granularity / scope 全等）
  ///   ⇒ 一个字节都不动（unchanged）。**刻意不重启**：重启要打断插件正在跑的活、
  ///   丢掉它的内存态，而配置没变时重启换不来任何东西；
  /// - 在跑但启动参数变了 ⇒ 断开后用**新参数**启动（restarted，附变化字段名）；
  /// - enabled=false ⇒ 断开并从实例列表移除（stopped），配置条目**保留**
  ///   （面板据此显示"已停用"，再次打开沿用同一个 id）；
  /// - 文件里已删除 ⇒ 断开并忘掉（stopped；工具定义与站点订阅在 [_disconnect] 里注销）；
  /// - 单个插件启动失败（命令不存在等）⇒ 只进 failed（带可读原因），**不影响其它
  ///   插件**，与 [start] 同口径：一个插件崩了不牵连同级与核心；
  /// - 顶层总开关关闭 ⇒ 只断不启（与 [start] 提前返回同一口径）。
  ///
  /// 对账真的改动了运行态时，按既有机制补一次工具定义收集：下线插件的定义与站点
  /// 订阅已在 [_disconnect] 里注销，新上线插件的申报由这次 [refreshToolDefinitions]
  /// 收走。什么都没变时**不触发收集**（不白打扰插件），工具表也就没有失效点。
  Future<PluginReconcileResult> applyConfigs() async {
    final String? readError = _reloadConfigs();
    if (readError != null) {
      // 配置读不出来：保持现状，只把可读原因报上去（见 [_reloadConfigs] 的说明）
      return PluginReconcileResult(totalEnabled: enabled, error: readError);
    }
    final List<PluginReconcileAction> started = <PluginReconcileAction>[];
    final List<PluginReconcileAction> stopped = <PluginReconcileAction>[];
    final List<PluginReconcileAction> restarted = <PluginReconcileAction>[];
    final List<PluginReconcileAction> unchanged = <PluginReconcileAction>[];
    final List<PluginReconcileAction> failed = <PluginReconcileAction>[];
    final Map<String, PluginConfig> next = <String, PluginConfig>{
      for (final PluginConfig config in _configs) config.id: config,
    };

    // ① 文件里已消失的运行实例：断开并忘掉。放在最前面——被删掉的插件不该继续
    //    收事件、占着工具命名空间与站点订阅。
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      if (next.containsKey(pluginId)) continue;
      const String reason = '配置条目已删除：实例已断开并忘掉（工具定义与站点订阅一并注销）';
      await _stopPlugin(pluginId, reason);
      _errors.remove(pluginId); // 条目都没了，旧错误不该再留在探针里
      stopped.add(
        PluginReconcileAction(
          kind: PluginReconcileKind.stopped,
          pluginId: pluginId,
          reason: reason,
        ),
      );
    }

    // ② 逐条对账（按文件顺序，与 start() 的遍历口径一致）
    for (final PluginConfig config in _configs) {
      final bool running = _isRunning(config.id);
      if (!enabled) {
        if (running) {
          const String reason =
              '插件系统总开关为关（plugins.yaml 顶层 enabled: false）：实例已断开';
          await _stopPlugin(config.id, reason);
          stopped.add(
            PluginReconcileAction(
              kind: PluginReconcileKind.stopped,
              pluginId: config.id,
              reason: reason,
            ),
          );
        }
        continue;
      }
      if (!config.enabled) {
        if (running) {
          const String reason = '条目已停用（enabled: false）：实例已断开，条目仍保留在清单里';
          await _stopPlugin(config.id, reason);
          stopped.add(
            PluginReconcileAction(
              kind: PluginReconcileKind.stopped,
              pluginId: config.id,
              reason: reason,
            ),
          );
        } else {
          unchanged.add(
            PluginReconcileAction(
              kind: PluginReconcileKind.unchanged,
              pluginId: config.id,
              reason: '条目已停用，实例本来就没在运行',
            ),
          );
        }
        continue;
      }
      if (!running) {
        // 进程退出 / 被关掉留下的残留实例先摘干净：_startOne 见到"实例表里已经有
        // 这个 id"会直接返回，那样会把一个死进程当成已就绪（假成功）。
        if (_hosts.containsKey(config.id)) await _disconnect(config.id);
        final PluginReconcileAction action = await _startForReconcile(config);
        (action.kind == PluginReconcileKind.failed ? failed : started).add(
          action,
        );
        continue;
      }
      final PluginConfig? spawned = _spawnedConfigs[config.id];
      // spawned == null 只可能出现在"实例不是 _startOne 拉起来的"这种不该存在的
      // 情况；此时证明不了参数没变 ⇒ 按当前配置重启一次（宁多重启一次，也不用旧参数硬撑）
      final String diff = spawned == null
          ? '没有上次启动参数的记录'
          : describeStartupDiff(spawned, config);
      if (diff.isEmpty) {
        unchanged.add(
          PluginReconcileAction(
            kind: PluginReconcileKind.unchanged,
            pluginId: config.id,
            reason: '启动参数未变（command / args / env / granularity / scope 全等）：保持运行，不重启',
          ),
        );
        continue;
      }
      // **重启窗口对外保持正常状态**（阶段 2）：先置 restarting，下面那个 [_disconnect]
      // 才不会注销它的站点订阅（注销了，窗口里到达的请求连暂存的入口都没有）。
      // 配置驱动的换一世与 hotRestart / restart 是同一件事，不能一套保活一套不保活。
      _setLifecycle(config.id, PluginLifecycleState.restarting);
      await _disconnect(config.id);
      final PluginReconcileAction action = await _startForReconcile(
        config,
        changed: diff,
      );
      (action.kind == PluginReconcileKind.failed ? failed : restarted).add(
        action,
      );
    }

    final PluginReconcileResult result = PluginReconcileResult(
      started: started,
      stopped: stopped,
      restarted: restarted,
      unchanged: unchanged,
      failed: failed,
      totalEnabled: enabled,
    );
    // **广播站点位「插件清单变更」**（`system.broadcast.config.changed`，阶段 6 新增）：
    // 面板改开关、REST 写条目、发布仓库装完都走到这一遍对账，所以对外也只在这里说一次
    // （写两遍 = 两条入口的回报形状迟早漂）。`unchanged` **一律不发**：“没改动”不是变更，
    // 发了就是让监听插件每次对账白醒一次，而它读到的状态与上一帧完全一样。
    for (final PluginReconcileAction action in <PluginReconcileAction>[
      ...started,
      ...restarted,
      ...stopped,
      ...failed,
    ]) {
      _announceConfigChanged(action);
    }
    if (result.hasChanges) {
      invalidateToolTable(reason: '插件配置对账：运行态有变化');
      await refreshToolDefinitions();
      // 与 start() 同口径：有实例在跑就该有探活节拍（幂等）。对账刚把插件拉起来
      // 而心跳巡检还停着的话，它就没人判活了。
      _watchdogTimer ??= Timer.periodic(heartbeatInterval, (Timer _) {
        unawaited(watchdog());
      });
    }
    log?.call(result.describe());
    return result;
  }

  /// 某插件此刻**真的在跑**吗（实例在表里且进程没退出）。
  bool _isRunning(String pluginId) {
    final PluginHost? host = _hosts[pluginId];
    return host != null && !host.isClosed;
  }

  /// 拉起一个插件并归类成 started / restarted / failed（**单个插件的失败不外溢**）。
  Future<PluginReconcileAction> _startForReconcile(
    PluginConfig config, {
    String changed = '',
  }) async {
    try {
      await _startOne(config);
    } catch (error) {
      // _startOne 自己会吞掉常规失败；这里兜住任何意外，保证"一个插件的问题不会
      // 中断整轮对账"（失败隔离是对账口径的一部分，不是可选项）。
      _errors[config.id] = '$error';
    }
    if (_hosts.containsKey(config.id)) {
      return PluginReconcileAction(
        kind: changed.isEmpty
            ? PluginReconcileKind.started
            : PluginReconcileKind.restarted,
        pluginId: config.id,
        reason: changed.isEmpty ? '已按配置启动' : '启动参数变化（$changed）：已断开并按新参数启动',
      );
    }
    return PluginReconcileAction(
      kind: PluginReconcileKind.failed,
      pluginId: config.id,
      reason: _errors[config.id] ?? '启动失败（总线没有记录到原因）',
    );
  }

  /// 断开一个实例，并把"停用"如实推给前端（[reason] = 面板上显示的可读原因）。
  ///
  /// 比 [_disconnect] 多做的事就是**广播状态**：不广播的话前端只能等下一次快照，
  /// 用户点完开关还会看到"还在跑"——那这次热应用就白做了。
  Future<void> _stopPlugin(String pluginId, String reason) async {
    // 先留一份配置：_disconnect 会把这个实例的记录清掉，而广播要用它带
    // scope / granularity（条目被删时磁盘上已经找不到这一条了）。
    final PluginConfig? last = _spawnedConfigs[pluginId] ?? config(pluginId);
    await _disconnect(pluginId);
    if (last != null) _emitStatus(last, 'disabled', reason: reason);
  }

  /// 两份配置在**启动参数**上的差异（可读字段名；全等返回空串）。
  ///
  /// 只比"改了就必须重新拉起进程"的字段：command / args / env / granularity / scope。
  /// **name 不在其中**——它只是显示名，改它不需要重启（"不无谓重启"的一部分）；
  /// enabled 是启停开关，由 [applyConfigs] 的分支单独处理，不算"启动参数"。
  static String describeStartupDiff(PluginConfig running, PluginConfig next) {
    final List<String> fields = <String>[];
    if (running.command != next.command) fields.add('command');
    if (!_sameArgs(running.args, next.args)) fields.add('args');
    if (!_sameEnv(running.env, next.env)) fields.add('env');
    if (running.granularity != next.granularity) fields.add('granularity');
    if (!_sameScope(running.scope, next.scope)) fields.add('scope');
    return fields.join(' / ');
  }

  /// 三个"同构比较"：逐项比而不是拼串（值里出现分隔符会误判）。
  /// scope 的值是 dynamic（YAML 里可能是数字 / 布尔），一律按文本比。
  static bool _sameArgs(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameEnv(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, String> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static bool _sameScope(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, dynamic> e in a.entries) {
      if (!b.containsKey(e.key)) return false;
      if (b[e.key].toString() != e.value.toString()) return false;
    }
    return true;
  }

  /// **触发「插件定义 tool」收集站**：插件按 schema 申报 → 收集 → 注册成动态工具。
  ///
  /// 数据流（用户定稿）：站点 --（schema + 附带信息）--> 所有订阅插件
  /// --目标数据：工具定义（名称 / 描述 / 参数 / 执行方式）--> 站点 --> 这里。
  /// 「触发时机」由**调用方**决定（本类在 start() 后触发一次；工具表刷新处可再触发），
  /// 站点内部不做管线：注册进工具表就是这里的后续处理。
  ///
  /// **收集站全局唯一**（用户定稿语义）：核心内任何文件、任何时机的触发都命中同一个
  /// 实例，不再按 team×mode 复制。因此这里不再"每插件建一条站"，而是把全部启用插件
  /// 订阅到唯一站点上，然后用**消息 scope** 决定这一趟投给谁：
  /// - [scope] 非空 = 就用它作消息 scope（只投给与它相容的订阅者）；
  /// - 为空 = 用调用点四元组；再为空则退回各订阅者自己的声明 scope。
  ///
  /// **跨 team 不再被本方法过滤掉**（这是"方便跨 team 数据整合"的落点）：一圈收集
  /// 能看到所有 team 的订阅者；隔离交给两处 fail-closed——投递时的
  /// `StationIsolation.checkSubscriber`，以及工具表可见性 `_visible`（调用点看不到
  /// 别的 team 的工具）。跨 scope 的原因仍记进 `skipped` 供观测，不静默。
  Future<ToolDefinitionRefresh> refreshToolDefinitions({
    StationScope? scope,
    StationScopeContext context = const StationScopeContext(),
  }) async {
    load();
    if (!enabled) {
      // 总开关关闭：不再收集（也把脏标记清掉，免得每次工具表都排一次空刷新）
      _toolTableDirty = false;
      _toolTableCache.clear();
      // 点位申报表跟着清：开关关了就没有人在发，留着就是假的在册
      _capabilitiesByPlugin.clear();
      _capabilityNotes = const <String>[];
      return const ToolDefinitionRefresh();
    }
    final Set<String> stationIds = <String>{};
    final List<String> skipped = <String>[];
    // 唯一收集站（不存在则现建）：全部订阅者都挂在它上面。
    final CollectStation? station = stations.toolDefineStationFor();
    if (station == null) {
      // 收集站不可用（被同名非收集站占用等）：明确记录，不静默
      skipped.add('收集站不可用：${StationHubIds.collect} 已被非收集站占用');
    }
    // 点位（capability）申报收集站（阶段 6）：与工具收集**共用这一趟插件循环**。
    // 另开一条路就会让两边的「哪些插件算活着」漂开（同一套 scope 口径、同一套销账）。
    final CollectStation? capabilityStation = stations
        .capabilityDefineStationFor();
    final List<StationCollectedItem> capabilityItems = <StationCollectedItem>[];
    final List<StationUnresponsive> capabilityUnresponsive =
        <StationUnresponsive>[];
    // 这一趟的**消息 scope**：决定投给哪些订阅者。
    final List<StationScope> messageScopes = <StationScope>[];
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      final PluginHost? host = _hosts[config.id];
      if (host == null || host.isClosed) continue;
      final StationScope pluginScope = _scopeOf(config, context);
      // mode 填错（不是 local/ssh）⇒ 该插件不参与站点收集（可读原因进 skipped）
      if (!pluginScope.isValidSubscriber) {
        skipped.add(
          '插件 ${config.id} 的 scope.mode_key=${pluginScope.modeKey} 非法'
          '（只能是 local | ssh，或留空）',
        );
        continue;
      }
      // 跨 scope 只记原因、不再拦（全局收集站要能看到所有 team 的订阅者）
      final String? crossScope = _crossScopeReason(
        config.id,
        pluginScope,
        context,
      );
      if (crossScope != null) skipped.add(crossScope);
      if (station == null) continue;
      stationIds.add(station.id);
      // 收集站的订阅是核心自己下的（插件不必写一行代码）⇒ 这一路同样是「新一世
      // 重新申报」，必须先把上一世代管的那份作废，否则改了 scope 的配置对账会给
      // 旧团队留下一条还能投递的声明。见 [_supersedeCarriedSubscriptions]。
      _supersedeCarriedSubscriptions(config.id);
      stations.subscribe(
        station.id,
        StationSubscriber(
          pluginId: config.id,
          scope: pluginScope,
          subscribedAt: _nowSeconds(),
        ),
        (StationRequest request) =>
            _respondToToolDefinition(config, host, request),
      );
      // 点位申报的订阅与工具申报同一个插件、同一份 scope（少一个插件就两边都少）。
      if (capabilityStation != null) {
        stations.subscribe(
          capabilityStation.id,
          StationSubscriber(
            pluginId: config.id,
            scope: pluginScope,
            subscribedAt: _nowSeconds(),
          ),
          (StationRequest request) => _respondToCapability(host, request),
        );
      }
      // 采集的**消息 scope**：优先调用方指定（决定这一趟投给谁），其次插件声明，
      // 再次调用点运行期四元组。**消息侧必须能证明 team**（fail-closed）——
      // 通配订阅（team 为空）因此必须借调用点的 team，借不到就这一趟不收集
      // （该插件的工具已由 tools/list 旧路径注册，不是静默丢功能）。
      final StationScope? explicit = scope;
      final StationScope messageScope;
      if (explicit != null) {
        messageScope = explicit;
      } else if (pluginScope.teamId.trim().isNotEmpty) {
        messageScope = pluginScope;
      } else if (context.teamId.trim().isNotEmpty) {
        // 消息的 mode 必须有合法值（站点消息自校验）：插件没声明时按调用点 / 本地兜底
        final String mode = StationModeKey.isValid(pluginScope.modeKey)
            ? pluginScope.modeKey
            : (StationModeKey.isValid(context.modeKey)
                  ? context.modeKey
                  : StationModeKey.local);
        messageScope = StationScope(
          teamId: context.teamId.trim(),
          agentId: context.agentId.trim(),
          sessionId: context.sessionId.trim(),
          modeKey: mode,
        );
      } else {
        skipped.add(
          '插件 ${config.id} 是通配订阅（无 team），这一趟收集没有调用点团队上下文：'
          '跳过站点采集（工具仍走 tools/list 路径）',
        );
        continue;
      }
      if (!messageScope.isValid) {
        skipped.add(
          '插件 ${config.id} 这一趟收集的消息 scope 不完整'
          '（${messageScope.describe()}）：跳过站点采集（消息必须能证明归属）',
        );
        continue;
      }
      if (!messageScopes.any((StationScope s) => s.exactEquals(messageScope))) {
        messageScopes.add(messageScope);
      }
    }
    final List<StationCollectedItem> collected = <StationCollectedItem>[];
    final List<StationUnresponsive> unresponsive = <StationUnresponsive>[];
    if (station != null) {
      for (final StationScope messageScope in messageScopes) {
        final StationCollectResult result = await station.collect(
          scope: messageScope,
          meta: <String, dynamic>{
            'purpose': 'tool_definition',
            'plugin_config': configFile,
          },
        );
        collected.addAll(result.items);
        unresponsive.addAll(result.unresponsive);
        skipped.addAll(result.skipped);
        if (capabilityStation != null) {
          final StationCollectResult caps = await capabilityStation.collect(
            scope: messageScope,
            meta: <String, dynamic>{
              'purpose': 'capability_definition',
              'plugin_config': configFile,
            },
          );
          capabilityItems.addAll(caps.items);
          capabilityUnresponsive.addAll(caps.unresponsive);
        }
      }
    }
    // 后续处理（触发方职责）：按来源 plugin_id 注册成动态工具。
    final List<String> registered = <String>[];
    final List<String> removed = <String>[];
    final Map<String, List<PluginToolDefinition>> byPlugin =
        <String, List<PluginToolDefinition>>{};
    for (final StationCollectedItem item in collected) {
      final Object? payload = item.payload;
      final Object? rawTools = payload is Map ? payload['tools'] : null;
      if (rawTools is! List) {
        unresponsive.add(
          StationUnresponsive(
            subscriber: item.subscriber,
            reason: '产出缺少 tools 数组（按 schema 应为工具定义列表）',
          ),
        );
        continue;
      }
      final List<PluginToolDefinition> definitions = <PluginToolDefinition>[];
      for (final Object? rawTool in rawTools) {
        final PluginToolDefinition? definition = PluginToolDefinition.tryParse(
          pluginId: item.pluginId,
          scope: item.subscriber.scope,
          payload: rawTool,
          onError: (String error) => skipped.add('插件 ${item.pluginId}：$error'),
        );
        if (definition != null) definitions.add(definition);
      }
      byPlugin[item.pluginId] = definitions;
    }
    for (final MapEntry<String, List<PluginToolDefinition>> entry
        in byPlugin.entries) {
      removed.addAll(_definitions.replacePlugin(entry.key, entry.value));
      registered.addAll(
        entry.value.map((PluginToolDefinition d) => d.namespacedName),
      );
    }
    if (unresponsive.isNotEmpty || skipped.isNotEmpty) {
      final int unresponsiveCount = unresponsive.length;
      final int skippedCount = skipped.length;
      log?.call(
        '插件工具定义收集：注册 ${registered.length} 个；'
        '未响应 $unresponsiveCount 个；跳过 $skippedCount 条',
      );
    }
    // 点位申报表**每轮重建**（文件头口径 3）：插件下线 / 热重启旧世代 / 没回包
    // ⇒ 那一份自然不在新表里（不留“声明还在但没人发”的活口）。
    if (capabilityStation != null) {
      final CapabilityAbsorption absorbed = absorbCapabilityRows(
        items: capabilityItems,
        unresponsive: capabilityUnresponsive,
      );
      _capabilitiesByPlugin
        ..clear()
        ..addAll(absorbed.byPlugin);
      _capabilityNotes = absorbed.notes;
      for (final String note in absorbed.notes) {
        log?.call('点位申报：$note');
      }
    }
    // 一次收集完成 = 工具表不再脏（缓存随即清空，下次取表按新定义重建）
    final ToolDefinitionRefresh outcome = ToolDefinitionRefresh(
      stationIds: stationIds.toList(growable: false),
      collected: collected,
      unresponsive: unresponsive,
      skipped: skipped,
      registered: registered,
      removed: removed,
    );
    _toolTableDirty = false;
    _toolTableCache.clear();
    _lastToolTableRefresh = outcome;
    toolTableRefreshCount++;
    return outcome;
  }

  // ── 工具表：缓存 + 失效点（M9 Wave 3-I） ──────────────────────────────

  /// **模型工具表刷新点**（同步）：返回当前模型工具表（插件部分）。
  ///
  /// 「收集站的触发时机由调用方决定」：这里就是触发方入口。工具表脏了（插件上线 /
  /// 下线 / 重启 / 换 scope）才**后台**触发一次收集，本次仍返回手上这一份——
  /// 「缓存 + 失效点」因此保证**每次工具调用都不会全量收集**；插件工具列表的变化
  /// 在本次就立刻体现（定义表随生命周期事件同步增删），重新收集只是把插件的申报
  /// 再核一遍（心跳仍在的插件照旧应答）。
  List<({String pluginId, PluginToolInfo tool})> toolTable({
    StationScope? scope,
  }) {
    load();
    if (_toolTableDirty) _scheduleToolTableRefresh(scope);
    final String key = _toolTableKey(scope);
    final List<({String pluginId, PluginToolInfo tool})>? cached =
        _toolTableCache[key];
    if (cached != null) return cached;
    final List<({String pluginId, PluginToolInfo tool})> built = allTools(
      scope: scope,
    );
    _toolTableCache[key] = built;
    return built;
  }

  /// **确保**工具表已收集过（异步；需要确定性的调用点与测试用）。
  ///
  /// 不脏的时候不会重复触发收集（返回上一次的结论）。
  Future<ToolDefinitionRefresh> ensureToolTableFresh({
    StationScope? scope,
    StationScopeContext context = const StationScopeContext(),
  }) async {
    load();
    if (!_toolTableDirty) {
      return _lastToolTableRefresh ?? const ToolDefinitionRefresh();
    }
    return refreshToolDefinitions(scope: scope, context: context);
  }

  /// 工具表是否脏（有失效点未处理）。
  bool get toolTableDirty => _toolTableDirty;

  /// **失效点**：插件上线 / 下线 / 重启时标脏并清缓存（下次刷新点重新收集）。
  void invalidateToolTable({String reason = ''}) {
    _toolTableDirty = true;
    _toolTableCache.clear();
    if (reason.isNotEmpty) {
      log?.call('插件工具表失效（$reason）：下次工具表刷新点会重新收集');
    }
  }

  /// 调用点 → **运行期四元组**（M9 Wave 3-I）。
  ///
  /// - team / agent / session：取 [callSiteContext]（核心按 agent 的团队归属解析），
  ///   未接线时只带 agent / session；
  /// - mode_key：由 [agentModeKeyResolver] 从**目标 agent 的工作空间模式**解析
  ///   （local | ssh），证明不了时退回上下文 / 声明里的值（缺省 local）。
  StationScope runtimeScopeFor({
    required String agentId,
    required String sessionId,
  }) {
    final StationScopeContext context =
        callSiteContext?.call(agentId, sessionId) ??
        StationScopeContext(agentId: agentId, sessionId: sessionId);
    final String agent = context.agentId.trim().isNotEmpty
        ? context.agentId.trim()
        : agentId.trim();
    final String session = context.sessionId.trim().isNotEmpty
        ? context.sessionId.trim()
        : sessionId.trim();
    final String fromAgent = agent.isEmpty
        ? ''
        : (agentModeKeyResolver?.call(agent) ?? '');
    final String mode = StationModeKey.isValid(fromAgent)
        ? fromAgent
        : (StationModeKey.isValid(context.modeKey)
              ? context.modeKey
              : StationModeKey.local);
    return StationScope(
      teamId: context.teamId.trim(),
      agentId: agent,
      sessionId: session,
      modeKey: mode,
    );
  }

  /// 把**执行站首命令集的挂载位置**接到全部执行站（M9 Wave 3-I；幂等）。
  ///
  /// 返回 null = 全部挂载成功；否则是可读原因（不静默）。
  String? mountExecuteStations(ExecuteStationMounts mounts) {
    final List<String> failed = <String>[];
    stations.mountExecuteStations((ExecuteStation station) {
      final String? error = mounts.mountInto(station);
      if (error != null) failed.add(error);
    });
    if (failed.isEmpty) return null;
    return failed.join('；');
  }

  /// **工具调用的中转站触发点**（工具层唯一入口调用；`phase` = pre | post）。
  ///
  /// 「把完整 tool_call 交给插件，改什么甚至不改由插件内部决定」——因此 payload 是
  /// **整条调用报文**（工具名 / 调用 id / 轮次 / 参数或结果），回填可以是对象
  /// （整体替换报文）或字符串（只替换结果文本）。
  ///
  /// **fail-open 红线**：未接线 / 无订阅者 / 订阅者未回 / 回包非法 / 任何异常，
  /// 一律返回原报文并给可读原因，绝不抛出、绝不阻塞工具执行。
  ///
  /// 返回 null = 与输入完全相同（**未改动**，调用方零开销走原路径）。
  Future<Map<String, dynamic>?> relayToolCall({
    required String phase,
    required String tool,
    required String callId,
    required int round,
    required String agentId,
    required String sessionId,
    Map<String, dynamic>? arguments,
    String result = '',
    bool isError = false,

    /// 这次调用是谁发起的（`agent` = 模型的工具调用；`plugin` = 插件经 `tool.call`）。
    ///
    /// 与广播 payload 同口径：中转订阅者拿到它才能区分"模型的调用"与"自己发起的
    /// 调用"（否则一个既订 `tool.pre`、又用 `tool.call` 的插件无法在中转侧闭环审计）。
    String origin = 'agent',
    String sourcePluginId = '',
  }) async {
    load();
    if (!enabled) return null;
    // 无运行期四元组（测试 / 嵌入式宿主未接线）⇒ 站点隔离证明不了归属，直接放行。
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return null;
    // 点位化：工具前 / 工具后是**两个独立的中转站点位**（各自唯一订阅者）。
    // payload 仍带 phase（向后兼容：老订阅者就是按 phase 过滤的）。
    final bool isPost = phase == 'post';
    final RelayStation? station = stations.relayPointFor(
      isPost ? StationHubIds.relayToolPost : StationHubIds.relayToolPre,
    );
    if (station == null) {
      // 走到这里 = 站点中枢没接线 / 点位被占成了别的类型（后者已在 load() 纠正并
      // 记日志）。fail-open 也要留线索，别让"插件没生效"变成零日志的悬案。
      log?.call(
        '工具中转（$phase $tool）：点位 '
        '${isPost ? StationHubIds.relayToolPost : StationHubIds.relayToolPre}'
        ' 不可用（未接线 / 类型不符），按未接线放行原报文',
      );
      return null;
    }
    if (station.subscribers.isEmpty) return null; // 快路径：没人订阅，零等待
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'phase': phase,
      'origin': origin,
      if (sourcePluginId.isNotEmpty) 'source_plugin_id': sourcePluginId,
      'tool': tool,
      'call_id': callId,
      'round': round,
      'arguments': ?arguments,
      if (phase == 'post') 'result': result,
      if (phase == 'post') 'is_error': isError,
    };
    try {
      final StationRelayResult relayed = await station.relay(
        data: payload,
        scope: scope,
        meta: <String, dynamic>{'tool': tool, 'call_id': callId},
      );
      if (!relayed.handled) {
        if (relayed.reason.isNotEmpty) {
          log?.call('工具中转（$phase $tool）未处理：${relayed.reason}');
        }
        return null;
      }
      final Object? data = relayed.data;
      if (data is Map) {
        final Map<String, dynamic> next = data.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        );
        // 未改动（内容相等）⇒ 返回 null，走原路径（避免无谓的对象替换）
        if (_sameMap(next, payload)) return null;
        return next;
      }
      if (data is String) {
        // 字符串回填 = 只替换结果文本（pre 阶段没有可替换的文本 ⇒ 视为未改动）
        if (phase != 'post' || data == result) return null;
        return <String, dynamic>{...payload, 'result': data};
      }
      log?.call(
        '工具中转（$phase $tool）：回填类型 ${data.runtimeType} 无法并入报文，'
        '按原样放行',
      );
      return null;
    } catch (error) {
      log?.call('工具中转（$phase $tool）异常（已放行原报文）：$error');
      return null;
    }
  }

  // ── 阶段 6 A 级：四个新中转点位（tool.repair / tool.probe / llm.register /
  //   compact.skip.reason）───────────────────────────────────────────────

  /// 这四个点位的**共同投递形状**（只写一次，否则四处 fail-open 口径一定漂）。
  ///
  /// 返回 null = **未接管**（点位不可用 / 无订阅者 / 没回 / 回包失败 / 异常），
  /// 调用方一律走内置那一条；绝不抛、绝不阻塞。接管了就把回包原样递上去（Map）。
  Future<Object?> _relayRaw(
    String pointId, {
    required Map<String, dynamic> payload,
    required StationScope scope,
    required String label,
    Map<String, dynamic>? meta,
  }) async {
    final RelayStation? station = stations.relayPointFor(pointId);
    if (station == null) {
      log?.call('$label：点位 $pointId 不可用（未接线 / 类型不符），按内置走');
      return null;
    }
    if (station.subscribers.isEmpty) return null; // 快路径：没人订阅，零等待
    try {
      final StationRelayResult relayed = await station.relay(
        data: <String, dynamic>{...payload, 'point': station.id},
        scope: scope,
        meta: meta ?? payload,
      );
      if (!relayed.handled) {
        if (relayed.reason.isNotEmpty) {
          log?.call('$label 未处理：${relayed.reason}');
        }
        return null;
      }
      return relayed.data;
    } catch (error) {
      log?.call('$label 异常（按内置走）：$error');
      return null;
    }
  }

  /// 中转点 `tool.repair`：历史里缺工具结果时，那句**修复文案由谁写**。
  ///
  /// 只接管“写什么”：落库与 `tool_end` 帧仍然只走内置那一条路（不开第二条落库路）。
  /// 返回 null ⇒ 用内置那句（`autoRepairToolResultText`），**不会因本站失败而修不了**。
  Future<String?> relayToolRepairText({
    required String agentId,
    required String sessionId,
    required String toolCallId,
    required String toolName,
    required String text,
  }) async {
    load();
    if (!enabled) return null;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return null;
    final Object? data = await _relayRaw(
      StationHubIds.relayToolRepair,
      label: '工具结果修复文案',
      meta: <String, dynamic>{'call_id': toolCallId},
      payload: <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        'text': text,
      },
      scope: scope,
    );
    if (data is! Map) return null;
    if (data['repaired'] != true) return null;
    final String better = '${data['text'] ?? ''}'.trim();
    if (better.isEmpty) {
      log?.call('工具结果修复文案：回包 repaired=true 但没带 text（用内置那句）');
      return null;
    }
    return better;
  }

  /// 中转点 `tool.probe`：“这次工具调用是不是已经有结果”由谁回答。
  ///
  /// 三档结果缺一不可（所以下面返回一个对象而不是 String?）：
  /// - null ⇒ **未接管**，调用方走内置探针（查库）；
  /// - `found: true` ⇒ 插件交出结果原文；
  /// - `found: false` ⇒ 插件**肯定地**说没有（也不再进内置探针：结果在插件那一侧，
  ///   库里查不到本来就是预期的）。
  Future<StationToolProbeVerdict?> relayToolProbe({
    required String agentId,
    required String sessionId,
    required String toolCallId,
  }) async {
    load();
    if (!enabled) return null;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return null;
    final Object? data = await _relayRaw(
      StationHubIds.relayToolProbe,
      label: '工具结果探针',
      meta: <String, dynamic>{'call_id': toolCallId},
      payload: <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
        'tool_call_id': toolCallId,
      },
      scope: scope,
    );
    if (data is! Map) return null;
    final Object? found = data['found'];
    if (found is! bool) {
      log?.call(
        '工具结果探针：回包没有布尔 found（实际 ${data['found'].runtimeType}），'
        '按未接管走内置探针',
      );
      return null;
    }
    return StationToolProbeVerdict(
      found: found,
      text: '${data['text'] ?? data['result'] ?? ''}',
    );
  }

  /// 中转点 `llm.register`：把一次运行中请求的**登记**投给插件（fire-and-forget）。
  ///
  /// **内置登记表永远先建立**（它是流式可关闭性的唯一执行点），所以这里不 await、
  /// 也不允许回包影响请求本身：插件回的 `note` 只进日志（计费 / 审计拿得到
  /// handle 与模型就够了）。取消 / 关闭 / 判死三个动作仍然只在核心里。
  void relayLlmRegisterNotice({
    required String handle,
    required String agentId,
    required String sessionId,
    required String model,
    required int turn,
  }) {
    load();
    if (!enabled) return;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return;
    unawaited(
      _relayRaw(
        StationHubIds.relayLlmRegister,
        label: 'LLM 请求登记',
        meta: <String, dynamic>{'handle': handle},
        payload: <String, dynamic>{
          'handle': handle,
          'agent_id': agentId,
          'session_id': sessionId,
          'model': model,
          'turn': turn,
        },
        scope: scope,
      ).then((Object? data) {
        if (data is! Map) return;
        final String note = '${data['note'] ?? ''}'.trim();
        if (note.isEmpty) return;
        // 回执只进日志：登记本身已经成立，这里不拿它改写任何判据。
        log?.call('LLM 请求登记回执（$handle）：$note');
      }),
    );
  }

  /// 中转点 `compact.skip.reason`：把“压缩为什么没走插件”那句原因投给插件，
  /// 插件可回一句更准的说法**覆盖那一条记录**（只改文案，不改分级位）。
  ///
  /// [hasSubscriber]=false（总开关关 / 作用域不匹配 / 无订阅者）时**不投**：根本没
  /// 插件在路上，投了只会多一条没人接的帧。回得太晚（这一轮已经收尾）就自然失效：
  /// [compactionSkipAnnotator] 只会覆盖还在账上那条，不会凭空造一条。
  void relayCompactSkipReason({
    required String agentId,
    required String sessionId,
    required String reason,
    required bool hasSubscriber,
  }) {
    load();
    if (!enabled || !hasSubscriber) return;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return;
    unawaited(
      _relayRaw(
        StationHubIds.relayCompactSkipReason,
        label: '压缩未接管原因',
        meta: <String, dynamic>{'session_id': sessionId},
        payload: <String, dynamic>{
          'agent_id': agentId,
          'session_id': sessionId,
          'reason': reason,
        },
        scope: scope,
      ).then((Object? data) {
        if (data is! Map) return;
        final String better = '${data['reason'] ?? ''}'.trim();
        if (better.isEmpty || better == reason) return;
        final void Function(String, String, String)? annotator =
            compactionSkipAnnotator;
        if (annotator == null) {
          log?.call('压缩未接管原因：插件回了更准的说法，但回写口未接线（不假装改过）');
          return;
        }
        annotator(agentId, sessionId, better);
      }),
    );
  }

  // ── 中转站点位：LLM 路径（点位化，2026-10-01） ─────────────────────────────
  //
  // 四个点位，各自独立实例、各自唯一订阅者：
  //   system.relay.llm.handle        LLM 处理（接管，含**流式回填**）
  //   system.relay.llm.request       投入 LLM 前（改写请求体）
  //   system.relay.context.compact   上下文压缩过程
  //   system.relay.prompt.system     系统提示词构造过程
  //
  // 全部遵守中转站的三条不变量：无订阅者 ⇒ 零等待走系统默认；未回填 / 回包非法 /
  // 心跳丢失 / 任何异常 ⇒ 回退系统默认（fail-open）；每个点位唯一订阅者。

  /// 打开中的「LLM 处理」插件流（`request_id` → 流状态）。
  final Map<String, _PluginLlmStream> _llmStreams =
      <String, _PluginLlmStream>{};

  /// **比流登记更早到达**的 `station/stream` 通知（`request_id` → 帧列表）。
  ///
  /// 为什么需要：核心是**处理完插件的回包之后**才把流登记进 [_llmStreams]，而插件
  /// 常常在"发出回包"的同一瞬间就开始推第一片增量——那条通知可能先到（同一个读循环
  /// tick）。早到的通知按 `request_id` 暂存，流一登记就**按原插件身份重放**（归属
  /// 校验照走一遍），于是"回包后立刻推流"不必靠节流/时序兜底。
  ///
  /// 有界：最多 [maxPendingStreamFrames] 条、最多 [maxPendingStreamIds] 个 request_id，
  /// 溢出丢最旧并记可读日志（绝不无界增长）。
  final Map<String, List<_PendingStreamFrame>> _pendingStreamFrames =
      <String, List<_PendingStreamFrame>>{};

  /// 早到通知的条数上限（跨所有 request_id）。
  static const int maxPendingStreamFrames = 128;

  /// 早到通知的 request_id 上限（防止伪造 id 撑爆内存）。
  static const int maxPendingStreamIds = 32;

  int get _pendingStreamFrameCount => _pendingStreamFrames.values.fold<int>(
    0,
    (int sum, List<_PendingStreamFrame> frames) => sum + frames.length,
  );

  /// 暂存一条早到的 `station/stream`（有界；溢出丢最旧并记日志）。
  void _bufferStreamFrame(
    String pluginId,
    String requestId,
    Map<String, dynamic> params,
  ) {
    if (_pendingStreamFrames.length >= maxPendingStreamIds &&
        !_pendingStreamFrames.containsKey(requestId)) {
      final String oldest = _pendingStreamFrames.keys.first;
      final int dropped = _pendingStreamFrames.remove(oldest)?.length ?? 0;
      log?.call(
        '插件 $pluginId 的 station/stream（$requestId）无法暂存：'
        '待关联的 request_id 已达上限 $maxPendingStreamIds，丢弃最旧的 $oldest（$dropped 条）',
      );
    }
    final List<_PendingStreamFrame> frames = _pendingStreamFrames.putIfAbsent(
      requestId,
      () => <_PendingStreamFrame>[],
    );
    frames.add(_PendingStreamFrame(pluginId: pluginId, params: params));
    while (_pendingStreamFrameCount > maxPendingStreamFrames) {
      final String oldest = _pendingStreamFrames.keys.first;
      final List<_PendingStreamFrame> bucket = _pendingStreamFrames[oldest]!;
      bucket.removeAt(0);
      if (bucket.isEmpty) _pendingStreamFrames.remove(oldest);
      log?.call(
        '早到的 station/stream 超过上限 $maxPendingStreamFrames 条，'
        '丢弃最旧的一条（request_id=$oldest）',
      );
    }
  }

  /// 把某 `request_id` 的早到通知按**原插件身份**重放（流登记后调用一次）。
  void _replayStreamFrames(String requestId) {
    final List<_PendingStreamFrame>? frames = _pendingStreamFrames.remove(
      requestId,
    );
    if (frames == null || frames.isEmpty) return;
    log?.call('LLM 接管流 $requestId：重放 ${frames.length} 条早到的 station/stream');
    for (final _PendingStreamFrame frame in frames) {
      // 走同一条入口 ⇒ 归属校验与"取消后丢弃"的判定都照旧生效
      _handleStationStream(frame.pluginId, frame.params);
    }
  }

  /// **丢弃**暂存的早到通知（流收尾 / 插件下线 / 溢出时）。
  ///
  /// [requestId] 非空只清那个 id；[pluginId] 非空只清该插件的帧。
  /// 丢弃一定记可读日志：暂存本身是"正常竞态"，但**从没被重放就丢掉**意味着有插件
  /// 在用一个不存在的 `request_id` 推流（最常见的原因：把 JSON-RPC 报文的 `id`
  /// 当成了 `request_id`）——静默丢弃会让插件侧毫无反馈。
  void _dropPendingStreamFrames({String? pluginId, String? requestId}) {
    final List<String> removedIds = <String>[];
    int dropped = 0;
    if (requestId != null) {
      dropped += _pendingStreamFrames.remove(requestId)?.length ?? 0;
      if (dropped > 0) removedIds.add(requestId);
    } else {
      final List<String> ids = _pendingStreamFrames.keys.toList();
      for (final String id in ids) {
        final List<_PendingStreamFrame>? frames = _pendingStreamFrames[id];
        if (frames == null) continue;
        if (pluginId == null) {
          dropped += frames.length;
          _pendingStreamFrames.remove(id);
          removedIds.add(id);
          continue;
        }
        final int before = frames.length;
        frames.removeWhere(
          (_PendingStreamFrame frame) => frame.pluginId == pluginId,
        );
        dropped += before - frames.length;
        if (frames.isEmpty) _pendingStreamFrames.remove(id);
        if (before != frames.length) removedIds.add(id);
      }
    }
    if (dropped == 0) return;
    log?.call(
      '丢弃 $dropped 条从未关联上在途流的 station/stream'
      '${removedIds.isEmpty ? '' : '（request_id：${removedIds.join('、')}）'}'
      '${pluginId == null ? '' : '，来源插件 $pluginId'}'
      '——注意：station/stream 要带**请求 params 里的 request_id**，不是 JSON-RPC 报文的 id',
    );
  }

  /// 暂存中的早到通知条数（快照 / 测试用；正常情况为 0）。
  int get pendingStreamFrames => _pendingStreamFrameCount;

  /// **刚刚收尾**的流 id（最近 [maxClosedStreamIds] 个）。
  ///
  /// 为什么需要：同一个 `request_id` 只有两种"当前没有流"的情形，处理方式相反——
  /// - **从没登记过**（回包与第一片增量同 tick）⇒ 暂存待重放（[_bufferStreamFrame]）；
  /// - **已经收尾**（done / error / 取消 / 心跳丢失）⇒ 迟到增量只能丢弃，并**当场**
  ///   记一条可读日志（否则插件以为还在推，核心却毫无反馈）。
  final Set<String> _closedStreamIds = <String>{};

  /// 收尾流 id 的记忆条数上限（只为区分上面两种情形，不需要长期保留）。
  static const int maxClosedStreamIds = 64;

  /// 打开中的插件流数量（快照 / 测试用）。
  int get openLlmStreams => _llmStreams.length;

  /// **中转站点位「LLM 处理」**（`system.relay.llm.handle`）。
  ///
  /// 返回非 null = 这一跳交给插件（[LlmSession] 消费这条流、**不再调 LLM**）；
  /// 返回 null = 不接管（无订阅者 / 未回填 / 回包认不出 / 任何异常）。
  ///
  /// 三种接管形态（`reply.payload`）：
  /// - `{stream: true}` ⇒ **流式接管**：返回的流由后续 `station/stream` 通知喂数据，
  ///   `done` / `error` 收尾；用户 stop 时向插件下发 `station/cancel`；
  /// - OpenAI 兼容响应 / 裸 message（`{content, reasoning_content, tool_calls}`）
  ///   ⇒ 一次性接管，展开成与流式同一套事件；
  /// - 数组 ⇒ 每项按 SSE 分片或非流式响应解码（分片数组）。
  Future<Stream<LlmStreamEvent>?> relayLlmHandle({
    required LlmRequest request,
    required String agentId,
    required String sessionId,
    required int turn,
    required bool Function() isCancelled,
  }) async {
    load();
    if (!enabled) return null;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return null;
    final RelayStation? station = stations.relayPointFor(
      StationHubIds.relayLlmHandle,
    );
    if (station == null) return null;
    if (station.subscribers.isEmpty) return null; // 快路径：没人订阅，零等待
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'agent_id': agentId,
      'session_id': sessionId,
      'turn': turn,
      'request': request.toWire(stream: true),
    };
    try {
      final StationRelayResult relayed = await station.relay(
        data: payload,
        scope: scope,
        meta: <String, dynamic>{'purpose': 'llm.handle', 'turn': turn},
      );
      if (!relayed.handled) {
        if (relayed.reason.isNotEmpty) {
          log?.call('LLM 处理中转未接管（第 $turn 跳）：${relayed.reason}');
        }
        return null;
      }
      final Object? data = relayed.data;
      if (data == null) return null; // 订阅者选择不改动 = 不接管
      if (data is Map && data['stream'] == true) {
        return _openPluginLlmStream(
          station: station,
          requestId: relayed.requestId,
          pluginId: relayed.pluginId,
          scope: scope,
          isCancelled: isCancelled,
          turn: turn,
        );
      }
      final List<LlmStreamEvent> events = _decodeLlmReply(data);
      if (events.isEmpty) {
        log?.call(
          'LLM 处理中转回包认不出（第 $turn 跳）：${data.runtimeType}'
          '——按未接管处理，走系统 LLM',
        );
        return null;
      }
      log?.call('LLM 处理中转：插件 ${relayed.pluginId} 一次性接管第 $turn 跳');
      return Stream<LlmStreamEvent>.fromIterable(events);
    } catch (error) {
      log?.call('LLM 处理中转异常（第 $turn 跳，已回退系统 LLM）：$error');
      return null;
    }
  }

  /// 把插件的接管回包解码成流式事件（一次性接管 / 分片数组两种形态）。
  static List<LlmStreamEvent> _decodeLlmReply(Object? data) {
    final List<LlmStreamEvent> events = <LlmStreamEvent>[];
    if (data is Map) {
      final Map<String, dynamic> map = data.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
      events.addAll(OpenAiCodec.decodeMessage(map));
      if (events.isEmpty) {
        // 也可能是 SSE 分片形态（`choices[0].delta`）
        events.addAll(OpenAiCodec.decodeChunk(jsonEncode(map)));
      }
      return events;
    }
    if (data is List) {
      for (final Object? item in data) {
        if (item is String) {
          events.addAll(OpenAiCodec.decodeChunk(item));
          continue;
        }
        if (item is Map) {
          final Map<String, dynamic> map = item.map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          );
          final List<LlmStreamEvent> one = OpenAiCodec.decodeMessage(map);
          if (one.isNotEmpty) {
            events.addAll(one);
          } else {
            events.addAll(OpenAiCodec.decodeChunk(jsonEncode(map)));
          }
          continue;
        }
        // 认不出的元素：整条回包作废（宁可走系统 LLM，也不吐半成品）
        return const <LlmStreamEvent>[];
      }
      return events;
    }
    if (data is String) return OpenAiCodec.decodeChunk(data);
    return const <LlmStreamEvent>[];
  }

  /// 打开一条**流式接管**（插件推 `station/stream`、核心边收边吐）。
  ///
  /// 三条收尾路径（缺一不可，否则会话会一直等下去）：
  /// 1. 插件 `done` / `error` ⇒ 正常收尾；
  /// 2. 用户取消（[isCancelled] 变真）⇒ 下发 `station/cancel` + 以"已取消"收尾；
  /// 3. 插件心跳丢失 / 进程退出 ⇒ 以失败收尾（与站点判活同一口径，不设静态总超时）。
  Stream<LlmStreamEvent> _openPluginLlmStream({
    required RelayStation station,
    required String requestId,
    required String pluginId,
    required StationScope scope,
    required bool Function() isCancelled,
    required int turn,
  }) {
    final StreamController<LlmStreamEvent> controller =
        StreamController<LlmStreamEvent>();
    final _PluginLlmStream stream = _PluginLlmStream(
      requestId: requestId,
      pluginId: pluginId,
      station: station,
      controller: controller,
    );
    // 同一 request_id 收到第二条 stream:true（插件重复回包 / 陈旧回包）：
    // 让旧的以失败收尾，避免"两条流抢同一个 id"。
    _llmStreams.remove(requestId)?.fail('同一 request_id 的新流已打开（旧流作废）');
    _llmStreams[requestId] = stream;
    log?.call('LLM 处理中转：插件 $pluginId 流式接管第 $turn 跳（$requestId）');
    // **回包与第一片增量常常同 tick 到达**：早到的那几片在这里按原身份重放，
    // 免得"插件推得比核心登记流更快"变成静默丢数据（示例插件原先只能靠节流苟住）。
    _replayStreamFrames(requestId);
    // 收尾守护：既不设静态总超时（长任务不该被时间杀），也不放任无限等——
    // 每拍检查取消信号与订阅者心跳（与站点 awaitReply 的判活口径一致）。
    stream.timer = Timer.periodic(const Duration(milliseconds: 250), (
      Timer timer,
    ) {
      if (stream.finished) {
        timer.cancel();
        return;
      }
      if (isCancelled()) {
        _closeLlmStream(
          requestId,
          cancelReason: '用户已停止本轮生成',
          failure: '生成已取消（插件接管流被中断）',
          cancelled: true,
        );
        return;
      }
      final StationLivenessState state = station.liveness(pluginId);
      if (state.known && !state.alive) {
        _closeLlmStream(
          requestId,
          failure:
              '插件 $pluginId 心跳丢失（${state.detail.isEmpty ? '连续未达' : state.detail}），'
              'LLM 接管流中断',
        );
        return;
      }
    });
    controller.onCancel = () {
      // 消费方提前放弃（会话被取消 / 出错退出）：通知插件别再推了
      _cancelLlmStream(requestId, '核心已放弃这条流');
    };
    return controller.stream;
  }

  /// 收尾一条插件流（幂等）。
  ///
  /// [cancelReason] 非空时先向插件下发 `station/cancel`（下行通知）；
  /// [failure] 非空时以 [LlmFailureEvent] 收尾，否则正常 `close`。
  void _closeLlmStream(
    String requestId, {
    String cancelReason = '',
    String failure = '',
    bool cancelled = false,
  }) {
    final _PluginLlmStream? stream = _llmStreams.remove(requestId);
    if (stream != null) {
      _closedStreamIds.add(requestId);
      while (_closedStreamIds.length > maxClosedStreamIds) {
        _closedStreamIds.remove(_closedStreamIds.first);
      }
    }
    // 这条流已经收尾：为它暂存的早到帧不会再有机会重放，直接清掉（并记线索）
    _dropPendingStreamFrames(requestId: requestId);
    if (stream == null) return;
    if (cancelReason.isNotEmpty) {
      _hosts[stream.pluginId]?.cancelStation(
        requestId: requestId,
        reason: cancelReason,
      );
    }
    stream.finish(failure: failure, cancelled: cancelled);
  }

  /// 向插件下发取消（流继续等待它收尾，但不再接受已到达的增量之前的数据？
  /// 不——**取消后到达的增量一律丢弃**，见 [_handleStationStream]）。
  void _cancelLlmStream(String requestId, String reason) {
    final _PluginLlmStream? stream = _llmStreams[requestId];
    if (stream == null || stream.cancelled) return;
    stream.cancelled = true;
    _hosts[stream.pluginId]?.cancelStation(
      requestId: requestId,
      reason: reason,
    );
    _closeLlmStream(requestId, failure: '生成已取消（插件接管流被中断）', cancelled: true);
  }

  /// **插件 → 核心：`station/stream` 通知**（流式回填的数据面）。
  ///
  /// 形态：`{request_id, delta: {kind: text|thinking|tool_call, …}}` 推增量；
  /// `{request_id, done: true, finish_reason?, usage?}` 收尾；
  /// `{request_id, error: {message}}` 出错收尾。
  ///
  /// 未知 / 已收尾的 `request_id`：丢弃并记可读日志（不报错、不影响该轮生成）。
  void _handleStationStream(String pluginId, Map<String, dynamic> params) {
    final String requestId = (params['request_id'] ?? '').toString().trim();
    if (requestId.isEmpty) {
      log?.call('插件 $pluginId 的 station/stream 缺少 request_id，已丢弃');
      return;
    }
    final _PluginLlmStream? stream = _llmStreams[requestId];
    if (stream == null) {
      if (_closedStreamIds.contains(requestId)) {
        // 这条流已经收尾（done / error / 取消 / 心跳丢失）：迟到增量只能丢弃。
        // **当场记日志**——插件以为还在推，核心必须给出反馈，否则是静默数据丢失。
        log?.call('插件 $pluginId 的 station/stream 迟到（$requestId 已收尾），本条增量已丢弃');
        return;
      }
      // 从没登记过：可能是"回包还没被处理完、插件已经推了第一片"——暂存等重放。
      _bufferStreamFrame(pluginId, requestId, params);
      return;
    }
    if (stream.pluginId != pluginId) {
      // 归属校验：只有打开这条流的插件能往里推（点位的唯一订阅者）
      log?.call('插件 $pluginId 试图写入 $requestId 的流（属于 ${stream.pluginId}），已拒绝');
      return;
    }
    if (stream.cancelled || stream.finished) return; // 取消 / 收尾后到达的增量一律丢弃
    final Object? rawError = params['error'];
    if (rawError != null) {
      final String message = rawError is Map
          ? (rawError['message'] ?? rawError['type'] ?? '插件流报错').toString()
          : rawError.toString();
      _closeLlmStream(requestId, failure: '插件接管流出错：$message');
      return;
    }
    if (params['done'] == true) {
      final Object? usage = params['usage'];
      if (usage is Map) {
        final LlmUsage parsed = OpenAiCodec.decodeUsage(usage);
        if (!parsed.isEmpty) stream.add(LlmUsageEvent(parsed));
      }
      // 逐调用用量账本（`usage.jsonl`）**不在这里写**：这一跳的账由引擎落
      // （`LlmAgentEngine`），并因为"会话知道这一跳被插件接管"而归到 `source=plugin`
      // ——插件回包带 usage 就用这份真值、不带就在会话里本地估算（标 `estimated`）。
      // 总线在这里**唯一**要做的就是上面那行"把 usage 交给流"，别在这里补一次落账
      // （那会与引擎那份重复记一行）。见 store/usage_log.dart 的 `UsageSource`。
      final String finish = (params['finish_reason'] ?? '').toString();
      if (finish.isNotEmpty) stream.add(LlmFinishEvent(finish));
      _closeLlmStream(requestId);
      return;
    }
    final Object? rawDelta = params['delta'];
    if (rawDelta == null) {
      log?.call('插件 $pluginId 的 station/stream 既没有 delta 也没有 done/error，已丢弃');
      return;
    }
    final List<LlmStreamEvent> events = _decodeLlmDelta(rawDelta);
    if (events.isEmpty) {
      log?.call('插件 $pluginId 的 station/stream delta 认不出，已丢弃');
      return;
    }
    for (final LlmStreamEvent event in events) {
      stream.add(event);
    }
  }

  /// 解码一条 `delta`（两种写法都认）：
  /// - **紧凑写法**：`{kind: text|thinking|tool_call, text?, index?, id?, name?, arguments_delta?}`；
  /// - **OpenAI 分片**：`{choices:[{delta:{…}}]}`（插件直接转发自己拿到的分片）。
  static List<LlmStreamEvent> _decodeLlmDelta(Object? rawDelta) {
    if (rawDelta is String) return OpenAiCodec.decodeChunk(rawDelta);
    if (rawDelta is! Map) return const <LlmStreamEvent>[];
    final Map<String, dynamic> delta = rawDelta.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    if (delta.containsKey('choices')) {
      return OpenAiCodec.decodeChunk(jsonEncode(delta));
    }
    final String kind = (delta['kind'] ?? delta['type'] ?? '').toString();
    switch (kind) {
      case 'text':
        final String text = (delta['text'] ?? delta['content'] ?? '')
            .toString();
        return text.isEmpty
            ? const <LlmStreamEvent>[]
            : <LlmStreamEvent>[LlmTextDelta(text)];
      case 'thinking':
      case 'reasoning':
        final String text = (delta['text'] ?? delta['reasoning_content'] ?? '')
            .toString();
        return text.isEmpty
            ? const <LlmStreamEvent>[]
            : <LlmStreamEvent>[LlmThinkingDelta(text)];
      case 'tool_call':
        final Object? index = delta['index'];
        final String id = (delta['id'] ?? '').toString();
        final String name = (delta['name'] ?? '').toString();
        final String args =
            (delta['arguments_delta'] ?? delta['arguments'] ?? '').toString();
        if (id.isEmpty && name.isEmpty && args.isEmpty) {
          return const <LlmStreamEvent>[];
        }
        return <LlmStreamEvent>[
          LlmToolCallDelta(
            index: index is num ? index.toInt() : 0,
            id: id.isEmpty ? null : id,
            name: name.isEmpty ? null : name,
            argumentsDelta: args,
          ),
        ];
      default:
        // 认不出 kind 时按"整条 OpenAI 分片 / 非流式响应"再试一次
        final List<LlmStreamEvent> chunk = OpenAiCodec.decodeMessage(delta);
        return chunk.isEmpty
            ? OpenAiCodec.decodeChunk(jsonEncode(delta))
            : chunk;
    }
  }

  /// **中转站点位「投入 LLM 前」**（`system.relay.llm.request`）。
  ///
  /// 返回改写后的请求；null = 不改（无订阅者 / 未回填 / 回包重建失败）。**仅在未被
  /// 「LLM 处理」接管时调用**——不投 LLM 就没有"投入前"可言。
  Future<LlmRequest?> relayLlmRequest({
    required LlmRequest request,
    required String agentId,
    required String sessionId,
    required int turn,
  }) async {
    load();
    if (!enabled) return null;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return null;
    final RelayStation? station = stations.relayPointFor(
      StationHubIds.relayLlmRequest,
    );
    if (station == null) return null;
    if (station.subscribers.isEmpty) return null;
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'agent_id': agentId,
      'session_id': sessionId,
      'turn': turn,
      'request': request.toWire(stream: true),
    };
    try {
      final StationRelayResult relayed = await station.relay(
        data: payload,
        scope: scope,
        meta: <String, dynamic>{'purpose': 'llm.request', 'turn': turn},
      );
      if (!relayed.handled || relayed.data == null) return null;
      final Object? data = relayed.data;
      // 回填可以是整个报文，也可以是只给 request 字段
      final Object? rawRequest = data is Map && data.containsKey('request')
          ? data['request']
          : data;
      final LlmRequest? rewritten = LlmRequest.tryFromWire(rawRequest);
      if (rewritten == null) {
        log?.call('投入 LLM 前改写点回包无法重建请求（第 $turn 跳）：按原请求放行');
        return null;
      }
      log?.call('投入 LLM 前改写点：插件 ${relayed.pluginId} 改写了第 $turn 跳的请求');
      return rewritten;
    } catch (error) {
      log?.call('投入 LLM 前改写点异常（第 $turn 跳，已放行原请求）：$error');
      return null;
    }
  }

  /// **中转站点位「上下文压缩过程」**（`system.relay.context.compact`）。
  ///
  /// **规划也归中转站**（2026-10 定稿）：只要这个点位有订阅者，核心就**不算切点**
  /// （`buildPlan` 完全不跑），而是把整份原料交出去；插件产出**整份新上下文**并回传
  /// 它覆盖了多少条原文。没订阅者（或它这轮不接管）才走系统内置 compact。
  ///
  /// 返回 null = 插件没接管，回退内置 compact。
  Future<CompactionRelayReply?> relayCompaction({
    required CoreAgent agent,
    required CoreSession session,
    required String systemPrompt,
    required int totalMessageCount,
    required int compactedMessageCount,
    required String existingSummary,
    required Map<String, dynamic>? wireRequest,
  }) async {
    load();
    if (!enabled) {
      _reportCompactionSkip(
        agent,
        session,
        '插件总开关已关闭（plugins.yaml）',
        hasSubscriber: false,
      );
      return null;
    }
    final StationScope scope = runtimeScopeFor(
      agentId: agent.id,
      sessionId: session.sessionId,
    );
    if (!scope.isValid) {
      _reportCompactionSkip(
        agent,
        session,
        '该会话不在插件的运行范围内（挂载点不匹配）',
        hasSubscriber: false,
      );
      return null;
    }
    final RelayStation? station = stations.relayPointFor(
      StationHubIds.relayContextCompact,
    );
    if (station == null) {
      _reportCompactionSkip(
        agent,
        session,
        '核心未注册「上下文压缩过程」这个中转点位',
        hasSubscriber: false,
      );
      return null;
    }
    if (station.subscribers.isEmpty) {
      _reportCompactionSkip(
        agent,
        session,
        '没有插件订阅该点位（未声明 system.relay.context.compact）',
        hasSubscriber: false,
      );
      return null;
    }
    // 这份会话的用量账本：插件读不到数据根（它的 fs.read 只在工作空间作用域内），
    // 所以由核心把"最近 N 行"捎过去（只作展示/排障；**不参与压缩决策**）。
    // 未接线 / 读失败 / 异常 ⇒ null ⇒ payload 里干脆不带这两个键（fail-open）。
    final PluginUsageRecent? recentUsage = await _recentUsageFor(
      agent.id,
      session.sessionId,
    );
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'agent_id': agent.id,
      'session_id': session.sessionId,
      // 系统提示词：放在你的列表**首条 system**（提示词槽位）里；核心每轮会用最新
      // 的那份覆盖它，所以这里给的是"压缩那一刻的快照"。
      'system_prompt': systemPrompt,
      // 原文条数（`covered_message_count` 的合法上界）。
      // **载荷不给落库全量原文**：那份既大又与真实上下文不同步（冷前缀已被压缩产物
      // 代表）；你要的原料是下面的 `request.messages`。
      'total_message_count': totalMessageCount,
      // 引擎此刻从原文第几条继续（这份新上下文要覆盖到哪，由回包决定）
      'compacted_message_count': compactedMessageCount,
      'existing_summary': existingSummary,
      'compacted': session.compacted,
      // **预先压缩态的线形请求**（引擎口径）：`{model, messages, tools, …}`，即
      // "对话这一轮真会发的那份"。它同时是压缩的**唯一原料**与**缓存前缀**：
      // 整份拿去当 `llm.call` 的 messages（末尾追加一条总结指令）即可命中端点前缀
      // 缓存；要保留的尾部也从它的 messages 里原样截取。
      'request': ?wireRequest,
      // 用量账本（`<会话目录>/usage.jsonl`）：路径只作排障，内容供面板展示
      // （这一轮花了多少 token / 内置兜底那次花了多少）。可选键，缺了照样工作。
      if (recentUsage != null) 'usage_file': recentUsage.path,
      if (recentUsage != null) 'recent_usage': recentUsage.calls,
    };
    try {
      final StationRelayResult relayed = await station.relay(
        data: payload,
        scope: scope,
        meta: <String, dynamic>{'purpose': 'context.compact'},
      );
      if (!relayed.handled || relayed.data == null) {
        _reportCompactionSkip(
          agent,
          session,
          '插件没有回包（未接管这次压缩）',
          hasSubscriber: true,
        );
        return null;
      }
      final Object? data = relayed.data;
      // 回包 `payload: null` = **不改动**：站点会把**原请求数据**原样放行
      // （见 StationInstance.relay 的 None 分支）。这里必须用同一性判掉它——
      // 不判就有可能把"插件没接管"误读成"插件回了一份新上下文"。
      if (identical(data, payload)) {
        // **原因优先用插件自己报的**（回包可选键 `reason`，纯增量）：只写"回 null"
        // 会把最难查的那类故障（插件白跑一次、核心悄悄兜底）变成事后黑洞——
        // 现场那次 734k prompt 的总结调用因正文非法 JSON 被弃，日志与会话提示
        // 都只剩"回 null"（见 docs/known-issues.md #31）。
        final String why = relayed.reason.trim();
        log?.call(
          '压缩中转：插件未接管（回 null），回退内置 compact'
          '${why.isEmpty ? '' : '；原因：$why'}',
        );
        _reportCompactionSkip(
          agent,
          session,
          why.isEmpty
              ? '插件回 null（原数据放行 = 不改动，未接管）'
              : '插件回 null（原数据放行 = 不改动）：$why',
          hasSubscriber: true,
        );
        return null;
      }
      if (data is! Map) {
        log?.call(
          '压缩中转回包不是对象（回 ${data.runtimeType}）：按未接管处理，回退内置 compact。'
          '回包形状应为 {"messages": [...], "covered_message_count": N}',
        );
        _reportCompactionSkip(
          agent,
          session,
          '插件回包不是对象（回 ${data.runtimeType}），无法当上下文用',
          hasSubscriber: true,
        );
        return null;
      }
      final Object? rawMessages = data['messages'];
      if (rawMessages is! List || rawMessages.isEmpty) {
        log?.call('压缩中转回包的 messages 不是非空数组：按未接管处理，回退内置 compact');
        _reportCompactionSkip(
          agent,
          session,
          '插件回包的 messages 不是非空数组',
          hasSubscriber: true,
        );
        return null;
      }
      final List<Map<String, dynamic>> context = <Map<String, dynamic>>[];
      for (int i = 0; i < rawMessages.length; i++) {
        final Object? item = rawMessages[i];
        if (LlmMessage.tryFromWire(item) == null) {
          log?.call(
            '压缩中转回包第 $i 条消息无法还原成 LLM 消息（角色/字段不合法）：'
            '整包按未接管处理，回退内置 compact',
          );
          _reportCompactionSkip(
            agent,
            session,
            '插件回包第 $i 条消息角色/字段不合法（无法还原成 LLM 消息）',
            hasSubscriber: true,
          );
          return null;
        }
        context.add(
          (item as Map).map(
            (dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
      }
      final Object? rawCovered = data['covered_message_count'];
      final int? covered = rawCovered is num ? rawCovered.toInt() : null;
      if (covered == null || covered < 0 || covered > totalMessageCount) {
        // 水位线是"下一轮从哪继续"的唯一依据：缺失/越界一律回退，绝不猜一个值
        log?.call(
          '压缩中转回包的 covered_message_count=${rawCovered ?? '缺失'} 非法'
          '（合法区间 0..$totalMessageCount）：按未接管处理，回退内置 compact',
        );
        _reportCompactionSkip(
          agent,
          session,
          '插件回包的 covered_message_count=${rawCovered ?? '缺失'} 非法'
          '（须在 0..$totalMessageCount 内）',
          hasSubscriber: true,
        );
        return null;
      }
      log?.call(
        '压缩中转：插件 ${relayed.pluginId} 接管了这次压缩'
        '（回 ${context.length} 条上下文，覆盖 $covered 条原文）',
      );
      return CompactionRelayReply(
        messages: context,
        coveredMessageCount: covered,
      );
    } catch (error) {
      log?.call('压缩中转异常（回退内置 compact）：$error');
      _reportCompactionSkip(
        agent,
        session,
        '压缩中转点异常（插件侧报错）：$error',
        hasSubscriber: true,
      );
      return null;
    }
  }

  /// 上报"压缩中转点为什么没接管"（每处"不接管"分支各一次，文案与同处的 `log` 同源）。
  ///
  /// 出口是 [compactionSkipSink]（接线方接到 `CompactionService.noteRelaySkip`）；
  /// [hasSubscriber] 见字段说明（决定该不该写进会话历史）。
  /// 未接线时它什么都不做——**不改任何行为**（fail-open 与接线前逐字一致）。
  void _reportCompactionSkip(
    CoreAgent agent,
    CoreSession session,
    String reason, {
    required bool hasSubscriber,
  }) {
    compactionSkipSink?.call(
      agent.id,
      session.sessionId,
      reason,
      hasSubscriber: hasSubscriber,
    );
    // 阶段 6：把这句原因投给 `compact.skip.reason`（让插件写得更准）。
    // **早退不投**（hasSubscriber=false 时根本没插件在路上）；fire-and-forget，
    // 不卡压缩本身（内置那句已经落账了）。
    relayCompactSkipReason(
      agentId: agent.id,
      sessionId: session.sessionId,
      reason: reason,
      hasSubscriber: hasSubscriber,
    );
  }

  /// 取该会话的**最近用量行**（[usageRecentProvider] 的包装）。
  ///
  /// 三条口径，缺一不可：
  /// - **未接线 ⇒ null**（payload 里不带 `recent_usage`，"没有这条通路"与"没有用量"
  ///   是两件事，插件据此区分"暂不支持"与"确实还没调用过"）；
  /// - **条数上限** [maxRecentUsageLines]：账本随会话一直长，压缩载荷必须是有界的
  ///   （取**最后** N 行 = 最近的那些）；
  /// - **异常/读失败 ⇒ null + 一句日志**：用量是遥测，绝不影响这次压缩（fail-open）。
  Future<PluginUsageRecent?> _recentUsageFor(
    String agentId,
    String sessionId,
  ) async {
    final PluginUsageRecentProvider? provider = usageRecentProvider;
    if (provider == null) return null;
    try {
      final PluginUsageRecent? recent = await provider(agentId, sessionId);
      if (recent == null) return null;
      final List<Map<String, dynamic>> calls = recent.calls;
      if (calls.length <= maxRecentUsageLines) return recent;
      return PluginUsageRecent(
        path: recent.path,
        calls: calls.sublist(calls.length - maxRecentUsageLines),
      );
    } catch (error) {
      log?.call('读取最近用量行失败（本次压缩照常，只是不带用量）：$error');
      return null;
    }
  }

  /// **中转站点位「系统提示词构造过程」**（`system.relay.prompt.system`）。
  ///
  /// 返回最终 system prompt；null = 不改（用内置构造结果）。空串 = 明确要求不带
  /// 系统提示词（与"不改"区分开，见 `LlmAgentEngine._relayedSystemPrompt`）。
  Future<String?> relaySystemPrompt({
    required AgentRunContext context,
    required String defaultPrompt,
  }) async {
    load();
    if (!enabled) return null;
    final StationScope scope = runtimeScopeFor(
      agentId: context.agentId,
      sessionId: context.sessionId,
    );
    if (!scope.isValid) return null;
    final RelayStation? station = stations.relayPointFor(
      StationHubIds.relayPromptSystem,
    );
    if (station == null) return null;
    if (station.subscribers.isEmpty) return null;
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'agent_id': context.agentId,
      'session_id': context.sessionId,
      'default': defaultPrompt,
    };
    try {
      final StationRelayResult relayed = await station.relay(
        data: payload,
        scope: scope,
        meta: <String, dynamic>{'purpose': 'prompt.system'},
      );
      if (!relayed.handled || relayed.data == null) return null;
      final Object? data = relayed.data;
      final Object? rawPrompt = data is Map
          ? (data['system_prompt'] ?? data['prompt'] ?? data['text'])
          : data;
      if (rawPrompt == null) return null;
      log?.call('系统提示词中转：插件 ${relayed.pluginId} 改写了本轮系统提示词');
      return rawPrompt.toString();
    } catch (error) {
      log?.call('系统提示词中转异常（已用内置构造结果）：$error');
      return null;
    }
  }

  /// **中转站点位「SSH 执行」**（`system.relay.ssh.execute`，2026-10-15 新增）。
  ///
  /// 定位：中转站不再只接「数据拦截-回填」，而是「**处理拓展点位**」——核心把一次
  /// 工作交给点位、订阅者处理并回填，就是同一套语义。SSH 因此与 LLM 接管 / 工具改写
  /// 共用中转站的 fail-open / scope / 唯一订阅者 / 无静态超时 四条不变量。
  ///
  /// 无订阅者 / 插件未接管 / 回包非法 ⇒ 返回 null，调用方（核心的 SSH 选路）回退
  /// 内置 `dartssh2`；插件回包为 `Map` 时原样透传。任何异常只写日志、不冒泡。
  ///
  /// [action]：这次 SSH 操作的语义名（`ensure` / `request` / `state` / `reconnect` /
  /// `close` / `shell.open` / `shell.close` …），与既有 `TunnelMethods.*` 同名同形状，
  /// 方便插件内部直接分发到 `TunnelManager`；新体系下它们不再是顶层 JSON-RPC method，
  /// 而统一以 `station/request` 投递。
  /// [payload]：随 action 携带的参数（SSH 配置、conn_id、目标机 JSON-RPC 的 method/params 等）。
  /// [agentId]、[sessionId]：站点隔离四元组的两个必选字段，mode_key 固定为 `ssh`（这个
  /// 点位只在 SSH 工作空间上触发）。若调用方无法提供（无会话背景的早期接线），
  /// 传空串 ⇒ 站点隔离不成立 ⇒ fail-open 回退内置（与既有口径一致）。
  Future<Map<String, dynamic>?> relaySshExecute({
    required String action,
    required String agentId,
    required String sessionId,
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) async {
    load();
    if (!enabled) return null;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return null;
    final RelayStation? station = stations.relayPointFor(
      StationHubIds.relaySshExecute,
    );
    if (station == null) {
      log?.call(
        'SSH 中转（action=$action）：点位 ${StationHubIds.relaySshExecute} 不可用'
        '（未接线 / 类型不符），按未接线回退内置',
      );
      return null;
    }
    if (station.subscribers.isEmpty) return null; // 快路径：零等待回退
    final Map<String, dynamic> wire = <String, dynamic>{
      'point': station.id,
      'action': action,
      ...payload,
    };
    try {
      final StationRelayResult relayed = await station.relay(
        data: wire,
        scope: scope,
        meta: <String, dynamic>{'purpose': 'ssh.execute', 'action': action},
      );
      if (!relayed.handled) {
        if (relayed.reason.isNotEmpty) {
          log?.call('SSH 中转（action=$action）未处理：${relayed.reason}');
        }
        return null;
      }
      final Object? data = relayed.data;
      if (data is! Map) {
        log?.call(
          'SSH 中转（action=$action）：回包类型 ${data.runtimeType} 不是对象，'
          '按未接管处理⇒回退内置',
        );
        return null;
      }
      return data.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    } catch (error) {
      log?.call('SSH 中转（action=$action）异常（已回退内置）：$error');
      return null;
    }
  }

  /// 中转站点位「SSH 执行」当前是否有订阅者（核心选路时用它判断“能不能走站点”）。
  ///
  /// 与既有 [sshExecutorLookup]（按能力 + 进程在跑）两条信号 **OR**：
  /// - 旧插件（只报 capability、不订阅）⇒ [sshExecutorLookup] 命中，新路径自动回退到
  ///   `tunnel.*` 方法，行为与今天一致；
  /// - 新插件（订了站点，无论是否报 capability）⇒ 本方法命中，核心可走站点投递；
  /// - 两者都命中 ⇒ 优先走站点（新路径为权威）。
  ///
  /// 插件无能力不订站点⇒ 两者都不命中⇒ 内置 dartssh2。热切换时插件重启与订阅
  /// 自动同步注销（既有基础设施），不需额外机制。
  bool sshExecuteStationSubscribed() {
    load();
    if (!enabled) return false;
    final RelayStation? station = stations.relayPointFor(
      StationHubIds.relaySshExecute,
    );
    return station != null && station.subscribers.isNotEmpty;
  }

  /// 同 [sshExecuteStationSubscribed]，但给「插件刚上线、订阅帧还在路上」留一个**有界**窗口。
  ///
  /// 为什么需要：capability 是在 `hello` 回包里解析的，而新插件的 `station/subscribe`
  /// 是回完 hello **之后**才发出的（`plugin_loop.dart` 的 `unawaited(_subscribeSshExecute())`）——
  /// 于是 [sshExecutorLookup] 命中与站点订上之间有几毫秒的竞态。选路时先订上没订上
  /// 决定走站点还是走旧 `tunnel.*`，因此需要这个小窗口跨越它。
  ///
  /// **已订上立即返回 true（不等待）**；只有「当前未订」才每 [interval] 探一次、至多 [timeout]。
  /// 旧插件（只报能力、永不订阅）因此每次最多付一个 [timeout]，而非永久等待
  /// （超时后如实返回 false 走旧路径，行为不回归）。
  Future<bool> sshExecuteStationSubscribedWithin({
    Duration timeout = const Duration(milliseconds: 400),
    Duration interval = const Duration(milliseconds: 100),
  }) async {
    if (sshExecuteStationSubscribed()) return true;
    if (timeout <= Duration.zero) return false;
    final Stopwatch elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      await Future<void>.delayed(interval);
      if (sshExecuteStationSubscribed()) return true;
    }
    return sshExecuteStationSubscribed();
  }

  // ── 广播站点位：工具调用（单向通知，**不等回包**） ──────────────────────

  /// 每次工具调用前 / 后各广播一条（点位 `system.broadcast.tool.pre|post`）。
  ///
  /// **不等回包**：工具调用在热路径上，`publish()` 会对每个订阅者 `awaitReply`
  /// 再 `Future.wait`——真 await 就等于让每个广播订阅者的响应速度拖慢每次工具调用。
  /// 因此这里 `unawaited`：广播 = 单向通知，公告板照写、计数照记，投递结果不回灌。
  ///
  /// [origin] = `agent`（模型发起的调用）或 `plugin`（插件经执行站发起的调用）；
  /// 插件自己的调用默认**不广播**（由 `tool.call` 的 `relay: false` 决定），
  /// 要审计就显式打开。
  void announceToolCall({
    required String phase,
    required String tool,
    required String callId,
    required int round,
    required String agentId,
    required String sessionId,
    Map<String, dynamic>? arguments,
    String result = '',
    bool isError = false,
    String origin = 'agent',
    String sourcePluginId = '',
  }) {
    load();
    if (!enabled) return;
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return;
    final bool isPost = phase == 'post';
    final BroadcastStation? station = stations.broadcastPointFor(
      isPost ? StationHubIds.broadcastToolPost : StationHubIds.broadcastToolPre,
    );
    if (station == null) return;
    if (station.subscribers.isEmpty) return; // 快路径：没人订阅，零开销
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      'phase': phase,
      'origin': origin,
      if (sourcePluginId.isNotEmpty) 'source_plugin_id': sourcePluginId,
      'tool': tool,
      'call_id': callId,
      'round': round,
      'agent_id': agentId,
      'session_id': sessionId,
      'arguments': ?arguments,
      if (isPost) 'result': result,
      if (isPost) 'is_error': isError,
    };
    // 单向通知：不 await、失败只记日志（工具调用不受广播影响）
    unawaited(
      station
          .publish(
            topic: 'tool.$phase',
            scope: scope,
            payload: payload,
            meta: <String, dynamic>{'origin': origin, 'tool': tool},
            sourcePluginId: sourcePluginId,
          )
          .then((StationPublishResult result) {
            if (result.deliveries.any((StationDelivery d) => !d.ok)) {
              log?.call('工具广播 ${result.describe()}');
            }
          })
          .catchError((Object error) {
            log?.call('工具广播异常（已忽略，不影响工具调用）：$error');
          }),
    );
  }

  /// **广播站点位「工具运行超时」**（`system.tool.timeout`，M9 点位化新增）。
  ///
  /// 由 `ToolRunRegistry` 在**一次运行跨过阈值时**调用（warning 与广播共用同一个
  /// "每次运行只发一次"闸门，见 `ToolRunRegistry._warnIfNeeded`）。
  ///
  /// [run] = 登记表给的载荷（冻结键：`handle` / `agent_id` / `session_id` / `tool` /
  /// `command` / `elapsed_ms` / `started_at`）；这里只补 `point`（与其它广播载荷同口径）。
  /// 订阅方式与既有 `system.*` 点位一致：`{station: 'broadcast', point: 'tool.timeout'}`
  /// （别名见 `StationPoints.broadcasts`）。
  ///
  /// 与 [announceToolCall] 同口径：**单向通知**（`unawaited`，不等回包、失败只记日志）。
  void announceToolTimeout(Map<String, dynamic> run) {
    load();
    if (!enabled) return;
    final String agentId = (run['agent_id'] ?? '').toString();
    final String sessionId = (run['session_id'] ?? '').toString();
    final StationScope scope = runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (!scope.isValid) return;
    final BroadcastStation? station = stations.broadcastPointFor(
      StationHubIds.broadcastToolTimeout,
    );
    if (station == null) return;
    if (station.subscribers.isEmpty) return; // 快路径：没人订阅，零开销
    final Map<String, dynamic> payload = <String, dynamic>{
      'point': station.id,
      ...run,
    };
    // 单向通知：不 await、失败只记日志（工具运行的超时判定不受广播影响）
    unawaited(
      station
          .publish(
            topic: 'tool.timeout',
            scope: scope,
            payload: payload,
            meta: <String, dynamic>{
              'tool': (run['tool'] ?? '').toString(),
              'handle': (run['handle'] ?? '').toString(),
            },
          )
          .then((StationPublishResult result) {
            if (result.deliveries.any((StationDelivery d) => !d.ok)) {
              log?.call('工具超时广播 ${result.describe()}');
            }
          })
          .catchError((Object error) {
            log?.call('工具超时广播异常（已忽略）：$error');
          }),
    );
  }

  /// 浅比较两个报文（回填 = 整体替换，键集与值都相同才算"未改动"）。
  static bool _sameMap(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, dynamic> e in a.entries) {
      if (!b.containsKey(e.key)) return false;
      if (!_sameValue(e.value, b[e.key])) return false;
    }
    return true;
  }

  static bool _sameValue(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return _sameMap(
        a.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        b.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      );
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (!_sameValue(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  // ── 插件 → 核心的请求通道（M9 §3「插件主动下命令」） ────────────────────

  /// 插件主动发起的请求（JSON-RPC `method` + `id`）的总入口（宿主
  /// [PluginHost.onPluginRequest] 的接线实现）。
  ///
  /// 实现执行站的 `station/command`、站点订阅 `station/subscribe` /
  /// `station/unsubscribe`，**插件自建站**的 `station/register` / `station/unregister`，
  /// 以及跨插件调用自建站的 `station/trigger`；未知 method ⇒ `-32601`（不静默）。
  /// 失败一律抛 [PluginRequestException]，由宿主变成 `{jsonrpc, id, error}` 响应。
  Future<Map<String, dynamic>> _handlePluginRequest(
    PluginConfig config,
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case PluginRpcMethods.stationCommand:
        return _handleStationCommand(config, params);
      case PluginRpcMethods.stationRegister:
        return _handleStationRegister(config, params);
      case PluginRpcMethods.stationUnregister:
        return _handleStationUnregister(config, params);
      case PluginRpcMethods.stationSubscribe:
        return _handleStationSubscribe(config, params);
      case PluginRpcMethods.stationUnsubscribe:
        return _handleStationUnsubscribe(config, params);
      case PluginRpcMethods.stationTrigger:
        return _handleStationTrigger(config, params);
      default:
        throw PluginRequestException(
          PluginRpcErrorCode.methodNotFound,
          'method not found: $method',
        );
    }
  }

  /// **插件自建站点（插件 → 核心）**：参数
  /// `{kind, name, readme, description?, schema?, max_subscriptions?, shared?, allowed_plugins?, config?}`。
  ///
  /// 为什么需要它（用户定稿语义）：站点全局化后，**每个点位只有一个订阅者**，
  /// 插件要按 team / agent 分开处理时，正解是"由一个转发型订阅者接管，再在插件内
  /// 建站点分发"——而"建站点"必须走核心，否则下游没有回包通道与等待链。
  ///
  /// 归属与安全：
  /// - **站点 id 由核心拼**（`plugin.{plugin_id}.{kind}.{name}`），插件**不能**自选 id
  ///   ——这正是"我的站点只能是我的"的强制点（[StationHub.checkSelfBuiltId] 是同一
  ///   口径的第二道校验）；
  /// - 只能建**既有四种类型**（不允许发明新类型）；
  /// - 执行站不可订阅，建它没有意义 ⇒ 拒绝（可读原因）；
  /// - 收集站**必须**带非空 schema（输入格式由站点定义）；
  /// - **`readme` 必填**（用户定稿）：站是插件建的，"它是干什么的、什么时候被触发、
  ///   订阅者该怎么回"必须由建站的插件写清楚——面板的站点详情页直接展示它，
  ///   共享站点时它是别人唯一能读到的说明书；
  /// - `shared` = true 时，**其它插件**可以按 `station/subscribe` / `station/trigger`
  ///   用它（`allowed_plugins` 非空 = 只开放给列出的插件）；默认 false = 只有所有者能用；
  /// - 同名重复注册 = 幂等返回既有站点（不报错、不覆盖，**也不改写 readme**）。
  ///
  /// 回包形状与 `station/command` 同风格：`{ok, station_id, kind, error}` ——
  /// 业务规则拒绝（类型非法 / 缺 schema / id 被占）是**结果**而非 JSON-RPC 错误。
  Future<Map<String, dynamic>> _handleStationRegister(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    final String kindRaw = (params['kind'] ?? '').toString().trim();
    final StationKind? kind = StationKind.fromWire(kindRaw);
    if (kind == null) {
      throw PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/register 需要 kind ∈ '
        '${StationKind.values.map((StationKind k) => k.wire).join(' | ')}'
        '（收到「$kindRaw」）',
      );
    }
    // 执行站不能自建（没有消费方），所以只有非执行站才拼 id
    String stationId = '';
    if (kind != StationKind.execute) {
      final String name = (params['name'] ?? '').toString().trim();
      final String? nameError = _checkSelfBuiltName(name);
      if (nameError != null) {
        return <String, dynamic>{
          'ok': false,
          'station_id': '',
          'kind': kind.wire,
          'error': nameError,
        };
      }
      stationId = selfBuiltStationId(config.id, kind, name);
    }
    // 幂等：同名重复注册拿到既有站点（插件重启后会再注册一遍）
    final StationInstance? existing = stationId.isEmpty
        ? null
        : stations.station(stationId);
    if (existing != null) {
      return <String, dynamic>{
        'ok': true,
        'station_id': existing.id,
        'kind': existing.kind.wire,
        'error': '',
      };
    }
    // 执行站不支持订阅，建它没有任何消费方（插件自己下发命令走内置执行站）
    if (kind == StationKind.execute) {
      return <String, dynamic>{
        'ok': false,
        'station_id': '',
        'kind': kind.wire,
        'error':
            '执行站不支持订阅（它由插件主动下命令），无需自建；'
            '要下命令请用 station/command',
      };
    }
    final Object? rawSchema = params['schema'];
    final StationSchema schema = StationSchema.fromJson(rawSchema);
    if (kind == StationKind.collect && schema.fields.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'station_id': '',
        'kind': kind.wire,
        'error': '收集站必须定义 schema（输入格式：fields 非空），当前为空',
      };
    }
    final int maxSubscriptions = _selfBuiltMaxSubscriptions(
      params['max_subscriptions'],
      kind,
    );
    // **readme 必填**（用户定稿：每一个插件内置站点都必须有介绍）。
    // 放在幂等分支之后：重启时的重复注册只拿回既有站点，不该因为这次没带介绍而失败。
    final String readme = (params['readme'] ?? '').toString().trim();
    if (readme.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'station_id': '',
        'kind': kind.wire,
        'error':
            'station/register 需要 readme（站点介绍，必填）：这个站干什么、'
            '什么时候被触发、订阅者该怎么回。内置站点的介绍来自核心的点位表。',
      };
    }
    final bool shared = params['shared'] == true;
    final List<String> allowedPlugins = _selfBuiltAllowedPlugins(
      params['allowed_plugins'],
    );
    final Map<String, dynamic> stationConfig = _selfBuiltConfig(
      params['config'],
    );
    final String description = (params['description'] ?? '').toString().trim();
    final String id = stationId;
    final StationInstance station = switch (kind) {
      StationKind.broadcast => BroadcastStation(
        id: id,
        description: description.isEmpty
            ? '插件 ${config.id} 自建广播站'
            : description,
        readme: readme,
        maxSubscriptions: maxSubscriptions,
        shared: shared,
        allowedPlugins: allowedPlugins,
        config: stationConfig,
      ),
      StationKind.relay => RelayStation(
        id: id,
        description: description.isEmpty
            ? '插件 ${config.id} 自建中转站'
            : description,
        readme: readme,
        maxSubscriptions: maxSubscriptions,
        shared: shared,
        allowedPlugins: allowedPlugins,
        config: stationConfig,
      ),
      StationKind.collect => CollectStation(
        id: id,
        description: description.isEmpty
            ? '插件 ${config.id} 自建收集站'
            : description,
        readme: readme,
        schema: schema,
        maxSubscriptions: maxSubscriptions,
        shared: shared,
        allowedPlugins: allowedPlugins,
        config: stationConfig,
      ),
      StationKind.execute => throw PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/register 不支持自建执行站',
      ),
    };
    final String? error = stations.register(station);
    if (error != null) {
      return <String, dynamic>{
        'ok': false,
        'station_id': '',
        'kind': kind.wire,
        'error': error,
      };
    }
    log?.call(
      '插件 ${config.id} 自建${kind.label} ${station.id}'
      '（订阅上限 $maxSubscriptions${shared ? '，已对外共享' : ''}）',
    );
    return <String, dynamic>{
      'ok': true,
      'station_id': station.id,
      'kind': kind.wire,
      'error': '',
    };
  }

  /// 自建站的共享白名单（宽容解析：非列表 = 空表 = 对所有插件开放）。
  static List<String> _selfBuiltAllowedPlugins(Object? raw) {
    if (raw is! List) return <String>[];
    return <String>[
      for (final Object? item in raw)
        if ('$item'.trim().isNotEmpty) '$item'.trim(),
    ];
  }

  /// 自建站的自定义配置（宽容解析：非映射 = 空映射）。
  static Map<String, dynamic> _selfBuiltConfig(Object? raw) {
    if (raw is! Map) return <String, dynamic>{};
    return <String, dynamic>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        e.key.toString(): e.value,
    };
  }

  /// **插件注销自建站点（插件 → 核心）**：参数 `{kind, name}`（或 `{station_id}`）。
  ///
  /// 只能注销**自己的**站点（id 前缀 `plugin.{自己}.`）；注销时同时清掉该站上的
  /// 订阅。**插件下线不会自动注销自建站**：站点是持久化资源（跨重启保留），
  /// 插件重启后按同名幂等重新注册即可；不想要了就显式注销。
  Future<Map<String, dynamic>> _handleStationUnregister(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    String id = (params['station_id'] ?? '').toString().trim();
    if (id.isEmpty) {
      final StationKind? kind = StationKind.fromWire(
        (params['kind'] ?? '').toString().trim(),
      );
      final String name = (params['name'] ?? '').toString().trim();
      if (kind == null || name.isEmpty) {
        throw const PluginRequestException(
          PluginRpcErrorCode.invalidParams,
          'station/unregister 需要 station_id，或 kind + name',
        );
      }
      id = selfBuiltStationId(config.id, kind, name);
    }
    // **先查归属、再查存在**（fail-closed）：内置站可能是懒创建的（此刻还没实例），
    // 但"插件不得动内置站"这条判断不依赖它存在——否则一个插件在内置站建出来之前
    // 请求注销它，就会拿到"不存在（可能已注销）"这种误导性的成功回包。
    final String? ownerError = _selfBuiltOwnershipError(config.id, id);
    if (ownerError != null) {
      return <String, dynamic>{
        'ok': false,
        'station_id': id,
        'removed_subscriptions': 0,
        'error': ownerError,
      };
    }
    final StationInstance? station = stations.station(id);
    if (station == null) {
      return <String, dynamic>{
        'ok': true,
        'station_id': id,
        'removed_subscriptions': 0,
        'error': '',
        'notice': '站点不存在（可能已注销）',
      };
    }
    final int subscriptions = station.subscribers.length;
    stations.unregister(id);
    log?.call('插件 ${config.id} 注销自建站点 $id（连带 $subscriptions 条订阅）');
    return <String, dynamic>{
      'ok': true,
      'station_id': id,
      'removed_subscriptions': subscriptions,
      'error': '',
    };
  }

  /// 自建站 id（核心拼装：插件不能自选，这是"我的站点只能是我的"的强制点）。
  static String selfBuiltStationId(
    String pluginId,
    StationKind kind,
    String name,
  ) => 'plugin.$pluginId.${kind.wire}.$name';

  /// 自建站名段校验（返回 null = 合法）。
  ///
  /// 名段只允许 `[A-Za-z0-9_-]`：它是 id 的一部分，混入 `.` / `@` / 空白会让
  /// 归属前缀判定（`plugin.{id}.`）产生歧义——例如插件 `a` 建 `b.relay.x`
  /// 就能顶掉插件 `a.b` 的站点。
  static String? _checkSelfBuiltName(String name) {
    if (name.isEmpty) {
      return '自建站点需要 name（站点 id 为 plugin.<插件id>.<类型>.<name>）';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
      return '自建站点的 name 只允许字母 / 数字 / 下划线 / 连字符，收到「$name」';
    }
    return null;
  }

  /// 自建站归属校验（返回 null = 属于该插件）。
  static String? _selfBuiltOwnershipError(String pluginId, String stationId) {
    if (stationId.startsWith('plugin.$pluginId.')) return null;
    if (StationHubIds.all.contains(stationId)) {
      return '「$stationId」是内置站点，插件不得注销或改写';
    }
    return '站点「$stationId」不属于插件 $pluginId（自建站 id 必须是 '
        'plugin.$pluginId.…）';
  }

  /// 自建站订阅上限：缺省按类型给默认值，列表型站点允许插件自报。
  static int _selfBuiltMaxSubscriptions(Object? raw, StationKind kind) {
    final int fallback = switch (kind) {
      StationKind.relay => 16,
      _ => StationInstance.defaultMaxSubscriptions,
    };
    if (raw is num) {
      final int value = raw.toInt();
      return value < 0 ? fallback : value;
    }
    return fallback;
  }

  /// **站点订阅（插件 → 核心）**：参数 `{station, point?, scope?, replace?, station_id?}`。
  ///
  /// - `station_id`：**可选**，直连某个具体点位/自建站（如 `system.relay.llm.handle`、
  ///   `plugin.forwarder.relay.audit`）。给了它就按 id 取——但**必须由核心校验归属**：
  ///   自建站只有它是自己的、或它是内置点位时才允许订阅；
  /// - `station`：类型线名（`relay` / `broadcast`；执行站不可订阅）；配合 `point`
  ///   指定点位（别名如 `llm.handle` / `tool.pre`，也接受完整 id 或 id 后缀）；
  ///   **`station: 'relay'` 不带 point = 一次订阅"工具前 + 工具后"两个点位**
  ///   （点位化之前就是一个实例收两段，老插件因此零改动）；
  /// - `scope`：订阅粒度（`team_id/agent_id/session_id/mode_key`）。**它是作用域
  ///   上限**：team 无法由插件自己认领——核心按目标 agent 的真实归属解析后校验，
  ///   解析不出来或与声明冲突一律拒绝（与 `station/command` 同一 fail-closed 口径）；
  /// - `replace`：每个中转站点位**唯一订阅者**，第二人默认被拒（先到先得），
  ///   显式 `replace: true` 才接管并回报被替换者。
  ///
  /// 回包是结果而非 JSON-RPC 错误：
  /// `{ok, station_id, station_ids, kind, scope, replaced, error, subscriptions}`——
  /// 一次订阅多个点位时 `station_ids` / `subscriptions` 给出每一个的结果，
  /// `ok` = 全部成功（部分成功时插件能读到逐条原因）。
  Future<Map<String, dynamic>> _handleStationSubscribe(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    // 插件可显式指定要订阅的站点实例（点位直连 / 自建站的消费入口）
    final String explicitId = (params['station_id'] ?? '').toString().trim();
    if (explicitId.isNotEmpty) {
      final StationScope scope = _resolveSubscriptionScope(config, params);
      final StationInstance? station = stations.pointFor(explicitId);
      if (station == null) {
        return <String, dynamic>{
          'ok': false,
          'station_id': explicitId,
          'station_ids': <String>[],
          'kind': '',
          'scope': scope.toJson(),
          'replaced': '',
          'error': '站点不存在：$explicitId',
          'subscriptions': <Map<String, dynamic>>[],
        };
      }
      return _subscribeToStations(config, params, <StationInstance>[
        station,
      ], scope);
    }
    final String kindRaw = (params['station'] ?? '').toString().trim();
    if (kindRaw.isEmpty) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/subscribe 需要 station（relay 或 broadcast）与可选 point，或 station_id',
      );
    }
    final StationKind? kind = StationKind.fromWire(kindRaw);
    if (kind == null || !kind.subscribable) {
      throw PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/subscribe 的 station 只支持 relay / broadcast，'
        '收到「$kindRaw」（执行站由插件主动下命令，不可订阅）',
      );
    }
    final StationScope scope = _resolveSubscriptionScope(config, params);
    final String pointRaw = (params['point'] ?? '').toString().trim();
    final List<StationPointSpec> specs = StationPoints.resolveAlias(
      kindWire: kindRaw,
      point: pointRaw,
    );
    if (specs.isEmpty) {
      throw PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/subscribe 的点位「$pointRaw」在${kind.label}里不存在；'
        '可用点位：${StationPoints.describeAliases(kind)}',
      );
    }
    final List<StationInstance> targets = <StationInstance>[];
    for (final StationPointSpec spec in specs) {
      final StationInstance? station = stations.pointFor(spec.id);
      if (station != null) targets.add(station);
    }
    if (targets.isEmpty) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 的 scope（${scope.describe()}）没有可用的'
        '${kind.label}：站点未接线（核心未启动站点中枢）',
      );
    }
    return _subscribeToStations(config, params, targets, scope);
  }

  /// 订阅**一个或多个**点位，并把逐条结果合成一份回包。
  ///
  /// 为什么允许多个：`station: 'relay'`（不带 point）在点位化之后表示
  /// "工具前 + 工具后都要"——老插件不改代码也能保持原行为。部分成功不视为失败，
  /// 但 `ok` 只在**全部成功**时为 true，且 `error` 汇总所有失败原因（不静默）。
  Future<Map<String, dynamic>> _subscribeToStations(
    PluginConfig config,
    Map<String, dynamic> params,
    List<StationInstance> targets,
    StationScope scope,
  ) async {
    final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
    for (final StationInstance station in targets) {
      results.add(await _subscribeToStation(config, params, station, scope));
    }
    final Map<String, dynamic> first = results.first;
    final List<String> errors = <String>[
      for (final Map<String, dynamic> item in results)
        if ('${item['error']}'.trim().isNotEmpty)
          '${item['station_id']}：${item['error']}',
    ];
    final List<String> replaced = <String>[
      for (final Map<String, dynamic> item in results)
        if ('${item['replaced']}'.trim().isNotEmpty) '${item['replaced']}',
    ];
    return <String, dynamic>{
      'ok': results.every((Map<String, dynamic> item) => item['ok'] == true),
      'station_id': first['station_id'],
      'station_ids': results
          .map((Map<String, dynamic> item) => item['station_id'])
          .toList(growable: false),
      'kind': first['kind'],
      'scope': scope.toJson(),
      'replaced': replaced.join(','),
      'error': errors.join('；'),
      'subscriptions': results,
    };
  }

  /// 订阅一个**已解析出来的**站点实例（内置类型寻址与 `station_id` 寻址共用）。
  ///
  /// 归属校验在这里做：插件可以订阅**内置站**或**自己的自建站**；别人的自建站只在
  /// **建站方显式共享**（`shared`，必要时再看 `allowed_plugins` 名单）时才放行——
  /// 闸门只认写进站点实例的声明，不靠「私下把 id 传过去」（那等于任何插件都能挂上
  /// 别人的拦截点）。
  Future<Map<String, dynamic>> _subscribeToStation(
    PluginConfig config,
    Map<String, dynamic> params,
    StationInstance station,
    StationScope scope,
  ) async {
    final bool builtin = StationHubIds.all.contains(station.id);
    final String? ownerError = builtin
        ? null
        : _selfBuiltAccessError(config, station);
    if (ownerError != null) {
      log?.call('插件 ${config.id} 订阅 ${station.id} 被拒：$ownerError');
      return <String, dynamic>{
        'ok': false,
        'station_id': station.id,
        'kind': station.kind.wire,
        'scope': scope.toJson(),
        'replaced': '',
        'error': ownerError,
      };
    }
    final StationKind kind = station.kind;
    // 新一世重新申报 ⇒ 上一世那份代管声明当场作废（理由与只堵这一路不够的原因
    // 都写在 [_supersedeCarriedSubscriptions]）。**必须先清旧的再挂新的**，顺序反了
    // 就会把刚挂上的这一世一起摘掉。
    _supersedeCarriedSubscriptions(config.id);
    final StationSubResult result = stations.subscribe(
      station.id,
      StationSubscriber(
        pluginId: config.id,
        scope: scope,
        subscribedAt: _nowSeconds(),
      ),
      // 站点 → 插件的回包通道与收集站同一条（`station/request`），不发明新协议。
      //
      // **回包函数延迟解析宿主**（不在订阅时固定 host 实例）：插件可以在
      // `hello` 握手期间就发订阅请求（此时 `_hosts` 还没登记），若在此刻取
      // `_hosts[config.id]` 会把「启动即订阅」的插件误判成"实例不在运行"。
      //
      // **先判 lifecycle、再判宿主**（阶段 2 保活的唯一入口）：重启窗口里旧宿主可能
      // 还在表里，把请求递给它等于亲手制造一次失败；而此刻没有宿主也不该直接回
      // failed——那是「暂时不可用」，不是「这个插件不干了」。
      (StationRequest request) async {
        if (_isKeepaliveWindow(config.id)) {
          return restartBuffer.push(
            config.id,
            request,
            (StationRequest r) => _deliverStationRequest(config.id, r),
          );
        }
        final PluginHost? host = _hosts[config.id];
        if (host == null || host.isClosed) {
          return StationReply.failed('插件 ${config.id} 未运行，无法处理站点请求');
        }
        return host.requestStation(request);
      },
      replace: params['replace'] == true,
    );
    if (!result.ok) {
      log?.call(
        '插件 ${config.id} 订阅 ${kind.label} 被拒（${station.id}）：${result.error}',
      );
    } else {
      log?.call(
        '插件 ${config.id} 订阅 ${kind.label}（${station.id}，'
        'scope=${scope.key}${result.replacedPluginId.isEmpty ? '' : '，接管自 ${result.replacedPluginId}'}）',
      );
    }
    return <String, dynamic>{
      'ok': result.ok,
      'station_id': station.id,
      'kind': kind.wire,
      'scope': scope.toJson(),
      'replaced': result.replacedPluginId,
      'error': result.error,
    };
  }

  /// **站点退订（插件 → 核心）**：参数 `{station, station_id?}`；幂等（未订阅也返回 ok）。
  Future<Map<String, dynamic>> _handleStationUnsubscribe(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    // 显式 id：退订某个具体站点（自建站的消费方退订走这条路）
    final String explicitId = (params['station_id'] ?? '').toString().trim();
    if (explicitId.isNotEmpty) {
      final StationInstance? station = stations.station(explicitId);
      if (station == null) {
        return <String, dynamic>{
          'ok': true,
          'station_id': explicitId,
          'kind': '',
          'removed': 0,
          'error': '',
        };
      }
      return <String, dynamic>{
        'ok': true,
        'station_id': station.id,
        'kind': station.kind.wire,
        'removed': stations.unsubscribe(station.id, config.id),
        'error': '',
      };
    }
    final String kindRaw = (params['station'] ?? '').toString().trim();
    final StationKind? kind = StationKind.fromWire(kindRaw);
    if (kind == null || !kind.subscribable) {
      throw PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/unsubscribe 的 station 只支持 relay / broadcast，'
        '收到「$kindRaw」（或改用 station_id）',
      );
    }
    final StationScope scope = _resolveSubscriptionScope(config, params);
    // 退订同样按点位：不带 point 的 `relay` = 两个工具点位一起退（与订阅对称）。
    final List<StationPointSpec> specs = StationPoints.resolveAlias(
      kindWire: kindRaw,
      point: (params['point'] ?? '').toString().trim(),
    );
    if (specs.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'station_id': '',
        'station_ids': <String>[],
        'kind': kind.wire,
        'removed': 0,
        'error': '点位不存在；可用点位：${StationPoints.describeAliases(kind)}',
      };
    }
    int removed = 0;
    final List<String> ids = <String>[];
    for (final StationPointSpec spec in specs) {
      final StationInstance? station = stations.pointFor(spec.id);
      if (station == null) continue;
      ids.add(station.id);
      removed += stations.unsubscribe(station.id, config.id);
    }
    if (ids.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'station_id': '',
        'station_ids': <String>[],
        'kind': kind.wire,
        'removed': 0,
        'error':
            '插件 ${config.id} 的 scope（${scope.describe()}）没有可用的${kind.label}',
      };
    }
    return <String, dynamic>{
      'ok': true,
      'station_id': ids.first,
      'station_ids': ids,
      'kind': kind.wire,
      'removed': removed,
      'error': '',
    };
  }

  /// 跨插件使用自建站的闸门（订阅与触发共用；返回 null = 放行）。
  ///
  /// 与 [_selfBuiltOwnershipError] 的区别：那条是「改写 / 注销」的所有权口径
  /// （只有建站方能做），这条是「使用」口径——所有者永远可用，别人要**订阅或
  /// 触发**必须建站方在 `station/register` 里显式声明 `shared`。
  static String? _selfBuiltAccessError(
    PluginConfig config,
    StationInstance station,
  ) {
    if (station.id.startsWith('plugin.${config.id}.')) return null;
    if (!station.shared) {
      return '站点「${station.id}」不属于插件 ${config.id}，且建站方没有声明 shared：'
          '要跨插件使用，请由建站方在 station/register 带 shared: true'
          '（可选 allowed_plugins 限定名单，留空 = 对所有插件开放）';
    }
    if (station.allowedPlugins.isNotEmpty &&
        !station.allowedPlugins.contains(config.id)) {
      final List<String> allowed = station.allowedPlugins.toList()..sort();
      return '站点「${station.id}」已共享，但插件白名单里没有 ${config.id}'
          '（当前白名单：${allowed.join('、')}）';
    }
    return null;
  }

  /// **站点触发（插件 → 核心）**：参数 `{station_id, topic?, scope?, payload?, meta?}`。
  ///
  /// 为什么需要它：自建站过去连**订阅**都要校验 `plugin.{自己}.` 前缀，「插件建的
  /// 站点被别的插件调用」根本走不通。这条路把**调用**显式化——调用方带 `station_id`，
  /// 核心按建站方的声明（`shared` / `allowed_plugins`）放行，并把消息 scope 按
  /// **真实归属**解析（不信任调用方自报的 team / mode，与订阅同一 fail-closed 口径）。
  ///
  /// 边界（一律给可读原因，不静默拒绝）：
  /// - **内置点位不可触发**：它们的触发时机由核心在固定接入点决定，插件要用内置
  ///   能力请下命令（`station/command`）；
  /// - **执行站不可触发**：它由命令驱动，没有「触发一次」的语义；
  /// - **消息必须带确定的 mode_key**：空 mode 在**订阅**里是通配（两种工作面都收），
  ///   但投递判据是「消息 ↔ 订阅者」，一条没有工作面的消息定不了投给谁；
  /// - 订阅者被站点所有者**禁用** ⇒ 不投递，但原因出现在 `skipped` 里（各站的 trigger 负责）。
  ///
  /// 站点自定义配置（[StationInstance.config]）随 meta 下发：核心**不解释**它的语义
  /// （那是建站方与订阅者之间的契约），但订阅者必须读得到——否则面板上配的「其他」
  /// 参数就是摆设。
  ///
  /// 回包 `{ok, station_id, kind, result, error}`：业务拒绝是**结果**而非 JSON-RPC 错误
  /// （与 `station/command` 同风格）；`result.summary` 是一句可直接给人看的描述。
  Future<Map<String, dynamic>> _handleStationTrigger(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    final String stationId = (params['station_id'] ?? '').toString().trim();
    if (stationId.isEmpty) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/trigger 需要 station_id（要下命令给内置能力请用 station/command）',
      );
    }
    final StationInstance? station = stations.station(stationId);
    if (station == null) {
      return <String, dynamic>{
        'ok': false,
        'station_id': stationId,
        'kind': '',
        'result': null,
        'error': '站点不存在：$stationId（自建站请用 station/register 返回的 station_id）',
      };
    }
    Map<String, dynamic> denied(String error) => <String, dynamic>{
      'ok': false,
      'station_id': station.id,
      'kind': station.kind.wire,
      'result': null,
      'error': error,
    };
    if (station.kind == StationKind.execute) {
      return denied('执行站由命令驱动（station/command），不支持 station/trigger');
    }
    final bool builtin = StationHubIds.all.contains(station.id);
    final bool isOwner = station.id.startsWith('plugin.${config.id}.');
    if (!station.callableBy(config.id, isOwner: isOwner, isBuiltin: builtin)) {
      final String reason = builtin
          ? '「${station.id}」是内置${station.kind.label}：触发时机由核心在固定接入点'
                '决定，插件不能主动触发；要使用内置能力请下命令（station/command）'
          : (_selfBuiltAccessError(config, station) ??
                '插件 ${config.id} 不能触发站点 ${station.id}');
      log?.call('插件 ${config.id} 触发 ${station.id} 被拒：$reason');
      return denied(reason);
    }
    final Object? rawMeta = params['meta'];
    if (rawMeta != null && rawMeta is! Map) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/trigger 的 meta 必须是 JSON 对象',
      );
    }
    // scope = 这一次消息的**运行期四元组**（订阅同一套解析：请求不得放大声明，
    // 有 agent 时按真实归属收窄）。
    final StationScope scope = _resolveSubscriptionScope(config, params);
    // 消息必须带**确定的** mode：订阅时空 mode = 通配（两种工作面都收），但投递判定
    // 看的是「消息 ↔ 订阅者」，一条没有工作面的消息无法判定该投给谁（fail-closed）。
    if (!StationModeKey.isValid(scope.modeKey)) {
      return denied(
        '触发需要确定的 scope.mode_key（local | ssh），当前解析出来是空：'
        '空 mode 在**订阅**里是通配，在**消息**里无法判定投给谁；'
        '请在 params.scope.mode_key 里给出，或带上 agent_id 让核心按真实归属解析',
      );
    }
    final Map<String, dynamic> meta = <String, dynamic>{
      'triggered_by': config.id,
      ...station.config,
      if (rawMeta is Map)
        ...rawMeta.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
    };
    final Object? payload = params['payload'];
    if (station is BroadcastStation) {
      final String topic = (params['topic'] ?? '').toString().trim();
      if (topic.isEmpty) {
        return denied('广播站触发需要 topic（公告板回看与订阅者分流都按它）');
      }
      final StationPublishResult result = await station.publish(
        topic: topic,
        scope: scope,
        payload: payload,
        meta: meta,
        sourcePluginId: config.id,
      );
      return <String, dynamic>{
        'ok': true,
        'station_id': station.id,
        'kind': station.kind.wire,
        'result': <String, dynamic>{
          'topic': result.topic,
          'board_seq': result.boardSeq,
          'delivered': result.delivered,
          'summary': result.describe(),
          'deliveries': <Map<String, dynamic>>[
            for (final StationDelivery delivery in result.deliveries)
              <String, dynamic>{
                'plugin_id': delivery.pluginId,
                'ok': delivery.ok,
                'error': delivery.error,
                'payload': delivery.payload,
              },
          ],
          'skipped': result.skipped,
        },
        'error': '',
      };
    }
    if (station is RelayStation) {
      final StationRelayResult result = await station.relay(
        data: payload,
        scope: scope,
        meta: meta,
        sourcePluginId: config.id,
      );
      return <String, dynamic>{
        'ok': true,
        'station_id': station.id,
        'kind': station.kind.wire,
        'result': <String, dynamic>{
          'handled': result.handled,
          'data': result.data,
          'plugin_id': result.pluginId,
          'request_id': result.requestId,
          'reason': result.reason,
          'summary': result.describe(),
        },
        'error': '',
      };
    }
    if (station is CollectStation) {
      final StationCollectResult result = await station.collect(
        scope: scope,
        request: payload,
        meta: meta,
        sourcePluginId: config.id,
      );
      return <String, dynamic>{
        'ok': true,
        'station_id': station.id,
        'kind': station.kind.wire,
        'result': <String, dynamic>{
          'summary': result.describe(),
          'complete': result.complete,
          'items': <Map<String, dynamic>>[
            for (final StationCollectedItem item in result.items)
              <String, dynamic>{
                'plugin_id': item.pluginId,
                'payload': item.payload,
              },
          ],
          'unresponsive': <Map<String, dynamic>>[
            for (final StationUnresponsive bad in result.unresponsive)
              <String, dynamic>{
                'plugin_id': bad.pluginId,
                'reason': bad.reason,
              },
          ],
          'skipped': result.skipped,
        },
        'error': '',
      };
    }
    return denied('站点 ${station.id} 的类型 ${station.kind.wire} 不支持触发');
  }

  /// 解析一次订阅的**运行期四元组**（与 `station/command` 同口径，fail-closed）。
  ///
  /// 与命令的区别：订阅是**长期**行为，因此必须有可证明的归属——
  /// - 有 agent ⇒ 按该 agent 的真实 team / mode 解析；
  /// - 无 agent（团队级订阅）⇒ team 取自请求或声明，且声明非空时必须一致；
  /// - mode 缺省按声明 / local 兜底（站点只在 local / ssh 两档上存在）。
  StationScope _resolveSubscriptionScope(
    PluginConfig config,
    Map<String, dynamic> params,
  ) {
    final StationScope declared = StationScope.parse(config.scope);
    final Object? rawScope = params['scope'];
    final StationScope requested = rawScope is Map
        ? StationScope.parse(
            rawScope.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          )
        : declared;
    // 声明与请求都是作用域上限：请求不得放大到声明之外。
    if (declared.teamId.trim().isNotEmpty &&
        requested.teamId.trim().isNotEmpty &&
        declared.teamId.trim() != requested.teamId.trim()) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 声明 team=${declared.teamId}，'
        '但订阅请求 team=${requested.teamId}：跨 team 拒绝（声明是作用域上限）',
      );
    }
    final String agentId = requested.agentId.trim().isNotEmpty
        ? requested.agentId.trim()
        : declared.agentId.trim();
    final String sessionId = requested.sessionId.trim().isNotEmpty
        ? requested.sessionId.trim()
        : declared.sessionId.trim();
    String teamId = requested.teamId.trim().isNotEmpty
        ? requested.teamId.trim()
        : declared.teamId.trim();
    // mode：请求 / 声明里有合法值就用它；**都没有则留空 = 两种工作面都收**
    // （不再兜底成 local：那会把 SSH 团队的订阅悄悄锁在本地模式上，永远收不到）
    String modeKey = StationModeKey.isValid(requested.modeKey)
        ? requested.modeKey
        : (StationModeKey.isValid(declared.modeKey) ? declared.modeKey : '');
    if (agentId.isNotEmpty) {
      // 有目标 agent：team / mode 一律按**真实归属**解析，不信任请求里的自述。
      final StationScopeContext? context = callSiteContext?.call(
        agentId,
        sessionId,
      );
      final String resolvedTeam = (context?.teamId ?? '').trim();
      if (resolvedTeam.isNotEmpty) {
        if (teamId.isNotEmpty && teamId != resolvedTeam) {
          throw PluginRequestException(
            PluginRpcErrorCode.scopeDenied,
            '插件 ${config.id} 订阅 team=$teamId，但 agent $agentId '
            '真实归属 team=$resolvedTeam：跨 team 拒绝',
          );
        }
        teamId = resolvedTeam;
      }
      final String resolvedMode = (agentModeKeyResolver?.call(agentId) ?? '')
          .trim();
      if (StationModeKey.isValid(resolvedMode)) {
        // 请求里**显式**声明了模式才做冲突校验（声明是上限）；没声明时按真实模式收窄，
        // 免得一份 map 订阅把 local / ssh 两个工作面混在一起。
        if (StationModeKey.isValid(requested.modeKey) &&
            requested.modeKey != resolvedMode) {
          throw PluginRequestException(
            PluginRpcErrorCode.scopeDenied,
            '插件 ${config.id} 订阅 mode=${requested.modeKey}，但 agent $agentId '
            '真实模式=$resolvedMode：跨模式拒绝',
          );
        }
        modeKey = StationModeKey.isValid(requested.modeKey)
            ? requested.modeKey
            : resolvedMode;
      }
    }
    // team 为空 = **通配所有 team**（用户定稿：为空默认作用于所有 team），
    // 不再 fail-closed 拒绝——订阅侧的空维度一律是"这一维不设条件"。
    return StationScope(
      teamId: teamId,
      agentId: agentId,
      sessionId: sessionId,
      modeKey: modeKey,
    );
  }

  /// **执行站命令（插件 → 核心）**：参数 {command, arguments, team_id?, agent_id?, session_id?, mode_key?}。
  ///
  /// **单实例 + 每条消息带身份（Q2）**：插件进程只有一个，身份**按这一次请求**解析：
  /// - 目标 agent 取请求里的 agent_id（params 顶层或 arguments 均可），缺省才回退
  ///   到 plugins.yaml 的 scope.agent_id；
  /// - team / mode 由核心按**目标 agent 的真实归属**解析（团队 + 工作空间模式），
  ///   而不是信任插件声明；
  /// - plugins.yaml 的 scope 从此是**作用域上限**：声明了 team 的插件只能在自己的
  ///   team 内活动；未声明的插件可服务任意 team，但每条命令都必须能证明归属
  ///   （fail-closed：agent 缺失 / 不存在 / 归属解析不出 / 请求里带的 team_id 与
  ///   真实归属不一致，一律拒绝）；
  /// - 不带 agent 的团队级命令（如 ui.push）：team 取请求或声明，agent 留空。
  ///
  /// 执行站的结论（含**可读错误**）原样放进 result 回给插件：命令被拒 / 挂载位置
  /// 失败不是 JSON-RPC 错误，而是 {ok: false, error: ...}——插件据此自查原因，
  /// 不会被吞成一句“调用失败”。
  Future<Map<String, dynamic>> _handleStationCommand(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    final String command = (params['command'] ?? '').toString().trim();
    if (command.isEmpty) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/command 需要 command（执行站命令名，如 fs.read / ui.push）',
      );
    }
    final Object? rawArguments = params['arguments'];
    if (rawArguments != null && rawArguments is! Map) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/command 的 arguments 必须是 JSON 对象',
      );
    }
    final Map<String, dynamic> arguments = rawArguments is Map
        ? rawArguments.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    // scope = 这一次命令的**运行期四元组**（Q2：单实例 + 每条消息带身份）。
    // 声明只作上限；team / mode 由核心按目标 agent 的真实归属解析。
    final StationScope declared = StationScope.parse(config.scope);
    final StationScope scope = _resolveCommandScope(
      config,
      declared,
      params,
      arguments,
    );
    // 点位化：执行站按**命令族**拆成多个点位，命令 → 所属点位在这里路由
    // （插件侧零改动：仍然只带 command）。
    if (StationPoints.ownerOfCommand(command) == null) {
      final List<String> allowed = StationPoints.allCommands.toList()..sort();
      return <String, dynamic>{
        'command': command,
        'ok': false,
        'mount_id': '',
        'payload': null,
        'error':
            '未知命令 $command（执行站命令白名单：${allowed.join('、')}）；'
            '命令 → 点位的分配见 station_points.dart',
      };
    }
    final ExecuteStation? station = stations.executeForCommand(command);
    if (station == null) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 的 scope（${scope.describe()}）没有可用的执行站'
        '（站点未接线：核心未启动站点中枢）',
      );
    }
    final StationCommandResult result = await station.execute(
      command: command,
      scope: scope,
      arguments: arguments,
      sourcePluginId: config.id,
    );
    // 结果原样回给插件（ok / payload / error 三件套，执行站说什么就回什么）
    return <String, dynamic>{
      'command': result.command,
      'ok': result.ok,
      'mount_id': result.mountId,
      'payload': result.payload,
      'error': result.error,
    };
  }

  /// 解析一次 station/command 的**运行期四元组**（Q2：单实例 + 每消息带身份）。
  ///
  /// 规则（fail-closed）：
  /// 1. 目标 agent = 请求里的 agent_id（params 顶层或 arguments）→ 声明里的
  ///    scope.agent_id；两者都空时才走"团队级命令"分支（如 ui.push）；
  /// 2. team / mode = 核心按目标 agent 的**真实归属**解析（callSiteContext /
  ///    agentModeKeyResolver）；解析器未接线（测试 / 嵌入式宿主）才回退到声明，
  ///    与改造前行为一致；
  /// 3. 插件声明是**作用域上限**：声明了非空 team / agent / session 时真实值必须一致；
  /// 4. 请求里显式带的 team_id / mode_key 必须与真实归属一致（带了就得对，
  ///    不允许"声明一套、请求另一套"）。
  StationScope _resolveCommandScope(
    PluginConfig config,
    StationScope declared,
    Map<String, dynamic> params,
    Map<String, dynamic> arguments,
  ) {
    String pick(String key) {
      for (final Object? source in <Object?>[params, arguments]) {
        if (source is! Map) continue;
        final Object? value = source[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
      return '';
    }

    final String requestedTeam = pick('team_id');
    final String requestedMode = pick('mode_key');
    final String requestedSession = pick('session_id');
    final String requestedAgent = pick('agent_id');

    // ── 团队级命令（无目标 agent，如 ui.push）：team 可以留空 = 通配所有 team ──
    //
    // 用户定稿：**为空默认作用于所有 team**。所以这里不再 fail-closed 拒绝；
    // 真正需要"证明归属"的是**执行类命令**（fs.* / terminal.exec / agent.*）——
    // 它们在自己的挂载位置里按目标 agent 解析工作空间，解析不出来就拒绝执行
    // （见 execute_mounts 的 _resolveTarget），闸门放在该放的地方。
    if (requestedAgent.isEmpty && declared.agentId.isEmpty) {
      final String team = requestedTeam.isNotEmpty
          ? requestedTeam
          : declared.teamId.trim();
      if (declared.teamId.trim().isNotEmpty &&
          team.isNotEmpty &&
          declared.teamId.trim() != team) {
        throw PluginRequestException(
          PluginRpcErrorCode.scopeDenied,
          '插件 ${config.id} 声明 team=${declared.teamId}，'
          '但命令要作用于 team=$team：跨 team 拒绝（声明是作用域上限）',
        );
      }
      return StationScope(
        teamId: team,
        sessionId: requestedSession.isNotEmpty
            ? requestedSession
            : declared.sessionId,
        // 命令是**消息**：站点侧自校验要求 mode 合法（空 = 不可证明 ⇒ 拒），
        // 所以这里保留 local 兜底（订阅侧才允许留空 = 两种工作面都收）。
        modeKey: StationModeKey.isValid(requestedMode)
            ? requestedMode
            : (StationModeKey.isValid(declared.modeKey)
                  ? declared.modeKey
                  : StationModeKey.local),
      );
    }

    // ── agent 级命令：按目标 agent 的真实归属解析 ────────────────────────
    final String agentId = requestedAgent.isNotEmpty
        ? requestedAgent
        : declared.agentId;
    final String sessionId = requestedSession.isNotEmpty
        ? requestedSession
        : declared.sessionId;
    final StationScopeContext? context = callSiteContext?.call(
      agentId,
      sessionId,
    );
    final String resolvedTeam = (context?.teamId ?? '').trim().isNotEmpty
        ? context!.teamId.trim()
        : declared.teamId.trim();
    final String resolvedMode = (agentModeKeyResolver?.call(agentId) ?? '')
        .trim();
    // 命令的 mode 必须**有合法值**（它决定打本地还是 SSH 工作空间，见
    // execute_mounts 的 _resolveTarget），所以这里保留 local 兜底——与订阅侧
    // 「留空 = 通配」不同：命令要真的落到某个工作面上，猜不出来就是 local + 之后
    // 与目标 agent 的真实模式做精确比对（对不上会被拒绝执行，fail-closed）。
    final String mode = StationModeKey.isValid(resolvedMode)
        ? resolvedMode
        : (StationModeKey.isValid(requestedMode)
              ? requestedMode
              : (StationModeKey.isValid(declared.modeKey)
                    ? declared.modeKey
                    : StationModeKey.local));

    if (declared.teamId.trim().isNotEmpty &&
        declared.teamId.trim() != resolvedTeam) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 声明 team=${declared.teamId}，但目标 agent $agentId '
        '真实归属 team=${_scopeOr(resolvedTeam)}：跨 team 拒绝（声明是作用域上限）',
      );
    }
    if (declared.agentId.isNotEmpty && declared.agentId != agentId) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 绑定了 agent=${declared.agentId}，不能对 $agentId 下命令',
      );
    }
    if (declared.sessionId.isNotEmpty &&
        sessionId.isNotEmpty &&
        declared.sessionId != sessionId) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 绑定了 session=${declared.sessionId}，'
        '与命令的 session=$sessionId 不一致',
      );
    }
    if (requestedTeam.isNotEmpty && requestedTeam != resolvedTeam) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '命令请求的 team_id=$requestedTeam 与目标 agent $agentId 的真实归属 '
        'team=${_scopeOr(resolvedTeam)} 不一致：跨 team 拒绝',
      );
    }
    if (StationModeKey.isValid(requestedMode) && requestedMode != mode) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '命令请求的 mode_key=$requestedMode 与目标 agent $agentId 的真实工作面 '
        'mode=$mode 不一致：拒绝',
      );
    }
    if (resolvedTeam.isEmpty) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 未声明 team，且目标 agent $agentId 没有可解析的团队归属，'
        '不能使用执行站（单实例插件请带 agent_id 并确保该 agent 存在；'
        '或在 plugins.yaml 的 scope.team_id 里声明团队）',
      );
    }
    return StationScope(
      teamId: resolvedTeam,
      agentId: agentId,
      sessionId: sessionId,
      modeKey: mode,
    );
  }

  /// 可读错误里把空归属显示成 "?"。
  static String _scopeOr(String value) => value.isEmpty ? '?' : value;

  void _scheduleToolTableRefresh(StationScope? scope) {
    if (_toolTableRefreshing) return;
    _toolTableRefreshing = true;
    toolTableRefreshHook?.call(scope);
    // 后台补一次收集：失败只记日志（插件不可用不该让工具表刷新点抛错）
    unawaited(() async {
      try {
        await refreshToolDefinitions(
          scope: scope,
          context: scope == null
              ? const StationScopeContext()
              : StationScopeContext(
                  teamId: scope.teamId,
                  agentId: scope.agentId,
                  sessionId: scope.sessionId,
                  modeKey: scope.modeKey,
                ),
        );
      } catch (error) {
        log?.call('插件工具表刷新失败（已忽略，保留现有工具表）：$error');
      } finally {
        _toolTableRefreshing = false;
      }
    }());
  }

  /// 缓存键：四元组全等（team / agent / session / mode 任一不同就是不同的表）。
  static String _toolTableKey(StationScope? scope) => scope?.key ?? '';

  /// 调用点上下文与插件声明不一致 ⇒ **不收集**并给出可读原因（fail-closed）。
  ///
  /// 订阅侧的空维度是**通配**（空 team = 所有 team），所以只在插件**声明了**该维度
  /// 且与调用点不一致时才算冲突。
  static String? _crossScopeReason(
    String pluginId,
    StationScope pluginScope,
    StationScopeContext context,
  ) {
    final String team = context.teamId.trim();
    if (team.isNotEmpty &&
        pluginScope.teamId.trim().isNotEmpty &&
        pluginScope.teamId != team) {
      return '插件 $pluginId 归属 team=${pluginScope.teamId}，与调用点 team=$team 不一致（跨 team 不收集）';
    }
    final String agent = context.agentId.trim();
    if (agent.isNotEmpty &&
        pluginScope.agentId.isNotEmpty &&
        pluginScope.agentId != agent) {
      return '插件 $pluginId 限定 agent=${pluginScope.agentId}，与调用点 agent=$agent 不一致（跨 scope 不收集）';
    }
    final String session = context.sessionId.trim();
    if (session.isNotEmpty &&
        pluginScope.sessionId.isNotEmpty &&
        pluginScope.sessionId != session) {
      return '插件 $pluginId 限定 session=${pluginScope.sessionId}，与调用点 session=$session 不一致（跨 scope 不收集）';
    }
    return null;
  }

  /// 无 team 归属插件的申报路径（tools/list → 动态工具表）。
  ///
  /// 站点体系要求四元组，这类插件不参与收集站；工具仍照旧注册（tool_name 与
  /// 执行名一致、执行方式 tools/call），与收集站产出的定义**同一张表**。
  void _registerLegacyTools(String pluginId, List<PluginToolInfo> tools) {
    _definitions.replacePlugin(pluginId, <PluginToolDefinition>[
      for (final PluginToolInfo tool in tools)
        PluginToolDefinition(
          pluginId: pluginId,
          toolName: tool.name,
          description: tool.description,
          parameters: tool.inputSchema,
        ),
    ]);
  }

  /// 点位申报的回包实现：直接交给插件（没有旧路径可退）。
  Future<StationReply> _respondToCapability(
    PluginHost host,
    StationRequest request,
  ) async {
    // 点位申报没有“旧路径兼容”（不像工具还能从 tools/list 兜一手）：
    // 插件没实现 station/request 就是没申报，由汇聚那一步**显式列出原因**。
    return host.requestStation(request);
  }

  /// 收集站订阅者的回包实现：**首选 station/request 通道**，老插件退回 tools/list。
  Future<StationReply> _respondToToolDefinition(
    PluginConfig config,
    PluginHost host,
    StationRequest request,
  ) async {
    final StationReply reply = await host.requestStation(request);
    if (!reply.isFailed) return reply;
    // 兼容路径：未实现 station/request 的插件仍用既有 tools/list 申报
    final List<PluginToolInfo> tools = await host.listTools(
      timeout: connectTimeout,
    );
    if (tools.isEmpty) return reply;
    return StationReply.ok(<String, dynamic>{
      'tools': <Map<String, dynamic>>[
        for (final PluginToolInfo tool in tools)
          <String, dynamic>{
            'tool_name': tool.name,
            'description': tool.description,
            'parameters': tool.inputSchema,
            'execution': <String, dynamic>{
              'method': PluginRpcMethods.toolsCall,
              'name': tool.name,
            },
          },
      ],
    });
  }

  /// 插件配置 + 调用点上下文 → **运行期四元组**（M9 Wave 3-I）。
  ///
  /// 默认口径（未接线 [stationScopeResolver] 时）：
  /// - team / agent / session：**只认插件自己的声明**（订阅身份 = 插件实例的声明
  ///   粒度）。调用点上下文不替插件认领归属：既避免无 team 归属的插件被跨 team
  ///   放大（plan §1.2 fail-closed），也避免 team 级插件被收窄成某个 agent 的订阅
  ///   （那会让同队其他 agent 再也看不到它的工具）；
  /// - mode_key：优先由 [agentModeKeyResolver] 从**调用点 agent 的工作空间模式**
  ///   解析（local | ssh），其次上下文显式值，最后声明兜底（缺省 local）——这是
  ///   「SSH 团队的命令不会打到本地工作空间」在工具表这一侧的落点。
  ///
  /// 调用点上下文另有两个用途：过滤不该参与本次收集的插件（见 [_crossScopeReason]）
  /// 与作为采集请求的**消息 scope**（见 refreshToolDefinitions）。
  StationScope _scopeOf(
    PluginConfig config, [
    StationScopeContext context = const StationScopeContext(),
  ]) {
    final RuntimeStationScopeResolver? resolver = stationScopeResolver;
    if (resolver != null) return resolver(config, context);
    final StationScope declared = StationScope.parse(config.scope);
    // 声明里连 team 都没有 ⇒ 通配订阅（空维度不设条件），只有 mode 填错才算出错。
    if (!declared.isValidSubscriber) return declared;
    // mode_key：调用点 agent 的工作空间模式（解析不出来才退回上下文 / 声明，
    // **都解析不出来就留空 = 两种工作面都收**，不再兜底成 local）
    final String callAgent = context.agentId.trim();
    final String fromAgent = callAgent.isEmpty
        ? ''
        : (agentModeKeyResolver?.call(callAgent) ?? '');
    final String mode = StationModeKey.isValid(fromAgent)
        ? fromAgent
        : (StationModeKey.isValid(context.modeKey)
              ? context.modeKey
              : declared.modeKey);
    return StationScope(
      teamId: declared.teamId,
      agentId: declared.agentId,
      sessionId: declared.sessionId,
      modeKey: mode,
    );
  }

  /// 站点活性探针：订阅者（插件）心跳还在不在。
  ///
  /// **重启窗口里给「无活性信息」而不是 lost**（阶段 2）：这不是谎报也不回避——
  /// 心跳台账本来就只能回答「这个进程还在不应」，而“旧进程已退、新进程未就绪”这一段
  /// 根本没有心跳可依据。报 lost 会让站点立刻终结等待（「订阅者心跳丢失」），暂存
  /// 就白做了；报 alive 那么核心在说一个自己知道不真的事。退回**活性窗口**（I×N）
  /// 才是既有口径：窗口内插件若真的再也没起来，stopped/failed 会把队列以可读失败收尾。
  /// 判死定义一字未改（不变量 15：只有心跳快照 down 与插件进程不可用两处能判死）。
  StationLivenessState _livenessOf(String pluginId) {
    final PluginLifecycleState lifecycle = lifecycleOf(pluginId);
    if (lifecycle.isTemporarilyUnavailable) {
      return StationLivenessState(
        known: false,
        alive: false,
        detail: '插件 $pluginId 处于 ${lifecycle.wire}（暂时不可用，不是判死）',
      );
    }
    final PluginHost? host = _hosts[pluginId];
    if (host == null) {
      return const StationLivenessState.lost('插件未启动或已下线');
    }
    if (host.isClosed) return const StationLivenessState.lost('插件进程已退出');
    if (host.liveness.isStale) {
      return StationLivenessState.lost('连续 ${host.liveness.missedCount} 拍未达');
    }
    return const StationLivenessState.alive();
  }

  /// 前端快照（GET /api/plugin/snapshot）。
  ///
  /// 字段与前端 plugin_monitor_service.dart 的宽容解析对齐；总开关关闭时
  /// 仍然 200 + enabled: false（前端渲染空态而不是报错）。
  /// stations 段 = 站点体系真实快照（站点实例 + 订阅 + 分类计数 + 收集站 schema）。
  Map<String, dynamic> snapshot({String? teamId}) {
    load();
    final List<Map<String, dynamic>> instances = <Map<String, dynamic>>[];
    int degradedCount = 0;
    for (final PluginConfig config in _configs) {
      final String scopeTeam = (config.scope['team_id'] ?? '').toString();
      if (teamId != null &&
          teamId.isNotEmpty &&
          scopeTeam.isNotEmpty &&
          scopeTeam != teamId) {
        continue;
      }
      final PluginHost? host = _hosts[config.id];
      final String? error = _errors[config.id];
      final bool degraded = host != null && host.liveness.isStale;
      if (degraded) degradedCount++;
      final String displayName = (host != null && host.name.isNotEmpty)
          ? host.name
          : config.name;
      instances.add(<String, dynamic>{
        'plugin_id': config.id,
        'name': displayName,
        // 插件详情页的数据源：介绍（来自 plugins.yaml）+ 当前注册的工具。
        // 工具放在实例上而不是配置上：它是对账出来的运行态（收集站收集到的定义），
        // 插件没启动就是空表（面板据此说“未提供工具”，而不是假装它有能力）。
        'description': config.description,
        'tools': toolsOf(config.id)
            .map(
              (PluginToolInfo t) => <String, dynamic>{
                'name': t.name,
                'description': t.description,
              },
            )
            .toList(growable: false),
        'granularity': config.granularity,
        'scope': config.scope,
        'status': error == null && host != null && !host.isClosed
            ? 'registered'
            : 'disabled',
        // **只增键**（D11）：status / health 的产出值与改动前逐字一致，lifecycle 与
        // generation 是新增的可选读数（面板据此显示「重启中 / 已挂起」）。
        'lifecycle': lifecycleOf(config.id).wire,
        'generation': generationOf(config.id),
        'health': host == null ? 'unavailable' : (degraded ? 'degraded' : 'ok'),
        if (host != null) ...<String, dynamic>{
          'missed_heartbeats': host.liveness.missedCount,
          'heartbeat_interval_s': host.liveness.interval.inMilliseconds / 1000,
          'last_heartbeat':
              (host.liveness.lastBeatAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
          'degraded_reason': degraded ? host.liveness.staleMessage : '',
        },
        if (_queueDepth[config.id] != null)
          'queue_depth': _queueDepth[config.id],
        'disabled_reason': error ?? '',
      });
    }
    final int disabled = instances
        .where((Map<String, dynamic> i) => i['status'] == 'disabled')
        .length;
    return <String, dynamic>{
      'enabled': enabled,
      'instances': instances,
      'stations': stations.snapshot(teamId: teamId),
      'watchdog': <String, dynamic>{
        'enabled': enabled,
        'interval_s': heartbeatInterval.inSeconds,
        'miss_threshold': missThreshold,
        'last_run': _lastWatchdogRun,
        'disabled_count': disabled,
        'degraded_count': degradedCount,
      },
      'config': <String, dynamic>{
        'enabled': enabled,
        'plugins': _configs.map((PluginConfig c) => c.toApiJson()).toList(),
        'path': configFile,
      },
      'station_summary': stations.summary(),
    };
  }

  /// 关闭全部实例与心跳定时器（幂等）。
  Future<void> close() async {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      final PluginConfig? pluginConfig = config(pluginId);
      await _disconnect(pluginId);
      if (pluginConfig != null) _emitStatus(pluginConfig, 'destroyed');
    }
    // **核心自己要退了 ⇒ 在这里收尸**（不留孤儿进程）。这不是时长判死：依据是
    // “父进程即将离开”这个事实，而快照池本来就随核心内存一起消失（D4），再等它
    // 转储毫无意义。这里也不 `await exited`：一个赖着不退的插件不该拖住整个退出。
    for (final PluginHost host in _reaping.toList(growable: false)) {
      host.killStray('核心退出 ⇒ 收尸（不留孤儿进程；不是时长判死）');
      _straysKilled++;
    }
    _reaping.clear();
    // 热重启的等待者必须以“拿不到快照”收尾，不能留一个永不完成的 future
    //（不变量 6：失败要可读上报，不静默挂住）。
    _failDumpWaiters('核心已退出 ⇒ 不再等这份快照');
    statePool.clear();
    // 暂存的站点请求也必须有人接盘：留一个永不完成的 future 就等于把会话挂在半空
    //（不变量 6：失败要可读上报，不静默挂住）。
    restartBuffer.abandonAll('核心已退出 ⇒ 这些暂存的站点请求不再等待');
    // 在等就绪的工具调用方也一样放回去（它们下一次取宿主会拿到 null，进而拿到
    // 一句可读的不可用原因，而不是永远挂着）。
    _wakeAllLifecycleWaiters();
    _stationKept.clear();
    stations.save();
  }

  /// 把所有在等的快照等待者以“没拿到”收尾（核心退出 / 热重启失败路径用）。
  void _failDumpWaiters(String reason) {
    if (_dumpWaiters.isEmpty) return;
    for (final Completer<String?> waiter in _dumpWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _dumpWaiters.clear();
    log?.call('快照等待收尾：$reason');
  }

  Future<PluginHost> _spawn(PluginConfig config, {String resumeDumpId = ''}) {
    final Future<PluginHost> Function(PluginConfig config)? factory =
        hostFactory;
    // 注入宿主（测试 / 自定义宿主）**拿不到 resumeDumpId**：它自己就是假定的插件，
    // 无得可「续」。因此取回快照不依赖它知道 dump_id——见
    // [handlePluginCommand] 的 `plugin.stateFetch`：代际由**核心自己**算。
    if (factory != null) return factory(config);
    return PluginHost.start(
      config,
      timeout: connectTimeout,
      heartbeatInterval: heartbeatInterval,
      coreVersion: coreVersion,
      resumeDumpId: resumeDumpId,
      onNotification: (Map<String, dynamic> notification) =>
          _emitPluginEvent(config.id, notification),
      // 插件主动请求（station/command）的处理器：建连时即接线，
      // 因此插件在 hello 握手期间就能下命令（不会撞上"未接线 ⇒ -32601"的窗口）。
      onPluginRequest: (String method, Map<String, dynamic> params) =>
          _handlePluginRequest(config, method, params),
    );
  }

  Future<void> _disconnect(String pluginId, {bool awaitExit = false}) async {
    final PluginHost? host = _hosts.remove(pluginId);
    // 实例没了 ⇒ "上次按什么参数起来的"这条记录也失效（重启会重新记）
    _spawnedConfigs.remove(pluginId);
    _queueDepth[pluginId] = 0;
    _degraded.remove(pluginId);
    _dead.remove(pluginId);
    // **UI 缓存一并作废**：插件下线后它的槽位不该再被重放给新连接（前端收不到
    // plugin_status 时尤其重要——例如核心重启、或前端当时正断线）
    uiCache.remove(pluginId);
    // **插件下线由总线注销其订阅**（站点订阅关系随之落盘）——但**重启窗口不注销**：
    // 注销后站点上就没有这个插件的回包函数，重启期间到达的请求连暂存的入口都
    // 没有（保活当场失效）。代价由 [_setLifecycle] 的 stopped/failed 分支补销。
    if (lifecycleOf(pluginId) == PluginLifecycleState.restarting) {
      _stationKept.add(pluginId);
    } else {
      _stationKept.remove(pluginId);
      stations.unsubscribePlugin(pluginId);
    }
    // 插件下线 ⇒ 它打开着的 LLM 接管流**必须以失败收尾**：否则会话会一直等一条
    // 永远不会有数据的流（判活定时器也会在一拍内发现并收尾，这里只是更快更明确）
    _failLlmStreamsOf(pluginId, '插件已下线，LLM 接管流中断');
    // 它"早到但从未关联上流"的帧也一并清掉（否则会留到下次同 id 的流被误放行）
    _dropPendingStreamFrames(pluginId: pluginId);
    // 动态工具表：下线插件的定义一并移除（避免调用到不存在的插件）
    _definitions.removePlugin(pluginId);
    // 插件下线 = 工具表失效点（模型工具表必须随之变化）
    invalidateToolTable(reason: '插件 $pluginId 下线');
    if (host == null) return;
    try {
      // 默认不等退出（D8）：“退没退”交给收尸台账按心跳判，不在这里卡住调用方。
      // `awaitExit: true` 只给“真的必须拿到退出码”的场景（Windows 替换二进制前的
      // 文件锁），等的也是事件而不是时长。
      await host.close(waitForExit: awaitExit);
    } catch (error) {
      log?.call('关闭插件 $pluginId 失败：$error');
    }
    if (!host.exitedConfirmed) {
      // 还没确认退出：挂上台账，由看门狗下一拍开始逐拍判。
      _reaping.add(host);
    }
    // **重启窗口不降回 stopped**：`hotRestart` / `restart` 一进来就置了 restarting，
    // 中间这段“旧进程已要求退、新进程还没就绪”对外必须是 restarting（阶段 2 的
    // 保活与路由判据全靠它）。除此之外断开就是 stopped。
    if (lifecycleOf(pluginId) != PluginLifecycleState.restarting) {
      _setLifecycle(pluginId, PluginLifecycleState.stopped);
    }
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 让某插件打开着的全部 LLM 接管流以失败收尾（下线 / 重启时调用）。
  void _failLlmStreamsOf(String pluginId, String reason) {
    final List<String> owned = <String>[
      for (final MapEntry<String, _PluginLlmStream> entry
          in _llmStreams.entries)
        if (entry.value.pluginId == pluginId) entry.key,
    ];
    for (final String requestId in owned) {
      _closeLlmStream(requestId, failure: reason);
    }
  }
}

/// 一条**比流登记更早到达**的 `station/stream` 通知（暂存待重放）。
///
/// 带 [pluginId] 是为了重放时**照走归属校验**：别人冒名推的帧不会因为"早到"而被放行。
class _PendingStreamFrame {
  const _PendingStreamFrame({required this.pluginId, required this.params});

  final String pluginId;
  final Map<String, dynamic> params;
}

/// 一条**插件接管的 LLM 流**（`system.relay.llm.handle` 的流式回填状态）。
///
/// 生命周期由 [PluginBus] 持有（`_llmStreams`）：打开 → 若干 `station/stream` 增量
/// → `done` / `error` / 取消 / 心跳丢失 收尾。**每个 request_id 只允许一条**。
class _PluginLlmStream {
  _PluginLlmStream({
    required this.requestId,
    required this.pluginId,
    required this.station,
    required this.controller,
  });

  final String requestId;
  final String pluginId;
  final RelayStation station;
  final StreamController<LlmStreamEvent> controller;

  /// 收尾守护定时器（取消信号 + 订阅者心跳判活）。
  Timer? timer;

  /// 是否已被取消（取消后到达的增量一律丢弃，见 `_handleStationStream`）。
  bool cancelled = false;

  /// 是否已收尾（幂等标记）。
  bool finished = false;

  void add(LlmStreamEvent event) {
    if (finished || controller.isClosed) return;
    controller.add(event);
  }

  /// 收尾（幂等）：[failure] 非空时先吐一条失败事件再关闭。
  void finish({String failure = '', bool cancelled = false}) {
    if (finished) return;
    finished = true;
    if (cancelled) this.cancelled = true;
    timer?.cancel();
    if (controller.isClosed) return;
    if (failure.isNotEmpty) {
      controller.add(LlmFailureEvent(failure, cancelled: cancelled));
    }
    controller.close();
  }

  /// 直接作废（同一 request_id 被新流顶掉时用）。
  void fail(String reason) => finish(failure: reason);
}

/// `plugin.*` 六条命令的**对外面**（20261015-hot-restart 阶段 1，D9/D2）。
///
/// 为什么要把这个划分写成常量而不是“等做 tool 的时候再说”：`plugin.stateDump` /
/// `plugin.stateFetch` 是**生命周期原语**——它们该不该被模型使唤，答案不能取决于
/// 下一个写 tool 的人忘了还是没忘。写在这里，阶段 3 的自迭代插件只能照这个表申报。
///
/// - [agentToolCommands]：控制面。人可以叫 agent 去“重启那个插件”“看看插件列表”，
///   这些动作有完整的业务含义，也能以可读结果收尾；
/// - [lifecycleOnlyCommands]：**只能由插件自己下**。它们的操作对象是“我这个进程的
///   那一份人生”，模型没有资格代它发言：一次错路的 stateDump 会把插件的内部状态
///   抓到一个它不该抓的名字上，而一次错路的 stateFetch 会把已消费的快照抽干。
abstract final class PluginToolSurface {
  /// 可以被申报成 agent tool 的 `plugin.*` 命令。
  static const Set<String> agentToolCommands = <String>{
    'plugin.list',
    'plugin.restart',
    'plugin.suspend',
    'plugin.state',
  };

  /// **不得**被申报成 agent tool 的命令（插件生命周期原语，D9）。
  static const Set<String> lifecycleOnlyCommands = <String>{
    'plugin.stateDump',
    'plugin.stateFetch',
  };

  /// 需要**留审计行**的命令：就是控制面那四条。
  ///
  /// 快照两条不审计是有意的：它们是插件自己续跑的内部动作（每一世都会下一次），
  /// 把它们记进审计只会把日志刷满，而它们证明不了“动了别人的东西”——本来就动不了
  /// （`_pluginCommand` 那里已经钉住了“只能是自己的键”）。
  static const Set<String> auditedCommands = agentToolCommands;
}

/// 一次**热重启**的结论（每条都带可读结果，不“看起来成功了”）。
///
/// 为什么单独一个类型而不是 `bool`：[PluginBus.hotRestart] 有三种截然不同的结局，
/// 而面板与 agent tool 必须把它们分开说：
/// - `ok=true, resumed=true`：真的带着快照换了一世；
/// - `ok=true, resumed=false`：换了一世，但**按冷启动**（没声明 suspension /
///   没递快照 / ack 丢了）——对用户这是“重启成功但状态没续上”，不是失败；
/// - `ok=false`：新一世没起来（按失败隔离处理，不牵连其它插件）。
class PluginHotRestartResult {
  const PluginHotRestartResult({
    required this.pluginId,
    required this.ok,
    this.resumed = false,
    this.dumpId = '',
    this.generation = 0,
    this.lifecycle = 'stopped',
    this.reason = '',
  });

  final String pluginId;

  /// 新一世是否就绪。
  final bool ok;

  /// 是否真的拿到了可续跑快照（= 下一世能取回它）。
  final bool resumed;

  /// 入池的快照 id（空 = 无快照）。
  final String dumpId;

  /// 重启后的**代际**。
  final int generation;

  /// 重启后的生命周期（`ready` / `failed`……）。
  final String lifecycle;

  /// 可读结论（含降级原因）。
  final String reason;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'plugin_id': pluginId,
    'resumed': resumed,
    'dump_id': dumpId,
    'generation': generation,
    'lifecycle': lifecycle,
    'reason': reason,
  };
}

/// 对账里**单个插件**的结论：做了什么（[kind]）+ 对谁（[pluginId]）+ 为什么（[reason]）。
class PluginReconcileAction {
  const PluginReconcileAction({
    required this.kind,
    required this.pluginId,
    required this.reason,
  });

  final PluginReconcileKind kind;
  final String pluginId;

  /// 可读原因（日志 / 热应用 detail 直接用；失败时就是"为什么没起来"）。
  final String reason;

  /// 一句话形式。
  String describe() => '$pluginId：$reason';
}

/// 对账动作的种类（[PluginBus.applyConfigs] 的五种结论）。
enum PluginReconcileKind {
  /// 文件里新增 / 本来没跑：按配置拉起来了。
  started,

  /// 按配置断开了（enabled=false，或条目已被删除）。
  stopped,

  /// 启动参数变了：断开后用新参数重新拉起。
  restarted,

  /// 配置与运行态已经一致，**没有**动它（尤其：启动参数没变 ⇒ 不重启）。
  unchanged,

  /// 这次没能就绪（可读原因在 [PluginReconcileAction.reason]）。
  failed;

  /// 中文名（日志 / 回报）。
  String get label => switch (this) {
    PluginReconcileKind.started => '启动',
    PluginReconcileKind.stopped => '停用',
    PluginReconcileKind.restarted => '重启',
    PluginReconcileKind.unchanged => '未变',
    PluginReconcileKind.failed => '失败',
  };
}

/// 一次**配置对账**的结论（[PluginBus.applyConfigs]）。
///
/// 分五类而不是一个 bool：调用方（热应用接缝 / 日志 / 测试）要能回答"这个插件这次
/// 到底被怎么处理了"，而不是只知道"整体成功或失败"。
class PluginReconcileResult {
  const PluginReconcileResult({
    this.started = const <PluginReconcileAction>[],
    this.stopped = const <PluginReconcileAction>[],
    this.restarted = const <PluginReconcileAction>[],
    this.unchanged = const <PluginReconcileAction>[],
    this.failed = const <PluginReconcileAction>[],
    this.totalEnabled = true,
    this.error = '',
  });

  final List<PluginReconcileAction> started;
  final List<PluginReconcileAction> stopped;
  final List<PluginReconcileAction> restarted;
  final List<PluginReconcileAction> unchanged;
  final List<PluginReconcileAction> failed;

  /// 对账时读到的插件系统总开关（false = 本次只断不启）。
  final bool totalEnabled;

  /// 读盘失败的可读原因（非空 = 本次没有对账，运行态与内存配置都保持原样）。
  final String error;

  /// 是否真的改动了运行态（新增 / 停用 / 重启任一非空）。
  bool get hasChanges =>
      started.isNotEmpty || stopped.isNotEmpty || restarted.isNotEmpty;

  /// 是否有插件没能就绪。
  bool get hasFailure => failed.isNotEmpty;

  /// 五类结论的平铺（遍历 / 查找用；顺序 = 启动 / 停用 / 重启 / 未变 / 失败）。
  List<PluginReconcileAction> get all => <PluginReconcileAction>[
    ...started,
    ...stopped,
    ...restarted,
    ...unchanged,
    ...failed,
  ];

  /// 某个插件这次的结论；本次没提到它 ⇒ null（例如"停用且没在跑的条目被删除"：
  /// 运行态与配置本来就一致，没有任何动作可做）。
  PluginReconcileAction? actionOf(String pluginId) {
    for (final PluginReconcileAction action in all) {
      if (action.pluginId == pluginId) return action;
    }
    return null;
  }

  /// 可读摘要（日志与热应用 detail 用）。
  String describe() {
    if (error.isNotEmpty) return '插件配置对账未执行：$error';
    final StringBuffer out = StringBuffer('插件配置对账');
    void segment(String label, List<PluginReconcileAction> items) {
      if (items.isEmpty) return;
      out.write('；$label ${items.length} 个：');
      out.write(items.map((PluginReconcileAction a) => a.describe()).join('、'));
    }

    segment('启动', started);
    segment('停用', stopped);
    segment('重启', restarted);
    segment('未变', unchanged);
    segment('失败', failed);
    if (!hasChanges && !hasFailure) out.write('：配置与运行态一致，无需变更');
    if (!totalEnabled) out.write('（插件系统总开关为关，未启动任何插件）');
    return out.toString();
  }
}

/// 一次「插件定义 tool」触发的回报（收集站部分结果 + 注册结果）。
class ToolDefinitionRefresh {
  const ToolDefinitionRefresh({
    this.stationIds = const <String>[],
    this.collected = const <StationCollectedItem>[],
    this.unresponsive = const <StationUnresponsive>[],
    this.skipped = const <String>[],
    this.registered = const <String>[],
    this.removed = const <String>[],
  });

  /// 本次触发涉及的收集站 id。
  final List<String> stationIds;

  /// 已收集到的合格产出。
  final List<StationCollectedItem> collected;

  /// 未响应者（**显式列出**，不静默、不阻塞、不整体失败）。
  final List<StationUnresponsive> unresponsive;

  /// 被跳过的条目（schema 之外的可读原因）。
  final List<String> skipped;

  /// 本轮注册进工具表的命名空间名。
  final List<String> registered;

  /// 本轮下线的命名空间名（插件没再申报的工具）。
  final List<String> removed;

  /// 注册条数。
  int get toolCount => registered.length;

  /// 是否全部订阅者都给了合格产出。
  bool get complete => unresponsive.isEmpty;

  /// 可读摘要（日志 / 工具层提示）。
  String describe() {
    final StringBuffer out = StringBuffer('插件工具定义：注册 ${registered.length} 个');
    if (removed.isNotEmpty) out.write('，下线 ${removed.length} 个');
    if (unresponsive.isNotEmpty) {
      out.write('；未响应 ${unresponsive.length} 个：');
      out.write(
        unresponsive
            .map((StationUnresponsive u) => '${u.pluginId}（${u.reason}）')
            .join('、'),
      );
    }
    for (final String reason in skipped) {
      out.write('；$reason');
    }
    return out.toString();
  }
}
