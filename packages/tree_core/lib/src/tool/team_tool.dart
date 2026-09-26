import 'dart:convert';

import '../team/team_service.dart';
import 'tool_runner.dart';

/// `team` 工具（M5b）：模型面向的团队管理入口（建队/名单/档案/审核状态）。
///
/// 设计边界（都来自参考实现的提示词，Dart 侧照抄语义）：
/// - **不提供任何模型能力**：没有 list_models；create/update/review 收到 model_id
///   一律报错——模型只能由用户在「团队成员 → 模型配置」页分配；
/// - 新建成员**不继承 TOP 模型**，在用户赋模型并审核通过前不接收消息；
/// - create_member / remove_member / review_member 属破坏性或权限性动作，
///   未经用户明确要求不要调用。
abstract final class TeamTool {
  static const String name = 'team';

  /// 工具声明（顺序稳定：便于提示词缓存与测试断言）。
  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[团队协作-管理域] 建队、成员档案、分工与状态查询。\n'
        '何时使用：list_teams 查看名下团队；list_members 查看本团队名单与拓扑；'
        'create_member 应用户自然语言要求创建成员（仅限 team leader）；'
        'remove_member 应用户明确要求移除成员（默认连同下级子树）；'
        'query_member/update_member 看/改 role、duty、can_lead_team 等档案；'
        'review_member 应用户明确要求同步放行/驳回；query_status 看实时状态。\n'
        '何时不用：发消息/派活/等待完成用 message 工具。\n'
        '模型边界：本工具**没有**模型能力——create_member/update_member/'
        'review_member 不接受 model_id（传了就报错）。成员模型由用户本人在'
        '「团队成员 → 模型配置」页选择。\n'
        '成员就绪：新成员 model_id 为空、review_status=pending_model，'
        '在用户赋模型并审核通过前不接收也不执行任何消息；list_members 返回'
        'not_ready_count 与 hint。\n'
        '注意：remove_member 只能移除自己的直属/下级成员，不可移除自身或任何上级；'
        '目标仍有下级时必须显式 cascade=true。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'description': '[团队协作-管理域] 建队、成员档案、分工与状态查询。',
          'enum': TeamService.actions,
        },
        'member_name': <String, dynamic>{
          'type': 'string',
          'description': 'create_member 的新成员名称',
        },
        'target_member_id': <String, dynamic>{
          'type': 'string',
          'description': '目标成员 ID 或名称',
        },
        'cascade': <String, dynamic>{
          'type': 'boolean',
          'description': 'remove_member 是否连同下级子树（默认 true）',
        },
        'name': <String, dynamic>{
          'type': 'string',
          'description': 'update_member 新名称',
        },
        'role': <String, dynamic>{
          'type': 'string',
          'description': 'create_member/update_member 角色',
        },
        'duty': <String, dynamic>{
          'type': 'string',
          'description': 'create_member/update_member 职责',
        },
        'can_lead_team': <String, dynamic>{
          'type': 'boolean',
          'description': '是否允许再建子团队（默认 true）',
        },
        'review_status': <String, dynamic>{
          'type': 'string',
          'description': 'review_member 目标状态（仅在用户明确要求时同步）',
          'enum': <String>['approved', 'rejected', 'pending_review'],
        },
        'approve': <String, dynamic>{
          'type': 'boolean',
          'description': 'review_status 未提供时生效：true=approved，false=rejected',
        },
        'work_status': <String, dynamic>{
          'type': 'string',
          'description': 'list_members 按实时状态筛选（只读字段）',
          'enum': <String>['idle', 'working'],
        },
        'level': <String, dynamic>{
          'type': 'integer',
          'description': 'list_members 按层级筛选（TOP=0）',
        },
        'comment': <String, dynamic>{
          'type': 'string',
          'description': 'update_member 评价',
        },
        'system_prompt': <String, dynamic>{
          'type': 'string',
          'description': '成员独立系统提示词',
        },
        'scores': <String, dynamic>{
          'type': 'object',
          'description': 'update_member 评分（0~10）',
          'properties': <String, dynamic>{
            'quality': <String, dynamic>{'type': 'number'},
            'efficiency': <String, dynamic>{'type': 'number'},
            'collaboration': <String, dynamic>{'type': 'number'},
            'accuracy': <String, dynamic>{'type': 'number'},
          },
        },
      },
      'required': <String>['action'],
    },
  );

  /// 执行一次调用：把服务的结构化结果转成模型可读的 JSON 文本。
  ///
  /// 失败（`error` 键）返回 `isError: true`，但仍给出完整 JSON：模型需要读 hint
  /// 才知道下一步该做什么（例如"让用户去模型配置页"）。
  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    TeamService service,
  ) async {
    final Map<String, dynamic> result = service.run(
      invocation.agentId,
      invocation.arguments,
    );
    return ToolOutcome(
      const JsonEncoder.withIndent('  ').convert(result),
      isError: result.containsKey('error'),
    );
  }
}
