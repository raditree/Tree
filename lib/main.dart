import 'package:flutter/material.dart';

import 'pages/login_page.dart';
import 'pages/main_page.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/theme_service.dart';

/// 应用入口
///
/// 启动前先检查本地是否存在有效 JWT token，据此决定初始路由：
/// 已登录进入主页，未登录进入登录页。
void main() async {
  // 确保 Flutter 绑定初始化（shared_preferences 等插件依赖此步骤）
  WidgetsFlutterBinding.ensureInitialized();

  // 加载本地保存的主题模式
  await ThemeService.instance.load();

  // 读取本地登录状态以决定初始路由
  final authService = AuthService();
  final loggedIn = await authService.isLoggedIn();

  // 已登录时预先加载 token 到 ApiService，供后续鉴权请求携带
  if (loggedIn) {
    final token = await authService.getToken();
    ApiService.setToken(token);
  }

  runApp(AgentTeamApp(initialRoute: loggedIn ? '/main' : '/login'));
}

/// 根 Widget - Agent 团队效率工具应用
///
/// 配置应用主题（浅色/深色/跟随系统）与命名路由。
/// 监听 [ThemeService] 以在切换主题时即时重建界面。
class AgentTeamApp extends StatelessWidget {
  // 初始路由，由 main() 根据登录状态传入
  final String initialRoute;

  const AgentTeamApp({super.key, required this.initialRoute});

  /// 浅色主题（深蓝专业风格）
  ThemeData _buildLightTheme() {
    return ThemeData(
      primaryColor: const Color(0xFF2563EB),
      scaffoldBackgroundColor: const Color(0xFFF3F4F6),
      cardColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF2563EB),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF2563EB),
        secondary: Color(0xFF2563EB),
      ),
      useMaterial3: false,
    );
  }

  /// 深色主题
  ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: const Color(0xFF3B82F6),
      scaffoldBackgroundColor: const Color(0xFF1F2937),
      cardColor: const Color(0xFF374151),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF111827),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF3B82F6),
        secondary: Color(0xFF3B82F6),
      ),
      useMaterial3: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeService.instance,
      builder: (BuildContext context, _) {
        return MaterialApp(
          title: 'Agent 团队效率工具',
          debugShowCheckedModeBanner: false,
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          themeMode: ThemeService.instance.mode,
          initialRoute: initialRoute,
          routes: {
            '/login': (context) => const LoginPage(),
            '/main': (context) => const MainPage(),
          },
        );
      },
    );
  }
}

