/// H1：tree.agent **24 条写路由**的真实 HTTP 对照（旧核心 vs 当前核心 + 插件）。
///
/// 参考侧 = 仓库里的 `build/tree_core.exe`（A5 前构建，含旧领域实现）；
/// 新侧 = 当前 `package:tree_core` 的 CoreServer + 真实 `build/plugins/tree_agent.exe`。
/// 两侧各自使用**独立的临时 dataDir**，但由同一份种子生成（agent/session/team/
/// 模型池/提问/工作空间/消息），因此可以逐条比较请求结果。
///
/// 覆盖 24 条 = G-1 中尚未在旧 verify 工具里双跑的 24 条：
///   19 条写路由（agent / 模型池 / token-rate / 会话 / 历史 / 提问 / 团队 / 维护）
/// + 5 条此前未双跑的 GET（questions / teammate log / specs / spec detail / transcript）。
/// C-08 新增的 `messages` / `cancel` 旧核心不存在，没有参考侧，只打印为跳过。
///
/// 比较口径：HTTP status + Content-Type + **规范化后的 body**（JSON 递归排序；
/// 时间戳、随机 id、绝对数据根路径、密钥替换为占位符）。任何一条不等都打印差异
/// 并以非 0 退出；连不上 / 插件起不来则说明可复现原因。
///
/// 用法（在 `packages/tree_core` 下）：
///   dart run tool/verify_agent_write_http.dart
///   dart run tool/verify_agent_write_http.dart --old-core `path` --agent `path`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_core/tree_core.dart';

const String kTopAgent = 'agt_top';
const String kMemberAgent = 'agt_member';
const String kEmptyAgent = 'agt_empty';
const String kDefaultSession = 'session_default';
const String kQuestionId = 'q_seed';
const String kFastFailBaseUrl = 'http://127.0.0.1:1/v1';

Future<void> main(List<String> args) async {
  final String repoRoot = _defaultRepoRoot();
  final String oldCorePath =
      _arg(args, '--old-core') ?? p.join(repoRoot, 'build', 'tree_core.exe');
  final String agentPath =
      _arg(args, '--agent') ??
      p.join(repoRoot, 'build', 'plugins', 'tree_agent.exe');
  final File oldCore = File(oldCorePath);
  final File agentExe = File(agentPath);
  if (!oldCore.existsSync()) {
    stderr.writeln('[setup] 找不到旧核心：${oldCore.path}');
    stderr.writeln('        用 --old-core 指定 A5 前构建（含旧领域实现）。');
    exitCode = 2;
    return;
  }
  if (!agentExe.existsSync()) {
    stderr.writeln('[setup] 找不到 tree.agent 插件：${agentExe.path}');
    stderr.writeln(
      '        先构建：dart run tool/build_plugins.dart --only tree.agent',
    );
    exitCode = 2;
    return;
  }

  final Directory temp = Directory.systemTemp.createTempSync('tree_h1_write_');
  final Directory oldDir = Directory(p.join(temp.path, 'old'))..createSync();
  final Directory newDir = Directory(p.join(temp.path, 'new'))..createSync();
  final Stopwatch watch = Stopwatch()..start();
  _Server? oldSide;
  _Server? newSide;
  try {
    _seedData(oldDir);
    _seedData(newDir);
    final ProcessResult oldVersion = await Process.run(oldCore.path, <String>[
      '--version',
    ]);
    stdout.writeln(
      '[setup] 旧核心：${oldCore.path}'
      '（--version → ${oldVersion.stdout.toString().trim()}）',
    );
    stdout.writeln('[setup] 新核心：package:tree_core + ${agentExe.path}');
    stdout.writeln('[setup] 临时数据根：${temp.path}');

    oldSide = await _OldCore.start(oldCore, oldDir, repoRoot);
    newSide = await _NewCore.start(newDir, agentExe.path);
    stdout.writeln('[setup] 旧核心 :${oldSide.port} / 新核心 :${newSide.port}，插件已就绪');

    final _Checker checker = _Checker(
      oldSide: oldSide,
      newSide: newSide,
      roots: <String>[oldDir.path, newDir.path],
    );
    await _runCases(checker);

    final List<_Result> planned = checker.results
        .where((_Result r) => !r.supplementary)
        .toList();
    final List<_Result> extra = checker.results
        .where((_Result r) => r.supplementary)
        .toList();
    final int plannedFailed = planned.where((_Result r) => !r.equal).length;
    final int extraFailed = extra.where((_Result r) => !r.equal).length;
    final int failed = plannedFailed + extraFailed;
    stdout.writeln('');
    stdout.writeln('=== H1 写路由 HTTP 对照汇总 ===');
    stdout.writeln(
      '计划覆盖：${planned.length}/24 条（19 写 + 5 既有只读）'
      '；一致 ${planned.length - plannedFailed}；不一致 $plannedFailed',
    );
    if (extra.isNotEmpty) {
      stdout.writeln(
        '补充验证：${extra.length} 条；一致 ${extra.length - extraFailed}；'
        '不一致 $extraFailed',
      );
    }
    stdout.writeln(
      '跳过：POST /api/agents/{agentId}/messages、cancel'
      '（C-08 新增，旧核心无参考侧）',
    );
    stdout.writeln('耗时：${watch.elapsed.inMilliseconds}ms');
    if (planned.length < 24) {
      stderr.writeln('[result] 计划仅覆盖 ${planned.length}/24 条');
      exitCode = 1;
    } else if (failed > 0) {
      stderr.writeln(
        '[result] 存在 $failed 条差异（计划 $plannedFailed / 补充 $extraFailed）',
      );
      exitCode = 1;
    } else {
      stdout.writeln('[OK] 24/24 条 status / Content-Type / body 一致');
    }
  } on _SetupFailure catch (error) {
    stderr.writeln('[setup] ${error.message}');
    exitCode = 2;
  } catch (error, stack) {
    stderr.writeln('[fatal] $error');
    stderr.writeln('$stack');
    exitCode = 2;
  } finally {
    await oldSide?.close();
    await newSide?.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发文件占用：留给系统清理，不影响结论。
    }
  }
}

