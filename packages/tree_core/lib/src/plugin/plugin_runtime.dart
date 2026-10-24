/// 插件运行形态的**唯一口径**（片 D）。
///
/// 只认两档：
/// - `ui`：由 [UiHost] 直接拉起进程，插件自己连 `TREE_CORE_URL` / WS 站点总线；
/// - `headless`：走既有 [PluginHost] 的 stdio 协议（hello / tools / 心跳）。
///
/// 历史清单里的 `binary` / `python`、空串、以及任意其它未知值一律归一化为
/// `headless`，并打上 `legacy = true`（面板据此提示「清单待升级」）。
/// **刻意不按语言枚举白名单**：运行形态只有「UI / 无头」两档，语言是清单里的
/// 实现细节，核心任何地方都不应出现「如果是 python 就…… / 如果是 binary 就……」。
library;

/// 运行形态的两档。
enum PluginRuntimeKind {
  /// UI 插件：进程自己连核心（窗口 / 站点总线）。
  ui,

  /// 无头插件：核心通过 stdio 握手与它通信。
  headless,
}

/// 归一化结果（原始值一并带出，供面板展示「待升级」）。
class PluginRuntimeInfo {
  const PluginRuntimeInfo({
    required this.kind,
    required this.legacy,
    required this.raw,
  });

  final PluginRuntimeKind kind;

  /// true = 这条清单不是新口径（空串 / `binary` / `python` / 未知值）。
  final bool legacy;

  /// 清单里写的原始 runtime（给索引 / 面板展示用）。
  final String raw;

  /// 归一化后的字符串值（`ui` / `headless`）。
  String get value => kind.name;
}

/// runtime 归一化的唯一入口。
abstract final class PluginRuntime {
  static const String ui = 'ui';
  static const String headless = 'headless';

  /// 归一化任意 runtime 字符串。
  ///
  /// - `ui` → ui（非 legacy）；
  /// - `headless` → headless（非 legacy）；
  /// - 空串 / `binary` / `python` / 任意其它未知值 → headless + legacy。
  static PluginRuntimeInfo parse(String raw) {
    final String value = raw.trim().toLowerCase();
    if (value == ui) {
      return PluginRuntimeInfo(
        kind: PluginRuntimeKind.ui,
        legacy: false,
        raw: raw,
      );
    }
    if (value == headless) {
      return PluginRuntimeInfo(
        kind: PluginRuntimeKind.headless,
        legacy: false,
        raw: raw,
      );
    }
    return PluginRuntimeInfo(
      kind: PluginRuntimeKind.headless,
      legacy: true,
      raw: raw,
    );
  }

  /// 是否归一化为 UI 形态（`ui.hello` 身份校验用）。
  static bool isUi(String raw) => parse(raw).kind == PluginRuntimeKind.ui;
}
