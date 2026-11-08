# tree.storage 插件侦察与落档（ST 系列）

> **状态**：2026-11-08 侦察完成，**本期只落档，不实施**。
> **定位**：给 TREE 内的 headless 插件提供统一集合存储（Sembast、纯 Dart、零原生依赖）。
> **前置拍板**：存储独立成插件（[doc-normalization-recon.md](../doc-normalization-recon.md) D27）；本文把它单开为车道 I。
> **本期出口**：协议、数据布局、切片与验收冻结；不改代码。

---

## 1. 结论先行

1. **`tree.storage` 是 headless 插件**，对其它插件只暴露执行站命令族 `storage.*`；
   其他插件**不 import** 它的源码，也不直接读它的数据库文件。
2. **默认一个插件一个库**：`<data_root>/storage/<plugin_id>/data.semdb`。
   不把所有插件塞进同一个库——一个插件的大扫描不应拖垮别人，单个库损坏也不该全盘失效。
3. **命名空间 = 调用方 plugin_id**：跨插件访问必须显式白名单，默认拒绝。
4. **DB 是运行时真源**；`storage.export` 只产出评审/迁移用的 NDJSON 快照，不反向作为真源。
5. **事务只有两种**：单条命令内部的原子写，或一次 `storage.tx` 的批量 ops + CAS（`rev`）；
   不提供跨命令长事务。
6. **失败策略**：依赖方 fail-closed。`tree.docnorm` 在 `baseline` / `graph.build` 前拿不到存储
   就拒绝执行，不降级成“内存里算一遍”。

---

## 2. 现状与缺口

| 事实 | 证据 | 影响 |
| --- | --- | --- |
| Sembast 已在用，但只在 `tree.agent` 内部 | `plugins/tree.agent/pubspec.yaml:16-18`、`lib/src/store/conversation_db.dart:10-24` | 证明纯 Dart 路线可行；但没有跨插件存储 |
| 会话库按 agent 分库、单写者 | `conversation_db.dart:22-24` | 同一套崩溃模型可复用；不能直接搬给多插件 |
| 插件之间只有站点总线（stdio RPC / 执行站命令） | `docs/plugin-development.md` §3.1、§6；`plugins/local_executor/local_executor_plugin.dart:47-66` | 存储只能走执行站，不能靠共享内存/共享包 |
| 各插件自造文件格式 | `tree.agent` 的 yaml/jsonl/semdb；docnorm 计划的 `export/*.jsonl` | 没有统一的集合语义、分页、CAS 与导出格式 |
| 没有 `tree.storage` 插件 | `plugins/` 目录无该条目 | 本期要新建；是 DN-4 起的外部前置 |

---

## 3. 定位与边界

**做**：

- 集合（collection）级的 `put/get/delete/query/scan/count`；
- 单命令原子批量写（`tx`）+ 乐观并发（`rev` / `if_rev`）；
- 分页游标、前缀/范围查询、排序；
- NDJSON 导出与导入、manifest（schema / 条数 / sha256）；
- 每个库的 `schema_version` 与 compact；
- 调用方隔离（namespace）与跨插件白名单。

**不做**：

- 不做 SQL / join / 聚合查询语言；
- 不做业务语义（建议、任务、图谱都归各自插件）；
- 不做跨插件“随便查别人的库”；
- 不新增核心 REST 面，不把存储写进核心。

---

## 4. 数据布局与生命周期

```text
<data_root>/storage/<team_id>/<plugin_id>/data.semdb   # 运行时真源（每团队 × 每插件一个库）
<data_root>/storage/<team_id>/<plugin_id>/export/      # 导出快照（可删，可重建）
  <collection>.ndjson
  manifest.json                                         # schema / count / sha256 / exported_at
```

**实例粒度**：`plugin.json` 用 `granularity: team`（与 `tree.agent` / 执行器同口径）。
平台会为每个 team 起一个实例，**路径必须带 team_id**，否则多团队实例会打开同一个库文件。
`team_id` 只从核心解析的 `scope` 取，不从调用方 payload 取；取不到 ⇒ 拒绝（fail-closed）。

- 目录与文件名走 `safeSegment` 同口径（只允许 `[A-Za-z0-9_.-]`）。
- 插件启动时打开自己的库；停止/热重启前 `close()`；崩溃后由 Sembast 自身追加日志恢复。
- **卸载保留数据**：卸载插件不删 `storage/<team_id>/<plugin_id>/`；只有显式 `storage.purge`
  （二次确认）才删除。理由：会话/建议/图谱属于用户资产，误删不可逆。
- **导出物不自动入库**：`export/` 是过程产物，默认进 `.gitignore`；需要评审时由人显式提交。

---

## 5. 协议：执行站 `storage.*`

注册（插件启动时，模式与 `local_executor` 相同）：

