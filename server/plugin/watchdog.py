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
- **巡检联动（M3/D-P2-7）**：``start()`` 周期 ``check()``——连续无进度
  （或超 ``max_run_seconds``）判死 run；同一实例连续判死达阈 → 回调停用
  （registry 接线发 ``plugin_status(disabled)``）；``auto_tick=True`` 的 run
  由框架代续期（慢处理不误杀）。
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Callable, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# 建议续期间隔（秒）：与前端 tool_exec_progress 上报周期（10s）对齐
DEFAULT_BEAT_INTERVAL = 10.0
# 滑窗判死窗口（秒）：距最近一次进度续期超过该值判定疑似卡死（与执行器一致）
DEFAULT_STALL_SECONDS = 60.0
# 巡检循环周期（秒）：M3 巡检默认 10s（env ``PLUGIN_WATCHDOG_CHECK_INTERVAL_S`` 可配）
DEFAULT_CHECK_INTERVAL = 10.0
# 判死双阈值（保守参数，D-P2-7；构造可注入、env 可覆盖）：
# - ``DEAD_STRIKES``：同一次 run 连续 N 轮巡检均判定停滞/超限 → 判死该 run；
# - ``MAX_CONSECUTIVE_DEAD``：同一实例连续判死 N 个 run → 停用该实例订阅（disabled）。
DEFAULT_DEAD_STRIKES = 2
DEFAULT_MAX_CONSECUTIVE_DEAD = 2


def _env_float(name: str, default: float, *, minimum: float = 0.001) -> float:
    """读取正浮点 env（非法/过小回退默认；M3 可测性通例）。"""
    try:
        value = float(os.environ.get(name, "") or default)
    except (TypeError, ValueError):
        return float(default)
    return value if value >= minimum else float(default)


