"""插件看门狗 - 进度续期 + 滑窗判死 + fail-closed 归属校验。

语义对齐 ``server/io_/local_executor.py`` 的 ``tool_exec_progress`` 模型
（10s 续期 / 60s 滑窗判死 / 归属校验），供插件体系两类用途复用：

- **处理级**（单次处理防超时/防悬挂）：插件处理期间周期性 ``beat()``
  续期；调用方可用 ``is_stalled()`` 判定"疑似卡死"，避免空等。
- **实例级**（常驻实例存活管理）：``touch_instance()`` 记录实例心跳，
  ``collect_stale_instances()`` 收集空闲超时的实例供清理。

设计要点（对应 ADR D7 / 02-discussion.md 分歧 2 裁定）：
- **fail-closed 归属校验**：``beat()`` 只有任务键存在且 owner 匹配才续期，
  乱报/跨归属续期一律拒绝（照搬 ``LocalExecutorClient.note_progress`` 语义）。
- **时间可注入**：所有判定函数接受 ``now`` 参数，便于单测与确定性验证。
- **存储独立**：不与执行器 / 会话缓存共享任何状态，纯内存、线程安全；
  插件心跳使用专用键（plugin_progress 语义），参数与执行器对齐 10s/60s。
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# 建议续期间隔（秒）：与前端 tool_exec_progress 上报周期（10s）对齐
DEFAULT_BEAT_INTERVAL = 10.0
# 滑窗判死窗口（秒）：距最近一次进度续期超过该值判定疑似卡死（与执行器一致）
DEFAULT_STALL_SECONDS = 60.0


def _norm_owner(owner: object) -> Tuple[str, ...]:
    """把 owner 归一化为可比较元组（字符串/序列均可，None 视为空）。"""
    if owner is None:
        return ()
    if isinstance(owner, str):
        return (owner,)
    return tuple(str(x) for x in owner)


class ProgressWatchdog:
    """通用进度看门狗（线程安全）。

    :param stall_seconds: 滑窗判死窗口（缺省 60s，与 tool_exec_progress 对齐）
    :param beat_interval: 建议续期间隔（缺省 10s；仅作提示常量，不强制）
    """

    def __init__(
        self,
        stall_seconds: float = DEFAULT_STALL_SECONDS,
        beat_interval: float = DEFAULT_BEAT_INTERVAL,
    ) -> None:
        self.stall_seconds = float(stall_seconds)
        self.beat_interval = float(beat_interval)
        self._lock = threading.Lock()
        self._tasks: Dict[str, Dict[str, object]] = {}
        self._instances: Dict[str, float] = {}

    # ------------------------------------------------------------------
    # 处理级：单次处理的进度续期与判死
    # ------------------------------------------------------------------
    def start_task(self, task_key: str, owner: object = None) -> None:
        """登记一个处理任务（开始监视）。

        :param task_key: 任务唯一键（如 ``plugin:{plugin_id}:{scope}``）
        :param owner: 归属标识（fail-closed 续期校验用；
            建议传 (user_id, team_id, agent_id, session_id) 元组）
        """
        now = time.time()
        with self._lock:
            self._tasks[str(task_key)] = {
                "owner": _norm_owner(owner),
                "started_at": now,
                "progress_at": now,
            }

    def beat(self, task_key: str, owner: object = None) -> bool:
        """上报一次进度（续期）。

        仅当任务存在且 owner 匹配时生效（fail-closed：不能证明归属即拒绝）。
        """
        with self._lock:
            task = self._tasks.get(str(task_key))
            if task is None:
                return False
            if _norm_owner(owner) != task["owner"]:
                return False
            task["progress_at"] = time.time()
            return True

    def finish_task(self, task_key: str, owner: object = None) -> bool:
        """登记任务完成并移除监视（提供 owner 时必须匹配，fail-closed）。"""
        with self._lock:
            task = self._tasks.get(str(task_key))
            if task is None:
                return False
            if owner is not None and _norm_owner(owner) != task["owner"]:
                return False
            self._tasks.pop(str(task_key), None)
            return True

    def is_stalled(self, task_key: str, now: Optional[float] = None) -> bool:
        """任务是否疑似卡死（无进度滑出窗口）。任务不存在返回 False。"""
        current = time.time() if now is None else float(now)
        with self._lock:
            task = self._tasks.get(str(task_key))
            if task is None:
                return False
            return (current - float(task["progress_at"])) >= self.stall_seconds

    def stalled_tasks(self, now: Optional[float] = None) -> List[str]:
        """所有疑似卡死的任务键列表（供巡检/失效处理）。"""
        current = time.time() if now is None else float(now)
        with self._lock:
            return [
                key
                for key, task in self._tasks.items()
                if (current - float(task["progress_at"])) >= self.stall_seconds
            ]

    def task_count(self) -> int:
        """当前在监视的任务数（观测用）。"""
        with self._lock:
            return len(self._tasks)

    # ------------------------------------------------------------------
    # 实例级：常驻实例的存活心跳（heartbeat_at → stale 清理）
    # ------------------------------------------------------------------
    def touch_instance(self, instance_key: str, now: Optional[float] = None) -> None:
        """刷新实例心跳（实例存活/活跃标记）。"""
        current = time.time() if now is None else float(now)
        with self._lock:
            self._instances[str(instance_key)] = current

    def is_instance_stale(
        self, instance_key: str, ttl: float, now: Optional[float] = None
    ) -> bool:
        """实例心跳是否超过 ttl 未刷新（疑似失活）。

        未登记的实例返回 True（保守：没有心跳视为不可信）。
        """
        current = time.time() if now is None else float(now)
        with self._lock:
            last = self._instances.get(str(instance_key))
            if last is None:
                return True
            return (current - last) >= float(ttl)

    def collect_stale_instances(
        self, ttl: float, now: Optional[float] = None
    ) -> List[str]:
        """收集心跳超时的实例键列表（供 TTL 清理；Pin 实例由调用方过滤）。"""
        current = time.time() if now is None else float(now)
        with self._lock:
            return [
                key
                for key, last in self._instances.items()
                if (current - last) >= float(ttl)
            ]

    def drop_instance(self, instance_key: str) -> None:
        """移除实例心跳记录（实例销毁时调用）。"""
        with self._lock:
            self._instances.pop(str(instance_key), None)

    def instance_count(self) -> int:
        """当前登记的实例心跳数（观测用）。"""
        with self._lock:
            return len(self._instances)

    # ------------------------------------------------------------------
    # 契约 §6 兼容别名（一期薄包装）
    # ⚠ 一期约束：``auto_tick`` 自动续期与 ``max_run_seconds`` 硬上限尚未由
    # 监控循环执行（续期由调用方 ``note_progress`` 驱动）；参数仅存档，
    # 待二期启用（见 artifacts/test-report.md 差距清单）。
    # ------------------------------------------------------------------
    def register_run(
        self,
        instance_key: object,
        run_id: str,
        *,
        auto_tick: bool = True,
        max_run_seconds: Optional[float] = 600.0,
    ) -> None:
        """登记一个插件处理 run（等价 ``start_task(run_id, owner=instance_key)``）。"""
        self.start_task(str(run_id), owner=instance_key)

    def note_progress(self, instance_key: object, run_id: str) -> bool:
        """续期（fail-closed 归属校验）：仅 ``(instance_key, run_id)`` 匹配才生效。"""
        return self.beat(str(run_id), owner=instance_key)

    def finish_run(self, instance_key: object, run_id: str) -> bool:
        """结束并移除 run 监视（归属必须匹配）。"""
        return self.finish_task(str(run_id), owner=instance_key)

    def heartbeat_instance(self, instance_key: object) -> None:
        """实例级心跳刷新（TTL 治理用；不参与判死）。"""
        self.touch_instance(str(instance_key))
