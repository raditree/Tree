/// 插件 ↔ 核心 JSON-RPC **方法名**的常量家。
///
/// **为什么需要这个文件**（不变量 7 在插件协议这一层的落点）：
/// architecture.md §13 的不变量 7 写的是「协议常量只从 `tree_protocol` 取」，
/// 但插件协议长期**没有**这个家——方法名曾是散在两侧的字面量：核心侧
/// `switch` 直接写 `case 'station/command':`，`'method': 'shutdown'` 硬写在
/// `plugin_host.dart`，插件侧自己再抄一份 `PluginMethods`。这类漂移只在真机上暴露
/// （与不变量 13 对 `tree_tunnel_protocol` 的理由完全同构）。
///
/// **本包不许依赖任何 IO 或平台代码**（纯 Dart，见 `tree_protocol` 的包注释）：
/// 这里只放常量与集合，不放编解码、不放客户端。
///
/// 方向划分是**语义**的，不是装饰：
/// - [coreToPlugin] 的方法由核心**发出**，插件必须实现；
/// - [pluginToCoreRequests] 由插件**发起**、核心必须应答（未知 ⇒ `-32601`，不静默）；
/// - [pluginToCoreNotifications] 由插件**推流**、核心不等应答。
/// 新增方法前先问「它属于哪一面」——放错集合，门禁的方向断言就会失真。
abstract final class PluginRpcMethods {
  // ── 核心 → 插件（下行）──────────────────────────────────────────────

  /// 握手（进程起好后第一件事）。
  static const String hello = 'hello';

  /// 拉取插件工具表（握手后与工具表刷新点都会再来）。
  static const String toolsList = 'tools/list';

  /// 调用插件工具。
  static const String toolsCall = 'tools/call';

  /// 心跳探测：每 `heartbeat_interval` 一次，核心只看"这一拍回了没"。
  static const String ping = 'ping';

  /// 站点请求（订阅者接管一次交互）；流式接管靠 `station/stream` 喂数据。
  static const String stationRequest = 'station/request';

  /// 流式回填的中断信号（通知，不等应答）。
  static const String stationCancel = 'station/cancel';

  /// 总线事件推送（通知）。
  ///
  /// **双向同名**：插件也可以往核心推一条 `event` 通知（见 docs/plugin-development.md
  /// 的插件主动通知）。两侧的历史命名撞在一起，改任何一侧都是破坏兼容，
  /// 因此本表**只列一次**，方向由它出现在哪条通道里决定。
  static const String event = 'event';

  /// 优雅退出通知（通知）。
  ///
  /// **它不是超时**：发出后核心只等"进程真的退出"，不等时长（见
  /// `plugin_host.dart` 的 `close()` 与 `docs/architecture.md` §13 不变量 4）。
  static const String shutdown = 'shutdown';

  /// **优雅挂起**（20261015-hot-restart 阶段 1 新增；本任务唯一新增的 method）。
  ///
  /// 语义：核心请求插件"把可续跑状态转储出来然后退出"。插件回 `{ok: true}` 即
  /// 表示它**接下来会**下 `station/command` 的 `plugin.stateDump`；回错误或不认
  /// 这一条（老插件）⇒ 核心按"不可挂起"处理，走冷启动重启（向后兼容，D3）。
  ///
  /// 为什么方向决定了它必须是 method 而不是站点命令：这是**核心主动下发**给
  /// 特定插件的一问一答，插件无法用它自己订阅的点位表达"核心在问我"。
  /// 反过来，转储与取回是插件主动递送，因此走已有的 `station/command`
  /// （D10：A+B 混合，核心侧那 6 个 `case` 一字不改）。
  static const String suspend = 'suspend';

  // ── 插件 → 核心（上行请求，必须应答）────────────────────────────────

  /// 下执行站命令（命令名与白名单见 `station_points.dart`）。
  static const String stationCommand = 'station/command';

  /// 订阅内置站点或自建站站点。
  static const String stationSubscribe = 'station/subscribe';

  /// 退订。
  static const String stationUnsubscribe = 'station/unsubscribe';

  /// 注册插件自建站。
  static const String stationRegister = 'station/register';

  /// 注销自建站。
  static const String stationUnregister = 'station/unregister';

  /// 跨插件触发别人的自建站。
  static const String stationTrigger = 'station/trigger';

  // ── 插件 → 核心（上行通知，不等应答）────────────────────────────────

  /// 流式回填的数据面（`request_id` 用**请求 params 里的那个**，不是 JSON-RPC 报文 id）。
  static const String stationStream = 'station/stream';

