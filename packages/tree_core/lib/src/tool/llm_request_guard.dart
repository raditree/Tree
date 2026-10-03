import '../llm/llm_session.dart';
import 'tool_run_registry.dart';

/// 把「运行中的 LLM 请求」登记进 [ToolRunRegistry] 的**现成实现**
/// （`LlmRequestRegistrar` 的生产落点；行为口径见 `LlmSession._watchRequest`）。
///
/// 为什么单独一个文件、而不是写在 `llm_session.dart` 里：**会话层不认识工具登记表**
/// （层间不互相依赖），由核心接线层把两者缝合起来——与 `ToolResultRepair` /
/// `ToolResultProbe` 同一个注入范式。
///
/// 语义约定（与工具那套完全一致，用户 2026-10-03 定夺）：
/// - 只有**连续沉默**（零事件）达到阈值时才会被登记 ⇒ 正常的长生成不进表、不 warning；
/// - 登记后**可被显式关闭**（右栏 / 插件 `tool.close` / agent `tool_runs action=close`）；
/// - `closed` 的判据是"这一项已从表里消失"——`close` 会移除它，**绝不自动关闭**。
LlmRequestRegistrar llmRequestRegistrarOf(
  ToolRunRegistry registry, {
  String tool = 'llm.request',
}) {
  return ({
    required String agentId,
    required String sessionId,
    required String model,
    required int turn,
  }) {
    final ToolRun run = registry.start(
      tool: tool,
      arguments: <String, dynamic>{'model': model, 'turn': turn},
      agentId: agentId,
      sessionId: sessionId,
    );
    return _RegistryRequestGuard(registry, run);
  };
}

/// 登记表里那一项 → `LlmRequestGuard` 的适配（`closed` = 已从表里消失）。
class _RegistryRequestGuard implements LlmRequestGuard {
  _RegistryRequestGuard(this._registry, this._run);

  final ToolRunRegistry _registry;
  final ToolRun _run;

  @override
  String get handle => _run.handle;

  @override
  bool get closed =>
      !_registry.list().any((ToolRun r) => r.handle == _run.handle);

  @override
  void finish() => _registry.finish(_run);
}
