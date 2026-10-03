import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/message.dart';
import '../services/message_window.dart';
import 'hook_notice_card.dart';
import 'message_scrollbar.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

/// 消息列表组件（StatelessWidget）
///
/// 渲染中栏消息列表。用户消息右对齐（蓝色气泡），agent 消息左对齐
/// （白色气泡 + 灰色边框）。流式消息在内容末尾显示闪烁光标。
///
/// **槽位表**（用户 2026-10-04：「滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息」）：
/// [slots] 按**全局下标**寻址（0 = 最旧那条），元素为 null 表示这一段还没取回来——
/// 画成等高占位槽。于是：
///
/// - 槽位表长度**只随新消息增长**，加载/淘汰都不改变它 ⇒ 右侧滑块
///   （[MessageScrollbar]，按全局下标算几何）上滑补页时不会跳来跳去；
/// - 列表把**本帧构建到的下标区间**帧后报给面板（[onWindowChanged]），面板据此
///   只补那一段、并淘汰离得远的槽位（限制缓存长度）；
/// - 「回到底部」= 请面板**重载末尾一段**（[onReloadTail]），不再在几千条估算高度里
///   做一次动画——落点确定，必然到底。
class MessageList extends StatelessWidget {
  /// 槽位表：全局下标 → 消息（null = 还没加载）。
  ///
  /// 面板持有同一个列表并**原地**放置/淘汰（见 MessageWindow），靠 [revision]
  /// 触发重建。
  final List<ChatMessage?> slots;

  /// 哪些消息**进主消息流**（null = 全部可见）。
  ///
  /// 临时员工的消息不进主消息流（它们在中栏只出现在"那次 subagent 工具调用的详情"里）：
  /// 面板传 (m) => !m.isSubagentMessage。这类槽位渲染成**零高度**（不占版面、也不
  /// 打断下标连续性）。
  final bool Function(ChatMessage message)? visible;

  /// 消息版本号：每次槽位表发生结构性变化（放置/追加/淘汰/清空）时递增，
  /// 用于触发重建与滚动跟随。由于 [slots] 是同一个可变列表引用，
  /// 无法通过长度/引用比较检测变化，故使用版本号信号。
  final int revision;

  /// 内联提问卡片的选择回调（参数为消息 id 与答案）
  final void Function(String messageId, String answer)? onAskAnswer;

  /// 定位目标消息 id：非空且 [scrollToRevision] 变化时滚动定位到该消息
  final String? scrollToMessageId;

  /// 定位触发号：外部递增触发滚动定位（与 [scrollToMessageId] 配合）
  final int scrollToRevision;

  /// 本次 revision 变化是否以「无动画直达底部」方式响应。
  ///
  /// 历史重载/重载末尾一段（切会话/切 agent/清空重拉/回到底部）传 true：
  /// 恢复跟随并直达底部。流式追加/增量更新传 false。
  final bool bottomJump;

  /// **在视口上方补了页**（递增的标记）：布局阶段按内容高度差补偿一次滚动位置，
  /// 免得"上面那一段由占位变实体"把正在看的内容推走。
  final int padAboveStamp;

  /// **本帧内容高度在"别处"变了**（递增的标记）：补页落在视口里/视口下方
  /// （横跨视口顶的那一份），或者淘汰掉了远处的槽位（真消息 → 88px 占位槽）。
  ///
  /// 为什么单独一个信号：这类变化**不是**"整段都在视口上方"（那走 [padAboveStamp]），
  /// 但也一样会让用户正在读的那一段整段下移/上移。列表侧用**实测锚点**
  /// （视口顶那条真消息的底边，见 [_MessageListViewState._resolveShiftAbove]）
  /// 把它补回来 —— 补的量在两个信号下是同一套口径，分开只是为了面板能表达
  /// "这一帧变的是哪一类"，也让测试能分别钉住（回归用例 N5/N6/N7）。
  final int contentShiftStamp;

  /// 本帧构建到的下标区间（帧后回调；面板据此补页 + 淘汰）。
  final void Function(int first, int last)? onWindowChanged;

  /// 「回到底部」：请面板重载末尾一段（空 = 退回旧的平滑回底行为）。
  final VoidCallback? onReloadTail;

  /// 消息流末尾追加的**插件内联卡片**（Q12）：按到达顺序排在最后一条消息之后。
  final List<Widget> trailingCards;

  /// 这一份会话的历史**正在路上**（切 agent / 首载 / 切会话）。
  ///
  /// 期间槽位表必然还是空的，但**不许**把它当成"真的没有消息"——空态（欢迎页）只在
  /// "确实加载完且真的没有消息"时出现（用户 2026-10-03 症状 1：切 agent 先闪一下
  /// 空窗口再载入历史）。加载中改渲染静态骨架（见 [_MessageListViewState.build]）。
  final bool loading;

  const MessageList({
    super.key,
    required this.slots,
    this.visible,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.padAboveStamp = 0,
    this.contentShiftStamp = 0,
    this.onWindowChanged,
    this.onReloadTail,
    this.trailingCards = const <Widget>[],
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return _MessageListView(
      slots: slots,
      visible: visible,
      revision: revision,
      onAskAnswer: onAskAnswer,
      scrollToMessageId: scrollToMessageId,
      scrollToRevision: scrollToRevision,
      bottomJump: bottomJump,
      padAboveStamp: padAboveStamp,
      contentShiftStamp: contentShiftStamp,
      onWindowChanged: onWindowChanged,
      onReloadTail: onReloadTail,
      trailingCards: trailingCards,
      loading: loading,
    );
  }
}

/// 内部带滚动控制的状态视图
class _MessageListView extends StatefulWidget {
  final List<ChatMessage?> slots;
  final bool Function(ChatMessage message)? visible;
  final int revision;
  final void Function(String messageId, String answer)? onAskAnswer;
  final String? scrollToMessageId;
  final int scrollToRevision;
  final bool bottomJump;
  final int padAboveStamp;
  final int contentShiftStamp;
  final void Function(int first, int last)? onWindowChanged;
  final VoidCallback? onReloadTail;
  final List<Widget> trailingCards;
  final bool loading;

  const _MessageListView({
    required this.slots,
    this.visible,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.padAboveStamp = 0,
    this.contentShiftStamp = 0,
    this.onWindowChanged,
    this.onReloadTail,
    this.trailingCards = const <Widget>[],
    this.loading = false,
  });

  @override
  State<_MessageListView> createState() => _MessageListViewState();
}

/// 占位槽的高度（px）。**固定值**：滑块的下标换算、以及"拖到某个下标"的落点估算
/// 都建立在"没加载的那一段每格一样高"这个前提上（见 [MessageScrollbar]）。
const double kMessagePlaceholderExtent = 88;

/// 「刚补了页」时的**布局前快照**：视口顶 + 已布局子项的顶边（下标 → 内容坐标）。
///
/// 与布局后再扫一遍配成对，用来量**实测**位移（见
/// [_MessageListViewState._resolveShiftAbove]）。
class _BuiltTopsSnapshot {
  const _BuiltTopsSnapshot({required this.viewportTop, required this.tops});

  /// 布局前的视口顶（sliver 自己的坐标系；已扣掉列表内边距）
  final double viewportTop;

