import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../../io/workspace_refresh_service.dart';
import '../services/download_center.dart';
import 'file_sync_button.dart';
import 'file_tree.dart';
import 'file_viewer.dart';
import 'git_history.dart';
import 'mcp_config_panel.dart';
import 'model_info_panel.dart';
import 'question_panel.dart';
import 'todo_panel.dart';

/// 文件管理面板（右栏）
///
/// 作为右栏的主容器，以 Tab 组织四个分区：
/// - 「文件」：文件浏览（[FileTree]）/ Git 历史（[GitHistory]）/ Todo（[TodoPanel]）
/// - 「MCP 配置」：MCP 服务列表与注册（[McpConfigPanel]）
/// - 「模型信息」：模型下拉、系统提示词与模型参数覆盖（[ModelInfoPanel]）
/// - 「问题回复」：统一汇总并答复所有提问（[QuestionPanel]）
///
/// 「插件」原本是这里的第 5 个页签，已迁到**左侧活动栏**（见
/// `main_page.dart` 的 `_buildActivityBar`），与 Agent 列表并列。
///
/// 点击文件时以覆盖层方式弹出 [FileViewer]，点击返回按钮关闭查看器。
class FilePanel extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 所属团队 ID（Todo 面板本地模式读取、模型信息页需要）
  final String? teamId;

  /// 所属团队显示名（下载列表里标注「来自哪个 team」）；为空时退回 [teamId]。
  final String teamName;

  /// 当前会话 ID（Todo 面板按会话隔离查询 todos）
  final String sessionId;

  /// 折叠右侧栏的回调
  final VoidCallback? onCollapse;

  /// 提问定位回调（透传给 [QuestionPanel]）
  final QuestionNavigateCallback? onNavigateToQuestion;

  const FilePanel({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.teamName = '',
    this.sessionId = 'session_default',
    this.onCollapse,
    this.onNavigateToQuestion,
  });

  @override
  State<FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<FilePanel> with TickerProviderStateMixin {
  /// 顶层 Tab 控制器（0=文件，1=MCP 配置，2=模型信息）
  late final TabController _tabController;

  /// 文件子 Tab 控制器（0=文件浏览，1=Git 历史，2=Todo）
  late final TabController _fileTabController;

  /// 当前选中的文件路径（非空时展示 FileViewer 覆盖层）
  String? _selectedFilePath;

  /// 文件树刷新触发器（上传等操作后递增，触发 FileTree 重新加载）
  int _fileRefreshTrigger = 0;

  /// 文件树当前所在目录（空 = 根）；「同步到本地」按它限定作用域（M8b）
  String _treePath = '';

  /// Git 历史刷新触发器
  int _gitRefreshTrigger = 0;

  /// Todo 列表刷新触发器
  int _todoRefreshTrigger = 0;

  /// 刷新文件树（兼容旧调用：视为文件区域）
  void _refreshFileTree() {
    setState(() {
      _fileRefreshTrigger++;
    });
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _fileTabController = TabController(length: 3, vsync: this);
    // 本地模式开关/工作目录变化时重新加载文件列表
    LocalExecutorService.instance.addListener(_onLocalModeChanged);
    // 工作空间数据变更（文件/Git/Todo 工具执行）时即时刷新右栏
    WorkspaceRefreshService.instance.addListener(_onWorkspaceChanged);
  }

  @override
  void dispose() {
    LocalExecutorService.instance.removeListener(_onLocalModeChanged);
    WorkspaceRefreshService.instance.removeListener(_onWorkspaceChanged);
    _tabController.dispose();
    _fileTabController.dispose();
    super.dispose();
  }

  /// 工作空间数据变更（工具写文件 / git 提交 / 更新 todo）时增量刷新右栏。
  ///
  /// 依据变更影响的区域，只递增对应 tab 的触发器；只读工具不触发，
  /// 不再"切 Tab 再切回"也无需整表重拉。
  void _onWorkspaceChanged() {
    if (!mounted) return;
    final Set<WorkspaceArea>? areas = WorkspaceRefreshService.instance
        .takeAreas();
    if (areas == null || areas.isEmpty) return;
    setState(() {
      if (areas.contains(WorkspaceArea.files)) {
        _fileRefreshTrigger++;
      }
      if (areas.contains(WorkspaceArea.git)) {
        _gitRefreshTrigger++;
      }
      if (areas.contains(WorkspaceArea.todo)) {
        _todoRefreshTrigger++;
      }
    });
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

  /// 处理文件/文件夹下载（M8c/M8d）
  ///
  /// - 文件：选保存目录后**流式**写盘，任务交给 [DownloadCenter] 在左栏「下载」
  ///   里展示进度（后台进行，不阻塞界面）；
  /// - 文件夹：核心先打成 tar.gz 再交给系统保存对话框（受核心打包上限约束）。
  Future<void> _handleDownload(String path, bool isDirectory) async {
    if (isMobile) {
      _showSnackBar('移动端暂不支持保存到本地文件系统，请到桌面端下载');
      return;
    }
    final String name = path.isEmpty ? 'workspace' : path.split('/').last;
    if (isDirectory) {
      final DownloadTask task = DownloadCenter.instance.begin(
        kind: DownloadKind.folder,
        name: '$name.tar.gz',
        sourceTeam: widget.teamName,
        sourceTeamId: widget.teamId ?? '',
      );
      try {
        _showSnackBar('正在打包 $name ...');
        final Uint8List bytes = await ApiService.downloadFolder(
          widget.workspaceId,
          path,
          teamId: widget.teamId ?? '',
        );
        final Uri? savedUri = await FilePicker.saveFile(
          dialogTitle: '保存文件夹',
          fileName: '$name.tar.gz',
          bytes: bytes,
        );
        if (!mounted) return;
        if (savedUri == null) {
          DownloadCenter.instance.cancel(task);
          return;
        }
        DownloadCenter.instance.complete(
          task,
          localPath: _uriToPath(savedUri),
          totalBytes: bytes.length,
        );
        _showSnackBar('已保存：${_uriBaseName(savedUri)}');
      } on Exception catch (e) {
        final String msg = e.toString().replaceFirst('Exception: ', '');
        DownloadCenter.instance.fail(task, msg);
        _showSnackBar('下载失败：$msg');
      }
      return;
    }

    final String? dirPath = await FilePicker.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dirPath == null || dirPath.isEmpty) return;
    if (!mounted) return;
    final String savePath = '$dirPath${Platform.pathSeparator}$name';
    unawaited(
      DownloadCenter.instance.startFileDownload(
        workspaceId: widget.workspaceId,
        path: path,
        savePath: savePath,
        name: name,
        sourceTeam: widget.teamName,
        sourceTeamId: widget.teamId ?? '',
        teamId: widget.teamId ?? '',
      ),
    );
    _showSnackBar('已加入下载列表：$name');
  }

  /// file_picker 返回的 Uri → 本地路径（非 file 协议时给原样字符串）。
  static String _uriToPath(Uri uri) =>
      uri.scheme == 'file' ? uri.toFilePath() : uri.toString();

  static String _uriBaseName(Uri uri) {
    final String path = _uriToPath(uri);
    return path.split(Platform.pathSeparator).last;
  }

  /// 显示 SnackBar 提示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // 顶层 Tab 栏（文件 / MCP 配置 / 模型信息 / 问题回复 / 插件）+ 折叠按钮
          _buildTopTabBar(),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).dividerColor,
          ),
          // 内容区域：按顶层 Tab 切换
          Expanded(
            child: GestureDetector(
              // 点击任意页签内容区的空白处折叠右侧栏（文件较少、Todo 为空、
              // MCP 配置、模型信息等的大片空白均生效）。子项自带点击手势
              // （列表项、Tab、按钮等）会优先消费，只有点到真正空白处才命中，
              // 不会误伤内容交互。打开 FileViewer 时禁止折叠。
              behavior: HitTestBehavior.translucent,
              onTap: _selectedFilePath == null ? widget.onCollapse : null,
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildFileSection(),
                  const McpConfigPanel(),
                  ModelInfoPanel(agentId: widget.teamId ?? ''),
                  QuestionPanel(
                    sessionId: widget.sessionId,
                    onNavigateToQuestion: widget.onNavigateToQuestion,
                  ),
                ],
              ),
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
              isScrollable: true,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              tabs: const [
                Tab(text: '文件'),
                Tab(text: 'MCP 配置'),
                Tab(text: '模型信息'),
                Tab(text: '问题回复'),
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
                teamId: widget.teamId ?? '',
                currentPath: _treePath,
                onUploaded: _refreshFileTree,
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
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
                    teamId: widget.teamId,
                    refreshTrigger: _fileRefreshTrigger,
                    onDownload: _handleDownload,
                    onPathChanged: (String path) {
                      if (path == _treePath) return;
                      setState(() {
                        _treePath = path;
                      });
                    },
                    onFileSelected: (String path) {
                      setState(() {
                        _selectedFilePath = path;
                      });
                    },
                  ),
                  GitHistory(
                    workspaceId: widget.workspaceId,
                    teamId: widget.teamId,
                    refreshTrigger: _gitRefreshTrigger,
                  ),
                  TodoPanel(
                    workspaceId: widget.workspaceId,
                    teamId: widget.teamId,
                    sessionId: widget.sessionId,
                    refreshTrigger: _todoRefreshTrigger,
                  ),
                ],
              ),
              // FileViewer 覆盖层（选中文件时显示）
              if (_selectedFilePath != null)
                Positioned.fill(
                  child: FileViewer(
                    workspaceId: widget.workspaceId,
                    teamId: widget.teamId,
                    teamName: widget.teamName,
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
