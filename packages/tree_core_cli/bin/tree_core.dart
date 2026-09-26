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

  // 落盘装配：存储（agents/sessions/messages）与设置/模型池。核心进程的所有
  // 状态都在 ~/.tree 下的纯文本文件里，用户可直接查看与手改。
  void logStore(String message) => stderr.writeln('[core:store] $message');
  final FileTreeStore store = FileTreeStore(paths, log: logStore);
  final CoreSettings settings = CoreSettings();
  FileSettingsSink(paths, log: logStore).load(settings);

  // 回复引擎：真实 LLM（OpenAI 兼容端点）。模型池来自 ~/.tree/config/models，
  // 因此"换模型/改密钥"只需改配置文件，不必改代码。
  // 工具执行器：工作空间目录取 agent 配置里的 workspace_dir，未配置则落到
  // <数据根>/workspaces/<agent_id>（首次使用时自动创建）。
  final FileTodoStore todos = FileTodoStore(paths);

  // 提问回路：工具层先建好、核心后建 WS 广播，因此广播目标用一个可后置绑定的
  // 槽（core 起监听后立即接上 `hub.broadcast`）。
  final FileQuestionStore questionStore = FileQuestionStore(paths);
  void Function(Map<String, dynamic> frame)? hubSink;
  final QuestionBroker questions = QuestionBroker(
    questions: questionStore,
    transcript: store,
    broadcast: (Map<String, dynamic> frame) => hubSink?.call(frame),
    log: (String message) => stderr.writeln('[core:ask] $message'),
  );
  // 团队服务：成员就是 agent（`agents/<id>.yaml`）。working 状态同样后置绑定到
  // 会话服务的在途任务表，避免"服务先于核心构造"的顺序环。
  bool Function(String agentId)? workingSink;
  final TeamService teams = TeamService(
    store: store,
    settings: settings,
    isWorking: (String agentId) => workingSink?.call(agentId) ?? false,
    log: (String message) => stderr.writeln('[core:team] $message'),
  );
  // 消息派发：投递实现要等核心起监听后才有（ConversationService 由核心创建），
  // 因此同样用可后置绑定的槽。
  TeamDelivery? deliverSink;
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
    // 活动日志与文件投递只走**本机**工作空间：SSH 成员的工作空间在远端，
    // 这里返回空串，投递会明确报"不支持"而不是复制到无关目录。
    workspaceDirOf: (String agentId) {
      final CoreAgent? agent = store.agent(agentId);
      if (agent != null && agent.sshConfig != null) return '';
      final String configured = agent?.workspaceDir ?? '';
      return configured.trim().isNotEmpty
          ? configured
          : paths.defaultWorkspaceDir(agentId);
    },
    log: (String message) => stderr.writeln('[core:msg] $message'),
  );
  final WorkspaceToolRunner tools = WorkspaceToolRunner(
    todoStore: todos,
    askQuestion: questions.ask,
    teamService: teams,
    messageDispatcher: messages,
    resolveSshConfig: (String agentId) => store.agent(agentId)?.sshConfig,
    // SSH 后端（dartssh2 + SFTP/exec）：每个 agent 一条连接，按需建立并缓存；
    // 远端根目录取 ssh.root（空 = 远端登录用户的 HOME）。
    sshIoFactory: (SshConfig config) async {
      final DartSshTransport transport = await DartSshTransport.connect(
        host: config.host,
        port: config.port,
        username: config.username,
        password: config.password,
        keyPath: config.resolvedKeyPath(),
        keyPassphrase: config.keyPassphrase,
      );
      final String root = await resolveRemoteRoot(transport, config.root);
      stderr.writeln('[core:tool] SSH 已连接 ${config.redacted()} root=$root');
      return SshWorkspaceIO(root, transport);
    },
    resolveWorkspaceDir: (String agentId) {
      final String configured = store.agent(agentId)?.workspaceDir ?? '';
      return configured.trim().isNotEmpty
          ? configured
          : paths.defaultWorkspaceDir(agentId);
    },
    log: (String message) => stderr.writeln('[core:tool] $message'),
  );
  final LlmAgentEngine engine = LlmAgentEngine(
    resolveModel: settings.model,
    toolRunner: tools,
    // 成员级模型参数覆盖（M5b）：用户在「团队成员 → 模型配置」页设置的
    // reasoning_effort / max_seqlen / max_output_tokens 在这里作用到请求上。
    agentOverrides: (String agentId) {
      final CoreAgent? agent = store.agent(agentId);
      if (agent == null) return const <String, Object?>{};
      return <String, Object?>{
        if (agent.reasoningEffort.trim().isNotEmpty)
          'reasoning_effort': agent.reasoningEffort,
        if (agent.maxSeqlenOverride > 0) 'max_seqlen': agent.maxSeqlenOverride,
        if (agent.maxOutputTokens > 0)
          'max_output_tokens': agent.maxOutputTokens,
      };
    },
    log: (String message) => stderr.writeln('[core:llm] $message'),
  );

  final CoreServer server = await CoreServer.start(
    port: port,
    streamChunkDelay: Duration(milliseconds: chunkDelayMs),
    enableHeartbeat: enableHeartbeat,
    store: store,
    settings: settings,
    todoStore: todos,
    engine: engine,
    questions: questions,
    teamService: teams,
    messageDispatcher: messages,
  );
  // 起监听后才存在的三个依赖一次性接上：广播、在途状态、消息投递
  hubSink = server.hub.broadcast;
  workingSink = server.conversation.isRunning;
  deliverSink = server.conversation.deliver;
  if (verbose) {
    // 访问日志走 stderr（stdout 是进程间协议，绝不能混入日志）
    server.accessLog = (String message) => stderr.writeln('[core] $message');
  }
  // 后台长任务结束后唤醒 agent（把完成提示注入会话并继续生成）
  tools.onHookFinished = (String agentId, String sessionId, String notice) {
    unawaited(
      server.conversation.wake(
        agentId: agentId,
        sessionId: sessionId,
        notice: notice,
      ),
    );
  };

  // 唯一的 stdout 输出：就绪握手（父进程按行读取并解析）
  stdout.writeln(server.handshake.encode());
  await stdout.flush();
  stderr.writeln(
    '[tree_core] v${TreeCore.version} listening on '
    '127.0.0.1:${server.port} (pid ${server.processId})',
  );
  stderr.writeln('[tree_core] 数据目录：${paths.root}');

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
  stderr.writeln('[tree_core] shutting down');
  await server.close();
  await tools.close();
  await stdout.flush();
  await stderr.flush();
  // 显式退出：stdin 订阅会让事件循环保持存活，返回 main 不保证 VM 结束
  exit(0);
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
