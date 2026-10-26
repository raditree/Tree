import 'station_instance.dart';
import 'station_points.dart';
import 'station_runtime.dart';

/// `plugin.*` 族的**统一入口**（插件热重启控制面 + 执行器挂载/工具转发）：由
/// `PluginBus` 实现。
///
/// 覆盖命令：`plugin.list` / `plugin.restart` / `plugin.suspend` / `plugin.state`
/// / `plugin.stateDump` / `plugin.stateFetch` / `plugin.toolCall` / `plugin.mount`。
/// 这一族的实现只能是 `PluginBus`：插件实例表、generation 计数、快照内存池都在它
/// 那里，挂载位置层因此不拿任何插件状态、只负责**归属校验 + 分派**。
///
/// [pluginId] 是**已在本层归一化过**的目标插件 id（快照两条 = 发起者自己的 id）；
/// [sourcePluginId] 是下达这条命令的插件 id（空 = 核心自己下的）——实现方据此
/// 钉住「插件只能动自己的快照」；[arguments] 是原始参数（原样透传，不预先消化）。
///
/// 返回值约定与其它槽一致：`{ok: true, ...结论}` 或 `{ok: false, error: 可读中文}`。
/// **不做静默降级**：没接线时本层直接以「未接线」失败（口径见类注释）。
typedef StationPluginManager = Future<Map<String, dynamic>> Function({
  required String command,
  required String pluginId,
  required String sourcePluginId,
  Map<String, dynamic>? arguments,
});

/// `station.*` 族的**统一入口**：由 `PluginBus` 实现。
///
/// 这一族的实现只能是总线：站点实例表、订阅者、公告板与计数都在它那里，挂载位置层
/// 因此**不拿任何站点状态**，只负责「能不能证明发起者属于这个 team」这一道闸门。
///
/// [teamId] 是**已经在这里证明过**的发起者 team（空串到不了实现）；`station.state`
/// 的目标写在 [arguments] 的 `station_id`（也接受订阅时那套 `point` 别名）。
typedef StationTopologyQuery = Future<Map<String, dynamic>> Function({
  required String command,
  required String teamId,
  Map<String, dynamic>? arguments,
  String sourcePluginId,
});

/// 执行站命令的挂载位置集中，**只挂平台面命令**。
///
/// A5（2026-10-25）起核心不再实现任何领域执行语义：`fs.*` / `terminal.*` /
/// `agent.*` / `llm.call` / `tool.*` / `session.rename` / `ssh.reconnect` /
/// `usage.query` 由 `local_executor` / `ssh_executor` / `tree.agent` 等插件在
/// 自己的执行站上自建；核心留下的只有两族**平台面**命令：
///
/// - `plugin.*`：插件热重启控制面 + 执行器挂载 + 工具/快照转发；
/// - `station.*`：站点拓扑只读查询。
///
/// 依赖没接线时**不做静默降级**：命令以「未接线」的可读原因失败。
class ExecuteStationMounts {
  ExecuteStationMounts({this.pluginManager, this.topologyQuery, this.log});

  /// 挂载位置 id 前缀（每个命令一个 id：`core.execute.plugin.list` …）。
  static const String mountIdPrefix = 'core.execute';

  /// `plugin.*` 族入口；null = 这些命令显式报「未接线」。
  final StationPluginManager? pluginManager;

  /// `station.*` 族（站点拓扑，只读）入口；null = 这些命令显式报「未接线」。
  final StationTopologyQuery? topologyQuery;

  final void Function(String message)? log;

  /// 把本点位拥有的命令挂到该执行站；返回 null = 全部成功，否则是可读原因（不静默）。
  ///
  /// 幂等：同 mountId + 同命令会被站点替换（重复调用不会叠加挂载项）。
  /// **点位化**：执行站按命令族拆成多个实例，所以这里只挂 `station.commands`
  /// （点位表给出的白名单子集）——给一个点位挂上不属于它的命令会被站点自己拒绝。
  String? mountInto(ExecuteStation station) {
    final List<String> failed = <String>[];
    for (final String command in station.commands) {
      final String? error = station.mount(
        command: command,
        mountId: '$mountIdPrefix.$command',
        handler: _handle,
      );
      if (error != null) failed.add(error);
    }
    if (failed.isEmpty) return null;
    return failed.join('；');
  }

