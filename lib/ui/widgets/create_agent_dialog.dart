import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../io/api_service.dart';

/// 创建 Agent 配置对话框
///
/// 让用户填写名称、从模型池中选择具体模型，并可填写系统提示词与团队配置。
/// 确认后通过 [Navigator.pop] 返回创建结果（Map），取消返回 null。
///
/// 返回的 Map 包含：
/// - `name`: Agent 名称
/// - `model_id`: 所选具体模型的 model_id
/// - `model_name`: 所选模型显示名（用于回显）
/// - `system_prompt`: 系统提示词
/// - `team_member_count`: 初始预建成员数（P4 建队，不填按每层上限全量预建）
/// - `max_level`: 团队最大层级深度（顶部 agent 为 Level 0）
/// - `max_members_per_level`: 每层成员上限
///
/// 团队配置创建后不可修改（成员只增不减）。
///
/// 模型选择会记忆到本地（SharedPreferences 键 `last_selected_model_id`），
/// 下次打开对话框默认选中上次使用的模型，不再每次都回退到模型池第一个。
class CreateAgentDialog extends StatefulWidget {
  const CreateAgentDialog({super.key});

  @override
  State<CreateAgentDialog> createState() => _CreateAgentDialogState();
}

class _CreateAgentDialogState extends State<CreateAgentDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _memberCountController = TextEditingController();
  final TextEditingController _maxLevelController = TextEditingController();
  final TextEditingController _maxMembersController = TextEditingController();

  /// 团队配置默认值（与后端 config/team.py 的代码默认值一致）
  static const int _defaultMaxLevel = 3;
  static const int _defaultMaxMembers = 7;

  /// 模型池（从后端加载）
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];

  /// 是否正在加载模型池
  bool _loading = true;

  /// 加载失败信息（为空表示无错误）
  String? _loadError;

  /// 当前选中的模型 id（默认第一个）
  String? _selectedModelId;

  /// 本地记忆的上次选择模型 id（加载模型池后用于恢复选中）
  String? _lastSelectedModelId;

  /// SharedPreferences 记忆键
  static const String _lastModelKey = 'last_selected_model_id';

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    _memberCountController.dispose();
    _maxLevelController.dispose();
    _maxMembersController.dispose();
    super.dispose();
  }

  /// 从后端加载模型池，并尝试恢复上次选择的模型
  Future<void> _loadModels() async {
    try {
      // 先读本地记忆（不阻塞模型池加载）
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        _lastSelectedModelId = prefs.getString(_lastModelKey);
      } catch (_) {
        _lastSelectedModelId = null;
      }
      final List<Map<String, dynamic>> models = await ApiService.getModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
        // 恢复上次选择：记忆模型仍在池中则选中它，否则回退第一个
        final bool remembered = _lastSelectedModelId != null &&
            models.any((m) =>
                (m['model_id'] as String? ?? '') == _lastSelectedModelId);
        _selectedModelId = remembered
            ? _lastSelectedModelId
            : (models.isNotEmpty ? models.first['model_id'] as String : null);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  /// 记忆本次选择的模型（下次打开对话框默认选中）
  Future<void> _rememberModel(String modelId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastModelKey, modelId);
    } catch (_) {
      // 记忆失败不影响创建流程
    }
  }

  /// 校验并提交创建
  void _submit() {
    final String name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写 Agent 名称')),
      );
      return;
    }
    if (_selectedModelId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择模型')),
      );
      return;
    }

    // 解析团队配置（空/非法回退默认值；越界提示）
    int? teamMemberCount;
    final String countText = _memberCountController.text.trim();
    if (countText.isNotEmpty) {
      final int? v = int.tryParse(countText);
      if (v == null || v < 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('初始成员数需为 ≥1 的整数')),
        );
        return;
      }
      teamMemberCount = v;
    }
    int maxLevel = _defaultMaxLevel;
    final String levelText = _maxLevelController.text.trim();
    if (levelText.isNotEmpty) {
      final int? v = int.tryParse(levelText);
      if (v == null || v < 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('团队层级需为 ≥1 的整数')),
        );
        return;
      }
      maxLevel = v;
    }
    int maxMembers = _defaultMaxMembers;
    final String membersText = _maxMembersController.text.trim();
    if (membersText.isNotEmpty) {
      final int? v = int.tryParse(membersText);
      if (v == null || v < 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('每层成员上限需为 ≥1 的整数')),
        );
        return;
      }
      maxMembers = v;
    }
    if (teamMemberCount != null && teamMemberCount > maxMembers) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('初始成员数不能超过每层成员上限')),
      );
      return;
    }

    String modelName = _selectedModelId!;
    for (final m in _models) {
      if (m['model_id'] == _selectedModelId && m['name'] is String) {
        modelName = m['name'] as String;
        break;
      }
    }
    // 记忆本次选择，下次打开默认选中
    _rememberModel(_selectedModelId!);
    Navigator.of(context).pop({
      'name': name,
      'model_id': _selectedModelId,
      'model_name': modelName,
      'system_prompt': _promptController.text.trim(),
      'team_member_count': teamMemberCount,
      'max_level': maxLevel,
      'max_members_per_level': maxMembers,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建 Agent'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 名称
              const Text('名称', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  hintText: '例如：樾深',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              // 模型（从模型池选择具体模型）
              const Text('模型', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _buildModelField(),
              const SizedBox(height: 16),
              // 系统提示词（可选）
              const Text('系统提示词（可选）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _promptController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '描述该 Agent 的角色与职责',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              // 团队配置（创建后不可修改）
              const Text('团队配置（创建后不可修改）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text(
                '创建后自动预建团队成员（P4 建队）；之后成员只增不减，'
                '由 Agent 经 team create_member 创建',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _maxMembersController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '每层成员上限',
                        hintText: '$_defaultMaxMembers',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _maxLevelController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '团队最大层级',
                        hintText: '$_defaultMaxLevel',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _memberCountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '初始成员数（留空按每层上限预建）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading || _selectedModelId == null ? null : _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }

  /// 模型选择控件：加载中 / 出错 / 下拉选择
  Widget _buildModelField() {
    if (_loading) {
      return SizedBox(
        height: 40,
        child: Row(
          children: const [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text(
              '正在加载模型池...',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      );
    }
    if (_loadError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '模型池加载失败: $_loadError',
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _loadError = null;
                });
                _loadModels();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }
    if (_models.isEmpty) {
      return const Text(
        '模型池为空，请先在 server/configs/models/ 下添加模型配置',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      );
    }
    return DropdownButtonFormField<String>(
      value: _selectedModelId,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: _models.map((m) {
        final String modelId = m['model_id'] as String;
        return DropdownMenuItem<String>(
          value: modelId,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
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
}
