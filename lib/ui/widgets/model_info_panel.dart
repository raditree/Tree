import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// 模型信息面板（右栏「模型信息」Tab）
///
/// 展示当前 agent 的模型配置：
/// - 模型下拉：从可用模型池中选择（复用创建 Agent 对话框的交互风格）
/// - 系统提示词编辑：保存时提交 `PATCH /api/agents/{id}`
/// - 当前模型 info 卡片：max_seqlen / thinking / if_vision / base_url（脱敏）
///
/// 数据源：`GET /api/agents/{id}/models-info`、`PATCH /api/agents/{id}`。
class ModelInfoPanel extends StatefulWidget {
  /// 所属顶层 agent ID
  final String agentId;

  /// 初始系统提示词（来自 Agent 对象，models-info 返回后优先用其覆盖）
  final String? initialSystemPrompt;

  const ModelInfoPanel({
    super.key,
    required this.agentId,
    this.initialSystemPrompt,
  });

  @override
  State<ModelInfoPanel> createState() => _ModelInfoPanelState();
}

class _ModelInfoPanelState extends State<ModelInfoPanel> {
  /// 可用模型池
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];

  /// 当前模型信息（含 system_prompt 等）
  Map<String, dynamic>? _current;

  /// 当前选中的模型 id
  String? _selectedModelId;

  /// 是否正在加载
  bool _loading = true;

  /// 加载失败信息
  String? _loadError;

  /// 是否正在保存
  bool _saving = false;

  /// 系统提示词控制器
  final TextEditingController _promptController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _promptController.text = widget.initialSystemPrompt ?? '';
    _load();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  /// 加载模型池与当前模型信息
  Future<void> _load() async {
    try {
      final Map<String, dynamic> data =
          await ApiService.getAgentModelsInfo(widget.agentId);
      final List<dynamic> rawModels =
          data['models'] as List<dynamic>? ?? <dynamic>[];
      // 后端返回结构为 {"agent": {id, model_id, system_prompt}, "models": [...]}
      // （注意：后端字段名为 agent，前端此前误读 current 导致永远取不到当前模型，
      //  模型下拉始终回退到模型池第一个 —— 已修正为 agent）
      final Map<String, dynamic>? current =
          (data['agent'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _models = rawModels
            .map((dynamic e) =>
                Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
            .toList();
        _current = current;
        // 当前 agent 绑定的模型优先；无则回退模型池第一个
        final String? boundModelId = current?['model_id'] as String?;
        final bool boundInPool = boundModelId != null &&
            _models.any((m) => (m['model_id'] as String? ?? '') == boundModelId);
        _selectedModelId = boundInPool
            ? boundModelId
            : (_models.isNotEmpty
                ? (_models.first['model_id'] as String?)
                : null);
        // models-info 返回的 system_prompt 优先于初始值
        final String? serverPrompt = current?['system_prompt'] as String?;
        if (serverPrompt != null) {
          _promptController.text = serverPrompt;
        }
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  /// 保存模型与系统提示词修改（PATCH）
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
    });
    try {
      await ApiService.updateAgent(
        widget.agentId,
        modelId: _selectedModelId,
        systemPrompt: _promptController.text.trim(),
      );
      if (!mounted) return;
      _showSnackBar('保存成功');
      _load();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('保存失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// base_url 脱敏：去掉协议前缀，便于展示
  String _maskUrl(String url) {
    String s = url;
    if (s.startsWith('https://')) s = s.substring(8);
    if (s.startsWith('http://')) s = s.substring(7);
    return s.isEmpty ? url : s;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _buildHeader(),
        Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// 头部：标题 + 保存按钮
  Widget _buildHeader() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '模型信息',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          if (!_loading && _loadError == null)
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '保存中' : '保存'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
        ],
      ),
    );
  }

  /// 主体：加载中 / 出错 / 内容
  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_loadError != null) {
      return _buildError();
    }
    final cs = Theme.of(context).colorScheme;
    final Map<String, dynamic>? current = _current;
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        // 模型下拉
        const Text('模型', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        _buildModelDropdown(),
        const SizedBox(height: 14),
        // 系统提示词编辑
        const Text('系统提示词',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: _promptController,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: '描述该 Agent 的角色与职责',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        // 当前模型信息卡片
        const Text('模型详情',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        _buildInfoCard(current, cs),
      ],
    );
  }

  /// 模型下拉控件
  Widget _buildModelDropdown() {
    if (_models.isEmpty) {
      return const Text(
        '模型池为空，请先在 server/configs/models/ 下添加模型配置',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return DropdownButtonFormField<String>(
      value: _selectedModelId,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: _models.map((Map<String, dynamic> m) {
        final String modelId = m['model_id'] as String? ?? '';
        return DropdownMenuItem<String>(
          value: modelId,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  m['name'] as String? ?? modelId,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      }).toList(),
      onChanged: (String? value) {
        setState(() {
          _selectedModelId = value;
        });
      },
    );
  }

  /// 当前模型详情卡片
  Widget _buildInfoCard(Map<String, dynamic>? current, ColorScheme cs) {
    if (current == null) {
      return Text(
        '暂无模型信息',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }
    final String modelId = current['model_id'] as String? ?? '';
    final String name = current['name'] as String? ?? modelId;
    final String baseUrl = _maskUrl(current['base_url'] as String? ?? '');
    final int? maxSeqLen = (current['max_seqlen'] as num?)?.toInt();
    final bool thinking = current['thinking'] as bool? ?? false;
    final bool ifVision = current['if_vision'] as bool? ?? false;

    Widget row(String label, String value, {Color? valueColor}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 84,
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  color: valueColor ?? cs.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          row('名称', name),
          row('Model ID', modelId.isEmpty ? '—' : modelId),
          row('最大上下文', maxSeqLen != null ? '$maxSeqLen tokens' : '—'),
          row('思考模型', thinking ? '是' : '否'),
          row('支持视觉', ifVision ? '是' : '否'),
          row('服务地址', baseUrl.isEmpty ? '—' : baseUrl),
        ],
      ),
    );
  }

  /// 加载失败视图（含重试）
  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              '模型信息加载失败',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$_loadError',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _loadError = null;
                });
                _load();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
