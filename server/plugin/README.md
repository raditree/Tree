# 插件体系（一期骨架 · 联调对齐版）

进程内事件总线 + 插件注册表 + 通用看门狗 + 出站 SDK（设计定案见
`agentspace/.hard/20260913-plugin-stations/decisions/ADR.md`，D1–D9；
接口契约见 `agentspace/.hard/20260913-plugin-stations/artifacts/interface-contract.md` v1）。

> **状态（2026-09-13）**：一期已接线（`main.py` lifespan 挂载 + `agent/routes.py`
> 级联清理 4 处）；总开关已配置化：**env `TREE_PLUGIN_ENABLED` 显式优先 → `app.yaml`
> `plugin.enabled` 回落（缺省 false）**，重启后端进程生效。
> **半二期处理站已实施**（`stations.py` + read 结果站接入；默认无订阅=零影响，
> 见「处理站（半二期）」章节）。
> **二期 M1/M2 已提交**（plugin_status + 面板快照；宿主通道后端承接面 + 示范插件
> 自动注册）；**M3 工程小件已实施**（巡检联动 / F3 / 防呆 / 链深 / F5 / read
> encoding；见「M3 工程小件（二期 M3）」章节）。
> 联调对齐：知遥 isolation/async v2 + 栖迟 core 四件套 **64 passed + 1 skipped**
> （skip = J5 活跃组上限，见文末差异清单）；**全量回归 816 passed / 1 skipped /
> 23 subtests / 0 failed**（对照 M2 收口 783：净增 +33＝M3 21 + EN1 先行 6 +
> F-M3 补测 6，零破坏）。

## 模块结构

| 文件 | 职责 | ADR 对应 |
|------|------|----------|
| `__init__.py` | 模块门面：总开关 / 单例获取 / 生命周期 / 埋点入口（safe_publish）/ 处理站入口（safe_process）/ 级联清理入口（plugin_cascade） | — |
| `bus.py` | 事件总线：统一信封、非阻塞发布、scope/type 过滤、异步分发、有界队列背压（drop_oldest） | D1 / D4 / D9 |
| `registry.py` | 插件实例注册表：实例按 scope 四元组隔离、TTL/Pin（周期清扫驱动）、级联清理（cascade_cleanup）、实例内串行；M3：`disable`（判死/F3 联动） | D2 / D3 |
| `watchdog.py` | 通用看门狗：进度续期 + 滑窗判死（10s/60s）+ fail-closed 归属校验；实例级心跳；**M3 巡检循环**（判死双阈值 → 停用联动） | D7 / D-P2-7 |
| `sdk.py` | 受控出站 SDK：workspace / dispatch / ws / log（白名单 + scope 强校验） | D6 |
| `join.py` | join 最小原语：键值/计数齐备 + 超时 + partial 交付 | D5 |
| `stations.py` | 处理站（半二期）：站×scope 键位唯一订阅、触发/等待/回填、fail-open 降级、分类计数；M3：防呆/链深/F3/F5 | D-PS1..PS7 |
| `host.py` | 宿主通道（二期 M2）：`plugin_host_*` op 承接 / 会话表 / 清理契约四场景 / fail-closed 计数 | D-P2-5 |
| `plugins/architecture_analyzer.py` | 示例插件：订阅工具事件 → 读工作空间 → 推送摘要（三站全链路） | 一期示范 |
| `plugins/read_station_demo.py` | 处理站示范插件：read 结果加标记前缀（确定性转换；E2E 载体） | 半二期示范 |

## 总开关（来源链：env 优先 → app.yaml；缺省关闭；关闭时零副作用）

```python
import plugin

plugin.is_enabled()          # 当前开关状态（默认 False）
plugin.set_enabled(True)     # 运行时启用（懒初始化组件）
plugin.set_enabled(False)    # 关闭事件接收（组件保留，处理完积压事件）
plugin.shutdown()            # 完整停止（组件销毁 + 开关复位；测试/退出用）
```

