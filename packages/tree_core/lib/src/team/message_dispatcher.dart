import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../store/atomic_file.dart';
import '../store/tree_store.dart';
import 'team_model.dart';
import 'team_service.dart';

/// 到点投递一个 agent 消息的实现（生产环境是 `ConversationService.deliver`）。
typedef TeamDelivery = Future<void> Function({
  required String agentId,
  required String sessionId,
  required String content,
  String senderId,
  String senderName,
});

/// 单目标投递结果。
class DeliveryResult {
  const DeliveryResult({
    required this.target,
    required this.status,
    this.id = '',
    this.name = '',
    this.type = '',
    this.reason = '',
  });

  final String target;

  /// `sent` / `rejected`。
  final String status;
  final String id;
  final String name;
  final String type;
  final String reason;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'target': target,
    'id': id,
    'name': name,
    'type': type,
    'status': status,
    if (reason.isNotEmpty) 'reason': reason,
  };
}

/// 团队消息派发（M5c）：把 leader/成员的消息投给队友，并在**派发前**过审核闸门。
///
/// 与参考实现的 `TeamMessageBroker` 的关系：
/// - 串行与队列语义由 `ConversationService` 的"按 agent 串行链 + stop 代次"承担，
///   这里只做**寻址、闸门、活动日志**；
/// - 投递**不阻塞**（参考实现同样立即返回 `sent`）；要等结果用 `wait_for`；
/// - **无静默回传**：成员正常完成不会自动发给任何人，只有"未就绪/模型缺失"这类
///   错误才会以 auto_reply 回到 agent 发送方。
class TeamMessageDispatcher {
  TeamMessageDispatcher({
    required this.store,
    required this.teams,
    required this.deliver,
    this.workspaceDirOf,
    this.activityLogPathOf,
    this.log,
    this.startGrace = const Duration(seconds: 5),
    this.pollInterval = const Duration(seconds: 2),
    this.maxFileBytes = 32 * 1024 * 1024,
  });

  final TreeStore store;
  final TeamService teams;

  /// 投递实现（核心服务注入）。
  final TeamDelivery deliver;

  /// agent 的**本地**工作空间目录；返回空串表示该 agent 的工作空间不在本机。
  final String Function(String agentId)? workspaceDirOf;

  /// 活动日志绝对路径（覆盖默认的 `<工作空间>/.self/activity.log`）。
  final String Function(String agentId)? activityLogPathOf;

  final void Function(String message)? log;

  /// `wait_for` 的启动宽限（这段时间内没观测到 working 就记 never_started）。
  final Duration startGrace;

  /// `wait_for` 的轮询间隔。
  final Duration pollInterval;

  /// 单文件投递上限。
  final int maxFileBytes;

  static const List<String> actions = <String>[
    'send_message',
    'broadcast',
    'wait_for',
    'list_members',
    'list_teams',
  ];

  /// 工具入口（未知 action 返回可读错误）。
  Future<Map<String, dynamic>> run(
    String agentId,
    Map<String, dynamic> args,
  ) async {
    final String action = (args['action'] ?? '').toString().trim();
    switch (action) {
      case 'send_message':
        return sendMessage(agentId, args);
      case 'broadcast':
        return broadcast(agentId, args);
      case 'wait_for':
        return waitFor(agentId, args);
      case 'list_members':
        return teams.listMembers(agentId, args: args);
      case 'list_teams':
        return teams.listTeams(agentId);
      default:
        return <String, dynamic>{
          'error': '未知 action: $action',
          'hint': '本工具支持的 action：${(<String>[...actions]..sort()).join('、')}',
        };
    }
  }

