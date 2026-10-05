import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/ui/text_scale_service.dart';

/// 界面文字缩放：夹取边界 + 持久化读回 + 同值不重通知。
///
/// 三条红线：
/// 1. 任何输入都夹在 [minScale, maxScale] 内（写非法值不报错、只出错值，
///    是最容易静默飘移的地方）；
/// 2. 首次启动（无持久化值）必须回落到 1.0，不能是 0 或 null；
/// 3. 同值 setScale 不重复 notify（滑杆 onChanged 会被高频调用）。
///
/// 持久化 key 用字符串字面量断言：它是跨版本的用户数据契约，
/// 改名 = 用户升级后设置丢失，测试要拦住这种漂移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('首次启动无持久化值时 load 回落到默认 1.0', () async {
    await TextScaleService.instance.load();
    expect(TextScaleService.instance.scale, TextScaleService.defaultScale);
  });

  test('setScale 低于下限被夹到 minScale', () async {
    await TextScaleService.instance.load();
    TextScaleService.instance.setScale(0.1);
    expect(TextScaleService.instance.scale, TextScaleService.minScale);
  });

  test('setScale 高于上限被夹到 maxScale', () async {
    await TextScaleService.instance.load();
    TextScaleService.instance.setScale(9.9);
    expect(TextScaleService.instance.scale, TextScaleService.maxScale);
  });

  test('setScale 同值时不触发 notifyListeners', () async {
    await TextScaleService.instance.load();
    TextScaleService.instance.setScale(1.2);
    int notifyCount = 0;
    TextScaleService.instance.addListener(() => notifyCount++);
    TextScaleService.instance.setScale(1.2);
    expect(notifyCount, 0, reason: '滑杆拖动时同值高频调用，不该重复重建');
  });

  test('setScale 把值写进 shared_preferences（key = text_scale）', () async {
    await TextScaleService.instance.load();
    TextScaleService.instance.setScale(1.3);
    // _persist 是 fire-and-forget，等它落盘
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('text_scale'), 1.3);
  });

  test('load 从持久化值恢复（跨启动）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'text_scale': 1.3,
    });
    await TextScaleService.instance.load();
    expect(TextScaleService.instance.scale, 1.3);
  });
}