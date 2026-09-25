import 'dart:async';

import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../../io/ssh_executor_service.dart';
import '../../io/websocket_service.dart';
import '../widgets/agent_list.dart';
import '../widgets/create_agent_dialog.dart';
import '../widgets/file_panel.dart';
import '../widgets/message_panel.dart';
import '../widgets/plugin_panel.dart';
import '../widgets/teammates_window_page.dart';
import 'login_page.dart';
import 'settings_page.dart';

/// 主页面 - 三栏布局
///
/// 左栏：Agent 列表（初始 260px，可调 200~400px）
/// 中栏：消息交互（弹性宽度，占据剩余空间）
/// 右栏：文件管理（初始 340px，可调 240~500px）
///
/// 支持通过拖拽分隔条调整左栏和右栏宽度；
/// 窗口尺寸过小时显示提示页面。
class MainPage extends StatefulWidget {
  const MainPage({super.key});

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

  // 折叠时宽度
  static const double _collapsedWidth = 40;

  /// 左侧活动栏宽度（VS Code 风格图标条，常驻不参与折叠动画）
  ///
  /// 必须**独立于** [_leftCollapsed] 的宽度动画：若把活动栏放进
  /// `AnimatedContainer` 内部，折叠左栏时它会被压到 [_collapsedWidth]，
  /// 图标显示不全。
  static const double _activityBarWidth = 48;

  /// 左侧活动栏当前选中的功能面板：0=Agent 列表，1=插件面板
  int _leftPanel = 0;

  // 侧栏折叠/展开的动画时长与曲线（宽度平滑过渡 + 内容淡入淡出）
  static const Duration _sidebarAnimDuration = Duration(milliseconds: 60);
  static const Curve _sidebarAnimCurve = Curves.linear;

  /// 移动端底部导航当前页（0=Agent 列表，1=消息，2=文件）
  int _mobileTab = 0;

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

  // 左栏宽度限制
  static const double _leftMinWidth = 200;
  static const double _leftMaxWidth = 400;
  // 右栏宽度限制
  static const double _rightMinWidth = 240;
  static const double _rightMaxWidth = 500;

