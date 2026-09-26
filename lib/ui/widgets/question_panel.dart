import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/question_update_service.dart';
import '../models/agent.dart';

/// 单条提问记录（右侧「问题回复」页数据模型）
class _QuestionItem {
  final String qid;
  final String agentId;
  final String teamId;
  final String sessionId;
  final bool isMember;
  final String question;
  final List<String> options;
  final String answer;
  final String status;
  final int createdAt;

  _QuestionItem({
    required this.qid,
    required this.agentId,
    required this.teamId,
    required this.sessionId,
    required this.isMember,
    required this.question,
    required this.options,
    required this.answer,
    required this.status,
    required this.createdAt,
  });

  bool get isPending => status == 'pending';

  factory _QuestionItem.fromJson(Map<String, dynamic> json) {
    return _QuestionItem(
      qid: (json['qid'] ?? '').toString(),
      agentId: (json['agent_id'] ?? '').toString(),
      teamId: (json['team_id'] ?? '').toString(),
      sessionId: (json['session_id'] ?? '').toString(),
      isMember: json['is_member'] == true,
      question: (json['question'] ?? '').toString(),
      options: (json['options'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(),
      answer: (json['answer'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      createdAt: int.tryParse(json['created_at']?.toString() ?? '0') ?? 0,
    );
  }
}

/// 提问导航回调：点击右侧某条提问，跳转到对应的对话上下文位置。
///
/// - 主 agent 提问：切中栏到对应 agent/会话并滚动定位到该提问卡片。
/// - 成员提问：打开该成员的工作进度详情窗口并滚动定位。
typedef QuestionNavigateCallback = void Function({
  required bool isMember,
  required String agentId,
  required String teamId,
  required String sessionId,
  required String messageId,
});

/// 右侧面板「问题回复」页
///
/// 按当前会话汇总所有 agent（含团队成员）的提问：待回答置顶可交互作答，
/// 已回复/已取消置灰在后。收到全局 [QuestionUpdateService] 通知时自动刷新，
/// 与中栏内联卡片保持实时同步。
class QuestionPanel extends StatefulWidget {
  /// 当前会话 id（提问按会话隔离；为空时列出全部）
  final String sessionId;

  /// 定位回调（由 MainPage 提供，用于跳转到提问上下文）
  final QuestionNavigateCallback? onNavigateToQuestion;

  const QuestionPanel({
    super.key,
    this.sessionId = 'session_default',
    this.onNavigateToQuestion,
  });

  @override
  State<QuestionPanel> createState() => _QuestionPanelState();
}

class _QuestionPanelState extends State<QuestionPanel> {
  List<_QuestionItem> _questions = <_QuestionItem>[];
  bool _loading = true;
  String? _error;

  /// agent id → 名称 映射（用于来源标签显示）
  Map<String, String> _agentNames = <String, String>{};

  /// 每张待答卡片的输入框控制器（qid → controller）
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  /// 正在作答中的 qid 集合（防重复提交）
  final Set<String> _submitting = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
    QuestionUpdateService.instance.addListener(_load);
  }

  @override
  void didUpdateWidget(covariant QuestionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _load();
    }
  }

  @override
  void dispose() {
    QuestionUpdateService.instance.removeListener(_load);
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 软更新：有旧数据时不闪加载态
  Future<void> _load() async {
    setState(() {
      _loading = _questions.isEmpty;
      _error = null;
    });
    try {
      // 并行拉取提问列表与 agent 列表（agent 列表用于来源名称映射）
      final List<Map<String, dynamic>> raw = await ApiService.getQuestions(
        sessionId: widget.sessionId,
      );
      Map<String, String> names = _agentNames;
      try {
        final List<Agent> agents = await ApiService.getAgents();
        names = <String, String>{
          for (final Agent a in agents) a.id: a.name,
        };
      } catch (_) {
        // 拉取 agent 名称失败时沿用旧映射，不阻断提问列表
      }
      final List<_QuestionItem> items =
          raw.map(_QuestionItem.fromJson).toList(growable: false);
      // 待回答置顶，其余（已回复/已取消）按创建时间倒序排后
      items.sort((a, b) {
        if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });
      if (!mounted) return;
      setState(() {
        _questions = items;
        _agentNames = names;
        _loading = false;
        // 清理已不再展示待答输入框的控制器
        final Set<String> pendingIds =
            items.where((i) => i.isPending).map((i) => i.qid).toSet();
        _controllers.removeWhere((qid, _) => !pendingIds.contains(qid));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取提问失败：$e';
      });
    }
  }

  /// 提交回答：调 REST 接口，成功后本地置 answered 并通知全局刷新
  Future<void> _submitAnswer(_QuestionItem item, String answer) async {
    final String text = answer.trim();
    if (text.isEmpty || _submitting.contains(item.qid)) return;
    setState(() {
      _submitting.add(item.qid);
    });
    try {
      await ApiService.answerQuestion(item.qid, text);
      if (!mounted) return;
      setState(() {
        final int idx =
            _questions.indexWhere((_QuestionItem q) => q.qid == item.qid);
        if (idx >= 0) {
          _questions[idx] = _QuestionItem(
            qid: item.qid,
            agentId: item.agentId,
            teamId: item.teamId,
            sessionId: item.sessionId,
            isMember: item.isMember,
            question: item.question,
            options: item.options,
            answer: text,
            status: 'answered',
            createdAt: item.createdAt,
          );
        }
      });
      // 通知全局（中栏内联卡片由后端 ask_user_question_resolved 同步）
      QuestionUpdateService.instance.notifyChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交回答失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _submitting.remove(item.qid);
        });
      }
    }
  }