  /// 插件自报日志（核心不按名字分支，原样转成前端 `plugin_event`）。
  static const String log = 'log';

  // ── 集合与派生读数 ──────────────────────────────────────────────────

  /// 核心 → 插件的全部方法。
  static const Set<String> coreToPlugin = <String>{
    hello,
    toolsList,
    toolsCall,
    ping,
    stationRequest,
    stationCancel,
    event,
    shutdown,
    suspend,
  };

  /// 插件 → 核心的请求（核心必须逐一应答）。
  static const Set<String> pluginToCoreRequests = <String>{
    stationCommand,
    stationSubscribe,
    stationUnsubscribe,
    stationRegister,
    stationUnregister,
    stationTrigger,
  };

  /// 插件 → 核心的通知（不等应答）。
  ///
  /// ⚠ 口径：**只有 [stationStream] 在核心里按名字分流**（进流式回填的数据面）；
  /// [log] 是**约定名**——核心不认它，而是把整条通知原样转成前端 `plugin_event`
  /// （见 `PluginBus._emitPluginEvent` 与 `PluginHost.notifications`）。把它列在本表里
  /// 是为了让门禁能识别它为已登记的协议名，而不是误报成飘的字面量。
  /// （插件也可以推 `event` 通知，那个名字已在 [event] 里登记，不重复列。）
  static const Set<String> pluginToCoreNotifications = <String>{
    stationStream,
    log,
  };

  /// 全部方法名（门禁用例据此判定"字面量是否已登记"）。
  ///
  /// 三个方向集合**不得有重叠**（否则 const 集合会在此报冲突），
  /// `plugin_rpc_method_gate_test.dart` 因此直接钉总数关系。
  static const Set<String> all = <String>{
    ...coreToPlugin,
    ...pluginToCoreRequests,
    ...pluginToCoreNotifications,
  };

  /// **20261015-hot-restart 之前的基线**（= [all] 去掉 `suspend`）。
  ///
  /// 为什么把基线写成常量：门禁要断言的是「协议面**只允许**按登记的增量长」，
  /// 而不是"看起来方法数差不多"。下一次正式扩协议时，把当时的 `all` 快照成新的
  /// 基线，并同步改 `plugin_rpc_method_gate_test.dart` 的期望计数。
  static const Set<String> baselineBeforeHotRestart = <String>{
    hello,
    toolsList,
    toolsCall,
    ping,
    stationRequest,
    stationCancel,
    event,
    shutdown,
    stationCommand,
    stationSubscribe,
    stationUnsubscribe,
    stationRegister,
    stationUnregister,
    stationTrigger,
    stationStream,
    log,
  };

  /// 相对 [baselineBeforeHotRestart] 的新增方法（门禁据此断言"本任务只加了 1 个"）。
  static Set<String> addedSinceBaseline() =>
      all.difference(baselineBeforeHotRestart);
}

/// 扫描到的**不属于插件协议**的方法名字面量的登记表（键 = 字面量，值 = 原因）。
///
/// 形状照 `nonProtocolTypeLiterals`：登记必须写原因，否则等于没门禁。
/// 这些字面量合法地存在于被扫描的源码里，但它们是**别的协议**，
/// 不该被塞进 [PluginRpcMethods]（那会让不变量 7 与 13 的边界糊掉）。
const Map<String, String> nonProtocolPluginMethodLiterals = <String, String>{
  // SSH 中转站协议（核心 ⇄ 插件 ⇄ 目标机 tree_agent）：方法名的家另在
  // tree_tunnel_protocol（不变量 13），不与本包共用一个常量表。
  'tunnel.ensure': '属于 tree_tunnel_protocol（不变量 13），非插件↔核心 JSON-RPC 面',
  'tunnel.request': '同上',
  'tunnel.state': '同上',
  'tunnel.close': '同上',
  'tunnel.event': '同上',
  // 目标机执行体自己的 stdio 协议（tree_agent 收的一侧），同样归 tree_tunnel_protocol。
  'agent.ping': '目标机 tree_agent 的 stdio 协议，归 tree_tunnel_protocol',
  'agent.start': '同上',
  'agent.read': '同上',
  'agent.write': '同上',
  'agent.exec': '同上',
  'agent.shell': '同上',
  // 插件 UI 帧的 method（约定名）：家在本包 PluginUiFrameType，不在 PluginRpcMethods。
  'ui/manifest': '插件 UI 声明帧，归 PluginUiFrameType',
  'ui/update': '同上',
};
