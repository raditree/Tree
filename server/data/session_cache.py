"""normal LLM 会话缓存。

按 (user_id, agent_id, session_id) 复用会话，使上下文跨消息累积，支持多轮
记忆与手动 compact。独立成模块，供 chat 编排（聊天创建/compact）与路由
（删除清理）共享，避免循环依赖。

多会话并行（P2）：同一 agent 的多个会话各自持有独立 ``AgentLLMSession``，
上下文互不干扰；``clear_user_agent`` 默认按 agent 级清理（模式切换/删除时
重建全部会话），也可按单个会话精确清理。
"""

import threading
from typing import Any, Dict, Optional, Tuple

from data.session_store import DEFAULT_SESSION

_lock = threading.Lock()
_sessions: Dict[Tuple[str, str, str], Any] = {}


def _key(user_id: str, agent_id: str, session_id: str) -> Tuple[str, str, str]:
    return (user_id, agent_id, session_id)


def get_session(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> Optional[Any]:
    """取缓存会话，不存在返回 None。"""
    with _lock:
        return _sessions.get(_key(user_id, agent_id, session_id))


def set_session(
    user_id: str, agent_id: str, session: Any, session_id: str = DEFAULT_SESSION
) -> None:
    """缓存会话。"""
    with _lock:
        _sessions[_key(user_id, agent_id, session_id)] = session


def pop_session(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> Optional[Any]:
    """移除并返回指定会话，不存在返回 None。"""
    with _lock:
        return _sessions.pop(_key(user_id, agent_id, session_id), None)


def clear_user_agent(
    user_id: str,
    agent_id: str,
    session_id: Optional[str] = None,
) -> int:
    """清理指定用户/agent 的缓存会话，返回清理数量。

    :param session_id: 指定会话 id；None 表示清理该 (user, agent) 的全部会话
    """
    with _lock:
        if session_id is None:
            keys = [k for k in _sessions if k[:2] == (user_id, agent_id)]
        else:
            keys = [k for k in _sessions if k == _key(user_id, agent_id, session_id)]
        for key in keys:
            _sessions.pop(key, None)
        return len(keys)
