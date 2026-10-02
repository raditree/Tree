import 'dart:async';
import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/tree_store.dart';
import '../store/yaml_codec.dart';
import '../tool/tool_runner.dart';
import 'builtin_specs.dart';

/// 一份 Spec（任务型规范）：元数据 + 正文。
///
/// 内置模板来自内嵌常量（[kBuiltinSpecTexts]）并**播种到工作空间**（`.self/spec/<id>.md`），
/// 自定义 Spec 同样落在这里（front matter + 三段正文）——文件是这个工作空间里的读取源，
/// 不需要额外的索引库；内置副本由核心维护（升级会被刷新，见 [SpecService.seedInto]），
/// 想按工作空间定制请用 `spec create` 另存一份。
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
/// - 索引不是 SQLite 表，而是**扫文件**（工作空间 `.self/spec/*.md`）。单用户
///   桌面下文件数量是几十个量级，扫描比维护索引更简单、也不会出现"文件在、索引缺"
///   的不一致。
class SpecService {
  SpecService({required this.store, this.log});

  final TreeStore store;

  final void Function(String message)? log;

  /// 选中规范后播种它的**随附文档**（id → 工作空间内的文件）的钩子。
  ///
  /// 为什么是钩子而不是直接调用：随附文档的原件在**核心所在机器**上（发行布局的
  /// 应用目录、开发态的仓库），解析与搬运是 plugin 侧的知识（
  /// `plugin/plugin_guide.dart`）；Spec 服务只负责"选中后把该带的文件带上"。
  /// 由核心启动时接线（`server/core_server.dart`）；未接线 = 本服务不管这件事。
  Future<List<Map<String, dynamic>>> Function(
    WorkspaceIO io,
    List<String> specIds,
  )?
  seedAssetsFor;

  /// Q9 索引快照：agentId → 已渲染的索引文本（见 [indexSnapshot]）。
  final Map<String, String> _indexText = <String, String>{};

  /// 正在后台刷新的 agent（避免每轮提示词都重复发起一次全量扫描）。
  final Set<String> _indexRefreshing = <String>{};

  /// Q9 ⑧ 章快照：`agentId|sessionId` → 本会话已选 Spec 的注入段（见
  /// [selectedSpecsSnapshot]）。`selected_spec_ids` 是**会话级**的，所以键里带 session。
  final Map<String, String> _selectedText = <String, String>{};

  /// 正在后台补已选全文的会话。
  final Set<String> _selectedRefreshing = <String>{};

  /// 取某 agent 工作空间 IO 的解析器（Q9 索引后台刷新用）；由核心启动时接线。
  ///
  /// 为什么需要它：系统提示词是**同步**拼装的，而索引要读工作空间文件（异步）。
  /// 没有快照时 [indexSnapshot] 只能先给内置模板，靠这个解析器在后台补全量。
  Future<WorkspaceIO?> Function(String agentId)? ioFor;

  /// 规范文件所在目录（**工作空间内的 `.self/spec/`**）。
  ///
  /// 与 `.self/results`、`.self/plan` 同一隐藏根：规范属于该工作空间/团队，
  /// 不同团队各有一份、互不影响；内置模板在首次进入工作空间时播种到这里。
  static const String specDir = '.self/spec';

