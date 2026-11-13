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
///
/// A5（2026-10-25）：核心只保留平台面（插件总线 / 服务端 / 存储 / 设置 / WS）；
/// 领域服务（SpecService / TeamService / FileService / LlmAgentEngine /
/// WorkspaceToolRunner / TerminalService 等）已整体移交插件，本入口不再装配它们。
///
/// 命令行参数：
///   `--port <n>`           监听端口（0 = 内核分配，默认）
///   `--chunk-delay-ms <n>` 兼容旧参数（A5 起核心无流式生成，忽略）
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
  final bool enableHeartbeat = !args.contains('--no-heartbeat');
  final bool verbose = args.contains('--verbose');

  // 单实例闸门（2026-11-01）：核心只能有**一个**进程。多开的后果是每个核心各自拉起
  // 一套插件与界面窗口、并发写同一份数据根（实测出现过 3 个核心同时在跑）。
  //
  // 判据不是"有没有文件"（硬杀会留下陈旧记录），而是"那把 token 还能不能打通
  // `/api/meta`"。活着 ⇒ 本次直接退出，交给 loader 附着；打不通 ⇒ 清掉陈旧记录继续。
  final CoreInstanceFile instance = CoreInstanceFile(paths.coreInstanceFile);
  final CoreInstanceRecord? existing = instance.read();
  if (existing != null) {
    final bool alive = await instance.alive(existing);
    if (alive) {
      stderr.writeln(
        '[tree_core] 已有核心在运行（pid=${existing.pid} '
        '${existing.httpBaseUrl}），本实例退出（核心是单实例）',
      );
      exit(0);
    }
    instance.clear();
  }

  // 日志出口（核心唯一的一处）：**同时**写 stderr（保持原样）与
  // `<数据根>/logs/core.log`（8 MiB × 5 份轮转）。放在这里是为了让后面**所有**
  // 日志（含启动计时）都走同一个出口——发布版没有调试器，落盘是唯一的取证手段。
  // 构造零副作用（懒打开），所以 --print-paths / -h / -v 那些早退分支不受影响。
  final CoreLogSink coreLog = CoreLogSink(paths);

  // 启动分段计时：把「核心启动慢」变成可归因的数字（日志的 [core:boot] 行）。
  final Stopwatch boot = Stopwatch()..start();
  void bootLog(String phase) =>
      coreLog.write('[core:boot] $phase：累计 ${boot.elapsedMilliseconds}ms');

  // 平台设置落盘（帧率 / 心跳判活 / 数据收集开关）。注意：`settings.yaml` 里
  // 仍可能带着尚未拆走的领域键（模型池在 `config/models/`，由 tree.agent 接管），
  // 核心只读不改（A5 遗留：CoreSettings 的领域拆分见报告）。
  final void Function(String message) logStore = coreLog.forPrefix('core:store');
  final CoreSettings settings = CoreSettings();
  FileSettingsSink(paths, log: logStore).load(settings);

  // 插件总线：配置在 <数据根>/config/plugins.yaml；启动时拉起全部启用插件
  // 并开始心跳巡检。坏插件只标记为不可用，不拦住核心启动。
  // 心跳判活参数（M9 1.1）同样来自设置：PluginBus 把它转给插件宿主（stdio 通道
  // 的 LivenessTracker）与站点看门狗。生效时机 = **下次核心启动**。
  void Function(Map<String, dynamic> frame)? hubSink;
  final PluginBus plugins = PluginBus(
    configFile: paths.pluginsConfigFile,
    coreVersion: TreeCore.version,
    heartbeatInterval: settings.heartbeatInterval,
    missThreshold: settings.missedHeartbeatLimit,
    // plugin_status / plugin_event 广播到前端（起监听后 hubSink 会被接上）
    broadcast: (Map<String, dynamic> frame) => hubSink?.call(frame),
    log: coreLog.forPrefix('core:plugin'),
  );
  bootLog('设置 / 插件总线装配完成（预热推迟到握手之后）');

  final CoreServer server = await CoreServer.start(
    port: port,
    enableHeartbeat: enableHeartbeat,
    settings: settings,
    pluginBus: plugins,
    // 发布仓库（阶段 5：插件管理只拉发布源的 Release 资产）：这里只给数据根的
    // 缓存目录，剩下的接线（已装条目读 plugins.yaml / 脚本型解释器探测 / 换文件
    // 闸门）在核心里做——路径口径归 CLI，行为口径归总线与下载器。
    pluginReleaseCacheDir: paths.pluginsReleaseDir,
    dataDir: paths.root,
  );
  // 起监听后才存在的依赖一次性接上：广播。
  hubSink = server.hub.broadcast;
  if (verbose) {
    // 访问日志同样走唯一出口（`--verbose` 是显式打开，量由轮转兜住）
    server.accessLog = coreLog.forPrefix('core');
  }
  // 未捕获异常始终记下来：此时 500 回包往往也写不出去，客户端只能看到连接断开
  server.errorLog = coreLog.forPrefix('core:error');

  bootLog('监听已就绪，即将发出握手');

  // 实例发现文件：**监听成功之后**才写（端口 / token 在此之前不存在）。loader 与
  // 之后任何一次双击都靠它判断"该附着还是该新起"，写在这里也保证它比握手先就位。
  await instance.write(
    CoreInstanceRecord(
      pid: server.processId,
      port: server.port,
      token: server.handshake.token,
      version: TreeCore.version,
      dataRoot: paths.root,
    ),
  );

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

  // 握手已发出 ⇒ 界面立刻可用。外设预热（插件）从这里**才开始**并行跑：
  // 慢插件只影响插件面板的首次就绪，不再拖住核心启动。
  unawaited(
    _warmUpPeripheralsAfterHandshake(
      plugins,
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
  // 实例发现文件跟着这一世一起消失：留着它会让下一次启动的探测去连一个已经关掉的端口
  //（探测失败虽然也能自愈，但"正常退出不留垃圾"本该由退出路径负责）。
  instance.clear();
  // 关停是唯一能保证日志尾部完整的时机：WriteQueue 在硬杀时会丢掉在途任务
  // （见 core_log_sink.dart / write_queue.dart 的说明），故必须在 exit 之前 flush。
  await coreLog.flush();
  await stdout.flush();
  await stderr.flush();
  // 显式退出：stdin 订阅会让事件循环保持存活，返回 main 不保证 VM 结束
  exit(0);
}

/// 握手**之后**并行预热插件，结束时只记日志（A5 后不再有对话引擎等待闸门）。
///
/// 原则只有两条：
/// 1. 预热绝不排在握手之前（否则插件卡住 = 界面看到"核心进程未能启动"）；
/// 2. 无论成败都只记日志（坏插件不拦住核心）。
Future<void> _warmUpPeripheralsAfterHandshake(
  PluginBus plugins,
  void Function(String message) log,
) async {
  try {
    await warmUpPeripherals(
      <WarmUpTask>[
        (
          name: '环境变量',
          // 启动时**主动重读一次**（而不是等第一次工具调用）：用户刚在系统里配好的
          // PATH / 新装工具，核心与随后拉起的插件进程要立刻按它工作。之后需要再
          // 刷新时走执行站 `env.refresh`（插件可调）。
          run: () async {
            final Map<String, String> env = await refreshLoginEnvironment(
              log: log,
            );
            final int pathSegments = (env['Path'] ?? env['PATH'] ?? '')
                .split(';')
                .where((String part) => part.trim().isNotEmpty)
                .length;
            log(
              '按登录口径读取环境变量 ${env.length} 项'
              '（PATH $pathSegments 段${Platform.isWindows ? '' : '，非 Windows 沿用继承值'}）',
            );
          },
        ),
        (
          name: '插件',
          run: () async {
            // 内置插件的两件 startup 事必须都排在 `plugins.start()` 之前（start 会做
            // 一次配置对账，改晚了对账看不到）：
            // 1) [migrateBuiltinEntries]：清单已从 Python 脚本换成随包二进制的项（现在
            //    是 `compact`），把磁盘上那条老命令重写掉——不迁移的后果是“插件突然
            //    起不来”，而 plugins.yaml 看上去完全正常；
            // 2) [seedDefaultEnabledBuiltins]：`defaultEnabled` 的项（`ssh_executor` 中转站
            //    与 `self_updater`）首次随包出现时播种一条 enabled: true；用户显式关过
            //    就绝不自动打开。
            final PluginConfigStore builtinStore = PluginConfigStore(
              plugins.configFile,
            );
            try {
              final List<String> moved = await migrateBuiltinEntries(
                catalog: BuiltinPluginCatalog(),
                store: builtinStore,
                log: log,
              );
              if (moved.isNotEmpty) {
                log('已迁移换代后的内置插件命令：${moved.join('、')}');
              }
            } catch (error) {
              // 迁移失败不该拦住插件系统启动（最坏就是那一项还要用户在面板上重开一次）。
              log('内置插件换代迁移失败（已忽略）：$error');
            }
            try {
              final List<String> seeded = await seedDefaultEnabledBuiltins(
                catalog: BuiltinPluginCatalog(),
                store: builtinStore,
                log: log,
              );
              if (seeded.isNotEmpty) {
                log('已播种默认开启的内置插件：${seeded.join('、')}');
              }
            } catch (error) {
              // 播种失败不该拦住插件系统启动（最坏就是中转站没默认开）。
              log('播种默认内置插件失败（已忽略）：$error');
            }
            // 3) [seedDesktopUiPlugin]：随安装包发布的默认界面（与核心同目录的
            //    `tree_ui.exe` + `plugin.json`）首次出现时登记一条 `runtime: ui`。
            //    少了这一步，新装机的 plugins.yaml 里根本没有界面这一条，核心
            //    永远不会拉起它 —— 用户双击图标只会看到引导页，或者什么都没有。
            //    登记进来之后**走的是与其它 UI 插件完全相同的通用启动路径**
            //    （PluginBus → UiHost），这里不写任何“默认界面”特判。
            try {
              final List<String> seededUi = await seedDesktopUiPlugin(
                store: builtinStore,
                log: log,
              );
              if (seededUi.isNotEmpty) {
                log('已登记随包默认界面插件：${seededUi.join('、')}');
              }
            } catch (error) {
              log('登记默认界面插件失败（已忽略）：$error');
            }
            await plugins.start();
          },
        ),
      ],
      budget: const Duration(seconds: 3),
      log: log,
    );
  } catch (error) {
    // warmUpPeripherals 自己绝不抛；这里只是最后一道兜底。
    log('外设预热异常（已忽略）：$error');
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
tree_core — Tree 桌面端核心进程（本地回环 HTTP + WS，平台面）

用法: tree_core [选项]
  --port <n>             监听端口（0 = 内核分配，默认）
  --chunk-delay-ms <n>   兼容旧参数（A5 起核心无流式生成，忽略）
  --data-dir <path>      数据根目录（默认：%APPDATA%\\Tree 等平台规范位置）
  --print-paths          打印解析出的数据根目录后退出
  --no-heartbeat         关闭保活心跳下发
  --verbose              打开请求级日志
  -v, --version          打印版本
  -h, --help             打印本用法
''';
