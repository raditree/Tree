import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

/// 一条"输出会超过内联上限（[kExecRunMaxStreamBytes]）"的命令 —— 两个平台都能造。
///
/// Windows 分支用 `powershell -EncodedCommand`（base64/UTF-16LE）：**这是为了绕开
/// `cmd /c` 的引号规则** —— 实测 `powershell -Command "[Console]::Out.Write(…)"`
/// 会被 cmd 剥掉引号、PowerShell 再把表达式当字符串原样打回（只 37 字节）；
/// `type "C:\…"` 也被 cmd 判成"路径语法不正确"。编码后的载荷只有 `A-Za-z0-9+/=`，
/// shell 无从下手。
String bigOutputCommand() => Platform.isWindows
    ? 'powershell -NoProfile -EncodedCommand '
          '${powershellEncodedCommand("[Console]::Out.Write('a' * 5000000)")}'
    : r"head -c 5000000 /dev/zero | tr '\0' a";

/// 把一段 PowerShell 脚本编成 `-EncodedCommand` 要的 base64（UTF-16LE）。
String powershellEncodedCommand(String script) {
  final List<int> utf16 = <int>[];
  for (final int unit in script.codeUnits) {
    utf16.add(unit & 0xFF);
    utf16.add((unit >> 8) & 0xFF);
  }
  return base64Encode(utf16);
}

/// 一条"要等 stdin 才会结束"的命令（stdin 关掉时应立刻拿到 EOF 退出）。
String waitsForStdinCommand() => Platform.isWindows ? 'more' : 'cat';

void main() {
  late Directory root;
  late String rootPath;
  late String stateDir;
  late ExecOps exec;

  setUp(() {
    root = createTempRoot('exec');
    rootPath = toPosix(root.path);
    stateDir = '$rootPath/state';
    exec = ExecOps(
      guard: PathGuard(rootPath),
      root: rootPath,
      stateDir: stateDir,
      // 缺省实现：生产是 /bin/sh -c，开发机（Windows）自动用 cmd.exe /c
      // —— 同一套 exec.run 逻辑因此在本机也有真覆盖。
      launcher: const DefaultShellLauncher(),
      ledger: ProcLedger(stateDir: stateDir, aliveProbe: (int pid) async => false),
    );
  });

  tearDown(() => removeTempRoot(root));

  group('exec.run', () {
    test('退出码 + stdout（字节经 base64 过线）', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': 'echo hello',
      });
      expect(r['exit_code'], 0);
      expect(
        utf8.decode(base64Decode(r['stdout'] as String)).trim(),
        'hello',
      );
      expect(r['timed_out'], false);
      expect(r['truncated'], false);
    });

    test('非 0 退出码原样回', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': 'exit 3',
      });
      expect(r['exit_code'], 3);
    });

    test('stderr 单独一路（字节不丢）', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': 'echo toerr 1>&2',
      });
      expect(
        utf8.decode(base64Decode(r['stderr'] as String)).trim(),
        'toerr',
      );
    });

    test('缺省 cwd = 工作空间根；越界 cwd ⇒ -32001', () async {
      expect(
        () => exec.run(<String, dynamic>{
          'command': 'echo hi',
          'cwd': '/definitely/outside',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.pathOutOfRoot,
          ),
        ),
      );
    });

    test('cwd 不存在 ⇒ exec_failed（命令起不来）', () async {
      expect(
        () => exec.run(<String, dynamic>{
          'command': 'echo hi',
          'cwd': '$rootPath/nope',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.execFailed,
          ),
        ),
      );
    });

    test('缺省**关掉 stdin**：等输入的命令不会永久挂住（不变量 5）', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': waitsForStdinCommand(),
        'timeout_ms': 5000,
      });
      expect(
        r['timed_out'],
        false,
        reason: '关掉 stdin 之后等输入的命令会立刻拿到 EOF —— 那就不会超时',
      );
      expect(r['exit_code'], 0);
    });

    test('软超时到点**不杀**：返回已得输出 + timed_out:true（且很快返回）', () async {
      final String longCommand = Platform.isWindows
          ? 'ping -n 6 127.0.0.1'
          : 'sleep 6';
      final Stopwatch watch = Stopwatch()..start();
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': longCommand,
        'timeout_ms': 400,
      });
      watch.stop();
      expect(r['timed_out'], true);
      expect(
        watch.elapsedMilliseconds,
        lessThan(4000),
        reason: '到点就回，不等命令结束',
      );
    });

    test('timeout_ms <= 0（含缺省）= 永不软超时', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': Platform.isWindows ? 'ping -n 2 127.0.0.1' : 'sleep 1',
        'timeout_ms': 0,
      });
      expect(r['timed_out'], false);
      expect(r['exit_code'], 0);
    });
  });

  group('exec.run 的内联上限与落盘（truncated 语义）', () {
    test('超过 kExecRunMaxStreamBytes ⇒ truncated=true，完整输出落 <state>/run/<id>.out', () async {
      final Map<String, dynamic> r = await exec.run(<String, dynamic>{
        'command': bigOutputCommand(),
      });
      expect(r['exit_code'], 0);
      expect(r['truncated'], true);
      expect(
        base64Decode(r['stdout'] as String).length,
        kExecRunMaxStreamBytes,
        reason: '内联部分的上限就是 kExecRunMaxStreamBytes',
      );

      final List<File> outs = Directory('$stateDir/run')
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.out'))
          .toList();
      expect(outs.length, 1, reason: '完整输出落盘到一个 <state>/run/<id>.out');
      expect(
        outs.single.lengthSync(),
        5000000,
        reason: '文件是"完整输出"，不是"截断后的部分"',
      );
      expect(
        outs.single.readAsBytesSync().every((int b) => b == 0x61),
        true,
        reason: '落盘内容与命令输出一致（全是 a）',
      );
    });
  });
}
