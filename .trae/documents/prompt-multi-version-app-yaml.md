# 提示词体系多版本支持 —— app.yaml 选择激活版本

## 概述

为现有集中式、版本化的提示词体系（`server/prompt` 包）建立**多版本选择机制**：
未来可在若干「版本打包目录」中登记多个版本的提示词内容，并通过
`server/configs/app.yaml` 的 `prompt.version` 指定**当前激活版本**。

本次交付范围（已与用户多轮确认）：
- **覆盖全部提示词产物**：系统提示词 13 章（静态头 + 静态尾）、上下文压缩器、
  以及内置 / MCP 工具描述。
- **仅登记 v1.0.0**：把现有内容迁移登记为 v1.0.0，建好多版本机制，未来新增版本只需
  新增数据目录 + 一行登记。
- **版本内容存数据文件目录**（用户选定）：`server/prompt/versions/<version>/` 下按
  章节/Markdown、工具/YAML、压缩器/Markdown 组织，内容与代码解耦，可直接 diff /
  Code Review / 回滚。

## 现状分析

- [registry.py](server/prompt/registry.py)：硬编码单一 `PROMPT_VERSION = "1.0.0"`；
  `audit_header()` 用常量生成审计头。
- [system_chapters.py](server/prompt/system_chapters.py)：模块级 `Chapter` 常量承载全部
  静态章节内容（`SYSTEM_STATIC_CHAPTERS` / `SYSTEM_STATIC_TAIL_CHAPTERS`），内容内嵌在代码。
- [llm_prompts.py](server/prompt/llm_prompts.py)：`context_compressor_prompt(raw)` 内嵌在代码。
- [tool_protocol.py](server/prompt/tool_protocol.py)：`describe()` 模板 + 仅审计用 `TOOL_MANIFEST`；
  **工具实际描述是 tool/mcp 各文件里的硬编码字符串**，未接入版本体系。
