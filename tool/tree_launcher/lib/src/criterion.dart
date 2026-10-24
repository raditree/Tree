/// 引导壳判据（**纯函数**，不碰 IO / 进程，便于单测与复用）。
///
/// 判据：**不存在任何"存活"的 UI 连接声明 `plugin.manage`** 时需要打开引导页。
/// 三种都开：
/// 1. 零连接；
/// 2. 只剩不具备 `plugin.manage` 的 UI；
/// 3. 具备该能力的条目被停用（`disabledPluginIds`）。
library;

/// 需要 UI 管理能力的 capability 名（与设计 §7.1 一手证据一致）。
const String pluginManageCapability = 'plugin.manage';

/// 一条 `/api/meta.ui[]` 的可判定视图。
class UiConnectionView {
  const UiConnectionView({
    required this.pluginId,
    required this.connections,
    required this.canManagePlugins,
  });

  final String pluginId;
  final int connections;
  final bool canManagePlugins;

  bool get alive => connections > 0;

  bool get usable => alive && canManagePlugins;
}

/// 把 `/api/meta` 的原始 JSON 解析成可判定视图（宽容：坏数据 = 零连接）。
List<UiConnectionView> parseUiConnections(Object? rawUi) {
  if (rawUi is! List) return const <UiConnectionView>[];
  final List<UiConnectionView> out = <UiConnectionView>[];
  for (final Object? item in rawUi) {
    if (item is! Map) continue;
    final Object? idValue = item['plugin_id'];
    final Object? countValue = item['connections'];
    final Object? capsValue = item['capabilities'];
    final int connections = countValue is num ? countValue.toInt() : 0;
    final bool manages = capsValue is List &&
        capsValue.any((Object? cap) => cap?.toString() == pluginManageCapability);
    out.add(
      UiConnectionView(
        pluginId: idValue?.toString() ?? '',
        connections: connections < 0 ? 0 : connections,
        canManagePlugins: manages,
      ),
    );
  }
  return out;
}

/// 是否必须打开引导页。
///
/// [disabledPluginIds]：被停用的插件 id（loader 从 `/api/plugin/snapshot` 的
/// `config.plugins[].enabled == false` 收集）。能力条目被停用 ⇒ 即使还留着一条
/// 陈旧连接，也按"没有可用管理界面"处理。
bool needsBootstrap(
  Object? metaJson, {
  Set<String> disabledPluginIds = const <String>{},
}) {
  if (metaJson is! Map) return true;
  final List<UiConnectionView> ui = parseUiConnections(metaJson['ui']);
  for (final UiConnectionView entry in ui) {
    if (!entry.usable) continue;
    if (disabledPluginIds.contains(entry.pluginId)) continue;
    return false;
  }
  return true;
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

/// 从 `/api/plugin/snapshot` 的原始 JSON 里收集被停用的插件 id。
Set<String> disabledPluginIdsOf(Object? snapshotJson) {
  if (snapshotJson is! Map) return const <String>{};
  final Object? config = snapshotJson['config'];
  if (config is! Map) return const <String>{};
  final Object? plugins = config['plugins'];
  if (plugins is! List) return const <String>{};
  final Set<String> out = <String>{};
  for (final Object? item in plugins) {
    if (item is! Map) continue;
    final Object? enabled = item['enabled'];
    if (enabled == false) {
      final Object? id = item['id'];
      if (id != null) out.add(id.toString());
    }
  }
  return out;
}