```jsonc
{"kind": "execute", "name": "storage",
 "readme": "插件集合存储：put/get/delete/query/scan/tx/export；namespace 默认=调用方 plugin_id。",
 "commands": ["storage.ensure", "storage.put", "storage.get", "storage.delete",
              "storage.query", "storage.scan", "storage.count", "storage.tx",
              "storage.export", "storage.import", "storage.stats", "storage.compact",
              "storage.purge"]}
```

> 命令按名字路由（`station/command` 不带 `station_id`），所以命令族必须是唯一前缀；
> `storage.` 由本插件独占，其它插件不得申报同名命令。
> **执行站不接受 `shared` / `allowed_plugins`**（核心只对可订阅站点生效）；本插件的
> 调用方白名单放在自己的配置文件里，在入口按 `meta.source_plugin_id` 自查。
> 身份与数据根由核心透传：`plugin_bus.dart:2711-2714` 在 `meta` 里带
> `{source_plugin_id, data_dir}`；本插件直接用 `data_dir` 拼路径，**不从调用方参数推导**。

### 5.1 通用信封

```jsonc
// 请求 payload
{
  "namespace": "tree.docnorm",     // 可省；省 = 调用方 plugin_id；跨命名空间必须被 allowlist
  "collection": "suggestions",
  "op": "put",                     // 与命令同名，便于 tx 内复用
  "key": "sug-01",
  "value": {"...": "..."},
  "if_rev": 3,                     // 可选：CAS
  "query": {...}, "limit": 100, "cursor": "...",
  "ops": [ ... ]                   // 仅 storage.tx
}

// 回包
{"ok": true, "rev": 4, "value": {...}, "values": [...], "count": 0,
 "cursor": "...", "error": "", "error_reason": ""}
```

### 5.2 命令表

| 命令 | 作用 | 关键约束 |
| --- | --- | --- |
| `storage.ensure` | 建集合 + 声明 `schema_version` | 已存在且版本更高 ⇒ 拒绝（不隐式降级） |
| `storage.put` | 写一条（有 `if_rev` 则 CAS） | value 必须是 JSON object；返回新 `rev` |
| `storage.get` | 按 key 取 | 不存在 ⇒ `ok:true, value:null` |
| `storage.delete` | 按 key 删 | 不存在 ⇒ `ok:true, deleted:false` |
| `storage.query` | 条件 + 排序 + 分页 | `limit` 上限 500；cursor 不透明 |
| `storage.scan` | 顺序扫（可按 key 前缀） | 只给导出/维护；业务读走 query |
| `storage.count` | 计数 | 与 query 同过滤条件 |
| `storage.tx` | 批量 ops 原子执行 | 任一失败整批回滚；最多 200 ops，**单次 tx 总字节 ≤ 8 MiB**（单条 value ≤ 1 MiB），超限直接拒绝 |
| `storage.export` | 导出 NDJSON + manifest | 原子写；不阻塞普通读写超过阈值即分片 |
| `storage.import` | 导入 NDJSON | 目标集合必须为空或 `replace:true`；校验 sha256 |
| `storage.stats` | 条目数 / 文件大小 / 版本 | 只读 |
| `storage.compact` | 压缩库文件 | 维护窗口执行；失败不影响读 |
| `storage.purge` | 删除本插件库 | 必须二次确认；只允许删自己的 namespace |

### 5.3 访问控制

- 调用方身份只认核心 `meta.source_plugin_id` / `triggered_by`，**不认 payload 里自报的 plugin_id**；
- 执行站命令的身份由核心在 `station/command` 的 `meta` 透传；本插件在入口按**自身配置的
  允许列表**自查（当前只允许 `tree.docnorm`）。**核心未带身份 ⇒ 拒绝**（fail-closed，不猜调用方）；
- `namespace` 缺省 = 调用方 plugin_id；填别人 namespace 且不在允许列表 ⇒ 403；
- 核心/UI 不直接持有 `storage.*` 命令；UI 仍走 REST 委派到业务插件；
- 审计：每条写命令记 `{caller, namespace, collection, op, key, bytes, at}` 到插件日志。

---

## 6. 一致性与并发

| 场景 | 规则 |
| --- | --- |
| 同进程并发 | 所有命令经单事件循环 + 数据库事务串行化 |
| 跨插件并发 | 各库独立；互不影响 |
| 读己之写 | 同一命令内保证；跨命令只保证“已提交可见” |
| 冲突 | 用 `rev` + `if_rev` 做 CAS；调用方自行重试（≤3 次） |
| 崩溃 | Sembast 追加日志 + 检查点；最多丢最后一条未提交写 |
| 迁移 | 每个集合带 `schema_version`；迁移由**所有者插件**在 `storage.ensure` 前执行 |
| 备份 | 大版本迁移前先 `export`；失败用导出物回滚，不直接改库文件 |

---

## 7. 切片（ST 系列）

