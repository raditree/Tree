import '../settings/core_settings.dart';
import '../store/tree_store.dart';
import '../util/ids.dart';
import 'team_model.dart';

/// 团队领域服务（M5b）：**成员就是 agent**，团队字段直接写进 `agents/<id>.yaml`。
///
/// 与参考实现（server 的 `teams` + `team_members` 两张表）的映射：
/// - TOP agent 的 `agents/<top>.yaml` 就是 teams 行（`max_level` /
///   `max_members_per_level`）；
/// - 成员是**独立 agent 文件**，`team_id` 指向 TOP、`parent_agent_id` 指直属上级，
///   因此用户能直接手改某个成员的 yaml（与本项目"绕开 UI 改配置"的一致策略）；
/// - `member_count` 一律按**实际成员数**回填（不是累加出来的计数器）；
/// - 每个成员有独立工作空间（默认 `<数据根>/workspaces/<member_id>`）。
///
/// 三条硬规则（都有自动化测试）：
/// 1. **没有模型写入口**：team 工具的 create/update/review 收到 `model_id` 一律报错，
///    模型只能由用户在「团队成员 → 模型配置」页（REST PATCH）分配；
/// 2. **新建成员恒为 `pending_model` 且 `model_id` 为空**，用户放行前不接收消息；
/// 3. **只能碰自己的子树**：不可移除自身/上级/非后代；目标有下级时必须显式 cascade。
class TeamService {
  TeamService({required this.store, this.settings, this.isWorking, this.log});

  final TreeStore store;

  /// 模型池（校验"模型存在"与计算 effective）；为 null 时跳过模型存在性校验。
  final CoreSettings? settings;

  /// working 的**唯一权威**（运行期任务表）；未接入时一律 idle。
  final bool Function(String agentId)? isWorking;

  final void Function(String message)? log;

  /// team 工具支持的 action（未知 action 的错误文案用）。
  static const List<String> actions = <String>[
    'list_teams',
    'list_members',
    'create_member',
    'remove_member',
    'query_member',
    'update_member',
    'review_member',
    'query_status',
  ];

  // ── 查询 ─────────────────────────────────────────────────────────────

  /// 全部顶部 agent（= 团队）。
  List<CoreAgent> teams() => store.teams();

  /// 某团队的全部成员（按创建时间升序；不含 TOP 自身）。
  List<CoreAgent> members(String teamId) => store.members(teamId);

