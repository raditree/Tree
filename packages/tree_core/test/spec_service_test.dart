import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// Spec 体系（M5d）：内置模板、索引、read→select 前置、沉淀与维护。
void main() {
  late Directory temp;
  late LocalWorkspaceIO io;
  late MemoryStore store;
  late SpecService service;
  late CoreAgent agent;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_spec_');
    io = LocalWorkspaceIO(temp.path);
    store = MemoryStore();
    service = SpecService(
      store: store,
      builtinSpecsDir: p.join(temp.path, 'builtin'),
    );
    agent = store.createAgent(name: '队长');
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  ToolInvocation call(Map<String, dynamic> args) => ToolInvocation(
    id: 'tool_1',
    name: 'spec',
    arguments: args,
    agentId: agent.id,
    sessionId: sessionId,
  );

  List<String> selected() =>
      store.session(agent.id, sessionId)?.selectedSpecIds ?? <String>[];

  test('内置模板：4 个、固定顺序、front matter 解析与原文逐字一致', () async {
    final List<SpecDocument> list = await service.index(agent.id, io);
    expect(list.map((SpecDocument s) => s.id), kBuiltinSpecIds);
    final SpecDocument easy = list.first;
    expect(easy.title, contains('简单任务'));
    expect(easy.taskType, 'easy');
    expect(easy.risk, 'low');
    expect(easy.pinned, isTrue);
    expect(easy.builtin, isTrue);
    expect(easy.when, isNotEmpty);
    expect(easy.tags, contains('easy'));
    expect(easy.body, contains('判型确认'));
    expect(easy.raw, kBuiltinSpecs['easy-task'], reason: 'read 必须逐字返回原文');
  });

  test('seedBuiltins：模板落到数据根，用户可查看与手改', () async {
    await service.seedBuiltins();
    final File file = File(p.join(temp.path, 'builtin', 'easy-task.md'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), kBuiltinSpecs['easy-task']);
    // 手改副本后再读取仍然可用（文件是真源）
    file.writeAsStringSync('---\nid: easy-task\ntitle: 改过的标题\n---\n\n正文\n');
    final SpecDocument? document = await service.detail(
      agent.id,
      io,
      'easy-task',
    );
    expect(document, isNotNull, reason: '内置优先读内嵌常量，副本改动不影响内置');
  });

  test('read/select：不存在报可读错误；必须先 read 再 select；空数组清空', () async {
    final Map<String, dynamic> missing = await service.run(
      call(<String, dynamic>{'action': 'read', 'spec_id': 'nope'}),
      io,
    );
    expect(missing['error'], contains('Spec 不存在: nope'));

    final Map<String, dynamic> guard = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['easy-task'],
      }),
      io,
    );
    expect(guard['error'], contains('select 前必须先 read 对应 Spec'));
    expect(selected(), isEmpty, reason: '被拒时不得写入选择');

    final Map<String, dynamic> read = await service.run(
      call(<String, dynamic>{'action': 'read', 'spec_id': 'easy-task'}),
      io,
    );
    expect(read['content'], kBuiltinSpecs['easy-task']);

    final Map<String, dynamic> ok = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['easy-task', 'easy-task'],
      }),
      io,
    );
    expect(ok['spec_ids'], <String>['easy-task'], reason: '去重保序');
    expect(selected(), <String>['easy-task']);

    final Map<String, dynamic> cleared = await service.run(
      call(<String, dynamic>{'action': 'select', 'spec_ids': <dynamic>[]}),
      io,
    );
    expect(cleared['spec_ids'], isEmpty);
    expect(cleared['note'], contains('取消全部'));
    expect(selected(), isEmpty);

    final Map<String, dynamic> ghost = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['ghost'],
      }),
      io,
    );
    expect(ghost['error'], contains('Spec 不存在: [ghost]'));
  });

  test('create：落盘到工作空间并可读回；重名/内置名/缺内容被拒', () async {
    final Map<String, dynamic> empty = await service.run(
      call(<String, dynamic>{'action': 'create', 'title': '  '}),
      io,
    );
    expect(empty['error'], 'create 需要 title');

    final Map<String, dynamic> noBody = await service.run(
      call(<String, dynamic>{'action': 'create', 'title': '只有标题'}),
      io,
    );
    expect(noBody['error'], contains('至少提供 workflow/rules/notes'));

    final Map<String, dynamic> builtinClash = await service.run(
      call(<String, dynamic>{
        'action': 'create',
        'title': 'easy-task',
        'workflow': 'x',
      }),
      io,
    );
    expect(builtinClash['error'], contains('Spec 已存在: easy-task'));

    final Map<String, dynamic> created = await service.run(
      call(<String, dynamic>{
        'action': 'create',
        'title': '数据库迁移规范',
        'task_type': 'custom',
        'description': '改表结构时的检查清单',
        'when': <String>['涉及 schema 变更'],
        'workflow': '1. 备份\n2. 写迁移',
        'rules': '必须先备份',
        'notes': '注意回滚',
      }),
      io,
    );
    final String id = created['spec_id'] as String;
    expect(id, startsWith('spec-'), reason: '中文标题退化为时间戳 id');
    final File file = File(p.join(temp.path, 'spec', '$id.md'));
    expect(file.existsSync(), isTrue, reason: '落盘在工作空间 spec/');
    final String text = file.readAsStringSync();
    expect(text, contains('## 工作流（workflow）'));
    expect(text, contains('## 该类任务规范'));
    expect(text, contains('## 注意事项'));

    // 读回：front matter 可被解析器还原
    final SpecDocument? document = await service.detail(agent.id, io, id);
    expect(document, isNotNull);
    expect(document!.title, '数据库迁移规范');
    expect(document.description, '改表结构时的检查清单');
    expect(document.when, <String>['涉及 schema 变更']);
    expect(document.builtin, isFalse);
    expect(document.version, 1);

    // 目录索引里出现（内置在前）
    final List<SpecDocument> list = await service.index(agent.id, io);
    expect(list.map((SpecDocument s) => s.id).toList(), <String>[
      ...kBuiltinSpecIds,
      id,
    ]);
  });

  test('update：内置不可改；按段合并保留未提供段；版本与 changelog 递增', () async {
    final Map<String, dynamic> builtin = await service.run(
      call(<String, dynamic>{'action': 'update', 'spec_id': 'easy-task'}),
      io,
    );
    expect(builtin['error'], 'easy-task 为内置 Spec，不可修改');

    final Map<String, dynamic> created = await service.run(
      call(<String, dynamic>{
        'action': 'create',
        'title': '我的规范',
        'workflow': '老流程',
        'rules': '老规则',
        'notes': '老注意',
      }),
      io,
    );
    final String id = created['spec_id'] as String;

    final Map<String, dynamic> updated = await service.run(
      call(<String, dynamic>{
        'action': 'update',
        'spec_id': id,
        'rules': '新规则',
      }),
      io,
    );
    expect(updated['success'], isTrue);
    final SpecDocument? document = await service.detail(agent.id, io, id);
    expect(document!.version, 2);
    expect(document.body, contains('新规则'));
    expect(document.body, contains('老流程'), reason: '未提供的段落保留');
    expect(document.body, contains('老注意'));
    expect(document.body, isNot(contains('老规则')));
    expect(document.changelog.first, contains('v2('));

    final Map<String, dynamic> ghost = await service.run(
      call(<String, dynamic>{'action': 'update', 'spec_id': 'ghost'}),
      io,
    );
    expect(ghost['error'], 'Spec 不存在: ghost');
  });

  test('search：关键词命中 + 内置置顶；缺 query 报错', () async {
    final Map<String, dynamic> noQuery = await service.run(
      call(<String, dynamic>{'action': 'search'}),
      io,
    );
    expect(noQuery['error'], contains('search 需要 query'));

    final Map<String, dynamic> hit = await service.run(
      call(<String, dynamic>{'action': 'search', 'query': '困难 企业级 高风险'}),
      io,
    );
    final List<dynamic> specs = hit['specs'] as List<dynamic>;
    expect(specs, isNotEmpty);
    expect(
      (specs.first as Map<String, dynamic>)['id'],
      'hard-task',
      reason: '内置置顶 + 关键词命中',
    );
  });

  test('list：返回索引与当前 selected_spec_ids', () async {
    await service.run(
      call(<String, dynamic>{'action': 'read', 'spec_id': 'easy-task'}),
      io,
    );
    await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['easy-task'],
      }),
      io,
    );
    final Map<String, dynamic> listed = await service.run(
      call(<String, dynamic>{'action': 'list'}),
      io,
    );
    expect(listed['count'], 4);
    expect(listed['selected_spec_ids'], <String>['easy-task']);
  });

  test('safeSpecId：小写、折叠连字符、去首尾；空则给时间戳兜底', () {
    expect(safeSpecId('DB Migration'), 'db-migration');
    expect(safeSpecId('  A__B  '), 'a-b');
    expect(safeSpecId('---'), startsWith('spec-'));
    expect(safeSpecId('数据库'), startsWith('spec-'), reason: '中文标题退化为时间戳 id');
  });

  test('工具声明：spec 需要工作空间、6 个 action、只在接入时才声明', () {
    expect(
      BuiltinTools.specs().map((ToolSpec s) => s.name),
      isNot(contains('spec')),
    );
    expect(
      BuiltinTools.specs(withSpec: true).map((ToolSpec s) => s.name),
      contains('spec'),
    );
    expect(BuiltinTools.needsWorkspace('spec'), isTrue);
    final ToolSpec spec = SpecTool.spec();
    final Map<String, dynamic> properties =
        spec.parameters['properties'] as Map<String, dynamic>;
    expect((properties['action'] as Map<String, dynamic>)['enum'], <String>[
      'search',
      'list',
      'read',
      'select',
      'create',
      'update',
    ]);
  });
}
