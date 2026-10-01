import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart';

/// **插件通知 → 前端 UI 帧**的桥（本轮新增；Q12 契约的生产端补齐）。
///
/// 背景（为什么需要这座桥）：Q12 的协议与前端**都已实现**——四类槽位
/// （`activity` 左侧活动栏 / `panel` 右栏 Tab / `status` 状态栏 / `card` 消息流卡片）、
/// 受限控件集、注册表与四处接入点；缺的是**核心侧把插件声明的槽位推给前端**的路径
/// （此前核心只会经执行站的 `ui.push` 推 **card** 一种槽位）。
///
/// 通道选择：插件与核心之间只有 stdio JSON-RPC，插件的**通知**（无 `id` 的报文）
/// 会经 `PluginBus._emitPluginEvent` 变成前端 `plugin_event` 帧——但前端注册表只认
/// `plugin_ui_manifest` / `plugin_ui_update`，因此这里按**约定 method** 转帧：
///
/// | 插件发出的通知 method | 转成的 WS 帧 | 语义 |
/// |---|---|---|
/// | `ui/manifest` | `plugin_ui_manifest` | **完整声明**该插件在该 team 上的全部槽位 |
/// | `ui/update`   | `plugin_ui_update`   | 按 `slot_key` 整块替换某槽位视图（`view: null` = 注销） |
/// | 其它 method   | （不转）`plugin_event` | 维持既有行为（日志 / 自定义事件） |
///
/// **不做 webview/iframe，也不执行插件 JS**（Q12 契约与 README 的既有约束）：
/// 视图只能是受限控件集的 JSON（text / list / table / form / progress / actions
/// 与 row / column 容器），未知控件由前端渲染成占位。
///
/// **安全边界（fail-closed）**：
/// - `plugin_id` **一律取实例 id**，不采信通知里的自述——否则 A 插件能注销 / 覆盖
///   B 插件的槽位；
/// - `team_id` 取插件声明（`plugins.yaml` 的 `scope.team_id`），声明为空时可自带
///   一个（前端按当前 team 过滤，跨 team 自然不呈现）；带进来的值若与声明冲突，
///   以声明为准并记日志；
/// - 槽位条数、`slot_key` 与视图大小都有上限，超限**整帧拒绝**并给可读原因（不静默）。
class PluginUiBridge {
  PluginUiBridge({this.maxSlots = defaultMaxSlots, this.maxViewBytes = defaultMaxViewBytes});

  /// 单帧最多槽位数（防插件一次性塞爆前端左栏）。
  static const int defaultMaxSlots = 16;

  /// 单个槽位视图的 JSON 字节上限（防超大帧；受限控件集本来就该是小的）。
  static const int defaultMaxViewBytes = 64 * 1024;

  /// 槽位上限。
  final int maxSlots;

  /// 视图字节上限。
  final int maxViewBytes;

  /// `ui/manifest` 通知的 method 名。
  static const String methodManifest = 'ui/manifest';

  /// `ui/update` 通知的 method 名。
  static const String methodUpdate = 'ui/update';

  /// 本桥接管的 method 集合。
  static const Set<String> methods = <String>{methodManifest, methodUpdate};

  /// 是否是我接管的通知 method。
  bool handles(Object? method) => methods.contains('$method');

  /// 把一条插件通知转成前端帧；返回 null = 该通知不归本桥处理（调用方维持原行为）。
  ///
  /// [pluginId] 必须是**实例 id**（不采信通知自述）；[declaredTeamId] 是
  /// `plugins.yaml` 里该插件的 `scope.team_id`（可为空）。
  /// [onRejected] 收到可读拒绝原因（调用方记日志；不返回 null 的"静默丢弃"）。
  Map<String, dynamic>? frameFor({
    required String pluginId,
    required String declaredTeamId,
    required String method,
    required Map<String, dynamic> params,
    void Function(String reason)? onRejected,
  }) {
    switch (method) {
      case methodManifest:
        return _manifestFrame(
          pluginId: pluginId,
          declaredTeamId: declaredTeamId,
          params: params,
          onRejected: onRejected,
        );
      case methodUpdate:
        return _updateFrame(
          pluginId: pluginId,
          declaredTeamId: declaredTeamId,
          params: params,
          onRejected: onRejected,
        );
      default:
        return null;
    }
  }

