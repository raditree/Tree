import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'fake_ssh.dart';

/// L1 的测试台：喂 stdin 字节流、收 stdout 帧（就是一个"假核心"）。
class Harness {
  Harness({FakeRemote? remote, FakeTimers? timers}) {
    this.remote = remote ?? FakeRemote();
    this.timers = timers ?? FakeTimers();
    dialer = FakeDialer(this.remote);
    loop = PluginLoop(
      dialer: dialer.call,
      loadBinary: memoryBinary(List<int>.filled(64, 7)),
      send: frames.add,
      log: logs.add,
      timerFactory: this.timers.factory,
      chunkBytes: 64,
    );
    run = loop.run(input.stream);
  }

  late final FakeRemote remote;
  late final FakeTimers timers;
  late final FakeDialer dialer;
  late final PluginLoop loop;
  late final Future<int> run;

  final StreamController<List<int>> input = StreamController<List<int>>();
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  final List<String> logs = <String>[];

  /// 最近一次 `tunnel.ensure` 回的 `conn_id`。
  ///
  /// 用例**不该**硬编码 `conn-1`：`conn_id` 现在带**进程内随机前缀**
  /// （`conn-<rand4>-<seq>`），正是为了让"插件重启后序号重来"不再撞名
  /// （见 `TunnelManager._create` 的注释）。
  String? lastConnId;

  /// 发一条**请求**并等回包落进 [frames]。
  Future<void> request(
    int id,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    input.add(encodeFrame(rpcRequest(id, method, params)));
    await pump(10);
    if (method == TunnelMethods.ensure) {
      final Object? conn = resultOf(id)['conn_id'];
      if (conn is String && conn.isNotEmpty) lastConnId = conn;
    }
  }

  /// 发一条**通知**（无 id）。
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    input.add(encodeFrame(rpcNotification(method, params)));
    await pump(10);
  }

  Map<String, dynamic> reply(int id) =>
      frames.firstWhere((Map<String, dynamic> f) => f['id'] == id);

  Map<String, dynamic>? errorOf(int id) {
    final Object? error = reply(id)['error'];
    return error is Map
        ? error.map((dynamic k, dynamic v) => MapEntry('$k', v))
        : null;
  }

  Map<String, dynamic> resultOf(int id) {
    final Object? result = reply(id)['result'];
    return result is Map
        ? result.map((dynamic k, dynamic v) => MapEntry('$k', v))
        : <String, dynamic>{};
  }

  Future<void> dispose() async {
    await loop.shutdown();
    await input.close();
    await run;
  }
}

