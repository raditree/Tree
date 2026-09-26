import 'package:flutter/material.dart';

/// 插件编辑弹窗（M9 §4.2）：新增 / 编辑一个插件（内置插件的编辑也走这里）。
///
/// 为什么单独一个文件：面板（plugin_panel.dart）已经很长，而表单 + 校验 + 安全
/// 二次确认是一块自洽的东西，放在一起才好读。
///
/// 三条硬要求落在本文件里：
/// 1. **表单字段齐全**：id / 名称 / 命令 / 参数（每行一个）/ 环境变量（KEY=VALUE
///    每行一个）/ granularity / scope（四项，留空 = 通配）/ 启用；
/// 2. **校验与可读错误**：id 字符集、命令非空、环境变量格式、scope.mode_key 取值
///    都在客户端先拦一遍（核心还会再校验一次，两端口径一致）；
/// 3. **安全提示 + 保存前二次确认**：命令字段 = 可以用界面拉起任意进程——这是
///    插件系统的固有能力，不是缺陷；所以弹窗内写明，并在保存时把**即将执行的
///    命令行**原样摆出来让用户确认一次。
class PluginEditorDialog extends StatefulWidget {
  const PluginEditorDialog({
    super.key,
    this.entry,
    this.builtinSpec,
    this.isBuiltin = false,
  });

  /// 编辑时回填的落盘条目（null = 新增）。
  final Map<String, dynamic>? entry;

  /// 内置插件的清单项（含 resolution 解析结果；null = 自定义插件）。
  final Map<String, dynamic>? builtinSpec;

  /// 是否内置插件（内置项不允许删除，id 也不允许改）。
  final bool isBuiltin;

  /// 打开弹窗；返回可直接发给核心的请求体（取消返回 null）。
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    Map<String, dynamic>? entry,
    Map<String, dynamic>? builtinSpec,
    bool isBuiltin = false,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext ctx) => PluginEditorDialog(
        entry: entry,
        builtinSpec: builtinSpec,
        isBuiltin: isBuiltin,
      ),
    );
  }

  @override
  State<PluginEditorDialog> createState() => _PluginEditorDialogState();
}

