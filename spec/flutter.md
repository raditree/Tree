---
id: flutter
title: Flutter 主题品牌色统一调整（对齐应用图标）
task_type: custom
description: Flutter 应用主题色与应用图标不一致时的品牌色统一：从图标提取主色 → 改主题 primary/onPrimary/primaryContainer → 替换页面硬编码品牌色 → 适配气泡/头像文字对比度 → verify（analyze+test）→ 同步 web manifest
when:
  - 用户指出界面色彩与图标/品牌视觉不一致
  - 主题主色换新（深浅两套 primary 更换）
  - 硬编码品牌色散落多个页面需统一
  - 换色后需处理 onPrimary 对比度（气泡/头像/按钮文字）
tags: [custom]
pinned: false
builtin: false
created_at: 1787564848
updated_at: 1787564848
---

## 工作流（workflow）

1. **提取图标主色**：用 PIL 脚本统计亮色像素（饱和度/亮度过滤），取 top 主色 + 渐变深色（如 #00FF8C 亮绿 + #00904A 深绿）。
2. **定色板**：深色主题 primary=图标主亮色（#00FF8C），浅色主题 primary=图标渐变深色（#00904A，保证白底对比度 ≥3:1）；同步定义 onPrimary（深色主题 onPrimary 用深墨绿，绝不能让白字压在亮绿上）、primaryContainer/onPrimaryContainer。
3. **改主题**：main.dart 的 ThemeData（primaryColor/appBarTheme/colorScheme/textSelectionTheme 注释）。
4. **扫硬编码**：全库 grep 旧品牌色 hex（如 2563EB），逐一替换；语义色（错误红/警告黄/成功绿/工具类型色板）保留不动。
5. **对比度适配**：用户气泡（cs.primary 底）内文字/附件/时间从 Colors.white 改为 cs.onPrimary 系；列表头像背景色改为跟随 Theme colorScheme.primary + onPrimary。
6. **verify**：flutter analyze（必须 0 error）+ flutter test 全量通过；grep 确认旧品牌色仅剩语义/注释残留。
7. **同步 web 端**：web/manifest.json 的 theme_color/background_color 同步为品牌色。
8. 完成后 git status 核对改动文件清单。

## 该类任务规范

- 换主题主色时必须同时检查 onPrimary 与 primaryContainer，Material2 下 ColorScheme 默认 onPrimary=white，亮绿/亮黄主色配白字是不可读的 bug。
- 硬编码品牌色集中在固定浅色页面（login/settings/ssh 弹窗）时统一用浅色主色（深绿）；列表/头像等跨模式组件优先改为 Theme colorScheme.primary 跟随主题，避免两套硬编码。
- 工具类型色板（read=蓝/write=绿/terminal=橙…）与状态语义色（红/黄/绿）属于功能区分色，不属于品牌色，不替换。
- 用户气泡内所有子元素（附件卡片、时间戳）的白字都要一起适配 onPrimary，不能只改主文字。
- [Warning] 换色后必须跑 analyze+test，防止 Theme.of(context) 在无 context 方法/async gap 中误用。

## 注意事项

- 截图读取注意：read 图像经前端执行器编码 base64，Windows 环境无 base64 命令时失败；且用户上传的 .input 截图在终端视角不存在，需用 PIL 直接分析宿主文件（图标）或请用户确认。
- 颜色对比度粗算法：sRGB 相对亮度 L=0.2126R+0.7152G+0.0722B（linear 后），对比=(L1+0.05)/(L2+0.05)。白字 on #00FF8C≈1.4:1 不可读。
