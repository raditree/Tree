import 'package:flutter/material.dart';

/// 右下角那个**停止键**（占发送键的位置）：实心圆 + 白色圆角方块。
///
/// 用户 2026-10-04 给的样子，两个 composer 共用同一份实现（中栏的 [MessageInput] 与
/// 成员面板的输入行），免得两处各画一套、越改越不像。
///
/// 出现时机由调用方决定（约定：**该 agent 正在生成** 且**输入框还是空的**时替换
/// 发送键；一旦开始打字就换回发送键——发送本身就意味着"中止这一轮并另起一轮"）。
class StopButton extends StatelessWidget {
  const StopButton({
    super.key,
    required this.onPressed,
    this.size = 34,
    this.tooltip = '停止这一轮生成（直接发新消息也会中止并另起一轮）',
  });

  final VoidCallback? onPressed;

  /// 圆形直径（与发送键一致，保证两种状态占同一个位置）。
  final double size;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: cs.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Container(
                width: size * 0.35,
                height: size * 0.35,
                decoration: BoxDecoration(
                  color: cs.onPrimary,
                  borderRadius: BorderRadius.circular(size * 0.09),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
