import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/tray_service.dart';

/// 关闭按钮的**决策**与设置持久化（托盘插件本身不进单测：它要真桌面环境）。
///
/// 两条红线：
/// 1. 默认**进托盘**（防误终止正在跑的任务）；
/// 2. 托盘装不上时**绝不隐藏**（否则用户界面没了、任务还在跑、又找不到入口）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('默认：关闭进托盘、关闭时先问一次、托盘未装好', () async {
    await TrayService.instance.load();
    expect(TrayService.instance.closeToTray, isTrue);
    expect(TrayService.instance.askOnClose, isTrue);
    expect(
      TrayService.instance.trayReady,
      isFalse,
      reason: '单测环境不会真去装托盘',
    );
  });

  test('决策表：托盘可用才隐藏，否则一律退出', () {
    expect(
      TrayService.decideClose(closeToTray: true, trayReady: true),
      TrayCloseAction.hideToTray,
    );
    expect(
      TrayService.decideClose(closeToTray: true, trayReady: false),
      TrayCloseAction.quit,
      reason: '托盘装不上还隐藏 = 把用户关在门外',
    );
    expect(
      TrayService.decideClose(closeToTray: false, trayReady: true),
      TrayCloseAction.quit,
    );
    expect(
      TrayService.decideClose(closeToTray: false, trayReady: false),
      TrayCloseAction.quit,
    );
  });

  test('设置读得回来：本地关掉"进托盘"与"先问一次"后重启仍是关掉', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      TrayService.keyCloseToTray: false,
      TrayService.keyAskOnClose: false,
    });
    await TrayService.instance.load();
    expect(TrayService.instance.closeToTray, isFalse);
    expect(TrayService.instance.askOnClose, isFalse);
  });

  test('设置写得下去：改动落盘（下次启动读到新值）', () async {
    await TrayService.instance.load();
    await TrayService.instance.setCloseToTray(false);
    await TrayService.instance.setAskOnClose(false);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(TrayService.keyCloseToTray), isFalse);
    expect(prefs.getBool(TrayService.keyAskOnClose), isFalse);

    // 复原单例状态，避免影响其它用例（同一个进程里只有一个 TrayService）
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await TrayService.instance.load();
    expect(TrayService.instance.closeToTray, isTrue);
  });
}
