import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../models/message.dart';
import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/websocket_service.dart';
import 'message_list.dart';

/// teammates 工作进度窗口
///
/// 进入时展示该 agent 的团队成员拓扑：根节点为当前 agent，下面按层级
/// （Level 1/2/…）分组展示各成员。每个成员卡片显示名称、状态
/// （working/idle）、模型、层级与评价。点击成员可进入其工作进度详情页
/// （进度消息与工具卡片、活动日志、直接发消息）。
/// 团队成员与 leader 共享工作目录 base，故不提供单独的文件浏览。
class TeammatesWindowPage extends StatefulWidget {
  final Agent agent;

  /// 打开窗口时的当前会话 id；透传给成员进度页，使历史/实时按会话过滤
  final String sessionId;

  /// 成员配置变更后的回调（透传到成员详情页；主界面据此重拉 agent 列表，
  /// 刷新待处理成员红点——本窗口自身的计数由 [_load] 刷新）
  final VoidCallback? onMembersChanged;

  const TeammatesWindowPage({
    super.key,
    required this.agent,
    required this.sessionId,
    this.onMembersChanged,
  });

  @override
  State<TeammatesWindowPage> createState() => _TeammatesWindowPageState();
}

class _TeammatesWindowPageState extends State<TeammatesWindowPage> {
  List<Map<String, dynamic>> _members = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  /// 等待用户处理的成员数（未分配模型 / 待审核）——顶部红色提示条
  int _pendingCount = 0;

  /// 实时 working 的成员 ID 集合（通过 WS agent_status 更新）
  final Set<String> _workingMembers = <String>{};

  /// WebSocket 服务（复用主连接，监听 agent_status）
  final WebSocketService _webSocket = WebSocketService();
  bool _wsConnected = false;

  @override
  void initState() {
    super.initState();
    _webSocket.onMessage = _handleWsMessage;
    // 连接建立/重连时清空 working 集合：后端重启会清空其内存态 _active_tasks，
    // 若不清空，前端会残留旧的 working（成员已 idle 却显示工作中）。
    // 清空后由后端在 WS 建立时补推真实的 agent_status（仍在工作的才重新标记）。
    _webSocket.onConnectionChange = (bool connected) {
      if (connected && mounted) {
        setState(() {
          _workingMembers.clear();
        });
      }
    };
    _connectWs();
    _load();
  }

  @override
  void dispose() {
    _webSocket.disconnect();
    super.dispose();
  }

  Future<void> _connectWs() async {
    if (_wsConnected) return;
    final AuthService auth = AuthService();
    final String? token = await auth.getToken();
    if (token == null || token.isEmpty) return;
    _webSocket.connect(token);
    _wsConnected = true;
  }

