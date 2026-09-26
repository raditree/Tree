import 'package:flutter/foundation.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 插件 UI 槽位注册表（Q12）：插件声明式布局的前端数据源。
///
/// 职责三件：
/// 1. **承载帧**——[handleFrame] 消费 `plugin_ui_manifest`（登记 / 整块替换槽位）、
///    `plugin_ui_update`（按 `slot_key` 局部替换视图，**整块替换、不做 diff**）与
///    `plugin_status(destroyed)`（插件卸载 / 断连 ⇒ 注销其全部槽位）；
/// 2. **team 过滤**——槽位一律带 `team_id`，只呈现当前 team 的槽位
///    （[setTeam] 切换即自动过滤，fail-closed；被过滤的槽位只隐藏不删除，
///    切回该 team 立刻恢复）；
/// 3. **动作出口**——[dispatchAction] 把按钮点击 / 表单提交组装成
///    `plugin_ui_action` 帧，经 [actionSender]（UI 层接到 WebSocketService）发出。
///
/// 多插件可同时挂同一槽位类型：槽位以 `slot_key` 为键独立存储，互不覆盖；
/// 排序规则见 [slotsOfKind]。
class PluginUiRegistry extends ChangeNotifier {
  PluginUiRegistry._();

  /// 全局单例（UI 各处默认使用）。
  static final PluginUiRegistry instance = PluginUiRegistry._();

  /// 测试专用实例（不共享单例状态）。
  @visibleForTesting
  factory PluginUiRegistry.forTesting() => PluginUiRegistry._();

  /// 动作帧发送通道（UI 层接 `WebSocketService.send`；测试可注入假发送器）。
  ///
  /// 为 null 时 [dispatchAction] 只返回 false，不抛异常——插件 UI 在未连上核心
  /// 时点了按钮应当"没反应"，而不是崩掉页面。
  void Function(Map<String, dynamic> frame)? actionSender;

  /// 槽位存储：slot_key -> 槽位（多插件共存互不覆盖）。
  final Map<String, PluginUiSlot> _slots = <String, PluginUiSlot>{};

  /// 到达序号：slot_key -> 单调递增序号（首次登记时分配，更新不改变）。
  ///
  /// 用于"同 order 时按到达顺序"的稳定排序；消息流卡片按它严格排序。
  final Map<String, int> _arrival = <String, int>{};
  int _arrivalSeq = 0;

  /// 当前 team（空串 = 未选 team：只呈现 team_id 为空的全局槽位）。
  String _teamId = '';

  /// 当前 team id。
  String get teamId => _teamId;

  /// 全部已登记槽位（**不过滤 team**；诊断与测试用）。
  List<PluginUiSlot> get allSlots =>
      List<PluginUiSlot>.unmodifiable(_slots.values);

  /// 切换当前 team：只呈现该 team 的槽位（数据保留，切回即恢复）。
  void setTeam(String teamId) {
    if (_teamId == teamId) {
      return;
    }
    _teamId = teamId;
    notifyListeners();
  }

  /// 槽位对当前 team 是否可见（fail-closed：team 必须精确匹配）。
  bool _visible(PluginUiSlot slot) => slot.teamId == _teamId;

