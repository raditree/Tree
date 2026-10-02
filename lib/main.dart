import 'dart:async';
import 'dart:io';
// AppExitResponse 定义在 dart:ui（material/widgets 只转引类型，不导出枚举本体）
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:tree_protocol/tree_protocol.dart';
import 'package:window_manager/window_manager.dart';

import 'io/api_service.dart';
import 'io/core_process_launcher.dart';
import 'io/single_instance.dart';
import 'io/tray_service.dart';
import 'io/websocket_service.dart';
import 'ui/pages/main_page.dart';
import 'ui/theme_service.dart';
import 'ui/widgets/close_to_tray_dialog.dart';

/// 应用入口（desktop 分支：无登录、无后端地址配置）。
///
/// 启动顺序：
/// 1. 加载本地主题；
/// 2. 拉起（或附着）**本机核心进程**，拿到随机端口与一次性本地 token；
/// 3. 把 HTTP/WS 基址与 token 交给 [ApiService] / [WebSocketService]；
/// 4. 进入主界面；核心启动失败时显示可操作的错误页而不是白屏。
Future<void> main() async {
  // shared_preferences / path_provider 等插件依赖绑定先初始化
  WidgetsFlutterBinding.ensureInitialized();

  // **单实例判定必须在拉起核心之前**：否则第二个核心已经起来了，两个核心共用同一个
  // 数据根（会话/消息互相覆盖）。
  final SingleInstanceState instanceState =
      await SingleInstanceLock.instance.acquire();
  if (instanceState == SingleInstanceState.alreadyRunning) {
    // 已经请那个实例把窗口叫到前面了（托盘里的窗口会自己出来）。这个窗口只说明
    // 一句就自己关闭：**绝不拉起第二个核心**。
    runApp(const AlreadyRunningApp());
    return;
  }

  // 关闭行为与主题一样属于本地偏好：先读出来，再决定关窗怎么做
  await TrayService.instance.load();

  // 窗口控制插件先初始化（关闭拦截放到"核心起来了"之后：见下面的注释）
  await windowManager.ensureInitialized();

  // 加载本地保存的主题模式
  await ThemeService.instance.load();

  final CoreHandshake? handshake = await CoreProcessLauncher.instance.start();
  if (handshake == null) {
    // 错误页**不拦截关闭**：这里连托盘都没装，拦下关闭按钮就等于让用户关不掉这个窗口
    runApp(CoreStartupErrorApp(
      message: CoreProcessLauncher.instance.lastError ?? '未知错误',
    ));
    return;
  }
  // 核心只监听 127.0.0.1，HTTP 与 WS 同源；token 每次启动都重新生成
  ApiService.baseUrl = handshake.httpBaseUrl;
  WebSocketService.baseUrl = handshake.wsBaseUrl;
  ApiService.setToken(handshake.token);

  // **拦截关闭按钮**：默认只隐藏窗口（见 [TrayService]），真正的退出走托盘菜单 /
  // 设置页的退出入口。桌面端的长任务正在跑时，误点关闭等于终止整轮工作。
  //
  // 放在核心就绪之后：错误页那条路没有窗口监听者，拦下关闭会让用户关不掉窗口。
  await windowManager.setPreventClose(true);

  // 托盘装不上**不致命**，但必须显式告诉用户：此时关闭按钮会直接退出（见 TrayService）
  await TrayService.instance.install();

  // 另一个实例想启动时（用户又双击了桌面图标）：把本窗口叫到前面——用户期望看到的是
  // "窗口回来了"，而不是"点了图标什么都没发生"。托盘不可用时也要能唤起（show 与托盘无关）。
  SingleInstanceLock.instance.onActivate = TrayService.instance.showWindow;

  // 启动期诊断（例如核心产物比界面旧、托盘不可用）随 App 一起渲染：这类问题一旦
  // 发生，现象是"界面有新功能、核心按旧行为跑"或"关窗行为与预期不符"，不主动提示
  // 几乎无法自证。
  runApp(AgentTeamApp(startupWarning: _startupWarning()));
}

/// 启动期诊断（合并多条；都为空时返回 null）。
String? _startupWarning() {
  final List<String> parts = <String>[
    if (CoreProcessLauncher.instance.buildWarning != null)
      CoreProcessLauncher.instance.buildWarning!,
    if (TrayService.instance.installError != null)
      '系统托盘不可用（${TrayService.instance.installError}）：关闭窗口会直接退出 Tree。',
  ];
  return parts.isEmpty ? null : parts.join('\n');
}

