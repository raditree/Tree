# Changelog

记录本仓库**桌面线**（单机核心进程形态）的变更，自首个开源版本 **1.0.0** 起。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/)；版本号与 `pubspec.yaml` 的 `version:` 一致
（有测试钉住两处不漂移）。

> **历史**：1.0.0 之前是闭源迭代期，且是另一条形态（服务端线：Flutter + Python FastAPI）。
> 桌面线把后端逻辑整体迁入本机核心进程、从零重写，历史条目与新代码不逐条对应，因此不再保留；
> 需要溯源请看 git 历史与 [docs/archive/](docs/archive/README.md)。

> **条目口径（只记断言）**：条目只写**新增或修改的断言**——即各模块 `README.md` 的
> 「不变量（assertions）」条款（包级 README 同样算：`tree_local_exec` / `tree_protocol` …），
> 每条给出断言原文与出处文件。**实现细节、重构、修 bug 若没有改动任何断言，就不写 CHANGELOG**
> ——溯源看 git 历史。理由：断言是"行为契约"的最小可验证单位，功能流水账既读不完、也对不上代码。
> 下面的 `### Added` / `Changed` / `Fixed` / `Docs` 是**首个版本（从零重写）的总览**：
> 断言上百条无法逐条列举，保留总览形态，不再往里加条目。

## [1.0.0] — 未发布（首个开源版本）

### 断言变化（新增 / 修改的 README 不变量）

- **关闭按钮默认不是退出**（[lib/README.md](lib/README.md) 不变量 7、[docs/architecture.md](docs/architecture.md) §1）：
  关闭窗口改为隐藏到系统托盘，核心与在跑的任务继续；真退出只有托盘菜单与设置页两条明确路径，
  都先让核心优雅退出再销毁窗口。安全底线：托盘装不上就绝不隐藏、核心启动失败的错误页不拦关闭。
- **同一数据根只允许一个实例**（[lib/README.md](lib/README.md) 不变量 8、[docs/architecture.md](docs/architecture.md) §1）：
  UI 在拉起核心前先抢一把回环端口锁（锁键 = 数据根），第二个实例握手确认后立刻退出、并把已有实例的
  窗口叫到前面，绝不拉起第二个核心；端口被别的程序占用时照常启动（不因为撞端口把用户挡在门外）。

- **LLM 传输层有限重试**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 11）：最多 5 次重试、
  退避 `5/10/20/40/80s`（累计 155s），且**只在这一次尝试一个事件都还没交给上层时**重试——半路断流（已有增量）不重试，
  4xx / 流中 error 帧 / 取消 / 传输层已关闭不重试，退避等待可取消；**每次重试前先产出 `LlmRetryNotice`**
  （落成 `llm_hidden` 的进度消息），用户不会对着两分多钟的空白猜是不是卡死了；**总结器走同一条传输层**，
  它的进度经 `CompactionService.noticeSink` 落成同一种消息。
