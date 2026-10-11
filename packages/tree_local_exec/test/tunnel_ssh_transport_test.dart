import 'dart:async';
import 'dart:convert';


import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 内存假隧道：把 agent 的 L2 方法在一张内存表上实现，用来钉住
/// `TunnelSshTransport` **映射层**的每一处语义（真链路归 WSL/Docker 的端到端）。
class FakeTunnelSession implements TunnelSession {
  FakeTunnelSession({this.root = '/ws'});

  @override
  final String root;

  final Map<String, List<int>> files = <String, List<int>>{};
  final Set<String> dirs = <String>{'/ws'};

  /// 被调用过的 (method, params) 记录。
  final List<String> calls = <String>[];

  final StreamController<TunnelShellEvent> eventSink =
      StreamController<TunnelShellEvent>.broadcast();

  @override
  Stream<TunnelShellEvent> get events => eventSink.stream;

  int snapshotCalls = 0;
  int reconnectCalls = 0;
  int closeCalls = 0;

  /// 插件是否还在（心跳失败时核心据此决定"判死"还是"等它回来"）。
  @override
  bool pluginAvailable = true;

  /// **这条会话绑定的那个插件实例**是否还在（插件重启换了实例 ⇒ false）。
  ///
  /// 与 [pluginAvailable] 的分工见 `TunnelSession.boundHostAlive` 的 dartdoc
  /// （只看 pluginAvailable 就是 2026-10-11 那个"重启插件后回不来"的 bug）。
  @override
  bool boundHostAlive = true;

  @override
  String unavailableReason = '插件已停';

  /// 被强制设定的状态（null = 一直 ready）。
  String? forcedState;
  String lastError = '';

  /// 下一次 `request` 抛这个（用完即清）。
  Object? nextError;

  /// `snapshot()` 抛这个（模拟"插件通道也断了"）。
  Object? snapshotError;

  /// `shell.open` 是否回"不支持 PTY"。
  bool ptyUnsupported = false;

  @override
  String get connId => 'conn-1';

  @override
  Map<String, dynamic> get agent =>
      <String, dynamic>{'os': 'linux', 'arch': 'x64', 'agent_version': '1.0.0'};

