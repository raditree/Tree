import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/plugin_monitor_service.dart';
import 'plugin_editor_dialog.dart';

/// 插件管理接口（面板 → 核心）。
///
/// 做成抽象类是为了**可测**：真实实现走 [ApiService] 的 REST 方法，widget 测试注入
/// 假实现就能在没有核心进程的情况下断言"点了哪个开关、发了什么请求、错误怎么显示"。
///
/// 为什么面板不把状态塞进 [PluginMonitorService]：那个服务是只读快照 + WS 增量的
/// 搬运工（M1 起就只读），而清单的增删改是**另一个数据源**（磁盘上的 plugins.yaml）。
/// 两者都在面板里合并展示：清单给"配置成什么样"，快照给"运行成什么样"。
abstract class PluginAdminClient {
  /// 读取插件清单（持久态）+ 每条的运行态。
  Future<Map<String, dynamic>> fetchConfigs();

  /// 读取内置插件目录（[refresh] = 强制核心重探运行时）。
  Future<Map<String, dynamic>> fetchBuiltins({bool refresh = false});

  /// 新增一个自定义插件。
  Future<Map<String, dynamic>> createConfig(Map<String, dynamic> body);

  /// 局部更新一个插件（开关 / 编辑）。
  Future<Map<String, dynamic>> updateConfig(
    String id,
    Map<String, dynamic> patch,
  );

  /// 删除一个自定义插件。
  Future<Map<String, dynamic>> deleteConfig(String id);

  /// 显式重启一个插件实例。
  Future<Map<String, dynamic>> restartConfig(String id);

  /// 打开 / 关闭一个内置插件（每项各自一个开关）。
  Future<Map<String, dynamic>> setBuiltinEnabled(
    String id, {
    required bool enabled,
  });
}

/// 默认实现：直接走 [ApiService]。
class ApiPluginAdminClient implements PluginAdminClient {
  const ApiPluginAdminClient();

  @override
  Future<Map<String, dynamic>> fetchConfigs() => ApiService.getPluginConfigs();

  @override
  Future<Map<String, dynamic>> fetchBuiltins({bool refresh = false}) =>
      ApiService.getPluginBuiltins(refresh: refresh);

  @override
  Future<Map<String, dynamic>> createConfig(Map<String, dynamic> body) =>
      ApiService.createPluginConfig(
        id: (body['id'] ?? '').toString(),
        name: (body['name'] ?? '').toString(),
        command: (body['command'] ?? '').toString(),
        args: _strings(body['args']),
        env: _stringMap(body['env']),
        granularity: (body['granularity'] ?? 'team').toString(),
        scope: _stringMap(body['scope']),
        enabled: body['enabled'] != false,
      );

  @override
  Future<Map<String, dynamic>> updateConfig(
    String id,
    Map<String, dynamic> patch,
  ) => ApiService.updatePluginConfig(id, patch);

  @override
  Future<Map<String, dynamic>> deleteConfig(String id) =>
      ApiService.deletePluginConfig(id);

  @override
  Future<Map<String, dynamic>> restartConfig(String id) =>
      ApiService.restartPluginConfig(id);

  @override
  Future<Map<String, dynamic>> setBuiltinEnabled(
    String id, {
    required bool enabled,
  }) => ApiService.setBuiltinPluginEnabled(id, enabled: enabled);

  static List<String> _strings(Object? raw) => raw is List
      ? <String>[for (final Object? e in raw) e.toString()]
      : const <String>[];

  static Map<String, String> _stringMap(Object? raw) => raw is Map
      ? <String, String>{
          for (final MapEntry<Object?, Object?> e in raw.entries)
            e.key.toString(): e.value?.toString() ?? '',
        }
      : const <String, String>{};
}

/// 插件面板（左侧活动栏「插件」页）：**可读写**。
///
/// 数据源两条，分工明确：
/// 1. 清单（读写）——[PluginAdminClient]（默认 REST /api/plugin/configs 与
///    /api/plugin/builtins）：插件实例分「内置」「自定义」两组，**每一项各有自己的
///    开关**（M9 §4.2：不是统一开关），另有 编辑 / 删除 / 重启；
/// 2. 运行态（只读）——[PluginMonitorService]（快照 + WS 增量）：站点 / 看门狗 /
///    心跳健康度，以及清单接口不可用时（旧核心）的实例列表兜底。
///
/// 展示纪律（延续既有口径）：
/// - 心跳降级 **不是** 停用（角标橙色 + 说明，状态标签仍是「已注册」）；
/// - 未知字段与未知状态一律忽略（不崩、不臆测）；
/// - 停用 = 条目保留（面板显示「已停用」而不是让它消失）；
/// - 热应用失败必须如实显示核心给的 notice（「配置已保存，但本次热应用失败，
///   重启核心后生效」）——不显示就等于骗用户"已经生效了"。
///
/// 位于左栏时由活动栏承担标题，可传 [showHeader] = false 避免双标题。
class PluginPanel extends StatefulWidget {
  /// 所属团队 ID（null / 空串 = 不过滤，展示当前用户可见全部实例）
  final String? teamId;

