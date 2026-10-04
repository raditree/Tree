import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../models/agent.dart';
import '../../io/api_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../../io/ssh_executor_service.dart';
import '../services/detail_selection.dart';
import '../services/onboarding_requests.dart';
import '../services/onboarding_state.dart';
import '../services/onboarding_steps.dart';
import '../services/plugin_ui_registry.dart';
import '../services/terminal_toggle_request.dart';
import '../widgets/activity_bar_item.dart';
import '../widgets/agent_list.dart';
import '../widgets/create_agent_dialog.dart';
import '../widgets/download_panel.dart';
import '../widgets/file_panel.dart';
import '../widgets/message_panel.dart';
import '../widgets/onboarding_guide.dart';
import '../widgets/plugin_panel.dart';
import '../widgets/plugin_ui_slots.dart';
import '../widgets/teammates_window_page.dart';
import 'settings_page.dart';

/// 主页面 - 三栏布局
///
/// 左栏：Agent 列表（初始 260px，最小 200px，**上限随窗口宽度变化**）
/// 中栏：消息交互（弹性宽度，占据剩余空间，最小 360px）
/// 右栏：文件管理（初始 340px，最小 240px，**上限随窗口宽度变化**）
///
/// 支持通过拖拽分隔条调整左栏和右栏宽度；**中栏也能折叠**（收成窄条，让出的
/// 宽度归展开着的侧栏，右栏优先）——右栏读文件时因此能用满整窗；
/// 窗口尺寸过小时显示提示页面。
class MainPage extends StatefulWidget {
  /// 插件槽位注册表（默认全局单例；测试注入独立实例，避免污染单例）
  final PluginUiRegistry? registry;

  const MainPage({super.key, this.registry});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  // 左栏当前宽度，初始 260px
  double _leftWidth = 260;
  // 右栏当前宽度，初始 340px
  double _rightWidth = 340;

  // 折叠状态
  bool _leftCollapsed = false;
  bool _rightCollapsed = false;
  /// 中栏（消息交互）是否折叠成窄条
  ///
  /// 用户 2026-10-04：「中间页支持折叠（右侧面板文件浏览时还是不够用）」——
  /// 折叠中栏让出的宽度交给**展开着的侧栏**（右栏优先，见 [_rightAbsorbs]），
  /// 这时右栏一路顶到窗口最右边，读文件能用满整窗；再点窄条上的箭头就回来。
  bool _centerCollapsed = false;

  // 折叠时宽度
  static const double _collapsedWidth = 40;

  /// 左侧活动栏宽度（VS Code 风格图标条，常驻不参与折叠动画）
  ///
  /// 必须**独立于** [_leftCollapsed] 的宽度动画：若把活动栏放进
  /// `AnimatedContainer` 内部，折叠左栏时它会被压到 [_collapsedWidth]，
  /// 图标显示不全。
  static const double _activityBarWidth = 48;

  /// 两个拖拽分隔条的宽度（展开时每个 6px，收起时为 0）
  static const double _dividerWidth = 6;

  /// 左侧活动栏当前选中的功能面板：0=Agent 列表，1=插件面板
  int _leftPanel = 0;

  // 侧栏折叠/展开的动画时长与曲线（宽度平滑过渡 + 内容淡入淡出）
  static const Duration _sidebarAnimDuration = Duration(milliseconds: 60);
  static const Curve _sidebarAnimCurve = Curves.linear;

  /// 移动端底部导航当前页（0=Agent 列表，1=消息，2=文件）
  int _mobileTab = 0;

  /// 内置左栏面板数量（Agent 列表 / 插件管理 / 下载）：插件活动栏槽位从它之后编号
  static const int _builtinLeftPanelCount = 3;

  /// 当前选中的**插件活动栏槽位键**（null = 选中的是内置面板）
  String? _selectedPluginActivityKey;

  /// 上一次算出的活动栏插件槽位键序列（只在集合真变化时重建左栏）
  List<String> _pluginActivityKeys = <String>[];

  /// 插件槽位注册表（默认全局单例）
  PluginUiRegistry get _registry => widget.registry ?? PluginUiRegistry.instance;

  // 当前选中的 Agent（未选择时为 null）
  Agent? _selectedAgent;

  // 当前会话 ID（中栏切换会话时更新；Todo 面板按会话隔离查询 todos）
  String _currentSessionId = 'session_default';

  // 消息面板刷新触发器（递增触发 MessagePanel 重新加载历史）
  int _refreshTrigger = 0;

  // 提问定位目标消息 id（右侧「问题回复」导航触发）
  String? _navigateMessageId;

  // 提问定位触发号（递增触发 MessagePanel 定位滚动）
  int _navigateTrigger = 0;

  // 当前选中 Agent 的列表（默认空，通过"创建 Agent"新增）
  List<Agent> _agents = <Agent>[];

  // 左右栏宽度限制：两侧都**只有下限是固定值**，上限不写死——统一取
  // "当前可用宽度 - 中栏最小宽度"（见 [_sideBudgetFor]），这样阅读文件
  // （长行 / 宽表格 / 宽 PDF）或编辑长提示词时，任一侧都能拖到接近整窗宽。
  static const double _leftMinWidth = 200;
  static const double _rightMinWidth = 240;

  /// 侧栏宽度下限的**通用**值：上限判定用它，保证"上限 ≥ 下限"不会翻转。
  static const double _minSideWidth =
      _leftMinWidth < _rightMinWidth ? _leftMinWidth : _rightMinWidth;

  /// 中栏（消息交互）最小宽度：左右栏变宽时给中栏留出的底线，防止中栏被压没。
  static const double _centerMinWidth = 360;

  /// 中栏当前要预留的宽度：折叠时它只剩一根 [_collapsedWidth] 窄条，
  /// 展开时才要 [_centerMinWidth]。侧栏预算与拖拽上限都以它为基准，
  /// 所以折叠中栏之后侧栏能一路拖到接近整窗宽。
  double get _centerReserveWidth =>
      _centerCollapsed ? _collapsedWidth : _centerMinWidth;

  /// 中栏折叠时**右栏承接**它让出的宽度。
  ///
  /// 右栏优先是有理由的：折叠中栏的动机就是"右栏读文件要地方"。
  bool get _rightAbsorbs => _centerCollapsed && !_rightCollapsed;

  /// 右栏也收着时，由左栏承接。
  bool get _leftAbsorbs => _centerCollapsed && _rightCollapsed && !_leftCollapsed;

  /// 固定占用的横向宽度：活动栏 + 当前**可见**的分隔条。
  ///
  /// 收起的分隔条不占宽度（原有行为）；正在**承接**中栏空间的侧栏，它的分隔条
  /// 也不占宽度——那一侧的宽度此刻由窗口决定，不再是用户可拖的量（拖它不会有
  /// 任何位移，留着只会让人以为控件坏了）。
  double get _chromeWidth =>
      _activityBarWidth +
      ((_leftCollapsed || _leftAbsorbs) ? 0 : _dividerWidth) +
      ((_rightCollapsed || _rightAbsorbs) ? 0 : _dividerWidth);

  /// 当前 build 时整页可用宽度（由 [_buildThreeColumnLayout] 的 LayoutBuilder 写入）。
  /// 拖拽侧栏分隔条时用它算上限；为 null 表示尚未完成首帧布局。
  double? _layoutAvailableWidth;

  /// 本帧是否已安排"帧后收敛侧栏宽度"的回调（防止重复安排）
  bool _sideNormalizeScheduled = false;

  /// 是否正在拖拽侧栏分隔条（拖拽期间帧后收敛让位给拖拽本身）
  bool _sideDragging = false;

  // 窗口最小尺寸
  static const double _minWindowWidth = 1024;
  static const double _minWindowHeight = 600;

  /// 当前 team 可见的活动栏插件槽位键（顺序即活动栏顺序）。
  List<String> _activitySlotKeys() => <String>[
    for (final PluginUiSlot slot
        in _registry.slotsOfKind(PluginUiSlotKind.activity))
      slot.slotKey,
  ];

