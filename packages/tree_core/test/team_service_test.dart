import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 团队领域服务（M5b）：结构、审核闸门与隔离不变量。
///
/// 参考实现是 `teams` + `team_members` 两张表；桌面端把成员做成**独立 agent 文件**，
/// 因此这里同时验证"团队字段真的落到 `agents/<id>.yaml`"（用户可手改）。
void main() {
  late MemoryStore store;
  late CoreSettings settings;
  late TeamService service;
  late CoreAgent top;

  setUp(() {
    store = MemoryStore();
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
      'max_output_tokens': 4096,
    });
    service = TeamService(store: store, settings: settings);
    top = store.createAgent(
      name: '队长',
      modelId: 'demo',
      maxLevel: 3,
      maxMembersPerLevel: 7,
    );
  });

  Map<String, dynamic> create([String name = '成员甲', String parent = '']) =>
      service.createMember(parent.isEmpty ? top.id : parent, <String, dynamic>{
        'action': 'create_member',
        'member_name': name,
      });

  group('结构', () {
    test('list_teams = 顶部 agent，member_count 按实际成员数回填', () {
      create('成员甲');
      final Map<String, dynamic> result = service.listTeams(top.id);
      final List<dynamic> teams = result['teams'] as List<dynamic>;
      expect(teams, hasLength(1));
      final Map<String, dynamic> view = teams.single as Map<String, dynamic>;
      expect(view['id'], top.id);
      expect(view['name'], '队长');
      expect(view['member_count'], 1);
      // 成员不是"团队"
      expect(service.teams().map((CoreAgent a) => a.id), <String>[top.id]);
    });

    test('create_member：pending_model + 空模型 + 层级/带队权/独立工作空间', () {
      final Map<String, dynamic> result = create('成员甲');
      expect(result.containsKey('error'), isFalse);
      expect(result['review_status'], ReviewStatus.pendingModel);
      expect(result['model_id'], '');
      expect(result['level'], 1);
      expect(result['can_lead_team'], isTrue);
      expect(result['initialized'], isFalse);
      expect(result['workspace_id'], isNot(top.workspaceId));
      final CoreAgent member = store.agent(result['member_id'] as String)!;
      expect(member.teamId, top.id, reason: 'team_id 指向 TOP');
      expect(member.parentAgentId, top.id);
      expect(member.isMember, isTrue);
      expect(
        service.reviewBlock(member.id),
        contains('尚未分配模型'),
        reason: '未就绪成员必须被审核闸拦住',
      );
      expect(store.agent(top.id)!.teamMemberCount, 1, reason: '计数回填');
    });

    test('list_members：分组、关系、not_ready_count 与白名单（不泄漏 system_prompt）', () {
      final String first = create('成员甲')['member_id'] as String;
      final String second =
          service.createMember(top.id, <String, dynamic>{
                'action': 'create_member',
                'member_name': '成员乙',
                'system_prompt': '机密提示词',
              })['member_id']
              as String;
      final String grand =
          service.createMember(first, <String, dynamic>{
                'action': 'create_member',
                'member_name': '孙成员',
              })['member_id']
              as String;

      final Map<String, dynamic> payload = service.listMembers(top.id);
      expect(payload['total'], 3);
      expect(payload['not_ready_count'], 3);
      expect(payload['hint'], contains('尚未就绪'));
      final Map<String, dynamic> groups =
          payload['groups'] as Map<String, dynamic>;
      expect((groups['team_leader'] as List<dynamic>).single['id'], top.id);
      expect(
        (groups['teammates'] as List<dynamic>)
            .map((dynamic m) => (m as Map<String, dynamic>)['id'])
            .toSet(),
        <String>{first, second},
        reason: '同毫秒创建时顺序由 id 兜底，这里只要求集合一致',
      );
      expect((groups['team_member'] as List<dynamic>).single['id'], grand);
      final Map<String, dynamic> memberView =
          (groups['team_member'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(memberView['relation'], MemberRelation.indirect);
      expect(memberView['log_path'], '.tree/$grand/.self/activity.log');
      expect(
        memberView.containsKey('system_prompt'),
        isFalse,
        reason: '名单是白名单视图，绝不暴露提示词',
      );
      final Map<String, dynamic> detailed =
          service.queryMember(top.id, <String, dynamic>{
                'target_member_id': second,
              })['member']
              as Map<String, dynamic>;
      expect(detailed['system_prompt'], '机密提示词', reason: 'query_member 才给');
    });

    test('成员自己调 list_members：不把自己列两遍，total 不含自己', () {
      final String first = create('成员甲')['member_id'] as String;
      final String second = create('成员乙')['member_id'] as String;
      final String grand = service.createMember(first, <String, dynamic>{
        'action': 'create_member',
        'member_name': '孙成员',
      })['member_id'] as String;

      final Map<String, dynamic> payload = service.listMembers(first);
      expect(payload['total'], 2, reason: '只有乙与孙成员，不含调用者自己');
      final List<dynamic> list = payload['members'] as List<dynamic>;
      expect(
        list.map((dynamic m) => (m as Map<String, dynamic>)['id']).toList(),
        <String>[first, grand, second],
        reason:
            'leaderView（自己）只出现一次；rest 里是孙成员与乙（同级关系）；'
            '旧实现会把自己同时塞进 leaderView 与 rest',
      );
      expect(
        list.where((dynamic m) => (m as Map<String, dynamic>)['id'] == first),
        hasLength(1),
      );
      final Map<String, dynamic> groups =
          payload['groups'] as Map<String, dynamic>;
      expect((groups['team_leader'] as List<dynamic>).single['id'], first);
      expect(
        (groups['teammates'] as List<dynamic>)
            .map((dynamic m) => (m as Map<String, dynamic>)['id'])
            .toSet(),
        <String>{grand},
        reason: '孙成员是它的直属',
      );
      expect((groups['team_member'] as List<dynamic>).single['id'], second);
    });

    test('实时工作状态来自注入的权威表（未接入恒 idle）', () {
      final String member = create('成员甲')['member_id'] as String;
      expect(service.workStatus(member), 'idle');
      final TeamService working = TeamService(
        store: store,
        settings: settings,
        isWorking: (String id) => id == member,
      );
      expect(working.workStatus(member), 'working');
      final Map<String, dynamic> filtered = working.listMembers(
        top.id,
        args: <String, dynamic>{'work_status': 'working'},
      );
      expect(
        (filtered['groups'] as Map<String, dynamic>)['teammates'],
        hasLength(1),
      );
    });
  });

  group('隔离与安全不变量', () {
    test('没有模型写入口：create/update/review 收到 model_id 一律报错且不改库', () {
      final Map<String, dynamic> created = service.createMember(
        top.id,
        <String, dynamic>{
          'action': 'create_member',
          'member_name': '成员甲',
          'model_id': 'demo',
        },
      );
      expect(created['error'], 'team 工具无权为成员分配模型');
      expect(service.members(top.id), isEmpty, reason: '校验失败不得创建');

      final String member = create('成员甲')['member_id'] as String;
      final Map<String, dynamic> updated = service.updateMember(
        top.id,
        <String, dynamic>{'target_member_id': member, 'model_id': 'demo'},
      );
      expect(updated['error'], 'team 工具无权修改成员模型');
      final Map<String, dynamic> reviewed = service.reviewMember(
        top.id,
        <String, dynamic>{'target_member_id': member, 'model_id': 'demo'},
      );
      expect(reviewed['error'], 'team 工具无权为成员分配模型');
      expect(store.agent(member)!.modelId, '');
    });

    test('work_status 只读：update 携带即报错，且库值不被改写', () {
      final String member = create('成员甲')['member_id'] as String;
      final Map<String, dynamic> result = service.updateMember(
        top.id,
        <String, dynamic>{'target_member_id': member, 'work_status': 'working'},
      );
      expect(result['error'], contains('work_status 为只读字段'));
      expect(store.agent(member)!.reviewStatus, ReviewStatus.pendingModel);
    });

    test('create_member 校验顺序：层级 → 带队权 → 直属人数 → 重名', () {
      // 层级：maxLevel=1 时，第 1 层成员不能再建子团队
      final CoreAgent shallow = store.createAgent(name: '浅队', maxLevel: 1);
      final String shallowChild =
          service.createMember(shallow.id, <String, dynamic>{
                'action': 'create_member',
                'member_name': '甲',
              })['member_id']
              as String;
      expect(
        service.createMember(shallowChild, <String, dynamic>{
          'action': 'create_member',
          'member_name': '乙',
        })['error'],
        contains('已达最大层级'),
      );

      // 带队权：先造一个不能带队的成员（层级 1 < 3，走带队权分支）
      final String noLead =
          service.createMember(top.id, <String, dynamic>{
                'action': 'create_member',
                'member_name': '不能带队',
                'can_lead_team': false,
              })['member_id']
              as String;
      expect(
        service.createMember(noLead, <String, dynamic>{
          'action': 'create_member',
          'member_name': '子',
        })['error'],
        contains('can_lead_team=False'),
      );

      // 人数：每层上限 1
      final CoreAgent onePerLevel = store.createAgent(
        name: '窄队',
        maxLevel: 3,
        maxMembersPerLevel: 1,
      );
      expect(
        service.createMember(onePerLevel.id, <String, dynamic>{
          'action': 'create_member',
          'member_name': '甲',
        })['error'],
        isNull,
      );
      expect(
        service.createMember(onePerLevel.id, <String, dynamic>{
          'action': 'create_member',
          'member_name': '乙',
        })['error'],
        contains('直属成员数量已达上限'),
      );

      // 重名（层级/带队权/人数均通过）
      final CoreAgent wide = store.createAgent(
        name: '宽队',
        maxLevel: 3,
        maxMembersPerLevel: 7,
      );
      service.createMember(wide.id, <String, dynamic>{
        'action': 'create_member',
        'member_name': '同名',
      });
      expect(
        service.createMember(wide.id, <String, dynamic>{
          'action': 'create_member',
          'member_name': '同名',
        })['error'],
        contains('成员名称已存在'),
      );
      expect(
        service.createMember(wide.id, <String, dynamic>{
          'action': 'create_member',
          'member_name': '   ',
        })['error'],
        '成员名称不能为空',
      );
    });

    test('remove_member：不可移除自身/所有者/上级/非后代', () {
      final String first = create('成员甲')['member_id'] as String;
      final String peer = create('成员乙')['member_id'] as String;
      final String grand =
          service.createMember(first, <String, dynamic>{
                'action': 'create_member',
                'member_name': '孙成员',
              })['member_id']
              as String;

      expect(
        service.removeMember(top.id, <String, dynamic>{
          'target_member_id': top.id,
        })['error'],
        contains('不可移除团队所有者'),
      );
      expect(
        service.removeMember(top.id, <String, dynamic>{
          'target_member_id': first,
          'cascade': true,
        })['error'],
        isNull,
      );
      // 现在 first 与 grand 都没了；peer 还在
      expect(store.agent(first), isNull);
      expect(store.agent(grand), isNull);
      expect(store.agent(peer), isNotNull);

      expect(
        service.removeMember(first, <String, dynamic>{
          'target_member_id': first,
        })['error'],
        contains('不存在'),
        reason: '已删除的成员不能再作为操作者',
      );
      // 成员不能移除自己
      final Map<String, dynamic> selfRemove = service.removeMember(
        peer,
        <String, dynamic>{'target_member_id': peer},
      );
      expect(selfRemove['error'], '不可移除自己');
      // 成员不能移除上级（TOP）
      final Map<String, dynamic> up = service.removeMember(
        peer,
        <String, dynamic>{'target_member_id': top.id},
      );
      expect(up['error'], contains('不可移除团队所有者'));
    });

    test('remove_member：非后代（平级）被拒；有下级时必须显式 cascade', () {
      final String first = create('成员甲')['member_id'] as String;
      final String peer = create('成员乙')['member_id'] as String;
      service.createMember(first, <String, dynamic>{
        'action': 'create_member',
        'member_name': '孙成员',
      });

      final Map<String, dynamic> peerAttempt = service.removeMember(
        first,
        <String, dynamic>{'target_member_id': peer},
      );
      expect(peerAttempt['error'], contains('不可移除非直属/下级成员'));

      final Map<String, dynamic> selfAttempt = service.removeMember(
        first,
        <String, dynamic>{'target_member_id': first},
      );
      expect(selfAttempt['error'], '不可移除自己');

      // 有下级但未 cascade：拒绝 + 列出需要的子树
      final Map<String, dynamic> blocked = service.removeMember(
        top.id,
        <String, dynamic>{'target_member_id': first, 'cascade': false},
      );
      expect(blocked['error'], contains('未指定 cascade'));
      expect(blocked['cascade_required'], hasLength(1));
      expect(store.agent(first), isNotNull, reason: '拒绝时不得删任何东西');

      final Map<String, dynamic> ok = service.removeMember(
        top.id,
        <String, dynamic>{'target_member_id': first, 'cascade': true},
      );
      expect(ok['removed_ids'], hasLength(2));
      expect(ok['subtree_removed'], hasLength(1));
      expect(store.agent(top.id)!.teamMemberCount, 1, reason: '删除后回填计数');
    });

    test('审核闸门：approved 放行；pending/rejected 给出可操作原因', () {
      final String member = create('成员甲')['member_id'] as String;
      expect(service.reviewBlock(top.id), isNull, reason: 'TOP 放行');
      expect(service.reviewBlock(member), contains('尚未分配模型'));

      service.reviewMember(member, <String, dynamic>{
        'target_member_id': member,
        'review_status': 'rejected',
      });
      expect(service.reviewBlock(member), contains('已被用户驳回'));

      // 用户放行后（REST 入口）才放行
      service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{
          'model_id': 'demo',
          'review_status': 'approved',
        },
      );
      expect(service.reviewBlock(member), isNull);
      expect(store.agent(member)!.isApproved, isTrue);
    });

    test('review_member 非法状态被拒；approve=false 等于驳回', () {
      final String member = create('成员甲')['member_id'] as String;
      expect(
        service.reviewMember(top.id, <String, dynamic>{
          'target_member_id': member,
          'review_status': '随便',
        })['error'],
        contains('审核状态非法'),
      );
      service.reviewMember(top.id, <String, dynamic>{
        'target_member_id': member,
        'approve': false,
      });
      expect(store.agent(member)!.reviewStatus, ReviewStatus.rejected);
    });

    test('update_member：空请求/重名被拒；可改档案与评分', () {
      final String member = create('成员甲')['member_id'] as String;
      create('成员乙');
      expect(
        service.updateMember(top.id, <String, dynamic>{
          'target_member_id': member,
        })['error'],
        '未提供任何可更新的字段',
      );
      expect(
        service.updateMember(top.id, <String, dynamic>{
          'target_member_id': member,
          'name': '成员乙',
        })['error'],
        contains('成员名称已存在'),
      );
      final Map<String, dynamic> result = service.updateMember(
        top.id,
        <String, dynamic>{
          'target_member_id': member,
          'role': '实现',
          'duty': '写代码',
          'can_lead_team': false,
          'comment': '不错',
          'scores': <String, dynamic>{'quality': 9.5, 'accuracy': 8},
        },
      );
      expect(result.containsKey('error'), isFalse);
      final CoreAgent updated = store.agent(member)!;
      expect(updated.role, '实现');
      expect(updated.duty, '写代码');
      expect(updated.canLeadTeam, isFalse);
      expect(updated.comment, '不错');
      expect(updated.scores['quality'], 9.5);
      expect(
        updated.reviewStatus,
        ReviewStatus.pendingModel,
        reason: '编辑档案不得打回审核状态',
      );
    });

    test('未知 action 返回可读错误与可用 action 列表', () {
      final Map<String, dynamic> result = service.run(top.id, <String, dynamic>{
        'action': 'nope',
      });
      expect(result['error'], '未知 action: nope');
      expect(result['hint'], contains('list_members'));
    });
  });

  group('用户侧 assignModel（唯一模型写入口）', () {
    test('分配模型 → 自动 pending_review；显式 approved 才放行', () {
      final String member = create('成员甲')['member_id'] as String;
      final Map<String, dynamic> assigned = service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{'model_id': 'demo'},
      );
      expect(assigned['success'], isTrue);
      expect(store.agent(member)!.modelId, 'demo');
      expect(
        store.agent(member)!.reviewStatus,
        ReviewStatus.approved,
        reason: '有模型即视为可审核通过（与参考实现 derive 一致）',
      );

      final Map<String, dynamic> pending = service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{'review_status': 'pending_review'},
      );
      expect(pending['success'], isTrue);
      expect(store.agent(member)!.reviewStatus, ReviewStatus.pendingReview);
    });

    test('清空模型回退 pending_model；空 body 与非法值可读报错', () {
      final String member = create('成员甲')['member_id'] as String;
      service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{'model_id': 'demo'},
      );
      service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{'model_id': ''},
      );
      expect(store.agent(member)!.modelId, '');
      expect(store.agent(member)!.reviewStatus, ReviewStatus.pendingModel);

      expect(
        service.assignModel(
          topId: top.id,
          memberId: member,
          body: <String, dynamic>{},
        )['error'],
        contains('至少提供'),
      );
      expect(
        service.assignModel(
          topId: top.id,
          memberId: member,
          body: <String, dynamic>{'model_id': '不存在'},
        )['error'],
        contains('模型不存在'),
      );
      expect(
        service.assignModel(
          topId: top.id,
          memberId: member,
          body: <String, dynamic>{'review_status': 'x'},
        )['error'],
        contains('审核状态非法'),
      );
    });

    test('成员级模型参数覆盖：存储 + effective 合并 + 非法值拒绝', () {
      final String member = create('成员甲')['member_id'] as String;
      service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{
          'model_id': 'demo',
          'review_status': 'approved',
        },
      );
      final Map<String, dynamic> result = service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{
          'reasoning_effort': 'high',
          'max_seqlen': 32000,
          'max_output_tokens': 2048,
          'compress_threshold': 0.8,
        },
      );
      expect(result['success'], isTrue);
      final Map<String, dynamic> overrides =
          (result['member'] as Map<String, dynamic>)['overrides']
              as Map<String, dynamic>;
      expect(overrides['reasoning_effort'], 'high');
      expect(overrides['max_seqlen'], 32000);
      final Map<String, dynamic> effective =
          (result['member'] as Map<String, dynamic>)['effective']
              as Map<String, dynamic>;
      expect(effective['max_seqlen'], 32000, reason: '覆盖优先于模型默认');
      expect(effective['max_output_tokens'], 2048);

      expect(
        service.assignModel(
          topId: top.id,
          memberId: member,
          body: <String, dynamic>{'max_seqlen': -1},
        )['error'],
        contains('正整数'),
      );
      expect(
        service.assignModel(
          topId: top.id,
          memberId: member,
          body: <String, dynamic>{'compress_threshold': 0.99},
        )['error'],
        contains('0.1~0.95'),
      );
      // 清除覆盖（传 null）
      service.assignModel(
        topId: top.id,
        memberId: member,
        body: <String, dynamic>{'max_seqlen': null},
      );
      expect(store.agent(member)!.maxSeqlenOverride, 0);
    });

    test('PATCH 只能作用于该 TOP 的成员', () {
      final CoreAgent other = store.createAgent(name: '别的队');
      final String member = create('成员甲')['member_id'] as String;
      expect(
        service.assignModel(
          topId: other.id,
          memberId: member,
          body: <String, dynamic>{'review_status': 'approved'},
        )['error'],
        contains('成员不存在'),
      );
    });
  });

  test('落盘：团队字段写进 agents/<id>.yaml，重载后仍在（用户可手改）', () async {
    final Directory temp = Directory.systemTemp.createTempSync('tree_team_');
    addTearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final TreePaths paths = TreePaths(temp.path);
    final FileTreeStore fileStore = FileTreeStore(paths);
    final TeamService fileService = TeamService(
      store: fileStore,
      settings: settings,
    );
    final CoreAgent fileTop = fileStore.createAgent(
      name: '队长',
      modelId: 'demo',
    );
    final String memberId =
        fileService.createMember(fileTop.id, <String, dynamic>{
              'action': 'create_member',
              'member_name': '成员甲',
              'role': '实现',
            })['member_id']
            as String;
    fileService.assignModel(
      topId: fileTop.id,
      memberId: memberId,
      body: <String, dynamic>{'model_id': 'demo', 'review_status': 'approved'},
    );
    await fileStore.flush();

    final String yaml = File(paths.agentFile(memberId)).readAsStringSync();
    expect(yaml, contains('team_id: ${fileTop.id}'));
    expect(yaml, contains('parent_agent_id: ${fileTop.id}'));
    expect(yaml, contains('level: 1'));
    expect(yaml, contains('review_status: approved'));
    // 非 ASCII 值会被 YamlCodec 加引号（"实现"），只断言值在文件里
    expect(yaml, contains('实现'));

    // 手改 yaml 后重载：成员改名生效（证明配置是数据而不是代码）
    // 非 ASCII 值是带引号写的（`name: "成员甲"`），手改时要按磁盘上的样子替换
    final String edited = yaml.replaceFirst('name: "成员甲"', 'name: "手改过的成员"');
    File(paths.agentFile(memberId)).writeAsStringSync(edited);
    final FileTreeStore reloaded = FileTreeStore(paths);
    expect(reloaded.agent(memberId)?.name, '手改过的成员');
    expect(reloaded.members(fileTop.id), hasLength(1));
    await fileStore.close();
    await reloaded.close();
  });
}