  /// 布局前：这一趟真被布局过的子项 → 顶边
  final Map<int, double> tops;
}

/// 底部锚定滚动控制器：把「钉在底部」做成**布局同帧**的同步操作。
///
/// 列表为常规（非反转）布局：offset 0 在顶部，maxScrollExtent 即底部。
/// - 跟随模式：内容变化时在布局阶段把 offset 同步钉到 maxScrollExtent
///   （早于绘制，无「先位移一帧再拉回」的逐帧闪烁抖动）。
/// - 阅读模式：**不做任何校正**。常规布局下在末尾追加/增长内容不会移动
///   已渲染内容的坐标，视口天然稳定，因此零漂移（无需任何 offset 补偿）——
///   唯一的例外是"视口**上方**补页"（占位槽换成真消息，高度变了），
///   由 [shiftAbove] 标记在布局阶段补偿（见 [padAboveStamp]）。
class _BottomAnchorScrollController extends ScrollController {
  _BottomAnchorScrollController({required this.shouldFollow});

  /// 是否处于跟随模式（需要钉底）
  final bool Function() shouldFollow;

  /// 是否需要把 offset 钉到底部：内容变化/首帧时由 State 置位，布局时消费。
  bool pinToBottom = false;

  /// **首帧即底部**（切 agent / 切会话 / 历史重载 / 回到底部 / 首次进入）。
  ///
  /// 与 [pinToBottom] 的分工：那个是"跟随模式"下每次内容变化都粘底的**持续**请求
  /// （消费一次之后靠"本来就贴底"继续跟）；这个是"新一份窗口内容落地"的**一次性**
  /// 要求，而且必须在这**同一次布局**里校到收敛——[applyContentDimensions] 返回
  /// false 会让 RenderViewport 在同帧内重跑布局，**绘制发生在收敛之后**，于是不会
  /// 出现"先按顶部渲染一帧、下一帧再跳到底"（用户 2026-10-03 症状 2）。
  bool firstFrameBottom = false;

  /// [firstFrameBottom] 上一轮校到的"底"（-1 = 这一轮还没校过）。
  /// 相邻两轮目标一致 ⇒ 已经收敛，收工（避免和 RenderViewport 的布局循环打架）。
  double firstFrameBottomTarget = -1;

  /// 视口**上方/视口里**刚补了页：布局阶段按**实测**高度差把 offset 挪同样多。
  bool shiftAbove = false;

  /// [shiftAbove] 的**实测解析器**：返回"用户正在读的那一段**实际**被顶下去了多少"
  /// （null = 实测拿不到 → 退回估算 + 限幅）。
  ///
  /// 为什么不能用 `maxScrollExtent` 的帧间差：长列表里它是**外推值**，
  /// 误差 ∝ 剩余条数（详见 [_BottomAnchorScrollPosition.applyContentDimensions]）。
  /// 由 [_MessageListViewState] 注入——它拿着列表的 [GlobalKey]，可以在布局前后
  /// 各读一遍渲染树（只有它知道"用户当时在看哪一条"）。
  double? Function()? resolveShiftAbove;

  /// 从渲染树读「某个子项**此刻**的顶边」（内容坐标；拿不到 = null）。
  /// 由 [_MessageListViewState] 注入（它拿着列表的 [GlobalKey]）。
  double? Function(int index)? readChildTop;

  /// 上一帧内容的总高度（-1 = 还不知道）。用来判断"刚才是不是贴着底"，
  /// 并作为补页补偿的**兜底**估算值（实测拿不到时才用，且有限幅）。
  double lastMaxExtent = -1;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _BottomAnchorScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      controller: this,
    );
  }
}

/// 见 [_BottomAnchorScrollController]：在布局阶段同步钉底 / 补偿上方补页。
class _BottomAnchorScrollPosition extends ScrollPositionWithSingleContext {
  _BottomAnchorScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.controller,
  });

  final _BottomAnchorScrollController controller;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final bool ok =
        super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    final bool following = controller.shouldFollow();
    final bool requested = controller.pinToBottom;
    // ① **首帧即底部**：新一份窗口内容落地的那一帧就落在底部（静默校正，走同一套
    //    `correctPixels` 通路；**不**动下面那套"实测锚点补偿"的口径）。
    //    只认跟随模式：用户在读历史时不抢他的位置。
    if (controller.firstFrameBottom) {
      if (!following) {
        controller.firstFrameBottom = false;
        controller.firstFrameBottomTarget = -1;
      } else {
        final double target =
            maxScrollExtent.clamp(minScrollExtent, maxScrollExtent);
        final bool settled = controller.firstFrameBottomTarget >= 0 &&
            (target - controller.firstFrameBottomTarget).abs() <= 0.5;
        if (settled) {
          // 连着两轮的"底"一样：估算已经稳定（懒构建把真实高度补完了）⇒ 收工
          controller.firstFrameBottom = false;
          controller.firstFrameBottomTarget = -1;
        } else {
          controller.firstFrameBottomTarget = target;
          if ((pixels - target).abs() > 0.01) {
            correctPixels(target);
            // 同帧重跑布局（绘制在收敛之后 ⇒ 没有"先在顶部再跳"的中间帧）
            return false;
          }
        }
      }
    }
    // **粘底**：请求贴底（首帧 / 历史重载 / 追加），或者上一帧我们本来就贴着底。
    //
    // 为什么"本来就贴着底"也算一次：列表的滚动范围是**估算**的，随着视口周围
    // 构建出真实内容，maxScrollExtent 还会再长——只认一次性的请求就会停在半路。
    // 用户一旦上滚，pixels 立刻离开 max，这里就不再校正。
    final bool glued =
        controller.lastMaxExtent >= 0 &&
        (pixels - controller.lastMaxExtent).abs() <= 1.0;
    // 刚补过页：**标记一定要消费掉**（跟随模式下由贴底接管，不能留到以后
    // 阅读模式下突然生效）；只有"不在跟随"时才需要自己补偿。
    final bool shiftAbove = controller.shiftAbove;
    controller.shiftAbove = false;
    final double? Function()? resolveShift = controller.resolveShiftAbove;
    controller.resolveShiftAbove = null;
    // 兜底口径：上一帧"内容总高"的差。**只在实测拿不到时用**，而且要限幅——
    // 长列表里它是外推值（见下面 shiftAbove 分支的注释）。
    final double estimatedDelta = controller.lastMaxExtent >= 0
        ? maxScrollExtent - controller.lastMaxExtent
        : 0;
    controller.lastMaxExtent = maxScrollExtent;
    if (shiftAbove && !following) {
      // 补页会让内容高度变（占位槽 88px ↔ 真消息），把 offset 加同样多，
      // 正在看的那一段就还在原地。返回 false 请求同帧重跑布局（绘制前就已补偿，不闪）。
      //
      // **补偿量取"实测位移"，不能取 maxScrollExtent 的差**：
      // 列表是懒构建的、没到底时 `maxScrollExtent` 是**外推值**
      // （SDK `RenderSliverList.estimateMaxScrollOffset` =
      // `末尾已布局偏移 + 已建子项平均高 × 剩余条数`），误差 **∝ 剩余条数**：
      // 真机会话几千条、视口在中段 ⇒ 单帧可差上千像素，而"真正长高的高度"
      // 最多几百像素（只有 cache extent 内那几行会被布局）⇒ 补偿量被噪声主导，
      // 视口被随机搬走（用户 2026-10-03：「触发一次懒加载后抖动非常厉害」）。
      //
      // 实测口径见 [_MessageListViewState._resolveShiftAbove]：
      // 锚点 = "用户**当时**正在看的第一条真消息"（跳过这一帧刚换过的格子），
      // 补偿量 = 锚点**底边**的实测位移（`layoutOffset` 是实测子项高度逐个累加的真值）。
      double? shift = resolveShift?.call();
      if (shift == null && estimatedDelta.abs() <= viewportDimension * 2) {
        // 实测拿不到（还没布局过 / 锚点不在这一趟布局里）：退回估算值，
        // 且**只在不超过两屏时采信**——宁可不补，也不要错补上千像素。
        shift = estimatedDelta;
      }
      if (shift != null && shift.abs() > 0.01) {
        correctPixels((pixels + shift).clamp(minScrollExtent, maxScrollExtent));
        return false;
      }
      return ok;
    }
    if (!ok || !following) return ok;
    if (!requested && !glued) return ok;
    controller.pinToBottom = false; // 消费一次
    if ((pixels - maxScrollExtent).abs() > 0.01) {
      correctPixels(maxScrollExtent.clamp(minScrollExtent, maxScrollExtent));
      // 返回 false 请求 RenderViewport 用校正后的 offset 同帧重跑布局：
      // 绘制前即已贴底（下一次迭代残差归零 → 返回 true 收敛）。
      return false;
    }
    return ok;
  }
}