  /// 首次进入某工作空间时播种内置模板，并在核心升级后**刷新**它们。
  ///
  /// 语义（用户 2026-10-02 定稿）：**内置规范的工作空间副本 = 核心管理的快照**——升级要让新文案
  /// 真正到达已有工作空间，而不是"只对新工作空间生效"（工作空间文件优先于内嵌模板，只写缺失就
  /// 等于永远吃旧文案）。规则：
  /// - 文件缺失 → 写入（`created`）；
  /// - 已存在且与模板一致 → 不写（`unchanged`，不刷 mtime）；
  /// - 已存在但不同、且副本 `version` **不高于**模板 → 先备份成 `<id>.md.bak.<n>` 再写新模板
  ///   （`refreshed`：手改内容进备份，不丢）；
  /// - 副本 `version` **高于**模板（来自更新的核心 / 别人手改过）→ 保留不动 + 记日志，绝不降级
  ///   （`kept_newer`）。
  ///
  /// 要按工作空间自定义，请用 `spec create` 另存一份（`spec update` 本来就拒绝内置 id）。
  /// 工作空间不可用（SSH 未连上 / 目录不可读）时不抛，只记日志——内置模板始终有内嵌常量兜底。
  /// 返回值是逐步动作（`id` / `action` / 备份名 / 版本），供日志与测试核对。
  Future<List<Map<String, dynamic>>> seedInto(WorkspaceIO io) async {
    final List<Map<String, dynamic>> notes = <Map<String, dynamic>>[];
    final Set<String> existing = await _specFileNames(io);
    for (final String id in kBuiltinSpecIds) {
      final String template = kBuiltinSpecTexts[id] ?? '';
      if (!existing.contains('$id.md')) {
        try {
          await io.writeFile('$specDir/$id.md', template);
          notes.add(<String, dynamic>{'id': id, 'action': 'created'});
        } catch (error) {
          log?.call('写内置 Spec 失败（$id）：$error');
        }
        continue;
      }
      try {
        final String current = (await io.readFile('$specDir/$id.md')).text;
        if (_sameSpecText(current, template)) {
          notes.add(<String, dynamic>{'id': id, 'action': 'unchanged'});
          continue;
        }
        final int fileVersion =
            parseSpecText(current, fallbackId: id, builtin: true).version;
        final int templateVersion =
            parseSpecText(template, fallbackId: id, builtin: true).version;
        if (fileVersion > templateVersion) {
          log?.call(
            '内置 Spec 副本比模板新，保留不动：$id（副本 v$fileVersion > 模板 v$templateVersion）',
          );
          notes.add(<String, dynamic>{
            'id': id,
            'action': 'kept_newer',
            'file_version': fileVersion,
            'template_version': templateVersion,
          });
          continue;
        }
        final int index = await _nextBackupIndex(io);
        final String backup = '$id.md.bak.$index';
        await io.writeFile('$specDir/$backup', current);
        await io.writeFile('$specDir/$id.md', template);
        // 同版本但内容不同也要说清楚（否则日志里"v6 → v6"看着像 bug）
        final String versionNote = fileVersion == templateVersion
            ? '同版本（v$fileVersion）但内容不同'
            : 'v$fileVersion → v$templateVersion';
        log?.call('内置 Spec 已升级：$id（$versionNote，旧副本备份为 $backup）');
        notes.add(<String, dynamic>{
          'id': id,
          'action': 'refreshed',
          'backup': backup,
          'file_version': fileVersion,
          'template_version': templateVersion,
        });
      } catch (error) {
        log?.call('刷新内置 Spec 失败（$id）：$error');
      }
    }
    return notes;
  }

