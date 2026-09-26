import 'dart:io';

import 'package:path/path.dart' as p;

/// 内置插件的**静态清单**（M9 §4.2：内置插件与自定义插件都要能在前端开/关）。
///
/// 为什么清单在核心而不是前端：内置插件的"身份"必须由核心认定——前端只拿到
/// id + 名称 + 说明 + 开关状态，具体要拉起什么命令、脚本在哪，全部由核心在
/// **打开的那一刻**解析（见 [BuiltinPluginCatalog.resolve]）：
/// - 运行时：Windows 依次探测 python / py -3；其他平台 python3 / python；
/// - 脚本：核心可执行文件同级的 `plugins/<name>.py`（发行包里由
///   tool/package_windows.dart 把 examples/plugins 复制到那里）。
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
    this.granularity = 'team',
    this.scope = const <String, dynamic>{},
  });

  /// 插件 id（也是落盘条目的 id；面板用它做开关）。
  final String id;

  /// 展示名。
  final String name;

  /// 说明（面板上给用户看的"这是什么、怎么用"）。
  final String description;

  /// 脚本文件名（相对 plugins/ 目录；不含路径分隔符）。
  final String script;

  /// 所需运行时的可读名字（如 python）。
  final String runtime;

  /// 默认实例粒度（team / agent / session）。
  final String granularity;

  /// 默认 scope（空 Map = 通配：不进站点体系，工具走 tools/list 申报路径）。
  final Map<String, dynamic> scope;

  /// 给前端的内置插件说明（config / enabled / resolution 由核心在响应里补）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'script': script,
    'runtime': runtime,
    'granularity': granularity,
    'scope': scope,
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
    this._probeTimeout = const Duration(seconds: 5),
  }) : _isWindows = isWindows ?? Platform.isWindows;

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
  ];

  /// 脚本查找目录的显式覆盖（测试注入；null = 默认的"可执行文件同级 + 开发态回退"）。
  final List<String>? _scriptRoots;

  /// 运行时探测实现（测试注入；null = 真起进程跑 --version）。
  final RuntimeProbe? _probe;

  /// 是否按 Windows 口径探测（测试注入；null = 取 Platform.isWindows）。
  final bool _isWindows;

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
    final String? script = findScript(spec, roots);
    if (script == null) {
      return _cache[spec.id] = BuiltinResolution.failed(
        '找不到内置插件脚本 ${spec.script}（依次查找：${roots.join('；')}）。'
        '发行包应当把 examples/plugins 复制到可执行文件同级的 plugins/ 目录'
        '（打包脚本 tool/package_windows.dart 已包含这一步）。',
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
    'args': <String>[...resolution.prefixArgs, resolution.scriptPath],
    'env': <String, String>{},
    'enabled': enabled,
    'granularity': spec.granularity,
    'scope': spec.scope,
    // 标记：UI 据此把这一条分到「内置」组（内置插件不给删除，只给停用）
    'builtin': true,
  };

  /// 脚本查找目录（按优先级）。
  ///
  /// 1. 核心可执行文件同级的 plugins/（**发行包的正规位置**：Tree.exe / tree_core.exe
  ///    与 plugins/ 同级）；
  /// 2. 当前工作目录下的 plugins/、examples/plugins/（**开发态回退**：dart run 时
  ///    可执行文件是 SDK 里的 dart.exe，同级没有 plugins/，不兜这两层就没法在仓库里试）。
  List<String> scriptRoots() {
    final List<String>? explicit = _scriptRoots;
    if (explicit != null) return List<String>.unmodifiable(explicit);
    final String exeDir = p.dirname(Platform.resolvedExecutable);
    final String cwd = Directory.current.path;
    return <String>[
      p.join(exeDir, 'plugins'),
      p.join(cwd, 'plugins'),
      p.join(cwd, 'examples', 'plugins'),
    ];
  }

  /// 在目录里找脚本文件（返回第一个存在的绝对路径；都不存在返回 null）。
  static String? findScript(BuiltinPluginSpec spec, List<String> roots) {
    for (final String root in roots) {
      final String candidate = p.join(root, spec.script);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 清掉缓存（测试用；也让"我刚装了 Python"能立刻被下一次解析看到）。
  void clearCache() {
    _cache.clear();
    _probeCache.clear();
  }

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
