/// **UI 插件 ⇄ 站点总线**的 WS 接线（片 B）。
///
/// 职责边界：
/// - 连接身份（`ui.hello`）与 `plugins.yaml` 的 `runtime: ui` 声明对账；
/// - WS 订阅只允许**广播站**（内置广播点位 + 插件自建广播站），中转 / 执行 /
///   收集站一律可读拒绝；
/// - 把站点投递映射成 `station_delivery` 帧（四态 + 单调 seq + 有界队列）；
/// - UI 自建广播站的注册 / 注销 / 触发与「最后一条连接断开即注销」；
/// - 为 `GET /api/meta` 聚合发现面（routes 在片 C 之前为空，**不编造静态清单**）。
///
/// **不做**的事：不实现 REST 委派（片 C）、不决定 UI / 无头的启动分流（片 D）、
/// 不删旧面板协议（片 E）。
library;

import 'dart:async';
import 'dart:io';

import 'package:tree_protocol/tree_protocol.dart';

import '../ws/ws_hub.dart';
import 'plugin_host.dart';
import 'plugin_runtime.dart';
import 'station_channel.dart';
import 'station_ids.dart';
import 'station_instance.dart';
import 'station_runtime.dart';
import 'station_schema.dart';
import 'station_scope.dart';
import 'stations.dart';

/// UI 连接与核心站点总线之间的桥。
class StationWsBridge {
  StationWsBridge({
    required this.stations,
    required this.configs,
    this.routes,
    this.log,
    this.onUiHello,
    this.onUiBranding,
    this.branding,
    this.queueCapacity = WsConnectionOutbox.defaultQueueCapacity,
  });

  /// 站点中枢（订阅、注册、落盘都在它这里）。
  final StationHub stations;

  /// 当前 `plugins.yaml` 配置（身份校验与发现面归属推导）。
  final List<PluginConfig> Function() configs;

  /// 片 C：委派路由归属表的只读快照（`/api/meta.routes`）。
  ///
  /// 由核心接线时注入 `DelegatedRouter.metaRoutes`；桥**不缓存**第二份，
  /// 因此插件重新申报 / 下线销账后这里立刻反映真实归属。
  final List<ApiMetaRoute> Function()? routes;

  final void Function(String message)? log;

  /// 片 D：UI 插件成功完成 `ui.hello` 后通知总线（用于 30s 连接窗口判活）。
  ///
  /// 桥只负责“身份通过”这一事实，不关心宿主怎么记状态。
  final void Function(String pluginId)? onUiHello;

  /// 片 E：`ui.hello` 里可选携带的品牌申报（`{icon, role, sizes}`）。
  ///
  /// 设计 §6.4 明确「UI 不参与收集站的请求/应答」，因此品牌申报**随 hello 投递**：
  /// 连接建立即申报一次；重连视为新申报。`null` = 该连接没有申报 ⇒ 撤回该插件。
  final void Function(String pluginId, Object? branding)? onUiBranding;

  /// 片 E：`/api/meta.branding` 的只读快照（当前生效品牌）。
  final ApiMetaBranding? Function()? branding;

  /// 每条连接的投递队列上限。
  final int queueCapacity;

  final Map<String, _UiConnectionState> _connections =
      <String, _UiConnectionState>{};

  /// 站点 id → 正在订阅它的 WS 通道（注销 / 下线时批量发 `closed`）。
  final Map<String, Set<WsStationSubscriberChannel>> _channelsByStation =
      <String, Set<WsStationSubscriberChannel>>{};

  /// UI 插件 id → 它在本进程里注册的自建站（最后一个窗口断开时整批注销）。
  final Map<String, Set<String>> _ownedStations =
      <String, Set<String>>{};

  /// 连接数（诊断）。
  int get connectionCount => _connections.length;

  /// `ui.hello` 是否接受该运行形态。
  ///
  /// **片 D 口径**：只认归一化后的 `ui`。`binary` / `python` / 空串 / 任意未知值
  /// 按 `headless` 处理，不允许作为 UI 连接（旧清单要用 UI 必须显式升级为
  /// `runtime: ui`）。
  static bool isUiRuntime(String runtime) => PluginRuntime.isUi(runtime);

