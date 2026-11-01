/// REST 路径（前端 `lib/io/api_service.dart` 实际使用的 40 条）。
///
/// 桌面分支中这些路径先由核心进程在 **127.0.0.1 回环**上原样提供（M1），
/// 后续里程碑再逐模块把前端 HTTP 调用换成直接调用；路径常量是过渡期的
/// 单一事实来源，可被完备性测试校验（前端出现未声明路径即失败）。
abstract final class ApiPaths {
  // ── 账号体系（desktop 分支删除，M1 从前端移除后清空本组） ──────────────
  static const String authRegistrationConfig = '/api/auth/registration-config';
  static const String authUpgrade = '/api/auth/upgrade';
  static const String authAccountStatus = '/api/auth/account/status';
  static const String authAccountDeleteRequest =
      '/api/auth/account/delete-request';
  static const String authAccountDeleteCancel =
      '/api/auth/account/delete-cancel';
  static const String authChangePassword = '/api/auth/change-password';

  /// 账号相关路径（M1 删除）。
  static const Set<String> removedWithAccounts = <String>{
    authRegistrationConfig,
    authUpgrade,
    authAccountStatus,
    authAccountDeleteRequest,
    authAccountDeleteCancel,
    authChangePassword,
  };

  // ── agent / 模型 ──────────────────────────────────────────────────────
  static const String agents = '/api/agents';
  static const String agent = '/api/agents/{agentId}';
  static const String agentModelsInfo = '/api/agents/{agentId}/models-info';
  static const String agentTodos = '/api/agents/{agentId}/todos';
  static const String agentTeammates = '/api/agents/{agentId}/teammates';
  static const String teammate = '/api/agents/{leaderId}/teammate/{memberId}';
  static const String teammateLog =
      '/api/agents/{memberId}/teammate/{memberId}/log';
  static const String teammateMessage =
      '/api/agents/{leaderId}/teammate/{memberId}/message';
  static const String models = '/api/models';
  static const String model = '/api/models/{modelId}';

  // ── 会话 / 历史 / spec ────────────────────────────────────────────────
  static const String conversations = '/api/conversations/{agentId}';

  /// 单条消息详情（GET）：会话历史列表页只回显示行，重负载点开按 id 即查。
  static const String agentMessageDetail =
      '/api/conversations/{agentId}/messages/{messageId}';
  static const String agentSessions = '/api/agents/{agentId}/sessions';
  static const String agentSession =
      '/api/agents/{agentId}/sessions/{sessionId}';
  static const String agentSessionSpecs =
      '/api/agents/{agentId}/sessions/{sessionId}/specs';
  static const String agentSpecs = '/api/agents/{agentId}/specs';
  static const String agentSpec = '/api/agents/{agentId}/specs/{specId}';

  /// 一键重置该 agent 工作空间里的系统提示词 / Spec（备份 .bak.N 后还原默认）。
  static const String agentReset = '/api/agents/{agentId}/reset';

  /// 手动压缩上下文（前端「压缩」按钮；已实现）。压缩服务未接线时显式 501，不静默 404。
  static const String agentCompact = '/api/agents/{agentId}/compact';

  /// 重建该 agent 的**远端链路**（POST，无 body）：SSH 心跳判失活之后的手动恢复入口。
  ///
  /// 为什么需要它：判失活只**标记**链路已死（不关连接、不静默挂起），而一条已经断掉的
  /// TCP 连接不会自己活回来——传输层会按退避自动重连，但如果自动重连已用尽 / 用户不想等，
  /// 就要有一个**显式**入口。语义：
  /// - 200 = 已重建（响应 `{ok, agent_id, stale}`，`stale` 复位为 false；**没有 `missed` 键**）；
  /// - 400 = 该 agent 不是 SSH 工作空间（本地后端没有可重连的链路）；
  /// - 404 = 没有这个 agent；
  /// - 500 = 这次重连失败 / SSH 配置不完整，`detail` 是**可读原因**（例如认证失败 / 主机不可达）。
  ///
  /// 判据不变：**重连不是新的判活依据**——判死仍然只认"连续 N 拍心跳丢失"（M9 规约 1.1），
  /// 重连是判死**之后**的动作，不引入任何静态时长上限。
  static const String agentSshReconnect = '/api/agents/{agentId}/ssh/reconnect';