/// 根 Widget - Agent 团队效率工具应用
///
/// 配置应用主题（浅色/深色/跟随系统）与主界面路由，并在应用退出时回收核心
/// 子进程（否则会留下孤儿进程，用户再也连不上旧实例）。
class AgentTeamApp extends StatefulWidget {
  const AgentTeamApp({super.key, this.startupWarning});

  /// 启动期诊断横幅（非致命）：非空时显示在主界面顶部，可关闭。
  ///
  /// 典型来源是「核心产物比界面旧」——核心是独立进程，界面新、核心旧时现象是
  /// 功能莫名缺失（工具表缺项、系统提示词缺章节），不提示几乎无法自证。
  final String? startupWarning;

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
  static ThemeData _buildLightTheme() {
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
  static ThemeData _buildDarkTheme() {
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
  State<AgentTeamApp> createState() => _AgentTeamAppState();
}

class _AgentTeamAppState extends State<AgentTeamApp> with WindowListener {
  /// 对话框用的导航器 key（`onWindowClose` 是插件回调，手里没有 BuildContext）。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 应用退出钩子：请求核心优雅关闭（stdin 写 shutdown，超时再强杀）。
  ///
  /// 用 AppLifecycleListener 而不是 dispose：dispose 在窗口关闭流程中不保证
  /// 被调用，而 onExitRequested 是桌面端"用户要求退出"的明确信号。
  ///
  /// **必须在 initState 里立即创建**：若写成 `late final _lifecycle = ...`
  /// 惰性初始化，则该监听器直到 dispose 才被构造（那时再注册观察者已无意义），
  /// 实测表现为"关窗后应用退出、核心进程变成孤儿继续占着端口与内存"。
  ///
  /// 注意它与 [onWindowClose] 的分工：`setPreventClose(true)` 之后，**点关闭按钮**
  /// 由 window_manager 拦下（走 [onWindowClose]）；`onExitRequested` 只在平台自己
  /// 发起退出时出现（如系统注销），那时不再问"要不要进托盘"，直接优雅退出。
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await TrayService.instance.quit();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _lifecycle?.dispose();
    super.dispose();
  }

  /// 用户点了关闭按钮（`setPreventClose(true)` 之后由 window_manager 转发）。
  ///
  /// 默认**只隐藏窗口**：核心与正在跑的任务继续。首次会问一次并记住选择；
  /// 托盘不可用时 [TrayService.decideClose] 直接给 quit（绝不把用户关在门外）。
  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    final TrayService tray = TrayService.instance;
    final TrayCloseAction action = TrayService.decideClose(
      closeToTray: tray.closeToTray,
      trayReady: tray.trayReady,
    );
    if (action == TrayCloseAction.quit) {
      await tray.quit();
      return;
    }
    if (tray.askOnClose) {
      final CloseToTrayChoice? choice = await _askCloseToTray();
      if (choice != null && choice.remember) {
        await tray.setAskOnClose(false);
        await tray.setCloseToTray(choice.hideToTray);
      }
      if (choice != null && !choice.hideToTray) {
        await tray.quit();
        return;
      }
    }
    await tray.hideWindow();
    // 这条行为在界面上没有痕迹（窗口直接消失），日志是唯一的自证材料
    debugPrint('关闭窗口：已隐藏到系统托盘，核心与任务继续运行');
  }

  /// 首次关闭的说明框；拿不到上下文（极端时机）时返回 null，调用方按默认隐藏。
  Future<CloseToTrayChoice?> _askCloseToTray() async {
    final BuildContext? context = _navigatorKey.currentContext;
    if (context == null) {
      // 这条路只该在"界面还没建起来"时出现；记一行日志，免得"没弹说明框"变成谜
      debugPrint('关闭窗口：拿不到对话框上下文，按默认隐藏到托盘');
      return null;
    }
    return showDialog<CloseToTrayChoice>(
      context: context,
      builder: (BuildContext context) => const CloseToTrayDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeService.instance,
      builder: (BuildContext context, _) {
        return MaterialApp(
          title: 'Agent 团队效率工具',
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: AgentTeamApp._buildLightTheme(),
          darkTheme: AgentTeamApp._buildDarkTheme(),
          themeMode: ThemeService.instance.mode,
          // 单一入口：桌面分支没有登录页
          home: _StartupWarningHost(
            warning: widget.startupWarning,
            child: const MainPage(),
          ),
        );
      },
    );
  }
}

