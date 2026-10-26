/// G-1 **插件路由申报校验 + 冒烟**工具（A5 重写）。
///
/// 为什么重写：A5 把 agent / llm / tool / team / files / spec / terminal 七个领域
/// 目录整体移交插件后，核心不再实现这些路由，旧版"核心 HTTP vs 插件 api/delegate
/// 双跑逐字节对照"已经没有参考侧。本工具改为**只对 tree.agent 插件**做两件事：
///
///   1. **申报校验**：拉起插件 → hello → 读收集站
///      `system.collect.api.routes` 的申报，与下方 [kExpectedRoutes]、协议包
///      [ApiPaths.delegated] 及静态申报规则逐条对照；
///   2. **路由冒烟**：经插件 `api/delegate` 打一条真实只读路由
///      （`GET /api/agents`），断言状态码与 JSON 形状——证明申报之外，委派
///      管道也真的能把请求送进插件实现。
///
/// 任何不一致都打印可读原因并以非 0 退出（可进 CI；不静默跳过）。
///
/// 用法（在 `packages/tree_core` 下）：
///   dart run tool/verify_agent_equivalence.dart
///   dart run tool/verify_agent_equivalence.dart --exe ../../build/plugins/tree_agent.exe
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_protocol/tree_protocol.dart';

/// tree.agent 应申报的委派路由（39 条 = 36 条 G-1 + 2 条 C-08 上行 + 1 条执行器激活）。
///
/// 与插件仓 `lib/tree_agent_loop.dart` 的 `kDeclaredRoutes` 逐条对应；这里是
/// **核心侧验收口径**：插件多报、少报、报核心永久面都会失败。
const List<String> kExpectedRoutes = <String>[
  // A2 只读面（12）。
  'GET /api/agents',
  'GET /api/conversations/{agentId}',
  'GET /api/agents/{agentId}',
  'GET /api/agents/{agentId}/sessions',
  'GET /api/agents/{agentId}/sessions/{sessionId}',
  'GET /api/agents/{agentId}/teammates',
  'GET /api/agents/{agentId}/todos',
  'GET /api/agents/{agentId}/subagents',
  'GET /api/models',
  'GET /api/agents/{agentId}/models-info',
  'GET /api/tools/running',
  'GET /api/settings/token-rate',
  // agent 定义写接口 + 临时员工 transcript（4）。
  'POST /api/agents',
  'PATCH /api/agents/{agentId}',
  'DELETE /api/agents/{agentId}',
  'GET /api/agents/{agentId}/subagents/{subagentId}/transcript',
  // C-08 新增上行（2）：核心不存在旧实现，行为由插件自检覆盖。
  'POST /api/agents/{agentId}/messages',
  'POST /api/agents/{agentId}/cancel',
  // 运行监督（2）。
  'POST /api/tools/running/{handle}/close',
  // 模型池写接口 + token 节奏（5）。
  'POST /api/models',
  'PATCH /api/models/{modelId}',
  'DELETE /api/models/{modelId}',
  'POST /api/settings/token-rate',
  // 会话 / 历史 / 提问（8）。
  'POST /api/agents/{agentId}/sessions',
  'PATCH /api/agents/{agentId}/sessions/{sessionId}',
  'DELETE /api/agents/{agentId}/sessions/{sessionId}',
  'POST /api/agents/{agentId}/sessions/{sessionId}/specs',
  'DELETE /api/conversations/{agentId}',
  'GET /api/questions',
  'POST /api/questions/{qid}/answer',
  // 团队写 / 维护 / spec（8）。
  'PATCH /api/agents/{leaderId}/teammate/{memberId}',
  'POST /api/agents/{leaderId}/teammate/{memberId}/message',
  'GET /api/agents/{leaderId}/teammate/{memberId}/log',
  'POST /api/agents/{agentId}/compact',
  'POST /api/agents/{agentId}/reset',
  'POST /api/agents/{agentId}/ssh/reconnect',
  // 执行器激活（1）：UI 开终端前真建连，非 G-1 契约。
  'POST /api/agents/{agentId}/activate',
  'GET /api/agents/{agentId}/specs',
  'GET /api/agents/{agentId}/specs/{specId}',
];

