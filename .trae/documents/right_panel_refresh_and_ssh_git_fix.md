# 修复：右栏非即时刷新 + SSH 模式 git 历史为空

## 摘要

两个技术债务：

1. **右栏（文件浏览 / Git 历史 / Todo）不能在文件等变更后即时刷新**，必须"切走再切回"才更新。
2. **SSH 模式下 Git 历史一直"暂无提交"**。

本文给出最小、决策完备的修复方案。

---

## 现状与根因分析

### 问题 A：右栏不即时刷新

- 右栏 [`FilePanel`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/file_panel.dart) 用 `_fileRefreshTrigger` 触发 `FileTree` / `TodoPanel` 重载（[file_panel.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/file_panel.dart#L62-L70)），但该触发器**只在**本地模式切换（[L93-L96](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/file_panel.dart#L93-L96)、[L78](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/file_panel.dart#L78)）与文件上传（[L248-L251](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/file_panel.dart#L248-L251)）时递增。
- `GitHistory`（[git_history.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/git_history.dart#L56-L61)）**完全没有**刷新触发器，只在 `initState` 加载一次。
- `TodoPanel` 靠 `refreshTrigger` + `sessionId` 变化才重载。
- **"切 Tab 再切回"之所以能刷新**，是因为右栏子分区是 `TabBarView` 的子节点，切换/离开时其 `State` 被销毁重建，`initState` 重新加载数据。这是"偶然生效"而非设计的刷新机制。
- 后端**不发** `todo_update` 等专用变更事件；工具执行只广播 `tool_start` / `tool_end`（[chat.py L1342/L1353](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L1342-L1353)）。所以"模型写文件 / 更新 todo / 做 git 提交"没有任何信号通知右栏。

### 问题 B：SSH 模式 git 历史为空

- git 端点 `io_/routes.py` 的 [`git_log`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L836-L872) 与 [`git_branches`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L875-L908) 只有**两条执行路径**：
  - **本地模式**：经反向 WS 转前端 `LocalExecutor`。
  - **其余全部**：`docker_manager.git_log`（docker 容器 或 docker 不可用时的本机目录）。
- **没有 SSH 分支**。而 agent 的 shell/工具已用 `mode_resolver` 区分 cloud/local/ssh（[mode_resolver.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/mode_resolver.py#L53-L74)），SSH 下返回 `SSHWorkspaceIO`（[ssh_workspace_io.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_workspace_io.py#L178-L199) 的 `git_log` 已存在）。
- 因此 SSH 模式下，git 端点落到 `docker_manager`，查询的是 **docker 容器/本机目录**而非 SSH 远端工作空间。远端有提交、本地/容器那份没提交 → `git log --all` 空 → 前端显示"暂无提交历史"。**"解析"本身没错，错在查询了错误的源。**

---

## 修改方案

### 后端：SSH 模式 git 走 SSHWorkspaceIO

**1. `server/io_/ssh_workspace_io.py` — 新增 `git_branches`**
与现有 [`git_log`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_workspace_io.py#L178-L199) 同构：

```python
async def git_branches(self, workspace_id: str) -> Dict[str, Any]:
    cwd = self._remote_path(workspace_id, "")
    full = f"cd {shlex.quote(cwd)} && git branch -a"
    result = await asyncio.to_thread(self._exec, ["sh", "-c", full])
    branches: List[str] = []
    current = ""
    if not result.get("error") and result.get("exit_code") == 0:
        for line in (result.get("stdout", "") or "").splitlines():
            s = line.strip()
            if not s:
                continue
            branches.append(s[2:].strip() if s.startswith("* ") else s)
            if s.startswith("* "):
                current = s[2:].strip()
    return {"branches": branches, "current": current,
            "exit_code": result.get("exit_code", 0)}
```

**2. `server/io_/routes.py` — `git_log` / `git_branches` 增加 SSH 分派**

在本地模式分支之后、`docker_manager` 兜底之前插入（与本地分支用同样的 `user_id` / `local_key` 判定）：

```python
# SSH 模式：转发到远端主机的 SSHWorkspaceIO
mode = mode_resolver.resolve_mode(user_id, top_agent_id or workspace_id)
if mode == "ssh":
    from io_.ssh_workspace_io import SSHWorkspaceIO
    ssh = SSHWorkspaceIO(state.ssh_manager, user_id, top_agent_id or workspace_id)
    result = await ssh.git_log(workspace_id, limit=int(limit))  # 或 ssh.git_branches(workspace_id)
    if result.get("error"):
        raise HTTPException(status_code=500, detail=result)
    return {"commits": result.get("commits", [])}   # branches 端点为 {"branches","current"}
```

需在文件顶部补充导入：`import state`、`from io_ import mode_resolver`（按需）。

> 说明：`git_diff / merge / fetch` 不在 `GitHistory` 面板展示范围内，本次不动，保持现状（docker/local 专用）。

**3. 前端 `GitHistory` 必须传 `topAgentId`**
SSH 注册以 `(user_id, top_agent_id)` 为 mode key（[mode_resolver._is_ssh](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/mode_resolver.py#L43-L50)）。当前 `git_history.dart` 调 `ApiService.getGitLog(workspaceId)`（[L77](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/git_history.dart#L77)）、`getGitBranches(workspaceId)`（[L102](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/git_history.dart#L102)）未传 `top_agent_id` → mode key 落到 `workspace_id`，SSH 判定失败。因此即使修好后端，仍会退到 docker。必须把 `topAgentId` 透传（`api_service` 已支持该参数，[api_service.dart L291-L299](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/api_service.dart#L291-L299)）。

### 前端：右栏即时刷新

**4. 新增 `lib/io/workspace_refresh_service.dart`**（全局变更通知，仿照现有 `LocalExecutorService` 的 ChangeNotifier 单例模式）

```dart
import 'package:flutter/foundation.dart';

/// 工作空间数据变更通知（文件 / Git / Todo）。
/// 中栏 MessagePanel 收到工具结束事件时触发，右栏 FilePanel 监听后刷新，
/// 无需"切 Tab 再切回"。
class WorkspaceRefreshService extends ChangeNotifier {
  WorkspaceRefreshService._();
  static final WorkspaceRefreshService instance = WorkspaceRefreshService._();

  DateTime? _lastNotify;
  static const Duration cooldown = Duration(milliseconds: 600);

  /// 节流通知：避免工具循环中连续 tool_end 导致高频拉取。
  void notifyWorkspaceChanged() {
    final DateTime now = DateTime.now();
    if (_lastNotify != null &&
        now.difference(_lastNotify!) < cooldown) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }
}
```

**5. `lib/ui/widgets/message_panel.dart` — 工具结束触发刷新**
在 [`_handleIncomingMessage`](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/message_panel.dart#L280) 的 `tool_end` 分支（[L373-L382](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/message_panel.dart#L373-L382)）末尾调用：

```dart
WorkspaceRefreshService.instance.notifyWorkspaceChanged();
```

覆盖 写文件/编辑/终端/git 工具/todo 工具 的全部 `tool_end`。文件顶部加 `import '../../io/workspace_refresh_service.dart';`。

**6. `lib/ui/widgets/file_panel.dart` — 订阅 + 参数透传**
- `initState` 里 `WorkspaceRefreshService.instance.addListener(_onWorkspaceChanged)`；`dispose` 里 `removeListener`。回调 `_refreshFileTree()`（复用现有递增 `_fileRefreshTrigger` 的逻辑）。
- `GitHistory` 新增两个字段并传入：`topAgentId: widget.topAgentId`、`refreshTrigger: _fileRefreshTrigger`。

**7. `lib/ui/widgets/git_history.dart` — 支持 `topAgentId` + `refreshTrigger`**
- 新增 `final String? topAgentId;` 与 `final int refreshTrigger;`（默认值）。
- 两处 API 调用带上 `topAgentId`。
- 增加 `didUpdateWidget`：`workspaceId / topAgentId / refreshTrigger` 任一变化时，同时 `_loadCommits()` 与 `_loadBranches()`。

---

## 假设与决策

- **刷新粒度**：挂在 WS `tool_end`，`WorkspaceRefreshService` 内 600ms 节流。工具循环中高频 `tool_end` 被合并，避免刷屏拉取；单次回合结尾必然有一次刷新。用户最关心的"文件/todo/git 变更后可见"，会在对应工具结束的瞬间反映到右栏。
- **不引入轮询**：无定时器、无每秒查文件列表，维持低负载。
- **保留原有"切 Tab 刷新"能力**：不破坏，只是变成不需要。
- **SSH git 修复范围**：仅 `git_log` + `git_branches`（即 `GitHistory` 面板展示的两项）。`diff / merge / fetch` 端点未动。
- **远端须为 git 仓库**：若远端工作空间初始化了 git 才有提交；SSH 修复后查询正确源，空/非仓库会显示空或错误（比现在的"永远是空"更接近真相）。
- **已知但没有本文范围内处理（建议后续）**：SSH 模式下**文件浏览/内容**（`get_files` / `get_file_content`）同样走 `docker_manager` 而非远端，存在"右栏文件与 SSH 工作空间不一致"的隐患。这与本次"右栏刷新"是不同问题；如需一并修正，可把 file 端点同样用 `mode_resolver` 分派（结构与本方案后端 git 一致），列为可选跟进。

---

## 验证

**后端**
- 对 `SSHWorkspaceIO.git_log / git_branches` 补单测（mock `_exec`）：正常多分支/当前分支/空输出解析。
- `server` 目录执行：`python -m pytest tests/test_ssh_workspace_io.py -q` 及冒烟现有 io 测试，确认无回归。
- 手动：切 SSH 模式 → 在远端工作空间 git commit → 打开 Git 历史应显示提交；再让 agent 写一个文件 → 切到"文件浏览"应立即显示（无需切 Tab）。

**前端**
- `flutter analyze` 无新错误。
- 手动：agent 使用 todo 工具更新 todo → Todo 标签即时变化；agent 写/建文件 → 文件浏览即时变化；agent 提交 → Git 历史即时变化；期间频繁工具调用不卡顿（节流生效）。

**注意**：后端改动需重启服务（按偏好不擅动后端进程，实施后再请用户确认重启）；前端热重载即可。