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

  /// 模型参数覆盖控制器（留空 = 不覆盖，用模型默认）
  final TextEditingController _maxSeqlenController = TextEditingController();
  final TextEditingController _maxOutputController = TextEditingController();

  /// 思考强度覆盖（'' = 不覆盖）
  String _reasoningEffort = '';

  /// 已保存的思考强度覆盖**不在当前模型可选档位内**（如模型换成了档位更少的
  /// 那个，旧覆盖值 `xhigh` 不再合法）。非空时在控件下给出提示，并在保存时
  /// 不下发该值——否则后端校验会拒绝整个 PATCH。
  String _staleReasoningEffort = '';

  /// 思考强度可选档位兜底值。
  ///
  /// 正常情况下由后端按模型下发 `reasoning_effort_options`（模型 .yaml 声明，
  /// 未声明则回退"有实际区分度"的档位）。这里仅在响应缺该字段时兜底，
  /// **不再列 minimal/medium/xhigh/ultra**：它们与服务端档位一一等价，
  /// 摆进下拉就是选起来无差别的假选项。
  static const List<String> _fallbackReasoningEfforts = <String>[
    'low',
    'high',
    'max',
  ];

  /// 上下文压缩阈值覆盖（null = 不覆盖 = 用模型默认，通常 0.8）
  double? _compressThreshold;

  @override
  void initState() {
    super.initState();
    _promptController.text = widget.initialSystemPrompt ?? '';
    _load();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _maxSeqlenController.dispose();
    _maxOutputController.dispose();
    super.dispose();
  }

  /// 当前选中的模型池条目（详情卡片的数据源）。
  ///
  /// 从 [_models] 中按 [_selectedModelId] 查找：后端 `models-info` 的
  /// `agent` 对象不含模型详情字段，模型详情只在 `models[]` 里。
  Map<String, dynamic>? get _selectedModel {
    final String? id = _selectedModelId;
    if (id == null || id.isEmpty) return null;
    for (final Map<String, dynamic> m in _models) {
      if ((m['model_id'] as String? ?? '') == id) return m;
    }
    return null;
  }

  /// 当前选中模型的可选思考强度档位。
  ///
  /// 数据源是后端 `models-info` 里该模型条目的 `reasoning_effort_options`
  /// （由模型 .yaml 声明，未声明则由后端回退到有实际区分度的档位）。
  /// 后端未下发时回退 [_fallbackReasoningEfforts]，保证下拉永不为空。
  List<String> _reasoningEffortOptions() {
    final List<dynamic>? raw =
        _selectedModel?['reasoning_effort_options'] as List<dynamic>?;
    if (raw == null) return _fallbackReasoningEfforts;
    final List<String> options = raw
        .map((dynamic e) => e.toString().trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    return options.isEmpty ? _fallbackReasoningEfforts : options;
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
        // 回填该 agent 的模型参数覆盖（null / 空 = 未覆盖 → 控件留空）
        final Map<String, dynamic> overrides =
            (data['overrides'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        _reasoningEffort = (overrides['reasoning_effort'] as String?) ?? '';
        // 库里的覆盖值可能已不在当前模型的档位内（模型换过/档位声明改过）。
        // 这里就清掉并提示，而不是把非法值留在下拉里 —— DropdownButtonFormField
        // 的 value 不在 items 中会直接断言失败，且保存时必被后端 400 拒绝。
        _staleReasoningEffort = '';
        if (_reasoningEffort.isNotEmpty &&
            !_reasoningEffortOptions().contains(_reasoningEffort)) {
          _staleReasoningEffort = _reasoningEffort;
          _reasoningEffort = '';
        }
        final int? ovSeq = (overrides['max_seqlen'] as num?)?.toInt();
        _maxSeqlenController.text = ovSeq != null ? '$ovSeq' : '';
        final int? ovOut = (overrides['max_output_tokens'] as num?)?.toInt();
        _maxOutputController.text = ovOut != null ? '$ovOut' : '';
        final num? ovThreshold = overrides['compress_threshold'] as num?;
        _compressThreshold = ovThreshold?.toDouble();
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

  /// 保存模型、系统提示词与模型参数覆盖修改（PATCH）
  ///
  /// 覆盖语义：控件留空 = 不修改该项（后端 `null` = 保留原值）。需要把某项
  /// 恢复为模型默认时，用「清除自定义参数」按钮整体重置（[clearOverrides]）。
  Future<void> _save({bool clearOverrides = false}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
    });
    try {
      await ApiService.updateAgent(
        widget.agentId,
        modelId: _selectedModelId,
        systemPrompt: _promptController.text.trim(),
        reasoningEffort: _reasoningEffort.isEmpty ? null : _reasoningEffort,
        maxSeqlen:
            clearOverrides ? null : int.tryParse(_maxSeqlenController.text.trim()),
        maxOutputTokens:
            clearOverrides ? null : int.tryParse(_maxOutputController.text.trim()),
        compressThreshold: clearOverrides ? null : _compressThreshold,
        clearOverrides: clearOverrides,
      );
      if (!mounted) return;
      _showSnackBar(clearOverrides ? '已恢复模型默认参数' : '保存成功');
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
        // 模型参数覆盖（思考强度 / 输入长度 / 输出长度 / 压缩阈值）
        Row(
          children: <Widget>[
            const Expanded(
              child: Text('模型参数（本 Agent）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: _saving ? null : () => _save(clearOverrides: true),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('恢复默认', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _buildOverridesSection(cs),
        const SizedBox(height: 14),
        // 当前模型信息卡片
        const Text('模型详情',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        _buildInfoCard(cs),
      ],
    );
  }

  /// 模型参数覆盖控件组
  ///
  /// 留空 = 不覆盖（用模型默认值）。压缩阈值只在**主动设置过**时提交
  /// （[_compressThreshold] 非 null），留空不会覆盖模型默认。
  Widget _buildOverridesSection(ColorScheme cs) {
    // 取非空引用：Dart 在 `mod == null || ...` 之类判断后会把 `mod?` 之后的
    // 访问判定为非空，继续用 `?.` 反而触发 invalid_null_aware_operator
    final Map<String, dynamic> mod =
        _selectedModel ?? const <String, dynamic>{};
    final num? rawSeq = mod['max_seqlen'] as num?;
    final String defaultSeq = rawSeq == null ? '—' : '${rawSeq.toInt()}';
    final num? rawOut = mod['max_output_tokens'] as num?;
    final String defaultOut =
        rawOut == null ? '未设置' : '${rawOut.toInt()}';
    final num? defaultThreshold = mod['compress_threshold'] as num?;
    final String defaultThresholdText = defaultThreshold != null
        ? '${(defaultThreshold * 100).toStringAsFixed(0)}%'
        : '80%';
    final String defaultEffort =
        ((mod['reasoning_effort'] as String?) ?? '').trim().isEmpty
            ? '不设置'
            : (mod['reasoning_effort'] as String).trim();
    // 思考强度可选档位（由当前模型声明；切模型后随之变化）
    final List<String> effortOptions = _reasoningEffortOptions();

    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 思考强度：档位由当前模型声明（后端 reasoning_effort_options），
        // 不硬编码 —— 硬编码会在模型只支持少数档位时给出选起来无差别的假选项，
        // 也会让"模型换档位后旧覆盖值非法"无法被发现。
        DropdownButtonFormField<String>(
          initialValue: _reasoningEffort.isEmpty ? '' : _reasoningEffort,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '思考强度（模型默认：$defaultEffort）',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<String>>[
            const DropdownMenuItem<String>(value: '', child: Text('不覆盖')),
            ...effortOptions.map(
              (String e) => DropdownMenuItem<String>(
                value: e,
                child: Text(e),
              ),
            ),
          ],
          onChanged: (String? value) {
            setState(() {
              _reasoningEffort = value ?? '';
            });
          },
        ),
        if (_staleReasoningEffort.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '原覆盖档位 "$_staleReasoningEffort" 不在当前模型的可选档位内，'
              '已重置为「不覆盖」；点保存即生效',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          ),
        const SizedBox(height: 10),
        // 最大输入（上下文预算）
        TextField(
          controller: _maxSeqlenController,
          keyboardType: TextInputType.number,
          decoration: deco('最大输入 tokens（模型默认 $defaultSeq）'),
        ),
        const SizedBox(height: 10),
        // 最大输出
        TextField(
          controller: _maxOutputController,
          keyboardType: TextInputType.number,
          decoration: deco('最大输出 tokens（模型默认 $defaultOut）'),
        ),
        const SizedBox(height: 10),
        // 上下文压缩阈值
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '上下文压缩阈值',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            Text(
              _compressThreshold == null
                  ? '不覆盖（默认 $defaultThresholdText）'
                  : '${(_compressThreshold! * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        Slider(
          value: _compressThreshold ?? 0.8,
          min: 0.1,
          max: 0.95,
          divisions: 17,
          label: '${((_compressThreshold ?? 0.8) * 100).toStringAsFixed(0)}%',
          onChanged: (double value) {
            setState(() {
              _compressThreshold = value;
            });
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _compressThreshold == null
                ? null
                : () {
                    setState(() {
                      _compressThreshold = null;
                    });
                  },
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('设为不覆盖', style: TextStyle(fontSize: 12)),
          ),
        ),
        Text(
          '留空表示不覆盖（用模型默认值）；「恢复默认」清除本 Agent 的全部覆盖。'
          '压缩阈值越小越早压缩上下文。',
          style: TextStyle(fontSize: 11, color: cs.outline),
        ),
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
      initialValue: _selectedModelId,
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
          // 切模型后可选档位随模型声明变化：旧选择可能已非法，
          // 清掉并提示（否则保存时被后端 400 拒绝整个 PATCH）
          if (_reasoningEffort.isNotEmpty &&
              !_reasoningEffortOptions().contains(_reasoningEffort)) {
            _staleReasoningEffort = _reasoningEffort;
            _reasoningEffort = '';
          } else {
            _staleReasoningEffort = '';
          }
        });
      },
    );
  }

  /// 当前模型详情卡片
  ///
  /// 数据源必须是 **模型池条目**（`data['models'][i]`，含 name/base_url/
  /// max_seqlen/thinking/if_vision），而不是 `data['agent']`（该对象只有
  /// id/model_id/system_prompt）。此前误传 `_current`（agent 记录）导致
  /// 「最大上下文」恒「—」、「思考模型」「支持视觉」恒「否」、「服务地址」
  /// 恒「—」。
  Widget _buildInfoCard(ColorScheme cs) {
    final Map<String, dynamic>? model = _selectedModel;
    if (model == null) {
      return Text(
        '暂无模型信息',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }
    final String modelId = model['model_id'] as String? ?? '';
    final String name = model['name'] as String? ?? modelId;
    final String baseUrl = _maskUrl(model['base_url'] as String? ?? '');
    final int? maxSeqLen = (model['max_seqlen'] as num?)?.toInt();
    final bool thinking = model['thinking'] as bool? ?? false;
    final bool ifVision = model['if_vision'] as bool? ?? false;
    final String reasoningEffort =
        model['reasoning_effort'] as String? ?? '';
    final int? maxOutputTokens = (model['max_output_tokens'] as num?)?.toInt();
    final num? compressThreshold = model['compress_threshold'] as num?;

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
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
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
          row('思考强度', reasoningEffort.isEmpty ? '默认' : reasoningEffort),
          row(
            '最大输出',
            maxOutputTokens != null ? '$maxOutputTokens tokens' : '默认',
          ),
          row(
            '压缩阈值',
            compressThreshold != null
                ? '${(compressThreshold * 100).toStringAsFixed(0)}%'
                : '默认 80%',
          ),
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
