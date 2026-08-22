import 'dart:async';

import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/ssh_executor_service.dart';
import '../../io/websocket_service.dart';
import '../widgets/agent_list.dart';
import '../widgets/create_agent_dialog.dart';
import '../widgets/file_panel.dart';
import '../widgets/message_panel.dart';
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

  // 当前选中的 Agent（未选择时为 null）
  Agent? _selectedAgent;

  // 消息面板刷新触发器（递增触发 MessagePanel 重新加载历史）
  int _refreshTrigger = 0;

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
      );
      if (!mounted) return;
      setState(() {
        _agents.add(agent);
        _selectedAgent = agent;
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
  /// 若删除的是当前选中的 agent，则清除选中态，并注销其本地执行器，
  /// 避免删除/重建后旧注册残留导致新 agent 走错执行通道。
  Future<void> _handleDeleteAgent(Agent agent) async {
    try {
      await ApiService.deleteAgent(agent.id);
      if (!mounted) return;
      setState(() {
        _agents.removeWhere((a) => a.id == agent.id);
        if (_selectedAgent?.id == agent.id) {
          _selectedAgent = null;
          // 注销当前顶部 agent 的本地执行器（后端清注册，前端复位状态）
          LocalExecutorService.instance.unregister();
          LocalExecutorService.instance.setCurrentTopAgent('');
          // 注销当前顶部 agent 的 SSH 执行器（后端删除该 agent 的 SSH 配置）
          unawaited(SshExecutorService.instance.disable());
          SshExecutorService.instance.setCurrentTopAgent('');
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
        // 左栏：Agent 列表（折叠或展开）
        if (_leftCollapsed)
          _buildCollapsedLeftBar()
        else ...[
          SizedBox(
            width: _leftWidth,
            child: _buildAgentPanel(),
          ),
          // 拖拽分隔条 1（控制左栏宽度）
          DraggableDivider(
            onDrag: (delta) {
              setState(() {
                _leftWidth = (_leftWidth + delta)
                    .clamp(_leftMinWidth, _leftMaxWidth)
                    .toDouble();
              });
            },
          ),
        ],
        // 中栏：消息交互（弹性宽度）
        Expanded(
          child: MessagePanel(
            selectedAgent: _selectedAgent,
            refreshTrigger: _refreshTrigger,
          ),
        ),
        // 右栏：文件管理（折叠或展开）
        if (_rightCollapsed)
          _buildCollapsedRightBar()
        else ...[
          // 拖拽分隔条 2（控制右栏宽度）
          DraggableDivider(
            onDrag: (delta) {
              setState(() {
                // 右栏分隔条向右拖拽（delta 为正）时，右栏宽度减小
                _rightWidth = (_rightWidth - delta)
                    .clamp(_rightMinWidth, _rightMaxWidth)
                    .toDouble();
              });
            },
          ),
          SizedBox(
            width: _rightWidth,
            child: _buildFilePanel(),
          ),
        ],
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
              '请先在左侧选择或创建一个 Agent',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return FilePanel(
      key: ValueKey(workspaceId),
      workspaceId: workspaceId,
      onCollapse: () {
        setState(() {
          _rightCollapsed = true;
        });
      },
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
                });
              },
              onClearHistory: _handleClearHistory,
              onDelete: _handleDeleteAgent,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建左栏标题栏（标题 + 设置/创建/折叠按钮）
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
          // 设置入口
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
            color: cs.primary,
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
            child: RotatedBox(
              quarterTurns: 1,
              child: Center(
                child: Text(
                  'Agent 列表',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
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
            child: RotatedBox(
              quarterTurns: 1,
              child: Center(
                child: Text(
                  '文件管理',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
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
