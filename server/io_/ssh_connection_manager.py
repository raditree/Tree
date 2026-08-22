"""SSH 连接管理器 - 懒连接 + transport 探活重连 + 连接测试。

SSH 运行模式下，后端直接以 paramiko 连接用户配置的远端主机，把工作空间
工具调用（文件读写 / 终端命令）转发到远端执行。配置持久化在
``data/ssh_store.py``，本模块负责：

- :meth:`register`：测试连接 → 成功则落库并激活（spec：先测试后生效）
- :meth:`unregister`：关闭连接并删除配置（回退云端）
- :meth:`is_ssh`：判定某 top agent 是否处于 SSH 模式
- :meth:`get_connection`：返回懒建立的 paramiko client（transport 失活自动重连）

连接以 ``(user_id, agent_id)`` 为键缓存；所有 paramiko 操作均为阻塞式，
由调用方（SSHWorkspaceIO 的 async 方法）经 ``asyncio.to_thread`` 切线程。
"""
from __future__ import annotations

import logging
import threading
from typing import Any, Dict, Optional, Tuple

import paramiko

from data import ssh_store

logger = logging.getLogger(__name__)


def _build_connect_args(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """由存储配置构造 paramiko connect 关键字参数。"""
    args: Dict[str, Any] = {
        "hostname": cfg.get("host", ""),
        "port": int(cfg.get("port", 22) or 22),
        "username": cfg.get("username", ""),
        "timeout": 10,
        "allow_agent": False,
        "look_for_keys": False,
    }
    auth_type = cfg.get("auth_type", "password")
    if auth_type == "key" and cfg.get("private_key_path"):
        args["key_filename"] = cfg.get("private_key_path")
    else:
        args["password"] = cfg.get("password", "")
    return args


class SSHConnectionManager:
    """管理某用户到各顶部 agent 的 SSH 连接（懒连接 + 探活重连）。"""

    def __init__(self) -> None:
        # key = f"{user_id}:{agent_id}" -> paramiko.SSHClient
        self._clients: Dict[str, paramiko.SSHClient] = {}
        self._lock = threading.Lock()

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
    # 连接测试 / 注册 / 注销
    # ------------------------------------------------------------------
    def test_connection(self, cfg: Dict[str, Any]) -> Tuple[bool, str]:
        """测试 SSH 连接是否可用（不缓存连接）。

        :return: ``(ok, message_or_empty)``
        """
        if not cfg.get("host"):
            return False, "host 不能为空"
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(**{k: v for k, v in _build_connect_args(cfg).items()})
            return True, ""
        except paramiko.AuthenticationException:
            return False, "SSH 认证失败（用户名/密码或私钥错误）"
        except paramiko.SSHException as exc:
            return False, f"SSH 连接失败: {exc}"
        except Exception as exc:  # noqa: BLE001
            return False, f"SSH 连接异常: {exc}"
        finally:
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass

    def register(
        self, user_id: str, agent_id: str, cfg: Dict[str, Any]
    ) -> Tuple[bool, str]:
        """注册 SSH 模式：先测试连接，成功后持久化并（懒）激活。

        与 local 模式的互斥校验由调用方（WS/REST 层经 ModeResolver）执行。
        """
        ok, message = self.test_connection(cfg)
        if not ok:
            return False, message
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
        # 清掉旧缓存连接，下次 get_connection 按新配置重连
        self._drop_client(user_id, agent_id)
        logger.info(
            "用户 %s 顶部 agent %s 已启用 SSH 模式（%s@%s）",
            user_id, agent_id, cfg.get("username"), cfg.get("host"),
        )
        return True, ""

    def unregister(self, user_id: str, agent_id: str) -> bool:
        """注销 SSH 模式：关闭连接并删除配置，返回是否实际删除。"""
        self._drop_client(user_id, agent_id)
        removed = ssh_store.delete_connection(user_id, agent_id)
        if removed:
            logger.info("用户 %s 顶部 agent %s 已注销 SSH 模式", user_id, agent_id)
        return removed

    # ------------------------------------------------------------------
    # 连接获取（懒连接 + 探活重连）
    # ------------------------------------------------------------------
    def _key(self, user_id: str, agent_id: str) -> str:
        return f"{user_id}:{agent_id}"

    def _drop_client(self, user_id: str, agent_id: str) -> None:
        key = self._key(user_id, agent_id)
        with self._lock:
            client = self._clients.pop(key, None)
        if client is not None:
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass

    def get_connection(self, user_id: str, agent_id: str) -> paramiko.SSHClient:
        """返回该 top agent 的 SSH client（懒建立；失活/缺失则重建）。

        需保证已处于 SSH 模式（is_ssh 为真），否则抛出 RuntimeError。
        """
        cfg = ssh_store.get_connection(user_id, agent_id)
        if cfg is None:
            raise RuntimeError("该 agent 未启用 SSH 模式")
        key = self._key(user_id, agent_id)
        client = self._clients.get(key)
        if client is not None:
            transport = client.get_transport()
            if transport is not None and transport.is_active():
                return client
            # transport 失活：关闭并重建
            self._drop_client(user_id, agent_id)
        # 懒建立
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(**{k: v for k, v in _build_connect_args(cfg).items()})
        with self._lock:
            self._clients[key] = client
        return client

    def close_all(self) -> None:
        """关闭全部缓存连接（服务关闭时调用）。"""
        with self._lock:
            clients = list(self._clients.values())
            self._clients.clear()
        for client in clients:
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass
