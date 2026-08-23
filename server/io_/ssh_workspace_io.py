"""SSH 工作空间 IO - 委托前端 SSH 执行器执行。

SSH 模式下，SSH 连接由**前端（Flutter + dartssh2）发起**（IP 相对前端机器），
后端不再直接连接远端主机。本类与 :class:`io_.workspace_io.LocalWorkspaceIO`
行为一致：把工具调用包装成 ``tool_exec_request`` 经反向 WebSocket 转发给前端，
由前端经其 SSH 会话执行（SFTP / exec），并等待 ``tool_exec_response`` 回传。

前端按自身模式状态路由：收到 ``tool_exec_request`` 时若当前顶部 agent 处于
SSH 模式，则经其 dartssh2 会话执行（远端路径映射 / 穿越防护在前端实现）。
"""
from __future__ import annotations

import logging

from io_.workspace_io import LocalWorkspaceIO

logger = logging.getLogger(__name__)


class SSHWorkspaceIO(LocalWorkspaceIO):
    """SSH 模式实现：与本地模式相同，工具调用委托前端执行器（前端建连 SSH）。"""
