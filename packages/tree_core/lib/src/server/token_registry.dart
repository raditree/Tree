import 'dart:math';

import 'package:tree_protocol/tree_protocol.dart';

import '../util/token.dart';

/// token 的作用域。
enum TokenScope {
  /// 主 token：核心启动时生成，全权。
  primary,

  /// 引导票据：loader 申请、短时、单次使用；只能换页面/换会话。
  bootstrapTicket,

  /// 引导会话 token：插件管理页使用，10 分钟，只放行插件端点与 `GET /api/meta`。
  bootstrapSession,
}

/// 一次已解析的 token 访问。
class TokenAccess {
  const TokenAccess(this.scope);

  final TokenScope scope;

  bool get isPrimary => scope == TokenScope.primary;

  bool get isBootstrapSession => scope == TokenScope.bootstrapSession;
}

/// 单条 token 记录。
class TokenEntry {
  TokenEntry({
    required this.scope,
    required this.expiresAt,
    required this.singleUse,
  });

  final TokenScope scope;
  final DateTime expiresAt;
  final bool singleUse;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// token 作用域注册表。
///
/// 设计约束（片 E / 5.1）：
/// - 主 token 的行为**逐字不变**：`Authorization: Bearer <token>` 全端点放行。
/// - 引导票据单次、短时，只能拿去打开引导页或换会话 token。
/// - 引导会话 token 只放行插件端点与 `GET /api/meta`，越权一律 403 可读。
class TokenRegistry {
  TokenRegistry({
    required this.primaryToken,
    this.ticketTtl = const Duration(minutes: 5),
    this.sessionTtl = const Duration(minutes: 10),
    DateTime Function()? clock,
    this.log,
  }) : _clock = clock ?? DateTime.now;

  /// 主 token（核心启动时生成）。
  final String primaryToken;

  /// 票据有效期（loader 打开引导页的那一张）。
  final Duration ticketTtl;

  /// 会话 token 有效期（引导页内的那一张）。
  final Duration sessionTtl;

  final DateTime Function() _clock;
  final void Function(String message)? log;

  final Map<String, TokenEntry> _entries = <String, TokenEntry>{};
  final Random _random = Random.secure();

  /// 插件端点白名单：`{token → 方法集合}`。
  ///
  /// 会话 token **只**能请求这里列出的路径；`GET /api/meta` 是唯一的非插件端点。
  /// 用 `{id}` 占位符表示一段任意非空路径。测试直接固化此表。
  static const Map<String, Set<String>> bootstrapSessionAllowed = <String, Set<String>>{
    ApiPaths.meta: <String>{'GET'},
    ApiPaths.pluginSnapshot: <String>{'GET'},
    ApiPaths.pluginConfigs: <String>{'GET', 'POST'},
    ApiPaths.pluginConfig: <String>{'PATCH', 'DELETE'},
    ApiPaths.pluginConfigRestart: <String>{'POST'},
    ApiPaths.pluginBuiltins: <String>{'GET'},
    ApiPaths.pluginBuiltinEnable: <String>{'POST'},
    ApiPaths.pluginBuiltinDisable: <String>{'POST'},
    ApiPaths.pluginRelease: <String>{'GET'},
    ApiPaths.pluginReleaseRefresh: <String>{'POST'},
    ApiPaths.pluginReleaseInstall: <String>{'POST'},
    ApiPaths.pluginReleaseUninstall: <String>{'POST'},
    ApiPaths.pluginStation: <String>{'GET'},
    ApiPaths.pluginStationConfig: <String>{'PATCH'},
    ApiPaths.pluginStationSubscriber: <String>{'POST'},
  };

  /// 生成一张引导票据（单次、短时）。
  String issueBootstrapTicket({Duration? ttl}) {
    final String token = _generateToken();
    _entries[token] = TokenEntry(
      scope: TokenScope.bootstrapTicket,
      expiresAt: _clock().add(ttl ?? ticketTtl),
      singleUse: true,
    );
    return token;
  }

  /// 生成一个引导会话 token。
  String issueBootstrapSession({Duration? ttl}) {
    final String token = _generateToken();
    _entries[token] = TokenEntry(
      scope: TokenScope.bootstrapSession,
      expiresAt: _clock().add(ttl ?? sessionTtl),
      singleUse: false,
    );
    return token;
  }

