import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 一条落盘的后台（hook）任务台账。
///
/// 只记"重启后还能接续所必需"的信息：任务 id、归属（agent + 会话）、命令、日志相对
/// 路径、远端 pid、开始时刻。**哨兵路径不记**——它由日志路径按固定规则派生
/// （见 `SshWorkspaceIO.exitMarkerRelativePath`），少一个可能不一致的字段。
class HookLedgerEntry {
  const HookLedgerEntry({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.command,
    required this.logRelative,
    required this.startedAt,
    this.pid,
    this.failStreak = 0,
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String command;

  /// 日志的**工作空间相对路径**（远端那份）。
  final String logRelative;

  /// 远端包装子 shell 的 pid（拿不到为 null）。
  final int? pid;

  /// 开始时刻（epoch 毫秒）。
  final int startedAt;

  /// **连续接续失败次数**（2026-10-15 加）：这条台账每被 `restorePending` 接回来、
  /// 又一次以「失联 / 拿不到终态」收尾，就 +1。真实结局一旦可判（exited/gone/真退出码），
  /// `_finish` 会直接删台账、计数随之消失 —— 因此**只有"链路回来了却永远读不到结局"的僵尸**
  /// 才会把计数堆高。核心据此给僵尸一个上界，避免每次重启都无休止地重新唤醒（用户反馈的
  /// "hook 工具调用 + 延续声明、重启后又出现"）。老台账没有这个键 ⇒ 解析为 0（向后兼容）。
  final int failStreak;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'agent_id': agentId,
    'session_id': sessionId,
    'command': command,
    'log_relative': logRelative,
    'pid': pid,
    'started_at': startedAt,
    if (failStreak > 0) 'fail_streak': failStreak,
  };

  /// 解析一条台账；**接续必需的字段**不全才返回 null（调用方如实记日志并跳过，不假装读过）。
  ///
  /// 必需的是 [id] / [agentId] / [logRelative] —— 有这三样就能"找到任务、对上哨兵、继续对账"。
  ///
  /// **[sessionId] 允许为空**（2026-10-11 修）：执行站 / 无会话语境起出来的后台任务，
  /// 写出来就是空串（写入侧来自 `invocation.sessionId`）。读取侧要求非空 = **台账自己读不回来**，
  /// 真机症状是核心启动时刷 `后台任务台账形状不对，已跳过：hook_*.json`，
  /// 于是那些远端后台任务**永远不会被接回**（`restorePending` / 链路恢复认领都从 [load] 走）。
  static HookLedgerEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? agentId = raw['agent_id'];
    final Object? log = raw['log_relative'];
    if (id is! String || id.trim().isEmpty) return null;
    if (agentId is! String || agentId.trim().isEmpty) return null;
    if (log is! String || log.trim().isEmpty) return null;
    final Object? sessionId = raw['session_id'];
    final Object? pid = raw['pid'];
    final Object? startedAt = raw['started_at'];
    final Object? failStreak = raw['fail_streak'];
    return HookLedgerEntry(
      id: id,
      agentId: agentId,
      sessionId: sessionId is String ? sessionId : '',
      command: raw['command'] is String ? raw['command'] as String : '',
      logRelative: log,
      pid: pid is int && pid > 0 ? pid : null,
      startedAt: startedAt is int ? startedAt : 0,
      failStreak: failStreak is int && failStreak > 0 ? failStreak : 0,
    );
  }
}

/// **后台任务台账**（落盘）：让远端后台任务跨核心/应用重启**接续**。
///
/// 为什么落**本机数据根**（而不是工作空间内）：重启后可读性最稳（不依赖远端主机此刻
/// 可达、也不依赖 SSH 配置能不能建连）；工作空间在远端时，台账落远端就意味着"远端不可达
/// ⇒ 连'有个任务在跑'都不知道"。
///
/// 写入是**原子**的（临时文件 + rename）：半写的 json 在重启时会被当成损坏条目，
/// 那等于把一条正在跑的任务弄丢。读取对损坏条目**如实记日志并跳过**，不静默吞。
class HookLedger {
  HookLedger(this.dir, {this.log});

  /// 台账目录（`<data_root>/hooks`）。
  final String dir;

  /// 可读日志（生产接到 `core.log`）。
  final void Function(String message)? log;

  /// 写一条（同 id 覆盖：幂等）。失败只记日志——台账写不进去不该害死任务本身。
  Future<void> save(HookLedgerEntry entry) async {
    try {
      final Directory folder = Directory(dir);
      await folder.create(recursive: true);
      final String target = p.join(dir, '${_safeName(entry.id)}.json');
      final File temp = File('$target.tmp');
      await temp.writeAsString(jsonEncode(entry.toJson()), flush: true);
      await temp.rename(target);
    } catch (error) {
      log?.call('写后台任务台账失败（${entry.id}）：$error');
    }
  }

  /// 删一条（不存在不报错）。
  Future<void> remove(String id) async {
    try {
      final File file = File(p.join(dir, '${_safeName(id)}.json'));
      if (await file.exists()) await file.delete();
    } catch (error) {
      log?.call('删后台任务台账失败（$id）：$error');
    }
  }

  /// 读全部台账（按开始时刻升序）。损坏/半写的条目记日志后跳过。
  Future<List<HookLedgerEntry>> load() async {
    final List<HookLedgerEntry> out = <HookLedgerEntry>[];
    try {
      final Directory folder = Directory(dir);
      if (!await folder.exists()) return out;
      await for (final FileSystemEntity entity in folder.list()) {
        if (entity is! File || p.extension(entity.path) != '.json') continue;
        try {
          final Object? raw = jsonDecode(await entity.readAsString());
          final HookLedgerEntry? entry = HookLedgerEntry.fromJson(raw);
          if (entry == null) {
            log?.call('后台任务台账形状不对，已跳过：${p.basename(entity.path)}');
            continue;
          }
          out.add(entry);
        } catch (error) {
          log?.call('后台任务台账解析失败，已跳过（${p.basename(entity.path)}）：$error');
        }
      }
    } catch (error) {
      log?.call('读后台任务台账失败（$dir）：$error');
      return out;
    }
    out.sort(
      (HookLedgerEntry a, HookLedgerEntry b) => a.startedAt.compareTo(b.startedAt),
    );
    return out;
  }

  /// 任务 id 只含安全字符（`hook_<ms>_<n>`）；仍做一次兜底替换，避免越出台账目录。
  static String _safeName(String id) =>
      id.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
}
