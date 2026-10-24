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

  final HttpClient _http = HttpClient();
  Process? _process;
  MinimalHandshake? _core;

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
    return _menuLoop();
  }

  // ── 连接核心 ─────────────────────────────────────────────────────────

  Future<MinimalHandshake> _connect() async {
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

  // ── 判据 + 打开引导页 ─────────────────────────────────────────────────

  Future<void> _evaluateAndOpen() async {
    final bool shouldOpen = await _probeNeedsBootstrap();
    if (!shouldOpen) {
      stdout.writeln('[launcher] 检测到可用的插件管理界面，不打开引导页。');
      return;
    }
    stdout.writeln('[launcher] 没有存活的 plugin.manage 界面，打开引导页。');
    await _openBootstrap();
  }

  Future<bool> _probeNeedsBootstrap() async {
    // 核心刚拉起时 HTTP 可能还没就绪：短重试，不把"暂时连不上"误判成"需要引导"。
    for (int attempt = 0; attempt < 40; attempt++) {
      try {
        final Map<String, dynamic>? meta = await _getJson('/api/meta');
        if (meta == null) return true;
        final Map<String, dynamic>? snapshot = await _getJson(
          '/api/plugin/snapshot',
        );
        return needsBootstrap(
          meta,
          disabledPluginIds: disabledPluginIdsOf(snapshot),
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return true;
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

  Future<void> _shutdownCore() async {
    final Process? process = _process;
    if (process == null) {
      stdout.writeln('[launcher] 附着模式：不关闭已有核心。');
      _http.close(force: true);
      return;
    }
    stdout.writeln('[launcher] 正在优雅关闭核心…');
    try {
      process.stdin.writeln('shutdown');
      await process.stdin.flush();
    } catch (_) {
      // stdin 已关闭：直接走下面的超时强杀。
    }
    try {
      await process.exitCode.timeout(_shutdownGrace);
    } catch (_) {
      stderr.writeln('[launcher] 核心未在 ${_shutdownGrace.inSeconds}s 内退出，强制结束。');
      process.kill();
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