  /// 挂载位置自身没有需要释放的资源（A5 起不再持有 TerminalHooks / PTY）。
  Future<void> close() async {}

  // ── 命令分发 ─────────────────────────────────────────────────────────

  Future<StationCommandOutcome> _handle(StationCommandContext context) async {
    final String command = context.command;
    // 白名单复核（站点已校验过一次；挂载位置不假设调用方一定校验过）
    if (StationPoints.ownerOfCommand(command) == null) {
      return StationCommandOutcome.failed(
        '命令 $command 不在执行站命令白名单内，拒绝执行（挂载位置复核）',
      );
    }
    // **插件族不靠 agent 工作空间归属证明身份**，闸门是「发起者是谁的快照」与
    // 「能不能证明 team」（见 [_pluginCommand]）。
    if (command.startsWith('plugin.')) {
      try {
        return await _pluginCommand(context, command);
      } catch (error) {
        return StationCommandOutcome.failed('命令 $command 执行异常：$error');
      }
    }
    // `station.*` 也不靠 agent 工作空间归属证明身份（看站点拓扑本来就没有目标
    // agent），闸门同样只有「能不能证明 team」（见 [_stationCommand]）。
    if (command.startsWith('station.')) {
      try {
        return await _stationCommand(context, command);
      } catch (error) {
        return StationCommandOutcome.failed('命令 $command 执行异常：$error');
      }
    }
    // A5：领域执行命令已随核心领域目录一起移除，由插件自建执行站承接。
    return StationCommandOutcome.failed(
      '命令 $command 已不在核心平台面（A5 起由 local_executor / ssh_executor / '
      'tree.agent 等插件自建执行站承接）',
    );
  }

  /// `plugin.*` 族的归属闸门与分派（插件热重启控制面 + 执行器挂载/工具转发）。
  ///
  /// 两条不同的归属口径，刻意不合并成一条（合并就会一边假严、一边真松）：
  /// - `plugin.stateDump` / `plugin.stateFetch`：**发起者必须是插件**，且只能对
  ///   **自己**的快照下命令（`plugin_id` 与发起者不一致直接拒绝）。它们的闸门是
  ///   「谁在说话」而不是「目标 agent 属于哪个 team」——快照本来就没有 agent；
  /// - 其余命令（list / restart / suspend / state / mount / toolCall）：控制别人的
  ///   插件必须有可证明的 team 归属，`scope.team_id` 为空 ⇒ fail-closed 拒绝。
  ///
  /// 本层**不碰插件实例表**：具体做什么全部交给 [pluginManager]（= `PluginBus`），
  /// 没接线时以「未接线」显式失败（不做静默降级）。
  Future<StationCommandOutcome> _pluginCommand(
    StationCommandContext context,
    String command,
  ) async {
    final StationPluginManager? manager = pluginManager;
    if (manager == null) {
      return StationCommandOutcome.failed(
        '命令 $command 尚无挂载实现（核心未给执行站注入插件管理器：未接线，'
        '不假装已经做过）',
      );
    }
    // plugin.toolCall：把调用原样转给目标插件的 tools/call。核心**不解析**
    // agent_id / team_id / mode_key / session_id：身份由发起方放在
    // arguments.scope 里（不透明载荷），这里只认 plugin_id 与 tool。
    if (command == 'plugin.toolCall') {
      final String target = _string(context.arguments['plugin_id']);
      if (target.isEmpty) {
        return const StationCommandOutcome.failed(
          'plugin.toolCall 需要 arguments.plugin_id（要调哪个插件）',
        );
      }
      if (_string(context.arguments['tool']).isEmpty) {
        return const StationCommandOutcome.failed(
          'plugin.toolCall 需要 arguments.tool（插件内的工具名）',
        );
      }
      final Map<String, dynamic> result = await manager(
        command: command,
        pluginId: target,
        sourcePluginId: context.sourcePluginId,
        arguments: context.arguments,
      );
      return _outcomeOf(result, command);
    }
    final String requested = _string(context.arguments['plugin_id']);
    final bool selfSnapshot =
        command == 'plugin.stateDump' || command == 'plugin.stateFetch';
    String target = requested;
    if (selfSnapshot) {
      final String source = context.sourcePluginId.trim();
      if (source.isEmpty) {
        return StationCommandOutcome.failed(
          '命令 $command 必须由插件身份下达（没有 source_plugin_id ⇒ 证明不了快照'
          '归谁）：拒绝执行（fail-closed）',
        );
      }
      if (requested.isNotEmpty && requested != source) {
        return StationCommandOutcome.failed(
          '插件 $source 不能对 $requested 下 $command：只能操作自己的快照'
          '（跨插件读写一律拒绝）',
        );
      }
      target = source;
    } else {
      if (context.scope.teamId.trim().isEmpty) {
        return StationCommandOutcome.failed(
          '命令 $command 的 scope 缺少 team_id：证明不了归属 ⇒ 拒绝执行'
          '（fail-closed）',
        );
      }
      // plugin.list 不带目标 id（它就是「看全部」），其余命令要指名插件
      if (target.isEmpty && command != 'plugin.list') {
        return StationCommandOutcome.failed(
          '命令 $command 需要 arguments.plugin_id（要动哪个插件）',
        );
      }
    }
    final Map<String, dynamic> result = await manager(
      command: command,
      pluginId: target,
      sourcePluginId: context.sourcePluginId,
      arguments: context.arguments,
    );
    return _outcomeOf(result, command);
  }

