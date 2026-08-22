import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../../io/api_service.dart';

/// 任务规范（Spec）面板（P4 前端）
///
/// 展示某 agent 可用的 Spec 索引（内置 3 置顶 + 自定义），支持：
/// - 查看 Spec 元数据（task_type / when / tags / description）
/// - 展开查看 Spec 全文
/// - 为当前会话多选 Spec（挂 hook，重构 context 时注入全文）
///
/// 数据来源：``GET /api/agents/{id}/specs?session_id=...``、
/// ``GET /api/agents/{id}/specs/{specId}``；选择经
/// ``POST /api/agents/{id}/sessions/{sessionId}/specs`` 持久化。
class SpecPanel extends StatefulWidget {
  const SpecPanel({
    super.key,
    required this.agent,
    required this.sessionId,
  });

  /// 当前选中的 Agent
  final Agent agent;

  /// 当前会话 ID
  final String sessionId;

  @override
  State<SpecPanel> createState() => _SpecPanelState();
}

class _SpecPanelState extends State<SpecPanel> {
  bool _loading = true;
  String? _error;
  // spec 元数据列表
  List<Map<String, dynamic>> _specs = [];
  // 当前会话已选中的 spec id
  Set<String> _selected = <String>{};
  // 已展开查看全文的 spec id -> 全文
  final Map<String, String> _detailCache = <String, String>{};
  final Map<String, bool> _expanded = <String, bool>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> data = await ApiService.listAgentSpecs(
        widget.agent.id,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      final List<dynamic> raw = data['specs'] as List<dynamic>? ?? [];
      final List<dynamic> sel = data['selected_spec_ids'] as List<dynamic>? ?? [];
      setState(() {
        _specs = raw
            .map((dynamic e) => (e as Map<String, dynamic>).cast<String, dynamic>())
            .toList();
        _selected = sel.map((dynamic e) => e.toString()).toSet();
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

  /// 切换某 Spec 的选中状态（多选挂 hook）
  Future<void> _toggleSelect(String specId) async {
    final Set<String> next = Set<String>.from(_selected);
    if (next.contains(specId)) {
      next.remove(specId);
    } else {
      next.add(specId);
    }
    setState(() {
      _selected = next;
      _saving = true;
    });
    try {
      final List<String> saved = await ApiService.setSessionSpecs(
        widget.agent.id,
        widget.sessionId,
        next.toList(),
      );
      if (!mounted) return;
      setState(() {
        _selected = saved.toSet();
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存 Spec 选择失败: $e')));
    }
  }

  /// 展开/折叠查看全文（懒加载）
  Future<void> _toggleDetail(String specId) async {
    final bool willExpand = _expanded[specId] != true;
    setState(() => _expanded[specId] = willExpand);
    if (willExpand && !_detailCache.containsKey(specId)) {
      try {
        final Map<String, dynamic> data =
            await ApiService.getSpecDetail(widget.agent.id, specId);
        if (!mounted) return;
        setState(() {
          _detailCache[specId] =
              (data['content'] as String?) ?? '(无正文内容)';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _detailCache[specId] = '（加载失败: $e）';
        });
      }
    }
  }

  ColorScheme get _cs => Theme.of(context).colorScheme;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cs.surface,
      appBar: AppBar(
        title: const Text('任务规范（Spec）'),
        actions: <Widget>[
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              ),
            ),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 40, color: _cs.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_specs.isEmpty) {
      return const Center(child: Text('暂无可用 Spec'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _specs.length,
      itemBuilder: (BuildContext context, int index) {
        return _buildSpecCard(_specs[index]);
      },
    );
  }

  Widget _buildSpecCard(Map<String, dynamic> spec) {
    final String specId = (spec['id'] as String?) ?? '';
    final String title = (spec['title'] as String?) ?? specId;
    final String taskType = (spec['task_type'] as String?) ?? '';
    final bool builtin = (spec['builtin'] as bool?) ?? false;
    final bool pinned = (spec['pinned'] as bool?) ?? false;
    final bool selected = _selected.contains(specId);
    final bool expanded = _expanded[specId] == true;
    final List<dynamic> when = spec['when'] as List<dynamic>? ?? [];
    final List<dynamic> tags = spec['tags'] as List<dynamic>? ?? [];

    return Card(
      elevation: 0,
      color: _cs.surfaceVariant.withOpacity(0.35),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                // 选择勾选框（挂 hook）
                Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleSelect(specId),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          if (builtin || pinned)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: _cs.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                builtin ? '内置' : '置顶',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: _cs.onPrimaryContainer,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (taskType.isNotEmpty)
                            Text(
                              taskType,
                              style: TextStyle(
                                fontSize: 11,
                                color: _cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (when.isNotEmpty)
                        Text(
                          '适用: ${when.join('；')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: _cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: expanded ? '折叠正文' : '查看正文',
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  onPressed: () => _toggleDetail(specId),
                ),
              ],
            ),
            if (tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Wrap(
                  spacing: 4,
                  children: tags
                      .take(5)
                      .map<Widget>(
                        (dynamic t) => Chip(
                          label: Text('$t', style: const TextStyle(fontSize: 10)),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 0,
                          ),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      )
                      .toList(),
                ),
              ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, top: 4),
                child: _ExpandedMarkdown(
                  content: _detailCache[specId] ?? '加载中…',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 简洁的 Markdown 渲染容器（Spec 正文多为标题/列表/代码块）
///
/// 内置包不含完整 markdown 渲染器，这里对标题、代码行做轻量着色，
/// 通用文本原样展示。
class _ExpandedMarkdown extends StatelessWidget {
  const _ExpandedMarkdown({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Text(
        content,
        style: const TextStyle(fontSize: 12, height: 1.5),
      ),
    );
  }
}