  /// `send_message`：点对点（或一对多）派活/沟通。
  Future<Map<String, dynamic>> sendMessage(
    String agentId,
    Map<String, dynamic> args,
  ) async {
    final String message = (args['message'] ?? '').toString().trim();
    final List<String> rawTargets = _targets(args);
    if (rawTargets.isEmpty) {
      return <String, dynamic>{
        'error': '缺少 target_member_id（或 target_ids）',
        'hint': '请先 list_members 获取成员 ID/名称',
      };
    }
    if (message.isEmpty) {
      return <String, dynamic>{
        'error': '缺少 message',
        'hint': '消息内容不能为空；派活时写清工作内容与预期产出',
      };
    }
    final String sessionId = _sessionOf(args);
    final List<DeliveryResult> details = <DeliveryResult>[];
    final List<Map<String, dynamic>> unknown = <Map<String, dynamic>>[];
    for (final String raw in rawTargets) {
      final MessageTarget? target = teams.resolveMessageTarget(agentId, raw);
      if (target == null) {
        unknown.add(<String, dynamic>{
          'target': raw,
          'reason': teams.lastTargetReason,
        });
        continue;
      }
      details.add(
        await _deliverOne(
          senderId: agentId,
          target: target,
          content: message,
          sessionId: sessionId,
          files: _files(args),
          destDir: (args['dest_dir'] ?? '').toString(),
        ),
      );
    }
    final List<String> sent = details
        .where((DeliveryResult d) => d.status == 'sent')
        .map((DeliveryResult d) => d.id)
        .toList(growable: false);
    final List<Map<String, dynamic>> rejected = details
        .where((DeliveryResult d) => d.status != 'sent')
        .map(
          (DeliveryResult d) => <String, dynamic>{
            'id': d.id,
            'reason': d.reason,
          },
        )
        .toList(growable: false);
    final String status = sent.isEmpty
        ? 'error'
        : (rejected.isEmpty && unknown.isEmpty ? 'sent' : 'partial');
    return <String, dynamic>{
      'status': status,
      'message_id': 'msg_${DateTime.now().millisecondsSinceEpoch}',
      'details': details.map((DeliveryResult d) => d.toJson()).toList(),
      'sent': sent,
      'rejected': rejected,
      'unknown': unknown,
      if (unknown.isNotEmpty) 'hint': _unknownHint(unknown),
      if (rejected.isNotEmpty && unknown.isEmpty)
        'hint': '部分目标投递失败，可稍后重试或改用 list_members 核对成员状态',
      if (status == 'sent')
        'hint':
            '消息已投递，但系统不会替对方回传总结：如需对方回复，请在消息中明确要求，'
            '对方需自行 send_message 回发；若对方回发，只在有实质新信息或需要其决策时再回复，'
            '避免无内容的来回互发',
      'generated_at': _timestamp(),
    };
  }

  /// 用户直接给成员发消息（`POST /api/agents/{leaderId}/teammate/{memberId}/message`）。
  ///
  /// 与 [sendMessage] 的区别：**没有 agent 发送方**（senderId 为空），因此错误不会
  /// auto_reply 给任何人；投递仍要过审核闸门。
  Future<Map<String, dynamic>> sendFromUser({
    required String targetId,
    required String content,
    required String sessionId,
  }) async {
    if (content.trim().isEmpty) {
      return <String, dynamic>{'success': false, 'error': '缺少 content'};
    }
    final MessageTarget? target = teams.resolveMessageTarget(
      targetId,
      targetId,
    );
    if (target == null) {
      return <String, dynamic>{'success': false, 'error': '成员不存在: $targetId'};
    }
    final DeliveryResult result = await _deliverOne(
      senderId: '',
      target: target,
      content: content,
      sessionId: sessionId,
    );
    if (result.status == 'sent') {
      return <String, dynamic>{'success': true, 'detail': result.toJson()};
    }
    return <String, dynamic>{
      'success': false,
      'error': '投递失败（通道拒绝或未就绪）',
      'detail': result.toJson(),
    };
  }

  /// `broadcast`：只发给**直属**成员（不跨层级）。
  Future<Map<String, dynamic>> broadcast(
    String agentId,
    Map<String, dynamic> args,
  ) async {
    final String message = (args['message'] ?? '').toString().trim();
    if (message.isEmpty) {
      return <String, dynamic>{'error': '缺少 message', 'hint': '广播内容不能为空'};
    }
    final List<CoreAgent> recipients = teams.directMembers(agentId);
    if (recipients.isEmpty) {
      return <String, dynamic>{
        'status': 'no_recipients',
        'recipients': <String>[],
        'recipient_count': 0,
        'sent': <String>[],
        'rejected': <Map<String, dynamic>>[],
        'hint':
            '你当前没有直属成员，广播未发送给任何人。点对点沟通请用 send_message；'
            '若你刚创建成员，请先用 list_members 确认',
        'generated_at': _timestamp(),
      };
    }
    final String sessionId = _sessionOf(args);
    final List<DeliveryResult> details = <DeliveryResult>[];
    for (final CoreAgent member in recipients) {
      details.add(
        await _deliverOne(
          senderId: agentId,
          target: MessageTarget(
            id: member.id,
            name: member.name,
            type: 'member',
          ),
          content: message,
          sessionId: sessionId,
        ),
      );
    }
    final List<String> sent = details
        .where((DeliveryResult d) => d.status == 'sent')
        .map((DeliveryResult d) => d.id)
        .toList(growable: false);
    final List<Map<String, dynamic>> rejected = details
        .where((DeliveryResult d) => d.status != 'sent')
        .map(
          (DeliveryResult d) => <String, dynamic>{
            'id': d.id,
            'reason': d.reason,
          },
        )
        .toList(growable: false);
    return <String, dynamic>{
      'status': sent.isEmpty
          ? 'error'
          : (rejected.isEmpty ? 'broadcast' : 'partial'),
      'message_id': 'msg_${DateTime.now().millisecondsSinceEpoch}',
      'recipients': recipients.map((CoreAgent m) => m.id).toList(),
      'recipient_count': recipients.length,
      'sent': sent,
      'rejected': rejected,
      if (rejected.isNotEmpty)
        'hint':
            '${sent.length}/${recipients.length} 名直属成员投递成功，失败的成员可稍后用 send_message 单独重试',
      'generated_at': _timestamp(),
    };
  }

