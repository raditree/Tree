import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory root;
  late TreePaths paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_todos_');
    paths = TreePaths(root.path);
    paths.ensureLayoutSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('TodoItem', () {
    test('状态归一化：非法值回落 pending，大小写与空白宽容', () {
      expect(TodoItem.normalizeStatus('IN_PROGRESS'), 'in_progress');
      expect(TodoItem.normalizeStatus(' completed '), 'completed');
      expect(TodoItem.normalizeStatus('done'), 'pending');
      expect(TodoItem.normalizeStatus(''), 'pending');
    });

    test('进度夹取到 0~100', () {
      expect(TodoItem.clampProgress(-5), 0);
      expect(TodoItem.clampProgress(150), 100);
      expect(TodoItem.clampProgress(42), 42);
    });

    test('API 形态字段与前端 TodoItem.fromJson 对齐', () {
      const TodoItem todo = TodoItem(
        id: 't1',
        content: '写测试',
        status: 'in_progress',
        progress: 40,
        updatedAt: 123,
      );
      expect(todo.toApiJson(), <String, dynamic>{
        'id': 't1',
        'content': '写测试',
        'status': 'in_progress',
        'progress': 40,
        'updated_at': 123,
      });
    });
  });

  group('markdown 编解码', () {
    test('往返一致（含正文里有 | 与 — 这类符号）', () {
      final List<TodoItem> source = <TodoItem>[
        const TodoItem(id: 't1', content: '实现登录 | 支持 token'),
        const TodoItem(
          id: 't2',
          content: '写测试 — 覆盖 CRLF',
          status: 'in_progress',
          progress: 40,
        ),
        const TodoItem(
          id: 't3',
          content: '提交',
          status: 'completed',
          progress: 100,
        ),
      ];
      final String text = FileTodoStore.encodeMarkdown(source, header: '头');
      expect(text.startsWith('# 头'), isTrue);
      expect(text, contains('- [~] t2 | status=in_progress progress=40 |'));
      final List<TodoItem> back = FileTodoStore.decodeMarkdown(text);
      expect(back.length, 3);
      expect(back[0].content, '实现登录 | 支持 token');
      expect(back[0].status, 'pending');
      expect(back[1].content, '写测试 — 覆盖 CRLF');
      expect(back[1].progress, 40);
      expect(back[2].status, 'completed');
    });

    test('空清单写成（暂无待办）并解析回空列表', () {
      final String text = FileTodoStore.encodeMarkdown(<TodoItem>[]);
      expect(text, contains('暂无待办'));
      expect(FileTodoStore.decodeMarkdown(text), isEmpty);
    });

    test('手改容错：缺少元数据的勾选行也能读出来', () {
      final List<TodoItem> items = FileTodoStore.decodeMarkdown('''
# 我自己写的
- [ ] 随手加一条
- [x] 这条完成了
- [~] t9 | status=in_progress progress=30 | 正规范式
正文段落不会被当成待办
''');
      expect(items.length, 3);
      expect(items[0].content, '随手加一条');
      expect(items[0].status, 'pending');
      expect(items[1].status, 'completed');
      expect(items[1].progress, 100);
      expect(items[2].id, 't9');
    });

    test('非法状态与越界进度在解析时被纠正', () {
      final List<TodoItem> items = FileTodoStore.decodeMarkdown(
        '- [ ] t1 | status=whatever progress=999 | 越界',
      );
      expect(items.single.status, 'pending');
      expect(items.single.progress, 100);
    });
  });

  group('FileTodoStore', () {
    test('写入会话目录并在读取时还原；按会话隔离', () {
      final FileTodoStore store = FileTodoStore(paths);
      expect(store.read('agt_1', 'ses_1'), isEmpty);
      store.write('agt_1', 'ses_1', <TodoItem>[
        const TodoItem(id: 't1', content: '一'),
        const TodoItem(
          id: 't2',
          content: '二',
          status: 'completed',
          progress: 100,
        ),
      ]);
      final File file = File(paths.todoFile('agt_1', 'ses_1'));
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('t1 | status=pending'));

      final List<TodoItem> back = store.read('agt_1', 'ses_1');
      expect(back.map((TodoItem t) => t.content).toList(), <String>['一', '二']);
      expect(store.read('agt_1', 'ses_2'), isEmpty, reason: '按会话隔离');
    });

    test('写入是原子替换（不残留 .tmp），且覆盖旧内容', () {
      final FileTodoStore store = FileTodoStore(paths);
      store.write('agt_1', 'ses_1', <TodoItem>[
        const TodoItem(id: 't1', content: '旧'),
      ]);
      store.write('agt_1', 'ses_1', <TodoItem>[
        const TodoItem(id: 't9', content: '新'),
      ]);
      final String text = File(paths.todoFile('agt_1', 'ses_1'))
          .readAsStringSync();
      expect(text, contains('新'));
      expect(text, isNot(contains('旧')));
      expect(text, isNot(contains('.tmp')));
      expect(
        Directory(paths.sessionDir('agt_1', 'ses_1'))
            .listSync()
            .where((FileSystemEntity e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('手改文件后读取生效', () {
      final FileTodoStore store = FileTodoStore(paths);
      store.write('agt_1', 'ses_1', <TodoItem>[
        const TodoItem(id: 't1', content: '原始'),
      ]);
      File(paths.todoFile('agt_1', 'ses_1'))
          .writeAsStringSync('- [ ] t1 | status=pending progress=0 | 手改后的内容\n');
      expect(store.read('agt_1', 'ses_1').single.content, '手改后的内容');
    });
  });

  test('renderTodos 给模型看的清单带状态与进度', () {
    const List<TodoItem> todos = <TodoItem>[
      TodoItem(id: 't1', content: '待办一'),
      TodoItem(id: 't2', content: '进行中', status: 'in_progress', progress: 40),
      TodoItem(id: 't3', content: '完成', status: 'completed', progress: 100),
      TodoItem(id: 't4', content: '卡住', status: 'blocked'),
    ];
    final String text = renderTodos(todos);
    expect(text, contains('待办 4 项（已完成 1）'));
    expect(text, contains('[ ] t1 待办一 (pending 0%)'));
    expect(text, contains('[~] t2 进行中 (in_progress 40%)'));
    expect(text, contains('[x] t3 完成 (completed 100%)'));
    expect(text, contains('[!] t4 卡住 (blocked 0%)'));
    expect(renderTodos(<TodoItem>[]), contains('暂无待办'));
  });
}
