# 插件体系（一期骨架 · 联调对齐版）

进程内事件总线 + 插件注册表 + 通用看门狗 + 出站 SDK（设计定案见
`agentspace/.hard/20260913-plugin-stations/decisions/ADR.md`，D1–D9；
接口契约见 `agentspace/.hard/20260913-plugin-stations/artifacts/interface-contract.md` v1）。

> **状态（2026-09-13）**：一期已接线（`main.py` lifespan 挂载 + `agent/routes.py`
> 级联清理 4 处）；**默认关闭**，设 `TREE_PLUGIN_ENABLED=1` 并重启后端进程生效。
> 联调对齐：知遥 isolation/async v2 + 栖迟 core 四件套 **64 passed + 1 skipped**
> （skip = J5 活跃组上限，见文末差异清单）；全量回归相对基线零破坏。

## 模块结构

| 文件 | 职责 | ADR 对应 |
|------|------|----------|
| `__init__.py` | 模块门面：总开关 / 单例获取 / 生命周期 / 埋点入口（safe_publish）/ 级联清理入口（plugin_cascade） | — |
| `bus.py` | 事件总线：统一信封、非阻塞发布、scope/type 过滤、异步分发、有界队列背压（drop_oldest） | D1 / D4 / D9 |
| `registry.py` | 插件实例注册表：实例按 scope 四元组隔离、TTL/Pin（周期清扫驱动）、级联清理（cascade_cleanup）、实例内串行 | D2 / D3 |
| `watchdog.py` | 通用看门狗：进度续期 + 滑窗判死（10s/60s）+ fail-closed 归属校验；实例级心跳 | D7 |
| `sdk.py` | 受控出站 SDK：workspace / dispatch / ws / log（白名单 + scope 强校验） | D6 |
| `join.py` | join 最小原语：键值/计数齐备 + 超时 + partial 交付 | D5 |
| `plugins/architecture_analyzer.py` | 示例插件：订阅工具事件 → 读工作空间 → 推送摘要（三站全链路） | 一期示范 |

## 总开关（默认关闭；关闭时零副作用）

```python
import plugin

plugin.is_enabled()          # 当前开关状态（默认 False）
plugin.set_enabled(True)     # 运行时启用（懒初始化组件）
plugin.set_enabled(False)    # 关闭事件接收（组件保留，处理完积压事件）
plugin.shutdown()            # 完整停止（组件销毁 + 开关复位；测试/退出用）
```

- 环境变量 `TREE_PLUGIN_ENABLED=1`（`1/true/yes/on`）可在进程启动时默认启用；
- **关闭状态**：埋点 `safe_publish` / 级联清理 `plugin_cascade` 立即返回
  （False / 0）——不校验、不创建组件、不入队、不起线程（对现有行为零副作用）。

### 启动接线（已落地）

```python
# server/main.py lifespan（ws_manager 初始化之后）
from plugin import init_plugin_system
init_plugin_system()   # 仅当总开关开启时初始化组件 + 绑定主事件循环；默认关时 no-op
```

### 级联清理接线（已落地）

```python
# server/agent/routes.py（顶部 helper：懒 import + 全异常吞噬）
_plugin_cascade(user_id, agent_id=..., session_id=...)   # 会话删除 / 历史清空
_plugin_cascade(user_id, agent_id=...)                   # agent 删除 / 配置更新
_plugin_cascade(user_id, team_id=...)                    # TOP 删除（团队解散）
```

匹配语义（契约 §5.1）：`user_id` 必选；team/agent/session 为空 = 不限定，
非空必须与实例 scope 相等才命中；fail-closed 方向。

## 快速用法