  // ── 执行器插件承接（非 delegated 契约集，仅登记前端调用面）─────────────
  /// 终端会话（`local_executor` / `ssh_executor` 插件申报）。
  ///
  /// UI 只用这一族 REST 管会话（建 / 输入 / 取消 / 改尺寸 / 关），输出走执行器的
  /// 广播站。它们不属于 [delegated] 的 55 条契约，登记在这里只是为了满足
  /// 「前端用到的 /api 路径必须已声明」这条门禁。
  static const String terminalLocalSessions = '/api/terminal/local/sessions';
  static const String terminalSshSessions = '/api/terminal/ssh/sessions';

  // ── 提问 ──────────────────────────────────────────────────────────────
  static const String questions = '/api/questions';
  static const String questionAnswer = '/api/questions/{qid}/answer';

  // ── 文件 / 工作空间 ───────────────────────────────────────────────────
  static const String files = '/api/files/{workspaceId}';
  static const String fileContent = '/api/files/{workspaceId}/content';
  static const String filePdfInfo = '/api/files/{workspaceId}/pdf_info';
  static const String fileUploadInit = '/api/files/{workspaceId}/upload_init';
  static const String fileUploadChunk = '/api/files/{workspaceId}/upload_chunk';
  static const String fileUploadComplete =
      '/api/files/{workspaceId}/upload_complete';
  static const String fileSyncToLocal = '/api/files/{workspaceId}/syncToLocal';
  static const String fileDownload = '/api/files/{workspaceId}/download';
  static const String fileDownloadFolder =
      '/api/files/{workspaceId}/download_folder';

  /// 新建文件夹（POST，body {path}）：目标已存在 → 409。
  static const String fileMkdir = '/api/files/{workspaceId}/mkdir';

  /// 重命名 / 移动（POST，body {from, to}）：目标已存在 → 409、源不存在 → 404、
  /// 目标父目录不存在 → 400（**不自动建父目录**）。
  static const String fileRename = '/api/files/{workspaceId}/rename';

  /// 删除（DELETE ?path=[&recursive=1]）。
  ///
  /// **与 [files] 是同一条路径**：REST 按方法区分（GET = 列目录，DELETE = 删除），
  /// 这里单独给一个常量名是因为前端调用点要能一眼看出"这是删除"。
  static const String fileDelete = files;

  // ── 设置 / 插件 / MCP ─────────────────────────────────────────────────
  static const String settingsFrameRate = '/api/settings/frame-rate';
  static const String settingsTokenRate = '/api/settings/token-rate';

  /// 心跳判活参数（M9 规约 1.1）：I = 心跳间隔（秒）、N = 连续丢失阈值（次）。
  ///
  /// 两者是**一个整体**（判活窗口 = I×N），所以两个端点同形状、都接受两个字段；
  /// 窗口必须**严格大于**前端固定 10s 的 WS 心跳（`lib/io/websocket_service.dart`），
  /// 否则"在线但空闲"的连接会被判失活并反复重连。
  static const String settingsHeartbeatInterval =
      '/api/settings/heartbeat-interval';
  static const String settingsMissedHeartbeatLimit =
      '/api/settings/missed-heartbeat-limit';

  static const String settingsDataCollection = '/api/settings/data-collection';

  // ── 发现面 / 引导壳（插件化新增，核心永久面）──────────────────────────

  /// 发现面聚合（GET）：核心版本、`api_version`、UI 连接、可订广播站、
  /// 委派路由与插件申报的 capability。
  ///
  /// 它是 UI 唯一的「我现在能用什么」探测入口（设计见
  /// `docs/pluginization/ui-pluginization.md` §3.1 / §4.1）。
  static const String meta = '/api/meta';

  /// 引导页 HTML（GET）：无「能管插件的存活 UI 连接」时由 loader 打开。
  ///
  /// **不属 `/api` 前缀**：它是核心自有的页面入口（与插件端点分属两个命名
  /// 空间），因此直接挂在根路径上。
  static const String bootstrap = '/bootstrap';

  /// 一次性票据兑换短时会话 token（POST）。
  static const String bootstrapSession = '/api/bootstrap/session';

