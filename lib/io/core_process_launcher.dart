import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:tree_protocol/tree_protocol.dart';

/// 本地核心进程的启动、握手与生命周期管理。
///
/// 桌面分支的形态是"Flutter UI + 核心进程"两个进程（见迁移方案 §4）：
/// 核心以**随机端口 + 一次性随机 token** 监听 127.0.0.1，并把二者随单行
/// [CoreHandshake] 写到 stdout。本类负责：
/// 1. 解析核心可执行文件路径（支持环境变量覆盖与开发期回退）；
/// 2. 拉起子进程、读 stdout 首行握手、把其余输出转发为日志；
/// 3. 退出时先请求优雅关闭（stdin 写 `shutdown`），超时再强杀。
///
/// **附着模式**（开发/调试）：设置环境变量 `TREE_CORE_URL`（如
/// `http://127.0.0.1:8001`）与 `TREE_CORE_TOKEN`，则不拉起子进程而直接复用
/// 已在运行的核心——便于单独调试核心进程或对接既有服务。
class CoreProcessLauncher {
  CoreProcessLauncher._();

  /// 全局单例（进程生命周期内只应有一个核心进程）。
  static final CoreProcessLauncher instance = CoreProcessLauncher._();

  /// 附着模式的核心 HTTP 基址（不设置则拉起子进程）。
  static const String envUrl = 'TREE_CORE_URL';

  /// 附着模式的本地 token。
  static const String envToken = 'TREE_CORE_TOKEN';

  /// 显式指定核心可执行文件路径（覆盖默认解析顺序）。
  static const String envExe = 'TREE_CORE_EXE';

  /// 等待握手的超时（冷启动 + 杀毒软件扫描可能较慢）。
  static const Duration handshakeTimeout = Duration(seconds: 25);

  /// 优雅关闭的等待时长，超时后强杀。
  static const Duration shutdownGrace = Duration(seconds: 3);

  /// 核心可执行文件名（Windows 带 .exe）。
  static String get executableName =>
      Platform.isWindows ? 'tree_core.exe' : 'tree_core';

  Process? _process;
  CoreHandshake? _handshake;
  bool _attached = false;

  /// 最近一次失败的原因（供启动失败页展示）。
  String? lastError;

  /// 本次实际使用的核心可执行文件路径（附着模式为 null）。
  String? coreExecutablePath;

  /// 启动期诊断（非致命）：目前用于「核心产物比界面旧」。
  ///
  /// 为什么需要：核心是**独立进程**，它的产物可能来自更早的构建；此时界面是新
  /// 功能、核心是旧行为（工具表缺项、系统提示词缺章节、spec 索引消失……），现象
  /// 极难自证。用一次产物时间对比就能把这类问题直接摆到用户面前。
  String? buildWarning;

  /// 本次连接的核心握手信息；未启动成功时为 null。
  CoreHandshake? get handshake => _handshake;

  /// 是否为附着模式（复用外部已启动的核心）。
  bool get isAttached => _attached;

  /// 核心子进程是否仍在运行（附着模式恒为 null）。
  bool get isCoreProcessAlive => _process != null;

  /// 启动核心并返回握手；失败返回 null 并填充 [lastError]。
  Future<CoreHandshake?> start() async {
    if (_handshake != null) return _handshake;
    final CoreHandshake? attached = _tryAttach();
    if (attached != null) {
      _attached = true;
      _handshake = attached;
      debugPrint('[core] 附着已运行的核心：${attached.httpBaseUrl}');
      return attached;
    }
    final String? executable = _resolveExecutable();
    if (executable == null) {
      lastError =
          '未找到核心进程可执行文件 $executableName。\n'
          '已尝试：环境变量 $envExe、应用目录、以及从应用目录向上查找'
          '`.output/$executableName`（开发期）。\n'
          '便携版/安装版：请确认 $executableName 与 '
          '${p.basename(Platform.resolvedExecutable)} 在**同一目录**'
          '（整包解压，不要只复制主程序）。\n'
          '开发期请先执行：\n'
          '  dart compile exe packages/tree_core_cli/bin/tree_core.dart '
          '-o .output/$executableName';
      return null;
    }
    try {
      final Process process = await Process.start(
        executable,
        // 骨架期的流式节奏（模拟逐段输出）；M3 接入真实 LLM 后不再需要
        const <String>['--chunk-delay-ms', '40'],
        workingDirectory: p.dirname(executable),
      );
      _process = process;
      final CoreHandshake handshake = await _readHandshake(process);
      _handshake = handshake;
      coreExecutablePath = executable;
      buildWarning = _staleCoreWarning(executable);
      debugPrint(
        '[core] 已启动：$executable → ${handshake.httpBaseUrl} '
        '(pid ${handshake.pid})',
      );
      return handshake;
    } catch (e) {
      lastError = '核心进程启动失败：$e';
      await stop();
      return null;
    }
  }

  /// 请求核心退出：先写 `shutdown` 命令等它优雅收尾，超时再强杀。
  ///
  /// 顺序不可颠倒：核心在关闭时会断开全部 WS 连接并（M2 起）落盘，硬杀会
  /// 跳过收尾。附着模式下不碰外部进程。
  Future<void> stop() async {
    final Process? process = _process;
    _process = null;
    _handshake = null;
    if (process == null) return;
    try {
      process.stdin.writeln('shutdown');
      await process.stdin.flush();
    } catch (_) {
      // 进程已退出/管道已断：直接进入等待
    }
    try {
      await process.exitCode.timeout(shutdownGrace);
      return;
    } on TimeoutException {
      // 继续走强杀
    }
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
  }

