"""团队全量建队 - TOP agent 创建时预建全部成员（P4 团队初始化）。

spec「TOP 创建即全量建队」：创建 TOP agent 时 SHALL 同时预建全部成员——
名字取自 ``server/data/names.json``（同用户内全局唯一）、角色取自标准角色模板
（默认 16 个，可配置）、职责留空、状态 idle，并初始化 ``workspace/<agent id>/``
（含 ``.self/`` 与 ``spec/``）、登记 ``teams`` / ``team_members`` 表、
生成 ``.self/team_roster.md`` 视图。

说明：
- 建队发生在后端的 REST 创建 TOP 接口内，该时刻前端 WebSocket（local executor）
  尚未建立，故成员工作空间/roster 的写入走 ``DockerManager.exec_in_workspace``
  （本地降级子进程）这一确定性路径，而非反向 WS。
- 名单的权威来源是 ``team_store``（teams/team_members 表）；``team_roster.md``
  只是给 LLM 看的生成视图。
"""
import json
import logging
import random
import sqlite3
import string
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# 名字池文件：server/data/names.json
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_NAMES_FILE = _DATA_DIR / "names.json"

# 标准角色模板（默认 16 个；职责留空，由 leader 经 update_member 分配）
_DEFAULT_ROLES = (
    "产品经理",
    "架构师",
    "后端工程师",
    "前端工程师",
    "算法工程师",
    "测试工程师",
    "数据工程师",
    "运维工程师",
    "安全工程师",
    "UI 设计师",
    "UX 设计师",
    "项目经理",
    "技术写作工程师",
    "DevOps 工程师",
    "质量工程师",
    "教培工程师",
)

# roster 视图文件路径（与 team_tool 保持一致）
ROSTER_FILE_PATH = ".self/team_roster.md"


def _load_names() -> List[str]:
    """读取名字池（``server/data/names.json``）。"""
    if _NAMES_FILE.exists():
        try:
            data = json.loads(_NAMES_FILE.read_text(encoding="utf-8"))
            return [str(n).strip() for n in data if str(n).strip()]
        except Exception as exc:  # noqa: BLE001
            logger.warning("解析名字池失败: %s", exc)
    return []


def _unused_names(pool: List[str], used: set) -> List[str]:
    """过滤掉同用户内已使用的名字，返回可用的新名。"""
    return [n for n in pool if n not in used]


def _used_names(user_id: str, top_agent_id: str) -> set:
    """收集同用户内已占用的名字（其他 agent 的 TOP 名 + 全部成员名）。"""
    from data.agent_store import get_agents
    from data.team_store import get_members

    used: set = set()
    # 该用户下所有 agent（TOP）的 name
    for a in get_agents(user_id) or []:
        used.add(a.get("name", ""))
    # 该 TOP 旗下成员名
    for m in get_members(top_agent_id) or []:
        used.add(m.get("name", ""))
    return used


def _pick_names(user_id: str, top_agent_id: str, count: int) -> List[str]:
    """从名字池为成员取名字（同用户全局唯一，随机打乱抽取）。

    :raises ValueError: 名字池不足以提供 count 个未用名字
    """
    pool = _load_names()
    used = _used_names(user_id, top_agent_id)
    avail = [n for n in pool if n not in used]
    if len(avail) < count:
        raise ValueError(
            f"名字池不足：需 {count} 个名字，可用 {len(avail)} 个"
            f"（已用 {len(used) - (0 if _team_exists(top_agent_id) else 0)} / 池 {len(pool)}）。"
            "请扩充 server/data/names.json。"
        )
    random.shuffle(avail)
    return avail[:count]


def _team_exists(top_agent_id: str) -> bool:
    from data.team_store import get_team

    return get_team(top_agent_id) is not None


