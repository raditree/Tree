import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../models/agent.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../../io/api_service.dart';
import '../../io/attachment_upload_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../../io/question_update_service.dart';
import '../../io/ssh_executor_service.dart';
import '../../io/websocket_service.dart';
import '../../io/workspace_refresh_service.dart';
import '../services/conversation_view.dart';
import '../services/detail_selection.dart';
import '../services/message_replay_guard.dart';
import '../services/message_window.dart';
import '../services/onboarding_requests.dart';
import '../services/plugin_ui_registry.dart';
import '../services/session_rename.dart';
import '../services/subagent_transcript.dart';
import '../services/team_scope_view.dart';
import '../services/terminal_toggle_request.dart';
import '../services/usage_log_files.dart';
import 'message_input.dart';
import 'message_list.dart';
import 'plugin_ui_slots.dart';
import 'mode_switch.dart';
import 'session_picker.dart';
import 'subagent_process_list.dart';
import 'subagent_view_switcher.dart';
import 'terminal_panel.dart';
import 'spec_panel.dart';
import 'ssh_config_dialog.dart';
import 'teammates_window_page.dart';
import 'usage_calls_panel.dart';

/// 消息交互面板（中栏）
///
/// 由标题栏、消息列表区与输入框区三部分组成：
/// - 标题栏显示当前选中 Agent 名称
/// - 消息列表区展示对话历史，支持流式追加
/// - 输入框区负责发送文本与附件
///
/// 未选择 Agent 时显示"请选择一个 Agent 开始对话"提示。
/// 发送消息时通过 WebSocket 推送至后端，接收消息时更新列表。
class MessagePanel extends StatefulWidget {
  /// 当前选中的 Agent（未选择时为 null）
  final Agent? selectedAgent;

  /// 外部触发刷新（如清空对话后递增），值变化时重新拉取历史
  final int refreshTrigger;

  /// 会话切换回调（选中/新建会话时触发，携带新的 session_id）
  final ValueChanged<String>? onSessionChanged;

  /// 定位目标消息 id（右侧「问题回复」导航触发）
  final String? navigateMessageId;

  /// 定位目标会话 id（与 [navigateMessageId] 配合）
  final String? navigateSessionId;

  /// 定位触发号：外部递增触发导航定位
  final int navigateTrigger;

  /// 成员配置变更后的回调（父页面重新拉取 agent 列表，刷新待处理成员红点）
  final VoidCallback? onAgentsChanged;

  /// 仅供测试：覆盖 `usage.jsonl` 的路径（`null` = 走正式入口，原样透传给
  /// [UsageLogFiles.readRecent] 的 `override`）。
  ///
  /// 为什么需要这个口子：账本路径来自握手的**数据根**
  /// （`CoreProcessLauncher.instance.coreDataRoot`），而握手只在真启动核心时发生——
  /// 组件测试里拿不到"读历史成功"的那条路，本字段把它补上（与该服务自带的
  /// `override`（"仅测试注入用"）是同一个用途，这里只是透传）。
  @visibleForTesting
  static String? debugUsageFileOverride;

  const MessagePanel({
    super.key,
    this.selectedAgent,
    this.refreshTrigger = 0,
    this.onSessionChanged,
    this.navigateMessageId,
    this.navigateSessionId,
    this.navigateTrigger = 0,
    this.onAgentsChanged,
  });

  @override
  State<MessagePanel> createState() => _MessagePanelState();
}

class _MessagePanelState extends State<MessagePanel> {
  /// 消息列表
  /// 消息窗口：整份会话流按**全局下标**寻址，只有视口附近与末尾一段是热的
  /// （用户 2026-10-04：「滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息」）。
  final MessageWindow _window = MessageWindow(pageSize: 200);

  /// 断线补发帧的「重播去重」闸（M9 §1.1 / Wave 3-H 待办 3）。
  ///
  /// 核心断线期间的广播帧会进补发队列、重连后原样重播（帧无 TTL、无序号）；
  /// 本闸按**消息 id** 挡住重复渲染：已封口（历史终稿 / 已 msg_end）的 id 不再
  /// 追加增量，列表里已有的 id 不再新建气泡。详见 [MessageReplayGuard]。
  final MessageReplayGuard _replayGuard = MessageReplayGuard();

  /// WebSocket 服务
  final WebSocketService _webSocket = WebSocketService();

  /// 是否处于终端模式（Ctrl+J）：输入框那块整体换成集成终端
  bool _terminalMode = false;

  /// 终端高度（像素；Ctrl+J 打开时按面板高的 40% 起步，可拖）
  double _terminalHeight = 260;

  /// 插件动作帧发送通道（Q12）：plugin_ui_action 经本面板的 WS 连接回核心。
  ///
  /// 存成字段（而不是每次现取 tear-off）是为了 dispose 时能用 identical 判断
  /// "通道还是不是自己装的"——重连/重建后不能把新面板的通道清掉。
  late final void Function(Map<String, dynamic> frame) _pluginActionSink =
      _webSocket.send;

  /// 是否已尝试连接 WebSocket（避免重复连接）
  bool _wsConnected = false;

  /// 消息版本号：消息列表每次结构性变化时递增，驱动 MessageList 滚动到底部
  int _scrollRevision = 0;

  /// 消息列表滚动模式标志：历史整批重载时置 true（MessageList 无动画直达
  /// 底部、迭代校正确保超长会话真正落底）；流式追加/增量更新时置 false
  /// （平滑滚动跟随）。
  bool _bottomJump = false;

  /// 定位目标消息 id（历史加载完成后消费，驱动 MessageList 定位滚动）
  String? _pendingScrollId;

  /// 定位目标会话 id（供 _loadSessions 优先选中目标会话）
  String? _pendingSessionId;

  /// MessageList 定位触发号
  int _scrollToRevision = 0;

  /// 定位目标消息 id（透传给 MessageList）
  String? _scrollToMessageId;

  /// 处于 working 状态的 agent 集合（用于标题栏显示状态与停止按钮）
  final Set<String> _workingAgents = <String>{};

  /// 处于 compacting（上下文压缩中）状态的 agent 集合（标题栏显示「压缩中」）
  final Set<String> _compactingAgents = <String>{};

  /// 是否正在等待用户回答 agent 的问题（AskUserQuestion）
  bool _asking = false;

  /// 本地运行模式是否启用
  bool _localEnabled = false;

  /// 本地后端工作目录
  String? _localWorkingDir;

  /// SSH 运行模式是否启用
  bool _sshEnabled = false;

  /// SSH 连接配置（host/port/...，供配置表单预填）
  Map<String, dynamic> _sshConfig = <String, dynamic>{};

  /// 当前运行模式：两态（M9 Q2 删除 cloud），**默认 local**。
  ///
  /// 只有明确配置了 SSH 才算远端执行，其余一律本机执行——"无执行器"不是一种
  /// 可选状态（进入页面/切 team 时会自动落本地，见 [_loadModeSettings]）。
  String get _currentMode => _sshEnabled ? 'ssh' : 'local';

  /// 切换运行模式时的防重入守卫（不再启动任何本地后端，仅防双击）
  bool _togglingMode = false;

  /// 当前顶部 agent 的对话是否已开始（发送首条消息后运行模式锁定，
  /// 防止因后端会话已绑定该模式的工具执行位置而出现模式切换"不生效"的困惑）
  bool _modeLocked = false;

  /// 各 agent 最近一次回复的 token 用量（agent_id -> usage）。
  /// 用于展示"当前上下文长度"（prompt_tokens / max_tokens）。
  final Map<String, Map<String, dynamic>> _usageByAgent =
      <String, Map<String, dynamic>>{};

  /// **逐调用**用量列表（当前 agent + 会话）：每一次调用留一行，喂给上下文条下面的
  /// 「本轮调用列表」（`UsageCallsPanel`）。
  ///
  /// 与 [_usageByAgent] 是**两份口径、互不影响**：那份"按 (agent, 会话) 只留最新"，
  /// 是「上下文长度」读数的依赖（一个字都不改）；这份"每一条都留一行"，回答的是
  /// "这一轮到底跑了几次、每次花了多少"。实时帧与账本（`usage.jsonl`）都能喂进来。
  final List<UsageCallView> _callUsages = <UsageCallView>[];

  /// 这份列表当前的归属（`agentId::sessionId`）与"账本读过没有"的记账：
  /// 同一个会话只读一次 `usage.jsonl`；换会话 / 换 agent 时连同列表一起清
  /// （见 [_clearWindow] / [_scheduleCallUsagesHistory]）。
  String _callUsagesKey = '';

  /// 账本读不到时的**可读原因**（空串 = 没出问题）。
  ///
  /// 只在"一条调用都没有"时作为空态显示——"读不到账本"（核心没给数据根 / 文件不存在 /
  /// IO 失败）与"这个会话还没调用过"必须分得开（见 [UsageHistoryRead.reason]）。
  String _callUsagesNote = '';

  /// 「本轮调用列表」最多展示**最近**多少次调用：长会话里"最近几次"才是有用的读数，
  /// 面板会把截断写进标题（`maxRows <= 0` 表示全显示，这里取一个有界的上限）。
  static const int _usageCallsMaxRows = 20;

  /// 当前 agent 的会话列表（多会话并行）
  List<ChatSession> _sessions = <ChatSession>[];

  /// 当前选中的会话（未加载时为 null，回退默认会话）
  ChatSession? _currentSession;

  /// 各 agent 上次浏览的会话 id（agent_id -> session_id）。
  /// 切换 agent 回来时恢复上次浏览的会话，而非回退默认会话。
  final Map<String, String> _lastSessionByAgent = <String, String>{};

  /// 当前会话 id（缺省为默认会话）
  String get _currentSessionId =>
      _currentSession?.sessionId ?? 'session_default';

  /// **正在看谁的对话**（用户 2026-10-04：「进 subagent 视角不新开窗口，借父 agent 窗口，
  /// 把对话数据与上下文长度条换成 subagent 的」）：空串 = 主会话；非空 = 那个临时员工
  /// （`sub_…`）的视角。
  ///
  /// 它是**视图状态**，不是会话：底下换的只是"显示谁的消息 + 用谁的上下文读数"，会话本身
  /// 没变——所以切会话 / 换 agent / 整表重拉时它必须清掉（见 [didUpdateWidget] 与
  /// [_handleSelectSession]）。
  String _viewSubagentId = '';

  /// 正在跑的**临时员工** id（帧里带 `subagent_id` 的那些）。
  ///
  /// 与 [_workingAgents] 分开：临时员工有独立的视角、也能被用户单独停止/追问
  /// （用户 2026-10-04），它的"工作中"不该混进任何真 agent 的状态里。
  final Set<String> _workingSubagents = <String>{};

  /// 一次拉多少条历史（**长会话只加载末尾一段**：用户 2026-10-04「会话太长时导入不能
  /// 直接划到底部；懒加载，长会话仅加载末尾一段」）。它就是窗口的页大小。
  static const int _historyPageSize = 200;

  /// 已加载的槽位离视口多远就淘汰（"仅缓存坐标附近的历史，其余均丢弃"：用户 2026-10-03）。
  ///
  /// 为什么从 400 收到 200：口径就是"只留窗口附近"，而且**已加载条目越少，
  /// "像素 ↔ 全局下标"的估算越准**（占位槽恒定 88px，已加载消息的真实高度才是误差来源）。
  static const int _cacheMargin = 200;

  /// 正在补的下标段（防同一段被并发拉两次）。
  final Set<String> _loadingGaps = <String>{};

  /// 补过但没补出东西来的段起点（服务端说"这里没有"）：不再反复要，免得空转。
  final Set<int> _barrenGaps = <int>{};

  /// 最近一次窗口回调报上来的视口区间（补页 / 淘汰的基准；-1 = 还没量出来）。
  int _visibleFrom = -1;
  int _visibleTo = -1;

  /// 视口**上方**补过页的次数：列表据此在布局阶段补一次滚动位置。
  int _padAboveStamp = 0;

  /// **本帧内容高度在"视口里/视口下方"变了**的标记（递增）：
  /// 补页落在视口里（横跨视口顶的那一份）或淘汰掉远处槽位时递增，
  /// 传给 [MessageList.contentShiftStamp] 让列表补一次滚动位置（A3/A2）。
  int _contentShiftStamp = 0;

  /// 刚定位过的那一页（淘汰时额外留着：它可能离视口很远，但用户正看着它）。
  MessageRange? _locateKeep;

  @override
  void initState() {
    super.initState();
    // Ctrl+J 的**全局**唤起：焦点不在中栏时由 MainPage 的「事件驿站」广播过来
    // （见 TerminalToggleRequest 的文档）。焦点在本面板里时走下面那层
    // CallbackShortcuts——内层先消费按键，所以两条路不会重复切换。
    TerminalToggleRequest.instance.addListener(_onTerminalToggleRequested);
    // 新手引导第 4 步「选择工作目录」：与左上角那颗目录按钮**同一条路径**（同一条校验、
    // 同一套"成员写团队 TOP"的口径），不另开一个选择器。
    WorkspacePickRequest.instance.addListener(_onWorkspacePickRequested);
    // Q12 插件布局：本面板的 WS 连接同时承载插件 UI 帧（manifest / update /
    // plugin_status 卸载），并作为 plugin_ui_action 的发送出口。
    PluginUiRegistry.instance.actionSender = _pluginActionSink;
    _webSocket.onMessage = _handleIncomingMessage;
    // 未知会话消息（Task 7 接收方会话保障）：msg_chunk/msg_end 携带不在
    // 已知列表中的 session_id 时自动创建本地会话条目，使被动接收
    // （跨 team 推送等）的消息在会话列表可见
    _webSocket.onUnknownSession = _ensureLocalSessionEntry;
    _syncKnownSessions();
    // 连接建立/重连时清空 working 集合：后端重启会清空其内存态 _active_tasks，
    // 若不清空，前端会残留旧的 working（无 API 调用却显示工作中）。
    // 清空后由后端在 WS 建立时补推真实的 agent_status（仍在工作的才重新标记）。
    _webSocket.onConnectionChange = (bool connected) {
      // 插件声明式 UI 由核心重放重建：断连时先清空注册表，避免"离线期间插件被停用 /
      // 条目被删除"留下的僵尸卡片与面板（详见 PluginUiRegistry.onConnectionChanged）。
      PluginUiRegistry.instance.onConnectionChanged(connected);
      if (connected && mounted) {
        setState(() {
          _workingAgents.clear();
          _compactingAgents.clear();
        });
        // 重连后刷新当前 agent 的运行模式显示（本地/SSH 写的是 agent 配置，
        // 不存在"重新注册执行器"这回事）。
        final String? curId = widget.selectedAgent?.id;
        if (curId != null && curId.isNotEmpty) {
          _ensureExecutorsReady(curId);
        }
      }
    };
    // 先恢复当前顶部 agent 的运行模式设置（仅供标题栏显示），再建立
    // WebSocket 连接；执行器注册由懒激活（发送前 ensureTeam）与重连
    // 恢复（syncRegisteredTeams）按 per-team 状态完成
    _initAsync();
    // 首次进入时若已选中 agent 则加载会话与历史
    if (widget.selectedAgent != null) {
      _loadSessions();
    }
  }

