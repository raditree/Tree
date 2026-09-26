import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// MCP 客户端的**心跳判活**用例（M9 规约 1.1：取消静态时间超时）。
///
/// 判据只有一条：**连续 N 拍心跳没达**。所以：
/// - 服务沉默（连 ping 都不回）⇒ 在途请求以显式「心跳丢失」错误结束，不永久挂起；
/// - 服务很慢但**照常回 ping** ⇒ 跑多久都不打断（"总时长"不再是判据）；
/// - 心跳恢复 ⇒ 失活标记自动清除，同一连接继续可用；
/// - 服务端不实现 ping（回 method-not-found）⇒ 错误回包也算心跳，不误判。
void main() {
  late String script;

  setUpAll(() {
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_mcp_server.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假 MCP 服务脚本必须存在');
  });

  McpServerConfig config({List<String> extra = const <String>[]}) =>
      McpServerConfig(
        name: 'fake',
        command: Platform.resolvedExecutable,
        args: <String>[script, ...extra],
      );

  test('心跳窗口内无响应：在途请求以「心跳丢失」显式结束（不挂起、不静默）', () async {
    // 握手正常，随后服务沉默 1500ms（远大于判活窗口 I×N = 450ms）：连 ping 都不回。
    // 参数留足余量是刻意的：进程冷启动（dart 脚本约 250ms）也落在心跳窗口内，
    // 窗口太窄会把"还没起来"误判成"心跳丢了"。
    final McpClient client = await McpClient.start(
      config(extra: <String>['--deaf-for=1500']),
      heartbeatInterval: const Duration(milliseconds: 150),
      missedHeartbeatLimit: 3,
    );
    addTearDown(client.close);
    expect(client.isDegraded, isFalse, reason: '握手期间心跳是好的');
    expect(client.liveness.lastBeatAt, isNotNull, reason: '握手回包就是一次心跳');

    final Stopwatch watch = Stopwatch()..start();
    await expectLater(
      client
          .callTool('echo', <String, dynamic>{'text': 'x'})
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<McpLivenessException>().having(
          (McpLivenessException e) => e.message,
          'message',
          allOf(contains('心跳丢失'), contains('链路失活'), contains('心跳间隔')),
        ),
      ),
    );
    watch.stop();
    expect(
      watch.elapsedMilliseconds,
      lessThan(1200),
      reason: '沉默窗口还没结束就该按心跳判死（不是等某个静态超时）',
    );
    expect(client.isDegraded, isTrue, reason: '连续 N 次丢失要标记 degraded');
    expect(client.degradeCount, greaterThan(0));
    expect(client.liveness.missedCount, greaterThanOrEqualTo(3));
    expect(client.isClosed, isFalse, reason: '判失活不杀进程：恢复后还能用');

    // 失活期间的新请求**立刻**显式失败：不再往一条判死的链路上发东西
    final Stopwatch immediate = Stopwatch()..start();
    await expectLater(
      client.callTool('echo', <String, dynamic>{'text': 'y'}),
      throwsA(isA<McpLivenessException>()),
    );
    immediate.stop();
    expect(immediate.elapsedMilliseconds, lessThan(200));
  });

  test('心跳正常的长请求：远超判活窗口也不被总时长打断', () async {
    final McpClient client = await McpClient.start(
      config(),
      heartbeatInterval: const Duration(milliseconds: 150),
      missedHeartbeatLimit: 3, // 判活窗口 = 450ms
    );
    addTearDown(client.close);

    final Stopwatch watch = Stopwatch()..start();
    // 服务端跑 900ms（= 3 个判活窗口）才回包，期间照常回 ping
    final McpCallResult slow = await client
        .callTool('slow-alive', <String, dynamic>{'ms': 900})
        .timeout(const Duration(seconds: 10));
    watch.stop();

    expect(slow.isError, isFalse);
    expect(slow.text, contains('慢慢做完'));
    expect(
      watch.elapsedMilliseconds,
      greaterThan(450),
      reason: '确实跑过了判活窗口——若还有静态超时，这里必失败',
    );
    expect(client.isDegraded, isFalse);
    expect(client.liveness.missedCount, 0, reason: '一直在回 ping，不该记丢失');
  });

  test('心跳恢复后自动清除失活标记：同一连接继续可用（不重连）', () async {
    final McpClient client = await McpClient.start(
      config(extra: <String>['--deaf-for=1500']),
      heartbeatInterval: const Duration(milliseconds: 150),
      missedHeartbeatLimit: 3, // 判活窗口 = 450ms（要容得下进程冷启动）
    );
    addTearDown(client.close);

    await expectLater(
      client
          .callTool('echo', <String, dynamic>{'text': '第一次'})
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<McpLivenessException>()),
    );
    expect(client.isDegraded, isTrue);

    // 沉默窗口过去 + 若干拍心跳（等得宽裕些，避免机器慢导致抖动）
    await Future<void>.delayed(const Duration(milliseconds: 2400));
    expect(client.isDegraded, isFalse, reason: '收到回包（心跳）后自动清除');
    expect(client.isClosed, isFalse);

    final McpCallResult ok = await client
        .callTool('echo', <String, dynamic>{'text': '第二次'})
        .timeout(const Duration(seconds: 10));
    expect(ok.text, 'echo: 第二次');
  });

  test('服务端不实现 ping（回 method-not-found）也算心跳：不误判失活', () async {
    final McpClient client = await McpClient.start(
      config(extra: <String>['--no-ping']),
      heartbeatInterval: const Duration(milliseconds: 250),
      missedHeartbeatLimit: 3, // 判活窗口 = 750ms（容得下冷启动）
    );
    addTearDown(client.close);

    // 5 拍以上（1500ms > 判活窗口 750ms）：ping 的错误回包必须被算作心跳
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(client.isDegraded, isFalse, reason: '回包（哪怕是错误回包）就是链路活着的证据');

    final McpCallResult echo = await client.callTool('echo', <String, dynamic>{
      'text': 'B',
    });
    expect(echo.text, 'echo: B');
  });

  test('服务一声不吭时，McpService 把心跳丢失变成模型可读的错误结果', () async {
    final Directory temp = Directory.systemTemp.createTempSync(
      'tree_mcp_live_',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final McpService service = McpService(
      configFile: p.join(temp.path, 'config', 'mcp.yaml'),
      heartbeatInterval: const Duration(milliseconds: 250),
      missedHeartbeatLimit: 2,
    );
    addTearDown(service.close);
    await service.register(<String, dynamic>{
      'name': 'deaf',
      'command': Platform.resolvedExecutable,
      'args': <String>[script, '--silent'],
    });

    // 注册（连接 + 拉工具）本身就会因心跳丢失失败：错误可读、不抛异常
    final McpCallResult failed = await service
        .callTool('mcp__deaf__echo', <String, dynamic>{'text': 'z'})
        .timeout(const Duration(seconds: 10));
    expect(failed.isError, isTrue);
    expect(failed.text, contains('心跳丢失'));
  });
}