class _MessageListViewState extends State<_MessageListView> {
  /// 底部锚定滚动控制器（见 [_BottomAnchorScrollController]）
  late final _BottomAnchorScrollController _controller;

  /// 模式开关（唯一的滚动行为状态）：
  /// - false = 跟随模式：始终钉在底部，随新内容一起移动；
  /// - true = 阅读模式：用户主动上滚查看历史，视口锁定、不随新内容移动。
  ///
  /// 进入阅读：任意一次离开底部的滚动；恢复跟随：**完全压到底部**才切换。
  bool _userDetached = false;

  /// 「回到底部」动画进行中：期间的中间位置不算用户上滚。
  bool _returningToBottom = false;

  /// 贴底判定阈值（px）：与底部距离不超过该值即视为「完全压到底部」。
  static const double _bottomEpsilon = 1.0;

  /// 消息 id → GlobalKey（定位目标可寻址）
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};

  /// 当前高亮定位的消息 id
  String? _highlightedId;

  /// 高亮清除定时器
  Timer? _highlightTimer;

  /// 定位重试次数（防止目标未构建时无限重试）
  int _scrollRetries = 0;

  /// **本帧构建到的下标区间**（-1 = 本帧还没构建任何槽位）。
  ///
  /// 只是**兜底**口径：权威口径是渲染树里 SliverList 实际持有的子项区间
  /// （见 [_builtRangeFromRenderTree]）——滚动时只有"新进视口的"子项会被重建，
  /// itemBuilder 收集不到整段可见区间。
  int _builtFirst = -1;
  int _builtLast = -1;

  /// 视口在整份历史里的坐标（帧后刷新）。
  ///
  /// **拇指直接监听它**：滚动时只重绘拇指，不重建列表（"鼠标滚动丝滑"的关键）；
  /// 面板的补页 / 淘汰也以它为准（见 [MessageList.onWindowChanged]）。
  final ValueNotifier<MessageWindowCoordinate> _coordinate =
      ValueNotifier<MessageWindowCoordinate>(MessageWindowCoordinate.unknown);

  /// 这一帧已经安排过帧后刷新（同帧去重）。
  bool _flushScheduled = false;

  /// 正在做"我们自己发起的跳转"（滚动通知里据此区分用户滚动，见 [_handleScrollNotification]）。
  bool _programmaticJump = false;

  /// 正在做的落点校正（null = 没有）。用户一动就丢掉，绝不和用户抢。
  MessageSeekCorrection? _seekCorrection;

  /// 列表自己的 key：从渲染树读"权威构建区间"要用它（见 [_builtRangeFromRenderTree]）。
  final GlobalKey _listKey = GlobalKey(debugLabel: 'message-list');

  /// `_itemKeys` 的上限：超了就按"还在槽位表里"清一次（长会话里它只增不减会漏）。
  static const int _itemKeysLimit = 2000;

  /// 直达底部的"收尾"帧数上限（见 [_jumpToBottomSettling]）。
  static const int _pinSettleLimit = 120;
  int _pinSettleFrames = 0;
  double _lastMaxExtent = -1;

  /// 程序化的"直达底部"进行中：期间不把滚动通知当成用户上滚。
  bool _jumpingToBottom = false;

  @override
  void initState() {
    super.initState();
    _controller = _BottomAnchorScrollController(
      shouldFollow: () => !_userDetached,
    );
    // 首帧即把视口钉到底部（最新消息），避免「顶部闪一下再落底」。
    //
    // **首帧也要"连续几帧贴底"**：导入长会话走的就是这条路径（不是 didUpdateWidget），
    // 懒构建列表首帧的 maxScrollExtent 只是估算值——只贴一帧就会停在半路。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToBottomSettling();
    });
    _controller.pinToBottom = true;
    // 首帧即底部：首屏（挂载时就带着槽位表）也走同一条"同帧校到收敛"的路，
    // 于是第一个被绘制的帧就已经在底部。
    _controller.firstFrameBottom = true;
    _controller.firstFrameBottomTarget = -1;
  }

  @override
  void didUpdateWidget(covariant _MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板补了页：占位槽换成真消息会改变内容高度，布局阶段补回来。
    // - [padAboveStamp]：整段都在视口上方的那一份；
    // - [contentShiftStamp]：横跨视口顶 / 落在视口里的那一份（视口顶那条真消息**以下**
    //   那一段必须由它来保住）。
    // 补偿量必须在本帧布局**之前**量（此刻渲染树里是上一帧的 layoutOffset）——
    // 见 [_snapshotShiftAnchor] 与 [_BottomAnchorScrollPosition]。
    if (oldWidget.padAboveStamp != widget.padAboveStamp ||
        oldWidget.contentShiftStamp != widget.contentShiftStamp) {
      _beginShiftCompensation();
    }
    if (oldWidget.revision != widget.revision) {
      // 槽位表变了：刷新一次视口坐标（面板可能还要按它补页 / 淘汰）
      _scheduleCoordinateFlush();
      _pruneItemKeys();
      if (widget.bottomJump) {
        // 重载（切会话 / 切 agent / 回到底部 / 清空重拉）：恢复跟随并直达底部
        _jumpToBottomSettling();
      } else if (!_userDetached) {
        // 跟随模式：本帧布局阶段同步钉底
        _schedulePin();
      }
      // 阅读模式：不做任何校正——常规布局下末尾新增/增长内容不会移动
      // 已渲染内容，视口天然稳定（零漂移）。
    } else if (!_userDetached) {
      _schedulePin();
    }
    // 定位触发：scrollToRevision 变化且存在目标消息 id
    if (oldWidget.scrollToRevision != widget.scrollToRevision &&
        widget.scrollToMessageId != null &&
        widget.scrollToMessageId!.isNotEmpty) {
      _scrollRetries = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessage(widget.scrollToMessageId!);
      });
    }
  }

  /// 请求在本次布局帧内把视口同步钉到底部（细节见 [_BottomAnchorScrollPosition]）。
  void _schedulePin() {
    _controller.pinToBottom = true;
  }

  /// 历史重载后**连续几帧**继续贴底。
  ///
  /// 为什么不能只贴一帧：ListView.builder 是懒构建的，长会话里
  /// maxScrollExtent 在首帧只是**估算值**；贴一次底之后，随着视口周围真正构建出
  /// 内容，额外高度才补上——用户看到的现象就是「导入长会话后没能到最底部」。
  /// 跟随模式下逐帧复查，直到位移归零或帧数用尽（用户上滚立即停手）。
  void _jumpToBottomSettling() {
    _userDetached = false;
    // **这一跳是程序发起的**：期间不管收到什么滚动通知都不许把它判成"用户上滚"。
    _jumpingToBottom = true;
    // 首帧即底部：这一次内容落地就在**首帧**（同帧内校到收敛）落到真底部，
    // 而不是"先渲染一帧再在下一帧跳过去"。
    _controller.firstFrameBottom = true;
    _controller.firstFrameBottomTarget = -1;
    _schedulePin();
    _lastMaxExtent = -1;
    _pinSettleFrames = _pinSettleLimit;
    _settlePin();
  }

  void _settlePin() {
    if (!mounted || _pinSettleFrames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pinSettleFrames <= 0 || _userDetached) {
        _jumpingToBottom = false;
        return;
      }
      if (!_controller.hasClients) {
        _jumpingToBottom = false;
        return;
      }
      _pinSettleFrames--;
      final ScrollPosition pos = _controller.position;
      final double max = pos.maxScrollExtent;
      // 还没贴底，或者内容又长高了（懒构建把额外高度补上来了）⇒ 再贴一帧
      final bool stillGrowing = max > _lastMaxExtent + 0.5;
      _lastMaxExtent = max;
      if ((pos.pixels - max).abs() > 0.5 || stillGrowing) {
        _schedulePin();
        // 重新贴底**必须再要一帧**：pinToBottom 只是个标记，没有新一帧就不会再
        // 触发一次布局（post-frame 回调本身不排帧）。少了这一句，长列表会停在中途。
        WidgetsBinding.instance.scheduleFrame();
        _settlePin();
        return;
      }
      // 收敛了：这一跳结束，此后才允许按滚动通知判定用户上滚
      _jumpingToBottom = false;
      _settlePin();
    });
  }

  /// 帧后把**视口坐标**算出来（[MessageWindowCoordinate]）并通知出去。
  ///
  /// 为什么要"帧后 + 每帧"：视口区间是靠**布局**才定下来的（渲染树里的子项区间），
  /// 而**滚动不重建父组件**——早先只在 `build` 里注册一次帧后回调，于是滚动时一次都
  /// 不上报，右侧拇指就死在原地（用户 2026-10-03：「页面上滚，拇指不动」）。
  void _scheduleCoordinateFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      _flushCoordinate();
    });
  }

  void _flushCoordinate() {
    if (!mounted) return;
    final MessageRange? authoritative = _builtRangeFromRenderTree();
    final int first;
    final int last;
    if (authoritative != null) {
      first = authoritative.from;
      last = authoritative.to - 1;
    } else {
      // 兜底：itemBuilder 收集到的并集（比真值宽，但至少会更新，不会静默冻住）
      first = _builtFirst;
      last = _builtLast;
    }
    _builtFirst = -1;
    _builtLast = -1;
    if (first < 0 || last < first) return;
    final MessageWindowCoordinate next = MessageWindowCoordinate(
      first: first,
      last: last.clamp(first, widget.slots.length - 1),
      total: widget.slots.length,
    );
    if (next == _coordinate.value) return;
    _coordinate.value = next;
    // 面板据它补页 / 淘汰（"滑到哪加载哪、只缓存坐标附近"）
    widget.onWindowChanged?.call(next.first, next.last);
    // 有落点校正在进行：拿这次实测的落点反馈下一步（见 [_pumpSeekCorrection]）
    _pumpSeekCorrection();
  }

  /// 从渲染树读**权威**的"构建到哪"：SliverList 实际持有的子项区间。
  ///
  /// 为什么不靠 itemBuilder 收集：滚动时 SliverList 只**创建**新进视口的子项，
  /// 留在原地的那些不会重建 ⇒ 收集到的区间是残缺的（早先的实现在滚动期间干脆
  /// 一次都不上报）。渲染树里的 `SliverMultiBoxAdaptorParentData.index` 才是真值。
  ///
  /// 找不到（结构变了 / 还没布局）时返回 null，调用方退回兜底口径。
  MessageRange? _builtRangeFromRenderTree() {
    final RenderSliverList? target = _sliverListFromRenderTree();
    if (target == null) return null;
    int? first;
    int? last;
    RenderBox? item = target.firstChild;
    while (item != null) {
      // **只认这一趟真的被布局过的子项**：`layoutOffset == null` 的是被
      // `AutomaticKeepAlive` 留在树里的屏外子项（滚动过的历史），它们不是"视口里看得到的"。
      if (target.childScrollOffset(item) != null) {
        final ParentData? data = item.parentData;
        if (data is SliverMultiBoxAdaptorParentData) {
          final int? index = data.index;
          if (index != null) {
            first ??= index;
            last = index;
          }
        }
      }
      item = target.childAfter(item);
    }
    if (first == null || last == null) return null;
    final int slotCount = widget.slots.length;
    if (slotCount <= 0) return null;
    // 末尾的插件内联卡片也在这张表里：夹进槽位范围
    return MessageRange(
      first.clamp(0, slotCount - 1),
      (last + 1).clamp(1, slotCount),
    );
  }

  /// 列表内部那个 [RenderSliverList]（懒构建子项都挂在它下面；null = 还没布局）。
  ///
  /// 注意：ListView 的 renderObject **不是** Viewport（外面还裹着 Scrollable 的
  /// Listener/Semantics/IgnorePointer…），所以在子树里找 `RenderSliverList`。
  RenderSliverList? _sliverListFromRenderTree() {
    final BuildContext? context = _listKey.currentContext;
    if (context == null) return null;
    final RenderObject? root = context.findRenderObject();
    if (root == null) return null;
    RenderSliverList? list;
    void find(RenderObject node) {
      if (list != null) return;
      if (node is RenderSliverList) {
        list = node;
        return;
      }
      node.visitChildren(find);
    }

    if (root is RenderSliverList) {
      list = root;
    } else {
      root.visitChildren(find);
    }
    return list;
  }

  /// 扫一遍渲染树：这一趟**真被布局过**的子项 → 顶边（下标 → 内容坐标）。
  ///
  /// 这个值来自 `SliverMultiBoxAdaptorParentData.layoutOffset`：由**实测**子项高度
  /// 逐个累加而来，不是 `maxScrollExtent` 那种外推估算——所以它才是
  /// "上面真正长高了多少"的真值。
  ///
  /// 注意**不要读子项的 `.size`**：那超出了 `RenderBox.size` 的许可范围
  /// （布局期间只有"声明了 parentUsesSize 的父对象"能读），会在布局断言里炸。
  /// 需要"某格的底边"时取它**下一条**子项的顶边（渲染树里子项是连续排布的）。
  /// `childScrollOffset == null` 的是被 `AutomaticKeepAlive` 留在树里的屏外子项。
  Map<int, double> _builtTopsFromRenderTree([RenderSliverList? target]) {
    final RenderSliverList? list = target ?? _sliverListFromRenderTree();
    final Map<int, double> out = <int, double>{};
    if (list == null) return out;
    RenderBox? item = list.firstChild;
    while (item != null) {
      final double? top = list.childScrollOffset(item);
      final ParentData? data = item.parentData;
      if (top != null &&
          data is SliverMultiBoxAdaptorParentData &&
          data.index != null) {
        out[data.index!] = top;
      }
      item = list.childAfter(item);
    }
    return out;
  }

  /// 布局**前**的快照：记下视口顶与已布局子项的顶边。
  ///
  /// 为什么必须在布局**之前**取：决定"用户**当时**在看哪一条"要按变化之前的位置判
  /// ——内容一长高，"视口顶之下的第一条真消息"就变成刚补进来的那几格了。
  /// 此刻渲染树里还是**上一帧**的 `layoutOffset`，正是"布局前"的真值。
  ///
  /// `!attached` 时不取（极端首帧路径下 `constraints` 会踩调试断言）：返回 null
  /// 即"实测拿不到"，调用方退回估算 + 限幅——不会抛异常。
  _BuiltTopsSnapshot? _snapshotBuiltTops() {
    final RenderSliverList? list = _sliverListFromRenderTree();
    if (list == null || !list.attached) return null;
    return _BuiltTopsSnapshot(
      viewportTop: list.constraints.scrollOffset,
      tops: _builtTopsFromRenderTree(list),
    );
  }

  /// 布局**后**再扫一遍 → 算出补偿量（null = 实测拿不到，调用方退回估算 + 限幅）。
  ///
  /// 锚点 = "用户**当时**正在看的第一条真消息"，两条口径缺一不可：
  /// - **按布局前的位置挑**（`top >= 布局前视口顶`），否则内容一长高就挑到新补的格子；
  /// - **跳过这一帧刚换过高度的子项**（占位槽 → 真消息 / 流式增长）：它们属于
  ///   "刚出现的新内容"，不是用户正在读的那一段。真机补页**先补横跨视口顶的那一份**，
  ///   紧贴视口顶的那一格往往**自身就是**被换掉的那一格；锚在它身上会漏补
  ///   它下面已经加载的内容（回归用例 N5：漏补 104px，用户看到的就是"整段下移"）。
  /// - 视口顶之下没有稳定真消息时，退而取视口顶之上最后一条稳定真消息。
  ///
  /// 补偿量 = 锚点**底边**的实测位移（= 它下一条子项顶边的差）：于是锚点**以下整段**
  /// 在屏幕上的位置也不动（N5 断言 ②）。
  double? _resolveShiftAbove(_BuiltTopsSnapshot before) {
    final Map<int, double> after = _builtTopsFromRenderTree();
    if (before.tops.isEmpty || after.isEmpty) return null;
    bool isReal(int index) =>
        index >= 0 && index < widget.slots.length && widget.slots[index] != null;
    // "这一帧高度没变" = 它与其**下一条**顶边差不变（只用 childScrollOffset，不读 .size）
    bool stable(int index) {
      final double? t0 = before.tops[index];
      final double? t1 = after[index];
      if (t0 == null || t1 == null) return false;
      final double? n0 = before.tops[index + 1];
      final double? n1 = after[index + 1];
      // 下一条读不到（视口末尾那一格）：量不到高度变化，按"稳定"处理（它的顶边即锚点底边）
      if (n0 == null || n1 == null) return true;
      return ((n1 - t1) - (n0 - t0)).abs() <= 0.01;
    }

    int? below;
    int? above;
    before.tops.forEach((int index, double top) {
      if (!isReal(index) || !stable(index)) return;
      if (top >= before.viewportTop - _bottomEpsilon) {
        if (below == null || top < before.tops[below]!) below = index;
      } else if (above == null || top > before.tops[above]!) {
        above = index;
      }
    });
    final int? anchor = below ?? above;
    if (anchor == null) return null;
    // 量锚点的**底边**：它下一条子项（读不到就退回锚点自己的顶边）
    final int probe = after.containsKey(anchor + 1) ? anchor + 1 : anchor;
    final double? now = after[probe];
    final double? was = before.tops[probe];
    if (now == null || was == null) return null;
    return now - was;
  }

  /// 开始一次"补页补偿"：布局前拍照 + 把解析器挂到控制器上（布局时消费一次）。
  ///
  /// 两个信号都走这里：[padAboveStamp]（整段在视口上方）与 [contentShiftStamp]
  /// （横跨视口顶 / 落在视口里）——补偿口径是同一套，锚点由
  /// [_resolveShiftAbove] 按"用户当时在看哪一条"现场判定。
  void _beginShiftCompensation() {
    final _BuiltTopsSnapshot? snapshot = _snapshotBuiltTops();
    _controller.resolveShiftAbove =
        snapshot == null ? null : () => _resolveShiftAbove(snapshot);
    _controller.shiftAbove = true;
  }

  /// 滚动定位到指定消息并短暂高亮。
  ///
  /// 兼容目标未构建（懒加载、目标在视口外）的情况：先按索引比例粗跳使目标进入构建
  /// 范围，下一帧重试精确定位；最终 [Scrollable.ensureVisible] 保证目标必达。
  /// **目标不在槽位表里**（还没加载）时直接返回：面板会先把它所在的那一段拉回来
  /// （见 message_panel 的 _locateMessage）。
  void _scrollToMessage(String id) {
    if (!_controller.hasClients) return;
    final int idx = widget.slots.indexWhere(
      (ChatMessage? m) => m?.id == id,
    );
    if (idx < 0) return;
    final GlobalKey? key = _itemKeys[id];
    final BuildContext? ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.2,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      setState(() {
        _highlightedId = id;
        // 定位到历史消息：视为用户脱离跟随（不把视口再拽回底部）
        _userDetached = true;
      });
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _highlightedId = null;
          });
        }
      });
    } else {
      // 目标尚未构建：按下标比例粗跳，下一帧重试精确定位
      if (_scrollRetries >= 2 || widget.slots.isEmpty) return;
      _scrollRetries++;
      final double ratio = widget.slots.length <= 1
          ? 0.0
          : idx / (widget.slots.length - 1);
      _controller.jumpTo(_controller.position.maxScrollExtent * ratio);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessage(id);
      });
    }
  }

  /// 滚动通知：在「跟随 / 阅读」两种模式间切换（完全贴底 → 跟随）。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollMetricsNotification) {
      // 内容尺寸变了（补页 / 流式增长）：视口区间可能跟着变，刷新一次坐标
      _scheduleCoordinateFlush();
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    // **滚动也要刷坐标**：滚动不重建父组件，只有这条路上能拿到新的视口区间
    // （用户 2026-10-03：「页面上滚，拇指不动」就是漏了这一步）。
    _scheduleCoordinateFlush();
    // 用户自己滚了 ⇒ 正在做的落点校正作废（不跟用户抢）
    if (!_programmaticJump) _cancelSeekCorrection();
    // 回底动画 / 程序化直达底部的中间帧不算用户上滚
    if (_returningToBottom) return false;
    if (_jumpingToBottom) return false;
    final ScrollMetrics m = notification.metrics;
    _setUserDetached(m.maxScrollExtent - m.pixels > _bottomEpsilon);
    return false;
  }

  /// 更新模式（仅在变化时 setState，驱动「回到底部」按钮显隐）
  void _setUserDetached(bool value) {
    if (_userDetached == value) return;
    setState(() {
      _userDetached = value;
    });
  }

  /// 平滑滚到底部并恢复跟随（没有 [MessageList.onReloadTail] 时的退路）。
  void _returnToBottom() {
    if (!_controller.hasClients) return;
    _setUserDetached(false);
    _returningToBottom = true;
    _controller
        .animateTo(
          _controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        )
        .whenComplete(() {
      _returningToBottom = false;
      if (!mounted || !_controller.hasClients) return;
      final ScrollPosition pos = _controller.position;
      _setUserDetached(pos.maxScrollExtent - pos.pixels > _bottomEpsilon);
    });
  }

  /// 拖到某个全局下标（右侧滑块）：按**坐标**算落点，帧后按实测落点校正。
  ///
  /// 落点为什么不能只算一次：`pixels ↔ 全局下标` 只是估算——占位槽恒定 88px
  /// （[kMessagePlaceholderExtent]），已加载消息的真实高度各不相同。所以：
  /// 先按 [pixelOffsetForIndex]（以视口第一条为锚点）跳过去，再由
  /// [MessageSeekCorrection] 用"实际落在哪"反馈修正（拖拽期间只粗跟，
  /// 松手时 [onSeekSettled] 收口，见 [_beginSeekCorrection]）。
  ///
  /// **下标的上限是"最后一条正好落在视口底"**（`total - 看得见的条数`）——滑块几何就是这么
  /// 定的（见 [messageScrollbarThumb]：看到末尾 = 贴底）。所以拖到最底下时必须**直达底部**，
  /// 否则会停在"最新那几条还差一屏"的地方。
  void _seekToIndex(int index) {
    if (!_controller.hasClients) return;
    // 新的落点请求作废上一次校正：别让两次校正互相甩
    _cancelSeekCorrection();
    final ScrollPosition pos = _controller.position;
    final MessageWindowCoordinate at = _coordinate.value;
    if (at.total > 0 && index >= at.lastSeekable) {
      _jumpTo(pos.maxScrollExtent);
      return;
    }
    _jumpTo(
      pixelOffsetForIndex(
        index: index,
        at: at,
        anchorPixels: pos.pixels,
        step: kMessagePlaceholderExtent,
      ).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  /// 我们自己发起的跳转：置标记，让滚动通知别把它当成"用户上滚"，也用来作废校正。
  void _jumpTo(double pixels) {
    if (!_controller.hasClients) return;
    _programmaticJump = true;
    _controller.jumpTo(pixels);
    WidgetsBinding.instance.addPostFrameCallback((_) => _programmaticJump = false);
  }

  /// 松手/点击之后：把落点校正到目标下标（≤[MessageSeekCorrection.maxAttempts] 次）。
  ///
  /// 用户的直觉是"拖到哪就停在哪"：拇指松手后画的是**真实坐标**，所以内容必须真的
  /// 落到那个下标附近——否则拇指会"回落"到内容真正所在的地方（用户 2026-10-03 报的
  /// 第 3 条：「松开后拇指回落到底部或顶部，但中间页面不会随其回落」）。
  void _beginSeekCorrection(int index) {
    if (!_controller.hasClients) return;
    if (!_coordinate.value.known) return;
    _seekCorrection = MessageSeekCorrection(
      target: index,
      step: kMessagePlaceholderExtent,
    );
    _pumpSeekCorrection();
  }

  /// 用**实测落点**推进校正：拿当前坐标（帧后刷新）当反馈，决定要不要再跳一次。
  void _pumpSeekCorrection() {
    final MessageSeekCorrection? correction = _seekCorrection;
    if (correction == null) return;
    if (correction.finished || !mounted || !_controller.hasClients) {
      _cancelSeekCorrection();
      return;
    }
    final MessageWindowCoordinate at = _coordinate.value;
    if (!at.known) return; // 还没量出来：等下一次坐标刷新
    final ScrollPosition pos = _controller.position;
    final double? next = correction.observe(
      landed: at.first,
      pixels: pos.pixels,
    );
    if (next == null) {
      _cancelSeekCorrection();
      return;
    }
    _jumpTo(next.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  void _cancelSeekCorrection() => _seekCorrection = null;

  /// 清掉已经不在槽位表里的 GlobalKey（只增不减的话，长会话里是一份隐性内存）。
  ///
  /// 阈值触发 + 整表扫一次：平时的开销是零，扫的时候是一次 O(条数)（稀有事件）。
  void _pruneItemKeys() {
    if (_itemKeys.length <= _itemKeysLimit) return;
    final Set<String> alive = <String>{
      for (final ChatMessage? m in widget.slots)
        if (m != null) m.id,
    };
    _itemKeys.removeWhere((String id, GlobalKey _) => !alive.contains(id));
  }

  /// 占位槽：**还没加载**的那一段（等高，见 [kMessagePlaceholderExtent]）。
  Widget _buildPlaceholder(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: kMessagePlaceholderExtent,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 180,
          height: 10,
          margin: const EdgeInsets.only(left: 6),
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(5),
          ),
        ),
      ),
    );
  }

  /// 一个槽位（或末尾的插件内联卡片）。
  Widget _buildItem(BuildContext context, int index) {
    final int slotCount = widget.slots.length;
    if (index >= slotCount) {
      // 消息之后的槽位让给插件内联卡片（Q12）：按到达顺序逐项渲染
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: widget.trailingCards[index - slotCount],
      );
    }
    if (_builtFirst < 0 || index < _builtFirst) _builtFirst = index;
    if (index > _builtLast) _builtLast = index;
    // 本帧有子项被构建 ⇒ 帧后刷新一次视口坐标（滚动时只有"新进视口"的子项会走到这里）
    _scheduleCoordinateFlush();
    final ChatMessage? message = widget.slots[index];
    if (message == null) return _buildPlaceholder(context);
    // 不进主消息流的那种（临时员工的消息）：零高度 —— 不占版面、也不打断下标连续性
    final bool Function(ChatMessage message)? visible = widget.visible;
    if (visible != null && !visible(message)) {
      return const SizedBox.shrink();
    }
    // 临时员工的消息：在他的那一段**开头**标一次（同一个人的连续消息/工具
    // 只在第一行顶标签，避免每条都占一行）。
    final ChatMessage? previous = index > 0 ? widget.slots[index - 1] : null;
    final bool showSubagentTag =
        message.isSubagentMessage &&
        (previous == null || previous.subagentId != message.subagentId);
    Widget child;
    if (message.kind == 'tool') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ToolCallCard(message: message),
      );
    } else if (message.kind == 'thinking') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ThinkingCard(message: message),
      );
    } else if (message.kind == 'ask_user_question') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _AskQuestionCard(
          message: message,
          onAnswer: widget.onAskAnswer,
        ),
      );
    } else if (message.kind == 'notice') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: HookNoticeCard(message: message),
      );
    } else {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _MessageBubble(message: message),
      );
    }
    if (showSubagentTag) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SubagentTagBar(
            name: message.subagentName,
            level: message.subagentLevel,
          ),
          child,
        ],
      );
    }
    // 定位目标：为每条消息挂 GlobalKey，命中定位时短暂高亮
    final GlobalKey key = _itemKeys.putIfAbsent(message.id, GlobalKey.new);
    final bool highlighted = _highlightedId == message.id;
    if (!highlighted) {
      return KeyedSubtree(key: key, child: child);
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary, width: 2),
      ),
      child: child,
    );
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _coordinate.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int slotCount = widget.slots.length;
    if (slotCount == 0 && widget.trailingCards.isEmpty) {
      // **加载中**（切 agent / 首载 / 切会话）：窗口本来就是空的，但这不是"没有消息"
      // ——渲染静态骨架，别闪空态（用户 2026-10-03 症状 1）。面板在历史真正落地
      // （或明确失败）之后才把 [MessageList.loading] 摘掉，那时才会走到下面的欢迎页。
      if (widget.loading) return _buildLoadingSkeleton(context);
      // 空态：居中排版，emoji 与文字分行（有插件卡片时不显示欢迎页）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('👋', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 8),
            Text(
              '你好，欢迎使用 Tree',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }
    // 本帧构建到哪由 _buildItem 收集（只是兜底）+ 渲染树读取（权威），见 [_flushCoordinate]。
    // 首帧也要安排一次：否则空表 / 全占位时坐标一直是 unknown（拇指不画）。
    _scheduleCoordinateFlush();
    return Stack(
      children: <Widget>[
        // 滚动通知：切换跟随/阅读模式（见 _onScrollNotification）
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          // **关掉桌面自动挂上的原生 Scrollbar**（用户 2026-10-03：「滑块乱跳」）：
          // 桌面 ScrollBehavior 会给每个竖向 Scrollable 自动包一条 Material Scrollbar
          // （`MaterialScrollBehavior.buildScrollbar`），它的几何来自**已构建内容**的
          // 估算范围（取回来的按真实高度、占位槽按占位高度，平均值随构建到哪而变）
          // ⇒ 窗口化列表里必然乱跳，而且就画在自绘的 MessageScrollbar 旁边（同一条窄带里
          // 两条拇指，一条稳一条跳）。这里只关滚动条（scrollbars: false），
          // 物理/越界指示/拖拽设备都保留。
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: ListView.builder(
              key: _listKey,
              controller: _controller,
              // 常规（非反转）布局：offset 0 = 顶部（最旧），maxScrollExtent = 底部。
              // 跟随模式下由 _BottomAnchorScrollPosition 在布局阶段同步钉底；
              // 阅读模式下不做任何补偿（零漂移）。
              // 右侧留出滑块的宽度（它画在列表之上、不占滚动区域）。
              padding: const EdgeInsets.only(
                left: 16,
                right: 24,
                top: 12,
                bottom: 12,
              ),
              itemCount: slotCount + widget.trailingCards.length,
              itemBuilder: _buildItem,
            ),
          ),
        ),
        // 右侧滑块：**按全局下标算几何**（用户 2026-10-04）——自带 Scrollbar 的
        // 几何来自"已构建内容"的估算范围，窗口化列表里会随滚动来回跳。
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 14,
          child: MessageScrollbar(
            coordinate: _coordinate,
            onSeek: _seekToIndex,
            onSeekSettled: _beginSeekCorrection,
          ),
        ),
        // 「回到底部」按钮：用户脱离跟随（向上查看历史）时显示，点击后**重载末尾
        // 一段**并回到最新（没有回调时退回平滑回底）。
        Positioned(
          right: 24,
          bottom: 16,
          child: AnimatedOpacity(
            opacity: _userDetached ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_userDetached,
              child: _buildScrollToBottomButton(),
            ),
          ),
        ),
      ],
    );
  }

  /// 加载中骨架：几条静态灰条（**不带任何动画**——加载指示器的循环动画会让
  /// `pumpAndSettle` 永不收敛，而"闪一下"本来就是这次要修的症状）。
  ///
  /// 用 [SingleChildScrollView] + 不可滚动物理包一层：窗口再矮也不会溢出
  /// （溢会在 widget 测试里直接抛错），同时不产生第二个可滚动位置。
  Widget _buildLoadingSkeleton(BuildContext context) {
    final Color bar = Theme.of(context).colorScheme.surfaceContainerHighest;
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 24, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final double widthFactor in <double>[0.45, 0.72, 0.55, 0.64, 0.5])
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(
                    height: 40,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: bar,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 「回到底部」悬浮按钮
  Widget _buildScrollToBottomButton() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '回到底部',
      child: Material(
        color: cs.surface,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _scrollToBottomFromButton,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              Icons.arrow_downward,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 点击「回到底部」：请面板**重载末尾一段**（落点确定，必然到底）；没有回调
  /// （别处复用本组件的场景）时退回平滑回底。
  void _scrollToBottomFromButton() {
    final VoidCallback? reload = widget.onReloadTail;
    if (reload != null) {
      _setUserDetached(false);
      reload();
      return;
    }
    _returnToBottom();
  }
}

/// 临时员工标记条（一行式消息流里「这一段是谁在说」）。
///
/// 为什么需要它：临时员工没有自己的会话，它的话与工具调用都写进**会话主人**的消息流
/// （`agent_id` 仍是主人，前端过滤口径不变），不打标就会看起来像主 agent 在说话。
/// 只在同一个临时员工的**那一段开头**画一次（见调用处的 `showSubagentTag`）。
class _SubagentTagBar extends StatelessWidget {
  const _SubagentTagBar({required this.name, required this.level});

  final String name;
  final int level;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String label = name.trim().isEmpty ? '未命名' : name.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Row(
        children: <Widget>[
          Icon(Icons.person_outline, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '临时员工「$label」 · 层级 $level',
              key: const ValueKey<String>('subagent-tag-bar'),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条消息气泡
///
/// 用户消息：右对齐，主色背景（浅色 #00904A + 白字 / 深色 #00FF8C + 墨绿字），
/// 文字用 onPrimary，保证对比度。
/// agent 消息：左对齐，背景 cs.surface（浅色白底 / 深色黑底），文字 onSurface
/// （浅色墨绿 / 深色浅绿白），边框 dividerColor。
/// 流式消息在内容末尾追加闪烁光标（"|" 与空格每 500ms 交替）。
/// 附件以小卡片形式展示在内容上方，含文件图标、文件名与大小。
class _MessageBubble extends StatefulWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  /// 光标闪烁定时器
  Timer? _timer;

  /// 当前是否显示光标（"|" 与空格交替）
  bool _showCursor = true;

  /// 鼠标是否悬停在气泡上（用于显示「复制全文」按钮）
  bool _hoverCopy = false;

  /// 气泡圆角
  static const double _radius = 12;

  @override
  void initState() {
    super.initState();
    if (widget.message.isStreaming) {
      _startBlinking();
    }
  }

  @override
  void didUpdateWidget(covariant _MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message.isStreaming && !oldWidget.message.isStreaming) {
      _startBlinking();
    } else if (!widget.message.isStreaming &&
        oldWidget.message.isStreaming) {
      _stopBlinking();
    }
  }

  /// 启动光标闪烁（每 500ms 切换一次）
  void _startBlinking() {
    _stopBlinking();
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (mounted) {
          setState(() {
            _showCursor = !_showCursor;
          });
        }
      },
    );
  }

  /// 停止光标闪烁
  void _stopBlinking() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopBlinking();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChatMessage message = widget.message;
    final bool isUser = message.isUser;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 气泡最大宽度：只留一小段内边距，不再按 70% 压缩。
        // 中栏被拖窄时（最小 360px）70% 只剩下 ~250px，右侧会空出一大片；
        // 留 7% 既能撑满可用宽度，又让左右气泡的对齐关系看得出来。
        final double maxBubbleWidth = constraints.maxWidth * 0.93;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: Container(
              padding: isUser
                  ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                  : const EdgeInsets.fromLTRB(12, 8, 14, 8),
              decoration: isUser
                  ? BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(_radius),
                    )
                  // 模型消息不给「边框盒子」，改成**高亮块**：左侧主色竖条 + 极淡的
                  // 同色底。盒子会把消息流切成一格一格，去掉之后整轮对话读起来是
                  // 连续的；竖条仍让人一眼认出「这段是模型说的」。
                  : BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.05),
                      border: Border(
                        left: BorderSide(
                          color: cs.primary.withValues(alpha: 0.6),
                          width: 3,
                        ),
                      ),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.attachments != null &&
                      message.attachments!.isNotEmpty) ...<Widget>[
                    _buildAttachments(isUser),
                    const SizedBox(height: 6),
                  ],
                  _buildContent(message, isUser),
                  const SizedBox(height: 4),
                  _buildTime(message, isUser),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 构建消息内容（流式时追加闪烁光标）
  Widget _buildContent(ChatMessage message, bool isUser) {
    // 用户气泡底色为 cs.primary（深色主题下为亮绿 #00FF8C），
    // 文字用 onPrimary（深色墨绿）保证对比度，避免白字在亮绿上看不清。
    final Color textColor = isUser
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurface;
    final String text = message.content;
    // 流式但尚无内容：仅显示闪烁光标
    if (message.isStreaming && text.isEmpty) {
      return Text(
        _showCursor ? '|' : ' ',
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (message.isStreaming) {
      return RichText(
        text: TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: text,
              style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
            ),
            TextSpan(
              text: _showCursor ? '|' : ' ',
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    // 用户消息保持纯文本（可选中复制）
    if (isUser) {
      return SelectableText(
        text,
        style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
      );
    }
    // agent 消息渲染 markdown（模型输出默认 markdown 格式）
    // - selectable: true → 段落/代码块内可任意框选复制（Flutter 3.7 下
    //   SelectionArea 无法选择 flutter_markdown 输出的 RichText，故启用
    //   markdown 自带选择模式；跨段落一次性拖选不受支持）
    // - hover 显示「复制全文」按钮（跨段落整条复制兜底）
    return _buildMarkdownContent(message, textColor);
  }

  /// 构建 agent 消息的 markdown 内容：可选择文本 + hover「复制全文」按钮
  Widget _buildMarkdownContent(ChatMessage message, Color textColor) {
    final bool streaming = message.isStreaming;
    return MouseRegion(
      onEnter: (_) {
        setState(() {
          _hoverCopy = true;
        });
      },
      onExit: (_) {
        setState(() {
          _hoverCopy = false;
        });
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // selectable: true → 段落/代码块内可框选复制（跨段落复制用「复制全文」）
          // 正文字重 w500 + 行距 1.55：跟工具行 / 思考行（12.5 常规体）拉开层次，
          // 模型的话一眼就是「正文」，工具与思考是「脚注」。
          MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                fontSize: 14,
                height: 1.55,
                fontWeight: FontWeight.w500,
                color: textColor,
              ),
            ),
          ),
          // 流式输出中不显示复制按钮（内容仍在变化）
          if (_hoverCopy && !streaming)
            Positioned(
              top: -8,
              right: -8,
              child: _buildCopyButton(),
            ),
        ],
      ),
    );
  }

  /// 「复制全文」按钮：复制原始 markdown 文本到剪贴板
  Widget _buildCopyButton() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _copyFullText,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy, size: 12, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                '复制',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 复制消息全文（原始 markdown 内容）
  Future<void> _copyFullText() async {
    await Clipboard.setData(ClipboardData(text: widget.message.content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制全文'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  /// 构建时间戳（小号灰色文字，含日期：MM-dd HH:mm，跨年补年份）
  Widget _buildTime(ChatMessage message, bool isUser) {
    final DateTime t = message.timestamp;
    final String mm = t.month.toString().padLeft(2, '0');
    final String dd = t.day.toString().padLeft(2, '0');
    final String hour = t.hour.toString().padLeft(2, '0');
    final String minute = t.minute.toString().padLeft(2, '0');
    final String date = t.year == DateTime.now().year
        ? '$mm-$dd'
        : '${t.year}-$mm-$dd';
    final Color color = isUser
        ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)
        : Theme.of(context).colorScheme.outline;
    return Text(
      '$date $hour:$minute',
      style: TextStyle(fontSize: 11, color: color),
    );
  }

  /// 构建附件卡片列表
  Widget _buildAttachments(bool isUser) {
    final List<Attachment> attachments = widget.message.attachments!;
    final cs = Theme.of(context).colorScheme;
    final Color textColor = isUser ? cs.onPrimary : cs.onSurface;
    final Color subColor =
        isUser ? cs.onPrimary.withValues(alpha: 0.7) : cs.onSurfaceVariant;
    final Color borderColor =
        isUser ? cs.onPrimary.withValues(alpha: 0.3) : Theme.of(context).dividerColor;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: attachments.map((Attachment a) {
        final Widget card = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isUser ? cs.onPrimary.withValues(alpha: 0.08) : cs.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.insert_drive_file, size: 16, color: subColor),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                    Text(
                      _formatSize(a.size),
                      style: TextStyle(fontSize: 10, color: subColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        // 附件在**工作空间**里的相对路径（发送时上传得到，核心把它写进提示词）。
        // 只是提示，不占版面；旧数据没有该字段时不显示。
        if (a.path.isEmpty) return card;
        return Tooltip(message: '工作空间路径：${a.path}', child: card);
      }).toList(),
    );
  }

  /// 格式化文件大小
  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unitIdx = 0;
    while (size >= 1024 && unitIdx < units.length - 1) {
      size /= 1024;
      unitIdx++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unitIdx]}';
  }
}

