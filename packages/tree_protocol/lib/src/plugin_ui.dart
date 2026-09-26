/// Q12 插件布局契约：三类 WS 帧 + 声明式视图模型（受限控件集）。
///
/// **传输**：沿用既有 WS 帧通道（`{"type": ..., "data": {...}}`，与 `plugin_status`
/// 等帧同构），新增三类帧（见 [PluginUiFrameType]）：
/// - [PluginUiFrameType.manifest]（核心 → 前端）：某插件的槽位声明（slot 列表 +
///   各槽位初始视图）；
/// - [PluginUiFrameType.update]（核心 → 前端）：按 `slot_key` 局部替换某槽位视图
///   （**整块替换，不做 diff**）；
/// - [PluginUiFrameType.action]（前端 → 核心）：用户在插件视图上的交互回调。
///
/// **槽位（4 类）**：[PluginUiSlotKind.activity]（左侧活动栏项）、
/// [PluginUiSlotKind.panel]（右栏 Tab）、[PluginUiSlotKind.status]（状态栏项）、
/// [PluginUiSlotKind.card]（消息流内联卡片，允许插件注入）。槽位一律带 `team_id`，
/// 前端只呈现当前 team 的槽位（与 M9 1.2 的站点隔离口径一致，fail-closed）。
///
/// **视图模型**：声明式、受限控件集，**不做 webview/iframe**；控件与容器的 JSON
/// 形状见 [PluginUiNode] 的 dartdoc；未知控件类型由渲染器给出「不支持的控件」
/// 占位而不是崩溃。按钮与表单提交经 [PluginUiAction] 回插件。
///
/// **方向常量不放进 `WsInboundType.all` 的原因**见 [PluginUiFrameType.inbound]。
library;

/// 插件 UI 帧类型（三件套）。
abstract final class PluginUiFrameType {
  /// 槽位声明（核心 → 前端）。
  static const String manifest = 'plugin_ui_manifest';

  /// 槽位视图局部替换（核心 → 前端；整块替换，不做 diff）。
  static const String update = 'plugin_ui_update';

  /// 插件视图交互回调（前端 → 核心）。
  static const String action = 'plugin_ui_action';

  /// 全部插件 UI 帧类型（完备性测试与文档用）。
  static const Set<String> all = <String>{manifest, update, action};

  /// 下行（核心 → 前端）。
  static const Set<String> outbound = <String>{manifest, update};

  /// 上行（前端 → 核心）。
  ///
  /// **登记口径**：本常量集是该帧的单一事实来源；[action] 已由
  /// `WsInboundType.pluginUiAction` 以**别名**（值不变）登记进 `WsInboundType.all`，
  /// 因此协议完备性门禁的硬断言「每一种上行帧都必须被 core_server 显式处理」
  /// 会强制核心保留 pluginUiAction 分支（不得被 `default` 静默吞掉）。
  static const Set<String> inbound = <String>{action};
}

/// 槽位类型（四类，4.1 契约）。
abstract final class PluginUiSlotKind {
  /// 左侧活动栏项（与「Agent 列表 / 插件 / 下载」并列）。
  static const String activity = 'activity';

  /// 右侧面板 Tab（追加在既有 Tab 之后）。
  static const String panel = 'panel';

  /// 状态栏项（主界面底部细状态栏，仅在有状态项时出现）。
  static const String status = 'status';

  /// 消息流内联卡片（按到达顺序渲染在消息流末尾）。
  static const String card = 'card';

  /// 四类槽位。
  static const Set<String> all = <String>{activity, panel, status, card};
}

/// 视图节点类型：4.1 契约的**受限控件集** + 两个**布局容器**。
///
/// 容器（[row] / [column]）是 4.1 控件清单之外的**前端扩展**：没有容器，一个槽位
/// 只能放一个控件（如「表格 + 按钮组」的面板无法表达）。协议与渲染器都把容器当
/// 普通节点处理，未知类型照旧走占位渲染。
abstract final class PluginUiViewType {
  /// 文本（纯文本 / markdown）。
  static const String text = 'text';

