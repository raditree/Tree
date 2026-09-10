// 前端执行器（本地 / SSH）tool_exec_request 归属校验单元测试。
//
// 背景：后端按"注册该 team 执行器的那条 WS 连接"定向投递（data.targeted=true）。
// 请求落到本端即说明后端认定本端是执行器，本端若不可执行必须明确回传错误，
// 否则后端会空等满卡死窗口（60s）后误判"前端卡死"并自动停用执行器注册。
// 未记录注册连接时的广播兜底（targeted=false）仍需静默放行：同用户其他实例
// 可能才是真正的执行器，抢先回错会占位并丢弃对方的成功结果。
//
// 运行方式（项目根目录）：
//   flutter test test/local_executor_tool_request_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/local_executor_service.dart';
import 'package:tree/io/ssh_executor_service.dart';
import 'package:tree/io/websocket_service.dart';

/// 假 WebSocket 服务：捕获发出的消息与注册进来的请求处理者。
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

Map<String, dynamic> _request({
  required String toolId,
  required String teamId,
  required bool targeted,
}) {
  return <String, dynamic>{
    'type': 'tool_exec_request',
    'data': <String, dynamic>{
      'tool_id': toolId,
      'team_id': teamId,
      'op': 'read_file',
      'workspace_id': teamId,
      'path': 'a.txt',
      'targeted': targeted,
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String teamId = 'top_test';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('本地执行器', () {
    final LocalExecutorService service = LocalExecutorService.instance;
    late _FakeWebSocketService ws;

    setUp(() {
      ws = _FakeWebSocketService();
      service.attach(ws);
    });

    tearDown(() async {
      service.deactivateTeam(teamId);
      service.cleanup();
      // SSH 优先用例会写入 SSH 启用态，一并复位
      await SshExecutorService.instance.deactivateTeam(teamId);
    });

    test('targeted=true 未知 team：明确回传错误并接管请求（避免后端空等 60s）', () {
      final bool handled = ws.requestHandlers.single(
        _request(toolId: 't1', teamId: teamId, targeted: true),
      );

      expect(handled, isTrue);
      final Map<String, dynamic>? resp = ws.lastResponse();
      expect(resp, isNotNull);
      expect(resp!['data']['tool_id'], 't1');
      expect(resp['data']['result']['error'], isNotEmpty);
    });

    test('targeted=true 已启用但未注册（registration_lost 复位后）：明确回传错误',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'local_exec_enabled_$teamId': true,
        'local_exec_working_dir_$teamId': 'C:/proj',
      });
      // 只恢复设置（enabled=true，registered 仍为 false）
      await service.loadTeamSettings(teamId);

      final bool handled = ws.requestHandlers.single(
        _request(toolId: 't2', teamId: teamId, targeted: true),
      );

      expect(handled, isTrue);
      final Map<String, dynamic>? resp = ws.lastResponse();
      expect(resp, isNotNull);
      expect(resp!['data']['tool_id'], 't2');
      expect(resp['data']['result']['error'], isNotEmpty);
    });

    test('targeted=false 未知 team：静默放行，不回传任何响应', () {
      final bool handled = ws.requestHandlers.single(
        _request(toolId: 't3', teamId: teamId, targeted: false),
      );

      expect(handled, isFalse);
      expect(ws.lastResponse(), isNull);
    });

    test('缺少 targeted 字段（旧后端）：按广播语义静默放行', () {
      final Map<String, dynamic> message =
          _request(toolId: 't4', teamId: teamId, targeted: false);
      (message['data'] as Map<String, dynamic>).remove('targeted');

      expect(ws.requestHandlers.single(message), isFalse);
      expect(ws.lastResponse(), isNull);
    });

    test('该 team 已启用 SSH：即便 targeted=true 也让位给 SSH 执行器', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ssh_exec_enabled_$teamId': true,
      });
      await SshExecutorService.instance.loadTeamSettings(teamId);
      expect(SshExecutorService.instance.isTeamEnabled(teamId), isTrue);

      final bool handled = ws.requestHandlers.single(
        _request(toolId: 't5', teamId: teamId, targeted: true),
      );

      // 放行（false）交由 SSH 执行器接管，且不得抢先回错占位
      expect(handled, isFalse);
      expect(ws.lastResponse(), isNull);
    });
  });

  group('SSH 执行器', () {
    final SshExecutorService service = SshExecutorService.instance;
    late _FakeWebSocketService ws;

    setUp(() {
      ws = _FakeWebSocketService();
      service.attach(ws);
    });

    tearDown(() async {
      service.cleanup();
      await service.deactivateTeam(teamId);
    });

    test('targeted=true 未知 team：明确回传错误并接管请求', () {
      final bool handled = ws.requestHandlers.single(
        _request(toolId: 's1', teamId: teamId, targeted: true),
      );

      expect(handled, isTrue);
      final Map<String, dynamic>? resp = ws.lastResponse();
      expect(resp, isNotNull);
      expect(resp!['data']['tool_id'], 's1');
      expect(resp['data']['result']['error'], isNotEmpty);
    });

    test('targeted=false 未知 team：静默放行，不回传任何响应', () {
      final bool handled = ws.requestHandlers.single(
        _request(toolId: 's2', teamId: teamId, targeted: false),
      );

      expect(handled, isFalse);
      expect(ws.lastResponse(), isNull);
    });
  });
}