  /// 处理一条上行帧；返回是否由本桥消费。
  bool handleFrame(WsConnection connection, Map<String, dynamic> frame) {
    switch (frame['type']) {
      case WsInboundType.uiHello:
        _handleHello(connection, frame);
        return true;
      case WsInboundType.stationSubscribe:
        _handleSubscribe(connection, frame);
        return true;
      case WsInboundType.stationUnsubscribe:
        _handleUnsubscribe(connection, frame);
        return true;
      case WsInboundType.stationRegister:
        _handleRegister(connection, frame);
        return true;
      case WsInboundType.stationUnregister:
        _handleUnregister(connection, frame);
        return true;
      case WsInboundType.stationTrigger:
        unawaited(_handleTrigger(connection, frame));
        return true;
      default:
        return false;
    }
  }

  /// 连接断开：摘掉它的全部订阅；该 UI 插件的最后一条连接断开时注销自建站。
  void onConnectionClosed(WsConnection connection) {
    final _UiConnectionState? state = _connections.remove(connection.id);
    if (state == null) return;
    state.outbox.dispose();
    for (final WsStationSubscriberChannel channel in state.channels.values) {
      stations.station(channel.stationId)?.unsubscribeKey(channel.subscriberKey);
      _forgetChannel(channel);
    }
    state.channels.clear();
    final _UiBond? bond = state.bond;
    if (bond == null) return;
    final bool hasOther = _connections.values.any(
      (_UiConnectionState other) => other.bond?.pluginId == bond.pluginId,
    );
    if (hasOther) return;
    final Set<String>? owned = _ownedStations.remove(bond.pluginId);
    if (owned == null) return;
    for (final String stationId in owned) {
      // unregister 会走 StationHub.onStationRemoved → 给其它订阅者发 closed。
      stations.unregister(stationId);
      _channelsByStation.remove(stationId);
    }
  }

  /// 站点从表里消失（注销）：给它的 WS 订阅者补 `closed`。
  void onStationRemoved(String stationId, String reason) {
    final Set<WsStationSubscriberChannel>? channels = _channelsByStation.remove(
      stationId,
    );
    if (channels == null) return;
    for (final WsStationSubscriberChannel channel
        in List<WsStationSubscriberChannel>.of(channels)) {
      channel.close(reason);
      _detach(channel);
    }
  }

  /// 插件下线（站点可能保留）：给订阅该插件自建站的 WS 连接发 `closed`。
  void onPluginOffline(String pluginId) {
    for (final StationInstance station in stations.stationList()) {
      if (!_owns(pluginId, station.id)) continue;
      final Set<WsStationSubscriberChannel>? channels = _channelsByStation[
        station.id
      ];
      if (channels == null) continue;
      final String reason = '插件 $pluginId 已下线，站点 ${station.id} 的订阅终止';
      for (final WsStationSubscriberChannel channel
          in List<WsStationSubscriberChannel>.of(channels)) {
        station.unsubscribeKey(channel.subscriberKey);
        channel.close(reason);
        _detach(channel);
      }
      _channelsByStation.remove(station.id);
    }
  }

