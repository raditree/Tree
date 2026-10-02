import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../agent/agent_engine.dart';
import '../agent/compaction_service.dart';
import '../agent/conversation_service.dart';
import '../agent/question_broker.dart';
import '../agent/question_store.dart';
import '../agent/scripted_agent.dart';
import '../agent/system_prompt_file.dart';
import '../agent/workspace_prompt.dart';
import '../files/file_service.dart';
import '../llm/llm_agent_engine.dart';
import '../llm/llm_json_caller.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_service.dart';
import '../plugin/builtin_plugins.dart';
import '../plugin/execute_mounts.dart';
import '../plugin/plugin_bus.dart';
import '../plugin/plugin_config_store.dart';
import '../plugin/station_scope.dart';
import '../settings/core_settings.dart';
import '../settings/ssh_config.dart';
import '../spec/builtin_spec_assets.dart';
import '../spec/spec_service.dart';
import '../store/memory_store.dart';
import '../store/tree_store.dart';
import '../team/message_dispatcher.dart';
import '../team/team_model.dart';
import '../team/team_repair.dart';
import '../team/team_service.dart';
import '../team/team_workspace.dart';
import '../tool/terminal_hooks.dart';
import '../tool/todo_store.dart';
import '../tool/tool_runner.dart';
import '../tool/workspace_tool_runner.dart';
import '../util/ids.dart';
import '../util/liveness.dart';
import '../util/token.dart';
import '../version.dart';
import '../ws/inbound_frames.dart';
import '../terminal/local_pty_starter.dart';
import '../terminal/pty_process.dart';
import '../terminal/terminal_service.dart';
import '../ws/ws_hub.dart';
import 'http_io.dart';
import 'http_router.dart';
import 'ws_liveness.dart';

/// 核心进程的回环 HTTP + WS 服务（M1 骨架）。
///
/// 设计要点（见迁移方案 §4）：
/// - **只监听 127.0.0.1**：不接受外部连接；
/// - **随机端口 + 一次性随机 token**：端口由内核分配，token 仅经 stdout
///   握手行交给父进程（不落盘），因此同机其他进程无法假冒；
/// - **协议形状与现状 server 完全一致**：lib/ui（约 15k 行）无需改动，
///   `lib/io` 只是把 baseUrl/token 换成核心下发的值；
/// - **零第三方依赖**：便于 `dart compile exe` 出单文件可执行。
///
/// 覆盖度不变量（由 `test/server_test.dart` 的覆盖度用例强制）：
/// **协议包 [ApiPaths.kept] 里的每一条路径，要么已在 [router] 实现，
/// 要么显式登记在 [stubApiPaths] 并以 501 明确拒绝**——不存在"前端会调、
/// 核心静默 404"的灰区。
class CoreServer {
  CoreServer._(
    this._http, {
    required this.processId,
    required this.token,
    required this.store,
    required this.settings,
    required this.todoStore,
    required this.teamService,
    required this.messageDispatcher,
    required this.specService,
    required this.specIoFor,
    required this.systemPromptStore,
    required this.mcpService,
    required this.pluginBus,
    required this.builtinPlugins,
    required this.pluginHotApplier,
    required this.fileService,
    this.agentBackup,
    required this.hub,
    required this.questions,
    required this.compaction,
    required this.conversation,
    required this.router,
    required this.stubRouter,
    required this.reassembler,
    required this.version,
    this.llmJsonCaller,
    this.ptyStarter,
    this.sshPtyStarter,
  }) {
    // 集成终端会话（Ctrl+J）：它要按 agent 解析工作区根，所以只在接了文件服务时可用；
    // 伪终端实现默认用平台实现（ConPTY / script），测试可注入假的。
    terminalService = fileService == null
        ? null
        : TerminalService(
            store: store,
            files: fileService!,
            startPty: ptyStarter ?? LocalPtyStarter(log: errorLog).start,
            startSshPty: sshPtyStarter,
            log: errorLog,
          );
  }

  /// WS 端点路径（前端 `WebSocketService.connect` 固定拼接 `/ws?token=`）。
  static const String wsPath = '/ws';

  /// 尚未实现、但前端会调用的路径（以 501 明确拒绝，而非静默 404）。
  ///
  /// **M7 已清空**：PDF 预览改成前端渲染（M7e 方案②，核心只给字节，见
  /// `lib/ui/widgets/pdf_preview.dart`），最后一项桩随之删除。保留这套机制给后续
  /// 新接口用——「前端会调、核心静默 404」的灰区比多条空集合更值得防。
  static const Set<String> stubApiPaths = <String>{};

  final HttpServer _http;

  /// 本进程 pid（父进程退出时兜底清理用）。
  final int processId;

  /// 本次运行的一次性本地 token。
  final String token;

  /// 存储（默认内存实现；CLI 注入 `FileTreeStore` 落 `~/.tree`）。
  final TreeStore store;

  /// 设置与模型池。
  final CoreSettings settings;

  /// 会话待办（`GET /api/agents/{id}/todos` 与 `set_todo_list` 工具共用同一份）。
  final TodoStore todoStore;

  /// WS 连接注册表与广播。
  final WsHub hub;

  /// 在线生效的 WS 判活节拍 I（= 保活定时器的实际间隔）。
  ///
  /// 启动时取自设置（或调用方显式传参），设置变更后可按需热更新（见
  /// [_applyLivenessToRunningHub]）；观测与测试读它。
  Duration _liveHeartbeatInterval = LivenessTracker.defaultInterval;

  /// 在线生效的 WS 判活阈值 N（在线连接的 `LivenessTracker.maxMisses`）。
  ///
  /// 热更新只动节拍：`maxMisses` 与 `interval` 在 [LivenessTracker] 里都是 final，
  /// 构造后改不了，所以这里记的是"在线台账真正在用的 N"。
  int _liveHeartbeatMissLimit = LivenessTracker.defaultMaxMisses;

  /// 调用方是否显式传过心跳参数（测试/调试的逃生口）：显式传参后设置不热更新——
  /// 否则一次设置变更会悄悄改掉调用方明确指定的节拍。
  bool _heartbeatPinned = false;

  /// 保活/判活是否开启：`enableHeartbeat: false` 时不热更新（那会把定时器重新打开）。
  bool _heartbeatEnabled = false;

  /// 在线生效的 WS 判活节拍（= 保活定时器实际间隔；设置变更后热更新）。
  Duration get liveHeartbeatInterval => _liveHeartbeatInterval;

  /// 在线生效的 WS 判活阈值（在线连接台账的 N；热更新不改它，见字段文档）。
  int get liveHeartbeatMissLimit => _liveHeartbeatMissLimit;

  /// 团队服务（M5b）；为 null 时不提供 teammates 路由（测试/最小骨架）。
  final TeamService? teamService;

  /// 团队消息派发（M5c）；为 null 时不提供消息/日志路由。
  final TeamMessageDispatcher? messageDispatcher;

  /// Spec 体系（M5d）；为 null 时 specs 路由返回空索引。
  final SpecService? specService;

  /// 取某 agent 的工作空间 IO（Spec 的自定义文件在工作空间里）。
  final Future<WorkspaceIO?> Function(String agentId)? specIoFor;

  /// 系统提示词存储（工作空间 `.self/system_prompt.md`）；为 null 时重置路由 503。
  final SystemPromptStore? systemPromptStore;

  /// MCP 服务（M6a）；为 null 时返回空服务列表。
  final McpService? mcpService;

  /// 插件总线（M6b）；为 null 时快照返回 `enabled: false` 空集。
  final PluginBus? pluginBus;

  /// 内置插件目录（M9 §4.2）：静态清单 + 运行时/脚本解析。
  ///
  /// 默认一份（探测 python / py -3、脚本查可执行文件同级的 plugins/）；测试注入
  /// 假的探测器与脚本目录，才能确定性地覆盖"运行时缺失 / 脚本缺失"的可读错误。
  final BuiltinPluginCatalog builtinPlugins;

  /// 热应用接缝（把"配置已落盘"翻译成"对运行中的插件总线做了什么"）。
  ///
  /// null = 用默认实现 [BusPluginHotApplier]（只用 PluginBus 的公开方法，因此
  /// "新增 / 改启动参数 / 停用"在本轮只能**如实回报**热应用失败——见该类的文档）；
  /// 测试注入假实现可以直接断言"热应用失败"这条路径。
  final PluginHotApplier? pluginHotApplier;

  /// 执行站首命令集的**挂载位置**（M9 Wave 3-I）；为 null = 未接线（命令会显式报
  /// 「暂无挂载位置」而不是静默成功）。
  ExecuteStationMounts? _stationMounts;

  /// 工作空间文件服务（M7d）；为 null 时文件路由返回 501。
  final FileService? fileService;

  /// 备份 `agents/<id>.yaml` 的回调；null = 不备份（内存 store / 测试）。
  final Future<String> Function(CoreAgent agent)? agentBackup;

  /// 集成终端会话管理（Ctrl+J）；[fileService] 未接线时为 null，终端帧会给可读错误。
  TerminalService? terminalService;

  /// 伪终端工厂（测试注入假实现；生产用平台实现，见 [LocalPtyStarter]）
  final PtyStarter? ptyStarter;

  /// 远端（SSH）伪终端工厂（生产由 CLI 注入 SshPtyAdapter.start：从缓存的那条 SSH
  /// 工作空间 IO 上取一条 shell 通道，复用同一条已建好的连接；测试注入假的）。
  ///
  /// 为 null = 远端终端未接线：远端 agent 的 terminal_open 回可读错误，**不会**
  /// 悄悄在本机给它起一个终端（判据是「有效 SSH」，见 TerminalService）。
  final SshPtyStarter? sshPtyStarter;

  /// 提问回路（M5a）；为 null 时核心不提供 `ask_user_question`（测试/最小骨架）。
  final QuestionBroker? questions;

  /// 上下文压缩（M7d-4）；为 null 时 `agentCompact` 返回 501。
  final CompactionService? compaction;

  /// 执行站命令 `llm.call` 的落点（**硬设 JSON 返回形式**的 LLM 调用）；null = 未接线。
  ///
  /// 由核心进程（CLI）构造并注入：它需要"按 modelId 解析模型 + 成员级覆盖"这两件
  /// 只有 CLI 手上的东西（与 [AgentEngine] / [CompactionService] 同一个理由）。
  final LlmJsonCaller? llmJsonCaller;

  /// 会话服务（用户消息 → 流式回复）。
  final ConversationService conversation;

  /// 已实现路由。
  final CoreRouter router;

  /// 显式登记为"未实现（501）"的路由。
  final CoreRouter stubRouter;

  /// WS 上行分片重组。
  final InboundFrameReassembler reassembler;

  /// 本实例绑定的 Spec 索引 provider（Q9）：close 时按身份解绑，
  /// 免得已关闭的核心把过期索引留在全局 provider 上。
  String Function(CoreAgent)? _specIndexBinding;

  /// 本实例绑定的「已选 Spec 全文」provider（Q9 ⑧）：同样在 close 时按身份解绑。
  String Function(CoreAgent, String)? _selectedSpecsBinding;

  /// 本实例绑定的团队工作目录 provider（成员共享 TOP 目录）：同样按身份解绑。
  TeamWorkspace? Function(CoreAgent)? _teamWorkspaceBinding;

  /// 版本号。
  final String version;

  /// 启动时刻。
  DateTime startedAt = DateTime.now();

  /// 请求级访问日志回调（CLI `--verbose` 打开；默认关闭以免刷屏）。
  void Function(String message)? accessLog;

  /// 未捕获异常日志回调（CLI 接到 stderr，始终打开）。
  ///
  /// 这条日志存在的理由：处理器在**响应已开始写出**时抛异常，兜底的 500 回包也会
  /// 失败，此时客户端只看到"连接被关掉"，错误本身只剩这里能说清楚。
  void Function(String message)? errorLog;

  void _access(HttpRequest request, int status) {
    accessLog?.call('${request.method} ${request.uri.path} -> $status');
  }

  // ── 运行统计（自检、测试与日志用） ──────────────────────────────────
  int httpRequests = 0;
  int rejectedRequests = 0;
  int stubRequests = 0;
  int notFoundRequests = 0;
  int internalErrors = 0;

  /// 实际监听端口（内核分配）。
  int get port => _http.port;

  /// 实际监听地址。
  InternetAddress get address => _http.address;

  /// 就绪握手信封（父进程据此配置 HTTP/WS 基址与 token）。
  CoreHandshake get handshake => CoreHandshake(
    host: '127.0.0.1',
    port: port,
    token: token,
    pid: processId,
    version: version,
  );

