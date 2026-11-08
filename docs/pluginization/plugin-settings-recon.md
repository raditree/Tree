# 插件设置（tree.settings）侦察与落档（K 系列）

> **状态**：2026-11-08 侦察完成；**K1~K4 已实施，K5（契约冻结+黑盒）待开始**。
> **选型**：用户拍板 **D 方案——独立设置插件**，不把插件设置做进核心。
> **目标**：让插件把自己的设置声明给 `tree.settings`，任意 UI 插件用同一份契约渲染；
> 插件自己持有最终生效值与热应用逻辑。
> **本期出口**：K1~K4 已落地（插件 + UI 卡片）；K5 冻结契约与黑盒验收。

---

## 1. 结论先行

1. **新增 headless 插件 `tree.settings`**：只做「schema 注册 + 用户覆盖值存取 + 变更广播」，
   不理解任何插件的业务语义。
2. **核心零改动**：不新增核心路由、不聚合设置、不存值；UI 经委派端点调用
   `tree.settings` 申报的 `/api/settings/*` 路由。
3. **插件持最终值**：设置服务只存“用户覆盖值”；插件启动时读覆盖值，再按
   `设置服务 > 环境变量 > 插件 config > schema 默认` 合并（与 D28 同口径）。
4. **secret 只写不读**：schema 的 `secret` 类型永远不回显，只回 `has_value`。
5. **v1 只做 team 作用域**：设置按团队隔离；全局设置仍归现有核心设置页，不混进来。
6. **可选依赖**：需要 UI 设置的插件才 `requires: tree.settings`；没有它时插件退回
   `.docnorm/config.json` 一类自有配置，不阻塞启动。
7. **不依赖 `tree.storage`**：`tree.settings` 自己一个 Sembast 库，K 车道不被 I 车道阻塞。

---

## 2. 现状

| 事实 | 证据 | 影响 |
| --- | --- | --- |
| 设置页是**硬编码**的 7 个分类 | `plugins/tree.ui.default/lib/ui/pages/settings_page.dart:589-682` | 插件无法把自己的设置放进去 |
| 插件没有设置声明/读写协议 | `docs/plugin-development.md`（无 settings 相关 method） | D28 只是设想，未落地 |
| 核心聚合面已有 `/api/meta` | `docs/plugin-development.md` §6；`system.collect.*` | 但 settings 不应走核心存储，走独立插件更干净 |
| UI 插件是纯消费者 | `docs/plugin-development.md` §6.8 | UI 只能调委派端点，不能承接设置写入 |
| 现有模型池/插件配置各写各的 | `config/models/*.yaml`、插件的 `.docnorm/config.json` | 缺少统一 UI 与变更通知，但值仍应归插件 |
| **核心已占用 `/api/settings/*`** | `packages/tree_core` 的帧率/心跳/插件发布源端点 | 新插件路由必须用 `/api/plugin-settings/*`，否则会与核心归属表撞车 |

---

## 3. 定位与边界

**做**：

- schema 注册（类型 / 默认值 / 枚举 / 范围 / 帮助 / 分组 / secret）；
- 用户覆盖值的 `get/set/reset/list`；
- 变更广播 `settings.changed`；
- 按 `owner_plugin_id` 隔离；跨插件不可读写；
- 版本化 schema 与幂等注册。

**不做**：

- 不做业务校验（枚举/范围之外的含义归插件）；
- 不读环境变量、不读插件自己的 config（合并由插件做）；
- 不存全局设置（归核心设置页）；
- 不做 UI 渲染（UI 插件按契约通用渲染）；
- 不做插件启停/生命周期。

---

## 4. 数据模型

```text
<data_root>/settings/<team_id>/settings.semdb
  settings_schema   key = "<owner_plugin_id>|<key>"   value = {schema...}
  settings_values   key = "<owner_plugin_id>|<key>"   value = {value, updated_at}
```

