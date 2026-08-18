"""API 价格预算控制。

提供 BudgetTracker 按 (user, top_agent) 追踪 API 用量与预算消耗，
以及 PriceCalculator 根据模型配置或 OpenAI 价格计算 token 成本。
"""

import logging
import threading
from typing import Any, Dict, List, Optional, Tuple

from core.conversation_store import save_budget_setting

logger = logging.getLogger(__name__)

# 预算消耗比例提醒阈值（每 10% 提醒一次，含耗尽）
_BUDGET_THRESHOLDS = list(range(10, 101, 10))


class PriceCalculator:
    """根据模型配置计算 token 成本。

    优先使用模型配置中的显式价格（input_price / output_price /
    cached_input_price，单位为美元/百万 token），未配置时默认 0。
    """

    def __init__(self, model_config: Any) -> None:
        """从模型配置的 extra 字典读取价格。

        :param model_config: ModelConfig 实例，其 extra 字段包含价格信息
        """
        extra = getattr(model_config, "extra", {}) or {}
        self.input_price: float = float(extra.get("input_price", 0))
        self.output_price: float = float(extra.get("output_price", 0))
        self.cached_input_price: float = float(extra.get("cached_input_price", 0))

    @property
    def has_pricing(self) -> bool:
        """是否有有效的价格配置（至少输入或输出价格非零）。"""
        return self.input_price > 0 or self.output_price > 0

    def calculate_cost(
        self,
        input_tokens: int,
        output_tokens: int,
        cached_tokens: int = 0,
    ) -> float:
        """计算 token 消耗的总成本（美元）。

        :param input_tokens: 输入 token 数（含缓存命中部分）
        :param output_tokens: 输出 token 数
        :param cached_tokens: 缓存命中的输入 token 数
        :return: 总成本（美元），保留 6 位小数
        """
        # 实际计费的输入 token = 总输入 - 缓存命中（缓存命中按折扣价计费）
        billed_input = max(0, input_tokens - cached_tokens)
        cost = (
            billed_input * self.input_price / 1_000_000
            + cached_tokens * self.cached_input_price / 1_000_000
            + output_tokens * self.output_price / 1_000_000
        )
        return round(cost, 6)


