# M9 计划：14 项修复与优化（语义对齐定稿）

> 落盘时间：本轮对齐完成后。**本文件是 M9 唯一事实源**，实现/评审/回溯都以它为准。
> 上游语义来源：用户逐条确认（Q1–Q13 + 全局规约），旧后端实现见第 6 节索引。

## 0. 基线与环境

| 项 | 值 |
|---|---|
| 工作树 | `E:\programs\Tree\desktop`（分支 `desktop`） |
| 基线 HEAD | `11e1376`（M8 收口）；M9 计划落盘后为 `f6f1567` |
| Dart SDK | `D:\app\flutter-sdk-3.47.5\flutter\bin\cache\dart-sdk\bin\dart.exe` |
| Flutter | `D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat` |
| 包结构 | `packages/tree_protocol`、`packages/tree_local_exec`、`packages/tree_core`、`packages/tree_core_cli`；前端 `lib/`；原生 `windows/runner/` |
| 验证 | `dart analyze packages`、`flutter analyze`（app 根）；测试 `dart test`（各包）、`flutter test`（app） |

**纪律**：禁止裸 `dart`/`flutter`（PATH 上是旧 SDK）；禁止对整目录 `dart format`（会重排无关文件），只格式化改动文件；不改与本次无关的文件。

---

## 1. 全局规约（M9 新增，所有子系统适用）

### 1.1 取消“静态时间”超时，改“心跳丢失”判超时
**口径**（用户澄清，2026 修订）：静态时间超时**全部取消**（跑到多久都不因时间失败）；但**仍然要超时**——判据换成**心跳丢失**。用户原话：「还是要超时，只是都不依赖静态时间，全部改成心跳丢了判超时（我主要是怕心跳还在、但总时间超了仍判超时被丢掉）」。

两个参数（**用户已确认默认值**）：
- 心跳间隔 **I = 10s**（好心跳的节奏）；
- 丢失阈值 **N = 3**（连续 N 次未成功收到心跳即判「心跳丢失」）；
- 落地形态：本波次先做成**代码常量 + 中文注释**（Dart 侧可被 settings 覆盖的常量），设置页可调列入 Wave 3 设置项。
- 本地执行体活性 = **进程存活**（用户已确认）：活着永不超时，不拿时间当判据。

判据 = **活性窗口 I×N 内没有任何心跳** ⇒ 判超时。**不是**任务总时长上限：心跳还在的任务永远不超时。

| 对象 | M9 口径 |
|---|---|
| 工具调用 | 无静态上限；执行端心跳丢失 ⇒ 该次工具调用以显式「心跳丢失」失败（不静默丢弃） |
| `terminal` | 无静态上限；心跳丢失 ⇒ **软超时**：不杀进程，转 hook 模式后台执行并返回查询/续看方式 |
| 消息发送（WS / team dispatch） | 无静态上限；连接心跳丢失 ⇒ 判超时，走重连补发（不静默丢消息） |
| 执行器命令（local/ssh RPC） | 无静态上限；执行器心跳丢失 ⇒ 判超时并以显式错误失败，触发重连 |
| 插件宿主（stdio 通道） | 无静态上限；连续 N 次心跳丢失 ⇒ 标记 degraded + 前端可见，可重连/重启（用户可见，不静默） |
| MCP 客户端 | 无静态上限；MCP ping 心跳丢失 ⇒ 判超时并报错 |
| LLM 传输 | 建连保留短超时（否则无法诊断）；流式读取**无总时长上限**，收到任意字节即刷新心跳，空闲心跳丢失才判超时 |
| 本地执行体（进程/命令） | 活性 = **进程存活**（OS 层）：进程活着永不超时；进程消失按正常退出处理 |

统一心跳形态：`heartbeat{scope, seq, ts}` ⇒ `heartbeat_ack`；同时记录**最近心跳时间**与**连续丢失计数**，供上层重连决策与 UI 显示；丢失必须显式报错，不得静默。

### 1.2 站点隔离矩阵（优化 3 的硬要求）
所有站点消息（广播站广播、执行站命令、中转站回填）必须携带并校验 **四元组 scope**：

