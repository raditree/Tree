import 'dart:async';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/atomic_file.dart';
import '../store/tree_store.dart';
import '../store/yaml_codec.dart';
import '../tool/tool_runner.dart';
import 'builtin_specs.dart';

/// 一份 Spec（任务型规范）：元数据 + 正文。
///
/// 内置模板来自内嵌常量（[kBuiltinSpecs]），自定义 Spec 是**工作空间里的**
/// `spec/<id>.md`（front matter + 三段正文）——文件才是真源，因此用户可以手改，
/// 也不需要额外的索引库。
class SpecDocument {
  SpecDocument({
    required this.id,
    required this.title,
    required this.body,
    this.taskType = 'custom',
    this.description = '',
    this.classification = '内部规范',
    this.risk = 'low',
    List<String>? when,
    List<String>? tags,
    List<String>? changelog,
    this.pinned = false,
    this.builtin = false,
    this.version = 1,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.raw = '',
  }) : when = when ?? <String>[],
       tags = tags ?? <String>[],
       changelog = changelog ?? <String>[];

  final String id;
  final String title;
  final String taskType;
  final String description;
  final List<String> when;
  final List<String> tags;
  final bool pinned;
  final bool builtin;
  final int version;
  final int createdAt;
  final int updatedAt;
  final String classification;
  final String risk;
  final List<String> changelog;

  /// 正文（不含 front matter）。
  final String body;

  /// 原文（front matter + 正文；`read` 直接返回它，保证与磁盘逐字一致）。
  final String raw;

