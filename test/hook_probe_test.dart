import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hook bat + stream write: stdout/stderr land in file', () async {
    if (!Platform.isWindows) return; // bat 方案仅 Windows
    final String base = Directory.current.path;
    const String outFile = '.output/probe_hook_final.log';
    final File f = File(outFile);
    if (await f.exists()) await f.delete();

    final String batPath = '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}hook_probe_final.bat';
    File(batPath).writeAsStringSync(
      '@echo off\r\n'
      'echo hello_stdout\r\n'
      'echo err_line 1>&2\r\n'
      'echo done_marker\r\n',
    );

    final Process p = await Process.start(
      'cmd',
      <String>['/d', '/s', '/c', batPath],
      workingDirectory: base,
    );
    final IOSink sink = f.openWrite();
    final Completer<void> outDone = Completer<void>();
    final Completer<void> errDone = Completer<void>();
    p.stdout.listen(sink.add, onDone: () {
      if (!outDone.isCompleted) outDone.complete();
    }, cancelOnError: true);
    p.stderr.listen(sink.add, onDone: () {
      if (!errDone.isCompleted) errDone.complete();
    }, cancelOnError: true);
    final int code = await p.exitCode;
    await Future.wait(<Future<void>>[outDone.future, errDone.future]);
    await sink.flush();
    await sink.close();
    File(batPath).deleteSync();

    final String content = await f.readAsString();
    // ignore: avoid_print
    print('FINAL exit=$code content=[$content]');
    expect(content.contains('hello_stdout'), true,
        reason: 'stdout 未落盘: [$content]');
    expect(content.contains('err_line'), true,
        reason: 'stderr 未落盘: [$content]');
    expect(content.contains('done_marker'), true,
        reason: '尾部输出未落盘（过早关闭）: [$content]');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
