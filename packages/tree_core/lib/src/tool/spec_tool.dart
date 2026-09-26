import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../spec/spec_service.dart';
import 'tool_runner.dart';

/// `spec` 工具（M5d）：任务型规范（Spec）的检索 / 选择 / 沉淀。
///
/// 与参考实现一致的强约束：**select 之前必须先 read**（模型要先看到全文再挂 hook），
/// 且内置 Spec 只能读不能改（要改就 `create` 自己的）。
abstract final class SpecTool {
  static const String name = 'spec';

  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[任务型规范（Spec）检索/选择/沉淀] 把任务经验沉淀为可复用规范，并在开工前挂上。\n'
        'search：按任务描述语义检索；list：看索引；read：读全文；select：挂 hook'
        '（**必须先 read 对应 Spec**；传空数组表示取消全部选择；实际注入发生在下次'
        '重构 context）；create/update：沉淀与维护自定义 Spec（落盘到工作空间 spec/）。\n'
        '内置 Spec（easy-task / complex-task / hard-task / team-meeting）只读。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'description': '要执行的动作',
          'enum': <String>[
            'search',
            'list',
            'read',
            'select',
            'create',
            'update',
          ],
        },
        'query': <String, dynamic>{
          'type': 'string',
          'description': 'search 用：任务描述/关键词（自然语言）',
        },
        'spec_ids': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': 'select 用：要挂 hook 的 Spec id 列表（空数组 = 取消全部）',
        },
        'spec_id': <String, dynamic>{
          'type': 'string',
          'description': 'read/update 用：目标 Spec id',
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
          'description': 'create/update 用：一句话描述（供索引与检索）',
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
