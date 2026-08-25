"""邀请码生命周期管理。

每个等级（common/pro/ultra/beta）维护一个当前有效邀请码：
- 启动时 ``init_invitation_codes()`` 为每个已配置等级生成邀请码并写入 key 文件；
- 后台 ``invitation_code_loop(level)`` 定期检查到期情况：到期后按冷却配置决定
  是否立即重新生成（``cooldown_minutes`` > 0 时先进入冷却，冷却结束才重新生成）；
- 注册/升级流程经 ``validate_code`` / ``consume_code`` 校验与扣减名额，与后台刷新
  通过 ``threading.Lock`` 保证并发安全。

所有时间戳统一使用秒（``time.time()``）。
"""
import asyncio
import logging
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from config.levels import get_level_config, get_levels, get_registration_config

logger = logging.getLogger(__name__)

# 每个等级一条邀请码状态：
# {level: {code, created_at, expires_at, cooldown_until, used_count}}
_codes: Dict[str, Dict[str, Any]] = {}
# 注册/升级（validate/consume）与后台刷新（loop）并发保护
_lock = threading.Lock()

# 后台循环轮询间隔上限（秒），避免频繁空转
_MAX_POLL_INTERVAL = 30
# validity 缺失/为 0 时的兜底轮询间隔（秒）
_DEFAULT_POLL_INTERVAL = 15


def _key_dir() -> Path:
    """key 文件目录：registration.key_dir 非空用其目录，否则用 server/ 目录。"""
    key_dir = (get_registration_config().get("key_dir") or "").strip()
    if key_dir:
        return Path(key_dir)
    return Path(__file__).resolve().parent.parent


def _key_path(level: str) -> Path:
    return _key_dir() / f"invitation_code_{level}.key"


def _write_key_file(level: str, code: str) -> None:
    """把邀请码写入 key 文件（内容为 token 字符串，带换行）。"""
    path = _key_path(level)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(code + "\n", encoding="utf-8")


def _fmt_time(ts: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


def _generate_and_store(level: str, state: Dict[str, Any], now: float) -> str:
    """生成新邀请码并写回 state、写入 key 文件（调用方需持有 _lock）。

    有效期：expires_at = created_at + validity_minutes * 60（秒）。
    """
    cfg = get_level_config(level)
    validity_minutes = int(cfg.get("validity_minutes") or 0)
    code = secrets.token_urlsafe(16)
    expires_at = now + validity_minutes * 60
    state.update(
        {
            "code": code,
            "created_at": now,
            "expires_at": expires_at,
            "cooldown_until": 0,
            "used_count": 0,
        }
    )
    _write_key_file(level, code)
    logger.info(
        "[邀请码] 等级 %s 邀请码已生成: %s（有效期至 %s）",
        level,
        code,
        _fmt_time(expires_at),
    )
    return code


def init_invitation_codes() -> None:
    """启动时为每个已配置等级生成邀请码并写入 key 文件。

    registration.levels 为空（未配置）时安全返回，不生成任何邀请码。
    """
    levels = get_levels()
    if not levels:
        logger.info("[邀请码] 未配置等级，跳过邀请码初始化")
        return
    now = time.time()
    with _lock:
        for level in levels:
            state = _codes.setdefault(level, {})
            _generate_and_store(level, state, now)


def _maybe_refresh(level: str) -> None:
    """检查并处理单个等级邀请码的到期/冷却/重新生成（线程安全）。"""
    now = time.time()
    with _lock:
        state = _codes.get(level)
        if state is None:
            return
        if now < state["expires_at"]:
            return  # 未到期
        cfg = get_level_config(level)
        cooldown_minutes = int(cfg.get("cooldown_minutes") or 0)
        cooldown_until = state.get("cooldown_until") or 0
        if cooldown_minutes > 0 and cooldown_until == 0:
            # 到期且配置了冷却：进入冷却（cooldown_until = now + cooldown_minutes*60），
            # 冷却期间不重新生成
            state["cooldown_until"] = now + cooldown_minutes * 60
            logger.info(
                "[邀请码] 等级 %s 邀请码已到期，进入冷却 %s 分钟（至 %s）",
                level,
                cooldown_minutes,
                _fmt_time(state["cooldown_until"]),
            )
            return
        if cooldown_minutes > 0 and now < cooldown_until:
            return  # 冷却中，等待冷却结束
        # cooldown_minutes<=0 或冷却已结束 -> 立即重新生成
        _generate_and_store(level, state, now)


async def invitation_code_loop(level: str) -> None:
    """后台循环：定期检查该等级邀请码是否到期，按冷却配置自动更新。"""
    while True:
        try:
            _maybe_refresh(level)
        except Exception as exc:  # noqa: BLE001
            logger.warning("[邀请码] 等级 %s 刷新异常: %s", level, exc)
        cfg = get_level_config(level)
        validity_minutes = int(cfg.get("validity_minutes") or 0)
        if validity_minutes > 0:
            sleep_sec = max(1, min(_MAX_POLL_INTERVAL, validity_minutes * 60))
        else:
            sleep_sec = _DEFAULT_POLL_INTERVAL
        await asyncio.sleep(sleep_sec)


def validate_code(code: str) -> Tuple[Optional[str], str]:
    """校验邀请码，返回 (等级, 原因)。

    匹配到有效（未到期、未冷却）邀请码时返回 ``(level, "有效")``；
    否则返回 ``(None, 原因)``，原因为 "无效邀请码" / "邀请码已过期" / "邀请码冷却中"。
    """
    if not code:
        return (None, "无效邀请码")
    now = time.time()
    with _lock:
        for level, state in _codes.items():
            stored = state.get("code")
            if stored and secrets.compare_digest(stored, code):
                cooldown_until = state.get("cooldown_until") or 0
                if cooldown_until and now < cooldown_until:
                    return (None, "邀请码冷却中")
                if now > state["expires_at"]:
                    return (None, "邀请码已过期")
                return (level, "有效")
    return (None, "无效邀请码")


def consume_code(level: str) -> bool:
    """扣减某等级一个注册名额（原子，锁内完成）。

    ``used_count`` 加 1 后若超过该等级 ``max_users`` 则回滚并返回 False（名额耗尽），
    否则返回 True。``max_users`` <= 0 视为不限名额。
    """
    with _lock:
        state = _codes.get(level)
        if state is None:
            return False
        cfg = get_level_config(level)
        max_users = int(cfg.get("max_users") or 0)
        state["used_count"] += 1
        if max_users > 0 and state["used_count"] > max_users:
            state["used_count"] -= 1  # 回滚
            return False
        return True


def get_current_code(level: str) -> str:
    """返回该等级当前邀请码（测试/管理用）；未初始化返回空字符串。"""
    with _lock:
        state = _codes.get(level)
        return state["code"] if state else ""
