import 'package:shared_preferences/shared_preferences.dart';

/// 新手引导的**看过 / 跳过**状态。
///
/// 为什么放 SharedPreferences 而不是核心配置：这是**纯界面偏好**（这台机器上这个用户
/// 想不想再看引导），跟 agent / 工作空间这些核心状态无关；放进核心设置会把"换台机器
/// 又弹一次"变成"换台机器永远不弹"。
///
/// 口径：
/// - 没有任何记录 ⇒ **该显示**（第一次使用）；
/// - 用户走完最后一步（「完成」）或按了「跳过引导」⇒ 记下来，之后不再自动弹；
/// - 设置页可以「重新显示新手引导」⇒ 走 [reset] 清掉记录再弹一次。
class OnboardingState {
  OnboardingState._();

  /// 全局单例（与 DetailSelection / TerminalToggleRequest 同一范式）。
  static final OnboardingState instance = OnboardingState._();

  /// 存储键（带版本号：将来引导大改可以换键，老用户重看一次新版本）。
  static const String storageKey = 'tree.onboarding.v1';

  /// 是否该显示引导。
  Future<bool> shouldShow() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(storageKey) != true;
  }

  /// 记下"这条用户已经看过 / 跳过了"（走完与跳过同一个口径：都别再自动弹）。
  Future<void> markDone() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(storageKey, true);
  }

  /// 清掉记录（设置页「重新显示新手引导」）。
  Future<void> reset() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }
}
