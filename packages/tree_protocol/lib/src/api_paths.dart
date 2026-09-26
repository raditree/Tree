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

  /// 手动压缩上下文（前端「压缩」按钮）。核心尚未实现：显式 501，不静默 404。
  static const String agentCompact = '/api/agents/{agentId}/compact';

  // ── 提问 ──────────────────────────────────────────────────────────────
  static const String questions = '/api/questions';
  static const String questionAnswer = '/api/questions/{qid}/answer';

  // ── 文件 / 工作空间 ───────────────────────────────────────────────────
  static const String files = '/api/files/{workspaceId}';
  static const String fileContent = '/api/files/{workspaceId}/content';
  static const String filePdfInfo = '/api/files/{workspaceId}/pdf_info';
  static const String filePdfPreview = '/api/files/{workspaceId}/pdf_preview';
  static const String fileUploadInit = '/api/files/{workspaceId}/upload_init';
  static const String fileUploadChunk = '/api/files/{workspaceId}/upload_chunk';
  static const String fileUploadComplete =
      '/api/files/{workspaceId}/upload_complete';
  static const String fileSyncToLocal = '/api/files/{workspaceId}/syncToLocal';
  static const String fileDownload = '/api/files/{workspaceId}/download';
  static const String fileDownloadFolder =
      '/api/files/{workspaceId}/download_folder';
  static const String fileUpload = '/api/files/{workspaceId}/upload';
  static const String workspaceGitLog = '/api/workspaces/{workspaceId}/git/log';
  static const String workspaceGitBranches =
      '/api/workspaces/{workspaceId}/git/branches';

  // ── 设置 / 插件 / MCP ─────────────────────────────────────────────────
  static const String settingsFrameRate = '/api/settings/frame-rate';
  static const String settingsRateLimit = '/api/settings/rate-limit';
  static const String settingsMessageCutin = '/api/settings/message-cutin';
  static const String settingsDataCollection = '/api/settings/data-collection';
  static const String pluginSnapshot = '/api/plugin/snapshot';
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
    agentCompact,
    questions,
    questionAnswer,
    files,
    fileContent,
    filePdfInfo,
    filePdfPreview,
    fileUploadInit,
    fileUploadChunk,
    fileUploadComplete,
    fileSyncToLocal,
    fileDownload,
    fileDownloadFolder,
    fileUpload,
    workspaceGitLog,
    workspaceGitBranches,
    settingsFrameRate,
    settingsRateLimit,
    settingsMessageCutin,
    settingsDataCollection,
    pluginSnapshot,
    mcpServices,
    mcpService,
  };

  /// 全部路径（保留 + 账号组）。
  static const Set<String> all = <String>{...kept, ...removedWithAccounts};
}
