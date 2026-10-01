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
///
/// **判活窗口（I × N）的取值约束（2026-10-01 排障结论）**：本文件的假服务是
/// `dart <fixture>.dart` —— 一个**冷启动**的子进程（起 VM + 加载脚本）。整套用例
/// 并发跑时实测冷启动会明显超过 450ms，此时窗口太窄会把"还没起来"判成"心跳丢了"，
/// `McpClient.start` 的握手直接失败（这正是它此前在核心全量里偶发 -2/-4 的原因）。
/// 因此窗口必须同时满足：
///   ① **> 并发负载下的冷启动**（实测留到 1.5s 才稳）；
///   ② **< 假服务的沉默时长**（否则沉默结束、心跳回来了，就永远等不到判死）。
/// 下面统一用 `300ms × 5 = 1.5s`，沉默时长给到 4s（比值留 2.5s 余量）。
/// 另外：**等状态一律轮询，别固定睡**——固定睡在负载下会因计时器延后假失败。
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
    // 握手正常，随后服务沉默 4s（远大于判活窗口 I×N = 1.5s）：连 ping 都不回。
    // 窗口留足余量是刻意的：并发跑时假服务（dart 脚本）冷启动可能超过 1s，
    // 窗口太窄会把"还没起来"误判成"心跳丢了"（见文件头的取值约束）。
    final McpClient client = await McpClient.start(
      config(extra: <String>['--deaf-for=4000']),
      heartbeatInterval: const Duration(milliseconds: 300),
      missedHeartbeatLimit: 5,
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
      lessThan(4000),
      reason: '沉默窗口（4s）还没结束就该按心跳判死：判据是心跳丢失，不是任何静态超时',
    );
    expect(client.isDegraded, isTrue, reason: '连续 N 次丢失要标记 degraded');
    expect(client.degradeCount, greaterThan(0));
    expect(client.liveness.missedCount, greaterThanOrEqualTo(5));
    expect(client.isClosed, isFalse, reason: '判失活不杀进程：恢复后还能用');

    // 失活期间的新请求**立刻**显式失败：不再往一条判死的链路上发东西
    final Stopwatch immediate = Stopwatch()..start();
    await expectLater(
      client.callTool('echo', <String, dynamic>{'text': 'y'}),
      throwsA(isA<McpLivenessException>()),
    );
    immediate.stop();
    expect(
      immediate.elapsedMilliseconds,
      lessThan(1000),
      reason: '远小于判活窗口（1.5s）：失活后不再等下一拍',
    );
  });

  test('心跳正常的长请求：远超判活窗口也不被总时长打断', () async {
    final McpClient client = await McpClient.start(
      config(),
      heartbeatInterval: const Duration(milliseconds: 300),
      missedHeartbeatLimit: 5, // 判活窗口 = 1.5s
    );
    addTearDown(client.close);

    final Stopwatch watch = Stopwatch()..start();
    // 服务端跑 4s（≈2.7 个判活窗口）才回包，期间照常回 ping
    final McpCallResult slow = await client
        .callTool('slow-alive', <String, dynamic>{'ms': 4000})
        .timeout(const Duration(seconds: 20));
    watch.stop();

    expect(slow.isError, isFalse);
    expect(slow.text, contains('慢慢做完'));
    expect(
      watch.elapsedMilliseconds,
      greaterThan(1500),
      reason: '确实跑过了判活窗口——若还有静态超时，这里必失败',
    );
    expect(client.isDegraded, isFalse);
    expect(client.liveness.missedCount, 0, reason: '一直在回 ping，不该记丢失');
  });

  test('心跳恢复后自动清除失活标记：同一连接继续可用（不重连）', () async {
    final McpClient client = await McpClient.start(
      config(extra: <String>['--deaf-for=4000']),
      heartbeatInterval: const Duration(milliseconds: 300),
      missedHeartbeatLimit: 5, // 判活窗口 = 1.5s（要容得下并发负载下的冷启动）
    );
    addTearDown(client.close);

    await expectLater(
      client
          .callTool('echo', <String, dynamic>{'text': '第一次'})
          .timeout(const Duration(seconds: 20)),
      throwsA(isA<McpLivenessException>()),
    );
    expect(client.isDegraded, isTrue);

    // 等"失活标记自动清除"：**轮询，不固定睡**——固定睡在并发负载下会因心跳计时器
    // 延后而假失败（本文件此前就是这么 flaky 的）。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (client.isDegraded && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(client.isDegraded, isFalse, reason: '收到回包（心跳）后自动清除');
    expect(client.isClosed, isFalse);

    final McpCallResult ok = await client
        .callTool('echo', <String, dynamic>{'text': '第二次'})
        .timeout(const Duration(seconds: 20));
    expect(ok.text, 'echo: 第二次');
  });

  test('服务端不实现 ping（回 method-not-found）也算心跳：不误判失活', () async {
    final McpClient client = await McpClient.start(
      config(extra: <String>['--no-ping']),
      heartbeatInterval: const Duration(milliseconds: 300),
      missedHeartbeatLimit: 5, // 判活窗口 = 1.5s（容得下冷启动）
    );
    addTearDown(client.close);

    // 5 拍以上（2500ms > 判活窗口 1500ms）：ping 的错误回包必须被算作心跳
    await Future<void>.delayed(const Duration(milliseconds: 2500));
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
