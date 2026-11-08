# 侦查落档：文档规范化 / 项目整理 / 代码复用识别（DN 系列）

> 状态：**本期只做侦察、语义对齐与落档，不实施**。本文档即本期交付物。
> 日期：2026-11-08。版本线：`1.0.5+1`（大版本迭代期）。
> **定位**：**TREE 平台的一个 headless 插件（`tree.docnorm`）**，跑在 TREE 之内（依赖插件平台 / 执行站 / `tree.storage` / 模型池 / 设置页）。
> **"零仓库依赖"指的是对被分析仓库零侵入**：打包进 TREE 后可直接指向任意仓库（Python / Java / Go / Rust / Node / C# / C++ / Dart …）；目标仓库**不装 TREE、不改代码、不加配置、不需要 Dart 运行时**，只读 `git ls-files` 与声明式配置。
> 本仓（desktop）只作为**首个被分析对象**（§6 数字为示例证据，不是设计前提）。
> **口径降级（用户拍板）**：任何模式都**不重写既有文档，只新增章节**；"全量同步"= 所有包各补一次缺章节，`--all` 只扩范围不扩权限。
> 作用域：**仅对 Git 追踪文件生效**；一个仓一个作用域，子模块 / 多仓 / monorepo 分别成域，不跨界提交。
> **口径状态**：D1~D34 为**默认口径（已定，可直接实施）**；P1~P8（§8）是**拍板记录**——除 P8 的评测基线需在执行前产出外，其余按默认执行。

---

## 0. 定位与结论速览

**本质任务：文档归一化 = 包功能收束**。目的是给 production line 提供**可替代全面侦查的最小输入**（每个包/子包：一句话功能 + 唯一入口 + 边界），文档是载体，`pkg_index` 是机器可读产物；同步、体检、建议、图谱都服务于这个目标。

**规则要可换，默认要空仓可用**：三层规则源——**规则包 > 仓库自述（`CONTRIBUTING*`/`AGENTS.md`/门禁命令）> 内置空仓默认**；空仓零配置可跑通，有文档的仓库先做**契约侦查**。

1. **流水线与"被分析仓库"的语言无关**，差异全部收敛到 `LanguageAdapter` 六方法（包识别 / 注释 / 声明 / 断言 / API / 构建测试）；未覆盖语言走 fallback 并标 `degraded: true`。
2. **"包"按生态清单识别**：`pyproject.toml` / `pom.xml`+`settings.gradle` / `go.mod` / `Cargo.toml` / `package.json`(workspaces) / `*.csproj` / `CMakeLists.txt` / `pubspec.yaml`；无清单退化为目录启发式；容器目录不单独成单元。
3. **有文档的仓库先做契约侦查**（`docnorm.contract`）→ `DocContract`（章节 / 索引 / 链接 / CHANGELOG / 提交风格 / 门禁）；侦查不出标 `unknown`，不猜、不阻塞。
4. **文档门禁抽象为 `DocPolicy`**（必需文档 / 必需章节 / 索引完整 / 链接可解析 + 仓库自定义命令）；生成侧必须先读策略再写。
5. **预算拆成两个额度，不再混用**（D5）：`context_cap = min(配置, 模型 max_seqlen × 70%)` 管**单次调用**；`stage_budget` 管**阶段累计**。两者各自报错；首建 450k 由 300 次小调用分摊，**不会被单次额度卡死**；模型未配 `max_seqlen` 时用兜底 128k（`plugins/tree.agent/lib/src/settings/domain_settings.dart:kFallbackMaxSeqlen`）。
6. **注入默认「注释 + 声明与描述」**，全代码仅在单次估计 ≤ `context_cap` 70% 时允许；测试默认仅注入断言。
7. **只增不改**：既有条款文本不动 ⇒ 条款差异只可能是 `added`；**索引是唯一例外**，但只允许**追加式插入**（D29）。
8. **变更判定用 `git diff`**，不用 `git status`（stat-dirty 会产出空提交）；多仓/子模块分域出计划，跨仓不合批。
9. **载体是 TREE 内的 headless 插件**（`requires: tree.storage` + `local_executor`），CLI 只是同一引擎的调试/CI 壳。
10. **与车道 H 的对接**：P0（DN-3 + DN-6，索引追加式 + 断链）解锁 **P1**（数据模型/队列，不依赖 `pkg_index`）；**DN-7（收束产物）、DN-9/10（图谱）是 P3 准备阶段前置**。
11. **建议四类**：`reuse` / `split_size` / `split_function` / `api_boundary`；docnorm 只产建议，**不执行、不建任务**。
12. **三层单向依赖破环**（D21）：L0 事实（`pkg_index` / `graph_*` / `doc_contract`，确定性、无 LLM）→ L1 文档（只增不改）→ L2 改造（产线任务）；L2 完成只把受影响包标 `stale`，由 `reanalyze --changed` 重算。
13. **建议状态单真源**（D20）：docnorm 只持建议事实与 `lastTaskId`；**任务状态唯一由产线持有**；UI 组合展示、不回写。
14. **图谱定 GraphRAG，只对文档建图**（§4.6）：分块/BM25 自写、Leiden 用 `yograph`（版本/许可证/Dart 3 兼容性**尚待核实**）、实体与社区报告走 LLM 并缓存；**本期上 embeddings（模型池 `kind: embedding`），检索默认 `hybrid`**；没有可用 embedding 时 lexical 降级并显式标 `mode`。
15. **存储独立成插件**（D27）：`tree.storage`（Sembast、纯 Dart）统一集合存储；**DB 为真源，JSONL 只是 `export` 快照**。
16. **安全默认收紧**（D30）：门禁命令默认**只列不跑**，`--run-gates` 才执行；规则包必须 pin commit + 校验和且默认禁网；`baseline` 默认 dry-run，`--commit` 才落盘提交。
17. **阈值不硬编码**（D31）：5 000 / 1 000 行、API > 20、一句话 ≤ 60 字等全部进 `policy.json` 默认值，引擎只读配置。
18. **插件可带设置项**（D28）：由独立 `tree.settings` 插件承载（车道 K）；插件声明 schema，服务存用户覆盖值并广播变更，任意 UI 插件通用渲染；核心不存值、不聚合。优先级 设置服务 > 环境变量 > 插件 config > 默认；secret 只回 `has_value`。**K 未落地前 docnorm 用 `.docnorm/config.json` + 环境变量**。
19. **模型池按用途分类**（D33）：`kind: chat | embedding | decision`；embedding 供 docnorm 检索，decision（JEV）供产线路由/重试/询问与 docnorm 冲突分级；JEV 输入 state + typed questions（noul/choice/score），输出概率与置信度，**不当 chat 模型用**。