Future<void> _runCases(_Checker c) async {
  // ── 5 条此前不在旧双跑表里的 GET（同属 G-1 的 24 条） ──────────────
  await c.check('GET questions', 'GET', '/api/questions');
  await c.check(
    'GET teammate log',
    'GET',
    '/api/agents/$kTopAgent/teammate/$kMemberAgent/log',
  );
  await c.check('GET specs', 'GET', '/api/agents/$kTopAgent/specs');
  await c.check(
    'GET spec detail（不存在）',
    'GET',
    '/api/agents/$kTopAgent/specs/no-such-spec',
  );
  await c.check(
    'GET subagent transcript（不存在）',
    'GET',
    '/api/agents/$kTopAgent/subagents/sub_nope/transcript',
  );

  // ── 模型池写（3） ──────────────────────────────────────────────────
  await c.check(
    'POST model',
    'POST',
    '/api/models',
    body: <String, dynamic>{
      'model_id': 'm_write',
      'name': '写模型',
      'base_url': kFastFailBaseUrl,
      'api_key': 'sk-write',
      'thinking': false,
      'if_vision': false,
      'reasoning_effort': 'low',
      'reasoning_effort_options': <String>['low', 'high'],
      'max_seqlen': 16000,
      'max_output_tokens': 2048,
    },
  );
  await c.check(
    'PATCH model',
    'PATCH',
    '/api/models/m_write',
    body: <String, dynamic>{
      'name': '写模型改',
      'base_url': 'http://127.0.0.1:2/v1',
      'api_key': 'sk-write-2',
      'max_output_tokens': 4096,
    },
  );
  await c.check('DELETE model', 'DELETE', '/api/models/m_write');

  // ── 传输设置写（1） ───────────────────────────────────────────────
  await c.check(
    'POST token-rate',
    'POST',
    '/api/settings/token-rate',
    body: <String, dynamic>{'token_rate': 77},
  );

  // ── 运行监督写（1） ───────────────────────────────────────────────
  await c.check(
    'POST tools-running close（失效句柄）',
    'POST',
    '/api/tools/running/toolrun_1_abcd_1/close',
  );

  // ── agent 定义写（3）：create → patch → delete ────────────────────
  final _Pair created = await c.checkPair(
    'POST agent',
    'POST',
    '/api/agents',
    body: <String, dynamic>{
      'name': '写路由_创建',
      'system_prompt': '你是创建',
      'model_id': 'm1',
      'team_member_count': 0,
      'max_level': 3,
      'max_members_per_level': 7,
    },
  );
  c.record('POST agent', created);
  final String? oldCreated = _createdAgentId(created.old);
  final String? newCreated = _createdAgentId(created.newReply);
  if (oldCreated == null || newCreated == null) {
    throw const _SetupFailure(
      'POST /api/agents 未返回 agent.id，无法继续 PATCH/DELETE',
    );
  }
  c.ids[oldCreated] = '<created-agent>';
  c.ids[newCreated] = '<created-agent>';
  await c.check(
    'PATCH agent',
    'PATCH',
    '/api/agents/$oldCreated',
    newPath: '/api/agents/$newCreated',
    body: <String, dynamic>{
      'system_prompt': '更新后的提示词',
      'model_id': 'm2',
      'max_seqlen': 32000,
      'compress_threshold': 0.75,
      'thinking': false,
    },
  );
  await c.check(
    'DELETE agent',
    'DELETE',
    '/api/agents/$oldCreated?cascade=1',
    newPath: '/api/agents/$newCreated?cascade=1',
  );

  // ── 会话写（4）：create → patch → specs → delete ──────────────────
  await c.check(
    'POST session',
    'POST',
    '/api/agents/$kTopAgent/sessions',
    body: <String, dynamic>{'title': '写路由会话', 'session_id': 'ses_write'},
  );
  await c.check(
    'PATCH session',
    'PATCH',
    '/api/agents/$kTopAgent/sessions/ses_write',
    body: <String, dynamic>{'title': '写路由会话改'},
  );
  await c.check(
    'POST session specs',
    'POST',
    '/api/agents/$kTopAgent/sessions/ses_write/specs',
    body: <String, dynamic>{
      'spec_ids': <String>['general-task'],
    },
  );
  await c.check(
    'DELETE session',
    'DELETE',
    '/api/agents/$kTopAgent/sessions/ses_write',
  );

  // ── 历史 / 提问 / 团队 / 维护写（8） ─────────────────────────────
  await c.check(
    'DELETE conversation',
    'DELETE',
    '/api/conversations/$kTopAgent?session_id=$kDefaultSession',
  );
  await c.check(
    'POST question answer',
    'POST',
    '/api/questions/$kQuestionId/answer',
    body: <String, dynamic>{
      'answers': <String>['要'],
    },
  );
  await c.check(
    'PATCH teammate',
    'PATCH',
    '/api/agents/$kTopAgent/teammate/$kMemberAgent',
    body: <String, dynamic>{'model_id': 'm2', 'max_seqlen': 32000},
  );
  await c.check(
    'POST teammate message',
    'POST',
    '/api/agents/$kTopAgent/teammate/$kMemberAgent/message',
    body: <String, dynamic>{'content': '把日志发我', 'session_id': kDefaultSession},
  );
  await c.check(
    'POST compact',
    'POST',
    '/api/agents/$kTopAgent/compact',
    body: <String, dynamic>{'session_id': kDefaultSession},
  );
  await c.check(
    'POST reset',
    'POST',
    '/api/agents/$kTopAgent/reset',
    body: <String, dynamic>{'target': 'all'},
  );
  await c.check(
    'POST ssh reconnect（未配置 SSH）',
    'POST',
    '/api/agents/$kTopAgent/ssh/reconnect',
  );
  await c.check(
    'POST compact（空 agent，补充）',
    'POST',
    '/api/agents/$kEmptyAgent/compact',
    body: <String, dynamic>{'session_id': kDefaultSession},
    supplementary: true,
  );
  await c.check(
    'POST reset（空 agent，补充）',
    'POST',
    '/api/agents/$kEmptyAgent/reset',
    body: <String, dynamic>{'target': 'spec'},
    supplementary: true,
  );
}

