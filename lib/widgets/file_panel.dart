import 'package:flutter/material.dart';

import 'file_sync_button.dart';
import 'file_tree.dart';
import 'file_viewer.dart';
import 'git_history.dart';

/// 文件管理面板（右栏）
///
/// 集成文件浏览、Git 历史与文件同步功能，作为右栏的主容器：
/// - 顶部标题栏："文件管理" + [FileSyncButton]
/// - Tab 切换："文件浏览"（[FileTree]） / "Git 历史"（[GitHistory]）
/// - 点击文件时以覆盖层方式弹出 [FileViewer]，点击返回按钮关闭查看器
class FilePanel extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  const FilePanel({
    super.key,
    required this.workspaceId,
  });

  @override
  State<FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<FilePanel>
    with SingleTickerProviderStateMixin {
  /// Tab 控制器（0=文件浏览，1=Git 历史）
  late final TabController _tabController;

  /// 当前选中的文件路径（非空时展示 FileViewer 覆盖层）
  String? _selectedFilePath;

  /// 文件树刷新触发器（上传等操作后递增，触发 FileTree 重新加载）
  int _fileRefreshTrigger = 0;

  /// 刷新文件树
  void _refreshFileTree() {
    setState(() {
      _fileRefreshTrigger++;
    });
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 关闭文件查看器
  void _closeViewer() {
    setState(() {
      _selectedFilePath = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // 标题栏：文件管理 + 同步按钮
          _buildTitleBar(),
          // Tab 栏
          _buildTabBar(),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).dividerColor,
          ),
          // 内容区域（使用 Stack 叠加 FileViewer 覆盖层）
          Expanded(
            child: Stack(
              children: [
                // Tab 内容
                TabBarView(
                  controller: _tabController,
                  children: [
                    FileTree(
                      workspaceId: widget.workspaceId,
                      refreshTrigger: _fileRefreshTrigger,
                      onFileSelected: (String path) {
                        setState(() {
                          _selectedFilePath = path;
                        });
                      },
                    ),
                    GitHistory(workspaceId: widget.workspaceId),
                  ],
                ),
                // FileViewer 覆盖层（选中文件时显示）
                if (_selectedFilePath != null)
                  Positioned.fill(
                    child: FileViewer(
                      workspaceId: widget.workspaceId,
                      filePath: _selectedFilePath!,
                      onClose: _closeViewer,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建标题栏
  ///
  /// 高度 48px，白色背景，底部 1px 分隔线。
  /// 左侧显示"文件管理"，右侧显示文件同步按钮。
  Widget _buildTitleBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          const Text(
            '文件管理',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          FileSyncButton(
            workspaceId: widget.workspaceId,
            onUploaded: _refreshFileTree,
          ),
        ],
      ),
    );
  }

  /// 构建 Tab 栏
  Widget _buildTabBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      child: TabBar(
        controller: _tabController,
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        indicatorColor: cs.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
        tabs: const [
          Tab(text: '文件浏览'),
          Tab(text: 'Git 历史'),
        ],
      ),
    );
  }
}
