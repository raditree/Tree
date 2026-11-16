# Embedding 逻辑去重扫描链路 · 实施计划（storage + settings 插件级绑定）

## Context

产线 P6「整理报告」目前的去重只有一条链：FNV-1a 全文件摘要 → 字节完全相同的文件分组。它能发现「复制粘贴的文件」，但发现不了「换个名字、改两行、逻辑一样」的重复函数，也不做跨文件、跨模块的语义召回。

本计划分两步：

1. **阶段 0（本期前置，两个插件一起改）**
   - `tree.storage` 增加 **plugin 级绑定**：调用方只给 plugin_id（namespace 缺省即自己），不再强制 `team_id`。
   - `tree.settings` 同样增加 **plugin 级绑定**：设置是插件级/机器级配置，本来就不该被团队切碎；全局库 + 设置页直接编辑全局值。
2. **阶段 1**：在 `tree.production.line` 新增独立的**逻辑去重链**：git 跟踪文件 → 函数级分块 → 内容哈希缓存 → `llm.embed` 向量 → 全库向量索引 top-k → 阈值判重 → 结果落 `tree.storage`；配置读 `tree.settings` 全局绑定，固定 `seed=42`，按 `git diff` 增量，支持 `--rebuild`。

边界：**不改** `production.audit.run`、不改 `AuditReport` schema、不改 FNV 精确去重链。两条链并存：FNV 负责「字节完全相同」，Embedding 只负责「语义/逻辑相似」预筛，不宣称字节相同。

## 阶段 0A：tree.storage 增加 plugin 级绑定

### API

所有 `storage.*` 命令新增**可选**参数：

```json
{"binding": "plugin"}            // 或省略 = "team"（默认，行为不变）
```

- `binding=team`（默认）：保持现状，`scope.team_id` 必填。
- `binding=plugin`：忽略 `team_id` / `agent_id` / `session_id`；库只按 `namespace` 落盘，`namespace` 缺省 = 调用方 `meta.source_plugin_id`。
- 非法值 → `invalid_arguments`；响应统一增加 `binding` 字段（team 时同时回 `team_id`，plugin 时回空串）。

### 路径与隔离

| 绑定 | 路径 |
|---|---|
| team（现状） | `<data_root>/storage/<team_id>/<namespace>/data.semdb` |
| plugin（新增） | `<data_root>/plugin_storage/<namespace>/data.semdb` |

- 单独顶层目录，不复用 `storage/<team_id>/`，避免与合法 team 名冲突，也不需要迁移旧数据。
- 一个 namespace = 一个库；所有调用都经 storage 执行站，插件级库不会被多个调用方进程同时打开。
- 访问控制不变：默认只能读写自己的 namespace；跨 namespace 仍需 `TREE_STORAGE_ALLOWED_PLUGINS`；`storage.purge` 只允许删自己的 namespace。

### 实现改动

- `lib/src/storage_engine.dart`：
  - 新增值对象 `StorageScope { kind: 'team'|'plugin', teamId }`。
  - `databasePath({required StorageScope scope, required String namespace})` 按上表分派。
  - `_database(scope, namespace)` 与 13 个命令方法把 `required String teamId` 改为 `required StorageScope scope`。
  - `export` manifest 增加 `binding`（team 仍写 `team_id`，plugin 写空串）。
  - `importData` 校验 manifest `binding`：缺失按 `team`（兼容旧导出）；不符 → `import_invalid`；plugin 绑定时 `team_id` 必须为空。
  - `stats` / `purge` 按 scope 返回路径、删对应库。
- `lib/src/storage_service.dart`：解析 `binding`，构造 `StorageScope`；team 绑定才校验 `team_id`；审计行增加 `binding`。
- `tree.storage_plugin.dart`：自检增加 plugin 绑定用例。
- `plugin.json`：0.1.0 → 0.2.0，描述补 plugin 级绑定与路径。
- 文档：`docs/pluginization/tree-storage-recon.md` 更新布局、参数、访问控制、兼容说明。