  /// 主 token 申请一次性引导票据（POST）：loader 用它打开 `/bootstrap?t=...`。
  ///
  /// 引导会话 token **不**能申请票据（不在会话白名单里）。
  static const String bootstrapTicket = '/api/bootstrap/ticket';

  static const String pluginSnapshot = '/api/plugin/snapshot';

  /// 插件清单的**读写面**（M9 §4.2 插件开关：内置与自定义都可在前端增删改）。
  ///
  /// 与只读快照 [pluginSnapshot] 的分工：
  /// - [pluginSnapshot] 是**运行态**快照（实例 / 站点 / 看门狗 / 心跳健康度），
  ///   数据源是插件总线**启动时读进内存**的配置，落盘改动不会反映在它里面；
  /// - [pluginConfigs] 系列直接读写「<数据根>/config/plugins.yaml」（持久态），
  ///   因此"刚保存的开关状态"以这一组为准（前端两个都取：列表用这组、健康度用快照）。
  static const String pluginConfigs = '/api/plugin/configs';

  /// 单条自定义插件配置（PATCH 局部更新 / DELETE 删除）。
  static const String pluginConfig = '/api/plugin/configs/{pluginId}';

  /// 显式重启某个插件实例（调插件总线的 restart）。
  static const String pluginConfigRestart =
      '/api/plugin/configs/{pluginId}/restart';

  /// 内置插件目录（清单 + 每项的启用态 + 运行时解析结果）。
  ///
  /// 内置插件的身份来自核心的**静态清单**（builtin_plugins.dart），前端只能开关；
  /// 打开时核心把它落成一条普通插件配置（带 builtin: true 标记供 UI 分组）。
  static const String pluginBuiltins = '/api/plugin/builtins';

  /// 打开一个内置插件：解析运行时与脚本路径 → 写一条普通插件配置 → 热启动。
  static const String pluginBuiltinEnable =
      '/api/plugin/builtins/{pluginId}/enable';

  /// 关闭一个内置插件：把该条置 enabled: false 并断开——**条目保留**，
  /// 面板显示「已停用」而不是让这一项消失。
  static const String pluginBuiltinDisable =
      '/api/plugin/builtins/{pluginId}/disable';

  /// 发布仓库清单的**只读面**（GET，**不联网**）：读本地缓存的 `plugin-index.json`。
  ///
  /// 为什么单独一条而不是“GET 也顺手刷新”：面板打开就要能列出“上次看到的那些”，
  /// 而那是一个网络动作。把两者分开后，“这次没刷成功、你现在看到的是上一次那份”
  /// 可以用 `online: false` 显式说出来，而不是离线看起来像最新。
  static const String pluginRelease = '/api/plugin/release';

  /// 拉最新 release 的发布索引并缓存（POST，**联网**）：成功回清单，失败回可读原因。
  ///
  /// 只读**发布源**的 **Releases 资产**（默认 Gitee → GitHub，逐源回退；回包带
  /// `source` 说明这一版是从哪个源拿的），不 `git clone` 源码：`plugins` 仓里放的是
  /// 给人改的源码，装机端要的是发布方事先备好的成品（索引就是那张合同）。
  static const String pluginReleaseRefresh = '/api/plugin/release/refresh';

  /// 从发布仓库装一条插件（POST，`pluginId` 取自索引）。
  ///
  /// 一个动作里包含：资产进缓存 → **闸门**（旧进程确认退出才换，不为换文件而强杀）
  ///  → 复制到临时名 → 原子改名覆盖 `plugins/` → 写出待落盘条目。任一步失败都
  /// 不碰旧文件，失败原因可读（`{ok:false, error}`）。
  static const String pluginReleaseInstall =
      '/api/plugin/release/{pluginId}/install';

  /// 卸载一条插件（POST，`pluginId` 取自已装条目）。
  ///
  /// 四段顺序（用户 2026-10-18 定稿）：**停用 → 等退出确认（不强杀）→ 删
  /// `plugins/` 里的文件 → 落盘条目**。内置项的分岔只在最后一步：删文件但
  /// **条目保留并置 `enabled: false`**（回到“待从仓库装”那一格，不从面板消失）；
  /// 自定义 / 从仓库装的条目则整条删掉。闸门等不到退出确认时回 400 + 可读原因，
  /// 文件与条目一个都不动。
  static const String pluginReleaseUninstall =
      '/api/plugin/release/{pluginId}/uninstall';