---

## 1. 语言矩阵（被分析仓库的适配层）

| 生态 | 包单元识别 | 注释 / 文档注释 | 声明抽取 | public API 计数 | 测试与断言 | 原生文档工具 |
| --- | --- | --- | --- | --- | --- | --- |
| Python | `pyproject.toml` / `setup.py` / 顶层 `__init__.py` 目录 | docstring | `ast` 的 `def` / `class` + 签名 | `__all__`；否则非 `_` 顶层名 | `assert` / pytest / unittest `assertX` | Sphinx / mkdocs / pdoc |
| Java | `pom.xml` modules / `settings.gradle` include | Javadoc `/** */` | 解析器优先；无则括号配对 | `public` 顶层类型与成员 | JUnit `assertX` | Javadoc |
| Kotlin | `build.gradle.kts` + `settings.gradle.kts` | KDoc | 同上 | `public`（默认可见性） | kotlin.test / JUnit | Dokka |
| Go | `go.mod`（模块；包 = 目录） | `//` `/* */`（godoc 约定） | 括号配对 | 首字母大写的导出标识符 | `testing` + `t.Errorf` | `go doc` |
| Rust | `Cargo.toml`（package / workspace） | `///` `!` | 括号配对 + `pub` 判据 | `pub` 项（排除 `pub(crate)`） | `assert!` + `#[test]` | rustdoc |
| Node / TS | `package.json` + `workspaces` | JSDoc / TSDoc | 括号配对；`export *` 追链 | `export` 声明 | jest / vitest `expect` | TypeDoc |
| **Vue 3** | `package.json` + `vite.config.*` / `nuxt.config.*`；`.vue` SFC | `<!-- -->` + `//` / `/** */` | `script setup` 的 `defineProps` / `defineEmits` / `defineExpose` + `export` | 组件 props/emits/slots + composables 导出 | vitest + `@vue/test-utils` | VitePress / TypeDoc |
| **Web / HTTP 接口** | OpenAPI/Swagger（`openapi.*` / `swagger.*`）、`.http` / `.rest` 请求文件 | 规范内 `description` / 注释 | 路径、方法、参数、响应 schema | 端点数（去重后） | 契约测试 / 请求样例 | Swagger UI / Redoc |
| C# | `*.csproj` / `.sln` | XML 注释 `///` | 括号配对 | `public` | xUnit / NUnit | DocFX |
| C / C++ | `CMakeLists.txt` / `meson.build` | Doxygen `/** */` | 头文件声明（需配置） | 头文件导出声明 | gtest / `assert` | Doxygen |
| Dart | `pubspec.yaml` | `///` | `dart doc --output` 的 `index.json`（SDK 自带） | barrel `export` 顶层声明 | `expect` | dartdoc |
| 其它 | 目录启发式 | 扩展名映射 | 括号配对 | 标 `unknown` | 通用 regex | Markdown 输出 |

共同点：包有边界、有源码集合、有注释/声明/测试/（可选）构建测试命令；差异全部由适配器回答。

---

## 2. 术语与口径对齐

| 用户用词 | 通用定义 | 落点 | 判据 |
| --- | --- | --- | --- |
| 包（package） | 可独立发布/构建的源码单元 | 见 §1 | 清单优先；容器目录不算单元 |
| 零仓库依赖 | 对被分析仓库零侵入 | — | 与"插件跑在 TREE 内"不矛盾 |
| 子包 | **按文件数与内聚度发现的逻辑单元**（README 只决定注入模式，见 D7） | `src/<module>/` 等 | 详见 §5 |
| 文档 | 包 README + 根 README + CHANGELOG + `docs/` | 与语言无关 | 仓库策略优先 |
| 追踪文件 | `git ls-files`（每仓/子模块分别取） | — | 未追踪不参与 |
| 更改 | `git diff` + 显式纳入的新文件 | — | **不看 `git status`** |
| 同步（全量/指定） | 全量 = 所有包各补缺章节；指定 = 只跑指定包 | — | 都不改写既有内容 |
| 规则源 | 规则包 > 仓库自述 > 内置空仓默认 | `rules/policy.json` | 空仓零配置可跑 |
| 文档契约 | 侦查出的仓库自身规矩 | `doc_contract` 集合 | 侦查不出标 `unknown` |
| 包功能收束 | 一句话功能 + 唯一入口 + 边界 ≥1 + 子包同形 | `pkg_index` | 见 D19 |
| 基线（baseline） | 一次建齐 L0+L1 的快照 | 默认 dry-run，`--commit` 落盘 | 产线开工资格（D24） |
| 建议文档 | 四类建议 | `suggestions` 集合 + `export` | 见 D9 / §4.4 |
| Token 估算 | `ceil(字符数 / token_scale)`；`context_cap` 与 `stage_budget` 分开 | 模型池口径 | 缺口径即失败 |
| 图谱 | GraphRAG（只文档建图） | `graph_*` 集合 | 见 §4.6 |

---

## 3. 流水线与安全边界

```text
scan → packages → contract → rules → dirty → plan → inject → generate → verify → state → commit/graph/audit
baseline   = scan+packages+contract+graph+补章节（默认 dry-run，--commit 才落盘）
reanalyze  = 只重算受影响包的 L0（包内文件全量），标 stale，可选补章节
```

| 命令 | 作用 | 依赖 |
| --- | --- | --- |
| `docnorm.baseline [--commit]` | 一次建齐 L0+L1；默认只出计划与 diff | git + storage |
| `docnorm.reanalyze --changed` | 只重算受影响包 | git + storage |
| `docnorm.contract` | 契约侦查 | git |
| `docnorm.audit` | 产四类建议 | L0 + storage |
| `docnorm.graph.build` | 重建链接图与 GraphRAG 索引（增量） | L0 + storage + LLM |
| `docnorm.query --mode local\|global\|basic` | 检索（给产线） | graph |
| `docnorm.check --edges` | 关联边检查 | graph |
| `docnorm.export` | JSONL 快照 | storage |
| `docnorm.commit [--run-gates]` | 分批提交（默认只列门禁命令） | git |

**安全边界（D30，硬性）**：

- **门禁命令默认只输出清单**（命令 + 工作目录 + 来源文件），不执行；`--run-gates` 才执行，并在执行前回显完整命令行。
- **规则包必须 pin commit + 校验和**（`--rules git-url@<sha>#sha256=…`）；未 pin 一律拒绝；**默认禁网**，联网需显式 `--allow-network`。
- `baseline` 默认 dry-run；`--commit` 才写盘并提交。
- 目标仓库视为不可信输入：**不执行其脚本/构建、不跟随符号链接出仓、不读 `.env`/密钥**。