### 兼容性

- 不传 `binding` 的老调用完全不变（team 必填、路径不变）。
- 旧导出物 manifest 无 `binding` → 按 team 导入。
- `granularity` 仍是 `team`（平台实例粒度不变），plugin 级只是库路径维度。

## 阶段 0B：tree.settings 增加 plugin 级绑定

### 为什么必须改

现状是插件语义，不是误读：

- `settings_service.dart:68-74`：`scope.team_id` 为空直接 `team_required`。
- `settings_engine.dart:48-66`：库路径 `<data_root>/settings/<team_id>/settings.semdb`。
- `plugin-settings-recon.md:20`：「v1 只做 team 作用域」。
- `scope` 由核心按调用点（Agent/团队/会话）解析后经站请求信封透传，不是设置页自造。

但设置本质是**插件级配置**（模型、阈值、开关），不该按团队各存一份；本期把它改成以全局为主。

### API

`settings.define / list / get / set / reset / export` 新增可选参数：

```json
{"binding": "plugin"}            // 或省略 = "team"（默认，兼容旧调用）
```

- `binding=plugin`：全局库，不需要 `team_id`；owner 仍只认 `meta.source_plugin_id`。
- `binding=team`：保持现状（team 必填、路径不变），作为显式的团队覆盖能力保留。
- 响应增加 `binding`、`team_id`（plugin 时空串）。

### 路径

| 绑定 | 路径 |
|---|---|
| team（现状） | `<data_root>/settings/<team_id>/settings.semdb` |
| plugin（新增） | `<data_root>/plugin_settings/settings.semdb` |

- 全局库一个文件装所有插件的 schema 与值（`schemas` key=owner，`values` key=`owner|key`），设置页一次读取全部插件。
- 写入仍只允许写自己的 owner（`meta.source_plugin_id`）；设置页通过 REST 代写时保持现有\"先确认 schema 存在\"的规则。

### 实现改动

- `lib/src/settings_engine.dart`：
  - 新增 `SettingsScope { binding, teamId }`；`databasePath(scope)` 按上表分派。
  - `define/list/get/set/reset/export` 与 `listSchemas` 的 `required String teamId` 改为 `required SettingsScope scope`（机械改动）。
  - schema 版本、类型校验、secret 规则不变。
- `lib/src/settings_service.dart`：
  - 解析 `arguments['binding']`；team 绑定才校验 `team_id`，plugin 绑定跳过。
  - `handleDelegate`：`binding` 从 query/body 读取；`binding=plugin` 时不再要求 `team_id`，`binding=team`（或省略）仍 400 `team_required`。
  - `SettingsChange` / `settings.changed` 载荷增加 `binding`（`team_id` 保持不广播，避免泄露归属）。
- `plugin.json`：0.1.0 → 0.2.0，描述改「插件级全局设置 + 可选团队覆盖」。
- 设置页（`plugins/tree.ui.default`）：
  - `ApiService.getPluginSettingsSchema/getPluginSettingsValues/updatePluginSettings/resetPluginSettings` 增加 `binding` 参数（默认 `plugin`），query/body 带 `binding=plugin`。
  - `PluginSettingsCard` 不再因 `teamId` 为空而清空：默认按全局加载；卡片标题标「全局（所有团队）」。团队覆盖不在本期 UI 暴露（API 仍可用）。
- 调用方：`tree.production.line` 的 `_readQuestionLimit` 改用 `binding:'plugin'`，去掉 `team_id` 为空就返回的守卫；`settings.define` 同样用 plugin 绑定。dedup 配置也走 plugin 绑定。
- 文档：`docs/pluginization/plugin-settings-recon.md` 增加 v2 绑定语义、路径、REST 参数、兼容性；`docs/work-log.md` 追加一行。

