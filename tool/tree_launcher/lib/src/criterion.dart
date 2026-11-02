/// 引导壳判据（**纯函数**，不碰 IO / 进程，便于单测与复用）。
///
/// 判据（用户 2026-11-01 钉死，**配置口径**，不看连接）：
/// - 启动时 `plugins.yaml` 里存在**启用状态**的 `runtime: ui` 插件 ⇒ **不开**引导页
///   （核心已经/即将按清单拉起它，loader 不该再弹浏览器页去抢戏）；
/// - 不存在 ⇒ **开**引导页（**即使界面已下载但被停用**也算“不存在”：用户停用它就是
///   不想要它，引导页才是他重新打开的入口）。
///
/// 为什么不用“存活连接 + plugin.manage”那套旧口径：核心刚拉起时界面还没握手上，
/// 那个判据必然判成“需要引导”，普通用户就会看到“桌面窗口 + 浏览器引导页”双开；
/// 而“有启用的 UI 插件、但它没连上”该由核心的实例健康度报出来，不是 loader 的事。
library;

/// `runtime` 里代表“图形界面插件”的归一化值（与核心 `PluginRuntime` 同口径）。
const String uiRuntimeValue = 'ui';

/// 一条 `/api/plugin/snapshot` 的 `config.plugins[]` 判定视图。
class PluginConfigView {
  const PluginConfigView({
    required this.pluginId,
    required this.runtime,
    required this.enabled,
  });

  final String pluginId;

  /// 归一化后的 runtime（空串 = 清单没写，按 headless 处理）。
  final String runtime;

  final bool enabled;

  /// 是不是**启用中的界面插件**（判据的唯一条件）。
  bool get isEnabledUi =>
      enabled && runtime.trim().toLowerCase() == uiRuntimeValue;
}

/// 把 `/api/plugin/snapshot` 解析成判定视图（宽容：坏数据 = 空清单）。
///
/// 后端不详 / 字段缺失的那些条目一律跳过：它们不是“可用的界面”，但也不阻止
/// 别的好条目被认出来。
List<PluginConfigView> parsePluginConfigs(Object? snapshotJson) {
  if (snapshotJson is! Map) return const <PluginConfigView>[];
  final Object? config = snapshotJson['config'];
  if (config is! Map) return const <PluginConfigView>[];
  final Object? plugins = config['plugins'];
  if (plugins is! List) return const <PluginConfigView>[];
  final List<PluginConfigView> out = <PluginConfigView>[];
  for (final Object? item in plugins) {
    if (item is! Map) continue;
    // 快照口径是 `plugin_id`（见核心 `PluginConfig.toApiJson()`）；`id` 只在
    // `plugins.yaml` 里出现。两者都认，免得判据因为键名不同而永远读不到条目
    // （2026-11-01 实机：读 `id` 时全部被跳过 ⇒ 误开引导页 + 桌面窗口）。
    final Object? rawId = item['plugin_id'] ?? item['id'];
    final String id = rawId?.toString().trim() ?? '';
    if (id.isEmpty) continue;
    out.add(
      PluginConfigView(
        pluginId: id,
        runtime: (item['runtime'] ?? '').toString(),
        // 缺省 enabled = 开（与 plugins.yaml 的口径一致）。
        enabled: item['enabled'] != false,
      ),
    );
  }
  return out;
}

/// 快照够不够用来下结论（`config.plugins[]` 必须真的读到了）。
///
/// 核心刚握手时 HTTP 可能已经通、但插件总线还在预热（`_warmUpPeripheralsAfterHandshake`
/// 在 3s 预算内播种默认界面并 `plugins.start()`），此时 `config.plugins` 可能是空数组
/// 甚至没有 `config` 段 —— 那是“还没准备好”，不是“没有界面插件”。loader 必须区分
/// 两件事并按重试处理，否则会在一开机就误开引导页。
bool snapshotReady(Object? snapshotJson) {
  if (snapshotJson is! Map) return false;
  final Object? config = snapshotJson['config'];
  if (config is! Map) return false;
  final Object? plugins = config['plugins'];
  return plugins is List;
}

/// 启用中的 UI 插件 id（launcher 用它在没窗口时补发 restart）。
Set<String> enabledUiPluginIdsOf(Object? snapshotJson) => <String>{
  for (final PluginConfigView view in parsePluginConfigs(snapshotJson))
    if (view.isEnabledUi) view.pluginId,
};

/// 是否必须打开引导页（**配置判据**，见文件头）。
///
/// [snapshotJson] 读不到结论（见 [snapshotReady]）时返回 **false**：宁可不开引导页
/// （核心启动失败已在握手阶段报错；误开一张浏览器页反而更像“坏了”）——调用方会在
/// 重试耗尽后打印一条可读提示。
bool needsBootstrapByConfig(Object? snapshotJson) {
  if (!snapshotReady(snapshotJson)) return false;
  return enabledUiPluginIdsOf(snapshotJson).isEmpty;
}

/// 从 `/api/meta` 取生效品牌里可用的 `.ico` 绝对路径（role=exe）。
///
/// 只接受 `role == "exe"` 且路径以 `.ico` 结尾（Windows 快捷方式只认 ico）；
/// 其余一律 `null`（回默认图标）。纯函数，文件存在性由调用方校验。
String? shortcutIconOf(Object? metaJson) {
  if (metaJson is! Map) return null;
  final Object? branding = metaJson['branding'];
  if (branding is! Map) return null;
  if (branding['role']?.toString() != 'exe') return null;
  final String icon = (branding['icon'] ?? '').toString().trim();
  if (icon.isEmpty) return null;
  if (!icon.toLowerCase().endsWith('.ico')) return null;
  return icon;
}