  @override
  Future<Object?> request(String method, Map<String, dynamic> params) async {
    calls.add('$method ${jsonEncode(params)}');
    final Object? forced = nextError;
    if (forced != null) {
      nextError = null;
      throw forced;
    }
    switch (method) {
      case AgentMethods.fsRead:
        final List<int> data = files[params['path']] ?? <int>[];
        final int offset = (params['offset'] as num?)?.toInt() ?? 0;
        final int want = (params['length'] as num?)?.toInt() ?? kReadChunkBytes;
        final int end = (offset + want).clamp(0, data.length);
        if (offset >= data.length) {
          return <String, dynamic>{
            'data': '',
            'size': data.length,
            'offset': offset,
            'eof': true,
          };
        }
        return <String, dynamic>{
          'data': base64Encode(data.sublist(offset, end)),
          'size': data.length,
          'offset': offset,
          'eof': end >= data.length,
        };
      case AgentMethods.fsWrite:
        final List<int> chunk = base64Decode(params['data'] as String);
        final String path = params['path'] as String;
        if (params['mode'] == 'append') {
          files.putIfAbsent(path, () => <int>[]).addAll(chunk);
        } else {
          files[path] = List<int>.from(chunk);
        }
        return <String, dynamic>{'size': files[path]!.length};
      case AgentMethods.fsStat:
        final String path = params['path'] as String;
        final List<int>? data = files[path];
        if (data == null) {
          return dirs.contains(path)
              ? <String, dynamic>{'type': 'dir', 'size': 0}
              : <String, dynamic>{'type': 'missing', 'size': 0};
        }
        return <String, dynamic>{'type': 'file', 'size': data.length};
      case AgentMethods.fsExists:
        final String path = params['path'] as String;
        return <String, dynamic>{
          'exists': files.containsKey(path) || dirs.contains(path),
          'is_dir': dirs.contains(path),
        };
      case AgentMethods.fsIsDir:
        return <String, dynamic>{'is_dir': dirs.contains(params['path'])};
      case AgentMethods.fsList:
        final String prefix = params['path'] as String;
        return <String, dynamic>{
          'files': files.keys
              .where((String k) => k.startsWith('$prefix/'))
              .map((String k) => k.substring(prefix.length + 1))
              .toList(),
        };
      case AgentMethods.fsListEntries:
        final String prefix = params['path'] as String;
        return <String, dynamic>{
          'entries': <Map<String, dynamic>>[
            for (final MapEntry<String, List<int>> e in files.entries)
              if (e.key.startsWith('$prefix/') &&
                  !e.key.substring(prefix.length + 1).contains('/'))
                <String, dynamic>{
                  'name': e.key.substring(prefix.length + 1),
                  'type': 'file',
                  'size': e.value.length,
                  'mtime_ms': 1700000000000,
                },
          ],
        };
      case AgentMethods.fsDelete:
        files.remove(params['path']);
        return <String, dynamic>{};
      case AgentMethods.fsMkdir:
        if (files.containsKey(params['path']) || dirs.contains(params['path'])) {
          throw RpcException(TunnelErrorCodes.alreadyExists, '已存在');
        }
        dirs.add(params['path'] as String);
        return <String, dynamic>{};
      case AgentMethods.fsRename:
        final String from = params['from'] as String;
        final String to = params['to'] as String;
        if (files.containsKey(to)) {
          throw RpcException(TunnelErrorCodes.alreadyExists, '目标已存在');
        }
        final List<int>? data = files.remove(from);
        if (data == null) {
          throw RpcException(TunnelErrorCodes.notFound, '源不存在');
        }
        files[to] = data;
        return <String, dynamic>{};
      case AgentMethods.fsRemove:
        final String path = params['path'] as String;
        final bool existed = files.containsKey(path) || dirs.contains(path);
        files.remove(path);
        dirs.remove(path);
        if (!existed) throw RpcException(TunnelErrorCodes.notFound, '不存在');
        return <String, dynamic>{};
      case AgentMethods.execRun:
        if ((params['command'] as String).contains('boom')) {
          return <String, dynamic>{
            'exit_code': 3,
            'stdout': base64Encode(utf8.encode('out')),
            'stderr': base64Encode(utf8.encode('err')),
            'timed_out': false,
          };
        }
        return <String, dynamic>{
          'exit_code': 0,
          'stdout': base64Encode(utf8.encode('hello')),
          'stderr': '',
        };
      case AgentMethods.shellOpen:
        if (ptyUnsupported) {
          throw RpcException(TunnelErrorCodes.ptyUnsupported, '没有 script');
        }
        return <String, dynamic>{'shell_id': 'sh-1', 'pty': true};
      case AgentMethods.shellWrite:
      case AgentMethods.shellClose:
        return <String, dynamic>{};
      case AgentMethods.shellResize:
        return <String, dynamic>{'supported': false};
      default:
        throw RpcException(RpcCodes.methodNotFound, '没有这个方法：$method');
    }
  }

  @override
  Future<TunnelSnapshot> snapshot() async {
    snapshotCalls++;
    final Object? boom = snapshotError;
    if (boom != null) throw boom;
    return TunnelSnapshot(
      connId: connId,
      state: forcedState ?? TunnelStates.ready,
      root: root,
      lastError: lastError,
    );
  }

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
    if (forcedState == TunnelStates.down) {
      throw WorkspaceIoException('重建失败：目标机仍不可达');
    }
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (!eventSink.isClosed) await eventSink.close();
  }
}

class FakeTunnelLink implements TunnelLink {
  FakeTunnelLink(this.session, [this._available = true]);

  final FakeTunnelSession session;
  bool _available;
  int ensureCalls = 0;
  Object? ensureError;

  set available(bool value) => _available = value;

  @override
  bool get available => _available;

  @override
  Future<TunnelSession> ensure(TunnelConnectRequest request) async {
    ensureCalls++;
    final Object? error = ensureError;
    if (error != null) throw error;
    return session;
  }
}

TunnelConnectRequest request() => const TunnelConnectRequest(
  host: 'h',
  username: 'u',
  password: 'p',
  heartbeatInterval: Duration(milliseconds: 40),
);

