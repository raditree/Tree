import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// exec 直接以「SSH 心跳丢失」失败的工作空间（terminal 软超时→hook 用）。
///
/// 从 LocalWorkspaceIO 派生而不是手写整个接口：只替换 exec 一个方法，其余行为
/// （resolve / writeFile）仍是真实实现，转后台的日志因此能真的落盘。
class _StaleIo extends LocalWorkspaceIO {
  _StaleIo(super.root);

  /// exec 被调用的次数：用来断言「绝不重跑命令」。
  int execCalls = 0;

  @override
  Future<ExecOutcome> exec(
    String command, {
    Duration timeout = const Duration(seconds: 120),
    int maxOutputBytes = 200 * 1024,
  }) async {
    execCalls++;
    throw SshLinkStaleException('SSH 链路失活：连续 3 次心跳丢失（测试）');
  }
}

void main() {
  late Directory root;
  late LocalWorkspaceIO io;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_tools_');
    io = LocalWorkspaceIO(root.path);
  });

  tearDown(() async {
    // hook 模式会拉起真实子进程：Windows 上子进程退出后可能还短暂持有日志文件
    // 句柄，直接删会偶发 PathAccessException，因此重试几次
    for (int i = 0; i < 10 && root.existsSync(); i++) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
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

    test('无匹配时列出实际扫描范围：扫描根/文件清单/生效排除目录（Q10）', () async {
      await io.writeFile('src/a.dart', 'final x = 1;');
      await io.writeFile('src/b.dart', 'final y = 2;');
      // 真存在的依赖目录：默认排除规则会跳过它，因此必须出现在「生效的排除目录」里
      await io.writeFile('node_modules/pkg/index.js', 'module.exports = 1;');

      final ToolOutcome none = await run('grep', <String, dynamic>{
        'pattern': 'nothing-here',
      });
      expect(none.content, contains('命中 0 处'));
      expect(none.content, contains('扫描根：.'));
      expect(none.content, contains('扫描文件：2 个'));
      expect(none.content, contains('src/a.dart'));
      expect(none.content, contains('src/b.dart'));
      expect(none.content, contains('生效的排除目录'));
      expect(none.content, contains('node_modules'));
    });

    test('有匹配时行为不变（不追加扫描清单）', () async {
      await io.writeFile('src/a.dart', 'final needle = 1;');
      final ToolOutcome hit = await run('grep', <String, dynamic>{
        'pattern': 'needle',
      });
      expect(hit.content, contains('命中 1 处'));
      expect(hit.content, contains('src/a.dart:1:'));
      expect(hit.content, isNot(contains('生效的排除目录')));
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

    test('跑得比旧的 timeout_seconds 上限久也不转后台、不终止（1.1：静态时长不再是判据）', () async {
      final TerminalHooks hooks = TerminalHooks();
      addTearDown(hooks.close);
      final String command = Platform.isWindows
          ? 'ping -n 3 127.0.0.1 >nul'
          : 'sleep 2';
      final DateTime started = DateTime.now();
      final ToolOutcome outcome = await BuiltinTools.run(
        call('terminal', <String, dynamic>{
          'command': command,
          'timeout_seconds': 1,
        }),
        io,
        hooks: hooks,
      );
      expect(outcome.isError, isFalse, reason: outcome.content);
      expect(outcome.content, contains('退出码 0'));
      expect(hooks.tasks, isEmpty, reason: '进程还活着（本地活性 = 进程存活）就不该转后台');
      expect(
        DateTime.now().difference(started).inMilliseconds,
        greaterThan(1000),
        reason: '真的等它跑完了，没有按静态时长提前返回',
      );
    });

    test('schema 不再声明 timeout_seconds；老参数被忽略', () async {
      final ToolSpec spec = BuiltinTools.specs().firstWhere(
        (ToolSpec s) => s.name == 'terminal',
      );
      final Map<String, dynamic> properties =
          spec.parameters['properties'] as Map<String, dynamic>;
      expect(
        properties.containsKey('timeout_seconds'),
        isFalse,
        reason: 'M9 1.1：没有静态时长上限，schema 不能留可限定时长的参数',
      );
      expect(spec.description, contains('没有静态超时'));
      // 兼容：老调用方仍传该参数时直接忽略，不影响执行
      final ToolOutcome outcome = await run('terminal', <String, dynamic>{
        'command': 'echo quick',
        'timeout_seconds': 99999,
      });
      expect(outcome.isError, isFalse);
      expect(outcome.content, contains('quick'));
    });
  });

  group('set_todo_list', () {
    test('未接入存储时不声明该工具（声明了没实现会让模型白调一轮）', () {
      final List<String> bare = BuiltinTools.specs()
          .map((ToolSpec s) => s.name)
          .toList();
      expect(bare, isNot(contains('set_todo_list')));
      final List<String> withTodos = BuiltinTools.specs(withTodos: true)
          .map((ToolSpec s) => s.name)
          .toList();
      expect(withTodos, contains('set_todo_list'));
      expect(withTodos.length, bare.length + 1);
    });

    test('未传存储时执行该工具回可读错误', () async {
      final ToolOutcome outcome = await BuiltinTools.run(
        call('set_todo_list', <String, dynamic>{'action': 'get'}),
        io,
      );
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('待办存储未接入'));
    });

    test('set → update → get → clear 全链路，id 自动分配且返回清单', () async {
      final MemoryTodoStore store = MemoryTodoStore();
      Future<ToolOutcome> todo(Map<String, dynamic> args) => BuiltinTools.run(
        call(BuiltinTools.setTodoList, args),
        io,
        todos: store,
      );

      final ToolOutcome setOutcome = await todo(<String, dynamic>{
        'action': 'set',
        'todos': <dynamic>[
          <String, dynamic>{'content': '实现登录'},
          <String, dynamic>{'content': '写测试', 'status': 'completed'},
        ],
      });
      expect(setOutcome.isError, isFalse);
      expect(setOutcome.content, contains('已设置 2 项'));
      expect(setOutcome.content, contains('t1'));
      expect(setOutcome.content, contains('已完成 1'));
      expect(
        store.read('agt_1', 'ses_1').map((TodoItem t) => t.id).toList(),
        <String>['t1', 't2'],
      );
      expect(
        store.read('agt_1', 'ses_1')[1].progress,
        100,
        reason: 'completed 未显式给进度时默认 100%',
      );

      final ToolOutcome updated = await todo(<String, dynamic>{
        'action': 'update',
        'todos': <dynamic>[
          <String, dynamic>{
            'id': 't1',
            'status': 'in_progress',
            'progress': '40',
          },
        ],
      });
      expect(updated.isError, isFalse);
      expect(updated.content, contains('(in_progress 40%)'));
      expect(store.read('agt_1', 'ses_1')[0].status, 'in_progress');
      expect(
        store.read('agt_1', 'ses_1')[0].content,
        '实现登录',
        reason: 'update 未给 content 时保留原文',
      );

      final ToolOutcome got = await todo(<String, dynamic>{'action': 'get'});
      expect(got.content, contains('t2'));

      final ToolOutcome cleared = await todo(<String, dynamic>{
        'action': 'clear',
      });
      expect(cleared.content, contains('已清空'));
      expect(store.read('agt_1', 'ses_1'), isEmpty);
    });

    test('错误路径：未知 action / set 空清单 / 缺 content / update 未知 id', () async {
      final MemoryTodoStore store = MemoryTodoStore();
      Future<ToolOutcome> todo(Map<String, dynamic> args) => BuiltinTools.run(
        call(BuiltinTools.setTodoList, args),
        io,
        todos: store,
      );

      final ToolOutcome badAction = await todo(<String, dynamic>{
        'action': 'boom',
      });
      expect(badAction.isError, isTrue);
      expect(badAction.content, contains('未知 action'));

      final ToolOutcome emptySet = await todo(<String, dynamic>{
        'action': 'set',
      });
      expect(emptySet.isError, isTrue);
      expect(emptySet.content, contains('action=clear'));

      final ToolOutcome noContent = await todo(<String, dynamic>{
        'action': 'set',
        'todos': <dynamic>[
          <String, dynamic>{'content': 'ok'},
          <String, dynamic>{'content': '   '},
        ],
      });
      expect(noContent.isError, isTrue);
      expect(noContent.content, contains('第 2 项缺少 content'));

      await todo(<String, dynamic>{
        'action': 'set',
        'todos': <dynamic>[
          <String, dynamic>{'content': '唯一'},
        ],
      });
      final ToolOutcome unknownId = await todo(<String, dynamic>{
        'action': 'update',
        'todos': <dynamic>[
          <String, dynamic>{'id': 'zzz', 'status': 'blocked'},
        ],
      });
      expect(unknownId.isError, isTrue);
      expect(unknownId.content, contains('未知待办 id'));
      expect(unknownId.content, contains('t1'), reason: '错误里要列出可用 id');

      final ToolOutcome missingId = await todo(<String, dynamic>{
        'action': 'update',
        'todos': <dynamic>[
          <String, dynamic>{'status': 'completed'},
        ],
      });
      expect(missingId.isError, isTrue);
      expect(missingId.content, contains('必须带 id'));
    });
  });

  group('terminal hook 模式', () {
    test('声明里带 hook 相关参数', () {
      final ToolSpec spec = BuiltinTools.specs().firstWhere(
        (ToolSpec s) => s.name == 'terminal',
      );
      final Map<String, dynamic> props =
          spec.parameters['properties'] as Map<String, dynamic>;
      expect(
        props.keys,
        containsAll(<String>['hook', 'output_file', 'hook_action', 'task_id']),
      );
      expect((props['hook_action'] as Map<String, dynamic>)['enum'], <String>[
        'status',
        'cancel',
      ]);
    });

    test('未接入 hooks 时：hook=true 与 hook_action 都回可读错误', () async {
      final ToolOutcome hookOff = await run('terminal', <String, dynamic>{
        'command': 'echo x',
        'hook': true,
      });
      expect(hookOff.isError, isTrue);
      expect(hookOff.content, contains('后台任务未接入'));

      final ToolOutcome statusOff = await run('terminal', <String, dynamic>{
        'command': 'echo x',
        'hook_action': 'status',
        'task_id': 'nope',
      });
      expect(statusOff.isError, isTrue);
      expect(statusOff.content, contains('后台任务未接入'));
    });

    test('启动/查询/取消：立即返回 task_id，未知 id 与未知 action 有可读错误', () async {
      final TerminalHooks hooks = TerminalHooks();
      addTearDown(hooks.close);
      Future<ToolOutcome> hookCall(Map<String, dynamic> args) =>
          BuiltinTools.run(call('terminal', args), io, hooks: hooks);

      final ToolOutcome started = await hookCall(<String, dynamic>{
        'command': 'echo tool-hook-ok',
        'hook': true,
      });
      expect(started.isError, isFalse);
      expect(started.content, contains('task_id: hook_'));
      expect(started.content, contains('日志：.output/hook_'));
      expect(hooks.tasks, hasLength(1));

      final String taskId = hooks.tasks.single.id;
      // 等命令结束（echo 很快）
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
      while (hooks.tasks.single.running && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final ToolOutcome status = await hookCall(<String, dynamic>{
        'command': 'echo x',
        'hook_action': 'status',
        'task_id': taskId,
      });
      expect(status.isError, isFalse);
      expect(status.content, contains('已结束'));
      expect(status.content, contains('退出码 0'));
      expect(status.content, contains('tool-hook-ok'));

      final ToolOutcome unknownTask = await hookCall(<String, dynamic>{
        'command': 'echo x',
        'hook_action': 'status',
        'task_id': 'hook_nope',
      });
      expect(unknownTask.isError, isTrue);
      expect(unknownTask.content, contains('未知 task_id'));
      expect(unknownTask.content, contains(taskId), reason: '错误里要列出现有任务');

      final ToolOutcome missingTask = await hookCall(<String, dynamic>{
        'command': 'echo x',
        'hook_action': 'status',
      });
      expect(missingTask.isError, isTrue);
      expect(missingTask.content, contains('需要 task_id'));

      final ToolOutcome badAction = await hookCall(<String, dynamic>{
        'command': 'echo x',
        'hook_action': 'watch',
        'task_id': taskId,
      });
      expect(badAction.isError, isTrue);
      expect(badAction.content, contains('未知 hook_action'));
    });

    test('SSH 心跳丢失：不杀进程、不重跑，转后台任务并给出查询/续看方式（1.1）', () async {
      final _StaleIo stale = _StaleIo(root.path);
      final TerminalHooks hooks = TerminalHooks();
      addTearDown(hooks.close);
      final ToolOutcome outcome = await BuiltinTools.run(
        call('terminal', <String, dynamic>{'command': 'sleep 999'}),
        stale,
        hooks: hooks,
      );
      expect(outcome.isError, isTrue, reason: '命令没跑完，不能算成功');
      expect(outcome.content, contains('会话心跳丢失'));
      expect(outcome.content, contains('没有终止远端进程，也没有重跑命令'));
      expect(outcome.content, contains('task_id: hook_'));
      expect(outcome.content, contains('hook_action=status'));
      expect(stale.execCalls, 1, reason: '绝不能重跑同一条命令（会重复副作用）');

      expect(hooks.tasks, hasLength(1));
      final HookTask task = hooks.tasks.single;
      expect(task.detached, isTrue);
      expect(task.process, isNull, reason: '本机没有进程句柄，也就无从「杀进程」');

      final ToolOutcome status = await BuiltinTools.run(
        call('terminal', <String, dynamic>{
          'command': 'x',
          'hook_action': 'status',
          'task_id': task.id,
        }),
        stale,
        hooks: hooks,
      );
      expect(status.content, contains('已转后台'));
      expect(status.content, contains('无法确认'));

      final ToolOutcome cancel = await BuiltinTools.run(
        call('terminal', <String, dynamic>{
          'command': 'x',
          'hook_action': 'cancel',
          'task_id': task.id,
        }),
        stale,
        hooks: hooks,
      );
      expect(cancel.isError, isTrue);
      expect(cancel.content, contains('无法终止'));
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

    test('默认不截断：超长结果原样交给门控，门控重定向到 .self/results（Q1+Q9）', () async {
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String agentId) => root.path,
      );
      await io.writeFile('big.txt', 'y' * 40000);
      final ToolOutcome outcome = await runner.run(
        call('read', <String, dynamic>{'file_path': 'big.txt'}),
      );
      expect(
        outcome.content.length,
        greaterThan(24000),
        reason: '工具层不再按 24000 字符先截断，否则根本走不到门控',
      );
      expect(outcome.content, isNot(contains('结果过长')));

      // 门控：送模型的那一份换成提示 + 预览，全文落工作空间（前端/落库仍是全文）
      final List<String> written = <String>[];
      final ToolResultGate gate = ToolResultGate(
        agentId: 'agt_1',
        writer: (String agentId, String relativePath, String content) async {
          written.add(relativePath);
          await io.writeFile(relativePath, content);
        },
      );
      final String forModel = await gate.apply('read', outcome.content);
      expect(forModel, contains('[工具结果已重定向]'));
      expect(forModel.length, lessThan(1600), reason: '送模型的只有提示 + 300 字符预览');
      expect(written.single, startsWith('.self/results/'));
      expect(written.single, endsWith('.read.result'));
      final String saved = File(
        p.joinAll(<String>[root.path, ...written.single.split('/')]),
      ).readAsStringSync();
      expect(saved, outcome.content, reason: '落盘的是全文');
      await runner.close();
    });

    test('显式给上限时仍按上限截断（保留头 70% + 尾 30%）', () async {
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
