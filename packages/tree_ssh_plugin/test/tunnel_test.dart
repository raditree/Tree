import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'fake_ssh.dart';

void main() {
  late FakeRemote remote;
  late FakeDialer dialer;
  late FakeTimers timers;
  late List<Map<String, dynamic>> events;

  setUp(() {
    remote = FakeRemote();
    dialer = FakeDialer(remote);
    timers = FakeTimers();
    events = <Map<String, dynamic>>[];
  });

  Tunnel build({
    Map<String, dynamic>? config,
    Duration maxTotal = const Duration(minutes: 30),
    AgentBinaryLoader? loadBinary,
  }) => Tunnel(
    connId: 'conn-1',
    config: TunnelConfig.parse(config ?? configJson())!,
    agent: const AgentRequest(version: '1.2.3'),
    dialer: dialer.call,
    loadBinary: loadBinary ?? memoryBinary(List<int>.filled(64, 1)),
    backoff: Backoff(maxTotal: maxTotal),
    timerFactory: timers.factory,
    onEvent: events.add,
    chunkBytes: 64,
  );

  group('隧道建立', () {
    test('connecting → booting → ready，并汇报 root / agent 信息', () async {
      final Tunnel tunnel = build();
      expect(tunnel.state, TunnelStates.connecting);
      expect(await tunnel.ensureReady(), isTrue);
      addTearDown(tunnel.close);

      expect(tunnel.state, TunnelStates.ready);
      expect(tunnel.root, '/home/tester');
      expect(tunnel.hello!.agentVersion, '1.2.3');
      expect(remote.spawned.length, 1);
      expect(remote.dials, 1);
      // 状态跃迁发过 tunnel/event（及时性补充）
      expect(
        events.map((Map<String, dynamic> e) => e['state']).toList(),
        <Object?>[
          TunnelStates.booting,
          TunnelStates.ready,
        ],
      );
      expect(events.every((Map<String, dynamic> e) => e['conn_id'] == 'conn-1'), isTrue);
    });

    test('并发 ensureReady 只建一条连接（单飞）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      final List<bool> results = await Future.wait(<Future<bool>>[
        tunnel.ensureReady(),
        tunnel.ensureReady(),
        tunnel.ensureReady(),
      ]);
      expect(results, <bool>[true, true, true]);
      expect(remote.dials, 1);
    });

    test('stateJson 是权威判活面，且**不含凭据**', () async {
      final Tunnel tunnel = build(
        config: configJson(password: 'hunter2', root: '/ws'),
      );
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      final Map<String, dynamic> json = tunnel.stateJson();
      expect(json['conn_id'], 'conn-1');
      expect(json['host'], '10.0.0.1');
      expect(json['port'], 22);
      expect(json['username'], 'tester');
      expect(json['state'], TunnelStates.ready);
      expect(json['attempt'], 1);
      expect(json['agent'], contains('version'));
      expect(json.containsKey('elapsed_ms'), isTrue);
      expect(json.toString().contains('hunter2'), isFalse);
    });
  });

  group('建连失败 ⇒ 退避重连', () {
    test('第一次失败进 reconnecting，并按 1s 排第一拍', () async {
      dialer.failWith = (int attempt) =>
          attempt == 1 ? SshDialException('网络不通') : null;
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      expect(await tunnel.ensureReady(), isFalse);
      expect(tunnel.state, TunnelStates.reconnecting);
      expect(tunnel.lastErrorKind, TunnelErrorKinds.agentUnreachable);
      expect(tunnel.lastError, contains('网络不通'));
      expect(timers.delays, <Duration>[const Duration(seconds: 1)]);

      timers.fireNext();
      await pump(6);
      expect(tunnel.state, TunnelStates.ready);
      expect(dialer.calls, 2);
      // 建连成功 ⇒ 退避账本清零
      expect(tunnel.backoff.attempt, 0);
    });

    test('退避节奏 1s → 2s → 4s …，且耗尽累计上限后转 down', () async {
      dialer.failWith = (int attempt) => SshDialException('一直不通');
      final Tunnel tunnel = build(maxTotal: const Duration(seconds: 7));
      addTearDown(tunnel.close);
      expect(await tunnel.ensureReady(), isFalse);
      expect(timers.delays, <Duration>[const Duration(seconds: 1)]);

      for (int i = 0; i < 10 && tunnel.state != TunnelStates.down; i++) {
        timers.fireNext();
        await pump(6);
      }
      // 1s + 2s + 4s → 7s（下一拍 8s 会顶破 7s）⇒ down
      expect(timers.delays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(tunnel.state, TunnelStates.down);
      expect(tunnel.lastErrorKind, TunnelErrorKinds.agentUnreachable);
      expect(dialer.calls, 4); // 首次 + 三拍重试
      expect(timers.pending, isEmpty);
    });

    test('不可调和的失败（架构不支持）直接 down，不浪费退避', () async {
      remote.machine = 'riscv64';
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      expect(await tunnel.ensureReady(), isFalse);
      expect(tunnel.state, TunnelStates.down);
      expect(tunnel.lastErrorKind, TunnelErrorKinds.archUnsupported);
      expect(timers.delays, isEmpty);
    });

    test('握手被拒 ⇒ handshake_failed ⇒ down', () async {
      remote.helloProtocol = 7;
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      expect(await tunnel.ensureReady(), isFalse);
      expect(tunnel.state, TunnelStates.down);
      expect(tunnel.lastErrorKind, TunnelErrorKinds.handshakeFailed);
    });

    test('本机配置问题（私钥不存在）⇒ config_incomplete ⇒ down（不回退类）', () async {
      dialer.failWith = (int attempt) => SshConfigException('私钥文件不存在：X');
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      expect(await tunnel.ensureReady(), isFalse);
      expect(tunnel.state, TunnelStates.down);
      expect(tunnel.lastErrorKind, TunnelErrorKinds.configIncomplete);
      expect(timers.delays, isEmpty);
    });
  });

  group('通道断 ⇒ 重连（不重放在途请求）', () {
    test('通道死掉：状态回 reconnecting，在途请求显式失败（不重放）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();

      // 让假 agent 对 fs.stat 不回包 ⇒ 人为制造一个"在途请求"
      remote.silentMethods.add(AgentMethods.fsStat);
      final Future<Map<String, dynamic>> inFlight = tunnel.request(
        AgentMethods.fsStat,
        <String, dynamic>{'path': '/x'},
      );
      await pump(2);

      // 通道断（模拟 SSH 链路掉线）
      _liveChannel(remote).kill();
      await pump(6);

      expect(tunnel.state, TunnelStates.reconnecting);
      expect(tunnel.lastErrorKind, TunnelErrorKinds.tunnelDown);
      final Map<String, dynamic> result = await inFlight;
      expect(result['ok'], isFalse);
      expect(result['error_kind'], TunnelErrorKinds.tunnelDown);
      // 通道**中途**断：不能承诺"未执行"（远端有没有执行到我们无从得知）⇒ 核心据此如实失败、不重发。
      expect(result['error'], contains('结果未知'));
      // 在途请求**没有**被偷偷重发（假 agent 只收到过一次）
      expect(
        _liveChannel(remote).received
            .where((Map<String, dynamic> f) => f['method'] == AgentMethods.fsStat)
            .length,
        1,
      );
    });

    test('重连会重跑 bootstrap（agent 版本对账天然完成）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      _liveChannel(remote).kill();
      await pump(6);
      expect(tunnel.state, TunnelStates.reconnecting);

      timers.fireNext();
      await pump(8);
      expect(tunnel.state, TunnelStates.ready);
      // 第二次 bootstrap：又走了一遍 uname → 又拉起一次 agent
      expect(remote.spawned.length, 2);
      expect(
        remote.commands.where((String c) => c == 'uname -m').length,
        2,
      );
    });
  });

  group('显式重连（tunnel.reconnect）', () {
    test('清零退避并立即重试（不等退避用完）', () async {
      int fails = 0;
      dialer.failWith = (int attempt) {
        fails++;
        return fails <= 3 ? SshDialException('不通') : null;
      };
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      timers.fireNext(); // 第 2 次尝试
      await pump(6);
      timers.fireNext(); // 第 3 次尝试
      await pump(6);
      expect(tunnel.state, TunnelStates.reconnecting);
      expect(timers.delays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(tunnel.backoff.attempt, 3);

      await tunnel.reconnect();
      expect(tunnel.state, TunnelStates.ready);
      expect(tunnel.backoff.attempt, 0);
      expect(dialer.calls, 4);
    });

    test('已经 ready 时是 no-op（不拆掉好连接）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      await tunnel.reconnect();
      expect(remote.dials, 1);
      expect(tunnel.state, TunnelStates.ready);
    });
  });

  group('tunnel.request 转发', () {
    test('非 ready ⇒ 显式 tunnel_not_ready（不静默、也不当判死）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      final Map<String, dynamic> result =
          await tunnel.request(AgentMethods.fsStat, <String, dynamic>{});
      expect(result, <String, dynamic>{
        'ok': false,
        'error': contains('隧道未就绪'),
        // 2026-10-11：这一格从 `tunnel_down` 改成 `tunnel_not_ready` ——
        // 报成 tunnel_down 会让核心把"重连中"当判死（用户真机症状的根因）。
        'error_kind': TunnelErrorKinds.tunnelNotReady,
        'tunnel_state': TunnelStates.connecting,
        'attempt': 0,
      });
    });

    test('ready ⇒ 原样转发并回 {ok:true, result}', () async {
      remote.handler = (String method, Map<String, dynamic> params) =>
          <String, dynamic>{'method': method, 'params': params};
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.fsStat,
        <String, dynamic>{'path': '/ws/a.txt'},
      );
      expect(result['ok'], isTrue);
      expect(result['result']['method'], AgentMethods.fsStat);
      expect(result['result']['params']['path'], '/ws/a.txt');
    });

    test('exec.run 的 command 被登录外壳包一层（agent 收到最终字符串）', () async {
      remote.handler = (String method, Map<String, dynamic> params) =>
          <String, dynamic>{'command': params['command']};
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.execRun,
        <String, dynamic>{'command': 'nvcc --version'},
      );
      expect(result['result']['command'], "bash -lc 'nvcc --version'");
    });

    test('exec.run 之外的方法不改 command（后台任务保持 sh -c 口径）', () async {
      remote.handler = (String method, Map<String, dynamic> params) =>
          <String, dynamic>{'command': params['command']};
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.execSpawn,
        <String, dynamic>{'command': 'sleep 10'},
      );
      expect(result['result']['command'], 'sleep 10');
    });

    test('agent 回业务错误 ⇒ 透传 error_code/error_data，且**不带** error_kind（不回退）', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      // 握手之后再让 agent 对 fs.read 回业务错误（否则连 hello 都会被拒）
      remote.errorHandler = (String method, Map<String, dynamic> params) =>
          method == AgentMethods.fsRead
              ? <String, dynamic>{
                  'code': TunnelErrorCodes.notFound,
                  'message': '路径不存在',
                  'data': <String, dynamic>{'path': '/nope'},
                }
              : null;
      final Map<String, dynamic> result = await tunnel.request(
        AgentMethods.fsRead,
        <String, dynamic>{'path': '/nope'},
      );
      expect(result['ok'], isFalse, reason: result.toString());
      expect(result['error_code'], TunnelErrorCodes.notFound);
      expect(result['error_data']['path'], '/nope');
      expect(result.containsKey('error_kind'), isFalse);
      // 业务错误不该把隧道打成 reconnecting
      expect(tunnel.state, TunnelStates.ready);
    });
  });

  group('PTY 通知转发（tunnel/event）', () {
    test('shell.data / shell.exit 原样转给核心', () async {
      final Tunnel tunnel = build();
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      final FakeSshChannel channel = _liveChannel(remote);
      channel.emitNotification(AgentMethods.shellData, <String, dynamic>{
        'shell_id': 'sh-1',
        'data': 'aGk=',
      });
      channel.emitNotification(AgentMethods.shellExit, <String, dynamic>{
        'shell_id': 'sh-1',
        'exit_code': 3,
      });
      await pump(4);

      final List<Map<String, dynamic>> shellEvents = events
          .where((Map<String, dynamic> e) => e['kind'] != TunnelEventKind.state)
          .toList(growable: false);
      expect(shellEvents.length, 2);
      expect(shellEvents[0], <String, dynamic>{
        'conn_id': 'conn-1',
        'kind': TunnelEventKind.shellData,
        'shell_id': 'sh-1',
        'data': 'aGk=',
      });
      expect(shellEvents[1], <String, dynamic>{
        'conn_id': 'conn-1',
        'kind': TunnelEventKind.shellExit,
        'shell_id': 'sh-1',
        'exit_code': 3,
      });
    });

    test('未知通知只记日志、不污染事件面', () async {
      final List<String> logs = <String>[];
      final Tunnel tunnel = Tunnel(
        connId: 'conn-9',
        config: TunnelConfig.parse(configJson())!,
        agent: const AgentRequest(version: '1.2.3'),
        dialer: dialer.call,
        loadBinary: memoryBinary(List<int>.filled(64, 1)),
        timerFactory: timers.factory,
        onEvent: events.add,
        log: logs.add,
        chunkBytes: 64,
      );
      addTearDown(tunnel.close);
      await tunnel.ensureReady();
      _liveChannel(remote)
          .emitNotification('weird.thing', <String, dynamic>{'x': 1});
      await pump(4);
      expect(
        events.where((Map<String, dynamic> e) => e['kind'] != 'state'),
        isEmpty,
      );
      expect(logs.join('\n'), contains('weird.thing'));
    });
  });

  group('关闭', () {
    test('close 幂等：关通道 + 关连接，请求从此显式失败', () async {
      final Tunnel tunnel = build();
      await tunnel.ensureReady();
      await tunnel.close();
      await tunnel.close();
      expect(tunnel.isClosed, isTrue);
      expect(remote.closed, 1);
      final Map<String, dynamic> result =
          await tunnel.request(AgentMethods.fsStat, <String, dynamic>{});
      expect(result['ok'], isFalse);
      expect(result['error'], contains('已关闭'));
    });
  });
}

/// 取"这条隧道真正用的那条假通道"（FakeRemote 只保留最后一条）。
FakeSshChannel _liveChannel(FakeRemote remote) => remote.lastChannel!;
