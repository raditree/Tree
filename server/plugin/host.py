"""宿主通道（二期 M2）后端承接面——契约 v1.3 §14 冻结版。

职责（本批最小集）：
- ``plugin_host_*`` op 命名空间（start/stop/status）的 server 侧定义与处理
  （**只增不改**：既有 ``mcp_stdio_*`` / ``exec_*`` 语义零改动）；
- 传输复用：经既有反向 WS ``tool_exec_request / tool_exec_response`` 链路
  （``io_.local_executor.ToolExecutorClient``）请求-回传；本模块不新建通道，
  不重复实现帧逻辑（前端侧复用 ``mcp_stdio_tunnel`` 状态机——契约 §14.1）；
- 会话表：``host_key → host_session_id``（同 key 幂等复用）、scope 归属、
  状态缓存（running/closed + exit_code/stderr_tail）；
- 清理契约四场景（§14.3）：①stop 指令 ②scope 级联（挂接入 ``plugin_cascade``
  单点）③断连标记 ``lost``（重连后对账回收）④退出上报（上行帧
  ``plugin_host_event``）；
- fail-closed：总开关关 / 无执行器 / 归属不符 / 未知会话 → 拒绝或 no-op +
  分类计数；一切异常吞掉（绝不影响既有链路）。

边界与调用约定：
- 面向执行器的 ``start/stop/status`` 为**阻塞调用**（沿用 ``executor.request``
  语义，含卡死/进度续期检测）；调用方须在工作线程中执行（既有惯例：
  线程池 / daemon 线程），不得阻塞事件循环线程；
- 本批仅承载"系统内置插件"通道（§14.1 承载范围）；``payload`` 透传容忍，
  后端不消费内容、不执行取自 payload 的命令。
"""

from __future__ import annotations

import logging
import os
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

from plugin.bus import make_scope, normalize_scope, scope_matches
from plugin.registry import scope_key

logger = logging.getLogger(__name__)

# ----------------------------------------------------------------------
# op / 上行帧 / 事件常量（只增不改）
# ----------------------------------------------------------------------
OP_HOST_START = "plugin_host_start"
OP_HOST_STOP = "plugin_host_stop"
OP_HOST_STATUS = "plugin_host_status"

# 上行帧类型（ws.endpoints 分发）与事件取值（本批仅 exit）
WS_MSG_HOST_EVENT = "plugin_host_event"
HOST_EVENT_EXIT = "exit"

# 可注入参数（env / 构造 / 时钟；测试缩参三通道）
ENV_OP_TIMEOUT_S = "PLUGIN_HOST_OP_TIMEOUT_S"
ENV_STOP_WAIT_S = "PLUGIN_HOST_STOP_WAIT_S"
DEFAULT_OP_TIMEOUT_S = 30.0
DEFAULT_STOP_WAIT_S = 5.0

# 单次重连对账探测上限（防风暴；超限部分留下轮对账）
MAX_RECONCILE_PROBE = 16
# stderr_tail 截尾长度（~2000 字符）
STDERR_TAIL_MAX = 2000

# 合法会话状态（fail-closed：未知值不落库）
STATES = ("running", "closed")


def _env_float(name: str, default: float, minimum: float = 0.01) -> float:
    """读取环境变量浮点参数（缺省/非法回退默认值）。"""
    try:
        value = float(os.environ.get(name, "") or default)
        return max(minimum, value)
    except (TypeError, ValueError):
        return default


def make_host_key(plugin_id: str, granularity: str, scope: Dict[str, str]) -> str:
    """构造 host_key（与注册表实例键同口径：``plugin_id|granularity|scope 键位``）。

    :raises ValueError: 未知粒度（fail-closed，不静默降级）
    """
    g = str(granularity or "team")
    key = scope_key(g, scope or {})
    return "|".join([str(plugin_id or ""), g, *[str(x or "") for x in key]])


