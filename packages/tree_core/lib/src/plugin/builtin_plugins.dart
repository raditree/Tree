import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'plugin_config_store.dart';
import 'plugin_host.dart' show PluginSuspension;

/// 框架自迭代插件的**内置身份**（与 `packages/tree_self_updater` 里那一份**必须同串**）。
///
/// 为什么不共享常量：插件包要零核心依赖（不能反过来依赖 tree_core），因此两边各一条，
/// 而“不同串”这个错由真子进程用例钉住：[plugin_tool_define_self_updater_test]。
const String kSelfUpdaterPluginId = 'self_updater';

/// 随包可执行文件的基本名（Windows 上解析时补 `.exe`）。
const String kSelfUpdaterBinaryName = 'tree_self_updater';

/// 内置压缩器的插件 id 与随包二进制基本名（2026-10-17：从 Python 脚本换成 Dart 产物）。
const String kCompactPluginId = 'compact';
const String kCompactBinaryName = 'tree_compact';

/// 内置插件的**静态清单**（M9 §4.2：内置插件与自定义插件都要能在前端开/关）。
///
/// 为什么清单在核心而不是前端：内置插件的"身份"必须由核心认定——前端只拿到
/// id + 名称 + 说明 + 开关状态，具体要拉起什么命令、脚本在哪，全部由核心在
/// **打开的那一刻**解析（见 [BuiltinPluginCatalog.resolve]）：
/// - **python 型**：Windows 依次探测 python / py -3；其他平台 python3 / python；
/// - **binary 型**（2026-10-10 新增，用于 `ssh_executor` 中转站）：**不做运行时探测**，
///   直接解析"可执行文件同级的 `plugins/<name>`（Windows 补 `.exe`）"；
/// - 脚本：优先核心可执行文件同级的 `plugins/<name>.py`（发行包里由
///   tool/package_windows.dart 把 examples/plugins 复制到那里）；开发态向上定位
///   **仓根**后查 `examples/plugins/`（不依赖当前工作目录——桌面壳是以自己所在
///   目录为 cwd 拉起核心的，Debug 产物目录下没有 plugins/）。
///
/// 解析结果会写成一条**普通插件配置**（带 builtin: true 标记供 UI 分组），
/// 因此内置插件与用户自己加的插件在运行时走的是同一条路（插件总线只认这一份配置）。
///
/// 解析不出来时**必须给可读错误**（「未检测到 Python，请先安装或改用自定义命令」），
/// 不允许静默失败：静默失败在界面上表现为"点了开关没反应"。
class BuiltinPluginSpec {
  const BuiltinPluginSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.script,
    required this.runtime,
    this.kind = kindPython,
    this.granularity = 'team',
    this.scope = const <String, dynamic>{},
    this.defaultEnabled = false,
    this.suspension = '',
  });

  /// 插件类型：需要 Python 解释器的脚本。
  static const String kindPython = 'python';

  /// 插件类型：随包分发的**可执行文件**（不探测任何运行时）。
  static const String kindBinary = 'binary';

  /// 插件 id（也是落盘条目的 id；面板用它做开关）。
  final String id;

  /// 展示名。
  final String name;

  /// 说明（面板上给用户看的"这是什么、怎么用"）。
  final String description;

  /// 文件名（相对 plugins/ 目录；不含路径分隔符）。
  ///
  /// - [kindPython]：脚本文件名（含 `.py`）；
  /// - [kindBinary]：可执行文件**基本名**（**不含** `.exe`；Windows 上解析时补）。
  final String script;

  /// 所需运行时的可读名字（如 python / binary）。
  final String runtime;

  /// [kindPython] / [kindBinary]。
  final String kind;

  /// 默认实例粒度（team / agent / session）。
  final String granularity;

  /// 默认 scope（空 Map = 不限定归属：不进站点体系，工具走 tools/list 申报路径，
  /// 因此对所有 team 的调用点都可见）。
  final Map<String, dynamic> scope;

  /// 是否**首次随包出现即默认开启**（用户 2026-10-10 拍板：「默认开（升级即生效）」）。
  ///
  /// 语义严格限定为：`plugins.yaml` 里**根本没有这一条**时才由
  /// [seedDefaultEnabledBuiltins] 播种一条 `enabled: true`。
  /// 用户显式关过（条目在、`enabled: false`）**绝不再自动打开**。
  final bool defaultEnabled;

  /// 可挂起声明（'' = 不可挂起；`keep` = 热重启先转储、新一世取回续跑）。
  ///
  /// 为什么必须做进内置清单而不是“让用户自己改 yaml”：`PluginConfig.fromJson` **不保留
  /// 未知键**（不变量 25），所以下面 [entryFor] 不写这一项时，落盘的条目就永远不会有
  /// `suspension`，热重启只能冷启动 —— 而“一个声明了可挂起的内置插件被冷重启”在界面上
  /// 表现为“状态没了”，看上去像 bug，实际是清单漏了一个字段。
  final String suspension;

  /// 给前端的内置插件说明（config / enabled / resolution 由核心在响应里补）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'script': script,
    'runtime': runtime,
    'kind': kind,
    'granularity': granularity,
    'scope': scope,
    'default_enabled': defaultEnabled,
    'suspension': suspension,
  };
}

