"""team / message 两个内置工具的公共基类。

历史上团队管理与团队通信都塞在单体 ``TeamTool`` 中，现拆为两个独立 LLM 工具：
- ``tool/team_tool.py``（工具名 ``team``）：成员/团队管理；
- ``tool/message_tool.py``（工具名 ``message``）：成员通信。

两者共享的能力集中在本模块的 ``TeamToolBase``：
- 构造依赖与自身身份引导（level / can_lead_team 从 team_store 实时读取）；
- 名单加载（team_members 表为权威源，roster 文件仅作旧数据回退视图）；
- 统一的 list_teams / list_members 输出（两个工具同一份实现，避免行为漂移）；
- 寻址解析（top 内成员 / 自己的 leader / 跨 TOP 顶层寻址）；
- broker 回退投递、live 工作状态、WorkspaceIO 助手、roster 读写。
"""

import logging
import random
import re
import string
import time
from typing import Any, Dict, List, Optional, Tuple

from io_.docker_manager import DockerManager
from io_.workspace_io import run_io
from llm.llm import AgentLLMSession

logger = logging.getLogger(__name__)

# 成员管理表在工作空间内的相对路径
ROSTER_FILE_PATH: str = ".self/team_roster.md"

# 多维评分字段
SCORE_FIELDS = ("quality", "efficiency", "collaboration", "accuracy")

# 活动日志行首时间戳（新格式带日期；旧格式仅 HH:MM:SS）
_LOG_TS_RE = re.compile(r"^\[\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*\]")
_LOG_TS_LEGACY_RE = re.compile(r"^\[\s*(\d{2}:\d{2}:\d{2})\s*\]")