@dataclass
class HostSession:
    """单个宿主会话记录（最小字段集；host_session_id 按不透明字符串存取）。

    状态机（最小）：``running → closed``（退出上报 / 停止确认 / 对账探测）。
    ``lost`` 为断连标记（不 kill；重连后对账回收）。
    """

    host_key: str
    host_session_id: str
    user_id: str
    team_id: str
    scope: Dict[str, str]
    state: str = "running"
    lost: bool = False
    exit_code: Optional[int] = None
    stderr_tail: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0

    def to_dict(self) -> Dict[str, Any]:
        """序列化（观测 / 测试 / 诊断）。"""
        return {
            "host_key": self.host_key,
            "host_session_id": self.host_session_id,
            "user_id": self.user_id,
            "team_id": self.team_id,
            "scope": dict(self.scope),
            "state": self.state,
            "lost": bool(self.lost),
            "exit_code": self.exit_code,
            "stderr_tail": self.stderr_tail,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


class HostChannel:
    """宿主通道后端承接面（进程内单例由 ``plugin`` 门面持有）。

    - 线程安全（RLock；后台任务=daemon 线程，测试可用 :meth:`drain` 收尾）；
    - 所有计数仅供观测/测试（:meth:`stats`），不参与判定。
    """

    def __init__(
        self,
        *,
        enabled_fn: Any = None,
        op_timeout_s: Optional[float] = None,
        stop_wait_s: Optional[float] = None,
        now_fn: Any = None,
    ) -> None:
        """:param enabled_fn: 开关判定注入（缺省延迟读取 ``plugin.is_enabled``）；
        :param op_timeout_s: start/status op 等待上限（缺省 env/30s）；
        :param stop_wait_s: stop 尽力而为等待上限（缺省 env/5s）；
        :param now_fn: 时钟注入（统计时间戳；缺省 ``time.time``）。
        """
        self._enabled_fn = enabled_fn
        self._op_timeout_s = op_timeout_s
        self._stop_wait_s = stop_wait_s
        self._now = now_fn or time.time
        self._lock = threading.RLock()
        self._by_key: Dict[str, HostSession] = {}
        self._by_id: Dict[str, HostSession] = {}
        self._threads: List[threading.Thread] = []
        self._counts: Dict[str, int] = {
            "started": 0,
            "reused": 0,
            "start_failed": 0,
            "stopped": 0,
            "stop_noop": 0,
            "stop_failed": 0,
            "status_ok": 0,
            "status_failed": 0,
            "exited": 0,
            "event_ignored": 0,
            "rejected_owner": 0,
            "rejected_invalid": 0,
            "rejected_no_executor": 0,
            "lost_marked": 0,
            "reconcile_probed": 0,
            "reconciled_closed": 0,
            "reconciled_running": 0,
            "reconcile_failed": 0,
            "cascaded": 0,
            "cascaded_stopped": 0,
            "cascaded_stop_failed": 0,
            "cascaded_no_executor": 0,
            "skipped_disabled": 0,
        }

    # ------------------------------------------------------------------
    # 门控 / 工具
    # ------------------------------------------------------------------
    def _is_enabled(self) -> bool:
        if self._enabled_fn is not None:
            try:
                return bool(self._enabled_fn())
            except Exception:  # noqa: BLE001
                return False
        try:
            import plugin  # noqa: PLC0415（延迟 import 防循环）

            return bool(plugin.is_enabled())
        except Exception:  # noqa: BLE001
            return False

    def _op_timeout(self) -> float:
        if self._op_timeout_s is not None:
            return max(0.01, float(self._op_timeout_s))
        return _env_float(ENV_OP_TIMEOUT_S, DEFAULT_OP_TIMEOUT_S)

    def _stop_wait(self) -> float:
        if self._stop_wait_s is not None:
            return max(0.01, float(self._stop_wait_s))
        return _env_float(ENV_STOP_WAIT_S, DEFAULT_STOP_WAIT_S)

    def _bump(self, key: str, n: int = 1) -> None:
        with self._lock:
            self._counts[key] = self._counts.get(key, 0) + int(n)

    @staticmethod
    def _lazy_runtime() -> Tuple[Any, Any]:
        """延迟解析执行器 / WS 管理器（缺省路径；测试注入优先）。"""
        try:
            import state  # noqa: PLC0415

            return (
                getattr(state, "local_executor", None),
                getattr(state, "ws_manager", None),
            )
        except Exception:  # noqa: BLE001
            return None, None

    def _spawn(self, target: Any, name: str) -> threading.Thread:
        """启动后台 daemon 线程（登记以便 :meth:`drain` 收尾）。"""
        thread = threading.Thread(target=target, name=name, daemon=True)
        with self._lock:
            self._threads = [t for t in self._threads if t.is_alive()]
            self._threads.append(thread)
        thread.start()
        return thread

    def drain(self, timeout: float = 2.0) -> None:
        """等待后台任务（级联停止 / 对账）收尾（有界；测试/关闭用）。"""
        with self._lock:
            threads = [t for t in self._threads if t.is_alive()]
            self._threads = threads
        deadline = time.time() + max(0.0, float(timeout))
        for thread in threads:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            thread.join(timeout=remaining)

    # ------------------------------------------------------------------
    # 会话查询（读侧）
    # ------------------------------------------------------------------
    def get_session(self, host_session_id: str) -> Optional[HostSession]:
        """按 host_session_id 取会话（不存在返回 None）。"""
        with self._lock:
            return self._by_id.get(str(host_session_id or ""))

    def list_sessions(self, user_id: str = "", team_id: str = "") -> List[Dict[str, Any]]:
        """列出会话快照（可按 user/team 过滤；观测/测试/诊断用）。"""
        with self._lock:
            items = [s.to_dict() for s in self._by_id.values()]
        if user_id:
            items = [s for s in items if s["user_id"] == str(user_id)]
        if team_id:
            items = [s for s in items if s["team_id"] == str(team_id)]
        return items

    def stats(self) -> Dict[str, Any]:
        """观测统计（分类计数 + 会话态汇总）。"""
        with self._lock:
            sessions = list(self._by_id.values())
            counts = dict(self._counts)
        return {
            "counts": counts,
            "sessions": len(sessions),
            "in_flight": sum(
                1 for s in sessions if s.state == "running" and not s.lost
            ),
            "lost": sum(1 for s in sessions if s.state == "running" and s.lost),
            "closed": sum(1 for s in sessions if s.state == "closed"),
            "op_timeout_s": self._op_timeout(),
            "stop_wait_s": self._stop_wait(),
        }

    def reset(self) -> None:
        """清空会话表与计数（测试清理用；先收尾后台任务）。"""
        self.drain(1.0)
        with self._lock:
            self._by_key.clear()
            self._by_id.clear()
            for key in list(self._counts.keys()):
                self._counts[key] = 0

    # ------------------------------------------------------------------
    # 服务端发起（start / stop / status）
    # ------------------------------------------------------------------
    def start_session(
        self,
        executor: Any,
        ws_manager: Any,
        user_id: str,
        host_key: str,
        *,
        team_id: str = "",
        scope: Optional[Dict[str, str]] = None,
        payload: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """发起 ``plugin_host_start``（幂等：同 host_key 且在跑 → 复用，不发 op）。

        :return: ``{"host_session_id": ...}`` / ``{"error": ...}``
        """
        if not self._is_enabled():
            self._bump("skipped_disabled")
            return {"error": "插件体系未启用"}
        host_key = str(host_key or "").strip()
        user_id = str(user_id or "")
        team_id = str(team_id or "")
        if not host_key or not user_id:
            self._bump("rejected_invalid")
            return {"error": "缺少 host_key/user_id"}
        with self._lock:
            cur = self._by_key.get(host_key)
            if (
                cur is not None
                and cur.state == "running"
                and not cur.lost
                and cur.user_id == user_id
                and cur.team_id == team_id
            ):
                self._bump("reused")
                return {"host_session_id": cur.host_session_id, "reused": True}
        if executor is None or ws_manager is None:
            self._bump("rejected_no_executor")
            return {"error": "前端执行器不可用"}
        req = {
            "op": OP_HOST_START,
            "host_key": host_key,
            "payload": dict(payload or {}),
            "team_id": team_id,
        }
        try:
            result = executor.request(
                ws_manager, user_id, req, timeout=self._op_timeout(), team_id=team_id
            )
        except Exception as exc:  # noqa: BLE001
            self._bump("start_failed")
            logger.warning("宿主会话启动请求异常: key=%s err=%r", host_key, exc)
            return {"error": f"宿主启动请求异常: {exc}"}
        if not isinstance(result, dict) or result.get("error"):
            self._bump("start_failed")
            return {
                "error": str((result or {}).get("error") or "宿主启动失败"),
            }
        sid = str(result.get("host_session_id") or "")
        if not sid:
            self._bump("start_failed")
            return {"error": "宿主未返回 host_session_id"}
        sc = normalize_scope(scope or {})
        sc["user_id"] = sc["user_id"] or user_id
        sc["team_id"] = sc["team_id"] or team_id
        sess = HostSession(
            host_key=host_key,
            host_session_id=sid,
            user_id=user_id,
            team_id=team_id,
            scope=sc,
            state="running",
            lost=False,
            created_at=self._now(),
            updated_at=self._now(),
        )
        with self._lock:
            old = self._by_key.get(host_key)
            if old is not None and old.host_session_id != sid:
                self._by_id.pop(old.host_session_id, None)
            self._by_key[host_key] = sess
            self._by_id[sid] = sess
        self._bump("started")
        logger.info("宿主会话建立: key=%s id=%s team=%s", host_key, sid, team_id)
        return {"host_session_id": sid}

    def stop_session(
        self,
        executor: Any,
        ws_manager: Any,
        user_id: str,
        host_session_id: str,
        *,
        team_id: str = "",
        reason: str = "manual",
    ) -> Dict[str, Any]:
        """发起 ``plugin_host_stop``（幂等：未知/已 closed → 直接 ok，不发 op）。

        "尽力而为"语义：失败仅记日志 + 计数（会话标记 ``lost`` 待对账），
        调用方不被异常打扰。
        """
        if not self._is_enabled():
            self._bump("skipped_disabled")
            return {"ok": False, "error": "插件体系未启用"}
        hsid = str(host_session_id or "")
        user_id = str(user_id or "")
        team_id = str(team_id or "")
        with self._lock:
            sess = self._by_id.get(hsid)
            if sess is None:
                self._bump("stop_noop")
                return {"ok": True, "note": "unknown_session"}
            if sess.user_id != user_id or (
                team_id and sess.team_id and sess.team_id != team_id
            ):
                self._bump("rejected_owner")
                return {"error": "宿主会话归属不符"}
            if sess.state == "closed":
                self._bump("stop_noop")
                return {"ok": True, "note": "already_closed"}
        if executor is None or ws_manager is None:
            with self._lock:
                sess.lost = True
                sess.updated_at = self._now()
            self._bump("stop_failed")
            return {"ok": False, "error": "前端执行器不可用"}
        req = {
            "op": OP_HOST_STOP,
            "host_session_id": hsid,
            "team_id": sess.team_id,
        }
        try:
            result = executor.request(
                ws_manager, user_id, req, timeout=self._stop_wait(), team_id=sess.team_id
            )
        except Exception as exc:  # noqa: BLE001
            # 与"无执行器"/"宿主返回 error"两路径一致：无法确认停止 → 标记失联，
            # 交重连对账回收（避免该会话不被 reconcile 扫描；知遥 CH6 观察项修正）
            with self._lock:
                sess.lost = True
                sess.updated_at = self._now()
            self._bump("stop_failed")
            logger.warning("宿主会话停止请求异常: id=%s err=%r", hsid, exc)
            return {"ok": False, "error": f"停止请求异常: {exc}"}
        ok = isinstance(result, dict) and not result.get("error")
        with self._lock:
            if ok:
                sess.state = "closed"
                sess.lost = False
            else:
                sess.lost = True
            sess.updated_at = self._now()
        self._bump("stopped" if ok else "stop_failed")
        if not ok:
            logger.info(
                "宿主会话停止未确认（尽力而为）: id=%s reason=%s result=%r",
                hsid,
                reason,
                result,
            )
            return {"ok": False, "error": str((result or {}).get("error") or "停止未确认")}
        return {"ok": True}

    def query_status(
        self,
        executor: Any,
        ws_manager: Any,
        user_id: str,
        host_session_id: str,
        *,
        team_id: str = "",
    ) -> Dict[str, Any]:
        """发起 ``plugin_host_status``（诊断/对账用；同步更新状态缓存）。"""
        if not self._is_enabled():
            self._bump("skipped_disabled")
            return {"error": "插件体系未启用"}
        hsid = str(host_session_id or "")
        user_id = str(user_id or "")
        team_id = str(team_id or "")
        with self._lock:
            sess = self._by_id.get(hsid)
        if sess is None:
            self._bump("rejected_invalid")
            return {"error": "未知宿主会话"}
        if sess.user_id != user_id or (
            team_id and sess.team_id and sess.team_id != team_id
        ):
            self._bump("rejected_owner")
            return {"error": "宿主会话归属不符"}
        if executor is None or ws_manager is None:
            self._bump("rejected_no_executor")
            return {"error": "前端执行器不可用"}
        req = {
            "op": OP_HOST_STATUS,
            "host_session_id": hsid,
            "team_id": sess.team_id,
        }
        try:
            result = executor.request(
                ws_manager, user_id, req, timeout=self._op_timeout(), team_id=sess.team_id
            )
        except Exception as exc:  # noqa: BLE001
            self._bump("status_failed")
            logger.warning("宿主状态查询异常: id=%s err=%r", hsid, exc)
            return {"error": f"宿主状态查询异常: {exc}"}
        if not isinstance(result, dict) or result.get("error"):
            self._bump("status_failed")
            return {"error": str((result or {}).get("error") or "宿主状态查询失败")}
        with self._lock:
            state_val = str(result.get("state") or "")
            if state_val in STATES:
                sess.state = state_val
            if "exit_code" in result:
                try:
                    raw_ec = result.get("exit_code")
                    sess.exit_code = int(raw_ec) if raw_ec is not None else None
                except (TypeError, ValueError):
                    pass
            tail = result.get("stderr_tail")
            if tail:
                sess.stderr_tail = str(tail)[-STDERR_TAIL_MAX:]
            sess.lost = False
            sess.updated_at = self._now()
        self._bump("status_ok")
        return dict(result)

    # ------------------------------------------------------------------
    # 上行（plugin_host_event）与清理契约
    # ------------------------------------------------------------------
    def on_event(self, user_id: str, data: Dict[str, Any]) -> bool:
        """处理上行帧 ``plugin_host_event``（本批仅 ``event='exit'``）。

        - 未知 event / 未知会话 / 归属不符：忽略 + 计数（fail-closed 零副作用）；
        - 命中：状态转 ``closed`` + ``exit_code`` / ``stderr_tail`` 更新。
        """
        if not self._is_enabled():
            return False
        data = data if isinstance(data, dict) else {}
        event = str(data.get("event") or "")
        hsid = str(data.get("host_session_id") or "")
        team_id = str(data.get("team_id") or "")
        if event != HOST_EVENT_EXIT or not hsid:
            self._bump("event_ignored")
            logger.debug("宿主上行帧忽略（event=%r id=%r）", event, hsid)
            return False
        with self._lock:
            sess = self._by_id.get(hsid)
            if sess is None or sess.user_id != str(user_id or "") or (
                team_id and sess.team_id and sess.team_id != team_id
            ):
                self._bump("event_ignored")
                logger.debug("宿主上行帧忽略（未知/归属不符）: id=%s", hsid)
                return False
            sess.state = "closed"
            sess.lost = False
            raw_ec = data.get("exit_code")
            try:
                sess.exit_code = int(raw_ec) if raw_ec is not None else None
            except (TypeError, ValueError):
                sess.exit_code = None
            tail = data.get("stderr_tail")
            if tail:
                sess.stderr_tail = str(tail)[-STDERR_TAIL_MAX:]
            sess.updated_at = self._now()
        self._bump("exited")
        logger.info(
            "宿主进程退出上报: id=%s exit_code=%s", hsid, data.get("exit_code")
        )
        return True

    def mark_lost(self, user_id: str, team_ids: Any) -> int:
        """断连回收（§14.3-3）：把该用户指定 team 的 running 会话标记 ``lost``。

        不 kill（进程不可达时以宿主侧对账为准）；返回新标记数。
        """
        if not self._is_enabled():
            return 0
        user_id = str(user_id or "")
        if isinstance(team_ids, str):
            team_ids = [team_ids]
        targets = {str(t or "") for t in (team_ids or []) if str(t or "")}
        if not user_id or not targets:
            return 0
        marked = 0
        with self._lock:
            for sess in self._by_id.values():
                if (
                    sess.user_id == user_id
                    and sess.team_id in targets
                    and sess.state == "running"
                    and not sess.lost
                ):
                    sess.lost = True
                    sess.updated_at = self._now()
                    marked += 1
        if marked:
            self._bump("lost_marked", marked)
        return marked

    def reconcile(
        self,
        executor: Any,
        ws_manager: Any,
        user_id: str,
        team_id: str = "",
        *,
        max_probe: int = MAX_RECONCILE_PROBE,
    ) -> Dict[str, int]:
        """（同步）重连对账：对 (user, team) 下 ``lost`` 会话逐个 status 探测。

        - 探测成功且 ``closed`` → 回收（状态落 closed）；
        - 探测成功且 ``running`` → 恢复（清 ``lost``）；
        - 探测失败 → 保持 ``lost``（下次再对）。
        """
        out = {"probed": 0, "closed": 0, "running": 0, "failed": 0}
        if not self._is_enabled():
            return out
        user_id = str(user_id or "")
        team_id = str(team_id or "")
        if executor is None or ws_manager is None:
            lex, lwm = self._lazy_runtime()
            executor = executor if executor is not None else lex
            ws_manager = ws_manager if ws_manager is not None else lwm
        with self._lock:
            targets = [
                s
                for s in self._by_id.values()
                if s.user_id == user_id
                and (not team_id or s.team_id == team_id)
                and s.state == "running"
                and s.lost
            ][: max(1, int(max_probe))]
        for sess in targets:
            out["probed"] += 1
            self._bump("reconcile_probed")
            result = self.query_status(
                executor, ws_manager, user_id, sess.host_session_id, team_id=sess.team_id
            )
            if result.get("error"):
                out["failed"] += 1
                self._bump("reconcile_failed")
            elif str(result.get("state") or "") == "closed":
                out["closed"] += 1
                self._bump("reconciled_closed")
            else:
                out["running"] += 1
                self._bump("reconciled_running")
        return out

    def reconcile_async(
        self,
        user_id: str,
        team_id: str = "",
        *,
        executor: Any = None,
        ws_manager: Any = None,
    ) -> int:
        """执行器（重）注册后 best-effort 对账调度（后台线程）。

        :return: 本次排期探测的会话数（0 = 无失联会话，未起线程）。
        """
        if not self._is_enabled():
            return 0
        user_id = str(user_id or "")
        team_id = str(team_id or "")
        with self._lock:
            count = sum(
                1
                for s in self._by_id.values()
                if s.user_id == user_id
                and (not team_id or s.team_id == team_id)
                and s.state == "running"
                and s.lost
            )
        if count <= 0:
            return 0
        self._spawn(
            lambda: self.reconcile(executor, ws_manager, user_id, team_id),
            name="plugin-host-reconcile",
        )
        return count

    def _stop_matched(self, sessions: List[HostSession], executor: Any, ws_manager: Any) -> None:
        """逐个 best-effort 停止（级联回收用；异常吞掉 + 计数）。"""
        if executor is None or ws_manager is None:
            lex, lwm = self._lazy_runtime()
            executor = executor if executor is not None else lex
            ws_manager = ws_manager if ws_manager is not None else lwm
        for sess in sessions:
            try:
                if executor is None or ws_manager is None:
                    self._bump("cascaded_no_executor")
                    continue
                req = {
                    "op": OP_HOST_STOP,
                    "host_session_id": sess.host_session_id,
                    "team_id": sess.team_id,
                }
                result = executor.request(
                    ws_manager,
                    sess.user_id,
                    req,
                    timeout=self._stop_wait(),
                    team_id=sess.team_id,
                )
                ok = isinstance(result, dict) and not result.get("error")
                self._bump("cascaded_stopped" if ok else "cascaded_stop_failed")
            except Exception:  # noqa: BLE001
                self._bump("cascaded_stop_failed")
                logger.exception("级联停止宿主会话异常（已忽略）: id=%s", sess.host_session_id)

    def cascade_cleanup(
        self,
        user_id: str,
        *,
        team_id: str = "",
        agent_id: str = "",
        session_id: str = "",
        executor: Any = None,
        ws_manager: Any = None,
        async_stop: bool = True,
    ) -> int:
        """scope 级联清理（§14.3-2，挂接入 ``plugin_cascade`` 单点）。

        匹配规则与注册表一致（``scope_matches`` fail-closed 方向）；命中记录
        立即移除，running 会话 best-effort 停止（缺省后台线程；失败仅计数）。

        :return: 移除的会话数
        """
        if not self._is_enabled():
            return 0
        user_id = str(user_id or "")
        if not user_id:
            return 0
        cond = make_scope(
            user_id=user_id,
            team_id=team_id,
            agent_id=agent_id,
            session_id=session_id,
        )
        matched: List[HostSession] = []
        with self._lock:
            for key, sess in list(self._by_key.items()):
                if scope_matches(cond, sess.scope):
                    matched.append(sess)
                    self._by_key.pop(key, None)
                    self._by_id.pop(sess.host_session_id, None)
        if not matched:
            return 0
        self._bump("cascaded", len(matched))
        running = [s for s in matched if s.state == "running"]
        if running:
            if async_stop:
                self._spawn(
                    lambda: self._stop_matched(running, executor, ws_manager),
                    name="plugin-host-cascade",
                )
            else:
                self._stop_matched(running, executor, ws_manager)
        return len(matched)