  /// 当前 team 可见的某类槽位。
  ///
  /// 排序：
  /// - [PluginUiSlotKind.card]（消息流卡片）：**严格按到达顺序**（插件注入即
  ///   插入消息流末尾，order 不参与）；
  /// - 其余三类：先按 `order` 升序，再按到达顺序，最后按 `slot_key` 字典序
  ///   （完全确定的顺序，避免同一帧内顺序抖动）。
  List<PluginUiSlot> slotsOfKind(String kind) {
    final List<PluginUiSlot> list = <PluginUiSlot>[
      for (final PluginUiSlot slot in _slots.values)
        if (slot.kind == kind && _visible(slot)) slot,
    ];
    if (kind == PluginUiSlotKind.card) {
      list.sort((PluginUiSlot a, PluginUiSlot b) =>
          _arrivalOf(a.slotKey).compareTo(_arrivalOf(b.slotKey)));
      return List<PluginUiSlot>.unmodifiable(list);
    }
    list.sort((PluginUiSlot a, PluginUiSlot b) {
      final int byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) {
        return byOrder;
      }
      final int byArrival =
          _arrivalOf(a.slotKey).compareTo(_arrivalOf(b.slotKey));
      if (byArrival != 0) {
        return byArrival;
      }
      return a.slotKey.compareTo(b.slotKey);
    });
    return List<PluginUiSlot>.unmodifiable(list);
  }

  /// 当前 team 是否（在该类槽位上）有可见槽位。
  bool hasKind(String kind) {
    for (final PluginUiSlot slot in _slots.values) {
      if (slot.kind == kind && _visible(slot)) {
        return true;
      }
    }
    return false;
  }

  /// 按 `slot_key` 取当前 team 可见的槽位（不可见 / 不存在返回 null）。
  PluginUiSlot? slot(String slotKey) {
    final PluginUiSlot? slot = _slots[slotKey];
    if (slot == null || !_visible(slot)) {
      return null;
    }
    return slot;
  }

  /// 按 `slot_key` 取槽位（**不过滤 team**；用于注销与诊断）。
  PluginUiSlot? slotRaw(String slotKey) => _slots[slotKey];

  /// 登记（或整块覆盖）一个槽位；返回是否为首次登记。
  bool registerSlot(PluginUiSlot slot) {
    final bool isNew = !_slots.containsKey(slot.slotKey);
    _slots[slot.slotKey] = slot;
    _arrival.putIfAbsent(slot.slotKey, () => _arrivalSeq++);
    notifyListeners();
    return isNew;
  }

  /// 应用一份 manifest（**该插件在该 team 上的完整槽位声明**）。
  ///
  /// - 逐槽位登记；同 `slot_key` 整块覆盖（含视图）；
  /// - 声明中**未列出**的旧槽位按（同 plugin_id + 同 team_id）范围注销——否则插件
  ///   改版去掉一个槽位后，前端会永远留着僵尸槽位；
  /// - 注销范围**不跨 team**：插件可以为不同 team 声明不同槽位，互不牵连。
  void applyManifest(PluginUiManifest manifest) {
    final Set<String> declared = <String>{
      for (final PluginUiSlot slot in manifest.slots) slot.slotKey,
    };
    final List<String> stale = <String>[
      for (final MapEntry<String, PluginUiSlot> e in _slots.entries)
        if (e.value.pluginId == manifest.pluginId &&
            e.value.teamId == manifest.teamId &&
            !declared.contains(e.key))
          e.key,
    ];
    for (final String key in stale) {
      _slots.remove(key);
      _arrival.remove(key);
    }
    for (final PluginUiSlot slot in manifest.slots) {
      _slots[slot.slotKey] = slot;
      _arrival.putIfAbsent(slot.slotKey, () => _arrivalSeq++);
    }
    notifyListeners();
  }

  /// 应用一次 update：按 `slot_key` **整块替换**视图；`view == null` 表示注销该槽位。
  ///
  /// 目标槽位不存在时**忽略**（不凭空新建——槽位的存在性只由 manifest 决定，
  /// 否则 update 会成为绕过 team 隔离的旁路）。返回是否产生了变化。
  bool applyUpdate(PluginUiUpdate update) {
    final PluginUiSlot? existing = _slots[update.slotKey];
    if (existing == null) {
      return false;
    }
    if (update.view == null) {
      return unregisterSlot(update.slotKey);
    }
    _slots[update.slotKey] = existing.copyWithView(update.view!);
    notifyListeners();
    return true;
  }

  /// 注销单个槽位；返回是否确实移除了。
  bool unregisterSlot(String slotKey) {
    if (_slots.remove(slotKey) == null) {
      return false;
    }
    _arrival.remove(slotKey);
    notifyListeners();
    return true;
  }

  /// 注销某插件的全部槽位（插件卸载 / 断连）；返回移除数量。
  int unregisterPlugin(String pluginId) {
    if (pluginId.isEmpty) {
      return 0;
    }
    final List<String> keys = <String>[
      for (final MapEntry<String, PluginUiSlot> e in _slots.entries)
        if (e.value.pluginId == pluginId) e.key,
    ];
    for (final String key in keys) {
      _slots.remove(key);
      _arrival.remove(key);
    }
    if (keys.isNotEmpty) {
      notifyListeners();
    }
    return keys.length;
  }

  /// 清空全部槽位（退出登录 / 测试复位）。
  void clear() {
    if (_slots.isEmpty) {
      return;
    }
    _slots.clear();
    _arrival.clear();
    notifyListeners();
  }

  /// 消费一帧；返回是否被本注册表处理（false = 与本注册表无关，调用方继续别的分支）。
  ///
  /// - `plugin_ui_manifest` / `plugin_ui_update`：类型匹配即算已处理（载荷畸形则
  ///   丢弃，不抛）；
  /// - `plugin_status` 且 `data.status == destroyed`：注销该插件全部槽位
  ///   （插件卸载 / 断连时槽位不得残留）。其它 status（registered / disabled）
  ///   不动槽位——disabled 可能恢复。
  bool handleFrame(Map<String, dynamic> frame) {
    final Object? type = frame['type'];
    if (type == PluginUiFrameType.manifest) {
      final PluginUiManifest? manifest = PluginUiManifest.fromFrame(frame);
      if (manifest != null) {
        applyManifest(manifest);
      }
      return true;
    }
    if (type == PluginUiFrameType.update) {
      final PluginUiUpdate? update = PluginUiUpdate.fromFrame(frame);
      if (update != null) {
        applyUpdate(update);
      }
      return true;
    }
    if (type == WsOutboundType.pluginStatus) {
      final Object? raw = frame['data'];
      if (raw is! Map) {
        return false;
      }
      final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
      if ((data['status'] ?? '').toString() != 'destroyed') {
        return false;
      }
      final String pluginId = (data['plugin_id'] ?? '').toString();
      if (pluginId.isEmpty) {
        return false;
      }
      unregisterPlugin(pluginId);
      return true;
    }
    return false;
  }

  /// 派发一次插件交互（按钮点击 / 表单提交）。
  ///
  /// [payload]：按钮点击 = 按钮自带的 payload；表单提交 = `submit.payload` 与字段值
  /// 合并（字段值覆盖同名键，见渲染器）。
  /// [agentId] / [sessionId]：当前上下文（隔离四元组的其余成员，可为空）。
  ///
  /// 槽位不存在或未接发送通道时返回 false（不抛）。
  bool dispatchAction({
    required String slotKey,
    required String actionId,
    Map<String, dynamic> payload = const <String, dynamic>{},
    String agentId = '',
    String sessionId = '',
  }) {
    final PluginUiSlot? slot = _slots[slotKey];
    if (slot == null || actionId.isEmpty) {
      return false;
    }
    final void Function(Map<String, dynamic> frame)? sender = actionSender;
    if (sender == null) {
      return false;
    }
    sender(PluginUiAction(
      slotKey: slotKey,
      actionId: actionId,
      pluginId: slot.pluginId,
      teamId: slot.teamId,
      agentId: agentId,
      sessionId: sessionId,
      payload: payload,
    ).toFrame());
    return true;
  }

  int _arrivalOf(String slotKey) => _arrival[slotKey] ?? 1 << 30;
}
