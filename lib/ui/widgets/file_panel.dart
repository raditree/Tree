import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../../io/api_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../../io/workspace_refresh_service.dart';
import '../services/detail_selection.dart';
import '../services/download_center.dart';
import '../services/plugin_ui_registry.dart';
import 'file_sync_button.dart';
import 'file_tree.dart';
import 'detail_panel.dart';
import 'file_viewer.dart';
import 'git_history.dart';
import 'mcp_config_panel.dart';
import 'model_info_panel.dart';
import 'plugin_ui_slots.dart';
import 'question_panel.dart';
import 'split_panes.dart';
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
/// main_page.dart 的 _buildActivityBar），与 Agent 列表并列。
///
/// Q12 插件布局：插件声明的 `panel` 槽位作为**插件 Tab 追加在既有 Tab 之后**
/// （见 [PluginUiRegistry.slotsOfKind]），内容由 [PluginPanelSlotView] 渲染；
/// 槽位变化（manifest / 注销 / 切 team）时按槽位键比对，仅在集合真变化时重建
/// TabController——避免每次 plugin_ui_update 都重置当前页签。
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

  /// 插件槽位注册表（默认全局单例；测试注入独立实例，避免污染单例）
  final PluginUiRegistry? registry;

  const FilePanel({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.teamName = '',
    this.sessionId = 'session_default',
    this.onCollapse,
    this.onNavigateToQuestion,
    this.registry,
  });

  @override
  State<FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<FilePanel> with TickerProviderStateMixin {
  /// 内置顶层 Tab 数量（文件 / MCP 配置 / 模型信息 / 问题回复 / 详情）
  static const int _builtinTabCount = 5;

  /// 「详情」页的固定索引（中栏点了工具行 / 思考行就切到它）
  static const int _detailTabIndex = _builtinTabCount - 1;

  /// 顶层 Tab 控制器（0=文件，1=MCP 配置，2=模型信息，3=问题回复，4=详情，
  /// 之后是插件 panel 槽位；插件槽位集合变化时重建）
  late TabController _tabController;

  /// 顶层 Tab 当前选中索引（重建控制器时保持选中页）
  int _topTabIndex = 0;

  /// 当前 team 可见的插件面板槽位（右栏顶层 Tab 的插件段）
  List<PluginUiSlot> _pluginPanels = <PluginUiSlot>[];

  /// 槽位注册表（默认全局单例）
  PluginUiRegistry get _registry =>
      widget.registry ?? PluginUiRegistry.instance;

  /// 文件子 Tab 控制器（0=文件浏览，1=Git 历史，2=Todo）
  late final TabController _fileTabController;

  /// 查看器窗格（1–2 个），每个是一个工作空间相对路径；空 = 不显示查看器。
  ///
  /// 分屏只做二分（用户 2026-10-02 定夺）：左右 / 上下可切、分隔可拖、各窗格独立
  /// 打开文件与保存。**同一个文件**双开时非活动窗格强制只读——两份缓冲各写各的，
  /// 后保存的那次会把对方写的覆盖掉。
  final List<String> _viewerPaths = <String>[];

  /// 每个窗格的 State key：换文件 / 关窗格前要问它「未保存的内容怎么办」
  final List<GlobalKey<FileViewerState>> _viewerKeys =
      <GlobalKey<FileViewerState>>[];

  /// 当前活动窗格（文件树里点文件换它；点某个窗格也会切过来）
  int _activePane = 0;

  /// 分屏方向（horizontal = 左右）与分隔比例
  Axis _splitAxis = Axis.horizontal;
  double _splitRatio = 0.5;

  /// 窗格分隔条宽度
  static const double _paneDividerWidth = 7;

  /// 是否正显示查看器
  bool get _viewerOpen => _viewerPaths.isNotEmpty;

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

  /// 一键重置工作空间里的系统提示词 / Spec。
  ///
  /// 核心侧语义：现有文件先备份成 `.bak.<n>`，再写回默认内容（Spec 的自定义文件
  /// 一并清理，备份里可找回）。这里不弹二次确认——"一键"就是它的用法，且备份保证可逆。
  Future<void> _resetWorkspace(String target) async {
    final String agentId = widget.teamId ?? '';
    if (agentId.isEmpty) {
      _showSnackBar('未选中 agent，无法重置');
      return;
    }
    try {
      await ApiService.resetAgentWorkspace(agentId, target: target);
      if (!mounted) return;
      _showSnackBar(
        target == 'spec'
            ? '已重置 Spec（旧文件已备份为 .bak.<n>）'
            : '已重置系统提示词（旧文件已备份为 .bak.<n>）',
      );
      if (target != 'system_prompt') _refreshFileTree();
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('重置失败：$error');
    }
  }

  @override
  void initState() {
    super.initState();
    _pluginPanels = _registry.slotsOfKind(PluginUiSlotKind.panel);
    _tabController = TabController(
      length: _builtinTabCount + _pluginPanels.length,
      vsync: this,
    );
    _tabController.addListener(_onTopTabChanged);
    // 中栏点了工具行 / 思考行 → 自动切到「详情」页
    DetailSelection.instance.addListener(_onDetailSelected);
    _fileTabController = TabController(length: 3, vsync: this);
    // Q12：插件槽位（manifest / 注销 / 切 team）变化时重算插件 Tab
    _registry.addListener(_onPluginSlotsChanged);
    // 本地模式开关/工作目录变化时重新加载文件列表
    LocalExecutorService.instance.addListener(_onLocalModeChanged);
    // 工作空间数据变更（文件/Git/Todo 工具执行）时即时刷新右栏
    WorkspaceRefreshService.instance.addListener(_onWorkspaceChanged);
  }

  @override
  void dispose() {
    DetailSelection.instance.removeListener(_onDetailSelected);
    LocalExecutorService.instance.removeListener(_onLocalModeChanged);
    WorkspaceRefreshService.instance.removeListener(_onWorkspaceChanged);
    _registry.removeListener(_onPluginSlotsChanged);
    _tabController.dispose();
    _fileTabController.dispose();
    super.dispose();
  }

  /// 中栏选中了工具行 / 思考行：切到「详情」页。
  ///
  /// 只在**选中**时切（清空不动）：用户点关闭收掉详情后，不该再被拽回这一页。
  void _onDetailSelected() {
    if (!mounted) return;
    if (DetailSelection.instance.message == null) return;
    if (_tabController.index != _detailTabIndex) {
      _tabController.animateTo(_detailTabIndex);
    }
  }

  /// 顶层 Tab 选中索引跟踪（TabController 重建时保持当前页）
  void _onTopTabChanged() {
    if (_tabController.index != _topTabIndex) {
      _topTabIndex = _tabController.index;
    }
  }

  /// 插件槽位集合变化：只有"槽位键序列"真的变了才重建 TabController。
  ///
  /// 视图更新（plugin_ui_update）不改变槽位键，因此不会重置当前页签，也不会
  /// 让用户正在填的表单被重建。
  void _onPluginSlotsChanged() {
    if (!mounted) return;
    final List<PluginUiSlot> slots = _registry.slotsOfKind(
      PluginUiSlotKind.panel,
    );
    if (_samePanelKeys(slots)) {
      return;
    }
    setState(() {
      _pluginPanels = slots;
      _rebuildTopTabController();
    });
  }

  /// 槽位键序列是否与当前一致（顺序敏感：Tab 顺序必须稳定）。
  bool _samePanelKeys(List<PluginUiSlot> slots) {
    if (slots.length != _pluginPanels.length) {
      return false;
    }
    for (int i = 0; i < slots.length; i++) {
      if (slots[i].slotKey != _pluginPanels[i].slotKey) {
        return false;
      }
    }
    return true;
  }

  /// 重建顶层 TabController（长度变了必须重建；保持当前选中页）
  void _rebuildTopTabController() {
    final int length = _builtinTabCount + _pluginPanels.length;
    final int index = _topTabIndex.clamp(0, length - 1);
    _tabController.dispose();
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: index,
    );
    _tabController.addListener(_onTopTabChanged);
    _topTabIndex = index;
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
  /// 切换执行模式会改变文件面板的数据源（本机目录 / 远端工作空间），
  /// 若不刷新则仍显示上一个数据源的文件列表。
  void _onLocalModeChanged() {
    if (!mounted) return;
    _refreshFileTree();
  }

  /// 打开文件：没有窗格就新建，有就换**活动窗格**的内容（先处理未保存的改动）。
  Future<void> _openViewer(String path) async {
    if (_viewerPaths.isEmpty) {
      setState(() {
        _viewerPaths.add(path);
        _viewerKeys.add(GlobalKey<FileViewerState>());
        _activePane = 0;
      });
      return;
    }
    final int index = _activePane.clamp(0, _viewerPaths.length - 1);
    if (_viewerPaths[index] == path) return;
    if (!await _confirmLeave(index)) return;
    if (!mounted) return;
    setState(() {
      _viewerPaths[index] = path;
    });
  }

  /// 分屏：把当前文件再开一个窗格（第二个窗格只读，见 [_isDuplicatePane]）
  void _splitViewer() {
    if (_viewerPaths.length >= 2 || _viewerPaths.isEmpty) return;
    setState(() {
      _viewerPaths.add(_viewerPaths[_activePane]);
      _viewerKeys.add(GlobalKey<FileViewerState>());
      _activePane = 1;
    });
  }

  /// 关闭一个窗格（未保存的内容按设置自动保存或问一次）
  Future<void> _closePane(int index) async {
    if (index < 0 || index >= _viewerPaths.length) return;
    if (!await _confirmLeave(index)) return;
    if (!mounted) return;
    setState(() {
      _viewerPaths.removeAt(index);
      _viewerKeys.removeAt(index);
      _activePane = _activePane.clamp(0, _viewerPaths.length - 1);
    });
  }

  /// 关闭整个查看器：每个窗格都要先处理未保存的改动，任何一个取消就整体不关
  Future<void> _closeViewer() async {
    for (int i = 0; i < _viewerPaths.length; i++) {
      if (!await _confirmLeave(i)) return;
      if (!mounted) return;
    }
    setState(() {
      _viewerPaths.clear();
      _viewerKeys.clear();
      _activePane = 0;
    });
  }

  /// 离开某个窗格前把未保存内容处理掉（true = 可以离开）
  Future<bool> _confirmLeave(int index) async {
    if (index < 0 || index >= _viewerKeys.length) return true;
    final FileViewerState? state = _viewerKeys[index].currentState;
    if (state == null) return true;
    return state.confirmLeave();
  }

  /// 这个窗格里的文件是否也在别的窗格里开着（是 ⇒ 本窗格锁只读）
  bool _isDuplicatePane(int index) {
    final String path = _viewerPaths[index];
    for (int i = 0; i < _viewerPaths.length; i++) {
      if (i != index && _viewerPaths[i] == path) return true;
    }
    return false;
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
              onTap: _viewerOpen ? null : widget.onCollapse,
              child: TabBarView(
                controller: _tabController,
                children: <Widget>[
                  _buildFileSection(),
                  const McpConfigPanel(),
                  ModelInfoPanel(agentId: widget.teamId ?? ''),
                  QuestionPanel(
                    sessionId: widget.sessionId,
                    onNavigateToQuestion: widget.onNavigateToQuestion,
                  ),
                  // 详情页：中栏点中的工具调用 / 思考完整摊开（见 DetailPanel）
                  const DetailPanel(),
                  // Q12：插件面板 Tab（追加在既有 Tab 之后）
                  for (final PluginUiSlot slot in _pluginPanels)
                    PluginPanelSlotView(
                      slot: slot,
                      registry: _registry,
                      agentId: widget.teamId ?? '',
                      sessionId: widget.sessionId,
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
              tabs: <Widget>[
                const Tab(text: '文件'),
                const Tab(text: 'MCP 配置'),
                const Tab(text: '模型信息'),
                const Tab(text: '问题回复'),
                const Tab(text: '详情'),
                // Q12 插件 Tab：追加在既有五个 Tab 之后，文案用槽位 title
                for (final PluginUiSlot slot in _pluginPanels)
                  Tab(text: pluginSlotLabel(slot)),
              ],
            ),
          ),
          // 一键重置（备份 .bak.<n> 后还原默认）：系统提示词 / Spec
          IconButton(
            tooltip: '重置系统提示词（备份 .bak.<n>）',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.assignment_return_outlined, size: 18),
            onPressed: () => _resetWorkspace('system_prompt'),
          ),
          IconButton(
            tooltip: '重置 Spec（备份 .bak.<n>）',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.rule_folder_outlined, size: 18),
            onPressed: () => _resetWorkspace('spec'),
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

  /// 查看器工具条：分屏 / 切方向 / 关窗格 / 关查看器。
  ///
  /// 为什么控件放顶栏而不是塞进每个窗格的标题栏：窗格可能被拖得很窄，标题栏还要
  /// 放文件名、语言标签、保存键；而分屏是「整个查看器」的动作，独立一条更稳。
  Widget _buildViewerToolbar() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool twoPanes = _viewerPaths.length == 2;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: cs.surface,
      child: Row(
        children: <Widget>[
          Text(
            twoPanes ? '2 个窗格' : '1 个窗格',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          if (twoPanes)
            IconButton(
              icon: Icon(
                _splitAxis == Axis.horizontal
                    ? Icons.splitscreen_outlined
                    : Icons.view_agenda_outlined,
                size: 16,
              ),
              tooltip: _splitAxis == Axis.horizontal ? '切成上下分屏' : '切成左右分屏',
              color: cs.onSurfaceVariant,
              onPressed: () {
                setState(() {
                  _splitAxis = _splitAxis == Axis.horizontal
                      ? Axis.vertical
                      : Axis.horizontal;
                });
              },
            ),
          if (!twoPanes)
            IconButton(
              icon: const Icon(Icons.vertical_split_outlined, size: 16),
              tooltip: '分屏：同一个文件再开一个窗格（第二个窗格只读）',
              color: cs.onSurfaceVariant,
              onPressed: _splitViewer,
            ),
          if (twoPanes)
            IconButton(
              icon: const Icon(Icons.close_fullscreen, size: 16),
              tooltip: '关闭当前窗格',
              color: cs.onSurfaceVariant,
              onPressed: () => unawaited(_closePane(_activePane)),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '关闭查看器',
            color: cs.onSurfaceVariant,
            onPressed: () => unawaited(_closeViewer()),
          ),
        ],
      ),
    );
  }

  /// 窗格区：1 个铺满；2 个交给 [SplitPanes]（方向 / 比例 / 太窄降级都在那里，可单测）
  Widget _buildPanes() {
    if (_viewerPaths.length < 2) return _buildPane(0);
    return SplitPanes(
      axis: _splitAxis,
      ratio: _splitRatio,
      dividerWidth: _paneDividerWidth,
      onRatioChanged: (double next) {
        setState(() {
          _splitRatio = next;
        });
      },
      first: _buildPane(0),
      second: _buildPane(1),
      degraded: _buildPane(_activePane.clamp(0, 1)),
    );
  }

  /// 单个窗格：点它成为活动窗格；同文件双开时锁只读
  Widget _buildPane(int index) {
    if (index < 0 || index >= _viewerPaths.length) {
      return const SizedBox.shrink();
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool active = index == _activePane;
    final bool duplicated = _isDuplicatePane(index);
    final Widget viewer = FileViewer(
      key: _viewerKeys[index],
      workspaceId: widget.workspaceId,
      teamId: widget.teamId,
      teamName: widget.teamName,
      filePath: _viewerPaths[index],
      readOnly: duplicated,
      readOnlyReason: duplicated
          ? '同一个文件已在另一个窗格打开：这里只读，避免两份缓冲互相覆盖'
          : '',
      onClose: () => unawaited(_closePane(index)),
    );
    if (_viewerPaths.length < 2) return viewer;
    return Stack(
      children: <Widget>[
        Listener(
          onPointerDown: (_) {
            if (_activePane != index) {
              setState(() {
                _activePane = index;
              });
            }
          },
          child: viewer,
        ),
        // 活动窗格的描边：一眼看出保存键与文件树点击会落到哪个窗格
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: active
                      ? cs.primary.withValues(alpha: 0.7)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
            ),
          ),
        ),
      ],
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
                      unawaited(_openViewer(path));
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
              // 查看器覆盖层：顶部一条分屏工具条 + 1–2 个窗格
              if (_viewerOpen)
                Positioned.fill(
                  child: Container(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: Column(
                      children: <Widget>[
                        _buildViewerToolbar(),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: Theme.of(context).dividerColor,
                        ),
                        Expanded(child: _buildPanes()),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
