import 'package:flutter/material.dart';

import '../services/onboarding_steps.dart';

/// 新手引导的**浮层卡片**（非模态：盖在中栏上方一小块，用户照样能点后面的界面）。
///
/// 为什么不是向导对话框：每一步的「带我过去」都要**打开真实的界面**（设置页、建 agent
/// 对话框、右栏页签、终端），模态对话框会把那些界面挡在外面——用户只能看着引导发愣。
/// 这里做成一张可随时跳过的小卡片，用户想边看边点就边看边点。
///
/// 口径（见 lib/README.md 不变量 17）：
/// - 「下一步」= **跳过这一步**（不做也不点【带我过去】，直接走）；
/// - 「跳过引导」= 整段跳过，两个都记进 [OnboardingState]，之后不再自动弹；
/// - 最后一步的【完成】= 走完；【带我过去】在那一步是"把 demo 那句话填进输入框"。
class OnboardingGuide extends StatelessWidget {
  const OnboardingGuide({
    super.key,
    required this.step,
    required this.index,
    required this.total,
    required this.onAction,
    required this.onNext,
    required this.onBack,
    required this.onSkipAll,
    required this.onFinish,
  });

  final OnboardingStep step;

  /// 当前第几步（0 基）与总步数（显示成 `3/8`）。
  final int index;
  final int total;

  /// 点【带我过去】：打开对应的真实界面（或预填 demo 文本）。
  final VoidCallback onAction;

  final VoidCallback onNext;
  final VoidCallback onBack;
  final VoidCallback onSkipAll;
  final VoidCallback onFinish;

  bool get _isLast => index >= total - 1;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey<String>('onboarding-guide'),
      elevation: 8,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
      ),
      child: Container(
        width: 460,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.tips_and_updates_outlined, size: 17, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '新手引导 · ${index + 1}/$total',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey<String>('onboarding-skip-all'),
                  onPressed: onSkipAll,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  child: const Text('跳过引导', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              step.title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              step.body,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                if (index > 0)
                  TextButton(
                    key: const ValueKey<String>('onboarding-back'),
                    onPressed: onBack,
                    child: const Text('上一步', style: TextStyle(fontSize: 12)),
                  ),
                const Spacer(),
                OutlinedButton(
                  key: const ValueKey<String>('onboarding-action'),
                  onPressed: onAction,
                  child: Text(
                    step.actionLabel,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey<String>('onboarding-next'),
                  onPressed: _isLast ? onFinish : onNext,
                  child: Text(
                    _isLast ? '完成' : '下一步（跳过这步）',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