String? _createdAgentId(_HttpReply reply) {
  final Object? json = reply.json;
  if (json is! Map) return null;
  final Object? agent = json['agent'];
  if (agent is! Map) return null;
  final Object? id = agent['id'];
  return id is String && id.isNotEmpty ? id : null;
}

// ─────────────────────────── 种子 ───────────────────────────

void _seedData(Directory dir) {
  final TreePaths paths = TreePaths(dir.path);
  Directory(paths.modelsDir).createSync(recursive: true);
  _writeYaml(File(paths.modelFile('m1')), <String, dynamic>{
    'model_id': 'm1',
    'name': '模型一',
    'base_url': kFastFailBaseUrl,
    'api_key': 'sk-m1',
    'thinking': false,
    'if_vision': false,
    'reasoning_effort': 'high',
    'reasoning_effort_options': <String>['low', 'high', 'max'],
    'max_seqlen': 64000,
    'max_output_tokens': 8192,
    'token_scale': 2.0,
    'longest_session_tokens': 0,
  });
  _writeYaml(File(paths.modelFile('m2')), <String, dynamic>{
    'model_id': 'm2',
    'name': '模型二',
    'base_url': kFastFailBaseUrl,
    'api_key': 'sk-m2',
    'thinking': false,
    'if_vision': false,
    'reasoning_effort': 'low',
    'reasoning_effort_options': <String>['low', 'high'],
    'max_seqlen': 32000,
    'max_output_tokens': 4096,
    'token_scale': 2.0,
    'longest_session_tokens': 0,
  });

  Directory(paths.agentsDir).createSync(recursive: true);
  final String wsTop = p.join(dir.path, 'workspaces', kTopAgent);
  final String wsMember = p.join(dir.path, 'workspaces', kMemberAgent);
  final String wsEmpty = p.join(dir.path, 'workspaces', kEmptyAgent);
  Directory(p.join(wsTop, '.self', 'spec')).createSync(recursive: true);
  Directory(p.join(wsMember, '.self')).createSync(recursive: true);
  Directory(p.join(wsEmpty, '.self', 'spec')).createSync(recursive: true);
  File(p.join(wsTop, '.self', 'system_prompt.md'))
      .writeAsStringSync('你是自定义提示词\n');
  File(p.join(wsMember, '.self', 'activity.log'))
      .writeAsStringSync('[10:00:00] 第一行\n[10:00:01] 第二行\n');
  _writeYaml(
    File(paths.agentFile(kTopAgent)),
    _agentYaml(
      id: kTopAgent,
      name: '拓扑',
      systemPrompt: '你是拓扑',
      modelId: 'm1',
      workspaceDir: wsTop,
    ),
  );
  _writeYaml(
    File(paths.agentFile(kMemberAgent)),
    _agentYaml(
      id: kMemberAgent,
      name: '前端',
      systemPrompt: '你是前端',
      modelId: 'm1',
      teamId: kTopAgent,
      parentAgentId: kTopAgent,
      level: 1,
      role: '前端',
      duty: '跑测试',
      canLeadTeam: false,
      reviewStatus: 'approved',
    ),
  );
  _writeYaml(
    File(paths.agentFile(kEmptyAgent)),
    _agentYaml(
      id: kEmptyAgent,
      name: '空 agent',
      systemPrompt: '你是空 agent',
      modelId: 'm1',
      workspaceDir: wsEmpty,
    ),
  );

  final String sessionDir = paths.sessionDir(kTopAgent, kDefaultSession);
  Directory(sessionDir).createSync(recursive: true);
  File(paths.sessionMetaFile(kTopAgent, kDefaultSession)).writeAsStringSync(
    jsonEncode(<String, dynamic>{
      'session_id': kDefaultSession,
      'agent_id': kTopAgent,
      'title': '默认会话',
      'status': 'active',
      'selected_spec_ids': <String>[],
      'compacted_summary': '',
      'compacted_message_count': 0,
      'created_at': '2026-10-25T10:00:00.000',
      'updated_at': '2026-10-25T10:00:00.000',
    }),
  );
  File(paths.messagesFile(kTopAgent, kDefaultSession)).writeAsStringSync(
    '${<String>[
      jsonEncode(<String, dynamic>{'id': 'msg_seed_1', 'agent_id': kTopAgent, 'session_id': kDefaultSession, 'role': 'user', 'content': '你好', 'timestamp': '2026-10-25T10:00:01.000', 'kind': 'text'}),
      jsonEncode(<String, dynamic>{'id': 'msg_seed_2', 'agent_id': kTopAgent, 'session_id': kDefaultSession, 'role': 'agent', 'content': '收到', 'timestamp': '2026-10-25T10:00:02.000', 'kind': 'text'}),
    ].join('\n')}\n',
  );
  Directory(paths.sessionsDataDir).createSync(recursive: true);
  File(paths.questionsFile).writeAsStringSync(
    jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'qid': kQuestionId,
        'agent_id': kTopAgent,
        'team_id': '',
        'session_id': kDefaultSession,
        'is_member': false,
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'question': '选哪个',
            'options': <String>['A', 'B'],
          },
        ],
        'answers': <String>[''],
        'question': '选哪个',
        'options': <String>['A', 'B'],
        'answer': '',
        'status': 'pending',
        'created_at': 1761367200000,
        'answered_at': 0,
      },
    ]),
  );
}