  /// 聚合 `GET /api/meta` 的发现面。
  ///
  /// `routes` 片 B 一律为空：路由声明由片 C 的收集站提供，这里**不维护第二份
  /// 静态清单**（不变量 13）。
  ApiMeta buildMeta({required String coreVersion, required String apiVersion}) {
    final Map<String, List<_UiBond>> byPlugin = <String, List<_UiBond>>{};
    for (final _UiConnectionState state in _connections.values) {
      final _UiBond? bond = state.bond;
      if (bond == null) continue;
      byPlugin.putIfAbsent(bond.pluginId, () => <_UiBond>[]).add(bond);
    }
    final List<ApiMetaUi> ui = <ApiMetaUi>[];
    final List<Object?> capabilities = <Object?>[];
    final Set<String> capabilityKeys = <String>{};
    bool canManage = false;
    for (final MapEntry<String, List<_UiBond>> entry in byPlugin.entries) {
      final List<String> merged = <String>[];
      String version = '';
      for (final _UiBond bond in entry.value) {
        if (version.isEmpty) version = bond.version;
        for (final Object? capability in bond.capabilities) {
          final String wire = capability == null ? '' : capability.toString();
          if (!merged.contains(wire)) merged.add(wire);
          if (wire == 'plugin.manage') canManage = true;
          final String key = '${capability.runtimeType}:$wire';
          if (capabilityKeys.add(key)) capabilities.add(capability);
        }
      }
      ui.add(
        ApiMetaUi(
          pluginId: entry.key,
          version: version,
          capabilities: merged,
          connections: entry.value.length,
        ),
      );
    }
    ui.sort((ApiMetaUi a, ApiMetaUi b) => a.pluginId.compareTo(b.pluginId));

    final List<PluginConfig> configsNow = configs();
    final List<ApiMetaStation> stationRows = <ApiMetaStation>[];
    for (final StationInstance station in stations.stationList()) {
      // 只列**可订阅的广播站**：收集 / 中转 / 执行站不得出现在发现面。
      if (station.kind != StationKind.broadcast) continue;
      final bool builtin = StationHubIds.all.contains(station.id);
      stationRows.add(
        ApiMetaStation(
          stationId: station.id,
          point: builtin ? station.id : '',
          ownerPluginId: _ownerOf(station.id, builtin, configsNow),
          description: station.description,
        ),
      );
    }

    return ApiMeta(
      coreVersion: coreVersion,
      apiVersion: apiVersion,
      ui: ui,
      canManagePlugins: canManage,
      // 片 B 没有委派路由；保持空数组让 UI 能区分「空」与「老核心没给」。
      // 片 C 起由收集站的归属表提供：未申报 / 冲突条目一律不出现。
      routes: routes?.call() ?? const <ApiMetaRoute>[],
      stations: stationRows,
      capabilities: capabilities,
      branding: branding?.call(),
    );
  }

  // ── 上行处理 ────────────────────────────────────────────────────────

  void _handleHello(WsConnection connection, Map<String, dynamic> frame) {
    final Map<String, dynamic> data = _data(frame);
    final String pluginId = (data['plugin_id'] ?? '').toString().trim();
    final String version = (data['version'] ?? '').toString().trim();
    final List<Object?> capabilities = _capabilities(data['capabilities']);
    if (pluginId.isEmpty) {
      _rejectAndClose(connection, 'ui.hello 缺少 plugin_id，连接已关闭');
      return;
    }
    final PluginConfig? config = _configFor(pluginId);
    if (config == null) {
      _rejectAndClose(
        connection,
        'UI 插件 $pluginId 未在 plugins.yaml 声明，拒绝连接',
      );
      return;
    }
    if (!isUiRuntime(config.runtime)) {
      _rejectAndClose(
        connection,
        '插件 $pluginId 的 runtime 是「${config.runtime}」，不是 ui，拒绝作为 UI 连接',
      );
      return;
    }
    final _UiConnectionState state = _connections.putIfAbsent(
      connection.id,
      () => _UiConnectionState(
        connection,
        capacity: queueCapacity,
      ),
    );
    final _UiBond? existing = state.bond;
    if (existing != null && existing.pluginId != pluginId) {
      // 一条连接不能中途换身份：已有的订阅归属无法安全迁移，直接断开。
      _rejectAndClose(
        connection,
        '连接已绑定 UI 插件 ${existing.pluginId}，不能再声明为 $pluginId',
      );
      return;
    }
    state.bond = _UiBond(pluginId, version, capabilities);
    log?.call('UI 连接 ${connection.id} 已绑定插件 $pluginId（$version）');
    onUiHello?.call(pluginId);
    // 品牌申报随 hello 到达：没带 branding 键 = 该插件撤回申报（回退上一条 / 默认）。
    onUiBranding?.call(pluginId, data['branding']);
  }

