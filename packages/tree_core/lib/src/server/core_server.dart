import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:path/path.dart' as p;
import 'package:tree_protocol/tree_protocol.dart';

import '../plugin/builtin_plugins.dart';
import '../plugin/execute_mounts.dart';
import '../plugin/plugin_bus.dart';
import '../plugin/plugin_config_store.dart';
import '../plugin/plugin_dependency.dart';
import '../plugin/plugin_downloader.dart';
import '../plugin/plugin_host.dart' show PluginConfig, PluginException;
import '../plugin/station_ws_bridge.dart';
import '../settings/core_settings.dart';
import '../store/memory_store.dart';
import '../store/plugin_store.dart';
import '../store/tree_paths.dart';
import '../store/tree_store.dart';
import '../util/core_log_sink.dart';
import '../util/ids.dart';
import '../util/liveness.dart';
import '../util/plugin_log_sink.dart';
import '../util/token.dart';
import '../version.dart';
import '../ws/inbound_frames.dart';
import '../ws/ws_hub.dart';
import 'http_io.dart';
import 'http_router.dart';
import 'bootstrap_page.dart';
import 'token_registry.dart';
import 'ws_liveness.dart';

/// 核心进程的回环 HTTP + WS 服务（A5 后的平台面）。
///
/// 设计要点（见迁移方案 §4）：
/// - **只监听 127.0.0.1**：不接受外部连接；
/// - **随机端口 + 一次性随机 token**：端口由内核分配，token 仅经 stdout
///   握手行交给父进程（不落盘），因此同机其他进程无法假冒；
/// - **协议形状与现状 server 完全一致**：lib/ui（约 15k 行）无需改动，
///   `lib/io` 只是把 baseUrl/token 换成核心下发的值；
/// - **零第三方依赖**：便于 `dart compile exe` 出单文件可执行。
///
/// A5（2026-10-25）起核心只保留平台面（`ApiPaths.coreOwned` 的 39 条方法路由）：
/// 插件控制面 19（含 UI 多窗口 3）+ 传输设置 9 + 引导壳 3 + 发现面 1 + 日志 3 + 存储 4。
/// 领域面（agent / files / llm / spec / team / terminal / tool）已整体移交插件，
/// 对应路由由插件经 `system.collect.api.routes` 申报后走 [delegatedRouter] 承接；
/// 核心不再注册、也不再实现它们（files/git/spec/terminal 暂时没有承接方 ⇒ 404）。
class CoreServer {
  CoreServer._(
    this._http, {
    required this.processId,
    required this.dataDir,
    required this.token,
    required this.store,
    required this.settings,
    required this.pluginBus,
    required this.builtinPlugins,
    required this.pluginHotApplier,
    required this.pluginDownloader,
    required this.hub,
    required this.router,
    required this.stubRouter,
    required this.reassembler,
    required this.version,
    Duration bootstrapTicketTtl = const Duration(minutes: 5),
    Duration bootstrapSessionTtl = const Duration(minutes: 10),
    DateTime Function()? tokenClock,
    String? bootstrapSourcePath,
  }) {
    tokens = TokenRegistry(
      primaryToken: token,
      ticketTtl: bootstrapTicketTtl,
      sessionTtl: bootstrapSessionTtl,
      clock: tokenClock,
      log: (String message) => errorLog?.call(message),
    );
    bootstrapPage = BootstrapPage(
      dataDir: dataDir,
      sourcePath: bootstrapSourcePath,
      log: (String message) => errorLog?.call(message),
    );
    final TreePaths apiPaths = TreePaths(dataDir);
    logSources = LogSourceRegistry(
      paths: apiPaths,
      pluginIds: () =>
          pluginBus?.configs().map((PluginConfig c) => c.id).toList() ??
          const <String>[],
    );
    pluginStore = PluginStore(paths: apiPaths);
    // 插件运行日志的落盘出口（日志 API 的数据源）。
    // 绑定发生在插件被拉起之前（生产：CLI 先 CoreServer.start 再 plugins.start）。
    pluginLogSink = PluginLogSink(
      apiPaths,
      failureLog: (String message) => errorLog?.call(message),
    );
    pluginBus?.bindPluginLog(
      (String pluginId, String line, String channel) =>
          pluginLogSink.write(pluginId, line, channel: channel),
    );
  }

  /// WS 端点路径（前端 `WebSocketService.connect` 固定拼接 `/ws?token=`）。
  static const String wsPath = '/ws';

  /// 存储 API 的**调用方插件身份**头（小写，`HttpHeaders.value` 不区分大小写）。
  ///
  /// 为什么不是独立插件 token：当前 UI 插件与核心共用主 token（片 D 的
  /// `TREE_CORE_TOKEN`），没有第二套凭据。这里的身份是**自报 + 白名单校验**：
  /// 头里的 id 必须能在已配置插件清单里找到，否则 403；未带头 ⇒ 主 token 视为
  /// 核心自身（命名空间 `core`）。跨命名空间一律 403，且不查目标是否存在
  /// （不变量 25：不泄露该命名空间是否存在）。
  static const String pluginIdHeader = 'x-tree-plugin-id';

  /// 尚未实现、但前端会调用的路径（以 501 明确拒绝，而非静默 404）。
  ///
  /// **M7 已清空**：PDF 预览改成前端渲染（M7e 方案②，核心只给字节，见
  /// `lib/ui/widgets/pdf_preview.dart`），最后一项桩随之删除。保留这套机制给后续
  /// 新接口用——「前端会调、核心静默 404」的灰区比多条空集合更值得防。
  static const Set<String> stubApiPaths = <String>{};

  /// 核心 HTTP API 的版本（`/api/meta.api_version`）。
  ///
  /// 与插件配置里的 `requires.api` 对比用；片 B 固定 1.0，协议形状变化才升。
  /// 单一来源在 [treeCoreApiVersion]（插件闸门也用同一个常量）。
  static const String apiVersion = treeCoreApiVersion;

  /// UI 插件 ⇄ 站点总线的 WS 接线；插件系统未启用（测试 / 最小骨架）时为 null。
  StationWsBridge? _stationWsBridge;

  final HttpServer _http;

  /// 本进程 pid（父进程退出时兜底清理用）。
  final int processId;

  /// 本次运行的一次性本地 token。
  final String token;

  /// token 作用域注册表（主 token / 引导票据 / 引导会话）。
  late final TokenRegistry tokens;

  /// 引导页磁盘种子与渲染。
  late final BootstrapPage bootstrapPage;

  /// 日志 API 的源注册与尾部读（片 F；核心永久面）。
  late final LogSourceRegistry logSources;

  /// 插件命名空间存储（片 F；`/api/store/{ns}/{key}` 的落盘实现）。
  late final PluginStore pluginStore;

  /// 插件运行日志的落盘出口（`<数据根>/logs/plugins/<id>.log`）。
  ///
  /// 写入者是插件总线的两路回调（stderr / `log` 通知），读取者是
  /// `LogSourceRegistry`（`/api/logs/plugin:<id>`）。两者同一个文件。
  late final PluginLogSink pluginLogSink;

  /// 存储（默认内存实现；CLI 注入 `FileTreeStore` 落 `~/.tree`）。
  ///
  /// A5 后平台面不再读写领域数据；保留字段只是为了启动参数兼容与未来平台状态。
  final TreeStore store;

  /// 设置（只保留平台级：帧率 / 心跳判活 / 数据收集开关）。
  final CoreSettings settings;

  /// WS 连接注册表与广播。
  final WsHub hub;

  /// 在线生效的 WS 判活节拍 I（= 保活定时器的实际间隔）。
  Duration _liveHeartbeatInterval = LivenessTracker.defaultInterval;

  /// 在线生效的 WS 判活阈值 N（在线连接的 `LivenessTracker.maxMisses`）。
  int _liveHeartbeatMissLimit = LivenessTracker.defaultMaxMisses;

  /// 调用方是否显式传过心跳参数：显式传参后设置不热更新。
  bool _heartbeatPinned = false;

  /// 保活/判活是否开启：`enableHeartbeat: false` 时不热更新。
  bool _heartbeatEnabled = false;

  /// 在线生效的 WS 判活节拍（= 保活定时器实际间隔；设置变更后热更新）。
  Duration get liveHeartbeatInterval => _liveHeartbeatInterval;

  /// 在线生效的 WS 判活阈值。
  int get liveHeartbeatMissLimit => _liveHeartbeatMissLimit;

  /// 插件总线；为 null 时快照返回 `enabled: false` 空集。
  final PluginBus? pluginBus;

  /// 内置插件目录：静态清单 + 运行时/脚本解析。
  final BuiltinPluginCatalog builtinPlugins;

  /// 热应用接缝（把"配置已落盘"翻译成"对运行中的插件总线做了什么"）。
  final PluginHotApplier? pluginHotApplier;

  /// 插件**发布仓库**的取清单 / 下载 / 放置；null = 三个路由给可读 503。
  final PluginDownloader? pluginDownloader;

  /// 执行站平台命令的挂载位置（`plugin.*` / `station.*`）。
  ExecuteStationMounts? _stationMounts;

  /// 已实现路由（A5 后 = [ApiPaths.coreOwned] 的 39 条）。
  final CoreRouter router;

  /// 显式登记为"未实现（501）"的路由。
  final CoreRouter stubRouter;

  /// 插件委派路由归属表（`system.collect.api.routes` 收集到的申报）。
  ///
  /// 查表顺序：已实现 [router] → [delegatedRouter] → 501 [stubRouter] → 404；
  /// 委派优先于桩但**永远不能**抢在已实现路由之前。
  final DelegatedRouter delegatedRouter = DelegatedRouter();

  /// 核心数据根（委派临时文件 `<dataDir>/tmp/api-delegate/` 的父目录）。
  final String dataDir;

  /// 委派请求/响应超过该字节数时改走磁盘（`body_path` / `result_path`）。
  static const int delegateInlineBodyLimit = 1 << 20;

  /// WS 上行分片重组。
  final InboundFrameReassembler reassembler;

  /// 版本号。
  final String version;

  /// 请求级访问日志回调（CLI `--verbose` 打开；默认关闭以免刷屏）。
  void Function(String message)? accessLog;