- 环境变量 `TREE_PLUGIN_ENABLED=1`（`1/true/yes/on`）可在进程启动时启用——显式设置时优先（含 `0` 显式关闭）；
- 未设置环境变量时，按 `server/configs/app.yaml` → `plugin.enabled` 判定（缺省 false）；两者均为进程启动时生效（重启后端后应用新值）。
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
| `workspace_read(path, workspace_id=None, encoding="utf-8")` / `workspace_write(path, content, workspace_id=None)` | 读 / 写工作空间（workspace_id 白名单：agent_id / team_id；M3：read 支持 `encoding` 可选参，非法编码 fail-open） |
| `dispatch_agent_message(target_ids, content, ...)` / `push_to_agent(target_ids, content, session_id="")` | 向 agent 推送（系统不做任何自动回传，故无被动标记参数；后为契约 §7 别名） |
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

## 处理站（半二期：read 结果站）

**定位**：数据流拦截点——数据流入站时触发订阅插件（**站 × scope 键位唯一**，
先到先得），插件处理后回填为最终数据。本期接入 1 个站：`tool.read.result`
（read 工具返回前；`stringify` 后、`redirect` 前单点替换——插件拿到**完整原始
结果**，处理结果仍受 redirect 门控兜底，工具面板展示与上下文自动同值）。
图像本体 / AskUser 直通；图像摘要文本随文本结果经站；仅成功结果触发（错误结果直通）。

**订阅（插件侧，一键）**：

```python
from plugin import get_stations
from plugin.stations import STATION_READ_RESULT, StationRequest

def on_station(req: StationRequest):
    return f"[已处理] {req.data}"   # str=替换；None=不改动；其它类型=非法（走降级）

get_stations().subscribe(STATION_READ_RESULT, "my_plugin", on_station,
                         granularity="agent", scope={"user_id": "u", "agent_id": "a"})
# 便捷演示入口：plugins/read_station_demo.py::register_demo_plugin(scope=...)
```

**系统侧触发（单点）**：`plugin.safe_process(station_id, data, scope, meta=…, cancel_event=…, timeout_s=…)`

- 无订阅 / 总开关关闭：原样返回（近零开销；2000 次调用实测 ~6.5ms）；
- 有订阅：交由插件处理并等待回填（超时默认 30s，env `PLUGIN_STATION_TIMEOUT_S` 可配；
  等待分段 `PLUGIN_STATION_WAIT_SLICE_S` 默认 0.5s——决定取消/失效发现延迟）。

**降级（fail-open 红线）**：无订阅 / 超时 / 取消 / 插件异常 / 非法回填 / 实例失效 /
队列满 → **一律放行原数据** + 分类计数（`get_stations().stats()["counts"]`）：

| 计数键 | 含义 |
|---|---|
| `requests` / `responded` | 进入处理流程 / 有效回填（str 或 None） |
| `timeout` / `cancelled` | 超时 / 取消与在途失效（含实例销毁；≤1 等待段发现） |
| `no_subscriber` / `rejected_conflict` | 0 命中 / 订阅冲突被拒（先到先得） |
| `invalid_response` / `overflow` / `handler_error` | 非法回填 / 队列满 / 插件异常 |
| `late_response` / `duplicate_response` | 迟到 / 重复回填（respond 先到先赢，无效化） |
| `reentrant_bypass` / `loop_bypass` / `chain_bypass` | 防重入 / M3 防呆（事件循环线程内同步触发）/ 链深超限——均为立即放行 |
| `unsubscribed` / `subscriptions_cascaded` / `internal_errors` | 退订 / 级联清理 / 兜底异常 |

**插件约束（handler 内）**：

1. 请勿在 handler 内**同步**触发同实例站——框架已作防重入 bypass 消解（立即放行 +
   `reentrant_bypass` 计数），属兜底而非推荐用法；
2. 请避免同步链中的**跨实例环形等待**——M3 已加**链深上限**兜底（超限立即放行 +
   `chain_bypass` 计数；默认上限 8、可配），超时兜底仍保留；
3. 等待期与降级语义（切片 / 取消 / 超时 / fail-open 分类）参见上方「降级」与计数表。

**演示与自测**（确定性、不经 LLM）：

```bat
server\.venv\Scripts\python.exe .output\plugin_station_demo.py     :: 端到端：替换/放行/超时降级
server\.venv\Scripts\python.exe .output\plugin_station_selftest.py :: 自测 19 项（全绿）
```

**真实链路观察**（部署后）：设 `TREE_PLUGIN_ENABLED=1` 重启 → 注册示范插件 →
agent 调用 read → 工具结果应带 `[处理站示范]` 前缀。