Map<String, dynamic> _agentYaml({
  required String id,
  required String name,
  required String systemPrompt,
  required String modelId,
  String workspaceDir = '',
  String teamId = '',
  String parentAgentId = '',
  int level = 0,
  String role = '',
  String duty = '',
  bool canLeadTeam = true,
  String reviewStatus = '',
}) => <String, dynamic>{
  'id': id,
  'name': name,
  'system_prompt': systemPrompt,
  'model_id': modelId,
  'workspace_id': 'ws_$id',
  'workspace_dir': workspaceDir,
  'team_member_count': 0,
  'max_level': 3,
  'max_members_per_level': 7,
  'team_id': teamId,
  'parent_agent_id': parentAgentId,
  'level': level,
  'role': role,
  'duty': duty,
  'can_lead_team': canLeadTeam,
  'review_status': reviewStatus,
  'comment': '',
  'scores': <String, double>{},
  'reasoning_effort': '',
  'max_seqlen_override': 0,
  'max_output_tokens': 0,
  'compress_threshold': 0,
  'thinking_override': null,
  'created_at': '2026-10-25T10:00:00.000',
  'updated_at': '2026-10-25T10:00:00.000',
};

void _writeYaml(File file, Map<String, dynamic> data) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(YamlCodec.encode(data));
}

