import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'api_service.dart';
import 'single_instance.dart';

/// 点窗口关闭按钮时该做什么（**纯决策**，与插件无关，便于单测）。
enum TrayCloseAction {
  /// 隐藏窗口：核心与正在跑的任务继续。
  hideToTray,

  /// 真正退出（走优雅关闭）。
  quit,
}

/// 「关闭窗口 = 最小化到系统托盘」的设置与托盘本体。
///
/// **为什么默认进托盘**：Tree 跑的是长任务（agent 可能正在改代码 / 跑命令），
/// 一次误点关闭就等于**终止整轮工作**且不可撤销。关闭按钮因此默认只隐藏窗口，
/// 真想退出要走**两步**（托盘菜单 / 设置页里的退出按钮——都是明确动作）。
///
/// 安全底线：**托盘装不上就绝不隐藏**（[decideClose] 会退回 quit），否则用户会
/// 得到"界面没了、任务还在跑、又找不到入口"的死局。
class TrayService extends ChangeNotifier {
  TrayService._();

  /// 全局单例（一个进程一个托盘图标）。
  static final TrayService instance = TrayService._();

  /// 设置键：关闭窗口时最小化到托盘（默认 **true**）。
  static const String keyCloseToTray = 'close_to_tray';

  /// 设置键：关闭时是否先问一次（勾过「不再提示」后为 false）。
  static const String keyAskOnClose = 'ask_on_close';

  /// 托盘图标资源（`pubspec.yaml` 里声明的资产名）。
  static const String trayIconAsset = 'assets/tray_icon.ico';

  /// 常态工具提示。
  static const String tooltip = 'Tree — Agent 团队效率工具';

  /// 隐藏后的工具提示：让"窗口不见了"这件事有个可读的解释。
  static const String tooltipHidden = 'Tree — 正在后台运行（双击恢复窗口，右键退出）';

  static const String menuShow = '显示主窗口';
  static const String menuNewWindow = '新建窗口';
  static const String menuQuit = '退出 Tree';

  /// 本进程的 UI 插件 id（空 = 开发期手动运行 / 没有清单）。
  ///
  /// 有它才能让核心“再拉起一个同一个插件的窗口”，也才能在退出时把同插件的
  /// **全部**窗口一起关掉。
  String uiPluginId = '';

  /// 托盘归属锁：多窗口 / 多 UI 插件下**只有一个窗口**装托盘。
  ///
  /// 用回环端口当锁（进程退出由内核释放）：谁抢到谁负责托盘与“关窗进托盘”。
  /// 抢不到的窗口按普通窗口处理（关窗即退出、没有托盘），避免出现多个托盘图标。
  final SingleInstanceLock _trayLock = SingleInstanceLock();

  /// 本进程是否持有托盘归属（[claimTrayOwner] 的结果）。
  bool _ownsTray = false;

  bool _closeToTray = true;
  bool _askOnClose = true;
  bool _installed = false;
  String? _installError;
  TrayIcon? _icon;

  /// 挂到托盘上的那个菜单（**必须持有引用**）。
  ///
  /// nativeapi 的包装对象带 finalizer：Dart 侧被 GC 会释放底层句柄，而这块原生菜单
  /// 还挂在托盘图标上——留个引用是最省事的正确做法（插件文档同样要求"要用就留着"）。
  Menu? attachedMenu;

  /// 关闭窗口时是否最小化到托盘。
  bool get closeToTray => _closeToTray;

  /// 关闭时是否先问一次（勾过「不再提示」后为 false）。
  bool get askOnClose => _askOnClose;

  /// 托盘是否**已经装好并且真的显示了**。false 时关闭按钮必须直接退出。
  bool get trayReady => _installed;

  /// 装不上时的可读原因（给启动横幅与设置页用；成功时为 null）。
  String? get installError => _installError;