  /// `station.*` 族的归属闸门与分派（站点拓扑，**只读**）。
  ///
  /// 闸门只有一条：**team 必须证明得了**（与插件族控制面同形，但理由不同：那里问
  /// 的是“能不能动它”，这里问的是“能不能看见它”——插件自建站里写着别人的 topic
  /// 与配置）。具体可见性过滤在实现方（`PluginBus.handleStationQuery`）里做，
  /// 本层不复制那份规则（复制一次就会两头漂）。
  Future<StationCommandOutcome> _stationCommand(
    StationCommandContext context,
    String command,
  ) async {
    final StationTopologyQuery? query = topologyQuery;
    if (query == null) {
      return StationCommandOutcome.failed(
        '命令 $command 尚无挂载实现（核心未给执行站注入站点拓扑读口：未接线，'
        '不假装已经读过）',
      );
    }
    final String teamId = context.scope.teamId.trim();
    if (teamId.isEmpty) {
      return StationCommandOutcome.failed(
        '命令 $command 的 scope 缺少 team_id：证明不了归属 ⇒ 拒绝执行'
        '（fail-closed）',
      );
    }
    final Map<String, dynamic> result = await query(
      command: command,
      teamId: teamId,
      arguments: context.arguments,
      sourcePluginId: context.sourcePluginId,
    );
    return _outcomeOf(result, command);
  }

  /// 把槽返回的 `{ok, …}` 翻成站点结论（插件族与站点族**共用这一条**口径）。
  ///
  /// 原因的键有两套写法：本层惯例是 `error`，而热重启的结论带的是 `reason`
  /// （`PluginHotRestartResult.toJson`）。只读 error 会把“新一世没起来”这种最要紧
  /// 的失败说成“未给出原因”（不变量 6：失败必须可读）。
  static StationCommandOutcome _outcomeOf(
    Map<String, dynamic> result,
    String command,
  ) {
    final Object? ok = result['ok'];
    if (ok is bool && !ok) {
      final String error = _string(result['error']).isNotEmpty
          ? _string(result['error'])
          : _string(result['reason']);
      return StationCommandOutcome.failed(
        error.isEmpty ? '命令 $command 失败（未给出原因）' : error,
      );
    }
    return StationCommandOutcome.ok(result);
  }

  static String _string(Object? value) =>
      value == null ? '' : value.toString().trim();
}