```
(team_id, agent_id, session_id, mode_key)   // mode_key ∈ {local, ssh}
```

- 广播/订阅、命令投递、回填一律 **scope 精确匹配**，跨 scope 不投递（fail-closed）；
- 订阅可声明"更细粒度"（如只订阅某 agent），但**不得放大**到其他 team；
- `mode_key` 必须区分 local 与 ssh：否则 SSH 团队的插件命令会打到本地工作空间。

### 1.3 token 口径统一
- 全局唯一换算：`tokens = ceil(字符数 / token_scale)`，`token_scale` **逐模型**存 `models/<model_id>.yaml`，初值 **2.00**（两位小数）；
- 估算点：上下文进度、压缩阈值、超长工具结果门控、token rate 节流、工具调用参数计量 —— **全部走同一个函数**；
- 学习：端点回真实 `prompt_tokens` 且**超过**该模型 `longest_session_tokens` 时，刷新记录并令
  `token_scale = 该次请求上下文字符数 / 真实 prompt_tokens`（保留 2 位）写回 yaml；无 usage 的端点只读不写。
- 长会话更准的原因：系统提示词/工具声明等**固定开销不随字符增长**，短会话 chars/token 偏小，长会话才逼近内容真实比值。

---

## 2. 逐项定稿

### Q1 上下文超限未压缩（含超长工具结果门控）
**根因**：压缩只在每轮生成前跑一次；模型未登记时 `max_seqlen` 兜 128000；工具循环内只有按 user 边界的**硬裁**（丢弃）；端点报超限后不压缩、不重试。
**旧实现**（必须照旧）：
1. **工具结果门控**：超过阈值 → 完整结果写 `.self/results/<ts>_<seq>.<工具名>.result`，回灌模型的只有提示（字符数 + 路径 + "用 read 分段读 / 用 terminal 解析" + 前 300 字符预览）；写失败退化为截断。
2. **工具循环内压缩**：旧 `llm.py` 在 tool 循环**每一轮 API 调用前**调 `_compress_context()`。
**M9 口径**：
- 门控阈值改**按 token 估算**：默认 **8,000 token**（≈16k 字符 @2.00），预览 300 字符，落点 `.self/results/`；
- **落库/界面留全文，只有"送给模型的那一份"替换为提示**；每次构造上下文都过一遍门控（历史重载同样生效）；
- `max_seqlen` 取不到时**不再默默兜 128000**：提示用户去补模型配置，并在日志与状态栏可见；
- 轮内压缩：每轮 API 调用前检查并压缩；
- 端点返回上下文超限错误时：**自动压缩一次并重试该轮**（仅一次，失败则如实报错）；
- 压缩失败必须**可见**（现在只记日志）。

### Q2 删除 cloud 模式
前端 `mode_switch.dart` 三态 → 两态（local/ssh），删除 `message_panel.dart` 里 `'cloud'` 分支；**默认 local** 并自动注册本地执行器（切 team 同样落 local）。

### Q3 思考卡片聚合 / 最终输出移位 / 中间输出消失
**根因**：`conversation_service.dart` 两个 `??=`（一轮只建一条 text + 一条 thinking）；落库同毫秒时间戳导致重载顺序漂移。
**旧实现（照旧）** `server/agent/chat.py:1984-2210`：
- thinking 段：独立 id，**遇 text / tool_call / ask_paused 关闭**（`msg_end` + 落库 `kind='thinking'`）；
- text 段：**遇 tool_call 关闭**，中间文本段**独立成消息并落库**（不带 usage）；
- tool_call：先关 thinking + text，再发 `tool_start`/`tool_end` 并落库（同 id）；
- 最终回复用整轮全文，usage 只挂最后一条。
**M9 追加**：落库顺序保留**单调序号**（消除毫秒同值漂移），历史重载顺序与事件顺序严格一致。