// ─────────────────────────── 检查器 ───────────────────────────

class _Checker {
  _Checker({required this.oldSide, required this.newSide, required this.roots});

  final _Server oldSide;
  final _Server newSide;
  final List<String> roots;
  final Map<String, String> ids = <String, String>{};
  final List<_Result> results = <_Result>[];

  Future<void> check(
    String name,
    String method,
    String path, {
    String? newPath,
    Map<String, dynamic>? body,
    bool supplementary = false,
  }) async {
    final _Pair pair = await checkPair(
      name,
      method,
      path,
      newPath: newPath,
      body: body,
      supplementary: supplementary,
    );
    record(name, pair, supplementary: supplementary);
  }

  void record(String name, _Pair pair, {bool supplementary = false}) {
    results.add(
      _Result(
        name,
        pair.old,
        pair.newReply,
        equal: pair.equal,
        supplementary: supplementary,
      ),
    );
  }

  Future<_Pair> checkPair(
    String name,
    String method,
    String path, {
    String? newPath,
    Map<String, dynamic>? body,
    bool supplementary = false,
  }) async {
    final _HttpReply oldReply = await oldSide.request(method, path, body);
    final _HttpReply newReply = await newSide.request(
      method,
      newPath ?? path,
      body,
    );
    final _View oldView = _view(oldReply, oldSide.port);
    final _View newView = _view(newReply, newSide.port);
    final bool equal =
        oldView.status == newView.status &&
        oldView.contentType == newView.contentType &&
        oldView.canonicalBody == newView.canonicalBody;
    final String tag = equal ? '[OK]' : '[DIFF]';
    stdout.writeln('$tag $name（$method ${newPath ?? path}）');
    stdout.writeln(
      '     status ${oldReply.status} / ${newReply.status}；'
      'content-type "${oldReply.contentType}" / "${newReply.contentType}"',
    );
    if (!equal) {
      if (oldView.status != newView.status) {
        stdout.writeln(
          '     status 不同：old=${oldView.status} new=${newView.status}',
        );
      }
      if (oldView.contentType != newView.contentType) {
        stdout.writeln(
          '     content-type 不同：old="${oldView.contentType}" '
          'new="${newView.contentType}"',
        );
      }
      if (oldView.canonicalBody != newView.canonicalBody) {
        final List<String> diffs = _diffPaths(oldView.body, newView.body);
        stdout.writeln('     body 差异（最多 20 处）：');
        for (final String diff in diffs.take(20)) {
          stdout.writeln('       - $diff');
        }
        stdout.writeln('     body（old，规范化）：');
        stdout.writeln(_pretty(oldView.body));
        stdout.writeln('     body（new，规范化）：');
        stdout.writeln(_pretty(newView.body));
      }
    }
    return _Pair(oldReply, newReply, equal: equal);
  }

