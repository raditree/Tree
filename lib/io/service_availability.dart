import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:tree_protocol/tree_protocol.dart';

/// 领域服务不可用的**全局可见状态**（G-7 / L-07）。
///
/// 背景：领域端点已下沉到插件，核心委派层在「归属插件已停用 / 启动失败 / 崩溃」时
/// 回 **503 + 可读原因**（见 `docs/pluginization/ui-pluginization.md` §5.3）。
/// 以前 UI 只在各自页面的 catch 里显示一行错误，用户看不出"是整个 agent 服务挂了"
/// 还是"这一次请求失败"——所以这里把 503 抬到主界面顶部提示条。
///
/// 只做一件事：记住最近一次 503 的原因，并在后续**领域端点**成功后清空。
/// 平台面端点（`/api/plugin`、`/api/meta`、`/api/logs`、`/api/store`、`/api/settings`）
/// 永远由核心自己承接，它们成功不代表领域服务恢复，因此不参与清空。
class ServiceAvailability {
  ServiceAvailability._();

  /// null = 正常；非 null = 给用户看的可读原因（"服务不可用：…"）。
  static final ValueNotifier<String?> reason = ValueNotifier<String?>(null);

  /// 平台面路径前缀：这些请求的成败与领域服务无关。
  ///
  /// 前缀集合取自协议常量（外加 settings 段的根），不在这里重复写 `/api/...` 字面量
  /// ——协议包有门禁会扫前端源码里的路径字面量。
  static final List<String> _platformPrefixes = <String>[
    ...ApiPaths.reservedDelegationPrefixes,
    _rootOf(ApiPaths.settingsFrameRate),
  ];

  /// 记一次 503（详情为空时给一句兜底文案）。
  static void reportUnavailable(String detail) {
    final String text = detail.trim();
    reason.value = text.isEmpty ? '依赖的插件服务不可用' : text;
  }

  /// 记一次领域端点成功：恢复后自动撤掉提示条。
  static void reportAvailable(String path) {
    if (reason.value == null) return;
    if (_isPlatform(path)) return;
    reason.value = null;
  }

  /// 手动关闭提示条（用户点「知道了」；下一次 503 会再出现）。
  static void dismiss() {
    reason.value = null;
  }

  static bool _isPlatform(String path) {
    for (final String prefix in _platformPrefixes) {
      if (path.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 去掉最后一段（`/api/settings/frame-rate` → `/api/settings`）。
  static String _rootOf(String path) {
    final int at = path.lastIndexOf('/');
    return at <= 0 ? path : path.substring(0, at);
  }
}