### Q4 远端不支持 Git
**旧实现（照旧）**：SSH 执行器用 **exec 通道**跑
`cd <ws> && git log --pretty=format:%H%x09%an%x09%ad%x09%s --date=iso -n N` 与 `git branch -a`，解析为 `{commits:[{hash,author,date,message}]}` / `{branches,current,exit_code}`。
**M9**：`tree_local_exec` SSH 侧加 exec 通道 + `gitLog`/`gitBranches` 两个 op（本地侧复用已有实现）；非仓库/无 git → 空列表 + exit_code，面板显示空而非 400。

### Q5 多文件粘贴（对话页输入框）
**口径**：Windows 剪贴板一次只有一张位图，多图只能经**文件列表**进来 → 统一做 **CF_HDROP 多文件优先于文本**（不止图片），多选文件 Ctrl+V → 多个附件。需要原生侧（`windows/runner/`）读 CF_HDROP 返回路径列表。

### Q6 输入框草稿按 team+session 缓存
文本 + 附件列表**一起**按 `team+session` 缓存（**纯内存**）；切换 team/session 恢复对应缓存（无则空）；**发送成功后清空该键缓存**。

### Q7 下载列表"打开文件所在位置"
每个任务行加动作：Windows 用 `explorer /select,"<path>"`；**文件夹任务定位到 tar.gz 压缩包本身**；文件已被移动/删除 → 提示而非静默失败。

### Q8 工具轮次上限
**删除** `LlmSession.maxToolTurns` 上限（无限制）。限制能力交给插件：插件可监视轮次，超限经**执行站的 `agent.stop`** 发停止信号。

### Q9 spec 工具瘦身 + 索引前置
- `spec` 只保留 **`select` / `create` / `update`**：`select` **直接返回所选 Spec 全文**（删除"先 read 再 select"约束、删除 `search`、删除 `list`）；
- 索引**注入系统提示词**，格式照旧 `- \`id\` [task_type] 标题（内置）（适用: when 摘要）`；默认**全列**，>50 条截断并注明"其余可用 `spec select` 直取（需已知 id）"；
- 内置 4（easy-task / complex-task / hard-task / team-meeting）只读。

### Q10 grep 无匹配时列出扫描文件
无匹配时工具结果返回：**扫描文件清单（上限 200，超出注明总数）** + **生效的排除目录清单** + 扫描根，帮助模型区分"真没有"与"被误排除"。

### Q11 站点体系（三站）
见第 3 节。

### Q12 插件布局
槽位：**左侧活动栏项 + 右栏 Tab + 状态栏 + 消息流内联卡片**；走**已有 WS 帧**；**允许插件注入消息流卡片**。UI 槽位走**独立通道**（manifest 声明 + WS 帧推 UI 描述），**不经三站**（三站只管数据面）。

### Q13 token rate 管道（口径统一）
- **工具调用参数**（`tool_start` 卡片 JSON）：按 `字符数 / token_scale` 折算 token，走**与思考同一条 token rate 管道**排队推送 → `write` 这类大参数调用自然产生等待，`read` 几乎不等待；
- **工具结果**（`tool_end`）：**直接推**，不延迟；
- 推完结果 → 进入下一轮 API 调用；
- 思考 / 正文 / 工具参数 全走一条管道 ⇒ 速率口径统一，UI 一条曲线。

---

## 3. 站点体系（优化 3 定稿）

| 站 | 旧名 | 方向 | 订阅 | 职责 |
|---|---|---|---|---|
| **广播站** | 广播站 | 插件 → 多订阅者 | **需订阅** | 主题广播 + 持久公告板（跨插件"交火"） |
| **执行站** | 接收站 | 插件 → 挂载点 | **不订阅、不触发插件** | 插件**主动下命令**；**执行器只是"站点的一种挂载位置"**（前端执行器、插件、系统内置皆可挂载） |
| **中转站** | 处理站 | 系统 → 插件 → 回填 | **需订阅** | 数据流拦截-回填；处理过程中可综合广播站信息、并用执行站做操作 |
| ~~旧中转站~~ | 插件间寻址路由 | — | — | **本期移除** |

