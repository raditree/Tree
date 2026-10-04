import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/question_update_service.dart';
import '../models/agent.dart';
import '../models/message.dart';

/// 单条提问记录（右侧「问题回复」页数据模型）
///
/// **多问题**：一条记录 = 一次提问（一个 qid），里面有 N 道题
/// （[questions] ≥ 1，单问是退化形态）；[answers] 是逐题答案。
class _QuestionItem {
  final String qid;
  final String agentId;
  final String teamId;
  final String sessionId;
  final bool isMember;
  final String question;
  final List<String> options;
  final List<AskQuestionItem> questions;
  final List<String> answers;
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
    required this.questions,
    required this.answers,
    required this.answer,
    required this.status,
    required this.createdAt,
  });

  bool get isPending => status == 'pending';

  /// 是否一次问了多道题（界面据此决定"点选项即作答"还是"逐题作答后提交"）。
  bool get isMulti => questions.length > 1;

  static List<AskQuestionItem> _questionsFromJson(
    Map<String, dynamic> json,
    String question,
    List<String> options,
  ) {
    final List<AskQuestionItem> parsed =
        (json['questions'] as List<dynamic>?)
            ?.whereType<Map<dynamic, dynamic>>()
            .map(
              (Map<dynamic, dynamic> item) => AskQuestionItem.fromJson(
                item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              ),
            )
            .toList() ??
        const <AskQuestionItem>[];
    // 老核心只有第一问：按 question / options 合成一项（与前端 ChatMessage 同口径）
    if (parsed.isNotEmpty) return parsed;
    return <AskQuestionItem>[AskQuestionItem(question: question, options: options)];
  }

  factory _QuestionItem.fromJson(Map<String, dynamic> json) {
    final String question = (json['question'] ?? '').toString();
    final List<String> options =
        (json['options'] as List<dynamic>? ?? const <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList();
    return _QuestionItem(
      qid: (json['qid'] ?? '').toString(),
      agentId: (json['agent_id'] ?? '').toString(),
      teamId: (json['team_id'] ?? '').toString(),
      sessionId: (json['session_id'] ?? '').toString(),
      isMember: json['is_member'] == true,
      question: question,
      options: options,
      questions: _questionsFromJson(json, question, options),
      answers:
          (json['answers'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[],
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

  /// 每张待答卡片**每题**的输入框控制器（键 = `qid#题号`，题号从 0 起）
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  /// 每题点选的选项（键 = `qid#题号`；自由输入**优先于**点选）
  final Map<String, String> _picked = <String, String>{};

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
        // 清理已不再展示待答输入框的控制器（键是 `qid#题号`）
        final Set<String> pendingIds =
            items.where((i) => i.isPending).map((i) => i.qid).toSet();
        bool belongsToPending(String key) {
          final int sep = key.indexOf('#');
          return pendingIds.contains(sep < 0 ? key : key.substring(0, sep));
        }
        _controllers.removeWhere((String key, TextEditingController c) {
          if (belongsToPending(key)) return false;
          c.dispose();
          return true;
        });
        _picked.removeWhere(
          (String key, String _) => !belongsToPending(key),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取提问失败：$e';
      });
    }
  }

  /// 提交回答：调 REST 接口（**逐题答案**），成功后本地置 answered 并通知全局刷新。
  ///
  /// 多问题：一次交齐（未作答的题传空串 ⇒ 核心记为「未作答」）。
  Future<void> _submitAnswer(_QuestionItem item, List<String> answers) async {
    if (_submitting.contains(item.qid)) return;
    final List<String> normalized = <String>[
      for (int i = 0; i < item.questions.length; i++)
        i < answers.length ? answers[i].trim() : '',
    ];
    setState(() {
      _submitting.add(item.qid);
    });
    try {
      await ApiService.answerQuestion(item.qid, normalized);
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
            questions: item.questions,
            answers: normalized,
            answer: _answersSummary(item, normalized),
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

  /// 本地展示用的答案摘要（核心也会算一份同口径的 `answer`；这里是为了提交后
  /// **立刻**更新界面，不用等下一次列表刷新）。
  String _answersSummary(_QuestionItem item, List<String> answers) {
    if (!item.isMulti) return answers.isEmpty ? '' : answers.first;
    return <String>[
      for (int i = 0; i < item.questions.length; i++)
        '第${i + 1}题：'
            '${i < answers.length && answers[i].isNotEmpty ? answers[i] : '（未作答）'}',
    ].join('\n');
  }

  /// 某题某个选项是否处于"选中/命中"（多问看点选，单问看已作答的答案）。
  bool _isPicked(_QuestionItem item, int index, String option) {
    if (!item.isMulti) {
      return !item.isPending &&
          index < item.answers.length &&
          item.answers[index] == option;
    }
    return _picked['${item.qid}#$index'] == option;
  }

  /// 逐题收集答案（自由输入优先，其次点选的选项；都没有 = 空串）。
  List<String> _collectAnswers(_QuestionItem item) {
    final List<String> answers = <String>[];
    for (int i = 0; i < item.questions.length; i++) {
      final String typed = _controllerAt(item.qid, i).text.trim();
      answers.add(
        typed.isNotEmpty ? typed : (_picked['${item.qid}#$i'] ?? ''),
      );
    }
    return answers;
  }

  TextEditingController _controllerAt(String qid, int index) =>
      _controllers.putIfAbsent('$qid#$index', TextEditingController.new);

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
            for (int i = 0; i < item.questions.length; i++)
              _buildQuestionBlock(context, item, i),
            if (item.isPending && item.isMulti) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  FilledButton(
                    onPressed: _submitting.contains(item.qid)
                        ? null
                        : () => _submitAnswer(item, _collectAnswers(item)),
                    child: const Text('提交全部回答'),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _unansweredCount(item) == 0
                        ? '已全部作答'
                        : '还有 ${_unansweredCount(item)} 题未作答',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
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

  /// 一道题：题面 + 选项 + 自由输入。
  ///
  /// 单问：点选项立刻作答（老行为）；多问：点选项为"选中"，逐题作答后由卡片
  /// 底部的「提交全部回答」统一提交。
  Widget _buildQuestionBlock(
    BuildContext context,
    _QuestionItem item,
    int index,
  ) {
    final cs = Theme.of(context).colorScheme;
    final AskQuestionItem question = item.questions[index];
    final bool busy = _submitting.contains(item.qid);
    final bool enabled = item.isPending && !busy;
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            item.isMulti
                ? '${index + 1}. ${question.question}'
                : (question.question.isEmpty ? '提问' : question.question),
            style: TextStyle(fontSize: 13, color: cs.onSurface, height: 1.4),
          ),
          if (item.isPending && question.options.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            for (final String option in question.options)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: enabled
                        ? () {
                            if (!item.isMulti) {
                              // 单问：点选项立刻作答（老行为）
                              _submitAnswer(item, <String>[option]);
                              return;
                            }
                            setState(() {
                              final String key = '${item.qid}#$index';
                              if (_picked[key] == option) {
                                _picked.remove(key);
                              } else {
                                _picked[key] = option;
                              }
                            });
                          }
                        : null,
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _isPicked(item, index, option)
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                          size: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            option,
                            style: TextStyle(fontSize: 12, color: cs.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          if (item.isPending) ...<Widget>[
            const SizedBox(height: 6),
            _buildAnswerInput(item, index),
          ],
        ],
      ),
    );
  }

  /// 某题的输入框（单问带发送键；多问由卡片底部的「提交全部回答」统一提交）。
  Widget _buildAnswerInput(_QuestionItem item, int index) {
    final TextEditingController controller = _controllerAt(item.qid, index);
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
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => item.isMulti
                ? _submitAnswer(item, _collectAnswers(item))
                : _submitSingle(item, index),
            decoration: InputDecoration(
              hintText: item.isMulti
                  ? '或直接输入第 ${index + 1} 题的答案…'
                  : '或直接输入回答…',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (!item.isMulti) ...<Widget>[
          const SizedBox(width: 6),
          IconButton(
            onPressed: busy ? null : () => _submitSingle(item, index),
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
      ],
    );
  }

  /// 单问：把某题输入框里的内容作为答案提交（空输入不提交）。
  void _submitSingle(_QuestionItem item, int index) {
    final String text = _controllerAt(item.qid, index).text.trim();
    if (text.isEmpty) return;
    _submitAnswer(item, <String>[text]);
  }

  /// 多问还有几题没答（底部提交按钮旁的提示）。
  int _unansweredCount(_QuestionItem item) =>
      _collectAnswers(item).where((String a) => a.isEmpty).length;
}
