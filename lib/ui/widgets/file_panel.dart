import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import 'file_sync_button.dart';
import 'file_tree.dart';
import 'file_viewer.dart';
import 'git_history.dart';
import 'mcp_config_panel.dart';
import 'model_info_panel.dart';
import 'todo_panel.dart';

/// 文件管理面板（右栏）
///
/// 作为右栏的主容器，以 Tab 组织三个分区：
/// - 「文件」：文件浏览（[FileTree]）/ Git 历史（[GitHistory]）/ Todo（[TodoPanel]）
/// - 「MCP 配置」：MCP 服务列表与注册（[McpConfigPanel]）
/// - 「模型信息」：模型下拉与系统提示词编辑（[ModelInfoPanel]）
///
/// 点击文件时以覆盖层方式弹出 [FileViewer]，点击返回按钮关闭查看器。
class FilePanel extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 所属顶层 agent ID（Todo 面板本地模式读取、模型信息页需要）
  final String? topAgentId;

  /// 折叠右侧栏的回调
  final VoidCallback? onCollapse;

  const FilePanel({
    super.key,
    required this.workspaceId,
    this.topAgentId,
    this.onCollapse,
  });

  @override
  State<FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<FilePanel>
    with TickerProviderStateMixin {
  /// 顶层 Tab 控制器（0=文件，1=MCP 配置，2=模型信息）
  late final TabController _tabController;

  /// 文件子 Tab 控制器（0=文件浏览，1=Git 历史，2=Todo）
  late final TabController _fileTabController;

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
    _tabController = TabController(length: 3, vsync: this);
    _fileTabController = TabController(length: 3, vsync: this);
    // 本地模式开关/工作目录变化时重新加载文件列表
    LocalExecutorService.instance.addListener(_onLocalModeChanged);
  }

  @override
  void dispose() {
    LocalExecutorService.instance.removeListener(_onLocalModeChanged);
    _tabController.dispose();
    _fileTabController.dispose();
    super.dispose();
  }

  /// 本地执行模式状态变化（切换开关/选择工作目录）时刷新文件树。
  ///
  /// 本地模式下文件面板数据源从云端容器切换到用户本机目录，
  /// 若不刷新则仍显示旧的（容器内）文件列表。
  void _onLocalModeChanged() {
    if (!mounted) return;
    _refreshFileTree();
  }

  /// 关闭文件查看器
  void _closeViewer() {
    setState(() {
      _selectedFilePath = null;
    });
  }

  /// 处理文件/文件夹下载
  ///
  /// 从后端获取文件/文件夹字节后，弹出系统保存对话框保存到本地。
  /// 移动端不支持系统保存对话框（file_picker.saveFile 仅桌面），直接提示。
  Future<void> _handleDownload(String path, bool isDirectory) async {
    if (isMobile) {
      _showSnackBar('移动端暂不支持保存到本地文件系统，请到桌面端下载');
      return;
    }
    try {
      // 显示加载提示
      _showSnackBar('正在下载...');
      final Uint8List bytes = isDirectory
          ? await ApiService.downloadFolder(widget.workspaceId, path)
          : await ApiService.downloadFile(widget.workspaceId, path);

      // 弹出系统保存对话框
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: isDirectory ? '保存文件夹' : '保存文件',
        fileName: isDirectory
            ? '${path.split('/').last}.tar.gz'
            : path.split('/').last,
      );

      if (savePath != null) {
        // 手动写入文件（file_picker 5.3.1 不支持 bytes 参数）
        await File(savePath).writeAsBytes(bytes);
        _showSnackBar('下载完成：${savePath.split(Platform.pathSeparator).last}');
      }
    } on Exception catch (e) {
      String msg = e.toString().replaceFirst('Exception: ', '');
      _showSnackBar('下载失败：$msg');
    }
  }

  /// 显示 SnackBar 提示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // 顶层 Tab 栏（文件 / MCP 配置 / 模型信息）+ 折叠按钮
          _buildTopTabBar(),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).dividerColor,
          ),
          // 内容区域：按顶层 Tab 切换
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFileSection(),
                const McpConfigPanel(),
                ModelInfoPanel(agentId: widget.topAgentId ?? ''),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶层 Tab 栏
  Widget _buildTopTabBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      color: cs.surface,
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: _tabController,
              labelColor: cs.primary,
              unselectedLabelColor: cs.onSurfaceVariant,
              indicatorColor: cs.primary,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              tabs: const [
                Tab(text: '文件'),
                Tab(text: 'MCP 配置'),
                Tab(text: '模型信息'),
              ],
            ),
          ),
          // 折叠右侧栏
          IconButton(
            tooltip: '折叠右侧栏',
            icon: const Icon(Icons.chevron_right),
            onPressed: widget.onCollapse,
          ),
        ],
      ),
    );
  }

  /// 文件分区：子 Tab 栏（文件浏览 / Git 历史 / Todo）+ 内容 + FileViewer 覆盖层
  Widget _buildFileSection() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 子 Tab 栏 + 文件同步按钮
        Container(
          color: cs.surface,
          padding: const EdgeInsets.only(right: 4),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _fileTabController,
                  labelColor: cs.primary,
                  unselectedLabelColor: cs.onSurfaceVariant,
                  indicatorColor: cs.primary,
                  indicatorSize: TabBarIndicatorSize.label,
                  labelStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(fontSize: 12),
                  tabs: const [
                    Tab(text: '文件浏览'),
                    Tab(text: 'Git 历史'),
                    Tab(text: 'Todo'),
                  ],
                ),
              ),
              FileSyncButton(
                workspaceId: widget.workspaceId,
                onUploaded: _refreshFileTree,
              ),
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).dividerColor,
        ),
        // 内容区域（使用 Stack 叠加 FileViewer 覆盖层）
        Expanded(
          child: Stack(
            children: [
              // 子 Tab 内容
              TabBarView(
                controller: _fileTabController,
                children: [
                  FileTree(
                    workspaceId: widget.workspaceId,
                    refreshTrigger: _fileRefreshTrigger,
                    onDownload: _handleDownload,
                    onFileSelected: (String path) {
                      setState(() {
                        _selectedFilePath = path;
                      });
                    },
                  ),
                  GitHistory(workspaceId: widget.workspaceId),
                  TodoPanel(
                    workspaceId: widget.workspaceId,
                    topAgentId: widget.topAgentId,
                    refreshTrigger: _fileRefreshTrigger,
                  ),
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
    );
  }
}
