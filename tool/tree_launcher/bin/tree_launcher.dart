import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_launcher/src/criterion.dart';
import 'package:tree_launcher/src/handshake.dart';

/// Tree 引导启动器（**纯 Dart，不依赖 Flutter**）。
///
/// 职责只有一个：判断"当前是否存在可用的管理界面"，没有就拉起/附着核心并打开
/// `/bootstrap?t=<ticket>`；有就只做控制台菜单（重签票据 / 数据目录 / 日志 / 退出）。
///
/// 已知差距：本期不做 Windows 托盘图标（需要 Win32 FFI 或第三方包）。
/// 品牌落地只做快捷方式 `IconLocation`（见 [_applyShortcutBranding]），
/// **绝不改写任何 exe 的 PE 资源**。
Future<void> main(List<String> args) async {
  final Launcher launcher = Launcher();
  final int code = await launcher.run();
  exit(code);
}

class Launcher {
  static const String _exeName = 'tree_core.exe';
  static const String _envUrl = 'TREE_CORE_URL';
  static const String _envToken = 'TREE_CORE_TOKEN';
  static const String _envExe = 'TREE_CORE_EXE';
  static const String _envDataRoot = 'TREE_DATA_ROOT';
  static const Duration _handshakeTimeout = Duration(seconds: 20);
  static const Duration _shutdownGrace = Duration(seconds: 3);

  /// 判据轮询：间隔 / 总预算 / 清单“稳定”计数。
  ///
  /// 预算 8s 的依据：核心的预热预算只有 3s（`boot_warmup.dart`），预算外的任务会继续
  /// 后台跑；8s 足够覆盖“播种 → 起界面”的正常路径，又不会让真的没有界面的用户在
  /// 双击后干等太久（那一档最多等 8s 就开引导页）。
  static const Duration _probeInterval = Duration(milliseconds: 250);
  static const Duration _probeBudget = Duration(seconds: 8);

  /// 连续多少次读到**非空清单**仍没有启用中的 ui，才认“确实没有界面”。
  /// 6 次 × 250ms ≈ 1.5s：远大于“播种内置插件 → 登记界面 → start()”之间的间隔，
  /// 又远小于用户能感知的等待。
  static const int _settleStreak = 6;

  final HttpClient _http = HttpClient();
  Process? _process;
  MinimalHandshake? _core;

  /// 界面插件生命周期监视（控制台菜单期间每 [_uiWatchInterval] 读一次快照）。
  Timer? _watch;

  /// 上一次读数里「是否存在启用中的界面插件」。
  ///
  /// 只靠它判**跃迁**（up→down 开引导页 / down→up 提示就绪）：没有跃迁就不动作，
  /// 避免核心预热期读到空清单时把“还没播种”误当成“界面被停用”。
  bool _uiUp = false;

  static const Duration _uiWatchInterval = Duration(seconds: 3);

  Future<int> run() async {
    try {
      _core = await _connect();
    } catch (error) {
      stderr.writeln('[launcher] 无法连接核心：$error');
      return 1;
    }
    _printBanner();
    await _evaluateAndOpen();
    await _applyShortcutBranding();
    _startUiWatch();
    return _menuLoop();
  }

  // ── 连接核心 ─────────────────────────────────────────────────────────

  Future<MinimalHandshake> _connect() async {
    _http.connectionTimeout = const Duration(seconds: 3);
    final String url = Platform.environment[_envUrl] ?? '';
    final String token = Platform.environment[_envToken] ?? '';
    if (url.isNotEmpty && token.isNotEmpty) {
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) {
        throw StateError('$_envUrl 不是合法 URL：$url');
      }
      stdout.writeln('[launcher] 附着已有核心 $url');
      return MinimalHandshake(
        host: uri.host,
        port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
        token: token,
        dataRoot: Platform.environment[_envDataRoot] ?? '',
      );
    }

    // **先找已经在跑的核心**：核心是单实例，重复双击必须附着而不是再起一个。
    // 不这么做的后果（2026-11-01 实测）：每次双击都新起一个 `tree_core.exe`，
    // 每个核心各自拉起一套插件与界面窗口、并发写同一份数据根，任务栏上还多出
    // 几个控制台窗口。判据是核心写的 `runtime/core.json` + 一次 `/api/meta` 探测。
    final MinimalHandshake? running = await _discoverRunningCore();
    if (running != null) {
      stdout.writeln(
        '[launcher] 附着已有核心 ${running.httpBaseUrl}（pid=${running.pid}）',
      );
      return running;
    }

