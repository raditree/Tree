import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows runner 的 **RedirectionGuard 自愈**契约（见 `docs/known-issues.md` #16）。
///
/// 真机背景（今天实测坐实）：Windows 11 的 RedirectionGuard
/// （`PROCESS_MITIGATION_REDIRECTION_TRUST_POLICY` 的 `EnforceRedirectionTrust` = 0x1）
/// 会让进程**拒绝跟随"非管理员创建的"重定向点**，而且它**沿调用链继承**：安装器是提权的，
/// 它在安装末尾把 Tree 拉起来 ⇒ 整棵 Tree 进程树（核心、集成终端里的 shell、用户在那个
/// shell 里跑的构建命令）都拒绝跟随 `windows/flutter/ephemeral/.plugin_symlinks/*`
/// ⇒ `flutter build windows` 必然失败（CMake `add_subdirectory … is not an existing
/// directory`），而同一个命令在用户自己开的终端里（explorer 派生、干净）能成功。
///
/// 这条策略**清不掉**（`SetProcessMitigationPolicy(id, 0)` → ERROR_ACCESS_DENIED，实测），
/// 也**没有**创建期开关可以给子进程关掉。所以 runner 的做法是：启动时自检一次，带着它就
/// **经 explorer 重新拉起自己**（explorer 那条链实测 0x0，能跟随）后退出。
///
/// 这个用例钉住自检契约 `--tree-rt-selfcheck`：**只报状态与决定、不起 Flutter**。
/// 门控：非 Windows、或没有构建好的 Tree.exe 时跳过（`CONTRIBUTING.md` 允许门控测试；
/// 本机已手工验证过两端：旧 exe 不认这个参数 ⇒ 什么都不打印、会去起界面（先红）；
/// 新 exe 打印 `tree-rt-selfcheck: flags=0x… would-relaunch=…`（后绿））。
void main() {
  const String exeRel = 'build/windows/x64/runner/Release/Tree.exe';
  final bool canRun = Platform.isWindows && File(exeRel).existsSync();

  test(
    'runner 自检：报出 RedirectionTrust 与"是否该自愈重启"，且不起 Flutter',
    () async {
      final Process process = await Process.start(
        exeRel,
        <String>['--tree-rt-selfcheck'],
      );
      final StringBuffer out = StringBuffer();
      final StreamSubscription<String> sub =
          process.stdout.transform(utf8.decoder).listen(out.write);
      bool exited = false;
      final Future<void> done = process.exitCode.then((int _) => exited = true);
      await Future.any<void>(<Future<void>>[
        done,
        Future<void>.delayed(const Duration(seconds: 20)),
      ]);
      if (!exited) {
        process.kill();
        await sub.cancel();
        fail('自检没有自己退出：旧 exe 不认这个参数 ⇒ 它会去起界面（这就是本用例的先红点）');
      }
      await sub.cancel();
      final String text = out.toString().trim();
      final RegExpMatch? match =
          RegExp(r'flags=0x([0-9A-Fa-f]{1,8}) would-relaunch=([01])')
              .firstMatch(text);
      expect(
        match,
        isNotNull,
        reason: 'runner 必须按契约打印状态行；实际输出：[$text]',
      );
      final int flags = int.parse(match!.group(1)!, radix: 16);
      final int wouldRelaunch = int.parse(match.group(2)!);
      expect(
        wouldRelaunch,
        flags != 0 ? 1 : 0,
        reason: '带着这条缓解（flags≠0）就该自愈重启；干净上下文（0x0）里不许乱重启',
      );
      expect(process.exitCode, completion(0));
    },
    skip: canRun
        ? false
        : '没有构建好的 $exeRel（先跑 flutter build windows --release）',
  );
}
