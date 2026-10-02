import 'package:flutter/material.dart';

/// 「关闭窗口 = 最小化到托盘」的**一次性**说明结果。
class CloseToTrayChoice {
  const CloseToTrayChoice({required this.hideToTray, required this.remember});

  /// true = 关闭窗口只隐藏到托盘；false = 现在就退出。
  final bool hideToTray;

  /// 是否把这次选择记成默认（勾了「记住我的选择」）。
  final bool remember;
}

/// 首次点关闭按钮时的说明对话框。
///
/// 为什么要有它：默认行为是"窗口消失、进程还在"——不解释一次，用户的第一反应是
/// "应用崩了/被关掉了"，然后去任务管理器杀进程（正在跑的任务因此真被打断）。
/// 这里把默认行为讲清楚，并让用户**一次性选定**以后的行为（取消/ESC = 按默认隐藏）。
class CloseToTrayDialog extends StatefulWidget {
  const CloseToTrayDialog({super.key});

  @override
  State<CloseToTrayDialog> createState() => _CloseToTrayDialogState();
}

class _CloseToTrayDialogState extends State<CloseToTrayDialog> {
  /// 默认勾上：用户已经表态过一次，就不该每次关闭都被问。
  bool _remember = true;

  void _close({required bool hideToTray}) {
    Navigator.of(context).pop(
      CloseToTrayChoice(hideToTray: hideToTray, remember: _remember),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('关闭窗口后继续在后台运行？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Tree 会最小化到系统托盘，正在跑的任务不会被打断。\n'
            '双击托盘图标恢复窗口；要完全退出，右键托盘图标选「退出 Tree」。',
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            key: const Key('close_to_tray_remember'),
            value: _remember,
            onChanged: (bool? value) =>
                setState(() => _remember = value ?? false),
            title: const Text('记住我的选择，下次不再提示'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => _close(hideToTray: false),
          child: const Text('退出 Tree'),
        ),
        FilledButton(
          onPressed: () => _close(hideToTray: true),
          child: const Text('后台运行（推荐）'),
        ),
      ],
    );
  }
}