## 宿主通道（二期 M2；契约 §14）

**定位**：插件 ↔ 宿主（本机前端执行器 / SSH 会话）的受控通道——op 命名空间
`plugin_host_*`（**只增不改**；不与 `mcp_stdio_*` / `exec_*` 混用），传输复用既有
反向 WS `tool_exec_request / tool_exec_response` 链路；策略收后端、前端薄。

**op（本批最小生命周期）**：`plugin_host_start`（幂等：同 host_key 复用）/
`plugin_host_stop`（幂等；尽力而为）/ `plugin_host_status`（running/closed +
exit_code + stderr_tail）。后端承接面 `host.py::HostChannel`；门面
`plugin.get_host_channel()`。

**上行帧**：`plugin_host_event`（本批仅 `event='exit'`；未知 event / 未知会话
静默忽略 + 计数）。

**清理契约四场景（§14.3）**：

1. stop 指令（显式调用；幂等）；
2. scope 级联 → 挂接入 `plugin_cascade` 单点（running 会话 best-effort 停止）；
3. 断连回收：WS 断连 / 执行器注销 → 会话标 `lost`（不 kill）；
4. 退出上报：上行帧命中 → 状态转 `closed` + `exit_code`/`stderr_tail`。

**重连对账（§14.3-3）**：执行器（重）注册后 `plugin_host_reconcile` best-effort
逐个 `status` 探测失联会话（closed → 回收；running → 恢复；失败保持 lost）。

**参数（env / 构造 / 时钟三通道可注入）**：`PLUGIN_HOST_OP_TIMEOUT_S`（默认 30s）、
`PLUGIN_HOST_STOP_WAIT_S`（默认 5s）。观测：`plugin.get_host_channel().stats()`
（分类计数 + in_flight/lost/closed）。

**示范插件自动注册（D-P2-6；默认关）**：

```bat
set TREE_PLUGIN_ENABLED=1
set TREE_PLUGIN_DEMO_READ_STATION=1
set TREE_PLUGIN_DEMO_SCOPE=user_id=<你的 user_id>;team_id=<可选>
:: 重启后端 → read 结果带 [处理站示范] 前缀；面板可见示范插件实例
```

- `TREE_PLUGIN_DEMO_SCOPE` 至少含 `user_id`（缺省跳过 + 告警，fail-closed）；
  粒度自动推导（session_id > agent_id > team）；键位占用等失败幂等静默。

**边界（本批）**：仅系统内置插件；`payload` 透传容忍、后端不消费、不执行任意命令；
SSH 退出上报=status 探测可知（watcher 列后续批次）。

## 状态事件与面板快照（二期 M1）

- **plugin_status**（WS，只增不改）：实例生命周期变化即发（`registered` / `destroyed`；
  `disabled` 随 M3 巡检联动），字段按契约 §8；全量低频 + 去重/限频（防风暴；去重仅约束连续同状态重复，生命周期跃迁必发）；
  交付语义＝尽力而为、最终一致（对账以快照为准）。
  参数：`PLUGIN_STATUS_DEDUP_S`（默认 1.0）、`PLUGIN_STATUS_MAX_PER_SEC`（默认 20）、
  `PLUGIN_STATUS_RATE_WINDOW_S`（默认 1.0）。
- **面板快照**（REST 只读）：`GET /api/plugin/snapshot?team_id=`（user 由 token 归属）——
  实例 / 站（含 `gauges.waits_in_flight`、`timing.wait_ms_*`）/ 看门狗 / 配置摘要；
  未启用时返回 `enabled=false` 骨架（200）。前端触点＝右栏第 5 Tab（防御式解析）。
- 测试：`tests/test_plugin_status.py` / `tests/test_plugin_snapshot.py`。

## M3 工程小件（二期 M3）

- **巡检联动（D-P2-7）**：看门狗巡检循环（默认 10s 检查；随插件体系初始化启动、
  `plugin.shutdown()` 停止）。连续 `dead_strikes`（默认 2）轮无进度 / 超
  `max_run_seconds` → 判死该 run（累计 `runs_judged_dead`，供快照
  `watchdog.judged_dead`）；同一实例**连续判死 ≥2**（`MAX_CONSECUTIVE_DEAD`）→
  停用实例（`plugin_status(disabled)` + `disabled_reason="watchdog_dead"`）。