不变式：① 写盘前必出条款差异（只允许 `added`，索引追加行除外）；② LLM 调用前必判 `context_cap` 与 `stage_budget`；③ 提交前先跑门禁（`--run-gates` 时），失败整批回滚；④ 产物只落在该仓追踪范围内（`export` 与建议导出除外）；⑤ 一次运行只作用于一个仓。

---

## 4. 语义冲突与默认口径（D1~D34）

| 编号 | 问题 | 默认口径 | 理由 |
| --- | --- | --- | --- |
| **D1** | 载体 | TREE 内 headless 插件 `tree.docnorm`（`requires: tree.storage` + `local_executor`）；对目标仓库零侵入；CLI 只是调试/CI 壳 | 依赖 TREE 是前提；零依赖只描述目标仓库 |
| **D2** | 模板来源 | 两套：模块类（职责/入口/约束/测试）与方案类（recon/scope/plan/acceptance/decisions）；模板只管新增章节形态 | 各仓风格差异大 |
| **D3** | CHANGELOG 口径 | 差异只允许 `added`；新增条款构成对外契约变化才入 CHANGELOG；不一致只报告 | 保住"只记行为变化" |
| **D4** | 补章节记账 | `doc_state`：`{addedSections[], codeFingerprint, updatedAt, stale}`；指纹用 git blob id 有序哈希 | 幂等、可复现 |
| **D5** | 预算（拆两个额度） | **`context_cap = min(配置, max_seqlen × 70%)`** 管单次调用（模型未配 seqlen 用兜底 128k）；**`stage_budget`** 管阶段累计（抽取/报告/检索各自独立）；两者分别报错、都不静默 | 400k 当"单次"会超 128k 模型上限、当"累计"又会卡死首建（450k）；必须分开 |
| **D6** | 注入模式 | 默认声明模式；测试默认仅断言；全代码仅当单次估计 ≤ `context_cap` 70% | 大包全代码必超限 |
| **D7** | 子包识别 | **按文件数与内聚度发现**（如目录内 ≥N 文件且被父 barrel/导出集中引用），README 只决定"注入 README 还是注入声明"；没有 README 也会被发现并生成建议 | 旧定义"自身带 README"是循环依赖，永远发现不了缺失文档的子包 |
| **D8** | 建议四类 | `reuse` / `split_size` / `split_function` / `api_boundary`；触发阈值全部读 `policy.json`（D31） | 四类对应四种动作 |
| **D9** | 建议落位 | `suggestions` 集合 + `export` 到 `.docnorm/export/suggestions/`（不进 `docs/`）；能被产线直接摄取 | 过程产物不升级为正式文档 |
| **D10** | 建议工具 | 内存工作区 `read/write/edit/submit`；`submit` 只落建议，不执行、不建任务、不提交 | 不落半成品 |
| **D11** | 自动分批提交 | 风格按 `git log` 探测；`git diff` 非空才入批；门禁默认只列不跑（D30）；不 push、不 amend、不跨仓 | 门禁命令可能不可信 |
| **D12** | 图谱方案 | GraphRAG，只文档建图；实体/关系与社区报告走 LLM 并缓存；检索 local/global/basic + 边检查 | 产线要查文档与关联边，不读代码 |
| **D13** | 体积度量 | 只算源码目录追踪文件；排除测试与生成文件；API 按 §1 口径 | 测试不计入 |
| **D14** | 包单元识别 | 清单优先；无清单用目录启发式；容器不单独成单元；monorepo 允许多适配器 | 多语言仓常见形态 |
| **D15** | 无解析器降级 | 注释模式 + 括号配对，标 `degraded` 并说明缺什么 | 不静默 |
| **D16** | 规范优先级 | 显式指定 > 仓库自述 > 内置默认（分层见 D17） | 不把默认强加给有规范的仓 |
| **D17** | 规则承载 | 三层规则源（规则包/仓库自述/空仓默认）；同层"更具体 wins"；覆盖写 `overriddenBy` | 规则必须可换 |
| **D18** | 有文档仓库起步 | 先 `contract` 侦查并入库，只侦查不改写；`unknown` 继续 | 认不清契约就会写崩 |
| **D19** | 包功能收束 | 一句话功能（≤60 字、动词开头、无并列逃逸词）+ 唯一入口 + 边界 ≥1 + 子包同形；阈值读 `policy.json`；**另标 `quality`（空/过短/过期）与 `stale`，只报告不硬写** | 防"有字就算收束"；质量必须可见 |
| **D20** | 建议状态单真源 | docnorm 只持建议事实（`kind/detail/plan/acceptance/risk`）与 `lastTaskId`；**任务状态唯一由产线持有**（`task.yaml`/产线库）；UI 组合展示、**不回写** | 双写必然不一致 |
| **D21** | 三层单向依赖 | L0 事实 → L1 文档 → L2 改造；产线不生成文档，docnorm 不执行改造；L2 后只标 `stale` | 破循环 |
| **D22** | 原文档不准确 | 文档是线索，L0 是准绳；冲突进 `conflicts[]`，不阻塞不修改 | 准确性风险收到 L0 |
| **D23** | 实施后"完整分析" | 只对受影响包做完整事实重算（包内文件全量），不全仓；不需产线参与 | 范围可控才可持续 |
| **D24** | 无基线怎么开工 | fail-closed：先 `baseline --commit`；没有 `pkg_index` 则产线拒绝进入实施阶段 | 不确定性挡在开工前 |
| **D25** | 产线怎么用图谱 | 只经 `docnorm.query` / `docnorm.check` 执行站命令；前端按钮走委派端点；不新增核心 REST。**产线 `requires` 需含 `tree.docnorm`，缺失即 fail-closed** | 执行站是插件间唯一通道 |
| **D26** | embeddings 与降级 | **本期默认上 embeddings**（模型池 `kind: embedding`），检索默认 `hybrid`（BM25 + 向量）；没有可用 embedding 时退 `entity linking + BM25 + 1~2 跳扩展`，结果显式标 `mode: lexical\|hybrid`，**不假装完整** | 用户拍板：上 embedding；但缺模型时不能被整块卡死 |
| **D27** | 存储 | 独立插件 `tree.storage`（Sembast、纯 Dart）；`requires` 关系；DB 真源 + `export` 快照 | 用户拍板；避免插件各造格式 |
| **D28** | 插件设置项 | **独立插件 `tree.settings`**（车道 K）：schema 注册 + 用户覆盖值存取 + `settings.changed` 广播；UI 通用渲染，核心不存值、不聚合；优先级 设置服务 > env > 插件 config > 默认；secret 只回 `has_value`；K 未落地前 docnorm 用 `.docnorm/config.json` + env | 预算/模型/开关要能改；用户拍板 D 方案“更干净” |
| **D29** | 索引与"字节不变"冲突 | 索引维护**只允许追加式插入**（新行插到末尾或对应分组末尾，不重排）；必须重排的文件列入 `rewrite_allowlist`，在报告里给完整 diff 并单独成一次提交 | DN-6 的"字节不变"与自动维护索引本来冲突，必须显式开例外 |
| **D30** | 安全边界 | 门禁命令默认只列不跑（`--run-gates`）；规则包 pin commit + sha256；默认禁网；`baseline` 默认 dry-run；不执行目标仓脚本、不跟随出仓链接、不读密钥 | 任意仓 = 不可信代码 / 供应链输入 |
| **D31** | 阈值配置化 | 体积/单文件/API 数/收束字数/检索 k/边检查阈值全部落 `policy.json`；引擎无硬编码 | 与"规则可换"一致 |
| **D32** | 跨文档口径统一 | 产线"不读代码"= **默认不读**；仅 `flags` 条目允许点状读取，**每会话 ≤ 8 个文件且计入上限**；产线 `requires: [tree.agent, tree.docnorm, local_executor]` | 消解与产线方案 §8.1 的冲突 |
| **D33** | 模型池按用途分类（含 JEV） | `kind: chat \| embedding \| decision`；`protocol: openai \| jev`；embedding 需 `dimensions` / `max_input_tokens`；decision（JEV）走 typed questions（`noul` / `choice` / `score`），返回选中项、概率分布、置信度。JEV 可由官方 API 或 OpenRouter/AIMLAPI 网关接入；**只用于决策点**（产线路由/重试/询问、docnorm 冲突分级），不得当 chat 用；置信度低于阈值 ⇒ 回退人工或 chat，并记录 `decision_mode` | 用户拍板：模型库增加 JEV 与 embedding；两类模型协议不同，必须先分类再选模型 |
| **D34** | 项目状态与工作日志维护 | **默认维护** `docs/project-status.md` 与 `docs/work-log.md`：已有则按**仓库既有规范**（路径/章节/表格列/索引）追加，不改写既有行、不重排；没有则用**内置模板**新建。`baseline` / `reanalyze --changed` 每写一次记一条（`run_id` 幂等）；`commit` 只回填该条提交号；`audit` 只读不写 | 让产线与人都能读到“最近一次归一化做了什么”；工具不替项目判断阶段与优先级 |