  /// 是否渲染自带标题栏（左栏由活动栏承担标题时传 false）
  final bool showHeader;

  /// 左栏折叠回调（内容下方空白区域点击触发）
  ///
  /// 为 null 时不注册点击（右栏等常驻场景不需要折叠语义）。
  final VoidCallback? onCollapse;

  /// 数据源覆盖（**测试注入用**；null = 全局单例 [PluginMonitorService.instance]）。
  ///
  /// 面板在真实使用里是单例（一处连接、多处展示），但 widget 测试需要一个干净的
  /// 服务实例，否则测试之间会共享同一次快照与连接态。
  final PluginMonitorService? service;

  /// 插件管理接口覆盖（**测试注入用**；null = 走 REST 的 [ApiPluginAdminClient]）。
  final PluginAdminClient? admin;

  const PluginPanel({
    super.key,
    this.teamId,
    this.showHeader = true,
    this.onCollapse,
    this.service,
    this.admin,
  });

  @override
  State<PluginPanel> createState() => _PluginPanelState();
}

class _PluginPanelState extends State<PluginPanel> {
  PluginMonitorService get _svc =>
      widget.service ?? PluginMonitorService.instance;

  PluginAdminClient get _admin => widget.admin ?? const ApiPluginAdminClient();

  /// 插件清单（持久态；落盘的那一份）。
  List<Map<String, dynamic>> _configs = <Map<String, dynamic>>[];

  /// 每条插件的运行态（id → running / health / reason / error / known）。
  Map<String, dynamic> _runtime = <String, dynamic>{};

  /// 内置插件目录（静态清单 + 启用态 + 运行时解析结果）。
  List<Map<String, dynamic>> _builtins = <Map<String, dynamic>>[];

  /// plugins.yaml 的真实路径（核心给；清单接口不可用时退回快照里的路径）。
  String _adminPath = '';

  /// 清单接口的错误（旧核心没这些端点时非空 ⇒ 退回只读实例列表）。
  String? _adminError;