  _View _view(_HttpReply reply, int port) {
    final Object? normalized = _normalize(reply.json ?? reply.text, roots, ids);
    return _View(
      status: reply.status,
      contentType: reply.contentType.trim().toLowerCase(),
      body: normalized,
      canonicalBody: _canonical(normalized),
      pretty: _pretty(normalized),
    );
  }

  String _pretty(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return '$value';
    }
  }
}

class _Result {
  _Result(
    this.name,
    this.old,
    this.newReply, {
    this.equal = true,
    this.supplementary = false,
  });
  final String name;
  final _HttpReply old;
  final _HttpReply newReply;
  final bool equal;
  final bool supplementary;
}

class _Pair {
  _Pair(this.old, this.newReply, {this.equal = true});
  final _HttpReply old;
  final _HttpReply newReply;
  final bool equal;
}

class _View {
  _View({
    required this.status,
    required this.contentType,
    required this.body,
    required this.canonicalBody,
    required this.pretty,
  });
  final int status;
  final String contentType;
  final Object? body;
  final String canonicalBody;
  final String pretty;
}

Object? _normalize(Object? value, List<String> roots, Map<String, String> ids) {
  if (value is Map) {
    final List<String> keys = value.keys.map((Object? k) => '$k').toList()
      ..sort();
    return <String, dynamic>{
      for (final String key in keys) key: _normalize(value[key], roots, ids),
    };
  }
  if (value is List) {
    return <Object?>[
      for (final Object? item in value) _normalize(item, roots, ids),
    ];
  }
  if (value is int && value > 1000000000000) return '<timestamp>';
  if (value is String) return _normalizeString(value, roots, ids);
  return value;
}

String _normalizeString(
  String input,
  List<String> roots,
  Map<String, String> ids,
) {
  String out = input.replaceAll('\\', '/');
  for (final String root in roots) {
    final String slashRoot = root.replaceAll('\\', '/');
    out = out.replaceAll(slashRoot, '<data-root>');
  }
  ids.forEach((String key, String value) {
    out = out.replaceAll(key, value);
  });
  out = out.replaceAll(
    RegExp(r'\b(?:agt|ses|sub|msg|ws|toolrun|q)_[A-Za-z0-9_]{8,}\b'),
    '<generated-id>',
  );
  out = out.replaceAll(
    RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?'),
    '<timestamp>',
  );
  out = out.replaceAll(RegExp(r'sk-[A-Za-z0-9_-]+'), '<secret>');
  return out;
}

