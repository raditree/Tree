import 'package:flutter/material.dart';

import '../../io/plugin_monitor_service.dart';

/// 插件面板（左侧活动栏「插件」页；只读）。
///
/// 数据源 = [PluginMonitorService]（REST 快照 + WS `plugin_status` 增量），
/// 显式三态：断连（重连中）/ 空（已连接、无实例与站）/ 错误（快照拉取失败）。
/// 渲染防御式：未知字段与未知状态一律忽略（不崩、不臆测）。
///
/// 健康度（M9 §1.1）：心跳连续丢失的实例打橙色「心跳降级」角标 + 一行说明，
/// 但状态标签**仍是「已注册」**——降级不是停用，别把两者混成一个状态。
///
/// 位于左栏时由活动栏承担标题，可传 [showHeader] = false 避免双标题。
///
/// 位于左栏时还应传 [onCollapse]：面板内容下方的空白区域可点击折叠左栏
/// （与 Agent 列表一致的交互）。
class PluginPanel extends StatefulWidget {
  /// 所属团队 ID（null / 空串 = 不过滤，展示当前用户可见全部实例）
  final String? teamId;

  /// 是否渲染自带标题栏（左栏由活动栏承担标题时传 false）
  final bool showHeader;

  /// 左栏折叠回调（内容下方空白区域点击触发）
  ///
  /// 为 null 时不注册点击（右栏等常驻场景不需要折叠语义）。
  final VoidCallback? onCollapse;

  const PluginPanel({
    super.key,
    this.teamId,
    this.showHeader = true,
    this.onCollapse,
  });

  @override
  State<PluginPanel> createState() => _PluginPanelState();
}

class _PluginPanelState extends State<PluginPanel> {
  PluginMonitorService get _svc => PluginMonitorService.instance;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
    _svc.start(teamId: widget.teamId ?? '');
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
            '插件（只读）',
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
            tooltip: '刷新快照',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: _svc.loading ? null : () => _svc.refresh(),
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
          _sectionTitle(cs, '插件实例（${snap.instances.length}）'),
          if (snap.instances.isEmpty)
            _emptyHint(cs, '暂无插件实例')
          else
            ...snap.instances.map(
              (PluginInstanceInfo e) => _instanceCard(cs, e, snap.watchdog),
            ),
          const SizedBox(height: 12),
          _sectionTitle(cs, '处理站（${snap.stations.length}）'),
          if (snap.stations.isEmpty)
            _emptyHint(cs, '暂无处理站订阅')
          else
            ...snap.stations.map((PluginStationInfo s) => _stationCard(cs, s)),
          const SizedBox(height: 12),
          _sectionTitle(cs, '看门狗'),
          _buildWatchdog(cs, snap),
        ],
      ),
    );
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

  /// 单个插件实例卡片。
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

  /// 单个处理站卡片（计数白名单裁剪，未知键忽略）。
  Widget _stationCard(ColorScheme cs, PluginStationInfo s) {
    final String subscriber =
        s.subscriptions.isEmpty || s.subscriptions.first.subscriber.isEmpty
        ? '—'
        : s.subscriptions.first.subscriber;
    final String subNote = s.subscriptions.length > 1
        ? '（+${s.subscriptions.length - 1}）'
        : '';
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
          Text(
            s.stationId,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          Text(
            '订阅: $subscriber$subNote',
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
  String _scopeSummary(Map<String, dynamic> scope) {
    final List<String> parts = <String>[];
    for (final String k in <String>['team_id', 'agent_id', 'session_id']) {
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