def _to_score(value: Any) -> float:
    """将任意值解析为 0-10 的评分，非法值归 0。"""
    try:
        return max(0.0, min(10.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def _fmt_ts(value: Any) -> str:
    """将毫秒时间戳格式化为 ``YYYY-MM-DD HH:MM:SS``；非法/空值返回空串。"""
    if not value:
        return ""
    try:
        ts = int(value) / 1000.0
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
    except (TypeError, ValueError):
        return str(value)


def _resolve_team_limits(team_id: str) -> Tuple[int, int]:
    """按 TOP 的团队记录解析规模限制，返回 ``(max_level, max_members_per_level)``。

    团队配置在创建 TOP agent 时由用户设定并持久化到 ``teams`` 表
    （创建后不可修改，成员只增不减）；旧数据无团队记录/配置列缺失时回退
    ``config.team`` 的代码默认值。

    :param team_id: 所属顶层 agent ID（顶部 agent 自身即 agent_id）
    :return: ``(max_level, max_members_per_level)``，均 >=1
    """
    from config.team import DEFAULT_TEAM_MAX_LEVEL, DEFAULT_TEAM_MAX_MEMBERS
    from data.team_store import get_team

    team = None
    if team_id:
        try:
            team = get_team(team_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取团队配置失败(按默认值): %s: %s", team_id, exc)
    max_level = DEFAULT_TEAM_MAX_LEVEL
    max_members = DEFAULT_TEAM_MAX_MEMBERS
    if isinstance(team, dict):
        try:
            max_level = max(1, int(team.get("max_level") or DEFAULT_TEAM_MAX_LEVEL))
        except (TypeError, ValueError):
            max_level = DEFAULT_TEAM_MAX_LEVEL
        try:
            max_members = max(
                1, int(team.get("max_members_per_level") or DEFAULT_TEAM_MAX_MEMBERS)
            )
        except (TypeError, ValueError):
            max_members = DEFAULT_TEAM_MAX_MEMBERS
    return max_level, max_members


class TeamToolBase:
    """team/message 工具公共基类（不直接作为 LLM 工具注册）。"""

    def __init__(
        self,
        session: AgentLLMSession,
        docker_manager: DockerManager,
        model_configs: dict,
        broker: Any = None,
        user_id: str = "",
        agent_id: str = "",
        leader_id: str = "",
        team_id: str = "",
        message_dispatcher: Any = None,
        io: Any = None,
        session_id: str = "",
    ) -> None:
        self.session = session
        self.docker_manager = docker_manager
        self.model_configs: Dict[str, Any] = model_configs
        self.workspace_id: str = getattr(session, "workspace_id", "") or ""
        self.broker = broker
        self.user_id = user_id
        self.agent_id = agent_id
        self.leader_id = leader_id
        self.team_id = team_id or agent_id
        self.session_id = session_id or ""
        # 统一消息发送回调（chat._dispatch_agent_message）：User-Agent /
        # Agent-Agent 收敛出口；缺省时回退 broker 直投
        self.message_dispatcher = message_dispatcher
        # 统一工作空间 IO（WorkspaceIO）
        self.io: Any = io

        # 成员缓存（权威源是 team_members 表；这里只做同会话新建成员的补充
        # 与未建队旧数据的 roster 回退，读取类动作一律实时查库）
        self.members: List[Dict[str, Any]] = []

        # 团队最大层级深度 + 每层成员上限
        self.max_team_level, self.max_members_per_level = _resolve_team_limits(
            self.team_id or self.agent_id
        )
        # 当前 agent 自身身份：从 team_members 引导（无行=TOP：Level 0/可带队）
        self.level, self.can_lead_team = self._bootstrap_identity()

        # 名单缓存初始化（实时查库；失败回退 roster 文件）
        self._load_roster()

    # ------------------------------------------------------------------
    # 分发助手
    # ------------------------------------------------------------------
    def _dispatch_actions(
        self, dispatch: Dict[str, Any], arguments: dict
    ) -> dict:
        action = arguments.get("action")
        handler = dispatch.get(action)
        if handler is None:
            available = "、".join(sorted(dispatch.keys()))
            return {
                "error": f"未知 action: {action}",
                "hint": f"本工具支持的 action：{available}",
                "generated_at": self._now(),
            }
        return handler(arguments)

    @staticmethod
    def _now() -> str:
        """返回当前时间字符串（带日期）。"""
        return time.strftime("%Y-%m-%d %H:%M:%S")

    @staticmethod
    def _generate_member_id() -> str:
        """生成唯一成员 ID：member_{timestamp}_{random}。"""
        ts = int(time.time())
        suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
        return f"member_{ts}_{suffix}"

    @staticmethod
    def _generate_message_id() -> str:
        """生成唯一消息 ID。"""
        ts = int(time.time() * 1000)
        suffix = random.randint(1000, 9999)
        return f"msg_{ts}_{suffix}"

    def _is_top(self) -> bool:
        """当前工具实例是否属于 TOP agent 自身。"""
        return bool(self.agent_id) and self.agent_id == self.team_id

    # ------------------------------------------------------------------
    # 自身身份引导
    # ------------------------------------------------------------------
    def _bootstrap_identity(self) -> Tuple[int, bool]:
        """从 team_members 读取当前 agent 自身层级/带队权。

        - TOP agent 不在 team_members 表中（无行）→ Level 0、可带队；
        - 成员行存在 → 以表中 level/can_lead_team 为准（修复历史硬编码
          level=0、can_lead_team 恒 True 导致的层级校验失效）。
        """
        if not self.team_id or not self.agent_id:
            return 0, True
        try:
            from data.team_store import get_member

            row = get_member(self.team_id, self.agent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("引导自身成员身份失败(按 TOP 处理): %s", exc)
            return 0, True
        if not row:
            return 0, True
        try:
            level = max(0, int(row.get("level") or 1))
        except (TypeError, ValueError):
            level = 1
        can_lead = bool(row.get("can_lead_team", 1))
        return level, can_lead

    # ------------------------------------------------------------------
    # 名单加载（team_members 权威源 + roster 旧数据回退）
    # ------------------------------------------------------------------
    def _normalize_store_row(self, row: Dict[str, Any]) -> Dict[str, Any]:
        """team_store 原始行 → 工具内部规范成员字典。"""
        top_id = self.team_id or self.agent_id
        try:
            level = max(0, int(row.get("level") or 1))
        except (TypeError, ValueError):
            level = 1
        created_ms = row.get("created_at")
        return {
            "id": row.get("id", ""),
            "name": row.get("name", ""),
            "role": row.get("role", "") or "",
            "duty": row.get("duty", "") or "",
            "model_id": row.get("model_id", "") or "",
            "level": level,
            "can_lead_team": bool(row.get("can_lead_team", 1)),
            "workspace_id": row.get("id", ""),
            "parent_agent_id": row.get("parent_agent_id", "") or "",
            "team_id": row.get("team_id", "") or top_id,
            "created_at_ms": created_ms,
            "created_at": _fmt_ts(created_ms),
            "work_status": row.get("work_status", "idle"),
            "scores": row.get("scores") or {},
            "comment": row.get("comment", "") or "",
            "system_prompt": row.get("system_prompt", "") or "",
            # 审核状态：成员能否工作的前置条件（用户审核通过才放行）
            "review_status": row.get("review_status", "") or "",
        }

    def _fetch_store_members(self) -> List[Dict[str, Any]]:
        """实时读取 team_members 全量名单并规范化（失败/空返回空列表）。"""
        from data.team_store import get_members

        top_id = self.team_id or self.agent_id
        if not top_id:
            return []
        try:
            rows = get_members(top_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("从 team_store 读取成员失败: %s", exc)
            return []
        return [self._normalize_store_row(r) for r in rows if r.get("id")]

    def _live_members(self) -> List[Dict[str, Any]]:
        """返回当前实时成员名单。

        team_members 表有数据时以其为权威源，并合并本工具实例刚创建、
        尚未/落库失败的内存成员；表为空（未建队的历史数据）时回退缓存
        （roster 文件解析结果）。
        """
        rows = self._fetch_store_members()
        if rows:
            known = {m.get("id") for m in rows}
            for m in self.members:
                mid = m.get("id", "")
                if mid and mid not in known:
                    rows.append(m)
            return rows
        return [dict(m) for m in self.members]

    def _load_roster(self) -> None:
        """初始化成员缓存：优先 team_store，空则回退工作空间 roster 文件。"""
        members = self._fetch_store_members()
        if members:
            self.members = members
            return
        if not self.workspace_id:
            return
        stdout = self._io_read(self.workspace_id, ROSTER_FILE_PATH)
        if stdout is None:
            cmd = ["sh", "-c", f"cat {ROSTER_FILE_PATH} 2>/dev/null"]
            try:
                result = self.docker_manager.exec_in_workspace(
                    self.workspace_id, cmd
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("读取成员管理表失败: %s", exc)
                return
            if not isinstance(result, dict) or result.get("exit_code") != 0:
                return
            stdout = result.get("stdout", "") or ""
        loaded = self._parse_roster_md(stdout)
        if loaded:
            self.members = loaded

    def _parse_roster_md(self, content: str) -> List[Dict[str, Any]]:
        """解析旧 roster markdown 表格为成员字典列表。

        兼容 11（无角色/职责）/13（含角色/职责）/14（末尾含可带队）列。
        历史 roster 是「本 agent 的成员视图」，无 parent_agent_id 列：
        - TOP 视角：行视为 TOP 直属（与历史语义一致）；
        - 非 TOP 视角：一律归为 team_member（parent 留空），消除把全
          TOP 成员误判为自己直属的伪直属问题。
        """
        members: List[Dict[str, Any]] = []
        legacy_parent = self.agent_id if self._is_top() else ""
        for raw_line in content.splitlines():
            line = raw_line.strip()
            if not line.startswith("|"):
                continue
            if "ID" in line and "名称" in line:
                continue
            if "---" in line.replace("|", ""):
                continue
            parts = [p.strip() for p in line.strip("|").split("|")]
            if len(parts) < 11:
                continue
            try:
                level = int(parts[3]) if parts[3].isdigit() else 0
            except (ValueError, IndexError):
                level = 0
            member_id = parts[0]
            if not member_id:
                continue
            new_format = len(parts) >= 13
            role = parts[7] if new_format else ""
            duty = parts[8] if new_format else ""
            if new_format:
                q, e, c, a = parts[9], parts[10], parts[11], parts[12]
            else:
                q, e, c, a = parts[7], parts[8], parts[9], parts[10]
            can_lead = True
            if len(parts) >= 14:
                can_lead = parts[13] not in ("否", "false", "False", "0")
            members.append(
                {
                    "id": member_id,
                    "name": parts[1],
                    "role": role,
                    "duty": duty,
                    "model_id": parts[2],
                    "level": level,
                    "can_lead_team": can_lead,
                    "workspace_id": member_id,
                    "parent_agent_id": legacy_parent,
                    "team_id": self.team_id or self.agent_id,
                    "created_at": parts[4],
                    "created_at_ms": None,
                    "work_status": "idle",
                    "scores": {
                        "quality": _to_score(q),
                        "efficiency": _to_score(e),
                        "collaboration": _to_score(c),
                        "accuracy": _to_score(a),
                    },
                    "comment": parts[6],
                    "system_prompt": "",
                }
            )
        return members

    def _save_roster(self, members: Optional[List[Dict[str, Any]]] = None) -> None:
        """把全量名单渲染写入当前 agent 工作空间的 ``.self/team_roster.md``。"""
        if not self.workspace_id:
            return
        from data.team_store import render_roster_md

        rows = members if members is not None else self._live_members()
        # render_roster_md 的创建时间列期望原始毫秒值
        render_rows = []
        for m in rows:
            item = dict(m)
            if item.get("created_at_ms") is not None:
                item["created_at"] = item.get("created_at_ms")
            render_rows.append(item)
        content = render_roster_md(render_rows)

        if self._io_write(self.workspace_id, ROSTER_FILE_PATH, content):
            return
        cmd = [
            "sh",
            "-c",
            f"mkdir -p .self && cat > {ROSTER_FILE_PATH} <<'ROSTER_EOF'\n"
            f"{content}ROSTER_EOF",
        ]
        try:
            self.docker_manager.exec_in_workspace(self.workspace_id, cmd)
        except Exception as exc:  # noqa: BLE001
            logger.warning("写入成员管理表失败: %s", exc)

    # ------------------------------------------------------------------
    # 寻址
    # ------------------------------------------------------------------
    def _lookup_agent_by_id(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """通过 agent_store 查询同用户 TOP agent 信息。"""
        try:
            from data.agent_store import get_agent

            return get_agent(self.user_id, agent_id)
        except Exception:  # noqa: BLE001
            return None

    def _list_top_agents(self) -> List[Dict[str, Any]]:
        """列出同用户名下全部 TOP agent（失败返回空）。"""
        if not self.user_id:
            return []
        try:
            from data.agent_store import get_agents

            return get_agents(self.user_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取 TOP agent 列表失败: %s", exc)
            return []

    def _find_member(self, target: str) -> Optional[Dict[str, Any]]:
        """在实时名单中按 id 或 name 精确查找成员（未找到返回 None）。"""
        if not target:
            return None
        for m in self._live_members():
            if m.get("id") == target or m.get("name") == target:
                return m
        return None

    def _resolve_target(self, target: str) -> Dict[str, Any]:
        """解析投递目标，返回 ``{type, id, name, reason}``。

        type 取值：
        - ``member``：本 TOP 团队成员（id/name 命中实时名单）；
        - ``leader``：当前 agent 的直属上级（成员向自己的 leader 汇报）；
        - ``top``：同用户名下其他 TOP（仅 TOP 自己可用跨 TOP 顶层寻址）；
        - ``unknown``：无法解析（成员尝试跨 TOP 时 reason=cross_top_denied）。
        """
        if not target:
            return {"type": "unknown", "id": "", "name": "", "reason": "empty"}
        member = self._find_member(target)
        if member is not None:
            return {
                "type": "member",
                "id": member.get("id", ""),
                "name": member.get("name", ""),
                "member": member,
            }
        if self.leader_id and target == self.leader_id:
            leader_agent = self._lookup_agent_by_id(self.leader_id)
            return {
                "type": "leader",
                "id": self.leader_id,
                "name": (leader_agent or {}).get("name", "") or self.leader_id,
                "agent": leader_agent,
            }
        for a in self._list_top_agents():
            if a.get("id") == target or a.get("name") == target:
                if not self._is_top():
                    return {
                        "type": "unknown",
                        "id": target,
                        "name": a.get("name", ""),
                        "reason": "cross_top_denied",
                    }
                return {
                    "type": "top",
                    "id": a.get("id", ""),
                    "name": a.get("name", ""),
                    "agent": a,
                }
        return {"type": "unknown", "id": target, "name": "", "reason": "not_found"}

    # ------------------------------------------------------------------
    # 消息投递
    # ------------------------------------------------------------------
    def _dispatch_to_member(
        self, member: Dict[str, Any], content: str
    ) -> bool:
        """broker 回退通道：将消息同步投递给成员，触发其异步串行处理。

        payload 的 leader_id 取**接收成员**的直属 leader
        （member.parent_agent_id），使 L1 给自己创建的 L2 投消息时，
        L2 收到的 leader 仍是该 L1，而不是被错误写成 TOP；向上级投递时
        调用方在 member 中带 parent_agent_id=self.leader_id。

        :return: 是否已入队（broker 或 user_id 为空时返回 False）
        """
        if self.broker is None or not self.user_id:
            return False
        member_id = member.get("id", "")
        if not member_id:
            return False
        member_model = member.get("model_id", "") or ""
        if not member_model and self.team_id:
            try:
                from data.agent_store import get_agent

                top_rec = get_agent(self.user_id, self.team_id) or {}
                member_model = top_rec.get("model_id") or ""
            except Exception as exc:  # noqa: BLE001
                logger.warning("成员空 model_id 回退 TOP 模型失败: %s", exc)
                member_model = ""
        leader_id = member.get("parent_agent_id", "") or self.leader_id
        return self.broker.dispatch(
            (self.user_id, member_id),
            {
                "user_id": self.user_id,
                "agent_id": member_id,
                "workspace_id": member.get("workspace_id", "") or member_id,
                "model_id": member_model,
                "system_prompt": member.get("system_prompt", ""),
                "leader_id": leader_id,
                "team_id": self.team_id,
                "content": content,
                "session_id": self.session_id,
            },
        )

    def _dispatch_one_fallback(
        self, resolved: Dict[str, Any], content: str
    ) -> bool:
        """无统一 dispatcher 时的 broker 直投（成员/leader/top 通用）。"""
        rtype = resolved.get("type")
        if rtype == "member":
            return self._dispatch_to_member(resolved["member"], content)
        if rtype in ("leader", "top"):
            agent = resolved.get("agent") or {}
            target = {
                "id": resolved["id"],
                "workspace_id": agent.get("workspace_id") or resolved["id"],
                "model_id": agent.get("model_id", "") or "",
                "system_prompt": "",
                # 接收方是自己的 leader：其上级是 self.leader_id 的 leader
                "parent_agent_id": self.leader_id,
            }
            return self._dispatch_to_member(target, content)
        return False

    # ------------------------------------------------------------------
    # WorkspaceIO 助手
    # ------------------------------------------------------------------
    def _io_write(self, workspace_id: str, path: str, content: str) -> bool:
        """通过 WorkspaceIO 写入文件（统一通道），成功返回 True。"""
        if self.io is None or not workspace_id:
            return False
        try:
            result = run_io(self.io.write_file(workspace_id, path, content))
            return not bool(result.get("error"))
        except Exception:  # noqa: BLE001
            logger.warning("WorkspaceIO 写入失败: %s@%s", workspace_id, path)
            return False

    def _io_read(self, workspace_id: str, path: str) -> Optional[str]:
        """通过 WorkspaceIO 读取文件，不存在或失败返回 None。"""
        if self.io is None or not workspace_id:
            return None
        try:
            result = run_io(self.io.read_file(workspace_id, path))
            if result.get("error"):
                return None
            return result.get("content", "")
        except Exception:  # noqa: BLE001
            return None

    def _leader_display_name(self) -> str:
        """当前 agent 的显示名（写入成员身份文件用）。"""
        return getattr(self.session, "agent_name", "") or "self"

    def _write_member_identity(self, member: Dict[str, Any]) -> None:
        """将成员身份信息写入其工作空间 ``.self/identity.md``。"""
        ws_id = member.get("workspace_id") or member.get("id")
        if not ws_id:
            return
        leading = "是" if member.get("can_lead_team", True) else "否"
        content = (
            "# 身份 (identity)\n\n"
            f"- member_id: {member.get('id', '')}\n"
            f"- name: {member.get('name', '')}\n"
            f"- level: {member.get('level', 0)}\n"
            f"- team_leader: {member.get('leader_name', '')}\n"
            f"- can_lead_team: {leading}\n"
        )
        if self._io_write(ws_id, ".self/identity.md", content):
            return
        b64 = __import__("base64").b64encode(content.encode("utf-8")).decode("ascii")
        cmd = [
            "sh", "-c",
            "mkdir -p .self && echo '{}' | base64 -d > .self/identity.md".format(b64),
        ]
        try:
            self.docker_manager.exec_in_workspace(ws_id, cmd)
        except Exception as exc:  # noqa: BLE001
            logger.warning("写入成员身份文件失败: %s", exc)

    def _init_member_private_space(self, member: Dict[str, Any]) -> None:
        """初始化成员私人空间 .self（rule.md / memory.md / activity.log）。"""
        ws_id = member.get("workspace_id") or member.get("id")
        if not ws_id:
            return
        name = member.get("name", "")
        leader = member.get("leader_name", "") or "self"
        mid = member.get("id", "")
        level = member.get("level", 1)
        now = self._now()
        files = {
            ".self/rule.md": (
                f"# 工作准则 (rule.md)\n\n"
                f"你是 {name}（Level {level} 团队成员，直属 leader: {leader}）。\n"
                f"工作准则：先读 .self/identity.md 与 .self/memory.md 确认身份与历史；"
                f"动手前先定位根因再做最小修改；工作过程与产出记录在 "
                f".self/activity.log（行首带日期时间）；完成后更新 "
                f".self/memory.md 并向 leader 汇报。\n"
            ),
            ".self/memory.md": (
                "# 记忆文档 (memory.md)\n\n"
                "## 任务记录\n\n"
                f"### {now} · 初始化\n\n"
                f"- 作为 {name}（member_id: {mid}）加入团队，直属 leader: {leader}。\n"
            ),
            ".self/activity.log": "",
        }
        for path, content in files.items():
            self._io_write(ws_id, path, content)

    # ------------------------------------------------------------------
    # 实时工作状态 / 成员视图
    # ------------------------------------------------------------------
    def _live_work_status(self, member_id: str) -> str:
        """返回成员**实际**工作状态（唯一权威：chat._active_tasks）。"""
        if not self.user_id or not member_id:
            return "idle"
        try:
            from agent.chat import _is_agent_working

            return "working" if _is_agent_working(self.user_id, member_id) else "idle"
        except Exception:  # noqa: BLE001
            return "idle"

    @staticmethod
    def _log_path(member_id: str) -> str:
        """成员活动日志在统一工作目录中的相对路径（leader 可直接 read）。"""
        return f"agentspace/{member_id}/.self/activity.log"

    def _member_view(
        self, member: Dict[str, Any], relation: str,
        names_map: Optional[Dict[str, str]] = None,
    ) -> Dict[str, Any]:
        """构造对外成员视图（白名单字段，不泄漏 system_prompt 等内部字段）。"""
        mid = member.get("id", "")
        parent_id = member.get("parent_agent_id", "") or ""
        leader_name = member.get("leader_name", "")
        if not leader_name and parent_id and names_map is not None:
            leader_name = names_map.get(parent_id, "")
        if not leader_name and parent_id:
            # 兜底：sub-leader 名称查 team_store，TOP 名称查 agent_store
            if parent_id == self.team_id:
                leader_name = (
                    (self._lookup_agent_by_id(parent_id) or {}).get("name", "")
                    or parent_id
                )
            else:
                leader_name = parent_id
        return {
            "id": mid,
            "name": member.get("name", ""),
            "role": member.get("role", "") or "",
            "duty": member.get("duty", "") or "",
            "model_id": member.get("model_id", "") or "",
            "level": int(member.get("level", 1) or 1),
            "can_lead_team": bool(member.get("can_lead_team", 1)),
            "parent_agent_id": parent_id,
            "leader_name": leader_name,
            "relation": relation,
            "work_status": self._live_work_status(mid),
            "review_status": member.get("review_status", "") or "",
            "log_path": self._log_path(mid),
            "created_at": member.get("created_at", "") or "",
        }

    # ------------------------------------------------------------------
    # 统一 list_teams / list_members（team 与 message 共用）
    # ------------------------------------------------------------------
    def _action_list_teams(self, arguments: dict) -> dict:
        """列出本用户名下全部 TOP agent（团队）概要。"""
        teams: List[Dict[str, Any]] = []
        for a in self._list_top_agents():
            _id = a.get("id", "")
            member_count = 0
            if _id:
                try:
                    from data.team_store import get_team

                    team = get_team(_id) or {}
                    member_count = int(team.get("member_count") or 0)
                except Exception:  # noqa: BLE001
                    member_count = 0
            teams.append({
                "id": _id,
                "name": a.get("name", ""),
                "model_id": a.get("model_id", ""),
                "workspace_id": a.get("workspace_id", ""),
                "member_count": member_count,
            })
        return {"teams": teams, "total": len(teams), "generated_at": self._now()}

    def _build_names_map(self, rows: List[Dict[str, Any]]) -> Dict[str, str]:
        """id→显示名映射（成员行 + 同用户 TOP agent）。"""
        names = {m.get("id", ""): m.get("name", "") for m in rows if m.get("id")}
        for a in self._list_top_agents():
            if a.get("id"):
                names.setdefault(a["id"], a.get("name", ""))
        return names

    def _action_list_members(self, arguments: dict) -> dict:
        """列出与本 agent 有关系的成员，按 team_leader/teammates/team_member 分组。

        - team_leader：自己的直属 leader（TOP 视角该组为空）；sub-leader
          先查 team_members（带真实 level），TOP 再查 agent_store；
        - teammates：parent_agent_id == 本 agent 的直属成员；
        - team_member：同 TOP 其余成员（排除自己），relation 标 peer/indirect。
        顶层 members 为三组合集（字段一致），total 与合集一致；筛选参数
        model_id/level/work_status 只作用于两个成员组。
        """
        rows = [m for m in self._live_members() if m.get("id") != self.agent_id]
        names_map = self._build_names_map(rows)

        own_id = self.agent_id or ""
        teammates_raw = [
            m for m in rows if (m.get("parent_agent_id") or "") == own_id
        ]
        others_raw = [
            m for m in rows if (m.get("parent_agent_id") or "") != own_id
        ]

        # 筛选（不含 leader 组）
        model_id = arguments.get("model_id")
        if model_id:
            teammates_raw = [m for m in teammates_raw if m.get("model_id") == model_id]
            others_raw = [m for m in others_raw if m.get("model_id") == model_id]
        level = arguments.get("level")
        if level is not None:
            try:
                lv = int(level)
                teammates_raw = [m for m in teammates_raw if m.get("level") == lv]
                others_raw = [m for m in others_raw if m.get("level") == lv]
            except (TypeError, ValueError):
                pass
        work_status = arguments.get("work_status")
        if work_status:
            teammates_raw = [
                m for m in teammates_raw
                if self._live_work_status(m.get("id", "")) == work_status
            ]
            others_raw = [
                m for m in others_raw
                if self._live_work_status(m.get("id", "")) == work_status
            ]

        teammates = [
            self._member_view(m, "direct", names_map) for m in teammates_raw
        ]
        team_member = []
        for m in others_raw:
            relation = "peer" if int(m.get("level", 1) or 1) == self.level else "indirect"
            team_member.append(self._member_view(m, relation, names_map))

        # team_leader：先 team_members（sub-leader 真实层级），再 agent_store
        team_leader: List[Dict[str, Any]] = []
        if self.leader_id:
            lm = next(
                (m for m in self._live_members() if m.get("id") == self.leader_id),
                None,
            )
            if lm is not None:
                view = self._member_view(lm, "team_leader", names_map)
                team_leader.append(view)
            else:
                leader_agent = self._lookup_agent_by_id(self.leader_id)
                team_leader.append({
                    "id": self.leader_id,
                    "name": (leader_agent or {}).get("name", "") or self.leader_id,
                    "role": (leader_agent or {}).get("role", "") or "",
                    "duty": "",
                    "model_id": (leader_agent or {}).get("model_id", "") or "",
                    "level": 0,
                    "can_lead_team": True,
                    "parent_agent_id": "",
                    "leader_name": "",
                    "relation": "team_leader",
                    "work_status": self._live_work_status(self.leader_id),
                    "log_path": self._log_path(self.leader_id),
                    "created_at": "",
                })

        missing = [
            (m.get("name") or m.get("id"))
            for m in teammates
            if not (m.get("role") and m.get("duty"))
        ]
        # 未就绪成员（未赋模型 / 待审核）必须显著提示：向它们派活必然被审核闸拒绝
        not_ready = [
            (m.get("name") or m.get("id"))
            for m in teammates
            if (m.get("review_status") or "") not in ("", "approved")
        ]
        hints: List[str] = []
        if not_ready:
            hints.append(
                "以下直属成员**尚未就绪**（未分配模型 / 未经用户审核），"
                "现在派活必被拒绝，请提示用户在「团队成员 → 模型配置」页"
                "为其选择模型并审核通过: " + "、".join(not_ready[:5])
            )
            if len(not_ready) > 5:
                hints[-1] += f" 等 {len(not_ready)} 名"
        if missing:
            hints.append(
                "以下直属成员 role/duty 为空，建议用 team update_member 补充完善后"
                "再用 message send_message 派发工作: " + "、".join(missing[:5])
            )
            if len(missing) > 5:
                hints[-1] += f" 等 {len(missing)} 名"
        hint = "；".join(hints)

        members_all = team_leader + teammates + team_member
        return {
            "groups": {
                "team_leader": team_leader,
                "teammates": teammates,
                "team_member": team_member,
            },
            "members": members_all,
            "total": len(members_all),
            "not_ready_count": len(not_ready),
            "hint": hint,
            "generated_at": self._now(),
        }

    # ------------------------------------------------------------------
    # 名单变更推送 / team_store 同步
    # ------------------------------------------------------------------
    def _sync_member_to_team_store(
        self, member_id: str, **fields: Any
    ) -> None:
        """把成员字段变更同步到 team_members 表（仅同步实际变化列）。"""
        from data.team_store import get_members, update_member

        top_id = self.team_id or self.agent_id
        if not top_id or not member_id:
            return
        patch = {k: v for k, v in fields.items() if v is not None}
        try:
            current = next(
                (m for m in get_members(top_id) if m.get("id") == member_id), None
            )
            if current is None:
                return
            clean: Dict[str, Any] = {}
            for k, v in patch.items():
                if k == "scores":
                    continue
                if str(current.get(k, "")) != str(v):
                    clean[k] = v
            if isinstance(patch.get("scores"), dict):
                merged = dict(current.get("scores") or {})
                merged.update(patch["scores"])
                clean["scores"] = merged
            if clean:
                update_member(top_id, member_id, **clean)
        except Exception as exc:  # noqa: BLE001
            logger.warning("同步成员信息到 team_store 失败 %s: %s", member_id, exc)

    def _push_roster_update(self) -> int:
        """名单变更后向本 TOP 下全部成员推送最新 roster（触发拓扑刷新）。"""
        from data.team_store import get_members, render_roster_md

        top_id = self.team_id or self.agent_id
        if not top_id:
            return 0
        try:
            members = get_members(top_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("名单推送读取成员失败: %s", exc)
            return 0
        if not members:
            return 0
        try:
            roster_md = render_roster_md(members)
        except Exception as exc:  # noqa: BLE001
            logger.warning("名单推送渲染 roster 失败: %s", exc)
            return 0
        pushed = 0
        for m in members:
            _id = m.get("id", "")
            if not _id or not self.user_id:
                continue
            payload = {
                "user_id": self.user_id,
                "agent_id": _id,
                "workspace_id": m.get("workspace_id") or _id,
                "model_id": m.get("model_id", ""),
                "system_prompt": m.get("system_prompt", ""),
                "leader_id": m.get("parent_agent_id") or top_id,
                "team_id": top_id,
                "content": ("【团队名单已更新】\n"
                            "请刷新你的成员拓扑认知，以最新名单为准：\n"
                            + roster_md),
                "event": "roster_update",
                "session_id": self.session_id,
            }
            try:
                if self.broker is not None:
                    if self.broker.dispatch((self.user_id, _id), payload):
                        pushed += 1
            except Exception as exc:  # noqa: BLE001
                logger.warning("名单推送投递失败 %s: %s", _id, exc)
        return pushed

    # ------------------------------------------------------------------
    # 成员活动日志
    # ------------------------------------------------------------------
    def _read_member_activity_tail(
        self, workspace_id: str, lines: int = 5
    ) -> List[str]:
        """读取成员活动日志最后 N 行（优先统一 IO，回退容器 tail）。"""
        if not workspace_id:
            return []
        content = self._io_read(workspace_id, ".self/activity.log")
        if content is not None:
            return [ln for ln in content.splitlines() if ln.strip()][-lines:]
        try:
            result = self.docker_manager.exec_in_workspace(
                workspace_id,
                ["sh", "-c", f"tail -n {lines} .self/activity.log 2>/dev/null"],
            )
            if isinstance(result, dict) and result.get("exit_code", 0) == 0:
                return [
                    ln for ln in (result.get("stdout", "") or "").splitlines()
                    if ln.strip()
                ]
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取成员活动日志失败: %s", exc)
        return []

    def _last_activity_at(self, workspace_id: str) -> str:
        """解析成员活动日志最后一行的时间戳（带日期；旧格式原样返回）。"""
        tail = self._read_member_activity_tail(workspace_id, lines=3)
        for line in reversed(tail):
            m = _LOG_TS_RE.match(line)
            if m:
                return m.group(1)
            legacy = _LOG_TS_LEGACY_RE.match(line)
            if legacy:
                return f"旧格式无日期 {legacy.group(1)}"
        return ""