```python
import plugin
from plugin import PluginSDK
from plugin.plugins.architecture_analyzer import ArchitectureAnalyzerPlugin, SUBSCRIBED_TYPES

plugin.set_enabled(True)

scope = {"user_id": "u1", "team_id": "t1", "agent_id": "a1", "session_id": "s1"}
sdk = PluginSDK(scope)                      # 出站 SDK（绑定实例 scope）
analyzer = ArchitectureAnalyzerPlugin(sdk, notify_targets=["a1"])

# 注册插件实例（team 粒度：服务该团队全部 agent/session；同键幂等复用）
inst = plugin.get_registry().register(
    "architecture_analyzer",
    analyzer.on_event,
    granularity="team",                     # team / agent / session
    scope={"user_id": "u1", "team_id": "t1"},
    event_types=SUBSCRIBED_TYPES,           # {"tool.call.completed"}
)

# 发布事件（通常由埋点自动发布；也可手动）
plugin.get_bus().publish("tool.call.completed", scope, {"tool_name": "read"}, source="manual")
```

### 出站能力（PluginSDK，fail-closed 校验）

| 方法 | 说明 |
|------|------|
| `workspace_read(path, workspace_id=None)` / `workspace_write(path, content, workspace_id=None)` | 读 / 写工作空间（workspace_id 白名单：agent_id / team_id） |
| `dispatch_agent_message(target_ids, content, ...)` / `push_to_agent(target_ids, content, session_id="")` | 向 agent 推送（默认 `active=False` 防循环；后为契约 §7 别名） |
| `ws_push({"type": "plugin_*", ...})` / `emit_frontend(event_type, data)` | 向前端推送（需主循环绑定；后为契约 §7 别名，构造 `plugin_event` 消息） |
| `activity_log(message)` / `log_activity(message)` | 追加活动日志（后为契约 §7 别名） |

越权调用返回 `{"error": ...}`（读取类）或 `False`（推送类），**绝不静默降级**。

### 依赖注入（测试 / 演示）

`plugin.sdk.set_io_provider / set_dispatcher / set_ws_sender / set_log_fn /
reset_injections()` 可替换底层实现（生产默认走延迟 import 的真实实现）。

## 埋点接入（一期：工具执行）

- **唯一入口**：`plugin.safe_publish(event_type, scope, payload, source)`
  —— 吞掉一切异常；总开关关闭 / 组件未初始化时静默 no-op（零副作用）。
- **点位**：`server/llm/llm.py::_run_completion_loop` 工具执行结果装配处
  （`yield tool_call` 之前）：

```python
plugin.safe_publish(
    "tool.call.completed",
    scope={"user_id": ..., "team_id": ..., "agent_id": ..., "session_id": ...},
    payload={"tool_name": ..., "duration_ms": ..., "ok": bool, "result_size": int},
    source="embedded:llm",
)
```

- payload 为**最小字段**（不含参数值与结果正文，防敏感数据扩散）；
- scope 四元组由 `AgentLLMSession` 携带并装配（`user_id/team_id/agent_id/session_id`）；
  三个生产构造点补传口径：成员会话 `team_id=team_id or agent_id`（chat.py 成员路径）、
  agent 会话 `team_id=agent_id`（顶层会话）、compact 临时会话仅装配 `session_id`
  （该路径无团队上下文且不执行工具循环，`team_id` 如实留空）；
- 未装配时字段为空串：fail-closed 语义下，事件缺字段时不命中要求该字段的实例；
  `user_id` 为空的事件拒绝发布；
- 兼容包装 `plugin.publish_tool_event(session, ...)` 保留（内部经 `safe_publish`）。

## 测试与演示

```bat
:: 插件四件套（isolation / async / core / scope_assembly）
cd server && .venv\Scripts\python.exe -m pytest tests/test_plugin_isolation.py tests/test_plugin_async.py tests/test_plugin_core.py tests/test_plugin_scope_assembly.py -q
::  → 64 passed + 1 skipped（skip = J5 活跃组上限，已知差异；含 D-13 并发注册用例、D-08 装配链路用例）

:: 端到端演示（publish → 处理 → 出站；含越权拒绝演示）
server\.venv\Scripts\python.exe .output\plugin_demo.py

:: C1 验证：TTL 周期清扫实测（小 TTL 常量；日志：.output/plugin_c1_ttl_sweep.log）
server\.venv\Scripts\python.exe .output\plugin_c1_ttl_sweep_demo.py

:: 全量回归（对比基线：621 passed → 685 passed / 1 skipped，零破坏；含 D-08 +4 用例）
cd server && .venv\Scripts\python.exe -m pytest tests/ -q
```