def _generate_member_ids(count: int) -> List[str]:
    """生成 count 个唯一成员 ID（member_{ts}_{rand}）。"""
    ts = int(time.time())
    result: List[str] = []
    for _ in range(count):
        suffix = "".join(
            random.choices(string.ascii_lowercase + string.digits, k=6)
        )
        result.append(f"member_{ts}_{suffix}")
    return result


def _write_member_workspace(
    docker_manager: Any, member: Dict[str, Any], top_agent: Dict[str, Any]
) -> None:
    """初始化成员工作空间（\\workspace/<agent id>/）与 .self 文档。

    与 team_tool._action_create_member 对齐：创建共享工作空间（本地降级本地目录），
    写入 identity.md / memory.md / rule.md / activity.log。建队时机 WS 未连，
    一律走 DockerManager.exec_in_workspace 确定性路径。
    """
    mem = dict(member)
    ws_id = mem.get("workspace_id") or mem.get("id")
    if not ws_id:
        return
    if docker_manager is not None:
        try:
            docker_manager.create_workspace(
                workspace_id=ws_id,
                parent_workspace_id=top_agent.get("workspace_id") or None,
                agent_name=mem.get("name"),
                shared_with=mem.get("top_workspace_id") or None,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("建队创建成员工作空间失败 %s: %s", ws_id, exc)

    name = mem.get("name", "")
    leader = top_agent.get("name", "") or "self"
    mid = mem.get("id", "")
    level = mem.get("level", 1)
    now = mem.get("created_at", "")
    files = {
        ".self/identity.md": (
            "# 身份 (identity)\n\n"
            f"- member_id: {mid}\n"
            f"- name: {name}\n"
            f"- top_agent: {leader} ({top_agent.get('id', '')})\n"
            f"- level: {level}\n"
            f"- can_lead_team: 是\n"
        ),
        ".self/rule.md": (
            f"# 工作准则 (rule.md)\n\n"
            f"你是 {name}（Level {level} 团队成员，直属 TOP leader: {leader}）。\n"
            "工作准则：先读 .self/identity.md 与 .self/memory.md 确认身份与历史；"
            "动手前先定位根因再做最小修改；完成后更新 .self/memory.md 并向 leader 汇报。\n"
        ),
        ".self/memory.md": (
            "# 记忆文档 (memory.md)\n\n"
            "## 任务记录\n\n"
            f"### {now} · 初始化\n\n"
            f"- 作为 {name}（member_id: {mid}）加入团队（TOP: {leader}）。\n"
        ),
        ".self/activity.log": "# Agent 活动日志\n",
    }
    for path, content in files.items():
        _b64_write(docker_manager, ws_id, path, content)


def _b64_write(docker_manager: Any, ws_id: str, path: str, content: str) -> None:
    """经 base64 写入文件（中文安全），本地/云端统一走 exec_in_workspace。"""
    import base64

    if docker_manager is None:
        return
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    cmd = [
        "sh", "-c",
        f"mkdir -p .self && echo '{b64}' | base64 -d > {path}",
    ]
    try:
        docker_manager.exec_in_workspace(ws_id, cmd)
    except Exception as exc:  # noqa: BLE001
        logger.warning("写入成员工作区 %s@%s 失败: %s", ws_id, path, exc)


def _write_roster_view(
    docker_manager: Any, top_agent: Dict[str, Any], members: List[Dict[str, Any]]
) -> None:
    """生成并落盘 roster 视图（``.self/team_roster.md``）。"""
    from data.team_store import render_roster_md

    content = render_roster_md(members)
    ws_id = top_agent.get("workspace_id") or top_agent.get("id")
    if not ws_id:
        return
    _b64_write(docker_manager, ws_id, ROSTER_FILE_PATH, content)


def init_team_for_top(
    user_id: str, top_agent: Dict[str, Any], docker_manager: Any,
    member_count: Optional[int] = None,
    max_level: Optional[int] = None,
    max_members_per_level: Optional[int] = None,
) -> Dict[str, Any]:
    """TOP agent 创建时全量建队（幂等：已有团队则直接返回现状）。

    :param user_id: 用户标识
    :param top_agent: 刚创建的 TOP agent 记录（需含 id/name/workspace_id）
    :param docker_manager: DockerManager 或 None
    :param member_count: 要创建的成员数，缺省按 ``max_members_per_level``
    :param max_level: 团队最大层级深度（创建 TOP 时设定，缺省用代码默认值）
    :param max_members_per_level: 每层成员上限（创建 TOP 时设定，缺省用代码
        默认值；成员数 = clamp(member_count or 上限, 1, 上限)，只增不减）
    :return: ``{"team":..., "members": [...], "created_count": n}``；
             名字池不足抛 ValueError
    """
    from data.team_store import (
        add_member,
        get_members,
        get_team,
        init_team,
    )

    top_agent_id = top_agent.get("id", "")
    if not top_agent_id:
        return {"error": "缺少 top_agent_id"}

    # 团队配置在创建 TOP 时设定：归一化后持久化到 teams 表（此后不可修改）
    from config.team import resolve_team_config

    cfg = resolve_team_config(max_level, max_members_per_level)
    team_max_level = cfg["max_level"]
    team_max_members = cfg["max_members_per_level"]

    # 幂等：已建团队直接返回现状（重复 TOP 记录/重试）
    existing = get_team(top_agent_id)
    if existing is not None:
        return {
            "team": existing,
            "members": get_members(top_agent_id),
            "created_count": 0,
        }

    # 初始成员数：显式 member_count 缺省按每层成员上限，钳制在 1..上限
    count = int(member_count or team_max_members)
    count = max(1, min(count, team_max_members))

    team = init_team(
        user_id, top_agent_id, top_agent.get("name", ""),
        max_level=team_max_level, max_members_per_level=team_max_members,
    )
    top_ws = top_agent.get("workspace_id") or top_agent_id

    # 取名字（同名用户全局唯一）与生成成员 ID
    names = _pick_names(user_id, top_agent_id, count)
    ids = _generate_member_ids(count)

    created: List[Dict[str, Any]] = []
    now_ms = int(time.time() * 1000)
    for i in range(count):
        role = _DEFAULT_ROLES[i % len(_DEFAULT_ROLES)]
        member = add_member(
            user_id=user_id,
            top_agent_id=top_agent_id,
            member_id=ids[i],
            name=names[i],
            role=role,
            duty="",
            # 成员默认继承 TOP 的模型：保证建队即可接收消息并真正执行
            # （此前 model_id 为空导致 _process_member_message 因模型缺失
            #   静默丢弃消息，成员"收不到"leader 的任务；leader 仍可经
            #   team update_member 为成员改配独立模型）
            model_id=top_agent.get("model_id", ""),
            level=1,
            system_prompt="",
            # P4 全量建队：直属 leader 即 TOP 自身
            parent_agent_id=top_agent_id,
        )
        member["workspace_id"] = member["id"]
        member["top_workspace_id"] = top_ws
        member["top_agent_name"] = top_agent.get("name", "")
        member["created_at"] = time.strftime(
            "%Y-%m-%d %H:%M:%S", time.localtime(now_ms / 1000)
        )
        created.append(member)

    # 初始化成员工作空间 + 生成 TOP 的 roster 视图
    for m in created:
        _write_member_workspace(docker_manager, m, top_agent)
    _write_roster_view(docker_manager, top_agent, created)

    logger.info(
        "TOP 全量建队完成: %s (%d 名成员)", top_agent_id, len(created)
    )
    return {
        "team": team,
        "members": created,
        "created_count": len(created),
    }


def get_top_members(top_agent_id: str) -> List[Dict[str, Any]]:
    """读取某 TOP 旗下全部成员（供 system prompt 拓扑注入 / 名单推送）。"""
    from data.team_store import get_members

    return get_members(top_agent_id) or []