/// 探测到的运行时：要拉起的命令 + 命令前缀参数（如 py -3）。
class BuiltinRuntime {
  const BuiltinRuntime(this.command, [this.prefixArgs = const <String>[]]);

  final String command;
  final List<String> prefixArgs;

  /// 可读描述（日志 / 面板用）。
  String get label =>
      prefixArgs.isEmpty ? command : '$command ${prefixArgs.join(' ')}';
}

/// 探测某个候选运行时是否可用（默认实现：跑一遍 --version，退出码 0 即可用）。
typedef RuntimeProbe = Future<bool> Function(String command, List<String> args);

/// 一次内置插件的解析结果（可读错误也在这里，不抛异常）。
class BuiltinResolution {
  const BuiltinResolution._({
    required this.ok,
    this.command = '',
    this.prefixArgs = const <String>[],
    this.scriptPath = '',
    this.error = '',
    this.searchedScriptRoots = const <String>[],
  });

  /// 成功：运行时可执行文件与脚本都解析出来了。
  factory BuiltinResolution.ok({
    required String command,
    required List<String> prefixArgs,
    required String scriptPath,
    required List<String> searchedScriptRoots,
  }) => BuiltinResolution._(
    ok: true,
    command: command,
    prefixArgs: prefixArgs,
    scriptPath: scriptPath,
    searchedScriptRoots: searchedScriptRoots,
  );

  /// 失败：可读中文原因（直接显示给用户）。
  factory BuiltinResolution.failed(
    String error, {
    List<String> searchedScriptRoots = const <String>[],
  }) => BuiltinResolution._(
    ok: false,
    error: error,
    searchedScriptRoots: searchedScriptRoots,
  );

  final bool ok;
  final String command;
  final List<String> prefixArgs;

  /// 脚本绝对路径（ok 时非空）。
  final String scriptPath;

  /// 可读错误（ok 时为空串）。
  final String error;

  /// 查找脚本时用过的目录（诊断用；面板会显示"我都找过哪儿"）。
  final List<String> searchedScriptRoots;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'command': command,
    'args': <String>[...prefixArgs, if (scriptPath.isNotEmpty) scriptPath],
    'script_path': scriptPath,
    'error': error,
    'searched_script_roots': searchedScriptRoots,
  };
}

/// 内置插件目录（静态清单 + 运行时/脚本解析 + 解析结果缓存）。
///
/// 缓存口径：探测要真起进程（Windows 上 python / py -3 两次），面板每次打开都探
/// 一遍既慢又吵，所以结果按进程缓存；用户可能"缺 Python 时去装了一个"，因此
/// 解析入口支持 [resolve] 的 refresh = true 强制重探（界面上有刷新按钮）。
class BuiltinPluginCatalog {
  BuiltinPluginCatalog({
    this._scriptRoots,
    this._probe,
    bool? isWindows,
    String? executableDir,
    this._probeTimeout = const Duration(seconds: 5),
  }) : _isWindows = isWindows ?? Platform.isWindows,
       _executableDir = executableDir ?? p.dirname(Platform.resolvedExecutable);