### 兼容性与存量值

- 不传 `binding` 的老调用行为不变（team 必填、路径不变）。
- 旧的 `<data_root>/settings/<team>/settings.semdb` 保留；全局库从 schema 默认开始。**不自动迁移**：当前真实使用只有 `questions_max_per_round` 一个键，影响可忽略；需要保留旧值时后续加 `settings.migrate` 或在全局设置页重填。
- `settings.list` 只读所选绑定的库，不合并 team 覆盖（避免隐式优先级）；团队覆盖是显式 API 能力。

## 阶段 1：Embedding 逻辑去重

### 关键决策

1. **独立命令族**，不塞进 `production.audit.run`：GET 整理报告必须零成本，而 embedding 付费且受 30s 委派截止；两者断点、锁、失败语义都不同。
2. **函数级分块用启发式扫描**，不引入 `analyzer`/tree-sitter（插件当前零重依赖）。无法可靠闭合的文件整体 fallback 为 `(file)` 块，宁可粗不可碎。
3. **向量按内容寻址**：`vec_key = hash(chunk 全字节 + 分块版本 + pipeline 版本 + 模型 + embedding 相关设置 + seed + 归一化/池化/指令前缀 + 维度)`。同一函数换文件、换路径也命中缓存；删除/改名靠 chunk 记录 + finalize GC 清理孤儿向量。
4. **增量用 git diff，比对用全库索引**：只对本次变更/新增 chunk 计算 top-k，却与全库所有 chunk 比较，避免漏掉「新函数与未变更函数重复」。
5. **缓存用 plugin 级绑定**：dedup 的 chunk/vector/result 一律 `binding:'plugin'`，不依赖 team，后续其它插件也能读。
6. **配置用 settings 全局绑定**：`binding:'plugin'` 读取，配置与团队无关；settings 缺失时回退 env / 默认。

### 模块划分（`plugins/tree.production.line/lib/src/`）

| 文件 | 职责 |
|---|---|
| `code_git.dart`（新） | 只读 git：`open(workspace)`、`lsFiles()`（`git ls-files -z --`）、`headSha()`、`deltaSince(base)`（`git diff --name-status -M -z <base> --`，解析 A/M/D/R）；`Process.run` + 60s 超时；错误码 `git_required` / `git_unavailable` / `git_timeout` |
| `code_chunk.dart`（新） | 纯函数分块：`chunkFile(path, content, language) → List<CodeChunk>`；`kChunkerVersion = 1` |
| `dedup_config.dart`（新） | settings（plugin 绑定）> env > 默认；`DedupConfig`、`embedSettingsHash`、`vecKeyOf(chunk, config)` |
| `dedup_store.dart`（新） | storage 封装（仿 `docnorm/baseline.dart` 的 `DocStore`），统一 `binding:'plugin'`：`ensureAll`、`listAll`（scan 5000 → `query sort:'id'` 500/页）、`txSliced`（≤200 ops / ≤8MiB）、`deleteKeys` |
| `dedup.dart`（新） | 纯领域：L2 归一化、余弦、top-k（有界插入、分数相同按 chunk id 升序，固定 seed=42 的确定性排序）、阈值判重、结果聚合 |
| `dedup_service.dart`（新） | 状态机 + 命令门面：`production.dedup.run` / `production.dedup.status` |

改动文件：

- `tree.production.line_plugin.dart`：新增 `kDedupCommands`、命令路由、`_callEmbed`、`_callStorage`（`binding:'plugin'`）、`_readQuestionLimit` 改全局绑定、schema v2、selftest 增加 dedup 段。
- `lib/tree_production_line.dart`：导出新模块。
- `lib/src/api.dart`：`dedupPattern`、GET（零成本）/POST（跑一批）、`kDeclaredRoutes`、错误码映射。
- `plugin.json`：0.9.0 → 0.10.0；描述补 P6 逻辑去重；`tree.storage` 仍 optional（缺时 dedup fail-closed）。
- `pubspec.yaml`：版本同步。
- `plugins/tree.ui.default`：工作台「整理报告」旁增加「逻辑去重」区；`api_service.dart` 增加 GET/POST 方法。
- `docs/pluginization/production-line-recon.md`：新增 §7.12；`docs/work-log.md` 追加一行。

