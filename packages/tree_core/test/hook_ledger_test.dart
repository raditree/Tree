import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 后台任务台账（远端 hook 跨重启接续的凭据）的落盘语义。
void main() {
  late Directory dir;
  late HookLedger ledger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tree_ledger_');
    ledger = HookLedger(dir.path);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  HookLedgerEntry entry(
    String id, {
    int startedAt = 1700000000000,
    int? pid = 42,
  }) => HookLedgerEntry(
    id: id,
    agentId: 'agt_1',
    sessionId: 'ses_1',
    command: 'python train.py',
    logRelative: '.output/$id.log',
    pid: pid,
    startedAt: startedAt,
  );

  test('save / load / remove：往返一致；remove 后不再出现', () async {
    await ledger.save(entry('hook_1'));
    final List<HookLedgerEntry> loaded = await ledger.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'hook_1');
    expect(loaded.single.agentId, 'agt_1');
    expect(loaded.single.sessionId, 'ses_1');
    expect(loaded.single.command, 'python train.py');
    expect(loaded.single.logRelative, '.output/hook_1.log');
    expect(loaded.single.pid, 42);
    await ledger.remove('hook_1');
    expect(await ledger.load(), isEmpty);
    // 删不存在的条目：不报错
    await ledger.remove('hook_1');
  });

  test('原子写：不留 .tmp；同 id 重复 save 只有一条', () async {
    await ledger.save(entry('hook_1'));
    await ledger.save(entry('hook_1', pid: null));
    final List<HookLedgerEntry> loaded = await ledger.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.pid, isNull, reason: '同 id 覆盖为最新一份');
    final List<String> names = dir
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .toList();
    expect(names.where((String n) => n.endsWith('.tmp')), isEmpty);
  });

  test('load 按开始时刻升序（接续顺序稳定）', () async {
    await ledger.save(entry('hook_b', startedAt: 300));
    await ledger.save(entry('hook_a', startedAt: 100));
    final List<HookLedgerEntry> loaded = await ledger.load();
    expect(loaded.map((HookLedgerEntry e) => e.id), <String>['hook_a', 'hook_b']);
  });

  test('损坏 / 形状不对的条目：记日志后跳过，不让其余条目陪葬', () async {
    final List<String> logs = <String>[];
    final HookLedger tolerant = HookLedger(dir.path, log: logs.add);
    File(p.join(dir.path, 'broken.json')).writeAsStringSync('{不是 json');
    File(
      p.join(dir.path, 'shape.json'),
    ).writeAsStringSync(jsonEncode(<String, dynamic>{'id': 'x'}));
    await tolerant.save(entry('hook_ok'));
    final List<HookLedgerEntry> loaded = await tolerant.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'hook_ok');
    expect(logs, hasLength(2), reason: '两条坏条目各留一次可读日志');
  });

  test('id 里的路径分隔符被清洗（写不出去台账目录之外）', () async {
    await ledger.save(
      HookLedgerEntry(
        id: '../evil',
        agentId: 'a',
        sessionId: 's',
        command: 'c',
        logRelative: '.output/x.log',
        startedAt: 1,
      ),
    );
    final List<File> files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(p.dirname(files.single.path), dir.path);
    expect(p.basename(files.single.path).contains('/'), isFalse);
  });
}