/// **已知协议包笔误**（本任务不改 tree_protocol，只登记不掩盖）：
/// `ApiPaths.teammateLog` 的第一个占位符写成了 `{memberId}`（应为 `{leaderId}`），
/// 与插件按契约文档申报的 `GET /api/agents/{leaderId}/teammate/{memberId}/log`
/// 不相等。校验时把这条按等价键放行并打印 WARN；协议包修正后删掉本表。
const Map<String, String> kKnownProtocolPatternDrift = <String, String>{
  'GET /api/agents/{leaderId}/teammate/{memberId}/log':
      'GET /api/agents/{memberId}/teammate/{memberId}/log',
};

Future<void> main(List<String> args) async {
  final String? exe = _resolveExe(_arg(args, '--exe'));
  if (exe == null) {
    stderr.writeln(
      '[verify] 找不到插件产物。先构建：dart run tool/build_plugins.dart --only tree.agent',
    );
    exitCode = 2;
    return;
  }
  stdout.writeln('[verify] 插件产物：$exe');

  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_agent_verify_',
  );
  final Process process = await Process.start(exe, const <String>[]);
  final StreamIterator<String> iterator = StreamIterator<String>(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  try {
    Future<Map<String, dynamic>> waitForId(int id) async {
      while (await iterator.moveNext()) {
        final Map<String, dynamic> message =
            jsonDecode(iterator.current) as Map<String, dynamic>;
        if (message['id'] == id) return message;
      }
      throw StateError('插件 stdout 提前关闭（期待 id=$id）');
    }

    void send(Map<String, dynamic> frame) {
      // 不并发调用 stdin.flush()：IOSink 的 flush 会占据 sink 的流绑定，
      // 连续 send 时后一次 writeln 可能撞上 `StreamSink is bound to a stream`。
      process.stdin.writeln(jsonEncode(frame));
    }

    // ① hello：证明插件宿主链路可用。
    send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'hello',
      'params': <String, dynamic>{'plugin_id': 'tree.agent'},
    });
    await waitForId(1);

    // ② 读申报表。
    send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'station/request',
      'params': <String, dynamic>{
        'station_id': 'system.collect.api.routes',
        'payload': <String, dynamic>{},
      },
    });
    final Map<String, dynamic> reply = await waitForId(2);
    final Object? rawRoutes = reply['result']?['reply']?['payload']?['routes'];
    if (rawRoutes is! List) {
      stderr.writeln('[verify] 收集站回包缺少 routes 列表：${reply['result']}');
      exitCode = 1;
      return;
    }

    final List<String> declared = <String>[];
    for (final Object? item in rawRoutes) {
      if (item is! Map) {
        stderr.writeln('[verify] 路由申报项不是对象：$item');
        exitCode = 1;
        return;
      }
      declared.add('${item['method']} ${item['pattern']}');
    }

    final List<String> failures = _checkDeclarations(declared);
    if (failures.isNotEmpty) {
      for (final String failure in failures) {
        stderr.writeln('[FAIL] 申报：$failure');
      }
      exitCode = 1;
      return;
    }
    stdout.writeln(
      '[OK] 申报：${declared.length} 条与 kExpectedRoutes 完全一致，'
      '且全部落在 ApiPaths.delegated 内',
    );

    // ③ 冒烟：真走一次 api/delegate（只读、无副作用）。
    send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'api/delegate',
      'params': <String, dynamic>{
        'method': 'GET',
        'path': '/api/agents',
        'params': <String, dynamic>{},
        'query': <String, dynamic>{},
        'headers': <String, dynamic>{},
        'scope': <String, dynamic>{'agent_id': ''},
        'workspace_dir': '',
        'data_dir': temp.path,
        'agent_id': '',
        'team_id': '',
        'request_id': 'verify-1',
      },
    });
    final Map<String, dynamic> delegated = await waitForId(3);
    final String? smokeFailure = _checkSmoke(delegated);
    if (smokeFailure != null) {
      stderr.writeln('[FAIL] 冒烟 GET /api/agents：$smokeFailure');
      exitCode = 1;
      return;
    }
    stdout.writeln('[OK] 冒烟：GET /api/agents 经 api/delegate 返回 200 + 合法 JSON');
  } finally {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    await iterator.cancel();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发文件占用：临时目录留给系统清理，不影响结论。
    }
  }
}

