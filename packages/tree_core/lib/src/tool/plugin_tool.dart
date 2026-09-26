import '../plugin/plugin_bus.dart';
import '../plugin/plugin_host.dart';
import '../plugin/station_runtime.dart';
import '../plugin/station_scope.dart';
import 'tool_runner.dart';

/// 「插件」工具（M6b + M9 Wave 3-F）：插件工具的发现入口与兜底调用路径。
///
/// 与 MCP 完全同构的两层设计：插件的工具以 plugin__<插件id>__<工具名> 的原生工具
/// 注入模型工具列表；plugin 提供 help（列出可用插件工具）与 call（按命名空间名调用）
/// 作为发现与兜底。
///
/// **M9：工具定义改由收集站收集**（station hub 的 plugin.tool.define）：
/// 插件按站点声明的 schema 申报工具定义 → 站点收集 → **触发方**（工具表刷新处，
/// 即 [refreshToolDefinitions] 的调用点）注册成动态工具；调用时按定义里的
/// **来源 plugin_id** 路由到该插件执行（见 PluginBus.callTool）。
/// 「触发时机」不写死在站点里：谁需要新工具表谁触发（本工具在 help 前也会触发一次）。
abstract final class PluginTool {
  static const String name = 'plugin';

  /// 是否由本工具处理（plugin 本身或任意插件命名空间工具名）。
  static bool handles(String toolName) =>
      toolName == name || parseNamespacedPluginTool(toolName) != null;

  /// **触发「插件定义 tool」收集站**：收集插件申报的工具定义并注册进工具表。
  ///
  /// 这就是「收集站的后续处理由触发方负责」里的触发方入口：调用点决定时机
  /// （插件启动后 / 工具表刷新处 / 用户在插件面板点刷新）。
  static Future<ToolDefinitionRefresh> refreshToolDefinitions(
    PluginBus bus, {
    StationScope? scope,
    StationScopeContext context = const StationScopeContext(),
  }) => bus.refreshToolDefinitions(scope: scope, context: context);

  /// **工具表刷新点**（同步）：取某个调用点（agent + 会话）的插件工具声明。
  ///
  /// 内部走 [PluginBus.toolTable]：**缓存 + 失效点**——工具表脏了才在后台补一次
  /// 收集站触发，本次仍返回手上这份，因此「每次工具调用都全量收集」不会发生。
  static List<ToolSpec> dynamicSpecsFor(
    PluginBus bus, {
    required String agentId,
    required String sessionId,
  }) {
    final StationScope scope = bus.runtimeScopeFor(
      agentId: agentId,
      sessionId: sessionId,
    );
    return dynamicSpecs(bus, scope: scope);
  }

  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[插件] 查看与调用已加载插件的工具。\n'
        'action=help：列出当前可用的插件工具（形如 plugin__<插件id>__<工具名>）；'
        'action=call：按 tool_name + arguments 调用。已就绪的插件工具通常也会直接'
        '出现在你的工具列表里，可直接调用，本工具是兜底与发现入口。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>['help', 'call'],
          'description': 'help 查看可用插件工具；call 调用指定工具',
        },
        'tool_name': <String, dynamic>{
          'type': 'string',
          'description': '要调用的工具名（action=call 必填），形如 plugin__<插件id>__<工具名>',
        },
        'arguments': <String, dynamic>{
          'type': 'object',
          'description': '工具参数（action=call 用）',
        },
      },
      'required': <String>['action'],
    },
  );

  /// 已就绪插件工具的原生声明（直接注入模型工具列表）。
  ///
  /// 表内容来自动态工具表（收集站收集后注册）；这里只做形状转换，不重新收集。
  /// [scope] 非空时按站点四元组过滤（跨 team / 跨模式的插件工具不进这张表）。
  static List<ToolSpec> dynamicSpecs(
    PluginBus bus, {
    StationScope? scope,
  }) => <ToolSpec>[
    for (final ({String pluginId, PluginToolInfo tool}) entry in bus.toolTable(
      scope: scope,
    ))
      ToolSpec(
        name: namespacedPluginTool(entry.pluginId, entry.tool.name),
        description:
            '[插件 ${entry.pluginId}] ${entry.tool.description.isEmpty ? entry.tool.name : entry.tool.description}',
        parameters: entry.tool.inputSchema,
      ),
  ];

  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    PluginBus bus,
  ) async {
    if (invocation.name != name) {
      final PluginCallResult result = await bus.callTool(
        invocation.name,
        invocation.arguments,
      );
      return ToolOutcome(
        result.text.isEmpty ? '（插件工具没有返回内容）' : result.text,
        isError: result.isError,
      );
    }
    final String action = (invocation.arguments['action'] ?? '')
        .toString()
        .trim();
    switch (action) {
      case 'help':
        await bus.start();
        // 工具表刷新处：按**调用点四元组**触发一次收集，再列当前注册结果
        // （未响应者会显式列出；跨 team / 跨模式的插件工具不进这张表）
        final StationScope callScope = bus.runtimeScopeFor(
          agentId: invocation.agentId,
          sessionId: invocation.sessionId,
        );
        final ToolDefinitionRefresh refresh = await bus.refreshToolDefinitions(
          scope: callScope.teamId.isEmpty ? null : callScope,
          context: StationScopeContext(
            teamId: callScope.teamId,
            agentId: callScope.agentId,
            sessionId: callScope.sessionId,
            modeKey: callScope.modeKey,
          ),
        );
        final List<({String pluginId, PluginToolInfo tool})> tools = bus
            .toolTable(scope: callScope);
        if (tools.isEmpty) {
          final List<String> configured = bus
              .configs()
              .map((PluginConfig c) => c.id)
              .toList();
          return ToolOutcome(
            '当前没有可用的插件工具'
            '（已配置插件：${configured.isEmpty ? '无' : configured.join('、')}）。'
            '可在 <数据根>/config/plugins.yaml 配置插件后重启核心。'
            '${refresh.unresponsive.isEmpty ? '' : '；未响应：${refresh.describe()}'}',
          );
        }
        final List<String> lines = <String>['可用插件工具列表:'];
        for (final ({String pluginId, PluginToolInfo tool}) entry in tools) {
          final String toolName = namespacedPluginTool(
            entry.pluginId,
            entry.tool.name,
          );
          lines.add(
            entry.tool.description.isEmpty
                ? '- $toolName'
                : '- $toolName: ${entry.tool.description}',
          );
        }
        if (refresh.unresponsive.isNotEmpty) {
          lines.add('');
          lines.add('未响应的插件（心跳丢失 / 窗口内无回，不影响上面的工具）:');
          for (final StationUnresponsive item in refresh.unresponsive) {
            lines.add('- ${item.pluginId}: ${item.reason}');
          }
        }
        return ToolOutcome(lines.join('\n'));
      case 'call':
        final String toolName = (invocation.arguments['tool_name'] ?? '')
            .toString()
            .trim();
        if (toolName.isEmpty) {
          return const ToolOutcome(
            'action=call 时必须提供 tool_name',
            isError: true,
          );
        }
        final Object? raw = invocation.arguments['arguments'];
        final Map<String, dynamic> args = raw is Map<dynamic, dynamic>
            ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final PluginCallResult result = await bus.callTool(toolName, args);
        return ToolOutcome(
          result.text.isEmpty ? '（插件工具没有返回内容）' : result.text,
          isError: result.isError,
        );
      default:
        return const ToolOutcome(
          "未知的 action，支持 'help' 或 'call'",
          isError: true,
        );
    }
  }
}
