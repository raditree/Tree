import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../models/file_node.dart';
import '../models/message.dart';
import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/websocket_service.dart';
import 'message_list.dart';

/// teammates 工作进度窗口
///
/// 进入时展示该 agent 的团队成员拓扑结构：根节点为当前 agent，下面按层级
/// 展示各成员。每个成员卡片显示名称、状态（working/idle）、模型、层级与
/// 评价。点击成员可进入其工作进度详情页（消息与工具卡片、活动日志、沙箱
/// 文件、直接发消息）。
class TeammatesWindowPage extends StatefulWidget {
  final Agent agent;

  /// 打开窗口时的当前会话 id；透传给成员进度页，使历史/实时按会话过滤
  final String sessionId;

  const TeammatesWindowPage({
    super.key,
    required this.agent,
    required this.sessionId,
  });

  @override
  State<TeammatesWindowPage> createState() => _TeammatesWindowPageState();
}

class _TeammatesWindowPageState extends State<TeammatesWindowPage> {
  List<Map<String, dynamic>> _members = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

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
      final List<Map<String, dynamic>> members =
          await ApiService.getTeammates(widget.agent.id);
      if (!mounted) return;
      setState(() {
        _members = members;
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
    // 拓扑：根为 leader，成员按层级分组展示
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _buildLeaderCard(),
        if (_members.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            '团队成员',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ..._members.map(_buildMemberCard),
        ],
      ],
    );
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
    // 实时状态：优先用 WS 维护的集合，回退到 API 返回的 live_status
    final bool working = _workingMembers.contains(id) ||
        (member['live_status'] as String?) == 'working';
    final Color statusColor =
        working ? Colors.orange : cs.outline;
    final String statusText = working ? '工作中' : '空闲';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TeammateDetailPage(
                leader: widget.agent,
                memberId: id,
                memberName: name.isNotEmpty ? name : id,
                sessionId: widget.sessionId,
              ),
            ),
          );
        },
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: working
              ? Colors.orange.withOpacity(0.2)
              : cs.surfaceVariant,
          child: Icon(
            working ? Icons.sync : Icons.person,
            size: 18,
            color: working ? Colors.orange : cs.onSurfaceVariant,
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
              'Level $level · ${model.isEmpty ? '未知模型' : model}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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
}

/// 单个团队成员的工作进度详情页
///
/// 包含四个部分：
/// - 进度：实时消息与工具调用卡片（订阅 WebSocket，按 agent_id 过滤）
/// - 日志：成员工作空间的活动日志
/// - 文件：成员沙箱文件浏览
/// - 消息：直接向成员发送消息
class TeammateDetailPage extends StatefulWidget {
  final Agent leader;
  final String memberId;
  final String memberName;

  /// 当前会话 id：历史加载与实时 WS 均按该会话过滤，避免跨会话混杂
  final String sessionId;

  /// 定位目标消息 id（右侧「问题回复」成员提问导航触发；历史加载后滚动定位）
  final String? scrollToMessageId;

  const TeammateDetailPage({
    super.key,
    required this.leader,
    required this.memberId,
    required this.memberName,
    required this.sessionId,
    this.scrollToMessageId,
  });

  @override
  State<TeammateDetailPage> createState() => _TeammateDetailPageState();
}

class _TeammateDetailPageState extends State<TeammateDetailPage> {
  final WebSocketService _webSocket = WebSocketService();
  final List<ChatMessage> _liveMessages = <ChatMessage>[];
  int _scrollRevision = 0;
  bool _wsConnected = false;
  String _log = '';
  String? _selectedTab = 'progress';

  /// MessageList 定位触发号（右侧「问题回复」成员提问导航用）
  int _scrollToRevision = 0;

  /// MessageList 定位目标消息 id
  String? _scrollToMessageId;

