import 'package:flutter/material.dart';

import '../../io/plugin_monitor_service.dart';
import '../services/detail_selection.dart';
import 'plugin_panel.dart';

/// 插件 / 站点的**详情页**（面板卡片点进去的那一层）。
///
/// 两个页面放在同一个文件里：它们共用同一套版式（区块标题、描边卡片、键值行、占位
/// 文案），拆成两个文件就会长出两份一模一样的私有 widget；而这两个页面各自只有一个
/// 入口（插件面板的卡片），没有独立复用的需求。
///
/// 数据口径（详情页不"猜"，缺什么就说什么缺）：
/// - **插件介绍**读清单里的 `description`（落盘 plugins.yaml）。刻意不取协议握手里的
///   说明：`initialize` 只在插件连上之后才有，而**启动失败的插件最需要介绍**；
/// - **工具表**读快照实例（对账出来的运行态）：插件没运行就是空表，页面据此写
///   「未提供工具」，而不是假装它有能力；
/// - **站点详情**必须重新 GET 一次：卡片上那份来自 WS 节流的快照（可能滞后），而
///   「禁用订阅者 / 改配置」要落在当前真值上；核心给的 404 / 400 原因原样显示。
///
/// 写操作（C 起详情页是**管理台**，不再只是只读页）：
/// - 站点页：可订阅数量 / 订阅者禁用 / 自定义配置，外加**站点启用 / 停用**（默认启用，
///   改后 PATCH 落 `config/stations.yaml`）；
/// - 插件页：发布仓库的「从仓库装它 / 从仓库更新」（A+）+ **管理按钮区**（C 起：
///   启用 / 停用 / 卸载 / 重启 / 热重启 / 编辑）。
///
/// 编辑仍然只有面板那一颗入口：字段校验与拉起进程的安全二次确认全在
/// [PluginEditorDialog] 里，页面自己复述一遍就会分叉——所以「编辑」按钮经
/// [PluginDetailPage.onEdit] 交回面板去开**同一个**弹窗。面板不传 admin 时
/// 这些区块都不渲染，页面退回全只读（旧调用方与测试不用改）。
Widget _sectionTitle(BuildContext context, String text) => Text(
  text,
  style: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

/// 详情页的区块（标题 + 内容）：两个页面共用间距与字号。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _sectionTitle(context, title),
          const SizedBox(height: 6),
          ...children.map(
            (Widget child) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 区块下方的弱说明行（口径 / 后果）。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}

/// 带「口径说明」的区块：note 当成内容的最后一项，这样 `_Section` 只剩一个
/// widget 列表参数（linter 要求 `children` 收尾，参数排在其后就违反规则）。
Widget _sectionWithNote({
  required String title,
  required List<Widget> children,
  String? note,
}) => _Section(
  title: title,
  children: <Widget>[
    ...children,
    if (note != null && note.trim().isNotEmpty) _Note(note),
  ],
);

/// 一张描边卡片（与面板卡片同款视觉：边框 + 圆角 8 + padding 10）。
class _Card extends StatelessWidget {
  const _Card({required this.children, this.borderColor});

  final List<Widget> children;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
          color: borderColor ?? Theme.of(context).dividerColor,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// 一行「标签 + 值」（值为空 ⇒ 显示「—」，不臆测）。
class _Kv extends StatelessWidget {
  const _Kv({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: TextStyle(fontSize: 12, color: color ?? cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

/// 启停状态（`status`）的中文名（面板卡片与详情页共用，**口径必须一致**）。
///
/// 认不出的值原样显示（旧核心 / 新枚举都不能崩，也不能翻译成"未知"之外的小动作）。
///
/// 注意：这里的"生命周期"只回答**配置上要不要跑**（registered / disabled）；
/// “现在处在阶段 2 的哪一段”是 [pluginLifecycleText] 的事（`lifecycle`），
/// “还听得见吗”是健康度（`health`）——**三个轴各管各的，谁也不得吃掉谁**。
String pluginStatusText(String status) {
  switch (status) {
    case 'registered':
      return '已注册';
    case 'disabled':
      return '已停用';
    case 'destroyed':
      return '已销毁';
    default:
      return status.isEmpty ? '未知' : status;
  }
}

/// 插件**生命周期阶段**（`lifecycle`）的中文名（面板卡片与详情页共用）。
///
/// 与 [pluginStatusText] / 健康度是**三个独立的轴**：`restarting` 时 `status` 仍是
/// `registered`、`health` 仍可能是 `ok` —— 所以这里只能说“重启中”，绝不能翻译成
/// “已停用”或“降级”（那会把一个安排内的动作报成事故）。缺失（旧核心）⇒ “未知”，
/// 不臆测；认不出的值原样显示（新核心发新阶段时前端不能崩）。
String pluginLifecycleText(String lifecycle) {
  switch (lifecycle) {
    case PluginInstanceInfo.lifecycleRestarting:
      return '重启中';
    case PluginInstanceInfo.lifecycleSuspended:
      return '已挂起';
    case PluginInstanceInfo.lifecycleBooting:
      return '启动中';
    case PluginInstanceInfo.lifecycleReady:
      return '就绪';
    case PluginInstanceInfo.lifecycleFailed:
      return '失败';
    case 'stopped':
      return '未运行';
    default:
      return lifecycle.isEmpty ? '未知（核心未提供生命周期）' : lifecycle;
  }
}

/// 把 scope 四元组拼成一行（只列非空维度；全空 ⇒ 「—」）。
String detailScopeText(Map<String, dynamic> scope) {
  final List<String> parts = <String>[];
  for (final String key in <String>[
    'team_id',
    'agent_id',
    'session_id',
    'mode_key',
  ]) {
    final String v = (scope[key] ?? '').toString();
    if (v.isNotEmpty) {
      parts.add('$key=$v');
    }
  }
  return parts.isEmpty ? '—' : parts.join(' · ');
}

// ── 插件详情页 ──────────────────────────────────────────────────────────────

/// 插件详情页：**这个插件是什么、能做什么、现在怎么样，以及对它动手**。
///
/// 数据由面板已有的两份（清单 + 快照）传入；写操作走可选的 [admin]（A+ 的仓库
/// 安装 + C 的管理按钮区），null ⇒ 与旧口径一致的全只读页。
///
/// 页面由面板经 `DetailSelection.inject` **注入右栏 DetailPanel**（C 起不再
/// Navigator.push 全屏），所以 AppBar 上有显式关闭按钮——注入态没有路由可返回。
class PluginDetailPage extends StatelessWidget {
  const PluginDetailPage({
    super.key,
    required this.pluginId,
    this.name = '',
    this.intro = '',
    this.isBuiltin = false,
    this.entry = const <String, dynamic>{},
    this.runtime = const <String, dynamic>{},
    this.resolution,
    this.instance,
    this.stations = const <PluginStationInfo>[],
    this.onOpenStation,
    this.admin,
    this.onInstalled,
    this.onEdit,
    this.onChanged,
  });

  /// 插件 id（清单与快照的公共键）
  final String pluginId;

  /// 展示名（可能为空 ⇒ 回退 id）
  final String name;

  /// 介绍正文（清单里的 `description`；空串 = 插件没写过）
  final String intro;

  final bool isBuiltin;

  /// 落盘的清单条目（命令 / 参数 / 粒度 / scope / enabled）
  final Map<String, dynamic> entry;

  /// 这一条的运行态（id → running / health / reason / error / known）
  final Map<String, dynamic> runtime;

  /// 内置项的运行时解析结果（非内置为 null）
  final Map<String, dynamic>? resolution;

  /// 快照里的实例（工具表与心跳健康度的来源；未运行 = null）
  final PluginInstanceInfo? instance;

  /// 快照里的全部站点（本页按 id 前缀与订阅者筛出与这个插件相关的两条线）
  final List<PluginStationInfo> stations;

  /// 点站点行时跳转（由面板负责注入站点详情页：页面自己不认识路由）
  final void Function(String stationId)? onOpenStation;

  /// 发布仓库读写通道（非空 ⇒ 渲染「发布仓库」区块与管理按钮区；null = 全只读）
  final PluginAdminClient? admin;

  /// 从仓库装/更新成功后的回调（面板拿它重拉清单 + 快照；页面自己不持有面板状态）
  final Future<void> Function()? onInstalled;

  /// 「编辑」按钮：交回面板开**同一个** [PluginEditorDialog]（字段校验与拉起进程的
  /// 安全二次确认只有一处实现）。null ⇒ 按钮不渲染。
  final Future<void> Function()? onEdit;

  /// 管理按钮（启用 / 停用 / 卸载 / 重启 / 热重启）写成功后的回调：面板重拉清单
  /// 并重新注入本页（否则详情页停在写之前的旧条目上）。null ⇒ 只发请求不回刷。
  final Future<void> Function()? onChanged;

  bool get _hasRuntime {
    if (runtime.isNotEmpty || instance != null) {
      return true;
    }
    // 内置项即使没运行也会有「已停用 / 未运行」这类事实要讲，空表不算有运行态。
    return false;
  }

  /// 它建的站点：插件自建站 id 的命名空间是 `plugin.<插件 id>.<kind>.<name>`（核心拼装）。
  List<PluginStationInfo> get _ownedStations => stations
      .where(
        (PluginStationInfo s) => s.stationId.startsWith('plugin.$pluginId.'),
      )
      .toList(growable: false);

  /// 它订阅了的站点（订阅者身份里带 plugin_id）。
  List<PluginStationInfo> get _subscribedStations => stations
      .where(
        (PluginStationInfo s) => s.subscriptions.any(
          (PluginStationSub sub) => sub.pluginId == pluginId,
        ),
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<PluginToolBrief> tools = instance?.tools ?? const <PluginToolBrief>[];
    final List<PluginStationInfo> owned = _ownedStations;
    final List<PluginStationInfo> subscribed = _subscribedStations;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          name.isEmpty ? pluginId : name,
          style: const TextStyle(fontSize: 15),
        ),
        actions: <Widget>[
          // 注入态没有路由可返回（C 起不再 push），关闭只能显式给按钮。
          IconButton(
            key: const Key('plugin-detail-close'),
            tooltip: '关闭详情',
            iconSize: 18,
            onPressed: () => DetailSelection.instance.clear(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: <Widget>[
          // 管理按钮区（C）：放在最前——进详情页多半是来动手的，不是来读介绍的。
          if (admin != null)
            _sectionWithNote(
              title: '管理',
              children: <Widget>[
                _PluginManageActions(
                  admin: admin!,
                  pluginId: pluginId,
                  isBuiltin: isBuiltin,
                  entry: entry,
                  onEdit: onEdit,
                  onChanged: onChanged,
                ),
              ],
              note: entry.isEmpty
                  ? (isBuiltin
                        // 内置项不随主包分发：成品要从发布仓库拉（下面那一块），
                        // 装好条目落盘，这里才有开关与卸载。
                        ? '内置项不随主包分发：还没落盘条目时先到下面的「发布仓库」'
                              '「从仓库装它」，装好条目落盘后再回来启用 / 卸载。'
                        : '这条只有运行实例、没有落盘条目，只能重启'
                              '（开关与卸载要对着 plugins.yaml 里的条目）。')
                  : (isBuiltin
                        ? '卸载只删成品文件，条目保留并停用（回到「待从仓库装」，可随时装回）。'
                        : '卸载会停用并删除这条落盘条目；改字段请走「编辑」。'),
            ),
          _Section(
            title: '介绍',
            children: <Widget>[
              SelectableText(
                intro.isEmpty
                    ? '这个插件没有写介绍。'
                          '点卡片上的「编辑」，在「介绍」里补一段（落盘 plugins.yaml 的 description）。'
                    : intro,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: intro.isEmpty ? cs.onSurfaceVariant : cs.onSurface,
                ),
              ),
            ],
          ),
          _sectionWithNote(
            title: '基本信息',
            children: <Widget>[
              _Card(
                children: <Widget>[
                  _Kv(label: '插件 id', value: pluginId),
                  _Kv(label: '展示名', value: name),
                  _Kv(label: '归属', value: isBuiltin ? '内置插件' : '自定义插件'),
                  _Kv(
                    label: '启用',
                    value: entry.isEmpty
                        ? ''
                        : (entry['enabled'] != false ? '已启用' : '已停用（条目保留）'),
                  ),
                  _Kv(label: '实例粒度', value: (entry['granularity'] ?? '').toString()),
                  _Kv(
                    label: 'scope',
                    value: detailScopeText(
                      entry['scope'] is Map
                          ? Map<String, dynamic>.from(
                              entry['scope'] as Map,
                            )
                          : const <String, dynamic>{},
                    ),
                  ),
                  _Kv(label: '命令', value: _commandText()),
                  // 来源（阶段 5）：只在条目真带了那两个键时才出现。手写的自定义条目
                  // 没它们 ⇒ 整行不渲染（而不是显示一个空值，那让人以为是 bug）。
                  if (_sourceText().isNotEmpty)
                    _Kv(label: '来源', value: _sourceText()),
                ],
              ),
            ],
            note: isBuiltin
                ? '内置插件的命令与脚本路径由核心解析，开关与编辑都只影响这一项。'
                : '改这些字段请用卡片上的「编辑」（保存后立即热应用，失败时会如实提示）。',
          ),
          if (resolution != null)
            _Section(
              title: '内置运行时',
              children: <Widget>[
                _Card(
                  borderColor: resolution!['ok'] == true
                      ? cs.outlineVariant
                      : cs.error,
                  children: <Widget>[_Kv(label: '解析结果', value: _resolutionText())],
                ),
              ],
            ),
          // A+：内置项缺成品（或想拿新版）时的就地入口。面板不传 admin ⇒ 整块不渲染，
          // 页面回到"全程只读"的旧口径（旧调用方与测试不用改）。
          if (isBuiltin && admin != null)
            _sectionWithNote(
              title: '发布仓库',
              children: <Widget>[
                _RepoInstallAction(
                  admin: admin!,
                  pluginId: pluginId,
                  // 解析不到成品 ⇒ 缺货（「从仓库装它」）；否则「从仓库更新」——
                  // 与面板卡片那颗按钮同一判据（resolution.ok）。
                  needsArtifact: resolution == null || resolution!['ok'] != true,
                  onInstalled: onInstalled,
                ),
              ],
              note: '装它会先自动刷新发布索引再安装；失败原因就地显示在按钮下方。',
            ),
          _sectionWithNote(
            title: '运行态',
            children: <Widget>[
              _Card(
                children: _hasRuntime
                    ? <Widget>[
                        _Kv(
                          label: '状态',
                          value: instance != null
                              ? pluginStatusText(instance!.status)
                              : (runtime['running'] == true
                                    ? '运行中'
                                    : '未运行'),
                        ),
                        _Kv(label: '健康度', value: _healthText()),
                        _Kv(label: '生命周期', value: _lifecycleText()),
                        _Kv(label: '停用原因', value: instance?.disabledReason ?? ''),
                        if ((runtime['error'] ?? '').toString().isNotEmpty)
                          _Kv(
                            label: '启动失败',
                            value: runtime['error'].toString(),
                            color: cs.error,
                          ),
                      ]
                    : <Widget>[
                        Text(
                          '当前没有这个插件的运行实例（未启动、已停用，或数据来自还没有'
                          '快照的旧核心）。介绍与配置仍在上方照常可看。',
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
              ),
            ],
            note: '心跳降级 ≠ 停用：降级只表示连续几拍没收到心跳，插件仍注册运行。\n'
                '活性看健康度、启停看状态、阶段看生命周期（三个轴各管各的）：'
                '「重启中」是安排内的一世交替，不是故障，也不是停用。',
          ),
          _sectionWithNote(
            title: '提供的工具（${tools.length}）',
            children: tools.isEmpty
                ? <Widget>[
                    Text(
                      '未提供工具（插件未运行，或确实没有申报工具）。',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ]
                : <Widget>[
                    for (final PluginToolBrief tool in tools)
                      _Card(
                        children: <Widget>[
                          Text(
                            tool.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (tool.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                tool.description,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
            note: '工具表是对账出来的运行态：插件没连上核心时这里就是空的。',
          ),
          _sectionWithNote(
            title: '它建的站点（${owned.length}）',
            children: owned.isEmpty
                ? <Widget>[_stationEmpty(cs, '这个插件没有自建站点。')]
                : <Widget>[
                    for (final PluginStationInfo s in owned)
                      _StationRow(
                        station: s,
                        onTap: () => onOpenStation?.call(s.stationId),
                      ),
                  ],
            note: '插件自建站 id 形如 plugin.<插件 id>.<kind>.<name>，建站方必须给 readme。',
          ),
          _sectionWithNote(
            title: '它订阅的站点（${subscribed.length}）',
            children: subscribed.isEmpty
                ? <Widget>[_stationEmpty(cs, '这个插件没有订阅任何站点。')]
                : <Widget>[
                    for (final PluginStationInfo s in subscribed)
                      _StationRow(
                        station: s,
                        badge: _mySubscriptionNote(s),
                        onTap: () => onOpenStation?.call(s.stationId),
                      ),
                  ],
            note: '订阅是"声明我要收哪类消息"；被站点所有者禁用时仍保留订阅，只是不投递。',
          ),
        ],
      ),
    );
  }

  /// 命令行（命令 + 参数原样拼出来，与「编辑」弹窗二次确认时看到的保持一致）。
  String _commandText() {
    final String command = (entry['command'] ?? '').toString();
    if (command.isEmpty) {
      return '';
    }
    final List<String> args = <String>[
      for (final Object? a in (entry['args'] as List<dynamic>? ?? <dynamic>[]))
        a.toString(),
    ];
    return args.isEmpty ? command : '$command ${args.join(' ')}';
  }

  /// 发布仓库来源（条目上的 `source` + `repo_version`）；本机自己加的 = 空串。
  ///
  /// 这两个键**只是展示用**：行为（怎么拉起、能不能挂起）一律只读已知键，所以它们
  /// 写坏了也不会让插件起不来（这也是为什么允许它们作为未知键留在盘上）。
  String _sourceText() {
    final String source = (entry['source'] ?? '').toString().trim();
    final String repoVersion = (entry['repo_version'] ?? '').toString().trim();
    if (source.isEmpty && repoVersion.isEmpty) return '';
    final String label = source == 'release'
        ? '发布仓库（只拉 GitHub Release 资产）'
        : source;
    return repoVersion.isEmpty ? label : '$label · 已装 $repoVersion';
  }

  String _resolutionText() {
    final Map<String, dynamic> spec = resolution!;
    if (spec['ok'] == true) {
      return '运行时 ${spec['command']} · 脚本 ${spec['script_path']}';
    }
    return '运行时未就绪：${spec['error'] ?? '未知原因'}';
  }

  /// 生命周期一行（阶段 2 新增的第三个轴）。
  ///
  /// 数据源与状态/健康度分开：`lifecycle` 是**新增的可选键**，旧核心没有 ⇒ 走
  /// [pluginLifecycleText] 的“未知”分支，绝不臆测成“未运行”（那会把一个装好的
  /// 插件讲成没跑）。代际只在真有值时附一句。
  String _lifecycleText() {
    final String lifecycle =
        instance?.lifecycle ?? (runtime['lifecycle'] ?? '').toString();
    final Object? rawGeneration = instance?.generation ?? runtime['generation'];
    final int? generation = rawGeneration is num ? rawGeneration.toInt() : null;
    final String text = pluginLifecycleText(lifecycle);
    return generation == null || generation <= 0
        ? text
        : '$text（第 $generation 代）';
  }

  /// 健康度一行（未知就写未知，不翻译）。
  String _healthText() {
    final String health = instance?.health ?? (runtime['health'] ?? '').toString();
    if (health.isEmpty) {
      return '未知（核心未提供健康度）';
    }
    final int? missed = instance?.missedHeartbeats;
    final String suffix = missed != null && missed > 0 ? '（丢失 $missed 拍）' : '';
    switch (health) {
      case PluginInstanceInfo.healthOk:
        return '正常';
      case PluginInstanceInfo.healthDegraded:
        final String reason = instance?.degradedReason ??
            (runtime['reason'] ?? '').toString();
        return reason.isEmpty
            ? '心跳降级$suffix（仍注册运行，非停用）'
            : '心跳降级$suffix：$reason（仍注册运行，非停用）';
      case PluginInstanceInfo.healthUnavailable:
        return '宿主不可用（未启动 / 已断开）';
      default:
        return health;
    }
  }

  /// 我在这个站点上的订阅状态（多实例粒度时可能有多条，逐条列出）。
  String _mySubscriptionNote(PluginStationInfo station) {
    final List<PluginStationSub> mine = station.subscriptions
        .where((PluginStationSub sub) => sub.pluginId == pluginId)
        .toList(growable: false);
    if (mine.isEmpty) {
      return '';
    }
    return mine
        .map(
          (PluginStationSub sub) =>
              '${sub.granularity.isEmpty ? 'team' : sub.granularity} 粒度'
              '${sub.disabled ? '（已禁用）' : ''}',
        )
        .join(' · ');
  }

  Widget _stationEmpty(ColorScheme cs, String text) => Text(
    text,
    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
  );
}

/// 详情页里的「从仓库装它 / 从仓库更新」按钮（A+）：内置项缺成品时的就地入口。
///
/// 流程与面板卡片那颗同口径（见 plugin_panel._installFromRepo）：**先自动刷新索引，
/// 再 install**——用户不该先去面板下面那一节点「刷新」再回来找这一条。失败原因
/// **就地**显示在按钮下方（不只是一条转瞬即逝的 snack）：刷新失败、索引里没有这一条、
/// 安装被换文件闸门拦住都算。
///
/// 自带 busy/error 状态（页面本体保持 StatelessWidget）：这颗按钮是页面上唯一的
/// 异步写操作，状态跟着按钮走比给整页升格更省事。
class _RepoInstallAction extends StatefulWidget {
  const _RepoInstallAction({
    required this.admin,
    required this.pluginId,
    required this.needsArtifact,
    this.onInstalled,
  });

  final PluginAdminClient admin;
  final String pluginId;

  /// true = 本机缺成品 ⇒ 「从仓库装它」；false = 已装 / 有更新 ⇒ 「从仓库更新」。
  final bool needsArtifact;

  /// 装成功后的回调（面板重拉清单 + 快照）。
  final Future<void> Function()? onInstalled;

  @override
  State<_RepoInstallAction> createState() => _RepoInstallActionState();
}

class _RepoInstallActionState extends State<_RepoInstallAction> {
  bool _busy = false;

  /// 就地失败原因（非空 ⇒ 按钮下方红字；清空时机 = 下一次点按钮 / 装成功）。
  String _error = '';

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      // ① 先刷新：装机端要的是**最新索引**（缓存那份可能还没有这一条，或版本旧）。
      final Map<String, dynamic> refreshed = await widget.admin.refreshRelease();
      final String refreshError = (refreshed['error'] ?? '').toString();
      List<Map<String, dynamic>> entries = _mapList(refreshed['entries']);
      if (refreshed['ok'] == false) {
        // 刷新失败不清空：核心把上一次那份递在 cached 里，里面**有**这一条就还能装
        // （“今晚限流”不该变成“什么都装不了”）。
        final Object? cached = refreshed['cached'];
        if (cached is Map) {
          entries = _mapList(cached['entries']);
        }
      }
      // ② 索引里没有这一条（仓库还没发 / 刷新后仍是旧索引）⇒ 就地说明，不发 install。
      final bool known = entries.any(
        (Map<String, dynamic> e) =>
            (e['plugin_id'] ?? '').toString() == widget.pluginId,
      );
      if (!known) {
        setState(() {
          _error = refreshError.isEmpty
              ? '索引里没有 ${widget.pluginId} 这一条'
                    '（发布仓库还没发它，或刷新后仍是旧索引）'
              : '刷新索引失败：$refreshError'
                    '（缓存里也没有 ${widget.pluginId} 这一条）';
        });
        return;
      }
      // ③ install（核心失败会抛成带原因的异常，下面 catch 里就地显示）。
      final Map<String, dynamic> result = await widget.admin.installRelease(
        widget.pluginId,
      );
      if (!mounted) return;
      setState(() => _error = '');
      final Object? install = result['install'];
      final String version = install is Map
          ? (install['version'] ?? '').toString()
          : '';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            version.isEmpty
                ? '已从发布仓库安装 ${widget.pluginId}'
                : '已从发布仓库安装 ${widget.pluginId}（$version）',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      await widget.onInstalled?.call();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _reason(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static List<Map<String, dynamic>> _mapList(Object? raw) => raw is List
      ? <Map<String, dynamic>>[
          for (final Object? item in raw)
            if (item is Map) Map<String, dynamic>.from(item),
        ]
      : <Map<String, dynamic>>[];

  static String _reason(Object error) =>
      '$error'.replaceFirst('Exception: ', '');

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return _Card(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                widget.needsArtifact
                    ? '本机还没有这一份成品，可从发布仓库装'
                    : '发布仓库里有它（可装最新版）',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            TextButton(
              key: Key('plugin-detail-repo-${widget.pluginId}'),
              onPressed: _busy ? null : _run,
              child: Text(
                _busy
                    ? '正在处理…'
                    : (widget.needsArtifact ? '从仓库装它' : '从仓库更新'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (_error.isNotEmpty)
          Text(
            _error,
            key: Key('plugin-detail-repo-error-${widget.pluginId}'),
            style: TextStyle(fontSize: 11, color: cs.error),
          ),
      ],
    );
  }
}

/// 详情页的**管理按钮区**（C）：启用 / 停用 · 重启 · 热重启 · 编辑 · 卸载。
///
/// 分工与面板卡片那排按钮完全一致（同一套 [PluginAdminClient] 写面），页面不复述
/// 任何核心判定：核心拒了就把 400 的中文原因**就地**显示在按钮下方（不是一条
/// 转瞬即逝的 snack）——「内置站不可改」「等不到退出确认」这类话必须留在屏幕上。
///
/// 自带 busy / 本地启用态 / 错误态（页面本体保持 StatelessWidget，与
/// [_RepoInstallAction] 同一个理由）：这是页面上唯一一组异步写操作，状态跟着按钮走。
/// 本地启用态在写成功后立即翻转，同时经 [PluginDetailPage.onChanged] 让面板重拉并
/// 重新注入本页——两边都会刷新，按钮不会停在旧值上。
class _PluginManageActions extends StatefulWidget {
  const _PluginManageActions({
    required this.admin,
    required this.pluginId,
    required this.isBuiltin,
    required this.entry,
    this.onEdit,
    this.onChanged,
  });

  final PluginAdminClient admin;
  final String pluginId;
  final bool isBuiltin;

  /// 落盘条目（空 = 只有运行实例没有条目：开关与卸载都没有对象，只留重启）。
  final Map<String, dynamic> entry;

  final Future<void> Function()? onEdit;
  final Future<void> Function()? onChanged;

  @override
  State<_PluginManageActions> createState() => _PluginManageActionsState();
}

class _PluginManageActionsState extends State<_PluginManageActions> {
  bool _busy = false;

  /// 本地启用态（写成功才翻；数据源是构造时的 entry，写后由 onChanged 重注入对齐）。
  late bool _enabled;

  /// 就地失败原因（非空 ⇒ 按钮下方红字；清空时机 = 下一次点任何一颗按钮）。
  String _error = '';

  @override
  void initState() {
    super.initState();
    _enabled = widget.entry['enabled'] != false;
  }

  /// 一次写操作：成功 ⇒ 显示回包结果并回调面板回刷；失败 ⇒ 原因就地显示。
  /// 返回是否成功（卸载靠它决定要不要关掉详情页）。
  Future<bool> _run(
    Future<Map<String, dynamic>> Function() action, {
    String successText = '',
    String Function(Map<String, dynamic> result)? successFrom,
  }) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final Map<String, dynamic> result = await action();
      if (!mounted) return false;
      // 热应用失败的话术必须如实显示（「配置已保存，但本次热应用失败…」），
      // 否则等于骗用户"已经生效了"。
      final String notice = (result['notice'] ?? '').toString();
      final String detail = (result['hot_apply_detail'] ?? '').toString();
      final String text = successFrom == null ? successText : successFrom(result);
      _snack(notice.isEmpty ? text : (detail.isEmpty ? notice : '$notice（$detail）'));
      await widget.onChanged?.call();
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = _reason(error));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 启用 / 停用：内置走 enable / disable 端点，自定义走 PATCH enabled（与面板同口径）。
  Future<void> _toggle() async {
    final bool next = !_enabled;
    final bool ok = await _run(
      () => widget.isBuiltin
          ? widget.admin.setBuiltinEnabled(widget.pluginId, enabled: next)
          : widget.admin.updateConfig(
              widget.pluginId,
              <String, dynamic>{'enabled': next},
            ),
      successText: next ? '已写入启用状态' : '已写入停用状态',
    );
    if (ok && mounted) setState(() => _enabled = next);
  }

  Future<void> _restart() => _run(
    () => widget.admin.restartConfig(widget.pluginId),
    successText: '已重启插件 ${widget.pluginId}',
  );

  /// 热重启：文案跟着回包的 `resumed` 走——“续上了”与“换了一世”是两件事（与面板同口径）。
  Future<void> _hotRestart() => _run(
    () => widget.admin.restartConfig(widget.pluginId, mode: 'hot'),
    successFrom: (Map<String, dynamic> result) => result['resumed'] == true
        ? '已热重启插件 ${widget.pluginId}，状态续到了第 ${result['generation'] ?? '?'} 代'
        : '已重启插件 ${widget.pluginId}，但按冷启动（目标没声明 suspension: keep '
              '或没递快照）：这不是失败，但状态确实没续上',
  );

  /// 卸载：先确认（不可逆动作），成功后关掉详情页——条目都没了，这一页没有对象。
  Future<void> _uninstall() async {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('卸载这个插件？'),
        content: Text(
          widget.isBuiltin
              ? '先停用并等它确认退出（不强杀），再删掉本机成品文件；'
                    '条目保留在 plugins.yaml 且为停用态，随时可「从仓库装」回。'
              : '先停用并等它确认退出（不强杀），再删掉成品文件并从 plugins.yaml '
                    '移除这条条目（不可撤销）。',
          style: const TextStyle(fontSize: 12),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('plugin-detail-uninstall-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final bool ok = await _run(
      () => widget.admin.uninstallRelease(widget.pluginId),
      successText: '已卸载 ${widget.pluginId}',
    );
    // 卸载成功 ⇒ 详情页失去对象，直接关掉（注入态没有路由可 pop，只能 clear）。
    if (ok && mounted) DetailSelection.instance.clear();
  }

  void _snack(String text) {
    if (text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  static String _reason(Object error) =>
      '$error'.replaceFirst('Exception: ', '');

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String id = widget.pluginId;
    final bool hasEntry = widget.entry.isNotEmpty;
    return _Card(
      children: <Widget>[
        Text(
          hasEntry
              ? (_enabled ? '当前已启用' : '当前已停用（条目保留）')
              : '当前没有落盘条目（只有运行实例）',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
        Wrap(
          spacing: 2,
          runSpacing: 0,
          children: <Widget>[
            if (hasEntry)
              TextButton(
                key: Key('plugin-detail-toggle-$id'),
                onPressed: _busy ? null : _toggle,
                child: Text(
                  _enabled ? '停用' : '启用',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            TextButton(
              key: Key('plugin-detail-restart-$id'),
              onPressed: _busy ? null : _restart,
              child: const Text('重启', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: Key('plugin-detail-hot-restart-$id'),
              onPressed: _busy ? null : _hotRestart,
              child: const Text(
                '热重启（保留状态）',
                style: TextStyle(fontSize: 12),
              ),
            ),
            if (hasEntry && widget.onEdit != null)
              TextButton(
                key: Key('plugin-detail-edit-$id'),
                onPressed: _busy ? null : () => widget.onEdit!.call(),
                child: const Text('编辑', style: TextStyle(fontSize: 12)),
              ),
            if (hasEntry)
              TextButton(
                key: Key('plugin-detail-uninstall-$id'),
                onPressed: _busy ? null : _uninstall,
                child: Text(
                  '卸载',
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
          ],
        ),
        if (_busy)
          Text(
            '正在处理…',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        if (_error.isNotEmpty)
          Text(
            _error,
            key: Key('plugin-detail-manage-error-$id'),
            style: TextStyle(fontSize: 11, color: cs.error),
          ),
      ],
    );
  }
}

/// 站点行（插件页里"它建的 / 它订阅的"两处共用；点一下进站点详情页）。
class _StationRow extends StatelessWidget {
  const _StationRow({required this.station, this.badge = '', this.onTap});

  final PluginStationInfo station;
  final String badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String kindLabel = station.displayKindLabel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _Card(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  station.stationId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (kindLabel.isNotEmpty)
                Text(
                  kindLabel,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              if (station.builtin)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '内置',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ),
            ],
          ),
          if (badge.isNotEmpty || station.subscriptions.isNotEmpty)
            Text(
              badge.isEmpty
                  ? '订阅者 ${station.subscriberCount} · ${detailScopeText(station.scope)}'
                  : '$badge · 订阅者 ${station.subscriberCount}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          if (station.introText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                station.introText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 站点详情页 ───────────────────────────────────────────────────────────────

/// 站点详情页：**这个站点是什么、最多能让谁订阅、现在谁在订阅（可禁用）、
/// 建站方还想说点什么**（后两项就是需求里的「其他：由站点自定义的配置信息」）。
///
/// 三条写口径（都是核心的规则，页面只是不复述判定）：
/// 1. **内置站只能改「可订阅插件数量」**（C 起 + 启用 / 停用）：介绍与自定义配置
///    在核心的点位表里，界面上改它等于把行为从代码摸到盘上，下次启动就被覆盖
///    回去——所以这一页把内置站的介绍与配置**只读**显示，并写清为什么；
/// 2. **禁用 ≠ 退订**：开关只让触发时不投递（核心计 `skipped_disabled`），
///    订阅关系与回包通道都留着，所以列表里那些「已禁用」的行仍在；
/// 3. 写成功后**直接用核心回的改后详情**刷新页面，不再发第二次 GET（少一次往返，
///    也就不会出现"界面比核心新"的假象）。
///
/// C 起的第四条写面是**站点启用 / 停用**（默认启用，缺键即启用）：改后 PATCH
/// `enabled` 落 `config/stations.yaml`，四类触发的第一道闸按可读原因跳过；
/// 这与第 2 条的「订阅者禁用」是两层开关（一个关站点、一个关某个订阅者的投递），
/// 谁也不覆盖谁。页面同样由面板注入右栏（不再 push），AppBar 带关闭按钮。
class StationDetailPage extends StatefulWidget {
  const StationDetailPage({
    super.key,
    required this.stationId,
    required this.admin,
    this.initial,
  });

  /// 站点 id（`system.*` / `plugin.tool.define` / `plugin.<插件 id>.<kind>.<name>`）
  final String stationId;

  /// 读写通道（真实走 REST；widget 测试注入假实现）
  final PluginAdminClient admin;

  /// 卡片上那一份快照数据（先渲染它再刷新：进页面不该看到一片空白）
  final PluginStationInfo? initial;

  @override
  State<StationDetailPage> createState() => _StationDetailPageState();
}

class _StationDetailPageState extends State<StationDetailPage> {
  PluginStationInfo? _info;

  /// 详情接口失败的原因（非空 ⇒ 顶部红条 + 重试按钮；不拿空数据渲染空白详情页）
  String? _loadError;

  /// 提交期间禁用全部写操作（连点会把两次 PATCH 交叉发出去）
  bool _busy = false;

  /// 「可订阅插件数量」输入框
  final TextEditingController _maxCtrl = TextEditingController();

  /// 「其他」区：每个已有键一个输入框（**键名不可改**——改键名等于换配置项）
  final Map<String, TextEditingController> _configCtrls =
      <String, TextEditingController>{};

  final TextEditingController _newKey = TextEditingController();
  final TextEditingController _newValue = TextEditingController();

  bool get _builtin => _info?.builtin ?? false;

  @override
  void initState() {
    super.initState();
    _info = widget.initial;
    _maxCtrl.text = _info?.maxSubscriptions?.toString() ?? '';
    _syncConfigCtrls(_info?.config ?? const <String, dynamic>{});
    _load();
  }

  @override
  void dispose() {
    _maxCtrl.dispose();
    _newKey.dispose();
    _newValue.dispose();
    for (final TextEditingController ctrl in _configCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  /// 拉详情：卡片那份可能来自节流的快照，而写操作要落在当前真值上。
  Future<void> _load() async {
    try {
      final Map<String, dynamic> detail = await widget.admin.stationDetail(
        widget.stationId,
      );
      if (!mounted) return;
      _apply(PluginStationInfo.tryParse(detail), error: null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = _reason(error));
    }
  }

  /// 用一份新详情替换本地状态（顺带把输入框同步到新值）。
  void _apply(PluginStationInfo? next, {String? error}) {
    setState(() {
      if (next != null) {
        _info = next;
        _maxCtrl.text = next.maxSubscriptions?.toString() ?? '';
        _syncConfigCtrls(next.config);
      }
      _loadError = error;
    });
  }

  void _syncConfigCtrls(Map<String, dynamic> config) {
    for (final String key in _configCtrls.keys.toList()) {
      if (!config.containsKey(key)) {
        _configCtrls.remove(key)!.dispose();
      }
    }
    for (final MapEntry<String, dynamic> entry in config.entries) {
      _configCtrls.putIfAbsent(
        entry.key,
        () => TextEditingController(text: _valueText(entry.value)),
      );
    }
  }

  /// 一次写操作：发请求 → 用核心回的**改后完整详情**替换本地状态 → 失败显示原因。
  Future<void> _write(
    Future<Map<String, dynamic>> Function() action, {
    required String successText,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> result = await action();
      final PluginStationInfo? parsed = PluginStationInfo.tryParse(result);
      if (parsed == null) {
        // 读不出 station_id 就是形状不对：不猜、不假装成功，让用户看得见。
        _snack('核心返回的站点详情读不出 station_id，请点右上角刷新');
      } else {
        _apply(parsed);
        _snack(successText);
      }
    } catch (error) {
      // 核心的 400 / 404 都带中文原因（内置站不可改 / 订阅者已退订），原样递给用户。
      _snack('操作失败：${_reason(error)}');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 站点启用 / 停用（C）：只发这一个键（局部 PATCH），改后详情回包刷新整页。
  Future<void> _toggleEnabled(bool enabled) => _write(
    () => widget.admin.patchStationConfig(
      widget.stationId,
      <String, dynamic>{'enabled': enabled},
    ),
    successText: enabled ? '已启用站点' : '已停用站点（订阅与配置保留）',
  );

  Future<void> _saveMax() {
    final String raw = _maxCtrl.text.trim();
    final int? value = int.tryParse(raw);
    if (value == null) {
      _snack('「可订阅插件数量」要写整数（0 或负数 = 不限制）');
      return Future<void>.value();
    }
    return _write(
      () => widget.admin.patchStationConfig(
        widget.stationId,
        <String, dynamic>{'max_subscriptions': value},
      ),
      successText: '已写入可订阅上限 $value',
    );
  }

  Future<void> _toggleSubscriber(PluginStationSub sub, bool enabled) => _write(
    // enabled = true ⇒ disabled: false（恢复投递）。
    () => widget.admin.setSubscriberDisabled(
      widget.stationId,
      sub.subscriber,
      disabled: !enabled,
    ),
    successText: enabled ? '已恢复 ${sub.pluginId} 的投递' : '已禁用 ${sub.pluginId}（订阅保留）',
  );

  /// 组装要写回的 config：**没改过的键沿用原值对象**（不改类型），改过的按字面量重识别。
  Map<String, dynamic> _collectConfig() {
    final Map<String, dynamic> original = _info?.config ?? const <String, dynamic>{};
    final Map<String, dynamic> out = <String, dynamic>{};
    original.forEach((String key, dynamic value) {
      final TextEditingController? ctrl = _configCtrls[key];
      if (ctrl == null) return;
      final String text = ctrl.text.trim();
      out[key] = text == _valueText(value) ? value : _coerceValue(text);
    });
    return out;
  }

  Future<void> _saveConfig() => _write(
    () => widget.admin.patchStationConfig(
      widget.stationId,
      <String, dynamic>{'config': _collectConfig()},
    ),
    successText: '已保存站点自定义配置',
  );

  Future<void> _addConfigEntry() {
    final String key = _newKey.text.trim();
    if (key.isEmpty) {
      _snack('请先写配置项的名字');
      return Future<void>.value();
    }
    if (_configCtrls.containsKey(key)) {
      _snack('已经有「$key」这一项了，直接在上面的输入框里改值就行');
      return Future<void>.value();
    }
    final Map<String, dynamic> next = _collectConfig()
      ..[key] = _coerceValue(_newValue.text);
    return _write(
      () => widget.admin.patchStationConfig(
        widget.stationId,
        <String, dynamic>{'config': next},
      ),
      successText: '已添加配置项 $key',
    );
  }

  Future<void> _removeConfigEntry(String key) {
    final Map<String, dynamic> next = _collectConfig()..remove(key);
    return _write(
      () => widget.admin.patchStationConfig(
        widget.stationId,
        <String, dynamic>{'config': next},
      ),
      successText: '已删除配置项 $key',
    );
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  static String _reason(Object error) =>
      '$error'.replaceFirst('Exception: ', '');

  /// 配置值的显示（Map / List 用 toString：这一区本来就是建站方自定义的原始数据）。
  static String _valueText(Object? value) => value?.toString() ?? '';

  /// 配置值的类型识别：整数 / 小数 / 布尔按字面量落回原类型，其余算字符串。
  ///
  /// 为什么要在前端识别：核心的 `config` 是原样落盘的键值映射，插件读到的就是这里
  /// 的类型。全部按字符串发回去会把 `route_limit: 8` 变成 `"8"`，插件那边一次
  /// `is int` 判定就静默失效——这类"改个数字就悄悄不干活"最难查。
  static Object _coerceValue(String raw) {
    final String v = raw.trim();
    final int? asInt = int.tryParse(v);
    if (asInt != null) return asInt;
    final double? asDouble = double.tryParse(v);
    if (asDouble != null) return asDouble;
    if (v == 'true') return true;
    if (v == 'false') return false;
    if (v.isEmpty) return '';
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final PluginStationInfo? info = _info;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.stationId,
          style: const TextStyle(fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            key: const Key('station-detail-refresh'),
            tooltip: '重新读取站点详情',
            iconSize: 18,
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            key: const Key('station-detail-close'),
            tooltip: '关闭详情',
            iconSize: 18,
            onPressed: () => DetailSelection.instance.clear(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: info == null
          ? _loadingOrError(cs)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: <Widget>[
                if (_loadError != null)
                  _banner(cs, '站点详情刷新失败：$_loadError（下方为最近一次数据）'),
                _sectionWithNote(
                  title: '站点介绍',
                  children: <Widget>[
                    SelectableText(
                      info.introText.isEmpty
                          ? '这个站点没有介绍（旧核心 / 旧存量数据没落 readme）。'
                                '插件自建站现在必填 readme：重新注册时带上就行。'
                          : info.introText,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: info.introText.isEmpty
                            ? cs.onSurfaceVariant
                            : cs.onSurface,
                      ),
                    ),
                  ],
                  note: info.readme.isEmpty && info.description.isNotEmpty
                      ? '（上面这一行是点位的短说明 description；建站方另写的 readme 会优先显示）'
                      : null,
                ),
                _Section(title: '基本信息', children: <Widget>[_basicsCard(cs, info)]),
                _sectionWithNote(
                  title: '启用状态',
                  children: <Widget>[
                    _Card(
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                info.enabled
                                    ? '已启用（四类触发照常投递）'
                                    : '已停用（触发以可读原因跳过，订阅与配置保留）',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: info.enabled
                                      ? cs.onSurface
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Switch(
                              key: const Key('station-detail-toggle'),
                              value: info.enabled,
                              onChanged: _busy ? null : _toggleEnabled,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                  note: '停用不删任何东西：广播 / 执行 / 中转 / 收集的触发会各自回报'
                      '「已停用」并计 skipped_disabled（中转站照旧放行原数据），'
                      '订阅关系与本页配置原样保留。',
                ),
                _sectionWithNote(
                  title: '站点可订阅插件数量',
                  children: <Widget>[_maxCard(info)],
                  note: '上限 ≤ 0 = 不限制。满了之后新订阅会被核心拒绝并计 overflow'
                      '（已订阅的不受影响）。',
                ),
                _sectionWithNote(
                  title: '已订阅插件管理（${info.subscriptions.length}）',
                  children: info.subscriptions.isEmpty
                      ? <Widget>[
                          _hint(
                            cs,
                            '还没有插件订阅这个站点（执行站按设计不接受订阅）。',
                          ),
                        ]
                      : <Widget>[
                          for (final PluginStationSub sub in info.subscriptions)
                            _subscriberCard(cs, sub),
                        ],
                  note: '开关只关掉「投递」：订阅关系与回包通道都保留，'
                      '被禁用的订阅者在核心计数里记为 skipped_disabled，不是消失。',
                ),
                _sectionWithNote(
                  title: '其他（站点自定义配置）',
                  children: <Widget>[_configCard(cs, info)],
                  note: _builtin
                      ? '内置站点的介绍与自定义配置在核心的点位表里，界面上只读'
                            '（这里能改的只有上面的「可订阅插件数量」）。'
                      : '键名不可改（改键名等于换配置项）；值按整数 / 小数 / 布尔自动识别，'
                            '其余按字符串。',
                ),
                _Section(
                  title: '计数',
                  children: <Widget>[_countsCard(cs, info)],
                ),
              ],
            ),
    );
  }

  /// 没有数据时的两种样子：还在读 ⇒ 转圈；读失败 ⇒ 说清原因并给重试。
  Widget _loadingOrError(ColorScheme cs) {
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '读不到站点 ${widget.stationId}：$_loadError',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.error),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('station-detail-retry'),
              onPressed: () {
                setState(() => _loadError = null);
                _load();
              },
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  Widget _banner(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        color: cs.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
        ),
      ),
    );
  }

  Widget _hint(ColorScheme cs, String text) => Text(
    text,
    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
  );

  /// 基本信息：类型 / 归属 / scope / 共享声明 / 团队分组。
  Widget _basicsCard(ColorScheme cs, PluginStationInfo info) {
    final String kindLabel = info.displayKindLabel;
    final String sharedText = !info.builtin && !info.shared
        ? '未共享（只有建站插件自己能订阅与触发）'
        : info.allowedPlugins.isEmpty
        ? '对所有插件开放'
        : '限白名单：${info.allowedPlugins.join('、')}';
    final String teams = info.subscribersByTeam.entries
        .map(
          (MapEntry<String, int> e) =>
              '${e.key.isEmpty ? '全部 team（未限定）' : e.key}（${e.value}）',
        )
        .join('、');
    return _Card(
      children: <Widget>[
        _Kv(
          label: '类型',
          value: kindLabel.isEmpty ? '${info.kind}（未知类型）' : kindLabel,
        ),
        _Kv(label: '归属', value: info.builtin ? '内置站点' : '插件自建站'),
        _Kv(label: 'scope', value: detailScopeText(info.scope)),
        _Kv(label: '跨插件共享', value: sharedText),
        _Kv(label: '订阅团队', value: teams),
      ],
    );
  }

  /// 可订阅数量：显示当前订阅数 + 一个整数输入框 + 保存。
  Widget _maxCard(PluginStationInfo info) {
    return _Card(
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              width: 104,
              child: Text(
                '当前订阅',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                '${info.subscriberCount} 个订阅者'
                '${info.disabledSubscriptions.isEmpty ? '' : '（其中 '
                        '${info.disabledSubscriptions.length} 个已禁用）'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('station-detail-max'),
                controller: _maxCtrl,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '可订阅插件数量上限',
                  helperText: '0 或负数 = 不限制',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('station-detail-save-max'),
              onPressed: _busy ? null : _saveMax,
              child: const Text('保存', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  /// 一条订阅：订阅者键位 + 粒度 + scope + 超时 + 投递开关。
  Widget _subscriberCard(ColorScheme cs, PluginStationSub sub) {
    final String timeout = sub.timeoutS == null ? '' : ' · 等待 ${sub.timeoutS}s';
    return _Card(
      borderColor: sub.disabled ? Colors.orange.withValues(alpha: 0.7) : null,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                sub.pluginId.isEmpty ? sub.subscriber : sub.pluginId,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              sub.disabled ? '已禁用' : '投递中',
              style: TextStyle(
                fontSize: 11,
                color: sub.disabled ? Colors.orange : Colors.green,
              ),
            ),
            Switch(
              key: Key('station-detail-sub-${sub.subscriber}'),
              value: !sub.disabled,
              onChanged: _busy
                  ? null
                  : (bool value) => _toggleSubscriber(sub, value),
            ),
          ],
        ),
        Text(
          '${sub.granularity.isEmpty ? 'team' : sub.granularity} 粒度 · '
          '${detailScopeText(sub.scope)}$timeout',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
        if (sub.subscriber.isNotEmpty && sub.pluginId.isNotEmpty)
          Text(
            '订阅键：${sub.subscriber}',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
      ],
    );
  }

  /// 「其他」区：内置只读，自建站可改值 / 加项 / 删项。
  Widget _configCard(ColorScheme cs, PluginStationInfo info) {
    final Map<String, dynamic> config = info.config;
    if (config.isEmpty && _builtin) {
      return _Card(
        children: <Widget>[_hint(cs, '这个内置点位没有自定义配置项。')],
      );
    }
    final List<Widget> rows = <Widget>[
      for (final MapEntry<String, dynamic> entry in config.entries)
        _configRow(cs, entry.key, entry.value),
    ];
    if (_builtin) {
      return _Card(
        children: <Widget>[...rows, if (rows.isEmpty) _hint(cs, '没有配置项。')],
      );
    }
    return _Card(
      children: <Widget>[
        ...rows,
        if (rows.isEmpty) _hint(cs, '建站方没有写配置项。'),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            TextButton(
              key: const Key('station-detail-save-config'),
              onPressed: _busy ? null : _saveConfig,
              child: const Text('保存配置', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const Divider(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('station-detail-new-key'),
                controller: _newKey,
                enabled: !_busy,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '新配置项名',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                key: const Key('station-detail-new-value'),
                controller: _newValue,
                enabled: !_busy,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '值',
                  isDense: true,
                ),
              ),
            ),
            TextButton(
              key: const Key('station-detail-add-config'),
              onPressed: _busy ? null : _addConfigEntry,
              child: const Text('添加', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  /// 一个配置项：键名 + 值输入框（内置只读 ⇒ 纯文本）+ 删除。
  Widget _configRow(ColorScheme cs, String key, Object? value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              key,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: _builtin
                ? SelectableText(
                    _valueText(value),
                    style: const TextStyle(fontSize: 12),
                  )
                : TextField(
                    key: Key('station-detail-config-$key'),
                    controller: _configCtrls[key],
                    enabled: !_busy,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(isDense: true),
                  ),
          ),
          if (!_builtin)
            IconButton(
              key: Key('station-detail-remove-$key'),
              tooltip: '删除这一项（保存时要点「保存配置」才落盘）',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : () => _removeConfigEntry(key),
              icon: Icon(Icons.close, size: 16, color: cs.error),
            ),
        ],
      ),
    );
  }

  /// 计数 + 在飞等待（未知键不显示，认不出的形状也不臆测）。
  Widget _countsCard(ColorScheme cs, PluginStationInfo info) {
    final List<Widget> lines = <Widget>[
      for (final MapEntry<String, int> entry in info.counts.entries)
        _Kv(label: entry.key, value: '${entry.value}'),
    ];
    if (info.waitsInFlight != null) {
      lines.add(_Kv(label: '等待中', value: '${info.waitsInFlight}'));
    }
    return _Card(
      children: lines.isEmpty
          ? <Widget>[_hint(cs, '还没有产生过交互（计数全空）。')]
          : lines,
    );
  }
}
