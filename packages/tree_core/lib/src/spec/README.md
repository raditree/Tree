# spec（任务型规范）

把任务经验沉淀成可复用的规范：内置模板内嵌并播种到工作空间，索引注入系统提示词，选中即拿全文。

## 文件

| 文件 | 作用 |
| --- | --- |
| [builtin_specs.dart](builtin_specs.dart) | 内置模板与四条模板共享的第 0 步（内嵌常量） |
| [builtin_spec_assets.dart](builtin_spec_assets.dart) | 选中内置规范时，把它引用的**随附文档**播种到工作空间 |
| [spec_service.dart](spec_service.dart) | 索引（扫文件）、`select` / `create` / `update`、播种与备份刷新 |

## 不变量（assertions）

1. **索引前置**：索引直接注入系统提示词，因此 `search` / `list` / `read` 三个动作被删除，`select` **直接返回全文**——省掉"select 之前必须先 read"的两轮调用（模型还常常漏一步）。
2. **索引不是索引库**：扫工作空间 `.self/spec/*.md`。单用户桌面下文件数量是几十个量级，扫描比维护索引更简单，也不会出现"文件在、索引缺"的不一致。
3. **内置模板内嵌为常量**：核心要 `dart compile exe` 成单文件，运行时按相对路径找 `assets/` 在打包后非常脆弱（工作目录、安装位置都可能变）。首次进入某工作空间时播种到 `.self/spec/`；副本由**核心维护**（升级先备份成 `.bak.<n>` 再刷新）；内置**只能读不能改**，要定制就 `spec create` 另存一份。
4. 四条模板共享同一段**第 0 步**（动手前先跟用户对齐语义）——做成共享常量而不是抄进每条正文，否则改三处漏一处。
5. `plugin-creator` 规范有**副作用**：选中它时由核心把插件开发指南原件播种到 `.self/docs/plugin-development.md`（工作空间类工具读不到应用目录 / 仓库里的原件，而正文里那句"读指南"就执行不了）。原则是**文档只有一份真相源**：模板是内嵌常量、随附文档是磁盘原件，核心只负责搬运；原件缺失时如实回报 `action: missing` + **探过的目录**，由规范正文的兜底流程接住（向用户索取原件），不静默、不假装成功。
6. 播种路径 [plugin_guide.dart](../plugin/plugin_guide.dart) 的 `kPluginGuideWorkspacePath` 与前端 `PluginDocs` 认的**专有文件名**必须一致（它不用泛化的 `README.md`，避免把用户送到一份无关文档上）。

## 测试

```bash
cd packages/tree_core
dart test test/spec_service_test.dart test/specs_api_test.dart test/plugin_guide_seed_test.dart
```
