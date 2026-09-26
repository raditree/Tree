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
import '../agent/workspace_prompt.dart';
import '../files/file_service.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_service.dart';
import '../plugin/execute_mounts.dart';
import '../plugin/plugin_bus.dart';
import '../plugin/station_scope.dart';
import '../settings/core_settings.dart';
import '../settings/ssh_config.dart';
import '../spec/spec_service.dart';
import '../store/atomic_file.dart';
import '../store/memory_store.dart';
import '../store/tree_store.dart';
import '../team/message_dispatcher.dart';
import '../team/team_service.dart';
import '../tool/terminal_hooks.dart';
import '../tool/todo_store.dart';
import '../util/liveness.dart';
import '../util/token.dart';
import '../version.dart';
import '../ws/inbound_frames.dart';
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
/// 覆盖度不变量（由 `test/server_coverage_test.dart` 强制）：
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
    required this.mcpService,
    required this.pluginBus,
    required this.fileService,
    required this.hub,
    required this.questions,
    required this.compaction,
    required this.conversation,
    required this.router,
    required this.stubRouter,
    required this.reassembler,
    required this.version,
  });

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

  /// 团队服务（M5b）；为 null 时不提供 teammates 路由（测试/最小骨架）。
  final TeamService? teamService;

  /// 团队消息派发（M5c）；为 null 时不提供消息/日志路由。
  final TeamMessageDispatcher? messageDispatcher;

  /// Spec 体系（M5d）；为 null 时 specs 路由返回空索引。
  final SpecService? specService;

  /// 取某 agent 的工作空间 IO（Spec 的自定义文件在工作空间里）。
  final Future<WorkspaceIO?> Function(String agentId)? specIoFor;

  /// MCP 服务（M6a）；为 null 时返回空服务列表。
  final McpService? mcpService;

  /// 插件总线（M6b）；为 null 时快照返回 `enabled: false` 空集。
  final PluginBus? pluginBus;

  /// 执行站首命令集的**挂载位置**（M9 Wave 3-I）；为 null = 未接线（命令会显式报
  /// 「暂无挂载位置」而不是静默成功）。
  ExecuteStationMounts? _stationMounts;

  /// 工作空间文件服务（M7d）；为 null 时文件路由返回 501。
  final FileService? fileService;

  /// 提问回路（M5a）；为 null 时核心不提供 `ask_user_question`（测试/最小骨架）。
  final QuestionBroker? questions;

  /// 上下文压缩（M7d-4）；为 null 时 `agentCompact` 返回 501。
  final CompactionService? compaction;

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
    Duration heartbeatInterval = LivenessTracker.defaultInterval,
    int heartbeatMissLimit = LivenessTracker.defaultMaxMisses,
    TreeStore? store,
    CoreSettings? settings,
    TodoStore? todoStore,
    AgentEngine? engine,
    QuestionBroker? questions,
    TeamService? teamService,
    TeamMessageDispatcher? messageDispatcher,
    SpecService? specService,
    Future<WorkspaceIO?> Function(String agentId)? specIoFor,
    McpService? mcpService,
    PluginBus? pluginBus,
    FileService? fileService,
    CompactionService? compaction,
    TerminalHooks? stationHooks,
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
    // 心跳间隔沿用 [heartbeatInterval]（默认 I=10s，与前端 10s 心跳节奏对齐；
    // 前端间隔必须小于本处判活窗口 I×N，否则"在线但空闲"的连接会被误判失活），
    // 连续 [heartbeatMissLimit]（默认 N=3）拍收不到任何入站帧才判失活。
    // 详见 LivenessWsHub 的类文档。
    final LivenessWsHub hub = LivenessWsHub(
      interval: heartbeatInterval,
      maxMisses: heartbeatMissLimit,
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
      mcpService: mcpService,
      pluginBus: pluginBus,
      fileService: fileService,
      compaction: compaction,
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
    // Q9：Spec 索引注入系统提示词。做成**可设置的 provider**（而不是给
    // `systemPromptWithWorkspace` 加参数）是因为提示词在会话生成与压缩估算两处
    // 拼装，两处必须逐字一致；provider 让它们自动同口径，也不需要改会话服务。
    // `ioFor` 让索引在没有快照时（例如首个会话）能在后台补一次全量扫描。
    if (specService != null) {
      final SpecService specs = specService;
      specs.ioFor = specIoFor;
      // agent 不属于这个 SpecService 的 store（同进程里可能有另一个核心/测试服务器）
      // 时不注入：否则会把别的 store 的索引写进当前提示词。
      String binding(CoreAgent agent) => specs.store.agent(agent.id) == null
          ? ''
          : specs.indexSnapshot(agent.id);
      server._specIndexBinding = binding;
      specIndexProvider = binding;
    }
    // 判死与恢复都要**可见**、要能触发补发（不静默）：
    // - 判死：写错误日志 + 关连接（前端会自动重连，这就是"触发重连"）；
    // - 恢复：把消息派发侧在失活期间登记的待补发消息补出去；
    // - 派发侧活性：接上"全体连接"级别的台账（心跳丢失 ⇒ 派发显式报错 + 登记补发）。
    hub.onStale = (String connectionId, LivenessTracker beat) =>
        server.errorLog?.call('WS 连接 $connectionId ${beat.staleMessage}');
    hub.onLinkStale = (LivenessTracker beat) =>
        server.errorLog?.call('WS 链路 ${beat.staleMessage}');
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
      hub.startHeartbeat(interval: heartbeatInterval);
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
    await _stationMounts?.close();
    await pluginBus?.close();
    // 总结器可能持有自己的 HTTP 连接池（与引擎的池分开）：随服务一起释放
    await compaction?.dispose();
    // 先把在途落盘任务写完再关闭监听（write-behind 的收尾）
    await questions?.questions.flush();
    await store.flush();
    // Q9：绑定还在自己身上才解绑（别的核心实例可能已经接管了全局 provider）
    if (identical(specIndexProvider, _specIndexBinding)) {
      specIndexProvider = null;
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
    // 调用点上下文：team 取 agent 的团队归属（agent / session 由调用点给）
    bus.callSiteContext ??= (String agentId, String sessionId) {
      final CoreAgent? agent = store.agent(agentId);
      return StationScopeContext(
        teamId: agent?.teamId ?? '',
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
      log: (String message) => errorLog?.call('[core:station] $message'),
    );
    _stationMounts = mounts;
    // 运行期四元组就绪 = 工具表的失效点：下次刷新点按**真实工作面**（local/ssh）
    // 重新收集一次（CLI 里 plugins.start() 早于本接线，那次用的是声明里的 mode）。
    bus.invalidateToolTable(reason: '站点接线完成（运行期四元组就绪）');
    final String? mountError = bus.mountExecuteStations(mounts);
    if (mountError != null) {
      errorLog?.call('执行站挂载位置接线不完整：$mountError');
    }
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
    // `server_coverage_test` 保证不相交且并集覆盖 ApiPaths.kept。
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
      onDone: () => hub.unregister(connection.id),
      onError: (Object _) => hub.unregister(connection.id),
      cancelOnError: true,
    );
  }

  /// 建连接：核心默认用带活性观测的 [LivenessWsConnection]（M9 1.1）；
  /// 注入普通 [WsHub] 的调用方退回基类连接（行为与旧版完全一致）。
  WsConnection _createConnection(WebSocket socket) {
    final WsHub registry = hub;
    if (registry is LivenessWsHub) return registry.createConnection(socket);
    return WsConnection(socket: socket);
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
    router.add('POST', ApiPaths.agentCompact, _compactAgent);
    router.add('GET', ApiPaths.questions, _listQuestions);
    router.add('POST', ApiPaths.questionAnswer, _answerQuestion);
    router.add('GET', ApiPaths.settingsFrameRate, _getFrameRate);
    router.add('POST', ApiPaths.settingsFrameRate, _setFrameRate);
    router.add('GET', ApiPaths.settingsTokenRate, _getTokenRate);
    router.add('POST', ApiPaths.settingsTokenRate, _setTokenRate);
    router.add('GET', ApiPaths.settingsMessageCutin, _getMessageCutin);
    router.add('POST', ApiPaths.settingsMessageCutin, _setMessageCutin);
    router.add('POST', ApiPaths.settingsDataCollection, _setDataCollection);
    router.add('GET', ApiPaths.files, _listFiles);
    router.add('GET', ApiPaths.fileContent, _fileContent);
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

    // ── 工作空间目录与 SSH 配置（M7c）：前端「运行模式」直接改 agent 配置 ──
    // 语义与模型配置一致：字段缺失 = 不改；显式空值 = 清空。
    bool touched = false;
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
    if (touched) {
      agent.updatedAt = DateTime.now().millisecondsSinceEpoch;
      store.putAgent(agent);
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'agent': agent.toApiJson(),
      if (agent.sshConfig != null) 'ssh': _sshView(agent.sshConfig!),
    });
  }

  /// SSH 配置的前端形态：在 `redacted()` 基础上补 `key_path`（表单预填需要），
  /// **仍然绝不含 password / key_passphrase**。
  static Map<String, dynamic> _sshView(SshConfig config) => <String, dynamic>{
    ...config.redacted(),
    if (config.keyPath.isNotEmpty) 'key_path': config.keyPath,
  };

  Future<void> _deleteAgent(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String agentId = params['agentId'] ?? '';
    final bool removed = store.deleteAgent(agentId);
    if (!removed) {
      await writeJson(request, 404, errorBody('agent 不存在'));
      return;
    }
    // 提问记录不随会话数据删除：agent 没了还留着提问会让右栏出现孤儿卡片
    final int questionsRemoved =
        questions?.questions.removeForAgent(agentId) ?? 0;
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      if (questionsRemoved > 0) 'questions_removed': questionsRemoved,
    });
  }

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
      // agent 级模型参数覆盖（M5 成员/覆盖特性落地）
      'overrides': <String, dynamic>{},
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
    final String? path = dispatcher.activityLogPath(memberId);
    String log = '';
    if (path != null) {
      final String? tail = AtomicFile.readTailOrNullSync(path, 64 * 1024);
      if (tail != null && tail.isNotEmpty) {
        final List<String> all = const LineSplitter().convert(tail);
        log = all.length <= lines
            ? all.join('\n')
            : all.sublist(all.length - lines).join('\n');
      }
    }
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'log': log,
      'path': path ?? '',
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

  Future<void> _getMessageCutin(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    await writeJson(request, 200, <String, dynamic>{
      'mode': settings.messageCutinDirect ? 'direct' : 'queue',
    });
  }

  Future<void> _setMessageCutin(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    settings.messageCutinDirect = (body['mode'] as String?) == 'direct';
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'mode': settings.messageCutinDirect ? 'direct' : 'queue',
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
    await writeJson(
      request,
      200,
      bus.snapshot(teamId: request.uri.queryParameters['team_id']),
    );
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

/// 便捷入口：启动核心并返回握手（CLI 用）。
Future<CoreServer> startCoreServer({
  int port = 0,
  Duration streamChunkDelay = const Duration(milliseconds: 40),
}) => CoreServer.start(port: port, streamChunkDelay: streamChunkDelay);
