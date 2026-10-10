import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'fake_ssh.dart';

/// 把通道上收到的写帧解出来（断言"插件发了什么"）。
List<Map<String, dynamic>> decodeWrites(FakeSshChannel channel) {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  final LineFrameDecoder decoder =
      LineFrameDecoder(onFrame: frames.add, onError: (String _) {});
  for (final List<int> bytes in channel.rawWrites) {
    decoder.add(bytes);
  }
  return frames;
}

void main() {
  late FakeRemote remote;
  late FakeSshChannel channel;
  late AgentClient client;
  late List<String> logs;
  late List<String> closedReasons;
  late List<String> notifications;

  setUp(() {
    remote = FakeRemote();
    channel = FakeSshChannel(remote);
    logs = <String>[];
    closedReasons = <String>[];
    notifications = <String>[];
    client = AgentClient(
      channel,
      log: logs.add,
      onClosed: closedReasons.add,
      onNotification: (String method, Map<String, dynamic> params) =>
          notifications.add(method),
    );
  });

  group('请求/响应配对', () {
    test('call 发一条合法请求帧并等配对响应', () async {
      final Map<String, dynamic> result =
          await client.call(AgentMethods.fsStat, <String, dynamic>{'path': '/a'});
      expect(result['ok'], isTrue);
      final List<Map<String, dynamic>> written = decodeWrites(channel);
      expect(written.single, <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': AgentMethods.fsStat,
        'params': <String, dynamic>{'path': '/a'},
      });
    });

    test('多条并发请求按 id 各自配对（不串号）', () async {
      remote.handler = (String method, Map<String, dynamic> params) =>
          <String, dynamic>{'echo': params['n']};
      final List<Map<String, dynamic>> results =
          await Future.wait(<Future<Map<String, dynamic>>>[
        client.call(AgentMethods.fsRead, <String, dynamic>{'n': 1}),
        client.call(AgentMethods.fsRead, <String, dynamic>{'n': 2}),
        client.call(AgentMethods.fsRead, <String, dynamic>{'n': 3}),
      ]);
      expect(
        results.map((Map<String, dynamic> r) => r['echo']).toList(),
        <Object?>[1, 2, 3],
      );
    });

    test('notify 发不带 id 的通知', () {
      client.notify(AgentMethods.shellWrite, <String, dynamic>{'shell_id': 's'});
      final Map<String, dynamic> frame = decodeWrites(channel).single;
      expect(frame['method'], AgentMethods.shellWrite);
      expect(frame.containsKey('id'), isFalse);
    });

    test('agent 回错误 ⇒ 抛 RpcException（码/消息/data 都在）', () async {
      remote.errorHandler = (String method, Map<String, dynamic> params) =>
          <String, dynamic>{
            'code': TunnelErrorCodes.notFound,
            'message': '路径不存在',
            'data': <String, dynamic>{'path': '/nope'},
          };
      await expectLater(
        client.call(AgentMethods.fsStat, <String, dynamic>{'path': '/nope'}),
        throwsA(
          isA<RpcException>()
              .having((RpcException e) => e.code, 'code', TunnelErrorCodes.notFound)
              .having((RpcException e) => e.message, 'message', '路径不存在')
              .having((RpcException e) => e.data, 'data', isNotNull),
        ),
      );
    });
  });

  group('通知与坏帧', () {
    test('agent 通知转给 onNotification', () async {
      channel.emitNotification(AgentMethods.shellData, <String, dynamic>{
        'shell_id': 'sh-1',
        'data': 'aGk=',
      });
      await pump(2);
      expect(notifications, <String>[AgentMethods.shellData]);
    });

    test('坏帧只报错、**不把通道搞哑**（后续请求照常）', () async {
      channel.emitRaw(utf8.encode('这不是 JSON\n'));
      channel.emitRaw(utf8.encode('{"jsonrpc":"2.0","id":1,}\n'));
      channel.emitRaw(utf8.encode('\n')); // 空行
      await pump(2);
      expect(logs.join('\n'), contains('坏帧'));
      final Map<String, dynamic> result = await client.call(AgentMethods.ping);
      expect(result['ok'], isTrue);
    });

    test('agent 反向发请求 ⇒ 插件明确回 -32601（不静默挂住它）', () async {
      channel.emitFrame(rpcRequest(7, 'agent.wants.something', <String, dynamic>{}));
      await pump(2);
      final Map<String, dynamic> response = decodeWrites(channel).single;
      expect(response['id'], 7);
      expect(response['error']['code'], RpcCodes.methodNotFound);
      expect(logs.join('\n'), contains('agent.wants.something'));
    });

    test('agent 的 stderr 只进日志、不进协议面', () async {
      channel.emitStderr(utf8.encode('agent 在抱怨\n'));
      await pump(2);
      expect(logs.join('\n'), contains('agent 在抱怨'));
      expect(client.isClosed, isFalse);
    });
  });

  group('通道死亡收口', () {
    test('通道断 ⇒ 在途请求全部以 AgentChannelClosed 收口，onClosed 只报一次', () async {
      remote.silentMethods.add(AgentMethods.fsStat);
      final Future<Map<String, dynamic>> inFlight =
          client.call(AgentMethods.fsStat, <String, dynamic>{'path': '/x'});
      await pump(2);
      channel.kill();
      await expectLater(inFlight, throwsA(isA<AgentChannelClosed>()));
      await pump(2);
      expect(client.isClosed, isTrue);
      expect(closedReasons, hasLength(1));
      // 退出码 / stdout 关闭谁先到都算"通道死了"，原因必须是可读的
      expect(closedReasons.single, anyOf(contains('stdout'), contains('exit')));
    });

    test('通道已关 ⇒ 新请求直接失败（不装作发出去了）', () async {
      channel.kill();
      await pump(2);
      await expectLater(
        client.call(AgentMethods.ping),
        throwsA(isA<AgentChannelClosed>()),
      );
    });

    test('close 幂等，且关掉之后 isClosed 为真', () async {
      await client.close();
      await client.close();
      expect(client.isClosed, isTrue);
    });

    test('agent 进程退出（exitCode 先到）也算通道死', () async {
      final FakeSshChannel exiting =
          FakeSshChannel(remote, exitCode: 3);
      final AgentClient other = AgentClient(exiting, log: logs.add);
      await pump(2);
      expect(other.isClosed, isTrue);
      expect(other.closedReason, contains('exit=3'));
    });
  });
}