  void _handleSubscribe(WsConnection connection, Map<String, dynamic> frame) {
    final _UiBond? bond = _requireBond(connection, '订阅站点');
    if (bond == null) return;
    final Map<String, dynamic> data = _data(frame);
    final String stationId = (data['station_id'] ?? '').toString().trim();
    if (stationId.isEmpty) {
      _sendError(connection, 'station/subscribe 缺少 station_id');
      return;
    }
    final StationInstance? station = stations.pointFor(stationId);
    if (station == null) {
      _sendError(
        connection,
        '站点不存在：$stationId（可用广播站见 /api/meta.stations）',
      );
      return;
    }
    if (station.kind != StationKind.broadcast) {
      // 白名单：中转 / 执行 / 收集站对 WS 一律不可订阅，原因必须可读。
      _sendError(
        connection,
        '站点 $stationId 是${station.kind.label}，WS 侧只允许订阅广播站',
      );
      return;
    }
    final StationScope scope = StationScope.parse(data['scope']);
    if (!scope.isValidSubscriber) {
      _sendError(
        connection,
        '订阅 scope 非法：mode_key 只能是 local | ssh，或留空表示通配',
      );
      return;
    }
    final List<String> topics = _topics(data['topics']);
    final StationSubscriber subscriber = StationSubscriber(
      pluginId: bond.pluginId,
      scope: scope,
      subscribedAt: _nowSeconds(),
      channelId: connection.id,
    );
    final String key = subscriber.key;
    final _UiConnectionState? state = _connections[connection.id];
    if (state == null) {
      _sendError(connection, '连接状态已失效，请重新 ui.hello');
      return;
    }
    final WsStationSubscriberChannel? old = state.channels[key];
    if (old != null) {
      old.dispose();
      _forgetChannel(old);
    }
    final WsStationSubscriberChannel channel = WsStationSubscriberChannel(
      channelId: connection.id,
      pluginId: bond.pluginId,
      stationId: station.id,
      point: StationHubIds.all.contains(station.id) ? station.id : '',
      scope: scope,
      topics: topics,
      outbox: state.outbox,
      sink: connection.send,
      queueCapacity: queueCapacity,
    );
    final StationSubResult result = stations.subscribe(
      station.id,
      subscriber,
      channel.deliver,
    );
    if (!result.ok) {
      channel.dispose();
      _sendError(connection, result.error, code: result.code);
      return;
    }
    state.channels[key] = channel;
    _channelsByStation.putIfAbsent(
      station.id,
      () => <WsStationSubscriberChannel>{},
    ).add(channel);
    if (old != null) {
      // 重逢同一订阅（窗口主动重订 / 重连后的同键订阅）：seq 从 1 重新开始，
      // 先发 reset 让 UI 清空本地水位。
      channel.emitReset();
    }
  }

  void _handleUnsubscribe(WsConnection connection, Map<String, dynamic> frame) {
    final _UiBond? bond = _requireBond(connection, '退订站点');
    if (bond == null) return;
    final Map<String, dynamic> data = _data(frame);
    final String stationId = (data['station_id'] ?? '').toString().trim();
    if (stationId.isEmpty) {
      _sendError(connection, 'station/unsubscribe 缺少 station_id');
      return;
    }
    final _UiConnectionState? state = _connections[connection.id];
    if (state == null) return;
    final List<WsStationSubscriberChannel> removed = state.channels.values
        .where((WsStationSubscriberChannel c) => c.stationId == stationId)
        .toList();
    for (final WsStationSubscriberChannel channel in removed) {
      stations.station(stationId)?.unsubscribeKey(channel.subscriberKey);
      channel.dispose();
      _forgetChannel(channel);
      state.channels.remove(channel.subscriberKey);
    }
  }

