import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/api_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../models/file_listing.dart';
import '../models/file_node.dart';
import '../models/git_status.dart';
import '../services/file_reveal.dart';
import '../services/workspace_paths.dart';
import 'file_tree_icon.dart';
import 'input_style.dart';

/// 行高（VS Code 的资源管理器约 22px；[ListView.itemExtent] 也用它，滚动位置可精算）
const double kFileTreeRowHeight = 22;

/// 行内字号（VS Code 资源管理器 ≈ 13）
const double kFileTreeFontSize = 13;

/// 每一层缩进宽度 = 箭头槽宽度（文件行也留出等宽空槽）：
/// 缩进引导线因此正好落在父级箭头槽的中心，同级文件与文件夹的名字也对得齐
const double kFileTreeIndentWidth = 16;

/// 行内左右 padding（要求 6–8px）
const double kFileTreeEdgePadding = 6;

/// **VS Code 型资源管理器**（文件面板的目录树）。
///
/// 与旧实现（单层列表 + 面包屑进入子目录）的口径变化，见 lib/README.md 不变量 16：
/// 1. **惰性加载的嵌套树**：目录就地展开 / 折叠，展开时按需拉取该层（不预拉整棵）；
/// 2. **只显示名字 + 类型图标**（没有"大小 / 修改时间"两列）：那两条信息进悬停 tooltip；
/// 3. **中性类型图标**（[fileTreeVisualFor] 纯函数给形状、[fileTreeIconColor] 给色）：
///    图标跟主题走、只有 git 状态上色（用户 2026-10-04 看图定稿，推翻旧的写死色板）；
/// 4. **缩进引导线 + 箭头（只在目录上，展开顺时针转 90°）**，文件行留等宽空槽；
/// 5. **整行悬停 / 选中高亮**，键盘 ↑/↓ 在树里移动选中；
/// 6. **git 状态着色**（整行名字 + 行尾字母，目录聚合子项状态）：核心没有这个端点时静默不着色；
/// 7. **新建 / 重命名 / 删除**（右键菜单 + 头部工具条；行内重命名、删除前确认）。
///
/// 数据全部经核心：目录列举 [ApiService.getFilesWithMeta]、git 状态
/// [ApiService.getGitStatus]、新建 [ApiService.createDirectory] /
/// [ApiService.saveFileContent]、改名 [ApiService.renamePath]、删除
/// [ApiService.deletePath]（前端不直接读盘，见 lib/README.md 不变量 1）。
class FileTree extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 顶层 agent（team）ID，用于后端三模式分派；为空时后端按 workspaceId 兜底
  final String? teamId;

  /// 文件选中回调，参数为文件的相对路径（相对工作空间根，正斜杠）
  final ValueChanged<String>? onFileSelected;

  /// 文件/文件夹下载回调，参数为路径和是否为目录
  final void Function(String path, bool isDirectory)? onDownload;

  /// 刷新触发器：递增时重新加载（展开状态保持不塌）
  final int refreshTrigger;

  /// 目录作用域变化回调：**选中目录**，或**选中文件所在目录**——头部显示它，
  /// 「同步到本地」也按它限定范围（M8b）。空串 = 工作空间根。
  final ValueChanged<String>? onPathChanged;

  /// 重命名 / 移动成功回调（旧路径 → 新路径；查看器里的窗格要跟着改名）
  final void Function(String from, String to)? onPathRenamed;

  /// 删除成功回调（被删的相对路径；查看器里指向它的窗格要关掉）
  final ValueChanged<String>? onPathDeleted;

  const FileTree({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.onFileSelected,
    this.onDownload,
    this.onPathChanged,
    this.onPathRenamed,
    this.onPathDeleted,
    this.refreshTrigger = 0,
  });

  @override
  State<FileTree> createState() => _FileTreeState();

  // ── 测试与"滚到选中项"用的 key（按相对路径唯一） ──

  /// 整行的 key
  static Key rowKey(String path) => ValueKey<String>('file_tree_row:$path');

  /// 行背景（悬停 / 选中底色都在它身上：测试直接读颜色）
  static Key rowBackgroundKey(String path) =>
      ValueKey<String>('file_tree_row_bg:$path');

  /// 目录箭头（文件行没有这个 key ⇒ "箭头只在目录上"可断言）
  static Key arrowKey(String path) => ValueKey<String>('file_tree_arrow:$path');

  /// 第 [level] 层缩进引导线（行内从左往右数）
  static Key indentGuideKey(String path, int level) =>
      ValueKey<String>('file_tree_guide:$path:$level');

  /// 选中行左侧那 2px 主色条（"选中"的第二个信号，测试直接量宽度）
  static Key selectionBarKey(String path) =>
      ValueKey<String>('file_tree_selection_bar:$path');

  /// 行内重命名输入框（同一时刻只会有一个）
  static const Key renameFieldKey = ValueKey<String>('file_tree_rename_field');
}

/// 一行条目的种类（状态行只占一行、不可交互，缩进与同级条目一致）
enum _TreeRowKind { node, loading, empty, error, truncated }

class _TreeRow {
  const _TreeRow.node(this.node, this.path, this.depth)
      : kind = _TreeRowKind.node,
        message = '';

  const _TreeRow.status(this.kind, this.message, this.path, this.depth)
      : node = null;

  final _TreeRowKind kind;
  final FileNode? node;
  final String path;
  final int depth;
  final String message;

  bool get isNode => kind == _TreeRowKind.node;
}

class _FileTreeState extends State<FileTree> {
  /// 已加载的目录：相对路径（'' = 根）→ 列举结果
  final Map<String, FileListing> _listings = <String, FileListing>{};