def _env_int(name: str, default: int) -> int:
    """读取正整数 env（非法/非正值回退默认；M3 可测性通例）。"""
    try:
        value = int(float(os.environ.get(name, "") or default))
    except (TypeError, ValueError):
        return int(default)
    return value if value >= 1 else int(default)


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
        check_interval: Optional[float] = None,
        dead_strikes: Optional[int] = None,
        max_consecutive_dead: Optional[int] = None,
    ) -> None:
        self.stall_seconds = float(stall_seconds)
        self.beat_interval = float(beat_interval)
        self._lock = threading.Lock()
        self._tasks: Dict[str, Dict[str, object]] = {}
        self._instances: Dict[str, float] = {}
        # M3 巡检参数（构造参数优先、env 覆盖；均可注入供测试缩参）
        self.check_interval = (
            float(check_interval)
            if check_interval is not None
            else _env_float("PLUGIN_WATCHDOG_CHECK_INTERVAL_S", DEFAULT_CHECK_INTERVAL)
        )
        self.dead_strikes = (
            int(dead_strikes)
            if dead_strikes is not None
            else _env_int("PLUGIN_WATCHDOG_DEAD_STRIKES", DEFAULT_DEAD_STRIKES)
        )
        self.max_consecutive_dead = (
            int(max_consecutive_dead)
            if max_consecutive_dead is not None
            else _env_int(
                "PLUGIN_WATCHDOG_MAX_CONSECUTIVE_DEAD",
                DEFAULT_MAX_CONSECUTIVE_DEAD,
            )
        )
        # 巡检循环状态（M3）
        self._loop_thread: Optional[threading.Thread] = None
        self._loop_stop = threading.Event()
        self._judged_dead_total = 0
        self._dead_streak: Dict[str, int] = {}
        self._disable_handler: Optional[Callable[[str, str], None]] = None

    # ------------------------------------------------------------------
    # 处理级：单次处理的进度续期与判死
    # ------------------------------------------------------------------
    def start_task(
        self,
        task_key: str,
        owner: object = None,
        *,
        auto_tick: bool = True,
        max_run_seconds: Optional[float] = None,
    ) -> None:
        """登记一个处理任务（开始监视）。

        :param task_key: 任务唯一键（如 ``plugin:{plugin_id}:{scope}``）
        :param owner: 归属标识（fail-closed 续期校验用；
            建议传 (user_id, team_id, agent_id, session_id) 元组）
        :param auto_tick: True=框架代续期（巡检循环自动刷新进度，仅硬上限判定）；
            False=由 ``beat`` / ``note_progress`` 显式续期（漏报参与判死）
        :param max_run_seconds: 硬上限（秒；None=不限）；超限经巡检判死释放
        """
        now = time.time()
        with self._lock:
            self._tasks[str(task_key)] = {
                "owner": _norm_owner(owner),
                "started_at": now,
                "progress_at": now,
                "auto_tick": bool(auto_tick),
                "max_run_seconds": (
                    float(max_run_seconds) if max_run_seconds is not None else None
                ),
                "strikes": 0,
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
        """登记任务完成并移除监视（提供 owner 时必须匹配，fail-closed）。

        M3：正常完成 = 实例存活信号 → 重置该实例的"连续判死"计数。
        """
        with self._lock:
            task = self._tasks.get(str(task_key))
            if task is None:
                return False
            if owner is not None and _norm_owner(owner) != task["owner"]:
                return False
            self._tasks.pop(str(task_key), None)
            owner_key = task.get("owner") or ()
            if owner_key:
                self._dead_streak[str(owner_key[0])] = 0
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
        """刷新实例心跳（实例存活/活跃标记）。

        M3：心跳 = 存活信号 → 重置该实例的"连续判死"计数（防误停用）。
        """
        current = time.time() if now is None else float(now)
        with self._lock:
            self._instances[str(instance_key)] = current
            self._dead_streak[str(instance_key)] = 0

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
        """移除实例心跳记录（实例销毁时调用）。

        M3：同步清理"连续判死"计数（实例已销毁，无需保留）。
        """
        with self._lock:
            self._instances.pop(str(instance_key), None)
            self._dead_streak.pop(str(instance_key), None)

    def instance_count(self) -> int:
        """当前登记的实例心跳数（观测用）。"""
        with self._lock:
            return len(self._instances)

    # ------------------------------------------------------------------
    # 契约 §6 兼容别名（薄包装；M3 起参数全量生效）
    # ``auto_tick`` 自动续期与 ``max_run_seconds`` 硬上限已由巡检循环执行
    # （M3/D-P2-7）；续期亦可用 ``note_progress`` 显式驱动。
    # ------------------------------------------------------------------
    def register_run(
        self,
        instance_key: object,
        run_id: str,
        *,
        auto_tick: bool = True,
        max_run_seconds: Optional[float] = 600.0,
    ) -> None:
        """登记一个插件处理 run（M3 起：``auto_tick`` / ``max_run_seconds`` 参与巡检）。"""
        self.start_task(
            str(run_id),
            owner=instance_key,
            auto_tick=auto_tick,
            max_run_seconds=max_run_seconds,
        )

    def note_progress(self, instance_key: object, run_id: str) -> bool:
        """续期（fail-closed 归属校验）：仅 ``(instance_key, run_id)`` 匹配才生效。"""
        return self.beat(str(run_id), owner=instance_key)

    def finish_run(self, instance_key: object, run_id: str) -> bool:
        """结束并移除 run 监视（归属必须匹配）。"""
        return self.finish_task(str(run_id), owner=instance_key)

    def heartbeat_instance(self, instance_key: object) -> None:
        """实例级心跳刷新（TTL 治理用；不参与判死）。"""
        self.touch_instance(str(instance_key))

    # ------------------------------------------------------------------
    # 巡检循环（M3：D-P2-7 / D-P2-8）——周期 check + 判死联动
    # ------------------------------------------------------------------
    def set_disable_handler(
        self, handler: Optional[Callable[[str, str], None]]
    ) -> None:
        """设置"连续判死达阈 → 停用实例"回调（签名 ``(instance_key, reason)``）。"""
        self._disable_handler = handler

    def judged_dead_count(self) -> int:
        """累计判死 run 数（供快照 / 面板；M3 观测补全）。"""
        with self._lock:
            return int(self._judged_dead_total)

    def start(self, interval: Optional[float] = None) -> bool:
        """启动巡检循环（幂等；周期默认 ``check_interval``，可覆盖缩参）。"""
        with self._lock:
            if self._loop_thread is not None and self._loop_thread.is_alive():
                return False
            seconds = self.check_interval
            if interval is not None:
                try:
                    seconds = max(0.01, float(interval))
                except (TypeError, ValueError):
                    seconds = self.check_interval
            self._loop_stop.clear()
            self._loop_thread = threading.Thread(
                target=self._loop,
                args=(seconds,),
                name="plugin-watchdog-patrol",
                daemon=True,
            )
            self._loop_thread.start()
        logger.info(
            "[plugin:watchdog] 巡检循环已启动（间隔 %.2fs；判死阈值=%d 次/%.0fs，"
            "连续判死阈值=%d）",
            seconds,
            self.dead_strikes,
            self.stall_seconds,
            self.max_consecutive_dead,
        )
        return True

    def stop(self, timeout: float = 1.0) -> None:
        """停止巡检循环（幂等；停止后可再次 start）。"""
        with self._lock:
            thread = self._loop_thread
            self._loop_thread = None
            self._loop_stop.set()
        if thread is not None and thread.is_alive():
            thread.join(timeout=timeout)
            logger.info("[plugin:watchdog] 巡检循环已停止")

    def check(self, now: Optional[float] = None) -> Dict[str, object]:
        """执行一轮巡检（可显式传 ``now``，便于测试确定性调用）。

        规则（保守参数；fail-safe 方向，绝不抛出）：

        - ``auto_tick=True`` 的 run：框架代续期（刷新进度时间），仅执行
          ``max_run_seconds`` 硬上限判定（慢处理不误杀）；
        - 停滞（距最近进度 ≥ ``stall_seconds``）或超限（距开始 ≥
          ``max_run_seconds``）：连续 ``dead_strikes`` 轮命中 → 判死
          （移除 run 监视 + 计数 + 回调）；期间任意续期即重新计数；
        - 同一实例连续判死 ≥ ``max_consecutive_dead`` 个 run（存活信号：
          实例心跳 / run 正常完成会重置）→ 触发停用回调（幂等由下游保证）。
        """
        current = time.time() if now is None else float(now)
        judged: List[str] = []
        to_disable: List[Tuple[str, str]] = []
        with self._lock:
            for key, task in list(self._tasks.items()):
                started = float(task.get("started_at", current))
                if bool(task.get("auto_tick", True)):
                    # 自动续期：慢处理不误杀（仅保留硬上限判定）
                    task["progress_at"] = current
                progress = float(task.get("progress_at", started))
                max_run = task.get("max_run_seconds")
                overdue = False
                if max_run is not None:
                    try:
                        overdue = (current - started) >= float(max_run)
                    except (TypeError, ValueError):
                        overdue = False
                stalled = (current - progress) >= self.stall_seconds
                if not (stalled or overdue):
                    if task.get("strikes"):
                        task["strikes"] = 0
                    continue
                strikes = int(task.get("strikes", 0)) + 1
                task["strikes"] = strikes
                if strikes < self.dead_strikes:
                    continue
                # 判死：移除 run 监视 + 计数 + 连续判死归集
                self._tasks.pop(key, None)
                self._judged_dead_total += 1
                judged.append(key)
                owner = task.get("owner") or ()
                inst_key = str(owner[0]) if owner else ""
                if not inst_key:
                    continue
                streak = int(self._dead_streak.get(inst_key, 0)) + 1
                self._dead_streak[inst_key] = streak
                if streak >= self.max_consecutive_dead:
                    self._dead_streak[inst_key] = 0
                    to_disable.append((inst_key, "watchdog_dead"))
            handler = self._disable_handler
        for key in judged:
            logger.warning(
                "[plugin:watchdog] run 判死（连续 %d 轮无进度/超限）: %s",
                self.dead_strikes,
                key,
            )
        for inst_key, reason in to_disable:
            logger.warning(
                "[plugin:watchdog] 连续判死达阈 → 请求停用实例: %s（reason=%s）",
                inst_key,
                reason,
            )
            if handler is not None:
                try:
                    handler(inst_key, reason)
                except Exception:  # noqa: BLE001
                    logger.exception(
                        "[plugin:watchdog] 停用回调异常（忽略）: %s", inst_key
                    )
        return {
            "runs_judged_dead": int(self._judged_dead_total),
            "judged_runs": judged,
            "disable_pending": [k for k, _r in to_disable],
        }

    def _loop(self, interval: float) -> None:
        """巡检线程主循环（异常不终止循环）。"""
        while not self._loop_stop.wait(interval):
            try:
                self.check()
            except Exception:  # noqa: BLE001
                logger.exception("[plugin:watchdog] 巡检异常（已忽略，继续下一轮）")
        logger.debug("[plugin:watchdog] 巡检线程退出")
