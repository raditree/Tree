import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// Git 历史查看组件
///
/// 通过 API 获取工作空间的 Git 提交历史与分支列表，以 Tab 切换方式展示：
/// - "提交历史" Tab：展示提交列表，每条包含 hash（前 7 位）、message、时间，
///   点击可展开查看完整 message。
/// - "分支列表" Tab：展示所有分支，当前分支高亮显示。
///
/// 提交图标使用蓝色 Icons.commit，加载中显示 CircularProgressIndicator。
class GitHistory extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 所属顶层 agent ID（SSH/本地模式下区分布局用，决定查询哪种执行源的 git）
  final String? topAgentId;

  /// 刷新触发器：递增时重新加载提交历史与分支列表
  final int refreshTrigger;

  const GitHistory({
    super.key,
    required this.workspaceId,
    this.topAgentId,
    this.refreshTrigger = 0,
  });

  @override
  State<GitHistory> createState() => _GitHistoryState();
}

class _GitHistoryState extends State<GitHistory>
    with SingleTickerProviderStateMixin {
  /// Tab 控制器（0=提交历史，1=分支列表）
  late final TabController _tabController;

  /// 提交历史列表
  List<Map<String, dynamic>> _commits = [];

  /// 分支列表
  List<String> _branches = [];

  /// 当前分支名称
  String _currentBranch = '';

  /// 是否正在加载提交历史
  bool _isLoadingCommits = true;

  /// 是否正在加载分支列表
  bool _isLoadingBranches = true;

  /// 提交历史加载错误
  String? _commitsError;

  /// 分支列表加载错误
  String? _branchesError;

  /// 当前展开查看详情的提交 hash
  String? _expandedHash;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadCommits();
    _loadBranches();
  }

  @override
  void didUpdateWidget(GitHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工作空间 / 顶层 agent / 刷新触发器变化时重新加载
    if (oldWidget.workspaceId != widget.workspaceId ||
        oldWidget.topAgentId != widget.topAgentId ||
        oldWidget.refreshTrigger != widget.refreshTrigger) {
      _loadCommits();
      _loadBranches();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 加载 Git 提交历史
  Future<void> _loadCommits() async {
    setState(() {
      _isLoadingCommits = true;
      _commitsError = null;
    });
    try {
      final List<Map<String, dynamic>> commits = await ApiService.getGitLog(
        widget.workspaceId,
        topAgentId: widget.topAgentId ?? '',
      );
      if (mounted) {
        setState(() {
          _commits = commits;
          _isLoadingCommits = false;
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _commitsError = e.toString().replaceFirst('Exception: ', '');
          _isLoadingCommits = false;
        });
      }
    }
  }

  /// 加载 Git 分支列表
  Future<void> _loadBranches() async {
    setState(() {
      _isLoadingBranches = true;
      _branchesError = null;
    });
    try {
      final Map<String, dynamic> data = await ApiService.getGitBranches(
        widget.workspaceId,
        topAgentId: widget.topAgentId ?? '',
      );
      final List<dynamic> rawBranches =
          data['branches'] as List<dynamic>? ?? [];
      final List<String> branches = rawBranches.map((dynamic b) {
        // 分支可能是字符串或 {"name": "..."} 对象
        if (b is String) return b;
        if (b is Map) return b['name']?.toString() ?? '';
        return b.toString();
      }).where((String s) => s.isNotEmpty).toList();
      if (mounted) {
        setState(() {
          _branches = branches;
          _currentBranch = data['current']?.toString() ?? '';
          _isLoadingBranches = false;
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _branchesError = e.toString().replaceFirst('Exception: ', '');
          _isLoadingBranches = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Tab 栏
        Container(
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
              Tab(text: '提交历史'),
              Tab(text: '分支列表'),
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).dividerColor,
        ),
        // Tab 内容
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildCommitsTab(),
              _buildBranchesTab(),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建提交历史 Tab
  Widget _buildCommitsTab() {
    if (_isLoadingCommits) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_commitsError != null) {
      return _buildMessageBody(
        icon: Icons.error_outline,
        iconColor: const Color(0xFFEF4444),
        message: _commitsError!,
      );
    }
    if (_commits.isEmpty) {
      return _buildMessageBody(
        icon: Icons.history,
        iconColor: Theme.of(context).colorScheme.outline,
        message: '暂无提交记录',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _commits.length,
      separatorBuilder: (BuildContext context, int index) {
        return Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).scaffoldBackgroundColor,
          indent: 40,
        );
      },
      itemBuilder: (BuildContext context, int index) {
        return _buildCommitItem(_commits[index]);
      },
    );
  }

  /// 构建单条提交项
  ///
  /// 点击切换展开/折叠，展开时显示完整 commit message。
  Widget _buildCommitItem(Map<String, dynamic> commit) {
    final String hash = _getString(commit, ['hash', 'sha', 'commit', 'id']);
    final String shortHash =
        hash.isNotEmpty ? hash.substring(0, hash.length < 7 ? hash.length : 7) : '';
    final String message = _getString(commit, ['message', 'msg', 'subject']);
    final String date = _getString(commit, ['date', 'time', 'created_at', 'committed_at']);
    final String author = _getString(commit, ['author', 'author_name', 'name']);

    final bool isExpanded = _expandedHash == hash;
    final cs = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () {
        setState(() {
          _expandedHash = isExpanded ? null : hash;
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 提交图标
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.commit,
                size: 20,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 10),
            // 内容区
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：message
                  Text(
                    message.isEmpty ? '(无提交信息)' : message,
                    maxLines: isExpanded ? null : 1,
                    overflow: isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 第二行：hash + 作者 + 时间
                  Row(
                    children: [
                      if (shortHash.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            shortHash,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (author.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      if (date.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(date),
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 展开/折叠指示箭头
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: cs.outline,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建分支列表 Tab
  Widget _buildBranchesTab() {
    if (_isLoadingBranches) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_branchesError != null) {
      return _buildMessageBody(
        icon: Icons.error_outline,
        iconColor: const Color(0xFFEF4444),
        message: _branchesError!,
      );
    }
    if (_branches.isEmpty) {
      return _buildMessageBody(
        icon: Icons.account_tree_outlined,
        iconColor: Theme.of(context).colorScheme.outline,
        message: '暂无分支',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _branches.length,
      separatorBuilder: (BuildContext context, int index) {
        return Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).scaffoldBackgroundColor,
          indent: 40,
        );
      },
      itemBuilder: (BuildContext context, int index) {
        return _buildBranchItem(_branches[index]);
      },
    );
  }

  /// 构建单条分支项
  ///
  /// 当前分支使用浅蓝背景 + 主题色文字高亮。
  Widget _buildBranchItem(String branch) {
    final bool isCurrent = branch == _currentBranch;
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: isCurrent ? cs.primaryContainer : Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              isCurrent ? Icons.account_tree : Icons.call_split,
              size: 18,
              color: isCurrent ? cs.primary : cs.outline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                branch,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                  color: isCurrent ? cs.primary : cs.onSurface,
                ),
              ),
            ),
            if (isCurrent)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '当前',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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

  /// 从 JSON 中按候选键名顺序提取字符串值
  ///
  /// 兼容后端不同字段命名（如 hash/sha、date/time 等）。
  String _getString(Map<String, dynamic> json, List<String> keys) {
    for (final String key in keys) {
      final dynamic value = json[key];
      if (value != null && value.toString().isNotEmpty) {
        return value.toString();
      }
    }
    return '';
  }

  /// 格式化日期
  ///
  /// 尝试解析 ISO 字符串并格式化为 "MM-DD HH:mm"，
  /// 解析失败时原样返回（截断到 16 个字符）。
  String _formatDate(String date) {
    if (date.isEmpty) return '';
    final DateTime? dt = DateTime.tryParse(date);
    if (dt == null) {
      return date.length > 16 ? date.substring(0, 16) : date;
    }
    final String month = dt.month.toString().padLeft(2, '0');
    final String day = dt.day.toString().padLeft(2, '0');
    final String hour = dt.hour.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }
}