/// 内联提问卡片（AskUserQuestion 的非阻塞展示）
///
/// 替代全屏遮罩对话框：提问以卡片形式插入消息流，答题者仍可滚动查看
/// 模型最近输出与右侧信息后再做决策。点击选项或输入自由文本后回调
/// [onAnswer]，由父级发送 user_answer 并置位 answered 禁用输入。
class _AskQuestionCard extends StatefulWidget {
  final ChatMessage message;
  final void Function(String messageId, String answer)? onAnswer;

  const _AskQuestionCard({required this.message, this.onAnswer});

  @override
  State<_AskQuestionCard> createState() => _AskQuestionCardState();
}

class _AskQuestionCardState extends State<_AskQuestionCard> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String text = _controller.text.trim();
    if (widget.message.answered || text.isEmpty) return;
    final void Function(String, String)? onAnswer = widget.onAnswer;
    if (onAnswer == null) return;
    _controller.clear();
    onAnswer(widget.message.id, text);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ChatMessage message = widget.message;
    final bool enabled = !message.answered && widget.onAnswer != null;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.primary, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.help_outline, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  message.answered ? '已提交你的选择' : 'Agent 需要你的输入',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              message.content.isEmpty ? '提问' : message.content,
              style: TextStyle(fontSize: 14, color: cs.onSurface, height: 1.4),
            ),
            if (message.options.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              for (final String option in message.options)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: enabled
                          ? () => widget.onAnswer!(message.id, option)
                          : null,
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            message.answered
                                ? Icons.check_circle_outline
                                : Icons.radio_button_unchecked,
                            size: 16,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              option,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 10),
            // 或直接输入回答
            TextField(
              controller: _controller,
              enabled: enabled,
              maxLines: 2,
              minLines: 1,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '或直接输入回答…',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: enabled ? _submit : null,
                  icon: const Icon(Icons.send, size: 18),
                  tooltip: '发送',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
