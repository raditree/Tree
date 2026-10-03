import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/ui/services/onboarding_state.dart';

/// 新手引导的**看过 / 跳过**状态（用户 2026-10-04：「加初次使用的指导（允许用户跳过）」）。
///
/// 口径：没有记录 ⇒ 该弹；走完或跳过 ⇒ 记下来，之后不再自动弹；设置页可以「重新显示」
/// ⇒ 清记录再弹一次。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('第一次使用（没有任何记录）⇒ 该显示', () async {
    expect(await OnboardingState.instance.shouldShow(), isTrue);
  });

  test('标记看过之后不再自动弹（跳过与走完同一个口径）', () async {
    await OnboardingState.instance.markDone();
    expect(await OnboardingState.instance.shouldShow(), isFalse);
  });

  test('「重新显示」清掉记录 ⇒ 又该弹一次', () async {
    await OnboardingState.instance.markDone();
    expect(await OnboardingState.instance.shouldShow(), isFalse);
    await OnboardingState.instance.reset();
    expect(await OnboardingState.instance.shouldShow(), isTrue);
  });

  test('存储键带版本号（将来大改引导可以换键让老用户重看一次）', () async {
    expect(OnboardingState.storageKey, 'tree.onboarding.v1');
    await OnboardingState.instance.markDone();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(OnboardingState.storageKey), isTrue);
  });
}
