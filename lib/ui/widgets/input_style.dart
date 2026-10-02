import 'package:flutter/material.dart';

/// 「无边框输入框」的装饰（边框由**外层卡片**画）。
///
/// 为什么必须是这个常量、而不是随手写一句 `border: InputBorder.none`：
/// 全局主题（[main.dart](../../main.dart) 的 `inputDecorationTheme`）给了
/// `enabledBorder` 与 `focusedBorder` 一圈 `OutlineInputBorder`（那是给设置页、各种
/// 表单用的）。而 `InputDecoration` 画边框的解析顺序是
/// **focusedBorder → enabledBorder → border**：只覆盖 `border`，主题那一圈照样画出来——
/// 表现就是"卡片里还有一个方框"（用户 2026-10-03 的截图：输入框中间多了一圈绿框）。
///
/// 所以「不要边框」必须把五个字段一起置空：enabled / focused / disabled / error /
/// focusedError。用 `kBorderlessInput.copyWith(...)` 再补 hintText / contentPadding 等。
const InputDecoration kBorderlessInput = InputDecoration(
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
);
