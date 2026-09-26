import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// Spec 体系（M9 Q9）：内置模板、索引前置（注入系统提示词）、select 直取全文、沉淀与维护。
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

  test('select：直接返回全文（无 read 前置）；空数组清空；不存在报可读错误', () async {
    final Map<String, dynamic> missing = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['ghost'],
      }),
      io,
    );
    expect(missing['error'], contains('Spec 不存在: [ghost]'));
    expect(selected(), isEmpty, reason: '被拒时不得写入选择');

    // Q9：不再要求「先 read」——一次调用既拿全文又挂 hook
    final Map<String, dynamic> ok = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['easy-task', 'easy-task'],
      }),
      io,
    );
    expect(ok['spec_ids'], <String>['easy-task'], reason: '去重保序');
    expect(ok['count'], 1);
    final Map<String, dynamic> first =
        (ok['specs'] as List<dynamic>).single as Map<String, dynamic>;
    expect(first['id'], 'easy-task');
    expect(
      first['content'],
      kBuiltinSpecs['easy-task'],
      reason: 'select 直接回全文',
    );
    expect(ok['note'], contains('不需要再 read'));
    expect(selected(), <String>['easy-task']);

    final Map<String, dynamic> cleared = await service.run(
      call(<String, dynamic>{'action': 'select', 'spec_ids': <dynamic>[]}),
      io,
    );
    expect(cleared['spec_ids'], isEmpty);
    expect(cleared['note'], contains('取消全部'));
    expect(selected(), isEmpty);

    // 删掉的三个动作必须是可读错误，而不是静默成功
    for (final String gone in <String>['search', 'list', 'read']) {
      final Map<String, dynamic> result = await service.run(
        call(<String, dynamic>{'action': gone, 'spec_id': 'easy-task'}),
        io,
      );
      expect(result['error'], contains('未知 spec 动作'), reason: gone);
    }
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

  test('索引渲染：格式照旧、内置标注、when 摘要超 80 截断、>50 条注明其余', () async {
    final List<SpecDocument> all = await service.index(agent.id, io);
    final String text = SpecService.renderIndex(all);
    expect(text, contains('- `easy-task` [easy] 简单任务（直接解决）（内置）'));
    expect(text, contains('（适用: '));

    // when 摘要超 80 字符：截断加省略号，不整条塞进提示词
    final String one = SpecService.renderIndex(<SpecDocument>[
      SpecDocument(id: 'x', title: '标题', body: '', when: <String>['条' * 100]),
    ]);
    expect(one, contains('…'));
    expect(one.contains('条' * 81), isFalse, reason: '摘要只留前 80 字符');

    // 默认全列、>50 条截断并注明「其余 N 条可用 spec select 直取（需已知 id）」
    final List<SpecDocument> many = <SpecDocument>[
      for (int i = 0; i < 55; i++)
        SpecDocument(id: 'spec-$i', title: '标题 $i', body: ''),
    ];
    final String cut = SpecService.renderIndex(many);
    expect(cut, contains('- `spec-49` '), reason: '第 50 条仍列出');
    expect(cut, isNot(contains('`spec-50`')));
    expect(cut, contains('其余 5 条可用 `spec select` 直取（需已知 id）'));
  });

  test('索引随系统提示词每轮重建：create/update 后自然刷新', () async {
    // 模拟核心启动处的接线（CoreServer.start 做的是同一件事）
    addTearDown(() => specIndexProvider = null);
    specIndexProvider = (CoreAgent a) => service.indexSnapshot(a.id);
    service.ioFor = (String _) async => io;

    final String before = systemPromptWithWorkspace(agent);
    expect(before, contains('## Spec 索引（任务型规范）'));
    expect(before, contains('easy-task'), reason: '内置 4 条在索引里');
    expect(before, isNot(contains('db-migration')));

    final Map<String, dynamic> created = await service.run(
      call(<String, dynamic>{
        'action': 'create',
        'title': 'DB Migration',
        'when': <String>['改表结构'],
        'workflow': '先备份再迁移',
      }),
      io,
    );
    final String id = created['spec_id'] as String;
    expect(id, 'db-migration');

    // 没有「刷新索引」这个动作：下一轮提示词的索引里就有它了
    final String after = systemPromptWithWorkspace(agent);
    expect(after, contains('`db-migration` [custom] DB Migration'));
    expect(after, contains('（适用: 改表结构）'));

    await service.run(
      call(<String, dynamic>{
        'action': 'update',
        'spec_id': id,
        'title': 'DB 迁移规范',
      }),
      io,
    );
    expect(systemPromptWithWorkspace(agent), contains('DB 迁移规范'));
  });

  test('safeSpecId：小写、折叠连字符、去首尾；空则给时间戳兜底', () {
    expect(safeSpecId('DB Migration'), 'db-migration');
    expect(safeSpecId('  A__B  '), 'a-b');
    expect(safeSpecId('---'), startsWith('spec-'));
    expect(safeSpecId('数据库'), startsWith('spec-'), reason: '中文标题退化为时间戳 id');
  });

  test('工具声明：spec 需要工作空间、只保留 select/create/update、只在接入时才声明', () {
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
      'select',
      'create',
      'update',
    ]);
    expect(properties.containsKey('query'), isFalse, reason: 'search 已删除');
  });
}