  void _handleWsMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    final String? type = data['type'] as String?;
    if (type == 'agent_status') {
      final Map<String, dynamic> d =
          (data['data'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
              {};
      final String? agentId = d['agent_id'] as String?;
      final String? status = d['status'] as String?;
      if (agentId == null) return;
      // 会话隔离：仅反映本窗口会话的状态；事件带 session_id 且不属于本会话时
      // 忽略（避免成员在其他会话工作时本窗口误显示"工作中"）。
      final String? sessionId = d['session_id'] as String?;
      if (sessionId != null && sessionId != widget.sessionId) return;
      setState(() {
        if (status == 'working' ||
            status == 'updating_memory' ||
            status == 'compacting') {
          _workingMembers.add(agentId);
        } else if (status == 'idle' || status == 'stopping') {
          _workingMembers.remove(agentId);
        }
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> data =
          await ApiService.getTeammatesPayload(widget.agent.id);
      final List<dynamic> raw = data['members'] as List<dynamic>? ?? <dynamic>[];
      final List<Map<String, dynamic>> members = raw
          .map((dynamic e) =>
              (e as Map<dynamic, dynamic>).cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() {
        _members = members;
        _pendingCount = (data['pending_member_count'] as num?)?.toInt() ??
            members
                .where((Map<String, dynamic> m) =>
                    _needsUserAction(m['review_status'] as String? ?? ''))
                .length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 该审核状态是否"等待用户处理"（与后端 REVIEW_STATUS_NEEDS_USER 同一口径）。
  static bool _needsUserAction(String status) =>
      status == 'pending_model' || status == 'pending_review';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.agent.name} 的团队'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('加载失败：$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_members.isEmpty) {
      return const Center(
        child: Text('该 agent 尚未创建任何团队成员。\n可通过 team 工具创建。',
            textAlign: TextAlign.center),
      );
    }
    // 拓扑：根为 leader，成员按层级（Level 1/2/…）分组展示
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (_pendingCount > 0) _buildPendingBanner(),
        _buildLeaderCard(),
        const SizedBox(height: 16),
        ..._buildLevelGroups(),
      ],
    );
  }

  /// 顶部红色提示条：有成员等待用户分配模型 / 审核。
  ///
  /// 成员在这之前**完全不工作**（后端审核闸拒收消息），必须让用户一眼看到
  /// 入口在哪，否则表现为"派活了但成员毫无反应"。
  Widget _buildPendingBanner() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有 $_pendingCount 名成员尚未就绪：需要你分配模型并审核后才会工作。'
              '点开对应成员 →「模型配置」页处理',
              style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  /// 将成员按 Level 分组，生成「Level N」分组标题与成员卡片
  List<Widget> _buildLevelGroups() {
    final Map<int, List<Map<String, dynamic>>> byLevel =
        <int, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> m in _members) {
      final int level = (m['level'] as num?)?.toInt() ?? 1;
      byLevel.putIfAbsent(level, () => <Map<String, dynamic>>[]).add(m);
    }
    final List<int> levels = byLevel.keys.toList()..sort();
    final List<Widget> children = <Widget>[];
    for (final int level in levels) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Level $level 成员',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ));
      children.addAll(byLevel[level]!.map(_buildMemberCard));
    }
    return children;
  }

