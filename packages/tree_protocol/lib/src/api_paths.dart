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
  static const String mcpServices = '/api/mcp/services';
  static const String mcpService = '/api/mcp/services/{name}';

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
    mcpServices,
    mcpService,
  };

  /// 全部路径（保留 + 账号组）。
  static const Set<String> all = <String>{...kept, ...removedWithAccounts};
}