  /// 列表。
  static const String list = 'list';

  /// 表格（columns + rows）。
  static const String table = 'table';

  /// 表单（字段 + 提交）。
  static const String form = 'form';

  /// 进度。
  static const String progress = 'progress';

  /// 按钮组。
  static const String actions = 'actions';

  /// 水平容器。
  static const String row = 'row';

  /// 垂直容器。
  static const String column = 'column';

  /// 全部节点类型（含容器）。
  static const Set<String> all = <String>{
    text,
    list,
    table,
    form,
    progress,
    actions,
    row,
    column,
  };

  /// 4.1 契约明列的六种控件。
  static const Set<String> controls = <String>{
    text,
    list,
    table,
    form,
    progress,
    actions,
  };

  /// 布局容器（4.1 之外的前端扩展）。
  static const Set<String> containers = <String>{row, column};
}

/// 表单字段类型。
abstract final class PluginUiFieldKind {
  /// 单行文本。
  static const String text = 'text';

  /// 多行文本。
  static const String textarea = 'textarea';

  /// 数值（提交时按 num 解析，非法回退原字符串）。
  static const String number = 'number';

  /// 下拉选择（`options` 给出候选项）。
  static const String select = 'select';

  /// 勾选框（提交 bool）。
  static const String checkbox = 'checkbox';

  /// 全部字段类型。
  static const Set<String> all = <String>{text, textarea, number, select, checkbox};
}

/// 按钮样式（仅影响观感，未知值回退 [secondary]）。
abstract final class PluginUiButtonStyle {
  /// 主操作。
  static const String primary = 'primary';

  /// 次操作（默认）。
  static const String secondary = 'secondary';

  /// 危险操作（红色）。
  static const String danger = 'danger';

  /// 全部按钮样式。
  static const Set<String> all = <String>{primary, secondary, danger};
}

/// 单个视图节点：`{"type": <控件类型>, ...字段}`。
///
/// 各控件 / 容器的 JSON 形状（未知键一律忽略、缺失字段走默认值，渲染器不崩）：
///
/// - `text`：`{"type":"text","text":"正文","format":"plain|markdown",
///   "style":"body|title|caption|mono"}`
///   —— `format` 缺省 `plain`；markdown 只经 Flutter 控件渲染（无 webview/iframe），
///   图片一律渲染成占位文本（不发起网络请求）；
/// - `list`：`{"type":"list","items":[<字符串|节点>...],"ordered":false,
///   "empty":"暂无数据"}` —— `items` 元素是标量时按文本渲染，是对象时递归渲染成节点；
/// - `table`：`{"type":"table","columns":["列名"...],"rows":[["单元格"...]...],
///   "caption":""}` —— 单元格只渲染标量文本（非标量用紧凑 JSON 文本兜底）；
/// - `form`：`{"type":"form","fields":[<字段>...],
///   "submit":{"action_id":"save","label":"保存","payload":{}},"note":""}`
///   —— 字段 = `{"key":"name","label":"名称","kind":"text|textarea|number|select|
///   checkbox","value":<任意>,"options":["a","b"],"placeholder":"","required":true,
///   "help":""}`；
/// - `progress`：`{"type":"progress","value":0.42,"label":"下载中","detail":"42%",
///   "indeterminate":false}` —— `value` 缺省或 `indeterminate=true` 时渲染不确定进度；
/// - `actions`：`{"type":"actions","buttons":[<按钮>...],"align":"start|end"}`
///   —— 按钮 = `{"action_id":"refresh","label":"刷新","style":"primary|secondary|
///   danger","enabled":true,"payload":{}}`；
/// - `column` / `row`（容器）：`{"type":"column","children":[<节点>...],"gap":8}`
///   —— `row` 为水平排列（子项按 Expanded 均分宽度）。
///
/// 节点的未知键**原样保留**（[raw]），`toJson()` 原样回吐：插件可携带自己的提示
/// 字段而不被前端剥掉。
class PluginUiNode {
  /// 构造（[raw] 必须含同值 `type` 字段，由 [tryParse] 保证）。
  const PluginUiNode(this.type, this.raw);

