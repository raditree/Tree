"""最小 join 原语 - 多触发齐备条件 + 超时 + partial 交付。

对应 ADR D5 的 join 原语（一期最小版）："齐备条件（计数/键值）+ 超时
（组独立计时）+ partial 交付（缺项清单）；插件自协调为逃生舱"。

一期提供轻量内存实现，供插件在"多中转站触发后 handle（联合数据处理）"
场景复用：

- ``expect_keys``：按来源键齐备（所有声明键到齐，重复键去重忽略）；
- ``expect_count``：按计数齐备；
- 超时：组独立计时（创建时刻起算），``check_timeout()`` 返回 partial
  结果（含缺项清单），供调用方兜底交付；
- 齐备判定在 ``add()`` 返回值中给出（``JoinResult``）；
- 未齐备前可随时 ``reset()`` 重用（内存态，不持久化——一期约束）。
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Any, List, Optional, Set


@dataclass
class JoinResult:
    """join 组结果。"""

    items: List[Any] = field(default_factory=list)
    keys: List[str] = field(default_factory=list)
    missing_keys: List[str] = field(default_factory=list)
    partial: bool = False     # True = 超时/手动 partial 交付
    timed_out: bool = False   # True = 因超时触发


class JoinBuffer:
    """多源 join 缓冲（线程安全，组独立计时）。

    :param expect_keys: 需齐备的来源键集合（与 expect_count 二选一或并用）
    :param expect_count: 需齐备的项数（与 expect_keys 二选一或并用）
    :param timeout: 组超时秒数（``check_timeout`` 用；None = 不超时）
    """

    def __init__(
        self,
        expect_keys: Optional[Set[str]] = None,
        expect_count: Optional[int] = None,
        timeout: Optional[float] = 60.0,
    ) -> None:
        if not expect_keys and not expect_count:
            raise ValueError("JoinBuffer 需至少声明 expect_keys 或 expect_count 之一")
        self.expect_keys = set(expect_keys) if expect_keys else None
        self.expect_count = int(expect_count) if expect_count else None
        self.timeout = float(timeout) if timeout is not None else None
        self._lock = threading.Lock()
        self._items: List[Any] = []
        self._seen: Set[str] = set()
        self._started_at = time.time()
        self._done = False

    # ------------------------------------------------------------------
    # 投递 / 检查
    # ------------------------------------------------------------------
    def add(self, item: Any, key: Optional[str] = None) -> Optional[JoinResult]:
        """加入一项；齐备时返回 ``JoinResult``（并标记完成），否则 None。

        :param key: 来源键（``expect_keys`` 模式下必填；重复键忽略）
        :raises ValueError: expect_keys 模式下未提供 key（fail-closed）
        """
        with self._lock:
            if self._done:
                return None
            if self.expect_keys is not None:
                if key is None:
                    raise ValueError("expect_keys 模式下 add() 必须提供 key")
                if key in self._seen:
                    return None  # 重复触发去重
                self._seen.add(str(key))
                self._items.append(item)
                if self.expect_keys.issubset(self._seen):
                    self._done = True
                    return self._result(partial=False)
                return None
            # 计数模式
            self._items.append(item)
            if self.expect_count is not None and len(self._items) >= self.expect_count:
                self._done = True
                return self._result(partial=False)
            return None

    def check_timeout(self, now: Optional[float] = None) -> Optional[JoinResult]:
        """检查组超时；超时且未齐备时返回 partial 结果（并标记完成）。"""
        if self.timeout is None:
            return None
        current = time.time() if now is None else float(now)
        with self._lock:
            if self._done:
                return None
            if (current - self._started_at) < self.timeout:
                return None
            self._done = True
            result = self._result(partial=True)
            result.timed_out = True
            return result

    def force_partial(self) -> Optional[JoinResult]:
        """手动强制 partial 交付（插件自协调逃生舱）；已交付返回 None。"""
        with self._lock:
            if self._done:
                return None
            self._done = True
            return self._result(partial=True)

    # ------------------------------------------------------------------
    # 状态
    # ------------------------------------------------------------------
    def pending_keys(self) -> List[str]:
        """尚未到齐的来源键清单（expect_keys 模式；其他模式为空）。"""
        with self._lock:
            if self.expect_keys is None:
                return []
            return sorted(self.expect_keys - self._seen)

    def done(self) -> bool:
        """组是否已交付（齐备或 partial）。"""
        with self._lock:
            return self._done

    def count(self) -> int:
        """已收集项数。"""
        with self._lock:
            return len(self._items)

    def reset(self) -> None:
        """重置缓冲（重新计时、清空已收集项），供下一组复用。"""
        with self._lock:
            self._items = []
            self._seen = set()
            self._started_at = time.time()
            self._done = False

    # ------------------------------------------------------------------
    # 内部
    # ------------------------------------------------------------------
    def _result(self, *, partial: bool) -> JoinResult:
        missing: List[str] = []
        if self.expect_keys is not None:
            missing = sorted(self.expect_keys - self._seen)
        return JoinResult(
            items=list(self._items),
            keys=sorted(self._seen),
            missing_keys=missing,
            partial=partial,
            timed_out=False,
        )
