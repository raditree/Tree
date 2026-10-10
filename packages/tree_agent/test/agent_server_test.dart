import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

void main() {
  late Directory root;
  late String rootPath;
  late String stateDir;

  setUp(() {
    root = createTempRoot('server');
    rootPath = toPosix(root.path);
    stateDir = '$rootPath/state';
  });

  tearDown(() => removeTempRoot(root));

  /// 起一个 server，把内存流当 stdin/stdout 用。
  _Harness start({Duration? idleTimeout}) {
    final AgentConfig config = AgentConfig(
      root: rootPath,
      token: 'sekret',
      stateDir: stateDir,
      idleTimeout: idleTimeout,
      home: '/home/u',
    );
    return _Harness(AgentServer(config: config));
  }

  group('agent.hello（握手）', () {
    test('token + protocol 都对 ⇒ ok，回 agent_version/os/arch/home/root/pid', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.request(1, AgentMethods.hello, <String, dynamic>{
        'protocol': kAgentProtocolVersion,
        'token': 'sekret',
        'agent_version': kAgentVersion,
      });
      final Map<String, dynamic> result =
          (reply['result'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      expect(result['protocol'], kAgentProtocolVersion);
      expect(result['ok'], true);
      expect(result['agent_version'], kAgentVersion);
      expect(result['os'], Platform.operatingSystem);
      expect(result['arch'], AgentConfig.detectArch());
      expect(result['home'], '/home/u');
      expect(result['root'], rootPath);
      expect(result['pid'], isA<int>());
    });

    test('token 不对 ⇒ -32007 handshake_failed', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.request(1, AgentMethods.hello, <String, dynamic>{
        'protocol': kAgentProtocolVersion,
        'token': 'wrong',
      });
      expect(
        (reply['error'] as Map<dynamic, dynamic>)['code'],
        TunnelErrorCodes.handshakeFailed,
      );
    });

    test('协议不匹配 ⇒ -32008 protocol_mismatch（插件据此报 handshake_failed 回退）', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.request(1, AgentMethods.hello, <String, dynamic>{
        'protocol': kAgentProtocolVersion + 1,
        'token': 'sekret',
      });
      expect(
        (reply['error'] as Map<dynamic, dynamic>)['code'],
        TunnelErrorCodes.protocolMismatch,
      );
    });
  });

  group('agent.ping / agent.info', () {
    test('ping 回 {ok, at_ms}', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.request(2, AgentMethods.ping);
      final Map<String, dynamic> result =
          (reply['result'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      expect(result['ok'], true);
      expect(result['at_ms'], isA<int>());
    });

    test('info 回目标机信息 + uptime_ms', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.request(3, AgentMethods.info);
      final Map<String, dynamic> result =
          (reply['result'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      expect(result['root'], rootPath);
      expect(result['home'], '/home/u');
      expect(result['agent_version'], kAgentVersion);
      expect(result['uptime_ms'], isA<int>());
    });
  });

  group('分发与帧纪律', () {
    test('未知方法 ⇒ -32601 method_not_found', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.request(9, 'nope.nope');
      expect(
        (reply['error'] as Map<dynamic, dynamic>)['code'],
        RpcCodes.methodNotFound,
      );
    });

    test('fs.* 走通（经服务端：路径越界 ⇒ -32001，正常 ⇒ 结果）', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> denied = await h.request(4, AgentMethods.fsRead, <String, dynamic>{
        'path': '/etc/passwd',
      });
      expect(
        (denied['error'] as Map<dynamic, dynamic>)['code'],
        TunnelErrorCodes.pathOutOfRoot,
      );

      await File('$rootPath/a.txt').writeAsString('hi');
      final Map<String, dynamic> ok = await h.request(5, AgentMethods.fsRead, <String, dynamic>{
        'path': '$rootPath/a.txt',
      });
      final Map<String, dynamic> result =
          (ok['result'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      expect(utf8.decode(base64Decode(result['data'] as String)), 'hi');
      expect(result['size'], 2);
      expect(result['eof'], true);
    });

    test('params 不是对象 ⇒ -32602 invalid_params（不是崩掉整条通道）', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      final Map<String, dynamic> reply = await h.requestFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 6,
        'method': AgentMethods.ping,
        'params': <int>[1, 2],
      });
      expect(
        (reply['error'] as Map<dynamic, dynamic>)['code'],
        RpcCodes.invalidParams,
      );

      final Map<String, dynamic> ping = await h.request(7, AgentMethods.ping);
      expect(ping['result'], isA<Map<dynamic, dynamic>>(), reason: '通道还活着');
    });

    test('坏帧（非法 JSON）被丢弃，通道继续可用', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      h.feedRaw(utf8.encode('这不是一个 JSON 帧\n'));
      h.feedRaw(utf8.encode('\n')); // 空行直接跳过
      final Map<String, dynamic> reply = await h.request(8, AgentMethods.ping);
      expect((reply['result'] as Map<dynamic, dynamic>)['ok'], true);
    });

    test('**stdout 上只有协议帧**：每一段输出都是合法 JSON-RPC 对象', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      await h.request(1, AgentMethods.ping);
      await h.request(2, 'nope.nope');
      expect(h.rawFrames, isNotEmpty);
      for (final List<int> frame in h.rawFrames) {
        final String text = utf8.decode(frame);
        expect(text.endsWith('\n'), true, reason: '行分隔：一帧一行');
        final Object? decoded = jsonDecode(text.trim());
        expect(decoded, isA<Map<String, dynamic>>());
        expect((decoded! as Map<String, dynamic>)['jsonrpc'], '2.0');
      }
    });
  });

  group('生命周期', () {
    test('stdin EOF ⇒ agent 退出（通道断 = agent 退，退出码 0）', () async {
      final _Harness h = start();
      final int code = await h.stop();
      expect(code, 0);
    });

    test('--idle-timeout-ms > 0：期间没有帧进来就退出', () async {
      final _Harness h = start(idleTimeout: const Duration(milliseconds: 200));
      final int code = await h.done;
      expect(code, 0);
      await h.stop();
    });

    test('缺省 idleTimeout = null ⇒ 永不（不会自己退出）', () async {
      final _Harness h = start();
      addTearDown(h.stop);
      bool finished = false;
      unawaited(h.done.then((int _) => finished = true));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(finished, false, reason: '没有静态总时长上限');
    });
  });
}