  /// 控件 / 容器类型（未知类型原样保留，由渲染器给占位）。
  final String type;

  /// 原始 JSON（含未知键；`toJson()` 原样返回）。
  final Map<String, dynamic> raw;

  /// 宽容解析：非 Map 或缺 `type` 时返回 null（调用方跳过该节点）。
  static PluginUiNode? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final String type = (raw['type'] ?? '').toString();
    if (type.isEmpty) {
      return null;
    }
    return PluginUiNode(type, Map<String, dynamic>.from(raw));
  }

  /// 是否为受限控件集内的类型（含容器）。
  bool get isKnownType => PluginUiViewType.all.contains(type);

  /// 读字符串字段（非字符串按 `toString()` 归一；缺失取 [fallback]）。
  String str(String key, {String fallback = ''}) {
    final Object? value = raw[key];
    if (value == null) {
      return fallback;
    }
    return value is String ? value : value.toString();
  }

  /// 读数值字段（非数值返回 null）。
  double? numOrNull(String key) {
    final Object? value = raw[key];
    return value is num ? value.toDouble() : null;
  }

  /// 读布尔字段（非布尔取 [fallback]）。
  bool boolOr(String key, {bool fallback = false}) {
    final Object? value = raw[key];
    return value is bool ? value : fallback;
  }

  /// 读列表字段（非 List 返回空列表）。
  List<Object?> listOrEmpty(String key) {
    final Object? value = raw[key];
    return value is List ? value : const <Object?>[];
  }

  /// 子节点（容器 `row` / `column` 的 `children`；非节点项被跳过）。
  List<PluginUiNode> get children {
    final List<PluginUiNode> nodes = <PluginUiNode>[];
    for (final Object? item in listOrEmpty('children')) {
      final PluginUiNode? node = PluginUiNode.tryParse(item);
      if (node != null) {
        nodes.add(node);
      }
    }
    return nodes;
  }

  /// 序列化（原样回吐 [raw]，含未知键）。
  Map<String, dynamic> toJson() => raw;
}

/// 槽位视图包络：`data.view` 可以是**单个节点**，也可以是**节点数组**
/// （数组 = 按顺序垂直堆叠，等价于一个隐式 `column`）。
///
/// 保留「原始是数组还是对象」这一形态（[isArray]），`toJson()` 原样还原，
/// 因此解码 → 编码是**无损往返**。
class PluginUiView {
  const PluginUiView._(this.nodes, this.isArray);

  /// 单节点视图。
  factory PluginUiView.of(PluginUiNode node) =>
      PluginUiView._(<PluginUiNode>[node], false);

  /// 节点数组视图（数组形态）。
  factory PluginUiView.array(List<PluginUiNode> nodes) =>
      PluginUiView._(List<PluginUiNode>.unmodifiable(nodes), true);

  /// 空视图（空数组形态）。
  static const PluginUiView empty = PluginUiView._(<PluginUiNode>[], true);

  /// 顶层节点（数组形态时按顺序排列）。
  final List<PluginUiNode> nodes;

  /// 原始 JSON 是否为数组形态。
  final bool isArray;

  /// 是否没有任何节点。
  bool get isEmpty => nodes.isEmpty;

  /// 宽容解析：`Map` → 单节点；`List` → 节点数组（坏条目跳过）；
  /// 其它（含 null）→ null。
  static PluginUiView? tryParse(Object? raw) {
    if (raw is Map) {
      final PluginUiNode? node = PluginUiNode.tryParse(raw);
      return node == null ? null : PluginUiView.of(node);
    }
    if (raw is List) {
      final List<PluginUiNode> nodes = <PluginUiNode>[];
      for (final Object? item in raw) {
        final PluginUiNode? node = PluginUiNode.tryParse(item);
        if (node != null) {
          nodes.add(node);
        }
      }
      return PluginUiView.array(nodes);
    }
    return null;
  }

