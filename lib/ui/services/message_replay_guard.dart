import 'package:flutter/foundation.dart';

/// WS 断线补发帧的「重播去重」闸（M9 §1.1 / Wave 3-H 待办 3；Wave 3-J 交付初版，
/// 本轮把判据从 **id 级**升级为 **id + 序号级**）。
///
/// **背景**：核心在链路失活 / 前端断开期间把广播帧登记进待补发队列，重连后按保活
/// 节拍**原样重播**（帧没有 TTL）。前端这边：
/// - `msg_chunk` 是**追加**语义（`content += chunk`），天然不幂等：同一片段送到
///   两次就渲染两遍；
/// - `msg_start` / `tool_start` / `message` / `ask_user_question` 是**新建气泡**
///   语义：同一 id 送到两次就会出现两条消息，后续增量只打进第一条，第二条永久空转。
///
/// **重复渲染的风险路径**（读代码路径得出，不是推测）：前端**没有**"重连后重拉
/// 历史"的行为，但**别的路径会整批重建消息列表**（切换 agent / 会话、清空历史后的
/// refreshTrigger、新建 / 删除会话）。只要某次重建落在"断线登记 → 重连重播"之间，
/// 同一条消息就会先由 REST 全量重建、再被重播增量追加一遍。
///
/// **判据（三条，按序判定）**：
/// 1. **已封口（sealed）的 id**：正文已成终稿。来源有两处——① REST 历史加载来的
///    消息：核心是"段关闭即落库"，能出现在历史里就说明该段已关闭，正文即终稿；
///    ② 已收到 `msg_end` 的段（核心在 `msg_end` 之前会 flush 掉攒帧，帧序有保证）。
///    这两类 id 上再收到 `msg_chunk` ⇒ 一律丢弃；
/// 2. **序号水位**（新核心）：核心给每条 `msg_chunk` 带同一 message id 内**严格
///    递增**的 `seq`（协议见 `WsStreamSeq`）。本闸按 id 记录「**已消费到的最新
///    序号**」，**序号不大于该水位的增量就是"已经渲染过的同一片段被重播"**，直接
///    丢弃 —— 这正是旧判据做不到的事：段的 id 在整个流式周期内不变，只有序号能把
///    "这一帧本端到底渲染过没有"说清楚。水位**只前进不后退**（乱序 / 迟到的老帧
///    即使被判据放行，也不得把水位拉回去）；
/// 3. **缺 seq = 未知（老核心）**：退回第 1 条的 id 级判据，行为与升级前**一致**。
///    **绝不**把缺失当成 0 / -1：那会把老核心第二条起的增量全部判成"重播"，正文
///    只剩第一帧（静默丢正文，比重复渲染更糟）。
///
/// **为什么不按片段内容去重**：内容级判据在协议上不可判定——同一 `(id, chunk)` 的
/// **合法**重复是存在的（同一帧窗口里的重复字符 / 重复短语，例如连着几帧都是"哈"），
/// 内容级去重会**静默吞掉正文**。序号是唯一能区分"合法重复"与"重播"的信息，所以
/// 去重按序号做、不按内容做；id 级判据也不丢内容（只在"已有权威副本"时才丢弃，
/// 而权威副本必然包含它们）。
///
/// **判据与记账分离**：[shouldAppendChunk] / [describe] 是**纯查询**；由调用方在
/// 真正把增量写进正文之后调 [markConsumed] 记账。这样 [describe] 复查同一帧时
/// 不会把自己刚记下的水位读成"重播"（否则排障日志会撒谎）。
///
/// **不复制列表状态**：`exists` 由调用方（消息列表）传入，本闸只持有封口集合与
/// 序号水位，因此不会与列表漂移（列表有 8 处 `clear()`，影子副本必然会漏同步）。
class MessageReplayGuard {
  /// 「一个序号都还没消费」的哨兵：小于协议的任何合法序号（`WsStreamSeq.firstSeq`
  /// 为 0），于是第一条增量（seq 0）不会被自己的水位挡掉。
  static const int _noneConsumed = -1;

  /// 已封口的消息 id（正文权威，重播增量不得再追加）。
  final Set<String> _sealed = <String>{};

  /// 每条消息**已消费到的最新序号**（缺项 = 还没消费过任何带序号的增量）。
  ///
  /// 只在调用方真正追加正文之后由 [markConsumed] 推进；与 [_sealed] 同生命周期
  /// （[resetToHistory] / [clear] 一并作废），否则跨会话切换会让它无限增长。
  final Map<String, int> _consumedSeq = <String, int>{};

  /// 已封口的 id 数量（观测 / 测试用）。
  int get sealedCount => _sealed.length;