- 三站**系统自带**（默认存在）；**允许插件自建站点**：只能注册**既有三种类型**下的站点实例（不允许发明新类型），注册后供其他插件订阅/调用。
- **首命令集（执行站）**：`fs.read`、`fs.write`、`fs.list`、`fs.grep`、`terminal.exec`、`agent.message`、`agent.stop`、`agent.compact`、`ui.push`。
- **隔离**：四元组 `(team_id, agent_id, session_id, mode_key)`，见 1.2。
- 权限沿用旧 SDK 的**工作空间白名单 + team/agent/session 隔离**。
- 参考实现：旧 `server/plugin/stations.py`（订阅键位 = 站 × scope 唯一、先到先得/replace/最细粒度、等待切片 0.5s、超时 30s、fail-open 降级、级联、15 计数键），旧 `server/plugin/sdk.py`（出站面：`workspace_read/write`、`dispatch_agent_message`、`ws_push/emit_frontend`、`activity_log`）。
- **注意**：站点等待/超时按 1.1 **取消硬超时**，改心跳保活。

---

## 4. 插件布局（优化 4 定稿）

- 声明式槽位（**不做 webview/iframe**）：插件在 manifest 声明槽位，宿主用受限控件集渲染（列表 / 表格 / 表单 / 按钮 / 进度 / 文本），点击回调经 WS 帧回插件；
- 槽位清单：左侧活动栏项、右栏 Tab、状态栏、消息流内联卡片；
- 允许插件注入消息流卡片（`ui.push` 命令）。

---

## 5. 分工与文件所有权（并行执行）

**规则**：一个文件同时只有一个执行者；子代理**不做 git 操作**（`add`/`commit` 由主控统一按子系统提交）；只跑与改动相关的测试。

### Wave 1（并行）
| 执行者 | 范围 | 条目 | 文件所有权 |
|---|---|---|---|
| A | 核心 LLM / 设置 / 压缩 | Q8、Q1、LLM 侧去超时 | `packages/tree_core/lib/src/llm/**`、`lib/src/util/tokens.dart`、`lib/src/settings/**`、`lib/src/agent/compaction_service.dart`、`lib/src/agent/conversation_service.dart`（仅接线）、`lib/src/server/core_server.dart`（仅设置/模型 yaml 接口） |
| B | 前端消息区 + 下载列表 | Q2、Q5、Q6、Q7 | `lib/ui/**`、`windows/runner/**`、`test/**` |
| C | 执行器层 | Q4、Q10 执行层、执行器去超时/心跳 | `packages/tree_local_exec/**` |

### Wave 2（Wave 1 收口后）
| 执行者 | 范围 | 条目 |
|---|---|---|
| D | 工具层 | Q9（spec）、Q10（grep 结果格式化）、terminal 软超时→hook |
| E | 会话/存储层 | Q3（分段）、Q13（token 管道） |

### Wave 3
| 执行者 | 范围 | 条目 |
|---|---|---|
| F | 插件体系 | Q11（三站）、Q12（插件布局）、插件/MCP 去超时 |
| G | 收尾 | 全局心跳规约核查、文档/README、全量回归 |

---

## 6. 旧实现参考索引

| 主题 | 旧后端（主工作树 `E:\programs\Tree\flutter_application_tree\flutter_application_tree`） | 本仓库既有文档 |
|---|---|---|
| 工具结果重定向门控 | `server/llm/llm.py:52/447-492/1129-1161`、`server/tool/__init__.py:280-392` | `.trae/documents/tool-result-redirect-gate.md` |
| 工具循环内压缩 | `server/llm/llm.py:976-982` | — |
| 消息分段 | `server/agent/chat.py:1984-2210` | `.trae/documents/team_message_split_plan.md` |
| SSH Git | `lib/io/ssh_workspace_executor.dart:1283/1317`、`server/io_/workspace_io.py:399/651/660` | `.trae/documents/right_panel_refresh_and_ssh_git_fix.md` |
| terminal hook 模式 | — | `.trae/documents/terminal_hook_mode_plan.md` |
| Spec 索引 / 瘦身 | `server/agent/chat.py:757-782`（`_SPEC_INDEX_LIMIT=12`）、`server/tool/spec_tool.py` | `.trae/documents/optimize-builtin-specs.md` |
| 站点体系 | `server/plugin/stations.py`、`server/plugin/sdk.py`、`server/plugin/__init__.py` | `spec/spec-1789268032.md`（主工作树） |
| 模型 yaml | `server/config/models.py`（旧） | `.trae/documents/prompt-multi-version-app-yaml.md` |