- [tool/*.py](server/tool/) 与 [mcp_tools/*.py](server/mcp_tools/)：`get_tool_definition()`
  内联长 description 文本（如 [read_tool.py](server/tool/read_tool.py#L84-L94)）。
- [document_server.py](server/mcp_tools/document_server.py)：`TOOLS` 列表内联各文档工具描述。
- [embed_search_tool.py](server/mcp_tools/embed_search_tool.py)：描述分 `has_embed` 两分支。
- [config.py](server/config/config.py)：`get_config()` 读 `configs/app.yaml`（带缓存）。
- [chat.py](server/agent/chat.py)：直接 import `audit_header` / `SYSTEM_STATIC_CHAPTERS` /
  `SYSTEM_STATIC_TAIL_CHAPTERS`。
- [llm.py](server/llm/llm.py)：`from prompt.llm_prompts import context_compressor_prompt`。
- 测试 [test_fix_noop_tools.py](server/tests/test_fix_noop_tools.py#L335)：`from prompt.system_chapters
  import WARNING_ACCOUNTABILITY`，且断言 `_build_agent_system_prompt` 含审计头/章节编号。

关键结论：
1. 版本选择层应**惰性**读 `get_config()`，不在 import 期耦合 `config`。
2. 内容迁到数据目录后，`chat.py`/`llm.py`/各工具从「激活版本加载器」取内容，
   调用代码保持版本无关。
3. 需兼容/更新既有测试对 `prompt.system_chapters` 行为（迁移后该模块角色变化）。

## 方案设计

### 目标数据目录布局

```
server/prompt/
  schema.py              # 不变：Chapter 数据类（元数据 + markdown 正文）
  registry.py            # 版本/审计工具：chapter_manifest、audit_header（按激活版章节目录）
  loader.py              # 新增：读取 versions/<version>/ 目录 → PromptVersion
  versions.py            # 新增：版本选择层（读配置→激活版本，缓存，fail-fast）
  tool_protocol.py       # 保留 describe()/mcp_tool_description()/TOOL_MANIFEST（构建描述用）
  versions/
    1.0.0/
      meta.yaml          # 版本元数据：version / date / scope / changelog
      chapters/
        authority.md
        task-paradigm.md
        security-boundary.md
        tool-routing.md
        spec-maintenance.md
        todo-discipline.md
        warning-accountability.md
      compressor.md      # 上下文压缩器模板（含 {raw} 占位）
      tools/
        builtin.yaml     # 系统内置工具描述（read/write/edit/...）
        mcp.yaml         # MCP 工具描述（document/embed_search）
```

### 1. app.yaml 新增 `prompt` 配置段

文件：`server/configs/app.yaml`

```yaml
# 提示词体系多版本选择（见 server/prompt/versions.py；内容在 server/prompt/versions/ 下）
prompt:
  version: "1.0.0"
```

### 2. 新增 `prompt/versions.py` —— 版本选择层

- `active_version()`：惰性 `config.config.get_config()` → `config["prompt"]["version"]`
  （默认 `"1.0.0"`），解析结果缓存。
- `get_version(version) -> PromptVersion`：委托 `loader.load_version(version)`；已加载则
  用缓存；目录不存在/版本未登记则 `raise`（fail-fast，杜绝静默回滚）。
- 激活解析器（对 chat.py / llm.py / 各工具的公共入口）：
  - `active_system_head()` / `active_system_tail()` → `Tuple[Chapter, ...]`
  - `active_compressor(raw)` → 压缩提示词
  - `active_tool_description(name)` → 工具描述
- `PromptVersion`（frozen dataclass，放 `schema.py`）：`version`、`system_head`、
  `system_tail`、`compressor`（模板函数）、`tool_descriptions: Dict[str, str]`、
  `meta`、`changelog`。

### 3. 新增 `prompt/loader.py` —— 数据目录加载器

- `load_version(version) -> PromptVersion`：读取 `versions/<version>/`：
  - `chapters/*.md`：解析 YAML front-matter（`id/title/version/level/description`）+
    markdown 正文 → `Chapter`；`level` 字符串映射到 `LEVEL_CORE/GUARDRAIL/OPS`。
    按文件名序号（`01_`…`07_`）或 front-matter 排序决定静态头/尾归属：
    头 4 章（authority/task-paradigm/security-boundary/tool-routing）、尾 3 章
    （spec-maintenance/todo-discipline/warning-accountability），并在 `meta.yaml` 里
    用 `head_ids`/`tail_ids` 显式声明，避免依赖两处硬编码。
  - `compressor.md`：读模板，`{raw}` 占位替换为调用参数。
  - `tools/builtin.yaml` / `tools/mcp.yaml`：`{name: {version, description}}` →
    `tool_descriptions[name] = description`。
  - `meta.yaml`：`version/date/scope/changelog`，供审计与 `SYSTEM_PROMPT_CHANGELOG` 动态拼装。
- 使用 `import yaml`；目录缺失时抛 `FileNotFoundError` 带版本号，交由 `versions.py` 转成
  "版本未登记"错误。

### 4. 新建版本内容数据 —— `versions/1.0.0/`

将当前**代码内嵌内容**迁移为数据文件（默认 `prompt.version=1.0.0` 行为与现状完全一致）：

- `meta.yaml`：版本 `1.0.0` / date `2026-08-23` / scope `system|tool|compressor` /
  changelog（沿用现有 `SYSTEM_PROMPT_CHANGELOG` 条目）。
- `chapters/*.md`：把 [system_chapters.py](server/prompt/system_chapters.py) 中 7 个
  `Chapter` 的 `title/version/level/description/content` 原样落盘。
- `compressor.md`：把 [llm_prompts.py](server/prompt/llm_prompts.py) 的
  `context_compressor_prompt` 文本落盘（`历史对话：\n{raw}` 处用 `{raw}`）。
- `tools/builtin.yaml`：迁移 `tool/*.py` 的 9 个描述（read/write/edit/terminal/mcp/team/
  set_todo_list/ask_user_question/spec）。
- `tools/mcp.yaml`：迁移 `mcp_tools/*.py` 的描述（document_server 全部 + embed_search 两个分支）。

### 5. 改造消费方 —— 从激活版本取内容

- [chat.py](server/agent/chat.py)：删除对 `prompt.system_chapters`/`registry` 的直接 import；
  `from prompt import versions`；`_build_agent_system_prompt` 内用
  `versions.active_system_head()/active_system_tail()/active_version()`（审计头）。
- [llm.py](server/llm/llm.py)：删除 `from prompt.llm_prompts import context_compressor_prompt`；
  压缩处改 `versions.active_compressor(raw)`。
- 内置工具 [tool/*.py](server/tool/)：`get_tool_definition()` 的 `description` 改为
  `versions.active_tool_description("<name>")`（参数 schema 等结构代码保留）。
- [document_server.py](server/mcp_tools/document_server.py)：各 `TOOLS[i]["description"]` 改为
  `versions.active_tool_description("<name>")`。
- [embed_search_tool.py](server/mcp_tools/embed_search_tool.py)：按 `has_embed` 选
  `active_tool_description("embed_search.embed")` /
  `active_tool_description("embed_search.grep")`（数据文件里两分支分别登记）。

### 6. registry 兼容性

- 保留 `audit_header()`/`chapter_manifest()` 对外符号，内部按激活版本的
  head+tail 章节目录生成，版本号取 `active_version()`。
- `PROMPT_VERSION/TOOL_TEMPLATE_VERSION/COMPRESSOR_VERSION` 保留为 "v1.0.0 基线"语义，
  更新注释说明运行版本以配置为准。

### 7. `prompt` 包 `__init__.py`

- 保留既有导出（`PROMPT_VERSION`/`audit_header`/`chapter_manifest`/`Chapter`）。
- 追加导出 `versions`、`loader` 供消费方使用。

### 8. 测试更新与新增

- 既有 [test_fix_noop_tools.py](server/tests/test_fix_noop_tools.py#L335)：把
  `from prompt.system_chapters import WARNING_ACCOUNTABILITY` 改为从 loader 读取 v1.0.0
  章节（或直接断言 `_build_agent_system_prompt` 输出的审计头/编号仍成立）。
- 新增 `server/tests/test_prompt_versions.py`：
  - `active_version()=="1.0.0"`；
  - head=4 / tail=3，且 id 与 `meta.yaml` 的 `head_ids/tail_ids` 一致；
  - `active_tool_description("read")` 含模板字段（"何时使用"）；
  - `active_compressor("x")` 含 "历史对话"、"x"；
  - 未登记版本（如 `9.9.9`）触发 `raise`。

## 假设与决策

- 配置放顶层 `prompt.version`（与 LLM 调用行为正交，不用 `llm` 段）。
- 未登记版本 fail-fast `raise`，不做静默回退。
- 版本选择层惰性导入 `config`，避免 import 期耦合/循环依赖。
- 描述文本迁数据后，`get_tool_definition` 只保留参数 schema 结构，description 全部来自
  激活版本数据。
- `DYNAMIC_CHAPTERS`（身份/memory/spec 索引等运行时注入章节）不纳入版本切换，仍由
  chat.py 现算。
- `tool/spec/builtin/*.md` 属 Spec 数据（已有版本元数据），不随激活版本切换。
- 迁移不改 v1.0.0 任何实际文本，保证默认配置行为与重构前一致。

## 验证步骤

1. 编译检查：`python -m py_compile` 覆盖 `prompt/`、`agent/chat.py`、`llm/llm.py`、
   `tool/*.py`、`mcp_tools/*.py`。
2. `python -m unittest tests.test_fix_noop_tools -v`：既有 20 用例全绿。
3. `python -m unittest tests.test_prompt_versions -v`：新增版本选择用例全绿。
4. 手工抽查：默认配置下 `active_tool_description("read")` 与 .yaml 内容一致；
   把 app.yaml 改为 `9.9.9` 后 `active_version()` 应 `raise`（验证后还原为 `1.0.0`）。

## 影响范围

- 新增：`server/prompt/loader.py`、`server/prompt/versions.py`、
  `server/prompt/versions/1.0.0/`（meta.yaml + chapters/*.md + compressor.md + tools/*.yaml）、
  `server/tests/test_prompt_versions.py`。
- 修改：`server/configs/app.yaml`、`server/prompt/__init__.py`、`server/prompt/registry.py`、
  `server/prompt/tool_protocol.py`、`server/agent/chat.py`、`server/llm/llm.py`、
  `server/tool/*.py`、`server/mcp_tools/document_server.py`、
  `server/mcp_tools/embed_search_tool.py`、`server/tests/test_fix_noop_tools.py`。
- 移除/降级：`server/prompt/system_chapters.py`、`server/prompt/llm_prompts.py` 的内容
  迁入数据目录后改为 thin 暴露（或删除并同步更新引用/测试）；`DYNAMIC_CHAPTERS` 保留。