### 函数级分块

- 语言：`.dart / .py / .go / .rs / .ts / .tsx / .js / .jsx / .vue`；Vue 只取 `<script>` 段。
- 识别：行级正则 + 头部扫描。
  - Dart：`class/mixin/extension` 维护 Owner 栈；方法/顶层函数 `[Type] name(...) {`；支持 `=> expr;`。
  - Go：`func (recv T) Name(...)`；Rust：`impl X { fn ... }`；Python：`def` / `async def` + 缩进归属。
  - TS/JS：`function`、class 方法、`const x = (...) =>`。
- 结束位置：字符状态机（normal / 行注释 / 块注释（Rust 嵌套）/ 单双引号 / 模板串 / Dart raw 与三引号 / 字符字面量），花括号深度归零；`=>` 在深度 0 的 `;` 结束；Python 用缩进回退。EOF 未闭合 → 整文件 fallback。
- `scope`：`Owner.name`（嵌套 `Outer.Inner.m`，≤120 字符）；匿名闭包并入宿主，不单独成块。
- `chunk_id = 'ch-' + fnv1aHex('$path\n$scope\n$contentHash')`，**不含行号**，行号漂移不换 id；`start_line/end_line` 只用于展示。
- 尺寸：`<60` 字符丢弃；`>6000` 字符按行窗口切成 `scope#1..n`；fallback 文件块 `scope='(file)'`。

### 存储模型（`binding:'plugin'`，namespace = tree.production.line，key 前缀 `<repoKey>#`）

| 集合 | key | value 要点 |
|---|---|---|
| `dedup_files` | `file:<path>` | `path, content_hash, bytes, chunker_version, chunk_ids[]` |
| `dedup_chunks` | `chunk:<chunkId>` | `id, path, scope, signature, start_line, end_line, hash, chars, text(≤6000), vec_key, chunker_version, pipeline_version` |
| `dedup_vectors` | `vec:<vecKey>` | `vec_key, content_hash, model, dimensions, seed=42, normalize, pooling, instruction_prefix, embed_settings_hash, pipeline_version, vector[]` |
| `dedup_results` | `result:<sourceChunkId>` | `id, path, scope, matches[{chunk_id,path,scope,score,exact}], threshold, model, pipeline_version, generated_at` |
| `dedup_meta` | `meta` | `pipeline_version, chunker_version, model, dimensions, seed, embed_settings_hash, baseline_sha, last_run{run_id,mode,head_sha,counts,degraded,reasons,finished_at}` |

- 所有集合 `storage.ensure {binding:'plugin', schema_version:1}`。
- 写：`txSliced` 每 200 ops 一批；chunk 正文 ≤6000 字符，远低于单条 1MiB。
- 删除：按 `dedup_files.chunk_ids` 精确删 `chunk:` / `result:`；向量不立即删，finalize 统一 GC（读全量 chunk 的 `vec_key` 集合，删未被引用的 `vec:`）。
- 重建：逐集合 `listAll` 后分批删（或 `storage.purge` 仅本 namespace），再走全量基线；finalize 后 `storage.compact`。

### 增量与状态机

状态文件：`<line>/dedup_state.json` + `.lock`（沿用 audit 的 exclusive create / 10 分钟陈旧锁）。字段：

`version, run_id, line_id, workspace, repo_key, mode, base_sha, head_sha, phase, pending_files[], file_cursor, embed_queue[], embed_cursor, compare_queue[], compare_cursor, gc_queue[], counts{}, degraded, reasons[], started_at`

