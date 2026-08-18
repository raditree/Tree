import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/local_executor_service.dart';
import '../services/websocket_service.dart';
import 'message_input.dart';
import 'message_list.dart';
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

  const MessagePanel({
    super.key,
    this.selectedAgent,
    this.refreshTrigger = 0,
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

  /// 处于 working 状态的 agent 集合（用于标题栏显示状态与停止按钮）
  final Set<String> _workingAgents = <String>{};

  /// 各 agent 最近的非 idle 状态（working / updating_memory 等），用于区分状态文案
  final Map<String, String> _agentStatus = <String, String>{};

  /// 是否正在等待用户回答 agent 的问题（AskUserQuestion）
  bool _asking = false;

  /// 本地运行模式是否启用
  bool _localEnabled = false;

  /// 本地后端工作目录
  String? _localWorkingDir;

  /// 切换运行模式时的防重入守卫（不再启动任何本地后端，仅防双击）
  bool _togglingMode = false;

  /// 当前顶部 agent 的对话是否已开始（发送首条消息后运行模式锁定，
  /// 防止因后端会话已绑定本地/云端工具而出现模式切换"不生效"的困惑）
  bool _modeLocked = false;

  /// 预算数据（来自后端 budget_update 事件）
  Map<String, dynamic>? _budgetData;

  /// 预算输入控制器
  final TextEditingController _budgetInputController = TextEditingController();

  /// 是否显示预算设置输入框
  bool _showBudgetInput = false;

  @override
  void initState() {
    super.initState();
    _webSocket.onMessage = _handleIncomingMessage;
    // 先恢复本地模式设置（按顶部 agent），再建立 WebSocket 连接，
    // 确保连接建立后能按正确的本地模式注册执行器
    _initAsync();
    // 首次进入时若已选中 agent 则加载历史与预算
    if (widget.selectedAgent != null) {
      _loadHistory();
      _loadBudget();
    }
  }

  /// 初始化：先加载当前顶部 agent 的本地模式设置，再连接 WebSocket
  Future<void> _initAsync() async {
    await _loadLocalSettings();
    if (!mounted) return;
    await _connectWebSocket();
  }

  /// 加载当前顶部 agent 的本地执行模式持久化设置，并同步注册/注销
  Future<void> _loadLocalSettings() async {
    if (widget.selectedAgent != null) {
      LocalExecutorService.instance
          .setCurrentTopAgent(widget.selectedAgent!.id);
    }
    await LocalExecutorService.instance.loadSettings();
    if (!mounted) return;
    setState(() {
      _localEnabled = LocalExecutorService.instance.enabled;
      _localWorkingDir = LocalExecutorService.instance.workingDirectory;
    });
    // 连接已建立时，按当前顶部 agent 的本地模式同步注册/注销
    if (_wsConnected && _webSocket.isConnected) {
      LocalExecutorService.instance.syncRegistration();
    }
  }

  @override
  void didUpdateWidget(covariant MessagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换 Agent 或外部触发刷新时清空消息列表并加载历史
    if (oldWidget.selectedAgent?.id != widget.selectedAgent?.id) {
      setState(() {
        _messages.clear();
        _budgetData = null;
        // 切换顶部 agent 后解除锁定，由新 agent 的历史/首条消息重新决定
        _modeLocked = false;
      });
      _loadHistory();
      _loadBudget();
      // 切换顶部 agent：加载其独立的本地模式设置并同步注册/注销
      _loadLocalSettings();
    } else if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      setState(() {
        _messages.clear();
      });
      _loadHistory();
    }
  }

  /// 从后端拉取当前 agent 的对话历史
  Future<void> _loadHistory() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    try {
      final List<Map<String, dynamic>> raw =
          await ApiService.getConversationHistory(agent.id);
      if (!mounted) return;
      setState(() {
        _messages.clear();
        for (final Map<String, dynamic> item in raw) {
          _messages.add(ChatMessage.fromJson(item));
        }
        // 历史已存在说明该顶部 agent 的对话已开始，运行模式一并锁定
        _modeLocked = _messages.isNotEmpty;
        _scrollRevision++;
      });
    } catch (e) {
      // 拉取失败时静默处理（保持空列表）
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
    _webSocket.connect(token);
    _wsConnected = true;
    // 按当前顶部 agent 的本地模式注册/注销（须在连接建立后发送）
    LocalExecutorService.instance.syncRegistration();
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

    if (type == 'msg_start') {
      if (!_isForCurrentAgent(data)) return;
      final ChatMessage message = ChatMessage(
        id: data['id'] as String? ?? '',
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      );
      if (message.id.isEmpty) return;
      setState(() {
        _messages.add(message);
        _scrollRevision++;
      });
    } else if (type == 'msg_chunk') {
      final String id = (data['id'] as String?) ?? '';
      final String chunk = (data['chunk'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        setState(() {
          _messages[idx].content += chunk;
        });
      }
    } else if (type == 'msg_end') {
      final String id = (data['id'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        final Map<String, dynamic>? usage =
            (data['usage'] as Map<String, dynamic>?)?.cast<String, dynamic>();
        setState(() {
          _messages[idx].isStreaming = false;
          _messages[idx].usage = usage;
          _scrollRevision++;
        });
      }
    } else if (type == 'msg_usage') {
      final String id = (data['id'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        final Map<String, dynamic>? usage =
            (data['usage'] as Map<String, dynamic>?)?.cast<String, dynamic>();
        setState(() {
          _messages[idx].usage = usage;
        });
      }
    } else if (type == 'tool_start') {
      if (!_isForCurrentAgent(data)) return;
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
      final String id = (data['id'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        setState(() {
          _messages[idx].toolRunning = false;
          _messages[idx].toolResult = (data['result'] as String?) ?? '';
        });
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
          _agentStatus[agentId] = 'working';
        } else if (status == 'updating_memory') {
          // 记忆更新阶段：仍视为忙碌（停止按钮可用），但展示独立文案
          _workingAgents.add(agentId);
          _agentStatus[agentId] = 'updating_memory';
        } else if (status == 'idle' || status == 'stopping') {
          _workingAgents.remove(agentId);
          _agentStatus.remove(agentId);
        }
      });
    } else if (type == 'ask_user_question') {
      _handleAskUserQuestion(data);
    } else if (type == 'budget_update') {
      // 预算更新事件
      final Map<String, dynamic>? d = data['data'] as Map<String, dynamic>?;
      if (d != null && d['budget'] != null && (d['budget'] as num).toDouble() > 0) {
        setState(() {
          _budgetData = Map<String, dynamic>.from(d);
        });
      }
    } else if (type == 'message') {
      if (!_isForCurrentAgent(data)) return;
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

  /// 处理 agent 的提问（AskUserQuestion 工具）：弹出选择/输入对话框
  void _handleAskUserQuestion(Map<String, dynamic> data) {
    if (_asking) return;
    _asking = true;
    final String qid = (data['id'] as String?) ?? '';
    final String question = (data['question'] as String?) ?? '提问';
    final List<String> options =
        (data['options'] as List?)?.map((e) => e.toString()).toList() ??
            <String>[];
    final TextEditingController controller = TextEditingController();

    Future<void> submit(String answer) async {
      _asking = false;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      controller.dispose();
      _webSocket.send(<String, dynamic>{
        'type': 'user_answer',
        'data': {'question_id': qid, 'answer': answer},
      });
    }

    Future<void> cancel() async {
      _asking = false;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      controller.dispose();
      _webSocket.send(<String, dynamic>{
        'type': 'cancel_question',
        'data': {'question_id': qid},
      });
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Agent 需要你的输入'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(question, style: const TextStyle(fontSize: 14)),
                if (options.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  for (final String option in options)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        title: Text(option, style: const TextStyle(fontSize: 13)),
                        onTap: () => submit(option),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    labelText: '或直接输入回答',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: cancel, child: const Text('取消')),
            TextButton(
              onPressed: () => submit(controller.text.trim()),
              child: const Text('发送'),
            ),
          ],
        );
      },
    ).then((_) {
      _asking = false;
      controller.dispose();
    });
  }

  /// 请求停止当前 agent 的进行中任务
  void _handleStop() {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    _webSocket.send(<String, dynamic>{
      'type': 'stop',
      'data': {'agent_id': agent.id},
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
    });
  }

  /// 从路径中提取文件名（兼容 / 与 \）
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  /// 切换当前顶部 agent 的本地执行模式。
  ///
  /// 仅需持久化开关并经反向 WS 注册/注销本地执行器，无需启动任何本地进程。
  Future<void> _toggleLocalMode() async {
    if (_togglingMode) return;
    // 发送首条消息后会话已绑定本地/云端工具，禁止再切换运行模式
    if (_modeLocked) {
      _showSnackBar('对话已开始，该顶部 agent 的运行模式已锁定，无法切换');
      return;
    }

    _togglingMode = true;
    try {
      if (_localEnabled) {
        // 关闭当前顶部 agent 的本地执行模式（后端注销该 agent 的本地执行器）
        await LocalExecutorService.instance.setEnabled(false);
        if (mounted) setState(() => _localEnabled = false);
      } else {
        // 开启前先选目录（工具执行结果写入此目录）
        // 注意：新 agent 的 _localWorkingDir 可能是空字符串而非 null，
        // 因此同时检查 null 和空字符串，确保目录必选
        if (_localWorkingDir == null || _localWorkingDir!.isEmpty) {
          await _pickWorkingDirectory();
          // 用户取消选择或路径仍为空，不启用本地模式
          if (_localWorkingDir == null || _localWorkingDir!.isEmpty) return;
        }
        await LocalExecutorService.instance.setEnabled(true);
        if (mounted) {
          setState(() => _localEnabled = true);
          _showSnackBar('本地执行模式已启用（工具直接在本机目录运行）');
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
    _budgetInputController.dispose();
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
          if (agent != null) _buildBudgetBar(),
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
            Expanded(child: MessageList(messages: _messages, revision: _scrollRevision)),
          if (agent != null) MessageInput(onSend: _handleSend),
        ],
      ),
    );
  }

  /// 从后端拉取当前 agent 的预算状态
  Future<void> _loadBudget() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    try {
      final Map<String, dynamic> data = await ApiService.getBudget(agent.id);
      if (!mounted) return;
      if (data['budget'] != null && (data['budget'] as num).toDouble() > 0) {
        setState(() {
          _budgetData = data;
        });
      }
    } catch (_) {
      // 静默失败
    }
  }

  /// 设置预算并发送到后端，关闭输入框
  Future<void> _setBudget() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String text = _budgetInputController.text.trim();
    final double? budget = double.tryParse(text);
    if (budget == null || budget <= 0) {
      _showSnackBar('请输入有效的预算金额（美元）');
      return;
    }
    try {
      await ApiService.setBudget(agent.id, budget);
      if (!mounted) return;
      setState(() {
        _showBudgetInput = false;
        _budgetInputController.clear();
      });
      // 设置后拉取一次最新状态
      _loadBudget();
      _showSnackBar('预算已设置为 \$${budget.toStringAsFixed(2)}');
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('设置预算失败: $e');
    }
  }

  /// 构建预算栏（显示预算使用进度条 + 设置按钮）
  Widget _buildBudgetBar() {
    final cs = Theme.of(context).colorScheme;
    final bool hasBudget = _budgetData != null &&
        _budgetData!['budget'] != null &&
        (_budgetData!['budget'] as num).toDouble() > 0;

    // 无预算时显示 "设置预算" 按钮
    if (!hasBudget) {
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
            Icon(Icons.account_balance_wallet_outlined, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('预算', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            const Spacer(),
            if (_showBudgetInput)
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: TextField(
                    controller: _budgetInputController,
                    autofocus: true,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: '输入金额（美元）',
                      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _setBudget(),
                    onTapOutside: (_) => _setBudget(),
                  ),
                ),
              )
            else
              SizedBox(
                height: 24,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('设置预算'),
                  onPressed: () {
                    setState(() => _showBudgetInput = true);
                  },
                ),
              ),
          ],
        ),
      );
    }

    // 有预算时显示进度条
    if (_showBudgetInput) {
      // 修改预算模式：显示输入框，焦点离开自动确认
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
            Icon(Icons.account_balance_wallet, size: 14, color: cs.primary),
            const SizedBox(width: 4),
            Expanded(
              child: SizedBox(
                height: 24,
                child: TextField(
                  controller: _budgetInputController,
                  autofocus: true,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: '修改预算金额（美元）',
                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _setBudget(),
                  onTapOutside: (_) => _setBudget(),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final double budget = (_budgetData!['budget'] as num).toDouble();
    final double used = (_budgetData!['used'] as num?)?.toDouble() ?? 0;
    final double remaining = (_budgetData!['remaining'] as num?)?.toDouble() ?? budget;
    final double percentage = (_budgetData!['percentage'] as num?)?.toDouble() ?? 0;
    final int inputTokens = (_budgetData!['input_tokens'] as num?)?.toInt() ?? 0;
    final int outputTokens = (_budgetData!['output_tokens'] as num?)?.toInt() ?? 0;
    final int cachedTokens = (_budgetData!['cached_tokens'] as num?)?.toInt() ?? 0;

    final Color barColor = percentage >= 100
        ? cs.error
        : percentage >= 80
            ? Colors.orange
            : percentage >= 50
                ? Colors.amber
                : Colors.green;

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
          Icon(Icons.account_balance_wallet, size: 14, color: barColor),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // 进度条
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: percentage / 100.0,
                    backgroundColor: cs.surfaceVariant.withOpacity(0.5),
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    minHeight: 4,
                  ),
                ),
                const SizedBox(height: 2),
                // 文字信息
                Row(
                  children: <Widget>[
                    Text(
                      '已用 \$${used.toStringAsFixed(4)}',
                      style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                    ),
                    const Spacer(),
                    Text(
                      '剩余 \$${remaining.toStringAsFixed(4)}',
                      style: TextStyle(fontSize: 9, color: barColor),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${percentage.toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: barColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 修改预算按钮
          SizedBox(
            width: 20,
            height: 20,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 12,
              icon: Icon(Icons.edit, color: cs.onSurfaceVariant),
              tooltip: '修改预算',
              onPressed: () {
                _budgetInputController.text = budget.toString();
                setState(() => _showBudgetInput = true);
              },
            ),
          ),
          // token 用量小图标
          Tooltip(
            message: '输入: $inputTokens | 输出: $outputTokens | 缓存命中: $cachedTokens',
            child: Icon(Icons.info_outline, size: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 构建标题栏（Agent 名称 + 本地运行开关 + 状态 + 停止/teammates/压缩按钮）
  Widget _buildTitleBar(Agent? agent) {
    final cs = Theme.of(context).colorScheme;
    final String? title = agent?.name;
    // 仅 normal LLM 需要上下文压缩（无限上下文 LLM 无操作）
    final bool showCompact = agent != null && !agent.isLimitless;
    // 当前 agent 是否在工作
    final bool working = agent != null && _workingAgents.contains(agent.id);
    // 工作状态文案（区分更新记忆阶段）
    final String? agentStatus = agent != null ? _agentStatus[agent.id] : null;
    final bool updatingMemory = agentStatus == 'updating_memory';
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
          // 本地运行开关（消息窗口左上）
          _buildLocalRunToggle(cs),
          // 工作目录选择（仅本地模式启用时显示）
          if (_localEnabled) _buildWorkingDirSelector(cs),
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
                        color: updatingMemory
                            ? Colors.blue
                            : cs.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      updatingMemory ? '更新记忆中' : '工作中',
                      style: TextStyle(
                        fontSize: 11,
                        color: updatingMemory ? Colors.blue : Colors.orange,
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
          if (showCompact)
            IconButton(
              tooltip: '压缩上下文',
              icon: const Icon(Icons.compress, size: 20),
              onPressed: () => _compactContext(agent.id),
            ),
        ],
      ),
    );
  }

  /// 构建本地运行开关图标（消息窗口左上）
  Widget _buildLocalRunToggle(ColorScheme cs) {
    final Color iconColor = _localEnabled ? Colors.green : cs.onSurfaceVariant;
    final IconData icon = _localEnabled ? Icons.power : Icons.power_settings_new;
    final String tooltip = _modeLocked
        ? '对话已开始，该顶部 agent 的运行模式已锁定'
        : (_localEnabled
            ? '本地运行中（点击切换为远程）'
            : '远程模式（点击切换为本地运行）');
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 20, color: iconColor),
          // 对话开始后锁定运行模式，禁止切换
          onPressed: _modeLocked ? null : _toggleLocalMode,
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
        builder: (_) => TeammatesWindowPage(agent: agent),
      ),
    );
  }

  /// 触发后端上下文压缩（compact 按钮）
  Future<void> _compactContext(String agentId) async {
    try {
      final Map<String, dynamic> result =
          await ApiService.compactAgent(agentId);
      if (!mounted) return;
      final bool compressed = result['compressed'] == true;
      final String message = compressed
          ? '已压缩上下文（当前 ${result['context_size']} 条）'
          : (result['reason'] == 'no_active_session'
              ? '该 agent 当前没有活跃的会话上下文'
              : '上下文无需压缩或该 agent 不支持');
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