  /// 来源标签：成员提问加「成员」前缀，名称优先按 top_agent 映射
  String _sourceLabel(_QuestionItem item) {
    final String refId = item.teamId.isNotEmpty ? item.teamId : item.agentId;
    final String name = _agentNames[refId] ?? refId;
    final String label = name.isEmpty ? '未知来源' : name;
    return item.isMember ? '成员 · $label' : label;
  }

  void _navigate(_QuestionItem item) {
    final QuestionNavigateCallback? cb = widget.onNavigateToQuestion;
    if (cb == null) return;
    cb(
      isMember: item.isMember,
      agentId: item.agentId,
      teamId: item.teamId.isNotEmpty ? item.teamId : item.agentId,
      sessionId: item.sessionId,
      messageId: item.qid,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: cs.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_questions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.help_outline, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              '暂无提问',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _questions.length,
        itemBuilder: (BuildContext context, int index) {
          return _buildQuestionCard(context, _questions[index]);
        },
      ),
    );
  }

  Widget _buildQuestionCard(BuildContext context, _QuestionItem item) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: item.isPending ? cs.primary.withValues(alpha: 0.5) : cs.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 顶部：来源 + 状态徽标 + 定位按钮
            Row(
              children: <Widget>[
                Icon(
                  item.isPending ? Icons.help_outline : Icons.check_circle_outline,
                  size: 16,
                  color: item.isPending ? cs.primary : Colors.green,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _sourceLabel(item),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _buildStatusBadge(item),
                if (widget.onNavigateToQuestion != null) ...<Widget>[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '定位到提问位置',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: Icon(Icons.north_east, color: cs.primary),
                    onPressed: () => _navigate(item),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            // 提问文本
            Text(
              item.question.isEmpty ? '提问' : item.question,
              style: TextStyle(fontSize: 13, color: cs.onSurface, height: 1.4),
            ),
            if (item.isPending) ...<Widget>[
              if (item.options.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                for (final String option in item.options)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _submitting.contains(item.qid)
                            ? null
                            : () => _submitAnswer(item, option),
                        style: OutlinedButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                        ),
                        child: Text(
                          option,
                          style: TextStyle(fontSize: 12, color: cs.onSurface),
                        ),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 6),
              _buildAnswerInput(item),
            ] else if (item.status == 'answered')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '已回复：${item.answer}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '已取消',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(_QuestionItem item) {
    final cs = Theme.of(context).colorScheme;
    final Color color;
    final String text;
    switch (item.status) {
      case 'pending':
        color = cs.primary;
        text = '待回答';
        break;
      case 'answered':
        color = Colors.green;
        text = '已回复';
        break;
      default:
        color = cs.outline;
        text = '已取消';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _buildAnswerInput(_QuestionItem item) {
    final TextEditingController controller =
        _controllers.putIfAbsent(item.qid, TextEditingController.new);
    final bool busy = _submitting.contains(item.qid);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !busy,
            maxLines: 2,
            minLines: 1,
            onSubmitted: (_) => _submitAnswer(item, controller.text),
            decoration: const InputDecoration(
              hintText: '或直接输入回答…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: busy ? null : () => _submitAnswer(item, controller.text),
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send, size: 18),
          tooltip: '发送',
        ),
      ],
    );
  }
}