  /// 未捕获异常日志回调（CLI 接到 stderr，始终打开）。
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
  static Future<CoreServer> start({
    InternetAddress? address,
    int port = 0,
    String? token,
    String version = treeCoreVersion,
    bool enableHeartbeat = true,
    Duration? heartbeatInterval,
    int? heartbeatMissLimit,
    TreeStore? store,
    CoreSettings? settings,
    PluginBus? pluginBus,
    BuiltinPluginCatalog? builtinPlugins,
    PluginHotApplier? pluginHotApplier,
    PluginDownloader? pluginDownloader,

    /// 发布仓库的下载缓存目录（生产传 `TreePaths.pluginsReleaseDir`）。
    String? pluginReleaseCacheDir,

    /// 核心数据根（CLI 传 `TreePaths.root`；null 时从插件配置路径反推）。
    String? dataDir,

    /// 引导页种子路径（测试注入；空 = 按 exe 同级 / 当前目录 / 仓库根探测）。
    String? bootstrapSourcePath,

    /// 引导票据与引导会话的时长（测试可缩短到毫秒级）。
    Duration bootstrapTicketTtl = const Duration(minutes: 5),
    Duration bootstrapSessionTtl = const Duration(minutes: 10),

    /// token 注册表的时钟（测试注入可控时间）。
    DateTime Function()? tokenClock,
  }) async {
    final HttpServer http = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    // 静态方法内 `pid` 即 `dart:io` 顶层 getter（本类字段名为 processId，无遮蔽）
    final int currentPid = pid;
    final TreeStore resolvedStore = store ?? MemoryStore();
    final CoreSettings resolvedSettings = settings ?? CoreSettings();
    // 心跳判活参数默认取设置（I=10s / N=3）：设置层保证 I×N **严格大于**前端固定的
    // 10s WS 心跳（见 CoreSettings.minLivenessWindowSeconds）。
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
    final BuiltinPluginCatalog resolvedBuiltinPlugins =
        builtinPlugins ?? BuiltinPluginCatalog();
    final String resolvedToken = token ?? CoreToken.generate();
    // 委派临时文件的根：优先用调用方显式给的 dataDir；否则从插件配置路径反推
    // （`<数据根>/config/plugins.yaml` 的上两级）；都没有时退到系统临时目录。
    final String resolvedDataDir =
        (dataDir == null || dataDir.trim().isEmpty)
        ? (pluginBus == null
              ? p.join(Directory.systemTemp.path, 'tree_core')
              : p.dirname(p.dirname(pluginBus.configFile)))
        : dataDir;
    if (pluginBus != null) pluginBus.dataDir = resolvedDataDir;
    // 默认下载器接三个既有出口：已装条目读 plugins.yaml、脚本型解释器用**与内置
    // 插件同一个**探测口径、换文件闸门问总线（只有它知道进程在不在）。
    final PluginDownloader? resolvedDownloader =
        pluginDownloader ??
        _releaseDownloaderFor(
          cacheDir: pluginReleaseCacheDir,
          bus: pluginBus,
          catalog: resolvedBuiltinPlugins,
        );
    // 片 E：品牌申报的路径闸门只认这几处插件目录（相对路径也按它们解析）。
    pluginBus?.configureBrandingDirs(<String>{
      defaultPluginInstallDir(),
      ...resolvedBuiltinPlugins.scriptRoots(),
    });
    final CoreServer server = CoreServer._(
      http,
      processId: currentPid,
      dataDir: resolvedDataDir,
      token: resolvedToken,
      store: resolvedStore,
      settings: resolvedSettings,
      pluginBus: pluginBus,
      builtinPlugins: resolvedBuiltinPlugins,
      // 默认热应用 = 总线公开面实现；总线为空时也用同一份（apply 前会先判空）
      pluginHotApplier:
          pluginHotApplier ??
          (pluginBus == null ? null : BusPluginHotApplier(pluginBus)),
      pluginDownloader: resolvedDownloader,
      hub: hub,
      router: CoreRouter(),
      stubRouter: CoreRouter(),
      reassembler: InboundFrameReassembler(),
      version: version,
      bootstrapTicketTtl: bootstrapTicketTtl,
      bootstrapSessionTtl: bootstrapSessionTtl,
      tokenClock: tokenClock,
      bootstrapSourcePath: bootstrapSourcePath,
    );
    // 片 D：UI 插件要用 `TREE_CORE_URL` / `TREE_CORE_TOKEN` 直连本核心。
    // 监听成功后立刻把实际端口与 token 接到总线上（CLI 里 plugins.start() 在这之后）。
    pluginBus?.bindCoreEndpoint(
      url: 'ws://127.0.0.1:${server.port}',
      token: server.token,
    );
    // 记录"在线生效"的判活参数：设置变更时用它判断能不能热更新节拍，也是观测/
    // 测试的读数点（见 liveHeartbeatInterval / liveHeartbeatMissLimit）。
    server._heartbeatPinned = heartbeatPinned;
    server._heartbeatEnabled = enableHeartbeat;
    server._liveHeartbeatInterval = resolvedHeartbeatInterval;
    server._liveHeartbeatMissLimit = resolvedHeartbeatMissLimit;
    // 判死与恢复都要**可见**：判死写错误日志 + 关连接（前端会自动重连）。
    hub.onStale = (String connectionId, LivenessTracker beat) {
      final String text = server._livenessLogText(beat);
      server.errorLog?.call('WS 连接 $connectionId $text');
    };
    hub.onLinkStale = (LivenessTracker beat) {
      final String text = server._livenessLogText(beat);
      server.errorLog?.call('WS 链路 $text');
    };
    // 平台执行站（plugin.* / station.*）+ UI 插件 WS 站点总线接线。
    server._wirePluginStations();
    server._registerRoutes();
    // L-28：把核心**当前已实现**的方法路由交给委派归属表做同键拒收。
    // 绑定的是注册后的实际键集：插件对同一 `METHOD pattern` 的申报会自动生效。
    server.delegatedRouter.bindCoreRoutes(server.router.routes);
    server._registerStubRoutes();
    if (enableHeartbeat) {
      hub.startHeartbeat(interval: resolvedHeartbeatInterval);
    }
    http.listen(server._dispatch, onError: (Object _) {}, cancelOnError: false);
    return server;
  }

  /// 关闭服务并释放全部连接（幂等）。
  Future<void> close({bool force = true}) async {
    reassembler.clear();
    await hub.closeAll();
    // 执行站挂载位置没有自有资源（A5 起不再持有 TerminalHooks / PTY）。
    await _stationMounts?.close();
    await pluginBus?.close();
    // 插件进程已停 ⇒ 不会再产生 stderr；把在途日志行落完再关监听。
    await pluginLogSink.close();
    await store.flush();
    await _http.close(force: force);
  }

  // ── 站点接线（A5 平台面：plugin.* / station.*） ─────────────────────────