/// 启动期诊断横幅的宿主：把非致命警告显示在主界面顶部，可关闭。
///
/// 为什么不做成 SnackBar：这类问题（核心是旧产物）在整个会话里都成立，一闪而过
/// 的提示等于没提示；横幅留在顶部直到用户主动关掉。
class _StartupWarningHost extends StatefulWidget {
  const _StartupWarningHost({required this.warning, required this.child});

  final String? warning;
  final Widget child;

  @override
  State<_StartupWarningHost> createState() => _StartupWarningHostState();
}

class _StartupWarningHostState extends State<_StartupWarningHost> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final String? warning = widget.warning;
    if (warning == null || warning.isEmpty || _dismissed) {
      return widget.child;
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        Material(
          color: cs.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    warning,
                    style: TextStyle(
                      color: cs.onErrorContainer,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '知道了',
                  icon: Icon(Icons.close, size: 18, color: cs.onErrorContainer),
                  onPressed: () => setState(() => _dismissed = true),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

/// 核心进程启动失败时的兜底界面。
///
/// 桌面分支没有后端，核心进程就是全部能力来源；启动失败必须给出**可操作的**
/// 原因与修复指引，而不是白屏或反复重连的登录页。
class CoreStartupErrorApp extends StatelessWidget {
  const CoreStartupErrorApp({super.key, required this.message});

  /// 失败原因（含已尝试的路径与修复命令）。
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent 团队效率工具 - 核心启动失败',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Microsoft YaHei',
        fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
        colorScheme: const ColorScheme.dark(
          primary: AgentTeamApp.brandBright,
          surface: AgentTeamApp.brandBlack,
          onSurface: Color(0xFFE6F3EC),
        ),
        scaffoldBackgroundColor: AgentTeamApp.brandBlack,
        useMaterial3: false,
      ),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '核心进程未能启动',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: AgentTeamApp.brandBright,
                        ),
                  ),
                  const SizedBox(height: 16),
                  const Text('桌面分支不再使用后端服务：全部逻辑由本机核心进程提供，'
                      '核心未就绪时应用无法工作。'),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AgentTeamApp.brandCard,
                      border: Border.all(color: AgentTeamApp.brandDivider),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      message,
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 已经有一个实例在跑时的提示窗口。
///
/// 为什么不静默退出：用户双击桌面图标时期望的是"窗口回来了"。锁的持有者已经被
/// [SingleInstanceLock.onActivate] 叫到前面——这里再给一句可读的解释，免得"窗口一闪
/// 就没了"被当成启动失败。本进程**没有**拉起核心，所以自动关闭时直接 `exit(0)`
/// 不会留下孤儿进程。
class AlreadyRunningApp extends StatefulWidget {
  const AlreadyRunningApp({
    super.key,
    this.autoCloseAfter = const Duration(seconds: 4),
  });

  /// 自动关闭时间（用户不点也自己退，不留一个无意义的窗口）。
  final Duration autoCloseAfter;

  @override
  State<AlreadyRunningApp> createState() => _AlreadyRunningAppState();
}

class _AlreadyRunningAppState extends State<AlreadyRunningApp> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.autoCloseAfter, _dismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _dismiss() => exit(0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tree 已在运行',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Microsoft YaHei',
        fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
        colorScheme: const ColorScheme.dark(
          primary: AgentTeamApp.brandBright,
          surface: AgentTeamApp.brandBlack,
          onSurface: Color(0xFFE6F3EC),
        ),
        scaffoldBackgroundColor: AgentTeamApp.brandBlack,
        useMaterial3: false,
      ),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Tree 已经在运行',
                    style: TextStyle(
                      color: AgentTeamApp.brandBright,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '已经有一个 Tree 实例在跑（可能收在系统托盘里），已为你把它的窗口叫到前面。\n'
                    '同一个数据根只允许一个实例，这个窗口会自动关闭。',
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _dismiss,
                      child: const Text('知道了'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
