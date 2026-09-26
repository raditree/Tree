import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../agent/agent_engine.dart';
import '../agent/conversation_service.dart';
import '../agent/question_broker.dart';
import '../agent/question_store.dart';
import '../agent/scripted_agent.dart';
import '../files/file_service.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_service.dart';
import '../plugin/plugin_bus.dart';
import '../settings/core_settings.dart';
import '../settings/ssh_config.dart';
import '../spec/spec_service.dart';
import '../store/atomic_file.dart';
import '../store/memory_store.dart';
import '../store/tree_store.dart';
import '../team/message_dispatcher.dart';
import '../team/team_service.dart';
import '../tool/todo_store.dart';
import '../util/token.dart';
import '../version.dart';
import '../ws/inbound_frames.dart';
import '../ws/ws_hub.dart';
import 'http_io.dart';
import 'http_router.dart';

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
    required this.conversation,
    required this.router,
    required this.stubRouter,
    required this.reassembler,
    required this.version,
  });

  /// WS 端点路径（前端 `WebSocketService.connect` 固定拼接 `/ws?token=`）。
  static const String wsPath = '/ws';

  /// M1 尚未实现、但前端会调用的路径（以 501 明确拒绝，而非静默 404）。
  ///
  /// 分组与归属里程碑：
  /// - 文件与工作空间：`files` / `fileContent` / `filePdf*` / `fileUpload*` /
  ///   `fileSyncToLocal`（M4 本地执行 + M7 文档能力）
  /// - Git 历史：`workspaceGitLog` / `workspaceGitBranches`（M4）
  static const Set<String> stubApiPaths = <String>{
    // PDF 预览需要 PDF 光栅化（纯 Dart 无此能力，待决策）；上传/同步属写路径，
    // 留待与下载一起做（M7d-2）
    ApiPaths.agentCompact,
    ApiPaths.fileDownloadFolder,
    ApiPaths.fileUpload,
    ApiPaths.filePdfPreview,
    ApiPaths.fileUploadInit,
    ApiPaths.fileUploadChunk,
    ApiPaths.fileUploadComplete,
    ApiPaths.fileSyncToLocal,
  };

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

  /// 工作空间文件服务（M7d）；为 null 时文件路由返回 501。
  final FileService? fileService;

  /// 提问回路（M5a）；为 null 时核心不提供 `ask_user_question`（测试/最小骨架）。
  final QuestionBroker? questions;

  /// 会话服务（用户消息 → 流式回复）。
  final ConversationService conversation;

  /// 已实现路由。
  final CoreRouter router;

  /// 显式登记为"未实现（501）"的路由。
  final CoreRouter stubRouter;

  /// WS 上行分片重组。
  final InboundFrameReassembler reassembler;

  /// 版本号。
  final String version;

  /// 启动时刻。
  DateTime startedAt = DateTime.now();

  /// 请求级访问日志回调（CLI `--verbose` 打开；默认关闭以免刷屏）。
  void Function(String message)? accessLog;

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
  static Future<CoreServer> start({
    InternetAddress? address,
    int port = 0,
    String? token,
    String version = treeCoreVersion,
    Duration streamChunkDelay = const Duration(milliseconds: 40),
    bool enableHeartbeat = true,
    Duration heartbeatInterval = const Duration(seconds: 30),
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
    final WsHub hub = WsHub();
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
      hub: hub,
      questions: questions,
      conversation: ConversationService(
        store: resolvedStore,
        hub: hub,
        settings: resolvedSettings,
        questions: questions,
        engine: engine ?? ScriptedAgent(chunkDelay: streamChunkDelay),
      ),
      router: CoreRouter(),
      stubRouter: CoreRouter(),
      reassembler: InboundFrameReassembler(),
      version: version,
    );
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
    await pluginBus?.close();
    // 先把在途落盘任务写完再关闭监听（write-behind 的收尾）
    await questions?.questions.flush();
    await store.flush();
    await _http.close(force: force);
  }

  // ── 请求分发 ─────────────────────────────────────────────────────────

  void _dispatch(HttpRequest request) {
    unawaited(
      _handle(request).catchError((Object error, StackTrace _) async {
        internalErrors++;
        _access(request, 500);
        try {
          await writeJson(request, 500, errorBody('核心进程内部错误：$error'));
        } catch (_) {
          // 响应已关闭：无法回包，仅计数
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
    final WsConnection connection = WsConnection(socket: socket);
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

  void _handleWsFrame(WsConnection connection, dynamic data) {
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
      case WsInboundType.registerLocalExecutor:
        connection.send(<String, dynamic>{
          'type': WsOutboundType.registerLocalExecutorAck,
          'data': <String, dynamic>{
            'success': true,
            'team_id': _dataField(frame, 'team_id'),
          },
        });
        break;
      case WsInboundType.unregisterLocalExecutor:
        connection.send(<String, dynamic>{
          'type': WsOutboundType.unregisterLocalExecutorAck,
          'data': <String, dynamic>{
            'success': true,
            'team_id': _dataField(frame, 'team_id'),
          },
        });
        break;
      case WsInboundType.registerSshExecutor:
        // 前端按 FIFO 匹配 ack 且不回显 team_id（见 SshExecutorService）。
        // M4 接入真实 SSH 前先回成功，避免设置面板等待 15s 超时。
        connection.send(<String, dynamic>{
          'type': WsOutboundType.registerSshExecutorAck,
          'data': <String, dynamic>{'success': true},
        });
        break;
      case WsInboundType.unregisterSshExecutor:
        connection.send(<String, dynamic>{
          'type': WsOutboundType.unregisterSshExecutorAck,
          'data': <String, dynamic>{'success': true},
        });
        break;
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
      case WsInboundType.toolExecResponse:
      case WsInboundType.toolExecProgress:
        // M4 反向执行通道的回报；M1 不会下发 tool_exec_request
        break;
      case WsInboundType.pluginHostEvent:
        // M6 插件宿主生命周期事件
        break;
      default:
        // 未知帧静默忽略（前向兼容：新前端配旧核心不应崩溃）
        break;
    }
  }

  static Map<String, dynamic>? _decodeFrame(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String _dataField(Map<String, dynamic> frame, String key) {
    final Map<String, dynamic> data =
        (frame['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return (data[key] as String?) ?? '';
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
    router.add('GET', ApiPaths.questions, _listQuestions);
    router.add('POST', ApiPaths.questionAnswer, _answerQuestion);
    router.add('GET', ApiPaths.settingsFrameRate, _getFrameRate);
    router.add('POST', ApiPaths.settingsFrameRate, _setFrameRate);
    router.add('GET', ApiPaths.settingsRateLimit, _getRateLimit);
    router.add('POST', ApiPaths.settingsRateLimit, _setRateLimit);
    router.add('GET', ApiPaths.settingsMessageCutin, _getMessageCutin);
    router.add('POST', ApiPaths.settingsMessageCutin, _setMessageCutin);
    router.add('POST', ApiPaths.settingsDataCollection, _setDataCollection);
    router.add('GET', ApiPaths.files, _listFiles);
    router.add('GET', ApiPaths.fileContent, _fileContent);
    router.add('GET', ApiPaths.filePdfInfo, _filePdfInfo);
    router.add('POST', ApiPaths.fileDownload, _downloadFile);
    router.add('GET', ApiPaths.workspaceGitLog, _workspaceGitLog);
    router.add('GET', ApiPaths.workspaceGitBranches, _workspaceGitBranches);
    router.add('GET', ApiPaths.pluginSnapshot, _pluginSnapshot);
    router.add('GET', ApiPaths.mcpServices, _mcpServices);
    router.add('POST', ApiPaths.mcpServices, _registerMcpService);
    router.add('DELETE', ApiPaths.mcpService, _deleteMcpService);
  }

  // ── agent ────────────────────────────────────────────────────────────

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
      // SSH 配置的**非机密**部分（host/port/username/key_path/root 与认证方式），
      // 供前端编辑；密码与口令永不回显。
      if (agent.sshConfig != null) 'ssh': agent.sshConfig!.redacted(),
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
      if (agent.sshConfig != null) 'ssh': agent.sshConfig!.redacted(),
    });
  }

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
    final List<String> ids =
        teamService?.cascadeIds(agentId) ?? <String>[agentId];
    bool anyRunning = false;
    for (final String id in ids) {
      final bool running = conversation.cancelAgent(id);
      anyRunning = anyRunning || running;
      if (!running) {
        hub.broadcast(<String, dynamic>{
          'type': WsOutboundType.agentStatus,
          'data': <String, dynamic>{
            'agent_id': id,
            'status': 'idle',
            if (sessionId.isNotEmpty) 'session_id': sessionId,
          },
        });
      }
    }
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

  Future<void> _getRateLimit(HttpRequest request, Map<String, String> _) async {
    await writeJson(request, 200, <String, dynamic>{
      'enabled': settings.rateLimitEnabled,
    });
  }

  Future<void> _setRateLimit(HttpRequest request, Map<String, String> _) async {
    final Map<String, dynamic> body = await readJsonBody(request);
    settings.rateLimitEnabled = body['enabled'] as bool? ?? false;
    await writeJson(request, 200, <String, dynamic>{
      'success': true,
      'enabled': settings.rateLimitEnabled,
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
  Future<bool> _writeFileError(
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
    final Map<String, dynamic> result = files.list(
      params['workspaceId'] ?? '',
      path: request.uri.queryParameters['path'] ?? '',
    );
    if (await _writeFileError(request, result)) return;
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
    final Map<String, dynamic> result = files.content(
      params['workspaceId'] ?? '',
      request.uri.queryParameters['path'] ?? '',
    );
    if (await _writeFileError(request, result)) return;
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
    final Map<String, dynamic> result = files.readBytes(
      params['workspaceId'] ?? '',
      (body['path'] ?? '').toString(),
    );
    if (await _writeFileError(request, result)) return;
    await writeBytes(
      request,
      200,
      result['bytes'] as List<int>,
      filename: result['name'] as String?,
    );
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
    final Map<String, dynamic> result = files.pdfInfo(
      params['workspaceId'] ?? '',
      request.uri.queryParameters['path'] ?? '',
    );
    if (await _writeFileError(request, result)) return;
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
    if (await _writeFileError(request, result)) return;
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
    if (await _writeFileError(request, result)) return;
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