### 4.1 缺章节判定、质量与幂等

- **章节识别**：按 `policy.json` 的章节清单匹配标题（字面量/正则、级别可配）；空白与大小写归一。
- **缺失才写**：命中即 `skipped: 已存在`。**存在但空/过短/与代码明显不符 ⇒ 记 `quality: empty|thin|suspect` 与 `stale`，只报告，不修改**（D19/D22）。
- **冲突只报告**：进 `conflicts[]`，不写盘。
- **幂等**：同 `codeFingerprint` + 同策略版本重复运行 **0 写盘**。
- **索引追加**：只追加行；重排进 `rewrite_allowlist` 并给 diff（D29）。

### 4.2 规则分层（空仓默认 / 仓库自述 / 规则包）

```text
rules/
  policy.json   # 必需文档/章节、索引与链接规则、CHANGELOG 口径、阈值（D31）
  templates/    # 模块类 / 方案类
  checks/       # 可选检查命令（默认只列不跑）
  README.md     # 适用范围与版本
```

规则包带 `version`，可放 `.docnorm/rules/` 或 `--rules git-url@<sha>#sha256=…`（D30）；合成结果写 `rulesSources[]`。空仓默认只要求最小收束章节（功能/入口/边界/测试），不强制索引与 CHANGELOG。

### 4.3 包功能收束的产物与消费方

`docnorm.export` 后得到 `.docnorm/export/packages.json`（源为 `pkg_index` 集合）：

```json
{ "schema": 1, "packages": [{
  "id": "tree_core", "path": "packages/tree_core", "language": "dart",
  "oneLiner": "桌面核心进程：插件总线 / 服务端 / 存储 / 设置 / WS 的平台面",
  "entry": "lib/tree_core.dart",
  "boundaries": ["不实现 agent 领域逻辑（在插件）"],
  "subpackages": [{ "id": "plugin", "oneLiner": "…", "entry": "…" }],
  "apiCount": 56, "lines": 29574, "maxFileLines": 5912,
  "docs": { "readme": "README.md", "sections": ["职责","入口","边界","不变量（assertions）","测试"] },
  "flags": [], "quality": "ok" }]}
```

- **消费方**：**产线 P3 准备阶段**（不是 P1）以 L0 为主、L1 为线索；只对 `flags` 条目点状侦查（默认不读代码，例外见 D32）。
- **验收**：`oneLiner` 非空率 100% 且 `quality != empty|thin`、`entry` 唯一、`boundaries` ≥ 1；不满足只进建议。

### 4.4 建议 → 产线（状态单真源）

记录结构（`suggestions`；`export` 后可评审）：

```json
{ "schema": 1, "id": "sug-20261108-01",
  "kind": "reuse | split_size | split_function | api_boundary",
  "detail": "包 29 574 行 > 5 000；单文件 5 912 行 > 1 000",
  "repo": "desktop", "package": "packages/tree_core",
  "targets": ["…/plugin/plugin_bus.dart"],
  "evidence": ["…"], "confidence": 0.78, "risk": "medium",
  "plan": "…", "acceptance": ["dart analyze 0", "dart test packages/tree_core"],
  "lastTaskId": null }
```

**状态真源**：docnorm 侧**没有** `draft/queued/running/done`；只有建议事实 + `lastTaskId`。任务生命周期（queued/running/done/failed/rejected）**唯一**由产线的 `task.yaml` / 产线库持有；UI 列表 = 建议事实 + 任务状态**组合展示**，点击「执行」只调产线端点建任务并把 `lastTaskId` 回填给 docnorm（单向），**不回写任务状态**。

链路：docnorm 写 `suggestions` → 产线准备阶段读集合 → UI 渲染 + 单条「执行」→ 委派端点建任务（路径以 `/api/meta` 为准）→ 任务状态由产线回报。

### 4.5 三层模型与时序