- **`llm_hidden`：用户看得见、模型看不见**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 12、
  [agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 3、
  [store/README.md](packages/tree_core/lib/src/store/README.md) 不变量 10）：失败 / 停止提示与**重试进度**照常落库、
  照常下发（前端当普通气泡），但引擎重建请求时**整条跳过**（压缩重试进度同理）；`kind` 保持 `text`——
  不做新 kind 的理由：`system` 会被读成 system prompt，「进不进提示词」与消息类别是两件正交的事。
- **工具批是原子的：批中途的注入不切开它**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 6）：
  一条 assistant 的 `tool_calls` 与它的**全部** tool 结果必须相邻；落在批中途的 hook 提示 / 用户插话
  一律推迟到该批结果之后——工具结果逐条落库（远端 SSH 上的慢工具尤其容易让注入卡在两条之间），
  就地发会把批切成"后半批没有 `reasoning_content`"，请求随即变成"以 tool 结果收尾、前面那条
  `tool_calls` 没有 reasoning"⇒ 端点 400。
- **提问的 `createdAt` 严格递增**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 8）：
  `QuestionStore.add` 把提问时间抬成"全库严格递增"（与消息时间戳同一条规则，共用 `monotonicStamp`）——
  否则同一毫秒的两条在 `GET /api/questions` 的"最新的排前面"里顺序漂移（`List.sort` 不保证稳定）；
  装载旧文件只读不改，不追改用户数据。
- **grep 的三个数字各管一件事**（[tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 7）：
  `scannedFileCount` 是计数、`scannedFilePaths` 只留 20 条抽样、`GrepQuery.maxResults`（默认 200）是命中行数上限。
- **成员与 leader 共享工作目录与 SSH、私有状态按 agent 分栏**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 2/3/4）：
  成员 yaml 里的 `workspace_dir` **不生效**、`ssh:` 缺省取 TOP 的、`.self` 落在 `.tree/<agent_id>/`。
- **删 agent 有两道闸门，且删除路径与 team 工具同规则**（[server/README.md](packages/tree_core/lib/src/server/README.md) 不变量 12、
  [team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 12、[lib/README.md](lib/README.md) 不变量 9）：
  有下级成员必须显式 `?cascade=1`（否则 409 + `cascade_required`，避免留下"删不掉、停不了、广播够不着却还能干活"
  的孤儿成员），**任一相关会话正在运行也拒绝**（409 + `running`，先停止并等它空闲——`stop` 抢不动正在执行的工具，
  核心不替用户等待）；通过后按「停 → 排水 → 清提问 → 叶→根删 → 回填 `team_member_count`」执行，删完不留 `data/<id>`。
- **悬空团队指针启动自愈**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 12：
  `team_repair.dart`）：上级被删的成员重挂到 TOP 且整棵子树的 `team_id`/`level` 一起平移；团队也没了就把最上层孤儿
  升为独立顶层 agent；`team_id` 悬空但父链完好按父链修正。每个被改的 `agents/<id>.yaml` 先备份 `.bak.<n>`（n 递增、
  绝不覆盖），幂等。
- **伪终端（PTY）交付原始字节、缺口如实报、句柄不留孤儿**（[tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 8/9/10）：
  `PtySession`（`startPtySession`）提供交互式伪终端：输出是**原始字节**（不解码、不清洗 ANSI）、键盘输入、改尺寸、
  退出码，`close()` 幂等且收掉进程；Windows 走 **ConPTY**（`dart:ffi` 直调 kernel32，阻塞读放独立 isolate），
  POSIX 走系统 `script`，后端或 API 缺失一律**显式抛可读错误**（`PtyUnsupportedException`），
  **绝不静默降级**成无 TTY 的一次性 `exec`；改尺寸做不到时只记日志不抛。
- **Ctrl+J 打开集成终端（真 PTY），且与焦点无关**（[lib/README.md](lib/README.md) 不变量 14、
  [terminal/README.md](packages/tree_core/lib/src/terminal/README.md)）：输入框那块整体换成终端面板并**主动展开**
  （面板高 40%，可拖），再按一次回到输入框；终端**没有输入行**——按键逐键译成终端字节（回车 / 退格 / 方向键 /
  Ctrl+字母 / UTF-8 可打印字符），Ctrl+J 留给切换。快捷键绑在 MainPage 顶层的 `CallbackShortcuts` + 全局
  `TerminalToggleRequest` 上：**焦点在文件树 / 代码编辑器 / 详情页 / 终端自身时照样唤起**，连「没有任何主焦点」
  那种情况也冒泡得到——此前挂在输入框上的局部快捷键只在输入框有焦点时才收得到。核心开**真伪终端**
  （Windows ConPTY / POSIX `script`），输出按 **base64 原始字节**走已有的那条 WS（`terminal_open/input/resize/close` 上行，
  `terminal_ready/output/exit/error` 下行），前端用自制 VT 解析器还原成屏幕（光标定位 / SGR / 备用屏 / 宽字符）。
  **两个后端都是真 PTY**：远端（SSH）agent 走 SSH 会话通道 + `pty-req`（dartssh2），并**复用那条已建好的 SSH 连接**
  （不为终端再连一次），远端的 `terminal_ready.cwd` 是空串——远端工作目录由 `SshWorkspaceIO` 自己解决，界面显示「工作区」；
  判据是**有效 SSH**（成员跟随团队 TOP，见不变量 15）。没接线时回可读错误，**绝不**悄悄在本机给远端 agent 起一个终端；
  连接断开 / 换 agent / 关面板都会收掉 shell，不留孤儿进程。协议完备性门禁要求核心逐一显式处理四种上行帧。
- **源码模式按语言着色，且只能编辑纯文本**（[lib/README.md](lib/README.md) 不变量 12）：**不引第三方高亮包**，
  一张规则表 + 单遍扫描（关键字 / 类型 / 字符串 / 注释 / 数字 / 注解 / 函数名）；只在 ≤ 128 KB 时着色（超过退回单色，
  保证输入不卡），记号按「文本 + 配色」缓存；是否文本**看字节**（前 4 KB 有 NUL 就当二进制）。只读闸门：图片 / PDF / Office、
  **被截断的大文件**（写回等于截短文件）、含 NUL 的二进制、外部显式传入的 `readOnly`。保存一律走核心并带 `if_size` 做外部改动检测
  （不符 → 409 → 覆盖保存 / 放弃并刷新 / 取消）；自动保存只做**失焦与离开**，没有定时器（可在设置里关）。
- **分屏只做二分**（[lib/README.md](lib/README.md) 不变量 13）：左右 / 上下可切、分隔可拖、
  每格独立打开与保存、太窄降级成单窗格；换文件 / 关窗格前先 `confirmLeave()`（开着失焦保存就静默写回，关着就问一次）。
- **同一个文件的两个窗格共享一份编辑缓冲**（[lib/README.md](lib/README.md) 不变量 13、
  [known-issues #11](docs/known-issues.md)、[editor_buffer.dart](lib/ui/services/editor_buffer.dart)）：两侧共用**同一个**
  `CodeEditingController` 与同一份 `dirty` / `saving` / `loadedSize`——一边打字另一边立刻可见，任一窗格保存成功两边一起
  变成已保存、`if_size` 冲突流程不变；控制器归缓冲所有，两个窗格都关掉之后才释放。
  **这推翻了旧口径"同文件双开 ⇒ 非活动窗格强制只读"**：旧理由（两份缓冲互相覆盖）在共享一份缓冲之后不成立。
- **新增 `PUT /api/files/{workspaceId}/content`**（[files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 7/8）：
  源码编辑器按完整文本保存，本机与 SSH 都走已有的工作空间 IO 抽象（UTF-8 写入、原样保留换行；既有非 UTF-8 文件沿用原代码页，
  编不回去就**显式拒绝**而不是静默转码）；`if_size` 与当前字节数不符回 409（文件已不存在也算冲突、不带 `size`），
  越界路径 / 图片 / PDF / Office / 压缩包 / 含 NUL 的二进制 / 超 `maxWriteBytes`（4 MB）一律可读 400，
  远端取不到可用工作空间 IO 时不假装成功。
- **消息流改一行式：模型消息高亮，工具 / 思考各占一行，完整内容去右栏「详情」页**
  （[lib/README.md](lib/README.md) 不变量 11）：模型消息去掉整圈边框，改成左侧主色竖条 + 极淡同色底的**高亮块**；
  工具调用压成一行「中文标签 + 关键参数（等宽）」并在行尾给增量（编辑 / 写入按行数 `+N -M`）、转圈或箭头；
  增量**只从这次调用的参数算**（`edit` 取 `old_text` / `new_text`、`write` 取 `content`，即**核心 schema 的键名**；
  对错了键就是恒 `+0 -0`），编辑工具的**结果**只有「已替换 N 处」这类话、**不带 diff**，不许解析结果文本；
  参数不全 / 不是编辑写入类工具 ⇒ 行尾**不给数字**（`+0 -0` 是假信息，宁缺勿假），行数与核心 `LineSplitter` 同口径。
  思考压成一行「思考 · 首行摘要」；悬停图标提亮 + 底色，点击在中栏选中并自动切到右栏第 5 个内置页签「详情」
  （右栏收着就先展开），在那里摊开**完整**参数与结果。选中项用 `DetailSelection` 保存快照并按 id 帧后刷新——
  跑着的工具 / 思考内容是原地变更的；切 agent 或整表重拉时清空。中栏**不再就地展开**：一轮里工具几十条，
  卡片会把时间线切散。
- **输入框改成卡片式、附件在发送前就能预览**（[lib/README.md](lib/README.md) 不变量 10）：
  附件预览在上、文本域在中，底部一行左边「+」（添加文件 / 展开输入框）、右边只有圆形发送键；
  「展开」只把文本域原位变高（Esc 收起）且不动草稿与附件；附件一律可预览——图片给缩略图、
  其它给「图标+名称+大小」卡片，点开读**本机**文件（是不是图片看扩展名、是不是文本一律看字节：
  前 4 KB 有 NUL 就当二进制），文件不在或读不到时直说原因，不显示 0 B。
- **提问 `cancel` 与"记录是否还在"解耦**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 8）：
  删除 agent 会摘掉提问记录，此时 `cancel` 也必须完成在途等待的 completer——否则等答案的工具永远拿不到结果，
  那一轮不收敛、`isRunning` 永远为真、连 `stop` 都救不回来。
- **左栏列出全部 agent（含团队成员）**（[lib/README.md](lib/README.md) 不变量 6、[docs/team.md](docs/team.md) §7）：
  成员也是独立 agent 文件，点开就是它自己的会话；顺序 = 顶层在前（保持接口顺序）＋ 成员紧跟各自的
  TOP，`team_id` 指向的 TOP 不在列表里时兜底列在末尾。**成员其余口径不变**：工具根 / 系统提示词 /
  文件面板仍解析到 leader 的工作目录与 SSH，插件作用域仍按 `teamScopeId` 回指团队。

- **核心启动不被外设预热拖住**（[server/README.md](packages/tree_core/lib/src/server/README.md) 不变量 13、
  [known-issues #13](docs/known-issues.md)）：MCP 首次连接（**没有超时参数**）与插件启动（**逐家串行**、每家 20s）
  **只在握手之后**预热——并行、有界（预算 3s，超预算不再等）、绝不抛（单家失败只记日志）；
  模型那一轮由 `LlmAgentEngine.awaitReady` 有界等一次预热，不会"悄悄少掉插件/MCP 工具"；
  每段往 stderr 打 `[core:boot]` 分段耗时。此前两段都排在握手**之前**，任何一家外设卡住都会让界面
  看到「核心进程未能启动（等待核心进程握手超时 25s）」。
- **成员 yaml 里的 `workspace_dir` 是"共享目录的镜像"**（[team/README.md](packages/tree_core/lib/src/team/README.md)
  不变量 13）：写进去的是**有效目录**——TOP 显式配置的，或 TOP 未配置时的默认目录；在建成员时、核心启动自愈时、
  TOP 改目录的 PATCH 之后维护（写前备份 `.bak.<n>`、幂等；TOP 自己的配置**绝不改写**）。
  它**不参与运行期解析**（仍只看 TOP 那份），只为两件事：界面显示成员实际在用的目录；
  **TOP 被删后成员升为 TOP 的无损交接**（用户断言 2026-10-03：升级后**不可以**重新选择工作目录，
  配置不能留空、按 TOP 填写）。
- **消息输入框的文本域自己不画边框**（[lib/README.md](lib/README.md) 不变量 10）：装饰必须把
  `enabledBorder` / `focusedBorder` / `disabledBorder` / `errorBorder` / `focusedErrorBorder` 一并置空
  （统一常量 [input_style.dart](lib/ui/widgets/input_style.dart)）——只写 `border: InputBorder.none` 压不住全局
  `inputDecorationTheme`（解析顺序 focusedBorder → enabledBorder → border），表现是卡片里多出主题那圈绿框；
  代码编辑器（源码视图）同一条口径。
- **「这是远端吗」的唯一判据是「有效 SSH」**（[files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 9、
  [team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 3）：`teamSshConfigFor`（成员自己没有 `ssh:` 时跟随团队 TOP）
  贯穿工具层、文件面板、Git 面板与集成终端；此前文件面板只看 `agent.sshConfig`，把 SSH leader 的成员判成本机
  ——面板会拿一个远端路径去本机找目录（轻则"目录不存在"，重则读到本机同名路径），集成终端更会在本机起一个 shell。
- **运行模式与工作目录是团队级的**（[lib/README.md](lib/README.md) 不变量 15）：中栏左上角按**团队 TOP** 合成
  ——成员自己显式配的 SSH 优先、否则跟随 TOP；目录只认 TOP 那份（TOP 未配置时退回成员自己的镜像，
  因此永远显示真实目录而不是「选择目录」）；选目录**写入 TOP** 并提示"团队成员共用"；
  TOP 是 SSH 时成员**切不回本地**（核心没有"成员覆盖成 local"这个概念），界面如实拒绝并说明去哪改。
- **源码视图左侧有行号槽，且软换行感知**（[lib/README.md](lib/README.md) 不变量 12、
  [code_gutter_layout.dart](lib/ui/services/code_gutter_layout.dart)、[file_viewer.dart](lib/ui/widgets/file_viewer.dart)、
  [file_editor_test.dart](test/file_editor_test.dart)）：源码模式的**可编辑与只读两条分支**都画行号
  （图片 / PDF / Office 与 Markdown / SVG **预览**没有）；一条逻辑行软换行成多个视觉行时**只给首行编号**
  （续行不画数字），行号与正文必须用**同一套度量**——同一 TextStyle、同一 textScaler、同一内容宽度
  （窗格宽 − 槽宽 − 正文 contentPadding 左右 − 光标留白），否则折行点不同、从折行处开始数字整体错位；
  行号槽跟着正文**同一条滚动控制器**平移（不挂第二个 Scrollable）、把正文顶部 contentPadding 算进偏移；
  布局只在文本 / 可用宽度变化时重算，数字不参与命中与选择。
- **右栏文件面板是 VS Code 型资源管理器**（[lib/README.md](lib/README.md) 不变量 16，用户 2026-10-03：
  「现在太简陋了，对标 VS Code」）：① **口径变化（不是漏改）**：旧的「单层列表 + 面包屑进子目录」换成
  **惰性加载的嵌套树**（展开时才拉那一层）——面包屑取消，头部显示「根目录 + 同步作用域」，**同步作用域改由选中项推导**
  （选中目录 = 它自己，选中文件 = 其父目录），**展开状态跨刷新保持**（工具写文件、上传、切执行模式重拉之后不塌）；
  ② **行只有名字 + 类型图标**（行高 22 / 字号 13，行内左右 padding 6）：大小与修改时间两列**下到悬停 tooltip**
  （目录给「N 项 · 时间」，没加载过子项时只给时间、**不编数字**），超长名 `ellipsis`、tooltip 第一行永远是全名；
  ③ 图标与颜色是纯函数 `fileTreeVisualFor`（路径 / 是否目录 / 是否展开），**色板写死不跟主题色**（跟主色走整棵树会变成
  一坨同色），源码家族取自 `code_highlight` 的 `languageForPath`（不抄第二张扩展名表）；④ 箭头只在目录上（另有等宽空槽
  保证同级对齐）+ 每层 1px 缩进引导线 + 整行悬停 / 选中（左侧 2px 主色条）+ ↑/↓/←/→/Enter/F2/Delete 键盘导航；
  ⑤ **git 状态染色**：`GET .../git-status` **只拉一次**缓存在面板状态，整行名字染色 + 行尾 M/U/A/D/R/I
  （VS Code gitDecoration 口径，被忽略更淡），**目录聚合子项状态**（删除 > 修改 > 未跟踪 > 新增 > 重命名 > 忽略）；
  `is_repo=false` / 端点还没有 / 断网**一律静默不着色**（状态色是锦上添花，不能把它变成错误页），增删改后失效重拉；
  ⑥ **新建 / 重命名 / 删除**：名字校验（空 / 路径分隔符 / 非法字符 / Windows 保留名 / 同名）**前端先挡一道**，
  且创建前**重新列一次目录**复查——核心的写文本端点**没有「仅新建」语义**，重名会被静默覆盖；重名给**行内红字**，
  删除要确认（目录**显式** `recursive=1` 并在确认框里写明「里面的内容会一起删除」），**工作空间根永远不许删**（前后端各一道）；
  超大目录被核心截断时给一行「仅显示前 N 项」（`getFilesWithMeta` 保留 `truncated`，旧的 `getFiles` 会丢掉它）；
  ⑦ **树与查看器同屏（上下分栏）**：覆盖层口径**已被推翻**——它会让「打开文件后新建 / 改名 / 删除」根本点不到，
  `onPathRenamed` / `onPathDeleted` 接线也永远点不到；改成上下分栏（比例默认 0.4 且**记在面板状态**里），
  **没打开文件时树独占**（不留空分栏）；可用高度 < 200px 降级成**只显示查看器**；开 / 关查看器时文件子 Tab 区用
  `GlobalKey` **搬**进 / 搬出分栏而不是重建（展开状态、选中项、已加载的目录都不丢）。
- **文件面板的增删改与 git 状态端点**（[files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 10/11、
  [tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 12/13）：新增 `POST .../mkdir`、`POST .../rename`、
  `DELETE ...?path=[&recursive=1]`、`GET .../git-status`（路径常量取自协议包 `ApiPaths`，不写字面量）。结构改动
  **只走工作空间 IO 抽象**（本机 `LocalWorkspaceIO`、远端 SFTP 的 `mkdir` / `rename` / `remove`，**不起 shell**，
  因此没有引号 / 转义 / 远端有没有 coreutils 这些问题），三条硬口径：**绝不覆盖**（重命名目标已存在 → 409；SFTP 的
  `posix-rename@openssh.com` 本身就是覆盖语义，所以两端都先自检）、**绝不自动建父目录**（父目录不存在 → 400，
  静默建目录会把写错的路径变成「成功」）、**永远拒绝删工作空间根**（`path` 空 / `.` / `a/..` 归一化成根 → 400）；
  非空目录默认拒绝（409 + 可读原因里说明要带 `recursive=1`），远端后端没接线 → 可读 400，**绝不落到本机**。
  git 状态与 git 日志**共用** `GitOutput.statusArgs` / `parseStatus`（`--porcelain=v1 -z`，空格 / 中文 / 引号路径、
  重命名、暂存与工作区混合、未跟踪、被忽略、非法输入都有单测；条目上限 2000，超出即 `truncated: true`）；
  两侧都**不抛异常**：不是仓库 ⇒ `is_repo: false` + 空列表（面板空态，**不是** 400）。
- **成员面板列的是「自己的下属」，且根卡片如实标注**（[team/README.md](packages/tree_core/lib/src/team/README.md)
  不变量 14、[lib/ui/services/teammates_view.dart](lib/ui/services/teammates_view.dart)，**用户断言 2026-10-03**：
  「凌川的成员里有凌川」）：`GET /api/agents/{id}/teammates` 的名单改成**以该 agent 为根的下属子树**——
  TOP 仍是整队（取值与顺序照旧），成员的子树通常为空；**绝不把自己 / 自己的兄弟 / 自己的上级列成「它的成员」**，
  `pending_member_count` 只数这份名单。以前一律取 `members(teamIdOf(id))`，而成员 `team_id` 回指团队 ⇒
  整队（含它自己）都成了「它的成员」，根卡片还硬写着「Level 0 · 团队负责人」。响应体新增 `self` 描述符
  （`level` / `is_member` / `top_agent_name`……），界面据此显示「Level N 成员 · 隶属「TOP」」；前端再
  **滤掉自己**一道（旧核心 / 中间态兜底），拿不到描述符时用 `agent.teamId` 兜底，**不编「我是负责人」**。

- **临时员工（`subagent`）工具：会话内的「临时员工」**（[store/README.md](packages/tree_core/lib/src/store/README.md) 不变量 11、
  [tool/README.md](packages/tree_core/lib/src/tool/README.md) 不变量 11、
  [agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 10/11/12、
  [tree_core_cli/README.md](packages/tree_core_cli/README.md) 不变量 6、[tree_core/README.md](packages/tree_core/README.md)「临时员工给前端用的字段」；
  **用户断言 2026-10-04**）：模型可以现场召一个**临时员工**干活——召之即来、干完还在（同一会话内可复用）、可再派发
  （层级上限 3，超限给可读错误）。与 `team` 的本质区别是**它只活在会话里**：记录落在
  `data/<agentId>/<sessionId>/subagents.json`，不写 `agents/<id>.yaml`、不进 `agents()` / `teams()` / `members()`、
  不可被 `message` 寻址、不计 `team_member_count`；**删会话或删 agent 即随之消失**，且**跨会话一律不保留**
  （换会话查不到、拿别的会话的 id 复用给可读错误——不静默新建、也不错误命中同名条目）。它**继承发起者**：
  同一份工作空间根（私有状态归会话主人，工作空间里不留 `sub_*` 目录）、同一个**有效 SSH**、同一个模型与成员级覆盖；
  工具集继承读写/命令/搜索/待办/提问/规范/MCP/插件，但**没有** `team` / `message`（不能被派活、不能建队），
  而**保留 `subagent`**（允许把同一个大任务拆细）。
  它与其它工具**同权、同三站**，不开后门：走 `WorkspaceToolRunner._execute → BuiltinTools.run` 这条唯一入口，
  中转站 `system.relay.tool.pre/post` 能改它的参数与结果、广播站 `system.broadcast.tool.pre/post` 各发一条、
  执行站命令 `tool.call` 能调它（与模型调用同一路径、同一权限），`needsWorkspace('subagent')` 显式为 false。
  消息与帧都带 `subagent_id / subagent_name / subagent_parent_id / subagent_level`（`agent_id` 仍是会话主人，
  既有过滤口径不变），而父 agent 的**模型上下文**刻意排掉带标记的消息（工具批必须原子，否则带 tools 的思考模式
  端点 400）——只有后台完成报告（`kind = subagent_report`）既带标记、又进发起者上下文（否则「干完了却没人知道」）。
  运行键 = `(subagentId, sessionId)`：与「正阻塞等它的父那一轮」绝不撞键（撞了就是死锁），N 个后台临时员工各占各的槽位
  并行跑、逐个完成逐个注入（**不做**「只留最后一个」的单槽位）；`stop` 与新消息插话会连带停掉同一会话里正在跑的
  临时员工，否则父那轮会一直卡在等一个没人管的子任务上。
- **临时员工的消息与工具行在中栏打标，不冒充主 agent**（[lib/README.md](lib/README.md) 不变量 11）：核心把临时员工
  的一切都写进**会话主人**的消息流（`agent_id` 仍是主人，既有帧过滤口径不动），前端按 `subagent_id` /
  `subagent_name` / `subagent_level` 在**这一段开头**画一条「临时员工「名」 · 层级 N」标记（同一个人的连续消息与
  工具只在第一行顶一次，换人重新标）；`subagent` 工具卡片是普通工具卡片（中文标签「临时员工」，行正文给 `task`，
  复用与后台在行里带出来）。按 `subagent_id` 分组 / 按 `subagent_parent_id` 树形展示是后续渲染——字段已经全在
  帧与历史接口里。
- **待处理成员红点接上真实计数**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 14、
  [docs/team.md](docs/team.md) §7）：`GET /api/agents` 的 `pending_member_count` 此前**从不被赋值**（恒 0），
  而 `docs/team.md` 写着「未就绪成员会在 leader 上显示红点」——左栏那排红点与角标因此**永远不亮**。
  现在按**与成员面板同一个名册口径**数：TOP 数整队、成员只数自己那棵子树里未分配模型 / 待审核的成员
  （成员不把整队的待办算在自己头上）；面板与徽章由同一个 `_rosterOf` 决定，不会出现「面板空、红点亮」。
- **文件面板三改：目录在左（可收起）+ 图标改成中性跟主题走**（[lib/README.md](lib/README.md) 不变量 16③/⑧，
  **用户断言 2026-10-04**：「文件查看器塞在目录下限制了大小，把目录放左边（允许折叠）」「文件为什么是这种橙色，
  改成图二的样式」）：① **布局从上下改回左右，上次的理由一并推翻**——上下分栏把查看器压扁（代码是按行看的，
  高度比宽度更吃紧），改成**左栏目录 / 右栏查看器**（比例默认 0.3、可拖、记在面板状态）；查看器工具条新增箭头键
  切换「目录收起 / 显示」，收起后查看器占满整格；**意愿与"这一刻能不能显示"分开**——可用宽度 < 400px 时降级成
  **只显示查看器**并在工具条上如实写出原因，拖宽右栏目录自己回来。② **图标改成中性单色**
  （`fileTreeIconColor(scheme) = onSurfaceVariant`）：目录收起 / 展开都是描边文件夹（状态交给左侧箭头），各类型靠
  **形状**区分——**推翻旧的「写死色板、不跟主题色」**（那正是用户看到的"这种橙色"），颜色只留给 git 状态
  （名字染色 + 行尾字母，口径不变）。③ 顺手修掉两处窄栏位溢出：目录头部标题走 `Flexible` + 省略号，查看器头部按
  宽度把预览切换 / 复制 / 下载收进「更多」菜单（动作键统一 28px 紧凑尺寸）。
- **首次使用的八步新手引导（处处可跳过）**（[lib/README.md](lib/README.md) 不变量 17，**用户断言 2026-10-04**）：
  顺序 = 用户定稿的 模型配置（设置页）→ 创建 agent → 配置模型信息 → 配置工作目录 → 启用插件 → 文件浏览 →
  Ctrl+J → demo 输入（「创建一名成员，负责插件开发」）。浮层**非模态**（每一步的「带我过去」要打开真实界面，
  模态会挡住它们）：设置页模型一节 / 建 agent 对话框 / 右栏「模型信息」·「文件」页 / 插件面板 / 集成终端 /
  工作目录选择器；除最后一步外只做导航，最后一步把 demo 那句话**填进输入框、不自动发送**。
  「下一步（跳过这步）」与「跳过引导」都能收工，都记进 SharedPreferences（UI 级偏好 `tree.onboarding.v1`）⇒
  之后不再自动弹；设置页新增「新手引导」卡片可**重新显示**。跨面板动作走全局广播（`ComposerPrefillRequest` /
  `WorkspacePickRequest`，与 `TerminalToggleRequest` 同一范式），右栏页签用「索引 + 请求序号」表达。

- **「全部折叠」不再「点了没反应」**（[lib/README.md](lib/README.md) 不变量 16⑤，**用户 2026-10-04**：
  「这个全部折叠点击为啥没反应」）：那一刻树本来就是全收着的，于是点了个"合法但看不见效果"的按钮。
  现在**没有展开项时这颗键置灰**（tooltip 明说「没有展开的目录（都收着呢）」，右键菜单里同一口径），
  真收了就**滚回顶部**（VS Code 同款）——每次点击都有可见反馈；顺带补一条回归测试：展开两层嵌套目录后
  点它，子行全部消失、箭头回到收起方向。

### Added（首个版本总览）

- **单进程桌面形态**：Flutter 界面 + 纯 Dart 核心 `tree_core`（可编译成单文件，约 10 MB）；
  核心只监听 `127.0.0.1` 随机端口，一次性 token 经 stdout 握手下发；关窗时优雅退出，不留孤儿进程。
- **agent 团队**：leader 用 `team` 工具建成员、审核闸门（无模型 + 待审核不接活），
  `message` 工具派活 / 广播 / `wait_for` 等交付；成员与 leader **共享同一个工作目录**（同一个项目）。
- **Spec（规范）体系**：内置 general-task / hard-task / team-meeting / plugin-creator，自定义规范落工作空间；
  索引与"已选全文"进系统提示词，`spec select` 直接返回全文。
- **MCP**：stdio 与 Streamable HTTP 两种传输、懒连接、心跳判活、工具命名空间化（`mcp__<服务>__<工具>`）。
- **插件与站点体系**：进程外插件（行分隔 JSON-RPC 2.0）+ 四类站点 / 17 个点位——广播、执行（fs / terminal /
  agent / ui / llm / tool / session）、中转（工具前 / 工具后 / LLM 接管 / 请求改写 / 压缩 / 系统提示词）、收集（工具申报）；
  插件可申报 UI 槽位与自己的工具。指南见 [docs/plugin-development.md](docs/plugin-development.md)，示例见 [examples/plugins/](examples/plugins/)。
- **SSH 运行模式**：工具、文件面板、Git 面板同一套语义；**成员跟随 leader 的 SSH**（同一台远端主机、同一个根）。
- **私有状态按 agent 分栏**：`.self/…` 真实落在 `.tree/<agent_id>/.self/…`（提示词 / 规范 / 长结果 / 活动日志）；
  团队共享项目文件、各自保留私有状态；核心启动时一次性迁移旧 `.self`。
- **会话并行**：同一 agent 的不同会话**并行**运行；同一会话内串行、新消息插话打断。
- **提问回路**：`ask_user_question` 落盘 + 卡片作答 / 取消 / 重启补答；右栏「问题回复」跨会话查看。
- **可复现的打包**：一条命令出便携 zip（构建 + 编译核心 + 拷 `pdfium.dll` + 写使用说明 + **自检** + 压缩），
  可选 Inno Setup 安装包（每用户安装、卸载不动用户数据）。

- **提示词资产索引**：模型看到的每一段文字（默认系统提示词 / 拼装顺序 / 内置 Spec 模板 / 插件指南副本 / 附件片段 /
  工具描述 / 会话状态 / 压缩摘要）在 [docs/architecture.md §8.1](docs/architecture.md) 有一张「源码 ↔ 运行期落点」对照表，
  改提示词不必再 grep 全仓；同时把「**侦察从文档开始**」（README → docs 索引 → 模块 README 的不变量 →
  development / known-issues → 再进代码核对）写进系统提示词与 general-task / hard-task 的 Recon 阶段。

### Changed

- **派活与回信归集到发起会话**：`message` 默认把接收方归集到"发起这一跳的会话"，
  teammates 窗口因此能看到成员进度与回信（此前会落到成员/leader 的默认会话，界面上什么都看不到）。
- **移除「消息切入设置」**：行为固定为"同会话插话打断 / 跨会话并行"，不再有死开关。
- 超长工具结果改为**重定向到工作空间**并只给模型预览（省 token、保全文）。

### Fixed

- **前缀缓存**：重建历史改为逐字复用"实发那一份"、系统提示词按会话钉住、Spec 快照冷热形态统一
  ⇒ 长会话不再每轮 0 命中（[known-issues #6](docs/known-issues.md) / [#8](docs/known-issues.md)）。
- **本地执行不再被"等输入"挂死**：子进程禁用交互（`-NonInteractive` + 关闭 stdin）+ 裸 `echo` 兼容翻译
  （[known-issues #7](docs/known-issues.md)）。
- **团队不再"发消息后无回复"**：跨会话消息不再掐掉另一个会话在途的轮次；
  `wait_for` 之后 leader 一定能继续发言（[known-issues #9](docs/known-issues.md)）。
- **取消一切静态任务超时**：判活只认心跳 / 进程存活；远端成员失联以"显式错误 + 部分结果"收口，不静默丢消息。

### Docs

- 文档收口（面向开源）：精简入口 [README.md](README.md)；新增
  [docs/architecture.md](docs/architecture.md)（架构 + 跨模块不变量）、[docs/development.md](docs/development.md)（构建 / 测试 / 打包 / 发布）、
  [docs/team.md](docs/team.md)（团队语义）、[CONTRIBUTING.md](CONTRIBUTING.md)（开发规则约束）与
  [docs/README.md](docs/README.md)（索引）；每个模块 README 写清职责 / 入口 / **不变量** / 测试；
  服务端线时代的历史文档移入 [docs/archive/](docs/archive/README.md)。
- 新增**文档契约门禁**（`packages/tree_protocol/test/docs_contract_test.dart`）：模块 README 的不变量节、
  入口文档、docs 索引完整性都会被测试检查。
