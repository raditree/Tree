import '../mcp/mcp_client.dart';
import '../mcp/mcp_service.dart';
import 'tool_runner.dart';

/// `mcp` 工具（M6a）：MCP 工具的发现入口与兜底调用路径。
///
/// 与参考实现一致的两层设计：
/// 1. 已连接服务的工具会以 `mcp__<服务>__<工具>` 的**原生工具**注入模型工具列表
///    （见 [dynamicSpecs]），模型可以直接调用；
/// 2. 本工具保留 `help`（列出可用 MCP 工具）与 `call`（按命名空间名调用）作为
///    发现入口与兜底。
abstract final class McpTool {
  static const String name = 'mcp';

  /// 是否由本工具处理（`mcp` 本身或任意命名空间工具名）。
  static bool handles(String toolName) =>
      toolName == name || parseNamespacedToolName(toolName) != null;

  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[MCP 工具] 查看与调用已注册的 MCP 服务工具。\n'
        'action=help：列出当前可用的 MCP 工具（形如 mcp__<服务名>__<工具名>）；'
        'action=call：按 tool_name + arguments 调用。已就绪的 MCP 工具通常也会直接'
        '出现在你的工具列表里，可直接调用，本工具是兜底与发现入口。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>['help', 'call'],
          'description': 'help 查看可用 MCP 工具；call 调用指定工具',
        },
        'tool_name': <String, dynamic>{
          'type': 'string',
          'description': '要调用的工具名（action=call 必填），形如 mcp__<服务>__<工具>',
        },
        'arguments': <String, dynamic>{
          'type': 'object',
          'description': '工具参数（action=call 用）',
        },
      },
      'required': <String>['action'],
    },
  );

  /// 已就绪 MCP 工具的原生声明（直接注入模型工具列表）。
  static List<ToolSpec> dynamicSpecs(McpService service) => <ToolSpec>[
    for (final ({String service, McpToolInfo tool}) entry in service.allTools())
      ToolSpec(
        name: namespacedToolName(entry.service, entry.tool.name),
        description:
            '[MCP ${entry.service}] ${entry.tool.description.isEmpty ? entry.tool.name : entry.tool.description}',
        parameters: entry.tool.inputSchema,
      ),
  ];

  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    McpService service,
  ) async {
    if (invocation.name != name) {
      final McpCallResult result = await service.callTool(
        invocation.name,
        invocation.arguments,
      );
      return ToolOutcome(
        result.text.isEmpty ? '（MCP 工具没有返回内容）' : result.text,
        isError: result.isError,
      );
    }
    final String action = (invocation.arguments['action'] ?? '')
        .toString()
        .trim();
    switch (action) {
      case 'help':
        await service.refresh();
        final List<({String service, McpToolInfo tool})> tools = service
            .allTools();
        if (tools.isEmpty) {
          final List<String> configured = service
              .servers()
              .map((McpServerConfig s) => s.name)
              .toList();
          return ToolOutcome(
            '当前没有可用的 MCP 工具'
            '（已配置服务：${configured.isEmpty ? '无' : configured.join('、')}）。'
            '可在右栏「MCP 配置」页注册服务，或在 <数据根>/config/mcp.yaml 手写。',
          );
        }
        final List<String> lines = <String>['可用 MCP 工具列表:'];
        for (final ({String service, McpToolInfo tool}) entry in tools) {
          final String toolName = namespacedToolName(
            entry.service,
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
        final McpCallResult result = await service.callTool(toolName, args);
        return ToolOutcome(
          result.text.isEmpty ? '（MCP 工具没有返回内容）' : result.text,
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
