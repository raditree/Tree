import 'package:flutter/material.dart';

import '../../io/plugin_monitor_service.dart';

/// 插件面板（右栏第 5 页签；只读）。
///
/// 数据源 = [PluginMonitorService]（REST 快照 + WS `plugin_status` 增量），
/// 显式三态：断连（重连中）/ 空（已连接、无实例与站）/ 错误（快照拉取失败）。
/// 渲染防御式：未知字段与未知状态一律忽略（不崩、不臆测）。
class PluginPanel extends StatefulWidget {
  /// 所属团队 ID（null / 空串 = 不过滤，展示当前用户可见全部实例）
  final String? teamId;

  const PluginPanel({super.key, this.teamId});

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
        _buildHeader(cs),
        if (!_svc.connected)
          _buildBanner(cs, '连接断开，正在重连…（下方为最近一次数据）'),
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
        return _centeredHint(cs, '等待连接…');
      }
      if (_svc.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _centeredHint(cs, '暂无数据');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        _sectionTitle(cs, '开关与配置'),
        _buildSwitchSection(cs, snap),
        const SizedBox(height: 12),
        _sectionTitle(cs, '插件实例（${snap.instances.length}）'),
        if (snap.instances.isEmpty)
          _emptyHint(cs, '暂无插件实例')
        else
          ...snap.instances.map(
            (PluginInstanceInfo e) => _instanceCard(cs, e),
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
  Widget _buildWatchdog(ColorScheme cs, PluginSnapshot snap) {
    final PluginWatchdogInfo? w = snap.watchdog;
    if (w == null) {
      return _emptyHint(cs, '暂无数据');
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        _pill(cs, '活跃 runs: ${w.activeRuns}'),
        _pill(cs, '判死: ${w.judgedDead}'),
      ],
    );
  }

  /// 单个插件实例卡片。
  Widget _instanceCard(ColorScheme cs, PluginInstanceInfo e) {
    final String title = e.name.isNotEmpty ? e.name : e.pluginId;
    final List<String> meta = <String>[
      if (e.granularity.isNotEmpty) '粒度 ${e.granularity}',
      '心跳 ${_relativeTime(e.lastHeartbeat)}',
      if (e.queueDepth != null && e.queueDepth! > 0) '队列 ${e.queueDepth}',
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
          if (e.disabledReason.isNotEmpty)
            Text(
              '停用原因: ${e.disabledReason}',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
        ],
      ),
    );
  }

  /// 单个处理站卡片（计数白名单裁剪，未知键忽略）。
  Widget _stationCard(ColorScheme cs, PluginStationInfo s) {
    final String subscriber = s.subscriptions.isEmpty ||
            s.subscriptions.first.subscriber.isEmpty
        ? '—'
        : s.subscriptions.first.subscriber;
    final String subNote =
        s.subscriptions.length > 1 ? '（+${s.subscriptions.length - 1}）' : '';
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
  Widget _pill(ColorScheme cs, String text, {bool emphasize = false}) {
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
          color: emphasize ? cs.onPrimaryContainer : cs.onSurfaceVariant,
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

  /// 居中提示（空态 / 断连态）。
  Widget _centeredHint(ColorScheme cs, String text) {
    return Center(
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
    final DateTime t =
        DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
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
