import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../../io/question_update_service.dart';
import '../../io/ssh_executor_service.dart';
import '../../io/websocket_service.dart';
import '../../io/workspace_refresh_service.dart';
import 'message_input.dart';
import 'message_list.dart';
import 'mode_switch.dart';
import 'session_picker.dart';
import 'spec_panel.dart';
import 'ssh_config_dialog.dart';
import 'teammates_window_page.dart';

/// 消息交互面板（中栏）
///
/// 由标题栏、消息列表区与输入框区三部分组成：
/// - 标题栏显示当前选中 Agent 名称
/// - 消息列表区展示对话历史，支持流式追加
/// - 输入框区负责发送文本与附件
///
/// 未选择 Agent 时显示"请选择一个 Agent 开始对话"提示。
/// 发送消息时通过 WebSocket 推送至后端，接收消息时更新列表。
class MessagePanel extends StatefulWidget {
  /// 当前选中的 Agent（未选择时为 null）
  final Agent? selectedAgent;

  /// 外部触发刷新（如清空对话后递增），值变化时重新拉取历史
  final int refreshTrigger;

  /// 会话切换回调（选中/新建会话时触发，携带新的 session_id）
  final ValueChanged<String>? onSessionChanged;

  /// 定位目标消息 id（右侧「问题回复」导航触发）
  final String? navigateMessageId;

  /// 定位目标会话 id（与 [navigateMessageId] 配合）
  final String? navigateSessionId;

  /// 定位触发号：外部递增触发导航定位
  final int navigateTrigger;

  const MessagePanel({
    super.key,
    this.selectedAgent,
    this.refreshTrigger = 0,
    this.onSessionChanged,
    this.navigateMessageId,
    this.navigateSessionId,
    this.navigateTrigger = 0,
  });

  @override
  State<MessagePanel> createState() => _MessagePanelState();
}

class _MessagePanelState extends State<MessagePanel> {
  /// 消息列表
  final List<ChatMessage> _messages = <ChatMessage>[];

  /// WebSocket 服务
  final WebSocketService _webSocket = WebSocketService();

  /// 是否已尝试连接 WebSocket（避免重复连接）
  bool _wsConnected = false;

  /// 消息版本号：消息列表每次结构性变化时递增，驱动 MessageList 滚动到底部
  int _scrollRevision = 0;

  /// 定位目标消息 id（历史加载完成后消费，驱动 MessageList 定位滚动）
  String? _pendingScrollId;

  /// 定位目标会话 id（供 _loadSessions 优先选中目标会话）
  String? _pendingSessionId;

  /// MessageList 定位触发号
  int _scrollToRevision = 0;

  /// 定位目标消息 id（透传给 MessageList）
  String? _scrollToMessageId;

  /// 处于 working 状态的 agent 集合（用于标题栏显示状态与停止按钮）
  final Set<String> _workingAgents = <String>{};

  /// 是否正在等待用户回答 agent 的问题（AskUserQuestion）
  bool _asking = false;

  /// 本地运行模式是否启用
  bool _localEnabled = false;

  /// 本地后端工作目录
  String? _localWorkingDir;

  /// SSH 运行模式是否启用
  bool _sshEnabled = false;

  /// SSH 连接配置（host/port/...，供配置表单预填）
  Map<String, dynamic> _sshConfig = <String, dynamic>{};

  /// 当前运行模式：ssh > local > cloud
  String get _currentMode =>
      _sshEnabled ? 'ssh' : (_localEnabled ? 'local' : 'cloud');

  /// 切换运行模式时的防重入守卫（不再启动任何本地后端，仅防双击）
  bool _togglingMode = false;

  /// 当前顶部 agent 的对话是否已开始（发送首条消息后运行模式锁定，
  /// 防止因后端会话已绑定本地/云端工具而出现模式切换"不生效"的困惑）
  bool _modeLocked = false;

  /// 各 agent 最近一次回复的 token 用量（agent_id -> usage）。
  /// 用于展示"当前上下文长度"（prompt_tokens / max_tokens）。
  final Map<String, Map<String, dynamic>> _usageByAgent =
      <String, Map<String, dynamic>>{};

  /// 当前 agent 的会话列表（多会话并行）
  List<ChatSession> _sessions = <ChatSession>[];

  /// 当前选中的会话（未加载时为 null，回退默认会话）
  ChatSession? _currentSession;

  /// 当前会话 id（缺省为默认会话）
  String get _currentSessionId =>
      _currentSession?.sessionId ?? 'session_default';