class _PluginEditorDialogState extends State<PluginEditorDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _id = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _command = TextEditingController();
  final TextEditingController _args = TextEditingController();
  final TextEditingController _env = TextEditingController();
  final TextEditingController _teamId = TextEditingController();
  final TextEditingController _agentId = TextEditingController();
  final TextEditingController _sessionId = TextEditingController();

  String _granularity = 'team';
  String _modeKey = '';
  bool _enabled = true;

  /// 环境变量的行级错误（提交时算出来，显示在输入框下方）。
  String _envError = '';

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> entry =
        widget.entry ?? const <String, dynamic>{};
    final Map<String, dynamic> spec =
        widget.builtinSpec ?? const <String, dynamic>{};
    _id.text = (entry['id'] ?? spec['id'] ?? '').toString();
    _name.text = (entry['name'] ?? spec['name'] ?? '').toString();
    _command.text = (entry['command'] ?? '').toString();
    final Object? rawArgs = entry['args'];
    _args.text = rawArgs is List
        ? rawArgs.map((Object? a) => a.toString()).join('\n')
        : '';
    final Object? rawEnv = entry['env'];
    if (rawEnv is Map) {
      _env.text = rawEnv.entries
          .map((MapEntry<Object?, Object?> e) => '${e.key}=${e.value}')
          .join('\n');
    }
    final Object? rawScope = entry['scope'];
    if (rawScope is Map) {
      _teamId.text = (rawScope['team_id'] ?? '').toString();
      _agentId.text = (rawScope['agent_id'] ?? '').toString();
      _sessionId.text = (rawScope['session_id'] ?? '').toString();
      final String mode = (rawScope['mode_key'] ?? '').toString();
      _modeKey = mode == 'local' || mode == 'ssh' ? mode : '';
    }
    final String granularity =
        (entry['granularity'] ?? spec['granularity'] ?? 'team').toString();
    _granularity = <String>['team', 'agent', 'session'].contains(granularity)
        ? granularity
        : 'team';
    _enabled = entry['enabled'] != false;
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _env.dispose();
    _teamId.dispose();
    _agentId.dispose();
    _sessionId.dispose();
    super.dispose();
  }

  /// 参数：每行一个（空行忽略）。
  List<String> _argsList() => _args.text
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();

  /// 环境变量：每行 KEY=VALUE（值里可以再出现 =，只按第一个 = 切）。
  Map<String, String> _envMap() => <String, String>{
    for (final String line in _env.text.split('\n'))
      if (line.trim().isNotEmpty)
        line.trim().split('=').first.trim(): line.trim().substring(
          line.trim().indexOf('=') + 1,
        ),
  };

  /// 环境变量行的可读校验（返回空串 = 通过）。
  String _validateEnv() {
    for (final String raw in _env.text.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      final int eq = line.indexOf('=');
      if (eq <= 0) {
        return '环境变量必须是 KEY=VALUE 形式（每行一个），这一行不合法：$line';
      }
    }
    return '';
  }

  /// 组装请求体（与核心的字段口径一致）。
  Map<String, dynamic> _body() {
    final Map<String, String> scope = <String, String>{
      if (_teamId.text.trim().isNotEmpty) 'team_id': _teamId.text.trim(),
      if (_agentId.text.trim().isNotEmpty) 'agent_id': _agentId.text.trim(),
      if (_sessionId.text.trim().isNotEmpty)
        'session_id': _sessionId.text.trim(),
      if (_modeKey.isNotEmpty) 'mode_key': _modeKey,
    };
    return <String, dynamic>{
      'id': _id.text.trim(),
      'name': _name.text.trim(),
      'command': _command.text.trim(),
      'args': _argsList(),
      'env': _envMap(),
      'enabled': _enabled,
      'granularity': _granularity,
      'scope': scope,
    };
  }

  /// 即将执行的命令行（二次确认时原样给用户看）。
  String _commandLine() {
    final List<String> parts = <String>[_command.text.trim(), ..._argsList()];
    return parts.join(' ');
  }

  Future<void> _submit() async {
    final bool formOk = _formKey.currentState?.validate() ?? false;
    final String envError = _validateEnv();
    setState(() => _envError = envError);
    if (!formOk || envError.isNotEmpty) return;

    final Map<String, dynamic> body = _body();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('确认保存并尝试启动？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '插件命令 = 可以用界面拉起任意进程（插件系统的固有能力）。'
              '它会以当前用户权限运行，能读写本机文件、访问网络。'
              '请只添加你信任的命令。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            Text(
              '即将执行：${_commandLine()}',
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('plugin-editor-confirm-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再改改'),
          ),
          FilledButton(
            key: const Key('plugin-editor-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认保存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(body);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Map<String, dynamic> spec =
        widget.builtinSpec ?? const <String, dynamic>{};
    final Map<String, dynamic> resolution =
        (spec['resolution'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return AlertDialog(
      title: Text(
        _isEdit ? '编辑插件 ${_id.text}' : '添加插件',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (widget.isBuiltin)
                  _hint(
                    cs,
                    '内置插件：命令与脚本路径由核心解析（${_builtinRuntimeText(resolution)}）。'
                    '保存后再在界面上开关这一项时，核心会用重新解析出的结果覆盖命令与参数。',
                  ),
                TextFormField(
                  key: const Key('plugin-editor-id'),
                  controller: _id,
                  enabled: !_isEdit,
                  decoration: const InputDecoration(
                    labelText: '插件 id *',
                    helperText: '字母 / 数字 / 下划线 / 点 / 连字符；保存后不可改',
                    isDense: true,
                  ),
                  validator: (String? value) {
                    final String v = (value ?? '').trim();
                    if (v.isEmpty) return '请填写插件 id';
                    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(v)) {
                      return 'id 只允许字母、数字、下划线、点和连字符';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('plugin-editor-name'),
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: '名称（展示用）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('plugin-editor-command'),
                  controller: _command,
                  decoration: const InputDecoration(
                    labelText: '命令 *',
                    helperText: '要拉起的可执行文件，如 python / node / C:/tools/x.exe',
                    isDense: true,
                  ),
                  validator: (String? value) =>
                      (value ?? '').trim().isEmpty ? '请填写要拉起的命令' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('plugin-editor-args'),
                  controller: _args,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '参数（每行一个）',
                    helperText: '例如：plugins/sample_plugin.py',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('plugin-editor-env'),
                  controller: _env,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: '环境变量（KEY=VALUE，每行一个）',
                    errorText: _envError.isEmpty ? null : _envError,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const Key('plugin-editor-granularity'),
                        initialValue: _granularity,
                        // isExpanded：半宽下拉框里长文案不设它会直接溢出（overflow）
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '实例粒度',
                          helperText: 'team / agent / session',
                          isDense: true,
                        ),
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem<String>(
                            value: 'team',
                            child: Text('team'),
                          ),
                          DropdownMenuItem<String>(
                            value: 'agent',
                            child: Text('agent'),
                          ),
                          DropdownMenuItem<String>(
                            value: 'session',
                            child: Text('session'),
                          ),
                        ],
                        onChanged: (String? value) =>
                            setState(() => _granularity = value ?? 'team'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const Key('plugin-editor-mode-key'),
                        initialValue: _modeKey,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'scope.mode_key',
                          isDense: true,
                        ),
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem<String>(
                            value: '',
                            child: Text('通配'),
                          ),
                          DropdownMenuItem<String>(
                            value: 'local',
                            child: Text('local'),
                          ),
                          DropdownMenuItem<String>(
                            value: 'ssh',
                            child: Text('ssh'),
                          ),
                        ],
                        onChanged: (String? value) =>
                            setState(() => _modeKey = value ?? ''),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'scope（留空 = 通配；四元组是站点隔离的判据）',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _scopeField(
                        'plugin-editor-team',
                        _teamId,
                        'team_id',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _scopeField(
                        'plugin-editor-agent',
                        _agentId,
                        'agent_id',
                      ),
                    ),
                  ],
                ),
                _scopeField('plugin-editor-session', _sessionId, 'session_id'),
                SwitchListTile(
                  key: const Key('plugin-editor-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('启用', style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                    '关闭 = 核心不启动它（条目保留，面板显示「已停用」）',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _enabled,
                  onChanged: (bool value) => setState(() => _enabled = value),
                ),
                const SizedBox(height: 4),
                _hint(
                  cs,
                  '安全提示：命令字段等于可以用界面拉起任意进程——这是插件系统的固有'
                  '能力。插件会以当前用户权限运行，请只添加你信任的命令；保存时会再'
                  '确认一次即将执行的命令行。',
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('plugin-editor-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('plugin-editor-save'),
          onPressed: _submit,
          child: Text(_isEdit ? '保存' : '添加'),
        ),
      ],
    );
  }

  /// 内置插件的运行时一句话（解析失败时给可读原因）。
  String _builtinRuntimeText(Map<String, dynamic> resolution) {
    if (resolution['ok'] == true) {
      final String command = (resolution['command'] ?? '').toString();
      final String path = (resolution['script_path'] ?? '').toString();
      return '运行时 $command，脚本 $path';
    }
    final String error = (resolution['error'] ?? '').toString();
    return error.isEmpty ? '运行时尚未解析' : error;
  }

  Widget _scopeField(
    String key,
    TextEditingController controller,
    String label,
  ) => TextFormField(
    key: Key(key),
    controller: controller,
    decoration: InputDecoration(labelText: label, isDense: true),
  );

  Widget _hint(ColorScheme cs, String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    ),
  );
}