## 与 interface-contract v1 的对齐与差异（联调逐项评审输入）

> **评审状态**（观澜，2026-09-13）：有条件通过 → C1/C2 已补齐并经独立补验
> （知遥 `test-report.md` v2，ALL PASS）→ **待复核转"通过"**。

**已对齐（本轮）**：

- 溢出策略：drop_oldest（保最新 + `dropped_full` 计数）；
- 级联清理：`cascade_cleanup` 语义（§5.1）已实现，并接线路由 4 处；
- 注册表：`set_pin` / `touch` / `list_instances` 补齐；TTL 默认 3600s
  （env `PLUGIN_INSTANCE_TTL_S` 可配；Pin 豁免）；
- 埋点：`safe_publish` 唯一入口 + `tool.call.completed` + 最小 payload；
- 看门狗：`register_run` / `note_progress` / `finish_run` / `heartbeat_instance`
  薄别名（fail-closed 归属校验沿用既有实现）；
- SDK：`push_to_agent` / `emit_frontend` / `log_activity` 契约别名；
- 初始化：`main.lifespan` 挂载 + routes 接线完成；前端忽略项已由柳依确认；
- **D-12/C1（评审条件，已补齐）**：初始化后启动 TTL 周期清扫线程
  （`start_sweeper()`；间隔 env `PLUGIN_TTL_SWEEP_INTERVAL_S`，默认 600s）；
- **D-13/C2（评审条件，已补齐）**：`register` 的"检查+插入"归并同一临界区，
  消除并发注册同键的孤儿窗口。

**保留差异（评审裁定：接受现状或二期；见 review-notes）**：

1. 总线类名沿用 `EventBus`（契约文字中为 `PluginBus`）——未改名；
2. 插件声明式定义层（`PluginSpec` / `register(spec)` / `get_or_create_instance` /
   懒创建）未实现：一期为显式 `register`（同键幂等复用）；
3. join 为独立原语 `JoinBuffer`（键/计数/超时/partial）；"组窗口 + 双上限 +
   活跃组管理"未实现（async J5 标注 skip）；
4. watchdog 无 auto_tick 监控循环、"连续判死 ≥2 → 停用实例"联动与
   `max_run_seconds` 执行（参数已存档）；
5. `registry.stats()` 返回实例快照 list（契约签名为 dict）；
6. SDK 未提供 `workspace_exec` / `workspace_grep` / `workspace_git_log` /
   `workspace_list`；`workspace_read` 无 `encoding` 参数；
7. WS 协议仅落地 `plugin_event`（`emit_frontend`）；`plugin_status`
   生命周期事件未发。

**口径更正**：契约 §5 表格 "TTL 默认 1800s" 与协调裁定 "3600s" 不一致——
按裁定实现 3600s。

## 一期已知局限与后续

1. `ws_push` 调度链：优先显式绑定循环（`bind_loop` / `init_plugin_system`），
   兜底复用 `state.local_executor` 已绑定循环；均无时降级丢弃（返回 False）；
2. 实例创建为显式注册（`register` 幂等）；按需懒实例化留二期；
3. join 为内存态最小原语（超时解除）；持久化 / 跨重启留二期；
4. 示例插件读取路径固定 `README.md`（演示用），真实场景可参数化；
5. 埋点字段如需扩展（如参数预览），另行评审（安全边界）；
6. 一期不做 UI、不做宿主通道、不持久化（见 ADR 分期）。
