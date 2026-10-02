import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 内置模板 front matter 里的 `version:` 行——测试要改版本号时**现取**，别硬编码数字
/// （硬编码会在模板 bump version 时误伤测试，而不是真的发现回归）。
final RegExp _versionLine = RegExp(r'^version: \d+$', multiLine: true);

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
    service = SpecService(store: store);
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
    final SpecDocument first = list.first;
    expect(first.id, 'general-task');
    expect(first.title, contains('通用任务'));
    expect(first.taskType, 'general');
    expect(first.risk, 'medium');
    expect(first.pinned, isTrue);
    expect(first.builtin, isTrue);
    expect(first.when, isNotEmpty);
    expect(first.tags, contains('general'));
    expect(first.body, contains('判型确认'));
    expect(
      first.raw,
      kBuiltinSpecTexts['general-task'],
      reason: '播种落盘、内嵌兜底、select 全文三者同源（原文 + 共享第 0 步）',
    );
    // 每条内置规范：正文首部就是共享的「第 0 步：先对齐用户语义」
    for (final SpecDocument document in list) {
      expect(
        document.body.startsWith('## 第 0 步：先对齐用户语义'),
        isTrue,
        reason: '${document.id} 的正文首部应是共享第 0 步：${document.body.split('\n').first}',
      );
      expect(document.body, contains('不得写文件'), reason: document.id);
      // 共享段落只有一份文本：所有规范里这一段逐字相同
      expect(
        document.body.contains(kSpecAlignFirstSection.trim()),
        isTrue,
        reason: document.id,
      );
    }
    // 版本与 changelog 要跟着升级走（否则工作空间里比模板新的副本会被降级）
    expect(first.version, greaterThan(5));
    expect(first.changelog.first, contains('第 0 步'));
    // plugin-creator：同为 general 型，正文口径是"读原指南 + 本机/远端分工"
    final SpecDocument last = list.last;
    expect(last.id, 'plugin-creator');
    expect(last.title, contains('插件开发'));
    expect(last.taskType, 'general');
    expect(last.builtin, isTrue);
    expect(last.body, contains('唯一口径'));
    expect(last.body, contains('docs/plugin-development.md'));
    // 正文要告诉 agent"指南副本在工作空间里"——它读不到应用目录/仓库里的原件
    expect(last.body, contains('.self/docs/plugin-development.md'));
    expect(last.raw, kBuiltinSpecTexts['plugin-creator']);
    expect(last.changelog.first, contains('第 0 步'));
  });

  test('seedInto：内置模板播种到工作空间 .self/spec/（含共享第 0 步）', () async {
    final List<Map<String, dynamic>> notes = await service.seedInto(io);
    final File file = File(
      p.join(temp.path, '.self', 'spec', 'general-task.md'),
    );
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), kBuiltinSpecTexts['general-task']);
    // 每个内置模板都要落盘（新增内置时漏播种 = 用户看不到文件）
    for (final String id in kBuiltinSpecIds) {
      final File seeded = File(p.join(temp.path, '.self', 'spec', '$id.md'));
      expect(seeded.existsSync(), isTrue, reason: '内置模板未播种：$id');
      expect(
        seeded.readAsStringSync(),
        kBuiltinSpecTexts[id],
        reason: '落盘内容 = 派生文本（原文 + 共享第 0 步）：$id',
      );
    }
    expect(
      notes.map((Map<String, dynamic> n) => n['action']),
      everyElement('created'),
    );
    // 再播一次：内容一致 → 不写（不刷 mtime）
    final List<Map<String, dynamic>> again = await service.seedInto(io);
    expect(
      again.map((Map<String, dynamic> n) => n['action']),
      everyElement('unchanged'),
    );
    // 手改副本后 detail 返回改后的内容（工作空间文件是这一侧的读取源）
    file.writeAsStringSync('---\nid: general-task\ntitle: 改过的标题\n---\n\n正文\n');
    final SpecDocument? document = await service.detail(
      agent.id,
      io,
      'general-task',
    );
    expect(document, isNotNull);
    expect(document!.title, '改过的标题');
  });

  test('seedInto 升级语义：旧副本先备份再刷新；比模板新的副本保留不动；自定义不受影响', () async {
    // 1) 先播种（当作"上一版核心播下的"），再手改成"旧模板 + 手改"
    await service.seedInto(io);
    final File builtin = File(
      p.join(temp.path, '.self', 'spec', 'general-task.md'),
    );
    // 版本号从模板现取后改小：硬编码 'version: N' 会在模板 bump 时误伤这个测试
    final String oldText = kBuiltinSpecTexts['general-task']!
        .replaceFirst(_versionLine, 'version: 2')
        .replaceFirst('## 判型确认', '## 我手改的一行\n\n## 判型确认');
    builtin.writeAsStringSync(oldText);

    // 2) 副本 version 低于模板且内容不同 → 备份 + 刷新
    final List<Map<String, dynamic>> refreshed = await service.seedInto(io);
    final Map<String, dynamic> general = refreshed.firstWhere(
      (Map<String, dynamic> n) => n['id'] == 'general-task',
    );
    expect(general['action'], 'refreshed');
    expect(general['backup'], 'general-task.md.bak.1');
    expect(general['file_version'], 2);
    expect(general['template_version'], greaterThan(2));
    expect(builtin.readAsStringSync(), kBuiltinSpecTexts['general-task']);
    final File backup = File(
      p.join(temp.path, '.self', 'spec', 'general-task.md.bak.1'),
    );
    expect(backup.readAsStringSync(), oldText, reason: '手改内容必须留在备份里，不丢');
    // `.bak.*` 不该被当成规范文件
    final List<SpecDocument> listed = await service.index(agent.id, io);
    expect(listed.map((SpecDocument s) => s.id), kBuiltinSpecIds);

    // 3) 副本 version 高于模板（更新的核心 / 别人手改过）→ 保留不动，绝不降级
    final File newer = File(
      p.join(temp.path, '.self', 'spec', 'team-meeting.md'),
    );
    final String newerText = kBuiltinSpecTexts['team-meeting']!
        .replaceFirst(_versionLine, 'version: 99');
    newer.writeAsStringSync(newerText);
    final List<String> logs = <String>[];
    final SpecService logged = SpecService(store: store, log: logs.add);
    final List<Map<String, dynamic>> kept = await logged.seedInto(io);
    final Map<String, dynamic> meeting = kept.firstWhere(
      (Map<String, dynamic> n) => n['id'] == 'team-meeting',
    );
    expect(meeting['action'], 'kept_newer');
    expect(newer.readAsStringSync(), newerText, reason: '版本更高的副本保留，不静默覆盖');
    expect(logs.join(), contains('保留不动'));

    // 4) 自定义规范完全不碰
    final File custom = File(
      p.join(temp.path, '.self', 'spec', 'my-custom.md'),
    );
    custom.writeAsStringSync('---\nid: my-custom\ntitle: 我的\n---\n\n正文\n');
    await service.seedInto(io);
    expect(custom.readAsStringSync(), contains('我的'));
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
        'spec_ids': <String>['general-task', 'general-task'],
      }),
      io,
    );
    expect(ok['spec_ids'], <String>['general-task'], reason: '去重保序');
    expect(ok['count'], 1);
    final Map<String, dynamic> first =
        (ok['specs'] as List<dynamic>).single as Map<String, dynamic>;
    expect(first['id'], 'general-task');
    expect(
      first['content'],
      kBuiltinSpecTexts['general-task'],
      reason: 'select 直接回全文（与落盘、内嵌兜底同源）',
    );
    expect(ok['note'], contains('不需要再 read'));
    expect(selected(), <String>['general-task']);

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
        call(<String, dynamic>{'action': gone, 'spec_id': 'general-task'}),
        io,
      );
      expect(result['error'], contains('未知 spec 动作'), reason: gone);
    }
  });

  test('select：选中 plugin-creator 播种随附指南并回报路径；播种异常不阻断选择', () async {
    // 指南原件（假）：`overrideDir` 指向它，`currentDir` 换成空目录避免真实 cwd 抢答
    final Directory src = Directory.systemTemp.createTempSync('tree_spec_guide_');
    addTearDown(() {
      try {
        if (src.existsSync()) src.deleteSync(recursive: true);
      } catch (_) {
        // Windows 句柄占用：不因此判失败
      }
    });
    File(
      p.join(src.path, 'plugin-development.md'),
    ).writeAsStringSync('# 指南\n');
    service.seedAssetsFor =
        (WorkspaceIO callIo, List<String> ids) => seedBuiltinSpecAssets(
          callIo,
          ids,
          overrideDir: src.path,
          currentDir: temp.path,
        );

    final Map<String, dynamic> ok = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['plugin-creator'],
      }),
      io,
    );
    expect(ok['error'], isNull);
    final Map<String, dynamic> asset =
        (ok['assets'] as List<dynamic>).single as Map<String, dynamic>;
    expect(asset['spec_id'], 'plugin-creator');
    expect(asset['path'], '.self/docs/plugin-development.md');
    expect(asset['action'], 'created');
    expect(ok['note'], contains('随附文档已就绪'));
    expect(
      File(p.join(temp.path, '.self', 'docs', 'plugin-development.md'))
          .readAsStringSync(),
      '# 指南\n',
      reason: '正文让 agent 读这份副本，副本必须真的在工作空间里',
    );

    // 没有随附文档的规范：不动工作空间，结果里也不该出现 assets
    final Map<String, dynamic> plain = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['general-task'],
      }),
      io,
    );
    expect(plain.containsKey('assets'), isFalse);

    // 播种抛错：select 本身照常成功（全文已在结果里，不因为搬文档失败而挡路）
    service.seedAssetsFor =
        (WorkspaceIO callIo, List<String> ids) async => throw StateError('boom');
    final Map<String, dynamic> survived = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['plugin-creator'],
      }),
      io,
    );
    expect(survived['error'], isNull);
    expect(survived['count'], 1);
    expect(selected(), <String>['plugin-creator']);
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
        'title': 'general-task',
        'workflow': 'x',
      }),
      io,
    );
    expect(builtinClash['error'], contains('Spec 已存在: general-task'));

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
    final File file = File(p.join(temp.path, '.self', 'spec', '$id.md'));
    expect(file.existsSync(), isTrue, reason: '落盘在工作空间 .self/spec/');
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
    // 每个内置都不可 update（新增内置时不能漏出可改的口子）
    for (final String id in kBuiltinSpecIds) {
      final Map<String, dynamic> builtin = await service.run(
        call(<String, dynamic>{'action': 'update', 'spec_id': id}),
        io,
      );
      expect(builtin['error'], '$id 为内置 Spec，不可修改', reason: id);
    }

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

  test('索引渲染：格式照旧、内置标注、when 摘要超 80 截断、>50 条注明其余，并带"所有 Spec 共同要求"前置', () async {
    final List<SpecDocument> all = await service.index(agent.id, io);
    final String text = SpecService.renderIndex(all);
    // 自定义规范改不到正文 ⇒ 索引段是"所有 spec 先对齐语义"的唯一公共落点
    expect(text.startsWith(SpecService.indexCommonNotice), isTrue);
    expect(text, contains('动手前先与用户对齐语义'));
    expect(text, contains('只做只读侦察'));
    expect(text, contains('- `general-task` [general] 通用任务（单人串行完成）（内置）'));
    expect(
      text,
      contains('- `plugin-creator` [general] 插件开发（新建 / 改造 Tree 插件）（内置）'),
      reason: '新增内置必须出现在注入提示词的索引里，且带内置标注',
    );
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
    expect(before, contains('general-task'), reason: '内置 4 条在索引里');
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

  test('⑧ 已选 Spec 全文：select 之后下一轮系统提示词就带全文（不再是空头承诺）', () async {
    addTearDown(() {
      selectedSpecsProvider = null;
      specIndexProvider = null;
    });
    // 模拟核心启动处的接线（CoreServer.start 做的是同一件事）
    selectedSpecsProvider = (CoreAgent a, String s) =>
        service.selectedSpecsSnapshot(a.id, s);
    service.ioFor = (String _) async => io;

    expect(
      systemPromptWithWorkspace(agent, sessionId: sessionId),
      isNot(contains('已选 Spec 全文')),
      reason: '没挂 hook 时不注入这一段',
    );

    final Map<String, dynamic> selected = await service.run(
      call(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['general-task'],
      }),
      io,
    );
    expect(selected['count'], 1);

    final String wired = systemPromptWithWorkspace(agent, sessionId: sessionId);
    expect(wired, contains('## 已选 Spec 全文（本会话挂的 hook）'));
    expect(wired, contains('### Spec: general-task'));
    expect(wired, contains('判型确认'), reason: '注入的是规范全文，不只是 id');
    expect(
      systemPromptWithWorkspace(agent, sessionId: 'ses_其他'),
      isNot(contains('已选 Spec 全文')),
      reason: 'hook 是按会话生效的',
    );
  });

  test('⑧ 快照：冷缓存（如重启后）同步取为空，补扫后按会话里存的 id 恢复', () async {
    addTearDown(() => selectedSpecsProvider = null);
    store.setSelectedSpecs(agent.id, sessionId, <String>['general-task']);
    service.ioFor = (String _) async => io;

    expect(
      service.selectedSpecsSnapshot(agent.id, sessionId),
      isEmpty,
      reason: '同步快照拿不到就先空着（本轮不注入），同时后台补一次',
    );
    await service.refreshSelectedSpecs(agent.id, sessionId, io);
    expect(
      service.selectedSpecsSnapshot(agent.id, sessionId),
      contains('### Spec: general-task'),
    );
  });

  test('⑧ 快照：悬空 hook（规范已不存在）跳过，不阻断其余', () async {
    store.setSelectedSpecs(agent.id, sessionId, <String>[
      'ghost-spec',
      'hard-task',
    ]);
    await service.refreshSelectedSpecs(agent.id, sessionId, io);
    final String text = service.selectedSpecsSnapshot(agent.id, sessionId);
    expect(text, contains('### Spec: hard-task'));
    expect(text, isNot(contains('ghost-spec')));
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
  test('ensureSnapshots：拼提示词前先把 ⑦/⑧ 快照热起来（冷热不在会话中途切换）', () async {
    service.ioFor = (String id) async => io;
    // 工作空间里放一条自定义规范：只有全量扫描过才会出现在索引里
    final Directory dir = Directory(p.join(temp.path, '.self', 'spec'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'my-spec.md')).writeAsString(
      '---\nid: my-spec\ntitle: 自定义规范（工作空间）\n---\n\n正文',
      flush: true,
    );
    // 库里已选 general-task，但**本进程还没读过**（= 冷启动现场：核心刚重启）
    store.session(agent.id, sessionId)!.selectedSpecIds = <String>['general-task'];

    final String coldIndex = service.indexSnapshot(agent.id);
    expect(coldIndex, isNot(contains('my-spec')), reason: '冷的时候只有内置模板');
    expect(
      service.selectedSpecsSnapshot(agent.id, sessionId),
      isEmpty,
      reason: '冷的时候 ⑧ 章整段不注入',
    );

    await service.ensureSnapshots(agent.id, sessionId);

    final String warmIndex = service.indexSnapshot(agent.id);
    expect(warmIndex, contains('my-spec'), reason: '预热后是全量索引');
    expect(
      service.selectedSpecsSnapshot(agent.id, sessionId),
      contains('general-task'),
      reason: '预热后 ⑧ 章有已选规范全文',
    );
    await service.ensureSnapshots(agent.id, sessionId);
    expect(service.indexSnapshot(agent.id), warmIndex, reason: '预热是幂等的');
  });

}
