import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../io/api_service.dart';
import '../theme_service.dart';

/// 设置页面（desktop 分支：账号/等级/密码/后端地址/注销 五组设置已删除）
///
/// 保留的设置项：
/// - 数据收集：仅保留开关以兼容历史配置（桌面单用户形态没有收集方，M7 移除）
/// - 主动延迟 / 流式帧率 / 消息切入模式：agent 运行节奏控制
/// - 自定义模型：模型池 CRUD（M2 起落 `~/.tree/config/models/*.yaml`）
/// - 主题管理：浅色 / 深色 / 跟随系统三种模式
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // --- 数据收集 ---
  bool _dataCollectionEnabled = false;

  // --- 主动延迟（限制单个 agent 的 API 调用频率，平均 6 次/分钟） ---
  bool _rateLimitEnabled = false;

  // --- 消息切入模式（false=串行排队，true=直接切入） ---
  bool _directCutin = false;

  // --- 流式帧率（主动延迟开启时叠加的生成器帧率，帧/秒，20~1000） ---
  int _frameRate = 20;
  int _frameRateMin = 20;
  int _frameRateMax = 1000;

  /// 帧率输入框（允许用户直接键入，提交时按范围夹取）
  final TextEditingController _frameRateController = TextEditingController();

  // --- 自定义模型（设置页 CRUD） ---
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  bool _modelsLoading = false;
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    _loadDataCollectionSetting();
    _loadRateLimitSetting();
    _loadMessageCutinSetting();
    _loadFrameRateSetting();
    _loadModelList();
  }

  @override
  void dispose() {
    _frameRateController.dispose();
    super.dispose();
  }

  /// 加载数据收集设置
  Future<void> _loadDataCollectionSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('data_collection_enabled') ?? false;
    if (mounted) {
      setState(() => _dataCollectionEnabled = enabled);
    }
  }

  /// 加载主动延迟设置
  Future<void> _loadRateLimitSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getBool('rate_limit_enabled') ?? false;
    if (mounted) {
      setState(() => _rateLimitEnabled = local);
    }
    // 尝试从后端拉取权威状态（后端未启动/未登录时忽略，保留本地值）
    try {
      final bool remote = await ApiService.getRateLimit();
      if (mounted) setState(() => _rateLimitEnabled = remote);
    } catch (_) {
      // 后端不可达时保留本地持久化值
    }
  }

  /// 切换主动延迟开关
  Future<void> _toggleRateLimit(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rate_limit_enabled', value);
    try {
      await ApiService.setRateLimit(value);
    } catch (_) {
      // 后端设置失败不阻塞本地持久化
    }
    if (mounted) {
      setState(() => _rateLimitEnabled = value);
    }
  }

  /// 加载消息切入模式设置
  Future<void> _loadMessageCutinSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getBool('message_cutin_direct') ?? false;
    if (mounted) {
      setState(() => _directCutin = local);
    }
    // 尝试从后端拉取权威状态（后端未启动/未登录时忽略，保留本地值）
    try {
      final bool remote = await ApiService.getMessageCutinDirect();
      if (mounted) setState(() => _directCutin = remote);
    } catch (_) {
      // 后端不可达时保留本地持久化值
    }
  }

  /// 切换消息切入模式（false=串行排队，true=直接切入）
  Future<void> _toggleMessageCutin(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('message_cutin_direct', value);
    try {
      await ApiService.setMessageCutinDirect(value);
    } catch (_) {
      // 后端设置失败不阻塞本地持久化
    }
    if (mounted) {
      setState(() => _directCutin = value);
    }
  }

  /// 加载流式帧率设置（权威值来自后端；后端不可达时用默认 20）
  Future<void> _loadFrameRateSetting() async {
    try {
      final Map<String, dynamic> data = await ApiService.getFrameRate();
      if (!mounted) return;
      final int rate = (data['frame_rate'] as num?)?.toInt() ?? _frameRate;
      final int min = (data['min'] as num?)?.toInt() ?? _frameRateMin;
      final int max = (data['max'] as num?)?.toInt() ?? _frameRateMax;
      setState(() {
        _frameRate = rate;
        _frameRateMin = min;
        _frameRateMax = max;
        _frameRateController.text = '$rate';
      });
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端会夹取范围）
      if (mounted) {
        setState(() => _frameRateController.text = '$_frameRate');
      }
    }
  }

  /// 提交流式帧率（按后端声明的范围夹取，以后端返回的生效值为准）
  Future<void> _applyFrameRate(int value) async {
    final int clamped = value < _frameRateMin
        ? _frameRateMin
        : (value > _frameRateMax ? _frameRateMax : value);
    try {
      final int effective = await ApiService.setFrameRate(clamped);
      if (!mounted) return;
      setState(() {
        _frameRate = effective;
        _frameRateController.text = '$effective';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _frameRateController.text = '$_frameRate');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('帧率设置失败：$e'), duration: const Duration(seconds: 2)),
      );
    }
  }

  /// 加载自定义模型列表
  Future<void> _loadModelList() async {
    if (mounted) {
      setState(() {
        _modelsLoading = true;
        _modelsError = null;
      });
    }
    try {
      final List<Map<String, dynamic>> models = await ApiService.getModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _modelsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsLoading = false;
        _modelsError = '$e';
      });
    }
  }

  /// 切换数据收集开关
  Future<void> _toggleDataCollection(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('data_collection_enabled', value);
    try {
      await ApiService.setDataCollection(value);
    } catch (_) {
      // 后端设置失败不阻塞本地持久化
    }
    if (mounted) {
      setState(() => _dataCollectionEnabled = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionTitle('数据收集'),
          const SizedBox(height: 8),
          _buildDataCollectionCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('主动延迟'),
          const SizedBox(height: 8),
          _buildRateLimitCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('流式帧率'),
          const SizedBox(height: 8),
          _buildFrameRateCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('自定义模型'),
          const SizedBox(height: 8),
          _buildCustomModelCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('消息切入模式'),
          const SizedBox(height: 8),
          _buildMessageCutinCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('主题管理'),
          const SizedBox(height: 8),
          _buildThemeCard(),
        ],
      ),
    );
  }

  /// 数据收集卡片
  Widget _buildDataCollectionCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '允许收集使用数据',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _dataCollectionEnabled
                            ? '已开启，仅保存开启期间的使用数据快照'
                            : '关闭状态，不会收集任何使用数据',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _dataCollectionEnabled,
                  onChanged: _toggleDataCollection,
                  activeThumbColor: cs.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 主动延迟卡片
  ///
  /// 开启后限制单个 agent 的 API 调用频率（平均 6 次/分钟），
  /// 适合交互式开发——放慢 agent 节奏，让用户跟得上每个步骤。
  Widget _buildRateLimitCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '主动延迟（API 限速）',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _rateLimitEnabled
                        ? '已开启：限制单个 agent 的 API 调用频率（平均 6 次/分钟），适合交互式开发'
                        : '关闭：API 调用不限速',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
            Switch(
              value: _rateLimitEnabled,
              onChanged: _toggleRateLimit,
              activeThumbColor: cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 流式帧率卡片
  ///
  /// 两把旋钮互不干扰：上面的「主动延迟」管 **API 调用频率**（等级决定上限），
  /// 这里的帧率管 **生成器帧率**——把同一轮回复内的流式 token 按该帧率合并
  /// 投递，避免以 token 速度刷屏。仅在主动延迟开启时生效。
  ///
  /// 范围 20~1000 帧/秒：20 是"跟得上的慢放"，1000 近似不限速。可直接键入，
  /// 提交时按后端声明的范围夹取。
  Widget _buildFrameRateCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '流式输出帧率（帧/秒）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              _rateLimitEnabled
                  ? '已开启主动延迟：本轮回复的流式输出按该帧率合并投递'
                  : '主动延迟未开启，帧率暂不生效（开启后立即生效）',
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _frameRateController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '帧率',
                      helperText: '$_frameRateMin~$_frameRateMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) _applyFrameRate(parsed);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '减少 20',
                  onPressed: _frameRate <= _frameRateMin
                      ? null
                      : () => _applyFrameRate(_frameRate - 20),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  tooltip: '增加 20',
                  onPressed: _frameRate >= _frameRateMax
                      ? null
                      : () => _applyFrameRate(_frameRate + 20),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    final int? parsed =
                        int.tryParse(_frameRateController.text.trim());
                    if (parsed != null) _applyFrameRate(parsed);
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Slider(
              value: _frameRate.toDouble().clamp(
                    _frameRateMin.toDouble(),
                    _frameRateMax.toDouble(),
                  ),
              min: _frameRateMin.toDouble(),
              max: _frameRateMax.toDouble(),
              divisions: 49,
              label: '$_frameRate fps',
              onChanged: (double value) {
                setState(() => _frameRate = value.round());
              },
              onChangeEnd: (double value) => _applyFrameRate(value.round()),
            ),
          ],
        ),
      ),
    );
  }

  /// 自定义模型卡片（列出模型池 + 新增/编辑/删除入口）
  Widget _buildCustomModelCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '模型池',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _modelsLoading ? null : _loadModelList,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                FilledButton.icon(
                  onPressed: () => _openModelEditor(null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新增'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '写入 ~/.tree/config/models/<model_id>.yaml，保存后立即对全部 Agent 生效。'
              'API Key 以明文保存在该文件（已在 .gitignore 中忽略）。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 8),
            if (_modelsLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_modelsError != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '模型列表加载失败：$_modelsError',
                      style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                    ),
                  ),
                  TextButton(onPressed: _loadModelList, child: const Text('重试')),
                ],
              )
            else if (_models.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '模型池为空，请新增一个模型配置',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
              )
            else
              ..._models.map((Map<String, dynamic> m) => _buildModelRow(m, cs)),
          ],
        ),
      ),
    );
  }

  /// 单个模型条目行
  Widget _buildModelRow(Map<String, dynamic> model, ColorScheme cs) {
    final String modelId = model['model_id'] as String? ?? '';
    final String name = model['name'] as String? ?? modelId;
    final bool hasKey = model['has_api_key'] as bool? ?? false;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        '$modelId'
        '${hasKey ? '' : ' · 未配置 API Key'}'
        '${(model['thinking'] as bool? ?? false) ? ' · thinking' : ''}'
        '${(model['if_vision'] as bool? ?? false) ? ' · vision' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: cs.primary,
            onPressed: () => _openModelEditor(model),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 18),
            color: Colors.redAccent,
            onPressed: () => _deleteModel(model),
          ),
        ],
      ),
    );
  }

  /// 打开模型编辑对话框（[existing] 为 null 表示新增）
  Future<void> _openModelEditor(Map<String, dynamic>? existing) async {
    final Map<String, dynamic>? payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) => _ModelEditorDialog(existing: existing),
    );
    if (payload == null || !mounted) return;
    try {
      if (existing == null) {
        await ApiService.createModel(payload);
      } else {
        final String modelId = existing['model_id'] as String? ?? '';
        await ApiService.updateModel(modelId, payload);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(existing == null ? '模型已新增' : '模型已更新'),
          duration: const Duration(seconds: 2),
        ),
      );
      await _loadModelList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e'), duration: const Duration(seconds: 3)),
      );
    }
  }

  /// 删除模型（二次确认；若仍有 agent 绑定则提示）
  Future<void> _deleteModel(Map<String, dynamic> model) async {
    final String modelId = model['model_id'] as String? ?? '';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除模型'),
        content: Text(
          '确定删除模型「${model['name'] ?? modelId}」？\n'
          '其配置文件将从服务器移除，操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final Map<String, dynamic> result = await ApiService.deleteModel(modelId);
      final List<dynamic> bound =
          result['bound_agents'] as List<dynamic>? ?? <dynamic>[];
      if (!mounted) return;
      final String suffix = bound.isEmpty
          ? ''
          : '；注意：仍有 ${bound.length} 个 Agent 绑定该模型，需重新指定模型';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除$suffix'), duration: const Duration(seconds: 3)),
      );
      await _loadModelList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e'), duration: const Duration(seconds: 3)),
      );
    }
  }

  /// 消息切入模式卡片
  ///
  /// 关闭（默认，串行排队）：新消息入队，仅在当前消息的 tool_call 间隙
  /// 逐条切入，当前轮结束后再逐条处理剩余消息。
  /// 开启（直接切入）：间隙把队列中当前会话的消息一次性全部切入；且本轮
  /// 给出最终文本后若仍有新消息则继续本轮，使几乎同时到达的消息一起处理。
  Widget _buildMessageCutinCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '直接切入新消息（不排队）',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _directCutin
                        ? '已开启：新消息一次性全部切入当前上下文，几乎同时到达的消息（如多名成员的回传总结）一起处理'
                        : '已关闭（串行排队）：新消息逐条切入，当前轮结束后再逐条处理剩余消息',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
            Switch(
              value: _directCutin,
              onChanged: _toggleMessageCutin,
              activeThumbColor: cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 分区标题
  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Color(0xFF94A3B8),
      ),
    );
  }

  /// 主题管理卡片
  ///
  /// Flutter 3.32+ 起 Radio 的 groupValue/onChanged 迁移到 [RadioGroup] 祖先：
  /// 组状态与变更回调由 RadioGroup 统一持有，子项 RadioListTile 只声明自身 value。
  Widget _buildThemeCard() {
    final ThemeService themeService = ThemeService.instance;
    return Card(
      margin: EdgeInsets.zero,
      child: AnimatedBuilder(
        animation: themeService,
        builder: (BuildContext context, _) {
          return RadioGroup<ThemeMode>(
            groupValue: themeService.mode,
            onChanged: (ThemeMode? value) {
              if (value != null) {
                themeService.setMode(value);
              }
            },
            child: Column(
              children: [
                _buildThemeOption(
                  ThemeMode.light,
                  Icons.light_mode_outlined,
                  '浅色',
                  '明亮模式，适合白天使用',
                ),
                _buildThemeOption(
                  ThemeMode.dark,
                  Icons.dark_mode_outlined,
                  '深色',
                  '深色模式，适合夜间或省电',
                ),
                _buildThemeOption(
                  ThemeMode.system,
                  Icons.brightness_auto_outlined,
                  '跟随系统',
                  '根据操作系统自动切换',
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 单个主题选项（RadioListTile 风格；组状态由 [_buildThemeCard] 的 RadioGroup 持有）
  Widget _buildThemeOption(
    ThemeMode mode,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final cs = Theme.of(context).colorScheme;
    return RadioListTile<ThemeMode>(
      value: mode,
      activeColor: cs.primary,
      secondary: Icon(icon, color: cs.primary),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

/// 自定义模型编辑对话框（新增 / 编辑）
///
/// 提交时返回一份 `Map<String, dynamic>` 请求体（交给 `ApiService.createModel`
/// 或 `updateModel`）。编辑模式下 **不预填 API Key**（后端从不回显密钥）：
/// 留空即"不修改"，`has_api_key` 只用于提示当前是否已配置。
class _ModelEditorDialog extends StatefulWidget {
  /// 待编辑模型（null = 新增）
  final Map<String, dynamic>? existing;

  const _ModelEditorDialog({this.existing});

  @override
  State<_ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<_ModelEditorDialog> {
  final TextEditingController _modelId = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _maxSeqlen = TextEditingController();
  final TextEditingController _maxOutput = TextEditingController();

  /// 思考强度可选档位（逗号分隔）。留空 = 用后端默认档位
  /// （low/high/max，见 `config.models.REASONING_EFFORT_CANONICAL`）。
  final TextEditingController _effortOptions = TextEditingController();

  bool _thinking = false;
  bool _ifVision = false;
  String _reasoningEffort = '';

  /// 思考强度档位兜底（与后端 REASONING_EFFORT_CANONICAL 一致）。
  ///
  /// 只列**有实际区分度**的档位：端点接受的枚举全集里
  /// minimal/medium/xhigh/ultra 与服务端档位一一等价，列出来就是假选项。
  static const List<String> _reasoningEfforts = <String>['low', 'high', 'max'];

  bool get _isEdit => widget.existing != null;

  /// 解析逗号分隔的档位输入（兼容中文逗号与空白）。
  static List<String> _parseEffortOptions(String raw) {
    return raw
        .replaceAll('，', ',')
        .split(',')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.existing;
    if (e == null) return;
    _modelId.text = e['model_id'] as String? ?? '';
    _name.text = e['name'] as String? ?? '';
    // base_url 后端已脱敏（仅协议+主机），编辑时留空表示"按原值不变"
    _thinking = e['thinking'] as bool? ?? false;
    _ifVision = e['if_vision'] as bool? ?? false;
    _reasoningEffort = e['reasoning_effort'] as String? ?? '';
    // 后端已按"模型声明或全局回退"解析好档位列表，直接回填（不预设当前选中值：
    // 列表仅表示"哪些可被 agent 覆盖"，与模型自身默认档位是两件事）
    final List<dynamic>? opts =
        e['reasoning_effort_options'] as List<dynamic>?;
    if (opts != null && opts.isNotEmpty) {
      _effortOptions.text =
          opts.map((dynamic v) => v.toString()).join(', ');
    }
    final int? seq = (e['max_seqlen'] as num?)?.toInt();
    if (seq != null) _maxSeqlen.text = '$seq';
    final int? out = (e['max_output_tokens'] as num?)?.toInt();
    if (out != null) _maxOutput.text = '$out';
  }

  @override
  void dispose() {
    _modelId.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _maxSeqlen.dispose();
    _maxOutput.dispose();
    _effortOptions.dispose();
    super.dispose();
  }

  /// 思考强度下拉项：候选来自「可选档位」输入框，留空则用兜底档位。
  ///
  /// 当前 `_reasoningEffort` 若不在候选中（如文件里存的是档位声明之外的旧值，
  /// 或用户刚把档位列表改窄）**必须补进 items**：`DropdownButtonFormField` 的
  /// value 不在 items 中会直接断言失败，整个编辑弹窗打不开。
  List<DropdownMenuItem<String>> _buildEffortItems() {
    final List<String> options = _parseEffortOptions(_effortOptions.text);
    final List<String> candidates =
        options.isEmpty ? List<String>.of(_reasoningEfforts) : options;
    if (_reasoningEffort.isNotEmpty &&
        !candidates.contains(_reasoningEffort)) {
      candidates.add(_reasoningEffort);
    }
    return <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('不设置')),
      ...candidates.map(
        (String e) => DropdownMenuItem<String>(value: e, child: Text(e)),
      ),
    ];
  }

  void _submit() {
    final String modelId = _modelId.text.trim();
    if (modelId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('model_id 不能为空')),
      );
      return;
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'model_id': modelId,
      'name': _name.text.trim(),
      'thinking': _thinking,
      'if_vision': _ifVision,
    };
    // base_url / api_key：编辑时留空表示沿用原值（后端据此保留）
    final String baseUrl = _baseUrl.text.trim();
    if (baseUrl.isNotEmpty) payload['base_url'] = baseUrl;
    final String apiKey = _apiKey.text.trim();
    if (apiKey.isNotEmpty) payload['api_key'] = apiKey;
    if (_reasoningEffort.isNotEmpty) {
      payload['reasoning_effort'] = _reasoningEffort;
    }
    // 可选档位：留空 = 用后端默认（low/high/max），此时**不下发该键**让后端保留
    // 文件现值或走回退；非空则解析为列表下发（后端会归一化并校验默认档位落在其中）
    final List<String> effortOptions =
        _parseEffortOptions(_effortOptions.text);
    if (effortOptions.isNotEmpty) {
      payload['reasoning_effort_options'] = effortOptions;
    }
    final int? seq = int.tryParse(_maxSeqlen.text.trim());
    if (seq != null) payload['max_seqlen'] = seq;
    final int? out = int.tryParse(_maxOutput.text.trim());
    if (out != null) payload['max_output_tokens'] = out;

    // 新增必须提供 base_url / api_key（后端校验），前端先行拦截给出可读提示
    if (!_isEdit && (baseUrl.isEmpty || apiKey.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('新增模型必须填写 base_url 与 api_key')),
      );
      return;
    }
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool hasKey = widget.existing?['has_api_key'] as bool? ?? false;
    return AlertDialog(
      title: Text(_isEdit ? '编辑模型' : '新增模型'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _modelId,
                enabled: !_isEdit,
                decoration: const InputDecoration(
                  labelText: 'model_id',
                  helperText: '唯一标识，同时作为配置文件名（字母/数字/. _ -）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '显示名称',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrl,
                decoration: InputDecoration(
                  labelText: 'base_url',
                  helperText: _isEdit
                      ? '留空 = 保持原地址不变'
                      : 'OpenAI 兼容端点，如 https://api.example.com/v1',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'api_key',
                  helperText: _isEdit
                      ? (hasKey ? '已配置；留空 = 不修改' : '当前未配置')
                      : '必填',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _reasoningEffort,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '思考强度默认档位（reasoning_effort）',
                  helperText: '仅在该模型可选档位内；可被各 Agent 覆盖',
                  isDense: true,
                ),
                items: _buildEffortItems(),
                onChanged: (String? value) {
                  setState(() => _reasoningEffort = value ?? '');
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _effortOptions,
                // 重建下拉项：候选档位随本输入框内容变化（见 _buildEffortItems）
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '可选档位（reasoning_effort_options）',
                  hintText: '如 low, high, max',
                  helperText: '留空 = 默认 low/high/max；'
                      '只列该端点真正区分的档位，别名会被折叠',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _maxSeqlen,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '最大输入 tokens',
                        hintText: '如 65536',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _maxOutput,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '最大输出 tokens',
                        hintText: '留空不限',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _thinking,
                onChanged: (bool v) => setState(() => _thinking = v),
                activeThumbColor: cs.primary,
                title: const Text('思考模型（thinking）',
                    style: TextStyle(fontSize: 13)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _ifVision,
                onChanged: (bool v) => setState(() => _ifVision = v),
                activeThumbColor: cs.primary,
                title: const Text('支持图像输入（if_vision）',
                    style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text(_isEdit ? '保存' : '创建'),
        ),
      ],
    );
  }
}
