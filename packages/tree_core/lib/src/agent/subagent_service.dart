import 'dart:async';

import '../settings/core_settings.dart';
import '../store/subagent_registry.dart';
import '../store/tree_store.dart';
import '../team/team_workspace.dart';
import '../tool/subagent_tool.dart';
import '../tool/tool_runner.dart';

/// 一次临时员工运行的请求（[SubagentTurnRunner] 的入参）。
class SubagentTurnRequest {
  const SubagentTurnRequest({
    required this.tag,
    required this.ownerAgentId,
    required this.sessionId,
    required this.task,
    this.fromUser = false,
  });

  /// 它是谁（id / 显示名 / 树上父节点 / 层级）。
  final SubagentTag tag;

  /// **会话主人**：这个临时员工所在会话归属的真实 agent（消息、工作空间、站点四元组
  /// 都按它归集）。
  final String ownerAgentId;

  /// 它只在这个会话里跑（运行标识 = `(subagentId, sessionId)`）。
  final String sessionId;

  /// 本次下达的自包含指令。
  final String task;

  /// 这条输入是不是**用户（界面）直接说的**。
  ///
  /// 区别只在落库形态：工具下达的任务落 `kind='subagent_task'` 的 agent 消息（它的输入，
  /// 但发起者的上下文里没有它）；用户说的话落 **`role='user'` 的普通消息 + 它的标记**
  /// （用户直接对临时员工说话，见 [ConversationService.sendToSubagent]）。
  final bool fromUser;
}

/// 一次临时员工运行的结果。
class SubagentTurnResult {
  const SubagentTurnResult({
    this.report = '',
    this.error = '',
    this.cancelled = false,
    this.userStopped = false,
  });

  /// 它的最终报告（最后一轮正文；没有文本产出时为空串）。
  final String report;

  /// 可读失败原因（空串 = 没失败）。
  final String error;

  /// 这一轮是不是被人为中止的（**任何**原因：用户叫停 / hook 唤醒 / 别的临时员工完成）。
  final bool cancelled;

  /// 这一轮是不是**人叫停**的（用户按停止 / 用户插话）。
  ///
  /// 人为中止**不向发起者注入结束提示**：用户自己会说原因，而且他很可能马上又给这个
  /// 临时员工发一条让它接着干——那时自然结束的报告才是发起者该看到的那一条。
  /// 系统内部的收敛（hook 唤醒、别的临时员工完成报告）**不算**：那类中止要报。
  final bool userStopped;

  bool get ok => error.isEmpty && report.trim().isNotEmpty;
}

/// 跑一轮临时员工生成（实现见 `ConversationService.runSubagent`）。
typedef SubagentTurnRunner =
    Future<SubagentTurnResult> Function(SubagentTurnRequest request);

/// 后台临时员工完成时的注入回调（CLI 接到 `tools.onHookFinished → conversation.wake`）。
///
/// **一次都不能丢**：多个后台临时员工并发完成时，每一个都会各自调用一次
/// （不做"只留最后一个"的单槽位）。
typedef SubagentFinished =
    void Function(
      String ownerAgentId,
      String sessionId,
      String notice,
      SubagentTag tag,
    );

/// `subagent` 工具的落点：校验 → 名册（复用/新建）→ 阻塞或后台运行 → 记完账。
///
/// 它**不自己跑 LLM**：真正的"跑一轮独立生成"在 [SubagentTurnRunner]（生产是
/// `ConversationService.runSubagent`），服务只负责"以谁的身份、按什么会话口径、
/// 用哪份配置"这件事。因此本类可以脱离 LLM 单测。
///
/// 三个后置绑定的槽（与 CLI 里 `hubSink` / `deliverSink` 同一范式）：
/// - [runner]：核心起监听后才有（`ConversationService` 由 CoreServer 创建）；
/// - [probeWorkspace]：工具层建好之后才有（用它解析发起者的工作空间）；
/// - [onFinished]：后台完成时把报告注入父会话（走既有 hook→wake 那条路）。
class SubagentService implements SubagentChannel {
  SubagentService({
    required this.store,
    required this.registry,
    required this.settings,
    this.probeWorkspace,
    this.onFinished,
    this.log,
  });

  /// **装饰后的** store（`SubagentStore`）：`agent(sub_…)` 要能查到临时员工，
  /// 否则工作空间/SSH/系统提示词这些既有路径认不出它。
  final TreeStore store;

  /// 会话级名册（内存索引 + 落盘）。
  final SubagentRegistry registry;