void main() {
  late Harness harness;

  setUp(() => harness = Harness());
  tearDown(() async => harness.dispose());

  group('标准方法（既有插件协议）', () {
    test('hello 申报 ssh-executor 能力（核心判断"有没有中转站"的唯一判据）', () async {
      await harness.request(1, 'hello', <String, dynamic>{'protocol': 1});
      final Map<String, dynamic> result = harness.resultOf(1);
      expect(result['plugin_id'], kPluginId);
      expect(result['name'], kPluginName);
      expect(result['version'], kPluginVersion);
      expect(result['protocol'], kTunnelProtocolVersion);
      expect(result['capabilities'], <String>[kCapabilitySshExecutor]);
    });

    test('ping 立即回 ok', () async {
      await harness.request(2, 'ping');
      expect(harness.resultOf(2), <String, dynamic>{'ok': true});
    });

    test('tools/list 回空表（执行器不申报任何工具）', () async {
      await harness.request(3, 'tools/list');
      expect(harness.resultOf(3), <String, dynamic>{'tools': <Object>[]});
    });

    test('未知方法 ⇒ -32601（**不静默**）', () async {
      await harness.request(4, 'tunnel.explode');
      final Map<String, dynamic>? error = harness.errorOf(4);
      expect(error, isNotNull);
      expect(error!['code'], RpcCodes.methodNotFound);
      expect(error['message'], contains('tunnel.explode'));
    });

    test('参数非法 ⇒ -32602（业务侧缺参，不静默）', () async {
      await harness.request(5, TunnelMethods.reconnect, <String, dynamic>{});
      final Map<String, dynamic>? error = harness.errorOf(5);
      expect(error!['code'], RpcCodes.invalidParams);
      expect(error['message'], contains('conn_id'));
    });
  });

  group('tunnel.ensure', () {
    test('建一条隧道并回 conn_id / root / agent', () async {
      await harness.request(10, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
        'agent': <String, dynamic>{'version': '1.2.3'},
      });
      final Map<String, dynamic> result = harness.resultOf(10);
      expect(result['ok'], isTrue);
      expect(result['conn_id'], matches(RegExp(r'^conn-[0-9a-z]{4}-1$')));
      expect(result['root'], '/home/tester');
      expect(result['agent']['version'], '1.2.3');
      expect(harness.remote.dials, 1);
    });

    test('同 key 再来一次 ⇒ 复用同一条（不重连、不重拉）', () async {
      await harness.request(11, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      await harness.request(12, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(password: '另一个口令'),
      });
      expect(harness.resultOf(11)['conn_id'], harness.lastConnId);
      expect(harness.resultOf(12)['conn_id'], harness.lastConnId);
      expect(harness.remote.dials, 1);
      expect(harness.remote.spawned.length, 1);
    });

    test('不同 host / root / login_shell ⇒ 不同 conn_id（去重按 key）', () async {
      await harness.request(13, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      await harness.request(14, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(host: '10.0.0.2'),
      });
      await harness.request(15, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(root: '/ws'),
      });
      await harness.request(16, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(loginShell: ''),
      });
      final List<String> ids = <String>[
        for (final int id in <int>[13, 14, 15, 16])
          harness.resultOf(id)['conn_id'].toString(),
      ];
      expect(ids.toSet().length, 4, reason: '不同 key ⇒ 不同 conn_id');
      for (final String id in ids) {
        expect(id, matches(RegExp(r'^conn-[0-9a-z]{4}-\d+$')));
      }
      expect(harness.remote.dials, 4);
    });

    test('config 不完整 ⇒ config_incomplete（不回退类），且**不建隧道**', () async {
      await harness.request(17, TunnelMethods.ensure, <String, dynamic>{
        'config': <String, dynamic>{'host': '10.0.0.1'},
      });
      final Map<String, dynamic> result = harness.resultOf(17);
      expect(result['ok'], isFalse);
      expect(result['error_kind'], TunnelErrorKinds.configIncomplete);
      expect(result['error'], contains('username'));
      expect(harness.remote.dials, 0);
      await harness.request(18, TunnelMethods.state);
      expect(harness.resultOf(18)['tunnels'], isEmpty);
    });

    test('架构不支持 ⇒ arch_unsupported（回退类）', () async {
      harness.remote.machine = 'riscv64';
      await harness.request(19, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      final Map<String, dynamic> result = harness.resultOf(19);
      expect(result['ok'], isFalse);
      expect(result['error_kind'], TunnelErrorKinds.archUnsupported);
      expect(
        shouldFallbackForErrorKind(result['error_kind'] as String),
        isTrue,
        reason: 'arch_unsupported 必须属于"回退内置"的那一类',
      );
    });

    test('连不上 ⇒ agent_unreachable（回退类）', () async {
      harness.dialer.failWith = (int attempt) => SshDialException('拒绝连接');
      await harness.request(20, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      final Map<String, dynamic> result = harness.resultOf(20);
      expect(result['error_kind'], TunnelErrorKinds.agentUnreachable);
      expect(
        shouldFallbackForErrorKind(result['error_kind'] as String),
        isTrue,
      );
    });
  });

  group('tunnel.state（权威判活面）', () {
    test('缺省 = 全部；带 conn_id = 这一条；未知 conn_id = 空表', () async {
      await harness.request(21, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      await harness.request(22, TunnelMethods.state);
      final List<dynamic> all = harness.resultOf(22)['tunnels'] as List<dynamic>;
      expect(all.length, 1);
      expect((all.single as Map<String, dynamic>)['state'], TunnelStates.ready);
      expect((all.single as Map<String, dynamic>)['host'], '10.0.0.1');

      await harness.request(23, TunnelMethods.state, <String, dynamic>{
        'conn_id': harness.lastConnId!,
      });
      expect((harness.resultOf(23)['tunnels'] as List<dynamic>).length, 1);

      await harness.request(24, TunnelMethods.state, <String, dynamic>{
        'conn_id': 'conn-404',
      });
      expect(harness.resultOf(24)['tunnels'], isEmpty);
    });

    test('state 里**没有**凭据（password 绝不外泄）', () async {
      await harness.request(25, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(password: 'hunter2'),
      });
      await harness.request(26, TunnelMethods.state);
      expect(harness.frames.toString().contains('hunter2'), isFalse);
      expect(harness.logs.join('\n').contains('hunter2'), isFalse);
      expect(harness.logs.join('\n'), contains('10.0.0.1:22/tester'));
    });
  });

  group('tunnel.request', () {
    test('把一次 L2 请求透传并回 {ok, result}', () async {
      await harness.request(30, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      harness.remote.handler =
          (String method, Map<String, dynamic> params) =>
              <String, dynamic>{'seen': method};
      await harness.request(31, TunnelMethods.request, <String, dynamic>{
        'conn_id': harness.lastConnId!,
        'method': AgentMethods.fsStat,
        'params': <String, dynamic>{'path': '/a'},
      });
      final Map<String, dynamic> result = harness.resultOf(31);
      expect(result['ok'], isTrue);
      expect(result['result']['seen'], AgentMethods.fsStat);
    });

    test('未知 conn_id ⇒ {ok:false, error_kind: tunnel_down}', () async {
      await harness.request(32, TunnelMethods.request, <String, dynamic>{
        'conn_id': 'conn-404',
        'method': AgentMethods.fsStat,
      });
      final Map<String, dynamic> result = harness.resultOf(32);
      expect(result['ok'], isFalse);
      expect(result['error_kind'], TunnelErrorKinds.tunnelDown);
    });

    test('缺 method ⇒ -32602（参数非法，不静默）', () async {
      await harness.request(33, TunnelMethods.request, <String, dynamic>{
        'conn_id': 'conn-any',
      });
      expect(harness.errorOf(33)!['code'], RpcCodes.invalidParams);
    });
  });

  group('tunnel.reconnect / tunnel.close', () {
    test('reconnect 已知 conn_id ⇒ 清零退避并立即重试', () async {
      harness.dialer.failWith =
          (int attempt) => attempt == 1 ? SshDialException('第一次失败') : null;
      await harness.request(40, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      expect(harness.resultOf(40)['error_kind'], TunnelErrorKinds.agentUnreachable);
      // ensure 失败时核心拿不到 conn_id，但隧道对象已经建在台账里 ⇒ 从台账取（用例只关心形状）。
      final String conn = harness.loop.manager.tunnels.single.connId;
      await harness.request(41, TunnelMethods.reconnect, <String, dynamic>{
        'conn_id': conn,
      });
      final Map<String, dynamic> result = harness.resultOf(41);
      expect(result['ok'], isTrue);
      expect(result['state'], TunnelStates.ready);
    });

    test('reconnect 未知 conn_id ⇒ ok:false（不装）', () async {
      await harness.request(42, TunnelMethods.reconnect, <String, dynamic>{
        'conn_id': 'conn-404',
      });
      expect(harness.resultOf(42)['ok'], isFalse);
    });

    test('close 收掉隧道（幂等）', () async {
      await harness.request(43, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      await harness.request(44, TunnelMethods.close, <String, dynamic>{
        'conn_id': harness.lastConnId!,
      });
      expect(harness.resultOf(44)['ok'], isTrue);
      expect(harness.remote.closed, 1);
      await harness.request(45, TunnelMethods.state);
      expect(harness.resultOf(45)['tunnels'], isEmpty);
      await harness.request(46, TunnelMethods.close, <String, dynamic>{
        'conn_id': harness.lastConnId!,
      });
      expect(harness.resultOf(46)['ok'], isTrue);
    });
  });

  group('SSH 执行中转站点位（station/subscribe + station/request）', () {
    test('hello 之后插件主动发一条 station/subscribe 订 ssh.execute', () async {
      await harness.request(60, PluginMethods.hello, <String, dynamic>{
        'protocol': 1,
      });
      // 出站订阅请求（插件 → 核心）：method=station/subscribe，point 显式指到 ssh.execute。
      final Map<String, dynamic> sub = harness.frames.firstWhere(
        (Map<String, dynamic> f) => f['method'] == StationMethods.subscribe,
      );
      expect(sub['params']['station'], SshExecuteStation.kind);
      expect(sub['params']['point'], SshExecuteStation.alias);
      expect(sub['params']['replace'], isTrue);
      // 订阅请求带 id（插件自有 id 空间，从 1 起），核心按 id 回响应。
      expect(sub['id'], isNotNull);
    });

    test('订阅成功（核心回 ok:true）⇒ 记一条已订阅日志', () async {
      await harness.request(61, PluginMethods.hello);
      final Map<String, dynamic> sub = harness.frames.firstWhere(
        (Map<String, dynamic> f) => f['method'] == StationMethods.subscribe,
      );
      // 用**插件自己的请求 id**回一条响应（无 method、有 id ⇒ isResponse）。
      harness.input.add(
        encodeFrame(
          rpcResult(sub['id'] as int, <String, dynamic>{'ok': true}),
        ),
      );
      await pump(10);
      expect(
        harness.logs.join('\n'),
        contains('已订阅 SSH 执行中转站点位'),
      );
    });

    test('订阅被旧核心拒（ok:false）⇒ 只记日志，旧路径不回归', () async {
      await harness.request(62, PluginMethods.hello);
      final Map<String, dynamic> sub = harness.frames.firstWhere(
        (Map<String, dynamic> f) => f['method'] == StationMethods.subscribe,
      );
      harness.input.add(
        encodeFrame(
          rpcResult(sub['id'] as int, <String, dynamic>{
            'ok': false,
            'error': '点位不存在',
          }),
        ),
      );
      await pump(10);
      expect(
        harness.logs.join('\n'),
        contains('旧路径 tunnel.* 继续可用'),
      );
    });

    test('station/request(action=ensure) ⇒ 建隧道并按 reply.payload 回形状', () async {
      await harness.request(70, StationMethods.request, <String, dynamic>{
        'station_id': SshExecuteStation.pointId,
        'request_id': 'relay-x',
        'payload': <String, dynamic>{
          'action': SshExecuteStation.ensure,
          'config': configJson(),
          'agent': <String, dynamic>{'version': '9.9.9'},
        },
      });
      final Map<String, dynamic> result = harness.resultOf(70);
      // 外层必须是 {reply:{payload:{...}}}（核心 requestStation 读 result['reply']）。
      expect(result.containsKey('reply'), isTrue);
      final Map<String, dynamic> payload =
          (result['reply']['payload'] as Map).map(
        (dynamic k, dynamic v) => MapEntry('$k', v),
      );
      expect(payload['ok'], isTrue);
      expect(payload['root'], '/home/tester');
      // agent 版本以**目标机握手自报**为准（协议 §6），与请求里带的版本无关——
      // 请求的 `agent` 只用于对账留痕，因此这里断言握手值而非入参值。
      expect(payload['agent']['version'], harness.remote.agentVersion);
      expect(harness.remote.dials, 1);
    });

    test('station/request(action=request/state/close) ⇒ 分发到同一套台账', () async {
      // 先经站点建一条隧道（复用 ensure 分发的同一 TunnelManager）。
      await harness.request(71, StationMethods.request, <String, dynamic>{
        'payload': <String, dynamic>{
          'action': SshExecuteStation.ensure,
          'config': configJson(),
        },
      });
      final String conn = harness.loop.manager.tunnels.single.connId;

      harness.remote.handler =
          (String method, Map<String, dynamic> params) =>
              <String, dynamic>{'seen': method};
      await harness.request(72, StationMethods.request, <String, dynamic>{
        'payload': <String, dynamic>{
          'action': SshExecuteStation.request,
          'conn_id': conn,
          'method': AgentMethods.fsStat,
          'params': <String, dynamic>{'path': '/a'},
        },
      });
      final Map<String, dynamic> reqPayload =
          (harness.resultOf(72)['reply']['payload'] as Map).map(
        (dynamic k, dynamic v) => MapEntry('$k', v),
      );
      expect(reqPayload['ok'], isTrue);
      expect(reqPayload['result']['seen'], AgentMethods.fsStat);

      await harness.request(73, StationMethods.request, <String, dynamic>{
        'payload': <String, dynamic>{
          'action': SshExecuteStation.state,
          'conn_id': conn,
        },
      });
      final Map<String, dynamic> statePayload =
          (harness.resultOf(73)['reply']['payload'] as Map).map(
        (dynamic k, dynamic v) => MapEntry('$k', v),
      );
      expect(statePayload['tunnels'], hasLength(1));

      await harness.request(74, StationMethods.request, <String, dynamic>{
        'payload': <String, dynamic>{
          'action': SshExecuteStation.close,
          'conn_id': conn,
        },
      });
      expect(harness.remote.closed, 1);
    });

    test('station/request 未知 action ⇒ {ok:false} 可读失败（核心据此回退）', () async {
      await harness.request(75, StationMethods.request, <String, dynamic>{
        'payload': <String, dynamic>{'action': 'explode'},
      });
      final Map<String, dynamic> payload =
          (harness.resultOf(75)['reply']['payload'] as Map).map(
        (dynamic k, dynamic v) => MapEntry('$k', v),
      );
      expect(payload['ok'], isFalse);
      expect(payload['error'], contains('explode'));
    });
  });

  group('生命周期与并发', () {
    test('ping **不会**被慢 ensure 堵住（读循环不 await 业务）', () async {
      harness.dialer.delay = const Duration(milliseconds: 40);
      harness.input.add(
        encodeFrame(
          rpcRequest(1, TunnelMethods.ensure, <String, dynamic>{
            'config': configJson(),
          }),
        ),
      );
      harness.input.add(encodeFrame(rpcRequest(2, 'ping')));
      // 只看**回包**（tunnel/event 是没有 id 的通知）
      List<Object?> replyIds() => harness.frames
          .where((Map<String, dynamic> f) => f['id'] != null)
          .map((Map<String, dynamic> f) => f['id'])
          .toList(growable: false);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      // 慢活在跑，但 ping 已经回了（铁律 2：必须并发）
      expect(replyIds(), <Object?>[2]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(replyIds(), <Object?>[2, 1]);
    });

    test('shutdown 通知 ⇒ 主循环收手退出（exit=0）', () async {
      await harness.notify('shutdown', const <String, dynamic>{});
      expect(await harness.run, 0);
      expect(harness.logs.join('\n'), contains('shutdown'));
    });

    test('shutdown 作为请求 ⇒ 先回 ok 再退出', () async {
      await harness.request(50, 'shutdown');
      expect(harness.resultOf(50), <String, dynamic>{'ok': true});
      expect(await harness.run, 0);
    });

    test('核心关掉 stdin ⇒ 主循环退出（exit=0）', () async {
      await harness.input.close();
      expect(await harness.run, 0);
    });

    test('状态跃迁会推 tunnel/event（及时性补充）', () async {
      await harness.request(51, TunnelMethods.ensure, <String, dynamic>{
        'config': configJson(),
      });
      final List<Map<String, dynamic>> events = harness.frames
          .where((Map<String, dynamic> f) => f['method'] == TunnelMethods.event)
          .toList(growable: false);
      expect(events, isNotEmpty);
      expect(events.first['params']['kind'], TunnelEventKind.state);
      expect(events.first['params']['conn_id'], harness.lastConnId);
      expect(events.last['params']['state'], TunnelStates.ready);
    });
  });
}
