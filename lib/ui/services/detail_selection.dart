import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../io/api_service.dart';
import '../models/message.dart';

/// 中栏 → 右栏「详情」页的选中项。
///
/// 为什么用一个全局可监听对象：点击发生在消息流深处（MessageList → 工具行 / 思考行），
/// 要打开的页面在右栏（FilePanel），两边隔着 main_page 的三栏骨架与四个构造函数。
/// 这个仓库本来就有同类做法（MessageDraftCache 的草稿），
/// 所以这里沿用「一个全局对象 + 单向写入」的形态，不穿透回调。
///
/// 为什么存**消息快照**而不是 id：右栏拿不到中栏的消息表。跑着的工具 / 思考内容是
/// **原地变更**的（同一个 ChatMessage 实例），所以刷新一律 notifyListeners——
/// 只认 id 覆盖引用，绝不让别人的内容顶上来。
///
/// 显示/详细两分（规格 §3.1.3/§3.1.4）：历史列表回的是轻量**显示行**（没有
/// tool_arguments / tool_result / thinking 正文），选中这种行时 [toggle] 会
/// **即查详情端点**、把快照换成全量副本——详情**不回写槽位表、不缓存**
/// （右栏关闭即 [clear] 释放）。在途消息（流式 / 工具在跑）内存里本来就是全量，
/// 不查库。
class DetailSelection extends ChangeNotifier {
  DetailSelection._();

  /// 全局单例：点它的地方在中栏，读它的地方在右栏
  static final DetailSelection instance = DetailSelection._();

  /// 详情即查函数（测试可注入替身；生产恒走委派详情端点）。
  static Future<Map<String, dynamic>> Function(
    String agentId,
    String messageId,
    String sessionId,
  ) detailFetcher = (
    String agentId,
    String messageId,
    String sessionId,
  ) => ApiService.getMessageDetail(agentId, messageId, sessionId: sessionId);

  ChatMessage? _message;

  /// 当前快照是不是**即查回来的全量详情**：是的话 [refresh] 不许把它降级回显示行。
  bool _detailFetched = false;

  /// 当前选中的消息；null = 没有选中（详情页显示空态）
  ChatMessage? get message => _message;

  /// 当前选中项的消息 id（null = 未选中）
  String? get selectedId => _message?.id;

  Widget? _injected;

  /// 注入右栏的**整页内容**（插件面板点卡片进详情页时调用 [inject]）。
  ///
  /// 为什么不走 Navigator.push：详情页要与中栏消息选中共用右栏那一格
  /// （用户 2026-10-18 定稿：详情页不再全屏 push），而右栏在窄屏折叠时根本没有
  /// 自己的路由栈可言。注入态下 DetailPanel 直接返回这一页（它自带 Scaffold/AppBar，
  /// 由详情页自己负责关闭——AppBar 上的 × 调 [clear]）。
  Widget? get injected => _injected;

  /// 选中一条消息（点工具行 / 思考行时调用）。
  ///
  /// 消息选中与注入详情**互斥**：右栏一格只能显示一种内容。
  void select(ChatMessage message) {
    _message = message;
    _detailFetched = false;
    _injected = null;
    notifyListeners();
  }

  /// 注入一页详情（插件面板点卡片时调用），同时清掉消息选中。
  void inject(Widget page) {
    _injected = page;
    _message = null;
    notifyListeners();
  }

  /// 清空选中（详情页的关闭按钮、切 agent / 会话时调用）
  /// 点一下卡片：选中它；**再点一次同一条就取消选中**。
  ///
  /// 用户 2026-10-04：「点击工具卡片后详情页显示对应工具详情，再点击一次工具卡片就取消
  /// （省的还要把鼠标移到详情页点「关闭详情」）」——工具行与思考行共用这一条，
  /// 两边的行为必须一致（一个能取消、一个不能会很别扭）。
  void toggle(ChatMessage message) {
    if (selectedId == message.id) {
      clear();
      return;
    }
    select(message);
    // 显示行没有详细数据：按 id 即查详情端点，查到后把快照换成全量副本。
    // 只替换这里的快照——槽位表仍是显示行（详情不缓存，右栏关闭即释放）。
    if (_needsDetail(message)) {
      unawaited(_fetchDetail(message));
    }
  }

  /// 这条消息要不要即查详情：只有**已封口**的工具 / 思考显示行要。
  ///
  /// 在途消息（流式中 / 工具在跑）内存里就是全量、还随帧原地更新，查库反而
  /// 拿旧快照顶掉实时内容；其余 kind（文本气泡 / 提问 / 汇报）正文本身就是
  /// 显示数据，没有详情层。
  static bool _needsDetail(ChatMessage m) {
    if (m.isStreaming || m.toolRunning) return false;
    if (m.agentId.isEmpty) return false; // 没有寻址坐标，查不了
    switch (m.kind) {
      case 'tool':
        return (m.toolArguments == null || m.toolArguments!.isEmpty) &&
            m.toolResult.isEmpty;
      case 'thinking':
        return m.content.isEmpty;
      default:
        return false;
    }
  }

  /// 即查详情并把快照升级成全量副本（**不缓存**：失败就停在显示行上）。
  Future<void> _fetchDetail(ChatMessage light) async {
    try {
      final Map<String, dynamic> json = await detailFetcher(
        light.agentId,
        light.id,
        light.sessionId,
      );
      // 查询途中可能已取消 / 换了选中：仍指向这一条才替换
      if (_message?.id != light.id) return;
      _message = ChatMessage.fromJson(json);
      _detailFetched = true;
      notifyListeners();
    } catch (_) {
      // 查不到：保持显示行快照（右栏显示头部与空正文），不清空选中、不弹错
    }
  }

  void clear() {
    if (_message == null && _injected == null) return;
    _message = null;
    _detailFetched = false;
    _injected = null;
    notifyListeners();
  }

  /// 消息流更新后同步同一 id 的快照。
  ///
  /// 不改变选中项、不因为「消息表里没有它了」就清空：删除 / 切会话导致的消失由调用方
  /// 显式 [clear]——否则用户刚点开的内容会在一次刷新里悄悄变空。
  ///
  /// **即查回来的全量详情不参与同步**：槽位表里现在存的是轻量显示行，
  /// 拿显示行覆盖已查到的详情 = 把用户正在看的内容降级回空壳。
  void refresh(Iterable<ChatMessage> messages) {
    if (_message == null || _detailFetched) return;
    for (final ChatMessage message in messages) {
      if (message.id != _message!.id) continue;
      if (!identical(message, _message)) _message = message;
      // 原地变更的内容（流式追加）也必须通知，否则详情页停在旧文本上
      notifyListeners();
      return;
    }
  }
}