  // ── 内部实现 ─────────────────────────────────────────────────────────

  /// 附着模式：环境变量同时给出 URL 与 token 才生效（缺一不可）。
  CoreHandshake? _tryAttach() {
    final Map<String, String> env = Platform.environment;
    final String url = env[envUrl] ?? '';
    final String token = env[envToken] ?? '';
    if (url.isEmpty || token.isEmpty) return null;
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || uri.port == 0) {
      lastError = '环境变量 $envUrl 不是合法的 http(s) 地址：$url';
      return null;
    }
    return CoreHandshake(
      host: uri.host,
      port: uri.port,
      token: token,
      pid: 0,
      version: 'attached',
    );
  }

  /// 核心产物是否比界面旧（陈旧产物的典型信号）。
  ///
  /// 判定：核心文件修改时间早于应用主程序 **60 秒以上**。容差是为了避开"同一次
  /// 构建里两个产物先后落盘"的正常情况；开发期只重建了 App 没重建核心时，两者
  /// 通常相差几十分钟到几小时，一定能命中。
  ///
  /// 只在能读到两个文件时间时判定，任何异常都当作"无法判定"（返回 null，不打扰
  /// 用户）。
  String? _staleCoreWarning(String executable) {
    try {
      return staleCoreWarningFor(
        coreMtime: File(executable).lastModifiedSync(),
        appMtime: File(Platform.resolvedExecutable).lastModifiedSync(),
        coreName: p.basename(executable),
        appName: p.basename(Platform.resolvedExecutable),
        coreExecutableName: executableName,
      );
    } catch (_) {
      return null;
    }
  }

  /// 陈旧产物的纯判定（可单测）：核心早于界面超过 [tolerance] 就给出告警文案。
  ///
  /// 抽成纯函数的原因：真实调用要读 `Platform.resolvedExecutable` 的修改时间，
  /// 在测试里无法构造；把"两个时间 + 两个文件名"作为输入，判定与文案就能被
  /// 直接验证。
  static String? staleCoreWarningFor({
    required DateTime coreMtime,
    required DateTime appMtime,
    required String coreName,
    required String appName,
    required String coreExecutableName,
    Duration tolerance = const Duration(seconds: 60),
  }) {
    if (!coreMtime.isBefore(appMtime.subtract(tolerance))) return null;
    return '核心进程产物比界面旧：\n'
        '  核心 $coreName（${_formatStamp(coreMtime)}）\n'
        '  界面 $appName（${_formatStamp(appMtime)}）\n'
        '界面上的新功能可能因为核心是旧产物而不可用（例如工具表缺项、系统提示词\n'
        '缺章节）。请重建核心后重启应用：\n'
        '  dart run tool/build_core.dart --out <与界面同目录>/$coreExecutableName';
  }

  static String _formatStamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';

  static String _two(int value) => value < 10 ? '0$value' : '$value';

  /// 解析核心可执行文件路径；找不到返回 null（[lastError] 由调用方设置）。
  ///
  /// 顺序：
  /// 1. `TREE_CORE_EXE`（显式覆盖，存在性校验后再用）；
  /// 2. **应用同目录**（发行版布局：安装包把核心放在 Tree.exe 旁边）；
  /// 3. 开发期回退：从应用目录向上最多 8 层查找 `.output/<name>`
  ///    （`flutter run` 的可执行文件在 `build/windows/x64/runner/Debug/`，
  ///    而开发期核心产物在仓库根的 `.output/`）。
  String? _resolveExecutable() {
    final String override = Platform.environment[envExe] ?? '';
    if (override.isNotEmpty) {
      return File(override).existsSync() ? override : null;
    }
    final Directory appDir = File(Platform.resolvedExecutable).parent;
    final File packaged = File(p.join(appDir.path, executableName));
    if (packaged.existsSync()) return packaged.path;
    Directory? dir = appDir;
    for (int depth = 0; depth < 8 && dir != null; depth++) {
      final File candidate = File(p.join(dir.path, '.output', executableName));
      if (candidate.existsSync()) return candidate.path;
      dir = dir.parent;
    }
    return null;
  }

  /// 读 stdout 直到拿到握手行；进程提前退出时抛异常。
  Future<CoreHandshake> _readHandshake(Process process) {
    final Completer<CoreHandshake> completer = Completer<CoreHandshake>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) {
            // stdout 是进程间协议：只有握手是给应用看的，其余按日志转发
            final CoreHandshake? decoded = CoreHandshake.decode(line);
            if (decoded != null) {
              if (!completer.isCompleted) completer.complete(decoded);
              return;
            }
            if (line.trim().isNotEmpty) debugPrint('[core] $line');
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
          if (line.trim().isNotEmpty) debugPrint('[core:err] $line');
        });
    unawaited(
      process.exitCode.then((int code) {
        debugPrint('[core] 核心进程已退出（exit=$code）');
        if (!completer.isCompleted) {
          completer.completeError(StateError('核心进程在握手前退出（exit=$code）'));
        }
        if (identical(_process, process)) _process = null;
      }),
    );
    return completer.future.timeout(
      handshakeTimeout,
      onTimeout: () => throw StateError(
        '等待核心进程握手超时'
        '（${handshakeTimeout.inSeconds}s）',
      ),
    );
  }
}