  /// 核心内置的插件清单（至少一项：示例插件 sample）。
  ///
  /// 新增内置插件 = 往这里加一条 + 随包分发 `plugins/<script>`；
  /// 面板会自动出现这一项（前端不写死任何内置插件）。
  static const List<BuiltinPluginSpec> specs = <BuiltinPluginSpec>[
    BuiltinPluginSpec(
      id: 'sample',
      name: '示例插件',
      description:
          '核心自带的示例插件（Python）：演示 stdio JSON-RPC 握手、工具申报与站点订阅，'
          '可以直接当自己写插件的骨架。打开后会调用 Python 运行 plugins/sample_plugin.py。',
      script: 'sample_plugin.py',
      runtime: 'python',
      granularity: 'team',
      scope: <String, dynamic>{},
    ),
    // 2026-10-17：**随包二进制**（以前是 `compact_plugin.py` + 解释器）。
    // 换代的理由不是“Dart 比较好看”，而是这份插件要在用户机器上零依赖地跑起来：
    // Python 形态下“没装 Python”与“装了但不在 PATH”在面板上都表现为一个开关弹不开，
    // 而核心自己就是 Dart，产物已经在包里——没道理再要求用户多一个运行时。
    // 老磁盘配置里那条 `python + …compact_plugin.py` 由 [migrateBuiltinEntries] 在
    // 启动期重写（不重写的结局是“压缩突然起不来”，而配置看上去完全正常）。
    BuiltinPluginSpec(
      id: kCompactPluginId,
      name: '上下文压缩',
      description:
          '内置压缩器（随包二进制，不是脚本）：接管 `system.relay.context.compact`，把长会话压成'
          '「摘要（背景 / 轨迹 / 改动产出文件）+ 必读文件（≤11 个，精确行范围，'
          '以 read 工具调用的形式拼进上下文）+ todo 快照」，最近一轮原文原样保留。'
          '总结调用走前缀缓存三条件（tools 透传 / 不用 system / response_format=text）；'
          '任何一步失败都会退回核心内置压缩，不会让上下文丢失。'
          '自检：`tree_compact --selftest`（不需要真核心，退出码 0 = 全绿）。',
      script: kCompactBinaryName,
      runtime: 'binary',
      kind: BuiltinPluginSpec.kindBinary,
      granularity: 'team',
      scope: <String, dynamic>{},
    ),
    // 2026-10-10：SSH 执行器的**中转站**（binary 型）。
    // 2026-10-15 定位重写：中转站 =「处理拓展点位」，SSH 执行因此与工具改写同构——
    // 插件订阅内置点位 `system.relay.ssh.execute`（别名 `ssh.execute`），核心把每次 SSH
    // 操作（建隧道 / 读写 / 命令 / PTY / 心跳）经 `PluginBus.relaySshExecute` 投成一次
    // `station/request`（首选路径：`StationTunnelLink`）。旧的 `tunnel.*` 方法 + hello.capabilities
    // 作为**兼容层保留**（只报能力、不订点位的旧核心仍走 `PluginTunnelLink`），两条复用
    // 同一个 `TunnelSshTransport`，选路任信号命中即认「有中转站」⇒ 热切换两种启动顺序都稳定。
    // 无订阅者 / 心跳丢 / 回包非法 ⇒ fail-open 回退内置 dartssh2（协议见 docs/ssh-tunnel-protocol.md）。
    // `defaultEnabled: true` = 首次随包出现即默认开启（用户 2026-10-10 拍板）。
    BuiltinPluginSpec(
      id: kSshExecutorPluginId,
      name: 'SSH 执行器中转站',
      description:
          'SSH 工作空间的**执行中转站**（随包二进制，不是脚本）：核心经它维护一条常驻 '
          'SSH 通道，把文件读写、命令执行、交互终端转发给目标机上的 `tree_agent`；'
          '目标机上首次使用会自动推送 agent（约 6 MB，按架构选 amd64/arm64）。'
          '隧道断开按退避重连（累计 30 分钟上限）；耗尽后核心**自动回退**内置 dartssh2 '
          '并在日志/右栏明示。关掉它 = 完全回到内置实现（功能不变，只是没有中转站）。',
      script: kSshExecutorBinaryName,
      runtime: 'binary',
      kind: BuiltinPluginSpec.kindBinary,
      granularity: 'team',
      scope: <String, dynamic>{},
      defaultEnabled: true,
    ),
    // 2026-10-15 阶段 3：**框架自迭代插件**（binary 型）。
    // 为什么内置而不是“让用户自己装一个”：这条能力是“框架自己的手柄”（热重启一个插件，
    // 含重启它自己所在的插件），缺了它，“改了插件代码必须手动重启核心”又得回来；
    // 而它**一行核心代码也不新加**：全部能力已经在执行站点位 `system.execute.plugin` 里，
    // 插件只是把一个 agent tool 转发到那六条命令上（其中快照两条不得做成 tool，D9）。
    // `suspension: keep` 是这一条能“重启自己而不丢上下文”的前提：没有它就等于冷启动，
    // 而“自重启”与“重启一下算了”的区别全在这一个字段上。
    BuiltinPluginSpec(
      id: kSelfUpdaterPluginId,
      name: '框架自迭代插件',
      description:
          '把「热重启一个插件（含重启它自己所在的插件）」做成一个 agent tool（随包二进制）：'
          '模型或右栏可以列出插件、看运行阶段、请求转储、热重启（默认尽量续跑）。'
          '重启期间核心照常响应这个插件的站点请求（有界暂存后重放），会话不因此失败；'
          '全部失败都以可读原因收尾，不会把一个插件拖成整个框架。'
          '自检：`tree_self_updater --selftest`（退出码 0 = 七项全绿）。',
      script: kSelfUpdaterBinaryName,
      runtime: 'binary',
      kind: BuiltinPluginSpec.kindBinary,
      granularity: 'team',
      scope: <String, dynamic>{},
      defaultEnabled: true,
      suspension: PluginSuspension.keep,
    ),
  ];

