import 'tool_run_registry.dart';
import 'tool_runner.dart';

/// `tool_runs` 的**落点契约**：作用域解析 + 显式关闭。
///
/// 为什么用具名契约把编排层隔开（与 `AskQuestion` / `SubagentChannel` 同一范式）：
/// - "谁是我的下级"**不许自己发明**——判据必须来自既有的团队关系
///   （`TeamService.directMembers` 的 `parent_agent_id`、临时员工名册的 `parentId`）；
/// - "关闭"必须落到**同一个**实现（`ToolRunRegistry.close`——右栏「正在执行的 tool」
///   的关闭按钮走的 REST 与执行站 `tool.close` 都是它），否则就会出现"两套关闭语义"。
///
/// 实现见 `tool_runs_scope.dart`（生产由 `WorkspaceToolRunner` 组装）。
abstract interface class ToolRunsChannel {
  /// 判定 `over_threshold` 的阈值（登记表那一份，默认 300 s = terminal 缺省软超时）。
  Duration get threshold;

  /// **可见的在途运行**：本 agent 自己 + 其直属下级（按开始顺序）。
  List<ToolRun> listVisible({required String agentId, required String sessionId});

  /// **显式关闭**一次运行：与右栏「关闭」按钮、执行站 `tool.close` 同一个 closer。
  ///
  /// [memberId] 非空 = 调用方额外断言这次运行的归属（防止把 handle 抄到别的下级）。
  /// 句柄失效 / 不属于自己或自己的直属下级 / 未接线 ⇒ `closed: false` + **可读原因**
  /// （fail-closed：绝不假装成功，也绝不越权动别人的运行）。
  Future<ToolCloseOutcome> closeVisible({
    required String agentId,
    required String sessionId,
    required String handle,
    String memberId = '',
  });
}

/// **内置工具 `tool_runs`**：查看与显式收手**正在执行的工具调用**。
///
/// 定位（plan `20261003-running-tools` §11.3，2026-10-03 用户定案）：工具执行没有静态
/// 上限，一条不返回的命令会让整个工具批永不结束，而引擎把"批中途到来的用户消息"
/// 推迟到批结束之后 ⇒ 会话"消息只能进不能出"（见 `.self/recon-arch-stability.md`
/// §2.7/§2.8）。§11.1 定案：不支持转 hook 的工具**一直等**，直到被
/// 用户 / 插件 / **上级 agent** 显式取消——所以上级 agent 手上必须有同一套
/// "看见 + 收手"的入口，这就是本工具。
///
/// 它**不是** `team` 的动作：能同时服务"看自己"与"看下级"两种场景，且不与团队拓扑耦合。
abstract final class ToolRunsTool {
  static const String name = 'tool_runs';