阶段（每个请求只推进有界预算，整段 tx 提交后才推进 cursor 并写 state）：

1. **plan**（≤ `dedup_files_per_request`，默认 50 文件/请求）：`git delta` → 读文件（≤ `dedup_max_file_bytes`）→ 分块 → 与 `dedup_files` 旧 `chunk_ids` 求差，写新 chunk/file 记录、收集待删 chunk/result、生成 `embed_queue`。
2. **embed**（≤2 次 `llm.embed`，每次 ≤ `dedup_embed_batch` 默认 32）：先按 `vec_key` 查 `dedup_vectors`，全键相等直接复用；未命中才请求（文本前加 `instruction_prefix`）。过滤空/纯空白 chunk（`llm.embed` 会静默丢空串导致下标错位），并严格校验 `vectors.length == inputs.length`、模型、维度。
3. **compare**（≤ `dedup_compare_per_request`，默认 100 源 chunk/请求）：一次性分页加载全局 chunk + vector 索引（进程内按 run_id 缓存），对每个源 chunk 计算余弦 top-k，`score ≥ threshold` 写 `dedup_results`；`hash` 相同标 `exact:true`。只比较本 run 新增/变更 chunk。
4. **finalize**：GC 孤儿向量与孤儿 chunk/result；写 `dedup_meta`；仅当 `degraded == false` 且无 pending 时推进 `baseline_sha = head_sha`；删 state。

删除/改名：

- `D`：读旧 `dedup_files`，删其 chunk/result/file 记录。
- `R`（`-M`）：按「删旧 + 增新」处理；新路径内容不变时 `vec_key` 命中，0 次 embedding。
- 已不在 `git ls-files` 里的旧 `dedup_files` 记录在 finalize 清理。

一致性：

- 每批先写 chunk 再写 vector，compare 只读有 vector 的 chunk。
- `head_sha` 每个请求重读；若与 state 不一致，返回 `head_moved`，丢弃 state 重新开始。
- `degraded` 或 pending 时暂停 baseline，下次从旧基线重放（缓存保证已 embed 的不重复付费）。

### 配置（tree.settings schema v2，全局绑定）

现有 `_questionSchema()` 的 `schema_version` 升到 `2`（保留原 `questions_max_per_round`），新增 group `dedup` 字段：

| key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `dedup_enabled` | bool | true | 关闭时 run 直接回 skipped |
| `dedup_model` | string | '' | 空 = 首个 `kind=embedding` |
| `dedup_similarity_threshold` | double | 0.90 | 0.5–0.99 |
| `dedup_top_k` | int | 5 | 1–20 |
| `dedup_embed_batch` | int | 32 | 1–64 |
| `dedup_instruction_prefix` | string | '' | 计入 `vec_key` |
| `dedup_normalize` | enum `l2/none` | l2 | 计入 `vec_key` |
| `dedup_pooling` | enum `mean/cls` | mean | 记录并计入 `vec_key`（实际池化由模型端决定） |
| `dedup_max_file_bytes` | int | 262144 | 超限跳过并记 reasons |
| `dedup_files_per_request` | int | 50 | 单请求 plan 预算 |
| `dedup_compare_per_request` | int | 100 | 单请求 compare 预算 |
| `dedup_max_index_chunks` | int | 20000 | 全局索引软上限，超限截断并显式记 reasons |

- 读取：`settings.get {binding:'plugin'}`；优先级 `settings > TREE_PL_DEDUP_* 环境变量 > 默认`。
- `seed` 固定常量 `42`，不可配置，但计入 `vec_key` 与每条记录。
- `settings_hash` 只覆盖影响向量的字段；改阈值/top-k 只重算 compare，不重嵌。
- settings 插件缺失/失败 → 默认值 + `degraded:true` + reason `settings_unavailable`，不 fail。

### 命令与 REST

命令（同一 `production` 执行站）：

