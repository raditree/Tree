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
  static const String agentSessions = '/api/agents/{agentId}/sessions';
  static const String agentSession =
      '/api/agents/{agentId}/sessions/{sessionId}';
  static const String agentSessionSpecs =
      '/api/agents/{agentId}/sessions/{sessionId}/specs';
  static const String agentSpecs = '/api/agents/{agentId}/specs';
  static const String agentSpec = '/api/agents/{agentId}/specs/{specId}';

  /// 一键重置该 agent 工作空间里的系统提示词 / Spec（备份 .bak.N 后还原默认）。
  static const String agentReset = '/api/agents/{agentId}/reset';

  /// 手动压缩上下文（前端「压缩」按钮）。核心尚未实现：显式 501，不静默 404。
  static const String agentCompact = '/api/agents/{agentId}/compact';

  /// 重建该 agent 的**远端链路**（POST，无 body）：SSH 心跳判失活之后的手动恢复入口。
  ///
  /// 为什么需要它：判失活只**标记**链路已死（不关连接、不静默挂起），而一条已经断掉的
  /// TCP 连接不会自己活回来——传输层会按退避自动重连，但如果自动重连已用尽 / 用户不想等，
  /// 就要有一个**显式**入口。语义：
  /// - 200 = 已重建（响应 `{ok, agent_id, stale, missed}`，`stale` 复位为 false）；
  /// - 400 = 该 agent 不是 SSH 工作空间（本地后端没有可重连的链路）或 SSH 配置不完整；
  /// - 404 = 没有这个 agent；
  /// - 500 = 这次重连失败，`error.detail` 是**可读原因**（例如认证失败 / 主机不可达）。
  ///
  /// 判据不变：**重连不是新的判活依据**——判死仍然只认"连续 N 拍心跳丢失"（M9 规约 1.1），
  /// 重连是判死**之后**的动作，不引入任何静态时长上限。
  static const String agentSshReconnect = '/api/agents/{agentId}/ssh/reconnect';

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

  /// Git 工作区状态（GET）：{is_repo, entries: [{path, status}], truncated}。
  static const String fileGitStatus = '/api/files/{workspaceId}/git-status';

  static const String workspaceGitLog = '/api/workspaces/{workspaceId}/git/log';
  static const String workspaceGitBranches =
      '/api/workspaces/{workspaceId}/git/branches';

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
  /// 只读 GitHub **Releases 资产**，不 `git clone` 源码：`plugins` 仓里放的是给人改的
  /// 源码，装机端要的是发布方事先备好的成品（索引就是那张合同）。
  static const String pluginReleaseRefresh = '/api/plugin/release/refresh';

  /// 从发布仓库装一条插件（POST，`pluginId` 取自索引）。
  ///
  /// 一个动作里包含：资产进缓存 → **闸门**（旧进程确认退出才换，不为换文件而强杀）
  ///  → 复制到临时名 → 原子改名覆盖 `plugins/` → 写出待落盘条目。任一步失败都
  /// 不碰旧文件，失败原因可读（`{ok:false, error}`）。
  static const String pluginReleaseInstall =
      '/api/plugin/release/{pluginId}/install';

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
    fileGitStatus,
    workspaceGitLog,
    workspaceGitBranches,
    settingsFrameRate,
    settingsTokenRate,
    settingsHeartbeatInterval,
    settingsMissedHeartbeatLimit,
    settingsDataCollection,
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
    pluginStation,
    pluginStationConfig,
    pluginStationSubscriber,
    mcpServices,
    mcpService,
    toolsRunning,
    toolsRunningClose,
    agentSubagents,
    agentSubagentTranscript,
  };

  /// 全部路径（保留 + 账号组）。
  static const Set<String> all = <String>{...kept, ...removedWithAccounts};
}