  /// 正在提交的插件 id（提交期间禁用该项的开关，避免连点）。
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
    _svc.start(teamId: widget.teamId ?? '');
    _loadAdmin();
  }

  @override
  void didUpdateWidget(covariant PluginPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.teamId != widget.teamId) {
      _svc.setTeam(widget.teamId ?? '');
    }
  }

  @override
  void dispose() {
    _svc.removeListener(_onChanged);
    _svc.stop();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // ── 数据 ─────────────────────────────────────────────────────────────

  /// 拉清单 + 内置目录（[refreshBuiltins] = 让核心重探运行时）。
  Future<void> _loadAdmin({bool refreshBuiltins = false}) async {
    try {
      final Map<String, dynamic> configs = await _admin.fetchConfigs();
      final Map<String, dynamic> builtins = await _admin.fetchBuiltins(
        refresh: refreshBuiltins,
      );
      if (!mounted) return;
      setState(() {
        _configs = _mapList(configs['configs']);
        final Object? runtime = configs['runtime'];
        _runtime = runtime is Map
            ? Map<String, dynamic>.from(runtime)
            : <String, dynamic>{};
        _builtins = _mapList(builtins['builtins']);
        _adminPath = (configs['path'] ?? builtins['path'] ?? '').toString();
        _adminError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _adminError = '$error'.replaceFirst('Exception: ', '');
      });
    }
  }

  static List<Map<String, dynamic>> _mapList(Object? raw) => raw is List
      ? <Map<String, dynamic>>[
          for (final Object? item in raw)
            if (item is Map) Map<String, dynamic>.from(item),
        ]
      : <Map<String, dynamic>>[];

  /// 自定义插件：落盘条目里没有 builtin 标记、且**不属于内置清单**的那些。
  ///
  /// 排除内置 id 是为了防手改：用户把 plugins.yaml 里的 builtin 标记删掉之后，
  /// 同一条目会同时出现在内置组（清单常驻）与自定义组（显示两份）——这里按 id 去重。
  List<Map<String, dynamic>> get _customConfigs {
    final Set<String> builtinIds = <String>{
      for (final Map<String, dynamic> b in _builtins)
        (b['id'] ?? '').toString(),
    };
    return <Map<String, dynamic>>[
      for (final Map<String, dynamic> c in _configs)
        if (c['builtin'] != true &&
            !builtinIds.contains((c['id'] ?? '').toString()))
          c,
    ];
  }

  // ── 提交 ─────────────────────────────────────────────────────────────

  /// 提交一次改动：调用 → 如实显示结果 → 重拉清单与快照。
  Future<void> _submit(
    String id,
    Future<Map<String, dynamic>> Function() action, {
    String successText = '',
  }) async {
    setState(() => _busy.add(id));
    try {
      final Map<String, dynamic> result = await action();
      _showWriteResult(result, successText: successText);
      await _loadAdmin();
      await _svc.refresh();
    } catch (error) {
      _snack('操作失败：${'$error'.replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  /// 写盘结果：核心给了 notice（热应用失败话术）就**必须**显示。
  void _showWriteResult(
    Map<String, dynamic> result, {
    required String successText,
  }) {
    final String notice = (result['notice'] ?? '').toString();
    final String detail = (result['hot_apply_detail'] ?? '').toString();
    if (notice.isNotEmpty) {
      _snack(detail.isEmpty ? notice : '$notice（$detail）');
      return;
    }
    if (successText.isNotEmpty) {
      _snack(successText);
    }
  }

  void _snack(String text) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  /// 每一项自己的开关：自定义插件 → PATCH enabled；内置插件 → enable / disable。
  Future<void> _toggleCustom(Map<String, dynamic> entry, bool value) {
    final String id = (entry['id'] ?? '').toString();
    return _submit(
      id,
      () => _admin.updateConfig(id, <String, dynamic>{'enabled': value}),
      successText: value ? '已写入启用状态' : '已写入停用状态',
    );
  }

  Future<void> _toggleBuiltin(Map<String, dynamic> item, bool value) {
    final String id = (item['id'] ?? '').toString();
    return _submit(
      id,
      () => _admin.setBuiltinEnabled(id, enabled: value),
      successText: value ? '已写入启用状态' : '已写入停用状态',
    );
  }

  Future<void> _restart(String id) =>
      _submit(id, () => _admin.restartConfig(id), successText: '已重启插件 $id');

  Future<void> _delete(Map<String, dynamic> entry) async {
    final String id = (entry['id'] ?? '').toString();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除插件？'),
        content: Text(
          '将从 plugins.yaml 里删除「$id」（条目与开关一并消失）。'
          '删除后需要重启核心才会断开正在运行的实例。',
          style: const TextStyle(fontSize: 12),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('plugin-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _submit(id, () => _admin.deleteConfig(id), successText: '已删除插件 $id');
  }

  /// 添加 / 编辑弹窗（内置插件也能编辑；id 不可改）。
  Future<void> _openEditor({
    Map<String, dynamic>? entry,
    Map<String, dynamic>? spec,
    bool isBuiltin = false,
  }) async {
    final Map<String, dynamic>? body = await PluginEditorDialog.show(
      context,
      entry: entry,
      builtinSpec: spec,
      isBuiltin: isBuiltin,
    );
    if (body == null || !mounted) return;
    final String id = (body['id'] ?? '').toString();
    if (entry != null) {
      await _submit(
        id,
        () => _admin.updateConfig(id, body),
        successText: '已保存插件 $id',
      );
      return;
    }
    await _submit(
      id,
      () => _admin.createConfig(body),
      successText: '已保存插件 $id',
    );
  }

  // ── 渲染 ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final PluginSnapshot? snap = _svc.snapshot;
    return Column(
      children: [
        if (widget.showHeader) _buildHeader(cs),
        if (!_svc.connected) _buildBanner(cs, '连接断开，正在重连…（下方为最近一次数据）'),
        if (_svc.error != null) _buildBanner(cs, '快照获取失败：${_svc.error}'),
        Expanded(child: _buildBody(cs, snap)),
      ],
    );
  }

  /// 头部：标题 + 连接指示 + 刷新按钮。
  Widget _buildHeader(ColorScheme cs) {
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Text(
            '插件管理',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _svc.connected ? Colors.green : Colors.orange,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            _svc.connected ? '已连接' : '未连接',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          IconButton(
            tooltip: '刷新快照与插件清单',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: _svc.loading
                ? null
                : () {
                    _svc.refresh();
                    _loadAdmin();
                  },
            icon: _svc.loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  /// 顶部提示条（断连 / 快照错误）。
  Widget _buildBanner(ColorScheme cs, String text) {
    return Container(
      width: double.infinity,
      color: cs.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
      ),
    );
  }

  /// 主体：按数据与连接状态渲染（断连 / 空 / 错误 / 数据四分支）。
  Widget _buildBody(ColorScheme cs, PluginSnapshot? snap) {
    if (snap == null) {
      if (!_svc.connected) {
        return _buildEmptyArea(cs, '等待连接…');
      }
      if (_svc.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _buildEmptyArea(cs, '暂无数据');
    }
    // 用 CustomScrollView 而非 ListView：内容不足一屏时，底部剩余空白由
    // SliverFillRemaining 撑满，成为"点击空白处折叠左栏"的折叠区
    // （与 AgentList 的实现一致）。
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.only(top: 8),
          sliver: SliverList(
            delegate: SliverChildListDelegate(<Widget>[_bodyContent(cs, snap)]),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: _buildCollapseZone(cs, snap),
        ),
      ],
    );
  }

  /// 面板主体内容（各区块，原 ListView 的 children）。
  Widget _bodyContent(ColorScheme cs, PluginSnapshot snap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(cs, '开关与配置'),
          _buildSwitchSection(cs, snap),
          const SizedBox(height: 12),
          _sectionTitle(cs, '插件实例（${_instanceCount(snap)}）'),
          _buildConfigPathHint(cs, snap),
          ..._buildInstances(cs, snap),
          const SizedBox(height: 12),
          // M9 §3 的正式名字是「站点」（广播 / 执行 / 中转 / 收集四类），
          // 旧文案「处理站」是已废弃的旧名（旧「处理站」= 现在的中转站）。
          _sectionTitle(cs, '站点（${snap.stations.length}）'),
          if (snap.stations.isEmpty)
            _emptyHint(cs, _stationsEmptyText(snap))
          else
            ...snap.stations.map((PluginStationInfo s) => _stationCard(cs, s)),
          const SizedBox(height: 12),
          _sectionTitle(cs, '看门狗'),
          _buildWatchdog(cs, snap),
        ],
      ),
    );
  }

  /// 「插件实例」的条目数：清单可用 = 内置项 + 自定义项；否则退回快照实例数。
  int _instanceCount(PluginSnapshot snap) => _adminError == null
      ? _builtins.length + _customConfigs.length
      : snap.instances.length;

  /// 清单文件路径 + 生效方式（M9 §4.2 要求把"真实路径"与"怎么生效"写在界面上）。
  ///
  /// 文案刻意用「清单文件：」而不是「插件配置：」——站点段的空态里已经有一句
  /// 「插件配置：<路径>」，两处同名会让人以为是重复渲染。
  Widget _buildConfigPathHint(ColorScheme cs, PluginSnapshot snap) {
    final String path = _adminPath.isNotEmpty
        ? _adminPath
        : snap.pluginConfigPath;
    if (path.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '清单文件：$path（保存后立即热应用；热应用失败时重启核心生效）',
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 插件实例区：内置 / 自定义两组；清单接口不可用时退回只读实例列表。
  List<Widget> _buildInstances(ColorScheme cs, PluginSnapshot snap) {
    if (_adminError != null) {
      return <Widget>[
        _emptyHint(cs, '插件清单接口不可用：$_adminError'),
        _emptyHint(cs, '（下面是快照里的运行态实例；升级核心后可直接在此增删改）'),
        if (snap.instances.isEmpty)
          _emptyHint(cs, _instancesEmptyText(snap))
        else
          ...snap.instances.map(
            (PluginInstanceInfo e) => _instanceCard(cs, e, snap.watchdog),
          ),
      ];
    }
    final List<Map<String, dynamic>> custom = _customConfigs;
    return <Widget>[
      _groupHeader(
        cs,
        '内置插件（${_builtins.length}）',
        trailing: IconButton(
          key: const Key('plugin-builtins-refresh'),
          tooltip: '重新探测内置插件运行时（装了 Python 之后点这里）',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: () => _loadAdmin(refreshBuiltins: true),
          icon: const Icon(Icons.refresh),
        ),
      ),
      if (_builtins.isEmpty)
        _emptyHint(cs, '核心没有提供内置插件目录（旧核心？）')
      else
        ..._builtins.map((Map<String, dynamic> b) => _builtinCard(cs, b)),
      _groupHeader(
        cs,
        '自定义插件（${custom.length}）',
        trailing: TextButton.icon(
          key: const Key('plugin-add'),
          onPressed: () => _openEditor(),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加插件', style: TextStyle(fontSize: 12)),
        ),
      ),
      if (custom.isEmpty)
        _emptyHint(cs, '还没有自定义插件。点「添加插件」写一个（命令 = 要拉起的进程）。')
      else
        ...custom.map((Map<String, dynamic> e) => _configCard(cs, e)),
    ];
  }

  /// 分组标题（内置 / 自定义），右侧可挂一个操作。
  Widget _groupHeader(ColorScheme cs, String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  /// 内置插件卡片：**每一项一个开关**；内置项不给删除（只给停用）。
  Widget _builtinCard(ColorScheme cs, Map<String, dynamic> item) {
    final String id = (item['id'] ?? '').toString();
    final String name = (item['name'] ?? '').toString();
    final bool enabled = item['enabled'] == true;
    final bool configured = item['configured'] == true;
    final Map<String, dynamic> entry =
        (item['config'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> resolution =
        (item['resolution'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final bool resolvable = resolution['ok'] == true;
    final String resolutionText = resolvable
        ? '运行时 ${resolution['command']} · 脚本 ${resolution['script_path']}'
        : '运行时未就绪：${resolution['error'] ?? '未知原因'}';
    final List<String> entryArgs = <String>[
      for (final Object? a in (entry['args'] as List<dynamic>? ?? <dynamic>[]))
        a.toString(),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name.isEmpty ? id : name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _pill(cs, '内置', emphasize: true),
              const SizedBox(width: 6),
              _enabledLabel(cs, enabled),
              Switch(
                key: Key('plugin-switch-builtin-$id'),
                value: enabled,
                onChanged: _busy.contains(id)
                    ? null
                    : (bool value) => _toggleBuiltin(item, value),
              ),
            ],
          ),
          Text(id, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          if ((item['description'] ?? '').toString().isNotEmpty)
            Text(
              (item['description'] ?? '').toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Text(
            resolutionText,
            style: TextStyle(
              fontSize: 11,
              color: resolvable ? cs.onSurfaceVariant : cs.error,
            ),
          ),
          if (configured)
            Text(
              '命令：${entry['command']} ${entryArgs.join(' ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Row(
            children: <Widget>[
              if (configured)
                TextButton(
                  key: Key('plugin-edit-$id'),
                  onPressed: _busy.contains(id)
                      ? null
                      : () => _openEditor(
                          entry: entry,
                          spec: item,
                          isBuiltin: true,
                        ),
                  child: const Text('编辑', style: TextStyle(fontSize: 12)),
                ),
              if (configured)
                TextButton(
                  key: Key('plugin-restart-$id'),
                  onPressed: _busy.contains(id) ? null : () => _restart(id),
                  child: const Text('重启', style: TextStyle(fontSize: 12)),
                ),
              Expanded(
                child: Text(
                  configured ? '内置插件不可删除；停用请用右侧开关' : '打开后可编辑（核心会解析运行时与脚本）',
                  style: TextStyle(fontSize: 10, color: cs.outline),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 自定义插件卡片：**每一项一个开关** + 编辑 / 删除 / 重启。
  Widget _configCard(ColorScheme cs, Map<String, dynamic> entry) {
    final String id = (entry['id'] ?? '').toString();
    final String name = (entry['name'] ?? '').toString();
    final bool enabled = entry['enabled'] != false;
    final Object? rawRuntime = _runtime[id];
    final Map<String, dynamic> runtime = rawRuntime is Map
        ? Map<String, dynamic>.from(rawRuntime)
        : <String, dynamic>{};
    final List<String> args = <String>[
      for (final Object? a in (entry['args'] as List<dynamic>? ?? <dynamic>[]))
        a.toString(),
    ];
    final Map<String, dynamic> scope = <String, dynamic>{};
    final Object? rawScope = entry['scope'];
    if (rawScope is Map) {
      for (final MapEntry<Object?, Object?> e in rawScope.entries) {
        scope[e.key.toString()] = e.value ?? '';
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name.isEmpty ? id : name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _enabledLabel(cs, enabled),
              Switch(
                key: Key('plugin-switch-custom-$id'),
                value: enabled,
                onChanged: _busy.contains(id)
                    ? null
                    : (bool value) => _toggleCustom(entry, value),
              ),
            ],
          ),
          if (name.isNotEmpty)
            Text(
              id,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Text(
            '命令：${entry['command']} ${args.join(' ')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          Text(
            '粒度 ${entry['granularity']} · scope: ${_scopeSummary(scope)}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          Text(
            _runtimeText(enabled, runtime),
            style: TextStyle(
              fontSize: 11,
              color: _runtimeColor(cs, enabled, runtime),
            ),
          ),
          if ((runtime['error'] ?? '').toString().isNotEmpty)
            Text(
              '启动失败：${runtime['error']}',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          // 心跳降级的原因（M9 §1.1：判活结果必须前端可见，且不能与"停用"混为一谈）
          if (runtime['health'] == 'degraded' &&
              (runtime['reason'] ?? '').toString().isNotEmpty)
            Text(
              '心跳降级：${runtime['reason']}（插件仍注册运行，非停用）',
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          Row(
            children: <Widget>[
              TextButton(
                key: Key('plugin-edit-$id'),
                onPressed: _busy.contains(id)
                    ? null
                    : () => _openEditor(entry: entry),
                child: const Text('编辑', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                key: Key('plugin-restart-$id'),
                onPressed: _busy.contains(id) ? null : () => _restart(id),
                child: const Text('重启', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                key: Key('plugin-delete-$id'),
                onPressed: _busy.contains(id) ? null : () => _delete(entry),
                child: Text(
                  '删除',
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 「已启用 / 已停用」标签（每项自己的开关状态）。
  Widget _enabledLabel(ColorScheme cs, bool enabled) => Text(
    enabled ? '已启用' : '已停用',
    style: TextStyle(
      fontSize: 11,
      color: enabled ? Colors.green : cs.onSurfaceVariant,
    ),
  );

  /// 自定义插件的运行态一句话。
  ///
  /// known=false 表示这条配置**还没被总线对账过**（例如刚写盘、或在旧核心上）。
  /// 热应用（applyConfigs）落地后这种情况几乎不再出现：写入即对账，所以这里
  /// 提示用户"可点重启或看原因"，而不是断言一定要重启核心。
  String _runtimeText(bool enabled, Map<String, dynamic> runtime) {
    if (!enabled) return '状态：已停用（条目保留）';
    if (runtime['running'] == true) {
      return runtime['health'] == 'degraded' ? '状态：运行中（心跳降级，仍注册）' : '状态：运行中';
    }
    if (runtime['known'] == true) return '状态：已启用但未运行（可点「重启」）';
    return '状态：已启用但未运行（可点「重启」，或看上方原因）';
  }

  Color _runtimeColor(
    ColorScheme cs,
    bool enabled,
    Map<String, dynamic> runtime,
  ) {
    if (!enabled) return cs.onSurfaceVariant;
    if (runtime['health'] == 'degraded') return Colors.orange;
    if (runtime['running'] == true) return Colors.green;
    return cs.onSurfaceVariant;
  }

  /// 空态占位（等待连接 / 暂无数据），点击任意空白处折叠左栏。
  Widget _buildEmptyArea(ColorScheme cs, String text) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onCollapse,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            if (widget.onCollapse != null) ...<Widget>[
              const SizedBox(height: 10),
              _buildCollapseHint(cs, ''),
            ],
          ],
        ),
      ),
    );
  }

  /// 数据态下方的折叠区：占满内容之外的剩余空白，点击即折叠左栏。
  ///
  /// 内容超过一屏时该区域被挤到滚动末尾，折叠入口仍保留在标题栏与活动栏。
  Widget _buildCollapseZone(ColorScheme cs, PluginSnapshot snap) {
    // 没有任何实例时，在折叠提示上方补一行空态说明：面板数据稀疏时，
    // 下方大片空白容易被误认为"还在加载"。
    final String hint = snap.instances.isNotEmpty ? '' : '暂无插件实例';
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onCollapse,
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        child: _buildCollapseHint(cs, hint),
      ),
    );
  }

  /// 折叠提示（图标 + 文案，可选上方附加一行空态说明）。
  ///
  /// 仅注册 onTap：同时注册 onDoubleTap 会让 GestureDetector 等待双击超时
  /// （约 300ms）再响应单击，折叠出现明显延迟。
  Widget _buildCollapseHint(ColorScheme cs, String extra) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (extra.isNotEmpty) ...<Widget>[
          Text(
            extra,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
        ],
        if (widget.onCollapse != null) ...<Widget>[
          Icon(Icons.chevron_left, size: 20, color: cs.outline),
          const SizedBox(height: 4),
          Text('点击空白处折叠左栏', style: TextStyle(fontSize: 11, color: cs.outline)),
        ],
      ],
    );
  }

  /// 开关与配置摘要（配置按白名单裁剪，未知键忽略）。
  Widget _buildSwitchSection(ColorScheme cs, PluginSnapshot snap) {
    final List<Widget> pills = <Widget>[
      _pill(cs, snap.enabled ? '已启用' : '未启用', emphasize: snap.enabled),
      _pill(cs, '每个插件各自一个开关'),
    ];
    if (snap.generatedAt != null) {
      pills.add(_pill(cs, '更新于 ${_relativeTime(snap.generatedAt)}'));
    }
    const List<String> configWhitelist = <String>[
      'station_timeout_s',
      'instance_ttl_s',
      'status_max_per_sec',
    ];
    for (final String k in configWhitelist) {
      final Object? v = snap.config[k];
      if (v != null) {
        pills.add(_pill(cs, '$k: $v'));
      }
    }
    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }

  /// 看门狗概要。
  ///
  /// 「判死」在 M9 §1.1 下恒为 0：心跳巡检只标健康度（degraded）**不终止插件**，
  /// 所以真正要看的数字是「降级」——有降级实例时该 pill 转橙提示。
  Widget _buildWatchdog(ColorScheme cs, PluginSnapshot snap) {
    final PluginWatchdogInfo? w = snap.watchdog;
    if (w == null) {
      return _emptyHint(cs, '暂无数据');
    }
    final int? degraded = w.degradedCount;
    final List<Widget> pills = <Widget>[
      _pill(cs, '活跃 runs: ${w.activeRuns}'),
      _pill(cs, '判死: ${w.judgedDead}'),
      if (degraded != null)
        _pill(cs, '降级: $degraded', color: degraded > 0 ? Colors.orange : null),
      if (w.intervalS != null && w.missThreshold != null)
        _pill(cs, '判活窗口 ${_trimNumber(w.intervalS!)}s×${w.missThreshold}'),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }

  /// 单个插件实例卡片（**清单接口不可用时的兜底**：只读运行态）。
  ///
  /// 健康度（M9 §1.1）：心跳连续丢失 ⇒ 角标「心跳降级」+ 一行说明；
  /// 此时 **状态标签仍是「已注册」**——降级不是停用，文案不得写成"已停用"。
  Widget _instanceCard(
    ColorScheme cs,
    PluginInstanceInfo e,
    PluginWatchdogInfo? watchdog,
  ) {
    final String title = e.name.isNotEmpty ? e.name : e.pluginId;
    final List<String> meta = <String>[
      if (e.granularity.isNotEmpty) '粒度 ${e.granularity}',
      '心跳 ${_relativeTime(e.lastHeartbeat)}',
      if (e.missedHeartbeats != null && e.missedHeartbeats! > 0)
        '丢失 ${e.missedHeartbeats} 拍',
      if (e.queueDepth != null && e.queueDepth! > 0) '队列 ${e.queueDepth}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
          // 降级实例描边转橙：不靠读文字也能一眼扫到
          color: e.isDegraded
              ? Colors.orange.withValues(alpha: 0.7)
              : Theme.of(context).dividerColor,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (e.isDegraded) ...<Widget>[
                _pill(cs, '心跳降级', color: Colors.orange),
                const SizedBox(width: 6),
              ],
              _statusLabel(cs, e.status),
            ],
          ),
          if (title != e.pluginId)
            Text(
              e.pluginId,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 2),
          Text(
            meta.join(' · '),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          Text(
            'scope: ${_scopeSummary(e.scope)}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          if (e.isDegraded)
            Text(
              _degradedDetail(e, watchdog),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          if (e.disabledReason.isNotEmpty)
            Text(
              '停用原因: ${e.disabledReason}',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
        ],
      ),
    );
  }

  /// 降级说明（角标下方那行橙字）：原因 + 丢失拍数 + 判活窗口 I×N。
  ///
  /// 文案纪律：**不出现"已停用"**——降级 = 心跳连续丢失，插件仍注册、仍在跑，
  /// 心跳恢复即自动清除；缺失的字段不臆测（缺失就不写）。
  String _degradedDetail(PluginInstanceInfo e, PluginWatchdogInfo? watchdog) {
    final int? n = watchdog?.missThreshold;
    final double? interval = e.heartbeatIntervalS ?? watchdog?.intervalS;
    final String head = e.degradedReason.isNotEmpty
        ? e.degradedReason
        : (n != null ? '连续 $n 拍未收到心跳' : '心跳连续丢失');
    final List<String> tail = <String>[
      '插件仍注册运行（非停用）',
      if (e.missedHeartbeats != null) '丢失 ${e.missedHeartbeats} 拍',
      if (interval != null && n != null)
        '判活窗口 ${_trimNumber(interval)}s×$n'
      else if (interval != null)
        '心跳间隔 ${_trimNumber(interval)}s',
    ];
    return '$head · ${tail.join(' · ')}';
  }

  /// 秒数去掉多余小数（30.0 → 30；2.5 → 2.5）。
  String _trimNumber(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  /// 单个站点卡片（计数白名单裁剪，未知键忽略）。
  ///
  /// 展示口径（M9 §3，站点全局化后）：
  /// **类型用核心给的 kind / kind_label**（中文名不写死在前端，旧核心缺 kind_label
  /// 时按线名兜底、两者都认不出就不显示类型标签），内置站打「内置」标识，
  /// 订阅数用核心给的 subscriber_count。
  ///
  /// **team 视角改看订阅者分组**（`subscribers_by_team`）：站点全局唯一、不绑 team，
  /// 所以"哪些团队在用这个站"只能由订阅声明回答；不再显示 mode_key 摘要。
  Widget _stationCard(ColorScheme cs, PluginStationInfo s) {
    final String kindLabel = s.displayKindLabel;
    final String subscriber =
        s.subscriptions.isEmpty || s.subscriptions.first.subscriber.isEmpty
        ? '—'
        : s.subscriptions.first.subscriber;
    final String subNote = s.subscriptions.length > 1
        ? '（+${s.subscriptions.length - 1}）'
        : '';
    // 团队分组摘要：`team（n）`，多个用「、」连；没有订阅者时不显示这一行。
    final String teamSummary = s.subscribersByTeam.entries
        .map(
          (MapEntry<String, int> e) =>
              '${e.key.isEmpty ? '未标团队' : e.key}（${e.value}）',
        )
        .join('、');
    const List<String> countKeys = <String>[
      'requests',
      'responded',
      'timeout',
      'cancelled',
      'no_subscriber',
      'overflow',
      'handler_error',
    ];
    final List<Widget> countPills = <Widget>[];
    for (final String k in countKeys) {
      final int? v = s.counts[k];
      if (v != null) {
        countPills.add(_pill(cs, '$k: $v'));
      }
    }
    if (s.waitsInFlight != null) {
      countPills.add(_pill(cs, '等待中: ${s.waitsInFlight}'));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.stationId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (kindLabel.isNotEmpty) ...[
                _pill(cs, kindLabel, emphasize: true),
                const SizedBox(width: 6),
              ],
              if (s.builtin) _pill(cs, '内置'),
            ],
          ),
          if (s.description.isNotEmpty)
            Text(
              s.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Text(
            '订阅（${s.subscriberCount}）: $subscriber$subNote',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          if (teamSummary.isNotEmpty)
            Text(
              '团队: $teamSummary',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          if (countPills.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: countPills),
          ],
        ],
      ),
    );
  }

  /// 插件实例段的空态说明。
  ///
  /// 用户实机反馈（截图）：「插件实例（0）／暂无插件实例」没说清**插件配在哪**。
  /// 插件来自快照里的配置文件（config.path，默认 <数据根>/config/plugins.yaml），
  /// 所以这里直接把路径写出来，并说明"改完要重启核心"。路径缺失（旧核心 / 未接入
  /// 总线）时退回原来那句，不臆测路径。
  String _instancesEmptyText(PluginSnapshot snap) {
    final String path = snap.pluginConfigPath;
    if (path.isEmpty) {
      return '暂无插件实例';
    }
    return '暂无插件实例\n插件配置在 $path（可直接编辑，保存后重启核心生效）';
  }

  /// 站点段的空态说明（可直接照做的文案）。
  ///
  /// 站点全局化后的口径：**每类站全局只有一个实例**（广播 / 执行 / 中转在核心启动
  /// 时就位，收集站由接入点需要时现建），team / agent / session / mode 是**每次交互
  /// 携带的信封**，不再是站点维度。真的为空只剩一种情况：数据来自没有预建逻辑的
  /// 旧核心（正常核心启动后至少有三站）。
  String _stationsEmptyText(PluginSnapshot snap) {
    final StringBuffer buffer = StringBuffer(
      '暂无站点实例。'
      '内置四站（广播 / 执行 / 中转 / 收集）**全局各一个**：前三站在核心启动时'
      '自动就位，收集站由接入点（如插件申报工具）需要时现建；'
      'team / session / agent 随每次交互携带，不再把站点按团队拆开。',
    );
    final String path = snap.pluginConfigPath;
    if (path.isNotEmpty) {
      buffer.write('\n插件配置：$path');
    }
    return buffer.toString();
  }

  /// 状态文本（未知状态原样展示、不崩）。
  Widget _statusLabel(ColorScheme cs, String status) {
    final String label;
    final Color color;
    switch (status) {
      case 'registered':
        label = '已注册';
        color = Colors.green;
        break;
      case 'disabled':
        label = '已停用';
        color = cs.error;
        break;
      case 'destroyed':
        label = '已销毁';
        color = cs.onSurfaceVariant;
        break;
      default:
        label = status.isEmpty ? '未知' : status;
        color = cs.onSurfaceVariant;
        break;
    }
    return Text(label, style: TextStyle(fontSize: 11, color: color));
  }

  /// 小圆角标签。
  ///
  /// [color] 覆盖文字色（如降级用橙色）；[emphasize] 给"当前态"标签上底色。
  Widget _pill(
    ColorScheme cs,
    String text, {
    bool emphasize = false,
    Color? color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: emphasize ? cs.primaryContainer : null,
        border: emphasize ? null : Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color:
              color ??
              (emphasize ? cs.onPrimaryContainer : cs.onSurfaceVariant),
        ),
      ),
    );
  }

  /// 区块标题。
  Widget _sectionTitle(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 区块空提示。
  Widget _emptyHint(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// scope 摘要（仅展示非空维度；空则 '—'）。
  ///
  /// **mode_key 必须显示**（M9 §1.2）：local / ssh 是站点隔离的关键维度，
  /// 同一个团队在两个工作面上是两个不同实例（id 就带 @local / @ssh）——
  /// 面板上看不出模式，用户就无法理解"为什么有两个广播站"。
  String _scopeSummary(Map<String, dynamic> scope) {
    final List<String> parts = <String>[];
    for (final String k in <String>[
      'team_id',
      'agent_id',
      'session_id',
      'mode_key',
    ]) {
      final String v = (scope[k] ?? '').toString();
      if (v.isNotEmpty) {
        parts.add('$k=$v');
      }
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 相对时间（epoch 秒 → 'Ns 前' / 'Nmin 前' / 'Nh 前' / 日期）。
  String _relativeTime(double? ts) {
    if (ts == null) {
      return '—';
    }
    final DateTime t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    final Duration diff = DateTime.now().difference(t);
    if (diff.inSeconds >= 0 && diff.inSeconds < 60) {
      return '${diff.inSeconds}s 前';
    }
    if (diff.inMinutes >= 0 && diff.inMinutes < 60) {
      return '${diff.inMinutes}min 前';
    }
    if (diff.inHours >= 0 && diff.inHours < 24) {
      return '${diff.inHours}h 前';
    }
    return t.toLocal().toString().split('.').first;
  }
}
