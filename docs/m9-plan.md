# M9 计划：14 项修复与优化（语义对齐定稿）

> 落盘时间：本轮对齐完成后。**本文件是 M9 唯一事实源**，实现/评审/回溯都以它为准。
> 上游语义来源：用户逐条确认（Q1–Q13 + 全局规约），旧后端实现见第 6 节索引。

## 0. 基线与环境

| 项 | 值 |
|---|---|
| 工作树 | `E:\programs\Tree\desktop`（分支 `desktop`） |
| 基线 HEAD | `11e1376` refactor: 替换主动延迟为 token 帧率和推送刷新帧率 |
| Dart SDK | `D:\app\flutter-sdk-3.47.5\flutter\bin\cache\dart-sdk\bin\dart.exe` |
| Flutter | `D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat` |
| 包结构 | `packages/tree_protocol`、`packages/tree_local_exec`、`packages/tree_core`、`packages/tree_core_cli`；前端 `lib/`；原生 `windows/runner/` |
| 验证 | `dart analyze packages`、`flutter analyze`（app 根）；测试 `dart test`（各包）、`flutter test`（app） |

**纪律**：禁止裸 `dart`/`flutter`（PATH 上是旧 SDK）；禁止对整目录 `dart format`（会重排无关文件），只格式化改动文件；不改与本次无关的文件。

---

## 1. 全局规约（M9 新增，所有子系统适用）

### 1.1 取消一切硬超时，改心跳保活
**理由**（用户口径）：本地执行，不存在服务器多用户无限期等待导致资源耗尽的后果。

适用范围与做法：

| 对象 | 现状 | M9 口径 |
|---|---|---|
| 工具调用 | 有执行超时 | **取消硬超时**；长任务靠心跳续命 |
| `terminal` | 前台命令有超时，到点终止 | **软超时**：到点不杀，切为 **hook 模式后台执行**，返回"已转后台 + 查询/续看方式" |
| 消息发送（WS send / team dispatch） | 发送超时后丢弃/报错 | 取消发送超时；改**背压 + 确认**，断线走重连补发 |
| 执行器命令（local/ssh executor RPC） | 有 RPC 超时 | 取消；改**心跳 + 断线重连**，命令在途可恢复 |
| 插件宿主（stdio 通道） | 心跳失败即停用/销毁 | 心跳只做**健康度标记**（`healthy/degraded`）+ 前端可见 + 用户手动重启；**不自动终止** |
| MCP 客户端 | 请求硬超时 | 取消；用 MCP `ping` 做心跳 |
| LLM 传输 | 建连/读取超时 | 建连可保留短超时（否则不可诊断），**流式读取不设总时长上限**，用空闲心跳（收到字节即续） |

统一心跳形态：`heartbeat{scope, seq, ts}`，接收方回 `heartbeat_ack`；缺失只影响健康度展示与重连决策。

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

### Wave 1-C 执行器层（packages/tree_local_exec）— 已交付，提交 fb3fd79
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

---

## 9. 变更记录

| 时间 | 变更 |
|---|---|
| 本轮 | 初稿：Q1–Q13 语义定稿 + 全局去超时/心跳规约 + 站点体系 + 分工 |