  /// `wait_for`：等成员做完（必须先观测到 working 再转 idle 才算 completed）。
  ///
  /// 为什么强调"先 working"：否则"消息还没被处理"会被误判成"已经做完了"，
  /// 这是最危险的假完成。参考实现用同一规则（START_GRACE + 只认 working→idle）。
  Future<Map<String, dynamic>> waitFor(
    String agentId,
    Map<String, dynamic> args,
  ) async {
    final List<String> rawTargets = _waitTargets(args);
    if (rawTargets.isEmpty) {
      return <String, dynamic>{
        'error': '缺少 target_member_ids',
        'hint': '请先用 list_members 获取成员 ID/名称，多个目标用逗号分隔',
      };
    }
    final List<CoreAgent> members = <CoreAgent>[];
    final List<String> missing = <String>[];
    for (final String raw in rawTargets) {
      final MessageTarget? target = teams.resolveMessageTarget(agentId, raw);
      final CoreAgent? member = target == null ? null : store.agent(target.id);
      if (member == null || member.teamId.isEmpty) {
        missing.add(raw);
        continue;
      }
      members.add(member);
    }
    if (missing.isNotEmpty) {
      return <String, dynamic>{
        'error': '以下成员不存在或不在本团队：${missing.join('、')}',
        'hint': '请用 list_members 核对成员 ID/名称（仅支持等待本团队成员）',
      };
    }
    final Duration timeout = _timeout(args);
    final DateTime started = DateTime.now();
    final Set<String> seenWorking = <String>{};
    bool timedOut = false;
    while (true) {
      for (final CoreAgent member in members) {
        if (teams.workStatus(member.id) == 'working') {
          seenWorking.add(member.id);
        }
      }
      final bool allDone = members.every(
        (CoreAgent m) =>
            seenWorking.contains(m.id) && teams.workStatus(m.id) != 'working',
      );
      if (allDone) break;
      final Duration elapsed = DateTime.now().difference(started);
      if (elapsed >= timeout) {
        timedOut = true;
        break;
      }
      // 宽限期内没等到 working：目标可能没接单或瞬间做完，不再空等
      final bool graceOver = elapsed >= startGrace;
      if (graceOver && seenWorking.isEmpty) break;
      await Future<void>.delayed(pollInterval);
    }
    final List<Map<String, dynamic>> views = <Map<String, dynamic>>[];
    final List<String> neverStarted = <String>[];
    final List<String> stillWorking = <String>[];
    for (final CoreAgent member in members) {
      final bool working = teams.workStatus(member.id) == 'working';
      final String outcome = seenWorking.contains(member.id) && !working
          ? 'completed'
          : (working
                ? 'working'
                : (seenWorking.contains(member.id)
                      ? 'working'
                      : 'never_started'));
      if (outcome == 'never_started') neverStarted.add(member.name);
      if (working) stillWorking.add(member.name);
      views.add(<String, dynamic>{
        'member_id': member.id,
        'name': member.name,
        'work_status': teams.workStatus(member.id),
        'outcome': outcome,
        'log_path': memberLogPath(member.id),
      });
    }
    return <String, dynamic>{
      'members': views,
      'timed_out': timedOut,
      'waited': DateTime.now().difference(started).inMilliseconds / 1000,
      'total': members.length,
      if (neverStarted.isNotEmpty)
        'hint':
            '以下成员在启动宽限内未观测到工作状态（可能未接单或已瞬间完成）：'
            '${neverStarted.join('、')}。请用 send_message 确认，或直接 read 其活动日志核实，'
            '不要直接假定任务完成',
      if (timedOut && stillWorking.isNotEmpty)
        'hint':
            '等待超时，以下成员仍在工作：${stillWorking.join('、')}。'
            '你可以结束本轮（无需继续 wait_for 轮询）：对方完成工作后**若主动回发消息**才会唤醒你，'
            '否则请稍后 read 其活动日志/产出核实，或自行 send_message 追问',
      'generated_at': _timestamp(),
    };
  }

