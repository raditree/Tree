import 'package:flutter/material.dart';

/// 运行模式三态开关按钮（cloud / local / ssh）。
///
/// 点击弹出菜单选择运行模式；当前模式以不同图标与颜色显示：
/// - cloud：云朵图标（灰）
/// - local：电源图标（绿）
/// - ssh：DNS 图标（橙）
///
/// 对话开始后 [locked] 为 true，禁止切换。
class ModeSwitchButton extends StatelessWidget {
  const ModeSwitchButton({
    super.key,
    required this.mode,
    required this.locked,
    required this.onSelect,
  });

  /// 当前模式：'cloud' | 'local' | 'ssh'
  final String mode;

  /// 对话开始后运行模式锁定，禁止切换
  final bool locked;

  /// 选择新模式回调（异步切换由调用方处理）
  final void Function(String mode) onSelect;

  IconData _iconFor() {
    if (mode == 'local') return Icons.power;
    if (mode == 'ssh') return Icons.dns_outlined;
    return Icons.cloud_outlined;
  }

  Color _colorFor(ColorScheme cs) {
    if (mode == 'local') return Colors.green;
    if (mode == 'ssh') return Colors.orange;
    return cs.onSurfaceVariant;
  }

  String _modeLabel() {
    if (mode == 'local') return '本地执行';
    if (mode == 'ssh') return 'SSH 远端执行';
    return '云端执行';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String tooltip = locked
        ? '对话已开始，该顶部 agent 的运行模式已锁定'
        : '当前: ${_modeLabel()}（点击切换运行模式）';
    return Tooltip(
      message: tooltip,
      child: PopupMenuButton<String>(
        enabled: !locked,
        tooltip: '',
        icon: Icon(_iconFor(), size: 20, color: _colorFor(cs)),
        onSelected: onSelect,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'cloud',
            child: Row(
              children: const <Widget>[
                Icon(Icons.cloud_outlined, size: 18, color: Colors.grey),
                SizedBox(width: 8),
                Text('云端执行（Docker 容器）'),
              ],
            ),
          ),
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