  /// 模型池（校验"发起者的有效模型"能不能解析出来）。
  final CoreSettings settings;

  /// 探测某 agent 的工作空间是否可用：返回可读原因，null/空串 = 可用。
  Future<String?> Function(String agentId)? probeWorkspace;

  /// 后台完成注入（见 [SubagentFinished]）。
  SubagentFinished? onFinished;

  /// 跑一轮的落点（后置绑定）。
  SubagentTurnRunner? runner;

  final void Function(String message)? log;

  // ── SubagentChannel ──────────────────────────────────────────────────

  @override
  bool isSubagent(String agentId) => registry.isSubagent(agentId);

  @override
  SubagentTag? tagOf(String agentId) {
    final CoreSubagent? record = registry.handle(agentId);
    if (record == null) return null;
    return SubagentTag(
      id: record.id,
      name: record.name,
      parentId: record.parentId,
      level: record.level,
    );
  }

  @override
  String privateOwnerOf(String agentId) => registry.privateOwnerOf(agentId);

  @override
  List<SubagentTag> directSubagentsOf(String agentId, String sessionId) {
    final String sid = sessionId.trim();
    if (sid.isEmpty) return const <SubagentTag>[];
    // 名册按 (会话主人, sessionId) 分栏：先沿 parentId 找到树根（会话主人），
    // 再在**本会话**的名册里挑 parentId == 自己 的那些（既有关系，不新造判据）。
    final String owner = registry.privateOwnerOf(agentId);
    return registry
        .records(owner, sid)
        .where((CoreSubagent s) => s.parentId == agentId)
        .map(
          (CoreSubagent s) => SubagentTag(
            id: s.id,
            name: s.name,
            parentId: s.parentId,
            level: s.level,
          ),
        )
        .toList(growable: false);
  }

  // ── 入口 ─────────────────────────────────────────────────────────────

