"""SSH 模式配置管理 - 仅负责配置持久化与模式判定，不再建立连接。

SSH 运行模式下，SSH 连接改由**前端（Flutter + dartssh2）发起**，IP 相对
前端机器；后端只做：

- :meth:`is_ssh`：判定某 top agent 是否处于 SSH 模式
- :meth:`get_config`：读取持久化的 SSH 连接配置
- :meth:`register`：持久化配置并激活模式（**不再测试连接**，连接测试由前端完成）
- :meth:`unregister`：删除配置并退出 SSH 模式

配置持久化在 ``data/ssh_store.py``。工具执行由
``io_.ssh_workspace_io.SSHWorkspaceIO`` 经反向 WebSocket 委托给前端执行器。
"""
from __future__ import annotations

import logging
from typing import Any, Dict, Optional, Tuple

from data import ssh_store

logger = logging.getLogger(__name__)


class SSHConnectionManager:
    """管理某用户到各顶部 agent 的 SSH 模式配置（不持有任何连接）。"""

    # ------------------------------------------------------------------
    # 模式判定
    # ------------------------------------------------------------------
    def is_ssh(self, user_id: str, agent_id: str) -> bool:
        """该 top agent 是否处于 SSH 模式（存在持久化配置即视为 SSH 模式）。"""
        return ssh_store.get_connection(user_id, agent_id) is not None

    def get_config(self, user_id: str, agent_id: str) -> Optional[Dict[str, Any]]:
        """读取持久化的 SSH 连接配置。"""
        return ssh_store.get_connection(user_id, agent_id)

    # ------------------------------------------------------------------
    # 注册 / 注销
    # ------------------------------------------------------------------
    def register(
        self, user_id: str, agent_id: str, cfg: Dict[str, Any]
    ) -> Tuple[bool, str]:
        """注册 SSH 模式：持久化配置并激活。

        连接测试由前端完成（``register_ssh_executor`` 发出前先在前端建连
        验证，IP 相对前端），后端不再发起连接测试。
        """
        ssh_store.save_connection(
            user_id=user_id,
            agent_id=agent_id,
            host=cfg.get("host", ""),
            port=int(cfg.get("port", 22) or 22),
            username=cfg.get("username", ""),
            auth_type=cfg.get("auth_type", "password"),
            password=cfg.get("password", ""),
            private_key_path=cfg.get("private_key_path", ""),
            remote_base_dir=cfg.get("remote_base_dir", ""),
        )
        logger.info(
            "用户 %s 顶部 agent %s 已启用 SSH 模式（%s@%s）",
            user_id, agent_id, cfg.get("username"), cfg.get("host"),
        )
        return True, ""

    def unregister(self, user_id: str, agent_id: str) -> bool:
        """注销 SSH 模式：删除配置，返回是否实际删除。"""
        removed = ssh_store.delete_connection(user_id, agent_id)
        if removed:
            logger.info("用户 %s 顶部 agent %s 已注销 SSH 模式", user_id, agent_id)
        return removed