  /// 消费一张票据；成功返回 null，失败返回**可读原因**。
  ///
  /// 票据被消费后立即从表里移除，第二次使用会落到"无效、已使用或已过期"。
  String? consumeBootstrapTicket(String? ticket) {
    final String value = ticket?.trim() ?? '';
    if (value.isEmpty) return '缺少引导票据';
    final TokenEntry? entry = _entries[value];
    if (entry == null || entry.scope != TokenScope.bootstrapTicket) {
      return '引导票据无效、已使用或已过期，请在 loader 菜单重新签发';
    }
    if (entry.isExpiredAt(_clock())) {
      _entries.remove(value);
      return '引导票据已过期，请在 loader 菜单重新签发';
    }
    _entries.remove(value);
    return null;
  }

  /// 解析 `Authorization: Bearer <token>`；无效 / 过期返回 null。
  TokenAccess? resolveAuthorization(String? header) {
    if (header == null || !header.startsWith('Bearer ')) return null;
    final String provided = header.substring('Bearer '.length).trim();
    if (provided.isEmpty) return null;
    if (CoreToken.matches(primaryToken, provided)) {
      return const TokenAccess(TokenScope.primary);
    }
    final TokenEntry? entry = _entries[provided];
    if (entry == null) return null;
    if (entry.isExpiredAt(_clock())) {
      _entries.remove(provided);
      return null;
    }
    // 票据只能走 consumeBootstrapTicket（打开页面 / 换会话），**不能**当 Bearer
    // 直接访问端点——否则一次页面票据就等于拿到了全权（越权）。
    if (entry.scope != TokenScope.bootstrapSession) return null;
    return TokenAccess(entry.scope);
  }

  /// 会话 token 是否放行该请求。
  static bool allowsBootstrapSession(String method, String path) {
    for (final MapEntry<String, Set<String>> item
        in bootstrapSessionAllowed.entries) {
      if (!_pathMatches(item.key, path)) continue;
      return item.value.contains(method.toUpperCase());
    }
    return false;
  }

  /// 吊销全部会话 token（首个 UI `ui.hello` 成功后调用）。
  int revokeSessions({String reason = ''}) {
    final List<String> doomed = _entries.entries
        .where((MapEntry<String, TokenEntry> e) {
          return e.value.scope == TokenScope.bootstrapSession;
        })
        .map((MapEntry<String, TokenEntry> e) => e.key)
        .toList();
    for (final String token in doomed) {
      _entries.remove(token);
    }
    if (doomed.isNotEmpty && reason.isNotEmpty) {
      log?.call('[core:bootstrap] 已吊销 ${doomed.length} 个引导会话 token：$reason');
    }
    return doomed.length;
  }

  /// 当前仍可用的会话 token 数量（观测 / 测试用）。
  int get liveSessionCount => _entries.values
      .where((TokenEntry e) => e.scope == TokenScope.bootstrapSession)
      .where((TokenEntry e) => !e.isExpiredAt(_clock()))
      .length;

  /// 当前仍可用的票据数量（观测 / 测试用）。
  int get pendingTicketCount => _entries.values
      .where((TokenEntry e) => e.scope == TokenScope.bootstrapTicket)
      .where((TokenEntry e) => !e.isExpiredAt(_clock()))
      .length;

  String _generateToken() {
    final List<int> bytes = List<int>.generate(
      CoreToken.entropyBytes,
      (_) => _random.nextInt(256),
    );
    String encoded = '';
    // 手写 base64url 无填充，避免额外的 dart:convert 导入在热路径上反复分配。
    const String alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    for (int i = 0; i < bytes.length; i += 3) {
      final int b0 = bytes[i];
      final int b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      final int b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      final int triple = (b0 << 16) | (b1 << 8) | b2;
      encoded += alphabet[(triple >> 18) & 0x3f];
      encoded += alphabet[(triple >> 12) & 0x3f];
      if (i + 1 < bytes.length) encoded += alphabet[(triple >> 6) & 0x3f];
      if (i + 2 < bytes.length) encoded += alphabet[triple & 0x3f];
    }
    return encoded;
  }

  static bool _pathMatches(String pattern, String path) {
    final List<String> want = pattern.split('/');
    final List<String> got = path.split('/');
    if (want.length != got.length) return false;
    for (int i = 0; i < want.length; i++) {
      final String segment = want[i];
      if (segment.startsWith('{') && segment.endsWith('}')) {
        if (got[i].isEmpty) return false;
      } else if (segment != got[i]) {
        return false;
      }
    }
    return true;
  }
}