  @override
  Future<ToolOutcome> run(SubagentRequest request) async {
    final ToolInvocation invocation = request.invocation;
    final String callerId = invocation.agentId;
    final String sessionId = invocation.sessionId.trim();
    if (sessionId.isEmpty) {
      return _error(
        '缺少会话上下文：subagent 必须在某个会话里调用——临时员工的活动要留在'
        '那个会话的历史里，没有会话它无处安身。',
      );
    }
    final CoreAgent? caller = store.agent(callerId);
    if (caller == null) {
      return _error('未知 agent：$callerId（无法以它的身份召临时员工）');
    }
    // 会话主人：发起者是临时员工时，沿树根找到真实 agent（嵌套派发同一口径）
    final CoreSubagent? callerRecord = registry.isSubagent(callerId)
        ? registry.handle(callerId)
        : null;
    final String ownerAgentId = callerRecord?.ownerAgentId ?? callerId;
    // **打开会话 = 装载名册**（临时员工随会话持久化；核心重启后同一会话原样回来）
    registry.ensureSession(ownerAgentId, sessionId);

    final String? modelError = _modelError(caller);
    if (modelError != null) return _error(modelError);

    final Future<String?> Function(String agentId)? probe = probeWorkspace;
    if (probe != null) {
      final String? reason = await probe(ownerAgentId);
      if (reason != null && reason.trim().isNotEmpty) return _error(reason);
    }

    // ── 复用入口（只在同一会话内有效） ──────────────────────────────────
    CoreSubagent? reuse;
    if (request.reuseRef.isNotEmpty) {
      final ({CoreSubagent? record, String? error}) found = _resolveReuse(
        ownerAgentId: ownerAgentId,
        sessionId: sessionId,
        ref: request.reuseRef,
      );
      if (found.error != null) return _error(found.error!);
      reuse = found.record;
    }

    // ── 层级上限（只对新建；复用不加深） ───────────────────────────────
    final int callerLevel = callerRecord?.level ?? 0;
    final int level = callerLevel + 1;
    if (reuse == null && level > SubagentLimits.maxDepth) {
      return _error(
        '临时员工层级上限 ${SubagentLimits.maxDepth}：你已经在第 $callerLevel 层'
        '（你也是一个临时员工），不能再往下派。'
        '请把要拆的活合并进自己的 task——只允许把同一个大任务拆细，'
        '不许用套娃绕开层级/上下文限制。',
      );
    }

    final CoreSubagent target;
    final bool reused = reuse != null;
    if (reuse != null) {
      target = reuse;
      target.updatedAt = DateTime.now().millisecondsSinceEpoch;
      registry.put(target);
    } else {
      final String id = registry.nextId();
      final String scope = _scopeOf(request.task);
      final CoreSubagent record = CoreSubagent(
        id: id,
        name: request.name,
        ownerAgentId: ownerAgentId,
        sessionId: sessionId,
        parentId: callerId,
        level: level,
        scope: scope,
        agent: _buildAgent(
          id: id,
          name: request.name,
          scope: scope,
          caller: caller,
          ownerAgentId: ownerAgentId,
          level: level,
        ),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      registry.put(record);
      target = record;
      log?.call(
        '新召临时员工 ${record.id}（${record.name}，层级 ${record.level}，'
        '会话 $ownerAgentId/$sessionId）',
      );
    }

    final SubagentTurnRunner? turnRunner = runner;
    if (turnRunner == null) {
      return _error(
        '临时员工运行器未接线（核心尚未启动完成）：请稍后重试；'
        '这属于接线问题，重试不需要改参数。',
      );
    }
    final SubagentTag tag = SubagentTag(
      id: target.id,
      name: target.name,
      parentId: target.parentId,
      level: target.level,
    );
    final SubagentTurnRequest turn = SubagentTurnRequest(
      tag: tag,
      ownerAgentId: ownerAgentId,
      sessionId: sessionId,
      task: request.task,
    );
    // 记账：它被跑过一轮（含复用）。失败也算跑过——实体留在会话里可复用。
    registry.markRun(target.id);
    if (request.background) {
      unawaited(_runBackground(turn, target));
      return ToolOutcome(
        '${_header(target, reused: reused)}\n'
        '已在后台开工，本轮不必等它：完成后报告会带着 subagent_id 注入本会话把你唤醒。'
        '可以同时开多个后台临时员工并行跑（它们**共享同一个工作空间**，'
        '请按文件/目录划分好各自的改写范围）。',
      );
    }
    SubagentTurnResult result;
    try {
      result = await turnRunner(turn);
    } catch (error) {
      result = SubagentTurnResult(error: '临时员工运行异常：$error');
    }
    return _blockingOutcome(target, result, reused: reused);
  }

  // ── 后台 ─────────────────────────────────────────────────────────────

  Future<void> _runBackground(
    SubagentTurnRequest turn,
    CoreSubagent target,
  ) async {
    SubagentTurnResult result;
    try {
      result = await runner!(turn);
    } catch (error) {
      result = SubagentTurnResult(error: '临时员工运行异常：$error');
    }
    final SubagentTag tag = turn.tag;
    // **人为中止不注入**（用户 2026-10-04：停止后不用向父 agent 发结束提示，用户自己说
    // 原因；出错导致的中止照样要说）——与界面直接发消息那条路同一口径。
    if (result.userStopped && result.error.isEmpty) {
      log?.call('临时员工 ${tag.id} 这一轮被用户叫停：不注入结束提示');
      return;
    }
    // **每个后台临时员工各注入一次**：不做"只留最后一个"的单槽位（并发完成不丢）
    final SubagentFinished? finished = onFinished;
    if (finished == null) {
      log?.call(
        '临时员工 ${tag.id} 已完成，但完成注入通道未接线：结果只留在会话历史里',
      );
      return;
    }
    finished(turn.ownerAgentId, turn.sessionId, _noticeText(target, result), tag);
  }

  // ── 复用解析 ─────────────────────────────────────────────────────────

  /// 解析复用入口（id 或显示名）：**只在同一会话内**有效。
  ///
  /// 跨会话一律给可读错误：拿另一个会话的旧 id 来复用，既不静默新建、也不错误命中
  /// 同名条目（用户 2026-10-04 的硬断言）。
  ({CoreSubagent? record, String? error}) _resolveReuse({
    required String ownerAgentId,
    required String sessionId,
    required String ref,
  }) {
    final List<CoreSubagent> here = registry.records(ownerAgentId, sessionId);
    final List<CoreSubagent> byId = here
        .where((CoreSubagent s) => s.id == ref)
        .toList(growable: false);
    if (byId.isNotEmpty) return (record: byId.first, error: null);
    final List<CoreSubagent> byName = here
        .where((CoreSubagent s) => s.name == ref)
        .toList(growable: false);
    if (byName.length == 1) return (record: byName.first, error: null);
    if (byName.length > 1) {
      return (
        record: null,
        error:
            '本会话有多个临时员工叫「$ref」：'
            '${byName.map((CoreSubagent s) => '${s.id}（层级 ${s.level}）').join('、')}'
            '—— 请改用 id 复用（subagent_id=<id>）。',
      );
    }
    final String foreign = _foreignReference(ownerAgentId, sessionId, ref);
    final String existing = here.isEmpty
        ? '本会话还没有临时员工。'
        : '本会话现有：'
              '${here.map((CoreSubagent s) => '${s.id}=${s.name}（层级 ${s.level}）').join('、')}。';
    if (foreign.isNotEmpty) {
      return (
        record: null,
        error:
            '该临时员工属于另一个会话，不能跨会话复用：'
            '${ref.startsWith(SubagentLimits.idPrefix) ? ref : '「$ref」'}'
            '$foreign。临时员工只活在它被召来的那个会话里（作用域 = 会话）；'
            '请在本会话新召一个（不填 subagent_id），或回到那个会话里继续用它。',
      );
    }
    return (
      record: null,
      error:
          '找不到要复用的临时员工：'
          '${ref.startsWith(SubagentLimits.idPrefix) ? ref : '「$ref」'}。$existing',
    );
  }

  /// 在**同一 agent 的其它会话**里找这个引用（跨会话复用的可读错误要用它）。
  ///
  /// 只在复用失败这条错误路径上跑，且每次查找都会把那个会话的名册装进内存
  /// （幂等缓存），因此代价有界。
  String _foreignReference(String ownerAgentId, String sessionId, String ref) {
    for (final CoreSession session in store.sessions(ownerAgentId)) {
      if (session.sessionId == sessionId) continue;
      for (final CoreSubagent other in store.subagents(
        ownerAgentId,
        session.sessionId,
      )) {
        if (other.id == ref || other.name == ref) {
          return '它在会话 ${session.sessionId} 里存在'
              '（临时员工「${other.name}」，id=${other.id}）';
        }
      }
    }
    return '';
  }

  // ── 组装运行配置 ─────────────────────────────────────────────────────

  /// 组装临时员工的运行配置：**继承发起者**的工作空间、SSH 口径、模型与成员级覆盖。
  ///
  /// 刻意不写 `workspaceDir`：工具根一路沿 `parentAgentId` 找到会话主人
  /// （`teamWorkspaceFor`），所以用户改了发起者的 `workspace_dir`，它跟着走；
  /// `sshConfig` 取发起者的**有效** SSH（成员跟随团队 TOP 的那份也算）。
  CoreAgent _buildAgent({
    required String id,
    required String name,
    required String scope,
    required CoreAgent caller,
    required String ownerAgentId,
    required int level,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String team = caller.teamId.trim().isNotEmpty
        ? caller.teamId.trim()
        : ownerAgentId;
    return CoreAgent(
      id: id,
      name: name,
      systemPrompt: subagentSystemPrompt(
        name: name,
        callerName: caller.name.trim().isEmpty ? caller.id : caller.name,
        level: level,
        scope: scope,
      ),
      modelId: caller.modelId,
      workspaceId: caller.workspaceId,
      sshConfig: teamSshConfigFor(caller, store.agent),
      teamId: team,
      parentAgentId: caller.id,
      level: level,
      role: '临时员工',
      duty: scope,
      canLeadTeam: false,
      // 父召来的，不走成员审核闸门：它当场就要干活
      reviewStatus: ReviewStatus.approved,
      reasoningEffort: caller.reasoningEffort,
      maxSeqlenOverride: caller.maxSeqlenOverride,
      maxOutputTokens: caller.maxOutputTokens,
      compressThreshold: caller.compressThreshold,
      thinkingOverride: caller.thinkingOverride,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 发起者的**有效模型**校验：说清缺什么、去哪配（不许静默失败）。
  String? _modelError(CoreAgent caller) {
    final String who = caller.name.trim().isEmpty ? caller.id : caller.name;
    final String modelId = caller.modelId.trim();
    if (modelId.isEmpty) {
      return '发起者「$who」没有可用模型：请先到「设置 → 自定义模型」添加模型，'
          '再到「团队成员 → 模型配置」（或该 agent 的设置页）为它选择一个模型——'
          '临时员工继承发起者的模型，发起者没有模型它就无从生成。';
    }
    if (settings.model(modelId) == null) {
      return '发起者「$who」配置的模型「$modelId」不在模型池里：'
          '请到「设置 → 自定义模型」补上这个模型（或改选一个已有模型）。';
    }
    return null;
  }

  // ── 文案 ─────────────────────────────────────────────────────────────

  static ToolOutcome _error(String message) =>
      ToolOutcome(message, isError: true);

  /// 结果头：**必须回传 id**（父 agent 的复用入口）。
  static String _header(CoreSubagent s, {required bool reused}) =>
      '【临时员工「${s.name}」】（id=${s.id}，层级 ${s.level}，'
      '本次=${reused ? '复用' : '新召'}；复用入口 subagent_id=${s.id}）';

  ToolOutcome _blockingOutcome(
    CoreSubagent s,
    SubagentTurnResult result, {
    required bool reused,
  }) {
    if (result.error.isNotEmpty) {
      return ToolOutcome(
        '${_header(s, reused: reused)}\n执行失败：${result.error}\n'
        '（可以复用同一个临时员工（subagent_id=${s.id}）把没做完的活接着做完，'
        '或换一个更小/更明确的任务新召一个。）',
        isError: true,
      );
    }
    final String report = result.report.trim();
    if (report.isEmpty) {
      return ToolOutcome(
        '${_header(s, reused: reused)}\n'
        '它跑完这一轮但**没有输出任何文本**（工作可能全在工具调用里）。'
        '需要结论时请在 task 里明确要求它以一段文字总结；'
        '也可以用 subagent_id=${s.id} 复用追问。',
      );
    }
    return ToolOutcome('${_header(s, reused: reused)}\n$report');
  }

  /// 后台完成时要注入发起者会话的那段话（[SubagentFinished] 的内容）。
  ///
  /// 公开而不是私有：界面直接给临时员工发的消息（[ConversationService.sendToSubagent]）
  /// 也走同一段话——同一件事不该有两种措辞。
  static String noticeText(CoreSubagent s, SubagentTurnResult result) =>
      _noticeText(s, result);

  static String _noticeText(CoreSubagent s, SubagentTurnResult result) {
    if (result.error.isNotEmpty) {
      return '【临时员工「${s.name}」（${s.id}）执行失败】\n${result.error}\n'
          '（可用 subagent_id=${s.id} 复用同一个临时员工接着做。）';
    }
    final String report = result.report.trim();
    if (report.isEmpty) {
      return '【临时员工「${s.name}」（${s.id}）已结束】\n'
          '它跑完这一轮但没有文本产出（工作可能全在工具调用里）；'
          '需要结论可用 subagent_id=${s.id} 复用追问。';
    }
    return '【临时员工「${s.name}」（${s.id}）完成报告】\n$report';
  }

  /// 职责/范围摘要（首个 task 的前若干字符）：复用判据 + 系统提示词都用它。
  static String _scopeOf(String task) {
    final String text = task.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }
}

/// 临时员工的**系统提示词**（用户明确要求写清复用与再派发的边界）。
///
/// 它继承发起者的**工作空间提示词文件**（`.self/system_prompt.md`，私有分栏归到
/// 会话主人 ⇒ 与发起者读同一份），这里追加的是"你是谁、能干什么、边界在哪"。
String subagentSystemPrompt({
  required String name,
  required String callerName,
  required int level,
  required String scope,
}) {
  final int remaining = SubagentLimits.maxDepth - level;
  return '''
你是「$name」——一个由「$callerName」在本次会话里现场召来的**临时员工**。

- **你没有历史、看不到发起者的会话**：task 里那段指令就是你全部的上下文。缺什么
  （文件路径、背景、验收标准、产出格式）就说明缺什么，不要假装知道。
- **工作空间与发起者是同一份**：直接读写文件、跑命令即可，工具结果里的路径就是真实路径。
- **干完必须给出一段最终报告**：做了什么、结论/产物在哪、还有什么没做完。
  不要只调工具不说话，也不要谎报完成；受阻就如实说清卡在哪。
- **你没有 team / message 工具**：你既不能被派活，也不能给团队成员派活/建队。
  需要用户决定时可以用 ask_user_question（问题会带上你的名字）。
- **复用规则（重要）**：只有当新任务与你**被召来时的职责/范围一致**时，
  发起者才应该复用你（同一个文件/模块/主题上的延续工作）；范围不同应由发起者
  新召一个。你被召来时的职责/范围：$scope
- **再派发（subagent）规则（重要）**：你也可以再召临时员工，但**只用于把同一个
  大任务拆细**给下级（例如你负责整个改造，把其中几个独立子项派下去）。
  你现在在第 $level 层，最多还能往下派 $remaining 层；**不许为绕开工具/权限/上下文
  限制而套娃**，也不要把整件事原样转包出去——你自己能干的部分不要往外推。
  并行的后台下级**共享同一个工作空间**，要按文件/目录划分各自的改写范围。
''';
}