  /// 一键重置：把 `.self/spec/` 下每个规范文件备份成 `.bak.<n>`（保留旧备份）后
  /// 删除，再播种内置模板。自定义规范一同被清理（备份里可找回）。
  Future<Map<String, dynamic>> reset(WorkspaceIO io) async {
    final List<String> files = await _listSpecFiles(io);
    final int index = await _nextBackupIndex(io);
    final List<String> backedUp = <String>[];
    final List<String> removed = <String>[];
    for (final String file in files) {
      String text;
      try {
        text = (await io.readFile(file)).text;
      } catch (_) {
        continue;
      }
      final String backup = '$file.bak.$index';
      await io.writeFile(backup, text);
      backedUp.add('$file → $backup');
      try {
        if (await io.deleteFile(file)) removed.add(file);
      } catch (error) {
        log?.call('删除规范文件失败（$file）：$error');
      }
    }
    await seedInto(io);
    return <String, dynamic>{
      'spec_dir': specDir,
      'backup_index': index,
      'backed_up': backedUp,
      'removed': removed,
      'restored': <String>[
        for (final String id in kBuiltinSpecIds) '$specDir/$id.md',
      ],
    };
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
      // 已选全文（⑧ 章）也要一起刷新：select 改了选择，create/update 改了正文。
      await refreshSelectedSpecs(invocation.agentId, invocation.sessionId, io);
    }
    return result;
  }

  /// 索引（REST `GET /api/agents/{id}/specs` 与 memory/team 工具共用）。
  ///
  /// **工作空间文件是源**：先播种（并刷新升级过的）内置模板，再读 `.self/spec/*.md`；内置模板
  /// 仍在内存里兜底（工作空间不可读 / 内置文件被删时补上）。顺序固定为内置在前、
  /// 其余按 id，保证索引稳定可预测。
  Future<List<SpecDocument>> index(String agentId, WorkspaceIO? io) async {
    final Map<String, SpecDocument> byId = <String, SpecDocument>{};
    if (io != null) {
      await seedInto(io);
      for (final SpecDocument file in await _customSpecs(io)) {
        byId.putIfAbsent(file.id, () => file); // 同名只保留第一个（文件名唯一）
      }
    }
    for (final String id in kBuiltinSpecIds) {
      if (byId.containsKey(id)) continue;
      final String? text = kBuiltinSpecTexts[id];
      if (text != null) {
        byId[id] = parseSpecText(text, fallbackId: id, builtin: true);
      }
    }
    final List<SpecDocument> out = <SpecDocument>[];
    for (final String id in kBuiltinSpecIds) {
      final SpecDocument? doc = byId.remove(id);
      if (doc != null) out.add(doc);
    }
    final List<SpecDocument> rest = byId.values.toList()
      ..sort((SpecDocument a, SpecDocument b) => a.id.compareTo(b.id));
    out.addAll(rest);
    // 扫完顺手更新提示词快照：前端打开 Spec 面板（REST 索引）也会刷新它
    _indexText[agentId] = renderIndex(out);
    return out;
  }

  // ── 索引（Q9：注入系统提示词） ───────────────────────────────────────

  /// 索引最多列多少条（Q9 口径：默认全列，超 50 条截断并在尾部注明其余条数）。
  static const int indexLimit = 50;

  /// 单条「适用条件」摘要的字符上限（照旧实现：超 80 字符截断加省略号）。
  static const int whenSummaryLimit = 80;

  /// 所有 Spec 的**共同前置**（渲染进索引段，注入系统提示词）。
  ///
  /// 为什么放在这里：自定义规范不在我们的文件里，改不到它的正文——索引段是"所有 spec"
  /// 唯一的公共落点。内置规范另有正文首部的「第 0 步」（`kSpecAlignFirstSection`），
  /// 两处口径必须一致（测试钉住）。
  static const String indexCommonNotice =
      '所有 Spec 共同要求：**动手前先与用户对齐语义**（复述目标/范围/验收 → 用户确认；'
      '歧义先问不猜；只能自己定的取舍要显式写默认值）。未对齐之前，只做只读侦察，不写文件、不改配置。';

  /// 把索引渲染成系统提示词里的列表（格式照旧实现）：
  /// 形如 `- id [task_type] 标题（内置）（适用: when 摘要）`，id 自带反引号。
  static String renderIndex(
    List<SpecDocument> specs, {
    int limit = indexLimit,
  }) {
    if (specs.isEmpty) {
      return '$indexCommonNotice\n\n（暂无 Spec；任务完成后可用 spec create 沉淀）';
    }
    final StringBuffer buffer = StringBuffer()
      ..writeln(indexCommonNotice)
      ..writeln();
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

  /// 把系统提示词依赖的两处快照**先热起来**（拼 `AgentRunContext` 之前调用）。
  ///
  /// 为什么必须有它：⑦ 索引与 ⑧ 已选全文都是**异步**补热的——冷的时候 [indexSnapshot]
  /// 只给内置模板、[selectedSpecsSnapshot] 给空串。若这个"冷 → 热"的切换落在会话中途，
  /// `[0] system` 的字节就变了，而它在消息序列的最前面 ⇒ **整条前缀（含全部历史）作废**，
  /// 端点前缀缓存直接 0 命中（2026-10-02 现场：核心重启后第一轮用冷串 32k，后台扫完
  /// 下一轮 68k 全部 miss；两处快照实测差 7,702 字，其中 ⑧ 章 7,388 字）。详见
  /// `docs/known-issues.md` #8。
  ///
  /// 只在**冷**的时候真的扫一次，热了立刻返回：热路径零成本；SSH 下是"每进程每 agent
  /// 一次"的网络往返，换来的是会话中途前缀不再漂移。
  ///
  /// 失败不抛：退回冷形态（与接线前行为一致），只记日志。
  Future<void> ensureSnapshots(String agentId, String sessionId) async {
    final Future<WorkspaceIO?> Function(String agentId)? resolve = ioFor;
    if (resolve == null) return;
    try {
      if (!_indexText.containsKey(agentId)) {
        await refreshIndex(agentId, await resolve(agentId));
      }
      if (sessionId.trim().isEmpty) return;
      final String key = _selectedKey(agentId, sessionId);
      if (!_selectedText.containsKey(key)) {
        await refreshSelectedSpecs(agentId, sessionId, await resolve(agentId));
      }
    } catch (error) {
      log?.call('预热 Spec 快照失败（$agentId/$sessionId）：$error');
    }
  }

  /// 供系统提示词用的索引快照（**同步**：提示词是同步拼装的）。
  ///
  /// 没有快照时先只给**内置模板**（内嵌常量，随时算得出来），同时后台补一次全量：
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

  /// 同步快照：本会话已选 Spec 的**全文**注入段（Q9 ⑧ 章）。
  ///
  /// 与 [indexSnapshot] 同一套路：系统提示词是**同步**拼装的，而读规范文件是异步的。
  /// 没有快照时先返回空串（本轮就不注入这一段），同时后台补一次；`select` /
  /// REST 改选择、`create` / `update` 改正文之后都会**立即写热**快照，
  /// 所以正常路径下"挂了 hook"下一轮就能在系统提示词里看到全文。
  String selectedSpecsSnapshot(String agentId, String sessionId) {
    if (sessionId.trim().isEmpty) return '';
    final String key = _selectedKey(agentId, sessionId);
    final String? cached = _selectedText[key];
    if (cached == null) _refreshSelectedLater(agentId, sessionId);
    return cached ?? '';
  }

  /// 重新读"本会话已选 Spec"的全文并刷新快照。
  ///
  /// 悬空 hook（`selected_spec_ids` 里指向已被删除的规范）会被跳过，不阻断其余的——
  /// 与参考实现的 `_build_selected_specs_text` 同一取舍。
  Future<void> refreshSelectedSpecs(
    String agentId,
    String sessionId,
    WorkspaceIO? io,
  ) async {
    if (sessionId.trim().isEmpty) return;
    final String key = _selectedKey(agentId, sessionId);
    try {
      final List<String> ids =
          store.session(agentId, sessionId)?.selectedSpecIds ??
          const <String>[];
      final List<String> blocks = <String>[];
      for (final String id in ids) {
        final SpecDocument? document = await detail(agentId, io, id);
        final String raw = document?.raw.trim() ?? '';
        if (raw.isEmpty) continue;
        blocks.add('### Spec: $id\n$raw');
      }
      _selectedText[key] = blocks.join('\n\n');
    } catch (error) {
      log?.call('刷新已选 Spec 全文失败（$agentId/$sessionId）：$error');
    }
  }

  /// 后台补一次已选全文（不阻塞本轮提示词）。
  void _refreshSelectedLater(String agentId, String sessionId) {
    final Future<WorkspaceIO?> Function(String agentId)? resolve = ioFor;
    if (resolve == null) return;
    final String key = _selectedKey(agentId, sessionId);
    if (!_selectedRefreshing.add(key)) return;
    unawaited(() async {
      try {
        await refreshSelectedSpecs(agentId, sessionId, await resolve(agentId));
      } catch (error) {
        log?.call('后台刷新已选 Spec 全文失败（$key）：$error');
      } finally {
        _selectedRefreshing.remove(key);
      }
    }());
  }

  static String _selectedKey(String agentId, String sessionId) =>
      '$agentId|$sessionId';

  /// 内置模板（同步，不碰工作空间；清单与顺序以 [kBuiltinSpecIds] 为准）。
  ///
  /// 用 [kBuiltinSpecTexts]（原文 + 共享第 0 步）而不是 [kBuiltinSpecs] 原文：播种落盘、
  /// 读不到文件时的兜底、`select` 回给模型的全文，三者必须逐字一致。
  static List<SpecDocument> _builtinDocuments() => <SpecDocument>[
    for (final String id in kBuiltinSpecIds)
      if (kBuiltinSpecTexts[id] != null)
        parseSpecText(kBuiltinSpecTexts[id]!, fallbackId: id, builtin: true),
  ];

  /// 单份详情（REST `GET /api/agents/{id}/specs/{specId}`）。
  Future<SpecDocument?> detail(
    String agentId,
    WorkspaceIO? io,
    String specId,
  ) async {
    final String id = specId.trim();
    // 工作空间文件优先（内置模板也落了盘，一个工作空间的副本优先于内嵌模板；
    // 副本与模板的一致性由 seedInto 的刷新语义维护）；文件缺失时用内嵌模板兜底。
    if (io != null) {
      final SpecDocument? file = await _readCustom(io, id);
      if (file != null) return file;
    }
    final String? builtinText = kBuiltinSpecTexts[id];
    if (builtinText != null) {
      return parseSpecText(builtinText, fallbackId: id, builtin: true);
    }
    return null;
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
    // 随附文档（如插件开发指南）随 select 播种：正文引用的文档必须在**工作空间里**，
    // agent 的 read 才读得到。播种失败不阻断选择（全文已在本次结果里），如实回报。
    final List<Map<String, dynamic>> assets = await _seedAssets(io, ids);
    return <String, dynamic>{
      'action': 'select',
      'spec_ids': ids,
      'count': selected.length,
      'specs': selected,
      if (assets.isNotEmpty) 'assets': assets,
      'note': (ids.isEmpty
              ? '已取消全部 Spec 选择（selected_spec_ids 已清空），后续重构 context 将不再注入任何 Spec。'
              : '已挂 hook，且全文已在本次结果里（不需要再 read）；实际注入发生在下次重构 context（compact/新建会话）。') +
          _assetsNote(assets),
    };
  }

  /// 播种选中规范的随附文档（钩子未接线 / 抛错都不影响 select 本身）。
  Future<List<Map<String, dynamic>>> _seedAssets(
    WorkspaceIO io,
    List<String> ids,
  ) async {
    final Future<List<Map<String, dynamic>>> Function(
      WorkspaceIO,
      List<String>,
    )?
    seeder = seedAssetsFor;
    if (seeder == null || ids.isEmpty) return const <Map<String, dynamic>>[];
    try {
      return await seeder(io, ids);
    } catch (error) {
      log?.call('播种随附文档失败：$error');
      return const <Map<String, dynamic>>[];
    }
  }

  /// 把随附文档的结果说成一句人能读的话（成功给路径与动作，失败给原因与兜底）。
  String _assetsNote(List<Map<String, dynamic>> assets) {
    final List<String> parts = <String>[];
    for (final Map<String, dynamic> asset in assets) {
      final String action = (asset['action'] ?? '').toString();
      final String path = (asset['path'] ?? '').toString();
      if (action == 'missing' || action == 'failed') {
        parts.add(
          '随附文档未就绪（$path）：${asset['error']}——按该规范正文的兜底流程向用户索取原件',
        );
      } else {
        parts.add('随附文档已就绪：$path（$action）');
      }
    }
    return parts.isEmpty ? '' : '；${parts.join('；')}';
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
      'note': '已创建并落盘到工作空间 .self/spec/；下一轮系统提示词的 Spec 索引里就会列出它。',
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
    for (final String file in await _listSpecFiles(io)) {
      final String id = file
          .substring(file.lastIndexOf('/') + 1)
          .replaceAll(RegExp(r'\.md$'), '');
      final SpecDocument? document = await _readCustom(io, id);
      if (document != null) out.add(document);
    }
    return out;
  }

  /// `.self/spec/` 下的规范文件（工作空间相对路径；仅 `.md`，不含 `.bak.*`）。
  Future<List<String>> _listSpecFiles(WorkspaceIO io) async {
    try {
      final List<String> files = await io.listFiles(
        relativePath: specDir,
        maxDepth: 1,
        maxEntries: 500,
      );
      return files
          .where((String f) => f.toLowerCase().endsWith('.md'))
          .toList(growable: false);
    } catch (_) {
      // 没有 spec 目录 / 工作空间不可读：当空目录
      return const <String>[];
    }
  }

  /// 目录下的**文件名集合**（播种时判断内置模板是否已存在）。
  Future<Set<String>> _specFileNames(WorkspaceIO io) async {
    try {
      final List<String> files = await io.listFiles(
        relativePath: specDir,
        maxDepth: 1,
        maxEntries: 500,
      );
      return <String>{
        for (final String f in files) f.substring(f.lastIndexOf('/') + 1),
      };
    } catch (_) {
      return <String>{};
    }
  }

  /// 两份规范文本是否**逐行相同**。
  ///
  /// 为什么不直接比字符串：`WorkspaceIO.readFile` 把行 `join('\n')` 返回（结尾换行被丢掉），
  /// 直接比会永远不等——于是每次建索引都白刷一遍、还永远报不出 `unchanged`。
  /// CRLF / LF 的差异同样不算"变了"（仓库里是 LF，Windows 上手存过的副本可能是 CRLF）。
  static bool _sameSpecText(String a, String b) {
    final List<String> left = const LineSplitter().convert(
      a.replaceAll('\r\n', '\n'),
    );
    final List<String> right = const LineSplitter().convert(
      b.replaceAll('\r\n', '\n'),
    );
    if (left.length != right.length) return false;
    for (int i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  /// 下一个可用的 `.bak.<n>` 序号（同目录已有备份时顺延，绝不覆盖旧备份）。
  Future<int> _nextBackupIndex(WorkspaceIO io) async {
    int max = 0;
    try {
      final List<String> files = await io.listFiles(
        relativePath: specDir,
        maxDepth: 1,
        maxEntries: 1000,
      );
      final RegExp pattern = RegExp(r'\.bak\.(\d+)$');
      for (final String f in files) {
        final RegExpMatch? match = pattern.firstMatch(f);
        if (match == null) continue;
        final int value = int.tryParse(match.group(1) ?? '') ?? 0;
        if (value > max) max = value;
      }
    } catch (_) {
      // 列目录失败：从 1 开始
    }
    return max + 1;
  }

  Future<SpecDocument?> _readCustom(WorkspaceIO io, String id) async {
    try {
      final FileContent content = await io.readFile('$specDir/$id.md');
      // 内置模板也落在同一目录：按 id 判定"内置"，与是否手改过无关。
      return parseSpecText(
        content.text,
        fallbackId: id,
        builtin: kBuiltinSpecs.containsKey(id),
      );
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