  Widget _buildLeaderCard() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withOpacity(0.4)),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 18,
            backgroundColor: cs.primary,
            child: Text(
              widget.agent.name.isNotEmpty ? widget.agent.name[0] : 'L',
              style: TextStyle(color: cs.onPrimary, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.agent.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Level 0 · 团队负责人',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberCard(Map<String, dynamic> member) {
    final cs = Theme.of(context).colorScheme;
    final String name = member['name'] as String? ?? '';
    final String id = member['id'] as String? ?? '';
    final String model = member['model_id'] as String? ?? '';
    final int level = (member['level'] as num?)?.toInt() ?? 0;
    final String comment = member['comment'] as String? ?? '';
    final String reviewStatus = member['review_status'] as String? ?? '';
    final bool needsAction = _needsUserAction(reviewStatus);
    // 实时状态：优先用 WS 维护的集合，回退到 API 返回的 live_status
    final bool working = _workingMembers.contains(id) ||
        (member['live_status'] as String?) == 'working';
    final Color statusColor =
        working ? Colors.orange : cs.outline;
    final String statusText = working ? '工作中' : '空闲';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      // 待处理成员用错误色描边，与顶部提示条呼应（一眼看出该点哪个）
      shape: needsAction
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.error, width: 1),
            )
          : null,
      child: ListTile(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TeammateDetailPage(
                leader: widget.agent,
                memberId: id,
                memberName: name.isNotEmpty ? name : id,
                sessionId: widget.sessionId,
                member: member,
                // 子页面处理完审核/赋模型后回到本页需要刷新计数与列表；
                // 同时通知主界面重拉 agent 列表（agent 列表红点同一口径）
                onChanged: () async {
                  await _load();
                  widget.onMembersChanged?.call();
                },
              ),
            ),
          );
        },
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: needsAction
              ? cs.errorContainer
              : (working
                  ? Colors.orange.withOpacity(0.2)
                  : cs.surfaceVariant),
          child: Icon(
            needsAction
                ? Icons.report_problem_outlined
                : (working ? Icons.sync : Icons.person),
            size: 18,
            color: needsAction
                ? cs.onErrorContainer
                : (working ? Colors.orange : cs.onSurfaceVariant),
          ),
        ),
        title: Text(
          name.isNotEmpty ? name : id,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              'Level $level · ${model.isEmpty ? '未分配模型' : model}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            if (needsAction)
              Text(
                _reviewHint(reviewStatus),
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            if (comment.isNotEmpty)
              Text(
                comment,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: statusColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(statusText,
                style: TextStyle(fontSize: 11, color: statusColor)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  /// 审核状态的中文提示（与后端拒绝原因同一口径）。
  static String _reviewHint(String status) {
    switch (status) {
      case 'pending_model':
        return '待分配模型（点开选择模型并审核后才能工作）';
      case 'pending_review':
        return '待审核（模型已选，点开确认放行）';
      case 'rejected':
        return '已驳回（不会接收任何消息）';
      default:
        return '';
    }
  }
}

/// 单个团队成员的工作进度详情页
///
/// 包含三部分：
/// - 进度：实时消息与工具调用卡片（订阅 WebSocket，按 agent_id 过滤）
/// - 模型配置：为用户分配成员模型 + 审核放行（成员就绪的唯一入口）
/// - 消息：直接向成员发送消息
/// （成员与 leader 共享工作目录 base，文件由主界面右侧文件栏展示，
///   此处不再提供独立的成员文件浏览。原「日志」Tab 已移除：成员日志由
///   leader agent 直接 read/grep 共享工作目录，用户侧更需要的是赋模型入口。）
class TeammateDetailPage extends StatefulWidget {
  final Agent leader;
  final String memberId;
  final String memberName;

  /// 当前会话 id：历史加载与实时 WS 均按该会话过滤，避免跨会话混杂
  final String sessionId;

  /// 定位目标消息 id（右侧「问题回复」成员提问导航触发；历史加载后滚动定位）
  final String? scrollToMessageId;

  /// 该成员的名单行（含 model_id / review_status / role / duty 等）
  final Map<String, dynamic>? member;

  /// 配置变更后的回调（父页面刷新成员列表与待处理计数）
  final Future<void> Function()? onChanged;

  const TeammateDetailPage({
    super.key,
    required this.leader,
    required this.memberId,
    required this.memberName,
    required this.sessionId,
    this.scrollToMessageId,
    this.member,
    this.onChanged,
  });

  @override
  State<TeammateDetailPage> createState() => _TeammateDetailPageState();
}

class _TeammateDetailPageState extends State<TeammateDetailPage> {
  final WebSocketService _webSocket = WebSocketService();
  final List<ChatMessage> _liveMessages = <ChatMessage>[];
  int _scrollRevision = 0;
  bool _wsConnected = false;
  String? _selectedTab = 'progress';

  /// MessageList 定位触发号（右侧「问题回复」成员提问导航用）
  int _scrollToRevision = 0;

  /// MessageList 定位目标消息 id
  String? _scrollToMessageId;

  /// 成员名单行（模型配置页的数据源；配置成功后就地更新）
  late Map<String, dynamic> _member;

  /// 可用模型池（模型配置页下拉）
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  bool _modelsLoading = false;
  String? _modelsError;

  /// 模型配置页当前选中的模型 id（'' = 未选择）
  String _selectedModelId = '';

  /// 成员级模型参数覆盖（留空 = 未设置 → 沿用 TOP / 模型默认）
  ///
  /// 键与后端覆盖列一致：``reasoning_effort`` / ``max_seqlen`` /
  /// ``max_output_tokens`` / ``compress_threshold``。
  final Map<String, String> _overrideText = <String, String>{
    'reasoning_effort': '',
    'max_seqlen': '',
    'max_output_tokens': '',
    'compress_threshold': '',
  };

  /// 进入本页时各覆盖项的原始文本，用于判断"用户是否改过这一项"
  /// （未改过就不提交该键 → 后端保持原值；改空 → 显式清除，回退 TOP）
  final Map<String, String> _overrideInitial = <String, String>{};

  /// 是否正在提交配置
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _member = Map<String, dynamic>.from(widget.member ?? <String, dynamic>{});
    _selectedModelId = _member['model_id'] as String? ?? '';
    _syncOverrideControllers();
    _webSocket.onMessage = _handleIncoming;
    _connectWs();
    _loadHistory();
    _loadModels();
  }

  /// 用成员自身的覆盖值回填控件（null = 未设置 → 留空）
  void _syncOverrideControllers() {
    final Map<String, dynamic> own =
        (_member['overrides'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
    for (final String key in _overrideText.keys) {
      final Object? value = own[key];
      _overrideText[key] = value == null ? '' : '$value';
    }
    _overrideInitial
      ..clear()
      ..addAll(_overrideText);
  }

  /// 该覆盖项的当前生效值描述（用于提示"留空时实际用的是谁的值"）
  String _effectiveHint(String key) {
    final Map<String, dynamic> eff =
        (_member['effective'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
    final Object? value = eff[key];
    if (value == null) return '模型默认';
    final String source = (eff['${key}_source'] as String?) ?? '';
    switch (source) {
      case 'member':
        return '$value（本成员）';
      case 'top':
        return '$value（继承 TOP）';
      default:
        return '$value（模型默认）';
    }
  }

  /// 加载可用模型池（模型配置页下拉数据源）。
  ///
  /// 复用 `models-info`：它返回 `models[]`（逐字段白名单、不含密钥），
  /// 与右栏「模型信息」同一份数据源，避免再开一个只读接口。
  Future<void> _loadModels() async {
    setState(() {
      _modelsLoading = true;
      _modelsError = null;
    });
    try {
      final Map<String, dynamic> data =
          await ApiService.getAgentModelsInfo(widget.leader.id);
      if (!mounted) return;
      final List<dynamic> raw = data['models'] as List<dynamic>? ?? <dynamic>[];
      setState(() {
        _models = raw
            .map((dynamic e) =>
                (e as Map<dynamic, dynamic>).cast<String, dynamic>())
            .toList();
        _modelsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsError = '$e';
        _modelsLoading = false;
      });
    }
  }

  /// 加载该成员当前会话的历史进度（对话历史 + 实时 WS 增量合并）
  Future<void> _loadHistory() async {
    try {
      final List<Map<String, dynamic>> history =
          await ApiService.getConversationHistory(
        widget.memberId,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      setState(() {
        _liveMessages.clear();
        for (final Map<String, dynamic> item in history) {
          _liveMessages.add(ChatMessage.fromJson(item));
        }
        // 定位导航：历史加载后直接触发 MessageList 定位滚动（而非滚底，
        // 避免「先滚底再跳位」的闪烁）；否则按原逻辑滚动到底部
        final String? target = widget.scrollToMessageId;
        if (target != null && target.isNotEmpty) {
          _scrollToMessageId = target;
          _scrollToRevision++;
        } else {
          _scrollRevision++;
        }
      });
    } catch (_) {
      // 拉取失败时保持空列表，仅依赖实时 WS
    }
  }

  Future<void> _connectWs() async {
    if (_wsConnected) return;
    final AuthService auth = AuthService();
    final String? token = await auth.getToken();
    if (token == null || token.isEmpty) return;
    _webSocket.connect(token);
    _wsConnected = true;
  }

  /// 处理成员实时进度：仅保留属于该成员、且属于当前会话的消息/工具卡片
  void _handleIncoming(Map<String, dynamic> data) {
    if (!mounted) return;
    final String? type = data['type'] as String?;
    final String? agentId = data['agent_id'] as String?;
    if (agentId != null && agentId != widget.memberId) return;

    // 跨会话隔离：事件带 session_id 时，仅接收当前会话的增量，丢弃其他会话
    // 的进度，避免把该成员在别的会话的工作混进本窗口。
    final String? incomingSession = data['session_id'] as String?;
    if (incomingSession != null && incomingSession != widget.sessionId) return;

    if (type == 'msg_start') {
      final ChatMessage message = ChatMessage(
        id: data['id'] as String? ?? '',
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      );
      if (message.id.isEmpty) return;
      setState(() {
        _liveMessages.add(message);
        _scrollRevision++;
      });
    } else if (type == 'msg_chunk') {
      final int idx =
          _liveMessages.indexWhere((ChatMessage m) => m.id == data['id']);
      if (idx >= 0) {
        setState(() {
          _liveMessages[idx].content += (data['chunk'] as String?) ?? '';
        });
      }
    } else if (type == 'msg_end') {
      final int idx =
          _liveMessages.indexWhere((ChatMessage m) => m.id == data['id']);
      if (idx >= 0) {
        setState(() {
          _liveMessages[idx].isStreaming = false;
          _scrollRevision++;
        });
      }
    } else if (type == 'tool_start') {
      final String id = (data['id'] as String?) ?? '';
      if (id.isEmpty) return;
      final Map<String, dynamic>? args =
          (data['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      setState(() {
        _liveMessages.add(ChatMessage(
          id: id,
          role: 'agent',
          content: '',
          timestamp: DateTime.now(),
          kind: 'tool',
          toolName: (data['name'] as String?) ?? '',
          toolArguments: args,
          toolRunning: true,
        ));
        _scrollRevision++;
      });
    } else if (type == 'tool_end') {
      final int idx =
          _liveMessages.indexWhere((ChatMessage m) => m.id == data['id']);
      if (idx >= 0) {
        setState(() {
          _liveMessages[idx].toolRunning = false;
          _liveMessages[idx].toolResult = (data['result'] as String?) ?? '';
        });
      }
    } else if (type == 'agent_status') {
      final Map<String, dynamic> d =
          (data['data'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
              {};
      // 会话隔离：agent_status 的 session_id 在 data 内层，带值且不属于本会话
      // 时忽略（与顶层过滤统一：缺省视为本会话）。
      final String? statusSession = d['session_id'] as String?;
      if (statusSession != null && statusSession != widget.sessionId) return;
      if (d['agent_id'] == widget.memberId) {
        // 成员状态变化（含审核放行后开始工作）：刷新名单行的实时状态
        _refreshMember();
      }
    }
  }

  /// 重新拉取本成员的名单行（审核/模型可能已被其它入口改动）。
  Future<void> _refreshMember() async {
    try {
      final List<Map<String, dynamic>> members =
          await ApiService.getTeammates(widget.leader.id);
      if (!mounted) return;
      for (final Map<String, dynamic> m in members) {
        if ((m['id'] as String?) == widget.memberId) {
          setState(() {
            _member = m;
            if ((m['model_id'] as String? ?? '').isNotEmpty) {
              _selectedModelId = m['model_id'] as String;
            }
          });
          return;
        }
      }
    } catch (_) {
      // 拉取失败保持现有数据
    }
  }

  /// 提交模型配置 / 审核（「模型配置」页）
  ///
  /// 语义：`assign` 只赋模型（进入待审核）；`approve` 赋模型并审核通过；
  /// `reject` 驳回；`reset` 退回待审核。赋模型与审核是成员能否工作的唯一闸门，
  /// 全部经用户侧接口 `PATCH /api/agents/{leader}/teammate/{member}`。
  Future<void> _submitMemberConfig(String action) async {
    if (_saving) return;
    final String modelId = _selectedModelId.trim();
    if (action != 'reject' && modelId.isEmpty) {
      _showSnack('请先选择模型');
      return;
    }
    setState(() => _saving = true);
    try {
      String? reviewStatus;
      switch (action) {
        case 'approve':
          reviewStatus = 'approved';
          break;
        case 'reject':
          reviewStatus = 'rejected';
          break;
        case 'reset':
          reviewStatus = 'pending_review';
          break;
        default:
          reviewStatus = null; // assign：只赋模型，状态由后端推导为待审核
      }
      // 只提交**改动过**的覆盖项：未改 = 后端保持原值；改空 = 显式清除该项
      // （回退 TOP / 模型默认）。这样"改模型参数"与"只审核"可以分开操作。
      final Map<String, Object?> overridePatch = <String, Object?>{};
      for (final String key in _overrideText.keys) {
        final String now = _overrideText[key]!.trim();
        if (now == (_overrideInitial[key] ?? '')) continue;
        if (now.isEmpty) {
          overridePatch[key] = null; // 清除该覆盖
        } else if (key == 'compress_threshold') {
          final double? parsed = double.tryParse(now);
          if (parsed == null || parsed < 0.1 || parsed > 0.95) {
            _showSnack('压缩阈值需为 0.1~0.95 的数值（当前输入：$now）');
            setState(() => _saving = false);
            return;
          }
          overridePatch[key] = parsed;
        } else {
          final int? parsed = int.tryParse(now);
          if (parsed == null || parsed <= 0) {
            _showSnack('最大输入/输出需为正整数（当前输入：$now）');
            setState(() => _saving = false);
            return;
          }
          overridePatch[key] = parsed;
        }
      }
      final Map<String, dynamic> resp = await ApiService.updateTeammate(
        widget.leader.id,
        widget.memberId,
        // reject 不改模型（仅改状态）；其余一律带上当前选择的模型
        modelId: action == 'reject' ? null : modelId,
        reviewStatus: reviewStatus,
        overrides: overridePatch.isEmpty ? null : overridePatch,
      );
      if (!mounted) return;
      final Map<String, dynamic>? m =
          (resp['member'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      setState(() {
        if (m != null) {
          _member = <String, dynamic>{..._member, ...m};
          _selectedModelId = m['model_id'] as String? ?? _selectedModelId;
          // 提交成功后以服务端返回的自身覆盖为准重算基线
          _syncOverrideControllers();
        }
      });
      final String status = m?['review_status'] as String? ?? '';
      _showSnack(status == 'approved' ? '已审核通过，成员现在可以工作' : '配置已保存');
      if (widget.onChanged != null) await widget.onChanged!();
    } catch (e) {
      if (!mounted) return;
      _showSnack('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _webSocket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool needsAction = _needsUserAction(
      _member['review_status'] as String? ?? '',
    );
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.memberName),
          // 未就绪成员：标题旁挂红色标记，避免用户误以为"派活没反应"
          bottom: TabBar(
            tabs: <Widget>[
              const Tab(text: '进度'),
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Text('模型配置'),
                    if (needsAction) ...<Widget>[
                      const SizedBox(width: 4),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            onTap: (int i) {
              setState(() {
                _selectedTab = i == 0 ? 'progress' : 'model';
              });
              if (i == 1) _loadModels();
            },
          ),
        ),
        body: Column(
          children: <Widget>[
            Expanded(child: _buildTabContent()),
            _buildMessageInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 'model':
        return _buildModelConfigTab();
      case 'progress':
      default:
        return MessageList(
          messages: _liveMessages,
          revision: _scrollRevision,
          scrollToMessageId: _scrollToMessageId,
          scrollToRevision: _scrollToRevision,
        );
    }
  }

  /// 「模型配置」页：为用户分配成员模型 + 审核放行。
  ///
  /// 这是成员能否工作的**唯一闸门**：成员创建时模型为空、状态 pending_model，
  /// 在用户赋模型并审核通过前后端会拒收其全部消息。
  Widget _buildModelConfigTab() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String reviewStatus = _member['review_status'] as String? ?? '';
    final bool needsAction = _needsUserAction(reviewStatus);
    final String role = _member['role'] as String? ?? '';
    final String duty = _member['duty'] as String? ?? '';
    final int level = (_member['level'] as num?)?.toInt() ?? 1;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (needsAction)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.error_outline,
                    size: 18, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _reviewHint(reviewStatus),
                    style:
                        TextStyle(fontSize: 12, color: cs.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        _infoRow('成员 ID', widget.memberId),
        _infoRow('层级', 'Level $level'),
        _infoRow('角色', role.isEmpty ? '（未设置）' : role),
        _infoRow('职责', duty.isEmpty ? '（未设置）' : duty),
        _infoRow('审核状态', _reviewStatusLabel(reviewStatus)),
        const Divider(height: 28),
        Text('分配模型', style: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
        if (_modelsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_modelsError != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('模型列表加载失败：$_modelsError',
                  style: TextStyle(fontSize: 12, color: cs.error)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _loadModels, child: const Text('重试')),
            ],
          )
        else
          DropdownButtonFormField<String>(
            value: _models.any((Map<String, dynamic> m) =>
                    (m['model_id'] as String? ?? '') == _selectedModelId)
                ? _selectedModelId
                : '',
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '成员使用的模型',
              helperText: '选择后需审核通过，成员才会开始接收消息',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: '',
                child: Text('（未选择）'),
              ),
              ..._models.map(
                (Map<String, dynamic> m) => DropdownMenuItem<String>(
                  value: m['model_id'] as String? ?? '',
                  child: Text(m['name'] as String? ??
                      (m['model_id'] as String? ?? '')),
                ),
              ),
            ],
            onChanged: (String? value) {
              setState(() => _selectedModelId = value ?? '');
            },
          ),
        const Divider(height: 28),
        Text('模型参数（本成员）', style: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 4),
        Text(
          '留空 = 不单独设置，沿用「生效值」；填入则覆盖 TOP 的设置。'
          '只有改动过的项会被提交，清空即回退继承。',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        _buildEffortField(cs),
        const SizedBox(height: 10),
        _overrideField(
          cs,
          key: 'max_seqlen',
          label: '最大输入 tokens',
          hint: '如 65536',
          numeric: true,
        ),
        const SizedBox(height: 10),
        _overrideField(
          cs,
          key: 'max_output_tokens',
          label: '最大输出 tokens',
          hint: '如 4096',
          numeric: true,
        ),
        const SizedBox(height: 10),
        _overrideField(
          cs,
          key: 'compress_threshold',
          label: '上下文压缩阈值',
          hint: '0.1~0.95，如 0.8',
          numeric: true,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _saving ? null : () => _submitMemberConfig('approve'),
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: const Text('保存并审核通过'),
            ),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _submitMemberConfig('assign'),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('仅保存（待审核）'),
            ),
            if (reviewStatus == 'approved')
              OutlinedButton.icon(
                onPressed:
                    _saving ? null : () => _submitMemberConfig('reject'),
                icon: const Icon(Icons.block, size: 18),
                label: const Text('驳回（停止接收消息）'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '说明：成员的模型与审核状态决定它能否工作。未分配模型或未审核通过的'
          '成员不会接收任何消息，leader 向其派活会被后端拒绝。审核通过后系统会'
          '向其补发一次初始化消息。',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 单个参数覆盖输入框：label + 生效值提示 + 输入框
  ///
  /// 用 TextEditingController 会带来"外部更新控件"的同步负担，这里用
  /// ``TextFormField(initialValue)`` + ``key`` 绑定当前值——值变化时 key 变化
  /// 会重建控件并带上新值；用户输入期间 key 不变，不会打断输入。
  Widget _overrideField(
    ColorScheme cs, {
    required String key,
    required String label,
    String hint = '',
    bool numeric = false,
  }) {
    final String value = _overrideText[key] ?? '';
    return TextFormField(
      key: ValueKey<String>('$key=$value'),
      initialValue: value,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: '生效值：${_effectiveHint(key)}',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (String text) => _overrideText[key] = text,
    );
  }

  /// 思考强度：可选档位来自该模型声明，另加"不单独设置"
  Widget _buildEffortField(ColorScheme cs) {
    final List<String> options = _effortOptions();
    final String value = _overrideText['reasoning_effort'] ?? '';
    final List<String> candidates = <String>[
      '',
      ...options,
      if (value.isNotEmpty && !options.contains(value)) value,
    ];
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '思考强度',
        helperText: '生效值：${_effectiveHint('reasoning_effort')}',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: candidates
          .map((String e) => DropdownMenuItem<String>(
                value: e,
                child: Text(e.isEmpty ? '（不单独设置）' : e),
              ))
          .toList(),
      onChanged: (String? v) =>
          setState(() => _overrideText['reasoning_effort'] = v ?? ''),
    );
  }

  /// 当前选中模型声明的思考强度可选档位（与右栏「模型信息」同一口径）
  List<String> _effortOptions() {
    // firstWhere 的 orElse 保证非空，故直接接非空 Map（用 `?[]` 会触发
    // unnecessary_null_aware_operator，接 `??` 又会触发 dead_null_aware）
    final Map<String, dynamic> model = _models.firstWhere(
      (Map<String, dynamic> m) =>
          (m['model_id'] as String? ?? '') == _selectedModelId,
      orElse: () => <String, dynamic>{},
    );
    final List<dynamic>? raw =
        model['reasoning_effort_options'] as List<dynamic>?;
    if (raw == null) return const <String>['low', 'high', 'max'];
    final List<String> options = raw
        .map((dynamic e) => e.toString().trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    return options.isEmpty ? const <String>['low', 'high', 'max'] : options;
  }

  Widget _infoRow(String label, String value) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  static String _reviewStatusLabel(String status) {
    switch (status) {
      case 'approved':
        return '已审核通过';
      case 'pending_model':
        return '待分配模型';
      case 'pending_review':
        return '待审核';
      case 'rejected':
        return '已驳回';
      default:
        return '未知';
    }
  }

  static String _reviewHint(String status) {
    switch (status) {
      case 'pending_model':
        return '该成员尚未分配模型，当前不接收任何消息。请选择模型后点「保存并审核通过」。';
      case 'pending_review':
        return '该成员已选模型但尚未审核，当前不接收任何消息。确认无误后点「保存并审核通过」。';
      case 'rejected':
        return '该成员已被驳回，不会接收任何消息。如需重新启用请选择模型并审核通过。';
      default:
        return '';
    }
  }

  /// 该审核状态是否"等待用户处理"（与后端 REVIEW_STATUS_NEEDS_USER 同一口径）
  static bool _needsUserAction(String status) =>
      status == 'pending_model' || status == 'pending_review';

  Widget _buildMessageInput() {
    final TextEditingController controller = TextEditingController();
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '直接向成员发送消息…',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: () async {
              final String text = controller.text.trim();
              if (text.isEmpty) return;
              // 本地追加一条"我 -> 成员"的记录
              setState(() {
                _liveMessages.add(ChatMessage(
                  id: 'user_${DateTime.now().millisecondsSinceEpoch}',
                  role: 'user',
                  content: text,
                  timestamp: DateTime.now(),
                ));
                _scrollRevision++;
              });
              controller.clear();
              try {
                await ApiService.sendTeammateMessage(
                    widget.leader.id, widget.memberId, text,
                    sessionId: widget.sessionId);
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('发送失败：$e')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