  /// 初始化：先加载当前顶部 agent 的运行模式设置，再连接 WebSocket
  Future<void> _initAsync() async {
    await _loadModeSettings();
    if (!mounted) return;
    await _connectWebSocket();
  }

  /// 加载当前顶部 agent 的本地/SSH 执行模式持久化设置（仅供 UI 显示）。
  ///
  /// per-team 模型下不再在此处做全量注册：注册由消息发送前的懒激活
  /// （[LocalExecutorService.ensureTeam] / [SshExecutorService.ensureTeam]）
  /// 与 WS 重连后的 syncRegisteredTeams 恢复负责；这里只把该 team 的持久化
  /// 设置读入服务内存并刷新标题栏的模式显示。加载完成后对当前 agent 补一次
  /// ensureTeam：进入会话（首次进入/切换 agent）时若启用了本地/SSH 执行器
  /// 而前端因进程重启丢了注册记忆，则自动补注册自愈（连接未就绪时静默跳过，
  /// 由 WS 连接建立后的同款 ensureTeam 兜底）。
  Future<void> _loadModeSettings() async {
    final String teamId = widget.selectedAgent?.id ?? '';
    // 运行模式与工作目录都是**团队级**的（2026-10-03 用户断言）：成员跟随团队 TOP
    // （核心口径见 team_workspace.dart；目录还会被核心镜像进成员自己的配置）。
    // 因此这里两份都读——自己那份 + 团队 TOP 那份——再合成显示：
    // - 模式：自己**显式**配了 SSH 就以自己为准（核心也是这个优先级），否则跟随 TOP；
    // - 工作目录：**只有 TOP 那份算数**（成员那份是核心写的镜像），所以优先显示 TOP 的
    //   目录；TOP 未配置时退回自己那份镜像——核心会把 TOP 的默认目录也镜像进来，
    //   成员页因此永远显示一个真实目录，而不是让用户去"重新选择工作目录"。
    final String ownerId =
        widget.selectedAgent?.teamScopeId ?? (teamId.isEmpty ? '' : teamId);
    final bool isMember = ownerId.isNotEmpty && ownerId != teamId;
    await Future.wait(<Future<void>>[
      LocalExecutorService.instance.loadTeamSettings(teamId),
      SshExecutorService.instance.loadTeamSettings(teamId),
      if (isMember) LocalExecutorService.instance.loadTeamSettings(ownerId),
      if (isMember) SshExecutorService.instance.loadTeamSettings(ownerId),
    ]);
    if (!mounted) return;
    // 竞态防护：等待期间已切换顶部 agent 时放弃本次恢复
    // （新切换会重新进入本函数，避免旧 agent 的显示状态误刷新）
    if (teamId != (widget.selectedAgent?.id ?? '')) return;
    final bool ownSsh = SshExecutorService.instance.isTeamEnabled(teamId);
    final bool ownerSsh =
        isMember && SshExecutorService.instance.isTeamEnabled(ownerId);
    final Map<String, dynamic> ownConfig = SshExecutorService.instance
        .teamConfig(teamId);
    final Map<String, dynamic> ownerConfig = isMember
        ? SshExecutorService.instance.teamConfig(ownerId)
        : ownConfig;
    final String ownDir = LocalExecutorService.instance.teamWorkingDirectory(
      teamId,
    );
    final String ownerDir = isMember
        ? LocalExecutorService.instance.teamWorkingDirectory(ownerId)
        : ownDir;
    // 合成口径集中在 TeamScopeView（纯函数，可单测）：模式"自己优先、否则跟随 TOP"、
    // 目录"只认 TOP 那份、TOP 未配置时退回成员镜像"。
    final TeamScopeView view = TeamScopeView.combine(
      isMember: isMember,
      memberHasSsh: ownSsh,
      teamHasSsh: ownerSsh,
      memberDir: ownDir,
      teamDir: ownerDir,
      memberSshConfig: ownConfig,
      teamSshConfig: ownerConfig,
    );
    setState(() {
      _sshEnabled = view.ssh;
      _localEnabled = view.local;
      _sshConfig = view.sshConfig;
      _localWorkingDir = view.workingDir;
    });
    if (teamId.isNotEmpty) {
      // 两态模型下不允许停在"无执行器"（M9 Q2）：进入页面/切换 team 后若两个
      // 执行器都未启用，自动落回本地执行器
      if (!_localEnabled && !_sshEnabled) {
        await _enableLocalFallback(teamId);
      }
      _ensureExecutorsReady(teamId);
    }
  }

  /// 自动落本地执行器（M9 Q2 删除 cloud 后的兜底）。
  ///
  /// 桌面上"本地执行器"等价于"该 agent 未配置 SSH"（见 LocalExecutorService），
  /// 因此写入本地模式**不弹目录选择**：工作目录留空即用核心默认工作空间，免得
  /// 每次进入会话都弹一次选目录。写入失败（核心不可达）不报错打断进入——界面
  /// 仍按默认 local 显示，下次进入或发送前会重试。
  Future<void> _enableLocalFallback(String teamId) async {
    try {
      await LocalExecutorService.instance.setTeamEnabled(teamId, true);
    } catch (_) {
      // 核心不可达：保持默认 local 的显示，不做失败弹窗（用户没主动做任何操作）
    }
    if (!mounted) return;
    // 竞态防护：等待期间已切换顶部 agent 时放弃本次回写
    if (teamId != (widget.selectedAgent?.id ?? '')) return;
    setState(() {
      _localEnabled = LocalExecutorService.instance.isTeamEnabled(teamId);
      _localWorkingDir = LocalExecutorService.instance.teamWorkingDirectory(
        teamId,
      );
      _sshEnabled = SshExecutorService.instance.isTeamEnabled(teamId);
    });
  }