/// 把内存流接成 agent 的两端，并提供"发一条请求、等它的响应"。
class _Harness {
  _Harness(this.server)
    : _messages = StreamController<Map<String, dynamic>>.broadcast() {
    _done = server.serve(
      input: _input.stream,
      emit: (List<int> bytes) async {
        rawFrames.add(bytes);
        _messages.add(
          (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>),
        );
      },
    );
  }

  final AgentServer server;
  final StreamController<List<int>> _input =
      StreamController<List<int>>();
  final StreamController<Map<String, dynamic>> _messages;
  final List<List<int>> rawFrames = <List<int>>[];

  late final Future<int> _done;

  Future<int> get done => _done;

  void feedRaw(List<int> bytes) => _input.add(bytes);

  Future<Map<String, dynamic>> request(
    int id,
    String method, [
    Map<String, dynamic>? params,
  ]) => requestFrame(rpcRequest(id, method, params));

  /// 直接送一条**手写帧**（用于构造非法 params 之类的形状）。
  Future<Map<String, dynamic>> requestFrame(Map<String, dynamic> frame) async {
    final Object? id = frame['id'];
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    final StreamSubscription<Map<String, dynamic>> subscription = _messages.stream
        .listen((Map<String, dynamic> message) {
          if (message['method'] == null &&
              message['id'] == id &&
              !completer.isCompleted) {
            completer.complete(message);
          }
        });
    _input.add(encodeFrame(frame));
    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      await subscription.cancel();
    }
  }

  /// 收尾：关掉 stdin（= 通道断），等 agent 退出。
  Future<int> stop() async {
    if (!_input.isClosed) await _input.close();
    final int code = await _done;
    if (!_messages.isClosed) await _messages.close();
    return code;
  }
}
