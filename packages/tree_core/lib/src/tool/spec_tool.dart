import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../spec/spec_service.dart';
import 'tool_runner.dart';

/// `spec` 工具（M9 Q9 瘦身）：任务型规范（Spec）的**选择 / 沉淀 / 维护**。
///
/// 三个设计决定：
/// - **只留三个动作**：`search` / `list` / `read` 已删除——索引直接写在系统提示词里
///   （见 `agent/workspace_prompt.dart`），模型看得到 id，`select` 一次就把全文拿回来；
/// - **删掉「select 之前必须先 read」的硬约束**：那是两轮工具调用，模型还常常漏一步；
/// - 内置 Spec 只能读不能改（要改就 `create` 自己的）。
abstract final class SpecTool {
  static const String name = 'spec';

  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[任务型规范（Spec）] 把任务经验沉淀为可复用规范，并在开工前挂上。\n'
        '**何时用：几乎没有例外**——开工第一步就按系统提示词里的 Spec 索引判型并 select；'
        '会改动文件或需要多步执行的任务不允许跳过（"先探索再说"也不行，探索前就该挂好），'
        '只有纯问答/查资料（不改任何文件）才可以不挂。\n'
        'select：挂 hook 并**直接返回所选 Spec 全文**（不需要先 read；传空数组表示取消全部选择）；'
        '挂上之后全文会作为「已选 Spec 全文」持续注入本会话的系统提示词，不是只在这一轮有效。\n'
        'create/update：沉淀与维护自定义 Spec（落盘到工作空间 .self/spec/）。\n'
        '可用 Spec 的索引（id/类型/标题/适用条件）已列在系统提示词里，直接用 id 选取。'
        '内置 Spec（索引里标着「内置」的那些，清单以索引为准）只读，不可 update。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'description': '要执行的动作',
          'enum': <String>['select', 'create', 'update'],
        },
        'spec_ids': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description':
              'select 用：要挂 hook 的 Spec id 列表（空数组 = 取消全部）；'
              '返回所选 Spec 全文',
        },
        'spec_id': <String, dynamic>{
          'type': 'string',
          'description': 'update 用：目标 Spec id',
        },
        'title': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：Spec 标题',
        },
        'task_type': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：任务类型',
          'enum': <String>['easy', 'complex', 'hard', 'custom'],
        },
        'description': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：一句话描述（进 Spec 索引）',
        },
        'risk': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：风险等级',
          'enum': <String>['low', 'medium', 'high', 'review'],
        },
        'classification': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：规范分类（默认 内部规范）',
        },
        'when': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': 'create/update 用：适用条件列表',
        },
        'workflow': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：工作流（Markdown）',
        },
        'rules': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：该类任务规范（Markdown）',
        },
        'notes': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 用：注意事项（Markdown）',
        },
      },
      'required': <String>['action'],
    },
  );

  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    SpecService service,
    WorkspaceIO io,
  ) async {
    final Map<String, dynamic> result = await service.run(invocation, io);
    return ToolOutcome(
      const JsonEncoder.withIndent('  ').convert(result),
      isError: result.containsKey('error'),
    );
  }
}
