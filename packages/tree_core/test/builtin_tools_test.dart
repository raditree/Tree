import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

void main() {
  late Directory root;
  late LocalWorkspaceIO io;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_tools_');
    io = LocalWorkspaceIO(root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ToolInvocation call(String name, [Map<String, dynamic> args = const {}]) =>
      ToolInvocation(
        id: 'tool_1',
        name: name,
        arguments: args,
        rawArguments: '',
        agentId: 'agt_1',
        sessionId: 'ses_1',
      );

  Future<ToolOutcome> run(
    String name, [
    Map<String, dynamic> args = const {},
  ]) => BuiltinTools.run(call(name, args), io);

  group('工具声明', () {
    test('M4 只声明已实现的 5 个工作空间工具', () {
      final List<String> names = BuiltinTools.specs()
          .map((ToolSpec s) => s.name)
          .toList();
      expect(
        names,
        <String>['read', 'write', 'edit', 'grep', 'terminal'],
        reason:
            '未实现的工具（team/message/spec/ask_user_question/mcp）不得声明，'
            '否则模型会调用并浪费一整轮 token',
      );
      for (final ToolSpec spec in BuiltinTools.specs()) {
        expect(spec.description, isNotEmpty, reason: '${spec.name} 缺少描述');
        final Map<String, dynamic> params = spec.parameters;
        expect(params['type'], 'object');
        expect(
          (params['required'] as List<dynamic>).isNotEmpty,
          isTrue,
          reason: '${spec.name} 应声明必填参数',
        );
      }
    });

    test('未知工具名回一条列出可用工具的错误结果', () async {
      final ToolOutcome outcome = await run('nope');
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('未知工具'));
      expect(outcome.content, contains('grep'));
    });
  });

  group('read / write / edit', () {
    test('write 后 read 能看到内容；read 带行范围与语言提示', () async {
      final ToolOutcome written = await run('write', <String, dynamic>{
        'file_path': 'lib/a.dart',
        'content': 'void main() {}\n// 注释\n',
      });
      expect(written.isError, isFalse);
      expect(written.content, contains('lib/a.dart'));

      final ToolOutcome readBack = await run('read', <String, dynamic>{
        'file_path': 'lib/a.dart',
      });
      expect(readBack.content, contains('void main() {}'));
      expect(readBack.content, contains('```dart'));
      expect(readBack.content, contains('共 2 行'));

      final ToolOutcome ranged = await run('read', <String, dynamic>{
        'file_path': 'lib/a.dart',
        'start_line': 2,
        'line_count': 1,
      });
      expect(ranged.content, contains('// 注释'));
      expect(ranged.content, isNot(contains('void main')));
    });

    test('read 的路径越界/文件不存在给出可读错误（不是异常）', () async {
      final ToolOutcome escape = await run('read', <String, dynamic>{
        'file_path': '../secret.txt',
      });
      expect(escape.isError, isTrue);
      expect(escape.content, contains('路径不合法'));
      expect(escape.content, contains('相对路径'));

      final ToolOutcome missing = await run('read', <String, dynamic>{
        'file_path': 'nope.txt',
      });
      expect(missing.isError, isTrue);
      expect(missing.content, contains('文件不存在'));
    });

    test('read 缺少 file_path、write 缺少 content 都是可读错误', () async {
      expect((await run('read')).isError, isTrue);
      final ToolOutcome write = await run('write', <String, dynamic>{
        'file_path': 'a.txt',
      });
      expect(write.isError, isFalse, reason: 'content 缺省视为空串写入');
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), isEmpty);
    });

    test('edit 替换并回报处数；唯一性冲突时提示解法', () async {
      await io.writeFile('a.txt', 'alpha beta gamma');
      final ToolOutcome ok = await run('edit', <String, dynamic>{
        'file_path': 'a.txt',
        'old_text': 'beta',
        'new_text': 'BETA',
      });
      expect(ok.isError, isFalse);
      expect(ok.content, contains('已替换 1 处'));

      await io.writeFile('b.txt', 'xx xx');
      final ToolOutcome dup = await run('edit', <String, dynamic>{
        'file_path': 'b.txt',
        'old_text': 'xx',
        'new_text': 'yy',
      });
      expect(dup.isError, isTrue);
      expect(dup.content, contains('replace_all'));
    });
  });

  group('grep', () {
    test('命中格式为 路径:行号: 内容；无命中也有明确结论', () async {
      await io.writeFile('src/a.dart', 'final x = 1;\nfinal needle = 2;\n');
      final ToolOutcome hit = await run('grep', <String, dynamic>{
        'pattern': 'needle',
      });
      expect(hit.isError, isFalse);
      expect(hit.content, contains('src/a.dart:2:'));
      expect(hit.content, contains('needle = 2'));

      final ToolOutcome none = await run('grep', <String, dynamic>{
        'pattern': 'nothing-here',
      });
      expect(none.content, contains('命中 0 处'));
      expect(none.content, contains('无匹配'));
    });

    test('参数宽容：regex/ignore_case 传字符串、exclude 传逗号串', () async {
      await io.writeFile('a.txt', 'Todo\nTODO\n');
      final ToolOutcome outcome = await run('grep', <String, dynamic>{
        'pattern': 'todo',
        'ignore_case': 'true',
        'regex': 'false',
        'max_results': '50',
        'exclude': '*.g.dart, *.min.js',
      });
      expect(outcome.content, contains('命中 2 处'));
    });

    test('缺少 pattern 是错误', () async {
      expect((await run('grep')).isError, isTrue);
    });
  });

  group('terminal', () {
    test('成功命令回报退出码与 stdout', () async {
      final ToolOutcome outcome = await run('terminal', <String, dynamic>{
        'command': 'echo hello-from-tool',
      });
      expect(outcome.isError, isFalse);
      expect(outcome.content, contains('退出码 0'));
      expect(outcome.content, contains('hello-from-tool'));
      expect(outcome.content, contains('shell='));
    });

    test('非零退出码标记 isError 但仍返回输出', () async {
      final ToolOutcome outcome = await run('terminal', <String, dynamic>{
        'command': 'exit 7',
      });
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('退出码 7'));
    });

    test('缺少 command 与空 command 都是错误', () async {
      expect((await run('terminal')).isError, isTrue);
      final ToolOutcome empty = await run('terminal', <String, dynamic>{
        'command': '   ',
      });
      expect(empty.isError, isTrue);
      expect(empty.content, contains('command 不能为空'));
    });

    test('timeout_seconds 越界被夹取（1~1800）', () async {
      final ToolOutcome outcome = await run('terminal', <String, dynamic>{
        'command': 'echo quick',
        'timeout_seconds': 99999,
      });
      expect(outcome.isError, isFalse);
    });
  });

  group('WorkspaceToolRunner', () {
    test('按需创建工作空间目录并复用同一实例', () async {
      final String dir = p.join(root.path, 'ws', 'agt_1');
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String agentId) =>
            p.join(root.path, 'ws', agentId),
      );
      expect(Directory(dir).existsSync(), isFalse);
      final ToolOutcome outcome = await runner.run(
        call('write', <String, dynamic>{'file_path': 'a.txt', 'content': 'x'}),
      );
      expect(outcome.isError, isFalse);
      expect(Directory(dir).existsSync(), isTrue);
      expect(File(p.join(dir, 'a.txt')).existsSync(), isTrue);
      expect(runner.workspaceRoots, hasLength(1));
      await runner.close();
    });

    test('工作空间目录解析为空 → 可读错误', () async {
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String agentId) => '',
      );
      final ToolOutcome outcome = await runner.run(
        call('write', <String, dynamic>{'file_path': 'a.txt', 'content': 'x'}),
      );
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('工作空间'));
      await runner.close();
    });

    test('超长结果被截断并标注省略字符数', () async {
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String agentId) => root.path,
        maxResultChars: 200,
      );
      await io.writeFile('big.txt', 'y' * 5000);
      final ToolOutcome outcome = await runner.run(
        call('read', <String, dynamic>{'file_path': 'big.txt'}),
      );
      expect(outcome.content.length, lessThan(5000));
      expect(outcome.content, contains('结果过长'));
      await runner.close();
    });
  });
}
