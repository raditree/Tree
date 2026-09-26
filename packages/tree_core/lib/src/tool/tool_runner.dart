/// 工具层与 LLM 层之间的契约。
///
/// 刻意**不引用 LLM 类型**：工具层只需要知道"工具有名字/说明/JSON Schema 参数"，
/// 由引擎在发请求时把它转成 `LlmToolSpec`。这样 M4 的真实工具实现（工作空间 IO
/// + 11 个内置工具）可以完全脱离 LLM 单测。
library;

/// 工具声明。
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    this.parameters = const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  });

  final String name;
  final String description;

  /// JSON Schema（Object）。
  final Map<String, dynamic> parameters;
}

/// 一次工具调用请求。
class ToolInvocation {
  const ToolInvocation({
    required this.id,
    required this.name,
    required this.arguments,
    required this.agentId,
    required this.sessionId,
    this.rawArguments = '',
  });

  /// 引擎生成的调用 id（用于 UI 卡片与取消）。
  final String id;

  /// 工具名。
  final String name;

  /// 已解析的参数（解析失败为空 Map，原始文本见 [rawArguments]）。
  final Map<String, dynamic> arguments;

  /// 模型给的原始参数文本（JSON 解析失败时用于回灌错误说明）。
  final String rawArguments;

  /// 归属的 agent / 会话（工作空间与权限按此解析）。
  final String agentId;
  final String sessionId;
}

/// 工具执行结果。
class ToolOutcome {
  const ToolOutcome(this.content, {this.isError = false});

  /// 回灌给模型的结果文本（Markdown 或纯文本均可）。
  final String content;

  /// 是否为错误结果（不影响消息格式，仅用于日志/UI 着色）。
  final bool isError;
}

/// 工具执行器。
abstract interface class ToolRunner {
  /// 本轮可用的工具声明（按 agent/会话可变，例如只有选中 Spec 时才挂 hook）。
  List<ToolSpec> specsFor({required String agentId, required String sessionId});

  /// 执行一次工具调用。
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  });
}

/// M3 的占位执行器：不声明任何工具。
///
/// 没有工具声明时模型不会请求工具，因此它只作为 `LlmSession` 的默认值存在；
/// 若模型仍然请求了工具（例如端点忽略 tools 字段），会回一条可读的错误结果，
/// 让工具循环正常收敛而不是卡死。
class EmptyToolRunner implements ToolRunner {
  const EmptyToolRunner();

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) => const <ToolSpec>[];

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async => const ToolOutcome('工具执行器尚未接入（M4）：无法执行该工具', isError: true);
}
