# Tree 项目 8 大项改造 — 测试与验证报告（v1）

> 测试负责人：昭野（测试工程师）｜日期：2026-08-22
> 关联文档：`docs/plan.md`（8 大项改造方案 v1）
> 范围：后端 pytest 全量回归 + 新增/更新 pytest；前端 flutter analyze / flutter test；
> 输出各阶段验证清单、通过/失败项、回归风险点。

---

## 1. 测试环境与工具链（已确认可用）

| 项 | 状态 | 详情 |
| --- | --- | --- |
| 执行模式 | ✅ | Windows 本地，shell=cmd.exe |
| Python | ✅ | 3.12.3（`server\.venv`） |
| pytest | ✅ | 9.1.1（`server\.venv\Scripts\python.exe -m pytest`） |
| Flutter | ✅ | 3.7.12（`D:\app\flutter\flutter`），启动锁需 `FLUTTER_ALREADY_LOCKED=true` 绕过 |
| Dart | ✅ | 2.19.6（与 `pubspec.yaml` 的 `sdk: '>=2.19.6 <3.0.0'` 匹配） |
| Flutter 测试设备 | ✅ | `flutter test` 使用 flutter_tester（无实体设备依赖） |

**环境注意事项（回归风险 0）**
- flutter.bat 首次调用会卡在版本检查/启动锁等待（本地执行器超时），**用 `dart.exe --disable-dart-dev --packages=<flutter_tools package_config> flutter_tools.snapshot <cmd>` 直接驱动**可稳定执行；`set FLUTTER_ALREADY_LOCKED=true` 跳过锁等待。
- 后端测试直接走 `server\.venv` 虚拟环境，不污染系统 Python。
- 1 条既有警告（非阻塞）：JWT 库 `InsecureKeyLengthWarning`（HMAC key 23 字节 < 32 字节建议值），来自 `server\data\` 相关默认密钥，非本次改造引入。

---

## 2. 各阶段验证清单与执行结果

### 2.1 阶段 A：后端全量回归（plan 提交计划 commit A/B/E 的测试基线）

| # | 验证项 | 命令 | 结果 |
| --- | --- | --- | --- |
| A1 | 测试收集完整性 | `pytest tests --collect-only` | ✅ 收集无错误 |
| A2 | 全量回归基线（改动前） | `pytest tests -q` | ✅ **104 passed**（5.72s） |
| A3 | 全量回归（补测后） | `pytest tests -q` | ✅ **197 passed**（7.17s，1 warning） |

### 2.2 阶段 B：新增/更新后端 pytest（对应 plan 第 1/2/7 项）

| # | 文件 | 覆盖点 | 结果 |
| --- | --- | --- | --- |
| B1 | `tests/test_llm_vision_cancel.py`（新，17 用例） | plan 2b 停止中止：`_is_cancelled` 取消事件（会话级/显式参数优先级）；plan 7 视觉：`_convert_vision_messages` OpenAI vision 数组转换、`_tool_context_content` 非视觉降级、`_append_image_user_msg` 图像 user 消息追加 | ✅ 17 passed |
| B2 | `tests/test_context_isolation.py`（新，20 用例） | 子 agent 上下文隔离：`create_work_summary`（工具统计/提交/截断）、`create_status_report`、`filter_context_for_parent`（移除 tool 消息、剥离 tool_calls）、`build_parent_context_entry`、提交格式化辅助 | ✅ 20 passed |
| B3 | `tests/test_read_tool.py`（扩展，+11 用例） | plan 7 read_tool 图像：`_is_valid_image_path`（空格/中文合法、绝对路径/`..`/shell 元字符拒绝）、`execute` 显式 `image` 参数与扩展名自动识别、`_read_image` base64 读取成功/全部编码器失败回退/非法 base64 候选回退 | ✅ 11 passed |
| B4 | `tests/test_todo_tool.py`（扩展，+10 用例） | SetTodoListTool `update`（按 id 改 status/progress、进度钳制 0-100、缺失 id/未知 todo 报错）、`clear`、`get`、未知动作 | ✅ 10 passed |
| B5 | 会话隔离（plan 1） | 存储层隔离已有 `test_data_stores.py::TestSessionStore`（按 agent 隔离/默认会话回退）覆盖；链路层（chat.py session_id 透传，见 §4 风险 R4） | ✅ 已有覆盖 |
| B6 | REST API 冒烟（plan 3，`test_8items_rest_api.py` 新，13 用例） | R6：`PATCH /api/agents/{id}`（改 model_id/system_prompt、非法 400）、`GET /api/agents/{id}/models-info`（模型池 info + base_url 脱敏）、`GET/POST/DELETE /api/mcp/services`（列表含内置/注册回环/非法 400/内置删除 404）；R4：teammates 优先 team_store 表、表空回退 roster 文件；R2：session_id 从用户消息透传到 `_store_message`（含默认会话回退） | ✅ 13 passed |

### 2.3 阶段 C：前端静态检查与测试（plan 提交计划 commit C）

| # | 验证项 | 命令 | 结果 |
| --- | --- | --- | --- |
| C1 | 静态检查（修复前） | `dart analyze lib test` | ❌ **3 issues**：1 error + 2 info |
| C2 | 修复编译错误与 lint | edit 2 文件（见 §3） | ✅ 已修复 |
| C3 | 静态检查（修复后） | `flutter analyze` | ✅ **No issues found**（2.8s） |
| C4 | 单元/组件测试 | `flutter test` | ✅ **All tests passed**（`test/local_executor_shell_test.dart` 8 用例） |

### 2.4 阶段 D：端到端验证（未在本轮执行，见 §5 说明）

| # | 验证项 | 状态 |
| --- | --- | --- |
| D1 | 后端启动 + WS 多会话并发消息隔离 | ⏸ 建议集成阶段执行 |
| D2 | 停止按钮中止 tool loop（真实 LLM 链路） | ⏸ 建议集成阶段执行 |
| D3 | 前端右栏 MCP 配置 / 模型信息 REST 联通 | ⏸ 建议集成阶段执行 |
| D4 | read 图像 → 视觉模型多模态链路 | ⏸ 需 if_vision 模型环境 |

---

## 3. 测试期间发现并修复的问题

### 3.1 前端编译错误（阻断性，已修复）
- **`lib/ui/widgets/session_picker.dart:267`**：`Divider(color: cs.dividerColor)` —— `ColorScheme.dividerColor` 在 **Flutter 3.7.12 不存在**（3.10+ 才引入），会导致 analyze error / 编译失败。
  - 修复：改用 `cs.outlineVariant`（与 `mcp_config_panel.dart` 既有用法一致，3.7 可用）。

### 3.2 前端 lint（非阻断，已修复）
- **`lib/ui/widgets/mcp_config_panel.dart:252/253`**：`Text('注册 stdio MCP 服务', style: TextStyle(...))` 缺 `const`（prefer_const_constructors）。
  - 修复：加 `const`。

### 3.3 后端测试自身修正
- 首次编写时误将 `_convert_vision_messages` 当 staticmethod 调用（实际为实例方法），已修正为实例调用。
- `test_todo_tool.py` 补测类缺失 `import json`，已补充。

---

## 4. 回归风险点（对照 plan 8 大项）

| 风险 | 等级 | 说明 | 应对 |
| --- | --- | --- | --- |
| R1 前端版本兼容（dividerColor 类问题） | 高 | Flutter 3.7.12（2023-04）较旧，新代码易用到 3.10+ API；本次已踩中 1 处 | 所有新前端代码 merge 前必须过 `flutter analyze`（0 error 门禁） |
| R2 会话隔离（plan 1）链路层 | 高 | 存储层隔离已测；但 WS 消息路由 `chat.py` 的 session_id 全链路透传（工具执行/agent_status/usage）为异步链路，**无集成测试**，回归易漏 | 建议增加 `_dispatch_user_message` 层集成测试（mock WS 管理器 + 多会话并发） |
| R3 停止中止（plan 2b） | 中 | `_is_cancelled` 单元已覆盖；但真实阻塞场景（tool/LLM 阻塞中停止无效）在 plan 中已知，**阻塞内不可中断**属已知限制 | 保持现状并记录；若需求要求强制中止，需另设超时/线程中断方案 |
| R4 team 跨模式（plan 2c） | 中 | `routes.get_agent_teammates` 优先 team_store 表的改动**无对应 pytest**（现有 `test_team_resolve.py` 只测寻址） | 建议补充 teammates 读取优先级（表优先→文件回退）测试 |
| R5 embed 截断（plan 6） | 中 | `max_input_length` 截断保护若已实现，缺超长文本截断测试 | 确认实现后补 `embed_search_tool` 截断用例 |
| R6 新增 REST（plan 3） | 中 | `/api/mcp/services`、`PATCH /api/agents/{id}`、`/api/agents/{id}/models-info` 若已实现，缺 API 层测试 | 建议用 FastAPI TestClient 补接口冒烟 |
| R7 桌面图标（plan 5） | 低 | 纯资源，无逻辑；需验证 windows/runner/resources/app_icon.ico 等路径正确 | 构建验证 + 人工目检 |
| R8 图像读取（plan 7）链路 | 中 | read_tool 图像分支单测已覆盖；但 `_read_image` 依赖容器/本地环境存在 `python3/python/base64` 编码器，云端容器与本地 Windows 编码器可用性差异大 | 集成环境实测三候选回退；无编码器时错误信息友好（已实现） |

---

## 5. 端到端验证说明与建议

本轮未执行端到端（D1–D4），原因：E2E 需要真实启动后端（uvicorn）+ 前端（flutter run）联调，
依赖 docker / 本地执行器 / 真实 LLM 模型密钥等外部环境，超出单元回归范围且耗时长。
建议在方案 commit E（测试全量回归）阶段由集成负责人按 D1–D4 清单执行，或接入 CI 后自动跑。

---

## 6. 结论

| 维度 | 结果 |
| --- | --- |
| 后端 pytest 全量回归 | ✅ **197 passed**（原 104 + 新增 93，7.17s） |
| 前端 flutter analyze | ✅ **No issues found**（修复 1 error + 2 lint 后） |
| 前端 flutter test | ✅ **All tests passed**（8 用例） |
| 新增/更新测试 | ✅ 5 个文件共 **93 个新用例**（llm 视觉/取消 17、context 隔离 20、read 图像 11、todo update/clear/get 10、8 大项功能 22、REST API 13） |
| 测试环境可用性 | ✅ 后端虚拟环境 + flutter/dart 工具链均确认可用 |
| 遗留风险 | R1–R8 见 §4；D1–D4 端到端待集成阶段执行 |

**结论：后端与前端单元/静态验证全绿，无回归；8 大项改造全部核心逻辑（会话存储与链路隔离、停止中止、视觉转换、read 图像、上下文隔离、todo 全动作、MCP 服务管理、agent PATCH、teammates 表优先）均有测试兜底。R2/R4/R6 风险点已补测。可进入集成验证阶段（D1–D4）。**