  @override
  void didUpdateWidget(covariant MessagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 右侧「问题回复」导航定位触发：记录待消费的定位目标
    final bool navTriggered =
        oldWidget.navigateTrigger != widget.navigateTrigger &&
        widget.navigateMessageId != null &&
        widget.navigateMessageId!.isNotEmpty;
    if (navTriggered) {
      _pendingScrollId = widget.navigateMessageId;
      _pendingSessionId = widget.navigateSessionId;
    }

    // 切换 Agent 或外部触发刷新时清空消息列表并加载历史
    if (oldWidget.selectedAgent?.id != widget.selectedAgent?.id) {
      // 详情是「某个 agent 的某条消息」：换 agent 就作废，右栏不留上一个的残留
      DetailSelection.instance.clear();
      // 临时员工只活在会话里：换 agent 时它们的"过程分栏"也一起清掉
      SubagentTranscript.instance.clear();
      // 终端绑在「当前 agent 的工作区」上：换 agent 就退出终端模式（面板 dispose
      // 时会发 terminal_close，核心收掉那个 shell）
      _terminalMode = false;
      setState(() {
        _clearWindow();
        _sessions = <ChatSession>[];
        _currentSession = null;
        _usageByAgent.clear();
        // 临时员工只活在会话里：换 agent 连"正在看谁"一起回到主会话
        _viewSubagentId = '';
        // 切换顶部 agent 后解除锁定，由新 agent 的历史/首条消息重新决定
        _modeLocked = false;
        // 导航定位目标属于旧 agent，切换后作废，避免残留误用
        _pendingScrollId = null;
        _pendingSessionId = null;
      });
      // 已知会话基线属于旧 agent：先清空，待新 agent 会话列表加载后重建
      _webSocket.clearKnownSessions();
      _loadSessions();
      // 切换顶部 agent：加载其独立的运行模式设置（仅供显示，不注册）
      _loadModeSettings();
    } else if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      // 历史被整表重拉：旧消息对象随即作废，详情跟着清
      DetailSelection.instance.clear();
      SubagentTranscript.instance.clear();
      setState(() {
        _clearWindow();
        // 整表重拉 = 过程分栏重建：正在看的那个临时员工可能已经不在这一屏里了
        _viewSubagentId = '';
      });
      _loadHistory();
    } else if (navTriggered) {
      // 同 agent 定位：按目标会话切换（若不同）后加载历史并定位
      final String? targetSession = widget.navigateSessionId;
      if (targetSession != null &&
          targetSession.isNotEmpty &&
          targetSession != _currentSessionId) {
        final ChatSession? ts = _sessions
            .where((ChatSession s) => s.sessionId == targetSession)
            .cast<ChatSession?>()
            .firstWhere((ChatSession? s) => s != null, orElse: () => null);
        setState(() {
          _currentSession = ts;
          _clearWindow();
        });
        widget.onSessionChanged?.call(targetSession);
        _loadHistory();
      } else if (_window.isEmpty) {
        _loadHistory();
      } else {
        _consumePendingScroll();
      }
    }
  }

  /// 消费定位目标：先在窗口里把目标那一段补回来（见 [_locateMessage]），
  /// 再递增 MessageList 的定位触发号驱动滚动。
  void _consumePendingScroll() {
    final String? id = _pendingScrollId;
    if (id == null || id.isEmpty) return;
    _pendingScrollId = null;
    unawaited(_locateMessage(id));
  }

  /// 同步当前 agent 的已知会话 id 到 WebSocketService（未知会话判定基线）。
  void _syncKnownSessions() {
    _webSocket.clearKnownSessions();
    _webSocket.registerKnownSessions(
      _sessions.map((ChatSession s) => s.sessionId),
    );
    _webSocket.registerKnownSessions(<String>[_currentSessionId]);
  }

  /// 未知会话自动建条（Task 7.2 前端兜底）。
  ///
  /// 由 WebSocketService.onUnknownSession 触发（msg_chunk/msg_end 携带未知
  /// session_id）：若消息属于当前选中 agent 且该会话不在列表中，则插入
  /// 本地会话条目（标题取首条消息摘要或"新会话"），使该会话可见、切换
  /// 后可加载历史。后端同时会落库并推送 session_created，权威列表重载时
  /// 以服务端为准。
  void _ensureLocalSessionEntry(Map<String, dynamic> data) {
    if (!mounted) return;
    final String agentId = (data['agent_id'] as String?) ?? '';
    final String sessionId = (data['session_id'] as String?) ?? '';
    if (sessionId.isEmpty) return;
    final Agent? agent = widget.selectedAgent;
    if (agent == null || agentId != agent.id) return;
    if (_sessions.any((ChatSession s) => s.sessionId == sessionId)) return;
    final String chunk = ((data['chunk'] as String?) ?? '').trim();
    final String title = chunk.isNotEmpty
        ? (chunk.length > 30 ? '${chunk.substring(0, 30)}…' : chunk)
        : '新会话';
    setState(() {
      _sessions.insert(0, ChatSession(sessionId: sessionId, title: title));
    });
    _webSocket.registerKnownSessions(<String>[sessionId]);
  }

  /// 处理后端 session_created 推送（Task 7.2 接收方会话保障）：
  /// 后端为接收 agent 创建会话元数据后即时纳入当前列表。
  void _handleSessionCreated(Map<String, dynamic> data) {
    if (!mounted) return;
    final Map<String, dynamic> d =
        (data['data'] as Map<String, dynamic>?) ?? data;
    final String agentId = (d['agent_id'] as String?) ?? '';
    final String sessionId = (d['session_id'] as String?) ?? '';
    if (sessionId.isEmpty) return;
    final Agent? agent = widget.selectedAgent;
    if (agent == null || agentId != agent.id) return;
    if (_sessions.any((ChatSession s) => s.sessionId == sessionId)) return;
    setState(() {
      _sessions.insert(
        0,
        ChatSession(
          sessionId: sessionId,
          title: (d['title'] as String?) ?? '新会话',
        ),
      );
    });
    _webSocket.registerKnownSessions(<String>[sessionId]);
  }

  /// 处理后端 `session_renamed` 推送（点位化新增）：
  /// 执行站命令 `session.rename` 由**插件**发起，前端没有"自己 setState"这条路径，
  /// 只能靠这条帧把会话列表里的标题改过来（否则要切走再切回才看得到新标题）。
  ///
  /// 变换逻辑在 [SessionRename]（纯函数，可直接单测）；这里只做 widget 侧的
  /// 取参、判空与 `setState`。
  void _handleSessionRenamed(Map<String, dynamic> data) {
    if (!mounted) return;
    final ({String agentId, String sessionId, String title}) payload =
        SessionRename.parse(data);
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final List<ChatSession>? next = SessionRename.apply(
      _sessions,
      currentAgentId: agent.id,
      agentId: payload.agentId,
      sessionId: payload.sessionId,
      title: payload.title,
    );
    if (next == null) return;
    setState(() {
      _sessions = next;
    });
  }

  /// 拉取当前 agent 的会话列表；切换会话时清空消息并重新加载历史
  Future<void> _loadSessions() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String agentId = agent.id;
    try {
      final List<ChatSession> sessions = await ApiService.getSessions(agent.id);
      if (!mounted) return;
      // 竞态防护：等待期间可能已切换 agent，丢弃过期响应
      // （否则旧 agent 的会话列表会覆盖新 agent，表现为"不稳定"）
      if (widget.selectedAgent?.id != agentId) return;
      setState(() {
        _sessions = sessions;
        // 运行模式按顶部 agent 级锁定：该 agent 任一历史会话有消息
        // 即视为「已开始过对话」，切换会话不解除锁定
        _modeLocked = sessions.any((s) => s.messageCount > 0);
        // 会话选择优先级：导航定位目标（一次性消费）> 该 agent 上次浏览
        // 的会话（_lastSessionByAgent）> 最近有消息的会话 > 列表首个。
        // 切换 agent 后 _currentSession 已清空，靠 _lastSessionByAgent
        // 恢复上次浏览的会话，而非回退默认会话。
        // 前端重启后 _lastSessionByAgent 丢失导致 prev 为空：此时若按原
        // 逻辑回退到 _currentSessionId（session_default），而默认会话
        // 无消息时（list_sessions 的兜底条目必然匹配），用户实际对话所在
        // 的非默认会话会被丢弃，compact/历史加载错位，误报
        // "该 agent 无活跃的会话上下文"。
        final String prev =
            _pendingSessionId ?? _lastSessionByAgent[agentId] ?? '';
        _pendingSessionId = null;
        ChatSession? target;
        if (prev.isNotEmpty) {
          final List<ChatSession> matched = sessions
              .where((ChatSession s) => s.sessionId == prev)
              .toList();
          if (matched.isNotEmpty) target = matched.first;
        }
        // 无明确目标（重启/首次进入/目标会话已删除）时：优先恢复最近
        // 有消息的会话，避免回退到空的默认会话导致会话错位
        target ??= _firstActiveSession(sessions);
        _currentSession =
            target ?? (sessions.isNotEmpty ? sessions.first : null);
        _clearWindow();
      });
      // 记录该 agent 本次实际生效的会话，供下次切换回来恢复
      _lastSessionByAgent[agentId] = _currentSessionId;
      // 会话列表已更新：同步未知会话判定基线
      _syncKnownSessions();
      _loadHistory();
      // 无论显式选会话还是自动选中，都把实际生效的会话 id 广播给
      // main_page -> FilePanel -> TodoPanel，保证"进入会话无 tool 调用"时
      // todo 也按当前会话隔离（否则 TodoPanel 会停留在旧的 session_default）
      if (mounted) {
        widget.onSessionChanged?.call(_currentSessionId);
      }
    } catch (e) {
      // 拉取失败时保持默认会话
    }
  }

  /// 会话列表（按最近更新倒序）中第一个有消息的会话。
  ///
  /// 用于前端重启/首次进入时恢复"上次实际对话所在会话"：list_sessions
  /// 始终兜底提供一个空的 session_default，若优先选中它会丢失用户真实
  /// 对话所在的非默认会话（compact/历史错位）。
  ChatSession? _firstActiveSession(List<ChatSession> sessions) {
    for (final ChatSession s in sessions) {
      if (s.messageCount > 0) return s;
    }
    return null;
  }

  /// 整表作废（换 agent / 换会话 / 清空历史）：窗口 + 封口闸 + 补页记账一起清。
  void _clearWindow() {
    _window.clear();
    _replayGuard.clear();
    _barrenGaps.clear();
    _loadingGaps.clear();
    _pendingWindow = null;
    _visibleFrom = -1;
    _visibleTo = -1;
    // 逐调用用量列表是**会话粒度**的：换了会话 / 换了 agent 就不是同一份账了，
    // 连同"读过账本没有"的记账一起清（历史由下一次 _loadHistory 重新读）。
    _callUsages.clear();
    _callUsagesKey = '';
    _callUsagesNote = '';
  }

  /// 从后端拉取当前 agent/会话的**末尾一段**历史，作为窗口的起点。
  ///
  /// 只取末尾 N 条（[MessageWindow.pageSize]）：长会话（几 MB 的 jsonl / 几千条消息）
  /// 导入不再是"全量读盘 + 全量建 widget + 再想办法滚到底"；用户滑到哪，再由
  /// [_onWindowChanged] 按**全局下标**补哪一段（滑到哪加载哪）。
  Future<void> _loadHistory() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String sessionId = _currentSessionId;
    // 逐调用用量列表：历史消息与用量账本同属"这个会话的过去"，顺手在这里补一次
    // （同一个 (agent, 会话) 只读一次，见 [_scheduleCallUsagesHistory]）
    _scheduleCallUsagesHistory(agent.id, sessionId);
    try {
      final HistoryPage page = await ApiService.getConversationHistoryPage(
        agent.id,
        sessionId: sessionId,
        limit: _historyPageSize,
      );
      if (!mounted) return;
      // 会话可能在等待期间被切换，丢弃过期的历史
      if (sessionId != _currentSessionId) return;
      final List<ChatMessage> tail = page.messages
          .map(ChatMessage.fromJson)
          .toList(growable: false);
      final String? pendingScroll = _pendingScrollId;
      _applyTailPage(page, tail, sessionId: sessionId, agent: agent);
      // 定位目标：历史加载完成后直接消费（面板会先把目标那一段拉回来）
      if (pendingScroll != null && pendingScroll.isNotEmpty) {
        _pendingScrollId = null;
        unawaited(_locateMessage(pendingScroll));
      }
    } catch (e) {
      // 拉取失败时静默处理（保持空列表）
    }
  }

  /// 把一份**末尾页**装进窗口（首屏 / 重载末尾一段共用）。
  ///
  /// 窗口里只留这一页 + 比它新的实时尾巴（见 [MessageWindow.resetTail]）：于是
  /// "回到最新"是确定性的——落点必然是最新消息，不靠估算高度。
  void _applyTailPage(
    HistoryPage page,
    List<ChatMessage> tail, {
    required String sessionId,
    required Agent agent,
  }) {
    setState(() {
      _window.resetTail(offset: page.offset, messages: tail);
      _window.ensureTotal(page.total);
      _loadingGaps.clear();
      _barrenGaps.clear();
      _locateKeep = null;
      _pendingWindow = null;
      _visibleFrom = -1;
      _visibleTo = -1;
      // 这批是**已关闭的段**（核心"段关闭即落库"）：全部封口——重播的
      // msg_start / msg_chunk 不许再长出第二条气泡。**累加**封口而不是替换：
      // 窗口只热视口附近，被淘汰的那些 id 也要认得出来（见 _hasMessage）。
      _replayGuard.sealAll(tail.map((ChatMessage m) => m.id));
      // 历史整批重建：驱动 MessageList 无动画直达底部（避免下滑动画）
      _bottomJump = true;
      _scrollRevision++;
      // 从历史中恢复 token 用量：取最后一条带 usage 的 agent 消息。
      // **只认主 agent 自己的消息**：临时员工的 usage 是它自己的上下文，
      // 混进来就把主 agent 的上下文长度统计带偏（用户 2026-10-04）。
      for (final ChatMessage m in _window.loadedList.reversed) {
        if (m.isSubagentMessage) continue;
        final Map<String, dynamic>? usage = m.usage;
        if (usage != null && usage.isNotEmpty) {
          _usageByAgent['${agent.id}::$sessionId'] = usage;
          break;
        }
      }
      // 临时员工的"过程分栏"跟着补全（合并语义：被淘汰的老过程也留着）
      SubagentTranscript.instance.sync(_window.loadedList);
    });
  }

  /// 「回到底部」= **重载末尾一段**（用户 2026-10-04：「回到底部按钮直接重载入历史」）。
  ///
  /// 为什么不滚到"估算的底部"：窗口里没加载的那一段每格都是占位高度，底在哪本来就
  /// 只是估算；重载末尾一页 = 把窗口换成一份**确定**的内容，落点必然是最新消息。
  Future<void> _reloadTail() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String sessionId = _currentSessionId;
    try {
      final HistoryPage page = await ApiService.getConversationHistoryPage(
        agent.id,
        sessionId: sessionId,
        limit: _historyPageSize,
      );
      if (!mounted || sessionId != _currentSessionId) return;
      _applyTailPage(
        page,
        page.messages.map(ChatMessage.fromJson).toList(growable: false),
        sessionId: sessionId,
        agent: agent,
      );
    } catch (e) {
      // 拉不到也让列表退回"贴底"：总比把用户按在一个不动的地方强
      if (!mounted) return;
      setState(() {
        _bottomJump = true;
        _scrollRevision++;
      });
    }
  }

  /// 列表把**视口坐标**报过来（每帧都可能报，见 `MessageList.onWindowChanged`）。
  ///
  /// 这里只记下"最新坐标"，真正干活的是 [_pumpWindowWork]：**同一时刻只跑一趟**，
  /// 滚动中反复触发只会不断覆盖待办。滚动丝滑靠两条：
  /// ① 视口附近已经加载好时，补页在 `MessageWindow.gapsFor` 那一步就是空
  ///    （零网络、零 setState）；
  /// ② 一趟里的请求是**串行**的（`await`），不会堆出一串并发请求。
  void _onWindowChanged(int first, int last) {
    if (first < 0 || last < first) return;
    _visibleFrom = first;
    _visibleTo = last;
    _pendingWindow = (first: first, last: last);
    unawaited(_pumpWindowWork());
  }

  /// 最新一次报上来的视口坐标（null = 没有待办）。
  ({int first, int last})? _pendingWindow;

  /// 有没有一趟正在跑。
  bool _windowWorkRunning = false;

  /// 一趟 = 按坐标补缺口 + 淘汰离得远的槽位；跑完再看有没有更新的坐标。
  ///
  /// **淘汰不与补页背靠背同帧**（A2）：两者都会改内容高度（补页让视口上方/视口里
  /// 长高，淘汰把远处的真消息换回 88px 占位槽），挤在同一帧里列表侧只能看到
  /// "净变化"，一次补偿里混进两种信号；而且淘汰可能把补偿锚点那一格换走，
  /// 让实测退化成估算。所以淘汰推到**补页之后的下一帧**（见 [_scheduleEvictAfterFrame]）。
  Future<void> _pumpWindowWork() async {
    if (_windowWorkRunning) return;
    _windowWorkRunning = true;
    try {
      while (mounted) {
        final ({int first, int last})? work = _pendingWindow;
        if (work == null) return;
        _pendingWindow = null;
        _visibleFrom = work.first;
        _visibleTo = work.last;
        await _fillWindow(work.first, work.last);
        if (!mounted) return;
        _scheduleEvictAfterFrame();
      }
    } finally {
      _windowWorkRunning = false;
    }
  }

  /// 这一个补页趟次是否已经把"淘汰"排到下一帧（同帧去重）。
  bool _evictScheduled = false;

  /// 把"淘汰"排到**补页之后的下一帧**（A2）。
  ///
  /// 为什么必须是**下一帧**：补页的 `setState` 会排一帧，postFrame 回调在那帧末执行 ⇒
  /// 淘汰的 `setState` 触发的是**再下一帧**，于是"这一帧只有补页"成为可断言的形状。
  /// 另外还要 `scheduleFrame()`：补页没放置任何东西时不会有帧，回调就永远不执行
  /// （淘汰会被无限推迟 ⇒ 缓存越攒越长）。
  void _scheduleEvictAfterFrame() {
    if (_evictScheduled) return;
    _evictScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _evictScheduled = false;
      if (!mounted) return;
      _evictFarSlots();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 把视口附近（[MessageWindow.gapsFor] 按 margin 外扩）缺的段补回来。
  ///
  /// **缺口在视口顶切开**（[splitGapAtViewportTop]）：横跨视口的缺口先补"视口及以下"
  /// （不改变视口上方高度 ⇒ 正在看的内容不动），再补"整段在视口上方"那份
  /// （走既有的 `padAboveStamp` 高度补偿）。否则视口上方由占位变实会长高，把用户
  /// 正在读的那一段整体推下去（用户 2026-10-03：「中间页的懒加载好像没做好」）。
  Future<void> _fillWindow(int first, int last) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String sessionId = _currentSessionId;
    for (final MessageRange gap in _window.gapsFor(first, last)) {
      for (final MessageRange request in splitGapAtViewportTop(gap, first)) {
        if (sessionId != _currentSessionId) return;
        if (_barrenGaps.contains(request.from)) continue;
        final String key = '${request.from}-${request.to}';
        if (!_loadingGaps.add(key)) continue;
        try {
          final HistoryPage page = await ApiService.getConversationHistoryPage(
            agent.id,
            sessionId: sessionId,
            from: request.from,
            limit: _window.pageSizeFor(request),
          );
          if (!mounted || sessionId != _currentSessionId) return;
          final List<ChatMessage> messages = page.messages
              .map(ChatMessage.fromJson)
              .toList(growable: false);
          setState(() {
            _window.ensureTotal(page.total);
            final int placed = _window.place(
              offset: page.offset,
              messages: messages,
            );
            // 视口**上方**补的页：占位槽换成真消息会改变上面的高度，让列表补一次
            if (page.offset + messages.length <= first) {
              _padAboveStamp++;
            } else {
              // 这一份**落在视口里**（面板故意先补横跨视口顶的 `[first, gap.to)`）：
              // 紧贴视口顶的那一格往往**自身就是**被换掉的那一格 ⇒ 它下面
              // 已经加载的内容会被整段推走。发 contentShiftStamp 让列表按实测
              // 锚点补回来（A3；列表侧口径见 MessageList.contentShiftStamp）。
              _contentShiftStamp++;
            }
            _replayGuard.sealAll(messages.map((ChatMessage m) => m.id));
            // 这一段补不出东西（对齐有偏差 / 服务端说没有）：记一笔，别再空转
            if (placed == 0) _barrenGaps.add(request.from);
            // 补页不是"整批重载"：别把 bottomJump 留在 true（否则用户正在读历史时
            // 一次补页会把他拽回底部）
            _bottomJump = false;
            _scrollRevision++;
          });
          SubagentTranscript.instance.sync(_window.loadedList);
        } catch (e) {
          // 补页失败：占位槽留着，用户再滑一下会重试（不当成"这里没有"）
        } finally {
          _loadingGaps.remove(key);
        }
      }
    }
  }

  /// 淘汰离视口太远的槽位（**限制缓存长度，仅缓存窗口附近的消息**）。
  ///
  /// 末尾一段与"正在流式 / 正在跑工具"的消息由 [MessageWindow.evict] 自己保；
  /// [_locateKeep]（刚定位过的那一页）也留着——它可能离视口很远，但用户正看着它。
  void _evictFarSlots() {
    if (_visibleFrom < 0) return;
    final MessageRange? locate = _locateKeep;
    final int removed = _window.evict(
      keep: MessageRange(
        _visibleFrom - _cacheMargin,
        _visibleTo + 1 + _cacheMargin,
      ),
      keepAlso: locate == null
          ? const <MessageRange>[]
          : <MessageRange>[locate],
    );
    if (removed == 0) return;
    setState(() {
      _bottomJump = false;
      // 淘汰同样改了内容高度（远处的真消息换回 88px 占位槽）：发一次补偿信号，
      // 让列表按实测锚点把"用户正在读的那一段"钉住（A2：淘汰独占这一帧）。
      _contentShiftStamp++;
      _scrollRevision++;
    });
    SubagentTranscript.instance.sync(_window.loadedList);
  }

  /// 定位到某条消息：它不在窗口里（早被淘汰 / 还没加载过）就先把它那一页拉回来
  /// （核心的 `at=` 寻址），再驱动列表滚动定位。
  Future<void> _locateMessage(String id) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final String sessionId = _currentSessionId;
    if (!_window.containsId(id)) {
      try {
        final HistoryPage page = await ApiService.getConversationHistoryPage(
          agent.id,
          sessionId: sessionId,
          atId: id,
          limit: _historyPageSize,
        );
        if (!mounted || sessionId != _currentSessionId) return;
        final List<ChatMessage> messages = page.messages
            .map(ChatMessage.fromJson)
            .toList(growable: false);
        setState(() {
          _window.ensureTotal(page.total);
          // 定位是"一次性跳转"：窗口直接换成目标那一段（+ 末尾实时尾巴），
          // 免得刚放进去就被淘汰、目标又没了
          _window.resetTail(offset: page.offset, messages: messages);
          _locateKeep = MessageRange(
            page.offset,
            page.offset + messages.length,
          );
          _replayGuard.sealAll(messages.map((ChatMessage m) => m.id));
          // 定位不是"回到底部"：窗口换了，但别贴底
          _bottomJump = false;
          _scrollRevision++;
        });
        SubagentTranscript.instance.sync(_window.loadedList);
      } catch (e) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _scrollToMessageId = id;
      _scrollToRevision++;
    });
  }

  /// 按工具名判定其影响的工作空间区域，决定右栏哪些 tab 需要增量刷新。
  ///
  /// 只读/会话管理/子代理分发等不变更文件与规范状态的工具返回空集，
  /// 避免每次工具结束右栏都会闪一下；其余未知工具保守归为文件区。
  Set<WorkspaceArea> _areasForToolName(String name) {
    switch (name) {
      case 'write':
      case 'edit':
        return {WorkspaceArea.files};
      case 'set_todo_list':
        return {WorkspaceArea.todo};
      case 'terminal':
        // 终端可能写文件，也可能执行 git 命令
        return {WorkspaceArea.files, WorkspaceArea.git};
      case 'read':
      case 'view':
      case 'cat':
      case 'show':
      case 'list':
      case 'search':
      case 'grep':
      case 'ask_user_question':
      case 'team':
        return {};
      default:
        if (name.startsWith('session_') ||
            name.startsWith('tool_') ||
            name.startsWith('member_') ||
            name.startsWith('help_') ||
            name.startsWith('web_') ||
            name.startsWith('mcp_')) {
          return {};
        }
        // 未知工具保守视为可能改文件
        return {WorkspaceArea.files};
    }
  }

  /// 建立 WebSocket 连接
  Future<void> _connectWebSocket() async {
    if (_wsConnected) return;
    final String? token = ApiService.token;
    if (token == null || token.isEmpty) return;
    _wsConnected = true;
    _webSocket.connect(token);
    // 连接建立后会同步触发 onConnectionChange(true)（见 initState）：
    // 在其中对"已注册且启用"的 team 恢复执行器注册，未激活的 team 不注册
  }

  /// 处理后端推送的消息
  ///
  /// 文本消息按段渲染：`msg_start` 创建、`msg_chunk` 追加、`msg_end` 结束。
  /// 工具调用按卡片渲染：`tool_start` 创建、`tool_end` 更新结果。
  /// 另处理 `agent_status`（working/idle）、`ask_user_question`（提问卡片）、
  /// `msg_usage`（token 用量）。
  void _handleIncomingMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    // Q12 插件布局帧先行分流：manifest / update / plugin_status(destroyed)
    // 由槽位注册表消费（按 team 过滤 + 槽位生命周期），不落到下面的消息分支。
    if (PluginUiRegistry.instance.handleFrame(data)) return;
    final String? type = data['type'] as String?;

    // 账本会在**没有对话帧**的时刻增长：压缩那两路（内置 `compact` / 插件中转经执行站
    // `llm.call`）都是核心内部或**插件进程**发起的调用，只写 `usage.jsonl`、不发对话帧
    // ⇒ 实时行入口（[_appendCallUsage] 那条路）永远收不到它们。
    // `llm_hidden` 系统提示帧（"上下文已压缩（来源：…）"这类，自动与手动压缩都会来）
    // 就是"发生了帧之外的事"的权威信号 ⇒ 重读一次账本尾部
    // （见 [_refreshCallUsagesHistory]；用户 2026-10-03 报告「压缩用的 LLM 没计进列表」）。
    if (_isLlmHiddenFrame(data)) _refreshCallUsagesHistory();

    if (type == 'msg_start') {
      if (!_isForCurrentAgent(data) || !_isForCurrentSession(data)) return;
      final ChatMessage message = ChatMessage(
        id: data['id'] as String? ?? '',
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
        kind: data['kind'] as String? ?? 'text',
        // 临时员工的话：打标显示在它名下（agent_id 仍是会话主人，过滤口径不变）
        subagentId: data['subagent_id'] as String? ?? '',
        subagentName: data['subagent_name'] as String? ?? '',
        subagentParentId: data['subagent_parent_id'] as String? ?? '',
        subagentLevel: (data['subagent_level'] as num?)?.toInt() ?? 0,
      );
      if (message.id.isEmpty) return;
      // 重播去重：同 id 已经在列表里（历史终稿 / 本端已在流式）⇒ 不再建第二条。
      // 否则同一个 id 会出现两个气泡，后续增量只打进第一条，第二条永久空转。
      if (!_replayGuard.shouldCreateMessage(
        id: message.id,
        exists: _hasMessage(message.id),
      )) {
        debugPrint('[消息] 忽略重播的 msg_start（同 id 已存在）: ${message.id}');
        return;
      }
      setState(() {
        _window.appendTail(message);
        _scrollRevision++;
        // 流式新增：平滑滚动跟随（历史整批重载才走直达底部）
        _bottomJump = false;
      });
    } else if (type == 'msg_chunk') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final String chunk = (data['chunk'] as String?) ?? '';
      final int idx = _indexOfMessage(id);
      // 单调序号（M9 去重判据）：新核心给每条 msg_chunk 带同一 id 内严格递增的
      // seq（缺字段 = 老核心 ⇒ null = 未知，退回 id 级判据），见 WsStreamSeq。
      final int? seq = WsStreamSeq.of(data);
      // 重播去重：已封口的 id（历史终稿 / 已 msg_end）不再追加；序号不大于已消费
      // 水位的增量 = 已经渲染过的同一片段被重播（断线补发重播的主要形态）；
      // 没有对应消息的孤立增量同样丢弃（既有行为）。
      if (!_replayGuard.shouldAppendChunk(id: id, exists: idx >= 0, seq: seq)) {
        debugPrint(
          '[消息] 丢弃增量（'
          '${_replayGuard.describe(id: id, exists: idx >= 0, seq: seq)}）: $id',
        );
        return;
      }
      setState(() {
        _window.at(idx)!.content += chunk;
      });
      // 判据与记账成对：**放行的这一帧**就是"已消费到的高水位"。放在真正写入
      // 之后，保证水位只描述"正文里确实有的内容"。
      _replayGuard.markConsumed(id: id, seq: seq);
    } else if (type == 'msg_end') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final int idx = _indexOfMessage(id);
      // 段关闭即封口：核心保证 msg_end 之前已 flush 全部增量（帧序有保证），
      // 此后该 id 的正文即终稿 ⇒ 再来 msg_chunk 一律是重播。
      _replayGuard.seal(id);
      // msg_end 的 seq 是**封口水位**（本段最后一条增量帧的序号，老核心不带）。
      // ① 把水位一并推进：即使封口集合被历史整批重建清掉，更老的重播帧仍被挡住；
      // ② 位次对不上 = 断线期间确实丢了增量帧（补发队列溢出 / 连接异常），
      //    显式记一笔——正文补不回来，但绝不静默。
      final int? sealSeq = WsStreamSeq.of(data);
      if (sealSeq != null) {
        final int consumed = _replayGuard.lastConsumedSeq(id) ?? -1;
        if (consumed != sealSeq) {
          debugPrint(
            '[消息] 段封口水位 $sealSeq，本端已消费 $consumed（差 '
            '${sealSeq - consumed} 帧，断线期间丢失的增量）: $id',
          );
        }
        _replayGuard.markConsumed(id: id, seq: sealSeq);
      }
      if (idx >= 0) {
        final Map<String, dynamic>? usage =
            (data['usage'] as Map<String, dynamic>?)?.cast<String, dynamic>();
        setState(() {
          _window.at(idx)!.isStreaming = false;
          _window.at(idx)!.usage = usage;
          _scrollRevision++;
          _bottomJump = false;
          if (usage != null) {
            _recordUsage(data, usage);
            // 逐调用列表是另一份口径（每次一行），与上面"只留最新"互不影响
            _appendUsageCall(UsageCallView.fromUsage(usage));
          }
        });
      }
    } else if (type == 'msg_usage') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final Map<String, dynamic>? usage =
          (data['usage'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      final int idx = _indexOfMessage(id);
      if (idx >= 0) {
        setState(() {
          _window.at(idx)!.usage = usage;
          if (usage != null) {
            _recordUsage(data, usage);
            // 逐调用列表：每次调用留一行（缓存的文字消息也照收）
            _appendUsageCall(UsageCallView.fromUsage(usage));
          }
        });
      } else if (usage != null) {
        // 会话粒度推进：工具循环中推送的 usage 没有对应文本消息（id 是工具卡片），
        // 仍要记录，使上下文统计持续更新
        _recordUsage(data, usage);
        // 同上：这份读数也要在「本轮调用列表」里占一行
        _appendUsageCall(UsageCallView.fromUsage(usage));
        if (mounted) setState(() {});
      }
    } else if (type == 'tool_start') {
      if (!_isForCurrentAgent(data) || !_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      if (id.isEmpty) return;
      // 重播去重：同一工具卡片 id 已有卡片时不再新建（重播帧的 tool_end 会照旧
      // 填到既有卡片上，是幂等的）。
      if (!_replayGuard.shouldCreateMessage(
        id: id,
        exists: _indexOfMessage(id) >= 0,
      )) {
        debugPrint('[消息] 忽略重播的 tool_start（同 id 已存在）: $id');
        return;
      }
      final Map<String, dynamic>? args =
          (data['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>();
      final ChatMessage toolMsg = ChatMessage(
        id: id,
        role: 'agent',
        content: '',
        timestamp: DateTime.now(),
        kind: 'tool',
        toolName: (data['name'] as String?) ?? '',
        toolArguments: args,
        toolRunning: true,
        // 临时员工调的工具也打标：一行式消息流里能看出这一步是谁干的
        subagentId: data['subagent_id'] as String? ?? '',
        subagentName: data['subagent_name'] as String? ?? '',
        subagentParentId: data['subagent_parent_id'] as String? ?? '',
        subagentLevel: (data['subagent_level'] as num?)?.toInt() ?? 0,
      );
      setState(() {
        _window.appendTail(toolMsg);
        _scrollRevision++;
        _bottomJump = false;
      });
    } else if (type == 'tool_end') {
      if (!_isForCurrentSession(data)) return;
      final String id = (data['id'] as String?) ?? '';
      final int idx = _indexOfMessage(id);
      if (idx >= 0) {
        setState(() {
          _window.at(idx)!.toolRunning = false;
          _window.at(idx)!.toolResult = (data['result'] as String?) ?? '';
        });
      }
      // 工具执行结束：按工具类型增量通知右栏刷新对应区域（文件/Git/Todo）。
      // 只读类工具不触发，避免每次工具结束右栏都闪一下。
      final Set<WorkspaceArea> areas = _areasForToolName(
        (data['name'] as String?) ?? '',
      );
      if (areas.isNotEmpty) {
        WorkspaceRefreshService.instance.notifyWorkspaceChanged(areas);
      }
    } else if (type == 'agent_status') {
      final Map<String, dynamic> d =
          (data['data'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
          {};
      final String? agentId = d['agent_id'] as String?;
      final String? status = d['status'] as String?;
      if (agentId == null) return;
      // 临时员工的帧带它自己的标记（agent_id 仍是会话主人）：单独记一份，中栏的
      // "临时员工视角"据此决定右下角是停止键还是发送键（用户 2026-10-04）
      final String subagentId = (d['subagent_id'] as String?) ?? '';
      // 离开 compacting = 这一轮压缩结束（内置与中转站都算）：用量此刻已落账。
      // 提示帧是主信号，这里只是兜底（旧核心 / 通知被吞时），见 [_refreshCallUsagesHistory]。
      final bool wasCompacting = _compactingAgents.contains(agentId);
      setState(() {
        if (status == 'working') {
          _workingAgents.add(agentId);
          _compactingAgents.remove(agentId);
          if (subagentId.isNotEmpty) _workingSubagents.add(subagentId);
        } else if (status == 'compacting') {
          _compactingAgents.add(agentId);
          if (subagentId.isNotEmpty) _workingSubagents.add(subagentId);
        } else if (status == 'idle' || status == 'stopping') {
          _workingAgents.remove(agentId);
          _compactingAgents.remove(agentId);
          if (subagentId.isNotEmpty) _workingSubagents.remove(subagentId);
        }
      });
      if (wasCompacting && status != 'compacting') _refreshCallUsagesHistory();
    } else if (type == 'ask_user_question') {
      _handleAskUserQuestion(data);
    } else if (type == 'ask_user_question_resolved') {
      // 右栏作答后，中栏对应内联卡片即时置灰
      final String qid = (((data['data'] as Map?)?['id']) as String?) ?? '';
      if (qid.isNotEmpty) {
        final int idx = _indexOfMessage(qid);
        if (idx >= 0) {
          setState(() {
            _window.at(idx)!.answered = true;
          });
        }
      }
    } else if (type == 'message') {
      if (!_isForCurrentAgent(data) || !_isForCurrentSession(data)) return;
      // 完整 agent 消息（如后端 _send_text_as_agent 发送的错误提示）
      final ChatMessage message = ChatMessage.fromJson(data);
      // 重播去重：诊断类 message 帧（_sendAdvisory）**不落库**，历史里没有，
      // 若重播帧再走一遍就会多出一条一模一样的系统提示；空 id 保持既有行为。
      if (message.id.isNotEmpty &&
          !_replayGuard.shouldCreateMessage(
            id: message.id,
            exists: _hasMessage(message.id),
          )) {
        debugPrint('[消息] 忽略重播的 message 帧（同 id 已存在）: ${message.id}');
        return;
      }
      setState(() {
        _window.appendTail(message);
        _scrollRevision++;
        _bottomJump = false;
      });
    } else if (type == 'session_created') {
      // 接收方会话保障（Task 7.2）：后端为接收 agent 新建会话后即时入列
      _handleSessionCreated(data);
    } else if (type == 'session_renamed') {
      // 点位化：插件经执行站 `session.rename` 改名后，标题要即时更新
      _handleSessionRenamed(data);
    }
    // 其余控制消息（file_sync_progress / heartbeat / error 等）忽略
    //
    // 每处理完一帧就把"临时员工的过程"重算一次：它们的消息不进主消息流，而是按
    // subagent_id 收在 [SubagentTranscript] 里，正在看某个临时员工详情的界面据此实时跟进
    // （消息对象是共享引用，流式增量原地改内容，所以这里重算索引就够）。
    SubagentTranscript.instance.sync(_window.loadedList);
  }

  /// 消息在列表中的下标（-1 = 不存在；空 id 一律视为不存在）。
  int _indexOfMessage(String id) => id.isEmpty ? -1 : _window.indexOfId(id);

  /// 本端是不是**已经有**这条消息，或者**认得**它（历史里出现过、但槽位早被淘汰）。
  ///
  /// 为什么要认得：窗口只热视口附近（"限制缓存长度"），被淘汰的 id 上重播
  /// `msg_start` / `tool_start` 会凭空多出一条气泡——正文却在历史里。封口集合是
  /// **累加**的（见 _applyTailPage / _fillWindow 的 sealAll），正好能认出它们。
  bool _hasMessage(String id) =>
      _indexOfMessage(id) >= 0 || _replayGuard.isSealed(id);

  /// 判断消息是否属于当前选中的 agent（避免工作中的成员消息污染主面板）
  bool _isForCurrentAgent(Map<String, dynamic> data) {
    final String? agentId = data['agent_id'] as String?;
    if (agentId == null) return true;
    final Agent? agent = widget.selectedAgent;
    return agent != null && agent.id == agentId;
  }

  /// 判断消息是否属于当前选中的会话（避免其他会话的流式输出污染当前面板）
  bool _isForCurrentSession(Map<String, dynamic> data) {
    final String? sessionId = data['session_id'] as String?;
    if (sessionId == null) return true; // 兼容后端未携带 session_id 的旧消息
    return sessionId == _currentSessionId;
  }

  /// 记录 token 用量：按 (agent, 会话) 粒度存储，切换会话后互不影响。
  ///
  /// **临时员工（subagent）的帧不记账**：它的 `agent_id` 是会话主人（帧归属口径如此），
  /// 但那份 `prompt_tokens` 描述的是**它自己**的上下文——记到主人头上会让
  /// 「上下文长度」这条读数被临时员工来回污染（用户 2026-10-04）。
  void _recordUsage(Map<String, dynamic> data, Map<String, dynamic> usage) {
    final String subagentId = (data['subagent_id'] as String?) ?? '';
    if (subagentId.isNotEmpty) return;
    final String agentId = (data['agent_id'] as String?) ?? '';
    final String sessionId =
        (data['session_id'] as String?) ?? _currentSessionId;
    _usageByAgent['$agentId::$sessionId'] = usage;
  }

  /// 追加一条**实时帧**的用量（`msg_usage` / `msg_end` 的 `usage` map）。
  ///
  /// 与 [_recordUsage] 是并行的两条路，而不是复用它：后者"只留最新"（上下文长度读数），
  /// 这里每一次调用都要留一行。**弱去重**（见 [_usageCallKey] / [_indexOfTwin]）：
  /// - 同一次调用先推 `msg_usage`、再在 `msg_end` 里带一份字段完全相同的 `usage` ⇒ 只留一条；
  /// - 断线补发把同一帧重播回来、而这次调用**已经落进账本**（列表里已有带 `at` 的那一行）
  ///   ⇒ 就地补全既有行，不新增一行（否则"这一轮"会被数成两次）。
  ///
  /// **临时员工（subagent）的帧也照收**：它的 `agent_id` 虽然是会话主人，但这是一次
  /// 真实的 LLM 调用、真实的花费，属于"这一轮花了多少"的一部分；而 [_recordUsage] 不收
  /// 它是因为那份 `prompt_tokens` 描述的是它自己的上下文，混进去会把上下文长度带偏——
  /// 两者是不同的问题（若要改成同口径，在这里加一行 `subagent_id` 判断即可）。
  void _appendUsageCall(UsageCallView call) {
    // ① 同键 = 同一次调用的两份读数（at 与来源/输入/输出都一样）
    if (_indexOfUsageCall(call) >= 0) return;
    // ② 孪生 = 一边有 at、一边没有（实时帧没有 at，账本行有）：合成一行，别数两次
    final int twin = _indexOfTwin(call);
    if (twin >= 0) {
      _callUsages[twin] = _fillMissing(_callUsages[twin], call);
      return;
    }
    _callUsages.add(call);
  }

  /// 弱去重键：`(at, source, prompt_tokens, completion_tokens)`。
  ///
  /// 口径取 `at + source + prompt_tokens`，**并列**带上 `completion_tokens`：实时帧没有
  /// `at`（键里恒为空串），同来源、输入相同但输出不同的两次调用是**两次真实调用**，
  /// 不该被合成一行；而真正重复的帧（同一次调用的两份读数）四个字段完全一致，照样只剩一条。
  static String _usageCallKey(UsageCallView call) =>
      '${call.at?.toUtc().toIso8601String() ?? ''}|${call.source}|'
      '${call.promptTokens}|${call.completionTokens}';

  /// 列表里同键条目的下标（-1 = 没有）。
  int _indexOfUsageCall(UsageCallView call) {
    final String key = _usageCallKey(call);
    for (int i = 0; i < _callUsages.length; i++) {
      if (_usageCallKey(_callUsages[i]) == key) return i;
    }
    return -1;
  }

  /// 列表里的"孪生"行：来源 + 输入 + 输出都对得上，且**两边只有一边**有时间戳。
  ///
  /// 为什么要认这一对：实时帧不带 `at` / `duration_ms`，账本行带——它们描述的是同一次
  /// 调用（实时帧可能被断线补发重播，也可能这次调用已经落进账本）。认出来就**合成一行**
  /// （见 [_fillMissing]）而不是让"这一轮"多算一次；两边都有时间戳的是账本里两次真调用，
  /// 不算孪生。
  int _indexOfTwin(UsageCallView call) {
    for (int i = 0; i < _callUsages.length; i++) {
      final UsageCallView row = _callUsages[i];
      if (row.source != call.source) continue;
      if (row.promptTokens != call.promptTokens) continue;
      if (row.completionTokens != call.completionTokens) continue;
      if (row.at != null && call.at != null) continue;
      return i;
    }
    return -1;
  }

  /// 把 [extra] 有的、[base] 缺的字段补上（`at` / `duration_ms` / `cached_tokens` / 模型名）。
  ///
  /// `null ≠ 0` 的字段（`cached_tokens` / `duration_ms` / `at`）只补 `null` 的那些；
  /// 计数与来源以 [base] 为准（孪生的两边本来就相同）。
  UsageCallView _fillMissing(UsageCallView base, UsageCallView extra) {
    return UsageCallView(
      source: base.source,
      model: base.model.isEmpty ? extra.model : base.model,
      promptTokens: base.promptTokens,
      cachedTokens: base.cachedTokens ?? extra.cachedTokens,
      completionTokens: base.completionTokens,
      // 两边只要有一边标了"估算"，这一行就是估算值
      estimated: base.estimated || extra.estimated,
      durationMs: base.durationMs ?? extra.durationMs,
      at: base.at ?? extra.at,
    );
  }

  /// 作废"这个会话只读过一次账本"的记账，并立刻重读一次（账本尾部 50 行）。
  ///
  /// 为什么必须有它：账本会在**没有对话帧**的时刻增长 —— 压缩的内置 `compact` 走核心自己的
  /// 总结器、插件中转经执行站 `llm.call`，两者都只写账本、不发对话帧，所以
  /// [_appendUsageCall]（实时行入口）永远看不到它们。若只在挂载时读一次，用户点了压缩、
  /// 账本明明多了一行，界面上却永远是「本轮调用列表（0 次）」——用户 2026-10-03 的真机报告。
  ///
  /// 两个触发信号（都在既有帧里，不新增协议）：
  /// - `llm_hidden` 系统提示帧（[_isLlmHiddenFrame]）：`_notifyCompacted` 落库的那条
  ///   "上下文已压缩（来源：…）"，**自动与手动压缩都会来** ⇒ 主信号；
  /// - `agent_status` 离开 `compacting` 那一刻（[_handleIncomingMessage] 里）⇒ 兜底。
  ///
  /// 重读走 [_mergeUsageHistory]：同键去重 + 实时行孪生合并都在里面 ⇒ 重复读不会长出第二行，
  /// 读不到也只是留一句可读原因（不抛、不红）。
  void _refreshCallUsagesHistory() {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    // 还没读过（这个会话压根没加载）⇒ 交给 [_loadHistory] 那次读，别提前开跑。
    if (_callUsagesKey.isEmpty) return;
    _callUsagesKey = '';
    _scheduleCallUsagesHistory(agent.id, _currentSessionId);
  }

  /// 这一帧是不是"给人看、不喂模型"的系统提示（`llm_hidden`）。
  ///
  /// 两种承载形态都认：提示消息的字段直接铺在帧上（`msg_end` / `msg_chunk` 这类），
  /// 或包在 `data` 里（事件帧的统一外壳）。
  static bool _isLlmHiddenFrame(Map<String, dynamic> data) {
    if (data['llm_hidden'] == true) return true;
    final Object? inner = data['data'];
    return inner is Map && inner['llm_hidden'] == true;
  }

  /// 按 `(agent, 会话)` 读一次 `usage.jsonl`，把**历史**调用补进逐调用列表。
  ///
  /// 触发点：[_loadHistory] 开头——首次进入 / 换 agent（经 [_loadSessions]）/ 换会话 /
  /// 整表重拉都汇合在那里，且那一刻 `(agent, 会话)` 已经确定。组件本身没有"展开回调"
  /// （不改 `UsageCallsPanel`），所以不去等用户点展开：账本只读尾巴一段，代价很小。
  ///
  /// 同一个 `(agent, 会话)` 只读一次（[_callUsagesKey] 记账）；换会话 / 换 agent 会清掉
  /// 这个记账（见 [_clearWindow]），下一次 [_loadHistory] 再读一遍。
  void _scheduleCallUsagesHistory(String agentId, String sessionId) {
    final String key = '$agentId::$sessionId';
    if (key == _callUsagesKey) return;
    _callUsagesKey = key;
    unawaited(
      _loadCallUsagesHistory(agentId: agentId, sessionId: sessionId, key: key),
    );
  }

  /// 读账本并合并（**绝不抛**：读不到只留一句可读原因，已经拿到的实时行照旧显示）。
  Future<void> _loadCallUsagesHistory({
    required String agentId,
    required String sessionId,
    required String key,
  }) async {
    final UsageHistoryRead read = await UsageLogFiles.readRecent(
      agentId: agentId,
      sessionId: sessionId,
      lines: UsageLogFiles.defaultLines,
      // 测试注入（见 [MessagePanel.debugUsageFileOverride]）；生产恒为 null。
      override: MessagePanel.debugUsageFileOverride,
    );
    // 竞态防护：等待期间切了会话 / 换了 agent ⇒ 这份读数作废（不许写进新会话的列表）
    if (!mounted || _callUsagesKey != key) return;
    setState(() {
      _callUsagesNote = read.ok ? '' : read.reason;
      _mergeUsageHistory(read.calls);
    });
  }

  /// 把账本行（文件顺序：早 → 晚）合进列表。
  ///
  /// 三条口径：
  /// - 与列表里某条**同键**（同 `at` + 来源 + 输入 + 输出）⇒ 不重复添加（账本被读了两遍
  ///   时不该长出第二行）；
  /// - 与某条**实时行是孪生**（来源 + 输入 + 输出都对得上，且实时那条没有 `at`）⇒ 就地
  ///   补全它的 `at` / `duration_ms`，**不**新增一行——两者描述的是同一次调用；
  /// - 其余（更早的调用）整体插在实时行**之前**，列表保持"早 → 晚"。
  void _mergeUsageHistory(List<UsageCallView> history) {
    if (history.isEmpty) return;
    final List<UsageCallView> older = <UsageCallView>[];
    for (final UsageCallView row in history) {
      if (_indexOfUsageCall(row) >= 0) continue;
      final int twin = _indexOfTwin(row);
      if (twin >= 0) {
        _callUsages[twin] = _fillMissing(_callUsages[twin], row);
        continue;
      }
      older.add(row);
    }
    if (older.isNotEmpty) _callUsages.insertAll(0, older);
  }

  /// 处理 agent 的提问（AskUserQuestion 工具）：以非阻塞内联卡片插入消息流。
  ///
  /// 不再弹全屏遮罩对话框，避免挡住模型最近输出与右侧信息；用户可先浏览
  /// 上下文再点选选项作答，由 [_handleAskAnswer] 发送 answer 并置位已作答状态。
  void _handleAskUserQuestion(Map<String, dynamic> data) {
    if (_asking) return;
    final String qid = (data['id'] as String?) ?? '';
    if (qid.isEmpty) return;
    // 重播去重：卡片本身落库（历史里会有），断线期间重播的提问帧不得再插一张
    // （否则已作答的旧问题会重新冒出来抢答）。
    if (!_replayGuard.shouldCreateMessage(id: qid, exists: _hasMessage(qid))) {
      debugPrint('[消息] 忽略重播的提问卡片（同 id 已存在）: $qid');
      return;
    }
    _asking = true;
    final String question = (data['question'] as String?) ?? '提问';
    final List<String> options =
        (data['options'] as List?)?.map((e) => e.toString()).toList() ??
        <String>[];
    setState(() {
      _window.appendTail(
        ChatMessage(
          id: qid,
          role: 'agent',
          content: question,
          timestamp: DateTime.now(),
          kind: 'ask_user_question',
          options: options,
          // 临时员工提问：问题正文里已有它的名字，这里再带上标记供界面打标
          subagentId: data['subagent_id'] as String? ?? '',
          subagentName: data['subagent_name'] as String? ?? '',
          subagentParentId: data['subagent_parent_id'] as String? ?? '',
          subagentLevel: (data['subagent_level'] as num?)?.toInt() ?? 0,
        ),
      );
      _scrollRevision++;
      _bottomJump = false;
    });
    // 通知右栏「问题回复」页即时出现新问题
    QuestionUpdateService.instance.notifyChanged();
  }

  /// 处理内联提问卡片的选项点选：发送 user_answer 并标记该问题已作答。
  void _handleAskAnswer(String messageId, String answer) {
    _asking = false;
    final int idx = _window.indexOfId(messageId);
    if (idx >= 0) {
      setState(() {
        _window.at(idx)!.answered = true;
      });
    }
    // 作答会驱动 agent 继续（resume 后可能立刻发起工具调用）：若前端曾重启/
    // 断连导致执行器注册丢失，先补注册（幂等）再发送答案，避免续轮工具调用
    // 撞上"前端执行器未启用"。本地/SSH 一并处理，fire-and-forget 不阻塞作答。
    final Agent? agent = widget.selectedAgent;
    if (agent != null) {
      _ensureExecutorsReady(agent.id);
    }
    _webSocket.send(<String, dynamic>{
      'type': 'user_answer',
      'data': {'question_id': messageId, 'answer': answer},
    });
    // 通知右栏「问题回复」页标记该问题已回复
    QuestionUpdateService.instance.notifyChanged();
  }

  /// 请求停止当前 agent/会话的进行中任务
  void _handleStop() {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    // 看临时员工视角时**只停它**（用户 2026-10-04：允许用户停止 subagent 的工作）——
    // agent 级的 stop 会级联停掉它的成员/子树，那不是这里该发生的事。
    final String viewId = _effectiveViewId;
    _webSocket.send(<String, dynamic>{
      'type': 'stop',
      'data': {
        'agent_id': viewId.isEmpty ? agent.id : viewId,
        'session_id': _currentSessionId,
      },
    });
    // 本地先把它的状态翻成空闲：帧回来之前别让那颗停止键卡在那里
    if (viewId.isNotEmpty) {
      setState(() => _workingSubagents.remove(viewId));
    }
  }

  /// 处理发送
  ///
  /// 附件先上传到该 agent 的**工作空间**（`.input/{yyyymmdd}/`），拿到工作空间
  /// 相对路径后再把消息发出去：核心据此在提示词里告诉模型"用户上传了什么、在哪"，
  /// 模型才能用文件工具读到它（只传本机路径等于什么都没发——本机路径既不是模型的
  /// 工作空间口径，SSH 模式下也根本读不到）。
  ///
  /// 返回值 = 是否已发出：`false` 时输入框保留文本与附件（上传失败不该让用户重写），
  /// 由 [MessageInput] 决定不清空草稿。
  Future<bool> _handleSend(String text, List<String> filePaths) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return false;
    // 发送前懒激活目标 team 的执行器配置（幂等）：未加载的从核心重新读取，
    // 已启用的走注册/写入流程。fire-and-forget + 超时兜底，绝不阻塞消息发送。
    _ensureExecutorsReady(agent.id);

    List<Map<String, dynamic>> attachments = const <Map<String, dynamic>>[];
    if (filePaths.isNotEmpty) {
      try {
        attachments = await AttachmentUploadService.uploadAll(
          // workspace_id 为空时退回 agent id：核心的 agentFor 两者都认
          agent.workspaceId.isEmpty ? agent.id : agent.workspaceId,
          filePaths,
          teamId: agent.id,
          onFile: (int index, int total, String name) {
            if (total > 1) _showSnackBar('正在上传附件 $index/$total：$name');
          },
        );
      } catch (error) {
        _showSnackBar('附件上传失败，消息未发送：${_errorText(error)}');
        return false;
      }
      if (!mounted) return false;
    }

    // 看临时员工视角时，这条消息发给**它**（用户 2026-10-04：向其发消息）：
    // - 收件人用它的 id（核心侧走 `sendToSubagent`：落 `role=user` + 它的标记）；
    // - 本地那条乐观气泡**也要打它的标记**，否则会出现在主消息流里而不是它的过程里。
    final String viewId = _effectiveViewId;
    final bool toSubagent = viewId.isNotEmpty;
    final List<ChatMessage> transcript = toSubagent
        ? _viewTranscript()
        : const <ChatMessage>[];
    final ChatMessage userMessage = ChatMessage(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
      attachments: attachments.isEmpty
          ? null
          : attachments.map(_attachmentOf).toList(),
      subagentId: toSubagent ? viewId : '',
      subagentName: toSubagent ? subagentName(transcript) : '',
      subagentParentId: toSubagent && transcript.isNotEmpty
          ? transcript.first.subagentParentId
          : '',
      subagentLevel: toSubagent ? subagentLevel(transcript) : 0,
    );

    setState(() {
      _window.appendTail(userMessage);
      _scrollRevision++;
      _bottomJump = false;
      // 发送首条消息后锁定运行模式（后端会话自此绑定该模式的工具执行位置）
      _modeLocked = true;
    });

    _webSocket.sendMessage(<String, dynamic>{
      'type': 'user_message',
      'agent_id': toSubagent ? viewId : agent.id,
      'content': text,
      // 工作空间相对路径（附件已由前端上传完成），核心把它写进提示词。
      // 临时员工与发起者**共享同一个工作空间**，所以上传目标仍是这个 agent。
      'attachments': attachments,
      'session_id': _currentSessionId,
    });
    return true;
  }

  /// 附件元数据（核心/上传服务口径）→ 前端展示模型。
  static Attachment _attachmentOf(Map<String, dynamic> meta) => Attachment(
    name: (meta['name'] ?? '').toString(),
    size: (meta['size'] as num?)?.toInt() ?? 0,
    type: (meta['type'] ?? '').toString(),
    path: (meta['path'] ?? '').toString(),
  );

  /// 异常 → 一句可读提示（去掉 `Exception: ` 前缀）。
  static String _errorText(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  /// 发送前确保目标 team 的执行器状态就绪（幂等懒激活）。
  ///
  /// 桌面端"注册"已等价于读/写该 agent 的配置（见 LocalExecutorService /
  /// SshExecutorService），这里仍保留超时兜底并 fire-and-forget：配置读取失败
  /// 不阻塞消息发送，重连与下次进入会重新自愈。
  void _ensureExecutorsReady(String teamId) {
    unawaited(() async {
      try {
        await LocalExecutorService.instance
            .ensureTeam(teamId)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
        await SshExecutorService.instance
            .ensureTeam(teamId)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {
        // 激活失败不阻塞发送
      }
    }());
  }

  /// 从路径中提取文件名（兼容 / 与 \）
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  /// 切换当前顶部 agent 的运行模式（local / ssh 两态互斥，M9 Q2 删除 cloud）。
  ///
  /// 开关均面向当前选中 agent 的 teamId 调用（per-team API）：
  /// - 切到 local：若 ssh 已启用先注销 ssh；未选目录则先选目录，再启用本地执行器。
  /// - 切到 ssh：若 local 已启用先注销 local；弹出 SSH 配置表单，确认后注册并等待
  ///   后端 ack（连接测试失败会回显错误）。
  Future<void> _switchMode(String targetMode) async {
    if (_togglingMode) return;
    // 发送首条消息后会话已绑定该模式的工具执行位置，禁止再切换运行模式
    if (_modeLocked) {
      _showSnackBar('对话已开始，该顶部 agent 的运行模式已锁定，无法切换');
      return;
    }
    final String? teamId = widget.selectedAgent?.id;
    if (teamId == null || teamId.isEmpty) return; // 未选择 agent 不切换
    final String current = _currentMode;
    if (targetMode == current) return;

    _togglingMode = true;
    try {
      if (targetMode == 'local') {
        // 移动端（Android/iOS）无桌面文件系统与目录选择能力，本地执行不可用
        if (isMobile) {
          _showSnackBar('移动端不支持本地执行模式，请使用 SSH 模式');
          return;
        }
        // 团队 TOP 配了 SSH 时，成员**无法**单独切回本地：核心的判据是
        // "自己配了 SSH 就用自己那份，否则跟随团队 TOP"（team_workspace.dart），
        // 没有"成员覆盖成 local"这个概念。这里如实拒绝，而不是假装切成功。
        final String ownerId = widget.selectedAgent?.teamScopeId ?? '';
        final bool isMember = ownerId.isNotEmpty && ownerId != teamId;
        if (!TeamScopeView.allowsLocalSwitch(
          isMember: isMember,
          teamHasSsh: SshExecutorService.instance.isTeamEnabled(ownerId),
        )) {
          _showSnackBar('该成员跟随团队 TOP 的 SSH 模式，无法单独切回本地：请先在团队 TOP 上关闭 SSH');
          return;
        }
        // 与 SSH 互斥：先注销 ssh
        if (current == 'ssh') {
          await SshExecutorService.instance.disableTeam(teamId);
        }
        // 开启前先选目录（工具执行结果写入此目录）
        // 注意：新 agent 的 _localWorkingDir 可能是空字符串而非 null，
        // 因此同时检查 null 和空字符串，确保目录必选
        if (_localWorkingDir == null || _localWorkingDir!.isEmpty) {
          await _pickWorkingDirectory();
          // 用户取消选择或路径仍为空，不启用本地模式
          if (_localWorkingDir == null || _localWorkingDir!.isEmpty) return;
        }
        await LocalExecutorService.instance.setTeamEnabled(teamId, true);
        if (!mounted) return;
        setState(() {
          _localEnabled = true;
          _sshEnabled = false;
        });
        _showSnackBar('本地执行模式已启用（工具直接在本机目录运行）');
      } else if (targetMode == 'ssh') {
        // 与 local 互斥：先注销 local
        if (current == 'local') {
          await LocalExecutorService.instance.setTeamEnabled(teamId, false);
        }
        if (!mounted) return;
        // 弹出 SSH 配置表单（预填已有配置）
        final Map<String, dynamic>? config =
            await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (BuildContext dialogContext) =>
                  SshConfigDialog(initialConfig: _sshConfig),
            );
        if (config == null || !mounted) return;
        // 注册并等待后端 ack（后端会先测试连接）
        final Map<String, dynamic> ack = await SshExecutorService.instance
            .enableTeam(teamId, config);
        if (!mounted) return;
        if (ack['success'] == true) {
          setState(() {
            _sshEnabled = true;
            _localEnabled = false;
            _sshConfig = config;
          });
          _showSnackBar('SSH 执行模式已启用（工具在远端主机执行）');
        } else {
          _showSnackBar('SSH 启用失败：${ack['message'] ?? '未知错误'}');
        }
      }
    } finally {
      _togglingMode = false;
    }
  }

  /// 选择工作目录（用户项目根目录，工具读写/命令执行都在此目录下）
  Future<void> _pickWorkingDirectory() async {
    final String? path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择项目根目录（工具执行结果写入此目录）',
    );
    if (path == null || path.isEmpty) return;
    final Agent? agent = widget.selectedAgent;
    final String agentId = agent?.id ?? '';
    // 写入目标是**团队 TOP**：工作目录是团队共享的那一份，成员自己的
    // `workspace_dir` 只是核心写下的镜像（team_workspace.dart 的断言：成员那份不生效）。
    // 若照着成员 id 写，用户等于改了一个没人读的字段。
    final String ownerId = agent?.teamScopeId ?? agentId;
    if (ownerId.isNotEmpty) {
      await LocalExecutorService.instance.setTeamWorkingDirectory(
        ownerId,
        path,
      );
    }
    if (!mounted) return;
    if (ownerId.isNotEmpty && ownerId != agentId) {
      _showSnackBar('已设为团队共享工作目录（团队成员共用这一个目录）');
    }
    setState(() {
      _localWorkingDir = path;
    });
  }

  /// 显示 SnackBar 提示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    // 只回收自己装上的通道：期间可能已有新面板接管（多窗口/重建）
    if (identical(PluginUiRegistry.instance.actionSender, _pluginActionSink)) {
      PluginUiRegistry.instance.actionSender = null;
    }
    TerminalToggleRequest.instance.removeListener(_onTerminalToggleRequested);
    WorkspacePickRequest.instance.removeListener(_onWorkspacePickRequested);
    _webSocket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 跑着的工具 / 思考还在长：帧后把右栏详情的同一 id 快照刷新一次。
    // 为什么放帧后：改这个 notifier 会让右栏与工具/思考行重建，在 build 期间
    // 通知就成了「build 期间 setState」。它只读窗口里已加载的消息，不改中栏状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) DetailSelection.instance.refresh(_window.loadedList);
    });
    final Agent? agent = widget.selectedAgent;
    // Ctrl+J：输入框那块整体换成集成终端（再按一次回来）。
    // 两条入口，互补而不是重复（内层先消费按键，不会双重切换）：
    // 1) 本面板这层 CallbackShortcuts + autofocus 的 Focus：焦点在中栏里时的最近一跳；
    // 2) MainPage 的全局「事件驿站」→ TerminalToggleRequest：焦点在文件面板 / 右栏 /
    //    消息列表这些**中栏之外**的地方时用（用户 2026-10-03 要求）；
    // 终端自己拿着焦点时由 TerminalPanel 自己处理（它要拦截几乎所有按键）。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true):
            _toggleTerminal,
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Column(
            children: <Widget>[
              _buildTitleBar(agent),
              if (agent != null) _buildContextBar(),
              if (agent != null) _buildUsageCallsSection(),
              if (agent == null)
                Expanded(
                  child: Center(
                    child: Text(
                      '请选择一个 Agent 开始对话',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  // Q12 消息流内联卡片：有插件卡片槽位时，在消息列表末尾追加卡片区
                  // （无卡片时传空列表，列表项数不变，不占位）。
                  child: ListenableBuilder(
                    listenable: PluginUiRegistry.instance,
                    builder: (BuildContext context, Widget? child) {
                      // 临时员工视角：**同一个窗口**换成它自己的过程（不新开页面）
                      final String viewId = _effectiveViewId;
                      if (viewId.isNotEmpty) {
                        return _buildSubagentView(viewId);
                      }
                      final bool hasCards = PluginUiRegistry.instance.hasKind(
                        PluginUiSlotKind.card,
                      );
                      // 临时员工的消息**不进主消息流**（用户 2026-10-04：「subagent 的输出跟主 agent
                      // 的输出混杂，根本没法分辨，subagent 的工具调用就在 subagent 的调用工具详情里看」）：
                      // 它们按 subagent_id 收进 [SubagentTranscript]，在"那次 subagent 工具调用的详情页"里看。
                      return MessageList(
                        // **槽位表**：全局下标 → 消息（null = 还没加载）。面板原地放置/
                        // 淘汰，列表据此画占位槽、按全局下标画右侧滑块。
                        slots: _window.slots,
                        // 临时员工的消息**不进主消息流**（用户 2026-10-04）：零高度槽位，
                        // 既不占版面、也不打断下标连续性；它们按 subagent_id 收在
                        // SubagentTranscript 里，在"那次 subagent 工具调用的详情页"看。
                        visible: (ChatMessage m) => !m.isSubagentMessage,
                        revision: _scrollRevision,
                        // 视口附近补过页：列表在布局阶段补一次滚动位置
                        padAboveStamp: _padAboveStamp,
                        // 本帧内容高度在"视口里/视口下方"变了（补页横跨视口顶 / 淘汰）：
                        // 同样要补偿一次（A3）
                        contentShiftStamp: _contentShiftStamp,
                        // 滑到哪加载哪 + 淘汰离得远的槽位（限制缓存长度）
                        onWindowChanged: _onWindowChanged,
                        // 「回到底部」= 重载末尾一段（用户 2026-10-04）
                        onReloadTail: _reloadTail,
                        onAskAnswer: _handleAskAnswer,
                        scrollToMessageId: _scrollToMessageId,
                        scrollToRevision: _scrollToRevision,
                        bottomJump: _bottomJump,
                        trailingCards: hasCards
                            ? <Widget>[
                                PluginInlineCards(
                                  agentId: agent.id,
                                  sessionId: _currentSessionId,
                                ),
                              ]
                            : const <Widget>[],
                      );
                    },
                  ),
                ),
              if (agent != null && _terminalMode) ...<Widget>[
                _buildTerminalDivider(),
                SizedBox(
                  height: _terminalHeight,
                  child: TerminalPanel(
                    agentId: agent.id,
                    webSocket: _webSocket,
                    onToggle: _toggleTerminal,
                    onClose: _toggleTerminal,
                    // 终端里的 `#TSend` 与手打一条消息走**同一个发送口**（上传附件、
                    // 上屏、WS 帧全一样），不另立一条容易跑偏的旁路
                    onSend: _handleSend,
                  ),
                ),
              ] else if (agent != null)
                MessageInput(
                  // 草稿按 team + session 隔离（M9 Q6）：切 agent/会话各自恢复
                  // 自己没发完的文本与附件，互不串味（终端模式期间它被移出树，
                  // 草稿靠缓存活着，切回来原样还在）
                  cacheKey: '${agent.id}::$_currentSessionId',
                  // 新手引导最后一步把 demo 那句话预填进来（只填不发）
                  prefill: ComposerPrefillRequest.instance,
                  onSend: _handleSend,
                  // 视角切换器：发送键左侧（用户 2026-10-04 要求的落点）
                  bottomTrailing: SubagentViewSwitcher(
                    ownerAgentId: agent.id,
                    ownerName: agent.name,
                    currentSubagentId: _effectiveViewId,
                    onSelect: _switchView,
                  ),
                  // 生成中且没输入内容时，右下角那个位置变成**停止键**（用户 2026-10-04；
                  // 开始打字就换回发送键——发送本身就会中止在途那一轮）。
                  // 看临时员工视角时看的是**它自己**的状态：停止/发消息都只作用在它身上。
                  busy: _viewTargetIsWorking(agent.id),
                  onStop: _handleStop,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全局驿站转来的切换请求（焦点不在中栏时；见 [TerminalToggleRequest]）。
  ///
  /// 这里再判一次 mounted / 有没有 agent：请求是**广播**，面板可能已经卸载，
  /// 或者当前根本没有选中的 agent（那时没有「对应工作区」可开终端）。
  /// 引导请求「选择工作目录」：转交给既有的目录选择流程（含团队 TOP / SSH 那套规则）。
  void _onWorkspacePickRequested() {
    if (widget.selectedAgent == null) return;
    unawaited(_pickWorkingDirectory());
  }

  void _onTerminalToggleRequested() {
    if (!mounted || widget.selectedAgent == null) return;
    _toggleTerminal();
  }

  /// Ctrl+J：在「对话输入框」与「集成终端」之间切换。
  ///
  /// **主动展开**的含义：打开时按面板高的 40%（夹 160–420）给一个起步高度，
  /// 并把焦点交给终端——用户按完 Ctrl+J 就能直接打字，不用再点一下。
  void _toggleTerminal() {
    if (widget.selectedAgent == null) return; // 没选 agent 就没有「对应工作区」
    setState(() {
      _terminalMode = !_terminalMode;
      if (_terminalMode) {
        _terminalHeight = (MediaQuery.sizeOf(context).height * 0.4).clamp(
          160.0,
          420.0,
        );
      }
    });
  }

  /// 终端与消息区之间的拖拽分隔条
  Widget _buildTerminalDivider() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (DragUpdateDetails d) {
          setState(() {
            _terminalHeight = (_terminalHeight - d.delta.dy).clamp(
              140.0,
              640.0,
            );
          });
        },
        child: SizedBox(
          height: 7,
          child: Center(
            child: Container(height: 1, color: Theme.of(context).dividerColor),
          ),
        ),
      ),
    );
  }

  /// 构建上下文长度栏：展示当前会话最近一次回复时的上下文长度
  /// （prompt_tokens / max_tokens），无数据时显示占位提示。
  Widget _buildContextBar() {
    final cs = Theme.of(context).colorScheme;
    final Agent? agent = widget.selectedAgent;
    // **各看各的**：主会话看自己的 usage，临时员工视角看它自己的（用户硬要求：
    // 临时员工的统计不并进主 agent 的读数）
    final String viewId = _effectiveViewId;
    final ContextReading? reading = viewContext(
      subagentId: viewId,
      mainUsage: agent != null
          ? _usageByAgent['${agent.id}::$_currentSessionId']
          : null,
      transcript: _viewTranscript(),
    );
    final int promptTokens = reading?.promptTokens ?? 0;
    final int maxTokens = reading?.maxTokens ?? 0;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.data_usage, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            viewId.isEmpty ? '上下文' : '它的上下文',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          if (maxTokens > 0)
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (promptTokens / maxTokens).clamp(0.0, 1.0),
                  backgroundColor: cs.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    promptTokens > maxTokens * 0.9 ? cs.error : cs.primary,
                  ),
                  minHeight: 4,
                ),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            maxTokens > 0
                ? '${_formatTokens(promptTokens)} / ${_formatTokens(maxTokens)}'
                : (promptTokens > 0 ? _formatTokens(promptTokens) : '暂无数据'),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 构建「本轮调用列表」折叠区：挂在上下文长度条下面一带。
  ///
  /// 两件事必须成立：
  /// 1. **有界宽度**：面板内部是一个 `Row`（里面有 `Spacer`），父级必须给出确定的
  ///    最大宽度——这里用 `Column(crossAxisAlignment: stretch)` 把中栏的宽度摊开传给
  ///    卡片；不塞进任何宽度未约束的 `Row`；
  /// 2. **默认收起 + 最多 20 行**：用量是"需要才查"的信息，折叠态只占一行标题，不把
  ///    中栏的竖向空间挤变形（展开与截断都由面板自己处理）。
  Widget _buildUsageCallsSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 说明行占**固定槽位**（没有原因时放零高度占位）：这样下面的
          // UsageCallsPanel 在元素树里位置恒定，展开状态不会因为一行说明的出现 /
          // 消失而被重建（折叠状态是面板自己的 State）。
          _buildCallUsagesNote(),
          UsageCallsPanel(
            calls: _callUsages,
            initiallyExpanded: false,
            maxRows: _usageCallsMaxRows,
          ),
        ],
      ),
    );
  }

  /// 账本读不到时的空态说明（**只在一条调用都没有时**出现）。
  ///
  /// "读不到账本"（核心没给数据根 / 还没有这个文件 / IO 失败）与"这个会话还没调用过"
  /// 是两件事，不该都显示成"暂无调用记录"——读不到时给一句人话，并且不抛、不红。
  Widget _buildCallUsagesNote() {
    final String note = _callUsages.isEmpty ? _callUsagesNote : '';
    if (note.isEmpty) return const SizedBox.shrink();
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: note,
        child: Text(
          note,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, height: 1.3, color: color),
        ),
      ),
    );
  }

  /// 将 token 数格式化为千分位可读文本（如 12345 -> 12.3k）
  String _formatTokens(int value) {
    if (value >= 10000) {
      final double k = value / 1000.0;
      return '${k.toStringAsFixed(1)}k';
    }
    return value.toString();
  }

  /// 构建标题栏（Agent 名称 + 本地运行开关 + 状态 + 停止/teammates/压缩按钮）
  Widget _buildTitleBar(Agent? agent) {
    final cs = Theme.of(context).colorScheme;
    // 看临时员工的过程时，标题就是它（**同一个窗口**，不新开页面）
    final String viewId = _effectiveViewId;
    final List<ChatMessage> viewTranscript = _viewTranscript();
    final bool inSubagentView = viewId.isNotEmpty;
    final String? title = agent == null
        ? null
        : viewTitle(
            subagentId: viewId,
            agentName: agent.name,
            transcript: viewTranscript,
          );
    // 当前 agent 是否在工作
    final bool working = agent != null && _workingAgents.contains(agent.id);
    // 当前 agent 是否在压缩上下文（compacting 状态，与 working 可并存：
    // working 是 agent 级、compacting 是会话级，跨会话可同时发生）
    final bool compacting =
        agent != null && _compactingAgents.contains(agent.id);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          // 运行模式两态开关（消息窗口左上：local / ssh，M9 Q2 删除 cloud）
          _buildModeSwitch(cs),
          // 工作目录选择（仅本地模式启用时显示）
          if (_localEnabled) _buildWorkingDirSelector(cs),
          // SSH 远端主机标签（仅 SSH 模式启用时显示）
          if (_sshEnabled) _buildSshHostLabel(cs),
          // Agent 名称
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      title ?? '未选择',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 临时员工视角：紧跟一句"谁召来的 · 第几层"（措辞与团队的层级分开）
                  if (inSubagentView) ...<Widget>[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        viewSubtitle(
                          callerName: SubagentTranscript.instance.callerNameOf(
                            viewId,
                            ownerAgentId: agent?.id ?? '',
                            ownerName: agent?.name ?? '',
                          ),
                          transcript: viewTranscript,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (working) ...<Widget>[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '工作中',
                      style: TextStyle(fontSize: 11, color: Colors.orange),
                    ),
                  ],
                  if (compacting) ...<Widget>[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.tertiary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '压缩中',
                      style: TextStyle(fontSize: 11, color: cs.tertiary),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (agent != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SessionPicker(
                sessions: _sessions,
                currentSessionId: _currentSessionId,
                onSelect: _handleSelectSession,
                onCreate: _handleCreateSession,
                onRename: _handleRenameSession,
                onDelete: _handleDeleteSession,
                // 看临时员工的过程时**锁住会话切换**（用户 2026-10-04 要求）：
                // 那条过程属于当前会话，切走会话这一屏就没有意义了
                locked: inSubagentView,
                lockedHint:
                    '正在看临时员工的过程：先切回主会话再换会话'
                    '（切换器在输入框右下）',
              ),
            ),
          if (agent != null)
            IconButton(
              tooltip: '任务规范 Spec',
              icon: const Icon(Icons.auto_awesome, size: 20),
              onPressed: () => _openSpecPanel(agent),
            ),
          if (agent != null)
            IconButton(
              tooltip: (agent.pendingMemberCount > 0)
                  ? '查看 teammates 工作进度（有 ${agent.pendingMemberCount} 名成员'
                        '等待分配模型 / 审核）'
                  : '查看 teammates 工作进度',
              icon: _buildTeammatesIcon(agent),
              onPressed: () => _openTeammatesWindow(agent),
            ),
          // 临时员工：与 teammates 入口**平级**（用户 2026-10-04：「应该做和 teammates 同级的热
          // 工作显示，在对话框支持选择进入 subagent 视角」）——本会话有才出现，点开选一个进去。
          if (agent != null) _buildSubagentEntry(agent),
          // 停止键**搬到了输入框右下**（占发送键的位置：生成中且没输入内容时出现，
          // 一开始打字就换回发送键）——用户 2026-10-04。标题栏不再重复放一个。
          if (agent != null)
            IconButton(
              tooltip: compacting ? '正在压缩中' : '压缩上下文',
              icon: Icon(
                Icons.compress,
                size: 20,
                color: compacting ? cs.outline : null,
              ),
              // 压缩期间禁用：后端按会话粒度互斥（防双击并发压缩），
              // 工作中由后端返回 agent_working 提示，不在此拦截
              onPressed: compacting ? null : () => _compactContext(agent.id),
            ),
        ],
      ),
    );
  }

  /// 构建运行模式两态开关（消息窗口左上，local / ssh）
  Widget _buildModeSwitch(ColorScheme cs) {
    return SizedBox(
      width: 36,
      height: 36,
      child: ModeSwitchButton(
        mode: _currentMode,
        locked: _modeLocked,
        onSelect: _switchMode,
        // 移动端不支持本机目录执行，隐藏「本地执行」菜单项
        showLocal: !isMobile,
      ),
    );
  }

  /// 构建 SSH 远端主机标签（仅 SSH 模式启用时显示）
  Widget _buildSshHostLabel(ColorScheme cs) {
    final String host = (_sshConfig['host'] as String?) ?? '';
    final String username = (_sshConfig['username'] as String?) ?? '';
    final String label = username.isNotEmpty && host.isNotEmpty
        ? '$username@$host'
        : host;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text(
          label.isEmpty ? 'SSH' : label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.orange),
        ),
      ),
    );
  }

  /// 构建工作目录选择器（仅本地模式启用时显示）
  Widget _buildWorkingDirSelector(ColorScheme cs) {
    final String displayPath = _basename(_localWorkingDir ?? '');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 100),
          child: GestureDetector(
            onTap: _pickWorkingDirectory,
            child: Text(
              displayPath.isEmpty ? '选择目录' : displayPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(Icons.folder_open, size: 16, color: cs.primary),
            onPressed: _pickWorkingDirectory,
            tooltip: '选择工作目录',
          ),
        ),
      ],
    );
  }

  /// 打开 teammates 工作进度窗口
  ///
  /// 窗口内成员配置（赋模型 / 审核）变更时经 [MessagePanel.onAgentsChanged]
  /// 让父页面重拉 agent 列表，使待处理成员红点在配置完成后立即消失；
  /// 关闭窗口后再兜底刷新一次。
  Future<void> _openTeammatesWindow(Agent agent) async {
    // 会话未就绪（首次加载 / 刚切换 agent，_loadSessions 尚未返回）时不得
    // 回退默认会话：否则窗口按 session_default 过滤，显示的是默认会话的
    // 成员进度而非当前会话。此时拒绝打开并提示，待会话确定后再进入。
    final String? sessionId = _currentSession?.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('会话加载中，请稍候再打开工作进度')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TeammatesWindowPage(
          agent: agent,
          // 透传当前会话：进度页历史/实时 WS 按该成员+该会话过滤，
          // 避免把该成员其他会话的工作进度混进当前窗口（跨会话）。
          sessionId: sessionId,
          // 成员配置变更 → 重拉 agent 列表，刷新待处理成员红点
          onMembersChanged: widget.onAgentsChanged,
        ),
      ),
    );
    if (!mounted) return;
    // 关闭窗口兜底刷新（成员可能被其它入口改动过）
    widget.onAgentsChanged?.call();
  }

  /// 临时员工入口：**与"发出这次调用的 agent"同级**（用户 2026-10-04 的更正：不是与
  /// teammates 同级）——它是这个 agent 自己召来的临时员工，入口就挂在它的会话头上，
  /// 列的是"谁召来的"，深度叫「临时员工层数」而不是团队的「层级」。
  Widget _buildSubagentEntry(Agent agent) {
    return ListenableBuilder(
      listenable: SubagentTranscript.instance,
      builder: (BuildContext context, Widget? child) {
        final List<String> ids = SubagentTranscript.instance.ids;
        if (ids.isEmpty) return const SizedBox.shrink();
        final String current = _effectiveViewId;
        return PopupMenuButton<String>(
          tooltip: current.isEmpty
              ? '「${agent.name}」召来的临时员工（${ids.length} 名）'
              : '正在看「${agent.name}」召来的临时员工 · 点这里换一个或回主会话',
          icon: const Icon(Icons.badge_outlined, size: 20),
          // 与切换器同一条路：**就地换视角**（不再 push 一个新页面）
          onSelected: _switchView,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: '',
              child: Row(
                children: <Widget>[
                  Icon(
                    current.isEmpty ? Icons.check : Icons.chat_bubble_outline,
                    size: 15,
                    color: current.isEmpty
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  const Text('主会话'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            for (final String id in ids)
              PopupMenuItem<String>(
                value: id,
                child: Row(
                  children: <Widget>[
                    Icon(
                      id == current ? Icons.check : Icons.badge_outlined,
                      size: 15,
                      color: id == current
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text(_subagentMenuLabel(agent, id))),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// 选择列表里的一行：**谁召来的** + 名字 + 深度 + 已有多少条过程。
  ///
  /// 措辞与 teammates 刻意分开（对齐语义）：这里是"某个 agent 召来的临时员工"，
  /// 深度是**临时员工套娃层数**，不是团队成员的 `level`。
  String _subagentMenuLabel(Agent agent, String id) {
    final List<ChatMessage> transcript = SubagentTranscript.instance.of(id);
    if (transcript.isEmpty) return id;
    final ChatMessage first = transcript.first;
    final String name = first.subagentName.isEmpty ? '未命名' : first.subagentName;
    final String caller = SubagentTranscript.instance.callerNameOf(
      id,
      ownerAgentId: agent.id,
      ownerName: agent.name,
    );
    final String who = caller.isEmpty ? '（未知调用方）' : '由「$caller」召来';
    return '临时员工「$name」 · $who · 第 ${first.subagentLevel} 层 · '
        '${transcript.length} 条过程';
  }

  /// 当前真正生效的视角 id（防御）：要看的临时员工必须还在这一屏的过程分栏里。
  ///
  /// 为什么要有它：过程分栏每帧按整份消息流重建（[SubagentTranscript.sync]），换会话 /
  /// 整表重拉之后那个 id 可能已经不存在了——那时**回到主会话**，而不是显示一个空屏。
  String get _effectiveViewId =>
      _viewSubagentId.isNotEmpty &&
          SubagentTranscript.instance.ids.contains(_viewSubagentId)
      ? _viewSubagentId
      : '';

  List<ChatMessage> _viewTranscript() =>
      SubagentTranscript.instance.of(_effectiveViewId);

  /// 切换视角（空串 = 回主会话）：**就地换**——用户 2026-10-04 明确要求不新开窗口，
  /// 借父 agent 的窗口把对话数据与上下文长度条换成它的。
  void _switchView(String subagentId) {
    if (subagentId == _viewSubagentId) return;
    setState(() {
      _viewSubagentId = subagentId;
      // 换视角 = 换一份消息：滚动位置与"跳到最新"按新视角重来
      _scrollRevision++;
      _bottomJump = true;
    });
  }

  /// 右下角那个键该看谁的"工作中"：主会话看 agent，临时员工视角看**它自己**。
  bool _viewTargetIsWorking(String agentId) {
    final String viewId = _effectiveViewId;
    if (viewId.isNotEmpty) return _workingSubagents.contains(viewId);
    return agentId.isNotEmpty && _workingAgents.contains(agentId);
  }

  /// 临时员工视角的正文区：一行身份条 + 它的完整过程（**同一个窗口**里换掉消息列表）。
  Widget _buildSubagentView(String subagentId) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Agent? agent = widget.selectedAgent;
    return ListenableBuilder(
      listenable: SubagentTranscript.instance,
      builder: (BuildContext context, Widget? child) {
        final List<ChatMessage> transcript = SubagentTranscript.instance.of(
          subagentId,
        );
        final String caller = SubagentTranscript.instance.callerNameOf(
          subagentId,
          ownerAgentId: agent?.id ?? '',
          ownerName: agent?.name ?? '',
        );
        final ContextReading? reading = subagentContext(transcript);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.badge_outlined, size: 15, color: cs.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${viewSubtitle(callerName: caller, transcript: transcript)}'
                          ' · $subagentId',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      // 它自己的实时状态（用户可以直接停止/追问它，所以必须看得见）
                      Text(
                        _workingSubagents.contains(subagentId) ? '工作中' : '空闲',
                        style: TextStyle(
                          fontSize: 11,
                          color: _workingSubagents.contains(subagentId)
                              ? Colors.orange
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (reading != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      subagentUsageLine(transcript) ?? '',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '你可以直接在这里给它发消息（它在跑时右下角那颗键是**停止**）；'
              '它自然跑完会把报告注入发起者会话；**你停的那一轮不会**——原因由你自己说。',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            SubagentProcessList(
              messages: transcript,
              emptyHint:
                  '还没有收到它的过程消息：它可能刚被召来（正在准备），'
                  '也可能这一轮只有报告。',
            ),
          ],
        );
      },
    );
  }

  /// teammates 入口图标：有待处理成员时叠一个红色小圆点。
  ///
  /// 与 Agent 列表的红点同一口径（成员未分配模型 / 待审核）。用角标而非替换
  /// 图标，保证入口位置与形状不变，只增加一个"有事要做"的信号。
  Widget _buildTeammatesIcon(Agent agent) {
    const Widget icon = Icon(Icons.hub, size: 20);
    if (agent.pendingMemberCount <= 0) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        icon,
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444),
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 打开任务规范（Spec）面板
  void _openSpecPanel(Agent agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SpecPanel(agent: agent, sessionId: _currentSessionId),
      ),
    );
  }

  // ==================== 多会话管理 ====================

  /// 切换会话：清空当前消息列表并加载目标会话历史
  void _handleSelectSession(ChatSession session) {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    if (session.sessionId == _currentSessionId) return;
    setState(() {
      _currentSession = session;
      _clearWindow();
      _scrollRevision++;
      // 临时员工属于**当前会话**：换会话就回主会话视角（否则会看着上一个会话的过程）
      _viewSubagentId = '';
    });
    _lastSessionByAgent[agent.id] = session.sessionId;
    _syncKnownSessions();
    widget.onSessionChanged?.call(_currentSessionId);
    _loadHistory();
  }

  /// 新建会话：创建后自动选中并切换
  Future<void> _handleCreateSession() async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    try {
      final ChatSession session = await ApiService.createSession(agent.id);
      if (!mounted) return;
      setState(() {
        _sessions.add(session);
        _currentSession = session;
        _clearWindow();
        _scrollRevision++;
        _viewSubagentId = '';
      });
      _lastSessionByAgent[agent.id] = session.sessionId;
      _syncKnownSessions();
      widget.onSessionChanged?.call(_currentSessionId);
      _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('新建会话失败：$e')));
    }
  }

  /// 重命名会话（弹窗输入新标题）
  Future<void> _handleRenameSession(ChatSession session) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null) return;
    final TextEditingController controller = TextEditingController(
      text: session.title,
    );
    final String? newTitle = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(labelText: '会话标题'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty) return;
    try {
      await ApiService.renameSession(agent.id, session.sessionId, newTitle);
      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .map(
              (ChatSession s) => s.sessionId == session.sessionId
                  ? ChatSession(
                      sessionId: s.sessionId,
                      title: newTitle,
                      status: s.status,
                      createdAt: s.createdAt,
                      updatedAt: s.updatedAt,
                      selectedSpecIds: s.selectedSpecIds,
                    )
                  : s,
            )
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  /// 删除会话（默认会话不可删除）：确认后删除并切换到剩余会话
  Future<void> _handleDeleteSession(ChatSession session) async {
    final Agent? agent = widget.selectedAgent;
    if (agent == null || session.isDefault) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除会话「${session.title}」吗？该会话的对话与上下文将被清除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiService.deleteSession(agent.id, session.sessionId);
      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .where((ChatSession s) => s.sessionId != session.sessionId)
            .toList();
        // 若删除的是当前会话，切到剩余首个会话
        if (_currentSessionId == session.sessionId) {
          _currentSession = _sessions.isNotEmpty ? _sessions.first : null;
          _clearWindow();
          _scrollRevision++;
          if (mounted) {
            widget.onSessionChanged?.call(_currentSessionId);
          }
        }
      });
      // 同步更新该 agent 的上次浏览会话（删除当前会话时已切到剩余首个；
      // 删除非当前会话时值不变，赋值无副作用）
      _lastSessionByAgent[agent.id] = _currentSessionId;
      _syncKnownSessions();
      _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除会话失败：$e')));
    }
  }

  /// 触发后端上下文压缩（compact 按钮）
  Future<void> _compactContext(String agentId) async {
    try {
      // 前端重启后会话列表可能仍在异步加载中（_currentSession 为 null）：
      // 此时立即压缩会回退到空的默认会话，误报"无活跃的会话上下文"。
      // 先确保取到实际生效的会话（内部会恢复最近活跃会话）再压缩。
      if (_currentSession == null && _sessions.isEmpty) {
        await _loadSessions();
      }
      final Map<String, dynamic> result = await ApiService.compactAgent(
        agentId,
        sessionId: _currentSessionId,
      );
      if (!mounted) return;
      final bool compressed = result['compressed'] == true;
      final String reason = (result['reason'] ?? '') as String;
      final String message;
      if (compressed) {
        // 压缩**走了哪条路**（内置 / 插件中转站）+ 插件**为什么没接管**：两个键都是
        // 核心新加的可选键（旧核心不返回），缺键时文案与以前逐字一致。
        final String source = (result['source'] ?? '') as String;
        final String via = source == 'relay'
            ? '插件中转站压缩'
            : source == 'builtin'
            ? '内置压缩'
            : '';
        final String skip = ((result['relay_skip_reason'] ?? '') as String)
            .trim();
        final StringBuffer text = StringBuffer(
          '已压缩上下文（当前 ${result['context_size']} 条',
        );
        if (via.isNotEmpty) text.write('，来源：$via');
        if (skip.isNotEmpty) text.write('；插件未接管：$skip');
        text.write('）');
        message = text.toString();
      } else if (reason == 'no_active_session') {
        message = '该 agent 当前没有活跃的会话上下文';
      } else if (reason == 'too_few_messages') {
        message = '对话消息太少，暂无需压缩';
      } else if (reason == 'nothing_to_summarize') {
        message = '最近对话较短，暂无需压缩';
      } else if (reason == 'agent_working') {
        message = '该会话正在处理消息，请稍后再压缩';
      } else if (reason == 'already_compacting') {
        message = '该会话正在压缩中';
      } else {
        message = '上下文无需压缩';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('压缩失败：$e')));
    }
  }
}