  /// 执行站平台命令的挂载位置 + 插件总线需要的**运行期四元组**解析器。
  ///
  /// A5 后核心不再实现领域命令（fs.* / terminal.* / agent.* / llm.call / tool.*）；
  /// 这里只把两族平台命令（`plugin.*` / `station.*`）挂到内置执行站上，并接上
  /// UI 插件的 WS 站点总线。
  void _wirePluginStations() {
    final PluginBus? bus = pluginBus;
    if (bus == null) return;
    final ExecuteStationMounts mounts = ExecuteStationMounts(
      pluginManager: bus.handlePluginCommand,
      topologyQuery: bus.handleStationQuery,
      log: (String message) => errorLog?.call('[core:station] $message'),
    );
    _stationMounts = mounts;
    // 内置站原本是**懒创建**的，这里在接线处确保三站存在（幂等 + 持久化由
    // StationHub.ensureBuiltinStations 保证；收集站不预建）。
    final List<String> prebuiltStations = bus.stations.ensureBuiltinStations();
    if (prebuiltStations.isNotEmpty) {
      errorLog?.call(
        '[core:station] 预建内置站 '
        '${prebuiltStations.length} 个：${prebuiltStations.join('、')}',
      );
    }
    // 片 C：收集 `system.collect.api.routes`，把插件申报写进委派归属表。
    bus.bindDelegatedRouter(delegatedRouter);
    bus.invalidateToolTable(reason: '站点接线完成（运行期四元组就绪）');
    final String? mountError = bus.mountExecuteStations(mounts);
    if (mountError != null) {
      errorLog?.call('执行站挂载位置接线不完整：$mountError');
    }
    // 片 B：UI 插件的 WS 站点总线。桥只做「连接身份 + 广播站订阅 + 四态投递 +
    // 自建站生命周期」，不碰 REST 委派（片 C）也不决定 UI 启动方式（片 D）。
    final StationWsBridge bridge = _stationWsBridge ??= StationWsBridge(
      stations: bus.stations,
      configs: bus.configs,
      routes: delegatedRouter.metaRoutes,
      log: (String message) => errorLog?.call('[core:station/ws] $message'),
      // 片 D：UI 插件连上后解除连接窗口的 degraded（总线只记状态，不做事）。
      onUiHello: (String pluginId, String windowId) {
        bus.noteUiHello(pluginId, windowId: windowId);
        // 片 E / 5.2：会话 token 在**首个** UI `ui.hello` 成功后吊销。
        tokens.revokeSessions(reason: 'UI 插件 $pluginId 已连接');
      },
      // 片 E / 5.5：品牌申报随 `ui.hello` 到达。
      onUiBranding: (String pluginId, Object? branding) {
        unawaited(bus.declareUiBranding(pluginId, branding));
      },
      branding: () => bus.activeBranding,
    );
    bus.stations.onStationRemoved = bridge.onStationRemoved;
    bus.onPluginOffline = bridge.onPluginOffline;
  }

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
    if (request.method == 'GET' && request.uri.path == ApiPaths.bootstrap) {
      // 引导页本身不认 Authorization：它只认 loader 签发的**一次性票据**。
      await _handleBootstrapPage(request, const <String, String>{});
      _access(request, request.response.statusCode);
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path == ApiPaths.bootstrapSession) {
      // 票据换会话：同样不走主 token（页面手里没有主 token）。
      await _handleBootstrapSession(request, const <String, String>{});
      _access(request, request.response.statusCode);
      return;
    }
    final TokenAccess? accessed = tokens.resolveAuthorization(
      request.headers.value(HttpHeaders.authorizationHeader),
    );
    if (accessed == null) {
      rejectedRequests++;
      _access(request, 401);
      await writeJson(request, 401, errorBody('本地 token 无效或已过期'));
      return;
    }
    if (accessed.isBootstrapSession &&
        !TokenRegistry.allowsBootstrapSession(
          request.method,
          request.uri.path,
        )) {
      // 会话 token 已知但权限不足：403（而不是 401，避免页面误以为票据过期）。
      rejectedRequests++;
      _access(request, 403);
      await writeJson(
        request,
        403,
        errorBody('引导会话 token 只放行插件端点与 GET /api/meta'),
      );
      return;
    }
    final List<String> segments = request.uri.pathSegments;
    // 查表顺序（片 C）：**已实现路由** → 委派归属表 → 桩路由（501）→ 404。
    // - 已实现路由必须先匹配：插件即使申报了同一 pattern 也抢不走核心实现；
    // - 委派必须**先于**桩：桩覆盖所有 kept 路径，否则"已申报委派"永远是 501。
    final HttpRouteMatch? match = router.match(request.method, segments);
    if (match != null) {
      await match.route.handler(request, match.params);
      _access(request, request.response.statusCode);
      return;
    }
    final DelegatedRouteMatch? delegated = delegatedRouter.match(
      request.method,
      segments,
    );
    if (delegated != null) {
      await _handleDelegated(request, delegated);
      _access(request, request.response.statusCode);
      return;
    }
    final HttpRouteMatch? stub = stubRouter.match(request.method, segments);
    if (stub != null) {
      await stub.route.handler(request, stub.params);
      _access(request, request.response.statusCode);
      return;
    }
    notFoundRequests++;
    _access(request, 404);
    await writeJson(request, 404, errorBody('未知接口：${request.uri.path}'));
  }

  // ── 引导壳（片 E） ───────────────────────────────────────────────────

  /// `GET /bootstrap?t=<ticket>`：校验票据、**当场作废**，返回磁盘上的引导页。
  ///
  /// 页面里的 `__BOOTSTRAP_TICKET__` 会替换成一张**新的**换会话票据：loader 那张
  /// 已经在本次请求里消费掉，重复使用一律 401。
  Future<void> _handleBootstrapPage(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final String? reason = tokens.consumeBootstrapTicket(
      request.uri.queryParameters['t'],
    );
    if (reason != null) {
      rejectedRequests++;
      await writeJson(request, 401, errorBody(reason));
      return;
    }
    final String exchangeTicket = tokens.issueBootstrapTicket(
      ttl: const Duration(minutes: 2),
    );
    final String html = await bootstrapPage.render(
      exchangeTicket: exchangeTicket,
    );
    final HttpResponse response = request.response;
    response.statusCode = 200;
    response.headers.contentType = ContentType(
      'text',
      'html',
      charset: 'utf-8',
    );
    response.headers.set('cache-control', 'no-store');
    response.add(utf8.encode(html));
    await response.close();
  }

  /// `POST /api/bootstrap/session`：一次性票据换 10 分钟会话 token。
  Future<void> _handleBootstrapSession(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    Map<String, dynamic> body;
    try {
      body = await readJsonBody(request);
    } on FormatException catch (error) {
      await writeJson(request, 400, errorBody('请求体不是合法 JSON：$error'));
      return;
    }
    final String? reason = tokens.consumeBootstrapTicket(
      (body['ticket'] ?? request.uri.queryParameters['t'])?.toString(),
    );
    if (reason != null) {
      rejectedRequests++;
      await writeJson(request, 401, errorBody(reason));
      return;
    }
    final String sessionToken = tokens.issueBootstrapSession();
    await writeJson(request, 200, <String, dynamic>{
      'token': sessionToken,
      'scope': 'plugin',
      'expires_in': tokens.sessionTtl.inSeconds,
    });
  }

  /// `POST /api/bootstrap/ticket`：主 token 申请一次性票据（loader 用）。
  Future<void> _apiBootstrapTicket(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final String ticket = tokens.issueBootstrapTicket();
    await writeJson(request, 200, <String, dynamic>{
      'ticket': ticket,
      'expires_in': tokens.ticketTtl.inSeconds,
      'url': '/bootstrap?t=$ticket',
    });
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
        hub.unregister(connection.id);
        // 片 B：连接断开 = 该窗口的订阅全部失效；若是这个 UI 插件的最后一条
        // 连接，它自建的广播站也一起注销（站点移除钩子会给其它订阅者补 closed）。
        _stationWsBridge?.onConnectionClosed(connection);
      },
      onError: (Object _) {
        hub.unregister(connection.id);
        _stationWsBridge?.onConnectionClosed(connection);
      },
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

  // ── WebSocket 帧分发（A5 平台面） ──────────────────────────────────────

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
      // ── UI 插件 ⇄ 站点总线（片 B，平台面） ─────────────────────────────
      // ui.hello 是连接身份；其余五条在没有插件系统时也必须给可读拒绝，
      // 不能像未知帧那样静默忽略（否则 UI 只会看到"没反应"）。
      case WsInboundType.uiHello:
      case WsInboundType.stationSubscribe:
      case WsInboundType.stationUnsubscribe:
      case WsInboundType.stationRegister:
      case WsInboundType.stationUnregister:
      case WsInboundType.stationTrigger:
        final StationWsBridge? bridge = _stationWsBridge;
        if (bridge == null) {
          connection.send(<String, dynamic>{
            'type': WsOutboundType.error,
            'data': <String, dynamic>{
              'ok': false,
              'error': '核心未启用插件系统，UI 站点总线不可用',
              'message': '核心未启用插件系统，UI 站点总线不可用',
            },
          });
        } else {
          bridge.handleFrame(connection, frame);
        }
        break;
      // ── A5：领域上行帧已移除 ──────────────────────────────────────────
      // user_message / stop / user_answer / cancel_question 已改委派端点
      // （POST /api/agents/{id}/messages | /cancel，由 tree.agent 承接）；
      // terminal_* 归 local_executor / ssh_executor 插件的执行站。这里**显式**
      // 回一条可读错误，不静默吞掉（否则 UI 只看到"没反应"）。
      case WsInboundType.userMessage:
      case WsInboundType.stop:
      case WsInboundType.userAnswer:
      case WsInboundType.cancelQuestion:
      case WsInboundType.terminalOpen:
      case WsInboundType.terminalInput:
      case WsInboundType.terminalResize:
      case WsInboundType.terminalClose:
        connection.send(<String, dynamic>{
          'type': WsOutboundType.error,
          'data': <String, dynamic>{
            'ok': false,
            'error': '该上行帧已随核心领域面移除（A5）：请改走插件委派端点 / 执行站',
            'message': '该上行帧已随核心领域面移除（A5）：请改走插件委派端点 / 执行站',
          },
        });
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

  // ── 日志与存储 API（片 F，核心永久面） ───────────────────────────────

  /// `GET /api/logs/sources`：枚举 `core` 与 `plugin:<id>` 日志源。
  Future<void> _listLogSources(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final List<Map<String, dynamic>> sources = await logSources.sources();
    await writeJson(request, 200, <String, dynamic>{'sources': sources});
  }

  /// `GET /api/logs/{source}?tail=&since=`：尾部读 NDJSON。
  ///
  /// `since` = 行号（1 起，见 [LogSourceRegistry.readTail]）；`tail` 默认 200、上限 5000。
  Future<void> _readLogSource(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String source = (params['source'] ?? '').trim();
    if (!logSources.isKnownSource(source)) {
      await writeJson(
        request,
        400,
        errorBody('非法日志源：只允许 "core" 或 "plugin:<已配置插件 id>"'),
      );
      return;
    }
    final Map<String, String> query = request.uri.queryParameters;
    int tail = LogSourceRegistry.defaultTailLines;
    final String rawTail = (query['tail'] ?? '').trim();
    if (rawTail.isNotEmpty) {
      final int? parsed = int.tryParse(rawTail);
      if (parsed == null) {
        await writeJson(request, 400, errorBody('tail 必须是整数行数'));
        return;
      }
      tail = parsed;
    }
    int? since;
    final String rawSince = (query['since'] ?? '').trim();
    if (rawSince.isNotEmpty) {
      since = int.tryParse(rawSince);
      if (since == null || since < 1) {
        await writeJson(request, 400, errorBody('since 必须是 >= 1 的行号'));
        return;
      }
    }
    final Map<String, dynamic> page = await logSources.readTail(
      source,
      tail: tail,
      since: since,
    );
    await writeJson(request, 200, page);
  }

  /// `DELETE /api/logs/{source}`：清空当前日志并轮转成 `<name>.1.log`。
  Future<void> _clearLogSource(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String source = (params['source'] ?? '').trim();
    if (!logSources.isKnownSource(source)) {
      await writeJson(
        request,
        400,
        errorBody('非法日志源：只允许 "core" 或 "plugin:<已配置插件 id>"'),
      );
      return;
    }
    await writeJson(request, 200, await logSources.clear(source));
  }

  /// 判定存储 API 的**调用方命名空间**。
  ///
  /// - 无 `X-Tree-Plugin-Id` ⇒ 主 token 视为核心自身，命名空间固定 `core`；
  /// - 有 ⇒ 必须是**已配置**的插件 id（自报 + 白名单校验），否则视为身份无效；
  /// - 引导会话 token 在更外层就被白名单挡掉（403），这里不重复处理。
  String? _callerStoreNamespace(HttpRequest request) {
    final String declared = (request.headers.value(pluginIdHeader) ?? '').trim();
    if (declared.isEmpty) return PluginStore.coreNamespace;
    if (declared == PluginStore.coreNamespace) return null;
    final PluginBus? bus = pluginBus;
    if (bus == null) return null;
    return bus.config(declared) == null ? null : declared;
  }

  /// 校验命名空间：调用方身份有效、`ns` 合法、且 `ns == 调用方命名空间`。
  ///
  /// 跨命名空间**一律 403**，且不检查目标命名空间是否存在（不变量 25）。
  Future<bool> _requireStoreNamespace(
    HttpRequest request,
    String ns,
  ) async {
    final String? caller = _callerStoreNamespace(request);
    if (caller == null) {
      await writeJson(
        request,
        403,
        errorBody('存储 API 的调用方插件身份无效（$pluginIdHeader 必须是已配置插件 id）'),
      );
      return false;
    }
    if (!PluginStore.isValidNamespace(ns)) {
      await writeJson(
        request,
        400,
        errorBody('命名空间非法：只允许 [A-Za-z0-9_.-]，且不能是 . / .. / Windows 保留名'),
      );
      return false;
    }
    if (ns != caller) {
      await writeJson(
        request,
        403,
        errorBody('禁止访问命名空间 "$ns"（调用方命名空间为 "$caller"）'),
      );
      return false;
    }
    return true;
  }

  /// `GET /api/store/{ns}?limit=&cursor=`：列键（按 key 升序分页）。
  Future<void> _listStoreKeys(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String ns = params['ns'] ?? '';
    if (!await _requireStoreNamespace(request, ns)) return;
    final Map<String, String> query = request.uri.queryParameters;
    int limit = PluginStore.defaultPageLimit;
    final String rawLimit = (query['limit'] ?? '').trim();
    if (rawLimit.isNotEmpty) {
      final int? parsed = int.tryParse(rawLimit);
      if (parsed == null || parsed < 1) {
        await writeJson(request, 400, errorBody('limit 必须是正整数'));
        return;
      }
      limit = parsed;
    }
    final StorePage page = await pluginStore.list(
      ns,
      limit: limit,
      cursor: query['cursor'],
    );
    await writeJson(request, 200, page.toJson());
  }

  /// `GET /api/store/{ns}/{key}`：原样字节回包，头带 `etag`。
  Future<void> _getStoreValue(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String ns = params['ns'] ?? '';
    if (!await _requireStoreNamespace(request, ns)) return;
    final String key = params['key'] ?? '';
    if (!pluginStore.isValidKey(key)) {
      await writeJson(request, 400, errorBody('key 非法：禁止路径分隔符 / .. / 盘符 / Windows 保留名'));
      return;
    }
    final StoreValue? value = await pluginStore.read(ns, key);
    if (value == null) {
      await writeJson(request, 404, errorBody('键不存在：$key'));
      return;
    }
    request.response.headers.set('etag', '"${value.etag}"');
    request.response.headers.set('cache-control', 'no-store');
    await writeBytes(
      request,
      200,
      value.bytes,
      contentType: 'application/octet-stream',
    );
  }

  /// `PUT /api/store/{ns}/{key}`：写值（二进制原样，核心不解析）。
  ///
  /// 乐观锁的 etag 可来自 `If-Match`、`X-Tree-Etag`、`?etag=`，或（仅当
  /// `Content-Type: application/json` 时）信封体 `{etag, value}`。`*` = 无条件覆盖。
  Future<void> _putStoreValue(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String ns = params['ns'] ?? '';
    if (!await _requireStoreNamespace(request, ns)) return;
    final String key = params['key'] ?? '';
    if (!pluginStore.isValidKey(key)) {
      await writeJson(request, 400, errorBody('key 非法：禁止路径分隔符 / .. / 盘符 / Windows 保留名'));
      return;
    }
    // 允许 JSON 信封（转义后可能略大于原值），但内存占用仍是硬上限。
    final int bodyCap = pluginStore.maxValueBytes * 2 + 64 * 1024;
    List<int> raw;
    try {
      raw = await readBodyBytes(request, maxBytes: bodyCap);
    } on RequestBodyTooLarge {
      await writeJson(
        request,
        413,
        errorBody('请求体超过上限（单值上限 ${pluginStore.maxValueBytes} 字节）'),
      );
      return;
    }
    List<int> value = raw;
    String? expected =
        request.headers.value('if-match') ??
        request.headers.value('x-tree-etag') ??
        request.uri.queryParameters['etag'];
    final String mime = request.headers.contentType?.mimeType ?? '';
    if (mime == 'application/json' && (expected ?? '').trim().isEmpty) {
      try {
        final Object? decoded = jsonDecode(
          utf8.decode(raw, allowMalformed: true),
        );
        if (decoded is Map<String, dynamic> &&
            decoded.containsKey('etag') &&
            decoded.containsKey('value')) {
          expected = decoded['etag']?.toString();
          value = utf8.encode(jsonEncode(decoded['value']));
        }
      } on FormatException {
        // 不是信封：按原始字节写（二进制主路径）。
      }
    }
    final StorePutResult result = await pluginStore.put(
      ns,
      key,
      value,
      expectedEtag: expected,
    );
    switch (result.status) {
      case StorePutStatus.created:
      case StorePutStatus.updated:
        request.response.headers.set('etag', '"${result.etag}"');
        await writeJson(request, 200, <String, dynamic>{
          'ok': true,
          'key': key,
          'etag': result.etag,
          'size': result.size,
          'created': result.status == StorePutStatus.created,
        });
        break;
      case StorePutStatus.conflict:
        await writeJson(request, 409, errorBody(result.message ?? 'etag 冲突'));
        break;
      case StorePutStatus.tooLarge:
        await writeJson(request, 413, errorBody(result.message ?? '值超过上限'));
        break;
      case StorePutStatus.quotaExceeded:
        await writeJson(request, 413, errorBody(result.message ?? '命名空间配额已满'));
        break;
    }
  }

  /// `DELETE /api/store/{ns}/{key}`：删除；不存在 ⇒ 404 可读。
  Future<void> _deleteStoreValue(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final String ns = params['ns'] ?? '';
    if (!await _requireStoreNamespace(request, ns)) return;
    final String key = params['key'] ?? '';
    if (!pluginStore.isValidKey(key)) {
      await writeJson(request, 400, errorBody('key 非法：禁止路径分隔符 / .. / 盘符 / Windows 保留名'));
      return;
    }
    final StoreDeleteResult result = await pluginStore.delete(ns, key);
    if (result.status == StoreDeleteStatus.notFound) {
      await writeJson(request, 404, errorBody('键不存在：$key'));
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'ok': true,
      'key': key,
      'freed_bytes': result.freedBytes,
    });
  }

  // ── 路由注册（A5：只剩 [ApiPaths.coreOwned] 的 39 条） ────────────────

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
    // 平台控制面（16）：装插件的前提，也是引导页唯一依赖。
    router.add('GET', ApiPaths.pluginSnapshot, _pluginSnapshot);
    router.add('GET', ApiPaths.pluginConfigs, _listPluginConfigs);
    router.add('POST', ApiPaths.pluginConfigs, _createPluginConfig);
    router.add('PATCH', ApiPaths.pluginConfig, _updatePluginConfig);
    router.add('DELETE', ApiPaths.pluginConfig, _deletePluginConfig);
    router.add('POST', ApiPaths.pluginConfigRestart, _restartPluginConfig);
    router.add('GET', ApiPaths.pluginBuiltins, _listBuiltinPlugins);
    router.add('POST', ApiPaths.pluginBuiltinEnable, _enableBuiltinPlugin);
    router.add('POST', ApiPaths.pluginBuiltinDisable, _disableBuiltinPlugin);
    // 发布仓库（阶段 5）：只读发布源（Gitee → GitHub 自动回退）的 Release 资产，
    // 不 clone 源码；四个路由的分工与理由见 ApiPaths.pluginRelease 的注释。
    router.add('GET', ApiPaths.pluginRelease, _pluginReleaseIndex);
    router.add('POST', ApiPaths.pluginReleaseRefresh, _refreshPluginRelease);
    router.add('POST', ApiPaths.pluginReleaseInstall, _installPluginRelease);
    router.add('POST', ApiPaths.pluginReleaseUninstall, _uninstallPluginRelease);
    // 站点详情与配置（面板「站点详情页」）。
    router.add('GET', ApiPaths.pluginStation, _stationDetail);
    router.add('PATCH', ApiPaths.pluginStationConfig, _updateStationConfig);
    router.add('POST', ApiPaths.pluginStationSubscriber, _setStationSubscriber);

    // UI 多窗口（3）：窗口 = 多进程，必须由核心拉起。
    router.add('GET', ApiPaths.pluginWindows, _listUiWindows);
    router.add('POST', ApiPaths.pluginWindows, _createUiWindow);
    router.add('DELETE', ApiPaths.pluginWindowsOfPlugin, _closeUiWindows);
    // 传输 / 判活设置（9）：交给插件会与传输层形成循环依赖。
    router.add('GET', ApiPaths.settingsFrameRate, _getFrameRate);
    router.add('POST', ApiPaths.settingsFrameRate, _setFrameRate);
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
    // 引导壳（3）。
    router.add('GET', ApiPaths.bootstrap, _handleBootstrapPage);
    router.add('POST', ApiPaths.bootstrapSession, _handleBootstrapSession);
    router.add('POST', ApiPaths.bootstrapTicket, _apiBootstrapTicket);
    // 发现面（1）。
    router.add('GET', ApiPaths.meta, _apiMeta);
    // 日志与存储（3 + 4，核心永久面）。`/api/logs/sources` 必须先于
    // `/api/logs/{source}` 注册，否则会被路径参数路由抢走。
    router.add('GET', ApiPaths.logSources, _listLogSources);
    router.add('GET', ApiPaths.logSource, _readLogSource);
    router.add('DELETE', ApiPaths.logSource, _clearLogSource);
    router.add('GET', ApiPaths.storeNamespace, _listStoreKeys);
    router.add('GET', ApiPaths.storeEntry, _getStoreValue);
    router.add('PUT', ApiPaths.storeEntry, _putStoreValue);
    router.add('DELETE', ApiPaths.storeEntry, _deleteStoreValue);
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

