import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/message.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

/// 消息列表组件（StatelessWidget）
///
/// 渲染中栏消息列表。用户消息右对齐（蓝色气泡），agent 消息左对齐
/// （白色气泡 + 灰色边框）。流式消息在内容末尾显示闪烁光标。
/// 附件以卡片形式展示。消息更新时自动滚动到底部。
///
/// 内部通过私有 StatefulWidget [_MessageListView] 管理滚动控制器，
/// 以实现自动滚动；通过 [_MessageBubble] 管理光标闪烁定时器。
class MessageList extends StatelessWidget {
  /// 待渲染的消息列表
  final List<ChatMessage> messages;

  /// 消息版本号：每次消息列表发生结构性变化（新增/清空重载）时递增，
  /// 用于触发滚动到底部。由于 [messages] 是同一个可变列表引用，
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
  /// 历史整批重载（切会话/切 agent/清空重拉）传 true：恢复跟随并直达底部
  /// （本帧布局阶段同步钉底）。流式追加/增量更新传 false：跟随模式下同步
  /// 钉底；阅读模式下不做任何补偿（视口保持不动）。
  final bool bottomJump;

  /// 消息流末尾追加的**插件内联卡片**（Q12）：按到达顺序排在最后一条消息之后。
  ///
  /// 单独用 Widget 列表而不是协议模型：消息列表只负责"在流里让出一段位置"，
  /// 卡片内容（渲染、动作回插件）由 lib/ui/widgets/plugin_ui_slots.dart 负责。
  final List<Widget> trailingCards;

  const MessageList({
    super.key,
    required this.messages,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.trailingCards = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    return _MessageListView(
      messages: messages,
      revision: revision,
      onAskAnswer: onAskAnswer,
      scrollToMessageId: scrollToMessageId,
      scrollToRevision: scrollToRevision,
      bottomJump: bottomJump,
      trailingCards: trailingCards,
    );
  }
}

/// 内部带滚动控制的状态视图
///
/// 维护 [ScrollController]，在 [revision] 变化时自动滚动到底部
/// （覆盖新增消息、切换 agent 重载历史、流式追加等场景）。
class _MessageListView extends StatefulWidget {
  final List<ChatMessage> messages;
  final int revision;
  final void Function(String messageId, String answer)? onAskAnswer;
  final String? scrollToMessageId;
  final int scrollToRevision;
  final bool bottomJump;
  final List<Widget> trailingCards;

  const _MessageListView({
    required this.messages,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.trailingCards = const <Widget>[],
  });

  @override
  State<_MessageListView> createState() => _MessageListViewState();
}

/// 底部锚定滚动控制器：把「钉在底部」做成**布局同帧**的同步操作。
///
/// 列表为常规（非反转）布局：offset 0 在顶部，`maxScrollExtent` 即底部。
/// - 跟随模式：内容变化时在布局阶段把 offset 同步钉到 `maxScrollExtent`
///   （早于绘制，无「先位移一帧再拉回」的逐帧闪烁抖动）。
/// - 阅读模式：**不做任何校正**。常规布局下在末尾追加/增长内容不会移动
///   已渲染内容的坐标，视口天然稳定，因此零漂移（无需任何 offset 补偿）。
class _BottomAnchorScrollController extends ScrollController {
  _BottomAnchorScrollController({required this.shouldFollow});

  /// 是否处于跟随模式（需要钉底）
  final bool Function() shouldFollow;

  /// 是否需要把 offset 钉到底部：内容变化/首帧时由 State 置位，布局时消费。
  bool pinToBottom = false;

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

/// 见 [_BottomAnchorScrollController]：在布局阶段把 offset 同步钉到底部。
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
    if (ok && controller.pinToBottom && controller.shouldFollow()) {
      controller.pinToBottom = false; // 消费一次
      if ((pixels - maxScrollExtent).abs() > 0.01) {
        correctPixels(maxScrollExtent.clamp(minScrollExtent, maxScrollExtent));
        // 返回 false 请求 RenderViewport 用校正后的 offset 同帧重跑布局：
        // 绘制前即已贴底（下一次迭代残差归零 → 返回 true 收敛）。
        return false;
      }
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

  /// 「回到底部」动画进行中：期间的中间位置不算用户上滚（避免刚点回底
  /// 就被判定为阅读模式）。
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

  @override
  void initState() {
    super.initState();
    _controller = _BottomAnchorScrollController(
      shouldFollow: () => !_userDetached,
    );
    // 首帧即把视口钉到底部（最新消息），避免「顶部闪一下再落底」。
    _controller.pinToBottom = true;
  }

  @override
  void didUpdateWidget(covariant _MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      if (widget.bottomJump) {
        // 历史整批重载（切会话/切 agent/清空重拉）：恢复跟随并直达底部
        _userDetached = false;
        _schedulePin();
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

  /// 滚动定位到指定消息并短暂高亮。
  ///
  /// 兼容目标未构建（ListView.builder 懒加载、目标在视口外）的情况：
  /// 先按索引比例粗跳使目标进入构建范围，下一帧重试精确定位；最终
  /// [Scrollable.ensureVisible] 保证目标必达。
  void _scrollToMessage(String id) {
    if (!_controller.hasClients) return;
    final int idx = widget.messages.indexWhere((ChatMessage m) => m.id == id);
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
      // 目标尚未构建：按索引比例粗跳，下一帧重试精确定位
      if (_scrollRetries >= 2 || widget.messages.isEmpty) return;
      _scrollRetries++;
      // 常规布局：idx 越靠后（越新）越靠近底部（offset 越大），按比例粗跳
      // 使目标进入构建范围。
      final double ratio = widget.messages.length <= 1
          ? 0.0
          : idx / (widget.messages.length - 1);
      _controller.jumpTo(_controller.position.maxScrollExtent * ratio);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessage(id);
      });
    }
  }

