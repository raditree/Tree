/// agent 侧事件（插件生态的数据面，M9 追加）：事件名常量 + 发布器。
///
/// **为什么有这一层**（plan §2 Q8）：核心侧的工具轮次静态上限已经删除——"跑到多少轮"
/// 不再由核心写死，限制能力交给插件：插件订阅 `agent.tool_call` 事件自己数轮次，
/// 超限就用**执行站的 `agent.stop`** 发停止信号（示例见
/// `examples/plugins/sample_plugin.py`）。
///
/// **本文件不做传输**：只负责"把事件构造出来，交给唯一订阅入口"。派发口径复用
/// [PluginBus.dispatchAgentEvent] 的**既有 scope 匹配**（`config.scope` 为空即通配，
/// 非空则精确匹配 `team_id` / `agent_id` / `session_id`）——不发明新的订阅语法。
///
/// 接线形态（会话服务持有一个发布器，默认 **未接线 = no-op**）：
/// ```dart
/// conversation.agentEvents.sink = pluginBus.dispatchAgentEvent;
/// ```
/// 没接线时事件根本不构造，核心行为与本改动之前**完全一致**；CLI / 测试因此可以
/// 自己决定要不要发（测试注入记录器即可断言事件）。
library;

/// agent 事件名与字段名（核心与插件共用的词表；避免两边写错字）。
abstract final class AgentEvents {
  /// 工具调用事件：一次调用的**开始 / 结束各一条**。
  ///
  /// 载荷字段：`{event, agent_id, session_id, team_id, tool, call_id, round, phase}`。
  /// - `tool`：模型看到的名字（含 `plugin__` / `mcp__` 命名空间）；
  /// - `call_id`：端点给的 tool_call id（开始 / 结束同值；缺失时为空串）；
  /// - `round`：**本任务内**第几次工具调用（从 1 开始，与"轮次上限"同口径）；
  /// - `phase`：[phaseStart] | [phaseEnd]（结束事件用于统计耗时）。
  static const String toolCall = 'agent.tool_call';

  /// 事件名字段（`{event: 'agent.tool_call', ...}`）。
  static const String fieldEvent = 'event';

  /// agent id 字段。
  static const String fieldAgentId = 'agent_id';

  /// 会话 id 字段。
  static const String fieldSessionId = 'session_id';

  /// 团队 id 字段（站点隔离四元组的 team；空串 = 无团队归属）。
  static const String fieldTeamId = 'team_id';

  /// 工具名字段。
  static const String fieldTool = 'tool';

  /// 端点 tool_call id 字段。
  static const String fieldCallId = 'call_id';

  /// 轮次字段。
  static const String fieldRound = 'round';

  /// 阶段字段。
  static const String fieldPhase = 'phase';

  /// [fieldPhase] 的取值：工具调用开始。
  static const String phaseStart = 'start';

  /// [fieldPhase] 的取值：工具调用结束。
  static const String phaseEnd = 'end';
}

/// agent 事件的订阅入口（生产路径 = `PluginBus.dispatchAgentEvent`）。
typedef AgentEventSink = void Function(Map<String, dynamic> event);

/// agent 事件发布器：构造事件 → 交给 [sink]（未接线 = no-op）。
///
/// **失败绝不冒泡**：事件发布发生在生成循环里（工具调用处），插件侧的任何问题都不该
/// 让生成失败——订阅方抛异常时只回报给 [onError]（可空 = 静默吞掉），事件本身丢弃。
class AgentEventPublisher {
  /// 构造。
  ///
  /// [sink] 为空 = 未接线（本类全部方法都是 no-op）；[onError] 为空 = 发布失败静默。
  AgentEventPublisher({this.sink, this.onError});

  /// 订阅入口；null = 未接线（不构造事件、零开销）。
  AgentEventSink? sink;

  /// 发布失败的读数口（订阅方抛异常时的可读原因）；null = 静默吞掉。
  void Function(String message)? onError;

  /// 是否已接线。未接线时核心不发任何 agent 事件（行为与接线前一致）。
  bool get enabled => sink != null;

  /// 发布一条 `agent.tool_call`（工具调用开始 / 结束）。
  ///
  /// [phase] 取 [AgentEvents.phaseStart] / [AgentEvents.phaseEnd]；[round] 为
  /// **本任务内**的工具调用序号（从 1 开始），插件按它实现"超过 N 次就停"。
  void toolCall({
    required String agentId,
    required String sessionId,
    required String phase,
    String teamId = '',
    String tool = '',
    String callId = '',
    int round = 0,
  }) {
    final AgentEventSink? target = sink;
    if (target == null) return;
    _deliver(<String, dynamic>{
      AgentEvents.fieldEvent: AgentEvents.toolCall,
      AgentEvents.fieldAgentId: agentId,
      AgentEvents.fieldSessionId: sessionId,
      AgentEvents.fieldTeamId: teamId,
      AgentEvents.fieldTool: tool,
      AgentEvents.fieldCallId: callId,
      AgentEvents.fieldRound: round,
      AgentEvents.fieldPhase: phase,
    });
  }

  /// 投递（异常收敛在 [onError]，绝不打断调用方）。
  void _deliver(Map<String, dynamic> event) {
    final AgentEventSink? target = sink;
    if (target == null) return;
    try {
      target(event);
    } catch (error) {
      onError?.call(
        'agent 事件 ${event[AgentEvents.fieldEvent]} 发布失败（已忽略）：$error',
      );
    }
  }
}