  /// 序列化（保持原形态：单节点 → 对象；数组 → 数组）。
  Object toJson() {
    if (nodes.isEmpty) {
      return isArray ? <Object?>[] : <String, dynamic>{};
    }
    if (isArray) {
      return nodes.map((PluginUiNode n) => n.toJson()).toList();
    }
    return nodes.first.toJson();
  }
}

/// 表单字段：`{"key","label","kind","value","options","placeholder","required","help"}`。
///
/// 未知键原样保留（[raw]），`toJson()` 原样回吐。
class PluginUiField {
  /// 构造（[raw] 必须含非空 `key`，由 [tryParse] 保证）。
  const PluginUiField(this.key, this.raw);

  /// 字段名（提交 payload 的键）。
  final String key;

  /// 原始 JSON。
  final Map<String, dynamic> raw;

  /// 宽容解析：非 Map 或缺 `key` 时返回 null（跳过该字段）。
  static PluginUiField? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final String key = (raw['key'] ?? '').toString();
    if (key.isEmpty) {
      return null;
    }
    return PluginUiField(key, Map<String, dynamic>.from(raw));
  }

  /// 展示标签（缺省回退 [key]）。
  String get label {
    final String label = (raw['label'] ?? '').toString();
    return label.isEmpty ? key : label;
  }

  /// 字段类型（未知值按 [PluginUiFieldKind.text] 处理）。
  String get kind {
    final String kind = (raw['kind'] ?? '').toString();
    return PluginUiFieldKind.all.contains(kind)
        ? kind
        : PluginUiFieldKind.text;
  }

  /// 初始值。
  Object? get value => raw['value'];

  /// 候选项（[PluginUiFieldKind.select] 用；非标量项按 `toString()` 归一）。
  List<String> get options {
    final List<String> options = <String>[];
    for (final Object? item in (raw['options'] is List
        ? raw['options'] as List<Object?>
        : const <Object?>[])) {
      if (item == null) {
        continue;
      }
      options.add(item is String ? item : item.toString());
    }
    return options;
  }

  /// 输入提示。
  String get placeholder => (raw['placeholder'] ?? '').toString();

  /// 是否必填（渲染器只做提示，不做拦截——拦截交由插件判定）。
  bool get required => raw['required'] == true;

  /// 字段说明。
  String get help => (raw['help'] ?? '').toString();

  /// 序列化（原样回吐 [raw]）。
  Map<String, dynamic> toJson() => raw;
}

/// 按钮：`{"action_id","label","style","enabled","payload"}`。
class PluginUiButton {
  /// 构造（[raw] 必须含非空 `action_id`，由 [tryParse] 保证）。
  const PluginUiButton(this.actionId, this.raw);

  /// 动作 id（回插件时的 [PluginUiAction.actionId]）。
  final String actionId;

  /// 原始 JSON。
  final Map<String, dynamic> raw;

  /// 宽容解析：非 Map 或缺 `action_id` 时返回 null（跳过该按钮）。
  static PluginUiButton? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final String actionId = (raw['action_id'] ?? '').toString();
    if (actionId.isEmpty) {
      return null;
    }
    return PluginUiButton(actionId, Map<String, dynamic>.from(raw));
  }

  /// 按钮文案（缺省回退 [actionId]）。
  String get label {
    final String label = (raw['label'] ?? '').toString();
    return label.isEmpty ? actionId : label;
  }

  /// 样式（未知值回退 [PluginUiButtonStyle.secondary]）。
  String get style {
    final String style = (raw['style'] ?? '').toString();
    return PluginUiButtonStyle.all.contains(style)
        ? style
        : PluginUiButtonStyle.secondary;
  }

  /// 是否可点（缺省 true）。
  bool get enabled => raw['enabled'] != false;

  /// 随按钮附带的 payload（与表单字段值合并后回插件）。
  Map<String, dynamic> get payload {
    final Object? value = raw['payload'];
    return value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};
  }

  /// 序列化（原样回吐 [raw]）。
  Map<String, dynamic> toJson() => raw;
}