void main() {
  test('没有中转站 ⇒ connect 抛 agent_unreachable（可回退）', () async {
    final FakeTunnelLink link = FakeTunnelLink(
      FakeTunnelSession(),
      false,
    );
    await expectLater(
      TunnelSshTransport.connect(link, request()),
      throwsA(
        isA<TunnelUnavailableException>()
            .having(
              (TunnelUnavailableException e) => e.kind,
              'kind',
              TunnelErrorKinds.agentUnreachable,
            )
            .having((TunnelUnavailableException e) => e.shouldFallback, 'fallback', isTrue),
      ),
    );
  });

  test('ensure 失败原样上抛（kind 决定回退与否）', () async {
    final FakeTunnelLink link = FakeTunnelLink(FakeTunnelSession())
      ..ensureError = TunnelUnavailableException(
        TunnelErrorKinds.configIncomplete,
        '缺凭据',
      );
    await expectLater(
      TunnelSshTransport.connect(link, request()),
      throwsA(
        isA<TunnelUnavailableException>().having(
          (TunnelUnavailableException e) => e.shouldFallback,
          '不该回退',
          isFalse,
        ),
      ),
    );
  });

  group('文件原语映射', () {
    late FakeTunnelLink link;
    late FakeTunnelSession session;
    late TunnelSshTransport t;

    setUp(() async {
      session = FakeTunnelSession();
      link = FakeTunnelLink(session);
      t = await TunnelSshTransport.connect(link, request());
    });

    tearDown(() async => t.close());

    test('root 来自 session（核心据此构造 SshWorkspaceIO）', () {
      expect(t.root, '/ws');
      expect(t.agentInfo['arch'], 'x64');
    });

    test('write/read 往返；超过一块的内容自动分块 append', () async {
      final List<int> big = List<int>.generate(kReadChunkBytes * 2 + 7, (int i) => i % 251);
      await t.write('/ws/big.bin', big);
      final List<int> back = await t.read('/ws/big.bin');
      expect(back, big);
      final int writes = session.calls
          .where((String c) => c.startsWith(AgentMethods.fsWrite))
          .length;
      expect(writes, 3, reason: '2 块整 + 1 块零头');
    });

    test('readStream 支持 offset/length', () async {
      await t.write('/ws/a.txt', utf8.encode('0123456789'));
      final List<int> got = <int>[];
      await for (final List<int> chunk in t.readStream('/ws/a.txt', offset: 2, length: 3)) {
        got.addAll(chunk);
      }
      expect(utf8.decode(got), '234');
    });

    test('size 对缺失文件抛可读异常', () async {
      await expectLater(
        t.size('/ws/nope'),
        throwsA(
          isA<WorkspaceIoException>().having(
            (WorkspaceIoException e) => e.message,
            'message',
            contains('不存在'),
          ),
        ),
      );
    });

    test('exists / isDirectory / listFiles / listEntries / delete / mkdir / rename / remove', () async {
      await t.makeDirectory('/ws/d');
      expect(await t.isDirectory('/ws/d'), isTrue);
      await t.write('/ws/d/f.txt', utf8.encode('x'));
      expect(await t.exists('/ws/d/f.txt'), isTrue);
      expect(await t.listFiles('/ws/d'), <String>['f.txt']);
      final List<SshFileEntry> entries = await t.listEntries('/ws/d');
      expect(entries.single.name, 'f.txt');
      expect(entries.single.isDirectory, isFalse);
      expect(entries.single.size, 1);
      expect(entries.single.modified, isNotNull);

      await t.rename('/ws/d/f.txt', '/ws/d/g.txt');
      expect(await t.exists('/ws/d/g.txt'), isTrue);
      expect(await t.exists('/ws/d/f.txt'), isFalse);

      await t.delete('/ws/d/g.txt');
      expect(await t.exists('/ws/d/g.txt'), isFalse);

      await t.remove('/ws/d');
      expect(await t.isDirectory('/ws/d'), isFalse);
    });

    test('mkdir 目标已存在 ⇒ 翻成可读的 WorkspaceIoException（与 dartssh2 同口径）', () async {
      // 为什么是 WorkspaceIoException 而不是裸 RpcException：上层（`SshWorkspaceIO` /
      // 工具层 / 文件面板）按"IO 失败"统一处置，裸 RpcException 是它们不认识的类型
      // （真机 e2e 抓到过：越界路径把 `-32001` 直接漏到了 `expect(throwsA(WorkspaceIoException))` 上）。
      // 业务结果码（alreadyExists 等）由 `SshWorkspaceIO` 自己先 `exists` 自检后组装，
      // **不**依赖这一层抛的异常类型。
      await t.makeDirectory('/ws/d');
      await expectLater(
        t.makeDirectory('/ws/d'),
        throwsA(
          isA<WorkspaceIoException>().having(
            (WorkspaceIoException e) => e.message,
            'message',
            contains('已存在'),
          ),
        ),
      );
    });
  });

  group('命令与 PTY', () {
    late FakeTunnelSession session;
    late TunnelSshTransport t;

    setUp(() async {
      session = FakeTunnelSession();
      t = await TunnelSshTransport.connect(FakeTunnelLink(session), request());
    });

    tearDown(() async => t.close());

    test('run 透传 timeout_ms=0（软窗口归 SshWorkspaceIO，不在这一层切时间）', () async {
      final SshExecResult r = await t.run('echo hi', timeout: const Duration(seconds: 3));
      expect(r.exitCode, 0);
      expect(r.stdout, 'hello');
      expect(session.calls.single, contains('"timeout_ms":0'));
    });

    test('run 取回非零退出码与 stderr', () async {
      final SshExecResult r = await t.run('boom');
      expect(r.exitCode, 3);
      expect(r.stdout, 'out');
      expect(r.stderr, 'err');
    });

    test('PTY 不可用 ⇒ PtyUnsupportedException（绝不静默降级）', () async {
      session.ptyUnsupported = true;
      await expectLater(
        t.openShell(columns: 80, rows: 24),
        throwsA(isA<PtyUnsupportedException>()),
      );
    });

    test('shell.data / shell.exit 通知 ⇒ 通道输出与退出码收口', () async {
      final SshShellChannel ch = await t.openShell(columns: 80, rows: 24);
      final List<int> seen = <int>[];
      final StreamSubscription<List<int>> sub = ch.output.listen(seen.addAll);
      session.eventSink.add(
        TunnelShellEvent(
          connId: 'conn-1',
          kind: TunnelEventKind.shellData,
          shellId: 'sh-1',
          data: utf8.encode('hi'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, utf8.encode('hi'));
      session.eventSink.add(
        const TunnelShellEvent(
          connId: 'conn-1',
          kind: TunnelEventKind.shellExit,
          shellId: 'sh-1',
          exitCode: 7,
        ),
      );
      expect(await ch.exitCode, 7);
      await sub.cancel();
      await ch.close();
    });

    test('close 幂等，且 exitCode 收口为 -1', () async {
      final SshShellChannel ch = await t.openShell(columns: 80, rows: 24);
      await ch.close();
      await ch.close();
      expect(await ch.exitCode, -1);
    });
  });

  group('活性与回退判据', () {
    test('心跳一拍成功 ⇒ 判活；隧道 down ⇒ tunnelDown + fallbackReason', () async {
      final FakeTunnelSession session = FakeTunnelSession();
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(session.snapshotCalls, greaterThan(0));
      expect(t.liveness.isStale, isFalse);
      expect(t.tunnelDown, isFalse);

      session
        ..forcedState = TunnelStates.down
        ..lastError = '退避耗尽';
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(t.tunnelDown, isTrue);
      expect(t.fallbackReason, contains('退避耗尽'));
      expect(t.liveness.isStale, isTrue);
      await t.close();
    });

    test('请求级失败**不判死**：如实失败但隧道还留着（判死只来自心跳）', () async {
      final FakeTunnelSession session = FakeTunnelSession();
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      // 通道断在请求中途 ⇒ 插件报 tunnel_down ⇒ 这次如实失败、**不重放**……
      session.nextError = TunnelUnavailableException(
        TunnelErrorKinds.tunnelDown,
        '隧道通道已断，本次操作结果未知（不会自动重试）',
      );
      await expectLater(
        t.read('/ws/a'),
        throwsA(isA<SshLinkStaleException>()),
      );
      // ……但**不许**据此判死回退：那正是 2026-10-11 那个"一次抖动就回退内置"的 bug。
      expect(
        t.tunnelDown,
        isFalse,
        reason: '判死只能由心跳快照 down / 插件不可用触发',
      );
      await t.close();
    });

    test('"还没好"（tunnel_not_ready）⇒ 等它回来再发一次（不判死、也不是重放）', () async {
      final FakeTunnelSession session = FakeTunnelSession();
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
        readyPollInterval: const Duration(milliseconds: 10),
      );
      session
        ..files['/ws/a'] = utf8.encode('hi').toList()
        ..forcedState = TunnelStates.reconnecting
        ..nextError = TunnelUnavailableException(
          TunnelErrorKinds.tunnelNotReady,
          '隧道未就绪（state=reconnecting）',
        );
      final Future<List<int>> pending = t.read('/ws/a');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        session.calls.where((String c) => c.startsWith('fs.read')).length,
        1,
        reason: '插件在"未就绪"时不会转发 ⇒ 这一次请求确定没执行过',
      );
      expect(t.tunnelDown, isFalse, reason: '重连期间绝不判死');

      session.forcedState = null; // 隧道回来了
      expect(utf8.decode(await pending), 'hi');
      expect(
        session.calls.where((String c) => c.startsWith('fs.read')).length,
        2,
        reason: '恢复后重发一次（"确定未执行"才允许重发）',
      );
      await t.close();
    });

    test('等太久（超预算）⇒ 如实失败，不无限期挂着', () async {
      final FakeTunnelSession session = FakeTunnelSession()
        ..forcedState = TunnelStates.reconnecting
        ..nextError = TunnelUnavailableException(
          TunnelErrorKinds.tunnelNotReady,
          '隧道未就绪',
        );
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
        readyPollInterval: const Duration(milliseconds: 10),
        maxReadyWait: const Duration(milliseconds: 60),
      );
      await expectLater(
        t.read('/ws/a'),
        throwsA(
          isA<SshLinkStaleException>().having(
            (SshLinkStaleException e) => e.message,
            'message',
            contains('仍未恢复'),
          ),
        ),
      );
      await t.close();
    });

    test('插件已不可用 ⇒ 判死（本地事实：没有中转站了）', () async {
      final FakeTunnelSession session = FakeTunnelSession()
        ..pluginAvailable = false
        ..snapshotError = WorkspaceIoException('插件通道已断');
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(t.tunnelDown, isTrue);
      expect(t.fallbackReason, contains('插件'));
      await t.close();
    });

    test('插件**换了实例**（绑定的通道已断、但插件整体还在）⇒ 也要判死', () async {
      // 2026-10-11 真机 bug 的正面复现：插件停用又启用 ⇒ 新实例在跑（pluginAvailable = true），
      // 而这条会话绑的是**旧实例**（通道已关）。老判据只看 pluginAvailable ⇒ 永不判死 ⇒
      // 核心缓存里那条死链路被永久使用（真机日志每 10 秒一条"心跳失败：输出流已关闭"，
      // 而且"重启插件也没用"——用户原话）。
      final FakeTunnelSession session = FakeTunnelSession()
        ..boundHostAlive = false
        ..pluginAvailable = true
        ..snapshotError = WorkspaceIoException('插件 ssh_executor 的输出流已关闭');
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        t.tunnelDown,
        isTrue,
        reason: '绑定的实例没了 ⇒ 必须判死，核心才会撤换缓存并在下次解析重建',
      );
      expect(t.fallbackReason, contains('实例'));
      await t.close();
    });

    test('实例还在、只是这条隧道拉不到状态 ⇒ **不判死**（等它回来）', () async {
      final FakeTunnelSession session = FakeTunnelSession()
        ..boundHostAlive = true
        ..pluginAvailable = true
        ..snapshotError = WorkspaceIoException('网络抖动');
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(t.tunnelDown, isFalse, reason: '抖动不判死（用户 2026-10-11 口径，不许回退）');
      await t.close();
    });

    test('reconnect 单飞：并发调用复用同一次', () async {
      final FakeTunnelSession session = FakeTunnelSession();
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      await Future.wait<void>(<Future<void>>[t.reconnect(), t.reconnect()]);
      expect(session.reconnectCalls, 1);
      expect(t.liveness.isStale, isFalse);
      await t.close();
    });

    test('close 会收掉隧道', () async {
      final FakeTunnelSession session = FakeTunnelSession();
      final TunnelSshTransport t = await TunnelSshTransport.connect(
        FakeTunnelLink(session),
        request(),
      );
      await t.close();
      expect(session.closeCalls, 1);
    });
  });
}