List<String> _diffPaths(Object? oldValue, Object? newValue) {
  final List<String> out = <String>[];
  void walk(Object? oldNode, Object? newNode, String path) {
    if (out.length >= 100) return;
    if (oldNode is Map && newNode is Map) {
      final Set<String> keys = <String>{
        ...oldNode.keys.map((Object? k) => '$k'),
        ...newNode.keys.map((Object? k) => '$k'),
      };
      for (final String key in keys.toList()..sort()) {
        walk(oldNode[key], newNode[key], '$path.$key');
      }
      return;
    }
    if (oldNode is List && newNode is List) {
      final int max = oldNode.length > newNode.length
          ? oldNode.length
          : newNode.length;
      for (int i = 0; i < max; i++) {
        walk(
          i < oldNode.length ? oldNode[i] : null,
          i < newNode.length ? newNode[i] : null,
          '$path[$i]',
        );
      }
      return;
    }
    if (jsonEncode(oldNode) != jsonEncode(newNode)) {
      out.add('$path: ${jsonEncode(oldNode)} -> ${jsonEncode(newNode)}');
    }
  }

  walk(oldValue, newValue, r'$');
  return out;
}

String _canonical(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.map((Object? k) => '$k').toList()
      ..sort();
    return '{${keys.map((String k) => '$k:${_canonical(value[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map<Object?>(_canonical).join(',')}]';
  }
  return jsonEncode(value);
}

// ─────────────────────────── 进程/HTTP ───────────────────────────

abstract class _Server {
  int get port;
  Future<_HttpReply> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]);
  Future<void> close();
}

class _HttpReply {
  _HttpReply({
    required this.status,
    required this.contentType,
    required this.text,
    this.json,
  });
  final int status;
  final String contentType;
  final String text;
  final Object? json;
}

class _OldCore implements _Server {
  _OldCore._(this._process, this.port, this._token);

  final Process _process;
  @override
  final int port;
  final String _token;
  final HttpClient _http = HttpClient();

  static Future<_OldCore> start(
    File exe,
    Directory dataDir,
    String workingDir,
  ) async {
    final Process process = await Process.start(exe.path, <String>[
      '--data-dir',
      dataDir.path,
      '--no-heartbeat',
    ], workingDirectory: workingDir);
    final Completer<Map<String, dynamic>> handshake =
        Completer<Map<String, dynamic>>();
    final StreamSubscription<String> out = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          if (handshake.isCompleted) return;
          try {
            final Object? decoded = jsonDecode(line);
            if (decoded is Map<String, dynamic>) handshake.complete(decoded);
          } catch (_) {
            // 非 JSON 行不参与握手（旧核心理论上 stdout 只有一行）。
          }
        });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          if (line.contains('error') || line.contains('Error')) {
            stderr.writeln('[old-core] $line');
          }
        });
    Map<String, dynamic> ready;
    try {
      ready = await handshake.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      process.kill();
      await out.cancel();
      throw const _SetupFailure('旧核心 30s 内没有输出握手行（build/tree_core.exe 不可用）');
    }
    final Object? portValue = ready['port'];
    final Object? tokenValue = ready['token'];
    if (portValue is! num || tokenValue is! String) {
      process.kill();
      throw const _SetupFailure('旧核心握手行缺少 port/token');
    }
    return _OldCore._(process, portValue.toInt(), tokenValue);
  }

  @override
  Future<_HttpReply> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) =>
      _httpRequest('http://127.0.0.1:$port', _token, method, path, body, _http);

  @override
  Future<void> close() async {
    try {
      _process.stdin.writeln('shutdown');
      await _process.stdin.flush();
    } catch (_) {}
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
    _http.close(force: true);
  }
}

class _NewCore implements _Server {
  _NewCore._(this._server);

