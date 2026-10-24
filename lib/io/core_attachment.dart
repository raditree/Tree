import 'dart:io';

import 'package:path/path.dart' as p;

/// UI 插件对**已运行核心**的附着信息（U1 起唯一来源）。
///
/// UI 不再拥有核心的生命周期：核心的 `UiHost` 拉起 `tree_ui.exe` 并注入
/// `TREE_CORE_URL` / `TREE_CORE_TOKEN`，本类只负责读取、校验、拼出 REST 与 WS
/// 基址。**绝不 spawn 核心**——启动顺序是「loader → 核心 → UI 插件」。
///
/// 开发期仍可用 `--dart-define=TREE_CORE_URL=...`
/// `--dart-define=TREE_CORE_TOKEN=...` 覆盖（见 `tool/dev_run.ps1`）。
class CoreAttachment {
  CoreAttachment._();

  /// 全局单例（一个 UI 进程只附着到一个核心）。
  static final CoreAttachment instance = CoreAttachment._();

  /// 核心 WS 基址（由 `UiHost` 注入，形如 `ws://127.0.0.1:54321`）。
  static const String envUrl = 'TREE_CORE_URL';

  /// 核心一次性本地 token。
  static const String envToken = 'TREE_CORE_TOKEN';

  /// 数据根（loader 与核心共用的键；没有就为空串，**不猜** `%APPDATA%\Tree`）。
  static const String envDataRoot = 'TREE_DATA_ROOT';

  /// 旧调试口径的数据根键（兼容环境变量）。
  static const String envHome = 'TREE_HOME';

  /// 开发期 `--dart-define` 覆盖（编译期常量，空串 = 不用）。
  static const String defineUrl = String.fromEnvironment('TREE_CORE_URL');
  static const String defineToken = String.fromEnvironment('TREE_CORE_TOKEN');

  /// REST 基址（`http://host:port`）；未附着时为空串。
  String httpBaseUrl = '';

  /// WS 基址（`ws://host:port`）；未附着时为空串。
  String wsBaseUrl = '';

  /// 本地 token；未附着时为空串。
  String token = '';

  /// 核心数据根（日志 / 用量账本的读入口）；拿不到时为空串。
  String dataRoot = '';

  /// 最近一次附着失败的可读原因（启动错误页展示）。
  String lastError = '';

  /// 显式锁键（`TREE_INSTANCE_KEY`，多开调试用）；空串 = 按核心地址推导。
  String _keyOverride = '';

  /// 是否已附着。
  bool get isAttached =>
      httpBaseUrl.isNotEmpty && wsBaseUrl.isNotEmpty && token.isNotEmpty;

  /// 单实例锁键：**同一核心**只允许一个 UI 实例（不同核心 / 不同端口互不干扰）。
  String get instanceKey {
    if (_keyOverride.isNotEmpty) return _keyOverride;
    return isAttached ? 'ui:$wsBaseUrl' : 'ui:unattached';
  }

  /// 核心日志文件路径（`<数据根>/logs/core.log`）；无数据根时为空串。
  String get coreLogFile =>
      dataRoot.isEmpty ? '' : p.join(dataRoot, 'logs', 'core.log');

  /// 读取环境变量并构造连接信息；失败返回 false 并写入 [lastError]。
  ///
  /// [env] 仅测试注入用。`--dart-define` 优先于进程环境变量（开发期覆盖）。
  bool attach({Map<String, String>? env}) {
    final Map<String, String> source = env ?? Platform.environment;
    final String rawUrl = _firstNonEmpty(<String>[
      defineUrl,
      source[envUrl] ?? '',
    ]);
    final String rawToken = _firstNonEmpty(<String>[
      defineToken,
      source[envToken] ?? '',
    ]);
    dataRoot = _firstNonEmpty(<String>[
      source[envDataRoot] ?? '',
      source[envHome] ?? '',
    ]);
    _keyOverride = (source['TREE_INSTANCE_KEY'] ?? '').trim();

    if (rawUrl.isEmpty || rawToken.isEmpty) {
      final List<String> missing = <String>[
        if (rawUrl.isEmpty) envUrl,
        if (rawToken.isEmpty) envToken,
      ];
      lastError =
          '未附着到核心：缺少环境变量 ${missing.join(' / ')}。\n'
          '作为 UI 插件运行时，这两个变量由核心的 UiHost 注入（不要自己拉起核心）。\n'
          '开发期请用 tool/dev_run.ps1 启动（先起核心再带 --dart-define 运行 UI），\n'
          '或手动设置这两个环境变量后再运行。';
      return false;
    }

    final Uri? uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty || uri.port == 0) {
      lastError = '环境变量 $envUrl 不是合法地址：$rawUrl\n'
          '期望形如 ws://127.0.0.1:<port>（也接受 http://）。';
      return false;
    }

    final bool secure = uri.scheme == 'https' || uri.scheme == 'wss';
    httpBaseUrl = Uri(
      scheme: secure ? 'https' : 'http',
      host: uri.host,
      port: uri.port,
    ).toString();
    wsBaseUrl = Uri(
      scheme: secure ? 'wss' : 'ws',
      host: uri.host,
      port: uri.port,
    ).toString();
    token = rawToken;
    lastError = '';
    return true;
  }

  static String _firstNonEmpty(List<String> values) {
    for (final String value in values) {
      if (value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }
}