/// 一个插件槽位声明（`plugin_ui_manifest.data.slots[]` 元素）。
class PluginUiSlot {
  /// 构造。
  const PluginUiSlot({
    required this.slotKey,
    required this.kind,
    this.pluginId = '',
    this.teamId = '',
    this.title = '',
    this.icon = '',
    this.order = 0,
    this.view = PluginUiView.empty,
  });

  /// 槽位键（**全局唯一**）：更新 / 注销 / 动作回调都按它定位。
  final String slotKey;

  /// 槽位类型（[PluginUiSlotKind] 之一）。
  final String kind;

  /// 归属插件 id（manifest 帧级 `plugin_id`，槽位条目可覆盖）。
  final String pluginId;

  /// 归属 team id（帧级 `team_id`，槽位条目可覆盖）；前端只呈现当前 team 的槽位。
  final String teamId;

  /// 展示名（活动栏 tooltip / 右栏 Tab 文案 / 状态栏文案缺省值）。
  final String title;

  /// 受控图标名（前端映射到 Flutter 图标；未知名回退默认图标）。
  final String icon;

  /// 同类型槽位内的排序权重（小的在前；相同则按 [slotKey] 字典序，保证稳定）。
  final int order;

  /// 该槽位的视图（整块替换）。
  final PluginUiView view;

  /// 宽容解析：非 Map / 缺 `slot_key` / 未知 `slot` 时返回 null（跳过该槽位）。
  ///
  /// [fallbackPluginId] / [fallbackTeamId] 来自 manifest 帧级字段：槽位条目自己
  /// 的 `plugin_id` / `team_id` 优先（缺省时用帧级值兜底）。
  static PluginUiSlot? tryParse(
    Object? raw, {
    String fallbackPluginId = '',
    String fallbackTeamId = '',
  }) {
    if (raw is! Map) {
      return null;
    }
    final String slotKey = (raw['slot_key'] ?? '').toString();
    final String kind = (raw['slot'] ?? raw['slot_kind'] ?? '').toString();
    if (slotKey.isEmpty || !PluginUiSlotKind.all.contains(kind)) {
      return null;
    }
    final String pluginId = (raw['plugin_id'] ?? '').toString();
    final String teamId = (raw['team_id'] ?? '').toString();
    final Object? rawOrder = raw['order'];
    return PluginUiSlot(
      slotKey: slotKey,
      kind: kind,
      pluginId: pluginId.isEmpty ? fallbackPluginId : pluginId,
      teamId: teamId.isEmpty ? fallbackTeamId : teamId,
      title: (raw['title'] ?? '').toString(),
      icon: (raw['icon'] ?? '').toString(),
      order: rawOrder is num ? rawOrder.toInt() : 0,
      view: PluginUiView.tryParse(raw['view']) ?? PluginUiView.empty,
    );
  }

  /// 复制并整块替换视图（[PluginUiUpdate] 用；不做 diff）。
  PluginUiSlot copyWithView(PluginUiView view) => PluginUiSlot(
        slotKey: slotKey,
        kind: kind,
        pluginId: pluginId,
        teamId: teamId,
        title: title,
        icon: icon,
        order: order,
        view: view,
      );

  /// 序列化为槽位声明 JSON（帧级字段不回填；视图原样）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'slot_key': slotKey,
        'slot': kind,
        if (pluginId.isNotEmpty) 'plugin_id': pluginId,
        if (teamId.isNotEmpty) 'team_id': teamId,
        if (title.isNotEmpty) 'title': title,
        if (icon.isNotEmpty) 'icon': icon,
        'order': order,
        'view': view.toJson(),
      };
}