- `team_id` 从核心解析的 `scope` 取，不从调用方 payload 取；取不到 ⇒ 拒绝。
- 每个插件一个 `owner_plugin_id`；调用方只能写自己的 key（核心 `meta.source_plugin_id`）。
- schema 版本：`schema_version` 单调递增；同版本重复注册幂等，低版本拒绝覆盖高版本。
- 值的类型由 schema 决定；写入前按类型/范围校验；`secret` 只存值、不回显。
- 值文件与 `config/models/*.yaml` 同一信任边界；v1 不额外加密（见 §9）。

### 4.1 schema 形状

```jsonc
{
  "owner_plugin_id": "tree.docnorm",
  "schema_version": 3,
  "groups": [
    {"id": "budget", "title": "预算", "order": 10}
  ],
  "fields": [
    {"key": "stage_budget", "group": "budget", "type": "int",
     "title": "阶段预算（token）", "default": 400000, "min": 1000, "max": 2000000,
     "help": "单阶段累计上限；超限 fail-closed"},
    {"key": "embedding_model", "group": "retrieval", "type": "string",
     "title": "检索 embedding 模型", "default": ""},
    {"key": "api_token", "group": "retrieval", "type": "secret",
     "title": "网关令牌", "default": ""}
  ]
}
```

支持的 `type`：`bool` / `int` / `double` / `string` / `enum` / `secret` / `path` / `string_list`。
`enum` 必须带 `options`；`path` 只做字符串，不做存在性校验（宿主环境可能不同）。

---

## 5. 协议

### 5.1 插件 → 设置服务（执行站命令族 `settings.*`）

`tree.settings` 注册自建执行站：

```jsonc
{"kind": "execute", "name": "settings",
 "readme": "插件设置 schema 注册与用户覆盖值存取；namespace=调用方 plugin_id。",
 "commands": ["settings.define", "settings.list", "settings.get",
              "settings.set", "settings.reset", "settings.export"]}
```

| 命令 | 作用 | 约束 |
| --- | --- | --- |
| `settings.define` | 注册/升级 schema | 幂等；低版本不覆盖高版本；调用方只能写自己的 owner |
| `settings.list` | 列出自己的 schema + 当前值 | `secret` 只回 `has_value` |
| `settings.get` | 取单个 key 的覆盖值 | 不存在 ⇒ `value:null`（插件用默认值） |
| `settings.set` | 写入覆盖值 | 按 schema 校验；`secret` 不回显 |
| `settings.reset` | 删除覆盖值（回到默认） | 幂等 |
| `settings.export` | 导出本插件 schema + 值（脱敏） | 供诊断/迁移，不导入 |

身份只认核心 `station/command` 的 `meta.source_plugin_id`；缺身份 ⇒ 拒绝。
`tree.settings` 不反向调用业务插件；变更靠广播。

### 5.2 UI → 设置服务（REST 委派）

`tree.settings` 申报：

