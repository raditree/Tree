import 'package:flutter/foundation.dart';

/// WS 断线补发帧的「重播去重」闸（M9 §1.1，对应 Wave 3-H 待办 3）。
///
/// **背景**：核心在链路失活 / 前端断开期间把广播帧登记进待补发队列，重连后按保活
/// 节拍**原样重播**（帧没有 TTL，也没有序号 / 偏移）。前端这边：
/// - `msg_chunk` 是**追加**语义（`content += chunk`），天然不幂等：同一片段送到
///   两次就渲染两遍；
/// - `msg_start` / `tool_start` / `message` / `ask_user_question` 是**新建气泡**
///   语义：同一 id 送到两次就会出现两条消息，后续增量只打进第一条，第二条永久空转。
///
/// **核对结论（读代码路径得出，不是推测）**：
/// 1. 前端**没有**"重连后重拉历史"的行为——中栏 [MessagePanel] 的
///    `onConnectionChange` 只清 working/compacting 集合并补跑执行器 ensureTeam，
///    不调 `_loadHistory()`；成员窗口只清 working 集合。所以"重拉历史 + 重播帧"
///    这个最坏组合当前**不会同时发生**；
/// 2. 但重复渲染的风险仍然真实：**别的路径会整批重建消息列表**（切换 agent / 会话、
///    清空历史后的 refreshTrigger、新建 / 删除会话）。只要某次重建落在"断线登记 →
///    重连重播"之间，同一条消息就会先由 REST 全量重建、再被重播增量追加一遍。
///
/// 因此本闸把"重复"判据收敛到**消息 id**：
/// - **已封口（sealed）的 id**：正文已成终稿。来源有两处——
///   ① REST 历史加载来的消息：核心是"段关闭即落库"，能出现在历史里就说明该段已关闭，
///      正文即终稿；② 已收到 `msg_end` 的段：同一 id 不会再产出增量（核心在
///      `msg_end` 之前会 flush 掉攒帧，帧序有保证）。这两类 id 上再收到 `msg_chunk`
///      ⇒ 一律丢弃；
/// - **列表里已存在的 id**：重播的 `msg_start` / `tool_start` / `message` /
///   `ask_user_question` 不再新建气泡（避免同 id 两条消息）。
///
/// **为什么不做"按片段内容去重"**：帧没有序号，重播帧与正常帧在字节上不可区分；而
/// 同一 `(id, chunk)` 的**合法**重复是存在的（同一帧窗口里的重复字符 / 重复短语，
/// 例如连着几帧都是"哈"），内容级去重会**静默吞掉正文**。id 级判据不丢内容：只有
/// "这些帧已经有权威副本（历史终稿 / 已结束段）"时才丢弃，而权威副本必然已包含它们。
///
/// **不复制列表状态**：`exists` 由调用方（消息列表）传入，本闸只持有封口集合，
/// 因此不会与列表漂移（列表有 8 处 `clear()`，影子副本必然会漏同步）。
class MessageReplayGuard {
  /// 已封口的消息 id（正文权威，重播增量不得再追加）。
  final Set<String> _sealed = <String>{};

  /// 已封口的 id 数量（观测 / 测试用）。
  int get sealedCount => _sealed.length;

  /// 该 id 是否已封口（正文权威）。
  bool isSealed(String id) => _sealed.contains(id);

  /// 封口单个 id（收到 `msg_end` 时调用；空 id 忽略）。
  void seal(String id) {
    if (id.isNotEmpty) {
      _sealed.add(id);
    }
  }

  /// 批量封口（不改变已有的封口记录）。
  void sealAll(Iterable<String> ids) {
    for (final String id in ids) {
      seal(id);
    }
  }

  /// 历史整批重建：**替换**封口集合（上一批 id 属于别的 agent / 会话，不再需要）。
  void resetToHistory(Iterable<String> ids) {
    _sealed.clear();
    sealAll(ids);
  }

  /// 清空封口集合（列表整体作废时调用）。
  void clear() => _sealed.clear();

  /// 该 id 是否允许**新建**消息 / 卡片。
  ///
  /// [exists] = 列表里已有同 id 的消息：重播的 start 帧（`msg_start` /
  /// `tool_start` / `message` / `ask_user_question`）一律不再建第二条；
  /// 空 id 不参与去重（旧核心 / 畸形帧），交调用方按既有行为处理。
  bool shouldCreateMessage({required String id, required bool exists}) =>
      id.isNotEmpty && !exists;

  /// 该 id 的流式增量（`msg_chunk`）是否应当追加。
  ///
  /// [exists] = 列表里已有同 id 的消息。三个否决条件：空 id、没有对应消息
  /// （孤立增量）、该 id 已封口（重播的历史终稿 / 已结束段）。
  bool shouldAppendChunk({required String id, required bool exists}) =>
      id.isNotEmpty && exists && !_sealed.contains(id);

  /// 调试用的一句话结论（日志里区分"为什么丢弃"）。
  String describe({required String id, required bool exists}) {
    if (id.isEmpty) return '空 id';
    if (_sealed.contains(id)) return '已封口（历史终稿 / 已 msg_end）';
    if (!exists) return '无对应消息（孤立帧）';
    return '正常';
  }

  /// 仅测试 / 排障：当前封口集合的快照。
  @visibleForTesting
  Set<String> get sealedIds => Set<String>.unmodifiable(_sealed);
}
