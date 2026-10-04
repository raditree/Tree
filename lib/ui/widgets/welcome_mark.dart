import 'package:flutter/material.dart';

/// 中栏空态的欢迎标识：主题色的 `TREE` 字标 + HUD 三段线。
///
/// 用户 2026-10-04：「中间页的 hello 标识有点 out-of-date 且与本应用主题色不合」——
/// 原来的 `👋` 是**平台彩色**字体（Windows 上是黄色），染不上主题色，摆在绿 + 近黑的
/// 品牌配色里是"外来色"；而且它跟应用图标（近黑底 + 亮绿 HUD 断口弧）没有任何关系。
///
/// 版式是用户从 8 个候选里定的「C7」：
/// - **字**：`TREE` 大写、宽字距、w800、主色渐变（深色 亮绿→渐变深绿；浅色 深绿→中绿）；
/// - **线**：**HUD 三段线**——中间一段更粗更亮、两侧短段带缺口，呼应应用图标那圈断口弧。
///
/// 全是纯样式（[TextStyle] / [ShaderMask] / [Container]）：**不加资源、不动 pubspec**，
/// 颜色一律取自 [ColorScheme] 的主色，深浅主题各自成套。
/// **什么时候**显示它（只在"确实加载完且真的没有消息"时）的口径在 `MessageList` 那边。
class WelcomeMark extends StatelessWidget {
  const WelcomeMark({super.key});

  /// 字标文案（大写是版式的一部分）
  static const String wordmark = 'TREE';

  /// 字标下那一行问候
  static const String caption = '你好，欢迎使用';

  /// 字标字号与字距（宽字距是这版式的主体，别单独调）
  static const double wordmarkFontSize = 25;
  static const double wordmarkLetterSpacing = 7;

  /// HUD 三段线的几何：两侧短段（半透明）、中间长段（实心），段间留缺口
  static const double sideSegmentWidth = 15;
  static const double midSegmentWidth = 34;
  static const double segmentGap = 5;
  static const double sideSegmentHeight = 2.4;
  static const double midSegmentHeight = 3.6;

  /// 三段线整体宽度（= 2×侧段 + 中段 + 2×缺口）
  static const double ruleWidth =
      sideSegmentWidth * 2 + midSegmentWidth + segmentGap * 2;

  /// 测试用键
  static const Key wordmarkKey = Key('welcome-mark-wordmark');
  static const Key ruleKey = Key('welcome-mark-rule');

  /// 品牌渐变的两个色停。
  ///
  /// 起点就是**主题主色**（深色 = 亮绿 `#00FF8C`、浅色 = 深绿 `#00904A`，随主题走），
  /// 终点按主题补一个同族色：深色 → 应用图标那头的渐变深绿，浅色 → 中绿（白底上仍可读）。
  ///
  /// 为什么终点写成字面量：品牌色板是 `main.dart` 里 `AgentTeamApp` 的静态常量，
  /// 组件反向 import `main.dart` 会绕成一圈；这里只固定两个终点，起点仍随主题。
  static List<Color> gradientOf(ColorScheme cs) =>
      cs.brightness == Brightness.dark
          ? <Color>[cs.primary, const Color(0xFF00904A)]
          : <Color>[cs.primary, const Color(0xFF00B45C)];

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 字：ShaderMask 只吃 alpha（颜色由渐变决定），所以底字给白色
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (Rect bounds) => LinearGradient(
            colors: gradientOf(cs),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(bounds),
          child: const Text(
            wordmark,
            key: wordmarkKey,
            style: TextStyle(
              fontSize: wordmarkFontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: wordmarkLetterSpacing,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 10),
        _buildHudRule(cs),
        const SizedBox(height: 16),
        Text(
          caption,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
        ),
      ],
    );
  }

  /// HUD 三段线：中间段更亮更粗，两侧段半透明（缺口 = 段间那段空白）
  Widget _buildHudRule(ColorScheme cs) {
    Widget segment(double width, double height, Color color) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(height / 2),
          ),
        );
    return Row(
      key: ruleKey,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        segment(
          sideSegmentWidth,
          sideSegmentHeight,
          cs.primary.withValues(alpha: 0.5),
        ),
        const SizedBox(width: segmentGap),
        segment(midSegmentWidth, midSegmentHeight, cs.primary),
        const SizedBox(width: segmentGap),
        segment(
          sideSegmentWidth,
          sideSegmentHeight,
          cs.primary.withValues(alpha: 0.5),
        ),
      ],
    );
  }
}
