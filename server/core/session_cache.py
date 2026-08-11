"""normal LLM 会话缓存。

按 (user_id, agent_id) 复用会话，使上下文跨消息累积，支持多轮记忆与手动
compact。独立成模块，供 main.py（聊天创建/compact）与 routes.py（删除清理）
共享，避免循环依赖。
"""

import threading
from typing import Any, Dict, Optional, Tuple

_lock = threading.Lock()
_sessions: Dict[Tuple[str, str], Any] = {}


def get_session(user_id: str, agent_id: str) -> Optional[Any]:
    """取缓存会话，不存在返回 None。"""
    with _lock:
        return _sessions.get((user_id, agent_id))


def set_session(user_id: str, agent_id: str, session: Any) -> None:
    """缓存会话。"""
    with _lock:
        _sessions[(user_id, agent_id)] = session


def pop_session(user_id: str, agent_id: str) -> Optional[Any]:
    """移除并返回指定会话，不存在返回 None。"""
    with _lock:
        return _sessions.pop((user_id, agent_id), None)


def clear_user_agent(user_id: str, agent_id: str) -> int:
    """清理指定用户/agent 的所有缓存会话，返回清理数量。"""
    with _lock:
        keys = [k for k in _sessions if k == (user_id, agent_id)]
        for key in keys:
            _sessions.pop(key, None)
        return len(keys)