  void _handleRegister(WsConnection connection, Map<String, dynamic> frame) {
    final _UiBond? bond = _requireBond(connection, '注册自建站');
    if (bond == null) return;
    final Map<String, dynamic> data = _data(frame);
    final String kindRaw = (data['kind'] ?? '').toString().trim();
    final StationKind? kind = StationKind.fromWire(kindRaw);
    if (kind == null) {
      _sendError(
        connection,
        'station/register 需要合法的 kind（WS 侧只允许 broadcast，收到「$kindRaw」）',
      );
      return;
    }
    if (kind != StationKind.broadcast) {
      _sendError(
        connection,
        'WS 侧只允许注册广播站；${kind.label}不能在 UI 侧自建',
      );
      return;
    }
    final String name = (data['name'] ?? '').toString().trim();
    final String? nameError = StationHubIds.selfBuiltNameError(name);
    if (nameError != null) {
      _sendError(connection, nameError);
      return;
    }
    final String stationId = 'plugin.${bond.pluginId}.${kind.wire}.$name';
    final String readme = (data['readme'] ?? '').toString().trim();
    final bool shared = data['shared'] == true;
    final List<String> allowedPlugins = _strings(data['allowed_plugins']);
    final Map<String, dynamic> stationConfig = _map(data['config']);
    final String description = (data['description'] ?? '').toString().trim();
    final String resolvedDescription = description.isEmpty
        ? 'UI 插件 ${bond.pluginId} 自建广播站'
        : description;
    final int maxSubscriptions = _maxSubscriptions(data['max_subscriptions']);

    final StationInstance? existing = stations.station(stationId);
    if (existing != null) {
      if (existing.kind != StationKind.broadcast) {
        _sendError(connection, '站点 id 已被非广播站占用：$stationId');
        return;
      }
      if (!_owns(bond.pluginId, stationId)) {
        _sendError(connection, '站点 id 已被其它插件占用：$stationId');
        return;
      }
      // 同 id 幂等：配置必须一致；不同配置可读拒收（不允许静默改写别人的站）。
      // 这里也覆盖「核心重启后站点表还在、UI 重新抬手注册」：归属按 plugin_id
      // 前缀判定，配置一致就认领回 [_ownedStations]，后续关窗仍能整批注销。
      if (existing.readme != readme ||
          existing.description != resolvedDescription ||
          existing.maxSubscriptions != maxSubscriptions ||
          existing.shared != shared ||
          existing.allowedPlugins.length != allowedPlugins.length ||
          !_sameList(existing.allowedPlugins, allowedPlugins) ||
          !_sameMap(existing.config, stationConfig)) {
        _sendError(
          connection,
          '站点 $stationId 已存在且配置不同；同 id 注册只允许幂等（原站点保持不变）',
        );
        return;
      }
      _ownedStations
          .putIfAbsent(bond.pluginId, () => <String>{})
          .add(stationId);
      return;
    }
    if (readme.isEmpty) {
      _sendError(
        connection,
        'station/register 需要 readme（站点介绍，必填）：这个站干什么、什么时候被触发、订阅者该怎么回',
      );
      return;
    }
    final String? error = stations.register(
      BroadcastStation(
        id: stationId,
        description: resolvedDescription,
        readme: readme,
        maxSubscriptions: maxSubscriptions,
        shared: shared,
        allowedPlugins: allowedPlugins,
        config: stationConfig,
      ),
    );
    if (error != null) {
      _sendError(connection, error);
      return;
    }
    _ownedStations
        .putIfAbsent(bond.pluginId, () => <String>{})
        .add(stationId);
    _channelsByStation.putIfAbsent(
      stationId,
      () => <WsStationSubscriberChannel>{},
    );
    log?.call('UI 插件 ${bond.pluginId} 注册自建广播站 $stationId');
  }

  void _handleUnregister(WsConnection connection, Map<String, dynamic> frame) {
    final _UiBond? bond = _requireBond(connection, '注销自建站');
    if (bond == null) return;
    final Map<String, dynamic> data = _data(frame);
    final String stationId = (data['station_id'] ?? '').toString().trim();
    if (stationId.isEmpty) {
      _sendError(connection, 'station/unregister 缺少 station_id');
      return;
    }
    if (!_owns(bond.pluginId, stationId)) {
      _sendError(
        connection,
        '站点 $stationId 不是插件 ${bond.pluginId} 在 UI 侧注册的自建站，拒绝注销',
      );
      return;
    }
    final Set<String>? owned = _ownedStations[bond.pluginId];
    owned?.remove(stationId);
    if (!stations.unregister(stationId)) {
      // 幂等：已经不在了也当成功（站点移除钩子不会触发，无需补 closed）。
      return;
    }
    log?.call('UI 插件 ${bond.pluginId} 注销自建广播站 $stationId');
  }

