# L-23 `scope` 去领域化 · 侦查报告

> 状态：**侦查完成，本期不实现**（用户 2026-11-01 定：本期完成完整侦查，下期按本报告执行）。
> 目的：让下期可以照 §5 的执行序无脑推，不需要重新勘查。
> 核对方式：源码 grep + 配置清点；**未改任何代码**。

## 0. 一句话结论

wire 上的四元组 `(team_id, agent_id, session_id, mode_key)` **几乎无人消费**——
12 个插件的 `plugin.json` 的 `scope` 全是 `{}`，四个领域插件源码里对
`team_id` / `mode_key` **零读取**。真正的绑定全在核心内部（4 类判定点）。
建议按 **C1 → C2 两步走**：先把协议上的领域字段摘掉（一个版本），再让归属靠
租约 + agent 归属链解析；`agent_id` / `session_id` 保留（事件可见性需要）。

## 1. 问题定义

「领域化」指**协议层知道业务概念**：

- `mode_key ∈ {local, ssh}` 是执行器领域概念（工作空间模式）；
- `team_id` 是团队领域概念。

两者被写进站点消息信封与订阅声明，于是每个执行站命令、每条广播都拖着两个
领域字段，插件与外部实现被迫理解它们。定义在
`packages/tree_core/lib/src/plugin/station_scope.dart:1-29`（文件头即写明
"站点隔离四元组（M9 §1.2 硬要求）"）。

站点实例已在 M9 Wave 3 全局化（每类站一个实例，不绑 team / mode），所以
scope 只剩两处（`:17-20`）：**消息信封**与**订阅声明**。

## 2. 现状事实（逐条已核实）

### 2.1 wire 面

- `StationScope.parse`（`station_scope.dart:107-122`）与 `toJson`（`:125-130`）
  四个键全写全读。
- 携带点：`station/command`（`station_instance.dart:1005` 起）、`station/stream`、
  `station/trigger`、`station/subscribe`、中转站回填与广播（`plugin_bus.dart:2158`）。

### 2.2 唯一来源与构造点

- `StationScopeContext`（`station_scope.dart:156-199`）是 team/agent/session 的
  运行期唯一来源；`modeKey` 通常留空，由 `PluginBus.agentModeKeyResolver`
  （`plugin_bus.dart:272`）按目标 agent 的工作空间解析。
- 构造点：`plugin_bus.dart:1673`、`:3378`、`:3684`、`:3717`、`:5292-5294`、`:5593`。

### 2.3 声明合并与既有接管钩子（关键）

`_scopeOf`（`plugin_bus.dart:5591-5620`）把 `plugin.json` 的 `scope` 声明与
运行时解析合并。**它已经支持整体接管**：

```dart
final RuntimeStationScopeResolver? resolver = stationScopeResolver;
if (resolver != null) return resolver(config, context);   // :5595-5596
```

→ 去领域化的改造可以从这个钩子切入，不必先动所有 `_scopeOf` 调用点。

### 2.4 判定点（共 4 类，改这里才算改到根）

| 判定 | 位置 | 当前规则 |
| --- | --- | --- |
| 消息自校验 | `station_scope.dart:224-236` | `team_id` 必非空 + `mode_key` 合法 |
| 命令 scope | `station_scope.dart:248-255` | 只校验 `mode_key` 合法（team 可空 = 通配） |
| 投递判定 | `station_scope.dart:262-289` | team / mode 精确相等；agent / session 只许更细 |
| 团队+模式相容 | `station_scope.dart:311-344` | 订阅侧空 = 通配；消息侧空 = 拒绝 |

调用方：`station_instance.dart:761`、`:1142`、`:1325`；`plugin_bus.dart:2158`
（广播可见性）、`:804` / `:818`（工具表可见性 `_visible`）；
`execute_mounts.dart:205`、`:244-253`（执行站目标解析：`team_id` must 非空、
agent 可解析、scope 与目标 agent 真实归属精确相等，缺一即拒）。

### 2.5 插件面（破坏面比预想小）

- 12 个 `plugin.json` 的 `scope` **全部是 `{}`**：
  `tree.agent` / `local_executor` / `ssh_executor` / `files` / `mcp` /
  `extra-tools` / `compact` / `sample` / `minimal` / `suspendable` /
  `self_updater` / `terminal_probe`。
- `plugins/{tree.agent,local_executor,ssh_executor,files}/lib` 内
  `team_id|mode_key|scope[...]` **零命中**：插件只把收到的 `scope` map 原样透传
  给 `station/command`，不读也不判。
- ⇒ S3/S4 阶段的插件改动只有：删 `plugin.json` 的 `scope` 字段 + 删加载校验。

### 2.6 UI 面

- 插件配置编辑器：`lib/ui/widgets/plugin_editor_dialog.dart:98-164`（team / agent /
  session / mode 四个输入）、`:407`（表单字段声明）。
- 展示：`lib/ui/widgets/plugin_detail_page.dart:205-208`、
  `lib/ui/widgets/plugin_panel.dart:2142-2145`。
- 事件监控：`lib/io/plugin_monitor_service.dart:230`（分组键拼 `team_id`）、
  `:830`（按事件 `team_id` 过滤）。
- **不要混淆**：`lib/io/api_service.dart:192-1753` 的 `team_id` 是 REST 查询参数
  （agent / 文件 API），与站点 scope 无关，本项不动它。

### 2.7 测试面

