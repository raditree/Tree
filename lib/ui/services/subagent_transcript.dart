import 'package:flutter/foundation.dart';

import '../models/message.dart';

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

  /// 某个临时员工的消息（**按时间顺序**；没有就是空表）。
  List<ChatMessage> of(String subagentId) =>
      List<ChatMessage>.unmodifiable(_byId[subagentId] ?? const <ChatMessage>[]);

  /// 已知的临时员工 id（按第一次出现排序）。
  List<String> get ids => List<String>.unmodifiable(_byId.keys);

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
    final List<ChatMessage> transcript = of(subagentId);
    if (transcript.isEmpty) return '';
    final String parentId = transcript.first.subagentParentId;
    if (parentId.isEmpty) return '';
    if (parentId == ownerAgentId) return ownerName;
    final List<ChatMessage> parent = of(parentId);
    if (parent.isNotEmpty && parent.first.subagentName.isNotEmpty) {
      return parent.first.subagentName;
    }
    return '';
  }

  /// 清空（切 agent / 换会话 / 整表重拉时调用）。
  void clear() {
    if (_byId.isEmpty && _seen.isEmpty) return;
    _byId.clear();
    _seen.clear();
    notifyListeners();
  }
}
