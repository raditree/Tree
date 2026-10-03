import 'package:flutter/material.dart';

import 'package:tree_protocol/tree_protocol.dart';

import '../models/message.dart';
import '../../io/api_service.dart';
import '../../io/websocket_service.dart';
import '../services/subagent_transcript.dart';
import 'subagent_process_list.dart';

/// 临时员工（subagent）的**工作进度页**——与 teammates 窗口**同一层级**的独立入口。
///
/// 用户 2026-10-04：「应该做和 teammates 同级的工作显示（仅显示与 teammates 同级），在对话框
/// 支持选择进入 subagent 视角」。所以它不是嵌在工具详情里的一小块，而是一页：
/// 头部（名字 / 层级 / id / 它自己的上下文用量 / 实时状态）+ 它的完整过程（文本 / 思考 /
/// 工具调用 / 完成报告，与详情页共用 [SubagentProcessList]）。
///
/// 数据来源：过程消息来自 [SubagentTranscript]（面板每帧同步一次，实时跟进）；
/// working / idle 由本页自己的 WS 连接按 `subagent_id` 过滤 [WsOutboundType.agentStatus]
/// 帧得到（与 teammates 窗口同一条做法）。
class SubagentViewPage extends StatefulWidget {
  const SubagentViewPage({
    super.key,
    required this.subagentId,
    required this.agentId,
    required this.sessionId,
    this.fallbackName = '',
    this.ownerName = '',
  });

  /// 临时员工 id（`sub_…`）。
  final String subagentId;

  /// 会话主人（帧过滤用）。
  final String agentId;
  final String sessionId;

  /// 还没有过程消息时先用这个名字当标题（从选择列表带进来）。
  final String fallbackName;

  /// **发出这次调用的 agent** 的显示名（它才是"同级"的那个：临时员工是它召来的，
  /// 不是团队成员）。名字只有面板知道，所以由它传进来。
  final String ownerName;

  @override
  State<SubagentViewPage> createState() => _SubagentViewPageState();
}

class _SubagentViewPageState extends State<SubagentViewPage> {
  final WebSocketService _webSocket = WebSocketService();
  bool _wsConnected = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _webSocket.onMessage = _handleWsMessage;
    _webSocket.onConnectionChange = (bool connected) {
      if (connected && mounted) setState(() => _working = false);
    };
    final String? token = ApiService.token;
    if (token != null && token.isNotEmpty) {
      _webSocket.connect(token);
      _wsConnected = true;
    }
  }

  @override
  void dispose() {
    _webSocket.disconnect();
    super.dispose();
  }

  void _handleWsMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    if ((data['type'] as String?) != WsOutboundType.agentStatus) return;
    final Map<String, dynamic> d =
        (data['data'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
    // 只认**这一个**临时员工的状态（帧归属是会话主人，靠 subagent_id 分辨）
    if ((d['subagent_id'] as String?) != widget.subagentId) return;
    final String? sessionId = d['session_id'] as String?;
    if (sessionId != null && sessionId != widget.sessionId) return;
    final String status = (d['status'] as String?) ?? '';
    setState(() {
      _working =
          status == 'working' ||
          status == 'updating_memory' ||
          status == 'compacting';
    });
  }

  /// 调用方显示名（对齐语义：临时员工是"某个 agent 召来的"，不是团队成员）。
  String _callerName() {
    final String name = SubagentTranscript.instance.callerNameOf(
      widget.subagentId,
      ownerAgentId: widget.agentId,
      ownerName: widget.ownerName,
    );
    if (name.isNotEmpty) return name;
    return widget.ownerName.isEmpty ? '（未知调用方）' : widget.ownerName;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: SubagentTranscript.instance,
          builder: (BuildContext context, Widget? child) {
            final List<ChatMessage> transcript = SubagentTranscript.instance.of(
              widget.subagentId,
            );
            final String name = transcript.isNotEmpty &&
                    transcript.first.subagentName.isNotEmpty
                ? transcript.first.subagentName
                : (widget.fallbackName.isEmpty ? '临时员工' : widget.fallbackName);
            return Text('临时员工「$name」', style: const TextStyle(fontSize: 16));
          },
        ),
        actions: <Widget>[
          if (_working)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '工作中',
                  style: TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: SubagentTranscript.instance,
        builder: (BuildContext context, Widget? child) {
          final List<ChatMessage> transcript = SubagentTranscript.instance.of(
            widget.subagentId,
          );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              _buildHeaderCard(context, cs, transcript),
              const SizedBox(height: 16),
              SubagentProcessList(
                messages: transcript,
                emptyHint: '还没有收到它的过程消息：它可能刚被召来（正在准备），'
                    '也可能这一轮只有报告。',
              ),
            ],
          );
        },
      ),
    );
  }

  /// 头部卡片：它是什么（层级 / id）+ 它自己的上下文用量 + 实时状态。
  Widget _buildHeaderCard(
    BuildContext context,
    ColorScheme cs,
    List<ChatMessage> transcript,
  ) {
    final int level = transcript.isEmpty ? 0 : transcript.first.subagentLevel;
    final String? usage = subagentUsageLine(transcript);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.person_outline, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '由「${_callerName()}」召来 · 第 ${level == 0 ? 1 : level} 层 · '
                  '${widget.subagentId}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              Text(
                _working ? '工作中' : '空闲',
                style: TextStyle(
                  fontSize: 12,
                  color: _working ? Colors.orange : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (usage != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              usage,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '它是**发出这次调用的那个 agent** 现场召来的临时员工（与它的调用方同级，'
            '不是团队成员）：只活在**这个会话**里，一切过程都记在会话历史里；'
            '中栏主消息流不显示它的过程（去"调用它的那次 subagent 工具调用"里也能看）。',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, height: 1.4),
          ),
          if (!_wsConnected) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '实时状态未连接（历史过程照常显示）',
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
          ],
        ],
      ),
    );
  }
}