  /// 滚动通知：在「跟随 / 阅读」两种模式间切换。
  ///
  /// - 完全贴底（与底部距离 ≤ [_bottomEpsilon]）→ 跟随模式；
  /// - 任意一次离开底部的滚动（拖拽 / 滚轮 / 触控板 / 拖动滚动条）→
  ///   立即进入阅读模式。
  ///
  /// 跟随模式下的贴底由 [_BottomAnchorScrollPosition] 在布局阶段同步完成，
  /// 不产生中间位移，故这里的「离开底部」只可能来自用户输入。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    // 回底动画的中间帧不算用户上滚
    if (_returningToBottom) return false;
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

  /// 平滑滚到底部并恢复跟随（点击「回到底部」按钮）。
  ///
  /// 动画完成后按落点重新结算模式：若被用户中途打断则回到阅读模式；
  /// 否则已贴底、保持跟随。使用 whenComplete：动画被拖拽打断或组件被移除
  /// 时 future 均会完成，不会挂起。
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

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty && widget.trailingCards.isEmpty) {
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
    return Stack(
      children: <Widget>[
        // 滚动通知：切换跟随/阅读模式（见 _onScrollNotification）
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ListView.builder(
            controller: _controller,
            // 常规（非反转）布局：offset 0 = 顶部（最旧），maxScrollExtent = 底部。
            // 跟随模式下由 _BottomAnchorScrollPosition 在布局阶段同步钉底
            // （首帧即贴底，无「顶部闪一下再落底」）；阅读模式下不做任何补偿，
            // 末尾新增内容天然不影响已渲染内容的位置（零漂移）。
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: widget.messages.length + widget.trailingCards.length,
            itemBuilder: (BuildContext context, int index) {
              // 消息之后的槽位让给插件内联卡片（Q12）：按到达顺序逐项渲染，
              // 位置 = 消息流末尾（最新消息之后），与流式追加同一个滚动语义。
              if (index >= widget.messages.length) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: widget.trailingCards[index - widget.messages.length],
                );
              }
              // 常规布局：index 递增 = 由旧到新，最新消息在底部
              final ChatMessage message = widget.messages[index];
              // 工具调用卡片：默认折叠，独立渲染
              Widget child;
              if (message.kind == 'tool') {
                child = Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ToolCallCard(message: message),
                );
              } else if (message.kind == 'thinking') {
                // 思考（推理）卡片：默认折叠，可展开查看完整推理内容
                child = Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ThinkingCard(message: message),
                );
              } else if (message.kind == 'ask_user_question') {
                // 内联提问卡片：非阻塞，允许查看上下文与右侧信息后再作答
                child = Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _AskQuestionCard(
                    message: message,
                    onAnswer: widget.onAskAnswer,
                  ),
                );
              } else {
                child = Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _MessageBubble(message: message),
                );
              }
              // 定位目标：为每条消息挂 GlobalKey，命中定位时短暂高亮
              final GlobalKey key =
                  _itemKeys.putIfAbsent(message.id, GlobalKey.new);
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
            },
          ),
        ),
        // 「回到底部」按钮：用户脱离跟随（向上查看历史）时显示，
        // 点击后平滑回到底部并恢复自动跟随
        Positioned(
          right: 16,
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

  /// 点击「回到底部」：恢复跟随并平滑滚到底
  void _scrollToBottomFromButton() {
    _returnToBottom();
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
        // 气泡最大宽度为父容器 70%
        final double maxBubbleWidth = constraints.maxWidth * 0.7;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: isUser ? cs.primary : cs.surface,
                borderRadius: BorderRadius.circular(_radius),
                border: isUser
                    ? null
                    : Border.all(color: Theme.of(context).dividerColor),
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
          MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
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