| 层 | 内容 | 依赖 | 要 LLM | 触发 |
| --- | --- | --- | --- | --- |
| **L0 事实** | `pkg_index` / `graph_*` / `doc_contract`（均在 `tree.storage`） | git + 源码 | 否 | 人 / `baseline` / `reanalyze` |
| **L1 文档** | README 收束章节、索引、docs | L0 | 是（可选、惰性） | 同上 |
| **L2 改造** | 拆分 / 抽复用 / 收口 API 的产线任务 | L0 + L1 | 是（产线 LLM） | 前端「执行」 |

```text
① baseline --commit     建齐 L0+L1 并分批提交
② 产线准备（P3）        读 L0（主）+ L1（线索）；默认不读代码，flags 条目点状读取 ≤8 文件/会话
③ 产线实施              只改代码，不生成文档
④ reanalyze --changed   只重算受影响包，更新图边，补章节可选，提交
⑤ 回到 ②
```

判定：① 无 `pkg_index` ⇒ 产线拒绝进入实施（D24）；② L1 与 L0 冲突 ⇒ 以 L0 为准并记 `conflicts[]`；③ 未重算 ⇒ 标 `stale`，按"未知"处理。

### 4.6 GraphRAG on Dart

**结论**：可完整落地，不需要 Python / 向量库 / 原生依赖（语料只有文档，10²~10³ chunk）。但**依赖与评测仍需先验证**（P8）。

| 步骤 | Dart 实现 |
| --- | --- |
| 分块 | Markdown 标题切 section，段落合并 600~1 200 字符；token 计数注入 `estimateTokens` |
| 实体/关系抽取 | 每 chunk 一次 JSON 抽取，`chunkHash` 缓存；实体 `package/module/route/point/config/concept/decision`，关系 `belongs_to/references/implements/supersedes/conflicts_with/documents` |
| 图存储 | `graph_nodes` / `graph_edges` / `graph_chunks`（`tree.storage`） |
| 社区检测 | `yograph` 0.5.x 的 `Community.leiden(seed:)`；不引入则自写 Louvain（约 200 行） |
| 社区报告 | 每社区一份摘要，按成员集合哈希缓存 |
| 向量索引 | **默认启用** flat cosine（归一化点积），模型池 `kind: embedding`；没有可用 embedding 时跳过并标 `mode: lexical` |
| 检索 | 默认 `hybrid`：local（实体链接 → 1~2 跳 → BM25 叠加 cosine）/ global（BM25 选 5~10 报告再 reduce）/ basic（BM25 + cosine top-k）；无 embedding 时纯 BM25 |
| 关联边检查 | 断链 / 孤儿 / 过期引用 / 未解析提及 / 跨包引用 / 术语冲突 |

存储集合：`doc_contract` `doc_state` `pkg_index` `graph_chunks` `graph_nodes` `graph_edges` `graph_communities` `graph_reports` `graph_vectors` `suggestions` `checks`；`docnorm.export` 导出 `.docnorm/export/*.jsonl`。

**预算与成本**（两额度，D5）：单次调用受 `context_cap`（≤ max_seqlen×70%，兜底 128k）约束；**首建 450k 是 `stage_budget` 累计值**，由 300 次小调用分摊，不会被单次额度卡死。默认 `stage_budget` 400k（可配），本地模型下主要是时间成本；换模型后必须重新校准 `token_scale`。

**评测基线（P8，DN-10 验收前置）**：先定 **15~20 条 golden Q**（覆盖"怎么分层 / 改这个点位影响哪些文档 / 哪些引用没同步"），指标 `recall@k`（k=5/10）与边检查 precision；未达基线不得接入产线准备阶段。依赖核实项：`yograph` 与 `rag_kit` 的版本、许可证、Dart 3 兼容性（当前仅为口头断言）。

### 4.7 项目状态与工作日志（D34）

**默认维护两份项目文档**，路径由 `DocPolicy` 发现：

- **状态**：优先 `docs/project-status.md`；也接受仓库既有的 `STATUS.md` / `docs/status.md` 等带
  “当前阶段 / 车道 / 下一步”语义的文档；
- **日志**：优先 `docs/work-log.md`；也接受 `WORKLOG.md` / `DEVELOPMENT_LOG.md` 等。

**已有则按仓库规范**：先 `contract` 侦查章节与表格列；写时只**追加/回填**，不改写既有行、
不重排。侦查不出结构 ⇒ 不猜，改为在文末追加一个 `## docnorm` 段并在报告标 `unknown`。

**没有则用内置模板新建**（模板进 `policy.json/templates/project/`）：

- 状态模板：`# 项目状态` + `当前阶段` + `当前事项` 表（事项/状态/下一步）+ `变更记录` 表（日期/变更/依据）；
- 日志模板：`# Work Log` + 表（日期/事项/结论与关键数字/提交/原文档）。

写入规则：

| 事件 | 写什么 | 幂等键 |
| --- | --- | --- |
| `baseline` | 状态：新增/更新 `docnorm` 车道行；日志追加一行 | `run_id` |
| `reanalyze --changed` | 同上，只写受影响包 | `run_id` + fingerprint |
| `commit` | 回填该 run 日志行的“提交”列 | `run_id` |
| `audit` | 只读，不写 | — |

- 日志一行必须能独立读懂：事项、结论/关键数字、提交、原文档；不写“同步文档”这种空话。
- 状态只维护 `docnorm` 自己的车道/行，**不动其它车道的排序与内容**；没有车道结构时追加
  `## 文档归一化` 段。
- 两份文档的变更都走“索引追加行”规则（D29）；新建时同步 `docs/README.md`（若存在）。
- 冲突：人/产线同时写同一行 ⇒ 以 `run_id` 去重，后写者只追加不覆盖；内容冲突进 `conflicts[]`，
  不自动合并。
- 状态文档不是“项目阶段真源”：工具只描述“文档归一化最近做了什么”，阶段/优先级仍由人/产线维护。

---

## 5. 适配层接口

```text
LanguageAdapter {
  bool canHandle(repo)
  List<PackageUnit> packages(repo)          // 含 container 标记
  List<SubUnit> subpackages(PackageUnit)    // 文件数 × 内聚度（D7），README 只影响注入模式
  Comments comments(unit)                   // 文件 / 声明 / 摘要三粒度
  Declarations declarations(unit)
  List<Assertion> assertions(unit)
  ApiCount apiCount(unit)                   // 可返回 unknown
  Cmd? build(unit); Cmd? test(unit)
  String? docTool(unit)
  ApiSurface? apiSurface(repo)              // 可选：OpenAPI / .http 端点面（Web-HTTP 适配器实现）
}
```