  // ── 投递 ─────────────────────────────────────────────────────────────

  Future<DeliveryResult> _deliverOne({
    required String senderId,
    required MessageTarget target,
    required String content,
    required String sessionId,
    List<String> files = const <String>[],
    String destDir = '',
  }) async {
    final String? blocked = teams.reviewBlock(target.id);
    if (blocked != null) {
      // 消息**不静默丢弃**：写活动日志 + 向 agent 发送方回传原因（参考实现同语义）
      await _activity(target.id, '[blocked] 成员未就绪：$blocked，消息未处理');
      await _autoReply(
        senderId: senderId,
        sessionId: sessionId,
        content:
            '[成员 ${target.id} 无法处理消息] $blocked。'
            '消息已丢弃：${_preview(content)}',
      );
      return DeliveryResult(
        target: target.id,
        id: target.id,
        name: target.name,
        type: target.type,
        status: 'rejected',
        reason: '投递失败（通道拒绝或未就绪）',
      );
    }
    final Map<String, dynamic> copied = files.isEmpty
        ? <String, dynamic>{}
        : await _copyFiles(
            from: senderId,
            to: target.id,
            files: files,
            destDir: destDir,
          );
    final String finalBody = copied['note'] == null
        ? content
        : '$content\n\n${copied['note']}';
    await _activity(
      target.id,
      '[start(成员)] 收到 ${_nameOf(senderId)} 消息: ${_preview(content)}',
    );
    unawaited(
      deliver(
            agentId: target.id,
            sessionId: sessionId,
            content: finalBody,
            senderId: senderId,
            senderName: _nameOf(senderId),
          )
          .then((_) async {
            await _activity(target.id, '[done(成员)] 回复完成');
          })
          .catchError((Object error) async {
            await _activity(target.id, '[error] 成员处理失败: $error');
          }),
    );
    return DeliveryResult(
      target: target.id,
      id: target.id,
      name: target.name,
      type: target.type,
      status: 'sent',
    );
  }

  /// 错误回传到 **agent** 发送方；用户自己发的（senderId 为空）不回传。
  Future<void> _autoReply({
    required String senderId,
    required String sessionId,
    required String content,
  }) async {
    if (senderId.trim().isEmpty) return;
    final CoreAgent? sender = store.agent(senderId);
    if (sender == null) return;
    await _activity(sender.id, '[auto_reply] $content');
    unawaited(
      deliver(
        agentId: sender.id,
        sessionId: sessionId,
        content: content,
        senderId: '',
        senderName: '',
      ).catchError((Object _) {}),
    );
  }

  String _nameOf(String agentId) => store.agent(agentId)?.name ?? agentId;

  static String _preview(String content) =>
      content.length > 120 ? '${content.substring(0, 120)}…' : content;

  /// 活动日志（本地镜像；SSH 成员的工作空间不在本机时不写）。
  Future<void> _activity(String agentId, String line) async {
    final String? path = _activityPath(agentId);
    if (path == null) return;
    try {
      await AtomicFile.appendLine(path, line);
    } catch (error) {
      log?.call('写活动日志失败（$agentId）：$error');
    }
  }

  /// 活动日志路径（`GET teammateLog` 读的也是它）。
  String? activityLogPath(String agentId) => _activityPath(agentId);

  String? _activityPath(String agentId) {
    final String? explicit = activityLogPathOf?.call(agentId);
    if (explicit != null && explicit.trim().isNotEmpty) return explicit;
    final String dir = workspaceDirOf?.call(agentId) ?? '';
    if (dir.trim().isEmpty) return null;
    return p.join(dir, '.self', 'activity.log');
  }

