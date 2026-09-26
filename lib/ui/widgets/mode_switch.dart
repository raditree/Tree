import 'package:flutter/material.dart';

/// 运行模式两态开关按钮（local / ssh，M9 Q2 删除 cloud）。
///
/// 点击弹出菜单选择运行模式；当前模式以不同图标与颜色显示：
/// - local：电源图标（绿）
/// - ssh：DNS 图标（橙）
///
/// 模式只剩"工具在哪台机器上跑"两种取值，**默认 local**（由 MessagePanel
/// 保证：两个执行器都未启用时自动落本地），因此这里不再有"云端"分支。
/// 对话开始后 [locked] 为 true，禁止切换。
/// 移动端（Android/iOS）无桌面文件系统与目录选择能力，本地执行模式不可用，
/// 通过 [showLocal] 隐藏「本地执行」菜单项（仅保留 SSH）。
class ModeSwitchButton extends StatelessWidget {
  const ModeSwitchButton({
    super.key,
    required this.mode,
    required this.locked,
    required this.onSelect,
    this.showLocal = true,
  });

  /// 当前模式：'local' | 'ssh'
  final String mode;

  /// 对话开始后运行模式锁定，禁止切换
  final bool locked;

  /// 选择新模式回调（异步切换由调用方处理）
  final void Function(String mode) onSelect;

  /// 是否显示「本地执行」选项（移动端不支持本机目录执行，传 false 隐藏）
  final bool showLocal;

  IconData _iconFor() => mode == 'ssh' ? Icons.dns_outlined : Icons.power;

  Color _colorFor() => mode == 'ssh' ? Colors.orange : Colors.green;

  String _modeLabel() => mode == 'ssh' ? 'SSH 远端执行' : '本地执行';

  @override
  Widget build(BuildContext context) {
    final String tooltip = locked
        ? '对话已开始，该顶部 agent 的运行模式已锁定'
        : '当前: ${_modeLabel()}（点击切换运行模式）';
    return Tooltip(
      message: tooltip,
      child: PopupMenuButton<String>(
        enabled: !locked,
        tooltip: '',
        icon: Icon(_iconFor(), size: 20, color: _colorFor()),
        onSelected: onSelect,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          if (showLocal)
            PopupMenuItem<String>(
              value: 'local',
              child: Row(
                children: const <Widget>[
                  Icon(Icons.desktop_windows, size: 18, color: Colors.green),
                  SizedBox(width: 8),
                  Text('本地执行（本机目录）'),
                ],
              ),
            ),
          PopupMenuItem<String>(
            value: 'ssh',
            child: Row(
              children: const <Widget>[
                Icon(Icons.dns_outlined, size: 18, color: Colors.orange),
                SizedBox(width: 8),
                Text('SSH 执行（远端主机）'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
