import 'todo_store.dart';

/// 塞进每次工具结果前的"会话状态"提示（M5d）。
///
/// 为什么每个工具结果都带：模型最容易忘的两件事就是"我有一条 in_progress 的 todo"
/// 和"本会话挂了哪个 Spec"。参考实现把它们拼在每次工具结果前，这里保持同一语义
/// （文案也刻意保持接近，便于对照排障）。
String sessionStatusText({
  required List<TodoItem> todos,
  required List<String> selectedSpecIds,
}) {
  final String timestamp = _timestamp();
  return '当前 in_progress todo（current_todo_id）：\n'
      '${todoStatusText(todos)}\n'
      '当前 selected spec（selected spec）：\n'
      '${specStatusText(selectedSpecIds)}\n'
      '---\n结果返回时间：$timestamp（本机时间）\n';
}

/// todo 三态文案。
String todoStatusText(List<TodoItem> todos) {
  if (todos.isEmpty) return ' - "[Warning]todo 未设置"';
  final List<TodoItem> running = todos
      .where((TodoItem t) => t.status == 'in_progress')
      .toList(growable: false);
  if (running.isEmpty) {
    return ' - "[Info]todo 已设置：${todos.length} 项，'
        '[Warning]无 in_progress 项，请更新进度或开始 pending 项"';
  }
  final String items = running
      .map((TodoItem t) => '${t.id} ${t.progress}%')
      .join(', ');
  return ' - "[Info]当前 in_progress：$items';
}

/// spec 三态文案（内置 = [kBuiltinSpecIds] 里的 id）。
String specStatusText(List<String> selectedSpecIds) {
  if (selectedSpecIds.isEmpty) return ' - "[Warning]spec 未选择"';
  bool hasBuiltin = false;
  final StringBuffer items = StringBuffer();
  for (final String id in selectedSpecIds) {
    final bool builtin = kBuiltinSpecIdSet.contains(id);
    if (builtin) hasBuiltin = true;
    items.write('$id(${builtin ? '内置' : '自定义'})，');
  }
  return ' - "[Info]已选择：[${items.toString()}]'
      '${hasBuiltin ? '' : '[Warning]至少选择一个内置 spec'}';
}

/// 内置 Spec id 的集合（判断文案用）。
const Set<String> kBuiltinSpecIdSet = <String>{
  'general-task',
  'hard-task',
  'team-meeting',
};

String _timestamp() {
  final DateTime now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}