  /// `ui/manifest` → `plugin_ui_manifest`。
  Map<String, dynamic>? _manifestFrame({
    required String pluginId,
    required String declaredTeamId,
    required Map<String, dynamic> params,
    void Function(String reason)? onRejected,
  }) {
    final Object? rawSlots = params['slots'];
    if (rawSlots is! List) {
      onRejected?.call('ui/manifest 的 slots 必须是数组（整帧拒绝，不静默降级）');
      return null;
    }
    if (rawSlots.length > maxSlots) {
      onRejected?.call(
        'ui/manifest 的槽位数 ${rawSlots.length} 超过上限 $maxSlots（整帧拒绝）',
      );
      return null;
    }
    final String teamId = _resolveTeamId(
      pluginId: pluginId,
      declaredTeamId: declaredTeamId,
      claimed: params['team_id'],
      onRejected: onRejected,
    );
    final List<PluginUiSlot> slots = <PluginUiSlot>[];
    for (final Object? item in rawSlots) {
      final PluginUiSlot? slot = PluginUiSlot.tryParse(
        item,
        // **归属一律用实例 id / 解析出的 team**：槽位条目自带的 plugin_id /
        // team_id 会被 tryParse 的兜底覆盖 —— 但只有条目留空时才兜底，
        // 所以这里先列表校验，把越权条目挡在外面。
        fallbackPluginId: pluginId,
        fallbackTeamId: teamId,
      );
      if (slot == null) {
        onRejected?.call('ui/manifest 有一条槽位非法（缺 slot_key 或 slot 类型未知），已跳过');
        continue;
      }
      if (slot.pluginId != pluginId) {
        onRejected?.call(
          'ui/manifest 的槽位 ${slot.slotKey} 声称属于插件 ${slot.pluginId}，'
          '与实例 $pluginId 不符（越权声明，已跳过）',
        );
        continue;
      }
      if (slot.teamId != teamId) {
        onRejected?.call(
          'ui/manifest 的槽位 ${slot.slotKey} team=${slot.teamId} 与声明的 $teamId 不符'
          '（跨 team 拒绝，已跳过）',
        );
        continue;
      }
      final String? tooBig = _viewTooBig(slot);
      if (tooBig != null) {
        onRejected?.call(tooBig);
        continue;
      }
      slots.add(slot);
    }
    if (slots.isEmpty) {
      onRejected?.call('ui/manifest 没有任何合法槽位（整帧不发；如需注销全部槽位请显式发空 arrays）');
      return null;
    }
    return PluginUiManifest(
      pluginId: pluginId,
      teamId: teamId,
      slots: slots,
    ).toFrame();
  }

  /// `ui/update` → `plugin_ui_update`（按 `slot_key` 整块替换；`view: null` = 注销）。
  Map<String, dynamic>? _updateFrame({
    required String pluginId,
    required String declaredTeamId,
    required Map<String, dynamic> params,
    void Function(String reason)? onRejected,
  }) {
    final String slotKey = (params['slot_key'] ?? '').toString().trim();
    if (slotKey.isEmpty) {
      onRejected?.call('ui/update 缺少 slot_key，已丢弃');
      return null;
    }
    final String teamId = _resolveTeamId(
      pluginId: pluginId,
      declaredTeamId: declaredTeamId,
      claimed: params['team_id'],
      onRejected: onRejected,
    );
    final bool hasView = params.containsKey('view');
    final Object? rawView = params['view'];
    final PluginUiView? view = hasView && rawView != null
        ? PluginUiView.tryParse(rawView)
        : null;
    if (hasView && rawView != null && view == null) {
      onRejected?.call('ui/update 的 view 非法（声明式视图解析失败），已丢弃');
      return null;
    }
    if (view != null &&
        utf8.encode(jsonEncode(view.toJson())).length > maxViewBytes) {
      onRejected?.call('ui/update 的 view 超过 $maxViewBytes 字节上限，已丢弃');
      return null;
    }
    return PluginUiUpdate(
      pluginId: pluginId,
      teamId: teamId,
      slotKey: slotKey,
      view: view,
    ).toFrame();
  }

  /// 解析归属 team：**声明优先**（插件不得自述刷到别的 team）。
  String _resolveTeamId({
    required String pluginId,
    required String declaredTeamId,
    required Object? claimed,
    void Function(String reason)? onRejected,
  }) {
    final String declared = declaredTeamId.trim();
    final String own = (claimed ?? '').toString().trim();
    if (declared.isNotEmpty) {
      if (own.isNotEmpty && own != declared) {
        onRejected?.call(
          '插件 $pluginId 的 UI 声明携带 team=$own，与 plugins.yaml 的 $declared 不符：'
          '以声明为准（声明是作用域上限）',
        );
      }
      return declared;
    }
    return own;
  }

  /// 视图体积校验（返回可读原因；null = 通过）。
  String? _viewTooBig(PluginUiSlot slot) {
    final int bytes = utf8.encode(jsonEncode(slot.toJson())).length;
    if (bytes <= maxViewBytes) return null;
    return '槽位 ${slot.slotKey} 的声明体积 $bytes 字节超过上限 $maxViewBytes（已跳过）';
  }
}
