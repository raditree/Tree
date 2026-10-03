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
import '../services/editor_buffer.dart';
import '../services/plugin_ui_registry.dart';
import '../services/workspace_paths.dart';
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
import 'tool_runs_panel.dart';

/// 同文件双开时的窗格提示：两侧**共享同一份缓冲**，不是两份各写各的。
const String _sharedBufferNotice = '同一文件已在另一窗格打开：两侧共享同一份缓冲，就地编辑即同步';

/// 文件管理面板（右栏）
///
/// 作为右栏的主容器，以 Tab 组织六个内置分区：
/// - 「文件」：文件浏览（[FileTree]）/ Git 历史（[GitHistory]）/ Todo（[TodoPanel]）
/// - 「MCP 配置」：MCP 服务列表与注册（[McpConfigPanel]）
/// - 「模型信息」：模型下拉、系统提示词与模型参数覆盖（[ModelInfoPanel]）
/// - 「问题回复」：统一汇总并答复所有提问（[QuestionPanel]）
/// - 「正在执行的 tool」：核心内存登记表里正在跑的工具，超阈值高亮 + 每行显式关闭
///   （[ToolRunsPanel]；关闭与执行站 `tool.close` 同实现）
/// - 「详情」：中栏点中的工具 / 思考行完整摊开（[DetailPanel]）
///
/// 「插件」原本是这里的第 5 个页签，已迁到**左侧活动栏**（见
/// main_page.dart 的 _buildActivityBar），与 Agent 列表并列。
///
/// Q12 插件布局：插件声明的 `panel` 槽位作为**插件 Tab 追加在既有 Tab 之后**
/// （见 [PluginUiRegistry.slotsOfKind]），内容由 [PluginPanelSlotView] 渲染；
/// 槽位变化（manifest / 注销 / 切 team）时按槽位键比对，仅在集合真变化时重建
/// TabController——避免每次 plugin_ui_update 都重置当前页签。
///
/// 点击文件时在**下格**打开 [FileViewer]：树与查看器**同屏**（上下分栏，比例默认 0.4，
/// 太矮时按 [SplitPanes] 的既有口径降级成一次只显示一个）；没打开文件时树独占整个区域。
/// 关闭查看器（工具条 / 窗格的返回按钮）回到树独占。见 lib/README.md 不变量 16。
///
/// **分屏是"一个文件一份文档、两个视图"**：同一个路径的窗格共用同一个
/// [EditorBuffer]（同一个控制器 + 一份 dirty / saving / loadedSize），两边都能编辑、
/// 一边打字另一边立刻可见，保存只有一套语义（见 [lib/README.md] 不变量 13）。
class FilePanel extends StatefulWidget {
  /// 顶层页签里「文件」的索引（新手引导第 6 步要切到它；与内部 Tab 顺序同源）。
  static const int filesTabIndex = 0;

  /// 顶层页签里「模型信息」的索引（新手引导第 3 步要切到它）。
  static const int modelInfoTabIndex = 2;

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

  /// 顶层页签的外部选中请求（索引：0=文件，2=模型信息，…；null = 不动）。
  ///
  /// 新手引导用它把用户直接带到「模型信息」/「文件」页；只在**值变化**时生效——
  /// 用户自己翻页后不该被下一次重建拽回去。
  final int? selectTab;

  /// [selectTab] 的**请求序号**：每次外部请求自增。
  ///
  /// 为什么不能只看索引有没有变：用户可能自己翻走再点一次引导的「带我过去」——
  /// 索引没变、但用户确实要回到那一页。按序号判"这是一次新请求"才没有死按钮。
  final int selectTabRevision;

  const FilePanel({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.teamName = '',
    this.sessionId = 'session_default',
    this.onCollapse,
    this.onNavigateToQuestion,
    this.registry,
    this.selectTab,
    this.selectTabRevision = 0,
  });