  /// 从本地设置加载（应用启动时调用；读不到就用默认值）。
  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _closeToTray = prefs.getBool(keyCloseToTray) ?? true;
      _askOnClose = prefs.getBool(keyAskOnClose) ?? true;
    } catch (error) {
      // 读不到（无插件环境 / 存储异常）就用默认值：默认是"进托盘"——在"可能误终止
      // 长任务"与"多点一下才能退出"之间，前者代价大得多。
      debugPrint('托盘设置读取失败，使用默认值（关闭进托盘）：$error');
    }
    notifyListeners();
  }

  /// 设置并持久化"关闭窗口时最小化到托盘"。
  Future<void> setCloseToTray(bool value) async {
    if (_closeToTray == value) return;
    _closeToTray = value;
    notifyListeners();
    await _persist(keyCloseToTray, value);
  }

  /// 设置并持久化"关闭时是否先问一次"。
  Future<void> setAskOnClose(bool value) async {
    if (_askOnClose == value) return;
    _askOnClose = value;
    notifyListeners();
    await _persist(keyAskOnClose, value);
  }

  Future<void> _persist(String key, bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (error) {
      debugPrint('托盘设置写入失败（本次仍按新值生效，重启后回到旧值）：$error');
    }
  }

  /// 关闭按钮的动作（纯函数：默认值 / 托盘不可用时都退回"直接退出"）。
  static TrayCloseAction decideClose({
    required bool closeToTray,
    required bool trayReady,
  }) => closeToTray && trayReady
      ? TrayCloseAction.hideToTray
      : TrayCloseAction.quit;

  /// 抢“托盘归属”：同一核心的多个窗口里只有一个能返回 true。
  ///
  /// 返回值只决定**本窗口**是否装托盘 / 是否拦关闭；抢不到不是错误（不写
  /// [installError]，避免每个副窗口都弹一条“托盘不可用”的启动提示）。
  Future<bool> claimTrayOwner(String coreKey) async {
    final SingleInstanceState state = await _trayLock.acquire(
      key: 'tray:$coreKey',
    );
    _ownsTray = state == SingleInstanceState.acquired;
    if (!_ownsTray) {
      debugPrint('托盘归属：已被同一核心的另一个窗口持有，本窗口不装托盘（关窗即退出）');
    }
    return _ownsTray;
  }

  /// 装上托盘图标与菜单。返回是否可用；失败原因进 [installError]。
  ///
  /// 幂等：已经装好时直接返回 true。
  Future<bool> install() async {
    if (_installed) return true;
    try {
      final TrayIcon? icon = TrayIcon.create();
      if (icon == null) return _fail('托盘图标创建失败');
      final Image? image = ImageAsset.fromAsset(trayIconAsset);
      if (image == null) {
        icon.dispose();
        return _fail('托盘图标资源不可读（$trayIconAsset）');
      }
      icon.icon = image;
      icon.setTooltip(tooltip);

      final Menu? menu = Menu.create();
      final MenuItem? showItem = MenuItem.createWithLabelAndType(
        menuShow,
        MenuItemType.normal,
      );
      final MenuItem? newWindowItem = uiPluginId.isEmpty
          ? null
          : MenuItem.createWithLabelAndType(
              menuNewWindow,
              MenuItemType.normal,
            );
      final MenuItem? quitItem = MenuItem.createWithLabelAndType(
        menuQuit,
        MenuItemType.normal,
      );
      if (menu == null || showItem == null || quitItem == null) {
        icon.dispose();
        return _fail('托盘菜单创建失败');
      }
      showItem.addListener((MenuEvent event) {
        if (event is MenuItemClickedEvent) unawaited(showWindow());
      });
      newWindowItem?.addListener((MenuEvent event) {
        if (event is MenuItemClickedEvent) unawaited(newWindow());
      });
      quitItem.addListener((MenuEvent event) {
        if (event is MenuItemClickedEvent) unawaited(quit());
      });
      menu.addItem(showItem);
      if (newWindowItem != null) {
        menu.addItem(newWindowItem);
      }
      menu.addSeparator();
      menu.addItem(quitItem);
      icon.setContextMenu(menu);
      // 右键即弹菜单（Windows 习惯）；左键/双击由下面的监听器恢复窗口
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      icon.addListener((TrayIconEvent event) {
        if (event is TrayIconClickedEvent ||
            event is TrayIconDoubleClickedEvent) {
          unawaited(showWindow());
        }
      });
      if (!icon.setVisible(true)) {
        icon.dispose();
        return _fail('托盘图标显示失败（该桌面环境可能不支持托盘）');
      }
      _icon = icon;
      attachedMenu = menu;
      _installed = true;
      _installError = null;
      notifyListeners();
      return true;
    } catch (error) {
      return _fail('$error');
    }
  }

  bool _fail(String reason) {
    _installError = reason;
    _installed = false;
    debugPrint('托盘不可用：$reason（关闭窗口将直接退出）');
    notifyListeners();
    return false;
  }

  /// 恢复窗口（托盘单击 / 双击 / 菜单）。
  Future<void> showWindow() async {
    _icon?.setTooltip(tooltip);
    await windowManager.show();
    await windowManager.focus();
  }

  /// 隐藏窗口到托盘（工具提示同时改成"正在后台运行"）。
  Future<void> hideWindow() async {
    _icon?.setTooltip(tooltipHidden);
    await windowManager.hide();
  }

  /// 让核心再拉起一个**同一个 UI 插件**的窗口（多窗口 = 多进程）。
  ///
  /// 为什么不让本进程自己 `Process.start`：窗口的进程生命周期归核心管
  /// （`UiHost` 记录 pid、退出要收尸、`/api/plugin/windows` 要能列出来），
  /// 自己拉起来的进程在核心看来是孤儿。
  Future<void> newWindow() async {
    if (uiPluginId.isEmpty) {
      debugPrint('新建窗口：当前进程没有插件身份（开发期手动运行），核心无法拉起新窗口');
      return;
    }
    try {
      final Map<String, dynamic> result = await ApiService.createUiWindow(
        uiPluginId,
      );
      debugPrint('新建窗口：${result['window_id']}（pid=${result['pid']}）');
    } catch (error) {
      debugPrint('新建窗口失败：$error');
    }
  }

  /// 关掉当前核心上**全部 UI 插件的全部窗口**（多插件并存时也要一次退干净）。
  ///
  /// 顺序：别的插件先关、自己最后关——关自己这一条会让核心立刻收掉本进程，
  /// 后面的请求就没机会发出去了。
  Future<void> _closeAllUiWindows() async {
    final Set<String> plugins = <String>{};
    try {
      final Map<String, dynamic> listing = await ApiService.listUiWindows();
      final Object? raw = listing['windows'];
      if (raw is List<dynamic>) {
        for (final Object? item in raw) {
          if (item is! Map) continue;
          final String id = (item['plugin_id'] ?? '').toString().trim();
          if (id.isNotEmpty) plugins.add(id);
        }
      }
    } catch (error) {
      debugPrint('列出 UI 窗口失败（按本插件关闭）：$error');
    }
    if (uiPluginId.isNotEmpty) plugins.add(uiPluginId);
    final List<String> targets = plugins.toList()
      ..sort((String a, String b) {
        if (a == uiPluginId) return 1;
        if (b == uiPluginId) return -1;
        return a.compareTo(b);
      });
    for (final String id in targets) {
      try {
        await ApiService.closeUiWindows(id).timeout(const Duration(seconds: 2));
      } catch (error) {
        // 关到自己时核心已经把本进程收掉，这里必然失败；继续本地退出即可。
        debugPrint('关闭 UI 插件 $id 的窗口失败（继续退出）：$error');
      }
    }
  }

  /// **真正退出界面**：关闭全部 UI 窗口 → 解除托盘归属 → 拿掉托盘图标 → 销毁窗口。
  ///
  /// 顺序是有意的：先解除"拦截关闭"（否则后续关闭流程仍会被拦）、再拿掉图标
  /// （否则图标会残留到鼠标划过才消失）、最后才关窗口。**核心不退出**：UI 是插件，
  /// 退出界面只让 `UiHost` 把它置为 stopped，系统继续运行。
  ///
  /// **多窗口 / 多 UI 插件**：只有托盘归属者会先请核心把**所有 UI 插件的窗口**关掉——
  /// 否则用户点了“退出”，其余窗口会留在没有托盘的孤岛里。副窗口的关闭走
  /// [decideClose] 的 quit 分支，只结束自己。
  Future<void> quit() async {
    if (_ownsTray) {
      await _closeAllUiWindows();
    }
    await _trayLock.release();
    // 先放开单实例锁：万一本进程还要多活一会儿（销毁窗口），同一个核心的下一个
    // UI 实例不该被一个"正在退出"的进程挡在门外。
    await SingleInstanceLock.instance.release();
    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      debugPrint('解除关闭拦截失败（继续退出）：$error');
    }
    try {
      _icon?.dispose();
      _icon = null;
      attachedMenu = null;
      _installed = false;
    } catch (error) {
      debugPrint('移除托盘图标失败（继续退出）：$error');
    }
    // **只退出界面，不退出核心**：UI 是插件，核心的生命周期归 loader / 用户管理。
    await windowManager.destroy();
    // 兜底：个别平台/异常路径下窗口销毁不一定结束消息循环，2 秒后强制退出。
    Timer(const Duration(seconds: 2), () => exit(0));
  }
}
