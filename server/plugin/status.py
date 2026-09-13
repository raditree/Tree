"""插件生命周期状态发射器（二期 M1-a）—— ``plugin_status`` 事件（契约 §8 / §15.2）。

职责：

- **全量低频**：实例生命周期变化即发（``registered`` / ``disabled`` / ``destroyed``）；
- **防风暴**：同实例 + 同状态的连续重复在去重窗口内合并为一次；状态跃迁
  必发（跃迁会重置该实例其他状态的窗口）；全局速率超限丢弃并计数；
- **交付语义**：尽力而为、最终一致（对账以快照为准）——发送失败静默、绝不抛出；
- **字段**：按契约 §8 ``{plugin_id, scope, status, reason?, ts}``
  （消息外壳 ``{"type": "plugin_status", "data": ...}``，与 ``plugin_event`` 同形）。

可测性（ADR「参数可配 / 可注入」通例）：

- env：``PLUGIN_STATUS_DEDUP_S``（去重窗口，默认 1.0s）、
  ``PLUGIN_STATUS_MAX_PER_SEC``（速率上限，默认 20）、
  ``PLUGIN_STATUS_RATE_WINDOW_S``（限频窗口，默认 1.0s）；
- 构造注入：``StatusEmitter(dedup_s=..., max_per_sec=..., rate_window_s=...,
  time_fn=..., sender=...)``——``time_fn`` 假时钟可完全确定性控制；
- 全局替换：``get_status_emitter()`` / ``set_status_emitter(...)``（测试隔离）。

只增不改：本模块不触碰任何既有协议与组件；发送失败仅计数（fail-open）。
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Callable, Dict, Optional, Tuple

logger = logging.getLogger(__name__)

ENV_DEDUP_S = "PLUGIN_STATUS_DEDUP_S"
ENV_MAX_PER_SEC = "PLUGIN_STATUS_MAX_PER_SEC"
ENV_RATE_WINDOW_S = "PLUGIN_STATUS_RATE_WINDOW_S"

DEFAULT_DEDUP_S = 1.0
DEFAULT_MAX_PER_SEC = 20
DEFAULT_RATE_WINDOW_S = 1.0

# 去重跟踪表上限（超出时清理过期条目，防长跑内存增长）
MAX_TRACK_ENTRIES = 4096

# 状态枚举（契约 §8）
STATUS_REGISTERED = "registered"
STATUS_DISABLED = "disabled"
STATUS_DESTROYED = "destroyed"


def _env_float(name: str, default: float, *, minimum: float = 0.001) -> float:
    """读取正浮点 env（非法/非正值回退默认）。"""
    try:
        value = float(os.environ.get(name, "") or default)
    except (TypeError, ValueError):
        return default
    return value if value >= minimum else default


def _env_int(name: str, default: int) -> int:
    """读取正整数 env（非法/非正值回退默认）。"""
    try:
        value = int(float(os.environ.get(name, "") or default))
    except (TypeError, ValueError):
        return default
    return value if value >= 1 else default


def _default_sender(user_id: str, message: Dict[str, Any]) -> bool:
    """默认发送通道：复用 ``sdk.ws_push`` 的调度链（延迟 import 防循环）。"""
    try:
        from plugin import sdk as _sdk  # noqa: PLC0415

        return bool(_sdk.ws_push_message(user_id, message))
    except Exception:  # noqa: BLE001
        logger.debug("plugin_status 默认发送通道异常（忽略）", exc_info=True)
        return False


class StatusEmitter:
    """``plugin_status`` 发射器（线程安全；去重 + 限频 + 分类计数）。

    计数键（``stats()``）：``emitted`` / ``deduped`` / ``throttled`` /
    ``send_failed`` / ``skipped_no_user``。
    """

    def __init__(
        self,
        *,
        dedup_s: Optional[float] = None,
        max_per_sec: Optional[int] = None,
        rate_window_s: Optional[float] = None,
        time_fn: Optional[Callable[[], float]] = None,
        sender: Optional[Callable[[str, Dict[str, Any]], bool]] = None,
    ) -> None:
        self._dedup_s = (
            float(dedup_s)
            if dedup_s is not None
            else _env_float(ENV_DEDUP_S, DEFAULT_DEDUP_S)
        )
        self._max_per_sec = (
            int(max_per_sec)
            if max_per_sec is not None
            else _env_int(ENV_MAX_PER_SEC, DEFAULT_MAX_PER_SEC)
        )
        self._rate_window_s = (
            float(rate_window_s)
            if rate_window_s is not None
            else _env_float(ENV_RATE_WINDOW_S, DEFAULT_RATE_WINDOW_S)
        )
        self._time_fn = time_fn or time.monotonic
        self._sender = sender
        self._lock = threading.Lock()
        # (实例键或 plugin_id|scope, 状态) → 最近一次发射时刻（去重窗口）
        self._last: Dict[Tuple[str, str], float] = {}
        self._win_start = 0.0
        self._win_count = 0
        self._stats: Dict[str, int] = {
            "emitted": 0,
            "deduped": 0,
            "throttled": 0,
            "send_failed": 0,
            "skipped_no_user": 0,
        }

    # ------------------------------------------------------------------
    def emit(
        self,
        plugin_id: str,
        scope: Optional[Dict[str, str]],
        status: str,
        *,
        reason: str = "",
        inst_key: str = "",
    ) -> bool:
        """发射一条 ``plugin_status``。

        筛选失败（缺 user_id / 去重 / 限频）与发送失败均返回 ``False``；
        绝不抛出（fail-open，绝不影响生命周期主流程）。
        """
        try:
            scope_d = dict(scope or {})
            user_id = str(scope_d.get("user_id", "") or "")
            if not user_id:
                with self._lock:
                    self._stats["skipped_no_user"] += 1
                logger.debug(
                    "plugin_status 缺 user_id（跳过）: %s %s", plugin_id, status
                )
                return False

            now = float(self._time_fn())
            key = (str(inst_key or f"{plugin_id}|{scope_d}"), str(status))
            with self._lock:
                last = self._last.get(key)
                if last is not None and (now - last) < self._dedup_s:
                    self._stats["deduped"] += 1
                    return False
                self._last[key] = now
                # 跃迁必发：同实例其他状态的去重窗口即刻失效——去重仅约束
                # 连续同状态的重复；registered→destroyed→registered 的第三发
                # 属真实跃迁，不得被旧 registered 窗口吞掉（M1 复验①裁定）。
                inst = key[0]
                for stale in [k for k in self._last if k[0] == inst and k != key]:
                    del self._last[stale]
                if len(self._last) > MAX_TRACK_ENTRIES:
                    cutoff = now - max(self._dedup_s * 60.0, 60.0)
                    self._last = {
                        k: v for k, v in self._last.items() if v >= cutoff
                    }
                if (now - self._win_start) >= self._rate_window_s:
                    self._win_start = now
                    self._win_count = 0
                if self._win_count >= self._max_per_sec:
                    self._stats["throttled"] += 1
                    return False
                self._win_count += 1

            message: Dict[str, Any] = {
                "type": "plugin_status",
                "data": {
                    "plugin_id": str(plugin_id),
                    "scope": scope_d,
                    "status": str(status),
                    "reason": str(reason or ""),
                    "ts": time.time(),
                },
            }
            sender = self._sender or _default_sender
            ok = False
            try:
                ok = bool(sender(user_id, message))
            except Exception:  # noqa: BLE001
                ok = False
                logger.debug("plugin_status 发送异常（忽略）", exc_info=True)
            with self._lock:
                if ok:
                    self._stats["emitted"] += 1
                else:
                    self._stats["send_failed"] += 1
            return ok
        except Exception:  # noqa: BLE001
            logger.debug("plugin_status 发射异常（忽略）", exc_info=True)
            return False

    # ------------------------------------------------------------------
    def stats(self) -> Dict[str, Any]:
        """发射器计数快照。"""
        with self._lock:
            return dict(self._stats)

    def reset(self) -> None:
        """清空去重/限频状态与计数（测试清理用）。"""
        with self._lock:
            self._last.clear()
            self._win_start = 0.0
            self._win_count = 0
            for key in self._stats:
                self._stats[key] = 0


# ----------------------------------------------------------------------
# 模块级单例与门面（registry 生命周期触点通过 emit_status 调用）
# ----------------------------------------------------------------------
_emitter: StatusEmitter = StatusEmitter()


def get_status_emitter() -> StatusEmitter:
    """当前全局发射器（测试 / 观测用）。"""
    return _emitter


def set_status_emitter(emitter: StatusEmitter) -> None:
    """替换全局发射器（测试注入 / 独立验证用）。"""
    global _emitter
    _emitter = emitter


def emit_status(
    plugin_id: str,
    scope: Optional[Dict[str, str]],
    status: str,
    *,
    reason: str = "",
    inst_key: str = "",
) -> bool:
    """门面：向全局发射器投递一条生命周期事件。"""
    return _emitter.emit(
        plugin_id, scope, status, reason=reason, inst_key=inst_key
    )
