import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/message.dart';
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

  /// 本帧构建到的下标区间（帧后回调；面板据此补页 + 淘汰）。
  final void Function(int first, int last)? onWindowChanged;

  /// 「回到底部」：请面板重载末尾一段（空 = 退回旧的平滑回底行为）。
  final VoidCallback? onReloadTail;

  /// 消息流末尾追加的**插件内联卡片**（Q12）：按到达顺序排在最后一条消息之后。
  final List<Widget> trailingCards;

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
    this.onWindowChanged,
    this.onReloadTail,
    this.trailingCards = const <Widget>[],
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
      onWindowChanged: onWindowChanged,
      onReloadTail: onReloadTail,
      trailingCards: trailingCards,
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
  final void Function(int first, int last)? onWindowChanged;
  final VoidCallback? onReloadTail;
  final List<Widget> trailingCards;

  const _MessageListView({
    required this.slots,
    this.visible,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.padAboveStamp = 0,
    this.onWindowChanged,
    this.onReloadTail,
    this.trailingCards = const <Widget>[],
  });

  @override
  State<_MessageListView> createState() => _MessageListViewState();
}

/// 占位槽的高度（px）。**固定值**：滑块的下标换算、以及"拖到某个下标"的落点估算
/// 都建立在"没加载的那一段每格一样高"这个前提上（见 [MessageScrollbar]）。
const double kMessagePlaceholderExtent = 88;

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

  /// 视口**上方**刚补了页：布局阶段按内容高度差把 offset 往下挪同样多。
  bool shiftAbove = false;

  /// 上一帧内容的总高度（-1 = 还不知道）。用来判断"刚才是不是贴着底"。
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
    // **粘底**：请求贴底（首帧 / 历史重载 / 追加），或者上一帧我们本来就贴着底。
    //
    // 为什么"本来就贴着底"也算一次：列表的滚动范围是**估算**的，随着视口周围
    // 构建出真实内容，maxScrollExtent 还会再长——只认一次性的请求就会停在半路。
    // 用户一旦上滚，pixels 立刻离开 max，这里就不再校正。
    final bool glued =
        controller.lastMaxExtent >= 0 &&
        (pixels - controller.lastMaxExtent).abs() <= 1.0;
    // 上方刚补过页：**标记一定要消费掉**（跟随模式下由贴底接管，不能留到以后
    // 阅读模式下突然生效）；只有"不在跟随"时才需要自己补偿。
    final bool shiftAbove = controller.shiftAbove;
    controller.shiftAbove = false;
    final double delta = controller.lastMaxExtent >= 0
        ? maxScrollExtent - controller.lastMaxExtent
        : 0;
    controller.lastMaxExtent = maxScrollExtent;
    if (shiftAbove && !following) {
      if (delta.abs() > 0.01) {
        // 上方补页只会让"上面的高度"变多：把 offset 加同样多，正在看的那一段
        // 就还在原地。返回 false 请求同帧重跑布局（绘制前就已补偿，不闪）。
        correctPixels(
          (pixels + delta).clamp(minScrollExtent, maxScrollExtent),
        );
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
  /// 面板的"滑到哪加载哪"与"限制缓存长度"都以此为视口口径（见 [MessageList.onWindowChanged]）。
  int _builtFirst = -1;
  int _builtLast = -1;

  /// 上一次报给面板（同时也是滑块几何的输入）的下标区间。
  int _reportedFirst = -1;
  int _reportedLast = -1;

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
  }

  @override
  void didUpdateWidget(covariant _MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板在**视口上方**补了页：占位槽换成真消息会改变上面的高度，布局阶段补回来
    if (oldWidget.padAboveStamp != widget.padAboveStamp) {
      _controller.shiftAbove = true;
    }
    if (oldWidget.revision != widget.revision) {
      // 槽位表变了：强制再报一次窗口（面板可能还要补页 / 淘汰）
      _reportedFirst = -1;
      _reportedLast = -1;
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

  /// 帧后把**本帧构建到的下标区间**报给面板（补页 / 淘汰的视口口径），
  /// 同时刷新右侧滑块的几何。
  void _flushWindow() {
    if (!mounted || _builtFirst < 0) return;
    if (_builtFirst == _reportedFirst && _builtLast == _reportedLast) return;
    setState(() {
      _reportedFirst = _builtFirst;
      _reportedLast = _builtLast;
    });
    widget.onWindowChanged?.call(_builtFirst, _builtLast);
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
    if (notification is! ScrollUpdateNotification) return false;
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

  /// 拖到某个全局下标（右侧滑块）：先按"占位槽高度 × 下标"落到大致位置，
  /// 帧后报窗口时面板会补那一段；落点准不准只影响滑动的手感，不影响正确性。
  ///
  /// **下标的上限是"最后一条正好落在视口底"**（`total - 看得见的条数`）——滑块几何就是这么
  /// 定的（见 [messageScrollbarThumb]：看到末尾 = 贴底）。所以拖到最底下时必须**直达底部**，
  /// 否则会停在"最新那几条还差一屏"的地方。
  void _seekToIndex(int index) {
    if (!_controller.hasClients) return;
    final ScrollPosition pos = _controller.position;
    final int total = widget.slots.length;
    final int visible =
        _reportedLast < _reportedFirst ? 1 : _reportedLast - _reportedFirst + 1;
    final int lastFirst = (total - visible).clamp(0, total - 1);
    if (index >= lastFirst) {
      _controller.jumpTo(pos.maxScrollExtent);
      return;
    }
    final double target = (index * kMessagePlaceholderExtent).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    _controller.jumpTo(target);
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int slotCount = widget.slots.length;
    if (slotCount == 0 && widget.trailingCards.isEmpty) {
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
    // 本帧构建到哪（见 _flushWindow）：每帧重置，itemBuilder 里重新量
    _builtFirst = -1;
    _builtLast = -1;
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushWindow());
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
            total: slotCount,
            firstVisible: _reportedFirst,
            lastVisible: _reportedLast,
            onSeek: _seekToIndex,
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
