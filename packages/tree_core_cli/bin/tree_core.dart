import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 核心进程入口（`dart compile exe` → `tree_core.exe`）。
///
/// **stdout 是进程间协议**：第一行是单行 JSON 的 [CoreHandshake]（父进程据此
/// 配置 HTTP/WS 基址与本地 token）。因此本进程的一切人类可读日志一律走
/// **stderr**，绝不污染 stdout。
///
/// 退出约定（按可靠性排序）：
/// 1. 父进程向 stdin 写一行 `shutdown`（最可靠，Windows 亦可用）；
/// 2. Ctrl+C / 平台支持的终止信号；
/// 3. 父进程 `kill()` 兜底（核心进程只做原子写，容忍硬杀）。
///
/// **stdin EOF 不是退出信号**——它只表示控制通道关闭（无 stdin 的启动方式下
/// 立即 EOF），据此退出会让核心刚启动就消失。
/// 命令行参数：
///   `--port <n>`           监听端口（0 = 内核分配，默认）
///   `--chunk-delay-ms <n>` 流式片段间隔毫秒（默认 40，0 = 不限速）
///   `--data-dir <path>`   数据根目录（默认：平台规范位置，见 TreePaths）
///   --print-paths         打印解析出的数据根目录后退出
///   --no-heartbeat         关闭保活心跳下发
///   --verbose              打开请求级日志
///   -v, --version          打印版本
///   -h, --help             打印用法
Future<void> main(List<String> args) async {
  if (args.contains('-v') || args.contains('--version')) {
    stdout.writeln(TreeCore.version);
    return;
  }
  if (args.contains('-h') || args.contains('--help')) {
    stderr.writeln(_usage);
    return;
  }
  final TreePaths paths = TreePaths.resolve(
    override: _stringArg(args, '--data-dir'),
  );
  if (args.contains('--print-paths')) {
    stdout.writeln(paths.root);
    return;
  }
  final int port = _intArg(args, '--port') ?? 0;
  final int chunkDelayMs = _intArg(args, '--chunk-delay-ms') ?? 40;
  final bool enableHeartbeat = !args.contains('--no-heartbeat');
  final bool verbose = args.contains('--verbose');

  // 日志出口（核心唯一的一处）：**同时**写 stderr（保持原样）与
  // `<数据根>/logs/core.log`（8 MiB × 5 份轮转）。放在这里是为了让后面**所有**
  // 日志（含启动计时）都走同一个出口——发布版没有调试器，落盘是唯一的取证手段。
  // 构造零副作用（懒打开），所以 --print-paths / -h / -v 那些早退分支不受影响。
  final CoreLogSink coreLog = CoreLogSink(paths);

  // 启动分段计时：把「核心启动慢」变成可归因的数字（日志的 [core:boot] 行）。
  final Stopwatch boot = Stopwatch()..start();
  void bootLog(String phase) =>
      coreLog.write('[core:boot] $phase：累计 ${boot.elapsedMilliseconds}ms');

  // 落盘装配：存储（agents/sessions/messages）与设置/模型池。核心进程的所有
  // 状态都在 ~/.tree 下的纯文本文件里，用户可直接查看与手改。
  final void Function(String message) logStore = coreLog.forPrefix('core:store');
  final FileTreeStore fileStore = FileTreeStore(paths, log: logStore);
  // 临时员工（subagent）的**会话级名册**：记录只落
  // `data/<agentId>/<sessionId>/subagents.json`（随会话删除一起消失），不进 agents/。
  final void Function(String message) logSubagent = coreLog.forPrefix(
    'core:subagent',
  );
  final SubagentRegistry subagents = SubagentRegistry(
    persistence: fileStore,
    log: logSubagent,
  );
  // 工具层 / 文件服务 / 会话服务统一用这一层：`store.agent(sub_…)` 要能查到临时员工
  // （工作空间、SSH、系统提示词、结果门控这些既有路径因此一处都不用改）。
  final SubagentStore store = SubagentStore(
    inner: fileStore,
    registry: subagents,
  );
  final CoreSettings settings = CoreSettings();
  FileSettingsSink(paths, log: logStore).load(settings);

  // 回复引擎：真实 LLM（OpenAI 兼容端点）。模型池来自 ~/.tree/config/models，
  // 因此"换模型/改密钥"只需改配置文件，不必改代码。
  // 工具执行器：工作空间目录取 agent 配置里的 workspace_dir，未配置则落到
  // <数据根>/workspaces/<agent_id>（首次使用时自动创建）。
  final FileTodoStore todos = FileTodoStore(paths);

  // Spec 体系：内置模板内嵌在核心包里，**播种到每个工作空间的 .self/spec/**；
  // 自定义 Spec 同样落在那里——规范属于工作空间/团队，各存一份、互不影响。
  // 内置副本是**核心管理的快照**：核心升级后 seedInto 会先备份旧副本（`.bak.<n>`）再刷新，
  // 所以升级能到达已有工作空间；要按工作空间定制请用 `spec create`（内置 id 本就不可 update）。
  final SpecService specs = SpecService(
    store: store,
    log: coreLog.forPrefix('core:spec'),
  );

  // MCP 服务（M6a）：配置在 <数据根>/config/mcp.yaml；启动时尝试连接一次，
  // 失败只在日志里说明（坏插件不该拦住核心启动）。
  // 心跳判活参数（M9 1.1）从设置取：MCP 的 ping 节拍与"连续几拍算死"因此可调。
  // 生效时机 = **下次核心启动**：McpService / McpClient 的这两个字段是 final，
  // 构造后不再变（设置在运行期改了也不会改到这里，界面上写的是"下次启动生效"）。
  final McpService mcp = McpService(
    configFile: paths.mcpConfigFile,
    heartbeatInterval: settings.heartbeatInterval,
    missedHeartbeatLimit: settings.missedHeartbeatLimit,
    log: coreLog.forPrefix('core:mcp'),
  );
  // 首次连接**不在这里做**：MCP 的初始连接没有超时参数（见 McpClient 的类文档），
  // 排在握手之前时，一家半死的 MCP 服务就能把核心启动拖到 25s 握手超时。改为握手
  // 之后并行预热，见 _warmUpPeripheralsAfterHandshake。
  bootLog('存储 / 设置 / MCP 装配完成');

  // 提问回路与插件总线都要"工具层先建、核心后建 WS 广播"，因此统一用一个可后置
  // 绑定的广播槽（核心起监听后立即接上 `hub.broadcast`）。
  void Function(Map<String, dynamic> frame)? hubSink;

  // 插件总线（M6b）：配置在 <数据根>/config/plugins.yaml；启动时拉起全部启用插件
  // 并开始心跳巡检。坏插件只标记为不可用，不拦住核心启动。
  // 心跳判活参数（M9 1.1）同样来自设置：PluginBus 把它转给插件宿主（stdio 通道
  // 的 LivenessTracker）与站点看门狗。生效时机 = **下次核心启动**（PluginBus /
  // PluginHost 的字段是 final；插件重连只是复用同一份参数）。
  final PluginBus plugins = PluginBus(
    configFile: paths.pluginsConfigFile,
    coreVersion: TreeCore.version,
    heartbeatInterval: settings.heartbeatInterval,
    missThreshold: settings.missedHeartbeatLimit,
    // plugin_status / plugin_event 广播到前端（起监听后 hubSink 会被接上）
    broadcast: (Map<String, dynamic> frame) => hubSink?.call(frame),
    log: coreLog.forPrefix('core:plugin'),
  );
  // 同上：插件启动是**逐家串行**且每家 20s 超时（PluginBus.connectTimeout），
  // 排在握手之前 = 坏插件直接把启动拖到超时。改为握手之后并行预热。
  bootLog('插件总线装配完成（预热推迟到握手之后）');

  // 提问回路：工具层先建好、核心后建 WS 广播，因此广播目标用一个可后置绑定的
  // 槽（core 起监听后立即接上 `hub.broadcast`）。
  final FileQuestionStore questionStore = FileQuestionStore(paths);
  final QuestionBroker questions = QuestionBroker(
    questions: questionStore,
    transcript: store,
    broadcast: (Map<String, dynamic> frame) => hubSink?.call(frame),
    log: coreLog.forPrefix('core:ask'),
  );
  // 团队服务：成员就是 agent（`agents/<id>.yaml`）。working 状态同样后置绑定到
  // 会话服务的在途任务表，避免"服务先于核心构造"的顺序环。
  bool Function(String agentId)? workingSink;
  final TeamService teams = TeamService(
    store: store,
    settings: settings,
    // 成员的工作目录是"团队 TOP 那份的镜像"（见 syncWorkspaceMirrors）：
    // 建成员时要能算出 TOP 未配置目录时的默认目录。
    defaultWorkspaceDir: paths.defaultWorkspaceDir,
    isWorking: (String agentId) => workingSink?.call(agentId) ?? false,
    log: coreLog.forPrefix('core:team'),
  );
  // 团队关系自愈：用户直接删 agent 会在下级 yaml 里留下悬空的
  // `parent_agent_id`/`team_id`（实测后果：那些成员广播够不着、级联停止/删除失效，
  // 却仍会被寻址、还能干活）。启动时修一次，改动前先备份成 `.bak.<n>`；幂等，
  // 明细见 team_repair.dart 的三条规则。
  await repairTeamLinks(
    store,
    backup: (CoreAgent agent) => backupAgentFile(paths, agent.id),
    log: coreLog.forPrefix('core:team'),
  );
  // 消息派发：投递实现要等核心起监听后才有（ConversationService 由核心创建），
  // 因此同样用可后置绑定的槽。
  TeamDelivery? deliverSink;
  // 活动日志要走 agent 自己的工作空间 IO（本地与 SSH 同一口径）——但工具层在后文才建，
  // 因此同样用可后置绑定的槽（与 deliverSink 同一范式）。
  Future<WorkspaceIO?> Function(String agentId)? ioSink;
  final TeamMessageDispatcher messages = TeamMessageDispatcher(
    store: store,
    teams: teams,
    deliver:
        ({
          required String agentId,
          required String sessionId,
          required String content,
          String senderId = '',
          String senderName = '',
        }) {
          final TeamDelivery? sink = deliverSink;
          if (sink == null) return Future<void>.value();
          return sink(
            agentId: agentId,
            sessionId: sessionId,
            content: content,
            senderId: senderId,
            senderName: senderName,
          );
        },
    // 这里给出的是**本机目录**（`workspaceDirOf` 的语义就是"本机绝对路径"）：
    // - **文件投递**已不再依赖它——投递按 `ioFor` 解析两侧端点，SSH 两端也能投（见
    //   `TeamMessageDispatcher._copyFiles` 与 team/README 不变量 15），本机目录只在
    //   "两侧都是本机"时走 `File.copy` 那条快路；
    // - **活动日志**同样优先走工作空间 IO；本机目录只是无 IO 时的兜底。
    // ⇒ SSH agent 在这里返回空串不会让投递/日志失效，只是别拿它当"本机路径"用。
    workspaceDirOf: (String agentId) {
      final CoreAgent? agent = store.agent(agentId);
      if (agent == null) return paths.defaultWorkspaceDir(agentId);
      // 成员跟随团队 TOP 的 SSH（见 teamSshConfigFor）：远端工作空间不在本机 ⇒ 本地
      // 活动日志与文件投递都不适用（与"leader 自己是 SSH agent"同一口径）。
      if (teamSshConfigFor(agent, store.agent) != null) return '';
      // 成员跟随团队 TOP 的工作目录（见 TeamWorkspace，2026-10-02 定夺）；TOP 口径不变。
      final TeamWorkspace shared = teamWorkspaceFor(agent, store.agent);
      return shared.configuredDir.isNotEmpty
          ? shared.configuredDir
          : paths.defaultWorkspaceDir(shared.owner.id);
    },
    ioFor: (String agentId) async {
      final Future<WorkspaceIO?> Function(String agentId)? sink = ioSink;
      if (sink == null) return null;
      return sink(agentId);
    },
    log: coreLog.forPrefix('core:msg'),
  );
  // 一次性迁移：私有状态从 `.self/` 搬到 `.tree/<agent_id>/.self/`（按 agent 分栏）。
  // 只搬**团队 TOP** 的：成员与 leader 共享工作目录，旧 `.self` 不可能属于成员
  // （成员以前有自己的目录，那份留在原地不动）。幂等，失败只记日志。
  for (final CoreAgent agent in store.agents()) {
    if (teams.teamIdOf(agent.id) != agent.id) continue;
    final String own = agent.workspaceDir.trim();
    migrateLegacySelfDir(
      workspaceDir: own.isNotEmpty ? own : paths.defaultWorkspaceDir(agent.id),
      agentId: agent.id,
      log: coreLog.forPrefix('core:migrate'),
    );
  }

  // 工作目录镜像（2026-10-03 用户断言）：把团队共享目录写进成员自己的配置。
  // 顺序**必须在自愈之后**：自愈可能把成员升为独立 TOP，而升级正是要保住这份目录。
  final WorkspaceMirrorReport mirrors = await syncWorkspaceMirrors(
    store,
    defaultDirFor: paths.defaultWorkspaceDir,
    backup: (CoreAgent agent) => backupAgentFile(paths, agent.id),
    log: coreLog.forPrefix('core:team'),
  );
  if (!mirrors.isEmpty) {
    bootLog('工作目录镜像完成：${mirrors.changedCount} 个成员');
  }
  bootLog('团队关系自愈与旧 .self 迁移完成');

  // 临时员工服务：校验 / 名册（复用或新建）/ 阻塞或后台运行。
  // 真正的"跑一轮独立生成"在会话服务里，三个依赖都**后置绑定**（与 ioSink 同一范式）。
  final SubagentService subagentService = SubagentService(
    store: store,
    registry: subagents,
    settings: settings,
    log: coreLog.forPrefix('core:subagent'),
  );
  final WorkspaceToolRunner tools = WorkspaceToolRunner(
    todoStore: todos,
    askQuestion: questions.ask,
    teamService: teams,
    messageDispatcher: messages,
    specService: specs,
    subagentService: subagentService,
    mcpService: mcp,
    pluginBus: plugins,
    // **远端后台任务的落盘台账**（`<数据根>/hooks`）：核心/应用重启后据此接续
    // （见启动末尾的 `restorePending`），完成提示投递回原会话。
    hookLedger: HookLedger(
      paths.hooksDir,
      log: coreLog.forPrefix('core:tool'),
    ),
    // 成员跟随团队 TOP 的 SSH：自己没有 ssh 配置时用 TOP 那份（同一台远端主机、同一个根）。
    resolveSshConfig: (String agentId) {
      final CoreAgent? agent = store.agent(agentId);
      // 未知的 `sub_*`（名册未装载 / 已被清理）**不猜**：返回 null 让上层显式失败，
      // 绝不让它落到 `workspaces/<id>` 那个并不存在的工作空间上。
      if (agent == null) return null;
      return teamSshConfigFor(agent, store.agent);
    },
    // SSH 后端（dartssh2 + SFTP/exec）：每个 agent 一条连接，按需建立并缓存；
    // 远端根目录取 ssh.root（空 = 远端登录用户的 HOME）。
    sshIoFactory: (SshConfig config) async {
      // 心跳判活参数（M9 1.1）在**每次建连时**从设置现读：SSH 的 SshLiveness 归
      // 这条连接所有，所以设置一改，下一条（重）建的连接就用新值——不必重启核心。
      final DartSshTransport transport = await DartSshTransport.connect(
        host: config.host,
        port: config.port,
        username: config.username,
        password: config.password,
        keyPath: config.resolvedKeyPath(),
        keyPassphrase: config.keyPassphrase,
        heartbeatInterval: settings.heartbeatInterval,
        maxMissedHeartbeats: settings.missedHeartbeatLimit,
        // 远端命令默认套一层**登录外壳**（`bash -lc`）：exec 通道是非登录 shell，
        // 不套就看不到用户 ssh 进来时有的工具（nvcc / conda 那类 profile PATH）。
        // agent yaml 里 `ssh.login_shell` 可换模板或写空串关掉。
        loginShell: config.loginShell,
        log: coreLog.forPrefix('core:tool'),
      );
      final String root = await resolveRemoteRoot(transport, config.root);
      coreLog.write('[core:tool] SSH 已连接 ${config.redacted()} root=$root');
      return SshWorkspaceIO(root, transport);
    },
    resolveWorkspaceDir: (String agentId) {
      final CoreAgent? agent = store.agent(agentId);
      // 未知的 `sub_*` 不落到默认目录（那会凭空造一个空工作空间）：返回空串，
      // 让 `_ioFor` 记日志并显式失败（可读错误，不静默）。
      if (agent == null) {
        return agentId.startsWith(SubagentLimits.idPrefix)
            ? ''
            : paths.defaultWorkspaceDir(agentId);
      }
      // 工具根：成员与团队 TOP **共享同一个工作目录**（见 TeamWorkspace）；
      // 临时员工沿 `parent_agent_id` 找到会话主人，因此与发起者**同一份根**。
      final TeamWorkspace shared = teamWorkspaceFor(agent, store.agent);
      return shared.configuredDir.isNotEmpty
          ? shared.configuredDir
          : paths.defaultWorkspaceDir(shared.owner.id);
    },
    log: coreLog.forPrefix('core:tool'),
  );

  // 活动日志的工作空间 IO 后置绑定：从这里起，**SSH 模式下的 agent**（含跟随 leader
  // SSH 的成员）也会把 `[start(成员)]/…` 写进它自己远端工作空间的 .self/activity.log。
  ioSink = tools.ioFor;

  // 临时员工的两个后置依赖：
  // - 工作空间探测（说清缺什么、去哪配）：探**会话主人**的工作空间，子 agent 与它同一份；
  // - 后台完成注入：走**既有**的 `tools.onHookFinished → conversation.wake` 那条路
  //   （不新开第二条唤醒通道），并带上 subagent 标记供前端分组。
  subagentService.probeWorkspace = (String agentId) async {
    final WorkspaceIO? io = await tools.ioFor(agentId);
    if (io == null) {
      return '工作空间不可用：$agentId 的工作目录解析失败，或它的 SSH 配置不完整/'
          '尚未接入（详见核心日志 [core:tool]）。请到该 agent 的设置页检查'
          '工作目录，或到「设置 → SSH」补全 ssh 段。';
    }
    return null;
  };
  subagentService.onFinished =
      (String ownerAgentId, String sessionId, String notice, SubagentTag tag) {
        tools.onHookFinished?.call(
          ownerAgentId,
          sessionId,
          notice,
          subagent: tag,
        );
      };

  // 系统提示词（Q6）：落在**每个工作空间**的 .self/system_prompt.md（团队分隔）。
  // 首次用到某工作空间时播种默认内容，之后只读用户版本；运行期每轮按 agent 缓存
  // 快照，改文件保存即下一轮生效。右侧活动栏的「重置」按钮走同一条读写路径。
  final SystemPromptStore systemPrompts = SystemPromptStore(
    ioFor: tools.ioFor,
    log: coreLog.forPrefix('core:prompt'),
  );
  systemPromptFileProvider = (CoreAgent agent) =>
      systemPrompts.snapshot(agent.id);

  // 工作空间文件服务（M7d/M7g）：文件面板 / 查看器 / Git 面板的数据源。
  // 前端仍只经 REST 读写，路径安全边界都在 FileService 里；配了 ssh 的 agent
  // 走同一份 SshWorkspaceIO（与工具层共用连接，避免文件面板再连一条）。
  final FileService files = FileService(
    store: store,
    defaultWorkspaceDir: paths.defaultWorkspaceDir,
    remoteFilesFor: (String agentId) async {
      // SshWorkspaceIO 同时实现了 WorkspaceIO 与 WorkspaceFiles，这里只做窄化。
      // 用 Object? 接收是为了让 `is` 提升干净：WorkspaceIO 与 WorkspaceFiles 是
      // 并列接口，直接在三元里提升会得到无法表达的交类型提示。
      final Object? io = await tools.ioFor(agentId);
      return io is WorkspaceFiles ? io : null;
    },
    log: coreLog.forPrefix('core:files'),
  );

  /// 成员级模型参数覆盖（M5b）：用户在「团队成员 → 模型配置」页设置的
  /// reasoning_effort / max_seqlen / max_output_tokens。
  ///
  /// 抽成局部函数是为了让**对话引擎与总结器共用同一口径**：压缩阈值按
  /// `agent.compressThreshold × max_seqlen` 判定，两处 max_seqlen 不一致就会
  /// 出现"压了还是超"或"没超就压"的怪象。
  Map<String, Object?> agentOverrides(String agentId) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return const <String, Object?>{};
    return <String, Object?>{
      if (agent.reasoningEffort.trim().isNotEmpty)
        'reasoning_effort': agent.reasoningEffort,
      if (agent.maxSeqlenOverride > 0) 'max_seqlen': agent.maxSeqlenOverride,
      if (agent.maxOutputTokens > 0) 'max_output_tokens': agent.maxOutputTokens,
      // 三态：没覆盖就不下发，交给模型自己的 thinking
      if (agent.thinkingOverride != null) 'thinking': agent.thinkingOverride,
    };
  }

  // 图像附件上传（`if_vision`）：把工作空间里的图片上传到**该模型配置的**端点
  // 拿 file_id，再在请求里引用（见 llm/vision_files.dart）。
  //
  // 两个容易搞错的点：
  // - 读字节只经 tools.ioFor(agentId)：SSH 成员的图片在**远端**，本机没有这个
  //   文件（拼本机路径必然读不到）；这也是与文件面板、工具层**同一份** IO；
  // - 上传从**本机核心**发出（用模型配置的 base_url / api_key），因此远端机器
  //   有没有外网都不影响。
  final WorkspaceVisionFileResolver visionFiles = WorkspaceVisionFileResolver(
    ioFor: tools.ioFor,
    cache: VisionFileCache(file: paths.visionFilesFile),
    log: coreLog.forPrefix('core:vision'),
  );

  // 外设就绪闸门：句柄必须在引擎构造前就有（预热本身要等握手之后才开跑），
  // 而它永不失败——无论预热成败都要放行，否则第一轮对话会被永久挂住。
  final Completer<void> peripheralsReady = Completer<void>();

  // 逐调用用量账本（③）：<数据根>/data/<agent>/<session>/usage.jsonl，一行一次
  // LLM 调用。一路共用同一个实例（每文件串行 + write-behind），关停时 flush。
  // 四类来源各有落账口：对话跳=引擎、内置压缩=CompactionService、执行站 llm.call=
  // CoreServer、插件接管跳=引擎（会话在读数里标了 plugin）。
  final UsageLog usageLog = UsageLog(paths, log: coreLog.forPrefix('core:usage'));

  final LlmAgentEngine engine = LlmAgentEngine(
    resolveModel: settings.model,
    toolRunner: tools,
    agentOverrides: agentOverrides,
    // 对话本身每一跳的逐调用账（含"端点不回 usage"的跳，那种标 estimated）
    usageLog: usageLog,
    // 图像视觉链路：只有模型配了 `if_vision` 才会用上（引擎内判），关着时请求体
    // 与从前逐字一致。
    visionResolver: visionFiles,
    // 外设（MCP/插件）就绪闸门：预热完成前开始的那一轮会在这里有界地等一下，
    // 避免"悄悄少掉插件/MCP 工具"（见 LlmAgentEngine.awaitReady）。
    awaitReady: () => peripheralsReady.future,
    // 每次工具结果前告诉模型当下的 todo 与已选 Spec。不接这个，用户在 UI 里
    // 勾选的 Spec 与 set_todo_list 的进度对模型来说就是装饰。
    sessionStatusText: (String agentId, String sessionId) => sessionStatusText(
      todos: todos.read(agentId, sessionId),
      selectedSpecIds:
          store.session(agentId, sessionId)?.selectedSpecIds ??
          const <String>[],
    ),
    log: coreLog.forPrefix('core:llm'),
  );

  // 上下文压缩（M7d-4）：总结走独立传输（不带工具，避免递归触发工具循环），
  // 阈值与水位线由 CompactionService 管；日志单独打 [core:compact] 前缀，
  // 这样用户报"压缩没生效"时能一眼看出核心到底压了没压。
  final CompactionService compaction = CompactionService(
    store: store,
    settings: settings,
    summarizer: LlmSummarizer(
      resolveModel: settings.model,
      agentOverrides: agentOverrides,
      log: coreLog.forPrefix('core:compact'),
    ),
    log: coreLog.forPrefix('core:compact'),
  );
  // 内置压缩那一次总结也是 LLM 调用：把账本接上（压缩时按会话绑定 sink；
  // 为什么不在构造参数里：UsageLog 与 CompactionService 都在这里才同时可见）。
  compaction.usageLog = usageLog;

  // 执行站 `llm.call`（点位化新增）：插件可让核心用**目标 agent 的模型**发一次
  // 硬设 `response_format=json_object` 的调用，拿结构化结果做高级处理。
  // 与对话引擎共用同一份模型解析与成员级覆盖（`agentOverrides`）。
  final LlmJsonCaller llmJsonCaller = LlmJsonCaller(
    resolveModel: settings.model,
    agentOverrides: agentOverrides,
    // 软超时到点才登记（正常快调用不进表）；登记后可由右栏 / 插件 tool.close /
    // agent 的 `tool_runs action=close` **显式关闭**（关闭即取消本流、释放连接）。
    requestRegistrar: llmRequestRegistrarOf(
      ToolRunRegistry.instance,
      tool: 'llm.call',
    ),
    log: coreLog.forPrefix('core:llm-call'),
  );

  bootLog('引擎与压缩装配完成');

  final CoreServer server = await CoreServer.start(    port: port,
    streamChunkDelay: Duration(milliseconds: chunkDelayMs),
    enableHeartbeat: enableHeartbeat,
    store: store,
    settings: settings,
    todoStore: todos,
    engine: engine,
    questions: questions,
    subagents: subagents,
    teamService: teams,
    messageDispatcher: messages,
    specService: specs,
    specIoFor: tools.ioFor,
    systemPromptStore: systemPrompts,
    mcpService: mcp,
    pluginBus: plugins,
    fileService: files,
    // 核心改 agent yaml（工作目录镜像）前先备份，与团队自愈同约定
    agentBackup: (CoreAgent agent) => backupAgentFile(paths, agent.id),
    // 执行站 llm.call 的逐调用账（source=llm.call；按会话绑定，见 _stationLlmCall）
    usageLog: usageLog,
    // 远端（SSH）终端的伪终端：从**缓存的那条** SSH 工作空间 IO 上取 shell 通道
    // （与文件面板 / 工具层同一条连接），因此 Ctrl+J 不会为每个 agent 再连一次 SSH。
    // 没接线时远端终端只回可读错误，绝不退回本机执行。
    sshPtyStarter: SshPtyAdapter(
      openChannel:
          (CoreAgent agent, {required int columns, required int rows}) async {
            final Object? io = await tools.ioFor(agent.id);
            // 工具层的 IO 外面包了一层 PrivateWorkspaceIO（私有状态分栏），拆开拿真身
            final Object? raw = io is PrivateWorkspaceIO ? io.inner : io;
            if (raw is! SshWorkspaceIO) {
              throw StateError(
                '该 agent 的有效工作空间不是 SSH 工作空间（${agent.id}），无法开远端终端',
              );
            }
            return raw.openShell(columns: columns, rows: rows);
          },
    ).start,
    compaction: compaction,
    // M9 Wave 3-I 第 2 条：执行站 terminal.exec 与工具层**共用同一份 TerminalHooks**，
    // 插件下发的 hook 任务与 agent 自己起的 hook 任务因此互相看得到 task_id
    // （hook_action=status/cancel 能查到对方起的任务）。该实例归工具层所有：
    // 完成回调走 tools.onHookFinished（下面接到 conversation.wake），
    // 释放由 tools.close() 负责，核心 close 不会重复关它。
    stationHooks: tools.hooks,
    // 执行站命令 `llm.call` 的落点（点位化）：**站点处硬设 JSON 返回形式**，
    // 模型复用目标 agent 的模型（与对话同一份解析 + 成员级覆盖）。
    llmJsonCaller: llmJsonCaller,
  );
  // 起监听后才存在的三个依赖一次性接上：广播、在途状态、消息投递
  hubSink = server.hub.broadcast;
  workingSink = server.conversation.isRunning;
  deliverSink = server.conversation.deliver;
  if (verbose) {
    // 访问日志同样走唯一出口（`--verbose` 是显式打开，量由轮转兜住）
    server.accessLog = coreLog.forPrefix('core');
  }
  // 未捕获异常始终记下来：此时 500 回包往往也写不出去，客户端只能看到连接断开
  server.errorLog = coreLog.forPrefix('core:error');
  // 后台长任务结束后唤醒 agent（把完成提示注入会话并继续生成）。
  // `subagent` 非空 = 这条通知来自一个**后台临时员工**：标记随消息一起落库与下发。
  // 多个后台临时员工并发完成时，每一次调用都是独立的一条消息 + 独立的一轮，互不覆盖。
  tools.onHookFinished = (
    String agentId,
    String sessionId,
    String notice, {
    SubagentTag? subagent,
  }) {
    unawaited(
      server.conversation.wake(
        agentId: agentId,
        sessionId: sessionId,
        notice: notice,
        subagent: subagent,
      ),
    );
  };
  // **远端后台任务接续**（用户 2026-10-04）：把落盘台账里仍未完成的远端后台命令重新
  // 挂上——**不重跑、不新起**。若它在"应用没在运行"这段时间里已经跑完，这里会立刻
  // 收尾并把完成提示走上面那条 `tools.onHookFinished → conversation.wake` 投递回
  // **原会话**；agent / 会话已不存在则由 `restorePending` 如实记日志（不假装投递成功）。
  unawaited(
    tools.hooks
        .restorePending(ioFor: tools.ioFor)
        .then((int count) {
          if (count > 0) bootLog('已接续 $count 个远端后台任务');
        })
        .catchError((Object error) {
          coreLog.forPrefix('core:tool')('接续远端后台任务失败：$error');
        }),
  );
  // 临时员工的"跑一轮"落点：会话服务（它才有引擎、会话与流式下行）
  subagentService.runner = server.conversation.runSubagent;

  bootLog('监听已就绪，即将发出握手');

  // 本进程自己的报告（`[tree_core]` 前缀）：与原先的 stderr 行逐字一致，只是同时落盘
  final void Function(String line) logCore = coreLog.forPrefix('tree_core');

  // 唯一的 stdout 输出：就绪握手（父进程按行读取并解析）。
  // 带上数据根（可选字段）：应用侧据此才能给出"打开日志目录 / 看最近 N 行"入口——
  // 它没有任何别的权威来源（拉起核心时不传 --data-dir）。
  stdout.writeln(server.handshake.withDataRoot(paths.root).encode());
  await stdout.flush();
  logCore(
    'v${TreeCore.version} listening on '
    '127.0.0.1:${server.port} (pid ${server.processId})',
  );
  logCore('数据目录：${paths.root}');
  logCore('核心日志落盘：${coreLog.logFile}');

  // 握手已发出 ⇒ 界面立刻可用。外设预热从这里**才开始**并行跑：慢的 MCP/插件
  // 只影响"第一轮生成时的工具表"（那一轮由 awaitReady 闸门兜底），不再拖住核心启动。
  unawaited(
    _warmUpPeripheralsAfterHandshake(
      mcp,
      plugins,
      peripheralsReady,
      coreLog.forPrefix('core:boot'),
    ),
  );

  final Completer<void> shutdown = Completer<void>();
  // 可靠退出通道：stdin 逐行命令（父进程写 `shutdown\n`）。
  //
  // 为什么不用 stdin EOF：**Windows 上父进程 `Process.stdin.close()` 不会让
  // 子进程的 stdin 变成 done**（实测挂起 15s+），故 EOF 只能当 best-effort。
  // 显式命令 + 信号 + 父进程兜底 kill 三者叠加才是可靠的进程生命周期管理。
  final StreamSubscription<String> control = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (String line) {
          final String command = line.trim().toLowerCase();
          if (command == 'shutdown' || command == 'quit' || command == 'exit') {
            _complete(shutdown);
          }
        },
        // 故意**不**把 stdin EOF 当作退出信号：父进程若不接管 stdin
        // （`Start-Process`、任务计划、双击运行、服务化等），子进程会立刻
        // 读到 EOF；若据此退出，核心会在打印握手后瞬间消失，父进程拿到端口
        // 却连不上。EOF 只是"控制通道已关闭"，生命周期由显式命令/信号/父进程
        // kill 决定。
        onError: (Object _) {},
        cancelOnError: true,
      );
  _watchSignal(ProcessSignal.sigint, shutdown);
  _watchSignal(ProcessSignal.sigterm, shutdown);

  await shutdown.future;
  await control.cancel();
  logCore('shutting down');
  await server.close();
  await tools.close();
  // 关停是唯一能保证日志尾部完整的时机：WriteQueue 在硬杀时会丢掉在途任务
  // （见 core_log_sink.dart / write_queue.dart 的说明），故必须在 exit 之前 flush。
  await coreLog.flush();
  // 逐调用用量账本同样走 WriteQueue：不 flush 就可能在 exit 时丢掉最后几笔账，
  // 而那些恰好是"用户刚看完的那几轮"。
  await usageLog.flush();
  await stdout.flush();
  await stderr.flush();
  // 显式退出：stdin 订阅会让事件循环保持存活，返回 main 不保证 VM 结束
  exit(0);
}

