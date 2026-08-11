import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/websocket_service.dart';
import 'message_input.dart';
import 'message_list.dart';

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

  @override
  void initState() {
    super.initState();
    _webSocket.onMessage = _handleIncomingMessage;
    _connectWebSocket();
    // 首次进入时若已选中 agent 则加载历史
    if (widget.selectedAgent != null) {
      _loadHistory();
    }
  }

  @override
  void didUpdateWidget(covariant MessagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换 Agent 或外部触发刷新时清空消息列表并加载历史
    if (oldWidget.selectedAgent?.id != widget.selectedAgent?.id) {
      setState(() {
        _messages.clear();
      });
      _loadHistory();
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
    _webSocket.connect(token);
    _wsConnected = true;
  }

  /// 处理后端推送的消息
  ///
  /// 支持三种流式事件：
  /// - `stream_start`：创建空的 agent 消息并标记为流式
  /// - `stream_chunk`：向对应消息追加内容
  /// - `stream_end`：标记对应消息流式结束
  ///
  /// 其他类型消息按完整 JSON 解析后直接加入列表。
  void _handleIncomingMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    final String? type = data['type'] as String?;
    if (type == 'stream_start') {
      final ChatMessage message = ChatMessage(
        id: (data['id'] as String?) ??
            'agent_${DateTime.now().millisecondsSinceEpoch}',
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      );
      setState(() {
        _messages.add(message);
        _scrollRevision++;
      });
    } else if (type == 'stream_chunk') {
      final String id = (data['id'] as String?) ?? '';
      final String chunk = (data['chunk'] as String?) ?? '';
      final int idx = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (idx >= 0) {
        setState(() {
          _messages[idx].content += chunk;
        });
      }
    } else if (type == 'stream_end') {
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
    } else if (type == 'message') {
      // 完整 agent 消息（如后端 _send_text_as_agent 发送的错误提示）
      final ChatMessage message = ChatMessage.fromJson(data);
      setState(() {
        _messages.add(message);
        _scrollRevision++;
      });
    }
    // 其余控制消息（tool_call / agent_status / file_sync_progress /
    // heartbeat / error 等）不含 content，忽略，避免产生空回复气泡。
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

  /// 构建标题栏（显示 Agent 名称 + normal LLM 的上下文压缩按钮）
  Widget _buildTitleBar(Agent? agent) {
    final cs = Theme.of(context).colorScheme;
    final String? title = agent?.name;
    // 仅 normal LLM 需要上下文压缩（无限上下文 LLM 无操作）
    final bool showCompact = agent != null && !agent.isLimitless;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
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