  /// 从**本地 zip** 装一条插件（POST，body `{zip_path, with_dependencies?}`）。
  ///
  /// 离线包入口（known-issues #38 / acceptance L-10）：zip 必须带 `plugin.json`
  /// （与 `tool/package_ui_plugin.dart` 产物同形状）+ 全部文件；核心解到
  /// `plugins/<id>/` 后走**与仓库通道同一套**后处理（依赖闸门 → 写 plugins.yaml →
  /// 热应用）。校验失败 / 解压失败 / 闸门等不到退出 ⇒ 400 + 可读原因，旧文件不动。
  static const String pluginInstallLocal = '/api/plugin/install/local';

  /// 单个站点的**详情**（GET）：介绍 + 可订阅上限 + 共享声明 + 自定义配置 +
  /// 订阅者列表（含禁用态）。
  ///
  /// 与 [pluginSnapshot] 的 `stations` 段**同一个数据源**（`StationInstance.describe()`），
  /// 这里只是按 id 取一条——站点全局唯一，不按 team 过滤（口径见 StationHub.snapshot）。
  static const String pluginStation = '/api/plugin/stations/{stationId}';

  /// 改站点配置（PATCH，**局部更新**：只发要改的键）。
  ///
  /// 能改什么按「内置 / 自建」分开（实现与理由见 `StationHub.updateConfig`）：
  /// - `max_subscriptions`（可订阅插件数量）：内置与自建都能改；
  /// - `readme` / `config` / `shared` / `allowed_plugins`：只有插件自建站能改，
  ///   内置点位的这些定义在核心的点位表里，改它 = 把行为从代码挪到盘上 ⇒ 400 + 可读原因。
  static const String pluginStationConfig =
      '/api/plugin/stations/{stationId}/config';

  /// 禁用 / 启用某个订阅者（POST，body `{disabled: bool}`）。
  ///
  /// **不是退订**：订阅关系与回包通道都保留，只让触发时不投递，并且每条触发都在
  /// 返回值里显式回报跳过原因（`skipped` + 计数 `skipped_disabled`），不静默。
  /// [subscriberKey] 形如 `plugin_id|scope`，取自站点详情的 `subscriptions[].subscriber`；
  /// 里面带 `|`，客户端必须 `Uri.encodeComponent`（核心按路径段解码后原样比对）。
  static const String pluginStationSubscriber =
      '/api/plugin/stations/{stationId}/subscribers/{subscriberKey}';

  /// UI 窗口（**多窗口**，2026-10-25）：列出当前窗口 / 新建一个窗口。
  ///
  /// 多窗口 = 多进程：每个窗口一条 WS 连接、一份进程内状态（选中的 agent、
  /// 打开的窗口）。核心只负责进程与身份，不共享 UI 状态。
  /// - `GET`：`{windows: [{plugin_id, window_id, pid, alive, ui_hello_seen}]}`；
  /// - `POST {plugin_id}`：再拉一个窗口，回 `{ok, plugin_id, window_id, pid}`。
  ///   不是 UI / 未启用 / 依赖不满足 / 超过窗口上限 ⇒ 409。
  static const String pluginWindows = '/api/plugin/windows';

  /// 关掉某个 UI 插件的**全部窗口**（`DELETE`，UI 的「退出应用」入口）。
  ///
  /// 与「停用」不同：条目仍是 `enabled: true`，下一次对账会重新拉起。
  static const String pluginWindowsOfPlugin = '/api/plugin/windows/{pluginId}';

  static const String mcpServices = '/api/mcp/services';
  static const String mcpService = '/api/mcp/services/{name}';

  // ── 运行中工具（"工具卡住"的可见面）────────────────────────────────────