  // 窗口最小尺寸
  static const double _minWindowWidth = 1024;
  static const double _minWindowHeight = 600;

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败: $e')),
        );
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该提问所属 Agent 不存在或已删除')),
          );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该提问所属 Agent 不存在或已删除')),
        );
      }
      return;
    }
    setState(() {
      _selectedAgent = target;
      _currentSessionId = sessionId;
      _navigateMessageId = messageId;
      _navigateTrigger++;
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
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e')),
        );
      }
    }
  }

  /// 删除指定 agent（连同其对话历史），并同步后端
  ///
  /// 按 teamId 注销该 agent 的执行器（注销后端注册、关闭 SSH 连接、清理
  /// per-team 内存状态），无论其是否为当前选中 agent——避免删除/重建后
  /// 旧注册残留导致新 agent 走错执行通道。
  Future<void> _handleDeleteAgent(Agent agent) async {
    try {
      await ApiService.deleteAgent(agent.id);
      if (!mounted) return;
      setState(() {
        _agents.removeWhere((a) => a.id == agent.id);
        // 注销该 team 的本地执行器（后端清注册，前端移除状态）
        LocalExecutorService.instance.deactivateTeam(agent.id);
        // 注销该 team 的 SSH 执行器（后端清注册并删除该 agent 的 SSH 配置，
        // 前端关闭连接并移除状态）
        unawaited(SshExecutorService.instance.deactivateTeam(agent.id));
        if (_selectedAgent?.id == agent.id) {
          _selectedAgent = null;
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 注册认证失败回调：token 过期时跳转登录页
    ApiService.onAuthError = _handleAuthError;
    WebSocketService.onAuthError = _handleAuthError;
    _loadAgents();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 清除回调，避免内存泄漏
    ApiService.onAuthError = null;
    WebSocketService.onAuthError = null;
    // 清理本地执行器：注销后端注册并释放 WebSocket 引用
    LocalExecutorService.instance.cleanup();
    // 清理 SSH 执行器：仅释放引用（不注销，SSH 配置后端持久化）
    SshExecutorService.instance.cleanup();
    super.dispose();
  }

  /// 处理认证失败：清除 token 并跳转回登录页
  void _handleAuthError() {
    // 清除本地 token
    unawaited(AuthService().clearToken());
    ApiService.setToken(null);
    // 跳转登录页
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载 Agent 列表失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
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
          return _buildThreeColumnLayout();
        },
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
            agents: _agents,
            onAgentSelected: (Agent agent) {
              setState(() {
                _selectedAgent = agent;
                _currentSessionId = 'session_default';
                _mobileTab = 1;
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
                  sessionId: _currentSessionId,
                  onNavigateToQuestion: _handleNavigateToQuestion,
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
            style: TextStyle(
              fontSize: 18,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '建议最小尺寸：1024 × 600',
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建三栏布局
  Widget _buildThreeColumnLayout() {
    return Row(
      children: [
        // 左侧活动栏：切换左栏功能面板（Agent 列表 / 插件），常驻显示
        _buildActivityBar(),
        // 左栏面板区（Agent 列表或插件；折叠时宽度平滑过渡，内容淡入淡出）
        _buildAnimatedSidebar(
          collapsed: _leftCollapsed,
          expandedWidth: _leftWidth,
          collapsedBar: _buildCollapsedLeftBar(),
          expandedBar: _buildLeftPanel(),
        ),
        // 拖拽分隔条 1（控制左栏宽度；折叠时平滑收为 0）
        _buildAnimatedDivider(
          collapsed: _leftCollapsed,
          divider: DraggableDivider(
            onDrag: (delta) {
              setState(() {
                _leftWidth = (_leftWidth + delta)
                    .clamp(_leftMinWidth, _leftMaxWidth)
                    .toDouble();
              });
            },
          ),
        ),
        // 中栏：消息交互（弹性宽度）
        Expanded(
          child: MessagePanel(
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
        ),
        // 拖拽分隔条 2（控制右栏宽度；折叠时平滑收为 0）
        _buildAnimatedDivider(
          collapsed: _rightCollapsed,
          divider: DraggableDivider(
            onDrag: (delta) {
              setState(() {
                // 右栏分隔条向右拖拽（delta 为正）时，右栏宽度减小
                _rightWidth = (_rightWidth - delta)
                    .clamp(_rightMinWidth, _rightMaxWidth)
                    .toDouble();
              });
            },
          ),
        ),
        // 右栏：文件管理（折叠时宽度平滑过渡，内容淡入淡出）
        _buildAnimatedSidebar(
          collapsed: _rightCollapsed,
          expandedWidth: _rightWidth,
          collapsedBar: _buildCollapsedRightBar(),
          expandedBar: _buildFilePanel(),
        ),
      ],
    );
  }

  /// 折叠自适应的侧栏：宽度随折叠状态平滑过渡。
  ///
  /// 展开内容始终以完整宽度挂载（折叠时超出容器部分被裁剪，并被折叠窄条
  /// 覆盖、禁用点击），从而保留其 State（滚动位置、当前 Tab、文件查看器等），
  /// 避免折叠再展开后访问位置丢失。
  Widget _buildAnimatedSidebar({
    required bool collapsed,
    required double expandedWidth,
    required Widget collapsedBar,
    required Widget expandedBar,
  }) {
    return AnimatedContainer(
      duration: _sidebarAnimDuration,
      curve: _sidebarAnimCurve,
      width: collapsed ? _collapsedWidth : expandedWidth,
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
              width: expandedWidth,
              child: IgnorePointer(
                ignoring: collapsed,
                child: TickerMode(
                  enabled: !collapsed,
                  child: expandedBar,
                ),
              ),
            ),
            // 折叠窄条：仅折叠时覆盖在展开面板之上
            if (collapsed)
              Positioned.fill(
                child: collapsedBar,
              ),
          ],
        ),
      ),
    );
  }

  /// 折叠自适应的分隔条：折叠时宽度平滑收为 0（不占空间）
  Widget _buildAnimatedDivider({
    required bool collapsed,
    required Widget divider,
  }) {
    return AnimatedContainer(
      duration: _sidebarAnimDuration,
      curve: _sidebarAnimCurve,
      width: collapsed ? 0 : 6,
      child: collapsed ? const SizedBox.shrink() : divider,
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
          _buildActivityItem(
            index: 0,
            icon: Icons.groups_outlined,
            selectedIcon: Icons.groups,
            tooltip: 'Agent 列表',
          ),
          const SizedBox(height: 4),
          _buildActivityItem(
            index: 1,
            icon: Icons.extension_outlined,
            selectedIcon: Icons.extension,
            tooltip: '插件（只读）',
          ),
          // 撑开剩余空间，把设置压到底部
          const Spacer(),
          _buildActivityAction(
            icon: Icons.settings_outlined,
            tooltip: '设置',
            onTap: _openSettings,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 打开设置页（活动栏底部全局入口）
  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const SettingsPage(),
      ),
    );
  }

  /// 活动栏里的**动作**按钮（非面板切换：不参与选中态、无高亮指示条）
  ///
  /// 与 [_buildActivityItem] 共用尺寸与图标规格，保证视觉一致；区别是没有
  /// 选中态（点它不会切换左栏面板）。
  Widget _buildActivityAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              // 与面板项对齐的占位（无选中色）
              const SizedBox(width: 2),
              Expanded(
                child: Icon(
                  icon,
                  size: 22,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个活动栏图标项（选中态带左侧高亮指示条 + 主色图标）
  Widget _buildActivityItem({
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String tooltip,
  }) {
    final bool selected = _leftPanel == index;
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          setState(() {
            _leftPanel = index;
            // 切到某个面板时顺带展开左栏（折叠状态下点图标应能看到内容）
            _leftCollapsed = false;
          });
        },
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              // 选中指示条
              Container(
                width: 2,
                height: 44,
                color: selected ? cs.primary : Colors.transparent,
              ),
              Expanded(
                child: Icon(
                  selected ? selectedIcon : icon,
                  size: 22,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建左栏当前选中的功能面板
  ///
  /// 用 [IndexedStack] 而非条件渲染：两个面板都保持挂载，因此
  /// - Agent 列表滚动位置、插件面板的最近快照都不丢；
  /// - `PluginMonitorService` 的引用计数稳定为 1，**切换面板不会断开/重建它
  ///   自有的 WebSocket**（条件渲染会每次 start/stop 造成连接抖动）。
  Widget _buildLeftPanel() {
    return IndexedStack(
      index: _leftPanel,
      children: <Widget>[
        _buildAgentPanel(),
        // 左栏由活动栏承担标题，避免与面板自带标题重复。
        // onCollapse：内容下方空白区域点击折叠左栏（与 Agent 列表一致）。
        PluginPanel(
          teamId: _selectedAgent?.id,
          showHeader: false,
          onCollapse: () {
            setState(() {
              _leftCollapsed = true;
            });
          },
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
      sessionId: _currentSessionId,
      onCollapse: () {
        setState(() {
          _rightCollapsed = true;
        });
      },
      onNavigateToQuestion: _handleNavigateToQuestion,
    );
  }

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
              agents: _agents,
              onAgentSelected: (Agent agent) {
                setState(() {
                  _selectedAgent = agent;
                  _currentSessionId = 'session_default';
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
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
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
                bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
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
                    // 折叠窄条文案随活动栏选择变化（左栏不再只有 Agent 列表）
                    _leftPanel == 0 ? 'Agent 列表' : '插件',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                    ),
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
                bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                    ),
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

/// 可拖拽的分隔条组件
///
/// 用于在三栏布局中分隔各栏，支持鼠标拖拽调整相邻栏的宽度。
/// 拖拽时变色提供视觉反馈，鼠标悬停时显示 resize 光标。
class DraggableDivider extends StatefulWidget {
  const DraggableDivider({
    super.key,
    required this.onDrag,
  });

  /// 拖拽回调，参数为水平方向的增量（dx）
  final ValueChanged<double> onDrag;

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
        },
        onHorizontalDragUpdate: (details) {
          widget.onDrag(details.delta.dx);
        },
        onHorizontalDragEnd: (_) {
          setState(() {
            _isDragging = false;
          });
        },
        child: Container(
          width: 6,
          color: _getColor(context),
        ),
      ),
    );
  }
}
