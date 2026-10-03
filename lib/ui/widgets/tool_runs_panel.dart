import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../models/tool_run.dart';

/// 右栏「正在执行的 tool」面板：把"哪个工具正卡着"从"只能猜"变成**看得见 + 关得掉**。
///
/// 背景（2026-10-03，见计划 `20261003-running-tools`）：工具卡住时原先"永久失联且无日志"。
/// 核心现在有一张**内存登记表**（`GET /api/tools/running`），本面板就是它的前端呈现：
/// 每行一个运行中的工具（工具名 / 命令摘要 / 已执行时长），超核心阈值（默认 120 s）的行
/// **高亮 + 打「已超时」标记**，并给一个**关闭**按钮。
///
/// **关闭与执行站同实现**：`ApiService.closeToolRun` 打的 REST 与插件调的站命令
/// `tool.close` 在核心侧接的是同一个 close（计划 §10 D5 冻结）——先终止进程树，再把句柄
/// 从登记表收尾。失败（句柄已失效 / 未接线）把核心给的原因**原样显示**，不静默、不假装成功。
///
/// **不自动杀**（D2）：超阈值只告警 + 高亮，关闭**必须显式**——`stop` 抢不动正在执行的
/// 工具（`lib/README.md` 的既有断言），所以这里也不给"一键全关"。
///
/// **刷新**：面板自己只在 initState 拉一次，之后由右栏按 `WorkspaceArea.toolRuns`
/// 递增 [refreshTrigger] 触发（与 Todo / Git 页同一个口径）。**不在面板里自己监听**
/// `WorkspaceRefreshService`：那是个"取走即清空"的通知（`takeAreas()`），两个监听者会互相
/// 抢——文件页的刷新会被面板吃掉。
class ToolRunsPanel extends StatefulWidget {
  const ToolRunsPanel({super.key, this.refreshTrigger = 0});

  /// 工作空间刷新触发计数（`WorkspaceArea.toolRuns`）：值变化即重拉登记表。
  final int refreshTrigger;

  @override
  State<ToolRunsPanel> createState() => _ToolRunsPanelState();
}

class _ToolRunsPanelState extends State<ToolRunsPanel> {
  /// 当前登记表里的运行中工具（空列表 = 正常空态，不是错误）。
  List<ToolRun> _runs = const <ToolRun>[];

  /// 正在拉首次 / 重试后的数据（软刷新时为 false，避免列表闪一下）。
  bool _loading = true;

  /// 读取登记表失败的可读原因（非 null 时整页显示原因 + 重试）。
  String? _loadError;

  /// 最近一次关闭失败的可读原因（列表仍在，只在顶部挂一条）。
  String? _actionError;