  /// 已记录序号水位的 id 数量（观测 / 测试用）。
  int get consumedSeqCount => _consumedSeq.length;

  /// 该 id 是否已封口（正文权威）。
  bool isSealed(String id) => _sealed.contains(id);

  /// 该 id **已消费到的最新序号**（null = 从未消费过带序号的增量 = 老核心 /
  /// 本段还没收到过带 seq 的帧）。
  int? lastConsumedSeq(String id) => _consumedSeq[id];

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

  /// 历史整批重建：**替换**封口集合（上一批 id 属于别的 agent / 会话，不再需要），
  /// 序号水位一并作废。
  ///
  /// 为什么水位也要清：重建后列表里的 id 全部被封口（判据 1 已经拦下它们，水位对
  /// 它们不再有任何作用），而没进列表的在途消息因为 `exists == false` 本来就收不到
  /// 增量；留着只会让 Map 随切换会话无限增长。
  void resetToHistory(Iterable<String> ids) {
    _sealed.clear();
    _consumedSeq.clear();
    sealAll(ids);
  }

  /// 清空封口集合与序号水位（列表整体作废时调用）。
  void clear() {
    _sealed.clear();
    _consumedSeq.clear();
  }

  /// 该 id 是否允许**新建**消息 / 卡片。
  ///
  /// [exists] = 列表里已有同 id 的消息：重播的 start 帧（`msg_start` /
  /// `tool_start` / `message` / `ask_user_question`）一律不再建第二条；
  /// 空 id 不参与去重（旧核心 / 畸形帧），交调用方按既有行为处理。
  bool shouldCreateMessage({required String id, required bool exists}) =>
      id.isNotEmpty && !exists;

  /// 该 id 的流式增量（`msg_chunk`）是否应当追加。**纯查询，不改状态**——
  /// 放行后请调用方追加正文并 [markConsumed] 记账。
  ///
  /// [exists] = 列表里已有同 id 的消息；[seq] = 帧上的单调序号（缺字段 = null =
  /// 老核心 = 未知）。四个否决条件：空 id、没有对应消息（孤立增量）、该 id 已封口
  /// （重播的历史终稿 / 已结束段）、序号不大于已消费水位（重播的已渲染片段）。
  bool shouldAppendChunk({
    required String id,
    required bool exists,
    int? seq,
  }) {
    if (id.isEmpty) return false;
    if (_sealed.contains(id)) return false;
    if (!exists) return false;
    // 序号判据（新核心）：重播帧的序号不可能超过本端已消费的水位 ⇒ ≤ 水位即重播。
    // 缺 seq（老核心）时整条判据跳过，退回上面的 id 级判据。
    if (seq != null && seq <= (_consumedSeq[id] ?? _noneConsumed)) return false;
    return true;
  }

  /// 记账：该序号（含）之前的增量**已经渲染进正文**。
  ///
  /// - 空 id / `seq == null`（缺字段 = 未知）⇒ 忽略：老核心没有序号可记；
  /// - 负数等非法值不参与（协议侧 `WsStreamSeq.of` 已把它们归一成 null，这里再
  ///   兜一道，避免调用方手工构造时把水位写成负值）；
  /// - **只前进不后退**：水位是"最新已消费"，回退会让已经渲染过的重播帧再次被放行。
  void markConsumed({required String id, int? seq}) {
    if (id.isEmpty || seq == null || seq < 0) return;
    final int? current = _consumedSeq[id];
    if (current == null || seq > current) {
      _consumedSeq[id] = seq;
    }
  }

  /// 调试用的一句话结论（日志里区分"为什么丢弃"）。**纯查询**，与
  /// [shouldAppendChunk] 的判定顺序保持一致。
  String describe({required String id, required bool exists, int? seq}) {
    if (id.isEmpty) return '空 id';
    if (_sealed.contains(id)) return '已封口（历史终稿 / 已 msg_end）';
    if (!exists) return '无对应消息（孤立帧）';
    final int? consumed = _consumedSeq[id];
    if (seq != null && seq <= (consumed ?? _noneConsumed)) {
      return '重播（序号 $seq ≤ 已消费水位 ${consumed ?? _noneConsumed}）';
    }
    return '正常';
  }

  /// 仅测试 / 排障：当前封口集合的快照。
  @visibleForTesting
  Set<String> get sealedIds => Set<String>.unmodifiable(_sealed);

  /// 仅测试 / 排障：当前序号水位的快照。
  @visibleForTesting
  Map<String, int> get consumedSeqs =>
      Map<String, int>.unmodifiable(_consumedSeq);
}
