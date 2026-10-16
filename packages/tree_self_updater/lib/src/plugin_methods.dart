/// 本插件用到的**插件 ⇄ 核心**协议方法名（一张自带的小常量表）。
///
/// 为什么不引 `package:tree_protocol` 的 `PluginRpcMethods`（那张才是全局真源）：
/// 插件包必须保持**零核心依赖、零 Flutter 依赖**——它是随包分发的独立二进制，
/// 依赖树里一旦有核心包，交叉编译与体积都受影响，而"插件与核心同权不同栈"本身
/// 就是这套站点体系的前提。`tree_ssh_plugin` 出于同一约束也是自带一张表。
///
/// 漂移怎么防（这是关键，不是靠自觉）：[packages/tree_protocol 的插件协议门禁]
/// 会把本包列入扫描面，任何**未登记**的 method 字面量都会让它红。因此
/// 新增协议方法时的正确顺序是：先进 `PluginRpcMethods`（核心真源）⇒ 再在这里补一行。
abstract final class PluginMethods {
  // ── 核心 → 插件 ──────────────────────────────────────────────────────

  /// 握手。参数里可能带 `resume_dump_id`（有 ⇒ 上一世留过快照，去 `plugin.stateFetch` 取）。
  static const String hello = 'hello';

  /// 心跳：回了就算活着。**必须立即回**，慢活不许堵住它。
  static const String ping = 'ping';

  /// 要工具清单（`{tools: [{name, description, inputSchema}]}`）。
  static const String toolsList = 'tools/list';

  /// 调用工具：`{name, arguments, scope?}`；`scope` 是核心给的**本次调用身份**。
  static const String toolsCall = 'tools/call';

  /// 优雅退出（回完 ack 再收手）。
  static const String shutdown = 'shutdown';

  /// 热重启前的转储请求（只有配置里 `suspension: keep` 才会收到）。
  static const String suspend = 'suspend';

  // ── 插件 → 核心 ──────────────────────────────────────────────────────

  /// 核心把一次站点请求交给订阅者（本插件只关心收集站的采集请求）。
  static const String stationRequest = 'station/request';

  /// 下一条执行站命令（本插件的全部能力都走这一条：`plugin.*`）。
  static const String stationCommand = 'station/command';
}

/// 执行站 `plugin.*` 的命令名（与核心 `StationPoints` 的白名单同串）。
///
/// 这里只列**本插件会下**的那些：`stateDump` / `stateFetch` 也在内，因为热重启
/// 转储/取回必须自己下（它们是生命周期原语，见 `tool_surface.dart` 的红线）。
abstract final class PluginCommands {
  static const String list = 'plugin.list';
  static const String restart = 'plugin.restart';
  static const String suspend = 'plugin.suspend';
  static const String state = 'plugin.state';
  static const String stateDump = 'plugin.stateDump';
  static const String stateFetch = 'plugin.stateFetch';
}

/// 本插件在 `hello` 里自报的身份。
///
/// `pluginId` 与核心 `BuiltinPluginSpec(id: 'self_updater')` **必须同串**：
/// 工具的命名空间是 `plugin__<实例 id>__<工具名>`，两边不一致就会出现
/// 「模型看到的工具名」与「插件认识的 id」对不上（这种错只在运行时以"未知工具"暴露）。
abstract final class SelfUpdaterIdentity {
  static const String pluginId = 'self_updater';
  static const String name = '框架自迭代插件';

  /// 自报版本：**构建时由仓根 pubspec 注入**（`tool/build_self_updater.dart` 的
  /// `-DkSelfUpdaterVersion=...`）。没注入（开发态直接 `dart run`）则用这个兜底值。
  static const String version = String.fromEnvironment(
    'kSelfUpdaterVersion',
    defaultValue: '0.1.0',
  );
}