  @override
  State<FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<FilePanel> with TickerProviderStateMixin {
  /// 内置顶层 Tab 数量（文件 / MCP 配置 / 模型信息 / 问题回复 / 正在执行的 tool / 详情）
  static const int _builtinTabCount = 6;


  /// 「详情」页的固定索引（中栏点了工具行 / 思考行就切到它）
  static const int _detailTabIndex = _builtinTabCount - 1;

  /// 顶层 Tab 控制器（0=文件，1=MCP 配置，2=模型信息，3=问题回复，4=正在执行的 tool，
  /// 5=详情，之后是插件 panel 槽位；插件槽位集合变化时重建）
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
  /// 打开与保存。**同一个文件**双开时两侧共享同一份 [_viewerBuffers]——一个控制器 +
  /// 一份 dirty / saving / loadedSize，所以不是"两份缓冲互相覆盖"，而是同一份文档的
  /// 两个视图（旧口径"非活动窗格强制只读"已被推翻）。
  final List<String> _viewerPaths = <String>[];

  /// 与 [_viewerPaths] 一一对应的共享编辑缓冲：同一个路径就是**同一个实例**，
  /// 最后一个引用它的窗格关掉后才 dispose（控制器随之回收）。
  final List<EditorBuffer> _viewerBuffers = <EditorBuffer>[];

  /// 每个窗格的 State key：换文件 / 关窗格前要问它「未保存的内容怎么办」
  final List<GlobalKey<FileViewerState>> _viewerKeys =
      <GlobalKey<FileViewerState>>[];

  /// 当前活动窗格（文件树里点文件换它；点某个窗格也会切过来）
  int _activePane = 0;

  /// 分屏方向（horizontal = 左右）与分隔比例
  Axis _splitAxis = Axis.horizontal;
  double _splitRatio = 0.5;

  /// 窗格分隔条宽度（查看器内部两格 + 树/查看器上下分栏共用）
  static const double _paneDividerWidth = 7;

  /// 树与查看器**同屏分栏**时树占的比例（默认 0.3：目录当侧栏、查看器拿大头）。
  ///
  /// 左右分栏下这个比例会随面板宽度伸缩（400px ⇒ 树 200px；1000px ⇒ 树 300px），
  /// 拖过就记在面板状态里；夹取与最小宽度交给 [SplitPanes]。
  double _treeSplitRatio = 0.3;

  /// 同屏分栏每一侧的最小**宽度**（目录这边至少要放得下头部那排动作键与 Tab）
  static const double _treeSplitMinExtent = 200;

  /// 可用**宽度**低于它就降级成"只显示查看器"：再窄下去两侧都不够用（用户 2026-10-04：
  /// 与其把查看器压成一条，不如让它占满，目录用工具条上的按钮随时叫回来）
  static const double _treeSplitDegradeBelow = 400;

  /// 用户是否要显示目录（工具条按钮切换）。**意愿与"这一刻能不能显示"分开**：
  /// 面板太窄时 [SplitPanes] 会降级成只看查看器，但这里不清掉用户的意愿——
  /// 拖宽之后目录自己回来，不用再点一次。
  bool _treeWanted = true;

  /// 最近一次布局给树/查看器区域的可用宽度（只用来把"面板太窄"如实说给用户听）
  double _lastTreeAreaWidth = 0;

  /// 文件子 Tab 区（文件浏览 / Git 历史 / Todo）的 key。
  ///
  /// 为什么需要它：打开 / 关闭查看器会把这块从「Expanded 的独子」**搬到** SplitPanes
  /// 的上格（或反过来）。没有 GlobalKey 的话元素树会重建——展开的目录、已加载的层、
  /// 选中项全丢（用户每开一个文件树就塌一次）；GlobalKey 让它被"搬"过去而不是重建。
  final GlobalKey _fileTabsKey = GlobalKey(debugLabel: 'file_panel_tabs');

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

  /// 「正在执行的 tool」页刷新触发器（工具开始 / 结束时登记表变了）
  int _toolRunsRefreshTrigger = 0;

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
    // 面板没了，手里那些共享缓冲（及其控制器）一起收掉；
    // 同文件双开时两格是同一个实例，去重后再 dispose。
    for (final EditorBuffer buffer in <EditorBuffer>{..._viewerBuffers}) {
      buffer.dispose();
    }
    _viewerBuffers.clear();
    _tabController.dispose();
    _fileTabController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部页签请求（新手引导）：按**请求序号**判"这是一次新请求"（见 selectTabRevision）
    final int? requested = widget.selectTab;
    if (requested != null &&
        widget.selectTabRevision != oldWidget.selectTabRevision) {
      final int index = requested.clamp(0, _tabController.length - 1);
      if (_tabController.index != index) _tabController.animateTo(index);
    }
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

  /// 工作空间数据变更（工具写文件 / git 提交 / 更新 todo / 工具开始结束）时增量刷新右栏。
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
      if (areas.contains(WorkspaceArea.toolRuns)) {
        _toolRunsRefreshTrigger++;
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

  /// 文件树里重命名成功：查看器里指向该路径（或其后代）的窗格**跟着改名**。
  ///
  /// 只换路径字符串：缓冲实例不动（同一份文档换了个名字，不是两份文档），
  /// [FileViewer] 的 didUpdateWidget 会按新路径重新加载。
  void _onTreePathRenamed(String from, String to) {
    bool changed = false;
    for (int i = 0; i < _viewerPaths.length; i++) {
      final String next = workspacePathRemap(_viewerPaths[i], from, to);
      if (next == _viewerPaths[i]) continue;
      _viewerPaths[i] = next;
      changed = true;
    }
    if (!changed || !mounted) return;
    setState(() {});
  }

  /// 文件树里删除了路径：指向它的窗格一起关掉。
  ///
  /// 不再问"未保存的改动怎么办"——删除前已经确认过一次（那时文件还在，用户选了删），
  /// 删完再弹一次确认只会自相矛盾。缓冲按"还有没有别的窗格引用"释放。
  void _onTreePathDeleted(String path) {
    final List<int> closing = <int>[];
    for (int i = 0; i < _viewerPaths.length; i++) {
      if (workspacePathAtOrUnder(_viewerPaths[i], path)) closing.add(i);
    }
    if (closing.isEmpty) return;
    final Set<EditorBuffer> released = <EditorBuffer>{};
    setState(() {
      for (final int index in closing.reversed) {
        released.add(_viewerBuffers[index]);
        _viewerPaths.removeAt(index);
        _viewerKeys.removeAt(index);
        _viewerBuffers.removeAt(index);
      }
      _activePane = _viewerPaths.isEmpty
          ? 0
          : _activePane.clamp(0, _viewerPaths.length - 1);
    });
    for (final EditorBuffer buffer in released) {
      _releaseBuffer(buffer);
    }
    _showSnackBar('文件已删除，查看器已关闭：$path');
  }

  /// 打开文件：没有窗格就新建，有就换**活动窗格**的内容（先处理未保存的改动）。
  ///
  /// 换到的路径若已在另一个窗格里开着，就取那个窗格的**同一个缓冲**：同一份文档两个
  /// 视图，不是两份缓冲（见 [EditorBuffer]）。
  Future<void> _openViewer(String path) async {
    if (_viewerPaths.isEmpty) {
      setState(() {
        _viewerPaths.add(path);
        _viewerBuffers.add(EditorBuffer());
        _viewerKeys.add(GlobalKey<FileViewerState>());
        _activePane = 0;
      });
      return;
    }
    final int index = _activePane.clamp(0, _viewerPaths.length - 1);
    if (_viewerPaths[index] == path) return;
    if (!await _confirmLeave(index)) return;
    if (!mounted) return;
    final EditorBuffer open = _bufferFor(path);
    final EditorBuffer previous = _viewerBuffers[index];
    setState(() {
      _viewerPaths[index] = path;
      _viewerBuffers[index] = open;
    });
    _releaseBuffer(previous);
  }

  /// 某个路径的共享缓冲：已有窗格开着它就复用那一个（**同一个实例**），否则新建一份。
  EditorBuffer _bufferFor(String path) {
    for (int i = 0; i < _viewerPaths.length; i++) {
      if (_viewerPaths[i] == path) return _viewerBuffers[i];
    }
    return EditorBuffer();
  }

  /// 没有窗格再引用这份缓冲了就释放它（控制器随 dispose 一起收掉）。
  ///
  /// 下一帧再释放：本帧刚被换掉的 TextField 还在拿它换 controller。
  /// **同文件双开时先关掉的那个窗格不能把另一个窗格正在用的控制器 dispose 掉**，
  /// 所以这里按实例判断"还有没有引用"。
  void _releaseBuffer(EditorBuffer buffer) {
    for (final EditorBuffer other in _viewerBuffers) {
      if (identical(other, buffer)) return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => buffer.dispose());
  }

  /// 分屏：把当前文件再开一个窗格（两侧共享**同一份**缓冲，见 [EditorBuffer]）
  void _splitViewer() {
    if (_viewerPaths.length >= 2 || _viewerPaths.isEmpty) return;
    setState(() {
      _viewerPaths.add(_viewerPaths[_activePane]);
      // 同一个实例：两个窗格共用一份控制器与 dirty / saving / loadedSize
      _viewerBuffers.add(_viewerBuffers[_activePane]);
      _viewerKeys.add(GlobalKey<FileViewerState>());
      _activePane = 1;
    });
  }

  /// 关闭一个窗格（未保存的内容按设置自动保存或问一次）
  ///
  /// 缓冲等**没有窗格再引用**它时才释放：同文件双开时先关掉的那个不能把另一个正在用
  /// 的控制器收掉。
  Future<void> _closePane(int index) async {
    if (index < 0 || index >= _viewerPaths.length) return;
    if (!await _confirmLeave(index)) return;
    if (!mounted) return;
    final EditorBuffer closed = _viewerBuffers[index];
    setState(() {
      _viewerPaths.removeAt(index);
      _viewerKeys.removeAt(index);
      _viewerBuffers.removeAt(index);
      // 关掉**最后一个**窗格时列表已空：clamp(0, -1) 会抛 ArgumentError，
      // 这里退回 0（查看器随之关闭，缓冲照下面那条规则释放）
      _activePane =
          _viewerPaths.isEmpty ? 0 : _activePane.clamp(0, _viewerPaths.length - 1);
    });
    _releaseBuffer(closed);
  }

  /// 关闭整个查看器：每份**文档**都要先处理未保存的改动，任何一个取消就整体不关。
  ///
  /// 同一份缓冲的两个窗格只问一次——它们是同一份文档，一个决定就够
  /// （全关之后缓冲与控制器才释放）。
  Future<void> _closeViewer() async {
    final Set<EditorBuffer> asked = <EditorBuffer>{};
    for (int i = 0; i < _viewerPaths.length; i++) {
      if (!asked.add(_viewerBuffers[i])) continue;
      if (!await _confirmLeave(i)) return;
      if (!mounted) return;
    }
    final Set<EditorBuffer> closing = <EditorBuffer>{..._viewerBuffers};
    setState(() {
      _viewerPaths.clear();
      _viewerKeys.clear();
      _viewerBuffers.clear();
      _activePane = 0;
    });
    for (final EditorBuffer buffer in closing) {
      _releaseBuffer(buffer);
    }
  }

  /// 离开某个窗格前把未保存内容处理掉（true = 可以离开）
  Future<bool> _confirmLeave(int index) async {
    if (index < 0 || index >= _viewerKeys.length) return true;
    final FileViewerState? state = _viewerKeys[index].currentState;
    if (state == null) return true;
    return state.confirmLeave();
  }

  /// 这个窗格里的文件是否也在别的窗格里开着（是 ⇒ 提示两侧共享同一份缓冲）
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
                  // 正在执行的 tool：核心内存登记表的快照 + 每行一个显式「关闭」
                  // （与执行站 tool.close 同实现）。见 ToolRunsPanel。
                  ToolRunsPanel(refreshTrigger: _toolRunsRefreshTrigger),
                  // 详情页：中栏点中的工具调用 / 思考完整摊开（见 DetailPanel）
                  // 带上工作空间：edit 的「变更」要读一次当前文件才有上下文
                  DetailPanel(
                    workspaceId: widget.workspaceId,
                    teamId: widget.teamId ?? '',
                  ),
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
                const Tab(text: '正在执行的 tool'),
                const Tab(text: '详情'),
                // Q12 插件 Tab：追加在既有六个 Tab 之后，文案用槽位 title
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

  /// 查看器工具条：收起/显示目录 / 分屏 / 切方向 / 关窗格 / 关查看器。
  ///
  /// 为什么控件放顶栏而不是塞进每个窗格的标题栏：窗格可能被拖得很窄，标题栏还要
  /// 放文件名、语言标签、保存键；而分屏是「整个查看器」的动作，独立一条更稳。
  ///
  /// 「目录」这颗键（用户 2026-10-04）：目录在左时一键收起、收起后一键叫回来；
  /// 面板窄到放不下并排两栏时，这里**如实写出原因**（而不是让用户对着一个看起来
  /// 没反应的按钮猜）。
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
          // 目录在左但**这一刻显示不出来**（面板太窄被 SplitPanes 降级）：如实说原因，
          // 否则用户会觉得这颗按钮点了没反应。
          if (_treeWanted && _treeAreaTooNarrow) ...<Widget>[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '面板太窄 · 目录已收起（拖宽右栏恢复）',
                key: const ValueKey<String>('tree-too-narrow-hint'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
          ],
          const Spacer(),
          _toolbarAction(
            // 目录在左：收起 = 箭头朝左、显示 = 箭头朝右（`left_panel_*` 这套图标
            // 在当前的 Flutter 版本里不存在，别用）
            icon: _treeWanted
                ? Icons.keyboard_double_arrow_left
                : Icons.keyboard_double_arrow_right,
            tooltip: _treeWanted ? '收起文件树（查看器占满）' : '显示文件树（目录在左）',
            color: cs.onSurfaceVariant,
            onPressed: () {
              setState(() {
                _treeWanted = !_treeWanted;
              });
            },
          ),
          if (twoPanes)
            _toolbarAction(
              icon: _splitAxis == Axis.horizontal
                  ? Icons.splitscreen_outlined
                  : Icons.view_agenda_outlined,
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
            _toolbarAction(
              icon: Icons.vertical_split_outlined,
              tooltip: '分屏：同一个文件再开一个窗格（两侧共享同一份缓冲）',
              color: cs.onSurfaceVariant,
              onPressed: _splitViewer,
            ),
          if (twoPanes)
            _toolbarAction(
              icon: Icons.close_fullscreen,
              tooltip: '关闭当前窗格',
              color: cs.onSurfaceVariant,
              onPressed: () => unawaited(_closePane(_activePane)),
            ),
          _toolbarAction(
            icon: Icons.close,
            tooltip: '关闭查看器',
            color: cs.onSurfaceVariant,
            onPressed: () => unawaited(_closeViewer()),
          ),
        ],
      ),
    );
  }