  /// 正在关闭中的句柄（按钮禁用，避免连点发两次关）。
  final Set<String> _closing = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ToolRunsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTrigger != oldWidget.refreshTrigger) {
      _load(silent: true);
    }
  }

  /// 拉一次登记表快照。
  ///
  /// [silent] = 软刷新：不显示加载态、失败也不把整页换成错误页（有旧数据就继续显示旧的，
  /// 只把原因挂出来）——与右栏其它页签"有数据就不抖"的口径一致。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final List<ToolRun> runs = await ApiService.getRunningTools();
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _loading = false;
        _loadError = null;
        // 已经不在登记表里的句柄不必再等它的关闭结果（核心重启 / 工具自己结束了）
        _closing.removeWhere(
          (String handle) => !runs.any((ToolRun r) => r.handle == handle),
        );
      });
    } catch (e) {
      if (!mounted) return;
      final String reason = _readable(e);
      setState(() {
        _loading = false;
        if (silent && _runs.isNotEmpty) {
          _actionError = '刷新失败：$reason';
        } else {
          _loadError = reason;
        }
      });
    }
  }

  /// 关闭一个运行中的工具：成功后重拉登记表（那一行该消失了）。
  Future<void> _close(ToolRun run) async {
    setState(() {
      _closing.add(run.handle);
      _actionError = null;
    });
    try {
      await ApiService.closeToolRun(run.handle);
      if (!mounted) return;
      setState(() => _closing.remove(run.handle));
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _closing.remove(run.handle);
        _actionError =
            '关闭 ${run.tool.isEmpty ? '未知工具' : run.tool}'
            '（${run.handle}）失败：${_readable(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildHeader(cs),
        if (_loadError != null) _buildBanner(
          cs: cs,
          key: const Key('tool-runs-error'),
          icon: Icons.error_outline,
          color: cs.error,
          text: '读取正在执行的工具失败：$_loadError',
          // 加载失败给一条出路：核心可能只是刚重启完
          action: TextButton(
            key: const Key('tool-runs-retry'),
            onPressed: () => _load(),
            child: const Text('重试'),
          ),
        ),
        if (_actionError != null) _buildBanner(
          cs: cs,
          key: const Key('tool-runs-action-error'),
          icon: Icons.warning_amber_outlined,
          color: cs.error,
          text: _actionError!,
          action: null,
        ),
        Expanded(child: _buildBody(theme, cs)),
      ],
    );
  }

  /// 头部：条数 + 手动刷新（自动刷新靠 [refreshTrigger]）。
  Widget _buildHeader(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.build_circle_outlined, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _loading && _runs.isEmpty
                  ? '正在执行的工具'
                  : '正在执行的工具（${_runs.length} 个）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const Spacer(),
          IconButton(
            key: const Key('tool-runs-refresh'),
            tooltip: '刷新',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () => _load(silent: _runs.isNotEmpty),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme cs) {
    if (_loadError != null) {
      // 原因已经在顶部横幅里（含重试键），正文只留一句"设备上什么都没显示"的说明
      return const SizedBox.shrink();
    }
    if (_loading && _runs.isEmpty) {
      // 不用 CircularProgressIndicator：一个永远在动的圈会让 widget 测试的
      // pumpAndSettle 挂住，而这里本来也只需要一句"在读了"
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '正在读取…',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    if (_runs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '当前没有正在执行的工具',
          key: const Key('tool-runs-empty'),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _runs.length,
      itemBuilder: (BuildContext context, int index) =>
          _ToolRunRow(run: _runs[index], closing: _closing.contains(_runs[index].handle), onClose: _close),
    );
  }

  Widget _buildBanner({
    required ColorScheme cs,
    required Key key,
    required IconData icon,
    required Color color,
    required String text,
    required Widget? action,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              key: key,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// 一行：工具名（+ 超时标记）/ 命令摘要 / 已执行时长 / 关闭键。
class _ToolRunRow extends StatelessWidget {
  const _ToolRunRow({
    required this.run,
    required this.closing,
    required this.onClose,
  });

  final ToolRun run;

  /// 这一行正在关闭（按钮禁用，避免连点发两次）。
  final bool closing;

  final Future<void> Function(ToolRun run) onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool over = run.overThreshold;
    return Container(
      key: Key('tool-run-row-${run.handle}'),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: over
          ? BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              over ? Icons.hourglass_bottom : Icons.play_circle_outline,
              size: 16,
              color: over ? cs.error : cs.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        run.tool.isEmpty ? '未知工具' : run.tool,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (over)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          key: Key('tool-run-over-${run.handle}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '已超时',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: cs.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  run.commandPreview.isEmpty
                      ? '（无命令摘要）'
                      : toolCommandPreview(run.commandPreview),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.25,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              toolElapsedLabel(run.elapsedMs),
              style: TextStyle(
                fontSize: 11,
                color: over ? cs.error : cs.onSurfaceVariant,
                fontWeight: over ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          IconButton(
            key: Key('tool-run-close-${run.handle}'),
            tooltip: '关闭这个工具（先终止进程树，再从登记表收尾；与执行站 tool.close 同实现）',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.cancel_outlined, size: 18),
            onPressed: closing ? null : () => onClose(run),
          ),
        ],
      ),
    );
  }
}

/// 命令摘要：把多行 / 连续空白**压成一行**，并按 [maxLength] 截断（默认 120 字 + 省略号）。
///
/// 为什么前端还要再截一刀：核心给的 `command_preview` 只保证"是预览"，但它可能仍很长
/// （`find` 那种一屏参数）且**带换行**——一行式列表里换行会直接把行高顶开。
String toolCommandPreview(String raw, {int maxLength = 120}) {
  final String flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (maxLength <= 0 || flat.length <= maxLength) return flat;
  return '${flat.substring(0, maxLength)}…';
}

/// 已执行时长文案：`< 1s` 给毫秒，`< 1min` 给秒（一位小数），再往上折成 `5m0s`。
///
/// 为什么不直接用 `formatDurationMs`：卡住的工具动辄几分钟，`300.0s` 要用户自己除 60。
String toolElapsedLabel(int ms) {
  if (ms <= 0) return '0ms';
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final int seconds = ms ~/ 1000;
  return '${seconds ~/ 60}m${seconds % 60}s';
}

/// 异常 → 一句可读提示（去掉 `Exception: ` 前缀，与右栏其它页同一口径）。
String _readable(Object error) =>
    error.toString().replaceFirst('Exception: ', '');
