library;

import 'package:flutter/foundation.dart';

/// 引导「带我过去」用到的两个**全局请求**（与 [TerminalToggleRequest] 同一范式）。
///
/// 为什么不让引导直接摸控件：这两件事**只有中栏的消息面板做得了**——预填要落在"当前
/// agent + 当前会话"那个输入框上，选目录要用它手里那份 agent 配置。引导在 MainPage 里，
/// 跨着面板，所以只广播"要做这件事"，由面板按自己的上下文落地。

/// 「把这段文字预填进输入框」请求（**不自动发送**）。
class ComposerPrefillRequest extends ChangeNotifier {
  ComposerPrefillRequest._();

  static final ComposerPrefillRequest instance = ComposerPrefillRequest._();

  String _text = '';
  int _revision = 0;

  /// 要填进输入框的文本。
  String get text => _text;

  /// 请求次数（每次 [request] 自增；监听方据此判断"这是一次新请求"）。
  int get revision => _revision;

  /// 请求预填 [text]（光标落到位、输入框拿到焦点；要发送得用户自己按）。
  void request(String text) {
    _text = text;
    _revision++;
    notifyListeners();
  }
}

/// 「弹出工作目录选择器」请求（引导第 4 步用）。
///
/// 落地口径与中栏左上角那颗目录按钮**完全一致**（含"成员写的是团队 TOP"、SSH 团队拒绝
/// 切本地这些规则），因为就是同一条代码路径。
class WorkspacePickRequest extends ChangeNotifier {
  WorkspacePickRequest._();

  static final WorkspacePickRequest instance = WorkspacePickRequest._();

  int _revision = 0;

  int get revision => _revision;

  /// 请求打开工作目录选择器。
  void request() {
    _revision++;
    notifyListeners();
  }
}
