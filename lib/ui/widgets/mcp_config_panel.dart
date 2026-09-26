import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/mcp_trust_store.dart';

/// MCP 配置面板（右栏「MCP 配置」Tab）
///
/// 展示已注册的 MCP 服务列表，支持注册新的 stdio 外接服务（可指定执行落点
/// scope 与自定义环境变量 env）与删除自定义服务。内置服务（builtin=true）
/// 不可删除。
///
/// 信任授权：后端对非可信启动器注册的服务标记 ``needs_confirmation``，该服务
/// 在本地 / SSH 宿主上首次拉起前必须由用户在**本面板**确认启动命令可信
/// （见 [McpTrustStore]）；未确认时宿主侧拒绝启动并提示回本面板确认。
///
/// 数据源：`GET/POST /api/mcp/services`、`DELETE /api/mcp/services/{name}`。
class McpConfigPanel extends StatefulWidget {
  const McpConfigPanel({super.key});

  @override
  State<McpConfigPanel> createState() => _McpConfigPanelState();
}

class _McpConfigPanelState extends State<McpConfigPanel> {
  /// 已注册的 MCP 服务列表
  List<Map<String, dynamic>> _services = <Map<String, dynamic>>[];

  /// 是否正在加载
  bool _loading = true;

  /// 加载失败信息（为空表示无错误）
  String? _loadError;

  /// 是否展示注册表单
  bool _showForm = false;

  /// 注册表单控制器
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _commandController = TextEditingController();
  final TextEditingController _argsController = TextEditingController();
  final TextEditingController _envController = TextEditingController();

  /// 注册表单选中的执行落点（""=自动，按当前会话模式）
  String _scope = '';

  /// 各服务启动命令的信任状态：服务名 -> 是否已确认信任。
  ///
  /// 只在 [_load] 时按服务当前 command/args 重算（指纹随配置变化），不缓存
  /// 到本地持久化之外的地方。
  Map<String, bool> _trusted = <String, bool>{};

  /// 执行落点选项（值 -> 显示名）
  static const Map<String, String> _scopeLabels = <String, String>{
    '': '自动（按当前模式）',
    'server': '后端进程',
    'local': '本地主机',
    'ssh': '远端主机（SSH）',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _argsController.dispose();
    _envController.dispose();
    super.dispose();
  }

