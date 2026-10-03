import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/ui/pages/main_page.dart';
import 'package:tree/ui/services/onboarding_state.dart';
import 'package:tree/ui/services/onboarding_steps.dart';
import 'package:tree/ui/widgets/onboarding_guide.dart';

/// 新手引导浮层 + 首次使用的接线（用户 2026-10-04：「加初次使用的指导（允许用户跳过）」）。
///
/// 两个口径在这里钉住：
/// 1. **非模态**：浮层只占中栏上方一块，后面的界面（设置页 / 建 agent 对话框 / 右栏）照样能点；
/// 2. **处处可跳过**：每一步的「下一步（跳过这步）」与整段的「跳过引导」都能收工，
///    且都记进 [OnboardingState]（下次启动不再自动弹）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpGuide(
    WidgetTester tester, {
    required int index,
    VoidCallback? onAction,
    VoidCallback? onNext,
    VoidCallback? onBack,
    VoidCallback? onSkipAll,
    VoidCallback? onFinish,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OnboardingGuide(
          step: kOnboardingSteps[index],
          index: index,
          total: kOnboardingSteps.length,
          onAction: onAction ?? () {},
          onNext: onNext ?? () {},
          onBack: onBack ?? () {},
          onSkipAll: onSkipAll ?? () {},
          onFinish: onFinish ?? () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('第一步：标题是 1/8、给「带我过去」，没有「上一步」', (WidgetTester tester) async {
    await pumpGuide(tester, index: 0);
    expect(find.text('新手引导 · 1/8'), findsOneWidget);
    expect(find.text(kOnboardingSteps[0].title), findsOneWidget);
    expect(find.text(kOnboardingSteps[0].actionLabel), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('onboarding-back')),
      findsNothing,
      reason: '第一步没有上一步',
    );
    expect(find.text('下一步（跳过这步）'), findsOneWidget);
  });

  testWidgets('最后一步：按钮变成「完成」，且仍能点「带我过去」预填 demo', (
    WidgetTester tester,
  ) async {
    int actions = 0;
    int finishes = 0;
    await pumpGuide(
      tester,
      index: kOnboardingSteps.length - 1,
      onAction: () => actions++,
      onFinish: () => finishes++,
    );
    expect(find.text('完成'), findsOneWidget);
    expect(
      find.text(kOnboardingSteps.last.actionLabel),
      findsOneWidget,
      reason: '最后一步的「带我过去」= 把 demo 那句话填进输入框',
    );
    await tester.tap(find.byKey(const ValueKey<String>('onboarding-action')));
    await tester.pump();
    expect(actions, 1);
    await tester.tap(find.byKey(const ValueKey<String>('onboarding-next')));
    await tester.pump();
    expect(finishes, 1);
  });

  testWidgets('「跳过引导」与「下一步」都能收工（回调说了算）', (WidgetTester tester) async {
    int skips = 0;
    int nexts = 0;
    await pumpGuide(tester, index: 2, onSkipAll: () => skips++, onNext: () => nexts++);
    await tester.tap(find.byKey(const ValueKey<String>('onboarding-skip-all')));
    await tester.pump();
    expect(skips, 1);
    await tester.tap(find.byKey(const ValueKey<String>('onboarding-next')));
    await tester.pump();
    expect(nexts, 1);
    expect(find.text('新手引导 · 3/8'), findsOneWidget);
  });

  testWidgets('MainPage 首次启动弹引导；「跳过引导」之后不再自动弹', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: MainPage()));
    // 引导是启动后异步问偏好再弹的：多推几帧等它出现
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byKey(const ValueKey<String>('onboarding-guide')).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(
      find.byKey(const ValueKey<String>('onboarding-guide')),
      findsOneWidget,
      reason: '第一次使用（没有任何记录）就该弹',
    );
    expect(find.text(kOnboardingSteps.first.title), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('onboarding-skip-all')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('onboarding-guide')),
      findsNothing,
      reason: '跳过就收工',
    );
    expect(
      await OnboardingState.instance.shouldShow(),
      isFalse,
      reason: '跳过得记下来，否则下次启动又弹',
    );

    // 再起一个 MainPage（模拟下次启动）：不该再自动弹
    await tester.pumpWidget(const MaterialApp(home: MainPage()));
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.byKey(const ValueKey<String>('onboarding-guide')),
      findsNothing,
      reason: '看过 / 跳过之后不再自动弹（要再看得去设置页「重新显示」）',
    );
  });
}