  /// 文件投递：发送方工作空间 → 接收方 `.input/<日期>/`。
  ///
  /// 只支持**本机**工作空间：SSH 成员的工作空间在远端，复制必须走其 WorkspaceIO；
  /// 那种情况明确报错而不是悄悄复制到本机某个无关目录。
  Future<Map<String, dynamic>> _copyFiles({
    required String from,
    required String to,
    required List<String> files,
    required String destDir,
  }) async {
    final String fromDir = workspaceDirOf?.call(from) ?? '';
    final String toDir = workspaceDirOf?.call(to) ?? '';
    if (fromDir.trim().isEmpty || toDir.trim().isEmpty) {
      return <String, dynamic>{
        'note': '（附件未投递：文件投递仅支持本机工作空间的成员，SSH 成员请改用其远端路径）',
      };
    }
    final String target = p.join(
      toDir,
      destDir.trim().isEmpty ? p.join('.input', _dateStamp()) : destDir.trim(),
    );
    int copiedCount = 0;
    final List<String> failed = <String>[];
    for (final String relative in files) {
      try {
        final String raw = relative.trim();
        if (raw.isEmpty) continue;
        final String absolute = p.normalize(p.join(fromDir, raw));
        if (!p.isWithin(fromDir, absolute) && absolute != fromDir) {
          failed.add(raw);
          continue;
        }
        final File source = File(absolute);
        if (!source.existsSync() || source.lengthSync() > maxFileBytes) {
          failed.add(raw);
          continue;
        }
        await Directory(target).create(recursive: true);
        await source.copy(p.join(target, p.basename(absolute)));
        copiedCount++;
      } catch (_) {
        failed.add(relative);
      }
    }
    return <String, dynamic>{
      'note':
          '（附件已投递 $copiedCount 个到 ${p.relative(target, from: toDir)}'
          '${failed.isEmpty ? '）' : '；失败：${failed.join('、')}）'}',
      'files_copied': copiedCount,
      'files_failed': failed,
    };
  }

  static List<String> _targets(Map<String, dynamic> args) {
    final Object? single = args['target_member_id'];
    if (single != null && single.toString().trim().isNotEmpty) {
      return <String>[single.toString().trim()];
    }
    final Object? many = args['target_ids'];
    if (many is List<dynamic>) {
      return many
          .map((dynamic e) => e.toString().trim())
          .where((String e) => e.isNotEmpty)
          .toList(growable: false);
    }
    if (many is String && many.trim().isNotEmpty) {
      return many
          .split(',')
          .map((String e) => e.trim())
          .where((String e) => e.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  static List<String> _waitTargets(Map<String, dynamic> args) {
    final Object? raw = args['target_member_ids'] ?? args['target_ids'];
    if (raw is List<dynamic>) {
      return raw
          .map((dynamic e) => e.toString().trim())
          .where((String e) => e.isNotEmpty)
          .toList(growable: false);
    }
    final String text = (raw ?? '').toString();
    return text
        .split(',')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _files(Map<String, dynamic> args) {
    final Object? raw = args['files'];
    if (raw is List<dynamic>) {
      return raw
          .map((dynamic e) => e.toString())
          .where((String e) => e.trim().isNotEmpty)
          .toList(growable: false);
    }
    if (raw is String && raw.trim().isNotEmpty) return <String>[raw.trim()];
    return const <String>[];
  }

  String _sessionOf(Map<String, dynamic> args) {
    final String session = (args['session_id'] ?? '').toString().trim();
    return session.isEmpty ? TreeStore.defaultSessionId : session;
  }

  Duration _timeout(Map<String, dynamic> args) {
    final Object? raw = args['timeout'];
    final int seconds = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '') ?? 300;
    final int clamped = seconds.clamp(1, 600);
    return Duration(seconds: clamped);
  }

  static String _unknownHint(List<Map<String, dynamic>> unknown) {
    final bool crossTop = unknown.any(
      (Map<String, dynamic> u) => u['reason'] == 'cross_top_denied',
    );
    if (crossTop) {
      return '跨 TOP 顶层通信仅 TOP agent 之间可用；如需联系其他团队，'
          '请把内容发给你的直属 leader，由其 TOP 转达';
    }
    return '目标不存在或不可达：团队内按成员名称/id 寻址（先 list_members），'
        '跨 TOP 按 TOP 名称寻址（先 list_teams，且仅 TOP 自己可发起）';
  }

  static String _dateStamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  static String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}