---

## 7. 验收基线（M8 收口时数值，M9 不得劣化）

- `dart analyze packages` → No issues；`flutter analyze` → clean；
- `tree_local_exec` 60 passed（+1 gated skip）、`tree_protocol` 11、`tree_core` 380、app `flutter test` 66；
- 真机 SSH 回归：`open@192.168.0.208`（key `~/.ssh/id_ed25519`，`TREE_SSH_TEST_ROOT=/mnt/space`），list/upload/download_folder/syncToLocal 四项通过。

---

## 8. 实施记录（WIP，随并行波次更新）

### Wave 1-A 核心 LLM / 设置 / 压缩（packages/tree_core）— 已交付（提交 feat(m9-a)，见 git log）
| 条目 | 结果 | 要点 |
|---|---|---|
| Q8 | 完成 | maxToolTurns 全删；终止条件只剩 取消 / 出错 / 模型给最终文本 |
| Q1-① | 完成 | estimateTokens = ceil(字符数 / token_scale) 单一标量；token_scale / longest_session_tokens 落 models/<id>.yaml；真实 prompt_tokens 破水位线才学习，区间护栏 [0.2, 20] 外整条丢弃；无 usage 只读不写 |
| Q1-② | 完成 | 新增 lib/src/llm/llm_result_gate.dart（8000 token、预览 300 字符、落 .self/results/）；只替换送模型那一份，前端与落库留全文；历史重载同样过门控；同 run 同结果只落一份 |
| Q1-③ | 完成 | 每轮 API 调用前压缩；端点报超限强制压缩一次并重试该轮（**整轮仅一次**，防死循环）；max_seqlen 兜底显式标注；压缩失败/降级用**不落库** message 帧提示（落库会插进上下文让模型回应它） |
| 1.1 LLM | 完成 | 无总时长上限；判死=心跳丢失（收到任意字节即续期，连续 10s×3 无字节 ⇒ livenessLost）；暴露 isAlive / missedHeartbeats / lastHeartbeatAt |

验证：dart analyze packages/tree_core 零 issue；tree_core 全量 **425 passed / 1 skipped / 1 failed**；flutter analyze 零 issue；app flutter test **81 passed**。

**已知失败（归属 Wave 2-E）**：server_test.dart「推送刷新帧率：同一帧窗口内的增量合并为一条 msg_chunk」——
_paceToken 现为每增量 Future.delayed(1ms)（11e1376 引入，常开无开关），本机 Windows 计时器粒度约 15.6ms，
7 个增量实测约 105ms > 50ms 帧窗口，必然切成两帧。修法见 Wave 2 任务定义（令牌桶 + 测试旋钮真正关掉节奏控制），**不得靠放宽断言掩盖**。

**待接线**：
- 门控与工具层截断的相互作用：WorkspaceToolRunner.maxResultChars = 24000 先截断，门控只覆盖 16000~24000 字符 → 已列入 Wave 2-D（让门控接管）。
- 真正的状态栏展示需要协议+前端加帧类型（当前用 message 帧）→ 随 Q12 插件布局的状态栏槽位一起做。
- AgentError 若需带结构化 livenessLost 标志，需改 agent_engine.dart（本轮未动）。

