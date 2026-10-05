# plugin（插件宿主与站点体系）

进程外插件（stdio JSON-RPC）的宿主，以及插件与核心之间**唯一**的交互面：站点。
四类站点、若干点位，外加执行站挂载、插件工具定义与 UI 槽位桥。

## 宿主与配置

| 文件 | 作用 |
| --- | --- |
| [plugin_host.dart](plugin_host.dart) | 进程外插件宿主：行分隔 JSON-RPC 2.0，入站报文分三类（响应 / 请求 / 通知） |
| [plugin_bus.dart](plugin_bus.dart) | 总线：配置、实例生命周期、事件分发、工具聚合、站点体系、心跳判活 |
| [plugin_config_store.dart](plugin_config_store.dart) | `plugins.yaml` 读写层：直接在原始 Map 上"读 → 改 → 原子写"（保留未知键） |
| [builtin_plugins.dart](builtin_plugins.dart) | 内置插件静态清单 + 运行时 / 脚本解析 |
| [plugin_guide.dart](plugin_guide.dart) | 插件开发指南在工作空间内的落点（`.self/docs/plugin-development.md`）与播种 |

## 站点

| 文件 | 作用 |
| --- | --- |
| [station_ids.dart](station_ids.dart) | 内置点位 id **常量**（只放常量，谁都要引、不能有依赖） |
| [station_points.dart](station_points.dart) | **点位表**：类型 / 中文名 / 说明 / 命令 / 订阅别名——点位的唯一定义处 |
| [station_schema.dart](station_schema.dart) | 站点类型枚举与收集站 schema |
| [station_scope.dart](station_scope.dart) | 隔离四元组与调用点上下文 |
| [station_instance.dart](station_instance.dart) | 四类站实例与各自的触发方法 |
| [station_runtime.dart](station_runtime.dart) | 一次触发的输入输出（订阅者 / 请求 / 回包 / 活性 / 分类计数） |
| [station_store.dart](station_store.dart) | 站点实例落盘 `config/stations.yaml`（跨重启保留） |
| [stations.dart](stations.dart) | 站点中枢：内置点位、插件自建站、订阅、下线注销、快照 |

## 接入点

| 文件 | 作用 |
| --- | --- |
| [execute_mounts.dart](execute_mounts.dart) | **系统内置挂载位置**：把执行站各命令族接到核心既有实现，并做四元组隔离 |
| [plugin_tool_definition.dart](plugin_tool_definition.dart) | 收集站首个接入点：插件定义 tool → 动态工具表 |
| [plugin_ui_bridge.dart](plugin_ui_bridge.dart) | 插件通知 → 前端 UI 帧（槽位）+ 当前态缓存（供后连的前端重放） |
| [agent_events.dart](agent_events.dart) | agent 事件发布器（工具调用开始 / 结束等） |

## 不变量（assertions）

1. **站点只有四种类型**（广播 / 执行 / 中转 / 收集），插件**不得发明新类型**；每类下若干**点位**，**每个点位是一个独立的全局实例**（各自唯一订阅者、各自计数、各自挂载位置、面板各自一行）。
2. **站点 id 不含 team / mode**：team / agent / session / mode 是**每次交互携带的信封**（消息 scope）与订阅声明，只在投递时用于匹配订阅者。按 team 复制站点会让站点数随团队数膨胀（一堆没人用的空壳），全局化后跨 team 数据整合天然可行，而隔离仍在投递判定处 fail-closed。
3. **点位表是唯一定义处**：加一个点位只该改 [station_points.dart](station_points.dart)（外加 `StationHubIds` 一个常量，且**必须加进 `all`**——否则会被当成别人的自建站、被归属校验收掉），不该去动订阅 / 路由 / 预建 / 面板四段逻辑。点位是**数据**不是行为。
4. **隔离 fail-closed**：按四元组（team / agent / session / mode）解析目标，任何归属**证明不了**就拒绝并给可读原因。执行站每条命令的第一件事就是校验：`agent_id` 与站点 scope 不一致拒、team 不一致拒、目标 agent 的**工作空间模式**（local | ssh）不一致拒（否则 SSH 团队的命令会打到本地工作空间）。
5. **中转站 fail-open 红线**：无订阅者 / 订阅者心跳丢失 / 回包非法 / 处理异常，一律**放行原数据**并给出可读原因，绝不抛出、绝不出半成品。压缩中转点的这份原因还**经 `PluginBus.compactionSkipSink` 上报**（带 `hasSubscriber` 分级位：早退 vs 有订阅者却没接管），接线方接到 `CompactionService.noteRelaySkip` ⇒ 原因能进 REST 响应与会话通知——否则"我装了压缩插件为什么没生效"只能去翻 stderr。
   **回包可选键 `reason`（2026-10-05 新增，纯增量）**：插件回 `payload: null`（= 不接管）时可以顺手说明
   **为什么**（`StationReply.reason` → `StationRelayResult.reason`）——原因于是从"只活在插件自己的内存面板"
   升级成**核心日志 + `relay_skip_reason` + 会话提示**；不带该键的老插件行为**逐字不变**。
   同理，**命令类失败若带着产出**（`llm.call` 解析不出 JSON 时的模型正文）要用
   `StationCommandOutcome.failedWith(error, payload)` 回，别只回一句 `error`——那等于把插件已付费的
   那次调用彻底丢掉（现场是 734k prompt 的总结，见 [../llm/README.md](../llm/README.md) 不变量 14）。
   **而且这份 `payload` 必须"穿到底"**：`StationInstance.execute()` 的 `ok:false` 分支也要把
   `outcome.payload` 放进 `StationCommandResult`（**曾经就漏在这一跳**：核心明明把原文放进了回包，
   插件收到的 `payload` 却是 null、报"原文 0 字"当场弃权，那笔 448k prompt 的总结又整包白扔；
   见 [../../../../../docs/known-issues.md](../../../../../docs/known-issues.md) #31「真机复现」）。
   判据：**"写进了回包" ≠ "走到了插件"**——执行站 → 插件总线 → 插件进程每一跳都要有用例钉住
   （`test/plugin_execute_new_commands_test.dart` 钉这一跳，`test/compact_plugin_e2e_test.dart` 钉真进程那一跳）。
