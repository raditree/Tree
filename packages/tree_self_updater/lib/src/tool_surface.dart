import 'plugin_methods.dart';

/// 本插件对外提供的**唯一 agent tool**：`plugin_hot_restart`。
///
/// 形状刻意是"一个 tool + `action` 参数"而不是四个 tool：四个 tool 会把模型工具表
/// 撑出四行同族条目（每行都要占提示词预算），而它们的语义本来就是同一个动作的四种问法。
abstract final class SelfUpdaterTool {
  /// 工具名（注册后的完整名字是 `plugin__self_updater__plugin_hot_restart`）。
  static const String name = 'plugin_hot_restart';

  /// `action` 的合法取值 ⇒ 对应的执行站命令。**这是唯一映射表**（用例钉住）。
  static const Map<String, String> actions = <String, String>{
    'list': PluginCommands.list,
    'state': PluginCommands.state,
    'restart': PluginCommands.restart,
    'suspend': PluginCommands.suspend,
  };

  /// **不得**出现在 action 里的命令：快照的转储/取回是生命周期原语，只由插件自己
  /// 在 `suspend` / `hello` 路径上下达（D9）。这里显式列出来，是为了让"有人以后
  /// 顺手加一个 `action: 'dump'`"当场可测（见 `test/self_updater_loop_test.dart`）。
  static const Set<String> refusedActions = <String>{
    'stateDump',
    'stateFetch',
    'plugin.stateDump',
    'plugin.stateFetch',
  };

  /// 工具的参数 schema（`tools/list` 那一面用 `inputSchema` 这个名字）。
  ///
  /// 刻意是 `final` 而不是 `const`：`enum` 那一项直接从 [actions] 的键推导，
  /// 写成 const 就得在这里手抄一遍可用动作（抄漏一个 = 模型按说明书填了合法值，
  /// 而映射表把它拒成“未知 action”——这种错只在运行时暴露，而且很像模型的错）。
  static final Map<String, Object> parameters = <String, Object>{
    'type': 'object',
    'properties': <String, Object>{
      'action': <String, Object>{
        'type': 'string',
        'enum': <String>[...actions.keys],
        'description':
            '要做什么：list = 列出所有插件（id / 是否启用 / 阶段 / 第几世 / 活性）；'
            'state = 看一个插件的运行态；restart = 热重启（默认尽量保留状态）；'
            'suspend = 只请求转储挂起，不换进程',
      },
      'plugin_id': <String, Object>{
        'type': 'string',
        'description':
            '目标插件 id（action=list 可省略；其余必须指名。填自己的 id 就是"重启我自己"，'
            '这是允许的：核心会先应答再动手）',
      },
      'keep_state': <String, Object>{
        'type': 'boolean',
        'description':
            'restart 时是否尝试续跑（缺省 true）。目标插件没声明 suspension: keep '
            '时核心按冷启动处理，这不算失败，回包会写明',
      },
      'wait_ready': <String, Object>{
        'type': 'boolean',
        'description':
            'restart 后是否再读一次 plugin.state 把「新一世的阶段/代际」附进结果'
            '（缺省 true）。重启自己时无效：应答必须先发给正在退出的我',
      },
    },
    'required': <String>['action'],
  };

  /// 工具描述（原样进模型工具表 ⇒ 这就是模型看到的说明书）。
  static const String description =
      '热重启一个插件进程（含重启我自己所在的插件），可保留可续跑状态。'
      '重启期间核心照常响应这个插件的站点请求（暂存后重放），会话不因此失败；'
      '失败一律以可读原因返回，不会把一个插件拖成整个框架。';

  /// `tools/list` 形状（name / description / inputSchema）。
  static List<Map<String, Object>> toolsListEntries() => <Map<String, Object>>[
    <String, Object>{
      'name': name,
      'description': description,
      'inputSchema': parameters,
    },
  ];

  /// 收集站（`plugin.tool.define`）形状（tool_name / description / parameters / execution）。
  ///
  /// 两条路的差别只在字段名：**同一份参数 schema 复用同一个常量**，
  /// 否则两条路会各自漂移出两个不同的工具（模型看到 A、核心注册成 B）。
  static List<Map<String, Object>> collectToolDefinitions() =>
      <Map<String, Object>>[
        <String, Object>{
          'tool_name': name,
          'description': description,
          'parameters': parameters,
          'execution': <String, Object>{
            'method': PluginMethods.toolsCall,
            'name': name,
          },
        },
      ];

  /// `action` ⇒ 执行站命令；非法/被拒时返回可读原因（不抛异常：工具的失败必须是结果）。
  static ({String? command, String? error}) resolveCommand(String action) {
    final String key = action.trim();
    if (refusedActions.contains(key)) {
      return (
        command: null,
        error:
            'action「$key」不是可申报的能力：plugin.stateDump / plugin.stateFetch '
            '是插件生命周期的原语，只由插件自己在转储/取回时下达，'
            '不暴露给模型（框架不变量：可续跑状态的进出面必须在核心侧收口）',
      );
    }
    final String? command = actions[key];
    if (command == null) {
      return (
        command: null,
        error:
            '未知 action「$key」（可用：${actions.keys.join(' | ')}）；'
            '本插件不接受其他 plugin.* 命令',
      );
    }
    return (command: command, error: null);
  }
}
