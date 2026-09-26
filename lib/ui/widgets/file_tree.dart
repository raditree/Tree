import 'package:flutter/material.dart';

import '../models/file_node.dart';
import '../../io/api_service.dart';

/// 文件树组件
///
/// 通过 API 获取工作空间文件列表，以"当前目录 + 面包屑导航"的方式
/// 展示文件树。点击文件夹进入下一级（展开），点击面包屑中的上级目录
/// 返回上一层（折叠）。点击文件时通过 [onFileSelected] 回调通知父组件。
///
/// 顶部面包屑显示当前路径，每个路径段可点击跳转；列表中目录排在文件之前，
/// 文件夹使用黄色 folder 图标，文件使用灰色 insert_drive_file 图标。
/// 加载中显示 CircularProgressIndicator，空目录显示"空文件夹"。
class FileTree extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 顶层 agent（team）ID，用于后端三模式分派；为空时后端按 workspaceId 兜底
  final String? teamId;

  /// 文件选中回调，参数为文件的相对路径
  final ValueChanged<String>? onFileSelected;

  /// 文件/文件夹下载回调，参数为路径和是否为目录
  final void Function(String path, bool isDirectory)? onDownload;

  /// 刷新触发器：递增时重新加载当前目录文件列表
  final int refreshTrigger;

  /// 当前目录变化回调（进入子目录 / 点面包屑时触发）。
  ///
  /// 「同步到本地」用它把作用域限制在当前这一层（M8b）。
  final ValueChanged<String>? onPathChanged;

  const FileTree({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.onFileSelected,
    this.onDownload,
    this.onPathChanged,
    this.refreshTrigger = 0,
  });

  @override
  State<FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<FileTree> {
  /// 当前所在目录的相对路径（根目录为空字符串）
  String _currentPath = '';

  /// 当前目录下的文件列表
  List<FileNode> _files = [];

  /// 是否正在加载
  bool _isLoading = true;

  /// 加载错误信息（为空表示无错误）
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFiles();
    // 初始路径（根）在首帧后通知父组件：initState 里回调会撞上父组件 build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPathChanged?.call(_currentPath);
    });
  }

  @override
  void didUpdateWidget(FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工作空间切换或刷新触发器变化时重新加载文件列表
    if (oldWidget.workspaceId != widget.workspaceId ||
        oldWidget.refreshTrigger != widget.refreshTrigger) {
      _loadFiles();
    }
  }

  /// 加载当前路径下的文件列表
  ///
  /// 调用 [ApiService.getFiles] 获取数据，加载完成后按"目录优先 + 名称排序"
  /// 的顺序排列。异常时设置 [_error] 以便 UI 展示。
  Future<void> _loadFiles() async {
    // 软更新：已有旧数据时保持旧列表可见，不闪加载态；仅首次加载显示 spinner
    setState(() {
      _isLoading = _files.isEmpty;
      _error = null;
    });
    try {
      final List<FileNode> files = await ApiService.getFiles(
        widget.workspaceId,
        path: _currentPath,
        teamId: widget.teamId ?? '',
      );
      // 排序：目录在前，文件在后；同类按名称字母序
      files.sort((FileNode a, FileNode b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _files = files;
          _isLoading = false;
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  /// 进入子目录
  ///
  /// 拼接新路径并重新加载文件列表。
  void _enterDirectory(FileNode dir) {
    String newPath;
    if (dir.path.isNotEmpty) {
      // 优先使用后端返回的 path 字段
      newPath = dir.path;
    } else if (_currentPath.isEmpty) {
      newPath = dir.name;
    } else {
      newPath = '$_currentPath/${dir.name}';
    }
    _currentPath = newPath;
    widget.onPathChanged?.call(_currentPath);
    _loadFiles();
  }

  /// 跳转到面包屑中指定层级的目录
  ///
  /// [index] 为路径段索引，0 表示根目录。
  void _navigateToSegment(int index) {
    if (index == 0) {
      _currentPath = '';
    } else {
      final List<String> segments = _currentPath.split('/');
      _currentPath = segments.sublist(0, index).join('/');
    }
    widget.onPathChanged?.call(_currentPath);
    _loadFiles();
  }

  /// 处理文件点击
  void _handleFileTap(FileNode file) {
    final String path = file.path.isNotEmpty ? file.path : file.name;
    widget.onFileSelected?.call(path);
  }

  /// 获取面包屑路径段列表
  ///
  /// 返回形如 `['根目录', 'src', 'lib']` 的列表。
  List<String> get _breadcrumbSegments {
    final List<String> segments = ['根目录'];
    if (_currentPath.isNotEmpty) {
      segments.addAll(_currentPath.split('/').where((s) => s.isNotEmpty));
    }
    return segments;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 面包屑导航
        _buildBreadcrumb(),
        // 分隔线
        Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
        // 文件列表区域
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// 构建面包屑导航
  ///
  /// 使用 Wrap + TextButton 布局，每个路径段可点击跳转，
  /// 段之间用 ">" 分隔。
  Widget _buildBreadcrumb() {
    final List<String> segments = _breadcrumbSegments;
    final cs = Theme.of(context).colorScheme;
    final List<Widget> chips = [];

    for (int i = 0; i < segments.length; i++) {
      // 当前路径段不需要响应点击（已在当前位置）
      final bool isLast = i == segments.length - 1;
      chips.add(
        TextButton(
          onPressed: isLast ? null : () => _navigateToSegment(i),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: isLast ? cs.onSurfaceVariant : cs.primary,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(segments[i]),
        ),
      );
      if (!isLast) {
        chips.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Icon(Icons.chevron_right, size: 14, color: cs.outline),
          ),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: cs.surface,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: chips,
      ),
    );
  }

  /// 构建文件列表主体
  ///
  /// 根据加载状态分别显示：加载中、错误、空目录、文件列表。
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _buildMessageBody(
        icon: Icons.error_outline,
        iconColor: const Color(0xFFEF4444),
        message: _error!,
      );
    }
    if (_files.isEmpty) {
      return _buildMessageBody(
        icon: Icons.folder_open,
        iconColor: Theme.of(context).colorScheme.outline,
        message: '空文件夹',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _files.length,
      separatorBuilder: (BuildContext context, int index) {
        return Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).scaffoldBackgroundColor,
          indent: 40,
        );
      },
      itemBuilder: (BuildContext context, int index) {
        return _buildFileItem(_files[index]);
      },
    );
  }

  /// 构建单条文件/目录项
  Widget _buildFileItem(FileNode node) {
    final bool isDir = node.isDirectory;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onSecondaryTapDown: (TapDownDetails details) {
        _showContextMenu(context, details.globalPosition, node);
      },
      child: InkWell(
        onTap: () {
          if (isDir) {
            _enterDirectory(node);
          } else {
            _handleFileTap(node);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // 图标
              Icon(
                isDir ? Icons.folder : Icons.insert_drive_file,
                size: 20,
                color: isDir ? const Color(0xFFF59E0B) : cs.outline,
              ),
              const SizedBox(width: 10),
              // 名称
              Expanded(
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
                ),
              ),
              // 大小 + 修改时间
              const SizedBox(width: 8),
              Text(
                node.formattedSize,
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
              const SizedBox(width: 8),
              Text(
                _formatModified(node.modified),
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
              // 目录右侧显示进入箭头
              if (isDir) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 16, color: cs.outline),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 显示右键上下文菜单
  void _showContextMenu(BuildContext context, Offset position, FileNode node) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'download',
          child: Row(
            children: [
              Icon(
                Icons.download,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              const Text('下载'),
            ],
          ),
        ),
      ],
    ).then((String? value) {
      if (value == 'download') {
        final String path = node.path.isNotEmpty ? node.path : node.name;
        widget.onDownload?.call(path, node.isDirectory);
      }
    });
  }

  /// 构建居中提示信息
  Widget _buildMessageBody({
    required IconData icon,
    required Color iconColor,
    required String message,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: iconColor),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  /// 格式化修改时间
  ///
  /// 尝试解析 ISO 字符串并格式化为 "MM-DD HH:mm"，
  /// 解析失败时原样返回（截断到 16 个字符避免过长）。
  String _formatModified(String modified) {
    if (modified.isEmpty) return '';
    final DateTime? dt = DateTime.tryParse(modified);
    if (dt == null) {
      return modified.length > 16 ? modified.substring(0, 16) : modified;
    }
    final String month = dt.month.toString().padLeft(2, '0');
    final String day = dt.day.toString().padLeft(2, '0');
    final String hour = dt.hour.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }
}