- `production.dedup.run {line_id, mode?: 'incremental'|'rebuild', limit?}`：推进一个请求批次，返回 `{run_id, phase, done, percent, progress:{files_total,files_done,chunks,embedded,reused,compared,pairs}, model, dimensions, degraded, reasons, counts}`。
- `production.dedup.status {line_id}`：只读 `dedup_meta` + top 结果，**不跑 git、不发 embedding**。

REST：

- `GET /api/production/lines/{lineId}/dedup` → status（零成本）。
- `POST /api/production/lines/{lineId}/dedup` body `{mode?, limit?}` → 跑一批（显式付费动作）。
- 加入 `kDeclaredRoutes`；错误码：`git_required`、`git_unavailable`、`git_timeout`、`storage_unavailable`、`dedup_in_progress`、`head_moved`、`no_embedding_model`、`embedding_failed`、`invalid_arguments`。
- 不需要 `team_required`：storage 与 settings 都走 plugin 绑定。

UI（`production_line_workbench.dart`）：

- 「整理报告」行旁加「逻辑去重」按钮 + 每批文件数输入 + 「全量重建」。
- 展示 `phase/percent` 进度、`embedded/reused` 计数、`degraded` 原因、top pairs（`path:scope ↔ path:scope · score`）。
- 未完成显示「继续」；GET 只读上次结果，不自动跑。

### 失败与降级

- 非 git 工作区：`git_required`（不提供文件系统模式）。
- 无 embedding 模型：`mode:'unavailable'`，不写任何向量，明确提示「仅 FNV 精确去重可用」，不影响 audit。
- 部分 embedding 失败：已成功向量保留，失败项留待下一批；`degraded:true`，不推进 baseline。
- storage 不可用：dedup 命令 fail-closed；产线其它功能不受影响。
- 文件超限/二进制：计入 skipped + reasons。
- 分块失败：整文件 `(file)` fallback，`fallback_files` 计数（最多列 20 个）。

## 测试

### 阶段 0A（tree.storage）

- service：`binding=plugin` 且 scope 为空时 CRUD 正常；`binding` 非法 → `invalid_arguments`；同 namespace 的 team / plugin 库互不可见；跨 namespace 仍 `namespace_denied`；plugin 绑定下 `purge` 只删自己的库。
- engine：`databasePath` 两种路径；`export` manifest 带 `binding`；`import` 缺失 binding 按 team、绑定不符 → `import_invalid`；`stats` 返回正确路径。
- selftest：新增 plugin 绑定用例并保留原 team 用例。

### 阶段 0B（tree.settings）

- service：`binding=plugin` 无 team 时 define/get/set/list/reset 正常；`binding=team` 仍 `team_required`；非法 binding → `invalid_arguments`；全局库与团队库同 owner/key 互不覆盖；`settings.changed` 载荷带 `binding`。
- REST：`GET schema?binding=plugin` 无 team 可读；`PATCH values` body 带 binding；`binding=team` 缺 team → 400。
- engine：路径、schema 版本/类型/secret 规则不变；全局库跨 owner 隔离。
- UI：`PluginSettingsCard` 在 `teamId=''` 时仍加载全局设置，请求带 `binding=plugin`；保存/reset 同样带 binding。
- selftest：plugin 绑定 + 原 team 用例。

### 阶段 1（tree.production.line）

