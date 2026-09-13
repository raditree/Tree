// 插件宿主会话管理器单元测试（M2：plugin_host_* 通道，契约 v1.3 §14）。
//
// 覆盖：
// - 纯函数：id 生成 / 尾部截断 / 字节解码 / POSIX 引号转义 / 默认空转
//   argv / 远端命令构建与解析；
// - 会话表最小生命周期：幂等 start（同 host_key 复用）/ stop（幂等）/
//   status（running→closed + exit_code + stderr_tail）；退出上报帧；
// - 清理契约四场景：stop 指令 / 级联回收（recycleTeam）/ 应用退出
//   （recycleAll）/ 断连回收对账（markAllLost + reconcileAfterReconnect）。
//
// 进程启动经 fake 句柄注入（PluginHostSpawn），不依赖真进程。
//
// 运行方式（项目根目录）：
//   flutter test test/plugin_host_sessions_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/plugin_host_sessions.dart';

/// fake 宿主进程：可控退出 / 杀灭 / stderr，供注入测试。
class _FakeProcess {
  _FakeProcess(this.pid);

  final int pid;
  final Completer<int> _exit = Completer<int>();
  final StreamController<List<int>> _stderr =
      StreamController<List<int>>();

  bool killed = false;
  int killCount = 0;
  bool killResult = true;

  PluginHostProcessHandle get handle => PluginHostProcessHandle(
        pid: pid,
        exitCode: _exit.future,
        stderr: _stderr.stream,
        kill: () {
          killed = true;
          killCount += 1;
          return killResult;
        },
      );

  void completeExit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void emitStderr(String text) => _stderr.add(utf8.encode(text));
}

/// 测试夹具：记录 spawn 请求 / 上报帧，构造 fake 管理器。
class _Harness {
  final List<PluginHostSpawnRequest> spawns = <PluginHostSpawnRequest>[];
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  final List<_FakeProcess> processes = <_FakeProcess>[];
  int _nextPid = 4000;
  bool failNextSpawn = false;

  late final PluginHostSessionManager manager = PluginHostSessionManager(
    spawn: (PluginHostSpawnRequest request) async {
      spawns.add(request);
      if (failNextSpawn) {
        failNextSpawn = false;
        throw StateError('spawn boom');
      }
      final _FakeProcess process = _FakeProcess(_nextPid);
      _nextPid += 1;
      processes.add(process);
      return process.handle;
    },
    notify: (Map<String, dynamic> frame) => frames.add(frame),
    now: () => DateTime.fromMillisecondsSinceEpoch(1000),
  );

  Future<void> flush() => Future<void>.delayed(Duration.zero);
}

