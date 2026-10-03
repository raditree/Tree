import '../store/subagent_registry.dart';
import 'tool_runner.dart';

/// 临时员工在**消息与帧**上的标记（`subagent_id` / `subagent_name` / …）。
///
/// 为什么要有它：临时员工没有自己的会话，它的一切都写进"召它的那个 agent 的会话"
/// 消息流里；前端要能把这一行式消息流**按临时员工分组**显示，就必须在每条消息/帧上
/// 拿到这四个字段（字段清单与渲染口径见 tree_core/README.md 与本次交付报告）。
///
/// [parentId] 是"召它的那个 agent"（真实 agent id 或上级临时员工 id），与 [level]
/// 一起构成会话内的**树**结构。
class SubagentTag {
  const SubagentTag({
    required this.id,
    required this.name,
    required this.parentId,
    required this.level,
  });

  /// 临时员工 id（`sub_…`，工具结果里回传给发起者供复用）。
  final String id;

  /// 显示名（界面与消息标记用）。
  final String name;

  /// 召它的那个 agent（树上的父节点）。
  final String parentId;

  /// 会话内层级（真实 agent 的直属临时员工 = 1）。
  final int level;

  /// 追加到 WS 帧 / 消息 JSON 上的字段（值为空时不写，避免污染普通消息）。
  Map<String, dynamic> get frameFields => <String, dynamic>{
    'subagent_id': id,
    if (name.isNotEmpty) 'subagent_name': name,
    if (parentId.isNotEmpty) 'subagent_parent_id': parentId,
    'subagent_level': level,
  };
}

/// 一次 `subagent` 调用（工具层已做过形状校验）。
class SubagentRequest {
  const SubagentRequest({
    required this.invocation,
    required this.task,
    required this.name,
    required this.reuseRef,
    required this.background,
  });

  final ToolInvocation invocation;

  /// 自包含的指令（已 trim，非空）。
  final String task;

  /// 显示名（已 trim；空 ⇒ 调用方用 [SubagentTool.defaultName]）。
  final String name;

  /// 复用入口：临时员工 id 或显示名；空串 = 新召一个。
  final String reuseRef;

  /// true = 后台执行（不阻塞，完成后把报告注入父会话）。
  final bool background;
}

/// `subagent` 工具的落点契约（实现见 `agent/subagent_service.dart`）。
///
/// 工具层只需要"跑一次 + 认不认得这个 id"，因此用具名契约把编排层隔开：
/// 工具层不必反向依赖 agent 层（与 [AskQuestion] 同一范式）。
abstract interface class SubagentChannel {
  /// 跑一次临时员工（校验 + 名册 + 阻塞/后台 + 兜底清理）。
  Future<ToolOutcome> run(SubagentRequest request);

  /// 该 id 是否临时员工（前缀判据：不要求已加载名册）。
  bool isSubagent(String agentId);

  /// 该 id 的临时员工标记（未加载/不是临时员工 ⇒ null）：提问卡片与消息落库要用它。
  SubagentTag? tagOf(String agentId);

  /// 临时员工的**私有状态归属**：`sub_…` → 会话主人（真实 agent）；其余返回自身。
  ///
  /// 用途：`.tree/<agent>/.self` 分栏 + 复用发起者那条工作空间/SSH 连接。
  String privateOwnerOf(String agentId);
}

/// `subagent` 工具（本能力核心侧入口）：**现场召一个临时员工干活**。
///
/// 与 `team` 的本质区别（用户定稿口径）：
/// - 它**只活在会话里**（可复用、随会话持久化），不写 `agents/<id>.yaml`、不进团队名册、
///   不可被 `message` 寻址；
/// - 它**继承发起者**的工作空间（同一份根 + 同一 SSH 口径）、模型与工具集；
/// - 它不能被派活（没有 `message`），也不能建队（没有 `team`）；但它**可以再召**
///   临时员工（把同一个大任务拆细，层级上限见 [SubagentLimits.maxDepth]）。
abstract final class SubagentTool {
  static const String name = 'subagent';
  static const String defaultName = '临时员工';

