import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// MCP 配置面板（右栏「MCP 配置」Tab）
///
/// 展示已注册的 MCP 服务列表，支持注册新的 stdio 外接服务与删除自定义服务。
/// 内置服务（builtin=true）不可删除。
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
    super.dispose();
  }

  /// 加载 MCP 服务列表
  Future<void> _load() async {
    try {
      final List<Map<String, dynamic>> services =
          await ApiService.getMcpServices();
      if (!mounted) return;
      setState(() {
        _services = services;
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

  /// 注册新的 MCP 服务
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
    try {
      await ApiService.registerMcpService(
        name: name,
        command: command,
        args: args,
      );
      if (!mounted) return;
      _showSnackBar('MCP 服务「$name」注册成功');
      _nameController.clear();
      _commandController.clear();
      _argsController.clear();
      setState(() {
        _showForm = false;
      });
      _load();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('注册失败：$e');
    }
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
      _load();
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

  /// 注册表单：名称 + 命令 + 参数
  Widget _buildRegisterForm() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.4),
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
                          color: cs.primaryContainer.withOpacity(0.6),
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