  /// 脚本查找目录的显式覆盖（测试注入；null = 默认的"可执行文件同级 + 开发态回退"）。
  final List<String>? _scriptRoots;

  /// 运行时探测实现（测试注入；null = 真起进程跑 --version）。
  final RuntimeProbe? _probe;

  /// 是否按 Windows 口径探测（测试注入；null = 取 Platform.isWindows）。
  final bool _isWindows;

  /// 可执行文件所在目录（测试注入；null = `Platform.resolvedExecutable` 的目录）。
  ///
  /// 注入的意义：内置脚本的查找优先级里"可执行文件同级 plugins/"与"向上找仓根"
  /// 都以它为起点，不注入就没法在测试里复现"核心跑在构建产物目录下"这个真实布局。
  final String _executableDir;

  /// 单次探测窗口（只是"这个候选能不能用"的诊断窗口，不是插件任务的时长上限）。
  final Duration _probeTimeout;

  final Map<String, BuiltinResolution> _cache = <String, BuiltinResolution>{};
  final Map<String, bool> _probeCache = <String, bool>{};

  /// 按 id 取清单项；不存在返回 null（REST 层据此回可读错误）。
  static BuiltinPluginSpec? specOf(String id) {
    for (final BuiltinPluginSpec spec in specs) {
      if (spec.id == id.trim()) return spec;
    }
    return null;
  }

  /// 随包分发的**内置插件文件名**（脚本名与二进制的两种拼写都收进来）。
  ///
  /// 唯一的读者是发布仓库的校验（`PluginDownloader`）：`plugins/` 里放的是插件**源码与
  /// 随包成品**，而插件管理只从 release 拉成品 —— 一条索引只要把 `files[].target` 写成
  /// `sample_plugin.py`，就能把核心自带的脚本盖掉。那在界面上表现为「示例插件突然起不
  /// 来」，而原因藏在一份远端 JSON 里，是归因最难的一类。
  static Set<String> protectedFileNames({bool? isWindows}) {
    final bool windows = isWindows ?? Platform.isWindows;
    final Set<String> names = <String>{};
    for (final BuiltinPluginSpec spec in specs) {
      names.add(spec.script);
      if (spec.kind == BuiltinPluginSpec.kindBinary) {
        names.add(binaryFileName(spec, isWindows: windows));
      }
    }
    return names;
  }