  /// 活动栏插件项集合变化：仅当**槽位键序列**变化时才重建左栏。
  ///
  /// 插件视图更新（plugin_ui_update）不改变键序列，因此不会让整页重建——
  /// 槽位视图本身由 [PluginActivityBarItems] / [PluginPanelSlotView] 各自监听。
  void _onPluginSlotsChanged() {
    if (!mounted) return;
    final List<String> keys = _activitySlotKeys();
    bool same = keys.length == _pluginActivityKeys.length;
    if (same) {
      for (int i = 0; i < keys.length; i++) {
        if (keys[i] != _pluginActivityKeys[i]) {
          same = false;
          break;
        }
      }
    }
    final bool stale = _selectedPluginActivityKey != null &&
        !keys.contains(_selectedPluginActivityKey);
    if (same && !stale) {
      return;
    }
    setState(() {
      _pluginActivityKeys = keys;
      if (stale) {
        // 选中的插件槽位被注销（插件卸载/断连/切 team）→ 回落到内置面板
        _selectedPluginActivityKey = null;
      }
    });
  }

  /// 切换插件槽位的 team 作用域（Q12 + M9 1.2 隔离口径）。
  ///
  /// 注册表只呈现"当前 team"的槽位；未选 agent 时当前 team 为空串，此时只呈现
  /// team_id 也为空的全局槽位（fail-closed，不把别的 team 的槽位漏出来）。
  void _setTeamScope(String? teamId) {
    _registry.setTeam(teamId ?? '');
  }