  /// 正在执行的工具快照（GET，**只读**）：`{runs:[{handle, agent_id, session_id,
  /// tool, command_preview, started_at, elapsed_ms, over_threshold}]}`。
  ///
  /// 数据源是核心的**内存登记表**（`ToolRunRegistry`）：只登记"正在跑的"，重启即清空，
  /// 不做历史运行记录。前端右栏「正在执行的 tool」页签的数据源。
  static const String toolsRunning = '/api/tools/running';

  /// 显式关闭一次运行中的工具（POST，body 无；`handle` 取自 [toolsRunning] 的列表）。
  ///
  /// 语义与执行站命令 `tool.close` **同一个实现**（先尽力终止进程树，再把这次运行从
  /// 登记表移除，并让在途工具调用收敛）；句柄失效 ⇒ 404 + 可读原因（fail-closed）。
  /// **不自动杀**：超阈值只 warning，关闭必须显式。
  static const String toolsRunningClose = '/api/tools/running/{handle}/close';

  // ── 临时员工名册（会话级，只读）──────────────────────────────────────

  /// 某个会话的**临时员工名册**（GET `?session_id=`，**只读**）。
  ///
  /// 数据源就是那份落盘名册（`data/<agentId>/<sessionId>/subagents.json`，见
  /// `store/README.md` 不变量 11）——前端"进入某个临时员工的入口"拿它当**权威来源**，
  /// 因此不会随中栏消息窗口的加载/淘汰而抖动（用户 2026-10-03）。
  /// **跨会话不保留**：只读该 `(agentId, sessionId)`，删会话即随之消失。
  static const String agentSubagents = '/api/agents/{agentId}/subagents';

  /// 某个临时员工的**全部落盘工作数据**（GET `?session_id=`，**只读**）。
  ///
  /// 对话与工具调用**本来就随会话落盘**（父会话 `messages.jsonl` 里带 `subagent_id`
  /// 标记的那一段，`store/README.md` 不变量 11），但中栏是**窗口化**加载（`lib/README.md`
  /// 不变量 19）——老过程被窗口淘汰、重启后只热末尾一段时，详情页"入口还在、点进去是空的"
  /// （用户 2026-10-11：「subagent 的工作数据不落盘，导致非常不稳定」）。这条端点补的就是
  /// **复查通路**：直读落盘、按 id 一次取全，不受窗口与历史分页影响。
  /// **跨会话不保留**照旧是硬不变量：只认该 `(agentId, sessionId)` 名册里的条目。
  static const String agentSubagentTranscript =
      '/api/agents/{agentId}/subagents/{subagentId}/transcript';

  // ── 上行改委派（插件化新增，归 tree.agent）────────────────────────────

  /// 发送一条用户消息（POST，body 与旧 WS 上行 `send_message` 同形）。
  ///
  /// 旧通道是 WS 上行帧 `user_message`（设计文档曾叫 `send_message`）；批次 G
  /// 改成**委派端点**，由 `tree.agent` 经 `system.collect.api.routes` 申报，核心
  /// **不实现**（见 `docs/pluginization/agent_pluginization.md` §1.3）。
  ///
  /// 回包定稿（G-1 C-08，见 `docs/pluginization/agent_api_contract.md` §3.2）：
  /// `200 {success:true, agent_id, session_id, session_created}`；缺 content ⇒ 400；
  /// 未知 agent ⇒ 404。
  static const String agentMessages = '/api/agents/{agentId}/messages';

  /// 取消当前生成（POST，body 无）。
  ///
  /// 旧通道是 WS 上行帧 `stop`（设计文档曾叫 `cancel`）；同上改委派，核心不实现。
  ///
  /// 回包定稿（G-1 C-08）：`200 {success:true, agent_id, cascade, cascade_ids,
  /// cancelled, idle, any_running}`——即 `_stopAgentTree` 的摘要；`sub_…` 收件人
  /// `cascade=false`，其余 `cascade=true`；未知 agent ⇒ 404。
  static const String agentCancel = '/api/agents/{agentId}/cancel';

  // ── 日志 / 存储（插件化新增，核心永久面）──────────────────────────────

  /// 日志源枚举（GET）：`{sources:[{id, kind, size?, modified?}]}`。
  ///
  /// 源 id 只有两种合法形态：`core` 与 `plugin:<插件 id>`；后者只列**已配置
  /// 或已存在日志文件**的插件（见 `docs/pluginization/ui-pluginization.md` §3.1）。
  static const String logSources = '/api/logs/sources';