### Wave 1-B 前端消息区与下载列表（lib/ui、windows/runner、test）— 已交付（提交 feat(m9-b)）
| 条目 | 结果 | 要点 |
|---|---|---|
| Q2 | 完成 | mode_switch 三态改两态；_currentMode 默认 local；新增 _enableLocalFallback（仅在两个执行器状态互相矛盾时触发，不弹目录选择，工作目录留空 = 核心默认工作空间） |
| Q5 | 完成（原生仅语法级验证） | 原生 readFiles（CF_HDROP + DragQueryFileW，中文路径转 UTF-8）；粘贴顺序 文件列表 → 单张位图 → 文本路径 → 普通文本 |
| Q6 | 完成 | MessageDraftCache（key = team::session，文本与附件一起、纯内存）；发送成功后清空该键 |
| Q7 | 完成 | 新增 lib/ui/services/file_reveal.dart（explorer /select, 分两参数传、不看退出码；macOS open -R；Linux 提示不支持） |

验证：dart analyze lib test 零 issue；flutter test 相关 4 个文件 18 passed（其中新增 15）。

**待办**
- Q5 需一次 flutter build windows + 手工回归（多选文件 Ctrl+V / 位图 / 文本三条路径）；C++ 仅通过 cl /Zs 语法检查，未链接、未运行。
- 根仓 flutter analyze 曾剩 1 个 error（packages/tree_core/test/llm_session_test.dart 的 maxToolTurns），属核心线 Q8；收口时确认 A 已同步，否则主控补。
- 产品口径待定：自动落本地时工作目录留空（核心默认工作空间），不弹目录选择。

### Wave 1-C 执行器层（packages/tree_local_exec）— 已交付（提交 feat(m9-c)：执行器层 SSH Git / grep 扫描清单 / 去超时心跳）
| 条目 | 结果 | 要点 |
|---|---|---|
| Q4 | 完成 | 新增 lib/src/git_output.dart（本地/SSH 共用命令与解析）；WorkspaceIO.gitLog/gitBranches；非仓库或无 git → 空列表 + 退出码 |
| Q10 执行层 | 完成 | GrepOutcome 新增 scannedFileCount / scannedFilePaths(≤200) / excludedDirs(≤50) |
| 1.1 执行器 | 完成 | 本地 exec 与 SSH run/建连/认证去超时；keepAliveInterval 10s + isConnected |

验证：dart analyze packages/tree_local_exec 零 issue；包内 dart test 86 passed / 1 skipped（真机 gate 未动）。

