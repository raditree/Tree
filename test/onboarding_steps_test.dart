import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/onboarding_steps.dart';

/// 新手引导的**步骤表**（用户 2026-10-04 定稿的顺序）：模型配置（设置页）→ 创建 agent →
/// 配置模型信息 → 配置工作目录 → 启用插件 → 文件浏览 → Ctrl+J → demo 输入。
///
/// 顺序是用户的断言，钉在这里：**改动顺序必须是有意的**，不能顺手重排。
void main() {
  test('八步，顺序与用户定稿逐项一致', () {
    expect(kOnboardingSteps, hasLength(8));
    expect(
      kOnboardingSteps.map((OnboardingStep s) => s.id).toList(),
      <OnboardingStepId>[
        OnboardingStepId.models,
        OnboardingStepId.createAgent,
        OnboardingStepId.agentModel,
        OnboardingStepId.workspace,
        OnboardingStepId.plugins,
        OnboardingStepId.files,
        OnboardingStepId.terminal,
        OnboardingStepId.demo,
      ],
    );
  });

  test('每一步都有标题 / 说明 / 带我过去的文案，且编号从 1 排到 8', () {
    for (int i = 0; i < kOnboardingSteps.length; i++) {
      final OnboardingStep step = kOnboardingSteps[i];
      expect(step.title, startsWith('${i + 1}/8'), reason: step.id.name);
      expect(step.body.trim(), isNotEmpty, reason: step.id.name);
      expect(step.actionLabel.trim(), isNotEmpty, reason: step.id.name);
    }
  });

  test('第 8 步（demo）的说明里带着那句原话，且常量就是用户给的那句', () {
    expect(kOnboardingDemoText, '创建一名成员，负责插件开发');
    final OnboardingStep demo = kOnboardingSteps.last;
    expect(demo.id, OnboardingStepId.demo);
    expect(demo.body, contains(kOnboardingDemoText));
  });

  test('每一步的「带我过去」都说清会去哪（不是「点击这里」这种含糊话）', () {
    for (final OnboardingStep step in kOnboardingSteps) {
      expect(
        step.actionLabel,
        isNot(contains('点击')),
        reason: '${step.id.name}：按钮文案要说明目的地',
      );
    }
  });
}
