import 'dart:convert';

import 'package:path/path.dart' as p;

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';

/// 一条待办。
///
/// 字段与前端 `TodoItem.fromJson` 一一对应（`content` 而不是 `text`），状态取值
/// 与前端渲染分支一致：`pending` / `in_progress` / `completed` / `blocked`。
class TodoItem {
  const TodoItem({
    required this.id,
    required this.content,
    this.status = 'pending',
    this.progress = 0,
    this.updatedAt = 0,
  });

  factory TodoItem.fromJson(Map<String, dynamic> json) => TodoItem(
    id: (json['id'] ?? '').toString(),
    content: (json['content'] ?? '').toString(),
    status: (json['status'] ?? 'pending').toString(),
    progress: (json['progress'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String content;
  final String status;

  /// 0~100。
  final int progress;

  /// 最后更新时间（毫秒）。
  final int updatedAt;

  /// 前端形态（`GET /api/agents/{id}/todos` 的条目）。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'id': id,
    'content': content,
    'status': status,
    'progress': progress,
    'updated_at': updatedAt,
  };

  TodoItem copyWith({String? content, String? status, int? progress}) =>
      TodoItem(
        id: id,
        content: content ?? this.content,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  /// 非法状态一律回落 pending，避免前端 switch 落到意外分支。
  static String normalizeStatus(String raw) {
    const List<String> allowed = <String>[
      'pending',
      'in_progress',
      'completed',
      'blocked',
    ];
    final String value = raw.trim().toLowerCase();
    return allowed.contains(value) ? value : 'pending';
  }

  /// 夹取进度到 0~100。
  static int clampProgress(int value) =>
      value < 0 ? 0 : (value > 100 ? 100 : value);
}

/// 待办存储（按会话隔离）。
///
/// 桌面分支只有一个用户，因此不需要"按用户"这一维；`(agentId, sessionId)` 就是
/// 全部坐标。**接口是同步的**：待办是几十字节的小文件，且读取入口同时被 HTTP
/// 处理器与工具调用使用，同步语义最省心（写入用原子替换）。
abstract interface class TodoStore {
  /// 读取某会话的待办（无则空列表）。
  List<TodoItem> read(String agentId, String sessionId);

  /// 覆盖写入某会话的待办。
  void write(String agentId, String sessionId, List<TodoItem> todos);
}

/// 纯内存实现（测试与"无落盘"场景）。
class MemoryTodoStore implements TodoStore {
  final Map<String, List<TodoItem>> _byKey = <String, List<TodoItem>>{};

  static String _key(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  @override
  List<TodoItem> read(String agentId, String sessionId) =>
      List<TodoItem>.unmodifiable(
        _byKey[_key(agentId, sessionId)] ?? const <TodoItem>[],
      );

  @override
  void write(String agentId, String sessionId, List<TodoItem> todos) {
    _byKey[_key(agentId, sessionId)] = List<TodoItem>.of(todos);
  }
}

/// 落盘实现：`data/<agent_id>/<session_id>/todos.md`（人类可直接手改）。
///
/// 形态是 markdown 勾选清单，元数据前置、**正文放在最后**（正文里出现任何符号
/// 都不会破坏解析）：
/// ```
/// - [ ] t1 | status=pending progress=0 | 实现登录接口
/// - [~] t2 | status=in_progress progress=40 | 写测试
/// - [x] t3 | status=completed progress=100 | 提交
/// ```
/// 手改容错：缺少元数据的 `- [ ] 随便写点什么` 也能读出来（id 自动生成、状态按
/// 勾选框推断）；`status=` 是权威值，勾选框只作为人类可读性同步。
class FileTodoStore implements TodoStore {
  FileTodoStore(this.paths);

  final TreePaths paths;

  static const String _header =
      'Tree 会话待办（可直接手改；'
      'status= 为权威值，勾选框会随写入同步）。';

  @override
  List<TodoItem> read(String agentId, String sessionId) {
    final String file = paths.todoFile(agentId, sessionId);
    final String? text = AtomicFile.readStringOrNullSync(file);
    if (text == null || text.trim().isEmpty) return <TodoItem>[];
    return decodeMarkdown(text);
  }

  @override
  void write(String agentId, String sessionId, List<TodoItem> todos) {
    final String file = paths.todoFile(agentId, sessionId);
    AtomicFile.writeStringAtomicSync(
      file,
      encodeMarkdown(todos, header: _header),
    );
  }

  /// 解析 markdown 清单。
  static List<TodoItem> decodeMarkdown(String text) {
    final List<TodoItem> items = <TodoItem>[];
    final RegExp full = RegExp(
      r'^- \[([ x~!])\] (\S+) \| status=(\w+) progress=(\d+) \| (.*)$',
    );
    final RegExp loose = RegExp(r'^- \[([ x~!])\] (.*)$');
    int auto = 0;
    for (final String raw in const LineSplitter().convert(text)) {
      final String line = raw.trimRight();
      final RegExpMatch? match = full.firstMatch(line);
      if (match != null) {
        items.add(
          TodoItem(
            id: match.group(2)!,
            content: match.group(5)!.trim(),
            status: TodoItem.normalizeStatus(match.group(3)!),
            progress: TodoItem.clampProgress(
              int.tryParse(match.group(4)!) ?? 0,
            ),
          ),
        );
        continue;
      }
      final RegExpMatch? looseMatch = loose.firstMatch(line);
      if (looseMatch == null) continue;
      auto++;
      items.add(
        TodoItem(
          id: 'h$auto',
          content: looseMatch.group(2)!.trim(),
          status: looseMatch.group(1) == 'x' ? 'completed' : 'pending',
          progress: looseMatch.group(1) == 'x' ? 100 : 0,
        ),
      );
    }
    return items;
  }

  /// 生成 markdown 清单。
  static String encodeMarkdown(List<TodoItem> todos, {String header = ''}) {
    final StringBuffer buffer = StringBuffer();
    if (header.isNotEmpty) {
      buffer.writeln('# $header');
      buffer.writeln();
    }
    if (todos.isEmpty) {
      buffer.writeln('（暂无待办）');
      return buffer.toString();
    }
    for (final TodoItem todo in todos) {
      buffer.writeln(
        '- [${_box(todo.status)}] ${todo.id} | status=${todo.status} '
        'progress=${todo.progress} | ${todo.content}',
      );
    }
    return buffer.toString();
  }

  static String _box(String status) {
    switch (status) {
      case 'completed':
        return 'x';
      case 'in_progress':
        return '~';
      case 'blocked':
        return '!';
      default:
        return ' ';
    }
  }
}

/// 把待办渲染成模型可读的清单（工具返回值）。
String renderTodos(List<TodoItem> todos) {
  if (todos.isEmpty) return '（暂无待办）';
  final int done = todos.where((TodoItem t) => t.status == 'completed').length;
  final StringBuffer buffer = StringBuffer()
    ..writeln('待办 ${todos.length} 项（已完成 $done）：');
  for (final TodoItem todo in todos) {
    final String box = switch (todo.status) {
      'completed' => '[x]',
      'in_progress' => '[~]',
      'blocked' => '[!]',
      _ => '[ ]',
    };
    buffer.writeln(
      '$box ${todo.id} ${todo.content} '
      '(${todo.status} ${todo.progress}%)',
    );
  }
  return buffer.toString().trimRight();
}

/// 会话目录下的待办文件路径（挂在 [TreePaths] 上以保持布局集中）。
extension TodoPathLayout on TreePaths {
  /// `data/<agent_id>/<session_id>/todos.md`。
  String todoFile(String agentId, String sessionId) =>
      p.join(sessionDir(agentId, sessionId), 'todos.md');
}