/// `plugin_ui_manifest` 帧载荷：某插件的槽位声明。
///
/// 完整帧形状：
/// ```json
/// {
///   "type": "plugin_ui_manifest",
///   "data": {
///     "plugin_id": "demo.plugin",
///     "team_id": "team_1",
///     "slots": [ { "slot_key": "...", "slot": "activity", "title": "示例",
///                  "icon": "extension", "order": 10, "view": { ... } } ]
///   }
/// }
/// ```
class PluginUiManifest {
  /// 构造。
  const PluginUiManifest({
    required this.pluginId,
    this.teamId = '',
    this.slots = const <PluginUiSlot>[],
  });

  /// 插件 id（槽位归属；空则整帧丢弃）。
  final String pluginId;

  /// 帧级 team id（槽位可各自覆盖）。
  final String teamId;

  /// 槽位声明（坏条目已在解析时跳过）。
  final List<PluginUiSlot> slots;

  /// 从帧的 `data` 载荷解析；缺 `plugin_id` 返回 null（fail-closed）。
  static PluginUiManifest? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final String pluginId = (raw['plugin_id'] ?? '').toString();
    if (pluginId.isEmpty) {
      return null;
    }
    final String teamId = (raw['team_id'] ?? '').toString();
    final List<PluginUiSlot> slots = <PluginUiSlot>[];
    final Object? rawSlots = raw['slots'];
    if (rawSlots is List) {
      for (final Object? item in rawSlots) {
        final PluginUiSlot? slot = PluginUiSlot.tryParse(
          item,
          fallbackPluginId: pluginId,
          fallbackTeamId: teamId,
        );
        if (slot != null) {
          slots.add(slot);
        }
      }
    }
    return PluginUiManifest(pluginId: pluginId, teamId: teamId, slots: slots);
  }

  /// 从完整 WS 帧解析（`type` 不匹配返回 null）。
  static PluginUiManifest? fromFrame(Map<String, dynamic> frame) {
    if (frame['type'] != PluginUiFrameType.manifest) {
      return null;
    }
    return tryParse(frame['data']);
  }

  /// 载荷 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'plugin_id': pluginId,
        'team_id': teamId,
        'slots': slots.map((PluginUiSlot s) => s.toJson()).toList(),
      };

  /// 完整 WS 帧。
  Map<String, dynamic> toFrame() => <String, dynamic>{
        'type': PluginUiFrameType.manifest,
        'data': toJson(),
      };
}

/// `plugin_ui_update` 帧载荷：按 `slot_key` **整块替换**某槽位视图。
///
/// 完整帧形状：
/// ```json
/// {
///   "type": "plugin_ui_update",
///   "data": {
///     "plugin_id": "demo.plugin",
///     "team_id": "team_1",
///     "slot_key": "demo.plugin.status.1",
///     "view": { ... }        // 缺省 / null ⇒ 注销该槽位
///   }
/// }
/// ```
class PluginUiUpdate {
  /// 构造（[view] 为 null 表示注销该槽位）。
  const PluginUiUpdate({
    required this.slotKey,
    this.pluginId = '',
    this.teamId = '',
    this.view,
  });

  /// 插件 id。
  final String pluginId;

  /// team id（team 过滤口径与 manifest 一致）。
  final String teamId;

  /// 目标槽位键。
  final String slotKey;

  /// 新视图（null = 注销该槽位）。
  final PluginUiView? view;