**口径偏差（Wave 2 必须遵守）**
1. grep 清单字段名 = scannedFilePaths（scannedFiles 已是既有 int 计数，语义不可改）；计数用 scannedFileCount。
2. SSH grep 改为按路径前缀剪枝（与本地一致）：以前 node_modules/** 的匹配会返回，现在不返回——属修正。
3. exec(timeout:) 与 timedOut 保留但语义恒为"永不超时"（恒 false），仅为兼容调用方签名。
4. DartSshTransport.connect 的 timeout 参数已删除（全仓无调用方）。

**待接线**
- packages/tree_core/lib/src/files/file_service.dart 的 gitLog/gitBranches 对 SSH 仍返回可读 400 → 接 WorkspaceIO.gitLog/gitBranches；注意 files_api_test.dart:315 断言 branches.single['name']，统一用 GitBranchesOutcome.toJson()（[String]）时需在 FileService 映射或同步改测试（前端 git_history.dart 两种都认）。
- README.md:174 关于"远端 Git 仍 400"的描述待更新（Wave 3-G）。
- 真机 SSH 回归留到 Wave 3-G。

### Wave 1-C 追加：超时判据改为心跳判活（提交见 git log feat(m9-c2)）
- 新增 ssh_liveness.dart（SshLiveness 台账 + SshLinkStaleException）：lastBeatAt / missedCount / isStale，I=10s、N=3 可配；任意成功读/写响应也算心跳并清零丢失。
- **心跳观测要点（踩坑记录）**：dartssh2 的 SSHClient.ping() 等的是 keepalive 全局请求的回包，_globalRequestReplyQueue 同时被 Success 与 **Failure** 喂（OpenSSH 回 REQUEST_FAILURE，也算回了）；而内置 SSHKeepAlive 把结果全吞掉 → 因此关掉内置心跳（keepAliveInterval: null），自建 Timer 循环，每拍 ping().timeout(I)：**窗口 = 一个心跳间隔（单拍 deadline，不是任务总时长）**。
- 在途操作显式失败：guard(op) 先查失活，再让 op 与失活信号赛跑；失活即抛 SshLinkStaleException（含「链路失活」「心跳丢失」）；**不关连接**，恢复（成功心跳 / reset / 重连）自动清除标记；流式读取逐块赛跑。
- 本地 exec：活性 = 进程存活，活着永不超时；**唯一的静态窗口**是「进程已死之后的残余管道收尾」（300ms 输出静默 + 3s 兜底，放弃时取消订阅）——属收尾而非任务上限；主控裁定保留（否则持续输出型后台进程会让工具调用永久挂住，与「不要永久挂起」冲突）。
- 接口变更：SshTransport.isConnected → SshLiveness get liveness（全仓无包外实现者）。
- **服务端兼容性提醒**：心跳观测依赖服务端对 keepalive 全局请求有回包（OpenSSH 回 FAILURE 算回）；静默忽略该请求的非常规服务端会被判失活。
- **真机实证（2026，主控临时探针，跑完即删）**：对 open@192.168.0.208（/mnt/space）连接后静默 35s（> I×N=30s），观测到 `missed=0 / stale=false`，随后 `pwd` 正常返回 `/mnt/space` —— 真机 OpenSSH 确实回 keepalive 全局请求，兼容性风险已排除。
- 验证：dart analyze packages/tree_local_exec 零 issue；包内 103 passed / 1 skipped（新增 17 例）。

### Wave 2 任务定义（Wave 1-A 收口后启动）

**D — 工具层**（packages/tree_core/lib/src/tool/**、lib/src/spec/**、lib/src/files/file_service.dart，以及 core_server 里 FileService 构造的那一处）
1. **Q9 spec 瘦身**：tool/spec_tool.dart 只保留 select / create / update；select **直接返回所选 Spec 全文**（删除"必须先 read"约束、删除 search 与 list）；索引注入系统提示词（agent/workspace_prompt.dart），格式照旧 `- \`id\` [task_type] 标题（内置）（适用: when 摘要）`，默认全列、>50 条截断并注明"其余可用 spec select 直取"。
2. **Q10 grep 结果文案**：无匹配时在工具结果里给出 扫描根 / scannedFileCount / scannedFilePaths（≤200，超出注明总数）/ excludedDirs（生效排除目录）。字段契约来自 Wave 1-C：**是 scannedFilePaths，不是 scannedFiles**。
3. **terminal 软超时 → hook 后台**：到点**不杀进程**，转 hook 模式后台执行并返回查询/续看方式（参考 .trae/documents/terminal_hook_mode_plan.md；执行器侧已去超时，见 Wave 1-C）。
4. **Q4 端到端接线**：file_service.dart 的 gitLog/gitBranches 的 SSH 分支改为经 WorkspaceIO 执行（参考 core_server 的 specIoFor 注入方式与 FileService.remoteFor 的写法）；返回体保持 REST 形状（`commits: [...]`、`branches: [{'name': ...}]`），以免破坏 files_api_test.dart:315 与前端 git_history.dart。

**E — 会话/存储层**（packages/tree_core/lib/src/agent/conversation_service.dart、lib/src/store/**、settings 的 tokenRate 读取）
1. **Q3 消息分段**（照旧后端 server/agent/chat.py:1984-2210）：thinking 段遇 text / tool_call / 提问即关闭；text 段遇 tool_call 即关闭并**独立落库**（中间输出不再并进最终回复）；tool 调用一条一张卡片；最终回复带 usage；落库加**单调序号**保证重载顺序稳定。
2. **Q13 token 管道**：工具调用参数按 `字符数 / token_scale` 折算 token，与思考**共用同一条 token rate 管道**推送 tool_start；tool_end **直接推**；推完再进下一轮 API 调用。

---

## 9. 变更记录

| 时间 | 变更 |
|---|---|
| 本轮 | 初稿：Q1–Q13 语义定稿 + 全局去超时/心跳规约 + 站点体系 + 分工 |
