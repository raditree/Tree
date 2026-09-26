import '../plugin/plugin_bus.dart';
import '../plugin/plugin_host.dart';
import 'tool_runner.dart';

/// `plugin` 工具（M6b）：插件工具的发现入口与兜底调用路径。
///
/// 与 MCP 完全同构的两层设计：已启动插件的工具以 `plugin__<插件id>__<工具名>`
/// 的原生工具注入模型工具列表；`plugin` 提供 `help`（列出可用插件工具）与
/// `call`（按命名空间名调用）作为发现与兜底。
abstract final class PluginTool {
  static const String name = 'plugin';

  /// 是否由本工具处理（`plugin` 本身或任意插件命名空间工具名）。
  static bool handles(String toolName) =>
      toolName == name || parseNamespacedPluginTool(toolName) != null;

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
  static List<ToolSpec> dynamicSpecs(PluginBus bus) => <ToolSpec>[
    for (final ({String pluginId, PluginToolInfo tool}) entry in bus.allTools())
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
        final List<({String pluginId, PluginToolInfo tool})> tools = bus
            .allTools();
        if (tools.isEmpty) {
          final List<String> configured = bus
              .configs()
              .map((PluginConfig c) => c.id)
              .toList();
          return ToolOutcome(
            '当前没有可用的插件工具'
            '（已配置插件：${configured.isEmpty ? '无' : configured.join('、')}）。'
            '可在 <数据根>/config/plugins.yaml 配置插件后重启核心。',
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