  /// 解析某项的运行时与脚本（结果缓存；[refresh] = 强制重探）。
  Future<BuiltinResolution> resolve(
    BuiltinPluginSpec spec, {
    bool refresh = false,
  }) async {
    if (!refresh) {
      final BuiltinResolution? cached = _cache[spec.id];
      if (cached != null) return cached;
    }
    final List<String> roots = scriptRoots();
    if (spec.kind == BuiltinPluginSpec.kindBinary) {
      // binary 型：**不做运行时探测**（没有 Python 可探的东西），只解析可执行文件。
      // 沿用同一条"解析失败给可读错误"的口径：静默失败在界面上就是"点了开关没反应"。
      final String? binary = findBinary(spec, roots, isWindows: _isWindows);
      if (binary == null) {
        return _cache[spec.id] = BuiltinResolution.failed(
          '找不到内置插件可执行文件 ${binaryFileName(spec, isWindows: _isWindows)}'
          '（依次查找：${roots.join('；')}）。'
          '发行包应当把 ${spec.script} 放在可执行文件同级的 plugins/ 目录'
          '（tool/package_windows.dart 已包含这一步）；开发态请先跑 tool/ 下'
          '对应的 build_*.dart 产出到仓根 build/plugins/。',
          searchedScriptRoots: roots,
        );
      }
      return _cache[spec.id] = BuiltinResolution.ok(
        command: binary,
        prefixArgs: const <String>[],
        scriptPath: '',
        searchedScriptRoots: roots,
      );
    }
    final String? script = findScript(spec, roots);
    if (script == null) {
      return _cache[spec.id] = BuiltinResolution.failed(
        '找不到内置插件脚本 ${spec.script}（依次查找：${roots.join('；')}）。'
        '发行包应当把 examples/plugins 复制到可执行文件同级的 plugins/ 目录'
        '（打包脚本 tool/package_windows.dart 已包含这一步）；'
        '开发态则会自动向上定位仓根再查 examples/plugins。',
        searchedScriptRoots: roots,
      );
    }
    final BuiltinRuntime? runtime = await _resolveRuntime();
    if (runtime == null) {
      return _cache[spec.id] = BuiltinResolution.failed(
        _runtimeMissingMessage(),
        searchedScriptRoots: roots,
      );
    }
    return _cache[spec.id] = BuiltinResolution.ok(
      command: runtime.command,
      prefixArgs: runtime.prefixArgs,
      scriptPath: script,
      searchedScriptRoots: roots,
    );
  }

  /// 生成一条**普通插件配置**（内置插件开关的落盘形态）。
  ///
  /// [enabled] = false 时只改开关（条目保留，面板显示「已停用」）。
  static Map<String, dynamic> entryFor(
    BuiltinPluginSpec spec,
    BuiltinResolution resolution, {
    bool enabled = true,
  }) => <String, dynamic>{
    'id': spec.id,
    'name': spec.name,
    'command': resolution.command,
    // binary 型没有脚本参数（scriptPath 为空）⇒ **不要**塞一个空串进去
    // （那样落盘就是 `args: [""]`，插件进程会拿到一个空参数）。
    'args': <String>[
      ...resolution.prefixArgs,
      if (resolution.scriptPath.isNotEmpty) resolution.scriptPath,
    ],
    'env': <String, String>{},
    'enabled': enabled,
    'granularity': spec.granularity,
    'scope': spec.scope,
    // 可挂起声明只在**非空**时写：留空也写就是给配置文件多一个无意义的键，
    // 而「用户看到的键」应当只包含真正影响行为的声明（与不变量 10「保留未知键」同一纪律）。
    if (spec.suspension.isNotEmpty) 'suspension': spec.suspension,
    // 标记：UI 据此把这一条分到「内置」组（内置插件不给删除，只给停用）
    'builtin': true,
  };