| 切片 | 范围 | 验收 |
| --- | --- | --- |
| **ST-1 骨架 + 单库 CRUD** | 插件骨架、执行站注册、`ensure/put/get/delete/query`、safeSegment | 单测覆盖建库/读写/删除/非法 key；自检退 0 |
| **ST-2 分页 + CAS + tx** | cursor、`rev/if_rev`、`storage.tx`、200 ops 上限 | 并发 CAS 冲突用例；tx 中途失败整批回滚 |
| **ST-3 导出/导入** | NDJSON、manifest、sha256、原子写 | 导入校验失败不落半截；导出可重建 |
| **ST-4 隔离与白名单** | namespace 归属、`allowed_plugins`、审计日志 | 伪造 namespace 被拒；未授权插件访问 403 |
| **ST-5 版本与维护** | `schema_version`、compact、purge 二次确认 | 迁移演练；purge 只删自己的库 |
| **ST-6 docnorm 接入** | `tree.docnorm` 以 `requires` 依赖并跑通 DN-4/DN-6 | 重启后数据在；缺存储时 fail-closed |

门禁沿用项目规则：`dart analyze`（无新增）→ 受影响包全量 `dart test` →
`tree_protocol` 访问控制 → 涉及 UI 才 `flutter`。

---

## 8. 验收判据

| 编号 | 判据 |
| --- | --- |
| TC-ST-01 | 两个插件各自建库，互不可见；跨 namespace 未授权 ⇒ 403 |
| TC-ST-02 | 同 key 两次 `put` 的 `rev` 单调递增；`if_rev` 不匹配 ⇒ 冲突错误，不覆盖 |
| TC-ST-03 | `storage.tx` 中任一 op 失败 ⇒ 整批回滚，库内无半截数据 |
| TC-ST-04 | `query` 的 limit 上限生效；cursor 翻页无重复/无丢条 |
| TC-ST-05 | 导出后删除集合，再用导出物导入，条目数与内容一致（sha256 校验） |
| TC-ST-06 | 强杀插件进程后重启，已提交数据可读，未提交数据不出现 |
| TC-ST-07 | 卸载插件不删库；`purge` 二次确认后才删除 |
| TC-ST-08 | 伪造 `source_plugin_id` 不能写别人 namespace |
| TC-ST-09 | `storage.ensure` 遇到更高 `schema_version` 拒绝，不静默降级 |
| TC-ST-10 | `tree.docnorm` 在存储不可用时 `baseline` fail-closed，给出可读原因 |
| TC-ST-11 | 单次 `storage.tx` 超过 8 MiB 或单条 value 超过 1 MiB ⇒ 整批拒绝，不落半截 |
| TC-ST-12 | 调用方伪造成 `meta.source_plugin_id` 不可能成功（核心透传覆盖）；缺身份 ⇒ 拒绝 |
| TC-ST-13 | 两个 team 的实例各写各的库文件；缺 `team_id` 的命令被拒，不落到“公共库” |

---

## 9. 风险与待拍板

| 项 | 推荐 | 说明 |
| --- | --- | --- |
| 单库 vs 分库 | **分库**（每团队 × 每插件一个） | 隔离故障与扫描；避免多团队实例撞同一库文件 |
| 实例粒度 | **`granularity: team` + 路径带 team_id** | 与 `tree.agent` / 执行器一致；缺 team_id 直接拒绝 |
| 卸载保留数据 | **保留 + 显式 purge** | 误删不可逆；与“用户资产”一致 |
| 单条 value 上限 | **1 MiB 内联**，单次 tx 总量 **8 MiB**，超出走文件信封 | 避免数据库被大块内容拖垮；也防一次 tx 长期占住事件循环 |
| `storage.` 前缀 | **不做核心预留**，先到先得 + 文档登记 | 核心预留要改点位表；当前由 tree.storage 首个申报，第三方不得重名（注册即拒）；若后续出现争用，再单开“命令族预留”切片 |
| 导出是否入库 | **默认不入库** | 过程产物；需要评审时人工提交 |
| 长事务 | **不提供** | 跨命令长事务会锁死其它插件；用 CAS 重试替代 |
| 是否给 UI 直连 | **不给** | UI 只走 REST 委派；保持“UI 只做消费者” |

---

## 10. 证据索引

- Sembast 已用（tree.agent 会话库）：`plugins/tree.agent/pubspec.yaml:16-18`、
  `plugins/tree.agent/lib/src/store/conversation_db.dart:10-24`
- 单写者与崩溃模型：`conversation_db.dart:22-24`
- 执行站注册形状：`plugins/local_executor/local_executor_plugin.dart:47-66`
- 命令按名字路由：`docs/plugin-development.md:567-570`
- 站点/执行站协议：`docs/plugin-development.md` §3.1 / §3.3 / §6
- 存储拍板：`docs/doc-normalization-recon.md` D27 / §7 外部前置
- 车道记录：[project-status.md](../project-status.md) 车道 I