  /// 工具声明（顺序稳定：便于提示词缓存与测试断言）。
  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[临时员工] 现场召一个临时员工干活：召之即来、干完还在（同一会话内可复用）。\n'
        '它的工作空间与模型**继承你**（同一份工作目录、同一 SSH 口径、同一个模型），'
        '工具集继承你的读写/命令/搜索/待办/提问/规范/MCP/插件工具，但**没有** team / message。\n'
        '调用口径：\n'
        '- task 必须**自包含**：临时员工看不到你的会话历史、也看不到你和别人的对话，'
        '所需上下文（文件路径、背景、验收标准、产出格式）都要写进 task；\n'
        '- 它会给出**可选用的结论/报告**；需要拿到它的产出就用默认的阻塞模式（background 缺省 false）；\n'
        '- 工具结果里会回传它的 id（sub_…）——**复用入口就是它**（subagent_id 传 id 或名称）。\n'
        '何时复用同一个临时员工：**只有当新任务与它被召来时的职责/范围一致时**才复用'
        '（同一个文件/模块/主题上的延续工作，历史延续、配置不变）；'
        '范围不同就**新召一个**（不填 subagent_id），不要拿一个临时员工干完全不相干的两件事。\n'
        '再派发（套娃）：临时员工自己也能召临时员工，**只用于把同一个大任务拆细**'
        '（例如一个临时员工负责整个改造，再把其中几个独立子项派给下级）；'
        '层级上限 ${SubagentLimits.maxDepth} 层'
        '（真实 agent 的直属临时员工 = 1 层），超限会返回可读错误——'
        '**不许为绕开工具/权限/上下文限制而套娃**，也不要把自己的活原样转包出去。\n'
        'background=true：不阻塞，可以**同时开多个**并行跑（数量不设上限），每次调用立刻返回'
        '一个句柄，完成后结果会带着 subagent_id / name 注入本会话把你唤醒。'
        '注意并行临时员工**共享同一个工作空间**：请按文件/目录划分好各自的改写范围，'
        '不要同时改同一个文件；不打算并行就别用 background。\n'
        '后台完成的多个结果**不会互相覆盖**：每一个都会各自注入一次。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'task': <String, dynamic>{
          'type': 'string',
          'description':
              '自包含的指令：背景、涉及的文件/目录、要做什么、验收标准、产出格式。'
              '它看不到你的会话历史，缺的上下文它无从得知。',
        },
        'name': <String, dynamic>{
          'type': 'string',
          'description':
              '显示名（缺省「${SubagentTool.defaultName}」）：仅用于界面与消息标记；'
              '同一会话内不要求唯一，名称复用有歧义时会报错。',
        },
        'subagent_id': <String, dynamic>{
          'type': 'string',
          'description':
              '复用入口：要复用的临时员工 id（sub_…，工具结果里给过）或它的显示名。'
              '只在**本会话内**有效——临时员工只活在它被召来的那个会话里，'
              '拿别的会话的 id 会得到可读错误。缺省 = 新召一个。',
        },
        'background': <String, dynamic>{
          'type': 'boolean',
          'description':
              'true = 后台执行：立刻返回它的 id，完成后报告注入本会话唤醒你；'
              '可同时开多个并行（它们共享工作空间，按文件/目录划分改写范围）。'
              'false（缺省）= 阻塞：等它跑完，把最终报告作为本次工具结果返回。',
        },
      },
      'required': <String>['task'],
    },
  );

  /// 工具形状校验（纯函数，不需要任何服务）：缺 task / 空 task 给可读错误。
  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    SubagentChannel channel,
  ) async {
    final Object? rawTask = invocation.arguments['task'];
    if (rawTask == null) {
      return const ToolOutcome(
        '缺少 task：subagent 必须给出一段**自包含**的指令——'
        '临时员工看不到你的会话历史与任何上下文，需要什么都要写在 task 里。',
        isError: true,
      );
    }
    final String task = rawTask is String ? rawTask.trim() : '$rawTask'.trim();
    if (task.isEmpty) {
      return const ToolOutcome(
        'task 不能为空：请写清背景、涉及的文件/目录、要做什么、验收标准与产出格式——'
        '临时员工看不到你的会话历史，缺的上下文它无从得知。',
        isError: true,
      );
    }
    final Object? rawName = invocation.arguments['name'];
    final String name = rawName == null ? '' : '$rawName'.trim();
    final Object? rawReuse = invocation.arguments['subagent_id'];
    final String reuseRef = rawReuse == null ? '' : '$rawReuse'.trim();
    return channel.run(
      SubagentRequest(
        invocation: invocation,
        task: task,
        name: name.isEmpty ? defaultName : name,
        reuseRef: reuseRef,
        background: _bool(invocation.arguments['background']),
      ),
    );
  }

  static bool _bool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final String text = value.trim().toLowerCase();
      return text == 'true' || text == '1' || text == 'yes';
    }
    if (value is num) return value != 0;
    return false;
  }
}