  /// 处理清空 agent 对话历史
  ///
  /// 调用后端 DELETE 接口清空指定 agent 的历史，并触发中栏重新加载（清空显示）。
  /// 当前选中的 agent 才需要触发中栏刷新；其他 agent 只清后端数据即可。
  Future<void> _handleClearHistory(Agent agent) async {
    try {
      await ApiService.clearConversationHistory(agent.id);
      // 若清空的是当前选中的 agent，则触发中栏刷新
      if (agent.id == _selectedAgent?.id) {
        setState(() {
          _refreshTrigger++;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清空失败: $e')));
      }
    }
  }

  /// 处理右侧「问题回复」页的定位导航。
  ///
  /// - 主 agent 提问：切换中栏到该提问所属 agent/会话，并滚动定位到该提问卡片。
  /// - 成员提问：打开该成员的工作进度详情窗口并滚动定位（不动中栏/左栏上下文）。
  Future<void> _handleNavigateToQuestion({
    required bool isMember,
    required String agentId,
    required String teamId,
    required String sessionId,
    required String messageId,
  }) async {
    if (isMember) {
      // 成员提问：打开成员进度详情窗口并滚动定位
      Agent? leader;
      for (final Agent a in _agents) {
        if (a.id == teamId) {
          leader = a;
          break;
        }
      }
      if (leader == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该提问所属 Agent 不存在或已删除')));
        }
        return;
      }
      String memberName = '';
      try {
        final List<Map<String, dynamic>> members =
            await ApiService.getTeammates(leader.id);
        for (final Map<String, dynamic> m in members) {
          if ((m['id'] as String?) == agentId) {
            memberName = (m['name'] as String?) ?? '';
            break;
          }
        }
      } catch (_) {
        // 拉取成员名失败时回退用成员 id 显示
      }
      if (!mounted) return;
      final Agent leaderAgent = leader;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TeammateDetailPage(
            leader: leaderAgent,
            memberId: agentId,
            memberName: memberName.isNotEmpty ? memberName : agentId,
            sessionId: sessionId,
            scrollToMessageId: messageId,
          ),
        ),
      );
      return;
    }
    // 主 agent 提问：切换中栏上下文并滚动定位
    Agent? target;
    for (final Agent a in _agents) {
      if (a.id == agentId) {
        target = a;
        break;
      }
    }
    if (target == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('该提问所属 Agent 不存在或已删除')));
      }
      return;
    }
    final Agent targetAgent = target;
    setState(() {
      _selectedAgent = targetAgent;
      _currentSessionId = sessionId;
      _navigateMessageId = messageId;
      _navigateTrigger++;
      // 切 team 即切插件槽位作用域（Q12）：用团队 id（成员回指团队）
      _setTeamScope(targetAgent.teamScopeId);
    });
  }

  /// 处理右侧「正在执行的 tool」页的**定位导航**：点某一行 ⇒ 切中栏到该运行所属的
  /// **agent / 会话**（与「问题回复」页同一范式；只切上下文，**不**滚动定位到某条消息）。
  ///
  /// agent 已不存在（被删 / 是名册未知的临时员工 id）⇒ 给可读提示并**不动**当前上下文。
  Future<void> _handleNavigateToToolRun({
    required String agentId,
    required String sessionId,
  }) async {
    Agent? target;
    for (final Agent a in _agents) {
      if (a.id == agentId) {
        target = a;
        break;
      }
    }
    if (target == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该运行所属 Agent 不存在或已删除')),
        );
      }
      return;
    }
    final Agent targetAgent = target;
    setState(() {
      _selectedAgent = targetAgent;
      _currentSessionId = sessionId;
      // 只切上下文：清掉上一次的消息定位目标，并递增触发号让中栏按新会话重载
      _navigateMessageId = null;
      _navigateTrigger++;
      _setTeamScope(targetAgent.teamScopeId);
    });
  }

  /// 弹出创建 Agent 配置对话框，并在确认后加入列表
  ///
  /// 创建成功的 Agent 会自动持久化到后端，并自动选中，方便立即开始对话。
  Future<void> _handleCreateAgent() async {
    final Map<String, dynamic>? result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) => const CreateAgentDialog(),
    );
    if (result == null || !mounted) return;

    try {
      final Agent agent = await ApiService.createAgent(
        name: result['name'] as String,
        modelId: result['model_id'] as String,
        systemPrompt: result['system_prompt'] as String? ?? '',
        teamMemberCount: result['team_member_count'] as int?,
        maxLevel: result['max_level'] as int?,
        maxMembersPerLevel: result['max_members_per_level'] as int?,
      );
      if (!mounted) return;
      setState(() {
        _agents.add(agent);
        _selectedAgent = agent;
        _currentSessionId = 'session_default';
        _setTeamScope(agent.teamScopeId);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建失败: $e')));
      }
    }
  }

  /// 删除指定 agent（连同其对话历史），并同步后端
  ///
  /// 核心有**两道闸门**（见 `CoreServer._deleteAgent`），这里把它们变成可操作交互：
  /// - **有下级成员** ⇒ 核心回 409 + 下级清单，这里摊开清单请用户确认，再带
  ///   `cascade: true` 重试（"删掉组长会让组员变孤儿"不再是一次点击就发生的事）；
  /// - **正在运行** ⇒ 提示"先停止并等它空闲"（`stop` 抢不动正在执行的工具，
  ///   核心不替用户等待）。
  ///
  /// 删除成功后的收尾：按 teamId 注销该 agent 的执行器（注销后端注册、关闭 SSH
  /// 连接、清理 per-team 内存状态），无论其是否为当前选中 agent——避免删除/重建后
  /// 旧注册残留导致新 agent 走错执行通道。
  Future<void> _handleDeleteAgent(Agent agent) async {
    try {
      await ApiService.deleteAgent(agent.id);
      if (!mounted) return;
      _afterAgentDeleted(agent);
    } on AgentDeleteBlocked catch (blocked) {
      if (!mounted) return;
      if (!blocked.needsCascade) {
        _toast('删除失败: $blocked');
        return;
      }
      final List<String> names = <String>[
        for (final Map<String, dynamic> member in blocked.cascadeRequired)
          '${member['name']}（L${member['level']}）',
      ];
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('连同下级成员一并删除？'),
          content: Text(
            '「${agent.name}」还有 ${names.length} 个下级成员：\n'
            '${names.join('、')}\n\n'
            '删除会连同它们一起移除（对话历史一并删除），此操作不可恢复。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                '一并删除',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await ApiService.deleteAgent(agent.id, cascade: true);
        if (!mounted) return;
        _afterAgentDeleted(agent);
      } catch (e) {
        if (mounted) _toast('删除失败: $e');
      }
    } catch (e) {
      if (mounted) _toast('删除失败: $e');
    }
  }

  /// 删除成功后的本地收尾（列表、执行器注册、选中态与插件作用域）。
  void _afterAgentDeleted(Agent agent) {
    setState(() {
      _agents.removeWhere((a) => a.id == agent.id);
      // 注销该 team 的本地执行器（后端清注册，前端移除状态）
      LocalExecutorService.instance.deactivateTeam(agent.id);
      // 注销该 team 的 SSH 执行器（后端清注册并删除该 agent 的 SSH 配置，
      // 前端关闭连接并移除状态）
      unawaited(SshExecutorService.instance.deactivateTeam(agent.id));
      if (_selectedAgent?.id == agent.id) {
        _selectedAgent = null;
        // 只有**团队 TOP 被删**时团队才真消失，插件槽位作用域才该回落为空；
        // 删的若是成员（teamId 非空），团队还在——清作用域会把该队的站点/槽位
        // 全滤掉，表现为"站点（0）"，重新选中 leader 才恢复。
        if (agent.teamId.isEmpty) _setTeamScope(null);
      }
    });
  }

  /// 统一的轻量提示（SnackBar）。
  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ── 新手引导（首次使用；每一步都能跳过） ─────────────────────────────

  /// 引导浮层是否可见。
  bool _guideVisible = false;

  /// 当前第几步（0 基，见 [kOnboardingSteps]）。
  int _guideIndex = 0;

  /// 右栏顶层页签的外部选中请求（引导第 3/6 步用）：索引 + 请求序号。
  int? _filePanelTab;
  int _filePanelTabRevision = 0;

  /// 活动栏里「插件管理」的位置（引导第 5 步）。
  static const int _pluginPanelIndex = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Q12：活动栏插件项集合变化时重建左栏（视图更新不触发整页重建）
    _pluginActivityKeys = _activitySlotKeys();
    _registry.addListener(_onPluginSlotsChanged);
    // 中栏点了工具行 / 思考行 → 详情在右栏；右栏收着的话先展开，
    // 否则用户点了半天什么也没发生
    DetailSelection.instance.addListener(_onDetailSelected);
    _loadAgents();
    unawaited(_maybeShowGuide());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DetailSelection.instance.removeListener(_onDetailSelected);
    _registry.removeListener(_onPluginSlotsChanged);
    // 清理本地执行器：注销核心进程注册并释放 WebSocket 引用
    LocalExecutorService.instance.cleanup();
    // 清理 SSH 执行器：仅释放引用（不注销，SSH 配置后端持久化）
    SshExecutorService.instance.cleanup();
    super.dispose();
  }

  /// 中栏选中了详情：右栏收着就展开（选中项被清空时什么都不做）
  void _onDetailSelected() {
    if (DetailSelection.instance.message == null) return;
    if (!_rightCollapsed) return;
    setState(() {
      _rightCollapsed = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // 应用退出时清理本地执行器（注销后端注册并释放 WebSocket 引用）
      LocalExecutorService.instance.cleanup();
      // 清理 SSH 执行器（仅释放引用，不注销后端持久化配置）
      SshExecutorService.instance.cleanup();
    }
  }

  /// 从后端加载已持久化的 agent 列表
  Future<void> _loadAgents() async {
    try {
      final List<Agent> agents = await ApiService.getAgents();
      if (!mounted) return;
      setState(() {
        _agents = agents;
      });
    } catch (e) {
      // 加载失败保留空列表，用户仍可尝试创建
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载 Agent 列表失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ctrl+J 的**全局驿站**（2026-10-03 用户要求：焦点不在输入框时也要能唤起终端）。
    //
    // 为什么必须挂在三栏的**共同祖先**上：按键沿当前焦点向父级冒泡，而以前 Ctrl+J 只
    // 挂在消息面板里（焦点本地）——焦点被文件面板 / 右栏 / 消息列表里的可选文本拿走之后，
    // 按键再也冒不到那个节点，快捷键就失效了。canRequestFocus: false ⇒ 它只当事件驿站，
    // 绝不抢焦点；真正切换终端的逻辑仍归消息面板（只有它知道终端开给哪个 agent）。
    //
    // 刻意不用 MaterialApp.shortcuts / 全局 HardwareKeyboard handler：那会把**对话框与
    // 独立窗口**也算进来（在设置对话框里按 Ctrl+J 去开背后的终端没有意义）；挂在主页这
    // 一层天然把路由排除在外——它们不在这棵焦点树里。
    return CallbackShortcuts(
      key: const ValueKey<String>('main-global-shortcuts'),
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true):
            TerminalToggleRequest.instance.request,
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        child: Scaffold(
      body: Column(
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 移动端（Android/iOS）：任意屏幕尺寸使用单栏底部导航布局。
                // 桌面三栏 + 最小 1024×600 限制在手机上会导致整页不可用
                // （手机竖屏宽度通常仅 360~430dp）。
                if (isMobile) return _buildMobileLayout();
                // 检查窗口尺寸是否满足最小要求
                if (constraints.maxWidth < _minWindowWidth ||
                    constraints.maxHeight < _minWindowHeight) {
                  return _buildSmallSizePrompt();
                }
                // 新手引导浮层：非模态地盖在中栏上方（下面的界面照样能点——
                // 每一步的「带我过去」都要打开真实界面）。
                return Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: _buildThreeColumnLayout(constraints.maxWidth),
                    ),
                    if (_guideVisible)
                      Positioned(
                        top: 16,
                        left: 0,
                        right: 0,
                        child: Center(child: _buildGuide()),
                      ),
                  ],
                );
              },
            ),
          ),
          // Q12 状态栏：主界面底部细条，只展示插件 status 槽位；
          // 没有任何状态项时整条不出现（零高度），不改变既有界面高度。
          PluginStatusBar(
            registry: _registry,
            agentId: _selectedAgent?.id ?? '',
            sessionId: _currentSessionId,
          ),
        ],
      ),
        ),
      ),
    );
  }

  /// 构建移动端单栏布局（底部导航切换：Agent 列表 / 消息 / 文件）
  ///
  /// 移动端屏幕窄，桌面三栏无法容纳，改为顶部 AppBar + 单页内容 +
  /// 底部导航；选中 Agent 后自动切到消息页。文件页未选中 Agent 时显示占位。
  Widget _buildMobileLayout() {
    final String workspaceId = _selectedAgent?.workspaceId ?? '';
    final String title;
    switch (_mobileTab) {
      case 0:
        title = 'Agent 列表';
        break;
      case 1:
        title = _selectedAgent?.name ?? 'Agent 团队效率工具';
        break;
      default:
        title = '文件管理';
        break;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const SettingsPage(),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
          ),
          if (_mobileTab == 0)
            IconButton(
              tooltip: '创建 Agent',
              onPressed: _handleCreateAgent,
              icon: const Icon(Icons.add_circle_outline),
            ),
        ],
      ),
      body: IndexedStack(
        index: _mobileTab,
        children: [
          AgentList(
            agents: _railAgents,
            onAgentSelected: (Agent agent) {
              setState(() {
                _selectedAgent = agent;
                _currentSessionId = 'session_default';
                _mobileTab = 1;
                _setTeamScope(agent.teamScopeId);
              });
            },
            onClearHistory: _handleClearHistory,
            onDelete: _handleDeleteAgent,
          ),
          MessagePanel(
            selectedAgent: _selectedAgent,
            refreshTrigger: _refreshTrigger,
            onSessionChanged: (String id) {
              setState(() {
                _currentSessionId = id;
              });
            },
            navigateMessageId: _navigateMessageId,
            navigateSessionId: _currentSessionId,
            navigateTrigger: _navigateTrigger,
            // 成员配置变更后重拉 agent 列表：刷新待处理成员红点/角标
            onAgentsChanged: _loadAgents,
          ),
          workspaceId.isEmpty
              ? _buildMobileFilePlaceholder()
              : FilePanel(
                  key: ValueKey(workspaceId),
                  workspaceId: workspaceId,
                  teamId: _selectedAgent?.id,
                  teamName: _selectedAgent?.name ?? '',
                  sessionId: _currentSessionId,
                  onNavigateToQuestion: _handleNavigateToQuestion,
                  onNavigateToToolRun: _handleNavigateToToolRun,
                  selectTab: _filePanelTab,
                  selectTabRevision: _filePanelTabRevision,
                ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _mobileTab,
        onDestinationSelected: (int index) {
          setState(() => _mobileTab = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups),
            label: 'Agent',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '消息',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '文件',
          ),
        ],
      ),
    );
  }

  /// 移动端未选中 Agent 时文件页占位
  Widget _buildMobileFilePlaceholder() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: 56,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '请先在 Agent 页选择或创建一个 Agent',
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 窗口尺寸过小时显示的提示页面
  Widget _buildSmallSizePrompt() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.aspect_ratio_outlined,
            size: 64,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '窗口尺寸过小，请调整窗口大小',
            style: TextStyle(fontSize: 18, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            '建议最小尺寸：1024 × 600',
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 构建三栏布局
  Widget _buildThreeColumnLayout(double availableWidth) {
    // 记录本帧可用宽度：左右栏宽度上限由它推出（见 [_sideBudgetFor]）。
    // 这里**只记录、不改状态**——布局期间 setState 会被框架判为非法；
    // 窗口尺寸变化导致的宽度收敛交给 [_scheduleSideNormalize]（帧后执行）。
    _layoutAvailableWidth = availableWidth;
    _scheduleSideNormalize();
    // 本帧就按预算夹一次**渲染宽度**（不动状态）：状态收敛要等帧后回调，而
    // 窗口缩小的那一帧布局已经发生——不夹就会把中栏挤到 0，渲染层直接报
    // RenderFlex overflow。**拖拽期间不夹**：此时宽度由 [_dragCouple] 现场
    // 决定（它已按预算把对侧让出去），再夹一次会把对侧的让位又吐回来，
    // 表现成"拖不过某个位置"。
    final double? budget = _sideBudgetFor(availableWidth);
    final (double renderLeft, double renderRight) = budget == null || _sideDragging
        ? (_leftWidth, _rightWidth)
        : _fitSideWidths(budget, _leftWidth, _rightWidth);
    // 中栏折叠时它只占一根窄条，但展开内容仍要按"折叠前的宽度"布局
    // （见 [_centerRenderWidth]：在 40px 宽的视口里重排会把消息流挤成一列）。
    final double renderCenter = _centerRenderWidth(
      availableWidth,
      renderLeft,
      renderRight,
    );
    // 谁承接中栏让出的宽度（右栏优先；两侧都收着则没人接）
    final bool leftAbsorbs = _leftAbsorbs;
    final bool rightAbsorbs = _rightAbsorbs;
    return Row(
      children: [
        // 左侧活动栏：切换左栏功能面板（Agent 列表 / 插件），常驻显示
        _buildActivityBar(),
        // 左栏面板区（Agent 列表或插件；收起时只留窄条）
        //
        // 外面这层 Flexible 是**常驻**的（只是 flex 在 0/1 之间变）：不能按状态
        // 换控件类型——SizedBox ↔ Flexible 一变，这棵子树会被整个重建，左栏的
        // 滚动位置与当前面板就丢了。flex 0 = 不做弹性（自己定宽度），
        // flex 1 = 承接中栏让出的宽度（见 [_leftAbsorbs]）。
        Flexible(
          flex: leftAbsorbs ? 1 : 0,
          child: _buildSidebar(
            key: const ValueKey<String>('main-left-sidebar'),
            collapsed: _leftCollapsed,
            expandedWidth: renderLeft,
            fill: leftAbsorbs,
            collapsedBar: _buildCollapsedLeftBar(),
            expandedBar: _buildLeftPanel(),
          ),
        ),
        // 拖拽分隔条 1（控制左栏宽度；折叠时平滑收为 0）
        _buildAnimatedDivider(
          hidden: _leftCollapsed || leftAbsorbs,
          divider: DraggableDivider(
            onDragStart: () => _beginSideDrag(),
            onDragEnd: _endSideDrag,
            onDrag: (delta) {
              setState(() {
                // 向右拖拽（delta 为正）时左栏变宽；不设固定像素上限，
                // 空间不够时右栏主动让位
                final (double l, double r) = _dragCouple(
                  availableWidth,
                  _leftWidth + delta,
                  _rightCollapsed ? 0 : _rightWidth,
                  true,
                );
                _leftWidth = l;
                // 右栏正在承接中栏让出的宽度：它的宽度由窗口决定，
                // 拖左分隔条只改左栏（否则会悄悄改掉一个看不见的量）
                if (!_rightCollapsed && !_rightAbsorbs) _rightWidth = r;
              });
            },
          ),
        ),
        // 中栏：消息交互（弹性宽度；折叠时收成窄条，宽度让给侧栏）
        Flexible(
          flex: _centerCollapsed ? 0 : 1,
          child: _buildCenterPane(expandedWidth: renderCenter),
        ),
        // 拖拽分隔条 2（控制右栏宽度；折叠时平滑收为 0）
        _buildAnimatedDivider(
          hidden: _rightCollapsed || rightAbsorbs,
          divider: DraggableDivider(
            onDragStart: () => _beginSideDrag(),
            onDragEnd: _endSideDrag,
            onDrag: (delta) {
              setState(() {
                // 右栏分隔条向左拖拽（delta 为负）时右栏变宽；
                // 空间不够时左栏主动让位
                final (double l, double r) = _dragCouple(
                  availableWidth,
                  _rightWidth - delta,
                  _leftCollapsed ? 0 : _leftWidth,
                  false,
                );
                _rightWidth = r;
                // 左栏正在承接中栏让出的宽度：它的宽度由窗口决定，拖右分隔条只改右栏
                if (!_leftCollapsed && !_leftAbsorbs) _leftWidth = l;
              });
            },
          ),
        ),
        // 右栏：文件管理（收起时只留窄条；中栏折叠时由它承接让出的宽度）
        Flexible(
          flex: rightAbsorbs ? 1 : 0,
          child: _buildSidebar(
            key: const ValueKey<String>('main-right-sidebar'),
            collapsed: _rightCollapsed,
            expandedWidth: renderRight,
            fill: rightAbsorbs,
            collapsedBar: _buildCollapsedRightBar(),
            expandedBar: _buildFilePanel(),
          ),
        ),
        // 中栏折叠、两侧也都收着：没人承接的宽度由空占位吃掉。
        // 少了它，整行会在右端留一块空白（三根折叠窄条全贴在左边）。
        if (_centerCollapsed && !leftAbsorbs && !rightAbsorbs) const Spacer(),
      ],
    );
  }

  /// 构建中栏（消息交互）。
  ///
  /// 中栏是**弹性列**，没有固定宽度：展开时吃满剩余空间，折叠时收成
  /// [_collapsedWidth] 窄条并把宽度让给侧栏。展开内容始终以 [expandedWidth]
  /// （= 折叠前的宽度）挂载、被 ClipRect 裁掉——与左右栏同一套机制，
  /// 所以折叠再展开**会话、消息滚动位置、输入框草稿都不丢**。
  Widget _buildCenterPane({required double expandedWidth}) {
    return _buildSidebar(
      key: const ValueKey<String>('main-center-sidebar'),
      collapsed: _centerCollapsed,
      expandedWidth: expandedWidth,
      // 展开时它是唯一的弹性列，宽度由父级给（不是固定像素）
      fill: !_centerCollapsed,
      collapsedBar: _buildCollapsedCenterBar(),
      expandedBar: MessagePanel(
        selectedAgent: _selectedAgent,
        refreshTrigger: _refreshTrigger,
        onSessionChanged: (String id) {
          setState(() {
            _currentSessionId = id;
          });
        },
        navigateMessageId: _navigateMessageId,
        navigateSessionId: _currentSessionId,
        navigateTrigger: _navigateTrigger,
        // 成员配置变更后重拉 agent 列表：刷新待处理成员红点/角标
        onAgentsChanged: _loadAgents,
        // 折叠中栏：把宽度让给侧栏（标题栏最右边那颗 chevron）
        onCollapse: () {
          setState(() {
            _centerCollapsed = true;
          });
        },
      ),
    );
  }

  /// 中栏"折叠前应有的宽度"：可用宽度扣掉固定占用与两侧当前宽度。
  ///
  /// 中栏没有固定宽度，折叠时得反算一个值给展开内容定宽（见 [_buildCenterPane]）：
  /// 在 40px 宽的视口里重排，消息流会被挤成一列，滚动位置也会被夹回去。
  /// 这个值不必精确——差几像素只是被裁掉的内容多/少一列。
  double _centerRenderWidth(
    double availableWidth,
    double leftWidth,
    double rightWidth,
  ) {
    final double leftSlot = _leftCollapsed ? _collapsedWidth : leftWidth;
    final double rightSlot = _rightCollapsed ? _collapsedWidth : rightWidth;
    final double width = availableWidth - _chromeWidth - leftSlot - rightSlot;
    // 下限就是 [_centerMinWidth]：中栏的内容（标题栏 + 输入框区）本身需要这么宽，
    // 按更窄的宽度布局会当场 RenderFlex overflow——而它反正被 40px 的窄条裁掉，
    // 用 360 布局与用 351 布局在屏幕上一模一样，只是后者会报错。
    return width > _centerMinWidth ? width : _centerMinWidth;
  }

  /// 构建折叠状态的中栏（窄条 + 展开按钮）。
  ///
  /// 与左右栏的折叠窄条同一套语言：顶部一颗展开键，其余整条可点开。
  Widget _buildCollapsedCenterBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: _collapsedWidth,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor,
                  width: 1,
                ),
              ),
            ),
            child: Center(
              child: IconButton(
                tooltip: '展开中栏',
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() {
                    _centerCollapsed = false;
                  });
                },
              ),
            ),
          ),
          Expanded(
            // 整条窄条可点击展开（不只顶部按钮）
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                setState(() {
                  _centerCollapsed = false;
                });
              },
              child: RotatedBox(
                quarterTurns: 1,
                child: Center(
                  child: Text(
                    '消息',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 侧栏（左/右）可用宽度预算：可用宽度扣掉固定占用与中栏保底宽度后的剩余。
  ///
  /// 固定占用＝活动栏 + 两个分隔条（收起时其分隔条宽度为 0）。**必须**扣掉它们，
  /// 否则按预算拖到极限时中栏实际只剩 `360 - 48 - 12 = 300`，内部 Row 直接溢出。
  ///
  /// 返回 null 表示当前无法判定（尚未完成首帧布局 / 窗口过窄）。
  ///
  /// 注意：**没有固定像素上限**——两侧共用这一份预算，所以文件阅读（长行 /
  /// 宽表格 / 宽 PDF）或长提示词编辑都能把任一侧拖到接近整窗宽，上限只由
  /// "中栏仍要留下 [_centerMinWidth]" 这一条底线决定。
  double? _sideBudgetFor(double availableWidth) {
    final double budget =
        availableWidth - _chromeWidth - _centerReserveWidth;
    return budget >= _minSideWidth ? budget : null;
  }

  /// 中栏实际可用宽度（供拖拽时反解单侧上限）。
  double _centerAvailableFor(double availableWidth) =>
      availableWidth - _chromeWidth;

  /// 在预算内确定左/右栏宽度：**等比缩减**，两侧都不破下限。
  ///
  /// 只按"单侧上限"夹是不够的：两栏都拖得很大时各自都没超上限，合起来却会把
  /// 中栏压到 0（布局直接溢出）。所以这里约束的是**两栏之和**；窗口变窄需要
  /// 收回空间时按剩余可缩空间等比分配，保留用户刻意做出来的不对称
  /// （例如"右栏很宽、左栏已在下限"）。
  ///
  /// 返回 (left, right)。
  (double, double) _fitSideWidths(double budget, double left, double right) {
    double l = left < _leftMinWidth ? _leftMinWidth : left;
    double r = right < _rightMinWidth ? _rightMinWidth : right;
    final double overflow = (l + r) - budget;
    if (overflow <= 0) return (l, r);

    // 两侧各自还能让出多少；按这个比例分摊 overflow，避免把某一侧先推到底
    final double slackL = l - _leftMinWidth;
    final double slackR = r - _rightMinWidth;
    final double slack = slackL + slackR;
    if (slack <= 0) {
      // 两侧都贴在下限：只能压中栏（窗口已小于最小窗口宽度，页面会切小窗提示）
      return (l, r);
    }
    l -= overflow * slackL / slack;
    r -= overflow * slackR / slack;
    return (l, r);
  }

  /// 把单个侧栏宽度抬到下限之上（合计约束由 [_fitSideWidths] 统一处理）。
  double _clampSideWidth(double width, double minWidth) =>
      width < minWidth ? minWidth : width;

  /// 在 [value] 不低于 [min] 的前提下，最多能给出 [need] 中的多少。
  static double _giveWithin(double value, double min, double need) {
    final double slack = value - min;
    return slack < need ? slack : need;
  }

  /// 拖拽分隔条时联动另一侧：被拖拽的一侧按请求变宽，位置不够时
  /// **主动从对侧借空间**（对侧可一直缩到自己的下限）。
  ///
  /// [draggedLeft] 指明拖的是左栏那一侧；[other] 是对侧**当前**宽度。
  /// 两栏**合计**只能占 `中栏可用宽度 - 中栏最小宽度(360)`，被拖拽侧先拿，
  /// 对侧拿剩下的：
  /// 1. 中栏本来有富余 → 先吃中栏，对侧不动；
  /// 2. 中栏已到 360 → 从对侧借，借到它的下限为止；
  /// 3. 对侧也到下限 → 被拖拽侧就此封顶（中栏不再被压）。
  ///
  /// 所以"右栏拖到很大"时左栏会自己让出空间，"左栏拖到很大"时右栏同理。
  ///
  /// 返回 (left, right)。
  (double, double) _dragCouple(
    double available,
    double requested,
    double other,
    bool draggedLeft,
  ) {
    // 中栏保底之后，留给两侧的总空间（中栏折叠时它只保底一根窄条）
    final double sideBudget =
        _centerAvailableFor(available) - _centerReserveWidth;
    final double draggedMin = draggedLeft ? _leftMinWidth : _rightMinWidth;
    final double otherMin = draggedLeft ? _rightMinWidth : _leftMinWidth;
    // 被拖拽侧的上限：总空间扣掉对侧下限
    final double draggedMax = sideBudget - otherMin;
    double dragged = _clampSideWidth(requested, draggedMin);
    if (dragged > draggedMax) dragged = draggedMax;

    // 对侧吃下剩余空间，但不超过它当前宽度（只让位、不长大）
    double otherNext = sideBudget - dragged;
    if (otherNext > other) otherNext = other;
    if (otherNext < otherMin) otherNext = otherMin;

    // 两侧都顶到下限仍放不下：只能压缩中栏（窗口已小于最小窗口宽度）
    final double overflow = dragged + otherNext - sideBudget;
    if (overflow > 0) {
      final double give = _giveWithin(dragged, draggedMin, overflow);
      dragged -= give;
      final double rest = overflow - give;
      if (rest > 0) otherNext -= _giveWithin(otherNext, otherMin, rest);
    }
    // 返回顺序恒为 (left, right)
    return draggedLeft ? (dragged, otherNext) : (otherNext, dragged);
  }

  /// 帧后把侧栏宽度收敛进当前预算（每帧最多安排一次）。
  ///
  /// 为什么不能在布局回调里直接收敛：`LayoutBuilder` 的 builder 在布局阶段
  /// 执行，此时 `setState` 抛 "setState() called during build"。而
  /// `didChangeMetrics` 也拿不到新尺寸——它在下一帧布局前触发，
  /// [_layoutAvailableWidth] 还是旧值。所以在**本帧布局拿到新宽度之后**、
  /// 下一帧之前（帧后回调）收敛，被压破的那一帧不会被绘制。
  void _scheduleSideNormalize() {
    // 拖拽期间不收敛：宽度由 [_dragCouple] 现场决定（它本身已经满足预算），
    // 再让"帧后收敛"插一脚会按另一套比例把用户正在拖的一侧往回拉。
    if (_sideNormalizeScheduled || _sideDragging) return;
    _sideNormalizeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sideNormalizeScheduled = false;
      _normalizeSideWidths();
    });
  }

  /// 开始拖拽侧栏分隔条：暂停帧后收敛，让拖拽完全说了算。
  void _beginSideDrag() {
    _sideDragging = true;
  }

  /// 结束拖拽：恢复收敛（拖拽期间若窗口被改变，这里补一次校正）。
  void _endSideDrag() {
    _sideDragging = false;
    _normalizeSideWidths();
  }

  /// 把左/右栏宽度收敛进当前窗口的预算内（已符合预算时什么都不做）。
  ///
  /// **等比收缩**而不是"谁宽谁先让"：窗口变窄时两栏按原比例缩，用户在拖拽中
  /// 刻意做出来的不对称（例如右栏 1240 / 左栏 200）不会被重新分配。
  void _normalizeSideWidths() {
    if (_sideDragging) return;
    final double? available = _layoutAvailableWidth;
    if (available == null || !mounted) return;
    final double? budget = _sideBudgetFor(available);
    if (budget == null) return;
    final double l = _leftCollapsed ? 0 : _leftWidth;
    final double r = _rightCollapsed ? 0 : _rightWidth;
    if (l + r <= budget) return; // 已在预算内，保持现状
    final (double nl, double nr) = _fitSideWidths(budget, l, r);
    final double newLeft = _leftCollapsed ? _leftWidth : nl;
    final double newRight = _rightCollapsed ? _rightWidth : nr;
    if (newLeft == _leftWidth && newRight == _rightWidth) return;
    setState(() {
      _leftWidth = newLeft;
      _rightWidth = newRight;
    });
  }

  /// 折叠自适应的侧栏：折叠时收成 [_collapsedWidth] 的窄条，展开时恢复给定宽度。
  ///
  /// **宽度不做补间动画**：改宽度必须当帧生效。若用 `AnimatedContainer` 补间，
  /// 窗口缩小后侧栏会按旧宽度逐帧缩回，这几帧里两栏之和超过预算，中栏被挤到 0
  /// 并直接抛 RenderFlex overflow（见 [_fitSideWidths]）。折叠/展开本身由
  /// ClipRect + 窄条覆盖完成，观感不受影响。
  ///
  /// 展开内容始终以完整宽度挂载（折叠时超出容器部分被裁剪，并被折叠窄条
  /// 覆盖、禁用点击），从而保留其 State（滚动位置、当前 Tab、文件查看器等），
  /// 避免折叠再展开后访问位置丢失。
  /// [fill] 为真时展开态**吃满父级给的宽度**（中栏自己、以及折叠中栏时承接
  /// 空间的侧栏）：宽度改由父级（[Flexible]）决定，内容按实际宽度布局——
  /// 右栏读文件时因此能用满整窗，而不是被自己的宽度状态卡住。
  Widget _buildSidebar({
    Key? key,
    required bool collapsed,
    required double expandedWidth,
    bool fill = false,
    required Widget collapsedBar,
    required Widget expandedBar,
  }) {
    return SizedBox(
      key: key,
      width: collapsed
          ? _collapsedWidth
          : (fill ? double.infinity : expandedWidth),
      child: ClipRect(
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            // 展开面板：以 Positioned 指定完整宽度布局（不受折叠时父级 40px
            // 紧约束影响），折叠时超出部分被 ClipRect 裁剪；仍挂载以保留
            // State，同时禁用点击与动画（折叠窄条会覆盖它）。
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: fill ? null : expandedWidth,
              right: fill ? 0 : null,
              child: IgnorePointer(
                ignoring: collapsed,
                child: TickerMode(enabled: !collapsed, child: expandedBar),
              ),
            ),
            // 折叠窄条：仅折叠时覆盖在展开面板之上
            if (collapsed) Positioned.fill(child: collapsedBar),
          ],
        ),
      ),
    );
  }

  /// 收起的侧栏所带的分隔条：宽度平滑收为 0（不占空间）
  ///
  /// 分隔条本身只有 6px，补间不会挤压中栏（预算按展开宽度计算，收起时更宽裕），
  /// 所以这里保留宽度过渡；侧栏宽度则必须当帧生效（见 [_buildSidebar]）。
  ///
  /// [hidden] 除了"这一侧收着"，还包括"这一侧正在承接中栏让出的空间"：那种
  /// 状态下它的宽度由窗口决定，拖这颗分隔条不会有任何位移，留着只会误导。
  Widget _buildAnimatedDivider({
    required bool hidden,
    required Widget divider,
  }) {
    return AnimatedContainer(
      duration: _sidebarAnimDuration,
      curve: _sidebarAnimCurve,
      width: hidden ? 0 : _dividerWidth,
      child: hidden ? const SizedBox.shrink() : divider,
    );
  }

  /// 构建左侧活动栏（VS Code 风格图标条：Agent 列表 / 插件 / 设置）
  ///
  /// 固定在整列最左侧且**不随面板折叠**：折叠只影响右侧的 [_leftWidth] 面板区。
  /// 插件面板由右栏迁到此处后，Agent 列表仍在最上面（默认选中项）。
  ///
  /// 设置入口固定在底部：它属于**全局**入口而非某个面板的功能，原先挂在
  /// Agent 面板标题栏上，切到插件面板后整个标题栏消失、设置也就找不到了。
  /// 放在活动栏底部后切任何面板都可见（与 VS Code 的齿轮位置一致）。
  Widget _buildActivityBar() {
    return Container(
      width: _activityBarWidth,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          const SizedBox(height: 8),
          ActivityBarItem(
            icon: Icons.groups_outlined,
            selectedIcon: Icons.groups,
            tooltip: 'Agent 列表',
            selected: _isBuiltinPanelSelected(0),
            onTap: () => _selectBuiltinPanel(0),
          ),
          const SizedBox(height: 4),
          ActivityBarItem(
            icon: Icons.extension_outlined,
            selectedIcon: Icons.extension,
            tooltip: '插件管理',
            selected: _isBuiltinPanelSelected(1),
            onTap: () => _selectBuiltinPanel(1),
          ),
          const SizedBox(height: 4),
          ActivityBarItem(
            icon: Icons.download_outlined,
            selectedIcon: Icons.download,
            tooltip: '下载列表',
            selected: _isBuiltinPanelSelected(2),
            onTap: () => _selectBuiltinPanel(2),
          ),
          // Q12：插件活动栏项追加在内置项之后（同一套尺寸 / 选中态 / 折叠行为）
          PluginActivityBarItems(
            registry: _registry,
            selectedSlotKey: _selectedPluginActivityKey,
            onSelect: _selectPluginPanel,
          ),
          // 撑开剩余空间，把设置压到底部
          const Spacer(),
          ActivityBarAction(
            icon: Icons.settings_outlined,
            tooltip: '设置',
            onTap: _openSettings,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 内置面板项是否处于选中态（选中插件项时内置项一律不高亮）
  bool _isBuiltinPanelSelected(int index) =>
      _selectedPluginActivityKey == null && _leftPanel == index;

  /// 切到内置左栏面板（并展开左栏，与既有行为一致）
  void _selectBuiltinPanel(int index) {
    setState(() {
      _leftPanel = index;
      _selectedPluginActivityKey = null;
      _leftCollapsed = false;
    });
  }

  /// 切到插件活动栏槽位（同样展开左栏；折叠态行为与内置项一致）
  void _selectPluginPanel(String slotKey) {
    setState(() {
      _selectedPluginActivityKey = slotKey;
      _leftCollapsed = false;
    });
  }

  // ── 新手引导 ─────────────────────────────────────────────────────────

  /// 第一次使用（没有任何"看过"记录）时弹一次引导；跳过或走完都不再自动弹。
  Future<void> _maybeShowGuide() async {
    bool show;
    try {
      show = await OnboardingState.instance.shouldShow();
    } catch (_) {
      // 读不到偏好（平台不支持 / 测试环境没装插件）就**不打扰**：引导是锦上添花，
      // 不能因为它把启动流程搞出未捕获异常。
      return;
    }
    if (!mounted || !show) return;
    setState(() {
      _guideVisible = true;
      _guideIndex = 0;
    });
  }

  /// 引导浮层（**非模态**：只盖中栏上方一小块，后面的界面照样能点——每一步都要
  /// 打开真实界面，模态对话框会把那些界面挡在外面）。
  Widget _buildGuide() {
    final int index = _guideIndex.clamp(0, kOnboardingSteps.length - 1);
    final OnboardingStep step = kOnboardingSteps[index];
    return OnboardingGuide(
      step: step,
      index: index,
      total: kOnboardingSteps.length,
      onAction: () => _runGuideAction(step),
      onBack: () => setState(() => _guideIndex = index - 1),
      onNext: () => setState(() => _guideIndex = index + 1),
      onSkipAll: () => unawaited(_closeGuide()),
      onFinish: () => unawaited(_closeGuide()),
    );
  }

  /// 收工（走完「完成」或按「跳过引导」）：记下来，之后不再自动弹。
  Future<void> _closeGuide() async {
    setState(() {
      _guideVisible = false;
    });
    try {
      await OnboardingState.instance.markDone();
    } catch (_) {
      // 写不进去（平台不支持）也不该打断用户：这次会话内它确实关掉了。
    }
  }

  /// 「带我过去」：**只做导航**（打开真实界面 / 唤起终端 / 预填输入框），
  /// 不替用户做决定、不自动提交任何东西。
  void _runGuideAction(OnboardingStep step) {
    switch (step.id) {
      case OnboardingStepId.models:
        unawaited(_openSettings(focusModels: true));
      case OnboardingStepId.createAgent:
        unawaited(_handleCreateAgent());
      case OnboardingStepId.agentModel:
        _requestFilePanelTab(FilePanel.modelInfoTabIndex);
      case OnboardingStepId.workspace:
        WorkspacePickRequest.instance.request();
      case OnboardingStepId.plugins:
        _selectBuiltinPanel(_pluginPanelIndex);
      case OnboardingStepId.files:
        _requestFilePanelTab(FilePanel.filesTabIndex);
      case OnboardingStepId.terminal:
        TerminalToggleRequest.instance.request();
      case OnboardingStepId.demo:
        // 只填进输入框，不自动发送（用户看清了再按发送）
        ComposerPrefillRequest.instance.request(kOnboardingDemoText);
    }
  }

  /// 展开右栏并请求切到某个顶层页签（序号自增 ⇒ 同一个页签点第二次也生效）。
  void _requestFilePanelTab(int tab) {
    setState(() {
      _rightCollapsed = false;
      _filePanelTab = tab;
      _filePanelTabRevision++;
    });
  }

  /// 打开设置页（活动栏底部全局入口）。
  ///
  /// [focusModels] 为真时滚到「自定义模型」一节（新手引导第 1 步）。
  /// 设置页返回 `true` = 用户在那里点了「重新显示新手引导」⇒ 清记录再弹一次。
  Future<void> _openSettings({bool focusModels = false}) async {
    final bool? replay = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) =>
            SettingsPage(focusModels: focusModels),
      ),
    );
    if (replay != true) return;
    await OnboardingState.instance.reset();
    if (!mounted) return;
    setState(() {
      _guideVisible = true;
      _guideIndex = 0;
    });
  }

  /// 构建左栏当前选中的功能面板
  ///
  /// 用 [IndexedStack] 而非条件渲染：两个面板都保持挂载，因此
  /// - Agent 列表滚动位置、插件面板的最近快照都不丢；
  /// - `PluginMonitorService` 的引用计数稳定为 1，**切换面板不会断开/重建它
  ///   自有的 WebSocket**（条件渲染会每次 start/stop 造成连接抖动）。
  Widget _buildLeftPanel() {
    // Q12：插件活动栏槽位排在三个内置面板之后；栈索引按"当前选中槽位"计算，
    // 槽位被注销时回落到内置面板（_onPluginSlotsChanged 会清掉过期选中）。
    final List<PluginUiSlot> activitySlots =
        _registry.slotsOfKind(PluginUiSlotKind.activity);
    final String? selectedKey = _selectedPluginActivityKey;
    final int pluginIndex = selectedKey == null
        ? -1
        : activitySlots.indexWhere((PluginUiSlot s) => s.slotKey == selectedKey);
    final int stackIndex = pluginIndex >= 0
        ? _builtinLeftPanelCount + pluginIndex
        : _leftPanel.clamp(0, _builtinLeftPanelCount - 1);
    return IndexedStack(
      index: stackIndex,
      children: <Widget>[
        _buildAgentPanel(),
        // 左栏由活动栏承担标题，避免与面板自带标题重复。
        // onCollapse：内容下方空白区域点击折叠左栏（与 Agent 列表一致）。
        PluginPanel(
          // 站点/槽位都以**团队**为单位：成员要回指团队，否则面板会被过滤成「站点（0）」
          teamId: _selectedAgent?.teamScopeId,
          showHeader: false,
          onCollapse: () {
            setState(() {
              _leftCollapsed = true;
            });
          },
        ),
        // 「下载」面板（M8d）：全局任务列表，每条标来源 team
        DownloadPanel(
          onCollapse: () {
            setState(() {
              _leftCollapsed = true;
            });
          },
        ),
        // Q12：每个活动栏插件槽位一个面板页（视图更新由该控件自行监听）
        for (final PluginUiSlot slot in activitySlots)
          PluginPanelSlotView(
            slot: slot,
            registry: _registry,
            agentId: _selectedAgent?.id ?? '',
            sessionId: _currentSessionId,
          ),
      ],
    );
  }

  /// 构建右栏文件面板
  ///
  /// 显示当前选中 agent 的工作空间文件与 git 历史；
  /// 未选中任何 agent 时显示占位提示。
  Widget _buildFilePanel() {
    final cs = Theme.of(context).colorScheme;
    final workspaceId = _selectedAgent?.workspaceId ?? '';
    if (workspaceId.isEmpty) {
      // 未选中 agent：右侧为空白占位，点击任意空白处折叠右侧栏。
      // 这里保留现有文字（不新增"点击空白处折叠"提醒，用户可自然外推）。
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          setState(() {
            _rightCollapsed = true;
          });
        },
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_outlined,
                size: 56,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '请先在左侧选择或创建一个 Agent',
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return FilePanel(
      key: ValueKey(workspaceId),
      workspaceId: workspaceId,
      teamId: _selectedAgent?.id,
      teamName: _selectedAgent?.name ?? '',
      sessionId: _currentSessionId,
      // 与主页面共用同一注册表（注入实例优先，便于测试）
      registry: widget.registry,
      onCollapse: () {
        setState(() {
          _rightCollapsed = true;
        });
      },
      onNavigateToQuestion: _handleNavigateToQuestion,
      // 「正在执行的 tool」点一行切中栏到该运行所属的 agent / 会话
      onNavigateToToolRun: _handleNavigateToToolRun,
      // 引导「带我过去」的页签请求（按序号触发，见 _requestFilePanelTab）
      selectTab: _filePanelTab,
      selectTabRevision: _filePanelTabRevision,
    );
  }

  /// 左栏 Agent 列表的数据源：**全部 agent（顶层 + 团队成员）**。
  ///
  /// 团队成员也是独立 agent 文件（`parent_agent_id` 指向直属上级、`team_id` 指向 TOP），
  /// `GET /api/agents` 会一并返回——**它们照常列在这里**（2026-10-02 定夺：先判"成员不独立
  /// 出现在左栏"，同日二改为**允许出现**）。点开成员就是它自己的会话，与顶层 agent 同一条通路，
  /// 顺序口径见 [railAgentsOf]。
  ///
  /// **其余口径不变**：成员的工具根 / 系统提示词 / 文件面板仍解析到 leader 的工作目录与 SSH
  /// （`teamWorkspaceFor`，"复用 leader 工作区"没动），插件作用域仍按 `teamScopeId` 回指
  /// 团队；团队拓扑与成员进度仍看 teammates 窗口（只是不再是**唯一**入口）。
  List<Agent> get _railAgents => railAgentsOf(_agents);

  /// 构建左栏 Agent 列表面板
  ///
  /// 顶部标题栏（含创建按钮）+ Agent 列表，选中 agent 时更新中栏标题。
  Widget _buildAgentPanel() {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // 标题栏（含创建 Agent 按钮）
          _buildAgentHeader(),
          // Agent 列表
          Expanded(
            child: AgentList(
              agents: _railAgents,
              onAgentSelected: (Agent agent) {
                setState(() {
                  _selectedAgent = agent;
                  _currentSessionId = 'session_default';
                  _setTeamScope(agent.teamScopeId);
                });
              },
              onClearHistory: _handleClearHistory,
              onDelete: _handleDeleteAgent,
              onCollapse: () {
                setState(() {
                  _leftCollapsed = true;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 构建左栏标题栏（标题 + 创建/折叠按钮）
  ///
  /// 设置入口已移到活动栏底部（全局入口，切面板后不应消失）。
  Widget _buildAgentHeader() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 16, right: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Agent 列表',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          // 创建 Agent
          IconButton(
            tooltip: '创建 Agent',
            onPressed: _handleCreateAgent,
            icon: const Icon(Icons.add_circle_outline),
            color: cs.primary,
          ),
          // 折叠左侧栏
          IconButton(
            tooltip: '折叠左侧栏',
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() {
                _leftCollapsed = true;
              });
            },
          ),
        ],
      ),
    );
  }

  /// 折叠窄条上的文案：插件槽位用槽位标签，内置面板用固定文案。
  String _collapsedLeftLabel() {
    final String? key = _selectedPluginActivityKey;
    if (key != null) {
      final PluginUiSlot? slot = _registry.slot(key);
      if (slot != null) {
        return pluginSlotLabel(slot);
      }
    }
    switch (_leftPanel) {
      case 1:
        return '插件';
      case 2:
        return '下载';
      default:
        return 'Agent 列表';
    }
  }

  /// 构建折叠状态的左侧栏（窄条 + 展开按钮）
  Widget _buildCollapsedLeftBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: _collapsedWidth,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor,
                  width: 1,
                ),
              ),
            ),
            child: Center(
              child: IconButton(
                tooltip: '展开左侧栏',
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() {
                    _leftCollapsed = false;
                  });
                },
              ),
            ),
          ),
          Expanded(
            // 整条窄条可点击展开（不只顶部按钮）
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                setState(() {
                  _leftCollapsed = false;
                });
              },
              child: RotatedBox(
                quarterTurns: 1,
                child: Center(
                  child: Text(
                    // 折叠窄条文案随活动栏选择变化（含插件活动栏槽位）
                    _collapsedLeftLabel(),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建折叠状态的右侧栏（窄条 + 展开按钮）
  Widget _buildCollapsedRightBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: _collapsedWidth,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor,
                  width: 1,
                ),
              ),
            ),
            child: Center(
              child: IconButton(
                tooltip: '展开右侧栏',
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  setState(() {
                    _rightCollapsed = false;
                  });
                },
              ),
            ),
          ),
          Expanded(
            // 整条窄条可点击展开（不只顶部按钮）
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                setState(() {
                  _rightCollapsed = false;
                });
              },
              child: RotatedBox(
                quarterTurns: 1,
                child: Center(
                  child: Text(
                    // 右栏现在含「文件 / MCP 配置 / 模型信息 / 问题回复」，
                    // 原「文件管理」文案已不准确
                    '工作区',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 左栏 Agent 列表的顺序：**顶层 agent 在前（保持接口顺序），成员紧跟各自的 TOP**。
///
/// 为什么这样排（而不是直接按接口顺序混排）：列表里现在同时有"团队根"和"成员"，混排
/// 看不出谁属于谁；把成员紧跟它的 TOP，既能一眼看出团队，也不打乱顶层之间的相对顺序
/// （接口按最近活跃倒序返回）。
///
/// 兜底：`team_id` 指向的 TOP 不在列表里时（TOP 被删 / 只加载到一部分），成员照样列在
/// 末尾——**绝不因为"找不到根"就让某个 agent 从列表里消失**。
List<Agent> railAgentsOf(List<Agent> agents) {
  final List<Agent> ordered = <Agent>[];
  final Set<String> placed = <String>{};
  for (final Agent top in agents) {
    if (top.teamId.isNotEmpty) continue;
    ordered.add(top);
    placed.add(top.id);
    for (final Agent member in agents) {
      if (member.teamId != top.id || !placed.add(member.id)) continue;
      ordered.add(member);
    }
  }
  for (final Agent agent in agents) {
    if (placed.add(agent.id)) ordered.add(agent);
  }
  return ordered;
}

/// 可拖拽的分隔条组件
///
/// 用于在三栏布局中分隔各栏，支持鼠标拖拽调整相邻栏的宽度。
/// 拖拽时变色提供视觉反馈，鼠标悬停时显示 resize 光标。
class DraggableDivider extends StatefulWidget {
  const DraggableDivider({
    super.key,
    required this.onDrag,
    this.onDragStart,
    this.onDragEnd,
  });

  /// 拖拽回调，参数为水平方向的增量（dx）
  final ValueChanged<double> onDrag;

  /// 开始拖拽（手指/鼠标按下并识别为水平拖拽）
  final VoidCallback? onDragStart;

  /// 结束拖拽（抬起）
  final VoidCallback? onDragEnd;

  @override
  State<DraggableDivider> createState() => _DraggableDividerState();
}

class _DraggableDividerState extends State<DraggableDivider> {
  // 是否正在拖拽
  bool _isDragging = false;
  // 鼠标是否悬停
  bool _isHovering = false;

  /// 根据状态获取分隔条颜色
  Color _getColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_isDragging) {
      // 拖拽时显示主题色
      return cs.primary;
    }
    if (_isHovering) {
      // 悬停时显示浅蓝色
      return cs.primaryContainer;
    }
    // 默认灰色
    return Theme.of(context).dividerColor;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onHorizontalDragStart: (_) {
          setState(() {
            _isDragging = true;
          });
          widget.onDragStart?.call();
        },
        onHorizontalDragUpdate: (details) {
          widget.onDrag(details.delta.dx);
        },
        onHorizontalDragEnd: (_) {
          setState(() {
            _isDragging = false;
          });
          widget.onDragEnd?.call();
        },
        onHorizontalDragCancel: () {
          setState(() {
            _isDragging = false;
          });
          widget.onDragEnd?.call();
        },
        child: Container(width: 6, color: _getColor(context)),
      ),
    );
  }
}