  /// 脚本查找目录（按优先级）。
  ///
  /// 1. 核心可执行文件同级的 `plugins/`（**发行包的正规位置**：Tree.exe /
  ///    tree_core.exe 与 plugins/ 同级）；
  /// 2. **仓根**的 `build/plugins/`（开发态的构建产物，`tool/build_ssh_plugin.dart` 的落点）;
  /// 3. **仓根**的 `examples/plugins/`（开发态回退，见 [repoRoot]）；
  /// 4. 当前工作目录下的 `plugins/`、`build/plugins/`、`examples/plugins/`（`dart run` 时的兜底）。
  ///
  /// 为什么第 2/3 条必须**锚定仓根**而不是相对 cwd：桌面壳是以**自己所在目录**为
  /// 工作目录拉起核心的，所以跑 Debug 构建时 cwd 是
  /// `build/windows/x64/runner/Debug`（该目录下没有 plugins/，Debug 产物也不复制），
  /// 于是"相对 cwd 的回退"一个都命中不了，内置示例插件在面板上就变成
  /// 「找不到内置插件脚本」。锚定仓根后，无论从哪个构建目录、哪个 cwd 启动都能找到。
  List<String> scriptRoots() {
    final List<String>? explicit = _scriptRoots;
    if (explicit != null) return List<String>.unmodifiable(explicit);
    final String exeDir = _executableDir;
    final String cwd = Directory.current.path;
    final String? repo = repoRoot(exeDir);
    return <String>[
      p.join(exeDir, 'plugins'),
      // 开发态的**构建产物**（`tool/build_ssh_plugin.dart` / `build_agent.dart` 的落点）：
      // 打了包就走上面那条（发行目录 plugins/），没打包时从这里读，免得开发时必须
      // 手动把二进制搬到 exe 同级。
      if (repo != null) p.join(repo, 'build', 'plugins'),
      if (repo != null) p.join(repo, 'examples', 'plugins'),
      p.join(cwd, 'plugins'),
      p.join(cwd, 'build', 'plugins'),
      p.join(cwd, 'examples', 'plugins'),
    ];
  }

  /// 从可执行文件所在目录向上找**仓根**（含 `packages/tree_core` 的那一层）。
  ///
  /// 找到返回绝对路径，找不到返回 null（发行包就是这种情况：可执行文件不在仓库里）。
  /// 向上层数设上限，避免在异常路径上无限回溯（软链接 / 根目录）。
  static String? repoRoot(String startDir) {
    Directory dir = Directory(p.absolute(startDir));
    for (int depth = 0; depth < 8; depth++) {
      final bool looksLikeRepo = Directory(
        p.join(dir.path, 'packages', 'tree_core'),
      ).existsSync();
      if (looksLikeRepo) return dir.path;
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break; // 到根了
      dir = parent;
    }
    return null;
  }