  /// 单个日志源的尾部读（GET `?tail=&since=`）与清空（DELETE）。
  ///
  /// `since` 的口径是**行号**（1 起）：从第 `since` 行开始返回；回包 `next_since`
  /// 是下一次继续读时应传的行号（没有新行时等于 EOF+1；若 `since` 已越过当前
  /// EOF，例如清空后日志又从第 1 行写起，则回到 EOF+1）。`tail` 默认 200、上限
  /// 5000；单次响应硬上限 1 MiB，超限返回最后一页并带 `truncated:true`。
  static const String logSource = '/api/logs/{source}';

  /// 某个命名空间的键列表（GET `?limit=&cursor=`）。
  static const String storeNamespace = '/api/store/{ns}';

  /// 某个键的读取（GET）/ 写入（PUT）/ 删除（DELETE）。
  ///
  /// 写入是二进制原样存取（核心不解析）：已存在的键必须带 `If-Match`（或
  /// `?etag=` / `X-Tree-Etag`）做乐观锁，`*` 表示无条件覆盖；不存在的键允许
  /// 不带 etag 创建。调用方命名空间由 `X-Tree-Plugin-Id` 头判定（缺省 = `core`），
  /// `ns` 必须与调用方一致，否则一律 403（不泄露目标命名空间是否存在）。
  static const String storeEntry = '/api/store/{ns}/{key}';

  // ── 契约与方法路由集合（L-28 起：委派不再有静态白名单）─────────────────

  /// 方法路由键：`METHOD /pattern`，与 `CoreRouter.routes` 的键格式逐字一致。
  ///
  /// 契约集合（[coreOwned] / [delegated] / [pendingHandoffRoutes]）与核心
  /// 覆盖度门禁都用这个格式，避免"路径集合"与"方法路由"两种口径混用
  /// （旧文档的 88 条路径就是混用导致的错数）。
  static String routeKey(String method, String pattern) =>
      '${method.toUpperCase()} $pattern';

  /// **核心永久面：40 条方法路由。**
  ///
  /// 平台控制面 20（含 UI 多窗口 3）+ 传输设置 9 + 引导壳 3 + 发现面 1 + 日志 3
  /// + 存储 4。只增不删：交接完成后核心 router 的键集必须**恰好等于**本集合
  /// （见 `docs/pluginization/ui-pluginization.md` §4.1 / §4.5）。
  static const Set<String> coreOwned = <String>{
    // 平台控制面（20）：装插件的前提，也是引导页唯一依赖。
    'GET $pluginSnapshot',
    'GET $pluginConfigs',
    'POST $pluginConfigs',
    'PATCH $pluginConfig',
    'DELETE $pluginConfig',
    'POST $pluginConfigRestart',
    'GET $pluginBuiltins',
    'POST $pluginBuiltinEnable',
    'POST $pluginBuiltinDisable',
    'GET $pluginRelease',
    'POST $pluginReleaseRefresh',
    'POST $pluginReleaseInstall',
    'POST $pluginReleaseUninstall',
    'POST $pluginInstallLocal',
    'GET $pluginStation',
    'PATCH $pluginStationConfig',
    'POST $pluginStationSubscriber',
    // UI 多窗口（3）：进程由核心拉起，UI 自己起不了第二个进程。
    'GET $pluginWindows',
    'POST $pluginWindows',
    'DELETE $pluginWindowsOfPlugin',
    // 传输 / 判活设置（9）：交给插件会与传输层形成循环依赖。
    'GET $settingsFrameRate',
    'POST $settingsFrameRate',
    'GET $settingsHeartbeatInterval',
    'PATCH $settingsHeartbeatInterval',
    'POST $settingsHeartbeatInterval',
    'GET $settingsMissedHeartbeatLimit',
    'PATCH $settingsMissedHeartbeatLimit',
    'POST $settingsMissedHeartbeatLimit',
    'POST $settingsDataCollection',
    // 引导壳（3）。
    'GET $bootstrap',
    'POST $bootstrapSession',
    'POST $bootstrapTicket',
    // 发现面（1）。
    'GET $meta',
    // 日志 API（3）。
    'GET $logSources',
    'GET $logSource',
    'DELETE $logSource',
    // 数据存储 API（4）。
    'GET $storeNamespace',
    'GET $storeEntry',
    'PUT $storeEntry',
    'DELETE $storeEntry',
  };

