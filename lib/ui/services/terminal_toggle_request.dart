import 'package:flutter/foundation.dart';

/// 「唤起集成终端」的**全局请求**（Ctrl+J：焦点不在输入框时也要能用）。
///
/// 为什么需要它，而不是像以前那样只在消息面板里挂一个 CallbackShortcuts：
/// 按键在 Flutter 里是沿**当前焦点**一路向父级冒泡的，面板那套是**焦点本地**的——焦点
/// 一旦被文件面板 / 右栏 / 消息列表里的可选文本拿走，按键就再也冒不到那个节点，Ctrl+J
/// 随即失效（用户 2026-10-03 反馈的现象）。
///
/// 现在由 MainPage 在三栏共同的祖先上挂一个 Focus(canRequestFocus: false) 当
/// 「事件驿站」，只要焦点还在主页范围内就一定能冒泡到它；而**真正切换终端的逻辑仍归
/// 消息面板**（只有它知道终端开在哪个 agent 上），所以这里只做一件事：广播一次请求。
///
/// 刻意不用 MaterialApp.shortcuts 或全局 HardwareKeyboard handler：那会把
/// **对话框与独立窗口**也算进来（在设置对话框里按 Ctrl+J 去开背后的终端没有意义）；
/// 挂在主页这一层天然把路由排除在外——它们不在这棵焦点树里。
class TerminalToggleRequest extends ChangeNotifier {
  TerminalToggleRequest._();

  /// 全局单例（与 DetailSelection / EditorSettings 同一范式）。
  static final TerminalToggleRequest instance = TerminalToggleRequest._();

  int _revision = 0;

  /// 请求次数（每次 [request] 自增；测试与观测用）。
  int get revision => _revision;

  /// 请求切换一次终端（谁切换、给哪个 agent，由监听方定义）。
  void request() {
    _revision++;
    notifyListeners();
  }
}