  /// 加载失败的目录：相对路径 → 可读原因
  final Map<String, String> _errors = <String, String>{};

  /// 正在加载的目录
  final Set<String> _loading = <String>{};

  /// 展开的目录（跨刷新保持：重拉之后不塌）
  final Set<String> _expanded = <String>{};

  /// 根加载失败的原因（根错误走整块提示，不是一行）
  String? _rootError;

  /// 选中项（键盘上下键移动的就是它；点文件仍会打开查看器）
  String? _selectedPath;

  /// 悬停项（自己管，不用 InkWell 的 overlay：底色要可断言）
  String? _hoveredPath;

  /// 正在行内重命名的路径 + 该行的行内错误（重名 / 非法字符）
  String? _renamingPath;
  String? _renameError;
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _renameFocus = FocusNode(debugLabel: 'file_tree_rename');

  /// 键盘导航的焦点（点任一行都抢过来；↑/↓ 才有效）
  final FocusNode _treeFocus = FocusNode(debugLabel: 'file_tree');

  /// 行滚动控制器（键盘移动选中时要把它滚进可见区）
  final ScrollController _scrollController = ScrollController();

  /// git 状态快照（树渲染完拉一次，缓存到面板状态；操作后失效重拉）
  GitStatusSnapshot _gitStatus = GitStatusSnapshot.none;

  /// 过期响应的世代号：切工作空间 / 重置后自增，旧请求回来直接丢
  int _generation = 0;