  /// A5 后迁移债台账已清零：核心 router == [coreOwned] 40 条（36 + UI 多窗口 3 + 本地安装 1）。
  ///
  /// 历史：这里曾登记 52 条「核心仍实现、待交接」的域路由；A5 已删除核心实现，
  /// git 3 条也按用户决定从契约中删除。保留空集合只为兼容旧门禁形状；
  /// 若将来需要登记「无承接方的插件面」，另建语义明确的集合，不要复用本名。
  static const Set<String> pendingHandoffRoutes = <String>{};

  /// **契约中归插件的全部方法路由：55 条。**
  ///
  /// agent 37（34 存量 + 2 新增上行改委派 + 1 消息详情）+ spec 2 + mcp 3 + files 13。
  /// **git 3 已按用户决定删除**（2026-10-25）。L-28 起它不是运行期白名单：
  /// 放行由 [delegationPatternError] 的命名空间规则 + 归属表冲突检测决定；
  /// 本集合只用于契约自检与 G-1 对照。
  static const Set<String> delegated = <String>{
    // agent 定义（7）
    'GET $agents',
    'POST $agents',
    'GET $agent',
    'PATCH $agent',
    'DELETE $agent',
    'GET $agentModelsInfo',
    'GET $agentTodos',
    // 子 agent（2）
    'GET $agentSubagents',
    'GET $agentSubagentTranscript',
    // 团队（4）
    'GET $agentTeammates',
    'PATCH $teammate',
    'GET $teammateLog',
    'POST $teammateMessage',
    // 模型池（4）
    'GET $models',
    'POST $models',
    'PATCH $model',
    'DELETE $model',
    // 会话 / 历史（9）
    'GET $conversations',
    'GET $agentMessageDetail',
    'DELETE $conversations',
    'GET $agentSessions',
    'POST $agentSessions',
    'GET $agentSession',
    'PATCH $agentSession',
    'DELETE $agentSession',
    'POST $agentSessionSpecs',
    // 维护（3）
    'POST $agentReset',
    'POST $agentCompact',
    'POST $agentSshReconnect',
    // 提问（2）
    'GET $questions',
    'POST $questionAnswer',
    // 运行监督（2）
    'GET $toolsRunning',
    'POST $toolsRunningClose',
    // token 节奏（2，agent 领域设置）
    'GET $settingsTokenRate',
    'POST $settingsTokenRate',
    // 上行改委派新增（2）：替代 WS 上行 send_message / cancel，核心不实现。
    'POST $agentMessages',
    'POST $agentCancel',
    // spec（2）
    'GET $agentSpecs',
    'GET $agentSpec',
    // mcp（3）：已交接给 mcp 插件，核心不再实现。
    'GET $mcpServices',
    'POST $mcpServices',
    'DELETE $mcpService',
    // files（13）
    'GET $files',
    'DELETE $fileDelete',
    'GET $fileContent',
    'PUT $fileContent',
    'GET $filePdfInfo',
    'POST $fileUploadInit',
    'POST $fileUploadChunk',
    'POST $fileUploadComplete',
    'POST $fileSyncToLocal',
    'POST $fileDownload',
    'POST $fileDownloadFolder',
    'POST $fileMkdir',
    'POST $fileRename',
  };

  /// 契约全集（95 = [coreOwned] 40 + [delegated] 55）。
  static final Set<String> contractRoutes = <String>{
    ...coreOwned,
    ...delegated,
  };

  /// **委派保留前缀**：整段保留给核心，插件不得申报。
  ///
  /// 只保留"谁都能看出是平台控制面"的五段；其余路径交给命名空间规则，
  /// 避免每加一条插件路由都要改核心（L-28）。
  static const Set<String> reservedDelegationPrefixes = <String>{
    '/api/plugin',
    '/api/bootstrap',
    '/api/meta',
    '/api/logs',
    '/api/store',
  };