  /// 索引形态（`GET /api/agents/{id}/specs` 列表项，字段与前端 spec_panel 对齐）。
  Map<String, dynamic> toMetaJson() => <String, dynamic>{
    'id': id,
    'spec_id': id,
    'title': title,
    'task_type': taskType,
    'description': description,
    'when': when,
    'tags': tags,
    'pinned': pinned,
    'builtin': builtin,
    'version': version,
    'classification': classification,
    'risk': risk,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// Spec 体系（M9 Q9 瘦身）：**索引前置 + 选择 / 沉淀 / 维护**。
///
/// 与参考实现的差异：
/// - **索引不再靠工具查**：索引直接注入系统提示词（见 `workspace_prompt.dart`
///   的 provider），因此 `search` / `list` / `read` 三个动作被删除，
///   `select` **直接返回所选 Spec 全文**（模型不必先 read 一遍再挂 hook）；
/// - 索引不是 SQLite 表，而是**扫文件**（内置模板 + 工作空间 `spec/*.md`）。单用户
///   桌面下文件数量是几十个量级，扫描比维护索引更简单、也不会出现"文件在、索引缺"
///   的不一致。
class SpecService {
  SpecService({required this.store, this.builtinSpecsDir = '', this.log});

  final TreeStore store;

  /// 内置模板的落盘目录（`<数据根>/spec/builtin`；空串 = 只读内嵌常量）。
  final String builtinSpecsDir;

  final void Function(String message)? log;

  /// Q9 索引快照：agentId → 已渲染的索引文本（见 [indexSnapshot]）。
  final Map<String, String> _indexText = <String, String>{};

  /// 正在后台刷新的 agent（避免每轮提示词都重复发起一次全量扫描）。
  final Set<String> _indexRefreshing = <String>{};

  /// 取某 agent 工作空间 IO 的解析器（Q9 索引后台刷新用）；由核心启动时接线。
  ///
  /// 为什么需要它：系统提示词是**同步**拼装的，而索引要读工作空间文件（异步）。
  /// 没有快照时 [indexSnapshot] 只能先给内置 4 条，靠这个解析器在后台补全量。
  Future<WorkspaceIO?> Function(String agentId)? ioFor;

  static const String specDir = 'spec';

  /// 首次启动把内置模板写到数据根（用户可查看、复制、手改副本）。
  Future<void> seedBuiltins() async {
    if (builtinSpecsDir.trim().isEmpty) return;
    for (final String id in kBuiltinSpecIds) {
      final String path = '$builtinSpecsDir/$id.md';
      try {
        await AtomicFile.writeStringAtomic(path, kBuiltinSpecs[id] ?? '');
      } catch (error) {
        log?.call('写内置 Spec 失败（$id）：$error');
      }
    }
  }

  /// 工具入口（Q9：只有 select / create / update 三个动作）。
  ///
  /// 每个动作成功后都**顺手刷新索引快照**：索引随系统提示词每轮重建，create/update
  /// 因此不需要额外的"刷新索引"动作——下一轮提示词里的索引就是新的。
  Future<Map<String, dynamic>> run(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String action = (invocation.arguments['action'] ?? '')
        .toString()
        .trim();
    final Map<String, dynamic> result;
    switch (action) {
      case 'select':
        result = await _select(invocation, io);
      case 'create':
        result = await _create(invocation, io);
      case 'update':
        result = await _update(invocation, io);
      default:
        return <String, dynamic>{
          'error': '未知 spec 动作: $action（应为 select/create/update）',
        };
    }
    if (!result.containsKey('error')) {
      await refreshIndex(invocation.agentId, io);
    }
    return result;
  }

  /// 索引（REST `GET /api/agents/{id}/specs` 与 memory/team 工具共用）。
  Future<List<SpecDocument>> index(String agentId, WorkspaceIO? io) async {
    final List<SpecDocument> out = <SpecDocument>[];
    final Set<String> seen = <String>{};
    for (final String id in kBuiltinSpecIds) {
      final String? text = kBuiltinSpecs[id];
      if (text == null) continue;
      out.add(parseSpecText(text, fallbackId: id, builtin: true));
      seen.add(id);
    }
    if (io != null) {
      for (final SpecDocument custom in await _customSpecs(io)) {
        if (seen.contains(custom.id)) continue; // 内置优先（与参考实现一致）
        out.add(custom);
      }
    }
    // 扫完顺手更新提示词快照：前端打开 Spec 面板（REST 索引）也会刷新它
    _indexText[agentId] = renderIndex(out);
    return out;
  }

  // ── 索引（Q9：注入系统提示词） ───────────────────────────────────────

  /// 索引最多列多少条（Q9 口径：默认全列，超 50 条截断并在尾部注明其余条数）。
  static const int indexLimit = 50;

  /// 单条「适用条件」摘要的字符上限（照旧实现：超 80 字符截断加省略号）。
  static const int whenSummaryLimit = 80;

  /// 把索引渲染成系统提示词里的列表（格式照旧实现）：
  /// 形如 `- id [task_type] 标题（内置）（适用: when 摘要）`，id 自带反引号。
  static String renderIndex(
    List<SpecDocument> specs, {
    int limit = indexLimit,
  }) {
    if (specs.isEmpty) {
      return '（暂无 Spec；任务完成后可用 spec create 沉淀）';
    }
    final StringBuffer buffer = StringBuffer();
    for (final SpecDocument spec in specs.take(limit)) {
      String when = spec.when.join('；');
      if (when.length > whenSummaryLimit) {
        when = '${when.substring(0, whenSummaryLimit)}…';
      }
      buffer.write('- `${spec.id}` [${spec.taskType}] ${spec.title}');
      if (spec.builtin) buffer.write('（内置）');
      if (when.trim().isNotEmpty) buffer.write('（适用: $when）');
      buffer.writeln();
    }
    final int rest = specs.length - limit;
    if (rest > 0) {
      buffer.writeln('- …其余 $rest 条可用 `spec select` 直取（需已知 id）');
    }
    return buffer.toString().trimRight();
  }

  /// 供系统提示词用的索引快照（**同步**：提示词是同步拼装的）。
  ///
  /// 没有快照时先只给**内置 4 条**（内嵌常量，随时算得出来），同时后台补一次全量：
  /// 会话第一轮不会因为「还没人扫过工作空间」而整段索引缺失，也不必让每轮提示词都
  /// 去等一次目录扫描（SSH 下那是一串网络往返）。
  String indexSnapshot(String agentId) {
    final String? cached = _indexText[agentId];
    if (cached == null) _refreshLater(agentId);
    return cached ?? renderIndex(_builtinDocuments());
  }

  /// 重新扫描并更新快照（[io] 为 null 时只有内置模板）。
  Future<void> refreshIndex(String agentId, WorkspaceIO? io) async {
    try {
      await index(agentId, io);
    } catch (error) {
      log?.call('刷新 Spec 索引失败（$agentId）：$error');
    }
  }

  /// 后台补一次全量索引（不阻塞本轮提示词）。
  void _refreshLater(String agentId) {
    final Future<WorkspaceIO?> Function(String agentId)? resolve = ioFor;
    if (resolve == null || !_indexRefreshing.add(agentId)) return;
    unawaited(() async {
      try {
        await refreshIndex(agentId, await resolve(agentId));
      } catch (error) {
        log?.call('后台刷新 Spec 索引失败（$agentId）：$error');
      } finally {
        _indexRefreshing.remove(agentId);
      }
    }());
  }

  /// 内置 4 条（同步，不碰工作空间）。
  static List<SpecDocument> _builtinDocuments() => <SpecDocument>[
    for (final String id in kBuiltinSpecIds)
      if (kBuiltinSpecs[id] != null)
        parseSpecText(kBuiltinSpecs[id]!, fallbackId: id, builtin: true),
  ];

  /// 单份详情（REST `GET /api/agents/{id}/specs/{specId}`）。
  Future<SpecDocument?> detail(
    String agentId,
    WorkspaceIO? io,
    String specId,
  ) async {
    final String id = specId.trim();
    final String? builtinText = kBuiltinSpecs[id];
    if (builtinText != null) {
      return parseSpecText(builtinText, fallbackId: id, builtin: true);
    }
    if (io == null) return null;
    return _readCustom(io, id);
  }

  // ── action 实现 ──────────────────────────────────────────────────────

  /// 选择 Spec：**直接返回所选 Spec 全文**（Q9 删掉了「必须先 read」的前置约束）。
  ///
  /// 模型挂 hook 需要看到规范全文，旧实现要求先 `read` 再 `select`，两轮工具调用且
  /// 容易漏一步；现在一次调用既拿到全文又挂上 hook。空数组 = 取消全部选择。
  Future<Map<String, dynamic>> _select(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final Object? raw = invocation.arguments['spec_ids'];
    if (raw is! List<dynamic>) {
      return <String, dynamic>{'error': 'select 需要 spec_ids 列表'};
    }
    final List<String> ids = <String>[];
    for (final dynamic item in raw) {
      final String id = item.toString().trim();
      if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
    final List<String> missing = <String>[];
    final List<Map<String, dynamic>> selected = <Map<String, dynamic>>[];
    for (final String id in ids) {
      final SpecDocument? document = await detail(invocation.agentId, io, id);
      if (document == null) {
        missing.add(id);
        continue;
      }
      selected.add(<String, dynamic>{
        'id': document.id,
        'title': document.title,
        'task_type': document.taskType,
        'content': document.raw,
      });
    }
    if (missing.isNotEmpty) {
      return <String, dynamic>{
        'error': 'Spec 不存在: $missing（可用 id 见系统提示词里的 Spec 索引）',
      };
    }
    store.setSelectedSpecs(invocation.agentId, invocation.sessionId, ids);
    return <String, dynamic>{
      'action': 'select',
      'spec_ids': ids,
      'count': selected.length,
      'specs': selected,
      'note': ids.isEmpty
          ? '已取消全部 Spec 选择（selected_spec_ids 已清空），后续重构 context 将不再注入任何 Spec。'
          : '已挂 hook，且全文已在本次结果里（不需要再 read）；实际注入发生在下次重构 context（compact/新建会话）。',
    };
  }

  Future<Map<String, dynamic>> _create(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String title = (invocation.arguments['title'] ?? '')
        .toString()
        .trim();
    if (title.isEmpty) return <String, dynamic>{'error': 'create 需要 title'};
    final String rawId = (invocation.arguments['spec_id'] ?? '')
        .toString()
        .trim();
    final String id = rawId.isEmpty ? safeSpecId(title) : safeSpecId(rawId);
    if (await detail(invocation.agentId, io, id) != null) {
      return <String, dynamic>{'error': 'Spec 已存在: $id（如需修改请用 update）'};
    }
    final String workflow = (invocation.arguments['workflow'] ?? '').toString();
    final String rules = (invocation.arguments['rules'] ?? '').toString();
    final String notes = (invocation.arguments['notes'] ?? '').toString();
    if (workflow.trim().isEmpty &&
        rules.trim().isEmpty &&
        notes.trim().isEmpty) {
      return <String, dynamic>{
        'error': 'create 需要至少提供 workflow/rules/notes 之一',
      };
    }
    final String taskType = (invocation.arguments['task_type'] ?? 'custom')
        .toString()
        .trim();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final SpecDocument document = SpecDocument(
      id: id,
      title: title,
      taskType: taskType.isEmpty ? 'custom' : taskType,
      description: (invocation.arguments['description'] ?? '').toString(),
      classification: (invocation.arguments['classification'] ?? '内部规范')
          .toString(),
      risk: (invocation.arguments['risk'] ?? 'low').toString(),
      when: _stringList(invocation.arguments['when']),
      tags: <String>[taskType.isEmpty ? 'custom' : taskType],
      body: '',
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    final String text = renderSpec(
      document: document,
      workflow: workflow,
      rules: rules,
      notes: notes,
    );
    try {
      await io.writeFile('$specDir/$id.md', text);
    } catch (error) {
      return <String, dynamic>{'error': 'Spec 文件写入失败: $specDir/$id.md（$error）'};
    }
    return <String, dynamic>{
      'action': 'create',
      'spec_id': id,
      'title': title,
      'note': '已创建并落盘到工作空间 spec/；下一轮系统提示词的 Spec 索引里就会列出它。',
    };
  }

  Future<Map<String, dynamic>> _update(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String id = (invocation.arguments['spec_id'] ?? '').toString().trim();
    if (id.isEmpty) return <String, dynamic>{'error': 'update 需要 spec_id'};
    if (kBuiltinSpecs.containsKey(id)) {
      return <String, dynamic>{'error': '$id 为内置 Spec，不可修改'};
    }
    final SpecDocument? existing = await _readCustom(io, id);
    if (existing == null) {
      return <String, dynamic>{'error': 'Spec 不存在: $id'};
    }
    final Map<String, String> sections = _splitSections(existing.body);
    const String workflowHeading = '## 工作流（workflow）';
    const String rulesHeading = '## 该类任务规范';
    const String notesHeading = '## 注意事项';
    String pick(String key, String fallback) {
      if (!invocation.arguments.containsKey(key)) return fallback;
      return (invocation.arguments[key] ?? '').toString();
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    final String title = (invocation.arguments['title'] ?? existing.title)
        .toString()
        .trim();
    final SpecDocument updated = SpecDocument(
      id: id,
      title: title.isEmpty ? existing.title : title,
      taskType: (invocation.arguments['task_type'] ?? existing.taskType)
          .toString(),
      description: (invocation.arguments['description'] ?? existing.description)
          .toString(),
      classification:
          (invocation.arguments['classification'] ?? existing.classification)
              .toString(),
      risk: (invocation.arguments['risk'] ?? existing.risk).toString(),
      when: invocation.arguments.containsKey('when')
          ? _stringList(invocation.arguments['when'])
          : existing.when,
      tags: existing.tags,
      body: '',
      version: existing.version + 1,
      createdAt: existing.createdAt == 0 ? now : existing.createdAt,
      updatedAt: now,
      changelog: <String>[
        'v${existing.version + 1}(${_date()}): 经 spec update 更新',
        ...existing.changelog,
      ],
    );
    final String text = renderSpec(
      document: updated,
      workflow: pick('workflow', sections[workflowHeading] ?? ''),
      rules: pick('rules', sections[rulesHeading] ?? ''),
      notes: pick('notes', sections[notesHeading] ?? ''),
    );
    try {
      await io.writeFile('$specDir/$id.md', text);
    } catch (error) {
      return <String, dynamic>{'error': 'Spec 文件写入失败: $specDir/$id.md（$error）'};
    }
    return <String, dynamic>{
      'action': 'update',
      'spec_id': id,
      'title': updated.title,
      'success': true,
    };
  }

  // ── 文件层 ───────────────────────────────────────────────────────────

  Future<List<SpecDocument>> _customSpecs(WorkspaceIO io) async {
    final List<SpecDocument> out = <SpecDocument>[];
    try {
      final List<String> files = await io.listFiles(
        relativePath: specDir,
        maxDepth: 1,
        maxEntries: 200,
      );
      for (final String file in files) {
        if (!file.toLowerCase().endsWith('.md')) continue;
        final String id = file
            .substring(file.lastIndexOf('/') + 1)
            .replaceAll(RegExp(r'\.md$'), '');
        final SpecDocument? document = await _readCustom(io, id);
        if (document != null) out.add(document);
      }
    } catch (_) {
      // 没有 spec 目录 / 工作空间不可读：只返回内置模板
    }
    return out;
  }

  Future<SpecDocument?> _readCustom(WorkspaceIO io, String id) async {
    try {
      final FileContent content = await io.readFile('$specDir/$id.md');
      return parseSpecText(content.text, fallbackId: id, builtin: false);
    } catch (_) {
      return null;
    }
  }

  static List<String> _stringList(Object? raw) {
    if (raw is List<dynamic>) {
      return raw
          .map((dynamic e) => e.toString())
          .where((String e) => e.trim().isNotEmpty)
          .toList(growable: false);
    }
    if (raw is String && raw.trim().isNotEmpty) return <String>[raw.trim()];
    return const <String>[];
  }

  static String _date() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }
}

/// Spec id 规范化：小写、非 `[a-z0-9-]` 换 `-`、折叠连续 `-`、去首尾 `-`。
String safeSpecId(String raw) {
  final String normalized = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return normalized.isEmpty
      ? 'spec-${DateTime.now().millisecondsSinceEpoch}'
      : normalized;
}

/// 解析 front matter + 正文。
SpecDocument parseSpecText(
  String text, {
  required String fallbackId,
  required bool builtin,
}) {
  final String normalized = text.replaceAll('\r\n', '\n');
  Map<String, dynamic> meta = <String, dynamic>{};
  String body = normalized;
  if (normalized.startsWith('---\n')) {
    final int end = normalized.indexOf('\n---', 4);
    if (end > 0) {
      try {
        meta = YamlCodec.decode(normalized.substring(4, end));
      } catch (_) {
        meta = <String, dynamic>{};
      }
      final int newline = normalized.indexOf('\n', end + 1);
      body = newline < 0 ? '' : normalized.substring(newline + 1);
    }
  }
  List<String> list(Object? raw) {
    if (raw is List<dynamic>) {
      return raw.map((dynamic e) => e.toString()).toList(growable: false);
    }
    return const <String>[];
  }

  // 手写的 front matter 里日期可能是 `2026-09-10`（字符串）也可能是毫秒数，
  // 因此取整必须宽容：解析不出来按 0 处理，绝不因为一个字段让整份 Spec 读不出来。
  int intOf(Object? raw, int fallback) {
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final String text = raw.trim();
      final int? direct = int.tryParse(text);
      if (direct != null) return direct;
      final DateTime? date = DateTime.tryParse(text);
      if (date != null) return date.millisecondsSinceEpoch;
    }
    return fallback;
  }

  return SpecDocument(
    id: (meta['id'] ?? fallbackId).toString(),
    title: (meta['title'] ?? fallbackId).toString(),
    taskType: (meta['task_type'] ?? 'custom').toString(),
    description: (meta['description'] ?? '').toString(),
    classification: (meta['classification'] ?? '内部规范').toString(),
    risk: (meta['risk'] ?? 'low').toString(),
    when: list(meta['when']),
    tags: list(meta['tags']),
    changelog: list(meta['changelog']),
    pinned: meta['pinned'] == true,
    builtin: builtin || meta['builtin'] == true,
    version: intOf(meta['version'], 1),
    createdAt: intOf(meta['created_at'], 0),
    updatedAt: intOf(meta['updated_at'], 0),
    body: body.trimLeft(),
    raw: normalized,
  );
}

/// 渲染自定义 Spec：front matter + 固定三段正文。
String renderSpec({
  required SpecDocument document,
  required String workflow,
  required String rules,
  required String notes,
}) {
  final Map<String, dynamic> front = <String, dynamic>{
    'id': document.id,
    'title': document.title,
    'task_type': document.taskType,
    'description': document.description,
    'when': document.when,
    'tags': document.tags,
    'pinned': document.pinned,
    'builtin': document.builtin,
    'created_at': document.createdAt,
    'updated_at': document.updatedAt,
    'version': document.version,
    'classification': document.classification,
    'risk': document.risk,
    'changelog': document.changelog,
  };
  return '---\n${YamlCodec.encode(front).trim()}\n---\n\n'
      '## 工作流（workflow）\n\n${workflow.trim()}\n\n'
      '## 该类任务规范\n\n${rules.trim()}\n\n'
      '## 注意事项\n\n${notes.trim()}\n';
}

/// 按 `## ` 标题切分正文（update 的"按段合并"用：提供的覆盖、未提供的保留）。
Map<String, String> _splitSections(String body) {
  final Map<String, String> out = <String, String>{};
  final List<RegExpMatch> matches = RegExp(
    r'^## ',
    multiLine: true,
  ).allMatches(body).toList();
  for (int i = 0; i < matches.length; i++) {
    final int start = matches[i].start;
    final int end = i + 1 < matches.length ? matches[i + 1].start : body.length;
    final String chunk = body.substring(start, end);
    final int newline = chunk.indexOf('\n');
    final String heading = (newline < 0 ? chunk : chunk.substring(0, newline))
        .trim();
    out[heading] = newline < 0 ? '' : chunk.substring(newline + 1).trim();
  }
  return out;
}