  /// 面板太窄、目录**这一刻**显示不出来（[SplitPanes] 会把并排两栏降级成只显示查看器）。
  ///
  /// 判据与 [SplitPanes] 逐字对齐：可用宽度 = 面板宽度 − 分隔条宽度。
  bool get _treeAreaTooNarrow =>
      _lastTreeAreaWidth > 0 &&
      (_lastTreeAreaWidth - _paneDividerWidth) < _treeSplitDegradeBelow;

  /// 工具条上的紧凑图标键：默认 IconButton 是 48×48，五颗键在 240px 的面板里会溢出
  /// （黄条警告）；这里与文件树头部同一种口径（26×26、内边距 4）。
  Widget _toolbarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) => IconButton(
    icon: Icon(icon, size: 16),
    tooltip: tooltip,
    color: color,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.all(4),
    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
    onPressed: onPressed,
  );

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

  /// 单个窗格：点它成为活动窗格；同文件双开时两侧共享同一份缓冲（只提示，不锁只读）
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
      // 同一个文件的另一个窗格共用这一份缓冲：就地编辑即同步（见 EditorBuffer）
      buffer: _viewerBuffers[index],
      paneNotice: duplicated ? _sharedBufferNotice : '',
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

  /// 文件分区：子 Tab 栏（文件浏览 / Git 历史 / Todo）+ 内容
  ///
  /// 内容区两种形态：没打开文件 = 子 Tab 独占；打开文件 = 上下分栏（上格子 Tab、下格查看器）。
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
        // 内容区域：**目录在左、查看器在右**（用户 2026-10-04 二改）。
        //
        // 为什么不再用覆盖层：覆盖层让"打开文件后树就点不到"——新建 / 重命名 / 删除
        // 这些树里的动作在开着文件时根本用不上（用户 2026-10-03 定夺改同屏）。
        // 为什么从上下改成左右（口径变化，2026-10-04）：上下分栏把查看器**压扁**
        // （代码是按行看的，高度比宽度更吃紧），而面板宽度是用户能拖的；目录当左侧栏
        // 更接近 VS Code，也允许一键收起把整格让给查看器。
        // 面板太窄（< [_treeSplitDegradeBelow]）时按 [SplitPanes] 的既有口径降级成
        // **只显示查看器**——此时工具条上写着原因，拖宽右栏目录自己回来。
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              _lastTreeAreaWidth = constraints.maxWidth;
              if (!_viewerOpen) return _buildFileTabs();
              if (!_treeWanted) return _buildViewerPane();
              return SplitPanes(
                axis: Axis.horizontal,
                ratio: _treeSplitRatio,
                minExtent: _treeSplitMinExtent,
                degradeBelow: _treeSplitDegradeBelow,
                dividerWidth: _paneDividerWidth,
                onRatioChanged: (double next) {
                  setState(() {
                    _treeSplitRatio = next;
                  });
                },
                first: _buildFileTabs(),
                second: _buildViewerPane(),
                // 太窄时只留查看器：工具条上的「显示文件树」把目录叫回来
                // （用户的意愿不被清掉，拖宽右栏目录自己回来）
                degraded: _buildViewerPane(),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 文件子 Tab 区（文件浏览 / Git 历史 / Todo）。
  ///
  /// 外面套 [KeyedSubtree] + [_fileTabsKey]：开 / 关查看器时这块会被搬进 / 搬出分栏，
  /// 有 key 才不会被重建（展开状态、选中项、已加载的目录都留着）。
  Widget _buildFileTabs() {
    return KeyedSubtree(
      key: _fileTabsKey,
      child: TabBarView(
        controller: _fileTabController,
        children: <Widget>[
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
            // 改名 / 删除之后查看器要跟着走（见 _onTreePathRenamed / _onTreePathDeleted）
            onPathRenamed: _onTreePathRenamed,
            onPathDeleted: _onTreePathDeleted,
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
    );
  }

  /// 查看器那一格：分屏工具条 + 1–2 个窗格（同屏分栏时它是**下格**）
  Widget _buildViewerPane() {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: <Widget>[
          _buildViewerToolbar(),
          Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
          Expanded(child: _buildPanes()),
        ],
      ),
    );
  }
}