  /// 在目录里找脚本文件（返回第一个存在的绝对路径；都不存在返回 null）。
  static String? findScript(BuiltinPluginSpec spec, List<String> roots) {
    for (final String root in roots) {
      final String candidate = p.join(root, spec.script);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// binary 型插件的**目标文件名**（Windows 补 `.exe`）。
  static String binaryFileName(
    BuiltinPluginSpec spec, {
    required bool isWindows,
  }) {
    final String base = spec.script.endsWith('.exe')
        ? spec.script.substring(0, spec.script.length - 4)
        : spec.script;
    return isWindows ? '$base.exe' : base;
  }

  /// 在目录里找**可执行文件**（返回第一个存在的绝对路径；都不存在返回 null）。
  ///
  /// 为什么 Windows 上也接受"不带 `.exe`"的名字：开发态可能是无扩展名的交叉编译产物
  /// （`dart compile exe --target-os=linux`），而 `.exe` 优先保证发行包/自机构建优先命中。
  static String? findBinary(
    BuiltinPluginSpec spec,
    List<String> roots, {
    required bool isWindows,
  }) {
    final List<String> names = <String>[
      binaryFileName(spec, isWindows: isWindows),
      if (isWindows) spec.script, // 兜底：无扩展名
    ];
    for (final String root in roots) {
      for (final String name in names) {
        final String candidate = p.join(root, name);
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  /// 清掉缓存（测试用；也让"我刚装了 Python"能立刻被下一次解析看到）。
  void clearCache() {
    _cache.clear();
    _probeCache.clear();
  }

  /// 探测本机可用的 Python 解释器（没有 = null）。
  ///
  /// 为什么公开：发布仓库里一条 `runtime: python` 的条目在**装之前**就要回答
  /// “这台机器拉得起它吗”。写一条注定起不来的配置比不装更糟（面板上会多一个
  /// 永远“启动失败”的条目），所以安装方要用与内置插件**同一个**探测口径，而不是
  /// 自己再拼一套 `which python`。
  Future<BuiltinRuntime?> detectRuntime() => _resolveRuntime();

  // ── 内部 ─────────────────────────────────────────────────────────────

  /// 候选运行时（Windows 先 python 再 py -3；其他平台先 python3 再 python）。
  ///
  /// Windows 上把 python 排在 py 之前，是因为 py.exe 只是启动器，py -3 仍可能
  /// 指向另一个解释器；直接命中 python 更符合用户"我装了 Python"的预期。
  List<BuiltinRuntime> _candidates() => _isWindows
      ? const <BuiltinRuntime>[
          BuiltinRuntime('python'),
          BuiltinRuntime('py', <String>['-3']),
        ]
      : const <BuiltinRuntime>[
          BuiltinRuntime('python3'),
          BuiltinRuntime('python'),
        ];

  Future<BuiltinRuntime?> _resolveRuntime() async {
    for (final BuiltinRuntime candidate in _candidates()) {
      if (await _usable(candidate)) return candidate;
    }
    return null;
  }

  Future<bool> _usable(BuiltinRuntime runtime) async {
    final String key = runtime.label;
    final bool? cached = _probeCache[key];
    if (cached != null) return cached;
    final RuntimeProbe? injected = _probe;
    bool ok = false;
    if (injected != null) {
      ok = await injected(runtime.command, runtime.prefixArgs);
    } else {
      ok = await _probeVersion(runtime);
    }
    _probeCache[key] = ok;
    return ok;
  }

  /// 默认探测：跑 --version，退出码 0 视为可用。
  ///
  /// 只看退出码、不看输出：Windows 上 python 的版本号走 stdout、部分发行版走
  /// stderr，认输出容易误判；而"命令跑得起来且正常退出"才是这里要的结论。
  /// Windows 的 Microsoft Store 占位 python.exe 会以非 0 退出（并提示去商店安装），
  /// 因此不会被误判成"已安装"。
  Future<bool> _probeVersion(BuiltinRuntime runtime) async {
    try {
      final ProcessResult result = await Process.run(runtime.command, <String>[
        ...runtime.prefixArgs,
        '--version',
      ]).timeout(_probeTimeout);
      return result.exitCode == 0;
    } catch (_) {
      // 命令不存在 / 起不来 / 超时：都算"这个候选不可用"，继续试下一个
      return false;
    }
  }

  String _runtimeMissingMessage() {
    final String tried = _candidates()
        .map((BuiltinRuntime r) => r.label)
        .join(' / ');
    return '未检测到 Python 运行时（依次尝试：$tried）。'
        '请先安装 Python 并确保它在 PATH 中，或改用「添加插件」写自定义命令。';
  }
}

/// 播种「默认开启」的内置插件条目（`defaultEnabled: true` 且**从未落盘过**的那些）。
///
/// 语义（用户 2026-10-10 拍板：「默认开（升级即生效）」）刻意收得很紧：
/// - **只处理"`plugins.yaml` 里根本没有这一条"**的情况。用户显式关过（条目在、
///   `enabled: false`）就**绝不再自动打开** —— 否则就是"帮用户改回他自己关掉的东西"；
/// - 解析不出来（缺二进制 / 缺 Python）⇒ **只记日志、不落盘**：装不上就不该在清单里
///   留一条永远起不来的条目（那只会让面板多一个"打开失败"）；
/// - **幂等**：重复调用没有副作用（已存在就跳过）。
///
/// 返回本次真正播种的 id 列表（空列表 = 什么都没做）。
Future<List<String>> seedDefaultEnabledBuiltins({
  required BuiltinPluginCatalog catalog,
  required PluginConfigStore store,
  void Function(String message)? log,
}) async {
  final List<String> seeded = <String>[];
  for (final BuiltinPluginSpec spec in BuiltinPluginCatalog.specs) {
    if (!spec.defaultEnabled) continue;
    if (store.readEntry(spec.id) != null) continue; // 已落盘（开或关）⇒ 尊重现状
    final BuiltinResolution resolution = await catalog.resolve(spec);
    if (!resolution.ok) {
      log?.call('内置插件 ${spec.id} 默认开启但解析失败（跳过播种）：${resolution.error}');
      continue;
    }
    final PluginStoreResult result = store.upsert(
      BuiltinPluginCatalog.entryFor(spec, resolution, enabled: true),
    );
    if (result.ok) {
      seeded.add(spec.id);
    } else {
      log?.call('内置插件 ${spec.id} 播种失败：${result.error}');
    }
  }
  return seeded;
}

/// **内置插件换代迁移**：清单已经把某一项换成随包二进制，而磁盘上那条还是老一代的
/// 解释器命令（`python` + `…/compact_plugin.py`）时，启动期把它重写掉。
///
/// 为什么必须做在启动期而不是等用户拨开关：`plugins.yaml` 里存的是**解析后的**
/// command/args（见 [BuiltinPluginCatalog.entryFor]），只有面板开关才会重写。清单一改，
/// 老条目仍指向那个已经不在包里的 `.py`——表现是“上下文压缩突然起不来”，而配置
/// 看上去完全正常，归因要穿过落盘配置、打包清单、发布索引三处。
///
/// 四条口径都是“少改”而不是“改全”：
/// - 只动 `builtin: true` 的条目（用户自己写的同 id 条目不是我们的事）；
/// - 只处理**清单已是 binary** 的这一代：python→python 的重写会白白触发解释器探测
///   （开机多起两个进程），而那条路由面板开关服务已经够了；
/// - 命令名已经是目标二进制 ⇒ 什么都不做（**幂等**：每次启动都跑，不能每次改文件）；
/// - 解析失败 ⇒ 保持现状并留一行（改坏比不改更糟）。
///
/// 迁移的是**命令**：用户的 `enabled` 与 `env` 原样保留（不该因为换运行时就被
/// 重新打开，也不该丢掉他手加的环境变量）。
Future<List<String>> migrateBuiltinEntries({
  required BuiltinPluginCatalog catalog,
  required PluginConfigStore store,
  void Function(String message)? log,
  bool? isWindows,
}) async {
  final bool windows = isWindows ?? Platform.isWindows;
  final List<String> migrated = <String>[];
  for (final BuiltinPluginSpec spec in BuiltinPluginCatalog.specs) {
    if (spec.kind != BuiltinPluginSpec.kindBinary) continue;
    final Map<String, dynamic>? stored = store.readEntry(spec.id);
    if (stored == null || stored['builtin'] != true) continue;
    final String want = BuiltinPluginCatalog.binaryFileName(
      spec,
      isWindows: windows,
    );
    final String storedCommand = '${stored['command'] ?? ''}';
    if (storedCommand.isNotEmpty &&
        p.basename(storedCommand.replaceAll('\\', '/')) == want) {
      continue; // 已经是这一代
    }
    final BuiltinResolution resolution = await catalog.resolve(spec);
    if (!resolution.ok) {
      log?.call('内置插件 ${spec.id} 换代跳过（解析不到 $want，保持现状）：${resolution.error}');
      continue;
    }
    final Map<String, dynamic> fresh = BuiltinPluginCatalog.entryFor(
      spec,
      resolution,
      enabled: stored['enabled'] != false,
    );
    final Object? env = stored['env'];
    if (env is Map && env.isNotEmpty) {
      fresh['env'] = env.map(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>('$key', '$value'),
      );
    }
    final PluginStoreResult result = store.upsert(fresh);
    if (!result.ok) {
      log?.call('内置插件 ${spec.id} 换代写入失败：${result.error}');
      continue;
    }
    migrated.add(spec.id);
    log?.call(
      '内置插件 ${spec.id} 已从「${storedCommand.isEmpty ? '空命令' : storedCommand}」'
      '换到随包二进制 ${resolution.command}',
    );
  }
  return migrated;
}