  /// agent 所属团队 id（TOP 自身即团队 id）。
  String teamIdOf(String agentId) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return '';
    return agent.teamId.isEmpty ? agent.id : agent.teamId;
  }

  /// agent 的实时工作状态（working / idle）。
  String workStatus(String agentId) =>
      (isWorking?.call(agentId) ?? false) ? 'working' : 'idle';

  /// 审核闸门（M5c 派发前调用）：返回拒绝原因，null = 放行。
  ///
  /// 与参考实现一致：TOP / 非成员放行；rejected、未分配模型、未审核分别给出
  /// **可操作**的原因，且**先于模型解析**——否则未就绪成员会被静默跑起来。
  String? reviewBlock(String agentId) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return 'agent 不存在: $agentId';
    if (agent.teamId.isEmpty) return null;
    if (agent.reviewStatus == ReviewStatus.approved) return null;
    if (agent.reviewStatus == ReviewStatus.rejected) {
      return '已被用户驳回（review_status=rejected），不会接收任何消息';
    }
    if (agent.modelId.trim().isEmpty) {
      return '尚未分配模型（review_status=pending_model）：'
          '需用户在「团队成员 → 模型配置」页选择模型并审核通过';
    }
    final String status = agent.reviewStatus.isEmpty
        ? ReviewStatus.pendingReview
        : agent.reviewStatus;
    return '尚未通过用户审核（review_status=$status）：'
        '需用户在「团队成员 → 模型配置」页确认放行';
  }

  Map<String, dynamic> listTeams(String agentId) {
    final List<CoreAgent> list = teams();
    return <String, dynamic>{
      'teams': <Map<String, dynamic>>[
        for (final CoreAgent team in list)
          <String, dynamic>{
            'id': team.id,
            'name': team.name,
            'model_id': team.modelId,
            'workspace_id': team.workspaceId,
            'member_count': members(team.id).length,
          },
      ],
      'total': list.length,
      'generated_at': _timestamp(),
    };
  }

  Map<String, dynamic> listMembers(
    String agentId, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) {
    final CoreAgent? self = store.agent(agentId);
    if (self == null) return _error('agent 不存在: $agentId');
    final String teamId = teamIdOf(agentId);
    final CoreAgent? top = store.agent(teamId);
    final List<CoreAgent> all = members(teamId);
    final int? levelFilter = args['level'] is num
        ? (args['level'] as num).toInt()
        : null;
    final String statusFilter = (args['work_status'] ?? '').toString();

    bool keep(CoreAgent m) {
      if (levelFilter != null && m.level != levelFilter) return false;
      if (statusFilter.isNotEmpty && workStatus(m.id) != statusFilter) {
        return false;
      }
      return true;
    }

    final List<Map<String, dynamic>> direct = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> rest = <Map<String, dynamic>>[];
    int notReady = 0;
    for (final CoreAgent member in all) {
      if (ReviewStatus.needsUser(member.reviewStatus)) notReady++;
      if (!keep(member)) continue;
      final CoreAgent? leader = store.agent(member.parentAgentId);
      final bool isDirect = member.parentAgentId == self.id;
      final Map<String, dynamic> view = <String, dynamic>{
        ...memberView(
          member,
          leaderName: leader?.name ?? '',
          relation: isDirect ? MemberRelation.direct : _relation(self, member),
          workStatus: workStatus(member.id),
        ),
        'overrides': memberOverrides(member),
        'effective': _effective(member),
        'live_status': workStatus(member.id),
      };
      (isDirect ? direct : rest).add(view);
    }
    final List<Map<String, dynamic>> leaderView = <Map<String, dynamic>>[
      if (levelFilter == null || levelFilter == 0)
        <String, dynamic>{
          'id': self.id,
          'name': self.name,
          'role': self.role,
          'duty': self.duty,
          'model_id': self.modelId,
          'level': self.level,
          'can_lead_team': self.canLeadTeam,
          'parent_agent_id': self.parentAgentId,
          'leader_name': top?.name ?? self.name,
          'relation': MemberRelation.teamLeader,
          'work_status': workStatus(self.id),
          'review_status': self.reviewStatus,
          'log_path': memberLogPath(self.id),
          'created_at': self.createdAt,
          'workspace_id': self.workspaceId,
        },
    ];
    return <String, dynamic>{
      'groups': <String, dynamic>{
        'team_leader': leaderView,
        'teammates': direct,
        'team_member': rest,
      },
      'members': <Map<String, dynamic>>[...leaderView, ...direct, ...rest],
      'total': all.length,
      'not_ready_count': notReady,
      if (notReady > 0)
        'hint':
            '有 $notReady 名成员尚未就绪（等待用户在「团队成员 → 模型配置」页'
            '分配模型并审核），他们不会接收也不会执行任何消息。',
      'generated_at': _timestamp(),
    };
  }

  Map<String, dynamic> queryMember(String agentId, Map<String, dynamic> args) {
    final _Target? found = _resolve(agentId, args, action: 'query_member');
    if (found == null) return _lastError!;
    final CoreAgent member = found.member;
    final CoreAgent? leader = store.agent(member.parentAgentId);
    return <String, dynamic>{
      'member': <String, dynamic>{
        ...memberView(
          member,
          leaderName: leader?.name ?? '',
          relation: member.id == agentId
              ? MemberRelation.teamLeader
              : _relation(store.agent(agentId), member),
          workStatus: workStatus(member.id),
        ),
        'comment': member.comment,
        'scores': member.scores,
        'system_prompt': member.systemPrompt,
        'overrides': memberOverrides(member),
      },
      'generated_at': _timestamp(),
    };
  }

  Map<String, dynamic> queryStatus(String agentId, Map<String, dynamic> args) {
    final _Target? found = _resolve(agentId, args, action: 'query_status');
    if (found == null) return _lastError!;
    final CoreAgent member = found.member;
    return <String, dynamic>{
      'member_id': member.id,
      'name': member.name,
      'work_status': workStatus(member.id),
      'last_active_at': member.updatedAt,
      'log_path': memberLogPath(member.id),
      'hint': '日志路径相对该成员自己的工作空间；leader 可直接 read/grep 共享目录。',
      'generated_at': _timestamp(),
    };
  }

  // ── 变更 ─────────────────────────────────────────────────────────────

  Map<String, dynamic> createMember(String agentId, Map<String, dynamic> args) {
    final CoreAgent? self = store.agent(agentId);
    if (self == null) return _error('agent 不存在: $agentId');
    if (_hasValue(args['model_id'])) {
      return _error(
        'team 工具无权为成员分配模型',
        hint:
            '成员模型由用户本人在「团队成员 → 模型配置」页亲自选择，你无权代替；'
            '请直接创建成员（不要传 model_id），创建后提示用户去配置模型并审核',
      );
    }
    final String teamId = teamIdOf(agentId);
    final CoreAgent? top = store.agent(teamId);
    final int maxLevel = TeamLimits.level(top?.maxLevel);
    final int maxMembers = TeamLimits.members(top?.maxMembersPerLevel);

    // 校验顺序（与参考实现一致）：层级 → 带队权 → 直属人数 → 名称
    if (self.level >= maxLevel) {
      return _error(
        '已达最大层级（Level $maxLevel），不可继续创建子团队',
        hint: '可由更上层 leader 创建，或先用 message send_message 把工作派给现有成员',
      );
    }
    if (!self.canLeadTeam) {
      return _error(
        '当前成员不可创建子团队（can_lead_team=False）',
        hint: '如需带队权限，请让你的直属 leader 用 team update_member 将你的 can_lead_team 置为 true',
      );
    }
    final int directCount = members(teamId)
        .where((CoreAgent m) => m.parentAgentId == self.id)
        .length;
    if (directCount >= maxMembers) {
      return _error(
        '你的直属成员数量已达上限（$maxMembers），不可继续创建成员',
        hint: '可把新工作交给现有直属成员，由其再分工',
      );
    }
    final String name = (args['member_name'] ?? args['name'] ?? '')
        .toString()
        .trim();
    if (name.isEmpty) return _error('成员名称不能为空');
    if (members(teamId).any((CoreAgent m) => m.name == name)) {
      return _error(
        '成员名称已存在: $name',
        hint: '团队内成员名称需唯一（按名称寻址依赖唯一性），请换一个名称后重试，或先用 list_members 查看现有成员',
      );
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    final String memberId = CoreIds.next('member');
    final CoreAgent member = CoreAgent(
      id: memberId,
      name: name,
      systemPrompt: (args['system_prompt'] ?? '').toString(),
      // 模型**绝不继承 TOP**：新建成员恒为空模型 + pending_model
      modelId: '',
      workspaceId: 'ws_$memberId',
      teamId: teamId,
      parentAgentId: self.id,
      level: self.level + 1,
      role: (args['role'] ?? '').toString(),
      duty: (args['duty'] ?? '').toString(),
      canLeadTeam: args['can_lead_team'] as bool? ?? true,
      reviewStatus: ReviewStatus.pendingModel,
      createdAt: now,
      updatedAt: now,
    );
    store.putAgent(member);
    _syncTopCount(teamId);
    log?.call('创建成员 ${member.id}（$name，level=${member.level}）等待用户配置模型');
    return <String, dynamic>{
      'member_id': member.id,
      'name': member.name,
      'role': member.role,
      'duty': member.duty,
      'model_id': member.modelId,
      'review_status': member.reviewStatus,
      'level': member.level,
      'can_lead_team': member.canLeadTeam,
      'workspace_id': member.workspaceId,
      'log_path': memberLogPath(member.id),
      'created_at': member.createdAt,
      'initialized': false,
      'persisted': true,
      'hint':
          '成员已创建，但处于等待用户处理状态（review_status=${member.reviewStatus}）：'
          '请让用户在「团队成员 → 模型配置」页为其选择模型并审核通过后，'
          '该成员才会接收并执行消息。在此之前它无法工作。',
      'generated_at': _timestamp(),
    };
  }

  Map<String, dynamic> removeMember(String agentId, Map<String, dynamic> args) {
    final CoreAgent? self = store.agent(agentId);
    if (self == null) return _error('agent 不存在: $agentId');
    final _Target? found = _resolve(agentId, args, action: 'remove_member');
    if (found == null) return _lastError!;
    final CoreAgent target = found.member;
    final String teamId = teamIdOf(agentId);
    if (target.id == teamId) {
      return _error(
        '不可移除团队所有者: $teamId',
        hint: '只能移除自己的直属/下级成员；解散团队请删除该顶层 agent',
      );
    }
    if (target.id == self.id) {
      return _error('不可移除自己', hint: '如需退出请由你的直属 leader 调用 remove_member');
    }
    if (_isAncestor(candidate: target, node: self)) {
      return _error(
        '不可移除自己的上级: ${target.name}',
        hint: '只能移除自己的直属/下级成员；上级由更上层 leader 管理',
      );
    }
    if (!_isDescendant(candidate: target, ancestor: self)) {
      return _error(
        '不可移除非直属/下级成员: ${target.name}',
        hint: '只能移除自己的下级；平级成员请由你们的共同 leader 处理',
      );
    }
    final List<CoreAgent> subtree = _subtree(target);
    final bool cascade = args['cascade'] as bool? ?? true;
    if (subtree.length > 1 && !cascade) {
      return <String, dynamic>{
        'error': '成员 ${target.name} 仍有 ${subtree.length - 1} 个下级成员，未指定 cascade',
        'cascade_required': subtree
            .where((CoreAgent m) => m.id != target.id)
            .map((CoreAgent m) => m.id)
            .toList(),
        'hint': '请显式传 cascade=true 连同下级子树一并移除，或先逐个移除其下级（避免留下孤儿成员）',
      };
    }
    // 先删叶子再删根（父先于子的逆序），避免留下"父没了子还在"的中间态
    final List<String> removed = <String>[];
    for (final CoreAgent member in subtree.reversed) {
      if (store.deleteAgent(member.id)) removed.add(member.id);
    }
    _syncTopCount(teamId);
    log?.call('移除成员 ${target.id} 及其 ${removed.length - 1} 个下级');
    return <String, dynamic>{
      'member_id': target.id,
      'name': target.name,
      'level': target.level,
      'removed_ids': removed,
      'subtree_removed': removed.where((String id) => id != target.id).toList(),
      'cascade': cascade,
      'persisted': true,
      'roster_pushed': removed.length,
      if (removed.length > 1)
        'hint': '已连同 ${removed.length - 1} 个下级成员一并移除；其工作空间已回收，磁盘数据保留供审计',
      'generated_at': _timestamp(),
    };
  }

  Map<String, dynamic> updateMember(String agentId, Map<String, dynamic> args) {
    final _Target? found = _resolve(agentId, args, action: 'update_member');
    if (found == null) return _lastError!;
    final CoreAgent member = found.member;
    if (_hasValue(args['model_id'])) {
      return _error(
        'team 工具无权修改成员模型',
        hint: '成员模型由用户本人在「团队成员 → 模型配置」页亲自选择，你无权代替；如需变更请提示用户去该页操作',
      );
    }
    if (_hasValue(args['work_status'])) {
      return _error(
        'work_status 为只读字段（由实际执行状态决定），请勿通过 update_member 设置；如需停止成员请使用前端「停止」按钮',
      );
    }
    final List<String> updated = <String>[];

    if (args.containsKey('name')) {
      final String name = (args['name'] ?? '').toString().trim();
      if (name.isEmpty) return _error('成员名称不能为空');
      final bool duplicate = members(teamIdOf(agentId))
          .any((CoreAgent m) => m.id != member.id && m.name == name);
      if (duplicate) {
        return _error('成员名称已存在: $name', hint: '团队内名称需唯一，请换名');
      }
      member.name = name;
      updated.add('name');
    }
    for (final MapEntry<String, String> field in <String, String>{
      'role': 'role',
      'duty': 'duty',
      'comment': 'comment',
      'system_prompt': 'system_prompt',
    }.entries) {
      if (!args.containsKey(field.key)) continue;
      final String value = (args[field.key] ?? '').toString();
      switch (field.value) {
        case 'role':
          member.role = value;
        case 'duty':
          member.duty = value;
        case 'comment':
          member.comment = value;
        case 'system_prompt':
          member.systemPrompt = value;
      }
      updated.add(field.key);
    }
    if (args.containsKey('can_lead_team')) {
      member.canLeadTeam = args['can_lead_team'] as bool? ?? member.canLeadTeam;
      updated.add('can_lead_team');
    }
    if (args.containsKey('scores')) {
      member.scores = _scores(args['scores']);
      updated.add('scores');
    }
    if (updated.isEmpty) {
      return _error(
        '未提供任何可更新的字段',
        hint:
            '可更新字段：name/role/duty/can_lead_team/comment/system_prompt/scores'
            '（work_status 只读，模型由用户在模型配置页设置）',
      );
    }
    member.updatedAt = DateTime.now().millisecondsSinceEpoch;
    store.putAgent(member);
    return <String, dynamic>{
      'member_id': member.id,
      'updated': updated,
      'member': _profile(member),
      'roster_pushed': 1,
      'generated_at': _timestamp(),
    };
  }

  Map<String, dynamic> reviewMember(String agentId, Map<String, dynamic> args) {
    final _Target? found = _resolve(agentId, args, action: 'review_member');
    if (found == null) return _lastError!;
    final CoreAgent member = found.member;
    if (_hasValue(args['model_id'])) {
      return _error(
        'team 工具无权为成员分配模型',
        hint: '成员模型由用户本人在「团队成员 → 模型配置」页亲自选择；本 action 只能同步审核状态',
      );
    }
    final String raw = args.containsKey('review_status')
        ? (args['review_status'] ?? '').toString().trim()
        : ((args['approve'] as bool? ?? true)
              ? ReviewStatus.approved
              : ReviewStatus.rejected);
    if (!ReviewStatus.isValid(raw)) {
      return _error(
        '审核状态非法: $raw',
        hint: '可用状态：approved（审核通过）/ rejected（驳回）/ pending_review（待审核）',
      );
    }
    member.reviewStatus = raw;
    member.updatedAt = DateTime.now().millisecondsSinceEpoch;
    store.putAgent(member);
    return <String, dynamic>{
      'member_id': member.id,
      'name': member.name,
      'review_status': member.reviewStatus,
      'model_id': member.modelId,
      'roster_pushed': 1,
      'hint': _reviewHint(member),
      'generated_at': _timestamp(),
    };
  }

  /// 工具入口：按 `action` 分发（未知 action 返回可读错误而不是抛异常）。
  Map<String, dynamic> run(String agentId, Map<String, dynamic> args) {
    final String action = (args['action'] ?? '').toString().trim();
    switch (action) {
      case 'list_teams':
        return listTeams(agentId);
      case 'list_members':
        return listMembers(agentId, args: args);
      case 'create_member':
        return createMember(agentId, args);
      case 'remove_member':
        return removeMember(agentId, args);
      case 'query_member':
        return queryMember(agentId, args);
      case 'update_member':
        return updateMember(agentId, args);
      case 'review_member':
        return reviewMember(agentId, args);
      case 'query_status':
        return queryStatus(agentId, args);
      default:
        return _error(
          '未知 action: $action',
          hint: '本工具支持的 action：${(<String>[...actions]..sort()).join('、')}',
        );
    }
  }

  // ── 用户侧（REST PATCH：唯一的模型写入口） ───────────────────────────

  /// 用户为成员分配模型 / 同步审核状态 / 调整成员级模型参数覆盖。
  ///
  /// 这是**唯一**能改 `model_id` 的入口（team 工具三处都拒绝），因此审核状态与
  /// 模型分配在这里联动：改模型 → 自动进入 `pending_review` 或回退 `pending_model`。
  Map<String, dynamic> assignModel({
    required String topId,
    required String memberId,
    required Map<String, dynamic> body,
  }) {
    final CoreAgent? member = store.agent(memberId);
    if (member == null) return _error('成员不存在: $memberId');
    final String teamId = teamIdOf(memberId);
    if (member.teamId.isEmpty || teamId != topId) {
      return _error('成员不存在: $memberId');
    }
    final bool hasModel = body.containsKey('model_id');
    final bool hasReview = body.containsKey('review_status');
    final List<String> overrideKeys = MemberOverrideKeys.all
        .where(body.containsKey)
        .toList(growable: false);
    if (!hasModel && !hasReview && overrideKeys.isEmpty) {
      return _error(
        '至少提供 model_id / review_status / 模型参数覆盖之一'
        '（可覆盖项：${MemberOverrideKeys.all.join(', ')}）',
      );
    }
    if (hasModel) {
      final String modelId = (body['model_id'] ?? '').toString().trim();
      if (modelId.isNotEmpty && settings?.model(modelId) == null) {
        return _error('模型不存在: $modelId（可先用 GET /api/models 获取可用模型池）');
      }
      member.modelId = modelId;
      member.reviewStatus = hasReview
          ? (body['review_status'] ?? '').toString().trim()
          : ReviewStatus.fromModelId(modelId);
    }
    if (hasReview) {
      final String status = (body['review_status'] ?? '').toString().trim();
      if (!ReviewStatus.isValid(status)) {
        return _error('审核状态非法: $status（可选: ${ReviewStatus.all.join(', ')}）');
      }
      member.reviewStatus = status;
    }
    for (final String key in overrideKeys) {
      final Object? value = body[key];
      switch (key) {
        case MemberOverrideKeys.reasoningEffort:
          member.reasoningEffort = (value ?? '').toString().trim();
        case MemberOverrideKeys.maxSeqlen:
          final int? parsed = _positiveInt(value);
          if (value != null && parsed == null) {
            return _error('$key 必须为正整数');
          }
          member.maxSeqlenOverride = parsed ?? 0;
        case MemberOverrideKeys.maxOutputTokens:
          final int? parsed = _positiveInt(value);
          if (value != null && parsed == null) {
            return _error('$key 必须为正整数');
          }
          member.maxOutputTokens = parsed ?? 0;
        case MemberOverrideKeys.compressThreshold:
          final double? parsed = value == null
              ? null
              : double.tryParse(value.toString());
          if (value != null &&
              (parsed == null || parsed < 0.1 || parsed > 0.95)) {
            return _error('compress_threshold 必须在 0.1~0.95 之间');
          }
          member.compressThreshold = parsed ?? 0;
      }
    }
    member.updatedAt = DateTime.now().millisecondsSinceEpoch;
    store.putAgent(member);
    final CoreAgent? top = store.agent(topId);
    return <String, dynamic>{
      'success': true,
      'member': <String, dynamic>{
        ..._profile(member),
        'overrides': memberOverrides(member),
        'effective': _effective(member),
        'live_status': workStatus(member.id),
      },
      'top_agent_name': top?.name ?? '',
    };
  }

  /// `GET /api/agents/{id}/teammates` 的响应体。
  Map<String, dynamic> teammatesPayload(String agentId) {
    final CoreAgent? self = store.agent(agentId);
    if (self == null) {
      return <String, dynamic>{
        'agent_id': agentId,
        'members': <Map<String, dynamic>>[],
        'pending_member_count': 0,
      };
    }
    final String teamId = teamIdOf(agentId);
    final List<CoreAgent> all = members(teamId);
    int pending = 0;
    final List<Map<String, dynamic>> views = <Map<String, dynamic>>[];
    for (final CoreAgent member in all) {
      if (ReviewStatus.needsUser(member.reviewStatus)) pending++;
      final CoreAgent? leader = store.agent(member.parentAgentId);
      views.add(<String, dynamic>{
        ...memberView(
          member,
          leaderName: leader?.name ?? '',
          relation: _relation(self, member),
          workStatus: workStatus(member.id),
        ),
        'overrides': memberOverrides(member),
        'effective': _effective(member),
        'live_status': workStatus(member.id),
      });
    }
    return <String, dynamic>{
      'agent_id': agentId,
      'members': views,
      'pending_member_count': pending,
    };
  }

  // ── 内部 ─────────────────────────────────────────────────────────────

  Map<String, dynamic>? _lastError;

  static bool _hasValue(Object? raw) =>
      raw != null && raw.toString().trim().isNotEmpty;

  static int? _positiveInt(Object? raw) {
    if (raw == null) return null;
    final int? value = raw is num ? raw.toInt() : int.tryParse(raw.toString());
    if (value == null || value <= 0) return null;
    return value;
  }

  Map<String, dynamic> _error(String message, {String hint = ''}) =>
      <String, dynamic>{'error': message, if (hint.isNotEmpty) 'hint': hint};

  /// 成员详情（含 comment/scores/system_prompt；仅 query/update 用）。
  Map<String, dynamic> _profile(CoreAgent member) => <String, dynamic>{
    ...memberView(
      member,
      leaderName: store.agent(member.parentAgentId)?.name ?? '',
      relation: MemberRelation.teamLeader,
      workStatus: workStatus(member.id),
    ),
    'comment': member.comment,
    'scores': member.scores,
    'system_prompt': member.systemPrompt,
  };

  static Map<String, double> _scores(Object? raw) {
    if (raw is! Map) return <String, double>{};
    final Map<String, double> out = <String, double>{};
    raw.forEach((dynamic key, dynamic value) {
      final double? parsed = value is num
          ? value.toDouble()
          : double.tryParse(value?.toString() ?? '');
      if (parsed != null) out[key.toString()] = parsed.clamp(0, 10).toDouble();
    });
    return out;
  }

  /// 有效模型参数（模型默认值 + 成员覆盖）。
  Map<String, Object?> _effective(CoreAgent member) {
    final CoreModelConfig? model = settings?.model(member.modelId);
    return <String, Object?>{
      MemberOverrideKeys.reasoningEffort:
          member.reasoningEffort.trim().isNotEmpty
          ? member.reasoningEffort
          : (model?.reasoningEffort ?? ''),
      MemberOverrideKeys.maxSeqlen: member.maxSeqlenOverride > 0
          ? member.maxSeqlenOverride
          : model?.effectiveMaxSeqlen,
      MemberOverrideKeys.maxOutputTokens: member.maxOutputTokens > 0
          ? member.maxOutputTokens
          : (model?.maxOutputTokens ?? 0),
    };
  }

  String _reviewHint(CoreAgent member) {
    if (member.reviewStatus == ReviewStatus.approved) {
      return '该成员已可接收并执行消息';
    }
    if (member.reviewStatus == ReviewStatus.rejected) {
      return '该成员已被驳回，不会接收任何消息';
    }
    if (member.modelId.trim().isEmpty) {
      return '该成员尚未分配模型，仍不可工作：请让用户在「团队成员 → 模型配置」页选择模型';
    }
    return '模型已分配但尚未审核通过，该成员仍不可工作';
  }

  /// 团队成员 + 上级链上的"自身/上级"判断。
  List<CoreAgent> _subtree(CoreAgent root) {
    final String teamId = teamIdOf(root.id);
    final List<CoreAgent> all = members(teamId);
    final Map<String, List<CoreAgent>> children = <String, List<CoreAgent>>{};
    for (final CoreAgent member in all) {
      children
          .putIfAbsent(member.parentAgentId, () => <CoreAgent>[])
          .add(member);
    }
    final List<CoreAgent> out = <CoreAgent>[root];
    for (int i = 0; i < out.length; i++) {
      out.addAll(children[out[i].id] ?? const <CoreAgent>[]);
    }
    return out;
  }

  bool _isAncestor({required CoreAgent candidate, required CoreAgent node}) {
    CoreAgent? cursor = store.agent(node.parentAgentId);
    int guard = 0;
    while (cursor != null && guard++ < 64) {
      if (cursor.id == candidate.id) return true;
      cursor = cursor.parentAgentId.isEmpty
          ? null
          : store.agent(cursor.parentAgentId);
    }
    return false;
  }

  bool _isDescendant({
    required CoreAgent candidate,
    required CoreAgent ancestor,
  }) {
    if (candidate.id == ancestor.id) return false;
    if (candidate.parentAgentId == ancestor.id) return true;
    return _subtree(ancestor).any((CoreAgent m) => m.id == candidate.id);
  }

  String _relation(CoreAgent? self, CoreAgent member) {
    if (self == null) return MemberRelation.indirect;
    if (member.id == self.id) return MemberRelation.teamLeader;
    if (member.parentAgentId == self.id) return MemberRelation.direct;
    if (member.parentAgentId == self.parentAgentId &&
        member.parentAgentId.isNotEmpty) {
      return MemberRelation.peer;
    }
    return MemberRelation.indirect;
  }

  /// 解析 action 的目标成员（`target_member_id` → `member_id` → `member_name`）。
  _Target? _resolve(
    String agentId,
    Map<String, dynamic> args, {
    required String action,
  }) {
    final Object? raw =
        args['target_member_id'] ?? args['member_id'] ?? args['member_name'];
    final String target = (raw ?? '').toString().trim();
    if (target.isEmpty) {
      _lastError = _error(
        '缺少 target_member_id',
        hint: action == 'query_member'
            ? '请用 list_members 查看当前团队的有效成员名单（支持按名称寻址）'
            : '请用 list_members 查看有效成员名单',
      );
      return null;
    }
    final String teamId = teamIdOf(agentId);
    for (final CoreAgent member in <CoreAgent>[
      if (store.agent(teamId) != null) store.agent(teamId)!,
      ...members(teamId),
    ]) {
      if (member.id == target || member.name == target) {
        return _Target(member);
      }
    }
    _lastError = _error(
      '成员不存在: $target',
      hint: action == 'query_member'
          ? '请用 list_members 查看当前团队的有效成员名单（支持按名称寻址）'
          : '请用 list_members 查看有效成员名单',
    );
    return null;
  }

  /// member_count 按**实际成员数**回填（不累加）。
  void _syncTopCount(String teamId) {
    final CoreAgent? top = store.agent(teamId);
    if (top == null) return;
    final int count = members(teamId).length;
    if (top.teamMemberCount == count) return;
    top.teamMemberCount = count;
    store.putAgent(top);
  }

  static String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}

/// 目标成员解析结果。
class _Target {
  _Target(this.member);
  final CoreAgent member;
}
