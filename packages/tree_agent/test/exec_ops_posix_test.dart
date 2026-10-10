import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';

import 'support.dart';

/// **POSIX 专属**的 `exec.run` 行为（`/bin/sh` + shell 语义；Windows 上 skip，M7 用
/// 交叉编译出的 Linux 二进制真跑）。断言一条都不删。
final String? posixSkipReason = Platform.isWindows
    ? 'POSIX 专属（/bin/sh、pwd、printf 转义、read 等 shell 语义）：Windows 开发机跳过，'
          'M7 用交叉编译的 Linux 二进制真跑'
    : null;

void main() {
  late Directory root;
  late String rootPath;
  late String stateDir;
  late ExecOps exec;

  setUp(() {
    root = createTempRoot('exec_posix');
    rootPath = toPosix(root.path);
    stateDir = '$rootPath/state';
    exec = ExecOps(
      guard: PathGuard(rootPath),
      root: rootPath,
      stateDir: stateDir,
      launcher: const PosixShellLauncher(),
      ledger: ProcLedger(stateDir: stateDir, aliveProbe: (int pid) async => false),
    );
  });

  tearDown(() => removeTempRoot(root));

  group('exec.run（POSIX）', () {
    test('缺省 cwd 就是工作空间根（pwd 印证）', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': 'pwd',
      });
      expect(utf8.decode(base64Decode(r['stdout'] as String)).trim(), rootPath);
    });

    test('stdin_b64 打进去；非 UTF-8 字节从 stdout 原样回来', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': 'cat',
        'stdin_b64': base64Encode(utf8.encode('hello stdin')),
      });
      expect(utf8.decode(base64Decode(r['stdout'] as String)), 'hello stdin');
    });

    test('stdout 是**原始字节**：0x00 / 0xff 不被解码破坏', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': r"printf '\377\376\001'",
      });
      expect(base64Decode(r['stdout'] as String), <int>[0xff, 0xfe, 0x01]);
    });

    test('软超时之后**进程仍在跑**，完整输出继续落盘（不是"截断后的一半"）', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': r"printf 'first'; sleep 2; printf 'second'",
        'timeout_ms': 300,
      });
      expect(r['timed_out'], true);
      expect(
        utf8.decode(base64Decode(r['stdout'] as String)),
        'first',
        reason: '返回时只拿到已经产出的部分',
      );

      // 等命令自然结束（不杀它） ⇒ 文件里应是完整输出。
      final File out = Directory('$stateDir/run')
          .listSync()
          .whereType<File>()
          .firstWhere((File f) => f.path.endsWith('.out'));
      String text = '';
      final Stopwatch watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 5)) {
        text = out.readAsStringSync();
        if (text.contains('second')) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(text, 'firstsecond', reason: '到点不杀 ⇒ 命令跑完，输出落盘完整');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('启动子进程必须禁交互：无 stdin 的命令立刻拿到 EOF', () async {
      // `read` 会一直等输入；stdin 关掉后它立刻收到 EOF 继续往下走。
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': 'read x || true; echo done',
        'timeout_ms': 5000,
      });
      expect(r['timed_out'], false);
      expect(utf8.decode(base64Decode(r['stdout'] as String)).trim(), 'done');
    });
  }, skip: posixSkipReason);
}
