# tree_self_updater

**框架自迭代插件**（`self_updater`，binary 型内置插件，由核心 spawn 的本机进程）。
它把「热重启一个插件（含重启它自己所在的插件）」做成**一个 agent tool**，
于是"改了插件代码要重启一下"这件事第一次不需要人（也不需要重启核心）：

```
模型 / 右栏 ──tools/call `plugin__self_updater__plugin_hot_restart`──▶ 本插件
                                                                    │
                                          station/command `plugin.*` ▼
                                                执行站点位 `system.execute.plugin`（核心侧）
```

**它自己不持有任何插件状态**：谁是第几世、快照在不在池里、重启成没成，全部由核心回答
（它才是唯一知道实例表的一方）。本插件做的只有三件事：把 `action` 翻译成一条 `plugin.*`
命令、把本次调用的身份原样带回、把核心的结论转成可读的工具结果。

## 职责（只做这三件事）

1. **申报工具**：同一个工具走两条申报路 —— `tools/list`（无归属时）与收集站
   `plugin.tool.define`（有 team 归属时），两条路**共用同一份参数表常量**
   （[lib/src/tool_surface.dart](lib/src/tool_surface.dart)）。
2. **转发动作**：`action ∈ list / state / restart / suspend` ⇒ `plugin.list / plugin.state /
   plugin.restart / plugin.suspend`。参数里的 `scope`（核心给的本次调用四元组）**原样**带回
   `station/command` 顶层 —— 自己编一个 `team_id` 就是越权。
3. **续跑自己这一世**：`hello` 完成后先 `plugin.stateFetch` 问一句"有没有我的快照"；
   收到 `suspend` 时**先 `plugin.stateDump`、等回包、再 ack**（顺序反了核心就只能碰运气，
   而它既不等待时长也不因沉默杀你）。

**它不做**：不把 `plugin.stateDump` / `plugin.stateFetch` 做成 `action`（D9：模型没有资格
代插件的生命周期发言）；不重启核心（不提供这条命令，也不该有）；不在 `stdout` 写日志。

## 内容

| 文件 | 内容 |
|---|---|
| [bin/tree_self_updater.dart](bin/tree_self_updater.dart) | 入口：`--selftest`（进程内假核心走一遍，输出走 stderr，退出码 0 = 全绿）；正常形态把 stdin 交给 `SelfUpdaterLoop` |
| [lib/src/self_updater_loop.dart](lib/src/self_updater_loop.dart) | 协议面与全部可计数证据（`toolCalls` / `commands` / `dumpCount` / `resumed` / `inheritedToolCalls`）；读循环**从不 await 业务**，`ping` 永远立即回 |
| [lib/src/tool_surface.dart](lib/src/tool_surface.dart) | 唯一一个 tool 的形状：`actions`（action ⇒ 命令的**唯一映射表**）、`refusedActions`（不得出现的两个）、`parameters`（`enum` 由 `actions.keys` 推导） |
| [lib/src/plugin_methods.dart](lib/src/plugin_methods.dart) | 自带的协议方法名常量 + 本插件身份（`pluginId` 必须与核心 `BuiltinPluginSpec(id: 'self_updater')` **同串**） |
| [lib/src/selftest.dart](lib/src/selftest.dart) | 九项随包自检（握手 / 两面申报 / 执行 / 拒绝原语 / 转储 / 必答 / 退出码），给装机端到端一个**可判定的退出码** |

## 不变量（assertions）

1. **一个 tool，`action` 选动作**：四个同族 tool 会把模型工具表撑出四行，而它们本来就是
   同一个动作的四种问法。`action` 的枚举**由映射表推导** —— 手写的固定表漏一项，
   表现是"模型按说明书填了合法值却被拒"，这种错只在运行时才看得见。
2. **快照两条不是能力**：`refusedActions` 与 `actions` 必须**不相交**；需要 `stateDump` /
   `stateFetch` 的时刻只有两个（`suspend` 处理里、`hello` 完成后），都由本插件自己下。
3. **转储在 ack 之前**：`suspend` 的帧序列必须是「`plugin.stateDump` 请求 → 它的回包 → ack」
   （用例数帧序，不看返回值）。反了 = 核心既不等时长（D8）也拿不到快照。
4. **身份只转述、不发明**：`station/command` 的归属参数只能来自 `tools/call` 的 `scope`；
   缺它时本插件如实说"本次调用没有可证明的归属身份"，而不是补一个看起来能过的值。
5. **零核心依赖**：只依赖 `package:tree_tunnel_protocol`（帧编解码 / RPC 常量）。方法名自带
   一张表，漂移由 [tree_protocol 的门禁](../tree_protocol/test/plugin_rpc_method_gate_test.dart)
   把本包 `lib/`、`bin/` 列入扫描面来钉 —— **不**为了共用常量而引入核心包依赖。

## 构建与随包分发

```bash
dart run tool/build_self_updater.dart      # 产出 build/plugins/tree_self_updater(.exe)
dart run bin/tree_self_updater.dart --selftest   # 开发态自检（cwd = 本包）
```

`tool/package_windows.dart` 会把产物拷进发行包的 `plugins/` 目录（缺失只打印不算失败，
与其他插件二进制同口径）；核心侧的解析顺序见
[builtin_plugins.dart](../tree_core/lib/src/plugin/builtin_plugins.dart)：可执行文件同级
`plugins/` → 仓根 `build/plugins/` → cwd 的 `plugins/` 与 `build/plugins/`
（2026-10-17：仓里的 `examples/plugins/` 已删，那两条回退跟着收掉）。

## 测试

```bash
cd packages/tree_self_updater && dart test          # 16 条（喂帧 + 进程内假核心）
cd packages/tree_core && dart test \
  test/plugin_tool_define_self_updater_test.dart \
  test/plugin_self_restart_tool_test.dart           # 真子进程 + 真执行站接线
```

协议面、点位表与"不暴露给 agent tool"的约定见
[docs/plugin-development.md](../../docs/plugin-development.md) §6.5 / §6.7。