  /// 从帧的 `data` 载荷解析；缺 `slot_key` 返回 null。
  static PluginUiUpdate? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final String slotKey = (raw['slot_key'] ?? '').toString();
    if (slotKey.isEmpty) {
      return null;
    }
    return PluginUiUpdate(
      slotKey: slotKey,
      pluginId: (raw['plugin_id'] ?? '').toString(),
      teamId: (raw['team_id'] ?? '').toString(),
      view: PluginUiView.tryParse(raw['view']),
    );
  }

  /// 从完整 WS 帧解析（`type` 不匹配返回 null）。
  static PluginUiUpdate? fromFrame(Map<String, dynamic> frame) {
    if (frame['type'] != PluginUiFrameType.update) {
      return null;
    }
    return tryParse(frame['data']);
  }

  /// 载荷 JSON（[view] 为 null 时保留 `"view": null`，语义显式）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'plugin_id': pluginId,
        'team_id': teamId,
        'slot_key': slotKey,
        'view': view?.toJson(),
      };

  /// 完整 WS 帧。
  Map<String, dynamic> toFrame() => <String, dynamic>{
        'type': PluginUiFrameType.update,
        'data': toJson(),
      };
}

/// `plugin_ui_action` 帧载荷：用户在插件视图上的交互回调（前端 → 核心）。
///
/// 完整帧形状：
/// ```json
/// {
///   "type": "plugin_ui_action",
///   "data": {
///     "plugin_id": "demo.plugin",
///     "team_id": "team_1",
///     "agent_id": "agent_1",
///     "session_id": "session_default",
///     "slot_key": "demo.plugin.panel.1",
///     "action_id": "save",
///     "payload": { "name": "x" }     // 表单提交时含各字段值
///   }
/// }
/// ```
class PluginUiAction {
  /// 构造。
  const PluginUiAction({
    required this.slotKey,
    required this.actionId,
    this.pluginId = '',
    this.teamId = '',
    this.agentId = '',
    this.sessionId = '',
    this.payload = const <String, dynamic>{},
  });

  /// 触发交互的槽位键。
  final String slotKey;

  /// 动作 id（按钮的 `action_id`，或表单 `submit.action_id`）。
  final String actionId;

  /// 归属插件 id（由槽位归属填充，便于核心路由到插件）。
  final String pluginId;

  /// 当前 team（隔离四元组成员之一）。
  final String teamId;

  /// 当前 agent（隔离四元组成员之一；可为空）。
  final String agentId;

  /// 当前会话（隔离四元组成员之一；可为空）。
  final String sessionId;

  /// 动作载荷：按钮点击 = 按钮 `payload`；表单提交 = `submit.payload` 与字段值
  /// 合并（**字段值覆盖同名键**）。
  final Map<String, dynamic> payload;

  /// 从帧的 `data` 载荷解析；缺 `slot_key` / `action_id` 返回 null。
  static PluginUiAction? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final String slotKey = (raw['slot_key'] ?? '').toString();
    final String actionId = (raw['action_id'] ?? '').toString();
    if (slotKey.isEmpty || actionId.isEmpty) {
      return null;
    }
    final Object? rawPayload = raw['payload'];
    return PluginUiAction(
      slotKey: slotKey,
      actionId: actionId,
      pluginId: (raw['plugin_id'] ?? '').toString(),
      teamId: (raw['team_id'] ?? '').toString(),
      agentId: (raw['agent_id'] ?? '').toString(),
      sessionId: (raw['session_id'] ?? '').toString(),
      payload: rawPayload is Map
          ? Map<String, dynamic>.from(rawPayload)
          : const <String, dynamic>{},
    );
  }

  /// 从完整 WS 帧解析（`type` 不匹配返回 null）。
  static PluginUiAction? fromFrame(Map<String, dynamic> frame) {
    if (frame['type'] != PluginUiFrameType.action) {
      return null;
    }
    return tryParse(frame['data']);
  }

  /// 载荷 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'plugin_id': pluginId,
        'team_id': teamId,
        'agent_id': agentId,
        'session_id': sessionId,
        'slot_key': slotKey,
        'action_id': actionId,
        'payload': payload,
      };

  /// 完整 WS 帧（前端 [WebSocketService.send] 直接发它）。
  Map<String, dynamic> toFrame() => <String, dynamic>{
        'type': PluginUiFrameType.action,
        'data': toJson(),
      };
}
