import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui/pages/login_page.dart';
import 'ui/pages/main_page.dart';
import 'io/api_service.dart';
import 'io/auth_service.dart';
import 'io/websocket_service.dart';
import 'ui/theme_service.dart';

/// 应用入口
///
/// 启动前先检查本地是否存在有效 JWT token，据此决定初始路由：
/// 已登录进入主页，未登录进入登录页。
void main() async {
  // 确保 Flutter 绑定初始化（shared_preferences 等插件依赖此步骤）
  WidgetsFlutterBinding.ensureInitialized();

  // 加载本地保存的主题模式
  await ThemeService.instance.load();

  // 加载自定义后端地址配置；未自定义时使用平台默认地址
  // （Android 模拟器为 10.0.2.2，其余平台 localhost）
  final prefs = await SharedPreferences.getInstance();
  final host = prefs.getString('custom_backend_host') ?? '';
  final port = prefs.getString('custom_backend_port') ?? '';
  final bool hasCustom = host.isNotEmpty && port.isNotEmpty;
  final String backendHost = hasCustom ? host : ApiService.defaultBackendHost();
  final String backendPort = hasCustom ? port : '8000';
  // HTTP 与 WebSocket 使用同一后端地址，避免自定义后 WS 仍连 localhost
  ApiService.baseUrl = 'http://$backendHost:$backendPort';
  WebSocketService.baseUrl = 'ws://$backendHost:$backendPort';

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

  // ==================== 品牌色板（对齐 web/icons/Icon-512.png） ====================
  /// 图标主亮绿（HUD 弧线）
  static const Color brandBright = Color(0xFF00FF8C);
  /// 图标渐变深绿（弧线暗部/高亮刻度）
  static const Color brandDeep = Color(0xFF00904A);
  /// 图标辅助深绿（细刻度线）
  static const Color brandLine = Color(0xFF00522C);
  /// 图标背景近黑（#030705，带极微弱绿）
  static const Color brandBlack = Color(0xFF030705);
  /// 深色卡片底色（比背景略亮）
  static const Color brandCard = Color(0xFF0A1A10);
  /// 绿色分割线（半透明亮绿，用于各类边线框/分隔线）
  static const Color brandDivider = Color(0xFF2B7A4B);
  /// 亮绿上的前景深墨绿（onPrimary，保证对比度）
  static const Color onBrandBright = Color(0xFF00280F);
  /// PrimaryContainer 深绿
  static const Color brandContainer = Color(0xFF0E2B1A);
  static const Color onBrandContainer = Color(0xFFB8FFD9);

  /// 浅色主题（白绿配色：白底 + 图标渐变深绿主色，清爽可读）
  ///
  /// 主色用 brandDeep（#00904A 图标渐变深绿），白底上保持足够对比度；
  /// 文字走 Material 浅色派生（近黑墨绿），避免黑字黑底的不可读问题。
  ThemeData _buildLightTheme() {
    return ThemeData(
      fontFamily: 'Microsoft YaHei',
      fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
      primaryColor: brandDeep,
      scaffoldBackgroundColor: const Color(0xFFF4FAF6),
      cardColor: Colors.white,
      dividerColor: const Color(0xFFC9E5D3),
      dividerTheme: const DividerThemeData(color: Color(0xFFC9E5D3), thickness: 1),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: brandDeep,
        elevation: 0,
        // 底部浅绿分割线：白底上的绿色分界，呼应图标风格
        shape: Border(
          bottom: BorderSide(color: Color(0xFFC9E5D3), width: 1),
        ),
      ),
      colorScheme: const ColorScheme.light(
        primary: brandDeep,
        onPrimary: Colors.white,
        secondary: brandDeep,
        onSecondary: Colors.white,
        primaryContainer: Color(0xFFD9F2E3),
        onPrimaryContainer: Color(0xFF00491F),
        secondaryContainer: Color(0xFFD9F2E3),
        onSecondaryContainer: Color(0xFF00491F),
        surface: Colors.white,
        onSurface: Color(0xFF1A2E21),
        // 显式补充（ColorScheme.light 未传时默认黑色/极端值，会在浅色底上
        // 造成同色不可读或过重描边）：灰绿系，与品牌绿协调且白底清晰
        surfaceContainerHighest: Color(0xFFDCEAE1),
        onSurfaceVariant: Color(0xFF44584C),
        outline: Color(0xFF6FA98A),
      ),
      // 输入框浅绿边框（聚焦时转品牌深绿）
      inputDecorationTheme: const InputDecorationTheme(
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFB9DCC7)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: brandDeep, width: 1.5),
        ),
      ),
      // 卡片：白底 + 浅绿描边
      cardTheme: CardThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFFC9E5D3)),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide(color: Color(0xFFC9E5D3)),
        ),
      ),
      // 文字选区浅绿，与用户消息气泡底色(deep 绿)区分开；白底上清晰可见。
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Color(0xFFA5E8C3),
        selectionHandleColor: Color(0xFF00904A),
      ),
      useMaterial3: false,
    );
  }

  /// 深色主题（黑背景 + 亮绿 HUD 弧线，主色 #00FF8C 与图标一致）
  ThemeData _buildDarkTheme() {
    return ThemeData(
      fontFamily: 'Microsoft YaHei',
      fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
      brightness: Brightness.dark,
      primaryColor: brandBright,
      scaffoldBackgroundColor: brandBlack,
      cardColor: brandCard,
      dividerColor: brandDivider,
      dividerTheme: const DividerThemeData(color: brandDivider, thickness: 1),
      appBarTheme: const AppBarTheme(
        backgroundColor: brandBlack,
        foregroundColor: Color(0xFFD9FFEC),
        elevation: 0,
        shape: Border(
          bottom: BorderSide(color: brandDivider, width: 1),
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: brandBright,
        onPrimary: onBrandBright,
        secondary: brandBright,
        onSecondary: onBrandBright,
        primaryContainer: brandContainer,
        onPrimaryContainer: onBrandContainer,
        secondaryContainer: brandContainer,
        onSecondaryContainer: onBrandContainer,
        surface: brandBlack,
        onSurface: Color(0xFFE6F3EC),
        // 显式补充（ColorScheme.dark 未传时默认白色，半透明表层/状态文字
        // 会亮到与深底失去层次，甚至同色不可见）：深绿灰系与品牌绿协调
        surfaceContainerHighest: Color(0xFF14251B),
        onSurfaceVariant: Color(0xFFA9C9B6),
        outline: Color(0xFF5E8E71),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: brandLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: brandBright, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: brandCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: brandDivider),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: brandCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide(color: brandDivider),
        ),
      ),
      // 深色模式下同样用 cyan 选区，避免与绿色气泡/深色背景隐形。
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Color(0xFF4DD0E1),
        selectionHandleColor: Color(0xFF00ACC1),
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

