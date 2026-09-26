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

  /// 检索/模型可读形态（不带全文，避免把上下文塞满）。
  Map<String, dynamic> toSearchJson() => <String, dynamic>{
    'id': id,
    'task_type': taskType,
    'title': title,
    'description': description,
    'when': when,
    'pinned': pinned,
    'builtin': builtin,
  };

  /// 按标题/描述/适用条件/标签的文本做关键词打分（0~1）。
  double score(List<String> tokens) {
    if (tokens.isEmpty) return 0;
    final String haystack = <String>[
      title,
      description,
      taskType,
      ...when,
      ...tags,
    ].join(' ').toLowerCase();
    int hit = 0;
    for (final String token in tokens) {
      if (token.isNotEmpty && haystack.contains(token)) hit++;
    }
    return hit / tokens.length;
  }
}

/// Spec 体系（M5d）：检索 / 索引 / 读全文 / 挂 hook / 沉淀 / 维护。
///
/// 与参考实现的差异：索引不是 SQLite 表，而是**扫文件**（内置模板目录 + 工作空间
/// `spec/*.md`）。单用户桌面下文件数量是几十个量级，扫描比维护索引更简单、也不会
/// 出现"文件在、索引缺"的不一致。
class SpecService {
  SpecService({required this.store, this.builtinSpecsDir = '', this.log});

  final TreeStore store;

  /// 内置模板的落盘目录（`<数据根>/spec/builtin`；空串 = 只读内嵌常量）。
  final String builtinSpecsDir;

  final void Function(String message)? log;

  /// 本会话已 `read` 过的 Spec（`select` 的前置条件；与参考实现同语义）。
  final Map<String, Set<String>> _readIds = <String, Set<String>>{};

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

  /// 工具入口。
  Future<Map<String, dynamic>> run(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String action = (invocation.arguments['action'] ?? '')
        .toString()
        .trim();
    switch (action) {
      case 'search':
        return _search(invocation, io);
      case 'list':
        return _list(invocation, io);
      case 'read':
        return await _read(invocation, io);
      case 'select':
        return await _select(invocation, io);
      case 'create':
        return await _create(invocation, io);
      case 'update':
        return await _update(invocation, io);
      default:
        return <String, dynamic>{
          'error':
              '未知 spec 动作: $action（应为 search/list/read/select/create/update）',
        };
    }
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
    return out;
  }

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

  Future<Map<String, dynamic>> _search(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String query = (invocation.arguments['query'] ?? '')
        .toString()
        .trim();
    if (query.isEmpty) {
      return <String, dynamic>{'error': 'search 需要 query（任务描述/关键词）'};
    }
    final List<SpecDocument> all = await index(invocation.agentId, io);
    final List<String> tokens = _tokens(query);
    final List<SpecDocument> hits = all
        .where((SpecDocument s) => s.score(tokens) > 0 || s.builtin)
        .toList();
    hits.sort((SpecDocument a, SpecDocument b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.score(tokens).compareTo(a.score(tokens));
    });
    final List<SpecDocument> top = hits.take(10).toList(growable: false);
    return <String, dynamic>{
      'action': 'search',
      'query': query,
      'count': top.length,
      'specs': top.map((SpecDocument s) => s.toSearchJson()).toList(),
    };
  }

  Future<Map<String, dynamic>> _list(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final List<SpecDocument> all = await index(invocation.agentId, io);
    final List<String> selectedSpecIds =
        store
            .session(invocation.agentId, invocation.sessionId)
            ?.selectedSpecIds ??
        const <String>[];
    return <String, dynamic>{
      'action': 'list',
      'count': all.length,
      'specs': all.map((SpecDocument s) => s.toSearchJson()).toList(),
      'selected_spec_ids': selectedSpecIds,
    };
  }

  Future<Map<String, dynamic>> _read(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String id = (invocation.arguments['spec_id'] ?? '').toString().trim();
    if (id.isEmpty) return <String, dynamic>{'error': 'read 需要 spec_id'};
    final SpecDocument? document = await detail(invocation.agentId, io, id);
    if (document == null) {
      return <String, dynamic>{
        'error': 'Spec 不存在: $id（可先 list/search 查看可用 id）',
      };
    }
    _readIds
        .putIfAbsent(_sessionKey(invocation), () => <String>{})
        .add(document.id);
    return <String, dynamic>{
      'action': 'read',
      'spec_id': document.id,
      'content': document.raw,
    };
  }

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
    final Set<String> read = _readIds[_sessionKey(invocation)] ?? <String>{};
    final List<String> missing = <String>[];
    final List<String> notRead = <String>[];
    for (final String id in ids) {
      final SpecDocument? document = await detail(invocation.agentId, io, id);
      if (document == null) {
        missing.add(id);
        continue;
      }
      if (!read.contains(id)) notRead.add(id);
    }
    if (missing.isNotEmpty) {
      return <String, dynamic>{
        'error': 'Spec 不存在: $missing（可先 list/search 查看可用 id）',
      };
    }
    if (notRead.isNotEmpty) {
      return <String, dynamic>{
        'error':
            'select 前必须先 read 对应 Spec: $notRead'
            '（请先 spec read 取全文，再 select 挂 hook）',
      };
    }
    store.setSelectedSpecs(invocation.agentId, invocation.sessionId, ids);
    return <String, dynamic>{
      'action': 'select',
      'spec_ids': ids,
      'note': ids.isEmpty
          ? '已取消全部 Spec 选择（selected_spec_ids 已清空），后续重构 context 将不再注入任何 Spec。'
          : '已挂 hook；实际注入发生在下次重构 context（compact/新建会话）。',
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
      'note': '已创建并落盘到工作空间 spec/；会出现在下次重构 context 的 Spec 索引中。',
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

  String _sessionKey(ToolInvocation invocation) =>
      '${invocation.agentId}/${invocation.sessionId}';

  static List<String> _tokens(String query) => query
      .toLowerCase()
      .split(RegExp(r'[\s,，。；;、/]+'))
      .map((String t) => t.trim())
      .where((String t) => t.isNotEmpty)
      .toList(growable: false);

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
