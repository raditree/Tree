import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 认证服务 - 负责本地 JWT token 的存储与读取
///
/// 使用 shared_preferences 在本地持久化保存登录凭证，
/// 应用启动时据此判断用户登录状态并决定初始路由。
class AuthService {
  // token 在 shared_preferences 中的存储键名
  static const String _tokenKey = 'jwt_token';

  /// 保存 JWT token 到本地存储
  Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  /// 从本地存储读取 JWT token，不存在则返回 null
  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  /// 清除本地存储的 JWT token（用于登出）
  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  /// 判断用户是否已登录（本地存在非空 token）
  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  /// 从本地 token 解析当前用户信息
  ///
  /// JWT 的 payload 中包含 `user`（openid、nickname、avatar 等）。
  /// 解析失败或未登录时返回 null。
  Future<Map<String, dynamic>?> getUserInfo() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return null;
    try {
      final List<String> parts = token.split('.');
      if (parts.length < 2) return null;
      // JWT 第二部分为 base64url 编码的 payload
      final String normalized =
          base64Url.normalize(parts[1]);
      final String decoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> payload =
          jsonDecode(decoded) as Map<String, dynamic>;
      final dynamic user = payload['user'];
      if (user is Map<String, dynamic>) {
        return user;
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