  final CoreServer _server;
  final HttpClient _http = HttpClient();

  @override
  int get port => _server.port;
  String get _token => _server.token;

  static Future<_NewCore> start(Directory dataDir, String agentPath) async {
    final String configFile = p.join(dataDir.path, 'config', 'plugins.yaml');
    Directory(p.dirname(configFile)).createSync(recursive: true);
    File(configFile).writeAsStringSync(
      YamlCodec.encode(<String, dynamic>{
        'enabled': true,
        'plugins': <Map<String, dynamic>>[
          if (File(p.join(p.dirname(agentPath), 'tree_local_executor.exe')).existsSync())
            <String, dynamic>{
              'id': 'local_executor',
              'name': 'Local Executor',
              'command': p.join(p.dirname(agentPath), 'tree_local_executor.exe'),
              'args': <String>[],
              'granularity': 'team',
              'scope': <String, dynamic>{},
            },
          <String, dynamic>{
            'id': 'tree.agent',
            'name': 'Tree Agent',
            'command': agentPath,
            'args': <String>[],
            'granularity': 'team',
            'scope': <String, dynamic>{},
            'requires': <String, dynamic>{
              'plugins': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'local_executor'},
              ],
            },
          },
        ],
      }),
    );
    final PluginBus bus = PluginBus(
      configFile: configFile,
      coreVersion: 'verify',
      heartbeatInterval: const Duration(seconds: 30),
      missThreshold: 3,
    );
    final CoreServer server = await CoreServer.start(
      dataDir: dataDir.path,
      enableHeartbeat: false,
      pluginBus: bus,
    );
    await bus.start();
    final _NewCore side = _NewCore._(server);
    await side._waitReady();
    return side;
  }

  Future<void> _waitReady() async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final _HttpReply reply = await request('GET', '/api/meta');
        final Object? routes = reply.json is Map
            ? (reply.json as Map)['routes']
            : null;
        if (routes is List && routes.length >= 38) return;
      } catch (_) {
        // 核心刚起时端口可能还没可连；继续轮询。
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const _SetupFailure('tree.agent 插件 30s 内未就绪（/api/meta 未见 38 条委派路由）');
  }

  @override
  Future<_HttpReply> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) =>
      _httpRequest('http://127.0.0.1:$port', _token, method, path, body, _http);

  @override
  Future<void> close() async {
    await _server.close();
    _http.close(force: true);
  }
}

Future<_HttpReply> _httpRequest(
  String baseUrl,
  String token,
  String method,
  String path,
  Map<String, dynamic>? body,
  HttpClient client,
) async {
  final Uri uri = Uri.parse('$baseUrl$path');
  final HttpClientRequest request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  if (body != null) {
    final List<int> bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    // 显式 contentLength：否则 HttpClient 走 chunked（length=-1），核心会把
    // 请求体落到 body_path，而 tree.agent 的写路由只读 body（插件的已知缺口）。
    request.contentLength = bytes.length;
    request.add(bytes);
  }
  final HttpClientResponse response = await request.close().timeout(
    const Duration(seconds: 20),
  );
  final String text = await utf8.decoder
      .bind(response)
      .join()
      .timeout(const Duration(seconds: 20));
  final String contentType = response.headers.contentType?.toString() ?? '';
  Object? json;
  if (text.trim().isNotEmpty) {
    try {
      json = jsonDecode(text);
    } catch (_) {
      json = null;
    }
  }
  return _HttpReply(
    status: response.statusCode,
    contentType: contentType,
    text: text,
    json: json,
  );
}

class _SetupFailure implements Exception {
  const _SetupFailure(this.message);
  final String message;
}

String _defaultRepoRoot() {
  for (final String candidate in <String>[
    p.normalize(p.join(Directory.current.path, '..', '..')),
    Directory.current.path,
  ]) {
    if (File(p.join(candidate, 'build', 'tree_core.exe')).existsSync()) {
      return candidate;
    }
  }
  return p.normalize(p.join(Directory.current.path, '..', '..'));
}

String? _arg(List<String> args, String name) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
