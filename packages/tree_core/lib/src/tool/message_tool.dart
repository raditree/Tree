import 'dart:convert';

import '../team/message_dispatcher.dart';
import 'tool_runner.dart';

/// `message` 工具（M5c）：团队通信域——派活、点对点沟通、直属广播、等待交付。
///
/// 语义边界（照抄参考实现的提示词）：
/// - **不存在"任务"对象**：派活就是 `send_message`；
/// - **系统不会替你回传总结**：需要对方回复必须在消息里明确要求，对方自行
///   `send_message` 回发；不要为了确认收到而互发；
/// - `broadcast` 只发给**直属**成员（不跨层级）；
/// - `wait_for` 只有在"先观测到 working 再转 idle"时才算 completed。
abstract final class MessageTool {
  static const String name = 'message';

  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[团队协作-通信域] 向成员派活、点对点沟通、直属广播、等待交付。\n'
        'send_message：给成员/直属 leader/其他 TOP 发消息（写明工作内容、预期产出与'
        '完成后回复要求）；broadcast：给全部直属成员广播；wait_for：等待成员完成'
        '当前工作；list_members/list_teams：与 team 工具同一实现。\n'
        '系统不会替你回传任何总结：需要对方知道结果，必须让对方自行 send_message 回发；'
        '禁止仅为确认收到/寒暄/复述而互发。\n'
        'files 为本 agent 工作空间内的相对路径，会复制到接收方 .input/<日期>/'
        '（可用 dest_dir 指定目录）。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'description': '[团队协作-通信域] 消息派发、广播、等待完成。',
          'enum': TeamMessageDispatcher.actions,
        },
        'target_member_id': <String, dynamic>{
          'type': 'string',
          'description': 'send_message 目标：成员 ID/名称、直属 leader、其他 TOP',
        },
        'target_ids': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': 'send_message 一对多目标列表（与 target_member_id 二选一）',
        },
        'target_member_ids': <String, dynamic>{
          'type': 'string',
          'description': 'wait_for 必填；多个目标用英文逗号分隔',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': 'send_message / broadcast 的消息正文',
        },
        'files': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': 'send_message 可选：本 agent 工作空间内的相对路径',
        },
        'dest_dir': <String, dynamic>{
          'type': 'string',
          'description': 'files 的目标目录（默认 .input/<日期>）',
        },
        'timeout': <String, dynamic>{
          'type': 'integer',
          'description': 'wait_for 最长等待秒数（默认 300，上限 600）',
        },
        'session_id': <String, dynamic>{
          'type': 'string',
          'description': '接收方归集的会话 id（默认 session_default）',
        },
      },
      'required': <String>['action'],
    },
  );

  /// 执行一次调用（异步：`wait_for` 会真的等）。
  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    TeamMessageDispatcher dispatcher,
  ) async {
    final Map<String, dynamic> result = await dispatcher.run(
      invocation.agentId,
      invocation.arguments,
    );
    return ToolOutcome(
      const JsonEncoder.withIndent('  ').convert(result),
      isError: result.containsKey('error'),
    );
  }
}