6. 中转站是 `scopeKeyUnique` **先到先得**：同键位第二人被拒（显式 `replace` 才替换并回报被替换者）——一个接入点只能有一个处理者。这也是点位各自成实例的原因：否则"接管 LLM"的插件会顺带垄断"系统提示词构造""上下文压缩"。
7. **收集站**：schema **必填**（订阅者必须按它产出，校验失败按可读错误回报该订阅者）；**不回填**原数据流（返回值即结果，后续处理由触发方负责）；某订阅者未响应（心跳丢失 / 窗口内无回 / 校验失败 / 回包报错）⇒ 返回**已收集部分 + 显式列出未响应者**，不静默、不阻塞、不整体失败。
8. **无静态总时间上限**（M9 §1.1）：看门狗每拍 `ping`，连续 N 拍没有心跳 ⇒ 只标记 `health: degraded` 并让前端可见，**不自动终止插件**（长任务跑多久都不因时间被杀）；心跳恢复自动清除；用户可显式 `restart`。唯一保留的短窗口是**建连握手**——没有它就诊断不出"插件根本没起来"。**站请求 / `tools/call` 同样没有静态超时**（`plugin_host.requestStation` 明写这条）；未响应只记"未响应者清单"。**软窗口之后只允许显式收手**（用户 `restart` / 关闭那一次运行）——全仓同一条口径见 [../llm/README.md](../llm/README.md) 不变量 2。
9. **插件与 agent 同权**：本仓库**没有工具审批层**，`tool.call` 走工具层唯一入口，与模型调用工具是同一条路径、同一份权限。这是设计事实，文档如实写出来，而不是假装有沙箱。
10. **写回配置必须保留未知键**：直接在原始 Map 上改 + 原子写，不经 `PluginConfig.fromJson` 中转（它会丢未知键，改一个开关会把文件改瘦成核心认识的形状）。id 白名单 `[A-Za-z0-9_.-]`（防止 id 被当成路径分段用）；校验失败一律返回**可读中文原因**，不抛异常。
11. **插件 UI 安全边界（fail-closed）**：`plugin_id` 一律取**实例 id**，不采信通知里的自述（否则 A 插件能注销 / 覆盖 B 的槽位）；`team_id` 以配置声明为准，冲突以声明为准并记日志；槽位条数 / `slot_key` / 视图大小都有上限，超限**整帧拒绝**。不做 webview / iframe、不执行插件 JS——视图只能是受限控件集的 JSON，未知控件由前端渲染成占位。
12. **UI 帧缓存只存"桥已放行"的帧**：插件槽位声明是一次性的，而广播是"当下有谁在听就发给谁"——前端刷新 / 重连、插件比前端先就绪、断线期间插件重启，都会让面板**永久消失**直到插件进程重启。缓存按帧类型存最后一个生效帧，新连接注册时重放（前端对同内容重放幂等）。越权 / 非法声明连缓存都进不去，重放**不是**绕过校验的旁路。
13. **agent 事件发布失败绝不冒泡**：发布发生在生成循环里（工具调用处），订阅方抛异常只回报 `onError`、事件丢弃——插件侧的任何问题都不该让生成失败。默认未接线 = **纯 no-op**。
14. 内置插件的"身份"由**核心**认定（前端只拿到 id / 名称 / 说明 / 开关状态）；解析不出运行时必须给可读错误（「未检测到 Python，请先安装或改用自定义命令」）——静默失败在界面上表现为"点了开关没反应"。
15. 执行站挂载位置的依赖**没接线时不做静默降级**：以「未接线」的可读原因失败。
16. 代理归属校验与订阅可见性**两处都按 team fail-closed**；插件要订阅站点就必须声明 `scope.team_id`，因此事件与命令的 `team_id` 一律取 agent 的**有效团队归属**（顶层 agent 自成一队，取它自己的 id），不能只读 `agent.teamId`（那会让顶层 agent 的事件永远带空 team，声明了 team 的插件反而收不到自己的事件，计数静默归零）。

## 测试

```bash
cd packages/tree_core
dart test test/plugin_test.dart test/plugin_request_test.dart test/plugin_station_test.dart \
          test/plugin_station_wiring_test.dart test/plugin_station_builtin_test.dart \
          test/station_points_test.dart test/plugin_self_station_e2e_test.dart \
          test/plugin_execute_mounts_test.dart test/execute_mounts_scope_test.dart \
          test/plugin_execute_new_commands_test.dart test/plugin_tool_define_test.dart \
          test/plugin_tool_table_test.dart test/plugin_ui_bridge_test.dart test/plugin_ui_manifest_test.dart \
          test/plugin_ui_replay_test.dart test/plugin_config_store_test.dart test/plugin_hot_apply_test.dart \
          test/builtin_plugin_script_roots_test.dart test/plugin_llm_relay_test.dart \
          test/compact_plugin_e2e_test.dart test/sample_plugin_layout_e2e_test.dart
```

点位清单与四类站的语义另见 [docs/plugin-development.md](../../../../../docs/plugin-development.md)。