  /// 工具声明（动作只有两个：list / close）。
  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[运行中工具] 查看与**显式收手**正在执行的工具调用（作用域 = 本 agent 自己 + '
        '其直属下级）。\n'
        '**什么时候用**：某个工具调用长时间不返回、会话像卡住了'
        '（消息发得进去、却一直没有产出）时——先 action=list 看是谁卡在哪个工具上、'
        '跑了多久、命令是什么；确认真卡住（比如一条全根扫描的命令）再用 action=close 收手。\n'
        '**action=list**：列出在途运行，每条给 handle / agent_id / session_id / tool / '
        'command_preview / started_at / elapsed_ms / over_threshold；已超阈值的项另附'
        '防呆风险提示（hint）。\n'
        '**action=close**：按 handle 显式终止一次运行（参数 handle 必填，可选 member_id '
        '校验归属）——先尽力终止进程树（拿得到本机进程时），再让这次工具调用收敛'
        '（立刻返回、它所在的那一批因此能收尾）。\n'
        '**close 是显式动作，不是自动杀**：超阈值只发一次 warning，没有任何东西会自动'
        '终止工具；停止键 / 插话的语义也没变（正在执行的工具跑完才收敛）——要收手就'
        '显式关这一次。\n'
        'handle 从哪来：`tool_runs action=list`，或 `team query_status` 的 '
        '`stuck_tools[].handle`。登记表是**纯内存**的（不跨核心重启存活），'
        '句柄在核心重启后、或这次运行结束后即失效，届时会回可读原因。\n'
        '只能看 / 关自己与**直属**下级的运行；别人的句柄会被拒绝并给出可读原因。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>['list', 'close'],
          'description': 'list = 列出在途运行；close = 按 handle 显式关闭一次运行',
        },
        'handle': <String, dynamic>{
          'type': 'string',
          'description':
              'action=close 必填：要关闭的工具运行句柄（形如 toolrun_<ms>_<rand>_<n>），'
              '从 tool_runs action=list 或 team query_status 的 stuck_tools 取',
        },
        'member_id': <String, dynamic>{
          'type': 'string',
          'description':
              'action=close 可选：断言这次运行归谁（agent_id），用来防止把 handle 抄到'
              '别的下级；与这条运行的 agent_id 不符时直接拒绝',
        },
      },
      'required': <String>['action'],
    },
  );

  /// 执行一次调用（形状 / 文案 / fail-closed 都在这里；作用域与关闭在 [channel]）。
  ///
  /// 任何失败（未知 action / 缺 handle / 未接线 / 句柄失效 / 越权）都返回
  /// `isError: true` 的**可读结果**，不抛异常——与内置工具的既有口径一致。
  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    ToolRunsChannel? channel,
  ) async {
    if (channel == null) {
      return const ToolOutcome(
        'tool_runs 未接线：核心没有接入工具运行登记表（详见核心日志）',
        isError: true,
      );
    }
    final String action = _string(invocation, 'action').trim().toLowerCase();
    switch (action) {
      case 'list':
        return ToolOutcome(
          renderList(
            runs: channel.listVisible(
              agentId: invocation.agentId,
              sessionId: invocation.sessionId,
            ),
            threshold: channel.threshold,
            selfId: invocation.agentId,
          ),
        );
      case 'close':
        return _close(invocation, channel);
      default:
        return ToolOutcome(
          '未知 action：$action（可用：list / close）',
          isError: true,
        );
    }
  }

  /// `action=close`：调**同一个** closer，把结论写成可读文案。
  static Future<ToolOutcome> _close(
    ToolInvocation invocation,
    ToolRunsChannel channel,
  ) async {
    final String handle = _string(invocation, 'handle').trim();
    if (handle.isEmpty) {
      return const ToolOutcome(
        'close 需要 handle：从 tool_runs action=list 或 team query_status 的 '
        'stuck_tools 取（形如 toolrun_<ms>_<rand>_<n>）',
        isError: true,
      );
    }
    final ToolCloseOutcome outcome = await channel.closeVisible(
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      handle: handle,
      memberId: _string(invocation, 'member_id').trim(),
    );
    if (!outcome.closed) {
      return ToolOutcome(
        '没能关闭这次工具运行：${outcome.note}',
        isError: true,
      );
    }
    return ToolOutcome(
      '已关闭一次工具运行：handle=$handle tool=${outcome.tool} '
      'elapsed_ms=${outcome.elapsedMs}\n'
      '说明：${outcome.note}\n'
      '这次调用已**立刻收敛**（不再等它跑完），它所在的那一批因此可以收尾了；'
      '命令若仍在跑，请用 terminal 复查进程与产物，不要直接重跑。',
    );
  }

  /// `action=list` 的可读清单。
  ///
  /// 每条的字段**与 REST 快照同源**（同一份 [ToolRun.toJson]）——面板、`stuck_tools`
  /// 与这里三处因此不会各自漂移；`over_threshold` 的项再附 [ToolRun.stuckHint] 那段
  /// 防呆提示（与 `query_status.stuck_tools[].hint` 逐字同源）。
  static String renderList({
    required List<ToolRun> runs,
    required Duration threshold,
    required String selfId,
  }) {
    const String scope = '本 agent 自己 + 其直属下级';
    final String limit =
        '超阈值 ${threshold.inSeconds}s（${threshold.inMilliseconds}ms）';
    if (runs.isEmpty) {
      return '当前没有正在执行的工具（作用域：$scope）。\n'
          '（登记表只记"正在跑的"：工具返回后即移除、核心重启即清空，因此这里是空的不代表历史没卡过。）';
    }
    final StringBuffer out = StringBuffer()
      ..writeln('正在执行的工具运行：${runs.length} 条（作用域：$scope；$limit）');
    int index = 0;
    for (final ToolRun run in runs) {
      index++;
      final Map<String, dynamic> json = run.toJson(threshold: threshold);
      out.writeln('$index) handle=${json['handle']}');
      out.writeln(
        '   agent_id=${json['agent_id']}${run.agentId == selfId ? '（我）' : '（下级）'} '
        'session_id=${json['session_id']} tool=${json['tool']}',
      );
      out.writeln(
        '   started_at=${json['started_at']} elapsed_ms=${json['elapsed_ms']}'
        '（${run.elapsedSeconds}s） over_threshold=${json['over_threshold']}',
      );
      out.writeln('   command_preview: ${json['command_preview']}');
      if (json['over_threshold'] == true) {
        out.writeln('   hint: ${run.stuckHint()}');
      }
    }
    out.write(
      '收手用 tool_runs action=close（args: {"handle": "<上面某个 handle>"}）——'
      '与右栏「正在执行的 tool」的关闭按钮、执行站 tool.close 是**同一个**实现；'
      '关闭是**显式**动作，不会自动杀工具。',
    );
    return out.toString();
  }

  static String _string(ToolInvocation invocation, String key) {
    final Object? value = invocation.arguments[key];
    if (value is String) return value;
    if (value == null) return '';
    return '$value';
  }
}