/// 握手**之后**并行预热外设（MCP / 插件），结束时放行 [ready] 闸门。
///
/// 原则只有两条：
/// 1. 预热绝不排在握手之前（否则外设卡住 = 界面看到"核心进程未能启动"）；
/// 2. 无论成败都要放行闸门（否则第一轮生成会永远等下去）。
Future<void> _warmUpPeripheralsAfterHandshake(
  McpService mcp,
  PluginBus plugins,
  Completer<void> ready,
  void Function(String message) log,
) async {
  try {
    await warmUpPeripherals(
      <WarmUpTask>[
        (name: 'MCP 服务', run: () => mcp.refresh()),
        (name: '插件', run: () => plugins.start()),
      ],
      budget: const Duration(seconds: 3),
      log: log,
    );
  } catch (error) {
    // warmUpPeripherals 自己绝不抛；这里只是最后一道兜底，保证闸门一定放行。
    log('外设预热异常（已忽略）：$error');
  } finally {
    if (!ready.isCompleted) ready.complete();
  }
}

void _complete(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

/// 订阅退出信号；**平台不支持时必须静默忽略**。
///
/// Windows 没有 SIGTERM：`ProcessSignal.sigterm.watch()` 会抛
/// `SignalException`（errno 50 / ERROR_NOT_SUPPORTED）。若不捕获，未处理异常会
/// 让刚打印完握手的核心进程立刻崩溃——父进程拿到端口却连不上。
/// 退出兜底由 stdin 的 `shutdown` 命令与父进程 kill 承担，故忽略是安全的。
void _watchSignal(ProcessSignal signal, Completer<void> shutdown) {
  try {
    signal.watch().listen(
      (_) => _complete(shutdown),
      // 关键：`watch()` 在不支持的平台上把 `SignalException` 作为**流错误**
      // 抛出，只加 try/catch 抓不到；无 onError 时它成为未处理异步异常并
      // 终止进程（表现为"打印完握手就退出，父进程连不上端口"）。
      onError: (Object _) {},
    );
  } catch (_) {
    // 同步抛出的平台不支持情形
  }
}

int? _intArg(List<String> args, String name) {
  final int index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return int.tryParse(args[index + 1]);
}

String? _stringArg(List<String> args, String name) {
  final int index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

const String _usage = '''
tree_core — Tree 桌面端核心进程（本地回环 HTTP + WS）

用法: tree_core [选项]
  --port <n>             监听端口（0 = 内核分配，默认）
  --chunk-delay-ms <n>   流式片段间隔毫秒（默认 40）
  --data-dir <path>      数据根目录（默认：%APPDATA%\\Tree 等平台规范位置）
  --print-paths          打印解析出的数据根目录后退出
  --no-heartbeat         关闭保活心跳下发
  --verbose              打开请求级日志
  -v, --version          打印版本
  -h, --help             打印本用法
''';