// ── 请求体解析（插件端点共用） ───────────────────────────────────────

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

  /// 宽松解析**可选**整数字段：缺字段 / 非法值一律返回 null = **不改该项**。
  ///
  /// 刻意不兜 0：0 会被夹到区间下限，等于"字段写错了却悄悄改了配置"。
  static int? _optionalInt(Map<String, dynamic> body, String key) {
    final Object? raw = body[key];
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  // ── REST 委派（片 C） ───────────────────────────────────────────────

  /// 插件委派临时根：`<数据根>/tmp/api-delegate/`。
  ///
  /// 请求体落盘（`body_path`）与核心分配的结果文件都在这下面；每个请求一个
  /// 子目录，回包结束后整目录递归清理。
  String get _delegateTempRoot => p.join(dataDir, 'tmp', 'api-delegate');

  /// 一次委派的完整处理：组装信封 → `api/delegate` → 校验回包 → 原样写回。
  ///
  /// 错误映射（每条 reason 都可读且具体，**绝不落到 404**）：
  /// 归属插件未安装 / 已停用 / 当前不可用 ⇒ 503；超时 ⇒ 504；回包非法 ⇒ 502。
  Future<void> _handleDelegated(
    HttpRequest request,
    DelegatedRouteMatch match,
  ) async {
    final String pluginId = match.pluginId;
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writeDelegateError(
        request,
        503,
        'service_unavailable',
        pluginId,
        '归属插件 $pluginId 未安装（核心没有启用插件总线）⇒ 无法承接委派请求',
      );
      return;
    }
    // 先把"归属插件是否可用"判掉：插件不在位时不要把大请求体读进内存/落盘。
    try {
      bus.requireApiDelegateHost(pluginId);
    } on PluginDelegateException catch (error) {
      await _writeDelegateError(
        request,
        error.status,
        _delegateErrorCode(error.status),
        pluginId,
        error.reason,
      );
      return;
    }

    final String requestId = CoreIds.next('api');
    final Directory requestDir = Directory(
      p.join(_delegateTempRoot, 'requests', requestId),
    );
    File? resultFile;
    try {
      final _DelegateBody body = await _readDelegateBody(request, requestDir);
      final Map<String, dynamic> query = _delegateQuery(request);
      final Object? rawAgentId =
          match.params['agentId'] ??
          match.params['workspaceId'] ??
          query['agent_id'];
      final String agentId = rawAgentId is String
          ? rawAgentId.trim()
          : '';
      // A5：核心不再持有 agent / team 领域数据，也不解析工作空间根。信封只把
      // 调用方**原样给出**的身份字段透传下去；team / session / mode / workspace
      // 由领域插件自己解析（与不变量 14「核心 scope 不含领域归属」同方向）。
      String passthrough(String key) {
        final Object? raw = query[key];
        return raw is String ? raw.trim() : '';
      }

      final String teamId = passthrough('team_id');
      final String sessionId = passthrough('session_id');
      final String modeKey = passthrough('mode_key');
      final String workspaceDir = passthrough('workspace_dir');
      final Map<String, dynamic> envelope = <String, dynamic>{
        'method': request.method,
        'path': request.uri.path,
        'params': match.params,
        'query': query,
        // 只转发白名单头：token / cookie / host / content-length 一律不出去。
        'headers': _delegateHeaders(request),
        'scope': <String, dynamic>{
          'team_id': teamId,
          'agent_id': agentId,
          'session_id': sessionId,
          'mode_key': modeKey,
        },
        'workspace_dir': workspaceDir,
        'data_dir': dataDir,
        'agent_id': agentId,
        'team_id': teamId,
        'request_id': requestId,
        if (body.inline != null) 'body': body.inline,
        if (body.path != null) 'body_path': body.path,
      };

      final Map<String, dynamic> raw;
      try {
        raw = await bus.requestApiDelegate(pluginId, envelope);
      } on PluginDelegateException catch (error) {
        await _writeDelegateError(
          request,
          error.status,
          _delegateErrorCode(error.status),
          pluginId,
          error.reason,
        );
        return;
      }

      final _DelegateReply reply;
      try {
        reply = await _parseDelegateReply(raw, pluginId);
        resultFile = reply.resultFile;
      } on _InvalidDelegateReply catch (error) {
        await _writeDelegateError(
          request,
          502,
          'bad_gateway',
          pluginId,
          '归属插件 $pluginId 的回包非法：${error.reason}',
        );
        return;
      }
      await _writeDelegateReply(request, reply);
    } finally {
      // 请求体临时目录先清；结果文件在写完后单独清（可能不在请求目录下）。
      try {
        if (await requestDir.exists()) {
          await requestDir.delete(recursive: true);
        }
      } catch (error) {
        errorLog?.call('委派临时目录清理失败：${requestDir.path} → $error');
      }
      if (resultFile != null) {
        try {
          if (await resultFile.exists()) await resultFile.delete();
        } catch (error) {
          errorLog?.call('委派结果临时文件清理失败：${resultFile.path} → $error');
        }
      }
    }
  }

  /// 组装发给插件的请求体。
  ///
  /// 超过 [delegateInlineBodyLimit]（1 MiB）或非文本内容 ⇒ 流式落盘到
  /// `<requestDir>/body.bin`，信封只带 `body_path`；文本且不超过阈值才走 `body`。
  /// 这样核心内存占用与请求体大小无关（100MB 上传也不会整块驻留）。
  Future<_DelegateBody> _readDelegateBody(
    HttpRequest request,
    Directory requestDir,
  ) async {
    final int length = request.contentLength;
    // 无 body 的方法（GET/HEAD/DELETE）在 length 未知时直接当空。
    if (length == 0 ||
        (length < 0 &&
            request.method != 'POST' &&
            request.method != 'PUT' &&
            request.method != 'PATCH')) {
      return const _DelegateBody(inline: '');
    }
    final String mime = (request.headers.contentType?.mimeType ?? '').trim();
    final bool textual =
        mime.isEmpty ||
        mime == 'application/json' ||
        mime == 'application/x-www-form-urlencoded' ||
        mime.startsWith('text/') ||
        mime.endsWith('+json');
    if (textual && length >= 0 && length <= delegateInlineBodyLimit) {
      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in request) {
        builder.add(chunk);
      }
      return _DelegateBody(
        inline: utf8.decode(builder.takeBytes(), allowMalformed: true),
      );
    }
    // 大体积 / 二进制 / 长度未知：边收边写，内存不随 body 增长。
    await requestDir.create(recursive: true);
    final File file = File(p.join(requestDir.path, 'body.bin'));
    final IOSink sink = file.openWrite();
    try {
      await for (final List<int> chunk in request) {
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    return _DelegateBody(path: file.path);
  }

  /// 查询串 → 信封 `query`（重复键给数组；`token` 不转发，避免把本地凭证带给插件）。
  Map<String, dynamic> _delegateQuery(HttpRequest request) {
    final Map<String, dynamic> query = <String, dynamic>{};
    for (final MapEntry<String, List<String>> entry
        in request.uri.queryParametersAll.entries) {
      if (entry.key == 'token') continue;
      query[entry.key] = entry.value.length == 1
          ? entry.value.single
          : entry.value;
    }
    return query;
  }

  /// 请求头白名单：只转发语义头，鉴权 / 连接 / 体积头一律不出核心。
  static const Set<String> _delegateRequestHeaders = <String>{
    'accept',
    'accept-language',
    'cache-control',
    'content-type',
    'if-match',
    'if-modified-since',
    'if-none-match',
    'if-unmodified-since',
    'pragma',
    'range',
    'x-requested-with',
  };

  Map<String, String> _delegateHeaders(HttpRequest request) {
    final Map<String, String> headers = <String, String>{};
    for (final String name in _delegateRequestHeaders) {
      final String? value = request.headers.value(name);
      if (value != null) headers[name] = value;
    }
    return headers;
  }

  /// 校验并解析插件回包；所有"形状不对"都抛 [_InvalidDelegateReply]。
  Future<_DelegateReply> _parseDelegateReply(
    Map<String, dynamic> raw,
    String pluginId,
  ) async {
    final Object? rawStatus = raw['status'];
    if (rawStatus is! int || rawStatus < 100 || rawStatus > 599) {
      throw const _InvalidDelegateReply('status 必须是 100..599 的整数');
    }
    final int status = rawStatus;
    final Object? rawBody = raw['body'];
    final Object? rawResultPath = raw['result_path'];
    if (rawBody != null && rawResultPath != null) {
      throw const _InvalidDelegateReply('body 与 result_path 只能给一个');
    }
    if (rawBody != null && rawBody is! String) {
      throw const _InvalidDelegateReply('body 必须是字符串');
    }
    if (rawResultPath != null && rawResultPath is! String) {
      throw const _InvalidDelegateReply('result_path 必须是字符串');
    }
    final Map<String, String> headers = <String, String>{};
    final Object? rawHeaders = raw['headers'];
    if (rawHeaders != null) {
      if (rawHeaders is! Map) {
        throw const _InvalidDelegateReply('headers 必须是对象');
      }
      for (final MapEntry<dynamic, dynamic> entry in rawHeaders.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw const _InvalidDelegateReply('headers 的键和值都必须是字符串');
        }
        headers[entry.key as String] = entry.value as String;
      }
    }
    String? body = rawBody as String?;
    File? resultFile;
    if (rawResultPath != null) {
      resultFile = await _validateDelegateResultPath(
        rawResultPath as String,
        pluginId,
      );
    } else if (body != null &&
        utf8.encode(body).length > delegateInlineBodyLimit) {
      // 超阈值还在走内联 body ⇒ 核心必须整块驻留，违反传输约定。
      throw const _InvalidDelegateReply(
        '内联 body 超过 1 MiB 阈值（必须改用 result_path）',
      );
    }
    if (body != null && body.isEmpty) body = '';
    return _DelegateReply(
      status: status,
      headers: headers,
      body: body,
      resultFile: resultFile,
    );
  }

  /// `result_path` 路径越界校验（§6）：只允许核心分配目录或归属插件自有命名空间。
  ///
  /// 同时要求文件真实存在；比较的是 `resolveSymbolicLinks` 之后的真实路径，
  /// Windows 下再做大小写归一，防止符号链接 / 大小写绕过。
  Future<File> _validateDelegateResultPath(
    String rawPath,
    String pluginId,
  ) async {
    if (rawPath.trim().isEmpty) {
      throw const _InvalidDelegateReply('result_path 为空');
    }
    final String absolute = p.normalize(p.absolute(rawPath.trim()));
    final File file = File(absolute);
    if (!await file.exists()) {
      throw const _InvalidDelegateReply('result_path 指向的文件不存在');
    }
    if (await FileSystemEntity.isDirectory(absolute)) {
      throw const _InvalidDelegateReply('result_path 指向的是目录，不是文件');
    }
    final String realFile = _lower(await file.resolveSymbolicLinks());
    final List<String> roots = <String>[
      p.join(_delegateTempRoot),
      p.join(dataDir, 'plugin-data', pluginId),
    ];
    for (final String root in roots) {
      final String realRoot = await _realRoot(root);
      if (_withinRoot(realRoot, realFile)) return file;
    }
    throw const _InvalidDelegateReply(
      'result_path 越界（只允许核心委派临时目录或该插件的数据命名空间）',
    );
  }

  Future<String> _realRoot(String root) async {
    final Directory directory = Directory(root);
    if (await directory.exists()) {
      try {
        return _lower(await directory.resolveSymbolicLinks());
      } catch (_) {
        // 解不出真实路径时退回规范化绝对路径，下面的前缀校验仍然生效。
      }
    }
    return _lower(p.normalize(p.absolute(root)));
  }

  String _lower(String path) => path.toLowerCase();

  bool _withinRoot(String root, String target) {
    final String normalizedRoot = root.endsWith(p.separator)
        ? root
        : '$root${p.separator}';
    return target == root || target.startsWith(normalizedRoot);
  }

  /// 把插件回包原样写回 HTTP（状态码 / 安全头 / 大体积流式）。
  Future<void> _writeDelegateReply(
    HttpRequest request,
    _DelegateReply reply,
  ) async {
    final HttpResponse response = request.response;
    response.statusCode = reply.status;
    // 只回写一组安全响应头；content-type 走白名单，content-length 由核心按实际
    // 字节数设置（插件给的不采信）。
    for (final MapEntry<String, String> entry
        in _delegateResponseHeaders(reply.headers).entries) {
      response.headers.set(entry.key, entry.value);
    }
    final ContentType contentType = _safeDelegateContentType(
      reply.headers['content-type'],
    );
    final bool bodyAllowed = reply.status != 204 && reply.status != 304;
    if (reply.resultFile != null) {
      final File file = reply.resultFile!;
      if (!bodyAllowed) {
        await response.close();
        return;
      }
      response.headers.contentType = contentType;
      response.headers.contentLength = await file.length();
      await response.addStream(file.openRead());
      await response.close();
      return;
    }
    final List<int> bytes = utf8.encode(reply.body ?? '');
    if (!bodyAllowed) {
      await response.close();
      return;
    }
    response.headers.contentType = contentType;
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  /// 插件可回写的响应头白名单（连接 / 长度 / cookie 等一律不采信）。
  static const Set<String> _delegateResponseHeaderAllow = <String>{
    'cache-control',
    'content-disposition',
    'content-range',
    'etag',
    'last-modified',
    'accept-ranges',
  };

  Map<String, String> _delegateResponseHeaders(Map<String, String> headers) {
    final Map<String, String> safe = <String, String>{};
    for (final MapEntry<String, String> entry in headers.entries) {
      final String name = entry.key.toLowerCase();
      if (_delegateResponseHeaderAllow.contains(name)) safe[name] = entry.value;
    }
    return safe;
  }

  /// Content-Type 白名单：不认识的类型一律降级为 `application/octet-stream`。
  static const Set<String> _delegateMimeTypes = <String>{
    'application/json',
    'application/octet-stream',
    'application/pdf',
    'application/zip',
    'application/x-ndjson',
    'text/plain',
    'text/csv',
    'text/markdown',
    'text/event-stream',
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'audio/mpeg',
    'audio/ogg',
    'audio/wav',
    'video/mp4',
    'video/webm',
  };

  ContentType _safeDelegateContentType(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return ContentType.parse('application/octet-stream');
    }
    try {
      final ContentType parsed = ContentType.parse(raw.trim());
      if (!_delegateMimeTypes.contains(parsed.mimeType)) {
        return ContentType.parse('application/octet-stream');
      }
      return parsed;
    } catch (_) {
      return ContentType.parse('application/octet-stream');
    }
  }

  Future<void> _writeDelegateError(
    HttpRequest request,
    int status,
    String error,
    String pluginId,
    String reason,
  ) async {
    await writeJson(request, status, <String, dynamic>{
      'ok': false,
      'error': error,
      'plugin_id': pluginId,
      'reason': reason,
    });
  }

  String _delegateErrorCode(int status) => switch (status) {
    503 => 'service_unavailable',
    504 => 'gateway_timeout',
    _ => 'bad_gateway',
  };

  Future<void> _apiMeta(HttpRequest request, Map<String, String> _) async {
    final StationWsBridge? bridge = _stationWsBridge;
    final ApiMeta meta =
        bridge?.buildMeta(coreVersion: version, apiVersion: apiVersion) ??
        ApiMeta(
          coreVersion: version,
          apiVersion: apiVersion,
          routes: delegatedRouter.metaRoutes(),
        );
    await writeJson(request, 200, meta.toJson());
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
    // team_id 参数按"团队"解释。A5 起核心不再持有 agent / team 领域数据，无法把
    // 成员 id 反查成团队 id：按原值透传（插件面板自己知道当前 team_id）。
    // **站点段不受此过滤**：站点全局唯一，过滤恒真；team 视角由每条订阅者的
    // scope 与 subscribers_by_team 承担（见 StationHub.snapshot）。
    final String teamId =
        request.uri.queryParameters['team_id']?.trim() ?? '';
    await writeJson(request, 200, bus.snapshot(teamId: teamId));
  }

  // ── UI 多窗口（3 条：列出 / 新建 / 全关） ──────────────────────────
  //
  // 多窗口 = 多进程：UI 自己做不了"再起一个自己"（会与单实例口径打架，也拿不到
  // 启动参数），所以进程由核心拉。窗口身份（`w1`/`w2`）由核心分配并经
  // `TREE_UI_WINDOW_ID` 注入；UI 在 `ui.hello` 里带回，`/api/meta.ui[].connections`
  // 就是窗口数。

  Future<void> _listUiWindows(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    await writeJson(request, 200, <String, dynamic>{
      'windows': bus.uiWindows(),
    });
  }

  Future<void> _createUiWindow(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final Map<String, dynamic> body = await readJsonBody(request);
    final String pluginId = (body['plugin_id'] ?? '').toString().trim();
    if (pluginId.isEmpty) {
      await writeJson(request, 400, errorBody('缺少 plugin_id'));
      return;
    }
    // 核心启动后手工加进 plugins.yaml 的条目：先对账再判断存在性。
    if (bus.config(pluginId) == null) await bus.applyConfigs();
    if (bus.config(pluginId) == null) {
      await writeJson(request, 404, errorBody('插件不存在：$pluginId'));
      return;
    }
    try {
      await writeJson(request, 200, await bus.startUiWindow(pluginId));
    } on PluginException catch (error) {
      // 不是 UI / 未启用 / 依赖或 API 版本不满足 / 超过窗口上限：都是可读的 409。
      await writeJson(request, 409, errorBody('$error'));
    } catch (error) {
      await writeJson(request, 500, errorBody('开窗口失败：$error'));
    }
  }

  Future<void> _closeUiWindows(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String pluginId = (params['pluginId'] ?? '').trim();
    if (bus.config(pluginId) == null) await bus.applyConfigs();
    if (bus.config(pluginId) == null) {
      await writeJson(request, 404, errorBody('插件不存在：$pluginId'));
      return;
    }
    try {
      await writeJson(request, 200, await bus.closeAllUiWindows(pluginId));
    } on PluginException catch (error) {
      await writeJson(request, 409, errorBody('$error'));
    } catch (error) {
      await writeJson(request, 500, errorBody('关窗口失败：$error'));
    }
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

  /// 依赖闸门的统一回包（409）。
  ///
  /// 形状即 `spec.md` ADDED「插件依赖」：`{ok:false, error, reasons,
  /// missing_dependencies:[{id, required, installed, actual, by, optional, reason}]}`。
  Future<void> _writeDependencyConflict(
    HttpRequest request,
    Map<String, dynamic> block, {
    String pluginId = '',
  }) async {
    await writeJson(request, 409, <String, dynamic>{
      ...block,
      if (pluginId.isNotEmpty) 'plugin_id': pluginId,
    });
  }

  /// 用“即将写盘的条目”跑一次依赖闸门（refresh = 先读最新 plugins.yaml）。
  Map<String, dynamic>? _dependencyBlockForEntry(
    PluginBus bus,
    Map<String, dynamic> entry,
  ) {
    final PluginConfig candidate = PluginConfig.fromJson(entry);
    // `requires.api` 先于插件依赖：协议形状不满足时，装依赖也救不回来。
    final Map<String, dynamic>? api = bus.apiBlock(candidate);
    if (api != null) return api;
    final PluginDependencyReport report = bus.checkDependencies(
      candidate,
      refresh: true,
    );
    return report.ok ? null : report.toJson();
  }

  /// `with_dependencies` 的自动补齐：**只装缺失项，不升级既有插件**。
  ///
  /// 返回 null = 依赖已齐（目标插件可以继续安装）；否则返回依赖闸门形状的 409 回包。
  /// 规则：
  /// - 已安装且版本满足 ⇒ 跳过（绝不因为索引里有新版就顺手升级）；
  /// - 已安装但版本不满足 ⇒ 直接拒绝（升级是用户动作，不是安装副作用）；
  /// - 同一 id 被多方要求 ⇒ 取区间交集，无交集 / 成环 ⇒ 可读失败、逐条列出；
  /// - 只补齐依赖自身，不碰目标插件（调用方随后走正常 install）。
  Future<Map<String, dynamic>?> _installMissingDependencies(
    PluginBus bus,
    PluginDownloader downloader,
    PluginConfigStore store,
    String targetId,
  ) async {
    PluginReleaseListing listing = downloader.cachedListing();
    if (!listing.ok || listing.entries.isEmpty) {
      listing = await downloader.refresh();
    }
    final Map<String, PluginRepoEntry> repo = <String, PluginRepoEntry>{
      for (final PluginRepoEntry entry in listing.entries) entry.id: entry,
    };
    final PluginRepoEntry? targetEntry = repo[targetId];
    if (targetEntry == null) {
      // 目标条目不在索引里：让正常 install 去给它的错误（这里不抢话）。
      return null;
    }
    final Map<String, Map<String, dynamic>> installed =
        <String, Map<String, dynamic>>{
          for (final Map<String, dynamic> entry in store.readEntries())
            if ((entry['id'] ?? '').toString().isNotEmpty)
              entry['id'].toString(): entry,
        };
    final List<PluginDependencyIssue> issues = <PluginDependencyIssue>[];
    final List<String> reasons = <String>[];
    final List<String> stack = <String>[targetId];

    String versionOf(Map<String, dynamic>? entry) {
      if (entry == null) return '';
      final Object? version = entry['version'];
      if (version is String && version.trim().isNotEmpty) return version.trim();
      final Object? repoVersion = entry['repo_version'];
      return repoVersion is String ? repoVersion.trim() : '';
    }

    /// 收集所有“已启用且要求 depId”的插件，加上当前这一条要求。
    List<({String by, PluginDependency dependency})> requirementsFor(
      String depId,
      String currentBy,
      PluginDependency current,
    ) {
      final List<({String by, PluginDependency dependency})> out =
          <({String by, PluginDependency dependency})>[
            (by: currentBy, dependency: current),
          ];
      for (final MapEntry<String, Map<String, dynamic>> item
          in installed.entries) {
        if (item.value['enabled'] == false) continue;
        final PluginConfig config = PluginConfig.fromJson(item.value);
        for (final PluginDependency dependency in config.requires) {
          if (dependency.id != depId || dependency.optional) continue;
          if (dependency.version == current.version &&
              item.key == currentBy) {
            continue;
          }
          out.add((by: item.key, dependency: dependency));
        }
      }
      return out;
    }

    ({String text, PluginVersionConstraint? intersection, String? error})
    intersectRequirements(
      String depId,
      List<({String by, PluginDependency dependency})> requirements,
    ) {
      final String text = requirements
          .map(
            (({String by, PluginDependency dependency}) item) =>
                '${item.by}：'
                '${item.dependency.version.isEmpty ? '任意版本' : item.dependency.version}',
          )
          .join('；');
      PluginVersionConstraint? intersection;
      for (final ({String by, PluginDependency dependency}) item
          in requirements) {
        final PluginVersionConstraint? one =
            PluginVersionConstraint.tryParse(item.dependency.version);
        if (one == null) {
          return (
            text: text,
            intersection: null,
            error: '依赖 $depId 的版本区间不可解析：${item.dependency.version}',
          );
        }
        intersection = intersection == null ? one : intersection.intersect(one);
        if (intersection.range.isEmpty) {
          return (
            text: text,
            intersection: intersection,
            error: '依赖 $depId 的版本区间无交集：$text',
          );
        }
      }
      return (text: text, intersection: intersection, error: null);
    }

    Future<bool> walk(PluginRepoEntry entry) async {
      for (final PluginDependency dependency in entry.requires) {
        if (dependency.optional) continue;
        final List<({String by, PluginDependency dependency})> requirements =
            requirementsFor(dependency.id, entry.id, dependency);
        final PluginVersionConstraint? parsed =
            PluginVersionConstraint.tryParse(dependency.version);
        final ({String text, PluginVersionConstraint? intersection, String? error})
        merged = intersectRequirements(dependency.id, requirements);
        final String requiredText = merged.text;
        final List<String> by = <String>[
          for (final ({String by, PluginDependency dependency}) item
              in requirements)
            item.by,
        ];
        if (merged.error != null) {
          reasons.add(merged.error!);
          issues.add(
            PluginDependencyIssue(
              id: dependency.id,
              required: requiredText,
              installed: installed.containsKey(dependency.id),
              actual: versionOf(installed[dependency.id]),
              by: by,
              reason: merged.error!,
            ),
          );
          return false;
        }
        final Map<String, dynamic>? live = installed[dependency.id];
        if (live != null) {
          final String actual = versionOf(live);
          if (merged.intersection != null &&
              !merged.intersection!.isAny &&
              (actual.isEmpty ||
                  !merged.intersection!.satisfies(actual))) {
            final String reason =
                '依赖 ${dependency.id} 已安装版本「${actual.isEmpty ? '未知' : actual}」'
                '不满足 $requiredText；自动安装只补齐缺失项，**不升级**既有插件';
            reasons.add(reason);
            issues.add(
              PluginDependencyIssue(
                id: dependency.id,
                required: requiredText,
                installed: true,
                actual: actual,
                by: by,
                reason: reason,
              ),
            );
            return false;
          }
          continue;
        }
        final PluginRepoEntry? candidate = repo[dependency.id];
        if (candidate == null) {
          final String reason =
              '缺少依赖 ${dependency.id}（发布索引里也没有这条）';
          reasons.add(reason);
          issues.add(
            PluginDependencyIssue(
              id: dependency.id,
              required: requiredText,
              installed: false,
              actual: '',
              by: by,
              reason: reason,
            ),
          );
          return false;
        }
        if (stack.contains(dependency.id)) {
          final int index = stack.indexOf(dependency.id);
          final String path = <String>[
            ...stack.sublist(index),
            dependency.id,
          ].join(' → ');
          final String reason = '依赖成环：$path';
          reasons.add(reason);
          issues.add(
            PluginDependencyIssue(
              id: dependency.id,
              required: requiredText,
              installed: false,
              actual: '',
              by: by,
              reason: reason,
            ),
          );
          return false;
        }
        final String candidateVersion = candidate.version.trim();
        if (parsed != null &&
            !parsed.isAny &&
            (candidateVersion.isEmpty || !parsed.satisfies(candidateVersion)) ||
            (merged.intersection != null &&
                !merged.intersection!.isAny &&
                (candidateVersion.isEmpty ||
                    !merged.intersection!.satisfies(candidateVersion)))) {
          final String reason =
              '发布索引里的 ${dependency.id} 版本'
              '「${candidateVersion.isEmpty ? '未知' : candidateVersion}」'
              '不满足 $requiredText';
          reasons.add(reason);
          issues.add(
            PluginDependencyIssue(
              id: dependency.id,
              required: requiredText,
              installed: false,
              actual: candidateVersion,
              by: by,
              reason: reason,
            ),
          );
          return false;
        }
        stack.add(dependency.id);
        final bool nested = await walk(candidate);
        stack.removeLast();
        if (!nested) return false;
        final PluginInstallResult install = await downloader.install(
          dependency.id,
          swapGate: bus.quiesceForSwap,
        );
        final Map<String, dynamic>? installedEntry = install.entry;
        if (!install.ok || installedEntry == null) {
          final String reason =
              '自动安装依赖 ${dependency.id} 失败：${install.error}';
          reasons.add(reason);
          issues.add(
            PluginDependencyIssue(
              id: dependency.id,
              required: requiredText,
              installed: false,
              actual: '',
              by: by,
              reason: reason,
            ),
          );
          return false;
        }
        final PluginStoreResult stored = store.upsert(installedEntry);
        final Map<String, dynamic>? row = stored.entry;
        if (!stored.ok || row == null) {
          final String reason =
              '依赖 ${dependency.id} 的文件已放置，但写入 plugins.yaml 失败：'
              '${stored.error}';
          reasons.add(reason);
          issues.add(
            PluginDependencyIssue(
              id: dependency.id,
              required: requiredText,
              installed: false,
              actual: '',
              by: by,
              reason: reason,
            ),
          );
          return false;
        }
        installed[dependency.id] = row;
        await _applyPluginChange(bus, row, enable: true);
      }
      return true;
    }

    if (await walk(targetEntry)) return null;
    return PluginDependencyReport(
      error: '插件 $targetId 的依赖无法自动补齐：${reasons.join('；')}',
      reasons: reasons,
      issues: issues,
    ).toJson();
  }

  /// 卸载“被依赖插件”的确认位（body 或 query 皆可，便于 CLI/面板两种调用）。
  bool _uninstallConfirmed(
    Map<String, dynamic> body,
    HttpRequest request,
  ) {
    final Object? value =
        body['confirm_dependents'] ??
        body['confirmDependents'] ??
        request.uri.queryParameters['confirm_dependents'];
    return value == true || value?.toString().toLowerCase() == 'true';
  }

  /// 某插件当前的运行态（给面板显示"在跑 / 已停用 / 心跳降级 / 启动失败原因"）。
  ///
  /// 数据源是插件总线的公开探针（healthOf / errorOf），不是自己另立台账。
  ///
  /// **只增键**（阶段 2 / D11）：`lifecycle` 与 `generation` 是新增的可选读数（面板
  /// 据此显示「重启中 / 已挂起」），`running` / `health` / `reason` / `error` / `known`
  /// 的产出值与口径一字未改——**活性看 health、启停看 status、阶段看 lifecycle**。
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
        'lifecycle': bus.lifecycleOf(id).wire,
        'generation': bus.generationOf(id),
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
    // 片 D：新增条目默认启用 ⇒ 启用前先过依赖闸门；拦下就回滚这条条目，
    // 保证磁盘上不会留下一条“开关开着但永远起不来”的配置。
    if (entry['enabled'] != false) {
      final Map<String, dynamic>? blocked = _dependencyBlockForEntry(bus, entry);
      if (blocked != null) {
        store.remove(newId);
        await _writeDependencyConflict(request, blocked, pluginId: newId);
        return;
      }
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
    final Map<String, dynamic>? before = store.readEntry(id);
    if (before == null) {
      await writeJson(request, 404, errorBody('插件不存在：$id'));
      return;
    }
    final PluginStoreResult result = store.update(id, body);
    final Map<String, dynamic>? entry = result.entry;
    if (!result.ok || entry == null) {
      await writeJson(request, 400, errorBody(result.error));
      return;
    }
    // 片 D：只有**从停用切到启用**（或显式 enabled:true）才过闸门；只是改名字 /
    // 改介绍不该被旧依赖问题连带拒绝。拦下时把开关回滚到改动前，条目其余字段保留。
    final bool enabling =
        entry['enabled'] != false &&
        (before['enabled'] != true || body['enabled'] == true);
    if (enabling) {
      final Map<String, dynamic>? blocked = _dependencyBlockForEntry(bus, entry);
      if (blocked != null) {
        store.update(id, <String, dynamic>{'enabled': before['enabled'] ?? false});
        await _writeDependencyConflict(request, blocked, pluginId: id);
        return;
      }
    }
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      entry,
      enable: entry['enabled'] != false,
    );
    await writeJson(request, 200, _pluginWriteBody(store, result, outcome));
  }

  /// DELETE /api/plugin/configs/{pluginId}：
  /// 删一条插件条目；**内置 id 也不例外**（2026-10-18 用户定稿：内置项就是
  /// plugins/ 目录下的那四个，走普通安装流程 ⇒ 装上之后与自定义条目同一条命：
  /// 删除 = 整条摘掉 + 断开实例）。
  ///
  /// 内置 id 的保护只剩**新增那一侧**（POST：不许自定义条目冒名内置 id，见
  /// [_createPluginConfig]）——那边拦的是"手改出一个假的内置项"，与删除无关。
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

  /// POST /api/plugin/configs/{pluginId}/restart：显式处置一个插件实例。
  ///
  /// 用途一：心跳 degraded 之后由用户手动恢复；用途二：改完配置想立刻按新参数拉起
  /// （日常开关走 PATCH，已经会自动对账，不必手动点这里）。
  ///
  /// **同一个路径三种做法**（body 的 `mode`，缺省 = 无 body = 旧行为逐字不变）：
  /// - 缺省 / `cold`：冷重启（断开再拉起，不做转储）——响应形状与升级前一致；
  /// - `hot`：热重启（先请插件转储、新一世取回续跑），回包带 `resumed`/`generation`；
  ///   目标没声明 `suspension: keep` 时 `resumed=false` 且 **不算失败**（那是冷启动，不是错误）；
  /// - `force_stop`：**用户显式强制停止**，全框架唯一能因为界面按钮而 `kill()` 的入口（D8）。
  ///
  /// 未知 mode 一律拒并给可读原因：把拼错的 `mode: 'hotr'` 静默当成冷重启，
  /// 用户看到的就是“我点了热重启但状态没续上”，而它会回一句成功。
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
    final Map<String, dynamic> body = await readJsonBody(request);
    final String mode = (body['mode'] ?? '').toString().trim();
    if (mode == 'force_stop') {
      // 用户显式强制停止永远放行：这是给“已经卡死、依赖怎么都不齐”留的出口。
      await writeJson(request, 200, await bus.forceStop(id));
      return;
    }
    // 片 D：重启前复核依赖（含热重启）。依赖缺失时重拉只会得到同样失败，
    // 这里直接 409 并给可读清单，避免“看起来重启了，实际没起来”。
    final PluginConfig restartConfig = bus.config(id)!;
    if (restartConfig.enabled) {
      final Map<String, dynamic>? blocked = bus.dependencyBlock(id);
      if (blocked != null) {
        await _writeDependencyConflict(request, blocked, pluginId: id);
        return;
      }
    }
    if (mode == 'hot') {
      final PluginHotRestartResult hot = await bus.hotRestart(
        id,
        keepState: body['keep_state'] != false,
      );
      if (!hot.ok) {
        await writeJson(
          request,
          400,
          errorBody(
            hot.reason.isEmpty
                ? '插件 $id 热重启后未就绪'
                : '插件 $id 热重启失败：${hot.reason}',
          ),
        );
        return;
      }
      await writeJson(request, 200, hot.toJson());
      return;
    }
    if (mode.isNotEmpty && mode != 'cold') {
      await writeJson(
        request,
        400,
        errorBody(
          '未知的 mode「$mode」：这一条只有 cold（冷重启，缺省）/ hot（热重启续跑）/ '
          'force_stop（用户显式强制停止）三种做法；不把拼错的值静默当成缺省，'
          '因为你看到的就是“点了热重启但状态没续上”',
        ),
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
  /// 内置项**永远在响应里**（未启用也可见）；config 为落盘的那一条（从未启用过 =
  /// null），resolution 是核心此刻解析出来的运行时与脚本路径（含可读错误，前端直接
  /// 显示）。
  ///
  /// 界面口径（2026-10-18 用户定稿）：内置项就是 plugins/ 目录下的那四个、成品从
  /// 发布仓库装 ⇒ 面板**不再单列「内置插件」组**，改走普通安装流程。这份清单仍然
  /// 有用：面板据 id 判断某条已安装条目是不是内置项（决定详情页要不要给「发布仓库」
  /// 区块与成品解析结果），核心也据它播种默认启用项。
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
    final Map<String, dynamic> candidateEntry = BuiltinPluginCatalog.entryFor(
      spec,
      resolution,
    );
    // 片 D：内置项打开也要过依赖闸门（候选条目先判，拦下就不写盘）。
    final Map<String, dynamic>? blocked = _dependencyBlockForEntry(
      bus,
      candidateEntry,
    );
    if (blocked != null) {
      await _writeDependencyConflict(request, blocked, pluginId: id);
      return;
    }
    final PluginStoreResult result = store.upsert(candidateEntry);
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

  // ── 发布仓库（阶段 5：插件管理只拉发布源的 Release 资产）─────────────────
  //
  // 三个处理器只做「调 [PluginDownloader] 的同一份实现 + 把条目落盘」：索引校验、
  // 字节数核对、换文件闸门、原子改名全在下载器里——路由层不复制规则，复制一次就
  // 会两头漂。落盘与热应用沿用**既有那一条路**（`_pluginStore` + `_applyPluginChange`），
  // 与内置开关/自定义新增同一个语义。

  /// 未接入发布仓库下载器时的统一回复（形状与 [_writePluginNotWired] 一致）。
  ///
  /// 为什么不是 501：前端对 501 有专门文案「功能开发中」，而这里是“做了，但这个
  /// 实例不知道数据根”（只有测试 / 最小骨架会这样，CLI 恒接线）。
  Future<void> _writePluginRepoNotWired(HttpRequest request) async {
    await writeJson(
      request,
      503,
      errorBody(
        '这台核心没接发布仓库下载器（没给它数据根的 plugins_release 缓存目录）：'
        '发布仓库面板会显示这条原因，不会默默空转',
      ),
    );
  }

  /// GET /api/plugin/release：读**本地缓存**的发布清单（不联网）。
  ///
  /// 为什么“没缓存”也回 200 + `ok:false`：面板要能把“为什么这个列表是空的” 显示
  /// 出来（并递上 `index_path` 让人去查），而 4xx 会把它压成一条 Exception；
  /// 与只读快照接口同样用 200 回空集的形状一致。
  Future<void> _pluginReleaseIndex(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginDownloader? downloader = pluginDownloader;
    if (downloader == null) {
      await _writePluginRepoNotWired(request);
      return;
    }
    await writeJson(request, 200, downloader.cachedListing().toJson());
  }

  /// POST /api/plugin/release/refresh：联网拉最新 release 的索引并缓存。
  ///
  /// 失败同样回 **200 + `ok:false` + 可读原因**（而不是 4xx）：刷新失败后还要把
  /// “上次那份”一并递出去（`cached`），否则前端只能剩一条错误而列表整个空掉——
  /// 那会把“GitHub 今晚限流”显示成“这个仓库没有插件”。
  Future<void> _refreshPluginRelease(
    HttpRequest request,
    Map<String, String> _,
  ) async {
    final PluginDownloader? downloader = pluginDownloader;
    if (downloader == null) {
      await _writePluginRepoNotWired(request);
      return;
    }
    final PluginReleaseListing listing = await downloader.refresh();
    errorLog?.call(
      '[core:plugin-release] 刷新发布索引：${listing.ok ? '成功（${listing.entries.length} 条，'
                'release ${listing.tag}）' : '失败：${listing.error}'}',
    );
    await writeJson(request, 200, <String, dynamic>{
      ...listing.toJson(),
      if (!listing.ok) 'cached': downloader.cachedListing().toJson(),
    });
  }

  /// POST /api/plugin/release/{pluginId}/install：从发布仓库装一条插件。
  ///
  /// 三段顺序不能反：
  /// 1. **先过索引的归属防线**（在任何磁盘动作之前）：`files[].target` 撞上本机已有的
  ///    内置成品、又不是这个 id 自己那件 ⇒ 整条进 skipped，install 拿不到它
  ///    （“不许盖别人的成品”，在 `_readEntry` 里拦）。反向的“自己的条目自己可更新”
  ///    由同一处的归属例外放行 —— 2026-10-18 A+ 删掉了这里按 `shipsOwnArtifact`
  ///    对内置 id 一律 400 的拦截：它把“从仓库更新自己”一起挡死，而那是缺成品的
  ///    内置项唯一的启用路径；
  /// 2. 装（资产进缓存 → 闸门 → 原子改名）：失败回 **400 + 可读原因**，旧文件一个
  ///    都没动（面板把这句话直接给用户看）；
  /// 3. 成功才写 plugins.yaml 并热应用（启用 = 拉起新版）。
  ///
  /// “文件已就位但条目写不进去”要**如实分开**说（不把 400 写成“已装好”）：那意味着
  /// 新文件在盘上而旧条目仍指旧路，需用户看 plugins.yaml。
  Future<void> _installPluginRelease(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final PluginDownloader? downloader = pluginDownloader;
    if (downloader == null) {
      await _writePluginRepoNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final PluginConfigStore store = _pluginStore(bus);
    final Map<String, dynamic>? existing = store.readEntry(id);
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final bool withDependencies =
        body['with_dependencies'] == true || body['withDependencies'] == true;
    // 片 D：`with_dependencies` 只**补齐缺失**的依赖（不升级已装版本）。
    // 冲突 / 成环 / 缺索引条目都在这一步回可读 409，且不会继续装目标插件。
    if (withDependencies) {
      final Map<String, dynamic>? dependencyBlock =
          await _installMissingDependencies(bus, downloader, store, id);
      if (dependencyBlock != null) {
        await _writeDependencyConflict(request, dependencyBlock, pluginId: id);
        return;
      }
    }
    final PluginInstallResult install = await downloader.install(
      id,
      swapGate: bus.quiesceForSwap,
    );
    final Map<String, dynamic>? entry = install.entry;
    if (!install.ok || entry == null) {
      final String reason = install.error.isEmpty
          ? '插件 $id 安装失败（下载器没给出原因）'
          : install.error;
      errorLog?.call('[core:plugin-release] 安装 $id 失败：$reason');
      await writeJson(request, 400, errorBody(reason));
      return;
    }
    // 内置身份跟着**条目**走，不跟着文件走：这条本来就是清单里的内置项，从 release
    // 装了成品之后它仍是同一个内置开关在服务，只是 command 指到了装进来的那一份。
    // 丢掉 `builtin: true` 会让面板把它当自定义条目，而 [migrateBuiltinEntries] 从此
    // 不再管它 —— 下一次内置换代就没人替这位用户改命令了（“配置看上去正常但起不来”
    // 那一类最难查的坑）。
    final Map<String, dynamic> toWrite = <String, dynamic>{
      ...entry,
      if (existing?['builtin'] == true) 'builtin': true,
    };
    // 片 D：依赖闸门在写盘之前。文件已经落到 plugins/，但**条目与进程都不动**：
    // 回包会如实带上 install 段，用户补齐依赖后再点一次即可。
    final Map<String, dynamic>? blocked = _dependencyBlockForEntry(bus, toWrite);
    if (blocked != null) {
      await _writeDependencyConflict(request, <String, dynamic>{
        ...blocked,
        'install': install.toJson(),
      }, pluginId: id);
      return;
    }
    final PluginStoreResult result = store.upsert(toWrite);
    final Map<String, dynamic>? stored = result.entry;
    if (!result.ok || stored == null) {
      final String reason =
          '插件文件已放置到 ${install.files.join(' / ')}，但写入 plugins.yaml 失败：'
          '${result.error}（旧条目未改动，新文件暂时不会被拉起）';
      errorLog?.call('[core:plugin-release] $reason');
      await writeJson(request, 400, errorBody(reason));
      return;
    }
    final PluginHotApplyOutcome outcome = await _applyPluginChange(
      bus,
      stored,
      enable: true,
    );
    errorLog?.call(
      '[core:plugin-release] 已安装 $id（${install.version}，'
      '${install.files.length} 个文件，热应用 ${outcome.applied ? '成功' : '失败：${outcome.detail}'}）',
    );
    await writeJson(request, 200, <String, dynamic>{
      ..._pluginWriteBody(store, result, outcome),
      'install': install.toJson(),
    });
  }

  /// POST /api/plugin/release/{pluginId}/uninstall：卸载一条插件（**不强杀**）。
  ///
  /// 四段顺序（2026-10-18 定稿，见 ApiPaths.pluginReleaseUninstall）：
  /// **停用 → 等退出确认 → 删 `plugins/` 里的文件 → 落盘条目**。前两段由
  /// [PluginBus.quiesceForSwap] 一次做完：它回可读拒绝时直接 400，文件与条目
  /// **一个都没动**（与 install 同一条纪律）。
  ///
  /// 内置项的分岔只在最后一步：删文件但**条目保留并置 `enabled: false`**——回到
  /// “待从仓库装”那一格（缺成品、开关还在），不从面板消失；自定义 / 从仓库装的
  /// 条目整条删掉。条目不存在但成品在盘上（从未启用过的内置成品）也算卸载：
  /// 只删文件，无条目可写。
  ///
  /// 到落盘那一步时文件可能已经半删（Windows 上被别的进程锁着），所以
  /// **无论删成功几个都照常落盘条目**——“文件删了但条目还开着”才是最坏状态；
  /// 删除失败逐个列在 `uninstall.failed` 里如实回报。
  Future<void> _uninstallPluginRelease(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final PluginDownloader? downloader = pluginDownloader;
    if (downloader == null) {
      await _writePluginRepoNotWired(request);
      return;
    }
    final String id = (params['pluginId'] ?? '').trim();
    final PluginConfigStore store = _pluginStore(bus);
    final Map<String, dynamic>? before = store.readEntry(id);
    final Map<String, dynamic> body = await _jsonBody(request) ?? <String, dynamic>{};
    // 片 D：卸载被依赖的插件要先确认——确认后**停用依赖方**（不是卸载它们）。
    // 未确认时回 409 + 依赖方清单，目标与依赖方都保持原样（文件也不动）。
    final List<PluginConfig> dependents = bus.dependentsOf(id);
    if (dependents.isNotEmpty && !_uninstallConfirmed(body, request)) {
      await _writeDependencyConflict(request, <String, dynamic>{
        'ok': false,
        'error': '插件 $id 正被 ${dependents.length} 个已启用插件依赖；'
            '确认卸载将同时**停用**这些依赖方（不会卸载它们）',
        'dependents': <Map<String, dynamic>>[
          for (final PluginConfig config in dependents)
            <String, dynamic>{
              'id': config.id,
              'name': config.name,
              'optional': false,
            },
        ],
        'missing_dependencies': <Map<String, dynamic>>[
          for (final PluginConfig config in dependents)
            <String, dynamic>{
              'id': id,
              'required': config.requires
                  .where(
                    (PluginDependency dependency) =>
                        dependency.id == id && !dependency.optional,
                  )
                  .map(
                    (PluginDependency dependency) => dependency.version.isEmpty
                        ? '任意版本'
                        : dependency.version,
                  )
                  .join(' / '),
              'installed': true,
              'actual': '',
              'by': <String>[config.id],
              'optional': false,
              'reason': '卸载后依赖将缺失，依赖方会被停用',
            },
        ],
      }, pluginId: id);
      return;
    }
    final List<String> targets = downloader.uninstallTargets(
      id,
      before,
      extraDirs: builtinPlugins.scriptRoots(),
    );
    // 没条目也没文件 = 没东西可卸（404）；只有其一（老条目 / 裸成品）都继续。
    if (before == null && targets.isEmpty) {
      await writeJson(request, 404, errorBody('插件不存在：$id'));
      return;
    }
    // 闸门：停用 + 等退出确认（[quiesceForSwap] 绝不 kill）。等不到 ⇒ 400 +
    // 可读原因，此刻文件与条目都还没被碰。
    final String blocked = await bus.quiesceForSwap(id);
    if (blocked.isNotEmpty) {
      await writeJson(request, 400, errorBody(blocked));
      return;
    }
    final ({List<String> deleted, Map<String, String> failed}) removed =
        downloader.removeUninstallTargets(targets);

    final PluginStoreResult result;
    final PluginHotApplyOutcome outcome;
    final bool builtinKept;
    if (before == null) {
      // 裸成品（从来没有条目）：文件删完就没别的要写，也不需要热应用。
      builtinKept = false;
      result = PluginStoreResult.success(null, store.readEntries());
      outcome = const PluginHotApplyOutcome.applied('没有条目可写（只删了成品文件）');
    } else {
      // 判内置看**清单 + 条目标记**两路：老条目可能没带 `builtin: true`，
      // 而清单里的 id 换代自哪一边都不该被整条删掉（删了就回不到内置开关那一格）。
      final bool builtin =
          before['builtin'] == true ||
          BuiltinPluginCatalog.specOf(id) != null;
      builtinKept = builtin;
      final PluginStoreResult written = builtin
          ? store.setEnabled(id, false)
          : store.remove(id);
      final Map<String, dynamic>? stored = written.entry;
      if (!written.ok) {
        // 文件已经删了、条目却写不动：如实分开说（与 install 的对偶情形同纪律），
        // 不把半删状态包装成成功。
        final String reason =
            '插件成品文件已删除（${removed.deleted.join(' / ')}），但写入 '
            'plugins.yaml 失败：${written.error}'
            '（文件已不在盘上，条目仍是旧的，请手工核对 ${store.path}）';
        errorLog?.call('[core:plugin-release] 卸载 $id 失败：$reason');
        await writeJson(request, 400, errorBody(reason));
        return;
      }
      result = written;
      outcome = await _applyPluginChange(
        bus,
        stored ?? before, // 整条删掉时用被删的那条去断开（与 _deletePluginConfig 同）
        enable: false,
      );
    }

    // 片 D：已确认的依赖方**停用**（条目保留，不删文件）；停用失败如实列出。
    final List<String> dependentsDisabled = <String>[];
    final Map<String, String> dependentsFailed = <String, String>{};
    for (final PluginConfig config in dependents) {
      final PluginStoreResult disabled = store.setEnabled(config.id, false);
      final Map<String, dynamic>? row = disabled.entry;
      if (!disabled.ok || row == null) {
        dependentsFailed[config.id] = disabled.error;
        continue;
      }
      dependentsDisabled.add(config.id);
      await _applyPluginChange(bus, row, enable: false);
    }

    final String fileNotice = removed.failed.isEmpty
        ? ''
        : '以下文件这次没删掉（可能被别的进程占用）：'
              '${removed.failed.keys.join(' / ')}——其余已删除，条目已按卸载落盘；'
              '等占用它的进程退出后可再删一次';
    errorLog?.call(
      '[core:plugin-release] 已卸载 $id'
      '${builtinKept ? '（内置项：条目保留并停用，回到“待从仓库装”）' : '（条目已删除）'}'
      '：删除 ${removed.deleted.length} 个文件'
      '${removed.failed.isEmpty ? '' : '，失败 ${removed.failed.length} 个'}',
    );
    await writeJson(request, 200, <String, dynamic>{
      ..._pluginWriteBody(store, result, outcome),
      'uninstall': <String, dynamic>{
        'plugin_id': id,
        'builtin_kept': builtinKept,
        'deleted': removed.deleted,
        'failed': removed.failed,
        'notice': fileNotice,
        'dependents_disabled': dependentsDisabled,
        'dependents_failed': dependentsFailed,
      },
    });
  }

  /// 默认接线：造一个发布仓库下载器（为什么可以回 null 见 [pluginDownloader]）。
  ///
  /// 四个注入都指向**既有事实源**，这里不再造一份判定：
  /// - `installedEntryOf`：plugins.yaml 里那条的 `repo_version`（判断“有没有更新”）；
  /// - `runtimeResolver`：内置插件目录的 Python 探测（与内置项同一口径，避免两套
  ///   “装了没”的结论互相矛盾）；
  /// - 换文件闸门由路由层现给（[PluginBus.quiesceForSwap]）：只有总线知道进程在不在；
  /// - `sources`：**有序多源**（默认 Gitee → GitHub，见 [defaultPluginReleaseSources]）；
  ///   token 从 `GITEE_TOKEN` / `GITHUB_TOKEN` 读，源顺序可用 `TREE_PLUGIN_RELEASE_ORDER`
  ///   覆盖（公开仓库不登录也能读，token 只在被限流/401 时才用得上）。
  static PluginDownloader? _releaseDownloaderFor({
    required String? cacheDir,
    required PluginBus? bus,
    required BuiltinPluginCatalog catalog,
  }) {
    final String dir = (cacheDir ?? '').trim();
    if (dir.isEmpty || bus == null) return null;
    final PluginConfigStore store = PluginConfigStore(bus.configFile);
    return PluginDownloader(
      cacheDir: dir,
      installDir: defaultPluginInstallDir(),
      sources: defaultPluginReleaseSources(
        giteeToken: (Platform.environment['GITEE_TOKEN'] ?? '').trim(),
        githubToken: (Platform.environment['GITHUB_TOKEN'] ?? '').trim(),
        order: parsePluginReleaseSourceOrder(
          Platform.environment['TREE_PLUGIN_RELEASE_ORDER'] ?? '',
        ),
      ),
      runtimeResolver: catalog.detectRuntime,
      installedEntryOf: store.readEntry,
    );
  }

  // ── 站点详情与配置（面板「站点详情页」的唯一写入口）──────────────────────
  //
  // 三个处理器都只做「取一条 + 调 [StationHub] 的同一份实现」：能改什么（内置只
  // 能改订阅上限）、禁用不等于退订这些判定全部在 StationHub 里，路由层不复制规则
  // ——复制一次就会两头漂。

  /// 站点详情里读不到的统一回包：404 + 可读原因（不给空对象让前端渲染空白详情页）。
  Future<void> _writeStationMissing(HttpRequest request, String stationId) {
    return writeJson(
      request,
      404,
      errorBody(
        '站点不存在：$stationId（内置站点 id 形如 station.…，'
        '插件自建站形如 plugin.<插件 id>.<kind>.<name>）',
      ),
    );
  }

  /// `GET /api/plugin/stations/{stationId}`：站点详情。
  ///
  /// 形状 = `StationInstance.describe()`（与 `GET /api/plugin/snapshot` 的 `stations` 段
  /// 各项**完全一致**）：介绍 / 可订阅上限 / 共享声明 / 自定义配置 / 订阅者（含禁用态）。
  Future<void> _stationDetail(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String stationId = (params['stationId'] ?? '').trim();
    final Map<String, dynamic>? detail = bus.stations
        .station(stationId)
        ?.describe();
    if (detail == null) {
      await _writeStationMissing(request, stationId);
      return;
    }
    await writeJson(request, 200, detail);
  }

  /// `PATCH /api/plugin/stations/{stationId}/config`：**局部**改站点配置。
  ///
  /// 只发要改的键。成功回**改后的完整详情**（前端直接拿它刷新页面，不再发第二次 GET）；
  /// 内置站改介绍/配置、值类型不对 ⇒ 400 + 指路原因（不静默忽略多余的键）。
  Future<void> _updateStationConfig(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String stationId = (params['stationId'] ?? '').trim();
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    if (bus.stations.station(stationId) == null) {
      await _writeStationMissing(request, stationId);
      return;
    }
    if (body.isEmpty) {
      await writeJson(request, 400, errorBody('PATCH 至少要给一个要改的键'));
      return;
    }
    final String? error = bus.stations.updateConfig(stationId, body);
    if (error != null) {
      await writeJson(request, 400, errorBody(error));
      return;
    }
    await writeJson(request, 200, bus.stations.station(stationId)!.describe());
  }

  /// `POST /api/plugin/stations/{stationId}/subscribers/{subscriberKey}`：
  /// 禁用 / 启用一个订阅者（body `{disabled: bool}`）。
  ///
  /// **禁用不是退订**：订阅关系与回包通道都留着，只让触发时不投递，并且每条触发
  /// 都在返回里显式回报跳过（计数 `skipped_disabled` + `skipped` 原因）——面板上
  /// 关掉一个订阅者必须是可诊断的，不能变成“插件那边莫名其妙收不到”。
  /// 键位里的 `|` 由客户端 `Uri.encodeComponent`，路由层拿到的已解码。
  Future<void> _setStationSubscriber(
    HttpRequest request,
    Map<String, String> params,
  ) async {
    final PluginBus? bus = pluginBus;
    if (bus == null) {
      await _writePluginNotWired(request);
      return;
    }
    final String stationId = (params['stationId'] ?? '').trim();
    final String subscriberKey = (params['subscriberKey'] ?? '').trim();
    final Map<String, dynamic>? body = await _jsonBody(request);
    if (body == null) return;
    final Object? raw = body['disabled'];
    if (raw is! bool) {
      await writeJson(
        request,
        400,
        errorBody('disabled 必须是布尔值（true = 禁用该订阅者，false = 恢复投递）'),
      );
      return;
    }
    if (subscriberKey.isEmpty) {
      await writeJson(
        request,
        400,
        errorBody(
          '缺少 subscriberKey（形如 plugin_id|scope，取自站点详情的 subscriptions[].subscriber）',
        ),
      );
      return;
    }
    final String? error = bus.stations.setSubscriberDisabled(
      stationId,
      subscriberKey,
      raw,
    );
    if (error != null) {
      // 站点不存在 / 订阅者不存在都是“找不到的东西”，同一个 404（原因里已说清是哪一个）。
      await writeJson(request, 404, errorBody(error));
      return;
    }
    await writeJson(request, 200, bus.stations.station(stationId)!.describe());
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

/// 委派请求体：内联字符串或落盘的 `body_path`（二选一）。
class _DelegateBody {
  const _DelegateBody({this.inline, this.path});

  final String? inline;
  final String? path;
}

/// 插件经 `api/delegate` 返回、且已通过 schema / 路径归属校验的回包。
class _DelegateReply {
  const _DelegateReply({
    required this.status,
    required this.headers,
    required this.body,
    required this.resultFile,
  });

  final int status;
  final Map<String, String> headers;
  final String? body;
  final File? resultFile;
}

/// 回包形状非法（映射 502）。[reason] 会拼进响应体，必须可读。
class _InvalidDelegateReply implements Exception {
  const _InvalidDelegateReply(this.reason);

  final String reason;
}

/// 便捷入口：启动核心并返回握手（CLI 用）。
Future<CoreServer> startCoreServer({int port = 0}) =>
    CoreServer.start(port: port);
