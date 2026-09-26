import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// MCP stdio 客户端（M6a）：**真进程**验证握手、工具列表、调用、超时与错误。
///
/// 假服务是一个 Dart 脚本（`test/fixtures/fake_mcp_server.dart`），通过 stdio
/// 说 JSON-RPC —— 与本机任何真实 MCP Server 走的是同一条路径。
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

  test('握手 → tools/list → tools/call 全链路', () async {
    final McpClient client = await McpClient.start(config());
    addTearDown(client.close);
    expect(client.serverInfo['name'], 'fake-mcp');
    expect(client.protocolVersion, '2024-11-05');
    expect(client.isClosed, isFalse);

    final List<McpToolInfo> tools = await client.listTools();
    expect(tools.map((McpToolInfo t) => t.name), <String>['echo', 'slow']);
    expect(tools.first.description, '回显输入');
    expect(
      (tools.first.inputSchema['properties'] as Map<String, dynamic>)
          .containsKey('text'),
      isTrue,
      reason: 'inputSchema 被原样保留（模型据此填参数）',
    );

    final McpCallResult echo = await client.callTool('echo', <String, dynamic>{
      'text': '你好',
    });
    expect(echo.isError, isFalse);
    expect(echo.text, 'echo: 你好');

    final McpCallResult unknown = await client.callTool(
      'nope',
      <String, dynamic>{},
    );
    expect(unknown.isError, isTrue);
    expect(unknown.text, contains('未知工具 nope'));
  });

  test('工具超时 → 可读异常（不让核心永久挂着）', () async {
    final McpClient client = await McpClient.start(config());
    addTearDown(client.close);
    await expectLater(
      client.callTool(
        'slow',
        <String, dynamic>{},
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<McpException>().having(
          (McpException e) => e.message,
          'message',
          contains('超时'),
        ),
      ),
    );
  });

  test('握手失败 → 报错里带服务给出的原因', () async {
    await expectLater(
      McpClient.start(config(extra: <String>['--fail-init'])),
      throwsA(
        isA<McpException>().having(
          (McpException e) => e.message,
          'message',
          contains('拒绝初始化'),
        ),
      ),
    );
  });

  test('command 为空 → 立刻报可读错误；关闭后再调用被拒', () async {
    await expectLater(
      McpClient.start(McpServerConfig(name: 'x', command: '')),
      throwsA(isA<McpException>()),
    );
    final McpClient client = await McpClient.start(config());
    await client.close();
    expect(client.isClosed, isTrue);
    await expectLater(client.listTools(), throwsA(isA<McpException>()));
  });

  test('命名空间工具名：mcp__<服务>__<工具> 往返解析', () {
    expect(namespacedToolName('fs', 'read'), 'mcp__fs__read');
    final ({String service, String tool})? parsed = parseNamespacedToolName(
      'mcp__fs__read_file',
    );
    expect(parsed?.service, 'fs');
    expect(parsed?.tool, 'read_file');
    expect(parseNamespacedToolName('read'), isNull);
    expect(parseNamespacedToolName('mcp__broken'), isNull);
  });
}