  /// 启动服务器。
  ///
  /// [port] 为 0 时由内核分配空闲端口（默认，避免固定端口冲突）。
  /// [streamChunkDelay] 是流式片段之间的延迟（测试传 `Duration.zero`）。
  ///
  /// [stationHooks] 是执行站 `terminal.exec` 要用的**后台任务管理器**；不传（null）
  /// 时核心自建一份（与 M9 之前完全一致：自建、自理完成回调、关服务时一起关）。
  /// 传了就用调用方的那一份——这样**插件下发的 hook 任务与 agent 自己起的 hook
  /// 任务共用同一张任务表**（`hook_action=status/cancel` 因此能互相看到 task_id）。
  /// 注入的实例**归调用方所有**：核心不接管它的完成回调、close 时也**不关它**
  /// （完成回调由注入方自己接，CLI 里是 `WorkspaceToolRunner.hooks.onFinished`
  /// → `tools.onHookFinished` → `conversation.wake`）。
  static Future<CoreServer> start({
    InternetAddress? address,
    int port = 0,
    String? token,
    String version = treeCoreVersion,
    Duration streamChunkDelay = const Duration(milliseconds: 40),
    bool enableHeartbeat = true,
    // 心跳判活参数（M9 规约 1.1）：默认**读设置**（用户已确认 I=10s / N=3，
    // 设置页可调）。显式传参仍是测试/调试的逃生口：传了就以传的为准，且不参与
    // 运行期热更新（见 [_applyLivenessToRunningHub]）。
    Duration? heartbeatInterval,
    int? heartbeatMissLimit,
    TreeStore? store,
    CoreSettings? settings,
    TodoStore? todoStore,
    AgentEngine? engine,
    QuestionBroker? questions,
    TeamService? teamService,
    TeamMessageDispatcher? messageDispatcher,
    SpecService? specService,
    Future<WorkspaceIO?> Function(String agentId)? specIoFor,
    SystemPromptStore? systemPromptStore,
    McpService? mcpService,
    PluginBus? pluginBus,
    BuiltinPluginCatalog? builtinPlugins,
    PluginHotApplier? pluginHotApplier,
    FileService? fileService,
    /// 备份 `agents/<id>.yaml` 的回调（工作目录镜像写盘前留底）。
    ///
    /// 与 team 自愈同约定：核心要改某个 agent 的 yaml 就先把它备份成 `.bak.<n>`。
    /// 由 CLI 传 `backupAgentFile`（只有它知道数据根）；null = 不备份（测试）。
    Future<String> Function(CoreAgent agent)? agentBackup,
    CompactionService? compaction,
    TerminalHooks? stationHooks,
    LlmJsonCaller? llmJsonCaller,
    PtyStarter? ptyStarter,
    SshPtyStarter? sshPtyStarter,
  }) async {
    final HttpServer http = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    // 静态方法内 `pid` 即 `dart:io` 顶层 getter（本类字段名为 processId，无遮蔽）
    final int currentPid = pid;
    final TreeStore resolvedStore = store ?? MemoryStore();
    final CoreSettings resolvedSettings = settings ?? CoreSettings();
    final TodoStore resolvedTodos = todoStore ?? MemoryTodoStore();
    // 心跳判活参数默认取设置（I=10s / N=3）：设置层保证 I×N **严格大于**前端固定的
    // 10s WS 心跳（见 CoreSettings.minLivenessWindowSeconds），否则"在线但空闲"的
    // 连接会被误判失活。连续 [resolvedHeartbeatMissLimit] 拍收不到任何入站帧才判失活，
    // 详见 LivenessWsHub 的类文档。
    final bool heartbeatPinned =
        heartbeatInterval != null || heartbeatMissLimit != null;
    final Duration resolvedHeartbeatInterval =
        heartbeatInterval ?? resolvedSettings.heartbeatInterval;
    final int resolvedHeartbeatMissLimit =
        heartbeatMissLimit ?? resolvedSettings.missedHeartbeatLimit;
    final LivenessWsHub hub = LivenessWsHub(
      interval: resolvedHeartbeatInterval,
      maxMisses: resolvedHeartbeatMissLimit,
    );
    final CoreServer server = CoreServer._(
      http,
      processId: currentPid,
      token: token ?? CoreToken.generate(),
      store: resolvedStore,
      settings: resolvedSettings,
      todoStore: resolvedTodos,
      teamService: teamService,
      messageDispatcher: messageDispatcher,
      specService: specService,
      specIoFor: specIoFor,
      systemPromptStore: systemPromptStore,
      mcpService: mcpService,
      pluginBus: pluginBus,
      builtinPlugins: builtinPlugins ?? BuiltinPluginCatalog(),
      // 默认热应用 = 总线公开面实现；总线为空时也用同一份（apply 前会先判空）
      pluginHotApplier:
          pluginHotApplier ??
          (pluginBus == null ? null : BusPluginHotApplier(pluginBus)),
      fileService: fileService,
      agentBackup: agentBackup,
      compaction: compaction,
      llmJsonCaller: llmJsonCaller,
      ptyStarter: ptyStarter,
      sshPtyStarter: sshPtyStarter,
      hub: hub,
      questions: questions,
      conversation: ConversationService(
        store: resolvedStore,
        hub: hub,
        settings: resolvedSettings,
        questions: questions,
        compaction: compaction,
        engine: engine ?? ScriptedAgent(chunkDelay: streamChunkDelay),
      ),
      router: CoreRouter(),
      stubRouter: CoreRouter(),
      reassembler: InboundFrameReassembler(),
      version: version,
    );
    // 记录"在线生效"的判活参数：设置变更时用它判断能不能热更新节拍，也是观测/
    // 测试的读数点（见 liveHeartbeatInterval / liveHeartbeatMissLimit）。
    server._heartbeatPinned = heartbeatPinned;
    server._heartbeatEnabled = enableHeartbeat;
    server._liveHeartbeatInterval = resolvedHeartbeatInterval;
    server._liveHeartbeatMissLimit = resolvedHeartbeatMissLimit;
    // Q9：Spec 索引注入系统提示词。做成**可设置的 provider**（而不是给
    // `systemPromptWithWorkspace` 加参数）是因为提示词在会话生成与压缩估算两处
    // 拼装，两处必须逐字一致；provider 让它们自动同口径，也不需要改会话服务。
    // `ioFor` 让索引在没有快照时（例如首个会话）能在后台补一次全量扫描。
    if (specService != null) {
      final SpecService specs = specService;
      specs.ioFor = specIoFor;
      // 选中内置规范时要播种到工作空间的**随附文档**（插件开发指南）：原件在核心
      // 所在机器上（发行布局的应用目录 plugins/、开发态的仓库 docs/），解析与搬运
      // 归 plugin 侧，所以在这里接线。取不到原件时只记日志 + 如实回报，不阻断 select。
      specs.seedAssetsFor = seedBuiltinSpecAssets;
      // agent 不属于这个 SpecService 的 store（同进程里可能有另一个核心/测试服务器）
      // 时不注入：否则会把别的 store 的索引写进当前提示词。
      String binding(CoreAgent agent) => specs.store.agent(agent.id) == null
          ? ''
          : specs.indexSnapshot(agent.id);
      server._specIndexBinding = binding;
      specIndexProvider = binding;
      // Q9 ⑧：已选 Spec 全文（本会话挂的 hook）。`selected_spec_ids` 是**会话级**的，
      // 所以这个 binding 多带一个 sessionId；没有它，`spec select` 对上下文就没有
      // 持续影响（压缩一轮后规范正文再也回不来）。
      String selectedBinding(CoreAgent agent, String sessionId) =>
          specs.store.agent(agent.id) == null
          ? ''
          : specs.selectedSpecsSnapshot(agent.id, sessionId);
      server._selectedSpecsBinding = selectedBinding;
      selectedSpecsProvider = selectedBinding;
      // 拼上下文前先把 ⑦/⑧ 快照热起来：冷热形态切换会让 `[0] system` 换字节，
      // 而它在消息最前面 ⇒ 整条前缀缓存作废（known-issues #8）。
      server.conversation.promptStatePrewarm =
          (String agentId, String sessionId) async {
            if (specs.store.agent(agentId) == null) return;
            await specs.ensureSnapshots(agentId, sessionId);
          };
    }
    // 团队工作目录（2026-10-02 用户定夺）：**成员与团队 TOP 共享同一个工作目录**，
    // 不再是"每个成员一个 workspaces/<member_id>"。提示词在会话生成与压缩估算两处
    // 拼装（必须逐字一致），而"一路向上找到 TOP"要查 store ⇒ 与 spec 同范式用 provider；
    // 返回 null = 不接管（旧口径：agent 自己的 workspace_dir）。
    // agent 不属于本实例的 store 时不接管：否则会把别的 store 的团队结构写进提示词。
    TeamWorkspace? teamBinding(CoreAgent agent) => server.store.agent(agent.id) == null
        ? null
        : teamWorkspaceFor(agent, server.store.agent);
    server._teamWorkspaceBinding = teamBinding;
    teamWorkspaceProvider = teamBinding;
    // 判死与恢复都要**可见**、要能触发补发（不静默）：
    // - 判死：写错误日志 + 关连接（前端会自动重连，这就是"触发重连"）；
    // - 恢复：把消息派发侧在失活期间登记的待补发消息补出去；
    // - 派发侧活性：接上"全体连接"级别的台账（心跳丢失 ⇒ 派发显式报错 + 登记补发）。
    hub.onStale = (String connectionId, LivenessTracker beat) {
      final String text = server._livenessLogText(beat);
      server.errorLog?.call('WS 连接 $connectionId $text');
    };
    hub.onLinkStale = (LivenessTracker beat) {
      final String text = server._livenessLogText(beat);
      server.errorLog?.call('WS 链路 $text');
    };
    hub.onLinkRecovered = () {
      final TeamMessageDispatcher? dispatcher = messageDispatcher;
      if (dispatcher == null) return;
      unawaited(dispatcher.flushPendingResends());
    };
    // 调用方自带台账时不覆盖（??=），只补空缺
    messageDispatcher?.linkLiveness ??= hub.linkLiveness;
    // M9 Wave 3-I：执行站挂载位置 + 运行期四元组（站点隔离的运行期依据）。
    // Wave 3-I 第 2 条：工具层把它的 hooks 传进来 ⇒ 插件与 agent 共用一张任务表。
    server._wirePluginStations(stationHooks: stationHooks);
    server._registerRoutes();
    server._registerStubRoutes();
    if (enableHeartbeat) {
      hub.startHeartbeat(interval: resolvedHeartbeatInterval);
    }
    http.listen(server._dispatch, onError: (Object _) {}, cancelOnError: false);
    return server;
  }

  /// 关闭服务并释放全部连接（幂等）。
  Future<void> close({bool force = true}) async {
    conversation.dispose();
    questions?.dispose();
    // 引擎可能持有 HTTP 连接池（真实 LLM 传输层）：随服务一起释放
    await conversation.engine.close();
    reassembler.clear();
    await hub.closeAll();
    await mcpService?.close();
    // 执行站挂载位置：只释放它**自建**的后台任务管理器（外部注入的那一份归注入方
    // 所有——CLI 里由 WorkspaceToolRunner.close() 关，这里重复关会把共用任务表清空）
    // 终端会话先收：别把孤儿 shell 留在用户的工作区里
    await terminalService?.closeAll();
    await _stationMounts?.close();
    await pluginBus?.close();
    // 总结器可能持有自己的 HTTP 连接池（与引擎的池分开）：随服务一起释放
    await compaction?.dispose();
    // 执行站 `llm.call` 的调用器同样自带连接池（与引擎的池分开）
    await llmJsonCaller?.close();
    // 先把在途落盘任务写完再关闭监听（write-behind 的收尾）
    await questions?.questions.flush();
    await store.flush();
    // Q9：绑定还在自己身上才解绑（别的核心实例可能已经接管了全局 provider）
    if (identical(specIndexProvider, _specIndexBinding)) {
      specIndexProvider = null;
    }
    if (identical(selectedSpecsProvider, _selectedSpecsBinding)) {
      selectedSpecsProvider = null;
    }
    if (identical(teamWorkspaceProvider, _teamWorkspaceBinding)) {
      teamWorkspaceProvider = null;
    }
    await _http.close(force: force);
  }

  // ── 站点接线（M9 Wave 3-I） ───────────────────────────────────────────

  /// 执行站首命令集的**挂载位置** + 插件总线需要的**运行期四元组**。
  ///
  /// 站点体系的两条硬要求都在这里落地：
  /// 1. 「执行器只是执行站的一种挂载位置」——八条命令（fs.* / terminal.exec /
  ///    agent.*）接到核心的既有实现上，不再出现「暂无挂载位置」；
  /// 2. plan §1.2 的隔离四元组在**运行期**解析：team 取 agent 的归属、mode_key 取
  ///    agent 的工作空间模式（local | ssh），因此 SSH 团队的命令不会打到本地工作空间。
  ///
  /// 未接线（pluginBus 为空）时什么都不做；工具层与 REST 路径不受影响。
  ///
  /// [stationHooks] 见 [start]：null = 自建一份（完成回调接 [ConversationService.wake]），
  /// 非 null = **与工具层共用**调用方那一份（插件命令与 agent 的工具调用因此看到同一张
  /// 任务表；完成回调归注入方，核心不接管、close 也不关它）。
  void _wirePluginStations({TerminalHooks? stationHooks}) {
    final PluginBus? bus = pluginBus;
    if (bus == null) return;
    // agent 工具调用事件 → 插件（Q8：轮次上限删掉后，限制能力交给插件：插件自己数
    // 轮次，超限时用执行站的 agent.stop 发停止信号）。未接线 = no-op，与改动前一致。
    conversation.agentEvents.sink = bus.dispatchAgentEvent;
    // 调用点上下文：team 取 agent 的团队归属（agent / session 由调用点给）
    bus.callSiteContext ??= (String agentId, String sessionId) {
      final CoreAgent? agent = store.agent(agentId);
      // 顶层 agent 的 team_id 为空 ⇒ **它自己就是团队**（与 TeamService.teamIdOf
      // 和站点预建的 keying 同口径）；成员则用它的 team_id。
      final String team = agent == null
          ? ''
          : (agent.teamId.trim().isEmpty ? agent.id : agent.teamId.trim());
      return StationScopeContext(
        teamId: team,
        agentId: agentId,
        sessionId: sessionId,
      );
    };
    // mode_key 的运行期来源：agent 有没有配 SSH 决定它属于哪个工作面
    bus.agentModeKeyResolver ??= (String agentId) =>
        store.agent(agentId)?.sshConfig != null
        ? StationModeKey.ssh
        : StationModeKey.local;
    // wait_for 的成员活性探针（M9 §1.1）：成员不存在 = 明确失联；在途生成 = 明确
    // 活着；其余（刚派活尚未接单 / 已干完）**不判死**，交给启动宽限判据。
    messageDispatcher?.memberLiveness ??= (String agentId) {
      final CoreAgent? member = store.agent(agentId);
      if (member == null) {
        return const MemberLivenessState.lost('成员已不存在（可能已被移除）');
      }
      if (conversation.isRunning(agentId)) {
        return const MemberLivenessState.alive(detail: '成员在途生成');
      }
      return const MemberLivenessState.unknown();
    };
    final ExecuteStationMounts mounts = ExecuteStationMounts.forStore(
      store: store,
      // 工作空间 IO = 工具层同一份解析（local / SSH 都走既有抽象）
      ioFor: (String agentId) async {
        final Future<WorkspaceIO?> Function(String agentId)? resolver =
            specIoFor;
        if (resolver == null) return null;
        return resolver(agentId);
      },
      // 后台任务管理器：没注入就自建，并把它完成回调接到会话唤醒（下面这条
      // onHookFinished 只对**自建**的那一份生效；注入的那份由注入方接回调——
      // 在 CLI 里是 WorkspaceToolRunner.hooks.onFinished → tools.onHookFinished
      // → conversation.wake，语义与自建路径一致）。
      hooks: stationHooks,
      onHookFinished: (String agentId, String sessionId, String notice) {
        unawaited(
          conversation
              .wake(agentId: agentId, sessionId: sessionId, notice: notice)
              .catchError((Object error) {
                errorLog?.call('terminal hook 唤醒失败（$agentId）：$error');
              }),
        );
      },
      messageSender: _stationDeliverMessage,
      agentStopper: (String agentId, {required bool cascade}) async =>
          _stopAgentTree(agentId, cascade: cascade),
      compactor: _stationCompact,
      // 点位化新增的三条命令（llm.call / tool.call / session.rename）：
      // 工具执行器优先取引擎手上那一份（与模型调用工具**同一条路径**）；
      // 没接线时命令以「未接线」显式失败，不做静默降级。
      llmCaller: _stationLlmCall,
      toolCaller: _stationToolCall,
      sessionRenamer: _stationRenameSession,
      log: (String message) => errorLog?.call('[core:station] $message'),
    );
    _stationMounts = mounts;
    // M9 §3「三站系统自带」+ 用户预期：内置三站原本是**懒创建**的（首次使用时才
    // 实例化），于是"没配插件 / 没人用过"时面板上就是「站点（0）」，与「三站默认
    // 设在系统中」不符。这里在站点接线处确保三站存在。
    //
    // **站点全局唯一**（用户定稿语义）：每类站一个实例，id 是类型常量，与 team /
    // agent / mode 无关——所以这里不再需要（也不该）读存储里的 team 组合去预建。
    // 新建 agent 不会、也不该产生新站点。
    //
    // 幂等 + 持久化由 StationHub.ensureBuiltinStations 保证：已从 stations.yaml
    // 恢复的不再新建、也不重复落盘；只有真的新建了才写一次盘。
    // **收集站不预建**：它的 schema 是接入点定义的输入格式（见该方法的 dartdoc）。
    final List<String> prebuiltStations = bus.stations.ensureBuiltinStations();
    if (prebuiltStations.isNotEmpty) {
      errorLog?.call(
        '[core:station] 预建内置站 '
        '${prebuiltStations.length} 个：${prebuiltStations.join('、')}',
      );
    }
    // 运行期四元组就绪 = 工具表的失效点：下次刷新点按**真实工作面**（local/ssh）
    // 重新收集一次（CLI 里 plugins.start() 早于本接线，那次用的是声明里的 mode）。
    bus.invalidateToolTable(reason: '站点接线完成（运行期四元组就绪）');
    final String? mountError = bus.mountExecuteStations(mounts);
    if (mountError != null) {
      errorLog?.call('执行站挂载位置接线不完整：$mountError');
    }
    _wirePluginRelayPoints(bus);
  }

  /// **点位化（2026-10-01）：把 LLM 侧的中转点接上插件总线**。
  ///
  /// 引擎（LLM 会话 / 系统提示词构造）与压缩服务都**不认识插件总线**，插件总线也
  /// 拿不到它们；核心是唯一同时够得着两边的地方，所以接线放在这里——与
  /// [LlmAgentEngine.toolTurnCompactor] 同一个范式（可写字段 + 显式接线点）。
  ///
  /// 接上之后的行为：
  /// - `system.relay.llm.handle`：插件可接管某一跳的 LLM 响应（含流式回填）；
  /// - `system.relay.llm.request`：插件可改写即将投出的请求体；
  /// - `system.relay.prompt.system`：插件可改写本轮系统提示词；
  /// - `system.relay.context.compact`：插件可产出**整份新上下文**（规划也归它，
  ///   替代内置 compact）。
  ///
  /// 全部 fail-open：无订阅者 / 未回填 / 异常 ⇒ 与接线前**逐字一致**的行为。
  void _wirePluginRelayPoints(PluginBus bus) {
    final AgentEngine engine = conversation.engine;
    if (engine is LlmAgentEngine) {
      engine.llmTurnHandler = bus.relayLlmHandle;
      engine.llmRequestRewriter = bus.relayLlmRequest;
      engine.systemPromptRelay = bus.relaySystemPrompt;
    }
    conversation.compaction?.relayHook = bus.relayCompaction;
  }