- chunker 单测：Dart/Py/Go/Rust/TS 各一；字符串/注释/嵌套注释中的花括号；`=>`；Python dedent；Vue script；EOF 未闭合 fallback；行号漂移 id 不变。
- 领域单测：`vecKey` 全字段敏感性；余弦/top-k 并列排序确定性；阈值边界；`exact` 标记。
- service 单测（fake storage/settings/embed）：首次全量基线；二次 0 embed；改一个函数只嵌 1 块；删除/改名清理；全局 top-k 命中未变更文件；`mode=rebuild`；模型/分块版本升级失效；崩溃后按 cursor 续跑；`head_moved`。
- 设置读取：断言 dedup 用 `binding:'plugin'`，不依赖 team；`_readQuestionLimit` 同样走全局绑定。
- api 单测：GET 不触发 embed；POST 推进；错误码映射。
- selftest：FakeCore 增加 `storage.*`（支持 `binding=plugin`）与 `settings.*`（支持 `binding=plugin`）内存实现、`llm.embed` 计数，断言两轮 0 调用、FNV 报告不变、`--rebuild` 幂等。

验证命令：

```powershell
cd plugins/tree.storage
dart pub get
dart analyze
dart test
cd ../tree.settings
dart pub get
dart analyze
dart test
cd ../tree.production.line
dart pub get
dart analyze
dart test
cd ../tree.ui.default
dart analyze
dart test
cd ../..
dart run tool/build_plugins.dart --only tree.storage
dart run tool/build_plugins.dart --only tree.settings
dart run tool/build_plugins.dart --only tree.production.line
```

可选端到端：临时 git 仓跑 `production.dedup.run` 直到 `done`，检查 `storage.stats {binding:'plugin'}` 中五个集合与 `dedup_results` 的 top pairs。

## 验收对照

| 验收标准 | 落点 |
|---|---|
| **storage 可只给 plugin 不给 team** | `binding:'plugin'` 全命令可用，路径 `plugin_storage/<namespace>` |
| **settings 可只给 plugin 不给 team** | `binding:'plugin'` 全命令 + REST 可用，路径 `plugin_settings/settings.semdb` |
| 设置页编辑的是全局值 | `PluginSettingsCard` 默认 `binding:'plugin'`，无 team 也能加载/保存 |
| 老调用不受影响 | 缺省 `binding:'team'`，两条链路径与校验不变 |
| 首次全量 tracked 建基线 | plan 阶段遍历 `git ls-files`，finalize 写 baseline |
| 无变更二次运行 embed = 0 | delta 为空 + `vec_key` 全命中 |
| 改一个函数只嵌新 chunk | chunk 差集 + 内容寻址向量 |
| 全字节命中不重发 | `vec_key` 含 chunk 全字节哈希 + embedding 设置 |
| 删除/改名清理 | file→chunk 反查 + finalize GC |
| 新 chunk 与全库 top-k | compare 阶段加载全量索引 |
| 版本升级失效 / seed 可复现 | `vec_key` 含版本与 seed；确定性排序 |
| 精确链边界清晰 | audit 的 FNV 链不改；结果标 `exact` |

## 风险

1. **两个插件的引擎签名改动面**：storage 13 个方法、settings 6 个方法 + 测试；用 `StorageScope` / `SettingsScope` 值对象收口。
2. **plugin 级库的并发**：所有访问都经各自执行站单进程，路径按 namespace/owner 唯一；文档写明不要绕过执行站直接开库。
3. **导出/导入兼容**：旧 storage manifest 无 `binding`，按 team 处理。
4. **存量设置值不自动迁移**：旧的团队库保留但不再被全局设置页读取；当前只有 `questions_max_per_round` 受影响，可在全局页重填。需要无损迁移时后续加 `settings.migrate`。
5. **启发式分块误判**：只接受可靠闭合边界，失败整文件 fallback，并用 `kChunkerVersion` 整体失效。
6. **全库索引加载成本**：`storage.scan` 5000 无 cursor，改用 `query sort:'id'` 分页 + 进程内缓存 + 软上限，超限显式说明。
7. **O(n²) 比对**：只比本 run 变更 chunk，单请求比较预算封顶，向量用 `Float32List`。
8. **存储膨胀**：正文 ≤6000 字符、结果按 chunk 覆盖写、finalize GC + `compact`。
9. **未跟踪文件不参与**：按要求只处理 git tracked；用户需先 `git add`。