class BudgetTracker:
    """按 (user_id, top_agent_id) 追踪 API 用量与预算消耗。

    线程安全。
    """

    def __init__(self, budget: float = 0.0) -> None:
        """初始化预算追踪器。

        :param budget: 总预算（美元）
        """
        self._lock = threading.Lock()
        self.budget: float = budget
        self.input_tokens: int = 0
        self.output_tokens: int = 0
        self.cached_tokens: int = 0
        self._notified_thresholds: set[int] = set()

    # ------------------------------------------------------------------
    # 用量记录
    # ------------------------------------------------------------------
    def reset(self) -> None:
        """重置所有用量计数器（用户发送新消息到顶层 agent 时调用）。"""
        with self._lock:
            self.input_tokens = 0
            self.output_tokens = 0
            self.cached_tokens = 0
            self._notified_thresholds.clear()

    def clear_thresholds(self) -> None:
        """仅清除已通知的阈值记录，不清除计数器。

        预算金额变更时调用，使阈值基于新预算重新评估。
        """
        with self._lock:
            self._notified_thresholds.clear()

    def record_usage(
        self,
        prompt_tokens: int,
        completion_tokens: int,
        cached_tokens: int = 0,
    ) -> None:
        """记录一次 API 调用的 token 消耗。

        :param prompt_tokens: 本次调用的输入 token 数
        :param completion_tokens: 本次调用的输出 token 数
        :param cached_tokens: 本次调用缓存命中的输入 token 数
        """
        with self._lock:
            self.input_tokens += prompt_tokens
            self.output_tokens += completion_tokens
            self.cached_tokens += cached_tokens

    # ------------------------------------------------------------------
    # 查询
    # ------------------------------------------------------------------
    def get_usage_snapshot(self) -> Dict[str, Any]:
        """获取当前用量快照。"""
        with self._lock:
            return {
                "input_tokens": self.input_tokens,
                "output_tokens": self.output_tokens,
                "cached_tokens": self.cached_tokens,
                "total_tokens": self.input_tokens + self.output_tokens,
                "budget": self.budget,
            }

    def get_cost(self, price_calc: PriceCalculator) -> float:
        """根据价格计算器计算当前总成本。"""
        with self._lock:
            return price_calc.calculate_cost(
                self.input_tokens, self.output_tokens, self.cached_tokens
            )

    def get_remaining(self, price_calc: PriceCalculator) -> float:
        """获取剩余预算（美元）。"""
        return round(self.budget - self.get_cost(price_calc), 6)

    def get_percentage(self, price_calc: PriceCalculator) -> float:
        """获取预算消耗百分比（0-100）。"""
        cost = self.get_cost(price_calc)
        if self.budget <= 0:
            return 0.0
        return min(100.0, round(cost / self.budget * 100, 1))

    def is_exhausted(self, price_calc: PriceCalculator) -> bool:
        """预算是否已耗尽。"""
        return self.budget > 0 and self.get_remaining(price_calc) <= 0

    # ------------------------------------------------------------------
    # 阈值提醒
    # ------------------------------------------------------------------
    def check_and_mark_threshold(
        self, price_calc: PriceCalculator
    ) -> Optional[int]:
        """检查是否有新的预算消耗比例阈值达到，返回该阈值百分比。

        每个阈值只会返回一次。返回 None 表示无新阈值。
        """
        pct = self.get_percentage(price_calc)
        with self._lock:
            for t in _BUDGET_THRESHOLDS:
                if pct >= t and t not in self._notified_thresholds:
                    self._notified_thresholds.add(t)
                    return t
        return None

    def get_budget_summary(
        self, price_calc: PriceCalculator, compact: bool = False
    ) -> str:
        """生成预算摘要文本（供注入 tool result 或系统提示词）。

        compact=True 时返回精简版（仅剩余金额与消耗比例），避免完整 token
        明细在每个工具结果后反复注入上下文导致"输入滚雪球"（累计 input
        tokens 异常偏大、成本虚高）。完整明细用于预算告警 / WebSocket 推送等
        面向用户的场景。
        """
        with self._lock:
            cost = price_calc.calculate_cost(
                self.input_tokens, self.output_tokens, self.cached_tokens
            )
            remaining = self.budget - cost if self.budget > 0 else 0
            pct = (
                min(100.0, round(cost / self.budget * 100, 1))
                if self.budget > 0
                else 0
            )
            if compact:
                return f"[预算] 剩余 ${remaining:.2f}（已消耗 {pct}%）"
            return (
                f"[预算] 已消耗 ${cost:.4f}（输入 {self.input_tokens} tokens, "
                f"输出 {self.output_tokens} tokens, "
                f"缓存命中 {self.cached_tokens} tokens）, "
                f"剩余 ${remaining:.4f}, "
                f"已消耗 {pct}%"
            )

    def get_budget_ws_data(self, price_calc: PriceCalculator) -> Dict[str, Any]:
        """生成 WebSocket 推送的预算更新数据。"""
        with self._lock:
            cost = price_calc.calculate_cost(
                self.input_tokens, self.output_tokens, self.cached_tokens
            )
            remaining = self.budget - cost if self.budget > 0 else 0
            pct = (
                min(100.0, round(cost / self.budget * 100, 1))
                if self.budget > 0
                else 0
            )
            return {
                "budget": self.budget,
                "used": round(cost, 6),
                "remaining": round(remaining, 6),
                "percentage": pct,
                "input_tokens": self.input_tokens,
                "output_tokens": self.output_tokens,
                "cached_tokens": self.cached_tokens,
            }


# 全局预算追踪器字典
# 键: (user_id, top_agent_id) -> BudgetTracker
_budget_trackers: Dict[Tuple[str, str], BudgetTracker] = {}
_trackers_lock = threading.Lock()


def get_budget_tracker(user_id: str, top_agent_id: str) -> BudgetTracker:
    """获取或创建预算追踪器。

    首次创建时尝试从 SQLite 加载已有预算设置，实现重启后恢复。
    """
    key = (user_id, top_agent_id)
    with _trackers_lock:
        if key not in _budget_trackers:
            tracker = BudgetTracker()
            # 从 SQLite 加载已有预算
            try:
                from core.conversation_store import load_budget_setting

                saved = load_budget_setting(user_id, top_agent_id)
                if saved is not None and saved > 0:
                    tracker.budget = saved
            except Exception:
                logger.warning("加载预算设置失败", exc_info=True)
            _budget_trackers[key] = tracker
        return _budget_trackers[key]


def reset_budget_tracker(user_id: str, top_agent_id: str) -> None:
    """重置预算追踪器（用户发送新消息到顶层 agent 时调用）。"""
    tracker = get_budget_tracker(user_id, top_agent_id)
    tracker.reset()


def set_budget(user_id: str, top_agent_id: str, budget: float) -> None:
    """设置预算金额。

    保留已有用量计数器，仅清除阈值记录，使阈值基于新预算重新评估。
    同时持久化到 SQLite，重启后自动恢复。
    """
    tracker = get_budget_tracker(user_id, top_agent_id)
    tracker.budget = budget
    tracker.clear_thresholds()
    # 持久化到 SQLite
    try:
        save_budget_setting(user_id, top_agent_id, budget)
    except Exception:
        logger.warning("保存预算设置失败", exc_info=True)


def get_budget_status(
    user_id: str, top_agent_id: str, model_config: Any
) -> Dict[str, Any]:
    """获取预算状态（用于 API 返回）。"""
    tracker = get_budget_tracker(user_id, top_agent_id)
    price_calc = PriceCalculator(model_config)
    data = tracker.get_budget_ws_data(price_calc)
    data["budget"] = tracker.budget
    return data