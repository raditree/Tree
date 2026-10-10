@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 真起一个 **插件进程**（`bin/tree_ssh_executor.dart`）说 L1。
///
/// 这是唯一覆盖 `bin/` 的用例：别的用例都在进程内直接调 `PluginLoop`，证不了
/// "stdout 只有协议帧、日志走 stderr、真实 stdio 上帧能来回、退出码是 0"。
/// 它**不需要网络**（只是 spawn 一个本机 Dart 进程）。
void main() {
  late Process process;
  late LineFrameDecoder decoder;
  late List<String> stderrLines;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  setUp(() async {
    stderrLines = <String>[];
    frames.clear();
    process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', 'bin/tree_ssh_executor.dart'],
      workingDirectory: Directory.current.path,
    );
    decoder = LineFrameDecoder(onFrame: frames.add, onError: (String _) {});
    // stdout 是协议面：按行帧解（解不开就是插件把日志写错地方了）
    process.stdout.listen(decoder.add);
    // stderr 是日志面：只收集
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);
  });

  tearDown(() async {
    process.kill();
    await process.exitCode;
  });

  Future<Map<String, dynamic>> call(
    int id,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    process.stdin.add(encodeFrame(rpcRequest(id, method, params)));
    await process.stdin.flush();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      for (final Map<String, dynamic> frame in frames) {
        if (frame['id'] == id) return frame;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('插件没有在 30s 内回包：$method');
  }

  test('真进程：hello / ping / tools.list 都能回，未知方法回 -32601', () async {
    final Map<String, dynamic> hello =
        await call(1, 'hello', <String, dynamic>{'protocol': 1});
    expect(hello['result']['capabilities'], <String>[kCapabilitySshExecutor]);
    expect(hello['result']['protocol'], kTunnelProtocolVersion);

    expect((await call(2, 'ping'))['result'], <String, dynamic>{'ok': true});
    expect((await call(3, 'tools/list'))['result'], <String, dynamic>{
      'tools': <Object>[],
    });

    final Map<String, dynamic> unknown = await call(4, 'nope');
    expect(unknown['error']['code'], RpcCodes.methodNotFound);
  });

  test('真进程：**一次塞多帧**也能逐条回（不因批量到达而炸/漏）', () async {
    // 回归钉子：stdout 每帧 flush 会把 sink 标成 bound，同一批解出的多帧再 add 就抛
    // `Bad state: StreamSink is bound to a stream`（编译成 exe + 管道 stdin 时实测必现）。
    final List<Map<String, dynamic>> batch = <Map<String, dynamic>>[
      rpcRequest(11, 'ping'),
      rpcRequest(12, 'hello', <String, dynamic>{'protocol': 1}),
      rpcRequest(13, 'tools/list'),
      rpcRequest(14, 'unknown.method'),
    ];
    process.stdin.add(<int>[
      for (final Map<String, dynamic> frame in batch) ...encodeFrame(frame),
    ]);
    await process.stdin.flush();

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    Set<Object?> seen = <Object?>{};
    while (DateTime.now().isBefore(deadline)) {
      seen = frames
          .map((Map<String, dynamic> f) => f['id'])
          .where((Object? id) => id != null)
          .toSet();
      if (seen.containsAll(<Object?>[11, 12, 13, 14])) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(seen, containsAll(<Object?>[11, 12, 13, 14]));
    expect(frames.firstWhere((Map<String, dynamic> f) => f['id'] == 14)['error']
        ['code'], RpcCodes.methodNotFound);
  });

  test('真进程：shutdown 通知后自己退出（exit=0）', () async {
    await call(1, 'ping');
    process.stdin.add(encodeFrame(rpcNotification('shutdown')));
    await process.stdin.flush();
    final int code = await process.exitCode.timeout(const Duration(seconds: 30));
    expect(code, 0);
    expect(stderrLines.join('\n'), contains('shutdown'));
  });

  test('真进程：关闭 stdin（核心收手）后退出（exit=0）', () async {
    await call(1, 'ping');
    await process.stdin.close();
    final int code = await process.exitCode.timeout(const Duration(seconds: 30));
    expect(code, 0);
  });
}
