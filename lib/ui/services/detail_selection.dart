import 'package:flutter/foundation.dart';

import '../models/message.dart';

/// 中栏 → 右栏「详情」页的选中项。
///
/// 为什么用一个全局可监听对象：点击发生在消息流深处（MessageList → 工具行 / 思考行），
/// 要打开的页面在右栏（FilePanel），两边隔着 main_page 的三栏骨架与四个构造函数。
/// 这个仓库本来就有同类做法（MessageDraftCache 的草稿、PluginUiRegistry 的槽位），
/// 所以这里沿用「一个全局对象 + 单向写入」的形态，不穿透回调。
///
/// 为什么存**消息快照**而不是 id：右栏拿不到中栏的消息表。跑着的工具 / 思考内容是
/// **原地变更**的（同一个 ChatMessage 实例），所以刷新一律 notifyListeners——
/// 只认 id 覆盖引用，绝不让别人的内容顶上来。
class DetailSelection extends ChangeNotifier {
  DetailSelection._();

  /// 全局单例：点它的地方在中栏，读它的地方在右栏
  static final DetailSelection instance = DetailSelection._();

  ChatMessage? _message;

  /// 当前选中的消息；null = 没有选中（详情页显示空态）
  ChatMessage? get message => _message;

  /// 当前选中项的消息 id（null = 未选中）
  String? get selectedId => _message?.id;

  /// 选中一条消息（点工具行 / 思考行时调用）
  void select(ChatMessage message) {
    _message = message;
    notifyListeners();
  }

  /// 清空选中（详情页的关闭按钮、切 agent / 会话时调用）
  void clear() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  /// 消息流更新后同步同一 id 的快照。
  ///
  /// 不改变选中项、不因为「消息表里没有它了」就清空：删除 / 切会话导致的消失由调用方
  /// 显式 [clear]——否则用户刚点开的内容会在一次刷新里悄悄变空。
  void refresh(Iterable<ChatMessage> messages) {
    if (_message == null) return;
    for (final ChatMessage message in messages) {
      if (message.id != _message!.id) continue;
      if (!identical(message, _message)) _message = message;
      // 原地变更的内容（流式追加）也必须通知，否则详情页停在旧文本上
      notifyListeners();
      return;
    }
  }
}
