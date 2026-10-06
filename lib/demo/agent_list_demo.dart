/// Agent 列表外观 demo —— 不连核心、不申请单实例锁，可与正式版同时跑。
///
///   flutter run -t lib/demo/agent_list_demo.dart -d windows
library;
import 'package:flutter/material.dart';

import '../ui/models/agent.dart';
import '../ui/widgets/agent_list.dart';

void main() => runApp(const _DemoApp());

class _DemoApp extends StatelessWidget {
  const _DemoApp();
  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: ThemeData(useMaterial3: true),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: const _DemoPage(),
      );
}

class _DemoPage extends StatelessWidget {
  const _DemoPage();

  static final List<Agent> _agents = <Agent>[
    // 团队 A · TOP（teamId 空 = 顶层）
    Agent(
      id: 'a1', name: '契门', type: 'normal',
      lastMessage: '## 轮次汇报（常规）\n- 已完成 3 项\n- 待办 2 项',
      lastMessageTime: DateTime.now().subtract(const Duration(seconds: 30)),
      pendingMemberCount: 2, teamId: '',
    ),
    // 团队 A · 成员（teamId = 'a1' ⇒ 与契门同色条；有未读）
    Agent(
      id: 'a2', name: '季衡', type: 'normal',
      lastMessage: 'The build passed with 3 warnings...',
      lastMessageTime: DateTime.now().subtract(const Duration(minutes: 5)),
      unreadCount: 5, teamId: 'a1',
    ),
    // 团队 B · TOP（与团队 A 不同色条；预览含长正文）
    Agent(
      id: 'a3', name: '凌川', type: 'normal',
      lastMessage: '上下文已压缩（来源：内置 compact）',
      lastMessageTime: DateTime.now().subtract(const Duration(hours: 5)),
      teamId: '',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: 280,
              child: AgentList(
                agents: _agents,
                onAgentSelected: (_) {},
                onClearHistory: (_) {},
                onDelete: (_) {},
              ),
            ),
            const VerticalDivider(width: 1),
            const Expanded(child: Center(child: Text('demo 右侧留白'))),
          ],
        ),
      );
}