`FallbackAdapter`：任意语言可跑，只保证启发式注释/声明与 `unknown` API，`degraded` 必为 true。

---

## 6. 首个被分析对象：本仓（示例证据）

| 包 | 源码行 | 最大单文件 | 导出符号 | 全代码 token 估计 |
| --- | --- | --- | --- | --- |
| `packages/tree_core` | 29 574 | 5 912 | 56 | ≈526 603 |
| `packages/tree_local_exec` | 8 127 | 1 568 | 18 | ≈138 708 |
| `packages/tree_protocol` | 1 956 | 563 | 14 | ≈35 780 |
| `packages/tree_agent` | 1 964 | 451 | 8 | ≈34 436 |
| `packages/tree_tunnel_protocol` | 491 | 239 | 3 | ≈8 660 |
| `plugins/tree.agent`（插件仓） | 28 969 | — | 93 个 lib 文件 | — |

结论：① 大包必然超单次额度 ⇒ 声明模式 + 分批是必需项；② **首个被分析对象必须覆盖 `plugins/`**（域插件体量与核心同量级，漏掉就会漏掉包收束）；③ 仓库自带文档门禁 ⇒ 必须走规则分层与契约侦查。

非 Dart 验证用 fixture 仓（`tool/doc/fixtures/{py,go,rust,ts,vue,http}`），只比计划与报告结构；
Vue fixture 覆盖 `script setup` 的 props/emits，HTTP fixture 覆盖 OpenAPI 与 `.http` 的端点抽取。

---

## 7. 切片（DN 系列）

| 切片 | 范围 | 验收 |
| --- | --- | --- |
| **DN-1** | 本侦查与语义对齐 | 本文档；D1~D34 默认口径已定，P1~P8 拍板记录（P8 基线执行前产出） |
| **DN-2** | 扫描 + 包图 + 适配层骨架 | **Dart / Python / Go / Rust / Node-TS（含 Vue 3 SFC）/ Web-HTTP（OpenAPI、`.http`）** 六族适配器 + fallback；fixture 验证包图、API 面与 `degraded` |
| **DN-3** | 契约侦查与规则源 | `doc_contract` + 三层规则合成 + `DocPolicy` 四条检查；空仓零配置可跑；本仓结果与 `docs_contract_test.dart` 6 条一致 |
| **DN-4** | 变更归集与计划 | `git diff` 归集、`plan --dry-run` 出注入单元与两额度估计；stat-dirty 不产计划 |
| **DN-5** | 注入与生成 | 三模式 × 三档；`context_cap` 闸；只追加缺章节；`degraded` 报告 |
| **DN-6** | 基线、落盘与校验 | `baseline`（默认 dry-run）/ `reanalyze --changed`；`doc_state`；索引追加式 + `rewrite_allowlist` diff；重复运行 0 写盘 |
| **DN-7** | 包功能收束与建议 | `pkg_index`（含 `quality`/`stale`）+ `suggestions`（四类）；阈值全读 `policy.json` |
| **DN-8** | 分批提交 + 基础链接图 | 风格探测；门禁默认只列（`--run-gates` 才跑）；三类确定性边 |
| **DN-9** | GraphRAG 索引 | 分块/抽取/Leiden/报告 + **默认 embedding 向量索引**落 `tree.storage`；重建幂等、增量只算变化 chunk、`export` 可 diff；无 embedding 时索引跳过并标 `mode: lexical` |
| **DN-10** | 检索与边检查 | `docnorm.query` / `docnorm.check`；`mode` 显式；**必须过 P8 的 golden set 才接入产线** |
| **DN-11** | 项目状态 / 工作日志维护 | 优先发现既有规范，缺失才用内置模板；`baseline`/`reanalyze` 追加、`commit` 回填、`run_id` 幂等；只维护 `docnorm` 自己的行，不改其它车道；验收见下表 |

依赖：DN-2→DN-3→DN-4→DN-5；DN-6 依赖 DN-3；DN-7 依赖 DN-2；DN-8 依赖 DN-4/DN-6；DN-9 依赖 DN-8；DN-10 依赖 DN-9 与 P8；**DN-11 依赖 DN-3 / DN-6，可与 DN-4 并行**。

DN-11 验收判据：

| 编号 | 判据 |
| --- | --- |
| TC-DN-01 | 已有 work-log 表：追加一行且列与既有表一致，既有行字节不变 |
| TC-DN-02 | 已有 project-status 车道表：只更新/新增 `docnorm` 行，其它车道内容与顺序不变 |
| TC-DN-03 | 两份文档都不存在：用内置模板新建，并同步 `docs/README.md` 索引（若存在） |
| TC-DN-04 | 同一 `run_id` 重复运行 ⇒ 0 写盘（日志不重复、状态不重复） |
| TC-DN-05 | 既有结构无法识别：不改写，文末追加 `## docnorm` 段并标 `unknown` |
| TC-DN-06 | `commit` 只回填该 run 的提交号，不新增行；`audit` 不写项目文档 |

**DN-2 实施记录（2026-11-08）**：`plugins/tree.docnorm` 已落地 headless 插件与执行站命令
`docnorm.scan`；六族适配器（Dart / Python / Go / Rust / Node-TS 含 Vue 3 SFC / Web-HTTP）
+ fallback 全部可跑；输出包图（包 id/root/行数/子包/公开声明/API 面/依赖/`depends_on`）
与 `degraded`。验证：插件自检 14/14、扫描单测 4/4、`build_plugins` 产物自检通过；
fixture 当前由测试内联临时目录生成，外部 fixture 仓随 DN-3 一起补齐。

**DN-3 实施记录（2026-11-08）**：`tree.docnorm` 新增两条执行站命令——`docnorm.contract`
（契约侦查：文档集合、章节、索引、链接、CHANGELOG 风格、静态门禁命令，门禁**只列不跑**）
与 `docnorm.check`（只回检查面）。实现：

- 三层规则源：内置空仓默认 → 仓库自述（`docnorm.yaml` / `docnorm.yml` /
  `.docnorm/policy.yaml|yml`，也允许用一层 `rules:` 包裹）→ 规则包；**规则包按 D30
  fail-closed**（pin+sha256 未实现，拒绝且不联网），输出里记 `unsupported`。
- 规则逐键合并并记来源：`rules.layers` / `rules.origins` / `rules.overridden` / `rules.repo_files`；
  未知键进 `warnings`，解析失败进 `warnings` 并标 `degraded`。