  @override
  void initState() {
    super.initState();
    _webSocket.onMessage = _handleIncoming;
    _connectWs();
    _loadHistory();
    _loadLog();
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
      if (d['agent_id'] == widget.memberId) {
        _loadLog();
      }
    }
  }

  Future<void> _loadLog() async {
    try {
      final String log = await ApiService.getTeammateLog(widget.memberId);
      if (!mounted) return;
      setState(() {
        _log = log;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _webSocket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.memberName),
          actions: <Widget>[
            IconButton(
              tooltip: '刷新日志',
              icon: const Icon(Icons.refresh),
              onPressed: _loadLog,
            ),
          ],
          bottom: TabBar(
            tabs: const <Widget>[
              Tab(text: '进度'),
              Tab(text: '日志'),
              Tab(text: '文件'),
            ],
            onTap: (int i) {
              setState(() {
                _selectedTab = i == 0 ? 'progress' : (i == 1 ? 'log' : 'files');
              });
              if (i == 1) _loadLog();
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
      case 'log':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            _log.isEmpty ? '（暂无活动日志）' : _log,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        );
      case 'files':
        return _MemberFileBrowser(
          workspaceId: widget.memberId,
          teamId: widget.leader.id,
        );
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

/// 成员沙箱文件浏览器（轻量版）
class _MemberFileBrowser extends StatefulWidget {
  final String workspaceId;

  /// 所属团队 ID（本地模式下用于后端判定，使成员面板也浏览共享 base）
  final String teamId;

  const _MemberFileBrowser({
    required this.workspaceId,
    required this.teamId,
  });

  @override
  State<_MemberFileBrowser> createState() => _MemberFileBrowserState();
}

class _MemberFileBrowserState extends State<_MemberFileBrowser> {
  List<FileNode>? _files;
  String? _error;

  /// 当前浏览的目录路径（相对工作空间根，空串表示根目录）
  String _currentPath = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _files = null;
      _error = null;
    });
    try {
      final List<FileNode> files = await ApiService.getFiles(
        widget.workspaceId,
        path: _currentPath,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() {
        _files = files;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  /// 进入子目录
  void _enterDirectory(FileNode node) {
    if (!node.isDirectory) return;
    setState(() {
      _currentPath = _joinPath(_currentPath, node.name);
    });
    _load();
  }

  /// 返回上一级
  void _goUp() {
    final int idx = _currentPath.lastIndexOf('/');
    setState(() {
      _currentPath = idx <= 0 ? '' : _currentPath.substring(0, idx);
    });
    _load();
  }

  /// 回到根目录
  void _goRoot() {
    setState(() {
      _currentPath = '';
    });
    _load();
  }

  String _joinPath(String parent, String child) =>
      parent.isEmpty ? child : '$parent/$child';

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('加载失败：$_error'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_files == null) return const Center(child: CircularProgressIndicator());
    if (_files!.isEmpty) {
      return Column(
        children: <Widget>[
          _buildNavBar(),
          const Expanded(child: Center(child: Text('该目录下暂无文件'))),
        ],
      );
    }
    return Column(
      children: <Widget>[
        _buildNavBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              itemCount: _files!.length,
              itemBuilder: (BuildContext context, int index) {
                final FileNode node = _files![index];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    node.isDirectory
                        ? Icons.folder
                        : Icons.insert_drive_file,
                    size: 18,
                  ),
                  title: Text(node.name,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                    node.isDirectory ? '目录' : node.formattedSize,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: node.isDirectory
                      ? const Icon(Icons.chevron_right, size: 18)
                      : null,
                  onTap: node.isDirectory ? () => _enterDirectory(node) : null,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部导航栏：面包屑 + 返回上级/回根
  Widget _buildNavBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '返回上级',
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: _currentPath.isEmpty ? null : _goUp,
          ),
          IconButton(
            tooltip: '回到根目录',
            icon: const Icon(Icons.home, size: 18),
            onPressed: _currentPath.isEmpty ? null : _goRoot,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _currentPath.isEmpty ? '/' : '/$_currentPath',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}