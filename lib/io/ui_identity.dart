import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_version.dart';

/// UI 插件的**身份**（`ui.hello` 的来源）。
///
/// 身份优先读可执行体同目录的 `plugin.json`（插件安装后的真实形态）；
/// 开发期 `flutter run` 没有清单，则退回内置默认 id 并**不发送 hello**——
/// 未在 `plugins.yaml` 声明的 id 会让核心 `_rejectAndClose` 掉整条连接，
/// 开发回路会直接断掉。这正是 U3 的取舍：**装成插件才声明身份**。
class UiIdentity {
  const UiIdentity({
    required this.pluginId,
    required this.version,
    required this.capabilities,
    required this.fromManifest,
    this.error = '',
  });

  /// 打包清单里的默认 id（与 `plugin.json` 一致）。
  static const String defaultPluginId = 'tree.ui.default';

  /// 本界面确实实现了插件管理（引导页 / 插件面板），据此参与"是否需要引导页"的聚合。
  static const String capabilityPluginManage = 'plugin.manage';

  /// `ui.hello` 的帧类型名（协议包里的同一字面量）。
  static const String helloType = 'ui.hello';

  final String pluginId;
  final String version;

  /// 能力声明（默认 `plugin.manage`）。
  final List<String> capabilities;

  /// 是否来自同目录 `plugin.json`（只有 true 才发 `ui.hello`）。
  final bool fromManifest;

  /// 清单读取失败的可读原因（仅诊断用，不阻断启动）。
  final String error;

  /// 连上核心后要发的握手帧；`fromManifest` 为 false 时返回 null（不发）。
  Map<String, dynamic>? helloFrame() {
    if (!fromManifest || pluginId.isEmpty) return null;
    return <String, dynamic>{
      'type': helloType,
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'version': version,
        'capabilities': capabilities,
      },
    };
  }

  /// 读取身份：默认从 `Platform.resolvedExecutable` 同目录的 `plugin.json` 取。
  ///
  /// [appDir] / [manifestPath] 仅供测试注入。
  static UiIdentity load({Directory? appDir, String? manifestPath}) {
    final String path = manifestPath ??
        p.join(
          (appDir ?? File(Platform.resolvedExecutable).parent).path,
          'plugin.json',
        );
    final File file = File(path);
    if (!file.existsSync()) {
      return const UiIdentity(
        pluginId: defaultPluginId,
        version: kAppVersion,
        capabilities: <String>[capabilityPluginManage],
        fromManifest: false,
      );
    }
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        return _fallback('$path 不是 JSON 对象');
      }
      final Object? rawId = decoded['id'];
      final String id = rawId == null ? '' : rawId.toString().trim();
      if (id.isEmpty) return _fallback('$path 缺少 id');
      final Object? rawVersion = decoded['version'];
      final String version = rawVersion == null
          ? kAppVersion
          : rawVersion.toString().trim();
      return UiIdentity(
        pluginId: id,
        version: version.isEmpty ? kAppVersion : version,
        capabilities: const <String>[capabilityPluginManage],
        fromManifest: true,
      );
    } catch (error) {
      return _fallback('读 $path 失败：$error');
    }
  }

  static UiIdentity _fallback(String error) => UiIdentity(
    pluginId: defaultPluginId,
    version: kAppVersion,
    capabilities: const <String>[capabilityPluginManage],
    fromManifest: false,
    error: error,
  );
}
