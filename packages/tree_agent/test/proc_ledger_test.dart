import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

void main() {
  late Directory root;
  late String stateDir;

  setUp(() {
    root = createTempRoot('ledger');
    stateDir = '${toPosix(root.path)}/state';
    Directory(stateDir).createSync(recursive: true);
  });

  tearDown(() => removeTempRoot(root));

  ProcRecord record(String id, {int pid = 4242}) => ProcRecord(
    id: id,
    pid: pid,
    pgid: pid,
    command: 'echo hi',
    logPath: '/ws/log/$id.txt',
    cwd: '/ws',
    startedAtMs: 111,
  );

  group('ProcsRecord JSON', () {
    test('往返保真', () {
      final ProcRecord r = record('a-1');
      final ProcRecord? back = ProcRecord.fromJson(r.toJson());
      expect(back, isNotNull);
      expect(back!.id, 'a-1');
      expect(back.pid, 4242);
      expect(back.pgid, 4242);
      expect(back.logPath, '/ws/log/a-1.txt');
      expect(back.startedAtMs, 111);
    });

    test('坏行返回 null（不炸整个台账）', () {
      expect(ProcRecord.fromJson(null), isNull);
      expect(ProcRecord.fromJson(<String, dynamic>{'id': ''}), isNull);
      expect(ProcRecord.fromJson('nope'), isNull);
    });
  });

  group('ProcLedger 落盘', () {
    test('原子写：留下 procs.json，不留 .tmp', () async {
      final ProcLedger ledger = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => true,
      );
      await ledger.add(record('a-1'));

      expect(await File('$stateDir/procs.json').exists(), true);
      expect(await File('$stateDir/procs.json.tmp').exists(), false);
      final Object? decoded = jsonDecode(
        await File('$stateDir/procs.json').readAsString(),
      );
      expect(decoded, isA<Map<String, dynamic>>());
    });

    test('**agent 重启后读回台账**', () async {
      final ProcLedger first = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => true,
      );
      await first.add(record('a-1'));
      await first.add(record('a-2', pid: 99));

      final ProcLedger second = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => true,
      );
      await second.load();
      expect(second.records.map((ProcRecord r) => r.id).toSet(), <String>{
        'a-1',
        'a-2',
      });
      expect(second.byId('a-2')!.pid, 99);
    });

    test('文件缺失 / 坏内容 ⇒ 空台账（不抛）', () async {
      final ProcLedger missing = ProcLedger(stateDir: '$stateDir/nope');
      await missing.load();
      expect(missing.records, isEmpty);

      await File('$stateDir/procs.json').writeAsString('{ 不是 json');
      final ProcLedger broken = ProcLedger(stateDir: stateDir);
      await broken.load();
      expect(broken.records, isEmpty);
    });

    test('remove 会落盘', () async {
      final ProcLedger ledger = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => true,
      );
      await ledger.add(record('a-1'));
      expect(await ledger.remove('a-1'), true);
      expect(await ledger.remove('a-1'), false);

      final ProcLedger reloaded = ProcLedger(stateDir: stateDir);
      await reloaded.load();
      expect(reloaded.records, isEmpty);
    });
  });

  group('对账（协议 §3.4：退出码文件 → kill -0 → gone）', () {
    test('退出码文件在 ⇒ exited + exit_code', () async {
      final ProcLedger ledger = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => true,
      );
      final ProcRecord r = record('a-1');
      await ledger.add(r);
      Directory('$stateDir/exit').createSync(recursive: true);
      await File(ledger.exitFilePath('a-1')).writeAsString('7');

      final ProcStatus status = await ledger.reconcile(r);
      expect(status.state, BackgroundStates.exited);
      expect(status.exitCode, 7);
    });

    test('没有退出码文件但进程活着 ⇒ running', () async {
      final ProcLedger ledger = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => pid == 4242,
      );
      final ProcStatus status = await ledger.reconcile(record('a-1'));
      expect(status.state, BackgroundStates.running);
      expect(status.exitCode, isNull);
    });

    test('进程没了、退出码也没有 ⇒ gone（**不猜** exit_code）', () async {
      final ProcLedger ledger = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => false,
      );
      final ProcStatus status = await ledger.reconcile(record('a-1'));
      expect(status.state, BackgroundStates.gone);
      expect(status.exitCode, isNull);
      expect(status.toJson().containsKey('exit_code'), false);
    });

    test('退出码文件写的是垃圾 ⇒ 当没写过（不猜）', () async {
      final ProcLedger ledger = ProcLedger(
        stateDir: stateDir,
        aliveProbe: (int pid) async => false,
      );
      Directory('$stateDir/exit').createSync(recursive: true);
      await File(ledger.exitFilePath('a-1')).writeAsString('不是数字');
      expect((await ledger.reconcile(record('a-1'))).state, BackgroundStates.gone);
    });
  });

  group('AgentIdGen', () {
    test('同毫秒内也唯一', () {
      final AgentIdGen ids = AgentIdGen(
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final Set<String> all = <String>{
        ids.next(),
        ids.next(),
        ids.next(),
      };
      expect(all.length, 3);
      expect(all.every((String id) => id.startsWith('1000-')), true);
    });
  });
}