    final String? exe = _resolveCoreExecutable();
    if (exe == null) {
      throw StateError('找不到核心可执行文件（可用 $_envExe 指定）');
    }
    stdout.writeln('[launcher] 拉起核心 $exe');
    final Process process = await Process.start(
      exe,
      const <String>[],
      mode: ProcessStartMode.normal,
    );
    _process = process;
    final Completer<MinimalHandshake> completer = Completer<MinimalHandshake>();
    // stdout 是握手协议：ready 行交给启动器，其余按日志转到 stderr，
    // 绝不能混进启动器自己的 stdout（控制台菜单要可读）。
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) {
            if (line.trim().isEmpty) return;
            final MinimalHandshake? decoded = MinimalHandshake.decode(line);
            if (decoded != null) {
              if (!completer.isCompleted) completer.complete(decoded);
              return;
            }
            stderr.writeln('[core] $line');
          },
          onError: (Object error) {
            if (!completer.isCompleted) {
              completer.completeError(StateError('读取核心 stdout 失败：$error'));
            }
          },
        );
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          if (line.trim().isEmpty) return;
          stderr.writeln('[core:err] $line');
        });
    process.exitCode.then((int code) {
      if (_process != null) {
        stderr.writeln('[launcher] 核心已退出（$code）');
        _process = null;
      }
    });

    final MinimalHandshake handshake = await completer.future.timeout(
      _handshakeTimeout,
      onTimeout: () => throw StateError('等待核心握手超时（${_handshakeTimeout.inSeconds}s）'),
    );
    stdout.writeln(
      '[launcher] 核心已就绪：v${handshake.version} pid=${handshake.pid} '
      '${handshake.httpBaseUrl}',
    );
    return handshake;
  }

  String? _resolveCoreExecutable() {
    final String override = Platform.environment[_envExe] ?? '';
    if (override.isNotEmpty) {
      return File(override).existsSync() ? override : null;
    }
    final Directory appDir = File(Platform.resolvedExecutable).parent;
    final File packaged = File(_join(appDir.path, _exeName));
    if (packaged.existsSync()) return packaged.path;
    Directory? cursor = appDir;
    for (int depth = 0; depth < 8 && cursor != null; depth++) {
      final File candidate = File(_join(_join(cursor.path, '.output'), _exeName));
      if (candidate.existsSync()) return candidate.path;
      cursor = cursor.parent;
    }
    return null;
  }

  // ── 找已经在跑的核心（单实例） ────────────────────────────────────────

  /// 数据根的 **loader 侧**解析（口径与核心 `TreePaths.resolve` 一致）。
  ///
  /// 核心只认 `--data-dir` / `TREE_HOME` / 平台默认；loader 另外支持
  /// `TREE_DATA_ROOT`（它拉起核心时会给的那一个），故这里按同一优先级解析。
  /// 找不到核心时也只能按这套规则猜——这是唯一能知道"核心把 runtime/core.json
  /// 写在哪"的途径（拉起核心时不传 `--data-dir`）。
  String _dataRootGuess() {
    final String explicit = (Platform.environment[_envDataRoot] ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    final String treeHome = (Platform.environment['TREE_HOME'] ?? '').trim();
    if (treeHome.isNotEmpty) return treeHome;
    if (Platform.isWindows) {
      final String appData = (Platform.environment['APPDATA'] ?? '').trim();
      if (appData.isNotEmpty) return _join(appData, 'Tree');
      final String profile = (Platform.environment['USERPROFILE'] ?? '').trim();
      if (profile.isNotEmpty) return _join(profile, '.tree');
      return _join(Directory.systemTemp.path, 'Tree');
    }
    final String home = (Platform.environment['HOME'] ?? '').trim();
    if (Platform.isMacOS) {
      return home.isEmpty
          ? _join(Directory.systemTemp.path, 'Tree')
          : _join(_join(home, 'Library'), 'Application Support/Tree');
    }
    final String xdg = (Platform.environment['XDG_DATA_HOME'] ?? '').trim();
    if (xdg.isNotEmpty) return _join(xdg, 'tree');
    return home.isEmpty
        ? _join(Directory.systemTemp.path, 'tree')
        : _join(_join(home, '.local'), 'share/tree');
  }

  /// 读核心的实例发现文件并探测它是否真的活着。
  ///
  /// 只信文件不够（硬杀会留下陈旧记录），只信端口也不够（端口会被别的进程复用）；
  /// 所以必须用记录里的 token 打通一次 `/api/meta`。任何失败都返回 null ⇒ 调用方
  /// 新起一个核心（新核心自己的单实例闸门会再探测一次并清理陈旧记录）。
  Future<MinimalHandshake?> _discoverRunningCore() async {
    final File file = File(
      _join(_join(_dataRootGuess(), 'runtime'), 'core.json'),
    );
    if (!file.existsSync()) return null;
    Map<String, dynamic>? data;
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    if (data == null) return null;
    final int port = (data['port'] as num?)?.toInt() ?? 0;
    final String token = (data['token'] ?? '').toString();
    if (port <= 0 || token.isEmpty) return null;
    final String host = (data['host'] ?? '').toString().trim();
    final String probeHost = host.isEmpty ? '127.0.0.1' : host;
    if (!await _probeAlive('http://$probeHost:$port', token)) return null;
    return MinimalHandshake(
      host: probeHost,
      port: port,
      token: token,
      pid: (data['pid'] as num?)?.toInt() ?? 0,
      version: (data['version'] ?? '').toString(),
      dataRoot: (data['data_root'] ?? '').toString(),
    );
  }

  /// 用给定 token 打一次 `/api/meta`：200 才算“活着”。
  Future<bool> _probeAlive(String baseUrl, String token) async {
    try {
      final HttpClientRequest request = await _http.getUrl(
        Uri.parse('$baseUrl/api/meta'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  // ── 判据 + 打开引导页 ─────────────────────────────────────────────────

  Future<void> _evaluateAndOpen() async {
    final _BootstrapProbe probe = await _probeBootstrap();
    if (!probe.ready) {
      stdout.writeln(
        '[launcher] 读不到插件清单（核心可能仍在预热），本次不打开引导页。',
      );
      return;
    }
    if (!probe.needsBootstrap) {
      stdout.writeln('[launcher] 存在启用中的界面插件，不开引导页。');
      _uiUp = probe.enabledUiIds.isNotEmpty;
      await _ensureUiWindow(probe.enabledUiIds);
      return;
    }
    stdout.writeln('[launcher] 没有启用中的界面插件，打开引导页。');
    _uiUp = false;
    await _openBootstrap();
  }

  /// 菜单期间**持续**盯界面插件（轮询 [snapshot]）。
  ///
  /// 判据此前只在启动时评一次，于是：
  /// - 中途停用了界面插件 ⇒ 桌面空了，但没人再开引导页（用户 2026-11-01 报过）；
  /// - 界面重新启用 ⇒ 引导页不知道，只能用户自己关。
  ///
  /// 这里做两件事，且**只在跃迁时动作**：
  /// - up → down：打一行说明并重开引导页（让用户有地方管理插件）；
  /// - down → up：打一行“界面已就绪”（引导页自己也会尝试 `window.close()`）。
  ///
  /// 没有跃迁就不动：核心预热期读到空清单是合法状态，不能把它当“被停用”。
  void _startUiWatch() {
    _watch?.cancel();
    _watch = Timer.periodic(_uiWatchInterval, (_) => _checkUiWatch());
  }

  Future<void> _checkUiWatch() async {
    try {
      final Map<String, dynamic>? data = await _getJson('/api/plugin/snapshot');
      if (!snapshotReady(data)) return;
      final bool up = enabledUiPluginIdsOf(data).isNotEmpty;
      if (up) {
        if (_uiUp) return;
        _uiUp = true;
        stdout.writeln(
          '[launcher] 界面插件已启用，界面应已接管（引导页可关闭）。',
        );
        return;
      }
      if (!_uiUp) return;
      _uiUp = false;
      stdout.writeln('[launcher] 界面插件已停用或移除，重新打开引导页。');
      await _openBootstrap();
    } catch (_) {
      // 核心正忙 / 正在重启：下一拍再看，不打断菜单。
    }
  }

  /// 轮询 `/api/plugin/snapshot` 直到能下结论。
  ///
  /// **为什么不能“读到 `config.plugins[]` 就下结论”**（2026-11-01 实测）：核心的握手
  /// 先于预热发出，随后才「迁移 → 播种内置 → 登记默认界面 → `plugins.start()`」。
  /// 握手后立刻读到的快照里，`config.plugins` 可能还是空的**合法数组**，判据于是把
  /// “还没播种”误读成“没有启用中的界面插件”：浏览器打开了引导页，桌面上界面其实
  /// 也起来了（两者同时出现）。
  ///
  /// 所以判据分两段：
  /// 1. 一旦出现启用中的 `runtime: ui` ⇒ 立刻定论（不开引导页）；
  /// 2. 没有的话，要**看到清单已稳定**（连续 [_settleStreak] 次读到非空清单且始终
  ///    没有 ui）才认“确实没有”，最多等到 [_probeBudget]；预算用尽仍读不到清单
  ///    ⇒ [ready] 为 false，**不做判断**。
  Future<_BootstrapProbe> _probeBootstrap() async {
    final Stopwatch watch = Stopwatch()..start();
    bool sawReady = false;
    int nonEmptyStreak = 0;
    while (watch.elapsed < _probeBudget) {
      try {
        final Map<String, dynamic>? data = await _getJson(
          '/api/plugin/snapshot',
        );
        if (snapshotReady(data)) {
          sawReady = true;
          final Set<String> ids = enabledUiPluginIdsOf(data);
          if (ids.isNotEmpty) {
            return _BootstrapProbe(
              ready: true,
              needsBootstrap: false,
              enabledUiIds: ids,
            );
          }
          nonEmptyStreak = parsePluginConfigs(data).isEmpty
              ? 0
              : nonEmptyStreak + 1;
          if (nonEmptyStreak >= _settleStreak) {
            return _BootstrapProbe(
              ready: true,
              needsBootstrap: needsBootstrapByConfig(data),
              enabledUiIds: const <String>{},
            );
          }
        }
      } catch (_) {
        // 核心 HTTP 还没起来：继续等。
      }
      await Future<void>.delayed(_probeInterval);
    }
    if (!sawReady) return const _BootstrapProbe.unready();
    return const _BootstrapProbe(
      ready: true,
      needsBootstrap: true,
      enabledUiIds: <String>{},
    );
  }

  /// 有启用的界面插件但**一个窗口都没有**时，补发一次冷重启。
  ///
  /// 为什么 loader 要管这件事：核心按清单拉起界面是正常路径，但“界面启动即崩”
  /// （比如被别的进程锁住文件、用户改坏了 command）会让用户对着空桌面无从下手；
  /// 这里补一次拉起，失败原因照样由核心记日志、控制台也留一行。
  Future<void> _ensureUiWindow(Set<String> uiPluginIds) async {
    if (uiPluginIds.isEmpty) return;
    // 判据看到的是**配置**：配置里刚出现 ui 的那一刻，核心可能才刚开始 spawn。
    // 这里先给 5s 观察窗，确认“真没有活着的窗口”才冷重启 —— 否则会把一个正在
    // 起的界面又拉一次（两个窗口、同一窗口 id，用户看到两份一样的界面）。
    bool alive = false;
    for (int attempt = 0; attempt < 20; attempt++) {
      try {
        final Map<String, dynamic>? windows = await _getJson(
          '/api/plugin/windows',
        );
        final Object? list = windows?['windows'];
        if (list is List) {
          for (final Object? item in list) {
            if (item is Map && item['alive'] == true) {
              alive = true;
              break;
            }
          }
        }
      } catch (error) {
        stderr.writeln('[launcher] 读取界面窗口失败（仍会尝试拉起）：$error');
        break;
      }
      if (alive) return;
      await Future<void>.delayed(_probeInterval);
    }
    if (alive) return;
    for (final String id in uiPluginIds) {
      try {
        await _postJson(
          '/api/plugin/configs/${Uri.encodeComponent(id)}/restart',
          <String, dynamic>{},
        );
        stdout.writeln('[launcher] 已请求拉起界面插件：$id');
      } catch (error) {
        stderr.writeln('[launcher] 拉起界面插件 $id 失败：$error');
      }
    }
  }

  Future<void> _openBootstrap() async {
    try {
      final Map<String, dynamic>? data = await _postJson(
        '/api/bootstrap/ticket',
        <String, dynamic>{},
      );
      final String ticket = (data?['ticket'] ?? '').toString();
      if (ticket.isEmpty) {
        stderr.writeln('[launcher] 申请引导票据失败：响应缺少 ticket');
        return;
      }
      final String url = '${_core!.httpBaseUrl}/bootstrap?t=$ticket';
      stdout.writeln('[launcher] 引导页：$url');
      await _openInBrowser(url);
    } catch (error) {
      stderr.writeln('[launcher] 打开引导页失败：$error');
    }
  }

  Future<void> _openInBrowser(String url) async {
    if (Platform.isWindows) {
      await Process.start(
        'cmd',
        <String>['/c', 'start', '', url],
        runInShell: true,
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isMacOS) {
      await Process.start('open', <String>[url]);
    } else {
      await Process.start('xdg-open', <String>[url]);
    }
  }

  /// 品牌落地：只更新启动器旁的 `Tree.lnk` 的 `IconLocation`。
  ///
  /// - **绝不改写任何 exe 的 PE 资源**（图标是 Windows 快捷方式的属性）；
  /// - 图标缺失 / 非 `.ico` ⇒ 把 `IconLocation` 清空，回默认图标；
  /// - 非 Windows 平台直接跳过。
  Future<void> _applyShortcutBranding() async {
    if (!Platform.isWindows) return;
    String? icon;
    try {
      icon = shortcutIconOf(await _getJson('/api/meta'));
    } catch (error) {
      stderr.writeln('[launcher] 读取品牌失败：$error');
      return;
    }
    if (icon != null && !File(icon).existsSync()) {
      stderr.writeln('[launcher] 品牌图标不存在，回默认：$icon');
      icon = null;
    }
    final String launcherPath = Platform.resolvedExecutable;
    final String shortcut = _join(
      File(launcherPath).parent.path,
      'Tree.lnk',
    );
    final String iconLocation = icon == null ? '' : '$icon,0';
    String q(String s) => s.replaceAll("'", "''");
    final String script =
        r'$ws = New-Object -ComObject WScript.Shell; '
        "\$s = \$ws.CreateShortcut('${q(shortcut)}'); "
        "\$s.TargetPath = '${q(launcherPath)}'; "
        "\$s.IconLocation = '${q(iconLocation)}'; "
        r'$s.Save()';
    try {
      final ProcessResult result = await Process.run('powershell', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      if (result.exitCode == 0) {
        stdout.writeln(
          icon == null ? '  快捷方式图标已回默认。' : '  已应用品牌图标：$icon',
        );
      } else {
        stderr.writeln(
          '[launcher] 更新快捷方式图标失败（exit=${result.exitCode}）：'
          '${result.stderr}',
        );
      }
    } catch (error) {
      stderr.writeln('[launcher] 更新快捷方式图标失败：$error');
    }
  }

  // ── 控制台菜单 ───────────────────────────────────────────────────────

  void _printBanner() {
    stdout.writeln('');
    stdout.writeln('  Tree 启动器（控制台模式）');
    stdout.writeln('  ──────────────────────────────────────');
    stdout.writeln('  1) 重新签发票据并打开引导页');
    stdout.writeln('  2) 打开数据目录');
    stdout.writeln('  3) 打开日志目录');
    stdout.writeln('  4) 退出（优雅关闭核心）');
    stdout.writeln('  ──────────────────────────────────────');
    stdout.writeln('  说明：本期没有托盘图标（已知差距）；关闭本窗口会退出启动器。');
    stdout.write('  请选择：');
    stdout.flush();
  }

  Future<int> _menuLoop() async {
    final Completer<int> done = Completer<int>();
    late final StreamSubscription<String> subscription;
    subscription = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) async {
            final String choice = line.trim();
            if (choice == '1') {
              await _openBootstrap();
            } else if (choice == '2') {
              await _openDirectory(_dataRoot());
            } else if (choice == '3') {
              await _openDirectory(_logRoot());
            } else if (choice == '4' || choice.toLowerCase() == 'q') {
              if (!done.isCompleted) done.complete(0);
            } else if (choice.isNotEmpty) {
              stdout.writeln('  未知选项：$choice');
            }
            stdout.write('  请选择：');
            stdout.flush();
          },
          onDone: () {
            if (!done.isCompleted) done.complete(0);
          },
          onError: (Object error) {
            stderr.writeln('[launcher] 读取控制台输入失败：$error');
            if (!done.isCompleted) done.complete(1);
          },
        );
    final int code = await done.future;
    _watch?.cancel();
    _watch = null;
    await subscription.cancel();
    await _shutdownCore();
    return code;
  }

  Future<void> _openDirectory(String path) async {
    try {
      await Directory(path).create(recursive: true);
      if (Platform.isWindows) {
        await Process.start('explorer.exe', <String>[path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', <String>[path]);
      } else {
        await Process.start('xdg-open', <String>[path]);
      }
      stdout.writeln('  已打开：$path');
    } catch (error) {
      stderr.writeln('[launcher] 打开目录失败：$error');
    }
  }

  String _dataRoot() {
    final String explicit = _core?.dataRoot ?? '';
    if (explicit.isNotEmpty) return explicit;
    final String env = Platform.environment[_envDataRoot] ?? '';
    if (env.isNotEmpty) return env;
    final String base = Platform.environment['APPDATA'] ?? Directory.current.path;
    return _join(base, 'Tree');
  }

  String _logRoot() => _join(_dataRoot(), 'logs');

  // ── 退出 ─────────────────────────────────────────────────────────────

  /// 收尾阶段的安全控制台输出。
  ///
  /// 实测（2026-11-01，stdout 被管道接走后）：`stdout.writeln` 会抛
  /// `Bad state: StreamSink is bound to a stream`。这一步抛出去就等于**跳过关闭
  /// 核心**，用户点「退出」后核心和界面会留在后台 —— 宁可少一行提示，也不能漏关。
  void _say(String line) {
    try {
      stdout.writeln(line);
    } catch (_) {}
  }

  void _warn(String line) {
    try {
      stderr.writeln(line);
    } catch (_) {}
  }

  Future<void> _shutdownCore() async {
    final Process? process = _process;
    if (process == null) {
      _say('[launcher] 附着模式：不关闭已有核心。');
      _http.close(force: true);
      return;
    }
    _say('[launcher] 正在优雅关闭核心…');
    bool exited = false;
    try {
      process.stdin.writeln('shutdown');
      await process.stdin.flush();
      await process.exitCode.timeout(_shutdownGrace);
      exited = true;
    } catch (_) {
      // stdin 已关闭 / 核心没在时限内退出：走下面的强杀。
    }
    if (!exited) {
      _warn('[launcher] 核心未在 ${_shutdownGrace.inSeconds}s 内退出，强制结束。');
      try {
        process.kill();
      } catch (_) {}
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // 已经退出 / 强杀失败：启动器仍然退出。
      }
    }
    _process = null;
    _http.close(force: true);
  }

  // ── HTTP ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _getJson(String path) =>
      _requestJson('GET', path, null);

  Future<Map<String, dynamic>?> _postJson(
    String path,
    Map<String, dynamic> body,
  ) => _requestJson('POST', path, body);

  Future<Map<String, dynamic>?> _requestJson(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final MinimalHandshake core = _core!;
    final Uri uri = Uri.parse('${core.httpBaseUrl}$path');
    final HttpClientRequest request = await _http.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${core.token}');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}：$text', uri: uri);
    }
    if (text.trim().isEmpty) return null;
    final Object? decoded = jsonDecode(text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  static String _join(String a, String b) =>
      a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';
}

/// 引导判据的结论。
///
/// [ready] 为 false = 预算内没读到 `config.plugins[]`（核心还在预热）：这时既不
/// 开引导页、也不声称“有界面”，只留一行提示。
class _BootstrapProbe {
  const _BootstrapProbe({
    required this.ready,
    required this.needsBootstrap,
    required this.enabledUiIds,
  });

  const _BootstrapProbe.unready()
    : ready = false,
      needsBootstrap = false,
      enabledUiIds = const <String>{};

  final bool ready;
  final bool needsBootstrap;
  final Set<String> enabledUiIds;
}
