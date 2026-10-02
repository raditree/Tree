import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 私有状态按 agent 分栏（`.self/…` → `.tree/<agent_id>/.self/…`）。
///
/// 背景（用户定夺，2026-10-02）：团队成员与 leader **共享同一个工作目录**，因此
/// `.self/` 必须按 agent 分开——否则成员的 `activity.log` / 系统提示词 / 规范 /
/// 长结果会与 leader 互相覆盖。内置规范、工具描述与若干常量里写的都是 `.self/…`
/// （模型口径），翻译只发生在 IO 装饰器 [PrivateWorkspaceIO] 这一层。
void main() {
  group('mapPrivatePath：只翻 .self 这一族', () {
    test(' .self 与 .self/… 翻成按 agent 分栏的真实路径', () {
      expect(mapPrivatePath('.self', 'agt_1'), '.tree/agt_1/.self');
      expect(
        mapPrivatePath('.self/results/read_ab.result', 'agt_1'),
        '.tree/agt_1/.self/results/read_ab.result',
      );
      expect(mapPrivatePath('./.self/plan/x.md', 'agt_1'), '.tree/agt_1/.self/plan/x.md');
      expect(mapPrivatePath('  .self/a  ', 'agt_1'), '.tree/agt_1/.self/a');
    });

    test('已经按 agent 分栏的真实路径与普通路径都原样返回（两种写法都合法）', () {
      expect(
        mapPrivatePath('.tree/agt_1/.self/a', 'agt_1'),
        '.tree/agt_1/.self/a',
      );
      expect(mapPrivatePath('src/main.dart', 'agt_1'), 'src/main.dart');
      expect(mapPrivatePath('.input/20261002/a.png', 'agt_1'), '.input/20261002/a.png');
      expect(mapPrivatePath('.selfish/a', 'agt_1'), '.selfish/a', reason: '不是 .self 目录');
    });
  });

  group('PrivateWorkspaceIO：文件工具读写落到自己的分栏', () {
    late Directory root;
    late PrivateWorkspaceIO io;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tree_private_io_');
      io = PrivateWorkspaceIO(LocalWorkspaceIO(root.path), 'agt_1');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('writeFile/readFile：模型写 .self/… 落盘在 .tree/<agent>/.self/…', () async {
      await io.writeFile('.self/plan/x.md', '计划正文');
      final File onDisk = File(
        p.join(root.path, '.tree', 'agt_1', '.self', 'plan', 'x.md'),
      );
      expect(onDisk.existsSync(), isTrue, reason: '真实位置按 agent 分栏');
      expect(onDisk.readAsStringSync(), '计划正文');
      expect(File(p.join(root.path, '.self', 'plan', 'x.md')).existsSync(), isFalse);

      expect((await io.readFile('.self/plan/x.md')).text, '计划正文');
      // 真实路径同样可读（工具结果里回显的就是它，可以继续拿来用）
      expect(
        (await io.readFile('.tree/agt_1/.self/plan/x.md')).text,
        '计划正文',
      );
    });

    test('普通路径不受影响；resolve 也按同一口径', () async {
      await io.writeFile('hello.http', 'GET /');
      expect(
        File(p.join(root.path, 'hello.http')).readAsStringSync(),
        'GET /',
      );
      expect(io.resolve('.self/a'), p.join(root.path, '.tree', 'agt_1', '.self', 'a'));
      expect(io.root, root.path, reason: '工作空间根不变（项目文件仍然是共享的那一份）');
    });

    test('editFile / grep / listFiles 都在自己的分栏里', () async {
      await io.writeFile('.self/spec/note.md', 'needle here');
      final EditOutcome edit = await io.editFile(
        '.self/spec/note.md',
        oldText: 'needle',
        newText: 'haystack',
      );
      expect(edit.replacements, 1);
      final GrepOutcome found = await io.grep(
        const GrepQuery(pattern: 'haystack', relativePath: '.self'),
      );
      expect(found.matches, hasLength(1));
      expect(found.matches.single.path, contains('.tree/agt_1/.self/spec/note.md'));
      final List<String> listed = await io.listFiles(relativePath: '.self');
      expect(listed.join('\n'), contains('spec'));
    });

    test('本机后端不是 WorkspaceFiles：文件面板接口显式报错而不是假装成功', () {
      expect(() => io.listEntries('.self'), throwsA(isA<WorkspaceIoException>()));
    });
  });

  group('migrateLegacySelfDir：旧 .self 一次性搬到按 agent 分栏处', () {
    test('搬过去、幂等、目标已存在时不覆盖', () {
      final Directory root = Directory.systemTemp.createTempSync('tree_self_migrate_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final File legacy = File(
        p.join(root.path, '.self', 'system_prompt.md'),
      )..createSync(recursive: true);
      legacy.writeAsStringSync('我改过的提示词');

      final List<String> logs = <String>[];
      migrateLegacySelfDir(
        workspaceDir: root.path,
        agentId: 'agt_1',
        log: logs.add,
      );
      expect(
        File(
          p.join(root.path, '.tree', 'agt_1', '.self', 'system_prompt.md'),
        ).readAsStringSync(),
        '我改过的提示词',
        reason: '用户改过的系统提示词不能丢',
      );
      expect(Directory(p.join(root.path, '.self')).existsSync(), isFalse);
      expect(logs.single, contains('.tree/agt_1/.self'));

      // 幂等：再来一次既不报错也不再记日志
      migrateLegacySelfDir(
        workspaceDir: root.path,
        agentId: 'agt_1',
        log: logs.add,
      );
      expect(logs, hasLength(1));

      // 目标已存在 ⇒ 不动（保护新分栏，绝不覆盖）
      File(p.join(root.path, '.self', 'again.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('新的一份');
      migrateLegacySelfDir(
        workspaceDir: root.path,
        agentId: 'agt_1',
        log: logs.add,
      );
      expect(
        File(p.join(root.path, '.tree', 'agt_1', '.self', 'again.md')).existsSync(),
        isFalse,
      );
    });
  });
}