  @override
  void initState() {
    super.initState();
    _webSocket.onMessage = _handleIncomingMessage;
    // 连接建立/重连时清空 working 集合：后端重启会清空其内存态 _active_tasks，
    // 若不清空，前端会残留旧的 working（无 API 调用却显示工作中）。
    // 清空后由后端在 WS 建立时补推真实的 agent_status（仍在工作的才重新标记）。
    _webSocket.onConnectionChange = (bool connected) {
      if (connected && mounted) {
        setState(() {
          _workingAgents.clear();
        });
      }
    };
    // 先恢复本地模式设置（按顶部 agent），再建立 WebSocket 连接，
    // 确保连接建立后能按正确的本地模式注册执行器
    _initAsync();
    // 首次进入时若已选中 agent 则加载会话与历史
    if (widget.selectedAgent != null) {
      _loadSessions();
    }
  }

  /// 初始化：先加载当前顶部 agent 的运行模式设置，再连接 WebSocket
  Future<void> _initAsync() async {
    await _loadModeSettings();
    if (!mounted) return;
    await _connectWebSocket();
  }

  /// 加载当前顶部 agent 的本地/SSH 执行模式持久化设置，并同步注册/注销
  Future<void> _loadModeSettings() async {
    if (widget.selectedAgent != null) {
      LocalExecutorService.instance
          .setCurrentTopAgent(widget.selectedAgent!.id);
      SshExecutorService.instance.setCurrentTopAgent(widget.selectedAgent!.id);
    }
    await Future.wait(<Future<void>>[
      LocalExecutorService.instance.loadSettings(),
      SshExecutorService.instance.loadSettings(),
    ]);
    if (!mounted) return;
    setState(() {
      _localEnabled = LocalExecutorService.instance.enabled;
      _localWorkingDir = LocalExecutorService.instance.workingDirectory;
      _sshEnabled = SshExecutorService.instance.enabled;
      _sshConfig = SshExecutorService.instance.config;
    });
    // 连接已建立时，按当前顶部 agent 的运行模式同步注册/注销
    if (_wsConnected && _webSocket.isConnected) {
      LocalExecutorService.instance.syncRegistration();
      SshExecutorService.instance.syncRegistration();
    }
  }

