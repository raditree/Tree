import 'package:shared_preferences/shared_preferences.dart';

/// MCP 启动命令信任存储：第三方 MCP 服务的首次确认授权（本地 / SSH 宿主）。
///
/// 后端对「非可信启动器」注册的服务下发 ``needs_confirmation``：该服务在本地 /
/// SSH 宿主上首次拉起前，必须由用户确认其**启动命令**可信，否则宿主侧拒绝启动
/// 并返回可读错误，由「MCP 配置」面板引导用户确认。确认结果以**启动命令指纹**
/// 的形式持久化在本端，后续同一命令直接放行。
///
/// 指纹由「命令 + 参数」规范化得到（``\x00`` 分隔，仅去首尾空白）：参数决定
/// 实际运行的包/脚本，必须纳入信任范围。服务注册是全局的（DB 中一份配置对所
/// 有 team 与三种模式生效），故信任也全局共享，不按 team / 主机区分。
class McpTrustStore {
  McpTrustStore._();

  /// SharedPreferences 键：已信任的启动命令指纹列表。
  static const String _kTrustedKey = 'mcp_trusted_commands';

  /// 计算启动命令指纹（[isTrusted] / [trust] / [revoke] 的入参）。
  ///
  /// 不做路径解析与大小写归一：不同形态的命令（``npx`` 与
  /// ``C:\...\npx.cmd``）本就是两条不同配置，各自独立确认更安全，也避免
  /// 解析结果在本地宿主与远端宿主上不一致。
  static String fingerprint(String command, List<String> args) {
    return <String>[command.trim(), ...args].join('\u0000');
  }

  /// 该指纹是否已被用户确认信任。
  static Future<bool> isTrusted(String fingerprint) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kTrustedKey) ?? <String>[])
        .contains(fingerprint);
  }

  /// 记录一条信任授权（幂等）。
  static Future<void> trust(String fingerprint) async {
    if (fingerprint.isEmpty) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> trusted =
        prefs.getStringList(_kTrustedKey) ?? <String>[];
    if (trusted.contains(fingerprint)) return;
    await prefs.setStringList(
      _kTrustedKey,
      <String>[...trusted, fingerprint],
    );
  }

  /// 撤销一条信任授权（幂等）。
  static Future<void> revoke(String fingerprint) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> trusted =
        prefs.getStringList(_kTrustedKey) ?? <String>[];
    if (!trusted.contains(fingerprint)) return;
    await prefs.setStringList(
      _kTrustedKey,
      trusted.where((String e) => e != fingerprint).toList(),
    );
  }

  /// 校验启动授权：``needsConfirmation`` 为真且指纹未被信任时返回**面向用户
  /// 的错误信息**（宿主侧据此拒绝启动），否则返回 null。
  ///
  /// 本地与 SSH 宿主共用本方法，确保两侧的拒绝语义与提示完全一致。
  static Future<String?> checkLaunch(
    String command,
    List<String> args, {
    required bool needsConfirmation,
  }) async {
    if (!needsConfirmation) return null;
    if (await isTrusted(fingerprint(command, args))) return null;
    final String cli = <String>[command, ...args].join(' ');
    return 'MCP 服务启动命令未获信任，已拒绝启动：$cli；'
        '请在右侧「MCP 配置」中确认该命令后再使用';
  }
}