**路径前缀必须避开核心既有 `/api/settings/*`**（帧率/心跳/插件发布源已占用），
本插件统一用 `/api/plugin-settings/*`：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/plugin-settings/schema` | 聚合所有插件 schema（可按 `plugin_id` 过滤） |
| GET | `/api/plugin-settings/values?plugin_id=...` | 当前覆盖值（secret 只回 `has_value`） |
| PATCH | `/api/plugin-settings/values` | `{plugin_id, values:{key:value}}`；逐项校验 |
| POST | `/api/plugin-settings/reset` | `{plugin_id, keys:[...]}` |
| POST | `/api/plugin-settings/apply` | 请求插件重新读取并热应用（可选） |

UI 插件只作为消费者调用；核心只做归属转发与形状校验。

### 5.3 变更广播

写入成功后发布 `system.broadcast` 的 topic `settings.changed`：

```jsonc
{"plugin_id": "tree.docnorm", "keys": ["stage_budget"], "generation": 12, "at": 0}
```

- 订阅方：业务插件（热应用）、UI（刷新表单）；
- 不携带值，避免 secret 泄露；插件收到后自己 `settings.get`；
- 广播失败不回滚写入（设置已落库），只在日志记录。

---

## 6. UI 契约

设置页新增一个「插件」分类（不替代现有全局设置）：

- 左栏按 `owner_plugin_id` 分组；右侧按 schema 的 `groups` 渲染；
- 字段类型 → 控件：`bool` 开关、`int/double` 数字框、`string` 文本框、`enum` 下拉、
  `secret` 密码框（只写；显示“已设置/未设置”）、`path` 文本 + 选择按钮、`string_list` 列表；
- 保存：只提交脏字段；逐项错误就地显示；`reset` 回默认；
- 无 schema 的插件不出现；
- 插件声明 `restart_required` 类字段时，保存后标注“需重启插件”并给「热重启」入口；
- **第三方 UI** 用同一份 `/api/settings/*` 契约；UI 能力声明 `settings.manage`（`ui.hello`）。

**回退**：没有 UI 声明 `settings.manage` 时，设置服务仍可经 REST 读写；是否提供核心托管的最小
设置页留待 K5 决定（不默认增加核心面）。

---

## 7. 切片（K 系列）

| 切片 | 范围 | 验收 |
| --- | --- | --- |
| **K1 服务骨架 + schema 注册** | `tree.settings` 插件、`settings.define/list`、自有 Sembast 单库、owner 隔离 | 两个插件各自注册互不可见；低版本不覆盖高版本；重启后 schema 在 |
| **K2 值存取 + 校验 + secret** | `get/set/reset`、类型/范围校验、`has_value`、导出 | 非法类型/越界拒绝；secret 永不回显；reset 回默认 |
| **K3 广播 + 插件热应用** | `settings.changed`、`_kit` 辅助（声明/读取/订阅） | 写入后插件收到变更并热应用；广播失败不回滚 |
| **K4 UI 通用渲染** | 设置页「插件」分类、类型→控件、脏字段保存、错误就地显示 | 任意插件只声明 schema 即出现表单；secret 只写 |
| **K5 契约冻结 + 黑盒** | schema 版本、未知类型、并发写、无 UI 回退、导出脱敏 | 契约只增不改；黑盒用真核心 + 真设置插件跑通 |

依赖：K1→K2→K3；K4 依赖 K1/K2；K5 依赖 K1~K4。

### 7.1 实施记录（2026-11-08）

| 切片 | 落地 | 验证 |
| --- | --- | --- |
| K1 | `plugins/tree.settings/`：执行站 `settings.define/list`，每团队 `<data_root>/settings/<team_id>/settings.semdb`，owner 只认 `meta.source_plugin_id` | 插件自检 29/29；engine 测试 8/8 |
| K2 | `settings.get/set/reset/export`；类型/枚举/范围校验；secret 只回 `has_value`；同版本 schema 幂等、异内容/降级拒绝 | 同上；越界/类型/未知 key 均拒 |
| K3 | 广播站 `plugin.tree.settings.broadcast.settings_changed`；写入后发 `settings.changed {plugin_id, keys, generation}`，不带值 | 自检断言广播带 plugin_id、不带 value |
| K4 | UI 设置页「插件」分类新增「插件设置」卡片（`plugin_settings_card.dart`）；按 schema 通用渲染、secret 只写、只提交脏字段、恢复默认 | `plugin_settings_card_test` 通过；`settings_nav_test` 通过；全量 UI 925 通过（唯一失败是既有版本常量 1.0.5 vs pubspec 1.0.6 漂移，与本切片无关） |
| K5 | 契约冻结（单元/自检层）：schema 版本策略、未知类型拒绝、20 并发写 generation 单调、export 脱敏、secret 默认值禁止非空、无 UI 时 REST 可读写；**真核心黑盒随主线 DN-2 联调** | engine 8/8；插件自检 29/29；REST 读写/secret 脱敏均在自检内 |

实现口径补充：

- REST 前缀最终用 **`/api/plugin-settings/*`**（核心已有 `/api/settings/*`，不能撞）；
- UI 首屏一次取 schema，再逐插件取 values（插件数量少，暂不做聚合端点）；
- `plugins/` 与 `tree.ui.default` 是独立仓库/挂载，K 的实现提交在**插件仓**，桌面仓只记录文档与状态。

---

## 8. 验收判据

| 编号 | 判据 |
| --- | --- |
| TC-SET-01 | 插件只能读写自己的 `owner_plugin_id`；越权写被拒 |
| TC-SET-02 | 同版本 schema 重复注册幂等；低版本不能覆盖高版本 |
| TC-SET-03 | int 越界 / enum 非法 / 类型不符 ⇒ 拒绝，且不落库 |
| TC-SET-04 | secret 写入后 `list/get` 只回 `has_value:true`，任何接口不回原文 |
| TC-SET-05 | `reset` 后插件下一次读取拿到默认值 |
| TC-SET-06 | 写入成功广播 `settings.changed`；订阅插件能热应用，无需重启 |
| TC-SET-07 | 广播失败时值仍已落库，错误只进日志 |
| TC-SET-08 | 两个 team 的实例互不可见；缺 team_id 拒绝 |
| TC-SET-09 | 无 UI 能力时 REST 仍可读写；UI 不崩 |
| TC-SET-10 | 未知字段类型：schema 注册被拒并给可读原因（不猜） |

---

## 9. 风险与待拍板

| 项 | 推荐 | 说明 |
| --- | --- | --- |
| secret 存储 | v1 与 `config/models/*.yaml` 同信任边界，不额外加密 | 若要加密，需定义密钥来源与轮换，单开安全切片 |
| 全局设置 | v1 只做 team 作用域 | 全局仍归核心设置页；跨团队共享值后续再加 |
| 插件依赖 | **可选**（需要 UI 设置的插件才依赖） | 缺失时插件退回自有 config（docnorm 的 `.docnorm/config.json`） |
| 无 UI 回退 | v1 只保证 REST；最小页面留 K5 | 不默认增加核心面 |
| 值存储 | 自有 Sembast 单库 | 不依赖 `tree.storage`，K 不被 I 阻塞 |
| 设置服务缺失 | 插件 fail-open 到 env/config | 设置不是业务数据，不能因服务缺失阻断启动 |
| 热应用 | 默认热应用；插件可声明需重启 | UI 标「需重启」并给热重启入口 |

---

## 10. 与既有口径的关系

- 取代 [doc-normalization-recon.md](../doc-normalization-recon.md) D28 里“核心设置页动态渲染”的设想：
  改为 `tree.settings` 独立插件 + UI 通用渲染；
- 插件设置的优先级仍是 `设置服务 > 环境变量 > 插件 config > 内置默认`；
- K 车道不阻塞 I/J；docnorm 在 K 落地前用 `.docnorm/config.json` + 环境变量；
- 核心面 35 条不变；`/api/plugin-settings/*` 由 `tree.settings` 经
  `system.collect.api.routes` 申报（避开核心已有的 `/api/settings/*`）。

---

## 11. 证据索引

- 设置页现状：`plugins/tree.ui.default/lib/ui/pages/settings_page.dart:589-682`
- 模型池写入者：`plugins/tree.agent/lib/src/settings/domain_settings.dart:287-322`
- UI 插件纯消费者：`docs/plugin-development.md` §6.8
- 执行站注册与命令路由：`docs/plugin-development.md` §3.3、§6；
  `plugins/local_executor/local_executor_plugin.dart:47-66`
- 身份透传：`packages/tree_core/lib/src/plugin/plugin_bus.dart:2711-2714`
- D28 原设想：[doc-normalization-recon.md](../doc-normalization-recon.md) D28
- 车道记录：[project-status.md](../project-status.md) 车道 K