  @override
  void didUpdateWidget(covariant MessagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 右侧「问题回复」导航定位触发：记录待消费的定位目标
    final bool navTriggered = oldWidget.navigateTrigger != widget.navigateTrigger &&
        widget.navigateMessageId != null &&
        widget.navigateMessageId!.isNotEmpty;
    if (navTriggered) {
      _pendingScrollId = widget.navigateMessageId;
      _pendingSessionId = widget.navigateSessionId;
    }

    // 切换 Agent 或外部触发刷新时清空消息列表并加载历史
    if (oldWidget.selectedAgent?.id != widget.selectedAgent?.id) {
      setState(() {
        _messages.clear();
        _sessions = <ChatSession>[];
        _currentSession = null;
        _usageByAgent.clear();
        // 切换顶部 agent 后解除锁定，由新 agent 的历史/首条消息重新决定
        _modeLocked = false;
      });
      _loadSessions();
      // 切换顶部 agent：加载其独立的运行模式设置并同步注册/注销
      _loadModeSettings();
    } else if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      setState(() {
        _messages.clear();
      });
      _loadHistory();
    } else if (navTriggered) {
      // 同 agent 定位：按目标会话切换（若不同）后加载历史并定位
      final String? targetSession = widget.navigateSessionId;
      if (targetSession != null &&
          targetSession.isNotEmpty &&
          targetSession != _currentSessionId) {
        final ChatSession? ts = _sessions
            .where((ChatSession s) => s.sessionId == targetSession)
            .cast<ChatSession?>()
            .firstWhere((ChatSession? s) => s != null, orElse: () => null);
        setState(() {
          _currentSession = ts;
          _messages.clear();
        });
        widget.onSessionChanged?.call(targetSession);
        _loadHistory();
      } else if (_messages.isEmpty) {
        _loadHistory();
      } else {
        _consumePendingScroll();
      }
    }
  }

  /// 消费定位目标：递增 MessageList 定位触发号，驱动滚动到目标消息。
  void _consumePendingScroll() {
    final String? id = _pendingScrollId;
    if (id == null || id.isEmpty) return;
    _pendingScrollId = null;
    setState(() {
      _scrollToMessageId = id;
      _scrollToRevision++;
    });
  }

  /// 拉取当前 agent 的会话列表；切换会话时清空消息并重新加载历史
  Future<void> _loadSessions() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    try {
      final List<ChatSession> sessions =
          await ApiService.getSessions(agent.id);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        // 运行模式按顶部 agent 级锁定：该 agent 任一历史会话有消息
        // 即视为「已开始过对话」，切换会话不解除锁定
        _modeLocked = sessions.any((s) => s.messageCount > 0);
        // 保持当前会话选择（若仍存在），否则回退到列表首个/默认会话。
        // 定位导航时优先选中目标会话（_pendingSessionId，一次性消费）。
        final String prev = _pendingSessionId ?? _currentSessionId;
        _pendingSessionId = null;
        final bool keep = sessions.any((s) => s.sessionId == prev);
        if (keep) {
          _currentSession = sessions.firstWhere((s) => s.sessionId == prev);
        } else if (sessions.isNotEmpty) {
          _currentSession = sessions.first;
        } else {
          _currentSession = null;
        }
        _messages.clear();
      });
      _loadHistory();
      // 无论显式选会话还是自动选中，都把实际生效的会话 id 广播给
      // main_page -> FilePanel -> TodoPanel，保证"进入会话无 tool 调用"时
      // todo 也按当前会话隔离（否则 TodoPanel 会停留在旧的 session_default）
      if (mounted) {
        widget.onSessionChanged?.call(_currentSessionId);
      }
    } catch (e) {
      // 拉取失败时保持默认会话
    }
  }

  /// 从后端拉取当前 agent/会话的对话历史
  Future<void> _loadHistory() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String sessionId = _currentSessionId;
    try {
      final List<Map<String, dynamic>> raw =
          await ApiService.getConversationHistory(
        agent.id,
        sessionId: sessionId,
      );
      if (!mounted) return;
      // 会话可能在等待期间被切换，丢弃过期的历史
      if (sessionId != _currentSessionId) return;
      // 定位目标：历史加载完成后直接消费，驱动 MessageList 定位滚动
      // （而非滚到底部，避免「先滚底再跳位」的闪烁）
      final String? pendingScroll = _pendingScrollId;
      setState(() {
        _messages.clear();
        for (final Map<String, dynamic> item in raw) {
          _messages.add(ChatMessage.fromJson(item));
        }
        // 注意：不再按「当前会话历史是否为空」重置 _modeLocked——
        // 运行模式是顶部 agent 级共享的，锁定状态由 _loadSessions
        // 依据「该 agent 是否已有任一历史会话」统一决定，切换会话
        // （含新建空会话）不得解除锁定。
        if (pendingScroll != null && pendingScroll.isNotEmpty) {
          _scrollToMessageId = pendingScroll;
          _scrollToRevision++;
          _pendingScrollId = null;
        } else {
          _scrollRevision++;
        }
        // 从历史中恢复 token 用量：取最后一条带 usage 的 agent 消息，
        // 使重启后「上下文长度」统计不丢失（usage 随消息已持久化）
        for (final ChatMessage m in _messages.reversed) {
          final Map<String, dynamic>? usage = m.usage;
          if (usage != null && usage.isNotEmpty) {
            _usageByAgent['${agent.id}::$sessionId'] = usage;
            break;
          }
        }
      });
    } catch (e) {
      // 拉取失败时静默处理（保持空列表）
    }
  }

  /// 按工具名判定其影响的工作空间区域，决定右栏哪些 tab 需要增量刷新。
  ///
  /// 只读/会话管理/子代理分发等不变更文件与规范状态的工具返回空集，
  /// 避免每次工具结束右栏都会闪一下；其余未知工具保守归为文件区。
  Set<WorkspaceArea> _areasForToolName(String name) {
    switch (name) {
      case 'write':
      case 'edit':
        return {WorkspaceArea.files};
      case 'set_todo_list':
        return {WorkspaceArea.todo};
      case 'terminal':
        // 终端可能写文件，也可能执行 git 命令
        return {WorkspaceArea.files, WorkspaceArea.git};
      case 'read':
      case 'view':
      case 'cat':
      case 'show':
      case 'list':
      case 'search':
      case 'grep':
      case 'ask_user_question':
      case 'team':
        return {};
      default:
        if (name.startsWith('session_') ||
            name.startsWith('tool_') ||
            name.startsWith('member_') ||
            name.startsWith('help_') ||
            name.startsWith('web_') ||
            name.startsWith('mcp_')) {
          return {};
        }
        // 未知工具保守视为可能改文件
        return {WorkspaceArea.files};
    }
  }

  /// 建立 WebSocket 连接
  Future<void> _connectWebSocket() async {
    if (_wsConnected) return;
    final AuthService auth = AuthService();
    final String? token = await auth.getToken();
    if (token == null || token.isEmpty) return;
    // 本地执行器接管工具执行请求（始终接管，按是否本地模式决定是否注册）
    LocalExecutorService.instance.attach(_webSocket);
    // SSH 执行器发送注册/注销消息
    SshExecutorService.instance.attach(_webSocket);
    _webSocket.connect(token);
    _wsConnected = true;
    // 按当前顶部 agent 的运行模式注册/注销（须在连接建立后发送）
    LocalExecutorService.instance.syncRegistration();
    SshExecutorService.instance.syncRegistration();
  }

  /// 处理后端推送的消息
  ///
  /// 文本消息按段渲染：`msg_start` 创建、`msg_chunk` 追加、`msg_end` 结束。
  /// 工具调用按卡片渲染：`tool_start` 创建、`tool_end` 更新结果。
  /// 另处理 `agent_status`（working/idle）、`ask_user_question`（提问卡片）、
  /// `msg_usage`（token 用量）。
  void _handleIncomingMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    final String? type = data['type'] as String?;

    // SSH 执行器注册/注销确认：交给服务完成挂起的等待
    if (type == 'register_ssh_executor_ack' ||
        type == 'unregister_ssh_executor_ack') {
      SshExecutorService.instance.resolveAck(
        (data['data'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      );
      return;
    }

    if (type == 'msg_start') {
      if (!_isForCurrentAgent(data) || !_isForCurrentSession(data)) return;
      final ChatMessage message = ChatMessage(
        id: data['id'] as String? ?? '',
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
        kind: data['kind'] as String? ?? 'text',
      );
      if (message.id.isEmpty) return;
      setState(() {
        _messages.add(message);
        _scrollRevision++;
      });
    } else if (type == 'msg_chunk') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final String chunk = (data['chunk'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        setState(() {
          _messages[idx].content += chunk;
        });
      }
    } else if (type == 'msg_end') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        final Map<String, dynamic>? usage =
            (data['usage'] as Map<String, dynamic>?)?.cast<String, dynamic>();
        setState(() {
          _messages[idx].isStreaming = false;
          _messages[idx].usage = usage;
          _scrollRevision++;
          if (usage != null) {
            _recordUsage(data, usage);
          }
        });
      }
    } else if (type == 'msg_usage') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final Map<String, dynamic>? usage =
          (data['usage'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        setState(() {
          _messages[idx].usage = usage;
          if (usage != null) {
            _recordUsage(data, usage);
          }
        });
      } else if (usage != null) {
        // 会话粒度推进：工具循环中推送的 usage 没有对应文本消息（id 是工具卡片），
        // 仍要记录，使上下文统计持续更新
        _recordUsage(data, usage);
        if (mounted) setState(() {});
      }
    } else if (type == 'tool_start') {
      if (!_isForCurrentAgent(data) || !_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      if (id.isEmpty) return;
      final Map<String, dynamic>? args =
          (data['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      final ChatMessage toolMsg = ChatMessage(
        id: id,
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        kind: 'tool',
        toolName: (data['name'] as String?) ?? '',
        toolArguments: args,
        toolRunning: true,
      );
      setState(() {
        _messages.add(toolMsg);
        _scrollRevision++;
      });
    } else if (type == 'tool_end') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        setState(() {
          _messages[idx].toolRunning = false;
          _messages[idx].toolResult = (data['result'] as String?) ?? '';
        });
      }
      // 工具执行结束：按工具类型增量通知右栏刷新对应区域（文件/Git/Todo）。
      // 只读类工具不触发，避免每次工具结束右栏都闪一下。
      final Set<WorkspaceArea> areas =
          _areasForToolName((data['name'] as String?) ?? '');
      if (areas.isNotEmpty) {
        WorkspaceRefreshService.instance.notifyWorkspaceChanged(areas);
      }
    } else if (type == 'agent_status') {
      final Map<String, dynamic> d =
          (data['data'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
              {};
      final String? agentId = d['agent_id'] as String?;
      final String? status = d['status'] as String?;
      if (agentId == null) return;
      setState(() {
        if (status == 'working') {
          _workingAgents.add(agentId);
        } else if (status == 'idle' || status == 'stopping') {
          _workingAgents.remove(agentId);
        }
      });
    } else if (type == 'ask_user_question') {
      _handleAskUserQuestion(data);
    } else if (type == 'ask_user_question_resolved') {
      // 右栏作答后，中栏对应内联卡片即时置灰
      final String qid =
          (((data['data'] as Map?)?['id']) as String?) ?? '';
      if (qid.isNotEmpty) {
        final int idx =
            _messages.indexWhere((ChatMessage m) => m.id == qid);
        if (idx >= 0) {
          setState(() {
            _messages[idx].answered = true;
          });
        }
      }
    } else if (type == 'message') {
      if (!_isForCurrentAgent(data) || !_isForCurrentSession(data)) return;
      // 完整 agent 消息（如后端 _send_text_as_agent 发送的错误提示）
      final ChatMessage message = ChatMessage.fromJson(data);
      setState(() {
        _messages.add(message);
        _scrollRevision++;
      });
    }
    // 其余控制消息（file_sync_progress / heartbeat / error 等）忽略
  }

  /// 判断消息是否属于当前选中的 agent（避免工作中的成员消息污染主面板）
  bool _isForCurrentAgent(Map<String, dynamic> data) {
    final String? agentId = data['agent_id'] as String?;
    if (agentId == null) return true;
    final Agent? agent = widget.selectedAgent;
    return agent != null && agent.id == agentId;
  }

  /// 判断消息是否属于当前选中的会话（避免其他会话的流式输出污染当前面板）
  bool _isForCurrentSession(Map<String, dynamic> data) {
    final String? sessionId = data['session_id'] as String?;
    if (sessionId == null) return true; // 兼容后端未携带 session_id 的旧消息
    return sessionId == _currentSessionId;
  }

  /// 记录 token 用量：按 (agent, 会话) 粒度存储，切换会话后互不影响
  void _recordUsage(
    Map<String, dynamic> data,
    Map<String, dynamic> usage,
  ) {
    final String agentId = (data['agent_id'] as String?) ?? '';
    final String sessionId = (data['session_id'] as String?) ?? _currentSessionId;
    _usageByAgent['$agentId::$sessionId'] = usage;
  }

  /// 处理 agent 的提问（AskUserQuestion 工具）：以非阻塞内联卡片插入消息流。
  ///
  /// 不再弹全屏遮罩对话框，避免挡住模型最近输出与右侧信息；用户可先浏览
  /// 上下文再点选选项作答，由 [_handleAskAnswer] 发送 answer 并置位已作答状态。
  void _handleAskUserQuestion(Map<String, dynamic> data) {
    if (_asking) return;
    final String qid = (data['id'] as String?) ?? '';
    if (qid.isEmpty) return;
    _asking = true;
    final String question = (data['question'] as String?) ?? '提问';
    final List<String> options =
        (data['options'] as List?)?.map((e) => e.toString()).toList() ??
            <String>[];
    setState(() {
      _messages.add(ChatMessage(
        id: qid,
        role: 'agent',
        content: question,
        timestamp: DateTime.now(),
        kind: 'ask_user_question',
        options: options,
      ));
      _scrollRevision++;
    });
    // 通知右栏「问题回复」页即时出现新问题
    QuestionUpdateService.instance.notifyChanged();
  }

  /// 处理内联提问卡片的选项点选：发送 user_answer 并标记该问题已作答。
  void _handleAskAnswer(String messageId, String answer) {
    _asking = false;
    final int idx = _messages.indexWhere((ChatMessage m) => m.id == messageId);
    if (idx >= 0) {
      setState(() {
        _messages[idx].answered = true;
      });
    }
    _webSocket.send(<String, dynamic>{
      'type': 'user_answer',
      'data': {'question_id': messageId, 'answer': answer},
    });
    // 通知右栏「问题回复」页标记该问题已回复
    QuestionUpdateService.instance.notifyChanged();
  }

  /// 请求停止当前 agent/会话的进行中任务
  void _handleStop() {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    _webSocket.send(<String, dynamic>{
      'type': 'stop',
      'data': {'agent_id': agent.id, 'session_id': _currentSessionId},
    });
  }

  /// 处理发送
  ///
  /// 先在本地追加用户消息，再通过 WebSocket 发送给后端。
  void _handleSend(String text, List<String> filePaths) {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;

    final List<Attachment> attachments = filePaths
        .map((String p) => Attachment(
              name: _basename(p),
              size: 0,
              type: '',
            ))
        .toList();

    final ChatMessage userMessage = ChatMessage(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
      attachments: attachments.isEmpty ? null : attachments,
    );

    setState(() {
      _messages.add(userMessage);
      _scrollRevision++;
      // 发送首条消息后锁定运行模式（后端会话自此绑定本地/云端工具）
      _modeLocked = true;
    });

    _webSocket.sendMessage(<String, dynamic>{
      'type': 'user_message',
      'agent_id': agent.id,
      'content': text,
      'attachments': filePaths,
      'session_id': _currentSessionId,
    });
  }

  /// 从路径中提取文件名（兼容 / 与 \）
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  /// 切换当前顶部 agent 的运行模式（cloud / local / ssh，三态互斥）。
  ///
  /// - 切到 local：若 ssh 已启用先注销 ssh；未选目录则先选目录，再启用本地执行器。
  /// - 切到 ssh：若 local 已启用先注销 local；弹出 SSH 配置表单，确认后注册并等待
  ///   后端 ack（连接测试失败会回显错误）。
  /// - 切到 cloud：注销 local 与 ssh，恢复云端执行。
  Future<void> _switchMode(String targetMode) async {
    if (_togglingMode) return;
    // 发送首条消息后会话已绑定本地/云端工具，禁止再切换运行模式
    if (_modeLocked) {
      _showSnackBar('对话已开始，该顶部 agent 的运行模式已锁定，无法切换');
      return;
    }
    final String current = _currentMode;
    if (targetMode == current) return;

    _togglingMode = true;
    try {
      if (targetMode == 'cloud') {
        if (current == 'local') {
          await LocalExecutorService.instance.setEnabled(false);
        } else if (current == 'ssh') {
          await SshExecutorService.instance.disable();
        }
        if (!mounted) return;
        setState(() {
          _localEnabled = false;
          _sshEnabled = false;
        });
        _showSnackBar('已切换为云端执行模式（Docker 容器）');
      } else if (targetMode == 'local') {
        // 移动端（Android/iOS）无桌面文件系统与目录选择能力，本地执行不可用
        if (isMobile) {
          _showSnackBar('移动端不支持本地执行模式，请使用云端或 SSH 模式');
          return;
        }
        // 与 SSH 互斥：先注销 ssh
        if (current == 'ssh') {
          await SshExecutorService.instance.disable();
        }
        // 开启前先选目录（工具执行结果写入此目录）
        // 注意：新 agent 的 _localWorkingDir 可能是空字符串而非 null，
        // 因此同时检查 null 和空字符串，确保目录必选
        if (_localWorkingDir == null || _localWorkingDir!.isEmpty) {
          await _pickWorkingDirectory();
          // 用户取消选择或路径仍为空，不启用本地模式
          if (_localWorkingDir == null || _localWorkingDir!.isEmpty) return;
        }
        await LocalExecutorService.instance.setEnabled(true);
        if (!mounted) return;
        setState(() {
          _localEnabled = true;
          _sshEnabled = false;
        });
        _showSnackBar('本地执行模式已启用（工具直接在本机目录运行）');
      } else if (targetMode == 'ssh') {
        // 与 local 互斥：先注销 local
        if (current == 'local') {
          await LocalExecutorService.instance.setEnabled(false);
        }
        if (!mounted) return;
        // 弹出 SSH 配置表单（预填已有配置）
        final Map<String, dynamic>? config = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (BuildContext dialogContext) =>
              SshConfigDialog(initialConfig: _sshConfig),
        );
        if (config == null || !mounted) return;
        // 注册并等待后端 ack（后端会先测试连接）
        final Map<String, dynamic> ack =
            await SshExecutorService.instance.enable(config);
        if (!mounted) return;
        if (ack['success'] == true) {
          setState(() {
            _sshEnabled = true;
            _localEnabled = false;
            _sshConfig = config;
          });
          _showSnackBar('SSH 执行模式已启用（工具在远端主机执行）');
        } else {
          _showSnackBar('SSH 启用失败：${ack['message'] ?? '未知错误'}');
        }
      }
    } finally {
      _togglingMode = false;
    }
  }

  /// 选择工作目录（用户项目根目录，工具读写/命令执行都在此目录下）
  Future<void> _pickWorkingDirectory() async {
    final String? path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择项目根目录（工具执行结果写入此目录）',
    );
    if (path == null || path.isEmpty) return;
    await LocalExecutorService.instance.setWorkingDirectory(path);
    if (!mounted) return;
    setState(() {
      _localWorkingDir = path;
    });
  }

  /// 显示 SnackBar 提示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _webSocket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Agent? agent = widget.selectedAgent;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: <Widget>[
          _buildTitleBar(agent),
          if (agent != null) _buildContextBar(),
          if (agent == null)
            Expanded(
              child: Center(
                child: Text(
                  '请选择一个 Agent 开始对话',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ),
            )
          else
            Expanded(
                      child: MessageList(
                        messages: _messages,
                        revision: _scrollRevision,
                        onAskAnswer: _handleAskAnswer,
                        scrollToMessageId: _scrollToMessageId,
                        scrollToRevision: _scrollToRevision,
                      ),
                    ),
          if (agent != null) MessageInput(onSend: _handleSend),
        ],
      ),
    );
  }

  /// 构建上下文长度栏：展示当前会话最近一次回复时的上下文长度
  /// （prompt_tokens / max_tokens），无数据时显示占位提示。
  Widget _buildContextBar() {
    final cs = Theme.of(context).colorScheme;
    final Agent? agent = widget.selectedAgent;
    final Map<String, dynamic>? usage = agent != null
        ? _usageByAgent['${agent.id}::$_currentSessionId']
        : null;
    final int promptTokens =
        (usage?['prompt_tokens'] as num?)?.toInt() ?? 0;
    final int maxTokens = (usage?['max_tokens'] as num?)?.toInt() ?? 0;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.3),
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.data_usage, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text('上下文', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          const SizedBox(width: 8),
          if (maxTokens > 0)
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (promptTokens / maxTokens).clamp(0.0, 1.0),
                  backgroundColor: cs.surfaceVariant.withOpacity(0.5),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    promptTokens > maxTokens * 0.9
                        ? cs.error
                        : cs.primary,
                  ),
                  minHeight: 4,
                ),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            maxTokens > 0
                ? '${_formatTokens(promptTokens)} / ${_formatTokens(maxTokens)}'
                : (promptTokens > 0
                    ? _formatTokens(promptTokens)
                    : '暂无数据'),
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 将 token 数格式化为千分位可读文本（如 12345 -> 12.3k）
  String _formatTokens(int value) {
    if (value >= 10000) {
      final double k = value / 1000.0;
      return '${k.toStringAsFixed(1)}k';
    }
    return value.toString();
  }

  /// 构建标题栏（Agent 名称 + 本地运行开关 + 状态 + 停止/teammates/压缩按钮）
  Widget _buildTitleBar(Agent? agent) {
    final cs = Theme.of(context).colorScheme;
    final String? title = agent?.name;
    // 当前 agent 是否在工作
    final bool working = agent != null && _workingAgents.contains(agent.id);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          // 运行模式三态开关（消息窗口左上：cloud / local / ssh）
          _buildModeSwitch(cs),
          // 工作目录选择（仅本地模式启用时显示）
          if (_localEnabled) _buildWorkingDirSelector(cs),
          // SSH 远端主机标签（仅 SSH 模式启用时显示）
          if (_sshEnabled) _buildSshHostLabel(cs),
          // Agent 名称
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      title ?? '未选择',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (working) ...<Widget>[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '工作中',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (agent != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SessionPicker(
                sessions: _sessions,
                currentSessionId: _currentSessionId,
                onSelect: _handleSelectSession,
                onCreate: _handleCreateSession,
                onRename: _handleRenameSession,
                onDelete: _handleDeleteSession,
              ),
            ),
          if (agent != null)
            IconButton(
              tooltip: '任务规范 Spec',
              icon: const Icon(Icons.auto_awesome, size: 20),
              onPressed: () => _openSpecPanel(agent),
            ),
          if (agent != null)
            IconButton(
              tooltip: '查看 teammates 工作进度',
              icon: const Icon(Icons.hub, size: 20),
              onPressed: () => _openTeammatesWindow(agent),
            ),
          if (working)
            IconButton(
              tooltip: '停止',
              icon: Icon(Icons.stop_circle, size: 22, color: cs.error),
              onPressed: _handleStop,
            ),
          if (agent != null)
            IconButton(
              tooltip: '压缩上下文',
              icon: const Icon(Icons.compress, size: 20),
              onPressed: () => _compactContext(agent.id),
            ),
        ],
      ),
    );
  }

  /// 构建运行模式三态开关（消息窗口左上）
  Widget _buildModeSwitch(ColorScheme cs) {
    return SizedBox(
      width: 36,
      height: 36,
      child: ModeSwitchButton(
        mode: _currentMode,
        locked: _modeLocked,
        onSelect: _switchMode,
        // 移动端不支持本机目录执行，隐藏「本地执行」菜单项
        showLocal: !isMobile,
      ),
    );
  }

  /// 构建 SSH 远端主机标签（仅 SSH 模式启用时显示）
  Widget _buildSshHostLabel(ColorScheme cs) {
    final String host = (_sshConfig['host'] as String?) ?? '';
    final String username = (_sshConfig['username'] as String?) ?? '';
    final String label = username.isNotEmpty && host.isNotEmpty
        ? '$username@$host'
        : host;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text(
          label.isEmpty ? 'SSH' : label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.orange,
          ),
        ),
      ),
    );
  }

  /// 构建工作目录选择器（仅本地模式启用时显示）
  Widget _buildWorkingDirSelector(ColorScheme cs) {
    final String displayPath = _basename(_localWorkingDir ?? '');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 100),
          child: GestureDetector(
            onTap: _pickWorkingDirectory,
            child: Text(
              displayPath.isEmpty ? '选择目录' : displayPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(Icons.folder_open, size: 16, color: cs.primary),
            onPressed: _pickWorkingDirectory,
            tooltip: '选择工作目录',
          ),
        ),
      ],
    );
  }

  /// 打开 teammates 工作进度窗口
  void _openTeammatesWindow(Agent agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TeammatesWindowPage(
          agent: agent,
          // 透传当前会话：进度页历史/实时 WS 按该成员+该会话过滤，
          // 避免把该成员其他会话的工作进度混进当前窗口（跨会话）。
          sessionId: _currentSessionId,
        ),
      ),
    );
  }

  /// 打开任务规范（Spec）面板
  void _openSpecPanel(Agent agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SpecPanel(
          agent: agent,
          sessionId: _currentSessionId,
        ),
      ),
    );
  }

  // ==================== 多会话管理 ====================

  /// 切换会话：清空当前消息列表并加载目标会话历史
  void _handleSelectSession(ChatSession session) {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    if (session.sessionId == _currentSessionId) return;
    setState(() {
      _currentSession = session;
      _messages.clear();
      _scrollRevision++;
    });
    widget.onSessionChanged?.call(_currentSessionId);
    _loadHistory();
  }

  /// 新建会话：创建后自动选中并切换
  Future<void> _handleCreateSession() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    try {
      final ChatSession session = await ApiService.createSession(agent.id);
      if (!mounted) return;
      setState(() {
        _sessions.add(session);
        _currentSession = session;
        _messages.clear();
        _scrollRevision++;
      });
      widget.onSessionChanged?.call(_currentSessionId);
      _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新建会话失败：$e')),
      );
    }
  }

  /// 重命名会话（弹窗输入新标题）
  Future<void> _handleRenameSession(ChatSession session) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final TextEditingController controller =
        TextEditingController(text: session.title);
    final String? newTitle = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(labelText: '会话标题'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty) return;
    try {
      await ApiService.renameSession(agent.id, session.sessionId, newTitle);
      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .map((ChatSession s) => s.sessionId == session.sessionId
                ? ChatSession(
                    sessionId: s.sessionId,
                    title: newTitle,
                    status: s.status,
                    createdAt: s.createdAt,
                    updatedAt: s.updatedAt,
                    selectedSpecIds: s.selectedSpecIds,
                  )
                : s)
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重命名失败：$e')),
      );
    }
  }

  /// 删除会话（默认会话不可删除）：确认后删除并切换到剩余会话
  Future<void> _handleDeleteSession(ChatSession session) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null || session.isDefault) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除会话「${session.title}」吗？该会话的对话与上下文将被清除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiService.deleteSession(agent.id, session.sessionId);
      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .where((ChatSession s) => s.sessionId != session.sessionId)
            .toList();
        // 若删除的是当前会话，切到剩余首个会话
        if (_currentSessionId == session.sessionId) {
          _currentSession = _sessions.isNotEmpty ? _sessions.first : null;
          _messages.clear();
          _scrollRevision++;
          if (mounted) {
            widget.onSessionChanged?.call(_currentSessionId);
          }
        }
      });
      _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除会话失败：$e')),
      );
    }
  }

  /// 触发后端上下文压缩（compact 按钮）
  Future<void> _compactContext(String agentId) async {
    try {
      final Map<String, dynamic> result = await ApiService.compactAgent(
        agentId,
        sessionId: _currentSessionId,
      );
      if (!mounted) return;
      final bool compressed = result['compressed'] == true;
      final String reason = (result['reason'] ?? '') as String;
      final String message;
      if (compressed) {
        message = '已压缩上下文（当前 ${result['context_size']} 条）';
      } else if (reason == 'no_active_session') {
        message = '该 agent 当前没有活跃的会话上下文';
      } else if (reason == 'too_few_messages') {
        message = '对话消息太少，暂无需压缩';
      } else if (reason == 'nothing_to_summarize') {
        message = '最近对话较短，暂无需压缩';
      } else {
        message = '上下文无需压缩';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('压缩失败：$e')));
    }
  }
}