  /// 执行站 `llm.call`：用目标 agent 的模型发一次**硬设 JSON 返回形式**的调用。
  ///
  /// agent 的 modelId 在核心侧解析（`store.agent(...).modelId`），模型池与成员级
  /// 覆盖由注入的 [llmJsonCaller] 负责——**与对话完全同一条解析路径**。
  Future<Map<String, dynamic>> _stationLlmCall({
    required String agentId,
    List<Object?>? messages,
    String? prompt,
    String? system,
    String? model,
    double? temperature,
    int? maxTokens,
    List<Object?>? tools,
  }) async {
    final LlmJsonCaller? caller = llmJsonCaller;
    if (caller == null) {
      return const <String, dynamic>{'error': 'llm.call 未接线：核心未注入 LLM 调用器'};
    }
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) {
      return <String, dynamic>{'error': 'agent 不存在：$agentId'};
    }
    return caller.call(
      agentId: agentId,
      modelId: agent.modelId,
      messages: messages,
      prompt: prompt,
      system: system,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      tools: tools,
    );
  }

  /// 执行站 `tool.call`：执行**任意工具**（内置 / MCP / 插件工具同一入口）。
  ///
  /// 默认 `relay: false`（绕开工具中转与广播）——理由见
  /// [WorkspaceToolRunner.runFromPlugin] 的自锁说明；要审计自己的调用就显式
  /// `relay: true`。**权限口径不变**：与模型调用工具同一条路径、同一份工作空间解析。
  Future<ToolOutcome> _stationToolCall({
    required String agentId,
    required String sessionId,
    required String tool,
    required Map<String, dynamic> arguments,
    required String sourcePluginId,
    required bool relay,
  }) async {
    final WorkspaceToolRunner? runner = _runnerFromEngine();
    if (runner == null) {
      return const ToolOutcome(
        'tool.call 未接线：核心未接入工具执行器（真实 LLM 引擎不可用）',
        isError: true,
      );
    }
    return runner.runFromPlugin(
      ToolInvocation(
        id: CoreIds.next('call'),
        name: tool,
        arguments: arguments,
        agentId: agentId,
        sessionId: sessionId,
      ),
      sourcePluginId: sourcePluginId,
      relay: relay,
    );
  }

  /// 引擎手上的工具执行器（`tool.call` 的落点）；不是真实运行器时返回 null。
  ///
  /// 为什么不给 CoreServer 直接注入工具运行器：引擎已经持有它，而"模型的工具调用"
  /// 与"插件经执行站的工具调用"必须是**同一个实例**（工作空间解析、MCP/插件工具
  /// 分派、后台任务表都在它身上），多注一份就有两个真相。
  WorkspaceToolRunner? _runnerFromEngine() {
    final AgentEngine engine = conversation.engine;
    if (engine is LlmAgentEngine && engine.toolRunner is WorkspaceToolRunner) {
      return engine.toolRunner as WorkspaceToolRunner;
    }
    return null;
  }

  /// 执行站 `session.rename`：与 REST `PATCH …/sessions/{id}` **同一 store 实现**。
  ///
  /// 改名成功后向前端发一条下行帧，让界面上的会话标题即时更新（REST 路径是前端
  /// 自己 setState，插件改名没有这条路径）。
  Future<Map<String, dynamic>> _stationRenameSession({
    required String agentId,
    required String sessionId,
    required String title,
  }) async {
    final bool renamed = store.renameSession(agentId, sessionId, title);
    if (!renamed) {
      return <String, dynamic>{'error': '会话不存在或未改名：$agentId/$sessionId'};
    }
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.sessionRenamed,
      'data': <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
        'title': title,
      },
    });
    return <String, dynamic>{'renamed': true};
  }

  /// 执行站 `agent.message`：插件 → 目标 agent 的会话。
  ///
  /// 首选团队派发（过审核闸门、写活动日志、链路失活时登记补发）；没有派发服务时
  /// 退回会话投递（把来源插件写在发送者位上，模型知道是谁发的）。
  Future<Map<String, dynamic>> _stationDeliverMessage({
    required String agentId,
    required String sessionId,
    required String content,
    String sourcePluginId = '',
  }) async {
    final CoreAgent? target = store.agent(agentId);
    if (target == null) {
      return <String, dynamic>{'error': '目标 agent 不存在：$agentId'};
    }
    final TeamMessageDispatcher? dispatcher = messageDispatcher;
    if (dispatcher != null) {
      // 插件不是团队成员：走用户侧入口（有审核闸门，且不会 auto_reply 回传给任何人）
      return dispatcher.sendFromUser(
        targetId: agentId,
        content: content,
        sessionId: sessionId,
      );
    }
    final String sender = sourcePluginId.isEmpty ? '插件' : '插件 $sourcePluginId';
    try {
      await conversation.deliver(
        agentId: agentId,
        sessionId: sessionId,
        content: content,
        senderName: sender,
      );
    } catch (error) {
      return <String, dynamic>{'error': '会话投递失败：$error'};
    }
    return <String, dynamic>{
      'success': true,
      'detail': <String, dynamic>{
        'target': agentId,
        'session_id': sessionId,
        'sender': sender,
      },
    };
  }

  /// 执行站 `agent.compact`：手动压缩（与 REST 的 compact 同一服务，同样拒绝在途
  /// 生成期间的压缩——压缩会改写上下文，与生成并发读写不安全）。
  Future<Map<String, dynamic>> _stationCompact(
    String agentId,
    String sessionId,
  ) async {
    final CompactionService? service = compaction;
    if (service == null) {
      return <String, dynamic>{'error': '上下文压缩尚未接入'};
    }
    if (conversation.isRunning(agentId)) {
      return <String, dynamic>{
        'error': 'agent 正在生成：压缩会改写上下文，与生成并发读写不安全',
        'reason': 'agent_working',
      };
    }
    _broadcastCompactStatus(agentId, sessionId, 'compacting');
    try {
      final CompactionResult result = await service.compact(agentId, sessionId);
      if (result.error.isNotEmpty) {
        return <String, dynamic>{
          'error': result.error,
          'status': result.status,
        };
      }
      return result.toJson();
    } finally {
      _broadcastCompactStatus(
        agentId,
        sessionId,
        conversation.isRunning(agentId) ? 'working' : 'idle',
      );
    }
  }

  // ── 请求分发 ─────────────────────────────────────────────────────────

  void _dispatch(HttpRequest request) {
    unawaited(
      _handle(request).catchError((Object error, StackTrace stack) async {
        internalErrors++;
        _access(request, 500);
        errorLog?.call(
          '未捕获异常：${request.method} ${request.uri.path} -> $error\n$stack',
        );
        try {
          await writeJson(request, 500, errorBody('核心进程内部错误：$error'));
        } catch (_) {
          // 响应已关闭：无法回包，仅计数（错误已由 errorLog 记下）
        }
      }),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    httpRequests++;
    if (request.uri.path == wsPath) {
      await _handleWebSocket(request);
      return;
    }
    if (!CoreToken.matchesAuthorization(
      token,
      request.headers.value(HttpHeaders.authorizationHeader),
    )) {
      rejectedRequests++;
      _access(request, 401);
      await writeJson(request, 401, errorBody('本地 token 无效'));
      return;
    }
    final List<String> segments = request.uri.pathSegments;
    // 先匹配已实现路由，再匹配"显式登记为未实现"的桩路由；两者由
    // `server_test` 的覆盖度用例保证不相交且并集覆盖 ApiPaths.kept。
    final HttpRouteMatch? match =
        router.match(request.method, segments) ??
        stubRouter.match(request.method, segments);
    if (match != null) {
      await match.route.handler(request, match.params);
      _access(request, request.response.statusCode);
      return;
    }
    notFoundRequests++;
    _access(request, 404);
    await writeJson(request, 404, errorBody('未知接口：${request.uri.path}'));
  }

  // ── WebSocket ────────────────────────────────────────────────────────

  Future<void> _handleWebSocket(HttpRequest request) async {
    if (!CoreToken.matches(token, request.uri.queryParameters['token'])) {
      rejectedRequests++;
      _access(request, 401);
      await writeJson(request, 401, errorBody('本地 token 无效'));
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      _access(request, 400);
      await writeJson(request, 400, errorBody('该端点需要 WebSocket 升级握手'));
      return;
    }
    final WebSocket socket = await WebSocketTransformer.upgrade(request);
    final WsConnection connection = _createConnection(socket);
    hub.register(connection);
    // 101 = Switching Protocols（升级成功的 HTTP 语义状态码）
    _access(request, 101);
    socket.listen(
      (dynamic data) => _handleWsFrame(connection, data),
      onDone: () {
        // 连接断了就把它开的终端收掉：否则会留下孤儿 shell 占着工作区
        unawaited(
          terminalService?.closeForConnection(connection.id) ??
              Future<void>.value(),
        );
        hub.unregister(connection.id);
      },
      onError: (Object _) => hub.unregister(connection.id),
      cancelOnError: true,
    );
    // **插件面板补发**：插件的槽位声明是"启动时发一次"的，前端刷新 / 重连 / 启动
    // 竞态错过就再也拿不到（注册表是内存态）。核心缓存了每个插件最后一个生效的 UI
    // 帧（PluginBus.uiCache），这里在连接就绪后只发给**这一条新连接**：重放是幂等
    // 的（前端整块覆盖），但绝不能广播——否则每次有人重连都会给其他连接重刷一遍。
    _replayPluginUi(connection);
  }

  /// 建连接：核心默认用带活性观测的 [LivenessWsConnection]（M9 1.1）；
  /// 注入普通 [WsHub] 的调用方退回基类连接（行为与旧版完全一致）。
  WsConnection _createConnection(WebSocket socket) {
    final WsHub registry = hub;
    if (registry is LivenessWsHub) return registry.createConnection(socket);
    return WsConnection(socket: socket);
  }

  /// 把已缓存插件 UI 帧重放给**刚注册的那一条连接**。
  ///
  /// 只发新连接，不走 [WsHub.broadcast]：重放对前端是幂等的，但广播会让每次重连
  /// 都扰动其他已经正确的连接。未接 [pluginBus]（或插件系统关闭）时什么都不做。
  void _replayPluginUi(WsConnection connection) {
    final PluginBus? bus = pluginBus;
    if (bus == null) return;
    for (final Map<String, dynamic> frame in bus.uiCache.frames()) {
      connection.send(frame);
    }
  }

  void _handleWsFrame(WsConnection connection, dynamic data) {
    // 收到**任意**入站帧（业务帧、心跳帧、分片帧……）= 链路还在 ⇒ 续期。
    // 这就是连接活性心跳的观测点：判据只在这里与保活定时器里产生，不看"上次发送
    // 过了多久"，因此不存在任何静态发送超时（M9 规约 1.1）。
    if (connection is LivenessWsConnection) connection.recordBeat();
    Map<String, dynamic>? frame = _decodeFrame(data.toString());
    if (frame == null) return;
    // 传输层分片：先重组为完整 JSON 文本，再走业务分发
    if (InboundFrameReassembler.isChunkFrame(frame)) {
      final String? complete = reassembler.accept(frame);
      if (complete == null) return;
      frame = _decodeFrame(complete);
      if (frame == null) return;
    }
    switch (frame['type'] as String? ?? '') {
      case WsInboundType.heartbeat:
        connection.send(<String, dynamic>{'type': WsOutboundType.heartbeat});
        break;
      case WsInboundType.userMessage:
        unawaited(conversation.handleUserMessage(frame));
        break;
      case WsInboundType.stop:
        _handleStop(connection, frame);
        break;
      // 说明（M7c）：`register_*_executor` / `unregister_*_executor` 已随"前端执行器"
      // 一起删除——桌面端工具由核心本机执行，不存在委托前端执行这回事。
      case WsInboundType.userAnswer:
        // 作答必须放进 `data` 子对象（前端 message_panel 的口径）；顶层回退
        // 只是兼容手段。
        if (!conversation.handleUserAnswer(frame)) {
          connection.send(<String, dynamic>{
            'type': WsOutboundType.error,
            'data': <String, dynamic>{'message': '没有等待回答的问题'},
          });
        }
        break;
      case WsInboundType.cancelQuestion:
        if (!conversation.handleCancelQuestion(frame)) {
          connection.send(<String, dynamic>{
            'type': WsOutboundType.error,
            'data': <String, dynamic>{'message': '没有等待回答的问题'},
          });
        }
        break;
      case WsInboundType.pluginUiAction:
        _handlePluginUiAction(connection, frame);
        break;
      // ── 集成终端（Ctrl+J） ──────────────────────────────────────────
      // 四条都要显式处理：静默忽略会让用户对着打不了字的终端猜（完备性门禁也拦）。
      case WsInboundType.terminalOpen:
        final TerminalService? terminals = terminalService;
        if (terminals == null) {
          connection.send(<String, dynamic>{
            'type': WsOutboundType.terminalError,
            TerminalFrame.terminalId:
                (frame[TerminalFrame.terminalId] ?? '').toString(),
            TerminalFrame.message: '核心未接线文件服务，终端不可用',
          });
        } else {
          unawaited(terminals.open(connection, frame));
        }
        break;
      case WsInboundType.terminalInput:
        unawaited(terminalService?.input(frame) ?? Future<void>.value());
        break;
      case WsInboundType.terminalResize:
        unawaited(terminalService?.resize(frame) ?? Future<void>.value());
        break;
      case WsInboundType.terminalClose:
        unawaited(
          terminalService?.closeFromFrame(frame) ?? Future<void>.value(),
        );
        break;
      default:
        // 未知帧静默忽略（前向兼容：新前端配旧核心不应崩溃）
        break;
    }
  }

  /// 插件 UI 交互回调（Q12）：把前端在插件槽位上的动作转给**声明该槽位的插件**。
  ///
  /// 路由依据只有帧里的 plugin_id（槽位自带优先，缺省回落帧级——前端注册表已经
  /// 按槽位做过 team 隔离，这里不替插件推断归属）；核心**不解释动作语义**，
  /// slot_key / action_id / payload 原样透传，插件收到后自行响应（通常是再推一帧
  /// plugin_ui_update 刷新槽位）。插件不在线时**显式回一帧 error 并记日志**，
  /// 不静默丢弃——否则用户点了按钮会「没有任何反应」。
  void _handlePluginUiAction(
    WsConnection connection,
    Map<String, dynamic> frame,
  ) {
    final Map<String, dynamic> data =
        (frame['data'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
        frame;
    final String pluginId = (data['plugin_id'] ?? '').toString().trim();
    final PluginBus? bus = pluginBus;
    if (pluginId.isEmpty || bus == null) {
      connection.send(<String, dynamic>{
        'type': WsOutboundType.error,
        'data': <String, dynamic>{'message': '插件交互未送达：缺少 plugin_id 或插件总线未启用'},
      });
      return;
    }
    for (final entry in bus.instances()) {
      if (entry.pluginId != pluginId) continue;
      entry.host.dispatchEvent(<String, dynamic>{
        'event': WsInboundType.pluginUiAction,
        'plugin_id': pluginId,
        'team_id': data['team_id'] ?? '',
        'agent_id': data['agent_id'] ?? '',
        'session_id': data['session_id'] ?? '',
        'slot_key': data['slot_key'] ?? '',
        'action_id': data['action_id'] ?? '',
        'payload': data['payload'] ?? const <String, dynamic>{},
      });
      return;
    }
    errorLog?.call('插件交互未送达：插件 $pluginId 未运行（slot_key=${data['slot_key']}）');
    connection.send(<String, dynamic>{
      'type': WsOutboundType.error,
      'data': <String, dynamic>{'message': '插件 $pluginId 未运行，交互未送达'},
    });
  }

  static Map<String, dynamic>? _decodeFrame(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // ── 路由注册 ─────────────────────────────────────────────────────────

  void _registerStubRoutes() {
    for (final String path in stubApiPaths) {
      for (final String method in <String>['GET', 'POST', 'PATCH', 'DELETE']) {
        stubRouter.add(method, path, (HttpRequest request, _) async {
          stubRequests++;
          await writeJson(request, 501, notImplementedBody(request.uri.path));
        });
      }
    }
  }

  void _registerRoutes() {
    router.add('GET', ApiPaths.agents, _listAgents);
    router.add('POST', ApiPaths.agents, _createAgent);
    router.add('GET', ApiPaths.agent, _getAgent);
    router.add('PATCH', ApiPaths.agent, _updateAgent);
    router.add('DELETE', ApiPaths.agent, _deleteAgent);
    router.add('GET', ApiPaths.agentModelsInfo, _agentModelsInfo);
    router.add('GET', ApiPaths.agentTodos, _agentTodos);
    router.add('GET', ApiPaths.agentTeammates, _agentTeammates);
    router.add('PATCH', ApiPaths.teammate, _updateTeammate);
    router.add('GET', ApiPaths.teammateLog, _teammateLog);
    router.add('POST', ApiPaths.teammateMessage, _teammateMessage);
    router.add('GET', ApiPaths.models, _listModels);
    router.add('POST', ApiPaths.models, _createModel);
    router.add('PATCH', ApiPaths.model, _updateModel);
    router.add('DELETE', ApiPaths.model, _deleteModel);
    router.add('GET', ApiPaths.conversations, _conversationHistory);
    router.add('DELETE', ApiPaths.conversations, _clearConversation);
    router.add('GET', ApiPaths.agentSessions, _listSessions);
    router.add('POST', ApiPaths.agentSessions, _createSession);
    router.add('GET', ApiPaths.agentSession, _sessionDetail);
    router.add('PATCH', ApiPaths.agentSession, _renameSession);
    router.add('DELETE', ApiPaths.agentSession, _deleteSession);
    router.add('POST', ApiPaths.agentSessionSpecs, _setSessionSpecs);
    router.add('GET', ApiPaths.agentSpecs, _listSpecs);
    router.add('GET', ApiPaths.agentSpec, _getSpec);
    router.add('POST', ApiPaths.agentReset, _resetWorkspace);
    router.add('POST', ApiPaths.agentCompact, _compactAgent);
    router.add('GET', ApiPaths.questions, _listQuestions);
    router.add('POST', ApiPaths.questionAnswer, _answerQuestion);
    router.add('GET', ApiPaths.settingsFrameRate, _getFrameRate);
    router.add('POST', ApiPaths.settingsFrameRate, _setFrameRate);
    router.add('GET', ApiPaths.settingsTokenRate, _getTokenRate);
    router.add('POST', ApiPaths.settingsTokenRate, _setTokenRate);
    // 心跳判活参数：两个端点同形状（都接受两个字段），PATCH 是主用法（部分更新），
    // POST 作别名与帧率端点保持一致的调用习惯。
    router.add(
      'GET',
      ApiPaths.settingsHeartbeatInterval,
      _getHeartbeatInterval,
    );
    router.add(
      'PATCH',
      ApiPaths.settingsHeartbeatInterval,
      _setHeartbeatInterval,
    );
    router.add(
      'POST',
      ApiPaths.settingsHeartbeatInterval,
      _setHeartbeatInterval,
    );
    router.add(
      'GET',
      ApiPaths.settingsMissedHeartbeatLimit,
      _getMissedHeartbeatLimit,
    );
    router.add(
      'PATCH',
      ApiPaths.settingsMissedHeartbeatLimit,
      _setMissedHeartbeatLimit,
    );
    router.add(
      'POST',
      ApiPaths.settingsMissedHeartbeatLimit,
      _setMissedHeartbeatLimit,
    );
    router.add('POST', ApiPaths.settingsDataCollection, _setDataCollection);
    router.add('GET', ApiPaths.files, _listFiles);
    router.add('GET', ApiPaths.fileContent, _fileContent);
    // 同路径的 PUT（M10）：源码编辑器保存（完整文本覆盖写）。
    router.add('PUT', ApiPaths.fileContent, _fileWriteContent);
    router.add('GET', ApiPaths.filePdfInfo, _filePdfInfo);
    router.add('POST', ApiPaths.fileDownload, _downloadFile);
    router.add('POST', ApiPaths.fileDownloadFolder, _downloadFolder);
    router.add('POST', ApiPaths.fileUploadInit, _uploadInit);
    router.add('POST', ApiPaths.fileUploadChunk, _uploadChunk);
    router.add('POST', ApiPaths.fileUploadComplete, _uploadComplete);
    router.add('POST', ApiPaths.fileSyncToLocal, _syncToLocal);
    router.add('GET', ApiPaths.workspaceGitLog, _workspaceGitLog);
    router.add('GET', ApiPaths.workspaceGitBranches, _workspaceGitBranches);
    router.add('GET', ApiPaths.pluginSnapshot, _pluginSnapshot);
    // 插件清单的读写面（M9 §4.2）：与只读快照分工见 ApiPaths.pluginConfigs 的注释。
    router.add('GET', ApiPaths.pluginConfigs, _listPluginConfigs);
    router.add('POST', ApiPaths.pluginConfigs, _createPluginConfig);
    router.add('PATCH', ApiPaths.pluginConfig, _updatePluginConfig);
    router.add('DELETE', ApiPaths.pluginConfig, _deletePluginConfig);
    router.add('POST', ApiPaths.pluginConfigRestart, _restartPluginConfig);
    router.add('GET', ApiPaths.pluginBuiltins, _listBuiltinPlugins);
    router.add('POST', ApiPaths.pluginBuiltinEnable, _enableBuiltinPlugin);
    router.add('POST', ApiPaths.pluginBuiltinDisable, _disableBuiltinPlugin);
    router.add('GET', ApiPaths.mcpServices, _mcpServices);
    router.add('POST', ApiPaths.mcpServices, _registerMcpService);
    router.add('DELETE', ApiPaths.mcpService, _deleteMcpService);
  }

  // ── agent ────────────────────────────────────────────────────────────

  /// `POST /api/agents/{agentId}/compact`：手动压缩上下文（M7d-4）。
  ///
  /// 状态帧与旧后端一致：压缩期间推 `agent_status=compacting`（前端显示「压缩中」
  /// 并禁用按钮），结束（含异常）后按**实际**工作状态推 working/idle——压缩期间
  /// 可能又来了新消息，无脑推 idle 会把前端的状态指示清掉。
  Future<void> _compactAgent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final CompactionService? service = compaction;
    if (service == null) {
      await writeJson(request, 501, errorBody('上下文压缩尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final String agentId = params['agentId'] ?? '';
    final String sessionId = (body['session_id'] ?? '').toString();
    // 该会话正在生成：拒绝压缩（压缩会改写上下文，与生成并发读写不安全）
    if (conversation.isRunning(agentId)) {
      await writeJson(request, 200, <String, dynamic>{
        'success': true,
        'compressed': false,
        'reason': 'agent_working',
        'context_size': 0,
      });
      return;
    }
    _broadcastCompactStatus(agentId, sessionId, 'compacting');
    try {
      final CompactionResult result = await service.compact(agentId, sessionId);
      if (result.error.isNotEmpty) {
        await writeJson(request, result.status, errorBody(result.error));
        return;
      }
      await writeJson(request, 200, result.toJson());
    } finally {
      _broadcastCompactStatus(
        agentId,
        sessionId,
        conversation.isRunning(agentId) ? 'working' : 'idle',
      );
    }
  }

  /// 推一条 `agent_status` 帧（前端据此显示/清除「压缩中」）。
  void _broadcastCompactStatus(
    String agentId,
    String sessionId,
    String status,
  ) {
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
        'status': status,
      },
    });
  }

  Future<void> _listAgents(HttpRequest request, Map<String, String> _) async {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final CoreAgent agent in store.agents()) {
      final CoreMessage? last = store.lastTextMessage(agent.id);
      items.add(
        agent.toApiJson(
          lastMessage: last?.content ?? '',
          lastMessageTime: last?.timestamp,
        ),
      );
    }
    await writeJson(request, 200, <String, dynamic>{'agents': items});
  }

  Future<void> _createAgent(HttpRequest request, Map<String, String> _) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final String name = (body['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      await writeJson(request, 400, errorBody('name 不能为空'));
      return;
    }
    final String modelId = (body['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty) {
      await writeJson(request, 400, errorBody('model_id 不能为空'));
      return;
    }
    if (settings.model(modelId) == null) {
      await writeJson(request, 400, errorBody('模型不存在：$modelId'));
      return;
    }
    final CoreAgent agent = store.createAgent(
      name: name,
      systemPrompt: body['system_prompt'] as String? ?? '',
      modelId: modelId,
      teamMemberCount: (body['team_member_count'] as num?)?.toInt() ?? 0,
      maxLevel: TeamLimits.level(body['max_level']),
      maxMembersPerLevel: TeamLimits.members(body['max_members_per_level']),
    );
    // 站点已全局唯一（每类站一个实例，与 team / agent 无关），所以新建 agent
    // **不需要**也不再触发任何站点预建：站点在核心启动的接线处就位，此后恒定。
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'agent': agent.toApiJson(),
    });
  }

  Future<void> _getAgent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final CoreAgent? agent = store.agent(params['agentId'] ?? '');
    if (agent == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'agent': agent.toApiJson(),
      // SSH 配置的**非机密**部分（host/port/username/auth/root/key_path），
      // 供前端表单预填；密码与口令永不回显。
      if (agent.sshConfig != null) 'ssh': _sshView(agent.sshConfig!),
    });
  }

  Future<void> _updateAgent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final String modelId = (body['model_id'] as String? ?? '').trim();
    if (modelId.isNotEmpty && settings.model(modelId) == null) {
      await writeJson(request, 400, errorBody('模型不存在：$modelId'));
      return;
    }
    final CoreAgent? agent = store.updateAgent(
      params['agentId'] ?? '',
      systemPrompt: body.containsKey('system_prompt')
          ? (body['system_prompt'] as String? ?? '')
          : null,
      modelId: modelId.isEmpty ? null : modelId,
    );
    if (agent == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }

    // 这是**用户显式改 agent 配置**（提示词 / 工作空间 / 模型参数都可能影响 `[0]`）：
    // 丢掉钉住的系统提示词，下一轮重建。注意与"发消息"的区别——后者永远不重建。
    // 本次 PATCH 若后面校验失败，重建出来的还是同一串字节，不额外损失缓存。
    conversation.invalidateSystemPrompt(agent.id);

    // ── 工作空间目录与 SSH 配置（M7c）：前端「运行模式」直接改 agent 配置 ──
    // 语义与模型配置一致：字段缺失 = 不改；显式空值 = 清空。
    bool touched = false;
    // 目录改动 = 团队共享目录变了 ⇒ 要立刻镜像给成员（见 _syncWorkspaceMirrors）。
    bool workspaceDirChanged = false;
    if (body.containsKey('workspace_dir')) {
      final String dir = (body['workspace_dir'] as String? ?? '').trim();
      if (dir.isNotEmpty && !p.isAbsolute(dir)) {
        await writeJson(
          request,
          400,
          errorBody('workspace_dir 必须是绝对路径或空串（空 = 用默认工作空间）'),
        );
        return;
      }
      agent.workspaceDir = dir;
      touched = true;
      workspaceDirChanged = true;
    }
    if (body.containsKey('ssh')) {
      final Object? raw = body['ssh'];
      if (raw == null) {
        agent.sshConfig = null;
        touched = true;
      } else if (raw is Map) {
        final Map<String, dynamic> sshBody = raw.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        );
        final SshConfig? parsed = SshConfig.parse(sshBody);
        if (parsed == null) {
          await writeJson(request, 400, errorBody('ssh.host 不能为空'));
          return;
        }
        // 密码/口令按 PATCH 语义：键缺失 = 保留原值，显式空串 = 清空
        final SshConfig? existing = agent.sshConfig;
        final String password = sshBody.containsKey('password')
            ? parsed.password
            : (existing?.password ?? '');
        final String passphrase = sshBody.containsKey('key_passphrase')
            ? parsed.keyPassphrase
            : (existing?.keyPassphrase ?? '');
        if (password.isEmpty && parsed.keyPath.isEmpty) {
          await writeJson(
            request,
            400,
            errorBody('SSH 需要 password 或 key_path 之一'),
          );
          return;
        }
        agent.sshConfig = SshConfig(
          host: parsed.host,
          port: parsed.port,
          username: parsed.username,
          password: password,
          keyPath: parsed.keyPath,
          keyPassphrase: passphrase,
          root: parsed.root,
        );
        touched = true;
      } else {
        await writeJson(request, 400, errorBody('ssh 必须是对象或 null'));
        return;
      }
    }
    // ── 模型参数覆盖（右栏「模型信息」页，M5b 语义）──
    // 语义与团队成员的「模型配置」一致：键缺省 = 不修改；显式 null = 清除该项；
    // clear_model_overrides = 一次性清空全部覆盖（回退模型默认，供「恢复默认」按钮）。
    if (body['clear_model_overrides'] == true) {
      agent.reasoningEffort = '';
      agent.maxSeqlenOverride = 0;
      agent.maxOutputTokens = 0;
      agent.compressThreshold = 0;
      agent.thinkingOverride = null;
      touched = true;
    } else {
      if (body.containsKey('reasoning_effort')) {
        agent.reasoningEffort = (body['reasoning_effort'] as String? ?? '')
            .trim();
        touched = true;
      }
      if (body.containsKey('max_seqlen')) {
        final Object? raw = body['max_seqlen'];
        if (raw == null) {
          agent.maxSeqlenOverride = 0;
        } else {
          final int? parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
          if (parsed == null || parsed <= 0) {
            await writeJson(
              request,
              400,
              errorBody('max_seqlen 必须为正整数，或 null 清除该项覆盖'),
            );
            return;
          }
          agent.maxSeqlenOverride = parsed;
        }
        touched = true;
      }
      if (body.containsKey('max_output_tokens')) {
        final Object? raw = body['max_output_tokens'];
        if (raw == null) {
          agent.maxOutputTokens = 0;
        } else {
          final int? parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
          if (parsed == null || parsed <= 0) {
            await writeJson(
              request,
              400,
              errorBody('max_output_tokens 必须为正整数，或 null 清除该项覆盖'),
            );
            return;
          }
          agent.maxOutputTokens = parsed;
        }
        touched = true;
      }
      if (body.containsKey('compress_threshold')) {
        final Object? raw = body['compress_threshold'];
        if (raw == null) {
          agent.compressThreshold = 0;
        } else {
          final double? parsed = raw is num
              ? raw.toDouble()
              : double.tryParse('$raw');
          if (parsed == null || parsed < 0.1 || parsed > 0.95) {
            await writeJson(
              request,
              400,
              errorBody('compress_threshold 必须在 0.1~0.95 之间，或 null 清除该项覆盖'),
            );
            return;
          }
          agent.compressThreshold = parsed;
        }
        touched = true;
      }
      if (body.containsKey('thinking')) {
        final Object? raw = body['thinking'];
        if (raw == null) {
          agent.thinkingOverride = null;
        } else if (raw is bool) {
          agent.thinkingOverride = raw;
        } else {
          await writeJson(
            request,
            400,
            errorBody('thinking 必须是 true / false，或 null 清除该项覆盖'),
          );
          return;
        }
        touched = true;
      }
    }
    if (touched) {
      agent.updatedAt = DateTime.now().millisecondsSinceEpoch;
      store.putAgent(agent);
    }
    // 改的是团队 TOP 的目录 ⇒ 成员的镜像要立刻跟上：成员页显示的是这份镜像，
    // 而"TOP 被删后成员升级为 TOP"要靠它做无损交接（用户断言 2026-10-03）。
    if (workspaceDirChanged) await _syncWorkspaceMirrors();
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'agent': agent.toApiJson(),
      if (agent.sshConfig != null) 'ssh': _sshView(agent.sshConfig!),
    });
  }

  /// 把团队共享工作目录镜像到成员（幂等；见 syncWorkspaceMirrors）。
  ///
  /// 没有 [fileService] 时算不出"TOP 未配置目录时的默认目录"，直接跳过而不是写半份：
  /// 写错比不写更糟（成员会落到一个并不存在的目录口径上）。
  Future<void> _syncWorkspaceMirrors() async {
    final FileService? files = fileService;
    if (files == null) return;
    try {
      await syncWorkspaceMirrors(
        store,
        defaultDirFor: files.defaultWorkspaceDir,
        backup: agentBackup,
        log: errorLog,
      );
    } catch (error) {
      // 镜像失败不该影响这次配置写入（用户改了目录就是改了；镜像下次启动会补上）
      errorLog?.call('工作目录镜像失败（不影响本次写入）：$error');
    }
  }

  /// SSH 配置的前端形态：在 `redacted()` 基础上补 `key_path`（表单预填需要），
  /// **仍然绝不含 password / key_passphrase**。
  static Map<String, dynamic> _sshView(SshConfig config) => <String, dynamic>{
    ...config.redacted(),
    if (config.keyPath.isNotEmpty) 'key_path': config.keyPath,
  };

  /// `DELETE /api/agents/{id}?cascade=1`：删除 agent（连同对话历史、会话与提问）。
  ///
  /// **两道闸门，都不通过就什么都不动**（2026-10-02 定稿）：
  /// 1. **有下级必须显式级联**：否则回 409 + `cascade_required`（字段形状沿用 team 工具
  ///    `remove_member`）。理由实测过：直接删掉一个中间层 leader，它的下级会变成
  ///    **孤儿**——`parent_agent_id` 悬空 ⇒ `directMembers` 够不着（广播不达）、
  ///    `cascadeIds` 够不着（级联停止/删除失效），而且 team 工具也再也删不掉它们
  ///    （`_subtree` 同样沿父链走）；只有用户回到左栏手删一条路。
  /// 2. **正在运行就拒绝**：`stop` 抢不动正在执行的工具（M9：本地执行活着就永不超时、
  ///    不按时间杀进程），所以这里**不等待、不轮询**——等待会把 HTTP 挂住，且"删掉正在
  ///    跑的 agent"正是残留的根因（那一轮继续往共享工作目录写、还能回一条来自幽灵成员的
  ///    消息、`data/<id>` 被写回来）。请用户先停止并等它空闲。
  ///
  /// 通过闸门后的顺序：停（作废排队任务 + 收尾在途提问）→ 排水 → 清提问记录 →
  /// 叶→根删 → 回填受影响 TOP 的 `team_member_count` → 再排水。
  ///
  /// 为什么先排水再删：`WriteQueue` 按**路径**串行，删 `data/<id>` 与写
  /// `data/<id>/<session>/messages.jsonl` 是两个 key、顺序不保证；不排水就可能
  /// "删完又被写回来"。
  Future<void> _deleteAgent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    if (store.agent(agentId) == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    final bool cascade = request.uri.queryParameters['cascade'] == '1' ||
        request.uri.queryParameters['cascade'] == 'true';
    final List<CoreAgent> descendants =
        teamService?.descendants(agentId) ?? const <CoreAgent>[];
    if (descendants.isNotEmpty && !cascade) {
      await writeJson(request, 409, <String, dynamic>{
        'detail': '该 agent 还有 ${descendants.length} 个下级成员，未指定 cascade',
        'error': '该 agent 还有 ${descendants.length} 个下级成员，未指定 cascade',
        'cascade_required': <Map<String, dynamic>>[
          for (final CoreAgent member in descendants)
            <String, dynamic>{
              'member_id': member.id,
              'name': member.name,
              'level': member.level,
              'parent_agent_id': member.parentAgentId,
            },
        ],
        'hint': '直接删除会让这些下级变成孤儿（找不到上级，广播与级联停止都够不着）；'
            '确认后带 ?cascade=1 连同下级一并删除，或先用 team 工具逐个移除下级',
      });
      return;
    }
    final List<String> ids = <String>[
      agentId,
      if (cascade) ...descendants.map((CoreAgent m) => m.id),
    ];
    // 记下每条的团队归属：删完就取不到了，而计数回填要用。
    final Map<String, String> teamOf = <String, String>{};
    for (final String id in ids) {
      final CoreAgent? agent = store.agent(id);
      if (agent == null) continue;
      teamOf[id] = teamOfFor(agent);
    }
    List<String> running() =>
        ids.where(conversation.isRunning).toList(growable: false);
    if (running().isNotEmpty) {
      await writeJson(request, 409, _busyBody(running()));
      return;
    }
    // 停：作废排队任务（旧代次出队即丢）+ 收尾在途提问（QuestionBroker）。
    for (final String id in ids) {
      _stopAgentTree(id, cascade: false);
    }
    // 竞态兜底：恰好在闸门之后接单的排队任务会被这次代次推进作废，但"已过代次检查、
    // 即将登记 token"的窗口仍在；再确认一次（不等待），有就照旧拒绝。
    final List<String> started = running();
    if (started.isNotEmpty) {
      await writeJson(request, 409, _busyBody(started));
      return;
    }
    await store.flush();
    // 提问记录：先取消（记录还在时立刻收尾在途等待）再摘记录——顺序反了会让
    // 等待中的工具永远拿不到结果（见 QuestionBroker.cancel 的注释）。
    int questionsRemoved = 0;
    for (final String id in ids) {
      questions?.cancelForAgent(id);
      questionsRemoved += questions?.questions.removeForAgent(id) ?? 0;
      await questions?.questions.flush();
    }
    // 叶→根删（父先于子的逆序），避免留下"父没了子还在"的中间态
    final List<String> removed = <String>[];
    for (final String id in ids.reversed) {
      if (store.deleteAgent(id)) removed.add(id);
    }
    await store.flush();
    // 回填存活 TOP 的成员数（用户侧删除也走 team 工具那套"按实际成员数"的回填）
    final Set<String> touchedTopIds = <String>{
      for (final String teamId in teamOf.values)
        if (!ids.contains(teamId)) teamId,
    };
    for (final String topId in touchedTopIds) {
      teamService?.syncMemberCount(topId);
    }
    await store.flush();
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'removed': removed,
      'cascade': cascade,
      if (questionsRemoved > 0) 'questions_removed': questionsRemoved,
    });
  }

  /// agent 的团队归属：成员取 `team_id`，顶层 agent 就是它自己。
  static String teamOfFor(CoreAgent agent) =>
      agent.teamId.isEmpty ? agent.id : agent.teamId;

  /// "正在运行，不能删"的 409 响应体（两道闸门共用）。
  Map<String, dynamic> _busyBody(List<String> running) => <String, dynamic>{
    'detail': 'agent 正在运行，不能删除',
    'error': 'agent 正在运行，不能删除',
    'running': running,
    'hint': '请先停止该 agent（成员可在标题栏按「停止」）并等它变为空闲后再删除；'
        '正在执行的工具无法被抢占（本地执行活着就永不超时），所以这里不会替你等待。',
  };

  Future<void> _agentModelsInfo(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final CoreAgent? agent = store.agent(params['agentId'] ?? '');
    if (agent == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'agent': <String, dynamic>{
        'id': agent.id,
        'model_id': agent.modelId,
        'system_prompt': agent.systemPrompt,
      },
      'models': settings
          .models()
          .map((CoreModelConfig m) => m.toApiJson())
          .toList(),
      // agent 级模型参数覆盖（M5 成员/覆盖特性落地）：只含**真正设置过**的键，
      // 前端据此回填「模型参数（本 Agent）」的四个控件（缺省 = 不覆盖）。
      'overrides': memberOverrides(agent),
    });
  }

  Future<void> _agentTodos(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    final String sessionId =
        request.uri.queryParameters['session_id'] ?? TreeStore.defaultSessionId;
    if (store.agent(agentId) == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    // 待办由 set_todo_list 工具写入（落 <会话目录>/todos.md），此处读同一份数据
    await writeJson(request, 200, <String, dynamic>{
      'todos': todoStore
          .read(agentId, sessionId)
          .map((TodoItem todo) => todo.toApiJson())
          .toList(),
      'session_id': sessionId,
    });
  }

  Future<void> _agentTeammates(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final TeamService? teams = teamService;
    if (teams == null) {
      // 未接入团队服务时返回空树（前端渲染空态），而不是 501 让窗口报错
      await writeJson(request, 200, <String, dynamic>{
        'agent_id': params['agentId'] ?? '',
        'members': <Map<String, dynamic>>[],
        'pending_member_count': 0,
      });
      return;
    }
    await writeJson(
      request,
      200,
      teams.teammatesPayload(params['agentId'] ?? ''),
    );
  }

  /// `PATCH /api/agents/{leaderId}/teammate/{memberId}`：**用户侧**唯一的模型写入口
  /// （team 工具三处都拒绝改模型）。
  Future<void> _updateTeammate(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final TeamService? teams = teamService;
    if (teams == null) {
      await writeJson(request, 501, errorBody('团队服务尚未接入'));
      return;
    }
    final Map<String, dynamic> body = await readJsonBody(request);
    final Map<String, dynamic> result = teams.assignModel(
      topId: params['leaderId'] ?? '',
      memberId: params['memberId'] ?? '',
      body: body,
    );
    final Object? error = result['error'];
    if (error != null) {
      final String message = error.toString();
      await writeJson(
        request,
        message.startsWith('成员不存在') ? 404 : 400,
        errorBody(message),
      );
      return;
    }
    await writeJson(request, 200, result);
  }

  /// 停止一个 agent 的当前轮（[cascade] = 连同下级子树）：**既有停止路径的唯一实现**。
  ///
  /// WS `stop` 帧与执行站 `agent.stop` 命令共用它，因此两条路的语义严格一致：
  /// 先 `cascadeIds` 展开子树，再逐个 `cancelAgent`（取消在途生成 + 作废排队任务）；
  /// **没有在途任务**的成员补推一条 `idle`，否则前端/成员窗口的「工作中」标识会
  /// 一直亮着（既有行为）。返回可读结论供调用方回报。
  Map<String, dynamic> _stopAgentTree(
    String agentId, {
    bool cascade = true,
    String sessionId = '',
  }) {
    final List<String> ids = cascade
        ? (teamService?.cascadeIds(agentId) ?? <String>[agentId])
        : <String>[agentId];
    final List<String> cancelled = <String>[];
    final List<String> idle = <String>[];
    for (final String id in ids) {
      final bool running = conversation.cancelAgent(id);
      if (running) {
        cancelled.add(id);
        continue;
      }
      idle.add(id);
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.agentStatus,
        'data': <String, dynamic>{
          'agent_id': id,
          'status': 'idle',
          if (sessionId.isNotEmpty) 'session_id': sessionId,
        },
      });
    }
    return <String, dynamic>{
      'cascade': cascade,
      'cascade_ids': ids,
      'cancelled': cancelled,
      'idle': idle,
      'any_running': cancelled.isNotEmpty,
    };
  }

  /// 处理 `stop`：**级联**语义（参考实现 `_stop_agent_tree`）。
  ///
  /// `agent_id` 是 TOP 时停整棵团队树：先自身、再成员。每个被取消的 agent 都作废
  /// 排队任务（见 `ConversationService.cancelAgent`）；**没有在途任务**的成员补一条
  /// `idle`，否则前端/成员窗口的"工作中"标识会一直亮着。
  void _handleStop(WsConnection connection, Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    final Map<String, dynamic> data = raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : frame;
    final String agentId = (data['agent_id'] ?? frame['agent_id'] ?? '')
        .toString()
        .trim();
    final String sessionId = (data['session_id'] ?? frame['session_id'] ?? '')
        .toString()
        .trim();
    if (agentId.isEmpty) {
      connection.send(<String, dynamic>{
        'type': WsOutboundType.error,
        'data': <String, dynamic>{'message': '缺少 agent_id'},
      });
      return;
    }
    final Map<String, dynamic> summary = _stopAgentTree(
      agentId,
      sessionId: sessionId,
    );
    final bool anyRunning = summary['any_running'] == true;
    final List<dynamic> ids = summary['cascade_ids'] as List<dynamic>;
    if (!anyRunning && ids.length == 1) {
      connection.send(<String, dynamic>{
        'type': WsOutboundType.error,
        'data': <String, dynamic>{'message': '没有进行中的任务可停止'},
      });
      return;
    }
    // 请求方：立刻回一条 stopping（前端把它当"已在停"处理）
    connection.send(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{
        'agent_id': agentId,
        'status': 'stopping',
        if (sessionId.isNotEmpty) 'session_id': sessionId,
      },
    });
  }

  /// `GET /api/agents/{memberId}/teammate/{memberId}/log?lines=60`：成员活动日志尾部。
  Future<void> _teammateLog(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final TeamMessageDispatcher? dispatcher = messageDispatcher;
    if (dispatcher == null) {
      await writeJson(request, 501, errorBody('团队服务尚未接入'));
      return;
    }
    final String memberId = params['memberId'] ?? '';
    final int lines =
        int.tryParse(request.uri.queryParameters['lines'] ?? '') ?? 60;
    // 读日志走 agent 自己的工作空间 IO ⇒ 本地与 **SSH 模式**同一个实现
    // （`readActivityLog` 内部再退回本机绝对路径兜底）。
    final Map<String, dynamic> read = await dispatcher.readActivityLog(
      memberId,
      lines: lines,
    );
    await writeJson(request, 200, <String, dynamic>{
      'success': read['success'] ?? true,
      'log': read['log'] ?? '',
      'path': read['path'] ?? '',
    });
  }

  /// `POST /api/agents/{leaderId}/teammate/{memberId}/message`：用户直接给成员发消息。
  Future<void> _teammateMessage(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final TeamMessageDispatcher? dispatcher = messageDispatcher;
    if (dispatcher == null) {
      await writeJson(request, 501, errorBody('团队服务尚未接入'));
      return;
    }
    final Map<String, dynamic> body = await readJsonBody(request);
    final String content = (body['content'] ?? '').toString();
    if (content.trim().isEmpty) {
      await writeJson(request, 200, <String, dynamic>{
        'success': false,
        'error': '缺少 content',
      });
      return;
    }
    final String sessionId = (body['session_id'] ?? '').toString().trim();
    final Map<String, dynamic> result = await dispatcher.sendFromUser(
      targetId: params['memberId'] ?? '',
      content: content,
      sessionId: sessionId.isEmpty ? TreeStore.defaultSessionId : sessionId,
    );
    await writeJson(request, 200, result);
  }

  // ── 模型 ─────────────────────────────────────────────────────────────

  Future<void> _listModels(HttpRequest request, Map<String, String> _) async {
    await writeJson(request, 200, <String, dynamic>{
      'models': settings
          .models()
          .map((CoreModelConfig m) => m.toApiJson())
          .toList(),
    });
  }

  Future<void> _createModel(HttpRequest request, Map<String, String> _) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final String? invalid = CoreSettings.validateNewModel(body);
    if (invalid != null) {
      await writeJson(request, 400, errorBody(invalid));
      return;
    }
    final CoreModelConfig? model = settings.createModel(body);
    if (model == null) {
      await writeJson(request, 409, errorBody('模型已存在：${body['model_id']}'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'model': model.toApiJson(),
    });
  }

  Future<void> _updateModel(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final CoreModelConfig? model = settings.updateModel(
      params['modelId'] ?? '',
      body,
    );
    if (model == null) {
      await writeJson(request, 404, errorBody('模型不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'model': model.toApiJson(),
    });
  }

  Future<void> _deleteModel(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String modelId = params['modelId'] ?? '';
    final bool removed = settings.deleteModel(modelId);
    if (!removed) {
      await writeJson(request, 404, errorBody('模型不存在'));
      return;
    }
    // 仍绑定该模型的 agent 列表（前端据此提示"需重新指定模型"）
    final List<String> bound = store
        .agents()
        .where((CoreAgent a) => a.modelId == modelId)
        .map((CoreAgent a) => a.id)
        .toList();
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'bound_agents': bound,
    });
  }

  // ── 会话与历史 ───────────────────────────────────────────────────────

  Future<void> _listSessions(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    if (store.agent(agentId) == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    // 兜底默认会话（对齐现状 server：list_sessions 至少返回一个空会话）
    store.ensureDefaultSession(agentId);
    final List<Map<String, dynamic>> items = store
        .sessions(agentId)
        .map(
          (CoreSession s) => s.toApiJson(
            messageCount: store.messageCount(agentId, s.sessionId),
          ),
        )
        .toList();
    await writeJson(request, 200, <String, dynamic>{
      'agent_id': agentId,
      'sessions': items,
    });
  }

  Future<void> _createSession(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final CoreSession? session = store.createSession(
      params['agentId'] ?? '',
      title: body['title'] as String? ?? '',
      sessionId: body['session_id'] as String?,
    );
    if (session == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'session': session.toApiJson(),
    });
  }

  Future<void> _sessionDetail(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    final String sessionId = params['sessionId'] ?? '';
    final CoreSession? session = store.session(agentId, sessionId);
    if (session == null) {
      await writeJson(request, 404, errorBody('会话不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'session': session.toApiJson(
        messageCount: store.messageCount(agentId, sessionId),
      ),
      'messages': store
          .messages(agentId, sessionId)
          .map((CoreMessage m) => m.toJson())
          .toList(),
    });
  }

  Future<void> _renameSession(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final bool renamed = store.renameSession(
      params['agentId'] ?? '',
      params['sessionId'] ?? '',
      body['title'] as String? ?? '',
    );
    if (!renamed) {
      await writeJson(request, 404, errorBody('会话不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{'success': true});
  }

  Future<void> _deleteSession(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final bool removed = store.deleteSession(
      params['agentId'] ?? '',
      params['sessionId'] ?? '',
    );
    if (!removed) {
      await writeJson(request, 404, errorBody('会话不存在'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{'success': true});
  }

  Future<void> _conversationHistory(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    if (store.agent(agentId) == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    final String sessionId =
        request.uri.queryParameters['session_id'] ?? TreeStore.defaultSessionId;
    final List<CoreMessage> messages = (sessionId == 'all')
        ? <CoreMessage>[
            for (final CoreSession s in store.sessions(agentId))
              ...store.messages(agentId, s.sessionId),
          ]
        : store.messages(agentId, sessionId);
    final List<CoreMessage> ordered = List<CoreMessage>.of(messages)
      ..sort(
        (CoreMessage a, CoreMessage b) => a.timestamp.compareTo(b.timestamp),
      );
    await writeJson(request, 200, <String, dynamic>{
      'agent_id': agentId,
      'session_id': sessionId,
      'messages': ordered.map((CoreMessage m) => _messageJson(m)).toList(),
    });
  }

  /// 消息的前端形态：提问卡片额外叠加提问记录里的状态与答案。
  ///
  /// 消息日志是**只追加**的，`answered` 落盘后永远是 false；真源在提问记录里，
  /// 因此历史加载时按 `qid == message.id` 覆盖。
  Map<String, dynamic> _messageJson(CoreMessage message) {
    final Map<String, dynamic> json = message.toJson();
    if (message.kind != 'ask_user_question') return json;
    final QuestionRecord? record = questions?.questions.byId(message.id);
    if (record == null) return json;
    json['answered'] = !record.isPending;
    json['answer'] = record.answer;
    if (record.options.isNotEmpty) json['options'] = record.options;
    return json;
  }

  Future<void> _clearConversation(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final int deleted = store.clearMessages(
      params['agentId'] ?? '',
      sessionId: request.uri.queryParameters['session_id'],
    );
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'deleted': deleted,
    });
  }

  Future<void> _setSessionSpecs(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final String agentId = params['agentId'] ?? '';
    final String sessionId = params['sessionId'] ?? '';
    if (store.session(agentId, sessionId) == null) {
      await writeJson(request, 404, errorBody('会话不存在'));
      return;
    }
    final List<String> specIds =
        (body['spec_ids'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList();
    store.setSelectedSpecs(agentId, sessionId, specIds);
    // 改了 hook 就立刻刷新 ⑧ 章快照，否则要等下一次后台补扫才进系统提示词
    final SpecService? specs = specService;
    if (specs != null) {
      await specs.refreshSelectedSpecs(
        agentId,
        sessionId,
        await specIoFor?.call(agentId),
      );
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'selected_spec_ids': specIds,
    });
  }

  Future<void> _listSpecs(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    final CoreSession? session = store.session(
      agentId,
      request.uri.queryParameters['session_id'] ?? TreeStore.defaultSessionId,
    );
    final SpecService? specs = specService;
    if (specs == null) {
      await writeJson(request, 200, <String, dynamic>{
        'specs': <Map<String, dynamic>>[],
        'selected_spec_ids': session?.selectedSpecIds ?? <String>[],
      });
      return;
    }
    final WorkspaceIO? io = await specIoFor?.call(agentId);
    final List<SpecDocument> documents = await specs.index(agentId, io);
    await writeJson(request, 200, <String, dynamic>{
      'specs': documents.map((SpecDocument d) => d.toMetaJson()).toList(),
      'selected_spec_ids': session?.selectedSpecIds ?? <String>[],
    });
  }

  /// `GET /api/agents/{agentId}/specs/{specId}`：Spec 详情（元数据 + 全文）。
  Future<void> _getSpec(HttpRequest request, Map<String, String> params) async {
    final SpecService? specs = specService;
    final String specId = params['specId'] ?? '';
    if (specs == null) {
      await writeJson(request, 200, <String, dynamic>{
        'meta': <String, dynamic>{},
        'content': '',
      });
      return;
    }
    final String agentId = params['agentId'] ?? '';
    final WorkspaceIO? io = await specIoFor?.call(agentId);
    final SpecDocument? document = await specs.detail(agentId, io, specId);
    if (document == null) {
      await writeJson(request, 404, errorBody('Spec 不存在: $specId'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'meta': document.toMetaJson(),
      'content': document.raw,
    });
  }

  /// `POST /api/agents/{agentId}/reset`：一键重置工作空间里的
  /// 系统提示词 / Spec（body: `{target}`，target ∈ system_prompt | spec | all）。
  ///
  /// 语义：现有文件先备份成 `.bak.<n>`（保留旧备份），再写回默认内容；Spec 的
  /// 自定义文件会一并清理（备份里可找回）。工作空间不可用时给**可读 400**，
  /// 而不是静默成功。
  Future<void> _resetWorkspace(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    final Map<String, dynamic> body = await readJsonBody(request);
    final String target = (body['target'] as String? ?? 'all')
        .trim()
        .toLowerCase();
    if (target != 'system_prompt' && target != 'spec' && target != 'all') {
      await writeJson(
        request,
        400,
        errorBody('target 只能是 system_prompt / spec / all'),
      );
      return;
    }
    if (store.agent(agentId) == null) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    final WorkspaceIO? io = await specIoFor?.call(agentId);
    if (io == null) {
      await writeJson(request, 400, errorBody('工作空间不可用（未接线 / SSH 配置不完整），无法重置'));
      return;
    }
    final Map<String, dynamic> result = <String, dynamic>{'success': true};
    if (target == 'system_prompt' || target == 'all') {
      final SystemPromptStore? prompts = systemPromptStore;
      if (prompts != null) {
        final PromptResetResult reset = await prompts.reset(agentId, io);
        await prompts.refresh(agentId);
        result['system_prompt'] = reset.toJson();
      }
    }
    // 显式重置 = 等价于"重新初始化"：丢掉钉住的系统提示词，下一次拼装用新内容
    // （区别于"发消息"——那永远不会重建提示词，见 ConversationService._systemPrompts）
    conversation.invalidateSystemPrompt(agentId);
    if (target == 'spec' || target == 'all') {
      final SpecService? specs = specService;
      if (specs != null) {
        result['spec'] = await specs.reset(io);
        await specs.refreshIndex(agentId, io);
      }
    }
    await writeJson(request, 200, result);
  }

  Future<void> _listQuestions(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final Map<String, String> query = request.uri.queryParameters;
    final QuestionBroker? broker = questions;
    final List<QuestionRecord> records = broker == null
        ? const <QuestionRecord>[]
        : broker.questions.list(
            agentId: query['agent_id'],
            sessionId: query['session_id'],
          );
    final String status = query['status'] ?? '';
    final List<QuestionRecord> filtered = status.isEmpty
        ? records
        : records
              .where((QuestionRecord r) => r.status == status)
              .toList(growable: false);
    // 最新的排前面（右栏「问题回复」页的首要需求是看到刚提出的问题）
    final List<QuestionRecord> ordered = List<QuestionRecord>.of(filtered)
      ..sort(
        (QuestionRecord a, QuestionRecord b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    await writeJson(request, 200, <String, dynamic>{
      'questions': ordered.map((QuestionRecord r) => r.toApiJson()).toList(),
      'total': ordered.length,
    });
  }

  /// `POST /api/questions/{qid}/answer`：与 WS `user_answer` 等价（REST 入口）。
  Future<void> _answerQuestion(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final QuestionBroker? broker = questions;
    if (broker == null) {
      await writeJson(request, 501, errorBody('提问回路尚未接入'));
      return;
    }
    final String qid = params['qid'] ?? '';
    final Map<String, dynamic> body = await readJsonBody(request);
    final String answer = (body['answer'] ?? '').toString();
    final QuestionRecord? record = broker.questions.byId(qid);
    if (record == null) {
      await writeJson(request, 404, errorBody('没有等待回答的问题'));
      return;
    }
    if (!record.isPending) {
      await writeJson(request, 400, errorBody('没有等待回答的问题'));
      return;
    }
    // 幂等：并发（WS + REST 同时作答）时只有第一次生效
    if (!broker.answer(qid, answer)) {
      await writeJson(request, 400, errorBody('没有等待回答的问题'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'qid': qid,
      'status': QuestionStatus.answered,
    });
  }

  // ── 设置 ─────────────────────────────────────────────────────────────

  Future<void> _getFrameRate(HttpRequest request, Map<String, String> _) async {
    await writeJson(request, 200, <String, dynamic>{
      'frame_rate': settings.frameRate,
      'min': CoreSettings.frameRateMin,
      'max': CoreSettings.frameRateMax,
    });
  }

  Future<void> _setFrameRate(HttpRequest request, Map<String, String> _) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final int requested =
        (body['frame_rate'] as num?)?.toInt() ?? CoreSettings.frameRateMin;
    await writeJson(request, 200, <String, dynamic>{
      'frame_rate': settings.setFrameRate(requested),
      'min': CoreSettings.frameRateMin,
      'max': CoreSettings.frameRateMax,
    });
  }

  Future<void> _getTokenRate(HttpRequest request, Map<String, String> _) async {
    await writeJson(request, 200, <String, dynamic>{
      'token_rate': settings.tokenAcquisitionRate,
      'min': CoreSettings.tokenRateMin,
      'max': CoreSettings.tokenRateMax,
    });
  }

  Future<void> _setTokenRate(HttpRequest request, Map<String, String> _) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    final int requested =
        (body['token_rate'] as num?)?.toInt() ?? CoreSettings.tokenRateMax;
    await writeJson(request, 200, <String, dynamic>{
      'token_rate': settings.setTokenAcquisitionRate(requested),
      'min': CoreSettings.tokenRateMin,
      'max': CoreSettings.tokenRateMax,
    });
  }

  Future<void> _setDataCollection(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    settings.dataCollectionEnabled = body['enabled'] as bool? ?? false;
    // 桌面单用户形态没有收集方：仅保留开关以兼容既有设置页（M7 移除）
    await writeJson(request, 200, <String, dynamic>{'success': true});
  }

  // ── 心跳判活参数（M9 规约 1.1；用户已确认默认 I=10s / N=3） ─────────────
  //
  // 两个参数是一体的：判活窗口 = I×N，且必须**严格大于**前端固定 10s 的 WS 心跳
  // （lib/io/websocket_service.dart，M9 收口不改它），否则"在线但空闲"的连接会被
  // 判失活并反复重连。因此：
  // - 两个端点**同形状**、都接受两个字段一起写（避免两次单字段写入之间出现非法
  //   中间态），响应永远给出生效值 + 区间 + 窗口；
  // - 夹取而不拒绝（规则与理由见 CoreSettings.setLiveness 的文档），真夹了就把
  //   可读原因放进 `notice`——用户要能知道"我填的 1s 为什么生效成 4s"；
  // - 写成功后立即把新节拍热更新到**在跑**的判活定时器上（见
  //   [_applyLivenessToRunningHub]），不必重启核心。

  Future<void> _getHeartbeatInterval(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    await writeJson(
      request,
      200,
      _livenessBody(
        min: CoreSettings.heartbeatIntervalMin,
        max: CoreSettings.heartbeatIntervalMax,
      ),
    );
  }

  Future<void> _setHeartbeatInterval(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    _patchLiveness(await readJsonBody(request));
    await writeJson(
      request,
      200,
      _livenessBody(
        min: CoreSettings.heartbeatIntervalMin,
        max: CoreSettings.heartbeatIntervalMax,
      ),
    );
  }

  Future<void> _getMissedHeartbeatLimit(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    await writeJson(
      request,
      200,
      _livenessBody(
        min: CoreSettings.missedHeartbeatLimitMin,
        max: CoreSettings.missedHeartbeatLimitMax,
      ),
    );
  }

  Future<void> _setMissedHeartbeatLimit(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    _patchLiveness(await readJsonBody(request));
    await writeJson(
      request,
      200,
      _livenessBody(
        min: CoreSettings.missedHeartbeatLimitMin,
        max: CoreSettings.missedHeartbeatLimitMax,
      ),
    );
  }

  /// 写入心跳判活参数（PATCH / POST 同义：只改请求体里出现的字段）并把新值热更新到
  /// 在跑的 WS 判活节拍上。
  void _patchLiveness(Map<String, dynamic> body) {
    settings.setLiveness(
      intervalSeconds: _optionalInt(body, 'heartbeat_interval'),
      missedLimit: _optionalInt(body, 'missed_heartbeat_limit'),
    );
    _applyLivenessToRunningHub();
  }

  /// 心跳判活端点的响应体（两个端点同形状）。
  Map<String, dynamic> _livenessBody({required int min, required int max}) {
    final String? notice = settings.livenessNotice;
    return <String, dynamic>{
      // 设置值（= 实际写入 settings.yaml 的值）
      'heartbeat_interval': settings.heartbeatIntervalSeconds,
      'missed_heartbeat_limit': settings.missedHeartbeatLimit,
      // 本端点管的那一项的绝对区间（与帧率端点同形状）
      'min': min,
      'max': max,
      // 两项各自的绝对区间：前端有两个输入框，而 min/max 只描述本端点那一项
      'heartbeat_interval_min': CoreSettings.heartbeatIntervalMin,
      'heartbeat_interval_max': CoreSettings.heartbeatIntervalMax,
      'missed_heartbeat_limit_min': CoreSettings.missedHeartbeatLimitMin,
      'missed_heartbeat_limit_max': CoreSettings.missedHeartbeatLimitMax,
      // 判活窗口 = I×N，必须**严格大于** min_window（前端固定的 10s WS 心跳）
      'window_seconds': settings.livenessWindowSeconds,
      'min_window_seconds': CoreSettings.minLivenessWindowSeconds,
      // 在线生效值：设置变更后 WS 判活节拍会热更新，N 只能等下次核心启动
      // （LivenessTracker.maxMisses 是 final）；两者不等时前端应说明生效时机。
      'live_interval_seconds': _liveHeartbeatInterval.inSeconds,
      'live_miss_limit': _liveHeartbeatMissLimit,
      // 只有真发生夹取时才给：可读原因（含"为什么"和实际生效值）
      'notice': ?notice,
    };
  }

  /// 把新设置热更新到**在跑**的保活定时器上（"保存后立即生效"）。
  ///
  /// 只能热更新节拍 I：在线连接的阈值在 `LivenessTracker.maxMisses`（final）里，
  /// 而定时器的节拍决定"多久算一拍"，所以热更新后的实际判活窗口 = 新节拍 × 在线 N。
  /// 因此只在"按**在线** N 计算仍然 > 前端 10s 心跳"时才动定时器——不能为了立即
  /// 生效把空闲连接推回会被误判失活的窗口；不满足就继续用旧节拍（下次启动核心起
  /// 用新值，响应里的 live_interval_seconds 会让前端说明这一点）。
  ///
  /// 调用方显式传过心跳参数（测试/调试逃生口）或保活被关掉时都不动。
  void _applyLivenessToRunningHub() {
    if (_heartbeatPinned || !_heartbeatEnabled) return;
    final WsHub running = hub;
    if (running is! LivenessWsHub) return;
    final int liveMissLimit = running.linkLiveness.maxMisses;
    final int intervalSeconds = settings.heartbeatIntervalSeconds;
    if (!CoreSettings.livenessWindowOk(intervalSeconds, liveMissLimit)) return;
    _liveHeartbeatMissLimit = liveMissLimit;
    final Duration interval = Duration(seconds: intervalSeconds);
    if (interval == _liveHeartbeatInterval) return;
    _liveHeartbeatInterval = interval;
    running.startHeartbeat(interval: interval);
  }

  /// 判活上报文案：节拍被热更新过时补一句真相。
  ///
  /// 在线台账（[LivenessTracker]）的 I/N 是 final，热更新只改定时器节拍，所以
  /// `staleMessage` 里的"心跳间隔"可能仍是启动值——日志不能因此骗人：实际窗口按
  /// 热更新后的节拍算，这里明说。
  String _livenessLogText(LivenessTracker beat) {
    final String text = beat.staleMessage;
    final Duration trackerInterval = beat.interval;
    if (trackerInterval == _liveHeartbeatInterval) return text;
    return '$text；节拍已按设置热更新为 '
        '${LivenessTracker.formatDuration(_liveHeartbeatInterval)}'
        '（台账仍记启动值 ${LivenessTracker.formatDuration(trackerInterval)}）';
  }

  // ── 插件 / MCP ───────────────────────────────────────────────────────

  /// 文件/工作空间路由的统一错误处理（FileService 用 `{error, status}` 表达失败）。
  /// 读 JSON 请求体；非法 JSON 时回 400 并返回 null（不留到 500）。
  Future<Map<String, dynamic>?> _jsonBody(HttpRequest request) async {
    try {
      return await readJsonBody(request);
    } on FormatException catch (error) {
      await writeJson(request, 400, errorBody('请求体非法：${error.message}'));
      return null;
    }
  }

  /// 宽松解析整数字段（前端偶尔把数字序列化成字符串）。
  static int _asInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 0;
  }

  /// 宽松解析**可选**整数字段：缺字段 / 非法值一律返回 null = **不改该项**。
  ///
  /// 刻意不学 [_asInt] 兜 0：0 会被夹到区间下限，等于"字段写错了却悄悄改了配置"。
  static int? _optionalInt(Map<String, dynamic> body, String key) {
    final Object? raw = body[key];
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// 服务层结果里带 `error` 时写回错误响应并返回 true（文件、压缩等共用）。
  ///
  /// 服务层统一用 `{error, status}` 表达失败，路由层只判断一次，避免每个处理器
  /// 各写一遍状态码映射（写错就是「该 400 的变成 500」）。
  Future<bool> _writeResultError(
    HttpRequest request,
    Map<String, dynamic> result,
  ) async {
    final Object? error = result['error'];
    if (error == null) return false;
    final int status = (result['status'] as num?)?.toInt() ?? 404;
    await writeJson(request, status, errorBody(error.toString()));
    return true;
  }

  /// `GET /api/files/{workspaceId}?path=`：目录树。
  Future<void> _listFiles(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic> result = await files.list(
      params['workspaceId'] ?? '',
      path: request.uri.queryParameters['path'] ?? '',
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `GET /api/files/{workspaceId}/content?path=`：文件内容（图片为 base64）。
  Future<void> _fileContent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic> result = await files.content(
      params['workspaceId'] ?? '',
      request.uri.queryParameters['path'] ?? '',
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// PUT /api/files/{workspaceId}/content?path=&force= ：按完整文本覆盖写（M10）。
  ///
  /// 前端源码编辑器保存用：请求体 {content, if_size?}（if_size = 前端加载时看到的
  /// 字节数）。成功 200 {success, path, size, written}；if_size 与当前字节数不符
  /// → 409 冲突 {error: 'conflict', detail, size}（文件已不存在时省略 size、由 detail
  /// 说明，前端据此判定 missing）；其余失败
  /// 400 {error, detail}。team_id 与 GET 同口径：当前核心按 workspaceId 定位工作
  /// 空间，该参数仅为前后端调用点一致而保留、不参与分派。
  ///
  /// 落盘与判定（路径守卫 / 二进制 / 上限 / 冲突）都在 [FileService.writeContent]，
  /// 这里只负责解析请求与把 {error, detail, status} 翻成 HTTP 响应。
  Future<void> _fileWriteContent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Object? content = body['content'];
    if (content is! String) {
      await writeJson(request, 400, <String, dynamic>{
        'error': 'invalid_body',
        'detail': '请求体缺少 content 字段（必须是完整文本）',
      });
      return;
    }
    final Map<String, String> query = request.uri.queryParameters;
    final Map<String, dynamic> result = await files.writeContent(
      params['workspaceId'] ?? '',
      path: query['path'] ?? '',
      content: content,
      ifSize: _optionalInt(body, 'if_size'),
      force: _truthy(query['force']),
    );
    final Object? error = result['error'];
    if (error == null) {
      await writeJson(request, 200, result);
      return;
    }
    // 写接口的错误体固定是 {error, detail}（409 冲突另带当前 size）：不再走
    // _writeResultError 那套「error 即 detail」的口径。
    final int status = (result['status'] as num?)?.toInt() ?? 400;
    final Map<String, dynamic> payload = <String, dynamic>{
      'error': error,
      'detail': result['detail'] ?? error,
    };
    final Object? size = result['size'];
    if (size != null) payload['size'] = size;
    await writeJson(request, status, payload);
  }

  /// 查询串里的布尔开关：「1」/「true」（大小写不敏感）为真，其余为假。
  static bool _truthy(Object? value) {
    final String text = (value ?? '').toString().trim().toLowerCase();
    return text == '1' || text == 'true' || text == 'yes' || text == 'on';
  }

  /// `POST /api/files/{workspaceId}/download`：原始字节下载（body: `{path}`）。
  Future<void> _downloadFile(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic> body = await readJsonBody(request);
    final Map<String, dynamic> result = await files.openDownload(
      params['workspaceId'] ?? '',
      (body['path'] ?? '').toString(),
    );
    if (await _writeResultError(request, result)) return;
    await writeStream(
      request,
      200,
      result['stream'] as Stream<List<int>>,
      filename: result['name'] as String?,
      length: result['size'] as int?,
    );
  }

  /// `POST /api/files/{workspaceId}/download_folder`：目录打包为 tar.gz。
  Future<void> _downloadFolder(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Map<String, dynamic> result = await files.archive(
      params['workspaceId'] ?? '',
      (body['path'] ?? '').toString(),
    );
    if (await _writeResultError(request, result)) return;
    await writeBytes(
      request,
      200,
      result['bytes'] as List<int>,
      filename: result['name'] as String?,
    );
  }

  /// `POST /api/files/{workspaceId}/upload_init`：建立分片上传会话。
  Future<void> _uploadInit(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Map<String, dynamic> result = await files.uploadInit(
      params['workspaceId'] ?? '',
      fileName: (body['file_name'] ?? '').toString(),
      relPath: (body['rel_path'] ?? '').toString(),
      totalSize: _asInt(body['total_size']),
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `POST /api/files/{workspaceId}/upload_chunk`：追加一个分片（base64）。
  Future<void> _uploadChunk(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Map<String, dynamic> result = await files.uploadChunk(
      params['workspaceId'] ?? '',
      uploadId: (body['upload_id'] ?? '').toString(),
      index: _asInt(body['index']),
      data: (body['data'] ?? '').toString(),
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `POST /api/files/{workspaceId}/upload_complete`：组装分片并落盘。
  Future<void> _uploadComplete(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Object? chunks = body['total_chunks'];
    final Map<String, dynamic> result = await files.uploadComplete(
      params['workspaceId'] ?? '',
      uploadId: (body['upload_id'] ?? '').toString(),
      totalChunks: chunks == null ? null : _asInt(chunks),
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `POST /api/files/{workspaceId}/syncToLocal`：整棵工作空间复制到本机目录。
  Future<void> _syncToLocal(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Map<String, dynamic> result = await files.syncToLocal(
      params['workspaceId'] ?? '',
      (body['local_path'] ?? '').toString(),
      path: (body['path'] ?? '').toString(),
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `GET /api/files/{workspaceId}/pdf_info?path=`：PDF 基本信息。
  Future<void> _filePdfInfo(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic> result = await files.pdfInfo(
      params['workspaceId'] ?? '',
      request.uri.queryParameters['path'] ?? '',
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `GET /api/workspaces/{workspaceId}/git/log?limit=`：提交历史。
  Future<void> _workspaceGitLog(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final int limit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
    final Map<String, dynamic> result = await files.gitLog(
      params['workspaceId'] ?? '',
      limit: limit,
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  /// `GET /api/workspaces/{workspaceId}/git/branches`：分支列表。
  Future<void> _workspaceGitBranches(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final FileService? files = fileService;
    if (files == null) {
      await writeJson(request, 501, errorBody('文件服务尚未接入'));
      return;
    }
    final Map<String, dynamic> result = await files.gitBranches(
      params['workspaceId'] ?? '',
    );
    if (await _writeResultError(request, result)) return;
    await writeJson(request, 200, result);
  }

  Future<void> _pluginSnapshot(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      // 未接入插件总线：返回空集（前端渲染空态），而不是 501 让面板报错
      await writeJson(request, 200, <String, dynamic>{
        'enabled': false,
        'instances': <Map<String, dynamic>>[],
        'stations': <Map<String, dynamic>>[],
        'watchdog': <String, dynamic>{},
        'config': <String, dynamic>{},
      });
      return;
    }
    // team_id 参数按"团队"解释，但调用方可能传的是**成员 agent 的 id**（前端在
    // 成员上下文里就是这样）。这里做一次反查：传进来的 id 若是成员，用它回指的
    // 团队 id——与"顶层 agent 用自身 id 当团队"口径一致（前端插件面板就是这么
    // 取当前团队的）。
    // **站点段不受此过滤**：站点全局唯一，过滤恒真；team 视角由每条订阅者的
    // scope 与 subscribers_by_team 承担（见 StationHub.snapshot）。
    final String requested =
        request.uri.queryParameters['team_id']?.trim() ?? '';
    final CoreAgent? named = requested.isEmpty ? null : store.agent(requested);
    final String teamId = named != null && named.teamId.isNotEmpty
        ? named.teamId
        : requested;
    await writeJson(request, 200, bus.snapshot(teamId: teamId));
  }

  // ── 插件清单读写（M9 §4.2：内置与自定义都要能在前端增删改 + 各自一个开关） ──

  /// 插件清单的存储层。
  ///
  /// 路径 = **插件总线正在用的那一份** plugins.yaml（bus.configFile）：这样"前台
  /// 写盘"和"总线读盘"永远是同一个文件，不会出现两处路径口径不一致。
  PluginConfigStore _pluginStore(PluginBus bus) => PluginConfigStore(
    bus.configFile,
    log: (String message) => errorLog?.call('[core:plugin-config] $message'),
  );

  /// 未接入插件总线时的统一可读拒绝。
  ///
  /// 刻意不用 501：前端对 501 有专门文案「功能开发中」，而这里不是"没做"，
  /// 而是"这台核心没接插件总线"（只有测试 / 最小骨架会这样，CLI 恒接线）。
  Future<void> _writePluginNotWired(HttpRequest request) async {
    await writeJson(request, 503, errorBody('插件总线尚未接入核心，插件管理不可用（快照接口仍返回空集）'));
  }

  /// 热应用一次落盘改动（默认实现见 [BusPluginHotApplier]）。
  Future<PluginHotApplyOutcome> _applyPluginChange(
    PluginBus bus,
    Map<String, dynamic> entry, {
    required bool enable,
  }) {
    final PluginHotApplier applier =
        pluginHotApplier ?? BusPluginHotApplier(bus);
    return applier.apply(entry, enable: enable);
  }

  /// 写操作的统一响应体（落盘结果 + 热应用结果）。
  ///
  /// 「配置已保存，但本次热应用失败，重启核心后生效」这句话**只在核心拼一次**
  /// （[PluginHotApplyOutcome.restartNotice]），前端原样显示——避免两边各写一句、
  /// 说法漂移。
  Map<String, dynamic> _pluginWriteBody(
    PluginConfigStore store,
    PluginStoreResult result,
    PluginHotApplyOutcome outcome,
  ) => <String, dynamic>{
    'ok': true,
    'path': store.path,
    'config': result.entry,
    'configs': result.entries,
    'hot_applied': outcome.applied,
    'notice': outcome.applied ? '' : PluginHotApplyOutcome.restartNotice,
    'hot_apply_detail': outcome.detail,
  };

  /// 每条插件的运行态（给面板显示"在跑 / 已停用 / 心跳降级 / 启动失败原因"）。
  ///
  /// 数据源是插件总线的公开探针（healthOf / errorOf），不是自己另立台账。
  Map<String, dynamic> _pluginRuntimeOf(
    PluginBus bus,
    List<Map<String, dynamic>> configs,
  ) {
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final Map<String, dynamic> config in configs) {
      final String id = (config['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final Map<String, dynamic> health = bus.healthOf(id);
      out[id] = <String, dynamic>{
        'running': health['health'] != 'unavailable',
        'health': health['health'],
        'reason': health['reason'] ?? '',
        'error': bus.errorOf(id) ?? '',
        // 总线运行期是否认识这一条：false = 还没对账过（写一次盘就会认识）
        'known': bus.config(id) != null,
      };
    }
    return out;
  }

  /// GET /api/plugin/configs：插件清单（**持久态**：刚保存的开关状态以它为准）。
  ///
  /// 与 GET /api/plugin/snapshot 的分工：快照给运行态（实例 / 站点 / 健康度），
  /// 这里给"文件里到底写了什么"（含编辑界面要回填的 env / scope / 未知键）。
  Future<void> _listPluginConfigs(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final PluginConfigStore store = _pluginStore(bus);
    final List<Map<String, dynamic>> configs = store.readEntries();
    await writeJson(request, 200, <String, dynamic>{
      'path': store.path,
      'enabled': store.totalEnabled(),
      'configs': configs,
      'runtime': _pluginRuntimeOf(bus, configs),
    });
  }

  /// POST /api/plugin/configs：新增一个自定义插件（写盘后尝试热应用）。
  Future<void> _createPluginConfig(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    // 内置插件的 id 已被清单占用：新增同 id 的自定义插件会让"内置组"与"自定义组"
    // 指向同一条配置（开关互相踩），直接拒绝并指路。
    final String newId = (body['id'] ?? '').toString().trim();
    final BuiltinPluginSpec? builtin = BuiltinPluginCatalog.specOf(newId);
    if (builtin != null) {
      await writeJson(
        request,
        400,
        errorBody(
          'id「$newId」是内置插件（${builtin.name}）：'
          '内置插件请用「内置插件」清单里的开关，或换一个 id',
        ),
      );
      return;
    }
    final PluginConfigStore store = _pluginStore(bus);
    final PluginStoreResult result = store.create(body);
    final Map<String, dynamic>? entry = result.entry;
    if (!result.ok || entry == null) {
      await writeJson(request, 400, errorBody(result.error));
      return;
    }
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      entry,
      enable: true,
    );
    await writeJson(request, 200, _pluginWriteBody(store, result, outcome));
  }

  /// PATCH /api/plugin/configs/{pluginId}：局部更新（每项的开关也走这里）。
  Future<void> _updatePluginConfig(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final PluginConfigStore store = _pluginStore(bus);
    if (store.readEntry(id) == null) {
      await writeJson(request, 404, errorBody('插件不存在：$id'));
      return;
    }
    final PluginStoreResult result = store.update(id, body);
    final Map<String, dynamic>? entry = result.entry;
    if (!result.ok || entry == null) {
      await writeJson(request, 400, errorBody(result.error));
      return;
    }
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      entry,
      enable: entry['enabled'] != false,
    );
    await writeJson(request, 200, _pluginWriteBody(store, result, outcome));
  }

  /// DELETE /api/plugin/configs/{pluginId}：删除一个自定义插件。
  Future<void> _deletePluginConfig(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final PluginConfigStore store = _pluginStore(bus);
    final Map<String, dynamic>? before = store.readEntry(id);
    if (before == null) {
      await writeJson(request, 404, errorBody('插件不存在：$id'));
      return;
    }
    // 内置条目不给删除（M9 §4.2：内置项只给"停用"，条目保留才能再次打开）
    if (before['builtin'] == true) {
      await writeJson(
        request,
        400,
        errorBody('内置插件 $id 不提供删除：请用停用（条目保留，可再次打开）'),
      );
      return;
    }
    final PluginStoreResult result = store.remove(id);
    if (!result.ok) {
      await writeJson(request, 400, errorBody(result.error));
      return;
    }
    // 删除后要断开：拿被删的那条（不是 null）去热应用，实现才能判断它当时在不在跑
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      before,
      enable: false,
    );
    await writeJson(request, 200, _pluginWriteBody(store, result, outcome));
  }

  /// POST /api/plugin/configs/{pluginId}/restart：显式重启一个插件实例。
  ///
  /// 用途一：心跳 degraded 之后由用户手动恢复；用途二：改完配置想立刻按新参数拉起
  /// （日常开关走 PATCH，已经会自动对账，不必手动点这里）。
  ///
  /// 若总线运行期还没见过这一条（例如用户直接手改了 plugins.yaml 再点重启），先按
  /// 磁盘对一次账——否则会误报"要重启核心"，而它其实现在就能被拉起来。
  Future<void> _restartPluginConfig(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final PluginConfigStore store = _pluginStore(bus);
    if (store.readEntry(id) == null) {
      await writeJson(request, 404, errorBody('插件不存在：$id'));
      return;
    }
    if (bus.config(id) == null) {
      // 运行期还不认识这一条（核心启动后手工加进 plugins.yaml 的）：先对账，
      // 让总线按磁盘把运行态对齐，再判断它到底在不在清单里。
      await bus.applyConfigs();
    }
    if (bus.config(id) == null) {
      await writeJson(
        request,
        400,
        errorBody('插件 $id 不在插件清单里（${store.path}）：请检查 plugins.yaml'),
      );
      return;
    }
    final bool ok = await bus.restart(id);
    final String reason = bus.errorOf(id) ?? '';
    if (!ok) {
      await writeJson(
        request,
        400,
        errorBody(reason.isEmpty ? '插件 $id 重启后未就绪' : '插件 $id 重启失败：$reason'),
      );
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'ok': true,
      'plugin_id': id,
      'running': true,
      'path': store.path,
    });
  }

  /// GET /api/plugin/builtins：内置插件目录（清单 + 每项启用态 + 运行时解析结果）。
  ///
  /// 内置项**永远在响应里**（未启用也可见，面板才有"带说明的开关"可点）；
  /// config 为落盘的那一条（从未启用过 = null），resolution 是核心此刻解析出来的
  /// 运行时与脚本路径（含可读错误，前端直接显示）。
  Future<void> _listBuiltinPlugins(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final PluginConfigStore store = _pluginStore(bus);
    // refresh=1 强制重探运行时（用户可能刚装好 Python：一次点击就该看到变化）
    final bool refresh = request.uri.queryParameters['refresh'] == '1';
    final List<Map<String, dynamic>> builtins = <Map<String, dynamic>>[];
    for (final BuiltinPluginSpec spec in BuiltinPluginCatalog.specs) {
      final Map<String, dynamic>? entry = store.readEntry(spec.id);
      final BuiltinResolution resolution = await builtinPlugins.resolve(
        spec,
        refresh: refresh,
      );
      builtins.add(<String, dynamic>{
        ...spec.toJson(),
        'enabled': entry != null && entry['enabled'] != false,
        'configured': entry != null,
        'config': entry,
        'resolution': resolution.toJson(),
      });
    }
    await writeJson(request, 200, <String, dynamic>{
      'path': store.path,
      'enabled': store.totalEnabled(),
      'runtime_checked': refresh,
      'builtins': builtins,
    });
  }

  /// POST /api/plugin/builtins/{pluginId}/enable：打开一个内置插件。
  ///
  /// 打开 = 解析运行时与脚本 → 写一条**普通插件配置**（带 builtin: true 标记）→
  /// 尝试热启动。解析不出来（没装 Python / 找不到脚本）时回**可读 400**，
  /// 不写盘、不假装成功。
  Future<void> _enableBuiltinPlugin(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final BuiltinPluginSpec? spec = BuiltinPluginCatalog.specOf(id);
    if (spec == null) {
      await writeJson(
        request,
        404,
        errorBody('未知的内置插件：$id（清单见 GET /api/plugin/builtins）'),
      );
      return;
    }
    // 用户点"打开"就重探一次：装了 Python / 补了脚本之后不需要重启核心
    final BuiltinResolution resolution = await builtinPlugins.resolve(
      spec,
      refresh: true,
    );
    if (!resolution.ok) {
      await writeJson(request, 400, errorBody(resolution.error));
      return;
    }
    final PluginConfigStore store = _pluginStore(bus);
    final PluginStoreResult result = store.upsert(
      BuiltinPluginCatalog.entryFor(spec, resolution),
    );
    final Map<String, dynamic>? entry = result.entry;
    if (!result.ok || entry == null) {
      await writeJson(request, 400, errorBody(result.error));
      return;
    }
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      entry,
      enable: true,
    );
    await writeJson(request, 200, <String, dynamic>{
      ..._pluginWriteBody(store, result, outcome),
      'resolution': resolution.toJson(),
    });
  }

  /// POST /api/plugin/builtins/{pluginId}/disable：关闭一个内置插件。
  ///
  /// 关闭 = 把该条置 enabled: false —— **条目保留**（面板显示「已停用」而不是让
  /// 这一项消失），下次打开沿用同一 id。从未启用过的内置项不落盘（没什么可改的），
  /// 只如实回报"本来就关着"。
  Future<void> _disableBuiltinPlugin(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final BuiltinPluginSpec? spec = BuiltinPluginCatalog.specOf(id);
    if (spec == null) {
      await writeJson(
        request,
        404,
        errorBody('未知的内置插件：$id（清单见 GET /api/plugin/builtins）'),
      );
      return;
    }
    final PluginConfigStore store = _pluginStore(bus);
    final Map<String, dynamic>? entry = store.readEntry(id);
    if (entry == null) {
      await writeJson(request, 200, <String, dynamic>{
        'ok': true,
        'path': store.path,
        'config': null,
        'configs': store.readEntries(),
        'hot_applied': true,
        'notice': '',
        'hot_apply_detail': '内置插件 $id 尚未启用，无需停用',
      });
      return;
    }
    final PluginStoreResult result = store.setEnabled(id, false);
    final Map<String, dynamic>? updated = result.entry;
    if (!result.ok || updated == null) {
      await writeJson(request, 400, errorBody(result.error));
      return;
    }
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      updated,
      enable: false,
    );
    await writeJson(request, 200, _pluginWriteBody(store, result, outcome));
  }

  Future<void> _mcpServices(HttpRequest request, Map<String, String> _) async {
    final McpService? mcp = mcpService;
    if (mcp == null) {
      await writeJson(request, 200, <String, dynamic>{
        'services': <Map<String, dynamic>>[],
      });
      return;
    }
    final Map<String, String> errors = <String, String>{};
    for (final McpServerConfig config in mcp.servers()) {
      final String? error = mcp.errorOf(config.name);
      if (error != null) errors[config.name] = error;
    }
    await writeJson(request, 200, <String, dynamic>{
      'services': mcp
          .servers()
          .map((McpServerConfig s) => s.toApiJson())
          .toList(),
      'tools': <Map<String, dynamic>>[
        for (final ({String service, McpToolInfo tool}) entry in mcp.allTools())
          <String, dynamic>{
            'service': entry.service,
            'name': entry.tool.name,
            'mcp_name': namespacedToolName(entry.service, entry.tool.name),
            'description': entry.tool.description,
          },
      ],
      'errors': errors,
    });
  }

  /// `POST /api/mcp/services`：注册（或覆盖）一个 stdio MCP 服务。
  Future<void> _registerMcpService(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final McpService? mcp = mcpService;
    if (mcp == null) {
      await writeJson(request, 501, errorBody('MCP 服务尚未接入'));
      return;
    }
    final Map<String, dynamic> body = await readJsonBody(request);
    final Map<String, dynamic> result = await mcp.register(body);
    final Object? error = result['error'];
    await writeJson(
      request,
      error == null ? 200 : 400,
      error == null ? result : errorBody(error.toString()),
    );
  }

  /// `DELETE /api/mcp/services/{name}`：删除一个服务（内置服务拒绝删除）。
  Future<void> _deleteMcpService(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final McpService? mcp = mcpService;
    if (mcp == null) {
      await writeJson(request, 501, errorBody('MCP 服务尚未接入'));
      return;
    }
    final Map<String, dynamic> result = await mcp.remove(params['name'] ?? '');
    final Object? error = result['error'];
    await writeJson(
      request,
      error == null ? 200 : 404,
      error == null ? result : errorBody(error.toString()),
    );
  }
}

/// 一次热应用的结果：配置**已经落盘**，这里只说"对运行中的插件总线做了什么"。
class PluginHotApplyOutcome {
  const PluginHotApplyOutcome.applied(this.detail) : applied = true;
  const PluginHotApplyOutcome.notApplied(this.detail) : applied = false;

  /// 是否真的作用到了运行中的插件上。
  final bool applied;

  /// 可读说明（applied 时是"做了什么"，否则是"为什么做不到"）。
  final String detail;

  /// 热应用失败时给前端显示的**统一话术**。
  ///
  /// 只在核心拼一次（REST 响应里的 notice 字段），前端原样显示：两边各写一句
  /// 迟早会说法漂移，而这句话是用户判断"我要不要重启核心"的唯一依据。
  static const String restartNotice = '配置已保存，但本次热应用失败，重启核心后生效';
}

/// 热应用接缝：把"配置已落盘"翻译成"对运行中的插件总线做了什么"。
///
/// 做成接缝（而不是把逻辑写死在处理器里）有两个理由：
/// 1. 插件总线正在另一路并行演进——将来它一旦提供"重新读盘 / 单插件断开"的公开
///    方法，只需换掉这个接口的实现，REST 层与前端一个字都不用改；
/// 2. 测试需要确定性地覆盖"热应用失败"这条路径（注入一个永远失败的实现即可）。
abstract class PluginHotApplier {
  Future<PluginHotApplyOutcome> apply(
    Map<String, dynamic> entry, {
    required bool enable,
  });
}

/// 默认热应用：把"配置已落盘"翻译成"对运行中的插件总线做了什么"。
///
/// 实现方式是**一层翻译**：调插件总线的配置对账（[PluginBus.applyConfigs]），再把
/// 对账结论按本条的 plugin_id 回报给 REST 层。真正的事在总线那边：重读 plugins.yaml、
/// 按新配置增删实例、判定"要不要重启"、隔离单个插件的启动失败。这里只负责回答
/// "这一条到底算不算生效"，并给一句可读的解释。
///
/// 为什么要留这层接缝（而不是把逻辑写死在处理器里）：
/// 1. REST 层与前端一个字都不用改就能换实现；
/// 2. 测试可以注入一个永远失败的实现，确定性地覆盖"热应用失败"这条路径。
///
/// 回报口径（**如实**，不假成功）：
/// - started / stopped / restarted / unchanged ⇒ `hot_applied: true` + 做了什么；
/// - failed（命令不存在、脚本缺失等）⇒ `hot_applied: false` +
///   「配置已保存，但本次热应用失败，重启核心后生效」+ 具体原因；
/// - 清单读不出来（YAML 被手改坏）⇒ 同上；此时运行实例保持原样，不因为一次
///   拼写错误把在跑的插件全停掉。
class BusPluginHotApplier implements PluginHotApplier {
  BusPluginHotApplier(this.bus);

  final PluginBus bus;

  @override
  Future<PluginHotApplyOutcome> apply(
    Map<String, dynamic> entry, {
    required bool enable,
  }) async {
    final String id = (entry['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      return const PluginHotApplyOutcome.notApplied('插件条目缺少 id，无法热应用');
    }
    final PluginReconcileResult report;
    try {
      // 对账是**整份清单**级的（不是只处理这一条）：只有把磁盘与运行实例全量对齐，
      // 才谈得上"开关立刻有用"；本次这一条的结论从结果里按 id 取。
      report = await bus.applyConfigs();
    } catch (error) {
      // applyConfigs 内部已做失败隔离；这里兜住任何意外，绝不把异常抛给 REST 层
      return PluginHotApplyOutcome.notApplied('插件配置热应用失败：$error');
    }
    if (report.error.isNotEmpty) {
      return PluginHotApplyOutcome.notApplied(report.error);
    }
    final PluginReconcileAction? action = report.actionOf(id);
    if (action == null) {
      // 本次对账**没有**提到这一条：说明它没在跑、也没有任何动作可做。
      if (!enable) {
        // 删除 / 停用一个没在跑的插件：目标（不跑）本来就达成
        return const PluginHotApplyOutcome.applied('该插件未在运行，无需断开');
      }
      if (!report.totalEnabled) {
        return PluginHotApplyOutcome.notApplied(
          '插件系统总开关为关（plugins.yaml 顶层 enabled: false），本次没有启动 $id',
        );
      }
      return PluginHotApplyOutcome.notApplied(
        '配置对账后没有插件 $id 的结论：它可能已不在 ${bus.configFile} 里',
      );
    }
    return switch (action.kind) {
      PluginReconcileKind.started => PluginHotApplyOutcome.applied(
        '插件已按最新配置启动（${action.reason}）',
      ),
      PluginReconcileKind.stopped => PluginHotApplyOutcome.applied(
        '插件已断开：${action.reason}',
      ),
      PluginReconcileKind.restarted => PluginHotApplyOutcome.applied(
        '插件已按新启动参数重启：${action.reason}',
      ),
      PluginReconcileKind.unchanged => PluginHotApplyOutcome.applied(
        '配置与运行中的实例一致，无需变更：${action.reason}',
      ),
      // 只有"这个插件这次没起来"才回失败——具体原因（命令不存在等）原样带上，
      // 前端会显示「配置已保存，但本次热应用失败，重启核心后生效」+ 这句话。
      PluginReconcileKind.failed => PluginHotApplyOutcome.notApplied(
        '插件 $id 本次未能就绪：${action.reason}',
      ),
    };
  }
}

/// 便捷入口：启动核心并返回握手（CLI 用）。
Future<CoreServer> startCoreServer({
  int port = 0,
  Duration streamChunkDelay = const Duration(milliseconds: 40),
}) => CoreServer.start(port: port, streamChunkDelay: streamChunkDelay);