  Future<void> _handleTrigger(
    WsConnection connection,
    Map<String, dynamic> frame,
  ) async {
    final _UiBond? bond = _requireBond(connection, '触发自建站');
    if (bond == null) return;
    final Map<String, dynamic> data = _data(frame);
    final String stationId = (data['station_id'] ?? '').toString().trim();
    if (stationId.isEmpty) {
      _sendError(connection, 'station/trigger 缺少 station_id');
      return;
    }
    final StationInstance? station = stations.station(stationId);
    if (station == null) {
      _sendError(connection, '站点不存在：$stationId');
      return;
    }
    if (station.kind != StationKind.broadcast) {
      _sendError(
        connection,
        '站点 $stationId 是${station.kind.label}；WS 侧只能触发自己注册的广播站',
      );
      return;
    }
    if (!_owns(bond.pluginId, stationId)) {
      _sendError(
        connection,
        '站点 $stationId 不是插件 ${bond.pluginId} 注册的自建广播站，拒绝触发',
      );
      return;
    }
    if (station is! BroadcastStation) {
      _sendError(connection, '站点 $stationId 不是广播站，拒绝触发');
      return;
    }
    final String topic = (data['topic'] ?? '').toString().trim();
    if (topic.isEmpty) {
      _sendError(connection, 'station/trigger 缺少 topic');
      return;
    }
    final StationScope scope = StationScope.parse(data['scope']);
    final Map<String, dynamic> meta = <String, dynamic>{
      ...station.config,
      ..._map(data['meta']),
      'triggered_by': bond.pluginId,
    };
    final StationPublishResult result = await station.publish(
      topic: topic,
      scope: scope,
      payload: data['payload'],
      meta: meta,
      sourcePluginId: bond.pluginId,
    );
    if (result.boardSeq == 0) {
      // 消息信封不可证明归属（团队为空 / mode 非法）或站点被禁用：可读拒绝。
      _sendError(
        connection,
        result.skipped.isEmpty
            ? '广播被拒：消息 scope 不可证明归属（team_id 必填、mode_key ∈ local | ssh）'
            : result.skipped.join('；'),
      );
    }
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  _UiBond? _requireBond(WsConnection connection, String action) {
    final _UiConnectionState? state = _connections[connection.id];
    final _UiBond? bond = state?.bond;
    if (bond == null) {
      _sendError(
        connection,
        '连接尚未完成 ui.hello，不能$action；请先声明 {plugin_id, version, capabilities[]}',
      );
      return null;
    }
    return bond;
  }

  bool _owns(String pluginId, String stationId) {
    if (StationHubIds.all.contains(stationId)) return false;
    if (_ownedStations[pluginId]?.contains(stationId) == true) return true;
    // 归属判据是 plugin_id（任务 2.5）。不能只做裸前缀比较：插件 id 允许带点，
    // `ui` 会误匹配 `plugin.ui.alpha.broadcast.x`。用已声明的插件 id 做**最长
    // 前缀**匹配，最长的那个才是站点的所有者；同时覆盖「核心重启后站点表还在、
    // UI 重连认领自己的站」。
    String best = '';
    for (final PluginConfig config in configs()) {
      if (config.id.isEmpty) continue;
      if (stationId.startsWith('plugin.${config.id}.') &&
          config.id.length > best.length) {
        best = config.id;
      }
    }
    if (best.isNotEmpty) return best == pluginId;
    // 配置里找不到（例如手工写入的测试站）：退回单段前缀判断，避免把站锁死。
    return stationId.startsWith('plugin.$pluginId.');
  }

  PluginConfig? _configFor(String pluginId) {
    for (final PluginConfig config in configs()) {
      if (config.id == pluginId) return config;
    }
    return null;
  }

  String _ownerOf(
    String stationId,
    bool builtin,
    List<PluginConfig> configsNow,
  ) {
    if (builtin) return 'core';
    for (final MapEntry<String, Set<String>> entry in _ownedStations.entries) {
      if (entry.value.contains(stationId)) return entry.key;
    }
    // 无主自建站（例如片 C/D 之前由插件通道注册的站）：按配置里的插件 id 做
    // **最长前缀**匹配；匹配不到就留空（不猜、不编造）。
    String best = '';
    for (final PluginConfig config in configsNow) {
      if (config.id.isEmpty) continue;
      if (stationId.startsWith('plugin.${config.id}.') &&
          config.id.length > best.length) {
        best = config.id;
      }
    }
    return best;
  }

  void _forgetChannel(WsStationSubscriberChannel channel) {
    final Set<WsStationSubscriberChannel>? set = _channelsByStation[
      channel.stationId
    ];
    set?.remove(channel);
    if (set != null && set.isEmpty) {
      _channelsByStation.remove(channel.stationId);
    }
  }

  void _detach(WsStationSubscriberChannel channel) {
    _forgetChannel(channel);
    final _UiConnectionState? state = _connections[channel.channelId];
    state?.channels.remove(channel.subscriberKey);
  }

  void _sendError(
    WsConnection connection,
    String error, {
    String code = '',
  }) {
    final String message = error.trim().isEmpty ? '站点请求被拒（无详细原因）' : error;
    connection.send(<String, dynamic>{
      'type': WsOutboundType.error,
      'data': <String, dynamic>{
        'ok': false,
        'error': message,
        'message': message,
        if (code.isNotEmpty) 'code': code,
      },
    });
  }

  void _rejectAndClose(WsConnection connection, String error) {
    _sendError(connection, error);
    log?.call(error);
    unawaited(_closeSocket(connection, error));
  }

  Future<void> _closeSocket(WsConnection connection, String reason) async {
    try {
      await connection.socket.close(WebSocketStatus.policyViolation, reason);
    } catch (_) {
      // 对端可能已经断开：关闭失败不影响拒绝语义。
    }
  }

  Map<String, dynamic> _data(Map<String, dynamic> frame) {
    final Object? data = frame['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return frame;
  }

  List<Object?> _capabilities(Object? raw) {
    if (raw is! List) return const <Object?>[];
    return List<Object?>.unmodifiable(raw);
  }

  List<String> _topics(Object? raw) {
    if (raw is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? item in raw) {
      final String value = item == null ? '' : item.toString().trim();
      if (value.isEmpty || out.contains(value)) continue;
      out.add(value);
    }
    return out;
  }

  List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? item in raw) {
      final String value = item == null ? '' : item.toString().trim();
      if (value.isEmpty || out.contains(value)) continue;
      out.add(value);
    }
    return out;
  }

