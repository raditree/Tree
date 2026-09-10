// 第三方 MCP stdio 隧道（local / SSH 宿主共用）单元测试。
//
// 隧道是"后端驱动、前端搬字节"的：帧的切分（换行分隔、半行留缓冲）、挂起读取
// 的唤醒、承载进程退出的感知，任一环节偏一点后端就无法重组 JSON-RPC 报文。
// 运行方式（项目根目录）：
//   flutter test test/mcp_stdio_tunnel_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/mcp_stdio_tunnel.dart';

/// 构造一个只做记录的空壳会话（写入/终止回调由用例覆盖）。
McpStdioTunnelSession _newSession({
  void Function(Uint8List data)? write,
  void Function()? kill,
}) {
  return McpStdioTunnelSession(
    id: 's1',
    teamId: 't1',
    write: write ?? (Uint8List _) {},
    kill: kill ?? () {},
  );
}

void main() {
  group('mcpStdioLineEnd', () {
    test('空缓冲 / 只有半行时返回 -1', () {
      expect(mcpStdioLineEnd(<int>[]), -1);
      expect(mcpStdioLineEnd('{"jsonrpc":"2.0"'.codeUnits), -1);
    });

    test('返回首个换行的下标（完整行含结尾 \\n）', () {
      expect(mcpStdioLineEnd('{"a":1}\n'.codeUnits), 7);
    });

    test('多行缓冲只取首行，其余留待下次读取', () {
      final List<int> buffer = 'one\ntwo\nthree'.codeUnits;
      final int end = mcpStdioLineEnd(buffer);
      expect(end, 3);
      expect(String.fromCharCodes(buffer.sublist(0, end + 1)), 'one\n');
    });

    test('UTF-8 多字节内容按字节下标切分，不截断字符', () {
      final List<int> buffer = utf8.encode('{"内容":"中文"}\n');
      final int end = mcpStdioLineEnd(buffer);
      expect(end, buffer.length - 1);
      expect(utf8.decode(buffer.sublist(0, end + 1)), '{"内容":"中文"}\n');
    });
  });

  group('McpStdioTunnelSession', () {
    late StreamController<List<int>> out;
    late StreamController<List<int>> err;

    setUp(() {
      out = StreamController<List<int>>();
      err = StreamController<List<int>>();
    });

    tearDown(() {
      out.close();
      err.close();
    });

    test('stdout 出现整行时唤醒挂起的读取', () async {
      final McpStdioTunnelSession session = _newSession()
        ..bindStreams(out.stream, err.stream);
      // 先挂起读取（模拟读取窗口内服务端稍后才输出）
      final Future<List<int>?> pending =
          session.takeLine(const Duration(seconds: 5));
      out.add(utf8.encode('{"jsonrpc":"2.0"}\n'));
      final List<int>? line = await pending;
      expect(line, isNotNull);
      expect(utf8.decode(line!), '{"jsonrpc":"2.0"}\n');
    });

    test('等待窗口内无整行返回 null（由后端续等，不视为中断）', () async {
      final McpStdioTunnelSession session = _newSession()
        ..bindStreams(out.stream, err.stream);
      expect(
        await session.takeLine(const Duration(milliseconds: 20)),
        isNull,
      );
      expect(session.closed, isFalse);
    });

    test('半行留在缓冲，补齐后按序取出', () async {
      final McpStdioTunnelSession session = _newSession()
        ..bindStreams(out.stream, err.stream);
      out.add(utf8.encode('{"a"'));
      expect(
        await session.takeLine(const Duration(milliseconds: 20)),
        isNull,
      );
      final Future<List<int>?> pending =
          session.takeLine(const Duration(seconds: 5));
      out.add(utf8.encode(':1}\nnext\n'));
      expect(utf8.decode((await pending)!), '{"a":1}\n');
      expect(
        utf8.decode((await session.takeLine(Duration.zero))!),
        'next\n',
      );
      expect(await session.takeLine(Duration.zero), isNull);
    });

    test('承载进程退出唤醒挂起读取并给出可读错误', () async {
      final McpStdioTunnelSession session = _newSession()
        ..bindStreams(out.stream, err.stream);
      final Future<List<int>?> pending =
          session.takeLine(const Duration(seconds: 30));
      err.add(utf8.encode('boom: no such module'));
      await Future<void>.delayed(Duration.zero);
      session.markExited(127);
      expect(await pending, isNull);
      expect(session.closed, isTrue);
      expect(session.exitedMessage(), contains('127'));
      expect(session.exitedMessage(), contains('no such module'));
    });

    test('dispose 终止承载进程并唤醒挂起读取', () async {
      bool killed = false;
      final McpStdioTunnelSession session =
          _newSession(kill: () => killed = true);
      final Future<List<int>?> pending =
          session.takeLine(const Duration(seconds: 30));
      session.dispose();
      expect(await pending, isNull);
      expect(killed, isTrue);
      expect(session.closed, isTrue);
    });

    test('writeBytes 原样交给承载进程 stdin', () {
      final List<int> written = <int>[];
      _newSession(write: (Uint8List data) => written.addAll(data))
          .writeBytes(Uint8List.fromList(utf8.encode('hi\n')));
      expect(utf8.decode(written), 'hi\n');
    });
  });
}