- `DocPolicy` 四条核心检查：`required_docs` / `required_sections`（原文子串匹配）/
  `index_complete`（目录直接子文件必须进索引）/ `links_resolvable`（跳过代码围栏与
  外部链接，支持 `link_fallbacks` 认迁移前的家）。仓库扩展两条：`module_readme`
  （模块 README + 模块地图）与 `mentions`（点名的真实符号）。
- 新增根 `docnorm.yaml`，把 `packages/tree_protocol/test/docs_contract_test.dart` 的判据
  落成声明式规则；两者同口径（该门禁现有 **7 条** test：入口文档 / 模块 README /
  docs 索引 / 归档索引 / tree_core 模块 / 提示词资产 / 相对链接；§7 原写"6 条"按实际
  测试数为准）。
- 验证：analyze 0、contract+scan 单测 9/9、插件自检 20/20、`build_plugins --only
  tree.docnorm` 产物自检通过；本仓契约 0 违规。`commit_style` 仍标 `unknown`
  （DN-8 才执行 git 探测）；`git ls-files` 收敛仍留 DN-4（当前按目录扫描 + 忽略构建产物）。

**DN-6 实施记录（2026-11-08）**：`tree.docnorm` 新增两条执行站命令
`docnorm.baseline [--commit]` 与 `docnorm.reanalyze --changed`，实现在
`plugins/tree.docnorm/lib/src/baseline.dart`：

- **默认 dry-run**：只出 `plan`（逐文件 diff / `skipped` / `rejected` /
  `rewrite_allowlist`）、缺口与 L0 状态；`--commit` 才写目标仓库并写入
  `tree.storage`。`written` 只记真实写盘，`would_write` 记计划。
- **只追加**：章节按 `sections: [{doc, heading, body}]` 追加到文末，已存在即
  `skipped`；索引按 `indexes: [{index, line, group?}]` 追加，`group` 命中时插到
  该分组末尾，既有行内容与顺序不变；整篇改写必须进 `rewrite_allowlist`，
  否则进 `rejected` 且不写盘（D29）。
- **`doc_state`**：`{addedSections[], codeFingerprint, updatedAt, stale}`，按文档
  （`#doc:<path>`）与包（`#pkg:<id>`）两条 key 落库；指纹用
  `git hash-object --stdin-paths` 取 blob id，再对有序 `path\tblob` 清单哈希（D4）。
- **`reanalyze --changed`**：变更用 `git diff --name-only HEAD` +
  `git ls-files --others --exclude-standard`（不读 `git status`），映射到最具体的
  已索引包并只重算这些包；没有 `pkg_index` 时 `baseline_required`（D24）；
  `changed=false` 时 `changed_required`，不做隐式全仓重扫。
- **ST-6 存储接入**：`plugin.json` 声明 `requires.plugins = [tree.storage]`；
  `doc_contract` / `pkg_index` / `doc_state` 经自建存储站 `storage.*` 读写；
  存储不可用、缺 `source_plugin_id` 或缺 `team_id` ⇒ `storage_unavailable`
  fail-closed，且发生在写任何目标仓库文件之前（TC-ST-10）。
- **幂等**：同一指纹 + 同一提案重复运行 **0 文件写 / 0 存储写**（`doc_state`
  比较忽略 `updatedAt`；`doc_contract` 在落盘后重算再入库，避免"新增标题导致
  下次重复写库"）。
- **边界**：L1 正文生成仍属 DN-5，本命令只接收提案并执行"只追加"落盘，不凭空
  写占位章节；提交批次与门禁执行仍属 DN-8。
- 验证：analyze 0、单测 15/15（baseline 6 条）、插件自检 35/0、
  `build_plugins --only tree.docnorm` 产物自检通过；`tree.storage` 29/29、
  协议仓 docs/plugin 契约 14/14。

**DN-4 实施记录（2026-11-09）**：`tree.docnorm` 新增只读命令 `docnorm.plan`，
实现在 `plugins/tree.docnorm/lib/src/plan.dart`：

- **变更归集**：`git diff --numstat --no-renames HEAD` + `git ls-files --others
  --exclude-standard`，只认内容差异；`0 0`（stat-dirty / mode-only）不产计划。
  `docnorm.reanalyze` 复用同一归集，不再用 `--name-only`。
- **注入单元**：按「最具体包 + 子包」归并；README 存在时默认 `readme` 模式，
  否则 `declarations`；测试文件走 `assertions`；显式 `full` 仅在
  `full <= full_code_limit` 时使用，否则降级并写 `reasons`。
- **两额度**：`context_cap = min(配置, model_max_seqlen × 70%)`（模型未配用兜底
  128k），`stage_budget` 默认 400k；配置优先级 `.docnorm/config.json` <
  `TREE_DOCNORM_*` 环境变量 < 调用方 `config` 覆盖。输出 `planned_tokens` /
  `batches` / `requires_chunking` / `within_context_cap` / `within_stage_budget`，
  两个额度分别报错，不静默裁剪。
- **估计口径**：字符数 / `token_scale`（默认 4）的启发式值；同一单元同时给
  full / readme / declarations / assertions 四种估计，接入模型池后再按真实 token
  校准。
- 验证：analyze 0、单测 19/19（plan 4 条）、插件自检 38/0、
  `build_plugins --only tree.docnorm` 产物自检通过；协议仓 docs/plugin 契约 14/14。

**DN-5 实施记录（2026-11-09）**：`tree.docnorm` 新增只读命令 `docnorm.generate`，
实现在 `plugins/tree.docnorm/lib/src/generate.dart`；`plan.dart` 抽出
`PlanContext` / `PlanUnit` / `loadPlanContext`，plan 与 generate 共用同一份
仓库 / 配置 / 扫描 / 变更归集 / 注入单元。

- **只补缺章节**：目标单元必须有 README；缺失章节 = `DocPolicy.requiredSections`
  命中该 README 的章节 − README 已存在的章节（无规则时用模块默认四节「职责 /
  入口 / 边界 / 测试」）；无 README ⇒ `readme_missing`、章节齐全 ⇒
  `sections_present`，两种情况 **0 次 `llm.call`**，且不凭空新建 README。
- **三模式 × 三档**：模式沿用 plan（`readme` / `declarations` / `assertions` /
  `full`，默认 `auto`），档位 `comments` / `declarations` / `full`（`tier` 可覆盖，
  默认由模式推导）；显式 `full` 超 `full_code_limit` 时降为 `readme` 并写 `reasons`。
- **`context_cap` 闸**：prompt 估计超限时先按 `full → declarations → comments`
  降档；仍超则按文件贪心分块；单文件仍超则丢弃（`reasons` 记「已丢弃」）并标
  `degraded`；`stage_budget` 累计，不足时停止后续调用并标 `exhausted`。