覆盖投递与执行站的现有用例约 10 个文件：
`ui_station_ws_test.dart`、`plugin_station_test.dart`、`plugin_station_query_test.dart`、
`plugin_station_arguments_test.dart`、`plugin_tool_call_station_test.dart`、
`plugin_mount_station_test.dart`、`plugin_state_pool_scope_test.dart`、
`station_tunnel_link_test.dart`、`station_tunnel_pty_test.dart`、
`plugin_self_station_e2e_test.dart`。
**没有**独立的 `station_scope_test.dart`——规则断言散在 `plugin_station_test.dart` 里。

## 3. 破坏面分级

| 级别 | 面 | 文件数 |
| --- | --- | --- |
| P0 协议 | `StationScope.parse/toJson` + 5 类消息/订阅参数 | 2~3 |
| P0 核心判定 | 4 类判定点 + 执行站目标解析 + 工具可见性 | 3（`station_scope.dart` / `plugin_bus.dart` / `execute_mounts.dart`） |
| P1 UI | 编辑器表单 + 两处展示 + 监控分组/过滤 | 4 |
| P2 插件 | 12 个 `plugin.json` 的空 `scope` + 加载校验 | 12（机械） |
| P3 外部 | 第三方插件自建 scope（未知） | 需公告 + 一个版本容忍 |

## 4. 候选方案

- **C1 内核化（快）**：wire 删 `scope`，核心内部继续用四元组。一个版本能摘掉
  协议脏字段，插件零改动（本来就不读）。
- **C2 租约化（彻底）**：归属由执行站租约 + agent 归属链证明，scope 只留
  `agent_id` / `session_id`。执行站契约片 1~5 已完成（租约归执行器插件），前提已具备。
- **C3 维持**：不做。

**推荐 C1 → C2 分两阶段**：C1 先让协议干净，C2 再把团队/模式判定下沉到归属解析。

## 5. 执行序（下期照此推，每步一个提交、可独立回滚）

> 全程要求：wire 解析器对未知键**容忍一个版本**（`StationScope.parse` 忽略多余键）。

**S0 冻结**：本报告进 `docs/README.md` 索引；契约补一句"scope 领域字段下沉计划"。

**S1 `mode_key` 下沉（核心 + UI）**
1. 判定：`checkMessageScope` / `checkCommandScope` / `checkSubscriber` 移除 mode 比对。
2. 归属：`execute_mounts._resolveTarget` 改用 `agentModeKeyResolver` 解析（已存在）。
3. 声明：`_scopeOf` 不再注入 mode；`plugin.json` 的 `scope.mode_key` 读取后丢弃。
4. UI：`plugin_editor_dialog.dart` 隐藏 mode 下拉；`plugin_monitor_service.dart:230`
   分组键去掉 mode。
5. 门禁：新增「订阅不写 mode 也能收到 SSH 消息」「本地 agent 不会收到 SSH 消息」。

**S2 `team_id` 下沉（核心）**
1. 消息侧 team 由 `agentId → team` 解析（agent 存储已有归属）；`station/command`
   不再要求 team 非空。
2. `execute_mounts` 的 team 校验改为"解析 agent 的真实 team 后比对"。
3. 团队级命令（`station.list`）改用显式 `global: true`，替代"空 team = 通配"。

**S3 类型收敛（tree_protocol + core + UI）**
1. `StationScope` 缩成 `SessionScope(agentId, sessionId)`；删 `parse/toJson` 的
   team/mode 键；`specificity`（`:95-99`）由 4 维降 2 维，同步 `station_tunnel_link`
   的"最细粒度优先"。
2. UI 三处表单字段删除；监控分组键改 `agent|session`。

**S4 收尾（插件仓 + 门禁）**
1. 删 12 个 `plugin.json` 的 `scope` 字段与加载校验（`_scopeOf` 走 resolver 分支）。
2. 门禁：扫 `packages/tree_core/lib/src/plugin/` 与 `plugins/`，`station/command`
   参数表里不得再出现 `scope.mode_key` / `scope.team_id` 字面量。
3. `plugin-development.md` §scope（两套含义）与契约 §4.1 改写，README 同步。

## 6. 风险与未决问题

- **R1 事件可见性**：前端按 event 的 `team_id` 过滤（`plugin_monitor_service.dart:830`）。
  team 删掉后改为"UI 侧用 agent → team 关系解析"（UI 已有该数据）。
- **R2 中转站优先级**：`specificity` 4 维 → 2 维，必须先跑
  `station_tunnel_link_test` 与 `station_tunnel_pty_test`。
- **R3 团队级命令语义**：`station.list` 这类"空 team 通配"要显式 `global`，
  否则会被误判成越权。
- **Q-S1** wire 上是否保留 `team_id` 作"观测字段"（只写不判）？建议**不保留**，
  观测走日志。
- **Q-S2** `station/subscribe` 是否改成 `agent_ids: [...]` 多值订阅？建议 S3 一并做。
- **Q-S3** 外部第三方插件是否已用 `scope` 声明？S4 前发一次公告，并保留一个版本的
  未知键容忍。

## 7. 验收判据（下期照此打勾）

1. `dart analyze` 干净；`packages/tree_core` 全量 `dart test` 绿；插件仓四个领域插件
   测试绿。
2. 新增用例：「SSH agent 的命令不得落到本地工作空间」（mode 删除后仍成立）、
   「跨团队事件不投递」、「团队级命令在白名单内可空 team」。
3. 真机 30 分钟：本地团队 + SSH 团队并行，事件与执行站命令均无串台。
4. `exec_station_contract.md` §4.1 的信封不再提四元组；`plugin-development.md`
   §scope 两套含义改写为"已删除，见本报告"。
5. 门禁：`packages/tree_core/lib/src/plugin/station_scope.dart` 内不再有
   `team_id` / `mode_key` 的 wire 序列化键（解析容错除外）。