  Map<String, dynamic> _map(Object? raw) {
    if (raw is! Map) return const <String, dynamic>{};
    return <String, dynamic>{
      for (final MapEntry<Object?, Object?> entry in raw.entries)
        entry.key.toString(): entry.value,
    };
  }

  int _maxSubscriptions(Object? raw) {
    if (raw is num) {
      final int value = raw.toInt();
      return value < 0 ? StationInstance.defaultMaxSubscriptions : value;
    }
    return StationInstance.defaultMaxSubscriptions;
  }

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _sameMap(Map<String, dynamic> a, Map<String, dynamic> b) =>
      _sameValue(a, b);

  bool _sameValue(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final Object? key in a.keys) {
        if (!b.containsKey(key)) return false;
        if (!_sameValue(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (!_sameValue(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

/// 一条已绑定 UI 身份的连接。
class _UiConnectionState {
  _UiConnectionState(
    this.connection, {
    required int capacity,
  }) : outbox = WsConnectionOutbox(
         sink: connection.send,
         capacity: capacity,
       );

  final WsConnection connection;
  final WsConnectionOutbox outbox;
  _UiBond? bond;
  final Map<String, WsStationSubscriberChannel> channels =
      <String, WsStationSubscriberChannel>{};
}

/// `ui.hello` 自报的身份。
class _UiBond {
  const _UiBond(this.pluginId, this.version, this.capabilities);

  final String pluginId;
  final String version;
  final List<Object?> capabilities;
}