- **`llm.call` 接线**：经 tree.agent 宿主能力站发 `messages`（system + user），
  失败也带回已付费的 `text` / `json`（known-issues #31）；解析严格 JSON
  `{"sections":[{"heading","body"}]}`，只接受本次请求的缺失章节，额外标题 /
  空正文 / 过短正文进 `rejected`，失败或无 JSON ⇒ `degraded`，**不用占位内容补齐**。
- **输出**：`documents[]` 逐单元报告 mode / tier / missing / generated / rejected /
  calls / tokens / degraded；顶层 `sections[]`（`doc` / `heading` / `body` /
  `mode: append`）可直接作为 `docnorm.baseline` 的 `sections`。命令整体只读
  （`dry_run: true`），落盘仍由 baseline `--commit` 执行。
- **依赖**：`plugin.json` 增加 `requires.plugins: tree.agent (>=0.28.0)`（`llm.call`
  的提供方），版本升 `0.4.0`（pubspec / plugin.json / 插件常量同步）。
- 验证：analyze 0、单测 28/28（generate 9 条：缺章节生成、已存在 0 调用、
  无 README 跳过、额外标题/过短正文拒绝、LLM 失败与非法 JSON degraded、
  full 降档、按文件分块、单文件丢弃、stage_budget 停止）、插件自检 42/0、
  `build_plugins --only tree.docnorm` 产物自检通过；协议仓 docs/plugin 契约 14/14。

**DN-7 实施记录（2026-11-09）**：`tree.docnorm` 新增只读命令 `docnorm.audit
[--commit]`，实现在 `plugins/tree.docnorm/lib/src/audit.dart`，收束事实解析在
`lib/src/summary.dart`；全程确定性、**不调 LLM**。

- **阈值配置化（D31）**：`DocPolicy` 新增 `thresholds`，从仓库策略文件
  `thresholds:` 读取并覆盖内置默认（`package_lines 5000` / `file_lines 1000` /
  `api_count 20` / `declaration_count 60` / `subpackage_count 12` /
  `one_liner_chars 60` / `min_one_liner_chars 8`）；未知键进 `warnings`，非法值
  fail-closed。
- **包功能收束（D19）**：从 README 确定性解析「职责 / 入口 / 边界」三节 →
  `one_liner` / `entry` / `boundaries`；`quality = empty | thin | suspect | ok`
  （缺职责或空 → empty；一句话过短 / 缺入口或边界 → thin；一句话超长 → suspect）。
  体积只算源码追踪文件，**排除测试与清单 / 配置**（D13）。只报告，不改写 README。
- **`pkg_index` 补全**：`baseline` / `reanalyze` 写入的包记录新增
  `summary` / `quality` / `stale`；`audit` 合并既有记录后补写同一批字段，
  `stale = doc_state.codeFingerprint != 当前代码指纹`（指纹与 baseline 同口径）。
- **四类建议（D8/§4.4）**：`split_size`（包行数或单文件超阈值）、
  `split_function`（公开声明数或子包数超阈值）、`api_boundary`（API 端点超阈值）、
  `reuse`（跨包同名导出，符号级、不走向量，P4 只报线索）。每条含
  `kind/detail/package/targets/evidence/confidence/risk/plan/acceptance/lastTaskId`，
  id 为稳定 FNV 短哈希；只写 `suggestions` 集合，**不建任务、不执行改造**（D20）。
- **安全与幂等**：默认 dry-run，`commit` 才写 `suggestions` / `pkg_index`；同一事实
  重复运行 **0 写**；保留已有 `lastTaskId`，删掉本次不再生成的建议；缺基线时
  `baseline_required: true` 但仍可出建议。
- 验证：analyze 0、单测 32/32（audit 4 条：收束事实与 quality、四类建议、commit
  幂等、stale）、插件自检 48/0、`build_plugins --only tree.docnorm` 产物自检通过；
  协议仓 docs/plugin 契约 14/14。

**外部前置（不属切片）**：`tree.storage` 插件（DN-4 前）；`tree.docnorm` 插件骨架（DN-9 前）；**`tree.settings` 插件（车道 K，可选：没有它时 docnorm 用 `.docnorm/config.json` + env）**；**模型池扩展**（`kind` / `protocol` / `dimensions`，含 embedding 与 JEV，D33；DN-9 前）；产线 `requires` 补 `tree.docnorm`（D25/D32）。

---

## 8. 拍板记录（2026-11-08；未列项按默认）

| # | 问题 | 结论 | 影响 |
| --- | --- | --- | --- |
| P1 | 首批适配器 | **Dart + Python + Go + Rust + Node/TS（含 Vue 3 SFC）+ Web/HTTP（OpenAPI/.http）** | DN-2 工作量与 fixture 仓 |
| P2 | 建议落位 | `suggestions` 集合 + `export` 导出 | 产线读取路径 |
| P3 | 社区检测与向量 | 引 `yograph`；**本期上 embeddings，检索默认 `hybrid`** | DN-9/10 与模型池 `kind: embedding` |
| P4 | 复用识别向量化 | **本期不上**；符号级 + LLM 核实，已记 [known-issues #45](known-issues.md) | 召回率有上限，不产生误报 |
| P5 | 既有条款与代码不一致 | 只报告不修改（`conflicts[]`） | 只增不改边界 |
| P6 | 目录约定 | `.docnorm/`（`config.json` + `export/`）；其余在 `tree.storage` | gitignore |
| P7 | 规则包形态 | 先内置空仓默认；`--rules` 支持本地与 pin 的 git 源 | DN-3 工作量 |
| P8 | GraphRAG 评测基线 | 先定 15~20 条 golden Q（`recall@k` + 边检查 precision），并核实 `yograph`/`rag_kit` 版本、许可证、Dart 3 兼容 | DN-10 能否接入产线 |

---

## 9. 跨文档待同步（产出后必须同步，否则两处口径漂移）

1. **产线方案 D1**：`requires: [tree.agent, tree.docnorm, local_executor]`；缺 `tree.docnorm` 时准备阶段 fail-closed（D25/D32）。**已同步**（产线 §1.5 / §10.1 / §14-D1）。
2. **产线方案 §8.1**：文件读取口径改为"**默认不读；仅 `flags` 条目点状读取，≤ 8 文件/会话**"（D32）。**已同步**（产线 §8.1 / TC-PL-14）。
3. **产线方案 P0 出口**：P0 = DN-3 + DN-6；**DN-7/DN-9/DN-10 是 P3 前置**，不进 P1（§0.10 / §4.3）。**已同步**（产线 §11 / TC-PL-13）。