  /// git 状态请求序号：后发先至的旧响应不许覆盖新状态
  int _gitStatusRequest = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadAll());
    // 初始作用域（根）在首帧后通知父组件：initState 里回调会撞上父组件 build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPathChanged?.call('');
    });
  }

  @override
  void didUpdateWidget(FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceId != widget.workspaceId) {
      unawaited(_resetAndReload());
      return;
    }
    // 刷新触发器变化（上传 / 工具写文件 / 切执行模式）：重拉，**展开状态保持**
    if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      unawaited(_reloadAll());
    }
  }

  @override
  void dispose() {
    _renameController.dispose();
    _renameFocus.dispose();
    _treeFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ==================== 数据 ====================

  /// 换工作空间：丢掉全部缓存与展开状态，从头开始
  Future<void> _resetAndReload() async {
    _generation++;
    setState(() {
      _listings.clear();
      _errors.clear();
      _loading.clear();
      _expanded.clear();
      _rootError = null;
      _selectedPath = null;
      _hoveredPath = null;
      _renamingPath = null;
      _renameError = null;
      _gitStatus = GitStatusSnapshot.none;
    });
    await _reloadAll();
  }

  /// 重拉：根 + **已展开的目录**（展开状态不塌）+ git 状态
  Future<void> _reloadAll() async {
    await _loadDir('');
    if (!mounted) return;
    for (final String dir in _expanded.toList()) {
      if (!mounted) return;
      await _loadDir(dir);
    }
    await _refreshGitStatus();
  }

  /// 拉一层目录（软更新：已有旧数据时保持可见，失败才换成错误行）
  Future<void> _loadDir(String path) async {
    if (_loading.contains(path)) return;
    final int generation = _generation;
    setState(() {
      _loading.add(path);
      _errors.remove(path);
      if (path.isEmpty) _rootError = null;
    });
    try {
      final FileListing listing = await ApiService.getFilesWithMeta(
        widget.workspaceId,
        path: path,
        teamId: widget.teamId ?? '',
      );
      if (!mounted || generation != _generation) return;
      final List<FileNode> sorted = <FileNode>[...listing.nodes]
        ..sort(_compareNodes);
      setState(() {
        _listings[path] = FileListing(
          nodes: sorted,
          truncated: listing.truncated,
        );
        _loading.remove(path);
      });
    } on Exception catch (error) {
      final String message = _reason(error);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading.remove(path);
        if (path.isEmpty) {
          _rootError = message;
        } else {
          _errors[path] = message;
          // 拿不到这一层就别再显示上一次的旧内容（会让人以为它还在）
          _listings.remove(path);
        }
      });
    }
  }

  /// 目录在前、文件在后；同类按名称字母序（与核心同一口径，前端再排一次保险）
  static int _compareNodes(FileNode a, FileNode b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// 重新拉 git 状态。
  ///
  /// **失败一律静默不着色**：核心可能还没实现这个端点（404/501）、工作空间可能
  /// 不是仓库、也可能断网——状态色是锦上添花，不能因为它把整棵树变成错误页。
  Future<void> _refreshGitStatus() async {
    final int generation = _generation;
    final int request = ++_gitStatusRequest;
    GitStatusSnapshot snapshot = GitStatusSnapshot.none;
    try {
      snapshot = await ApiService.getGitStatus(
        widget.workspaceId,
        teamId: widget.teamId ?? '',
      );
    } on Exception {
      snapshot = GitStatusSnapshot.none;
    }
    if (!mounted ||
        generation != _generation ||
        request != _gitStatusRequest) {
      return;
    }
    setState(() {
      _gitStatus = snapshot;
    });
  }

  // ==================== 展开 / 折叠 / 选中 ====================

  /// 展开 / 折叠一个目录；展开时按需拉取该层
  void _toggleDirectory(String path) {
    final bool expanding = !_expanded.contains(path);
    setState(() {
      if (expanding) {
        _expanded.add(path);
      } else {
        _expanded.remove(path);
      }
    });
    if (expanding && !_listings.containsKey(path)) {
      unawaited(_loadDir(path));
    }
  }

  /// 收起全部（展开状态清空；选中与作用域不动）。
  ///
  /// 两处体贴（用户 2026-10-04：「全部折叠点击为啥没反应」——那一刻本来就没有展开的
  /// 目录，所以点了个"合法但看不见效果"的按钮）：
  /// - 没有展开项时这颗键**置灰**并改 tooltip（见 `_buildHead`），一眼看出"没东西可收"；
  /// - 真收了就**滚回顶部**（VS Code 同款），保证每次点击都有可见反馈。
  void _collapseAll() {
    setState(() {
      _expanded.clear();
      _renamingPath = null;
      _renameError = null;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _refresh() => unawaited(_reloadAll());

  /// 点一行：目录 = 就地展开 / 折叠；文件 = 交给父组件打开查看器。
  ///
  /// 两者都会**选中**该行，并把「同步到本地」的作用域更新为它所在的目录。
  void _handleRowTap(_TreeRow row) {
    _treeFocus.requestFocus();
    if (!row.isNode) return;
    final FileNode node = row.node!;
    _selectPath(row);
    if (node.isDirectory) {
      _toggleDirectory(row.path);
      return;
    }
    widget.onFileSelected?.call(row.path);
  }

  /// 选中一行（键盘用；不触发打开 / 展开），并把「同步到本地」的作用域更新为
  /// **它所在的目录**（目录 = 它自己，文件 = 父目录）
  void _selectPath(_TreeRow row) {
    setState(() {
      _selectedPath = row.path;
    });
    widget.onPathChanged?.call(
      row.node!.isDirectory ? row.path : workspacePathParent(row.path),
    );
  }

  // ==================== 键盘导航 ====================

  /// ↑/↓ 在树里移动选中；→/← 展开折叠或跳父级；Enter 打开；F2 重命名；Delete 删除。
  ///
  /// 只处理 [KeyDownEvent]（长按才连续）。改名输入框自己消费方向键与回车，
  /// 那些事件到不了这里（正在改名时方向键仍是移动光标）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final List<_TreeRow> rows =
        _visibleRows().where((_TreeRow r) => r.isNode).toList();
    if (rows.isEmpty) return KeyEventResult.ignored;
    final int current =
        rows.indexWhere((_TreeRow r) => r.path == _selectedPath);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        return _moveSelection(rows, current + 1);
      case LogicalKeyboardKey.arrowUp:
        return _moveSelection(rows, current - 1);
      case LogicalKeyboardKey.arrowRight:
        return _expandOrNext(rows, current);
      case LogicalKeyboardKey.arrowLeft:
        return _collapseOrParent(rows, current);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (current < 0) return KeyEventResult.ignored;
        _handleRowTap(rows[current]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.f2:
        if (current < 0) return KeyEventResult.ignored;
        _startRename(rows[current].node!, rows[current].path);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
        if (current < 0) return KeyEventResult.ignored;
        unawaited(_confirmDelete(rows[current].node!, rows[current].path));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_renamingPath != null) {
          _cancelRename();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _moveSelection(List<_TreeRow> rows, int target) {
    final int index = target.clamp(0, rows.length - 1);
    _selectPath(rows[index]);
    _scrollIntoView(index);
    return KeyEventResult.handled;
  }

  KeyEventResult _expandOrNext(List<_TreeRow> rows, int current) {
    if (current < 0) {
      return _moveSelection(rows, 0);
    }
    final _TreeRow row = rows[current];
    if (row.node!.isDirectory && !_expanded.contains(row.path)) {
      _toggleDirectory(row.path);
      return KeyEventResult.handled;
    }
    return _moveSelection(rows, current + 1);
  }

  KeyEventResult _collapseOrParent(List<_TreeRow> rows, int current) {
    if (current < 0) return KeyEventResult.ignored;
    final _TreeRow row = rows[current];
    if (row.node!.isDirectory && _expanded.contains(row.path)) {
      _toggleDirectory(row.path);
      return KeyEventResult.handled;
    }
    final String parent = workspacePathParent(row.path);
    final int index = rows.indexWhere((_TreeRow r) => r.path == parent);
    if (index >= 0) {
      _selectPath(rows[index]);
      _scrollIntoView(index);
    }
    return KeyEventResult.handled;
  }

  /// 把第 [index] 行滚进可见区（行高固定 = [kFileTreeRowHeight]，位置可精算）
  void _scrollIntoView(int index) {
    if (!_scrollController.hasClients) return;
    final double top = index * kFileTreeRowHeight;
    final double bottom = top + kFileTreeRowHeight;
    final ScrollPosition position = _scrollController.position;
    double? target;
    if (top < position.pixels) {
      target = top;
    } else if (bottom > position.pixels + position.viewportDimension) {
      target = bottom - position.viewportDimension;
    }
    if (target == null) return;
    final double clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - position.pixels).abs() < 0.5) return;
    _scrollController.jumpTo(clamped);
  }

  // ==================== 行结构 ====================

  /// 展平可见行（含状态行）：根 → 已展开目录的子树
  List<_TreeRow> _visibleRows() {
    final List<_TreeRow> rows = <_TreeRow>[];
    void walk(String dir, int depth) {
      final String? error = _errors[dir];
      if (error != null) {
        rows.add(
          _TreeRow.status(_TreeRowKind.error, '加载失败：$error', dir, depth),
        );
        return;
      }
      final FileListing? listing = _listings[dir];
      if (listing == null) {
        if (_loading.contains(dir)) {
          rows.add(
            _TreeRow.status(_TreeRowKind.loading, '加载中…', dir, depth),
          );
        }
        return;
      }
      if (listing.isEmpty) {
        rows.add(_TreeRow.status(_TreeRowKind.empty, '空文件夹', dir, depth));
        return;
      }
      for (final FileNode node in listing.nodes) {
        final String path = _pathOf(dir, node);
        rows.add(_TreeRow.node(node, path, depth));
        if (node.isDirectory && _expanded.contains(path)) {
          walk(path, depth + 1);
        }
      }
      if (listing.truncated) {
        final String count = listing.length.toString();
        rows.add(
          _TreeRow.status(
            _TreeRowKind.truncated,
            '仅显示前 $count 项（核心已截断）',
            dir,
            depth + 1,
          ),
        );
      }
    }

    walk('', 0);
    return rows;
  }

  /// 条目的工作空间相对路径（优先用核心给的 [FileNode.path]，缺了才按当前目录拼）
  String _pathOf(String dir, FileNode node) => node.path.isNotEmpty
      ? workspacePathNormalize(node.path)
      : workspacePathJoin(dir, node.name);

  /// 当前选中的行（不可见 / 没选中时为 null）
  _TreeRow? _selectedRow() {
    final String? selected = _selectedPath;
    if (selected == null || selected.isEmpty) return null;
    for (final _TreeRow row in _visibleRows()) {
      if (row.isNode && row.path == selected) return row;
    }
    return null;
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _buildHead(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// 头部工具条：左边"当前根 + 同步作用域"，右边新建文件 / 新建文件夹 / 刷新 / 全部折叠
  ///
  /// VS Code 的资源管理器头部就是这几个动作；「在文件夹中显示」「复制路径」是**条目
  /// 动作**，只放右键菜单（头部没有"当前条目"的概念，放上去会猜错对象）。
  Widget _buildHead() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String scope = _scopePath();
    return Container(
      height: 30,
      color: cs.surface,
      padding: const EdgeInsets.only(left: 8, right: 2),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.folder_outlined,
            size: 15,
            color: fileTreeIconColor(cs),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: <Widget>[
                // 目录在左、这一栏可能被拖得很窄：标题自己也要能缩（否则整行溢出，
                // 黄黑条会出现在资源管理器头部）。
                Flexible(
                  child: Text(
                    '根目录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (scope.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      scope,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          _headAction(
            icon: Icons.note_add_outlined,
            tooltip: '新建文件',
            onPressed: () =>
                unawaited(_createEntry(_newEntryDir(), directory: false)),
          ),
          _headAction(
            icon: Icons.create_new_folder_outlined,
            tooltip: '新建文件夹',
            onPressed: () =>
                unawaited(_createEntry(_newEntryDir(), directory: true)),
          ),
          _headAction(icon: Icons.refresh, tooltip: '刷新', onPressed: _refresh),
          _headAction(
            icon: Icons.unfold_less,
            // 没有展开项时说清"为什么点了没反应"（用户 2026-10-04 的反馈）
            tooltip: _expanded.isEmpty ? '没有展开的目录（都收着呢）' : '全部折叠',
            onPressed: _expanded.isEmpty ? null : _collapseAll,
          ),
        ],
      ),
    );
  }

  Widget _headAction({
    required IconData icon,
    required String tooltip,
    // 可空：没有可做的事时**置灰**（例如"没有展开的目录"时的「全部折叠」），
    // 比点了没反应强——用户一眼就知道不是按钮坏了。
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      onPressed: onPressed,
    );
  }

  /// 当前同步作用域：选中目录，或选中文件所在目录（没有选中 = 根）
  String _scopePath() {
    final _TreeRow? row = _selectedRow();
    if (row == null) return '';
    return row.node!.isDirectory ? row.path : workspacePathParent(row.path);
  }

  /// 新建文件 / 文件夹的落点目录：选中目录 → 它；选中文件 → 它所在目录；否则根
  String _newEntryDir() {
    final _TreeRow? row = _selectedRow();
    if (row == null) return '';
    return row.node!.isDirectory ? row.path : workspacePathParent(row.path);
  }

  Widget _buildBody() {
    if (!_listings.containsKey('') && _loading.contains('')) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rootError != null && !_listings.containsKey('')) {
      return _messageBody(
        icon: Icons.error_outline,
        iconColor: const Color(0xFFEF4444),
        message: _rootError!,
      );
    }
    if (_listings['']?.isEmpty ?? false) {
      return _messageBody(
        icon: Icons.folder_open,
        iconColor: Theme.of(context).colorScheme.outline,
        message: '空文件夹',
      );
    }
    final List<_TreeRow> rows = _visibleRows();
    return GestureDetector(
      // 空白处右键 = 对根目录的操作菜单（空白处左键仍是面板的"折叠右栏"，不变）
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (TapDownDetails details) {
        unawaited(_showContextMenu(details.globalPosition, null));
      },
      onTap: () => _treeFocus.requestFocus(),
      child: Focus(
        focusNode: _treeFocus,
        onKeyEvent: _onKey,
        child: ListView.builder(
          controller: _scrollController,
          // 行高固定：滚动位置可精算（键盘移动选中时滚进可见区）
          itemExtent: kFileTreeRowHeight,
          padding: EdgeInsets.zero,
          itemCount: rows.length,
          itemBuilder: (BuildContext context, int index) =>
              _buildRow(rows[index]),
        ),
      ),
    );
  }

  /// 单行（条目 / 状态行）
  Widget _buildRow(_TreeRow row) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (!row.isNode) {
      final bool isError = row.kind == _TreeRowKind.error;
      return SizedBox(
        key: FileTree.rowKey(row.path),
        height: kFileTreeRowHeight,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: ColoredBox(
                key: FileTree.rowBackgroundKey(row.path),
                color: Colors.transparent,
              ),
            ),
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(width: kFileTreeEdgePadding),
                  for (int level = 0; level < row.depth; level++)
                    _indentGuide(row.path, level),
                  const SizedBox(width: kFileTreeEdgePadding),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (row.kind == _TreeRowKind.loading) ...<Widget>[
                            const SizedBox(
                              width: 11,
                              height: 11,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              row.message,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: kFileTreeFontSize,
                                fontStyle: FontStyle.italic,
                                color: isError
                                    ? const Color(0xFFEF4444)
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: kFileTreeEdgePadding),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final FileNode node = row.node!;
    final String path = row.path;
    final bool isDir = node.isDirectory;
    final bool expanded = isDir && _expanded.contains(path);
    final bool selected = _selectedPath == path;
    final bool hovered = _hoveredPath == path;
    final bool renaming = _renamingPath == path;
    final GitFileStatus? git = isDir
        ? _gitStatus.aggregateForDirectory(path)
        : _gitStatus.statusFor(path);
    final FileTreeVisual visual = fileTreeVisualFor(
      path,
      isDirectory: isDir,
      expanded: expanded,
    );
    final Color nameColor = git == null
        ? cs.onSurface
        : gitStatusColor(git).withValues(alpha: gitStatusOpacity(git));

    final Widget body = SizedBox(
      key: FileTree.rowKey(path),
      height: kFileTreeRowHeight,
      child: MouseRegion(
        onEnter: (_) => _setHovered(path),
        onExit: (_) {
          if (_hoveredPath == path) _setHovered(null);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleRowTap(row),
          onSecondaryTapDown: (TapDownDetails details) {
            _treeFocus.requestFocus();
            setState(() {
              _selectedPath = path;
            });
            unawaited(_showContextMenu(details.globalPosition, row));
          },
          child: Stack(
            children: <Widget>[
              // 整行底色：悬停浅、选中更重（VS Code 观感）
              Positioned.fill(
                child: ColoredBox(
                  key: FileTree.rowBackgroundKey(path),
                  color: selected
                      ? cs.primary.withValues(alpha: 0.16)
                      : hovered
                      ? cs.onSurface.withValues(alpha: 0.07)
                      : Colors.transparent,
                ),
              ),
              Positioned.fill(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SizedBox(width: kFileTreeEdgePadding),
                    // 缩进引导线：每层 1px 竖线，落在父级箭头槽的中心
                    for (int level = 0; level < row.depth; level++)
                      _indentGuide(path, level),
                    // 箭头槽：**只有目录有箭头**，文件行留等宽空槽 ⇒ 同级名字对齐
                    SizedBox(
                      width: kFileTreeIndentWidth,
                      child: isDir
                          ? AnimatedRotation(
                              key: FileTree.arrowKey(path),
                              turns: expanded ? 0.25 : 0,
                              duration: const Duration(milliseconds: 120),
                              child: Icon(
                                Icons.keyboard_arrow_right,
                                size: 16,
                                color: cs.onSurfaceVariant,
                              ),
                            )
                          : null,
                    ),
                    Icon(
                      visual.icon,
                      size: 14,
                      // 图标一律中性（跟主题走）：颜色只留给 git 状态（名字染色 + 行尾字母）
                      color: fileTreeIconColor(cs),
                    ),
                    const SizedBox(width: 6),
                    if (renaming)
                      _buildRenameField(node, path)
                    else
                      Expanded(
                        child: Text(
                          node.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: kFileTreeFontSize,
                            color: nameColor,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                    // 行尾 git 状态字母（目录带聚合状态时也用同一个字母，更淡）
                    if (git != null) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        git.letter,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: gitStatusColor(git).withValues(
                            alpha: gitStatusOpacity(git),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: kFileTreeEdgePadding),
                  ],
                ),
              ),
              // 选中：左侧 2px 主色条（与整行底色一起给"选中"两个信号）
              if (selected)
                Positioned(
                  key: FileTree.selectionBarKey(path),
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(color: cs.primary),
                ),
            ],
          ),
        ),
      ),
    );

    if (renaming) return body;
    return Tooltip(
      message: _tooltipFor(node, path, visual, git),
      waitDuration: const Duration(milliseconds: 400),
      child: body,
    );
  }

  /// 第 [level] 层缩进引导线（1px，低透明度 outlineVariant）
  Widget _indentGuide(String path, int level) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: FileTree.indentGuideKey(path, level),
      width: kFileTreeIndentWidth,
      child: Center(
        child: Container(
          width: 1,
          height: double.infinity,
          color: cs.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  /// 行内重命名输入框（回车确认 / Esc 或失焦取消；非法名字在行内给红字）
  Widget _buildRenameField(FileNode node, String path) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 170,
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border.all(color: cs.primary, width: 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: TextField(
                key: FileTree.renameFieldKey,
                controller: _renameController,
                focusNode: _renameFocus,
                style: const TextStyle(fontSize: kFileTreeFontSize),
                cursorWidth: 1,
                cursorHeight: 13,
                decoration: kBorderlessInput.copyWith(
                  isCollapsed: true,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (String value) =>
                    unawaited(_commitRename(node, path, value)),
                // 失焦 = 取消（不让"点别处"意外改名；要改就回车）
                onTapOutside: (_) => _cancelRename(),
              ),
            ),
          ),
          if (_renameError != null) ...<Widget>[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _renameError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 悬停 tooltip：名字（截断时靠它看全）+ 类型 · 大小/项数 · 修改时间 · git 状态。
  ///
  /// 「大小 / 修改时间」两列已从行里去掉，信息都搬到这里（VS Code 的资源管理器也
  /// 只显示名字 + 类型图标）：文件给 3.7 KB · 2026-10-02 11:31，目录给
  /// 12 项 · 2026-10-02 11:31（没加载过子项时就只给时间）。
  String _tooltipFor(
    FileNode node,
    String path,
    FileTreeVisual visual,
    GitFileStatus? git,
  ) {
    final List<String> parts = <String>[visual.label];
    if (node.isDirectory) {
      final FileListing? listing = _listings[path];
      if (listing != null) {
        final String count = listing.length.toString();
        parts.add('$count 项');
      }
    } else {
      parts.add(node.formattedSize);
    }
    final String modified = _formatModified(node.modified);
    if (modified.isNotEmpty) parts.add(modified);
    if (git != null) parts.add(git.label);
    final String title = node.name;
    final String detail = parts.join(' · ');
    return '$title\n$detail';
  }

  /// 修改时间：ISO → yyyy-MM-dd HH:mm；解析不了就原样截断到 19 字符
  static String _formatModified(String modified) {
    if (modified.isEmpty) return '';
    final DateTime? parsed = DateTime.tryParse(modified);
    if (parsed == null) {
      return modified.length > 19 ? modified.substring(0, 19) : modified;
    }
    final String month = parsed.month.toString().padLeft(2, '0');
    final String day = parsed.day.toString().padLeft(2, '0');
    final String hour = parsed.hour.toString().padLeft(2, '0');
    final String minute = parsed.minute.toString().padLeft(2, '0');
    final String year = parsed.year.toString();
    return '$year-$month-$day $hour:$minute';
  }

  /// 居中提示（根加载失败 / 根为空）
  Widget _messageBody({
    required IconData icon,
    required Color iconColor,
    required String message,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 40, color: iconColor),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: kFileTreeFontSize,
            ),
          ),
        ],
      ),
    );
  }


  // ==================== 悬停 / 选择 ====================


  void _setHovered(String? path) {
    if (_hoveredPath == path) return;
    setState(() {
      _hoveredPath = path;
    });
  }

  // ==================== 右键菜单 ====================

  /// 右键菜单：条目动作（打开 / 新建 / 重命名 / 删除 / 在文件夹中显示 / 复制路径）
  /// + 通用动作（刷新 / 全部折叠）。空白处右键 = 对**根目录**的菜单。
  Future<void> _showContextMenu(Offset globalPosition, _TreeRow? row) async {
    final bool hasNode = row != null && row.isNode;
    final bool isDir = hasNode && row.node!.isDirectory;
    final bool expanded = hasNode && _expanded.contains(row.path);
    final String? value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: <PopupMenuEntry<String>>[
        if (hasNode)
          PopupMenuItem<String>(
            value: 'open',
            child: _menuRow(
              isDir
                  ? (expanded ? Icons.unfold_less : Icons.expand_more)
                  : Icons.article_outlined,
              isDir ? (expanded ? '折叠' : '展开') : '打开',
            ),
          ),
        PopupMenuItem<String>(
          value: 'new_file',
          child: _menuRow(Icons.note_add_outlined, '新建文件'),
        ),
        PopupMenuItem<String>(
          value: 'new_folder',
          child: _menuRow(Icons.create_new_folder_outlined, '新建文件夹'),
        ),
        if (hasNode)
          PopupMenuItem<String>(
            value: 'rename',
            child: _menuRow(Icons.drive_file_rename_outline, '重命名'),
          ),
        if (hasNode)
          PopupMenuItem<String>(
            value: 'delete',
            child: _menuRow(Icons.delete_outline, '删除'),
          ),
        if (hasNode) const PopupMenuDivider(),
        if (hasNode)
          PopupMenuItem<String>(
            value: 'reveal',
            child: _menuRow(Icons.folder_open_outlined, '在文件夹中显示'),
          ),
        if (hasNode)
          PopupMenuItem<String>(
            value: 'copy_path',
            child: _menuRow(Icons.content_copy, '复制路径'),
          ),
        // 下载是旧菜单就有的能力（M8c/M8d：文件流式落盘 / 目录打 tar.gz），不许丢
        if (hasNode)
          PopupMenuItem<String>(
            value: 'download',
            child: _menuRow(Icons.download, '下载'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'refresh',
          child: _menuRow(Icons.refresh, '刷新'),
        ),
        PopupMenuItem<String>(
          value: 'collapse_all',
          // 没有展开项就置灰：与头部那颗键同一个口径（点了没反应最容易被当成 bug）
          enabled: _expanded.isNotEmpty,
          child: _menuRow(Icons.unfold_less, '全部折叠'),
        ),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'open':
        if (row != null) _handleRowTap(row);
      case 'new_file':
        await _createEntry(_rowDir(row) ?? '', directory: false);
      case 'new_folder':
        await _createEntry(_rowDir(row) ?? '', directory: true);
      case 'rename':
        if (row != null) _startRename(row.node!, row.path);
      case 'delete':
        if (row != null) await _confirmDelete(row.node!, row.path);
      case 'reveal':
        if (row != null) await _reveal(row.path);
      case 'copy_path':
        if (row != null) await _copyPath(row.path);
      case 'download':
        if (row != null) {
          widget.onDownload?.call(row.path, row.node!.isDirectory);
        }
      case 'refresh':
        _refresh();
      case 'collapse_all':
        _collapseAll();
    }
  }

  Widget _menuRow(IconData icon, String label) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }

  /// 菜单动作的落点目录：条目是目录 → 它；是文件 → 它所在目录；没条目 → 作用域/根
  String? _rowDir(_TreeRow? row) {
    if (row == null || !row.isNode) return _newEntryDir();
    return row.node!.isDirectory ? row.path : workspacePathParent(row.path);
  }

  // ==================== 动作：新建 / 重命名 / 删除 / 定位 / 复制 ====================

  /// 新建文件（空内容，走既有 PUT .../content）或新建文件夹（POST .../mkdir）。
  ///
  /// **不覆盖同名条目**：先按已加载的列举校验，写之前再列一次目录复查
  /// （核心的 PUT 没有"仅新建"语义，重名会被它静默覆盖——这个闸门只能放前端）。
  Future<void> _createEntry(String dirPath, {required bool directory}) async {
    final String action = directory ? '新建文件夹' : '新建文件';
    final String? name = await _promptEntryName(
      title: action,
      initial: directory ? '新建文件夹' : 'untitled.txt',
      dirPath: dirPath,
    );
    if (name == null || !mounted) return;
    final String target = workspacePathJoin(dirPath, name);
    if (await _entryExists(dirPath, name)) {
      if (!mounted) return;
      _showSnackBar('同名条目已存在，未创建：$target');
      return;
    }
    if (!mounted) return;
    try {
      if (directory) {
        await ApiService.createDirectory(widget.workspaceId, target);
      } else {
        await ApiService.saveFileContent(
          widget.workspaceId,
          target,
          '',
          teamId: widget.teamId ?? '',
        );
      }
    } on Exception catch (error) {
      if (!mounted) return;
      final String reason = _reason(error);
      _showSnackBar('$action失败：$reason');
      return;
    }
    if (!mounted) return;
    setState(() {
      if (dirPath.isNotEmpty) _expanded.add(dirPath);
      _selectedPath = target;
    });
    widget.onPathChanged?.call(dirPath);
    await _loadDir(dirPath);
    await _refreshGitStatus();
    if (!mounted) return;
    _showSnackBar('$action：$target');
  }

  /// 创建前的**新鲜**重名复查（列目录那一刻的同名条目也算数）
  Future<bool> _entryExists(String dirPath, String name) async {
    try {
      final FileListing listing = await ApiService.getFilesWithMeta(
        widget.workspaceId,
        path: dirPath,
        teamId: widget.teamId ?? '',
      );
      return listing.nodes.any(
        (FileNode node) => node.name.toLowerCase() == name.toLowerCase(),
      );
    } on Exception {
      // 列不动目录时不额外拦：真写不进去核心会给可读错误
      return false;
    }
  }

  /// 名字输入框（新建用）：校验不过就在对话框里给红字，不关框
  Future<String?> _promptEntryName({
    required String title,
    required String initial,
    required String dirPath,
  }) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _EntryNameDialog(
        title: title,
        initial: initial,
        dirPath: dirPath,
      ),
    );
  }

  /// 进入行内重命名（选中名字本体，扩展名不动，与 VS Code 一致）
  void _startRename(FileNode node, String path) {
    setState(() {
      _renamingPath = path;
      _renameError = null;
      _selectedPath = path;
      _renameController.text = node.name;
      _renameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: entryNameSelectionLength(node.name),
      );
    });
    widget.onPathChanged?.call(workspacePathParent(path));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _renamingPath == path) _renameFocus.requestFocus();
    });
  }

  void _cancelRename() {
    if (_renamingPath == null) return;
    setState(() {
      _renamingPath = null;
      _renameError = null;
    });
  }

  /// 提交行内重命名：本地校验（空 / 非法字符 / 重名）先挡一道，核心 409/404 再给可读原因
  Future<void> _commitRename(FileNode node, String path, String rawName) async {
    final String dir = workspacePathParent(path);
    final List<String> siblings = <String>[
      for (final FileNode sibling
          in _listings[dir]?.nodes ?? const <FileNode>[])
        sibling.name,
    ];
    final String? problem = validateEntryName(
      rawName,
      siblings: siblings,
      originalName: node.name,
    );
    if (problem != null) {
      setState(() => _renameError = problem);
      _renameFocus.requestFocus();
      return;
    }
    final String next = workspacePathJoin(dir, rawName.trim());
    try {
      await ApiService.renamePath(widget.workspaceId, path, next);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _renameError = _reason(error));
      _renameFocus.requestFocus();
      return;
    }
    if (!mounted) return;
    setState(() {
      _renamingPath = null;
      _renameError = null;
      _remapSubtree(path, next);
      _selectedPath = next;
    });
    widget.onPathChanged?.call(workspacePathParent(next));
    widget.onPathRenamed?.call(path, next);
    await _loadDir(dir);
    await _refreshGitStatus();
    if (!mounted) return;
    final String oldName = node.name;
    final String nextName = rawName.trim();
    _showSnackBar('已重命名：$oldName → $nextName');
  }

  /// 改名 / 移动之后把内存里的键整段换掉：展开状态、已加载的目录、错误、选中/悬停
  void _remapSubtree(String from, String to) {
    final Set<String> expanded = <String>{
      for (final String path in _expanded) workspacePathRemap(path, from, to),
    };
    _expanded
      ..clear()
      ..addAll(expanded);

    final Map<String, FileListing> listings = <String, FileListing>{
      for (final MapEntry<String, FileListing> entry in _listings.entries)
        workspacePathRemap(entry.key, from, to): entry.value,
    };
    _listings
      ..clear()
      ..addAll(listings);

    final Map<String, String> errors = <String, String>{
      for (final MapEntry<String, String> entry in _errors.entries)
        workspacePathRemap(entry.key, from, to): entry.value,
    };
    _errors
      ..clear()
      ..addAll(errors);

    if (_selectedPath != null) {
      _selectedPath = workspacePathRemap(_selectedPath!, from, to);
    }
    if (_hoveredPath != null) {
      _hoveredPath = workspacePathRemap(_hoveredPath!, from, to);
    }
  }

  /// 删除前确认。
  ///
  /// 递归口径**显式**：目录一律连着内容一起删（[ApiService.deletePath] 带
  /// recursive=1），确认框里把这件事说清楚——不静默递归，也不做半截。
  /// 工作空间根永远不许删（前端先拦，核心再拦一道）。
  Future<void> _confirmDelete(FileNode node, String path) async {
    if (path.isEmpty) {
      _showSnackBar('不能删除工作空间根目录');
      return;
    }
    final bool isDir = node.isDirectory;
    final String name = node.name;
    final String dialogMessage = isDir
        ? '确定删除「$name」吗？\n\n这是文件夹：里面的内容会一起删除（递归），删除后不可恢复。'
        : '确定删除「$name」吗？\n\n删除后不可恢复。';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(isDir ? '删除文件夹' : '删除文件'),
        content: Text(dialogMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ApiService.deletePath(
        widget.workspaceId,
        path,
        recursive: isDir,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      final String reason = _reason(error);
      _showSnackBar('删除失败：$reason');
      return;
    }
    if (!mounted) return;
    final String parent = workspacePathParent(path);
    setState(() {
      _listings.removeWhere(
        (String key, _) => key == path || workspacePathAtOrUnder(key, path),
      );
      _errors.removeWhere(
        (String key, _) => key == path || workspacePathAtOrUnder(key, path),
      );
      _expanded.removeWhere(
        (String key) => key == path || workspacePathAtOrUnder(key, path),
      );
      if (_selectedPath != null &&
          workspacePathAtOrUnder(_selectedPath!, path)) {
        _selectedPath = null;
      }
      if (_renamingPath != null &&
          workspacePathAtOrUnder(_renamingPath!, path)) {
        _renamingPath = null;
        _renameError = null;
      }
      if (_hoveredPath != null && workspacePathAtOrUnder(_hoveredPath!, path)) {
        _hoveredPath = null;
      }
      // 父目录的列举里立刻把它拿掉：删除后树里当场消失，不用等重拉回来
      final FileListing? parentListing = _listings[parent];
      if (parentListing != null) {
        _listings[parent] = FileListing(
          nodes: parentListing.nodes
              .where((FileNode entry) => entry.name != node.name)
              .toList(),
          truncated: parentListing.truncated,
        );
      }
    });
    widget.onPathDeleted?.call(path);
    await _loadDir(parent);
    await _refreshGitStatus();
    if (!mounted) return;
    _showSnackBar('已删除：$name');
  }

  /// 在系统文件管理器里定位条目。
  ///
  /// 只有**本地模式 + 显式配置过工作目录**才能算出绝对路径（核心默认工作空间在
  /// 核心数据根下，前端不知道那个路径）；做不到时给可读原因，不假装成功。
  Future<void> _reveal(String path) async {
    if (isMobile) {
      _showSnackBar('移动端不支持在本地文件管理器中定位');
      return;
    }
    final String teamId = widget.teamId ?? '';
    // 配置可能还没拉过（面板只读缓存）：这里补齐一次，否则会把"没拉过"误报成"没配置"
    await LocalExecutorService.instance.ensureTeam(teamId);
    if (!mounted) return;
    if (!LocalExecutorService.instance.isTeamEnabled(teamId)) {
      _showSnackBar('该 agent 走 SSH 远端工作区，文件不在本机，无法在文件管理器中定位');
      return;
    }
    final String root = LocalExecutorService.instance.teamWorkingDirectory(
      teamId,
    );
    if (root.isEmpty) {
      _showSnackBar(
        '该 agent 没有显式配置本地工作目录（核心默认工作空间在核心数据根下），前端算不出它的绝对路径',
      );
      return;
    }
    final String relative = path.replaceAll('/', Platform.pathSeparator);
    final String absolute = root + Platform.pathSeparator + relative;
    final String? error = await FileReveal.reveal(absolute);
    if (!mounted || error == null) return;
    _showSnackBar(error);
  }

  /// 复制工作空间相对路径（VS Code 的 Copy Relative Path 口径）
  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    _showSnackBar('已复制相对路径：$path');
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 异常 → 可直接显示的原因（核心抛的是 Exception(detail)）
  static String _reason(Object error) =>
      error.toString().replaceFirst('Exception: ', '');
}

/// 新建文件 / 文件夹的**名字输入框**。
///
/// 为什么是独立 StatefulWidget、而不是在 showDialog 里挂一个 controller：对话框的
/// 退场动画还在跑的时候，showDialog 的 Future 就已经 complete 了；在那里 dispose
/// 控制器会撞上 `TextEditingController was used after being disposed`（退场那一帧
/// 输入框还在重建）。控制器归本控件自己的 dispose 管，生命周期才对。
class _EntryNameDialog extends StatefulWidget {
  const _EntryNameDialog({
    required this.title,
    required this.initial,
    required this.dirPath,
  });

  final String title;
  final String initial;
  final String dirPath;

  @override
  State<_EntryNameDialog> createState() => _EntryNameDialogState();
}

class _EntryNameDialogState extends State<_EntryNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String raw = _controller.text;
    final String? problem = validateEntryName(
      raw,
      siblings: <String>[],
      originalName: null,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.dirPath.isEmpty
                ? '位置：工作空间根目录'
                : '位置：${widget.dirPath}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            autofocus: true,
            controller: _controller,
            decoration: InputDecoration(labelText: '名字', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}