- **停用联动（契约 §13.10）**：站请求按“实例不可用”路径 **fail-open 直通**
  （归因 `no_subscriber` + 日志 `disabled`）；订阅记录保留；重新注册同键实例 =
  恢复信号（清停用标记）。
- **F3（纯计数）**：站 handler 连续异常 ≥ `PLUGIN_STATION_ERROR_THRESHOLD`（默认 3）
  → 停用（`disabled_reason="handler_error"`）；任一次成功重置；与判死独立计数。
- **防呆（事件循环线程）**：`process()` 快速路径检测主 loop 线程（判据 A=bind 时
  记录 ident + B=running-loop 叠加）→ 立即放行 + `loop_bypass`（绝不阻塞事件循环）。
- **链深上限**：嵌套等待链深达 `PLUGIN_STATION_CHAIN_MAX`（默认 8）→ 立即放行 +
  `chain_bypass`（跨实例环防护，补 F1 同实例判定之外的面）。
- **F5 日志前缀**：站日志统一 `[plugin:station:<site>]`。
- **read encoding**：`sdk.workspace_read(path, workspace_id=None, encoding="utf-8")`；
  非法编码 fail-open 返回 `{"error": ...}`（不抛出）。
- **参数（构造参数优先、env 覆盖）**：`PLUGIN_WATCHDOG_CHECK_INTERVAL_S`（10s）、
  `PLUGIN_WATCHDOG_DEAD_STRIKES`（2）、`PLUGIN_WATCHDOG_MAX_CONSECUTIVE_DEAD`（2）、
  `PLUGIN_STATION_ERROR_THRESHOLD`（3）、`PLUGIN_STATION_CHAIN_MAX`（8）。
- 测试：`tests/test_plugin_m3_patrol.py`（9 例）+ `tests/test_plugin_m3_guard.py`
  （12 例）→ **21 passed**。

## 测试与演示

```bat
:: 插件四件套（isolation / async / core / scope_assembly）
cd server && .venv\Scripts\python.exe -m pytest tests/test_plugin_isolation.py tests/test_plugin_async.py tests/test_plugin_core.py tests/test_plugin_scope_assembly.py -q
::  → 64 passed + 1 skipped（skip = J5 活跃组上限，已知差异；含 D-13 并发注册用例、D-08 装配链路用例）

:: 宿主通道（二期 M2）模块单测（15 例：幂等/清理/mark_lost/reconcile/cascade/门面/注册入口）
cd server && .venv\Scripts\python.exe -m pytest tests/test_plugin_host_core.py -q
::  → 15 passed

:: 端到端演示（publish → 处理 → 出站；含越权拒绝演示）
server\.venv\Scripts\python.exe .output\plugin_demo.py

:: C1 验证：TTL 周期清扫实测（小 TTL 常量；日志：.output/plugin_c1_ttl_sweep.log）
server\.venv\Scripts\python.exe .output\plugin_c1_ttl_sweep_demo.py

:: 处理站（半二期）演示 + 自测
server\.venv\Scripts\python.exe .output\plugin_station_demo.py
server\.venv\Scripts\python.exe .output\plugin_station_selftest.py

:: M3 专项（巡检/判死停用/F3 + 防呆/链深/F5/read encoding）
cd server && .venv\Scripts\python.exe -m pytest tests/test_plugin_m3_patrol.py tests/test_plugin_m3_guard.py -q
::  → 21 passed

:: F-M3 补测（快照端点 fail-closed / id 主键 / F5 前缀兜底 / 回归）
cd server && .venv\Scripts\python.exe -m pytest tests/test_plugin_m3_fixes.py -q
::  → 6 passed

:: 全量回归（当前 816 passed / 1 skipped / 23 subtests；对照 M2 收口 783+1+23 净增 +33、零破坏）
cd server && .venv\Scripts\python.exe -m pytest tests/ -q
```

## 与 interface-contract v1 的对齐与差异（联调逐项评审输入）

> **评审状态**（观澜，2026-09-13）：有条件通过 → C1/C2 已补齐并经独立补验
> （知遥 `test-report.md` v2，ALL PASS）→ **通过**（v2 收口，复核记录见 `review-notes.md` §9）。

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
