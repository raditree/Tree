/// 插件定义 tool（M9 §3 收集站的**首个接入点**）。
///
/// 数据流（用户定稿）：
///   station(tool.define) --（schema + 可选附带信息）--> 所有订阅插件
///     --目标数据：工具定义（名称 / 描述 / 参数 schema / 执行方式）--> 站点
///     --> 触发方（**工具表刷新处**）注册成动态工具
///
/// - 「触发时机」不写死在站点里：由调用 refresh 的那段逻辑决定（本仓库里是
///   PluginBus 的插件启动 / 显式刷新点）；
/// - 调用时**按来源 plugin_id 路由**到声明它的插件执行（PluginToolDefinition.pluginId
///   是唯一依据，工具名只是展示与寻址用的命名空间）；
/// - 站点内部不做管线：收集结果是返回值，注册进工具表是触发方的后续处理。
library;

import 'plugin_host.dart';
import 'station_scope.dart';

/// 一条插件工具定义（收集站 schema 的 Dart 侧形状）。
class PluginToolDefinition {
  const PluginToolDefinition({
    required this.pluginId,
    required this.toolName,
    required this.description,
    required this.parameters,
    this.executionMethod = executionMethodToolCall,
    this.executionName = '',
    this.scope = const StationScope(),
  });

  /// 执行方式：经插件宿主的 tools/call 调用（当前唯一支持的方式）。
  static const String executionMethodToolCall = 'tools/call';

  /// 支持的执行方式集合。
  static const Set<String> supportedExecutionMethods = <String>{
    executionMethodToolCall,
  };

  /// **来源插件 id**（按来源路由的唯一依据）。
  final String pluginId;

  /// 插件内唯一的工具名。
  final String toolName;

  /// 工具描述（原样进模型工具表）。
  final String description;

  /// 参数定义（JSON Schema 形状）。
  final Map<String, dynamic> parameters;

  /// 执行方式。
  final String executionMethod;

  /// 插件侧实际工具名（空 = 用 [toolName]）。
  final String executionName;

  /// 申报时的 scope（team×mode 归属；隔离留痕与前端过滤用）。
  final StationScope scope;

  /// 注册到工具表后的命名空间名：plugin__插件id__工具名。
  String get namespacedName => namespacedPluginTool(pluginId, toolName);

  /// 实际调用插件时使用的工具名。
  String get resolvedExecutionName =>
      executionName.isEmpty ? toolName : executionName;

  /// 转成既有插件工具信息（工具层沿用 [PluginToolInfo] 的形状）。
  PluginToolInfo toToolInfo() => PluginToolInfo(
    name: toolName,
    description: description,
    inputSchema: parameters,
  );

  /// 序列化（快照 / 调试）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'plugin_id': pluginId,
    'tool_name': toolName,
    'description': description,
    'parameters': parameters,
    'execution': <String, dynamic>{
      'method': executionMethod,
      'name': resolvedExecutionName,
    },
    'scope': scope.toJson(),
  };

  /// 从收集站产出解析一条（schema 已校验；这里仍做防御性归一并给出可读错误）。
  ///
  /// 返回 null 时通过 [onError] 给出可读原因（调用方据此回报"该订阅者的哪条被丢"）。
  static PluginToolDefinition? tryParse({
    required String pluginId,
    required StationScope scope,
    required Object? payload,
    void Function(String error)? onError,
  }) {
    if (payload is! Map) {
      onError?.call('工具定义不是对象（键值映射）');
      return null;
    }
    final String toolName = (payload['tool_name'] ?? '').toString().trim();
    if (toolName.isEmpty) {
      onError?.call('工具定义缺少 tool_name');
      return null;
    }
    final String description = (payload['description'] ?? '').toString();
    final Object? rawParameters = payload['parameters'];
    final Map<String, dynamic> parameters = rawParameters is Map
        ? rawParameters.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{},
          };
    String method = executionMethodToolCall;
    String executionName = '';
    final Object? rawExecution = payload['execution'];
    if (rawExecution is Map) {
      final String declared = (rawExecution['method'] ?? '').toString().trim();
      if (declared.isNotEmpty) method = declared;
      executionName = (rawExecution['name'] ?? '').toString().trim();
    }
    if (!supportedExecutionMethods.contains(method)) {
      final String allowed = supportedExecutionMethods.join('、');
      onError?.call('工具 $toolName 的执行方式 $method 不支持（支持：$allowed）');
      return null;
    }
    return PluginToolDefinition(
      pluginId: pluginId,
      toolName: toolName,
      description: description,
      parameters: parameters,
      executionMethod: method,
      executionName: executionName,
      scope: scope,
    );
  }
}

/// 动态工具表（**触发方**在「工具表刷新处」用它注册收集到的定义）。
///
/// 单条路由依据 = 来源 plugin_id + 执行名；命名空间名是唯一键，
/// 同名工具由**后刷新者**覆盖（显式、可预期），不静默丢弃。
class PluginToolDefinitionTable {
  final Map<String, PluginToolDefinition> _byNamespaced =
      <String, PluginToolDefinition>{};

  /// 全量替换某插件的定义（该插件本轮没申报的工具视为已下线）。
  ///
  /// 返回被移除的命名空间名（调用方可据此提示"工具消失"）。
  List<String> replacePlugin(
    String pluginId,
    Iterable<PluginToolDefinition> definitions,
  ) {
    final List<String> removed = <String>[];
    _byNamespaced.removeWhere((String name, PluginToolDefinition def) {
      if (def.pluginId != pluginId) return false;
      removed.add(name);
      return true;
    });
    for (final PluginToolDefinition definition in definitions) {
      _byNamespaced[definition.namespacedName] = definition;
    }
    return removed;
  }

  /// 注册一条（同名覆盖）。
  void put(PluginToolDefinition definition) {
    _byNamespaced[definition.namespacedName] = definition;
  }

  /// 注销一个插件的全部定义；返回移除数。
  int removePlugin(String pluginId) {
    final int before = _byNamespaced.length;
    _byNamespaced.removeWhere(
      (String _, PluginToolDefinition def) => def.pluginId == pluginId,
    );
    return before - _byNamespaced.length;
  }

  /// 清空（测试 / 关停）。
  void clear() => _byNamespaced.clear();

  /// 全部定义（按命名空间名字典序，输出稳定）。
  List<PluginToolDefinition> definitions() {
    final List<PluginToolDefinition> list = _byNamespaced.values.toList();
    list.sort(
      (PluginToolDefinition a, PluginToolDefinition b) =>
          a.namespacedName.compareTo(b.namespacedName),
    );
    return list;
  }

  /// 按命名空间名取定义（**调用路由**用）。
  PluginToolDefinition? byNamespacedName(String name) => _byNamespaced[name];

  /// 按插件分组（快照 / 既有 tools 视图用）。
  Map<String, List<PluginToolInfo>> toolsByPlugin() {
    final Map<String, List<PluginToolInfo>> out =
        <String, List<PluginToolInfo>>{};
    for (final PluginToolDefinition definition in definitions()) {
      out
          .putIfAbsent(definition.pluginId, () => <PluginToolInfo>[])
          .add(definition.toToolInfo());
    }
    return out;
  }

  /// 当前定义条数。
  int get length => _byNamespaced.length;
}
