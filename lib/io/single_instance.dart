import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 单实例判定的结果。
enum SingleInstanceState {
  /// 本进程拿到了锁：可以继续启动（拉起核心、建界面）。
  acquired,

  /// **同机同数据根已经有一个实例在跑**：本进程必须立刻退出，绝不拉起第二个核心。
  /// 锁的持有者已被请去把窗口叫到前面。
  alreadyRunning,
}

/// 同机同数据根的**单实例锁**。
///
/// 为什么需要它（关窗进托盘之后更明显）：窗口被收进系统托盘时用户看不见主界面，
/// 最容易"再双击一次桌面图标"。那会拉起**第二个核心**，而两个核心共用同一个数据根
/// （store 的既有边界：多实例各持内存缓存、互不感知）——双方的会话与消息会互相覆盖。
///
/// 实现：**回环端口当锁**（纯 Dart、跨平台，进程退出由内核自动释放，没有需要清理的
/// 残留状态）：
/// - **锁键 = 本次使用的数据根**（`TREE_HOME`，没设就是"默认数据根"），哈希到
///   45800..45899 里的一个端口 ⇒ **同一数据根互斥，不同数据根（开发临时根 / 装了多份）
///   互不干扰**；`TREE_INSTANCE_KEY` 可显式覆盖锁键（多开调试用）；
/// - 先试着 `bind`：成功 = 本进程是唯一实例，持有到退出；
/// - `bind` 失败 ⇒ 连上去发一行带锁键的握手：**回的键与本进程一致**才算"是自己人"，
///   同时请对方把窗口叫到前面（[onActivate]），本进程退出；
/// - 端口被**别的程序**占用（握手超时 / 回的内容不对）⇒ **照常启动**——不能因为撞了
///   一个端口就把用户挡在门外。
class SingleInstanceLock {
  /// 生产用的全局单例（一个进程一个锁）。
  static final SingleInstanceLock instance = SingleInstanceLock();

  /// [keyOverride] 仅供测试与多开调试；为空时按 [lockKey] 从环境变量推导。
  SingleInstanceLock({this.keyOverride});

  /// 显式锁键（null = 按 [lockKey] 推导）。

  /// 握手前缀（改它就等于换协议，避免把旧版本当成自己人）。
  static const String handshake = 'TREE-INSTANCE-V1';

  /// 端口区间起点与跨度（回环地址上的私有区间，避开常用服务端口）。
  static const int portBase = 45800;
  static const int portSpan = 100;

  /// 显式覆盖锁键（多开调试：给不同实例不同的键）。
  static const String envKey = 'TREE_INSTANCE_KEY';

  /// 数据根环境变量（与核心 `tree_paths.dart` 同一个键）。
  static const String envHome = 'TREE_HOME';

  /// 握手超时：另一个实例在正常机器上应在毫秒级回话。
  static const Duration handshakeTimeout = Duration(milliseconds: 800);

  final String? keyOverride;
  ServerSocket? _server;
  String _key = '';

  /// 收到"另一个实例想进来"时调用（生产接线到 `TrayService.showWindow`）。
  ///
  /// 为什么有必要：用户双击桌面图标时期望的是"窗口回来了"。没有这个回调，
  /// 现象就是"点了图标什么都没发生"。
  Future<void> Function()? onActivate;

  /// 本进程当前持有的锁键（未获取时为空串）。
  String get key => _key;

  /// 本进程是否持有锁。
  bool get held => _server != null;

  /// 锁键：`TREE_INSTANCE_KEY` → `TREE_HOME` → 固定 'default'。
  ///
  /// Windows 路径大小写不敏感，因此统一按小写归一（`C:\\A` 与 `c:\\a` 是同一个数据根）。
  static String lockKey([Map<String, String>? env]) {
    final Map<String, String> source = env ?? Platform.environment;
    final String explicit = (source[envKey] ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    final String home = (source[envHome] ?? '').trim();
    return home.isEmpty ? 'default' : home.toLowerCase();
  }

  /// 锁键 → 端口（FNV-1a 取模；同一键恒等）。
  static int portFor(String key) {
    int hash = 0x811c9dc5;
    for (final int unit in utf8.encode(key.toLowerCase())) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return portBase + (hash % portSpan);
  }

  /// 抢锁。返回 [SingleInstanceState.alreadyRunning] 时**不要**再拉起核心。
  Future<SingleInstanceState> acquire({String? key}) async {
    final String resolved = key ?? keyOverride ?? lockKey();
    final int port = portFor(resolved);
    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } on SocketException {
      final bool mine = await _pingExisting(port, resolved);
      if (mine) {
        _key = resolved;
        return SingleInstanceState.alreadyRunning;
      }
      // 端口被别的程序占用：照常启动（宁可多一个实例，也不把用户挡在门外）
      debugPrint('单实例锁：端口 $port 被其它程序占用（握手无应答），按新实例继续启动');
      return SingleInstanceState.acquired;
    }
    _key = resolved;
    _server!.listen(_handleConnection, onError: (Object _) {});
    debugPrint('单实例锁：已持有（端口 $port，键 $resolved）');
    return SingleInstanceState.acquired;
  }

  /// 释放锁（退出前调用；进程退出时内核也会释放）。
  Future<void> release() async {
    final ServerSocket? server = _server;
    _server = null;
    _key = '';
    if (server == null) return;
    try {
      await server.close();
    } catch (error) {
      debugPrint('单实例锁：释放失败（忽略）：$error');
    }
  }

  /// 问一句"这个端口上跑的是不是同一个数据根的 Tree"。
  Future<bool> _pingExisting(int port, String key) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: handshakeTimeout,
      );
      final String expected = '$handshake $key OK';
      socket.write('$handshake $key\n');
      await socket.flush();
      final Completer<String> reply = Completer<String>();
      final StreamSubscription<String> subscription = utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen(
            (String line) {
              if (!reply.isCompleted) reply.complete(line.trim());
            },
            onError: (Object _) {
              if (!reply.isCompleted) reply.complete('');
            },
            onDone: () {
              if (!reply.isCompleted) reply.complete('');
            },
          );
      final String answer = await reply.future.timeout(
        handshakeTimeout,
        onTimeout: () => '',
      );
      await subscription.cancel();
      return answer == expected;
    } catch (error) {
      debugPrint('单实例锁：握手失败（按新实例继续）：$error');
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {
        // 关不关得上都不影响判定
      }
    }
  }

  /// 持有者侧：只认握手键一致的请求，回一句"是我"，并把窗口叫到前面。
  void _handleConnection(Socket socket) {
    final StringBuffer buffer = StringBuffer();
    socket.listen(
      (List<int> data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        final String message = buffer.toString().trim();
        if (message.isEmpty) return;
        final String expected = '$handshake $_key';
        if (message != expected) {
          // 不是自己人：不回话（避免把"别的程序占着端口"误判成本应用已在运行）
          socket.destroy();
          return;
        }
        socket.write('$expected OK\n');
        unawaited(
          socket.flush().then((_) => socket.close()).catchError((Object _) {}),
        );
        unawaited(_activate());
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  Future<void> _activate() async {
    final Future<void> Function()? callback = onActivate;
    if (callback == null) return;
    try {
      await callback();
    } catch (error) {
      debugPrint('单实例锁：唤起窗口失败：$error');
    }
  }
}