  /// 加载 MCP 服务列表（并刷新各服务的信任状态）
  Future<void> _load() async {
    try {
      final List<Map<String, dynamic>> services =
          await ApiService.getMcpServices();
      final Map<String, bool> trusted = <String, bool>{};
      for (final Map<String, dynamic> service in services) {
        final String fingerprint = _fingerprintOf(service);
        if (fingerprint.isEmpty) continue;
        trusted[service['name'] as String? ?? ''] =
            await McpTrustStore.isTrusted(fingerprint);
      }
      if (!mounted) return;
      setState(() {
        _services = services;
        _trusted = trusted;
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

  /// 服务启动命令的信任指纹（无命令的内置服务返回空串）。
  String _fingerprintOf(Map<String, dynamic> service) {
    final String command = (service['command'] as String? ?? '').trim();
    if (command.isEmpty) return '';
    final List<String> args = ((service['args'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic e) => e.toString())
        .toList();
    return McpTrustStore.fingerprint(command, args);
  }

  /// 注册新的 MCP 服务（随后对需确认的服务引导首次信任）
  Future<void> _register() async {
    final String name = _nameController.text.trim();
    final String command = _commandController.text.trim();
    if (name.isEmpty || command.isEmpty) {
      _showSnackBar('请填写服务名称与命令');
      return;
    }
    final List<String> args = _argsController.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((String e) => e.isNotEmpty)
        .toList();
    final Map<String, String>? env = _parseEnv();
    if (env == null) return;
    try {
      await ApiService.registerMcpService(
        name: name,
        command: command,
        args: args,
        scope: _scope,
        env: env,
      );
      if (!mounted) return;
      _showSnackBar('MCP 服务「$name」注册成功');
      _nameController.clear();
      _commandController.clear();
      _argsController.clear();
      _envController.clear();
      setState(() {
        _showForm = false;
      });
      await _load();
      await _confirmTrustIfNeeded(name);
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('注册失败：$e');
    }
  }

  /// 解析环境变量输入：每行一条 ``KEY=VALUE``。
  ///
  /// 空行忽略；非空行缺少 ``KEY=VALUE`` 形态时提示并放弃注册（不静默丢输入）。
  Map<String, String>? _parseEnv() {
    final Map<String, String> env = <String, String>{};
    for (final String line in _envController.text.split('\n')) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final int idx = trimmed.indexOf('=');
      if (idx <= 0) {
        _showSnackBar('环境变量格式应为 KEY=VALUE：$trimmed');
        return null;
      }
      env[trimmed.substring(0, idx).trim()] = trimmed.substring(idx + 1);
    }
    return env;
  }

  /// 待确认服务（非可信启动器）注册后立即引导用户确认信任。
  Future<void> _confirmTrustIfNeeded(String name) async {
    final Map<String, dynamic>? service = _serviceByName(name);
    if (service == null) return;
    if (!(service['needs_confirmation'] as bool? ?? false)) return;
    if (_trusted[name] == true) return;
    await _promptTrust(service);
  }

  /// 确认信任对话框：展示完整启动命令，用户确认后写入信任指纹。
  Future<void> _promptTrust(Map<String, dynamic> service) async {
    if (!mounted) return;
    final String name = service['name'] as String? ?? '';
    final String command = (service['command'] as String? ?? '').trim();
    final String fingerprint = _fingerprintOf(service);
    if (name.isEmpty || fingerprint.isEmpty) return;
    final List<dynamic> rawArgs = service['args'] as List<dynamic>? ?? [];
    final String cli = <String>[
      command,
      ...rawArgs.map((dynamic a) => a.toString()),
    ].join(' ');
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('确认信任 MCP 启动命令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '该服务不是常见启动器，将在工具调用时按执行落点拉起子进程。'
              '确认信任后才会启动：',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            SelectableText(
              cli,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('信任并启用'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await McpTrustStore.trust(fingerprint);
    if (!mounted) return;
    _showSnackBar('已信任「$name」的启动命令');
    await _load();
  }

  /// 撤销信任（下次启动前需重新确认）。
  Future<void> _revokeTrust(Map<String, dynamic> service) async {
    final String fingerprint = _fingerprintOf(service);
    if (fingerprint.isEmpty) return;
    await McpTrustStore.revoke(fingerprint);
    if (!mounted) return;
    _showSnackBar('已撤销「${service['name']}」的启动命令信任');
    await _load();
  }

  /// 按名称取列表中的服务记录（不存在返回 null）。
  Map<String, dynamic>? _serviceByName(String name) {
    for (final Map<String, dynamic> service in _services) {
      if ((service['name'] as String? ?? '') == name) return service;
    }
    return null;
  }

  /// 删除 MCP 服务（先确认）
  Future<void> _delete(Map<String, dynamic> service) async {
    final String name = service['name'] as String? ?? '';
    if (name.isEmpty) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除 MCP 服务'),
        content: Text('确定要删除 MCP 服务「$name」吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ApiService.deleteMcpService(name);
      if (!mounted) return;
      _showSnackBar('MCP 服务「$name」已删除');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('删除失败：$e');
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
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

  /// 头部：标题 + 「添加服务」按钮
  Widget _buildHeader() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'MCP 服务',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _showForm = !_showForm;
              });
            },
            icon: Icon(_showForm ? Icons.close : Icons.add, size: 16),
            label: Text(_showForm ? '收起' : '添加服务'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }

  /// 主体：加载中 / 出错 / 列表 + 注册表单
  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_loadError != null) {
      return _buildError();
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: <Widget>[
        if (_showForm) _buildRegisterForm(),
        if (_services.isEmpty && !_showForm)
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Column(
              children: <Widget>[
                Icon(
                  Icons.extension_off_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 8),
                Text(
                  '暂无 MCP 服务',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '点击右上角「添加服务」注册 stdio 外接服务',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          )
        else
          for (final Map<String, dynamic> service in _services)
            _buildServiceCard(service),
      ],
    );
  }

  /// 注册表单：名称 + 命令 + 参数 + 执行落点 + 环境变量
  Widget _buildRegisterForm() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('注册 stdio MCP 服务',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '服务名称',
              hintText: '如 my_mcp',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _commandController,
            decoration: const InputDecoration(
              labelText: '命令',
              hintText: '如 npx / python',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _argsController,
            decoration: const InputDecoration(
              labelText: '参数（空格分隔，可选）',
              hintText: '如 -y @modelcontextprotocol/server-filesystem',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _scope,
            isDense: true,
            decoration: const InputDecoration(
              labelText: '执行落点',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: _scopeLabels.entries
                .map((MapEntry<String, String> e) =>
                    DropdownMenuItem<String>(
                      value: e.key,
                      child: Text(e.value, style: const TextStyle(fontSize: 13)),
                    ))
                .toList(),
            onChanged: (String? value) {
              setState(() {
                _scope = value ?? '';
              });
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _envController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '环境变量（每行一条 KEY=VALUE，可选）',
              hintText: '如 API_KEY=xxx',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _register,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('注册'),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个服务卡片
  Widget _buildServiceCard(Map<String, dynamic> service) {
    final cs = Theme.of(context).colorScheme;
    final String name = service['name'] as String? ?? '';
    final String command = service['command'] as String? ?? '';
    final List<dynamic> rawArgs = service['args'] as List<dynamic>? ?? [];
    final String argsText =
        rawArgs.map((dynamic a) => a.toString()).join(' ');
    final bool builtin = service['builtin'] as bool? ?? false;
    final bool enabled = service['enabled'] as bool? ?? true;
    final String scope = service['scope'] as String? ?? '';
    final Map<dynamic, dynamic> rawEnv =
        (service['env'] as Map<dynamic, dynamic>?) ?? <dynamic, dynamic>{};
    final bool needsConfirmation =
        service['needs_confirmation'] as bool? ?? false;
    final bool trusted = _trusted[name] ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant, width: 0.5),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            builtin ? Icons.build_circle_outlined : Icons.extension_outlined,
            size: 18,
            color: builtin ? cs.primary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (builtin) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '内置',
                          style: TextStyle(fontSize: 10, color: cs.primary),
                        ),
                      ),
                    ],
                    if (!enabled) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        '已停用',
                        style: TextStyle(fontSize: 10, color: cs.outline),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  command.isNotEmpty
                      ? (argsText.isNotEmpty
                          ? '$command $argsText'
                          : command)
                      : '（未配置命令）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                if (!builtin) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '落点：${_scopeLabels[scope] ?? scope}'
                    '${rawEnv.isEmpty ? '' : ' · 环境变量：${rawEnv.keys.join('、')}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
                if (needsConfirmation) ...<Widget>[
                  const SizedBox(height: 2),
                  Row(
                    children: <Widget>[
                      Icon(
                        trusted
                            ? Icons.verified_user_outlined
                            : Icons.gpp_maybe_outlined,
                        size: 13,
                        color: trusted ? cs.primary : cs.error,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          trusted ? '启动命令已信任' : '启动命令待确认（未确认前不会启动）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: trusted ? cs.primary : cs.error,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: trusted
                            ? () => _revokeTrust(service)
                            : () => _promptTrust(service),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          trusted ? '撤销' : '信任',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (!builtin)
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.delete_outline, size: 16, color: cs.error),
              onPressed: () => _delete(service),
            ),
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
              'MCP 服务列表加载失败',
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
