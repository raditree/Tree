// 本地执行器 plugin_host_* op 分发接入测试（M2：宿主通道）。
//
// 覆盖：op → 宿主管理器接线（start/stop/status 回传字段）、载荷容忍
// （畸形 payload 不报错）、缺 host_key 快速失败、未知会话幂等 / 回错、
// stop→status 全链路。进程启动器经 [LocalExecutorService.debugSetPluginHostManager]
// 注入 fake，不依赖真进程。
//
// 运行方式（项目根目录）：
//   flutter test test/local_executor_plugin_host_dispatch_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/local_executor_service.dart';
import 'package:tree/io/plugin_host_sessions.dart';
import 'package:tree/io/websocket_service.dart';

/// 假 WebSocket 服务：捕获发出的消息与注册进来的请求处理者（同既有测试口径）。
class _FakeWebSocketService extends WebSocketService {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// attach 时注册进来的 tool_exec_request 处理者
  final List<bool Function(Map<String, dynamic> message)> requestHandlers =
      <bool Function(Map<String, dynamic> message)>[];

  @override
  void send(Map<String, dynamic> message) {
    sent.add(message);
  }

  @override
  void addToolExecRequestHandler(ToolExecRequestHandler handler) {
    requestHandlers.add(handler);
    super.addToolExecRequestHandler(handler);
  }

  /// 最近一条 ``tool_exec_response``（无则返回 null）
  Map<String, dynamic>? lastResponse() {
    for (final Map<String, dynamic> message in sent.reversed) {
      if (message['type'] == 'tool_exec_response') return message;
    }
    return null;
  }
}

const String _teamId = 'top_m2';

Map<String, dynamic> _request({
  required String op,
  String? hostKey,
  String? hostSessionId,
  Object? payload,
  bool targeted = true,
}) {
  return <String, dynamic>{
    'type': 'tool_exec_request',
    'data': <String, dynamic>{
      'tool_id': 't_$op',
      'team_id': _teamId,
      'op': op,
      if (hostKey != null) 'host_key': hostKey,
      if (hostSessionId != null) 'host_session_id': hostSessionId,
      if (payload != null) 'payload': payload,
      'targeted': targeted,
      // plugin_host_* 用 team 工作目录，workspace_id 仅为信封齐备
      'workspace_id': _teamId,
    },
  };
}

PluginHostProcessHandle _fakeHandle() {
  return PluginHostProcessHandle(
    pid: 4242,
    exitCode: Completer<int>().future,
    stderr: const Stream<List<int>>.empty(),
    kill: () => true,
  );
}

Map<String, dynamic> _resultOf(Map<String, dynamic>? response) {
  return (response!['data'] as Map<String, dynamic>)['result']
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final LocalExecutorService service = LocalExecutorService.instance;
  late _FakeWebSocketService ws;
  late List<PluginHostSpawnRequest> spawnRequests;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'local_exec_enabled_$_teamId': true,
      'local_exec_working_dir_$_teamId': 'C:/proj',
    });
    ws = _FakeWebSocketService();
    service.attach(ws);
    await service.loadTeamSettings(_teamId);
    await service.ensureTeam(_teamId); // 启用 + 目录 → 注册（registered=true）
    spawnRequests = <PluginHostSpawnRequest>[];
    service.debugSetPluginHostManager(PluginHostSessionManager(
      spawn: (PluginHostSpawnRequest request) async {
        spawnRequests.add(request);
        return _fakeHandle();
      },
      notify: (Map<String, dynamic> _) {},
    ));
  });

  tearDown(() {
    service.deactivateTeam(_teamId);
    service.cleanup();
  });

  test('plugin_host_start：分发到宿主管理器，回传 host_session_id（cwd=team 工作目录）',
      () async {
    final bool handled = ws.requestHandlers
        .single(_request(op: 'plugin_host_start', hostKey: 'k1'));
    expect(handled, isTrue);
    await pumpEventQueue();

    final Map<String, dynamic> result = _resultOf(ws.lastResponse());
    expect(result['host_session_id'], startsWith('phs_'));
    expect(spawnRequests, hasLength(1));
    expect(spawnRequests.single.teamId, _teamId);
    expect(spawnRequests.single.workingDirectory, 'C:/proj');
  });

  test('plugin_host_start：畸形 payload（非 Map）容忍，不影响建立', () async {
    final bool handled = ws.requestHandlers.single(
      _request(op: 'plugin_host_start', hostKey: 'k2', payload: 'not-a-map'),
    );
    expect(handled, isTrue);
    await pumpEventQueue();
    expect(_resultOf(ws.lastResponse())['host_session_id'], startsWith('phs_'));
  });

  test('plugin_host_start：缺 host_key → error 且不触达启动器', () async {
    ws.requestHandlers.single(_request(op: 'plugin_host_start'));
    await pumpEventQueue();
    expect(_resultOf(ws.lastResponse())['error'], contains('host_key'));
    expect(spawnRequests, isEmpty);
  });

  test('plugin_host_stop：未知会话幂等回 ok', () async {
    ws.requestHandlers.single(
      _request(op: 'plugin_host_stop', hostSessionId: 'phs_none'),
    );
    await pumpEventQueue();
    expect(_resultOf(ws.lastResponse())['ok'], isTrue);
  });

  test('plugin_host_status：未知会话回 error', () async {
    ws.requestHandlers.single(
      _request(op: 'plugin_host_status', hostSessionId: 'phs_none'),
    );
    await pumpEventQueue();
    expect(_resultOf(ws.lastResponse())['error'], isNotEmpty);
  });

  test('start→stop→status 全链路：stop 后 status 可查（closed）', () async {
    ws.requestHandlers.single(_request(op: 'plugin_host_start', hostKey: 'k9'));
    await pumpEventQueue();
    final String id =
        _resultOf(ws.lastResponse())['host_session_id'] as String;

    ws.requestHandlers.single(
      _request(op: 'plugin_host_stop', hostSessionId: id),
    );
    await pumpEventQueue();
    expect(_resultOf(ws.lastResponse())['ok'], isTrue);

    ws.requestHandlers.single(
      _request(op: 'plugin_host_status', hostSessionId: id),
    );
    await pumpEventQueue();
    expect(_resultOf(ws.lastResponse())['state'], 'closed');
  });
}
