import 'package:flutter/foundation.dart';

/// 提问数据变更通知（右侧「问题回复」页的全局刷新信号）。
///
/// 中栏 MessagePanel 在收到新提问 / 作答后调用 [notifyChanged]，右栏
/// QuestionPanel 监听后重新拉取列表，实现「中栏 → 右栏」实时同步。
///
/// 提问/作答事件频率低，无需节流合并，直接透传通知。
class QuestionUpdateService extends ChangeNotifier {
  QuestionUpdateService._();

  static final QuestionUpdateService instance = QuestionUpdateService._();

  void notifyChanged() => notifyListeners();
}