  /// 单个路径段的合法形状：字面量段或 `{name}` 占位符。
  static final RegExp _delegationSegment = RegExp(
    r'^(?:[A-Za-z0-9._~-]+|\{[A-Za-z][A-Za-z0-9_]*\})$',
  );

  /// 委派路径的**命名空间规则**：返回 null = 可申报，否则是给人看的拒收原因。
  ///
  /// 规则见 `docs/pluginization/ui-pluginization.md` §4.5：`/api/` 前缀、
  /// 段形状合法、不落在 [reservedDelegationPrefixes] 内。**不再逐条枚举**。
  static String? delegationPatternError(String pattern) {
    final String p = pattern.trim();
    if (!p.startsWith('/api/')) {
      return '路径必须以 /api/ 开头（核心页面入口 /bootstrap 不可申报）';
    }
    if (p.endsWith('/') || p.contains('//')) {
      return '路径不得以 / 结尾或包含空段';
    }
    for (final String segment in p.substring(1).split('/')) {
      if (segment.isEmpty) return '路径不得包含空段';
      if (!_delegationSegment.hasMatch(segment)) {
        return '路径段 "$segment" 含非法字符（只允许 [A-Za-z0-9._~-] 或 {name}）';
      }
    }
    for (final String prefix in reservedDelegationPrefixes) {
      if (p == prefix || p.startsWith('$prefix/')) {
        return '路径前缀 $prefix 是核心保留面，不允许插件申报';
      }
    }
    return null;
  }

  /// 方法路由的**静态契约冲突**检查：返回 null = 可申报。
  ///
  /// 与"核心当前已实现路由同键"的动态检查在 `DelegatedRouter` 里做——
  /// 核心删除实现后同一申报会自动生效，正是 L-28 要的效果。
  static String? delegationKeyError(String method, String pattern) {
    final String? shape = delegationPatternError(pattern);
    if (shape != null) return shape;
    final String key = routeKey(method, pattern);
    if (coreOwned.contains(key)) {
      return '该路由属于核心永久面（$key），不允许委派';
    }
    return null;
  }

  /// 桌面分支保留的全部路径。
  static const Set<String> kept = <String>{
    agents,
    agent,
    agentModelsInfo,
    agentTodos,
    agentTeammates,
    teammate,
    teammateLog,
    teammateMessage,
    models,
    model,
    conversations,
    agentMessageDetail,
    agentSessions,
    agentSession,
    agentSessionSpecs,
    agentSpecs,
    agentSpec,
    agentReset,
    agentCompact,
    agentSshReconnect,
    questions,
    questionAnswer,
    files,
    fileContent,
    filePdfInfo,
    fileUploadInit,
    fileUploadChunk,
    fileUploadComplete,
    fileSyncToLocal,
    fileDownload,
    fileDownloadFolder,
    fileMkdir,
    fileRename,
    // fileDelete 是 [files] 的**别名**（同一条路径，REST 按方法区分）：kept 是**路径集合**，
    // 重复列同一个字符串会让 const Set 在编译期报错，因此这里只列 files 一次。
    settingsFrameRate,
    settingsTokenRate,
    settingsHeartbeatInterval,
    settingsMissedHeartbeatLimit,
    settingsDataCollection,
    meta,
    bootstrap,
    bootstrapSession,
    bootstrapTicket,
    pluginSnapshot,
    pluginConfigs,
    pluginConfig,
    pluginConfigRestart,
    pluginBuiltins,
    pluginBuiltinEnable,
    pluginBuiltinDisable,
    pluginRelease,
    pluginReleaseRefresh,
    pluginReleaseInstall,
    pluginReleaseUninstall,
    pluginInstallLocal,
    pluginStation,
    pluginStationConfig,
    pluginStationSubscriber,
    pluginWindows,
    pluginWindowsOfPlugin,
    terminalLocalSessions,
    terminalSshSessions,
    mcpServices,
    mcpService,
    toolsRunning,
    toolsRunningClose,
    agentSubagents,
    agentSubagentTranscript,
    agentMessages,
    agentCancel,
    logSources,
    logSource,
    storeNamespace,
    storeEntry,
  };

  /// 全部路径（保留 + 账号组）。
  static const Set<String> all = <String>{...kept, ...removedWithAccounts};
}
