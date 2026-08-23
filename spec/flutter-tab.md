---
id: flutter-tab
title: Flutter 前端多组件改造（Tab 容器/自定义下拉/复制/折叠交互）
task_type: custom
description: Flutter 前端 UI 多组件改造的标准实施流程与技术约束（基于 Tree commit C 实施经验）
when:
  - Flutter 前端多组件改造（跨文件、多组件）
  - 会话下拉/列表项右键菜单
  - 右栏 Tab 容器扩展（MCP/模型信息等）
  - 消息 markdown 复制按钮
  - UI 体验优化（折叠/空态）
  - 前后端接口契约并行开发
tags: [custom]
pinned: false
builtin: false
created_at: 1787413158
updated_at: 1787413158
---

## 工作流（workflow）

## 工作流
1. **接口契约先行**：先确认后端 REST 是否就绪（读 server 路由或 ApiService 现状）；未就绪时按约定路径实现前端封装，UI 必须带加载失败+重试兜底（后端 404 时优雅降级）。
2. **选型约束检查**：确认 Flutter/Dart 版本（.dart_tool/version 或 pubspec environment），按约束选 API（见规则）。
3. **逐个组件实施**：ApiService 封装 → 组件重写 → 页面容器集成 → UI 细节。
4. **契约验证**：flutter analyze 通过；抽查后端路由路径与前端封装一致。
5. **交付汇报**：改动文件清单 + 技术选型理由 + 依赖后端接口的状态。

## 该类任务规范

## 技术约束（Flutter 3.7.x / Dart 2.19.6，实测）
- **MenuAnchor 3.7 初版不支持「菜单项内二级右键」**：需要列表项内再弹右键菜单时用 Overlay 自绘下拉（CompositedTransformTarget/Follower + Stack 点击屏障 + showMenu 二级菜单），勿用 PopupMenuButton/MenuAnchor。
- **SelectionArea 不能与 MarkdownBody(selectable:true) 嵌套**（SelectionArea 内禁含 SelectableText/EditableText，会断言失败）；要跨段选择则 MarkdownBody 设 selectable:false 由外层 SelectionArea 接管，另加「复制全文」按钮（Clipboard.setData 原始 markdown）。
- **ColorScheme 新 token 不可用**：Flutter 3.7 无 surfaceContainerHighest（3.22+）；用 surfaceVariant。
- **多 TabController 需 TickerProviderStateMixin**（SingleTickerProviderStateMixin 只支持一个）。
- **CRLF 文件 edit 陷阱**：Windows 下 CRLF 文件的含换行锚点匹配失败（工具按 LF 匹配）；先转 LF 或改用单行/无前导缩进锚点。
- TabBar 默认高度 46；放入 48 高 Row 与 IconButton 并排需 Expanded 包裹。
- 默认会话（session_id == 'session_default'）禁用重命名/删除。

## 注意事项

## 注意事项
- 前后端并行时：前端按约定接口实现，后端未实现显示「加载失败+重试」，不阻塞联调。
- 大文件（如 main_page.dart）改动前先确认换行符与编码，避免锚点匹配反复失败。
- 新增独立组件（MCP 页/模型信息页）放 lib/ui/widgets/，页面容器只做 Tab 集成。
- flutter analyze 通过即编译契约正确；运行时行为（SelectionArea 等）需回归测试。
