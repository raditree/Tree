"""内置 message 工具 - 团队通信。

仅覆盖通信子域（成员/团队管理在独立的 ``team`` 工具中）：
- send_message：向成员/直属 leader/其他 TOP 点对点发消息（支持一对多）
- broadcast：向**直属成员**广播（不跨层级）
- list_members / list_teams：与 team 工具共用同一份实现（基类）
- wait_for：等待成员完成当前工作（轮询实时执行态，修复假完成竞态）

任务派发不再有专门 action：派活 = send_message 写明工作内容与预期产出；
验收 = 成员回发消息 + leader 直接 read
``agentspace/{member_id}/.self/activity.log`` 或共享目录中的产出。
"""

import logging
import time
from typing import Any, Dict, List

from prompt import versions

from tool.team_base import TeamToolBase

logger = logging.getLogger(__name__)

MESSAGE_ACTIONS = (
    "send_message",
    "broadcast",
    "list_members",
    "list_teams",
    "wait_for",
)


class MessageTool(TeamToolBase):
    """message 工具：点对点消息、直属广播、等待完成。"""

    # wait_for 启动宽限/轮询参数（类属性便于测试 patch）
    START_GRACE_SEC = 5
    POLL_INTERVAL_SEC = 2

    # ------------------------------------------------------------------
    # 工具定义与分发
    # ------------------------------------------------------------------
    def get_tool_definition(self) -> dict:
        return {
            "type": "function",
            "function": {
                "name": "message",
                "description": versions.active_tool_description("message"),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": list(MESSAGE_ACTIONS),
                            "description": "send_message=点对点（可一对多，"
                                         "目标支持成员 id/名称、自己的直属 leader、"
                                         "其他 TOP）；broadcast=仅向你的**直属成员**"
                                         "广播（不跨层级，无直属时会明确返回 0 收件人）；"
                                         "wait_for=等待成员完成当前工作；"
                                         "list_members/list_teams=查名单。"
                                         "派活直接用 send_message 写明工作内容与预期产出。",
                        },
                        "target_member_id": {
                            "type": "string",
                            "description": "send_message 目标：成员 ID/名称、直属 "
                                           "leader ID 或其他 TOP 的 ID/名称；调用前"
                                           "先 list_members/list_teams 获取确切值",
                        },
                        "target_ids": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "send_message 一对多时的目标 ID/名称列表"
                                           "（与 target_member_id 二选一）",
                        },
                        "target_member_ids": {
                            "type": "string",
                            "description": "wait_for 必填：成员 ID/名称列表，"
                                           "多个用英文逗号分隔（如 'm1,m2'）",
                        },
                        "message": {
                            "type": "string",
                            "description": "消息内容（send_message/broadcast 必填）。"
                                           "派活时写清工作内容、预期产出与完成后回复要求",
                        },
                        "timeout": {
                            "type": "integer",
                            "description": "wait_for 最长等待秒数，默认 300，上限 600",
                        },
                    },
                    "required": ["action"],
                },
            },
        }

    def execute(self, arguments: dict) -> dict:
        dispatch = {
            "send_message": self._action_send_message,
            "broadcast": self._action_broadcast,
            "list_members": self._action_list_members,
            "list_teams": self._action_list_teams,
            "wait_for": self._action_wait_for,
        }
        return self._dispatch_actions(dispatch, arguments)

    # ------------------------------------------------------------------
    # send_message
    # ------------------------------------------------------------------
    def _deliver_one(self, resolved: Dict[str, Any], message: str) -> str:
        """向单个已解析目标投递，返回 sent / rejected 状态。"""
        target_id = resolved.get("id", "")
        if self.message_dispatcher is not None:
            try:
                r = self.message_dispatcher(
                    self.user_id,
                    [target_id],
                    message,
                    source_agent_id=self.agent_id,
                    team_id=self.team_id,
                    extra={"session_id": self.session_id},
                )
                if isinstance(r, dict):
                    if target_id in (r.get("sent") or []):
                        return "sent"
                    if r.get("status") in ("sent", "partial") and not r.get("rejected"):
                        return "sent"
                    return "rejected"
            except Exception as exc:  # noqa: BLE001
                logger.warning("send_message dispatcher 失败，回退 broker: %s", exc)
        # broker 回退
        try:
            return "sent" if self._dispatch_one_fallback(resolved, message) else "rejected"
        except Exception as exc:  # noqa: BLE001
            logger.warning("send_message broker 投递失败 %s: %s", target_id, exc)
            return "rejected"

    @staticmethod
    def _unknown_reason_hint(reason: str) -> str:
        if reason == "cross_top_denied":
            return ("跨 TOP 顶层通信仅 TOP agent 之间可用；如需联系其他团队，"
                    "请把内容发给你的直属 leader，由其 TOP 转达")
        if reason == "empty":
            return "目标为空"
        return ("目标不存在或不可达：团队内按成员名称/id 寻址（先 list_members），"
                "跨 TOP 按 TOP 名称寻址（先 list_teams，且仅 TOP 自己可发起）")

    def _action_send_message(self, arguments: dict) -> dict:
        """点对点发送（支持一对多），返回逐目标投递明细。"""
        target_raw = arguments.get("target_member_id") or arguments.get("target_ids")
        message = arguments.get("message", "")
        if not target_raw:
            return {
                "error": "缺少 target_member_id（或 target_ids）",
                "hint": "请先 list_members 获取成员 ID/名称",
                "generated_at": self._now(),
            }
        if not message:
            return {
                "error": "缺少 message",
                "hint": "消息内容不能为空；派活时写清工作内容与预期产出",
                "generated_at": self._now(),
            }
        if isinstance(target_raw, str):
            targets = [target_raw]
        elif isinstance(target_raw, list):
            targets = [t for t in target_raw if isinstance(t, str) and t.strip()]
        else:
            return {
                "error": "target_member_id 必须是字符串或字符串列表",
                "generated_at": self._now(),
            }
        if not targets:
            return {"error": "目标列表为空", "generated_at": self._now()}

        details: List[Dict[str, Any]] = []
        sent: List[str] = []
        rejected: List[Dict[str, str]] = []
        unknown: List[Dict[str, str]] = []
        for raw in targets:
            resolved = self._resolve_target(raw)
            rtype = resolved.get("type")
            if rtype == "unknown":
                reason = resolved.get("reason", "not_found")
                unknown.append({"target": raw, "reason": reason})
                details.append({
                    "target": raw, "id": "", "name": "",
                    "type": "unknown", "status": "unknown", "reason": reason,
                })
                continue
            status = self._deliver_one(resolved, message)
            rid = resolved.get("id", "")
            entry = {
                "target": raw,
                "id": rid,
                "name": resolved.get("name", ""),
                "type": rtype,
                "status": status,
            }
            details.append(entry)
            if status == "sent":
                sent.append(rid)
            else:
                rejected.append({"id": rid, "reason": "投递失败（通道拒绝或未就绪）"})

        if sent and not rejected and not unknown:
            overall = "sent"
        elif sent:
            overall = "partial"
        else:
            overall = "error"

        result = {
            "status": overall,
            "message_id": self._generate_message_id(),
            "details": details,
            "sent": sent,
            "rejected": rejected,
            "unknown": unknown,
            "generated_at": self._now(),
        }
        hints = []
        if unknown:
            hints.append(
                "未解析目标：" + "、".join(u["target"] for u in unknown)
                + "（" + self._unknown_reason_hint(unknown[0]["reason"]) + "）"
            )
        if rejected:
            hints.append(
                "部分目标投递失败，可稍后重试或改用 list_members 核对成员状态"
            )
        if hints:
            result["hint"] = "；".join(hints)
        return result

    # ------------------------------------------------------------------
    # broadcast（仅直属成员）
    # ------------------------------------------------------------------
    def _action_broadcast(self, arguments: dict) -> dict:
        """向全部直属成员广播（parent_agent_id == 本 agent，实时名单）。"""
        message = arguments.get("message", "")
        if not message:
            return {
                "error": "缺少 message",
                "hint": "广播内容不能为空",
                "generated_at": self._now(),
            }

        direct = [
            m for m in self._live_members()
            if (m.get("parent_agent_id") or "") == self.agent_id
            and m.get("id") != self.agent_id
        ]
        if not direct:
            return {
                "status": "no_recipients",
                "recipients": [],
                "recipient_count": 0,
                "hint": "你当前没有直属成员，广播未发送给任何人。点对点沟通请用 "
                        "send_message（可发给直属 leader 或同团队成员）；"
                        "若你刚创建成员，请先用 list_members 确认",
                "generated_at": self._now(),
            }

        member_ids = [m.get("id", "") for m in direct if m.get("id")]
        sent: List[str] = []
        rejected: List[Dict[str, str]] = []

        if self.message_dispatcher is not None:
            try:
                r = self.message_dispatcher(
                    self.user_id,
                    member_ids,
                    message,
                    source_agent_id=self.agent_id,
                    team_id=self.team_id,
                    extra={"session_id": self.session_id},
                )
                r = r if isinstance(r, dict) else {}
                sent = list(r.get("sent") or [])
                rej_ids = list(r.get("rejected") or [])
                rejected = [
                    {"id": rid, "reason": "投递失败（通道拒绝或未就绪）"}
                    for rid in rej_ids
                ]
            except Exception as exc:  # noqa: BLE001
                logger.warning("broadcast dispatcher 失败，回退 broker: %s", exc)
                sent, rejected = self._broadcast_fallback(direct, message)
        else:
            sent, rejected = self._broadcast_fallback(direct, message)

        status = "broadcast" if sent else "error"
        result = {
            "status": status,
            "message_id": self._generate_message_id(),
            "recipients": member_ids,
            "recipient_count": len(member_ids),
            "sent": sent,
            "rejected": rejected,
            "generated_at": self._now(),
        }
        missing_names = [
            m.get("name") or m.get("id") for m in direct
            if not (m.get("role") and m.get("duty"))
        ]
        if rejected:
            result["hint"] = (
                f"{len(sent)}/{len(member_ids)} 名直属成员投递成功，"
                "失败的成员可稍后用 send_message 单独重试"
            )
        elif missing_names:
            result["hint"] = (
                "以下直属成员 role/duty 为空，建议用 team update_member "
                "补充：" + "、".join(missing_names[:5])
            )
        return result

    def _broadcast_fallback(
        self, direct: List[Dict[str, Any]], message: str
    ) -> tuple:
        """无 dispatcher 时经 broker 逐个投递，返回 (sent, rejected)。"""
        sent: List[str] = []
        rejected: List[Dict[str, str]] = []
        for m in direct:
            mid = m.get("id", "")
            if not mid:
                continue
            try:
                if self._dispatch_to_member(m, message):
                    sent.append(mid)
                else:
                    rejected.append({"id": mid, "reason": "broker 未就绪"})
            except Exception as exc:  # noqa: BLE001
                logger.warning("broadcast 投递失败 %s: %s", mid, exc)
                rejected.append({"id": mid, "reason": str(exc)})
        return sent, rejected

    # ------------------------------------------------------------------
    # wait_for
    # ------------------------------------------------------------------
    def _action_wait_for(self, arguments: dict) -> dict:
        """等待一个或多个成员完成当前工作。

        修复假完成竞态：每个目标必须**至少观测到一次 working** 后再等其转
        idle 才记为 completed；启动宽限（START_GRACE_SEC）内未观测到 working
        的目标记 never_started（未接单或已瞬间完成，需 send_message/查日志
        确认），不再出现"刚 send_message 就立即返回完成"。
        """
        raw = arguments.get("target_member_ids", "")
        if isinstance(raw, list):
            wanted = [str(t).strip() for t in raw if str(t).strip()]
        else:
            wanted = [t.strip() for t in str(raw or "").split(",") if t.strip()]
        if not wanted:
            return {
                "error": "缺少 target_member_ids",
                "hint": "请先用 list_members 获取成员 ID/名称，多个目标用逗号分隔",
                "generated_at": self._now(),
            }

        live = self._live_members()
        resolved: Dict[str, Dict[str, Any]] = {}
        unresolved: List[str] = []
        for key in wanted:
            m = next(
                (x for x in live if x.get("id") == key or x.get("name") == key),
                None,
            )
            if m is None:
                unresolved.append(key)
            else:
                resolved[m.get("id", "")] = m
        if unresolved:
            return {
                "error": "以下成员不存在或不在本团队：" + "、".join(unresolved),
                "hint": "请用 list_members 核对成员 ID/名称（仅支持等待本团队成员）",
                "generated_at": self._now(),
            }

        try:
            timeout = max(1, min(int(arguments.get("timeout", 300)), 600))
        except (TypeError, ValueError):
            timeout = 300

        start = time.time()
        deadline = start + timeout
        grace_end = start + self.START_GRACE_SEC
        seen_working: set = set()
        completed: set = set()
        never_started: set = set()

        while True:
            now = time.time()
            if now >= deadline:
                break
            for mid in resolved:
                if mid in completed or mid in never_started:
                    continue
                status = self._live_work_status(mid)
                if status == "working":
                    seen_working.add(mid)
                elif mid in seen_working:
                    # 观测到 working 后转 idle：确属完成
                    completed.add(mid)
                elif now >= grace_end:
                    # 整个启动宽限内从未 working：未接单（或已瞬间完成）
                    never_started.add(mid)
            if len(completed) + len(never_started) >= len(resolved):
                break
            remaining = deadline - time.time()
            time.sleep(min(self.POLL_INTERVAL_SEC, max(0.1, remaining)))

        waited = round(min(timeout, time.time() - start), 1)
        timed_out = (len(completed) + len(never_started)) < len(resolved)

        results = []
        for mid, m in resolved.items():
            if mid in completed:
                outcome = "completed"
            elif mid in never_started:
                outcome = "never_started"
            else:
                outcome = "working"
            results.append({
                "member_id": mid,
                "name": m.get("name", ""),
                "work_status": self._live_work_status(mid),
                "outcome": outcome,
                "log_path": self._log_path(mid),
            })

        result = {
            "members": results,
            "timed_out": timed_out,
            "waited": waited,
            "total": len(results),
            "generated_at": self._now(),
        }
        ns_rows = [r for r in results if r["outcome"] == "never_started"]
        wk = [r["name"] or r["member_id"] for r in results if r["outcome"] == "working"]
        hints = []
        if ns_rows:
            ns = [r["name"] or r["member_id"] for r in ns_rows]
            ns_paths = "、".join(self._log_path(r["member_id"]) for r in ns_rows)
            hints.append(
                "以下成员在启动宽限内未观测到工作状态（可能未接单或已瞬间完成）："
                + "、".join(ns)
                + "。请用 send_message 确认，或直接 read 其活动日志（"
                + ns_paths
                + "）核实，不要直接假定任务完成"
            )
        if timed_out:
            hints.append(
                "等待超时，以下成员仍在工作：" + "、".join(wk)
                + "。你可以结束本轮（无需继续 wait_for 轮询）：成员完成回复后"
                "会自动回发消息唤醒你，届时再 read 日志/产出验收"
            )
        if hints:
            result["hint"] = "；".join(hints)
        return result