/// 申报表的三条不变量；返回空列表 = 通过。
List<String> _checkDeclarations(List<String> declared) {
  final List<String> failures = <String>[];
  final Set<String> actual = declared.toSet();
  final Set<String> expected = kExpectedRoutes.toSet();

  final List<String> missing = expected.difference(actual).toList()..sort();
  if (missing.isNotEmpty) {
    failures.add('缺少应申报路由：$missing');
  }
  final List<String> extra = actual.difference(expected).toList()..sort();
  if (extra.isNotEmpty) {
    failures.add('多出未在验收表内的申报：$extra');
  }
  // 断言里不可能出现，但先按集合口径防重复（重复申报会被核心整组拒收）。
  if (actual.length != declared.length) {
    failures.add('存在重复申报（${declared.length} 行 / ${actual.length} 个键）');
  }

  for (final String route in actual) {
    final int space = route.indexOf(' ');
    if (space <= 0) {
      failures.add('申报格式不是 "METHOD pattern"：$route');
      continue;
    }
    final String method = route.substring(0, space);
    final String pattern = route.substring(space + 1);
    if (!ApiPaths.delegated.contains(ApiPaths.routeKey(method, pattern))) {
      final String? equivalent = kKnownProtocolPatternDrift[route];
      if (equivalent == null || !ApiPaths.delegated.contains(equivalent)) {
        failures.add('$route 不在协议包 ApiPaths.delegated 契约内');
      } else {
        stdout.writeln(
          '[WARN] $route 与协议包常量占位符不一致（已知笔误），'
          '按 $equivalent 登记为契约内',
        );
      }
    }
    final String? staticError = ApiPaths.delegationKeyError(method, pattern);
    if (staticError != null) {
      failures.add('$route 通不过静态申报规则：$staticError');
    }
  }
  return failures;
}

/// 冒烟回包校验；返回 null = 通过。
String? _checkSmoke(Map<String, dynamic> delegated) {
  if (delegated['error'] != null) {
    return '插件返回 error：${delegated['error']}';
  }
  final Object? result = delegated['result'];
  if (result is! Map) return 'result 不是对象：$result';
  final int status = (result['status'] as num?)?.toInt() ?? -1;
  if (status != 200) return '状态码是 $status（期望 200）';
  final Object? body = result['body'];
  if (body is! String || body.trim().isEmpty) {
    return 'body 不是非空字符串';
  }
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map || decoded['agents'] is! List) {
    return 'body 不是含 agents 列表的 JSON 对象：$body';
  }
  return null;
}

String? _resolveExe(String? explicit) {
  if (explicit != null && explicit.trim().isNotEmpty) {
    final String path = p.normalize(p.absolute(explicit.trim()));
    return File(path).existsSync() ? path : null;
  }
  for (final String name in <String>['tree_agent.exe', 'tree_agent']) {
    for (final String candidate in <String>[
      p.join(Directory.current.path, '..', '..', 'build', 'plugins', name),
      p.join(Directory.current.path, 'build', 'plugins', name),
    ]) {
      final String path = p.normalize(candidate);
      if (File(path).existsSync()) return path;
    }
  }
  return null;
}

String? _arg(List<String> args, String name) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
