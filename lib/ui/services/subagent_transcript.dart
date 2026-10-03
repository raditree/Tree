import 'package:flutter/foundation.dart';

import '../models/message.dart';
import '../models/subagent_roster.dart';

/// 中栏消息流的**可见性口径**：临时员工（subagent）的消息**不进主消息流**。
///
/// 用户 2026-10-04：「subagent 的输出跟主 agent 的输出（包括工具调用）混杂，根本没法分辨，
/// subagent 的工具调用就在 subagent 的调用工具详情里看」——所以主流程只留主 agent 自己说的话
/// 与它调用的工具，临时员工干了什么去"那次 subagent 工具调用的详情页"里看。
///
/// 核心侧同口径：父 agent 的**模型上下文**也排掉带标记的消息（`store.messages`），
/// 只有后台完成报告会进父上下文——所以界面与模型看到的是同一件事的两个视角。
List<ChatMessage> visibleStreamMessages(Iterable<ChatMessage> messages) => messages
    .where((ChatMessage m) => !m.isSubagentMessage)
    .toList(growable: false);

/// 临时员工的**一次调用的过程**：把带同一个 `subagent_id` 的消息按到达顺序收在一起。
///
/// 数据来源是**同一份消息流**（历史接口给的是完整流，实时帧也带标记），所以这里没有第二条
/// 通路：面板每收到一批消息就 [sync] 一次，详情页按 id 取。
class SubagentTranscript extends ChangeNotifier {
  SubagentTranscript._();

  /// 全局单例（与 DetailSelection / TerminalToggleRequest 同一范式）。
  static final SubagentTranscript instance = SubagentTranscript._();

  final Map<String, List<ChatMessage>> _byId = <String, List<ChatMessage>>{};

  /// 已经收进来的消息 id（合并语义的去重依据，见 [sync]）。
  final Set<String> _seen = <String>{};

  /// **落盘名册**（id → 身份）：入口列表的**权威来源**（用户 2026-10-03
  /// 「进入某个临时成员的选项经常会无端变化」）。
  ///
  /// 为什么要有它：`_byId` 是从**当前已加载的消息窗口**建的索引，而中栏窗口化只热
  /// 视口附近（`lib/README.md` 不变量 19）——消息被淘汰，那个临时员工的入口就凭空
  /// 消失。名册本身**早就落盘**（`data/<agentId>/<sessionId>/subagents.json`，
  /// `store/README.md` 不变量 11），[setRoster] 把它接进来当权威来源。
  ///
  /// **跨会话不保留**：切 agent / 换会话时 [clear] 把名册层与消息层**一起**清掉。
  final Map<String, SubagentRosterEntry> _roster = <String, SubagentRosterEntry>{};

  /// 某个临时员工的消息（**按时间顺序**；没有就是空表）。
  List<ChatMessage> of(String subagentId) =>
      List<ChatMessage>.unmodifiable(_byId[subagentId] ?? const <ChatMessage>[]);

  /// 已知的临时员工 id：**名册里的（权威、稳定）在前**，消息流里观察到的补充在后
  /// （同一 id 不重复；两段各自保持稳定顺序 ⇒ 下拉里的条目不会自己换位置）。
  List<String> get ids => List<String>.unmodifiable(<String>[
    ..._roster.keys,
    for (final String id in _byId.keys)
      if (!_roster.containsKey(id)) id,
  ]);

  /// 用**落盘名册**替换名册层（幂等）。
  ///
  /// 拉取失败时调用方**不要**调用它——保留上一次名册比清空更好（清空会让入口
  /// 凭空变少，正是这次要修的症状）；消息流那条路仍然兜着观察到的 id。
  void setRoster(Iterable<SubagentRosterEntry> entries) {
    _roster
      ..clear()
      ..addEntries(
        entries.map(
          (SubagentRosterEntry e) => MapEntry<String, SubagentRosterEntry>(
            e.id,
            e,
          ),
        ),
      );
    notifyListeners();
  }

  /// 显示名：**名册优先**（消息还没加载 / 已被淘汰时也有正确名字），
  /// 退回消息流里那条标记，最后退回空串（调用方自己给兜底文案）。
  String nameOf(String subagentId) {
    final String fromRoster = _roster[subagentId]?.name.trim() ?? '';
    if (fromRoster.isNotEmpty) return fromRoster;
    for (final ChatMessage message in of(subagentId)) {
      if (message.subagentName.trim().isNotEmpty) {
        return message.subagentName.trim();
      }
    }
    return '';
  }

  /// 用当前消息流**补全**分栏（幂等：同一批消息重复调用结果一致）。
  ///
  /// **合并而不是重建**：中栏窗口只热视口附近与末尾一段（用户 2026-10-04「限制缓存
  /// 长度，仅缓存窗口附近的消息」），被淘汰的那些消息对象不该从"临时员工的过程"里
  /// 消失——它就在那一次工具调用的详情里看。整表作废（换 agent / 换会话）走 [clear]。
  ///
  /// 消息对象是**共享引用**（流式增量原地改内容），所以这里只建索引、不复制内容；
  /// 有新增、或者还有正在流式的过程时通知一次——正在看某个临时员工详情的界面要能
  /// 跟着它的流式输出一起长。
  void sync(Iterable<ChatMessage> messages) {
    bool changed = false;
    for (final ChatMessage message in messages) {
      if (!message.isSubagentMessage) continue;
      if (_seen.add(message.id)) {
        _byId.putIfAbsent(message.subagentId, () => <ChatMessage>[]).add(message);
        changed = true;
      } else if (message.isStreaming) {
        // 正文还在长：界面要跟着重画
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 某个临时员工**是谁召来的**（显示名）——语义对齐用（用户 2026-10-04：「不是跟 teammates
  /// 同级，说错了，是和发出调用的 agent 同级。对齐语义」）：
  ///
  /// - 父 id == 会话主人 ⇒ 就是那个 agent 自己召的（用 [ownerName]）；
  /// - 父 id 是另一个临时员工 ⇒ 用那个临时员工的显示名（它自己也是有标记的）。
  ///
  /// 找不到（父不在本会话的过程里）时如实退回 `''`，界面显示「（未知调用方）」而不是编一个名字。
  String callerNameOf(
    String subagentId, {
    required String ownerAgentId,
    required String ownerName,
  }) {
    final SubagentRosterEntry? entry = _roster[subagentId];
    final List<ChatMessage> transcript = of(subagentId);
    // 名册优先：消息还没加载（或已被淘汰）时也能说清"谁召来的"
    final String parentId = entry != null
        ? entry.parentId
        : (transcript.isEmpty ? '' : transcript.first.subagentParentId);
    if (parentId.isEmpty) return '';
    if (parentId == ownerAgentId) return ownerName;
    return nameOf(parentId);
  }

  /// 清空（切 agent / 换会话 / 整表重拉时调用）。
  void clear() {
    if (_byId.isEmpty && _seen.isEmpty && _roster.isEmpty) return;
    _byId.clear();
    _seen.clear();
    // 名册层与消息层**一起**清：名册是会话级的，「不跨会话保留」这条断言不能因为
    // "多缓存了一份落盘数据"而破（切 agent / 换会话必须看到新会话自己的入口）。
    _roster.clear();
    notifyListeners();
  }
}