void main() {
  group('纯函数', () {
    test('newPluginHostSessionId：phs_ 前缀 + 时间戳 + 递增序号，不重复', () {
      final DateTime fixed = DateTime.fromMillisecondsSinceEpoch(1000);
      final String a = newPluginHostSessionId(fixed);
      final String b = newPluginHostSessionId(fixed);
      expect(a, startsWith('phs_1000_'));
      expect(b, startsWith('phs_1000_'));
      expect(a, isNot(b));
    });

    test('trimTail：未超长原样；超长保留末尾；上限非正返回空', () {
      expect(trimTail('abc', 5), 'abc');
      expect(trimTail('abcdef', 3), 'def');
      expect(trimTail('abcdef', 0), '');
    });

    test('decodePluginHostBytes：UTF-8 正常解码；非法字节 latin1 兜底不抛错', () {
      expect(decodePluginHostBytes(utf8.encode('你好')), '你好');
      final String fallback = decodePluginHostBytes(<int>[0xFF, 0xFE]);
      expect(fallback, isNotEmpty);
    });

    test('shQuotePosix：普通串加单引号；内含单引号正确转义', () {
      expect(shQuotePosix('a b'), "'a b'");
      expect(shQuotePosix("a'b"), "'a'\\''b'");
    });

    test('defaultIdleArgv：Windows=ping；WSL 目录经 bash cd；Unix=sleep', () {
      final List<String> win = defaultIdleArgv(
        isWindows: true,
        unixLike: false,
        workingDirectory: 'C:/ws',
      );
      expect(win.first, 'ping');
      expect(win, contains('3600'));
      final List<String> wsl = defaultIdleArgv(
        isWindows: true,
        unixLike: true,
        workingDirectory: '/mnt/e/ws',
      );
      expect(wsl.first, 'bash');
      expect(wsl.last, contains('cd '));
      expect(wsl.last, contains('sleep 3600'));
      final List<String> unix = defaultIdleArgv(
        isWindows: false,
        unixLike: false,
        workingDirectory: '/home/u/ws',
      );
      expect(unix, <String>['sleep', '3600']);
    });

    test('远端命令构建：启动含 nohup+pidfile；状态/停止命令含 kill 语义', () {
      final String start = buildRemoteHostStartCommand(
        cwd: '/home/u/ws',
        pidFile: '/tmp/tree_ph_x.pid',
      );
      expect(start, contains('nohup sleep 3600'));
      expect(start, contains('/tmp/tree_ph_x.pid'));
      expect(start, contains('echo \$! >'));
      final String status =
          buildRemoteHostStatusCommand(pidFile: '/tmp/tree_ph_x.pid');
      expect(status, contains('kill -0'));
      final String stop =
          buildRemoteHostStopCommand(pidFile: '/tmp/tree_ph_x.pid');
      expect(stop, contains('kill -TERM'));
      expect(stop, contains('rm -f'));
    });

    test('parseRemoteHostStatusOutput：running / 其他按 closed', () {
      expect(parseRemoteHostStatusOutput('running\n'), 'running');
      expect(parseRemoteHostStatusOutput('closed'), 'closed');
      expect(parseRemoteHostStatusOutput(''), 'closed');
    });
  });

  group('最小生命周期（start / stop / status）', () {
    late _Harness h;

    setUp(() {
      h = _Harness();
    });

    test('start：建立会话并返回 host_session_id；spawn 收到归属与形态', () async {
      final Map<String, dynamic> res = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      expect(res['host_session_id'], startsWith('phs_'));
      expect(res['error'], isNull);
      expect(h.spawns, hasLength(1));
      expect(h.spawns.single.hostSessionId, res['host_session_id']);
      expect(h.spawns.single.teamId, 't1');
      expect(h.spawns.single.workingDirectory, 'C:/ws');
      expect(h.spawns.single.unixLike, isFalse);
      expect(h.manager.sessionCount, 1);
    });

    test('start 幂等：同 host_key 复用同一会话（不再 spawn）', () async {
      final Map<String, dynamic> first = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final Map<String, dynamic> second = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      expect(second['host_session_id'], first['host_session_id']);
      expect(h.spawns, hasLength(1));
      expect(h.manager.sessionCount, 1);
    });

    test('start：不同 host_key 各建会话', () async {
      await h.manager.start(
          hostKey: 'k1', teamId: 't1', workingDirectory: 'C:/ws', unixLike: false);
      await h.manager.start(
          hostKey: 'k2', teamId: 't1', workingDirectory: 'C:/ws', unixLike: false);
      expect(h.manager.sessionCount, 2);
    });

    test('start：缺 host_key / 启动失败 → error 且不建条目', () async {
      final Map<String, dynamic> missing = await h.manager.start(
        hostKey: '',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      expect(missing['error'], isNotEmpty);
      h.failNextSpawn = true;
      final Map<String, dynamic> failed = await h.manager.start(
        hostKey: 'kk',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      expect(failed['error'], contains('启动失败'));
      expect(h.manager.sessionCount, 0);
    });

    test('start：旧会话已 closed → 回收后重建新 id', () async {
      final Map<String, dynamic> first = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      h.processes.single.completeExit(0);
      await h.flush();
      final Map<String, dynamic> second = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      expect(second['host_session_id'], isNot(first['host_session_id']));
      expect(h.manager.sessionCount, 1);
    });

    test('stop：终止进程并回 ok；二次 stop 幂等（不重复杀）', () async {
      final Map<String, dynamic> started = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final String id = started['host_session_id'] as String;
      final Map<String, dynamic> first =
          h.manager.stop(hostSessionId: id, teamId: 't1');
      expect(first['ok'], isTrue);
      expect(h.processes.single.killed, isTrue);
      expect(h.processes.single.killCount, 1);
      final Map<String, dynamic> second =
          h.manager.stop(hostSessionId: id, teamId: 't1');
      expect(second['ok'], isTrue);
      expect(h.processes.single.killCount, 1);
    });

    test('stop：未知会话回 ok（幂等）；缺 id / 跨 team 回 error', () async {
      expect(
        h.manager.stop(hostSessionId: 'nope', teamId: 't1')['ok'],
        isTrue,
      );
      expect(
        h.manager.stop(hostSessionId: '', teamId: 't1')['error'],
        isNotEmpty,
      );
      final Map<String, dynamic> started = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final String id = started['host_session_id'] as String;
      final Map<String, dynamic> cross =
          h.manager.stop(hostSessionId: id, teamId: 't2');
      expect(cross['error'], contains('不属于'));
      expect(h.processes.single.killed, isFalse);
    });

    test('status：running → 退出后 closed + exit_code；未知 id / 跨 team 回 error',
        () async {
      final Map<String, dynamic> started = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final String id = started['host_session_id'] as String;
      final Map<String, dynamic> running =
          h.manager.status(hostSessionId: id, teamId: 't1');
      expect(running['state'], 'running');
      expect(running.containsKey('exit_code'), isFalse);

      h.processes.single.completeExit(7);
      await h.flush();
      final Map<String, dynamic> closed =
          h.manager.status(hostSessionId: id, teamId: 't1');
      expect(closed['state'], 'closed');
      expect(closed['exit_code'], 7);

      expect(
        h.manager.status(hostSessionId: 'nope', teamId: 't1')['error'],
        isNotEmpty,
      );
      expect(
        h.manager.status(hostSessionId: id, teamId: 't2')['error'],
        isNotEmpty,
      );
    });

    test('status：stderr 尾部聚合且截断至上限', () async {
      final Map<String, dynamic> started = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final String id = started['host_session_id'] as String;
      h.processes.single.emitStderr('err-line\n');
      await h.flush();
      expect(
        h.manager.status(hostSessionId: id, teamId: 't1')['stderr_tail'],
        'err-line\n',
      );
      h.processes.single.emitStderr('x' * 2500);
      await h.flush();
      final String tail =
          h.manager.status(hostSessionId: id, teamId: 't1')['stderr_tail']
              as String;
      expect(tail.length, kPluginHostStderrTailCap);
    });
  });

  group('退出上报（plugin_host_event）', () {
    late _Harness h;

    setUp(() {
      h = _Harness();
    });

    test('进程退出 → 发出 exit 帧（id/team/exit_code/stderr 尾）', () async {
      final Map<String, dynamic> started = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final String id = started['host_session_id'] as String;
      h.processes.single.emitStderr('oops');
      await h.flush();
      h.processes.single.completeExit(3);
      await h.flush();
      expect(h.frames, hasLength(1));
      final Map<String, dynamic> frame = h.frames.single;
      expect(frame['type'], kPluginHostEventType);
      final Map<String, dynamic> data = frame['data'] as Map<String, dynamic>;
      expect(data['host_session_id'], id);
      expect(data['team_id'], 't1');
      expect(data['event'], 'exit');
      expect(data['exit_code'], 3);
      expect(data['stderr_tail'], 'oops');
    });

    test('stop 触发的退出同样上报（仅一次）', () async {
      final Map<String, dynamic> started = await h.manager.start(
        hostKey: 'k1',
        teamId: 't1',
        workingDirectory: 'C:/ws',
        unixLike: false,
      );
      final String id = started['host_session_id'] as String;
      h.manager.stop(hostSessionId: id, teamId: 't1');
      h.processes.single.completeExit(-1);
      await h.flush();
      expect(h.frames, hasLength(1));
      expect(
        (h.frames.single['data'] as Map<String, dynamic>)['exit_code'],
        -1,
      );
    });
  });

  group('清理契约四场景', () {
    late _Harness h;

    setUp(() {
      h = _Harness();
    });

    Future<Map<String, dynamic>> startOn(String key, String team) =>
        h.manager.start(
          hostKey: key,
          teamId: team,
          workingDirectory: 'C:/ws',
          unixLike: false,
        );

    test('级联回收：recycleTeam 只回收该 team，其余保留', () async {
      await startOn('k1', 't1');
      await startOn('k2', 't2');
      h.manager.recycleTeam('t1');
      expect(h.manager.sessionCount, 1);
      expect(h.processes.first.killed, isTrue);
      expect(h.processes.last.killed, isFalse);
      expect(h.manager.sessionById(
        ((await startOn('k3', 't2'))['host_session_id']) as String,
      ), isNotNull);
    });

    test('应用退出：recycleAll 全部终止并清空表', () async {
      await startOn('k1', 't1');
      await startOn('k2', 't2');
      h.manager.recycleAll();
      expect(h.manager.sessionCount, 0);
      expect(h.processes.every((_FakeProcess p) => p.killed), isTrue);
      h.manager.recycleAll(); // 幂等不抛错
      expect(h.manager.sessionCount, 0);
    });

    test('断连标记：markAllLost / markTeamLost 置失联（不 kill）', () async {
      final String id1 =
          (await startOn('k1', 't1'))['host_session_id'] as String;
      final String id2 =
          (await startOn('k2', 't2'))['host_session_id'] as String;
      h.manager.markAllLost();
      expect(h.manager.sessionById(id1)!.lost, isTrue);
      expect(h.manager.sessionById(id2)!.lost, isTrue);
      expect(h.processes.every((_FakeProcess p) => !p.killed), isTrue);

      // 清除后单 team 标记
      h.manager.markAllLost();
      final _Harness h2 = _Harness();
      final Map<String, dynamic> a = await h2.manager.start(
          hostKey: 'a', teamId: 't1', workingDirectory: 'C:/ws', unixLike: false);
      final Map<String, dynamic> b = await h2.manager.start(
          hostKey: 'b', teamId: 't2', workingDirectory: 'C:/ws', unixLike: false);
      h2.manager.markTeamLost('t1');
      expect(
        h2.manager.sessionById(a['host_session_id'] as String)!.lost,
        isTrue,
      );
      expect(
        h2.manager.sessionById(b['host_session_id'] as String)!.lost,
        isFalse,
      );
    });

    test('重连对账：不可用 team 回收；可用 team 清除失联标记', () async {
      await startOn('k1', 't1');
      await startOn('k2', 't2');
      h.manager.markAllLost();
      h.manager.reconcileAfterReconnect((String team) => team == 't1');
      expect(h.manager.sessionCount, 1);
      expect(h.processes.first.killed, isFalse); // t1 保留
      expect(h.processes.last.killed, isTrue); // t2 回收
      expect(h.manager.sessionById(
        ((await startOn('k3', 't1'))['host_session_id']) as String,
      ), isNotNull);
    });

    test('重连对账：全部可用 → 零回收、失联标记清零', () async {
      final String id =
          (await startOn('k1', 't1'))['host_session_id'] as String;
      h.manager.markAllLost();
      h.manager.reconcileAfterReconnect((String team) => true);
      expect(h.manager.sessionCount, 1);
      expect(h.manager.sessionById(id)!.lost, isFalse);
      expect(h.processes.single.killed, isFalse);
    });
  });
}
