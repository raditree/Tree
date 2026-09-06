"""内置 team 工具 - 团队成员管理、消息管理、任务管理。

工具覆盖三个子域：
- 成员管理：创建成员（team leader 权限，应用户自然语言要求）、成员管理表
  （.self/team_roster.md）、多维评分、成员/状态查询
- 消息管理：点对点消息、广播消息、文件发送
- 任务管理：任务分配、任务完成流程、任务跟踪、等待成员完成

team 工具同时维护团队层级限制：顶部 agent 为 Level 0，最大层级深度与每层
成员上限在**创建 TOP agent 时设定**（teams 表，创建后不可修改，成员只增不
减）；can_lead_team 为 False 的成员不可创建子团队。成员创建只允许 team
leader（经 create_member，用户自然语言驱动），普通成员只能 update_member
编辑信息，不可创建/删除成员。
"""

import logging
import os
import random
import string
import time
from typing import Any, Dict, List, Optional, Tuple

from agent.context_isolation import ContextIsolator
from io_.docker_manager import DockerManager
from io_.workspace_io import run_io
from llm.llm import AgentLLMSession
from config.models import ModelConfig
from prompt import versions

logger = logging.getLogger(__name__)

# 成员管理表在工作空间内的相对路径
ROSTER_FILE_PATH: str = ".self/team_roster.md"

# 多维评分字段
SCORE_FIELDS = ("quality", "efficiency", "collaboration", "accuracy")


def _to_score(value: Any) -> float:
    """将任意值解析为 0-10 的评分，非法值归 0。"""
    try:
        return max(0.0, min(10.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def _fmt_ts(value: Any) -> str:
    """将毫秒时间戳格式化为 ``YYYY-MM-DD HH:MM:SS``；非法/空值原样返回。"""
    if not value:
        return "unknown"
    try:
        ts = int(value) / 1000.0
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
    except (TypeError, ValueError):
        return str(value)


def _resolve_team_limits(team_id: str) -> Tuple[int, int]:
    """按 TOP 的团队记录解析规模限制，返回 ``(max_level, max_members_per_level)``。

    团队配置在创建 TOP agent 时由用户设定并持久化到 ``teams`` 表
    （创建后不可修改，成员只增不减）；旧数据无团队记录/配置列缺失时回退
    ``config.team`` 的代码默认值。不再读取用户等级 / app.yaml / docker 配置。

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


class TeamTool:
    """team 工具：团队成员管理、消息管理、任务管理。

    每个 agent 持有一个 TeamTool 实例：
    - ``self.level`` 表示当前 agent 的层级，顶部 agent 为 Level 0
    - ``self.can_lead_team`` 表示当前 agent 是否可创建子团队（默认 True）
    - 成员管理表持久化到工作空间 ``.self/team_roster.md``
    - 消息与任务暂用内存存储（``self.messages`` / ``self.tasks``）
    """

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
        """初始化 team 工具。

        :param session: AgentLLMSession 实例，提供 workspace_id
        :param docker_manager: DockerManager 实例，用于工作空间与文件操作
        :param model_configs: 可用模型配置字典（model_id -> ModelConfig）
        :param broker: 团队成员消息投递器（TeamMessageBroker），用于
                       send_message/assign_task 时触发成员异步处理
        :param user_id: 当前 leader 的用户标识，投递成员消息时使用
        :param agent_id: 当前 agent 的 ID
        :param leader_id: 当前 agent 的上级 leader ID（用于队友向 leader 发消息）
        :param team_id: 顶层 agent 的 ID，用于预算追踪（团队成员共享顶层预算）
        :param session_id: 当前会话 ID（透传到成员投递，保证成员上下文
                           按 session 隔离；为空时投递回退默认会话）
        """
        self.session = session
        self.docker_manager = docker_manager
        self.model_configs: Dict[str, ModelConfig] = model_configs
        self.workspace_id: str = getattr(session, "workspace_id", "") or ""
        self.broker = broker
        self.user_id = user_id
        self.agent_id = agent_id
        self.leader_id = leader_id
        self.team_id = team_id or agent_id
        # 当前会话 ID：leader 投递成员消息时透传，成员上下文按 session 隔离
        self.session_id = session_id or ""
        # 统一消息发送回调（main 提供）：User-Agent / Agent-Agent 收敛出口
        self.message_dispatcher = message_dispatcher
        # 统一工作空间 IO（WorkspaceIO）：成员空间/roster/身份文件读写走统一通道，
        # 解决双轨制（team 工具走容器、成员工具走本地）导致的私人空间不可见问题。
        # 本地模式 -> baseDir/agentspace/{id}/.self；云端模式 -> 容器路径。
        self.io: Any = io

        # 成员列表（内存，同时持久化到 team_roster.md）
        self.members: List[Dict[str, Any]] = []
        # 消息历史（内存）：每条 {id, from, to, type, content, timestamp, ...}
        self.messages: List[Dict[str, Any]] = []
        # 任务列表（内存）：每条 {id, description, priority, ...}
        self.tasks: List[Dict[str, Any]] = []

        # 当前 agent 层级：顶部 agent 为 Level 0
        self.level: int = 0
        # 团队最大层级深度 + 每层成员上限：按所属 TOP 的团队记录解析
        # （创建 TOP 时设定，之后不可修改；未建队/旧数据回退代码默认值）
        self.max_team_level, self.max_members_per_level = _resolve_team_limits(
            self.team_id or self.agent_id
        )
        # 当前 agent 是否可带领团队（由 set 工具设置；False 时不可创建子团队）
        self.can_lead_team: bool = True

        # 上下文隔离器（SubTask 14.5）：控制子 agent 上下文对父 agent 的影响
        self.context_isolator = ContextIsolator()

        # 从工作空间加载已有成员管理表（若存在）
        self._load_roster()

    # ------------------------------------------------------------------
    # 工具定义与分发
    # ------------------------------------------------------------------
    def get_tool_definition(self) -> dict:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "team",
                "description": versions.active_tool_description("team"),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": [
                                "list_models",
                                "list_teams",
                                "list_members",
                                "create_member",
                                "query_member",
                                "update_member",
                                "query_status",
                                "view_member_output",
                                "view_member_log",
                                "send_message",
                                "broadcast",
                                "assign_task",
                                "query_tasks",
                                "wait_for",
                            ],
                            "description": "操作类型。按成员寻址的操作必须同时提供 "
                                         "target_member_id（或其等价别名 member_name），"
                                         "否则会因缺少 target_member_id 而失败："
                                         "update_member / query_member / query_status / "
                                         "view_member_output / view_member_log / "
                                         "send_message / assign_task。"
                                         "create_member 为团队 leader 权限：仅在用户"
                                         "明确要求组建/扩充团队时调用，创建后系统会"
                                         "自动向新成员发送其 system prompt 初始化消息",
                        },
                        "model_id": {
                            "type": "string",
                            "description": "编辑成员时选择的模型 ID",
                        },
                        "member_name": {
                            "type": "string",
                            "description": "成员名称（按 name 寻址时使用，是 target_member_id 的别名；"
                                           "update_member 等按成员寻址的操作二者必填其一）",
                        },
                        "target_member_id": {
                            "type": "string",
                            "description": "目标成员 ID 或名称（按 name 基于拓扑寻址）。"
                                           "update_member 等按成员寻址的操作必填："
                                           "调用前先从 list_members 获取确切 id/name，切勿省略",
                        },
                        "name": {
                            "type": "string",
                            "description": "编辑成员时的新名称（角色）",
                        },
                        "role": {
                            "type": "string",
                            "description": "成员角色（如 后端工程师），update_member 设置",
                        },
                        "duty": {
                            "type": "string",
                            "description": "成员职责/分工说明，update_member 设置",
                        },
                        "work_status": {
                            "type": "string",
                            "enum": ["idle", "working", "waiting_input", "stopped", "error"],
                            "description": "成员工作状态（**只读**：由实际执行态决定，"
                                           "请用 list_members/query_member 查询，"
                                           "不可通过 update_member 设置）",
                        },
                        "can_lead_team": {
                            "type": "boolean",
                            "description": "成员是否可创建子团队",
                        },
                        "comment": {
                            "type": "string",
                            "description": "对成员的评价",
                        },
                        "system_prompt": {
                            "type": "string",
                            "description": "成员的独立系统提示词/职责说明（create_member "
                                         "创建时设置，或 update_member 修改；仅更新提示词，"
                                         "**不清空成员上下文/工作区**，新提示词在成员下次"
                                         "上下文重建（compact）时生效）",
                        },
                        "scores": {
                            "type": "object",
                            "description": "多维评分（0-10）：quality/efficiency/collaboration/accuracy",
                            "properties": {
                                "quality": {"type": "number"},
                                "efficiency": {"type": "number"},
                                "collaboration": {"type": "number"},
                                "accuracy": {"type": "number"},
                            },
                        },
                        "message": {
                            "type": "string",
                            "description": "消息内容",
                        },
                        "file_path": {
                            "type": "string",
                            "description": "文件路径",
                        },
                        "task_description": {
                            "type": "string",
                            "description": "任务描述",
                        },
                        "task_priority": {
                            "type": "string",
                            "description": "任务优先级",
                        },
                        "task_output": {
                            "type": "string",
                            "description": "预期输出",
                        },
                        "limit": {
                            "type": "integer",
                            "description": "查看成员输出时返回的提交条数（默认 10）",
                        },
                        "lines": {
                            "type": "integer",
                            "description": "查看成员活动日志时返回的行数（默认 30）",
                        },
                        "target_member_ids": {
                            "type": "string",
                            "description": "等待完成的成员 ID 列表，多个 ID 用逗号分隔（如 'member_xxx,member_yyy'）",
                        },
                        "timeout": {
                            "type": "integer",
                            "description": "等待超时时间（秒），默认 300（5 分钟）",
                        },
                    },
                    "required": ["action"],
                },
            },
        }

    def execute(self, arguments: dict) -> dict:
        """根据 action 分发执行对应子流程。"""
        action = arguments.get("action")
        dispatch = {
            "list_models": self._action_list_models,
            "list_teams": self._action_list_teams,
            "list_members": self._action_list_members,
            "create_member": self._action_create_member,
            "query_member": self._action_query_member,
            "update_member": self._action_update_member,
            "query_status": self._action_query_status,
            "view_member_output": self._action_view_member_output,
            "view_member_log": self._action_view_member_log,
            "send_message": self._action_send_message,
            "broadcast": self._action_broadcast,
            "assign_task": self._action_assign_task,
            "query_tasks": self._action_query_tasks,
            "wait_for": self._action_wait_for,
        }
        handler = dispatch.get(action)
        if handler is None:
            return {"error": f"未知 action: {action}"}
        return handler(arguments)

    # ------------------------------------------------------------------
    # 辅助方法
    # ------------------------------------------------------------------
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

    @staticmethod
    def _generate_task_id() -> str:
        """生成唯一任务 ID。"""
        ts = int(time.time())
        suffix = random.randint(1000, 9999)
        return f"task_{ts}_{suffix}"

    def _find_member(self, member_id: str) -> Optional[Dict[str, Any]]:
        """按 ID 或名称查找成员，未找到返回 None。

        支持按 name 基于拓扑寻址（spec「top 内寻址」）：成员名在 TOP 内全局唯一，
        故 name 与 member id 一样可唯一定位到本 TOP 的一名成员。
        """
        for m in self.members:
            if m.get("id") == member_id or m.get("name") == member_id:
                return m
        return None

    def _lookup_agent_by_id(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """通过 agent_store 查询 agent 信息（向 leader 发送时补齐模型配置）。"""
        try:
            from data.agent_store import get_agent
            return get_agent(self.user_id, agent_id)
        except Exception:  # noqa: BLE001
            return None

    def _resolve_target(self, target: str) -> Dict[str, Any]:
        """解析投递目标（spec「top 内寻址 / 跨 Top 顶层寻址」）。

        返回 ``{"type": "member"|"top"|"unknown", "id": ..., "name": ...}``。
        - 目标命中本 TOP 成员（id 或 name）→ member；
        - 目标命中同用户名下其他 TOP（id 或 name）→ top（TOP agent 之间顶层寻址）；
        - 否则 unknown。
        """
        if not target:
            return {"type": "unknown", "id": "", "name": ""}
        # 1) 本 TOP 成员（按 id 或 name）
        member = self._find_member(target)
        if member is not None:
            return {
                "type": "member",
                "id": member.get("id", ""),
                "name": member.get("name", ""),
            }
        # 2) 同用户名下 TOP（按 id 或 name）
        if self.user_id:
            try:
                from data.agent_store import get_agents

                for a in get_agents(self.user_id) or []:
                    if a.get("id") == target or a.get("name") == target:
                        return {
                            "type": "top",
                            "id": a.get("id", ""),
                            "name": a.get("name", ""),
                        }
            except Exception as exc:  # noqa: BLE001
                logger.warning("解析跨 Top 目标失败: %s", exc)
        return {"type": "unknown", "id": target, "name": ""}

    def _dispatch_to_member(
        self, member: Dict[str, Any], content: str
    ) -> bool:
        """将消息同步投递给成员，触发其异步串行处理。

        :return: 是否已入队（broker 或 user_id 为空时不投递）
        """
        if self.broker is None or not self.user_id:
            return False
        member_id = member.get("id", "")
        if not member_id:
            return False
        # 空 model_id 自动回退所属 TOP 的模型（与 _dispatch_agent_message
        # 一致）：建队默认继承 TOP 模型，兼容历史空 model_id 成员，避免
        # 消息被 _process_member_message 因"模型不存在"静默丢弃。
        member_model = member.get("model_id", "") or ""
        if not member_model and self.team_id:
            try:
                from data.agent_store import get_agent

                top_rec = get_agent(self.user_id, self.team_id) or {}
                member_model = top_rec.get("model_id") or ""
            except Exception as exc:  # noqa: BLE001
                logger.warning("成员空 model_id 回退 TOP 模型失败: %s", exc)
                member_model = ""
        return self.broker.dispatch(
            (self.user_id, member_id),
            {
                "user_id": self.user_id,
                "agent_id": member_id,
                "workspace_id": member.get("workspace_id", ""),
                "model_id": member_model,
                "system_prompt": member.get("system_prompt", ""),
                "leader_id": self.leader_id,
                "team_id": self.team_id,
                "content": content,
                # 透传当前会话：成员上下文/历史按 session 隔离，避免多会话串扰
                "session_id": self.session_id,
            },
        )

    def _io_write(self, workspace_id: str, path: str, content: str) -> bool:
        """通过 WorkspaceIO 写入文件（统一双轨制），成功返回 True。"""
        if self.io is None:
            return False
        try:
            result = run_io(self.io.write_file(workspace_id, path, content))
            return not bool(result.get("error"))
        except Exception:  # noqa: BLE001
            logger.warning("WorkspaceIO 写入失败: %s@%s", workspace_id, path)
            return False

    def _io_read(self, workspace_id: str, path: str) -> Optional[str]:
        """通过 WorkspaceIO 读取文件，不存在或失败返回 None。"""
        if self.io is None:
            return None
        try:
            result = run_io(self.io.read_file(workspace_id, path))
            if result.get("error"):
                return None
            return result.get("content", "")
        except Exception:  # noqa: BLE001
            return None

    @staticmethod
    def _now() -> str:
        """返回当前时间字符串。"""
        return time.strftime("%Y-%m-%d %H:%M:%S")

    def _leader_name(self) -> str:
        """返回当前 agent（leader）的名称，用于成员身份记录。"""
        return getattr(self.session, "agent_name", "") or "self"

    def _write_member_identity(self, member: Dict[str, Any]) -> None:
        """将成员身份信息写入其工作空间 ``.self/identity.md``。

        供成员 normal LLM 在初始化时读取，明确自己所在 team、level、
        team leader 以及是否在开团队（checklist 6(c) 身份透明）。
        """
        ws_id = member.get("workspace_id")
        if not ws_id:
            return
        leading = "是" if member.get("can_lead_team") else "否"
        content = (
            "# 身份 (identity)\n\n"
            f"- member_id: {member.get('id', '')}\n"
            f"- name: {member.get('name', '')}\n"
            f"- level: {member.get('level', 0)}\n"
            f"- team_leader: {member.get('leader_name', '')} "
            f"({member.get('parent_workspace_id', '')})\n"
            f"- can_lead_team: {leading}\n"
        )
        # 优先走统一 WorkspaceIO（本地模式 -> baseDir/agentspace/{id}/.self，
        # 成员工具立即可见）；io 不可用时回退 docker exec（云端容器）
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

    @staticmethod
    def _sanitize_file_path(file_path: str) -> Optional[str]:
        """校验文件路径：仅允许相对路径且字符安全，防止路径穿越与命令注入。"""
        if not file_path:
            return None
        normalized = os.path.normpath(file_path).replace("\\", "/")
        # 不允许绝对路径或当前目录
        if normalized.startswith("/") or normalized in (".", ""):
            return None
        parts = normalized.split("/")
        if any(p == ".." for p in parts):
            return None
        # 仅允许安全字符，防止 shell 命令注入
        allowed = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_-."
        )
        if not all(c in allowed for c in normalized):
            return None
        return normalized

    # ------------------------------------------------------------------
    # SubTask 7.1: 创建成员流程
    # ------------------------------------------------------------------
    def _action_list_models(self, arguments: dict) -> dict:
        """列出可用模型池。"""
        models = [
            {
                "model_id": mid,
                "name": cfg.name,
            }
            for mid, cfg in self.model_configs.items()
        ]
        return {"models": models, "total": len(models)}

    def _action_list_teams(self, arguments: dict) -> dict:
        """列出本用户名下的全部 TOP agent（团队），用于跨 Top 顶层通信前"熟悉"对方。

        仅返回 TOP 概要（id/name/成员数），不透露其他团队的成员名单
        （spec「跨 TOP 成员名单不传递」）。
        """
        from data.agent_store import get_agents
        from data.team_store import get_team

        agents = []
        try:
            agents = get_agents(self.user_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("list_teams 读取 agent 失败: %s", exc)
        teams: List[Dict[str, Any]] = []
        for a in agents:
            _id = a.get("id", "")
            team = get_team(_id) if _id else None
            teams.append({
                "id": a.get("id", ""),
                "name": a.get("name", ""),
                "model_id": a.get("model_id", ""),
                "workspace_id": a.get("workspace_id", ""),
                "member_count": int((team or {}).get("member_count") or 0),
            })
        return {"teams": teams, "total": len(teams)}

    def _action_create_member(self, arguments: dict) -> dict:
        """创建新成员流程（团队 leader 权限，应用户自然语言要求调用）。

        1. 层级校验：当前层级 >= 本 TOP 配置的最大层级深度时拒绝（动态错误信息）
        2. can_lead_team 校验：当前 agent 不可带队时拒绝
        3. 直属成员数量校验：已达本 TOP 配置的每层成员上限时拒绝
           （按 parent_agent_id == 当前 agent 计数，成员只增不减）
        4. 未指定 model_id 时返回可用模型池
        5. 创建工作空间（parent_workspace_id = 当前 agent 的 workspace_id）
        6. 配置成员信息并加入 self.members（含 system_prompt）
        7. 持久化到成员管理表 + team_members 表
        8. **向新成员投递初始化消息**（携带其 system_prompt），触发成员
           首次会话构建与确认回复
        """
        # 层级深度校验（本 TOP 创建时设定的 max_level；顶部 agent 为 Level 0）
        if self.level >= self.max_team_level:
            return {
                "error": f"已达最大层级（Level {self.max_team_level}），"
                "不可继续创建子团队"
            }

        # 直属成员数量上限（按 parent_agent_id 计数，而非 TOP 总人数——
        # team_members 表含全层级成员，混计会让子 agent 误判上限已满）
        direct_count = sum(
            1 for m in self.members
            if (m.get("parent_agent_id") or "") == self.agent_id
        )
        if direct_count >= self.max_members_per_level:
            return {
                "error": f"当前 agent 的直属成员数量已达上限"
                f"（{self.max_members_per_level}），不可继续创建成员"
            }

        # can_lead_team 校验（SubTask 9.5.3）
        if not self.can_lead_team:
            return {"error": "当前成员不可创建子团队（can_lead_team=False）"}

        # 未指定 model_id 时返回可用模型池
        model_id = arguments.get("model_id")
        if not model_id:
            return self._action_list_models(arguments)

        if model_id not in self.model_configs:
            return {"error": f"模型不存在: {model_id}"}
        model_cfg = self.model_configs[model_id]

        # 生成成员 ID
        member_id = self._generate_member_id()
        member_name = arguments.get("member_name") or f"member-{member_id[-6:]}"
        # 成员独立系统提示词（leader 创建时设定；创建后系统自动向成员发送
        # 该提示词作为初始化消息，见本函数末尾）
        system_prompt = str(arguments.get("system_prompt") or "").strip()

        # 创建工作空间（含 Git，parent_workspace_id 设为当前 agent 的 workspace_id；
        # 云端模式下共享所属顶层 agent 的主工作区，仅初始化私人空间 .self）
        ws_result = self.docker_manager.create_workspace(
            workspace_id=member_id,
            parent_workspace_id=self.workspace_id or None,
            agent_name=member_name,
            shared_with=self.team_id,
        )
        if "error" in ws_result:
            return {"error": "创建成员工作空间失败", "detail": ws_result}

        # 配置成员信息：层级 = 当前层级 + 1（SubTask 9.5.1）
        now = self._now()
        member: Dict[str, Any] = {
            "id": member_id,
            "name": member_name,
            "model_id": model_id,
            "model_name": model_cfg.name,
            "level": self.level + 1,
            "workspace_id": ws_result.get("workspace_id", member_id),
            "container_id": ws_result.get("container_id", ""),
            "parent_workspace_id": self.workspace_id,
            "parent_agent_id": self.agent_id,
            "leader_name": self._leader_name(),
            "created_at": now,
            "work_status": "idle",  # idle / working / waiting_input / stopped / error
            "current_task": "",
            "can_lead_team": True,
            # 成员独立系统提示词（leader 可后续通过 update_member 修改；
            # 修改只更新提示词，不清空上下文/工作区）
            "system_prompt": system_prompt,
            # 多维评分（SubTask 7.3）
            "scores": {
                "quality": 0.0,
                "efficiency": 0.0,
                "collaboration": 0.0,
                "accuracy": 0.0,
            },
            "comment": "",
            # 任务与消息（内存）
            "task_ids": [],
            "message_history": [],
        }
        self.members.append(member)

        # 记录身份信息到工作空间 .self/identity.md（checklist 6(c)：身份透明）
        self._write_member_identity(member)

        # 初始化成员私人空间 .self（identity/rule/memory/activity），确保成员
        # 工具循环立即可读自己的身份与记忆，无需自行猜测路径（双轨制统一：
        # 本地模式经 WorkspaceIO 落到 baseDir/agentspace/{member_id}/.self）
        self._init_member_private_space(member)

        # 记录到成员管理表（视图）+ team_members 表（权威名单，含直属 leader）。
        # 注：此前 create_member 只写内存 + roster 视图，不落 team_members 表，
        # 重启后成员即消失（_load_from_team_store 读不到）——此处必须经
        # team_store.add_member 持久化（parent_agent_id 记录直属 leader）。
        self._save_roster()
        try:
            from data.team_store import add_member

            add_member(
                user_id=self.user_id,
                team_id=self.team_id or self.agent_id,
                member_id=member_id,
                name=member.get("name", ""),
                role=member.get("role", ""),
                duty=member.get("duty", ""),
                model_id=member.get("model_id", ""),
                level=member.get("level", 1),
                system_prompt=member.get("system_prompt", ""),
                parent_agent_id=member.get("parent_agent_id", ""),
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("持久化新成员到 team_store 失败 %s: %s", member_id, exc)

        # 创建后向新成员投递初始化消息（携带其 system_prompt）：
        # 成员首次会话据此构建系统提示词快照并回复确认，用户/leader 即可
        # 立即指派任务。投递失败不阻塞创建（成员已落库，可稍后 send_message）。
        initialized = self._dispatch_member_init(member)

        return {
            "member_id": member_id,
            "name": member_name,
            "model_id": model_id,
            "level": member["level"],
            "workspace_id": member["workspace_id"],
            "created_at": now,
            "initialized": initialized,
            "hint": "" if initialized else (
                "成员已创建但初始化消息投递失败（broker 未就绪），"
                "可稍后用 send_message 通知该成员"
            ),
        }

    def _dispatch_member_init(self, member: Dict[str, Any]) -> bool:
        """向新创建/加入的成员投递初始化消息（含其 system prompt）。

        内容明确告知成员身份、直属 leader 与职责（system prompt），触发其
        首次会话构建（``_process_member_message`` 以 payload.system_prompt
        注入系统提示词快照）并回复确认。

        :return: 是否已入队
        """
        sp = (member.get("system_prompt") or "").strip()
        content = (
            "【团队初始化】你已加入团队（直属 leader: "
            f"{member.get('leader_name') or self._leader_name()}）。\n"
        )
        if sp:
            content += f"你的角色与职责（system prompt）如下，请阅读并确认理解：\n{sp}\n"
        else:
            content += "目前未设置独立分工，请先向 leader 确认你的角色与职责。\n"
        content += "确认后等待 leader 派发任务。"
        return self._dispatch_to_member(member, content)

    def _init_member_private_space(self, member: Dict[str, Any]) -> None:
        """初始化成员私人空间 .self（rule.md / memory.md / activity.log）。

        identity.md 由 _write_member_identity 负责；此处补齐其余文件，
        全部走统一 WorkspaceIO（本地模式成员工具立即可见，云端容器同路径）。
        """
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
                f"动手前先定位根因再做最小修改；完成后更新 .self/memory.md 并向 leader 汇报。\n"
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
    # SubTask 7.2: 成员管理表
    # ------------------------------------------------------------------
    def _save_roster(self) -> None:
        """将成员名单写入工作空间 ``.self/team_roster.md``（生成视图）。

        名单的权威来源是 ``team_members`` 表（P4 建队登记）；此处根据
        ``self.members`` 渲染 13 列视图（ID|名称|模型|层级|创建时间|工作状态|
        评价|角色|职责|质量|效率|协作性|准确性），供 LLM 与统一投递解析。
        """
        if not self.workspace_id:
            return

        from data.team_store import render_roster_md

        content = render_roster_md(self.members)

        # 优先走统一 WorkspaceIO（本地模式 .self 本地可见，解决 roster 双轨问题）
        if self._io_write(self.workspace_id, ROSTER_FILE_PATH, content):
            return
        # 回退 docker exec（云端容器）
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

    def _load_roster(self) -> None:
        """加载成员列表。

        优先从 ``team_members`` 表（P4 团队初始化后的权威名单）读取；
        该表缺失（未建队/旧数据）时回退到工作空间 ``.self/team_roster.md``，
        并兼容旧 11 列格式与当前 13 列格式。
        """
        # 权威来源：team_store（teams/team_members 表）
        members = self._load_from_team_store()
        if members:
            self.members = members
            return

        # 回退：工作空间 roster 文件（未走 P4 建队的历史数据）
        if not self.workspace_id:
            return
        stdout = self._io_read(self.workspace_id, ROSTER_FILE_PATH)
        if stdout is None:
            cmd = ["sh", "-c", f"cat {ROSTER_FILE_PATH} 2>/dev/null"]
            try:
                result = self.docker_manager.exec_in_workspace(self.workspace_id, cmd)
            except Exception as exc:  # noqa: BLE001
                logger.warning("读取成员管理表失败: %s", exc)
                return
            if result.get("exit_code") != 0:
                return
            stdout = result.get("stdout", "") or ""
        loaded = self._parse_roster_md(stdout)
        if loaded:
            self.members = loaded

    def _load_from_team_store(self) -> List[Dict[str, Any]]:
        """从 ``team_members`` 表读取所属 TOP 的成员名单。

        member_id 同时作为 workspace_id（create_workspace 约定）。返回空列表
        表示尚未建队或本 TOP 无成员。
        """
        from data.team_store import get_members

        top_id = self.team_id or self.agent_id
        if not top_id:
            return []
        try:
            rows = get_members(top_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("从 team_store 读取成员失败: %s", exc)
            return []
        result: List[Dict[str, Any]] = []
        for r in rows:
            parent_id = r.get("parent_agent_id", "") or top_id
            leader_name = "self"
            if parent_id and parent_id != self.agent_id:
                parent_rec = self._lookup_agent_by_id(parent_id)
                if parent_rec is not None:
                    leader_name = parent_rec.get("name") or parent_id
            result.append({
                "id": r.get("id", ""),
                "name": r.get("name", ""),
                "role": r.get("role", ""),
                "duty": r.get("duty", ""),
                "model_id": r.get("model_id", ""),
                "model_name": r.get("model_id", ""),
                "level": int(r.get("level", 1) or 1),
                "workspace_id": r.get("id", ""),
                "container_id": "",
                "parent_workspace_id": self.workspace_id,
                "parent_agent_id": parent_id,
                "team_id": top_id,
                "leader_name": leader_name,
                "created_at": _fmt_ts(r.get("created_at")),
                "work_status": r.get("work_status", "idle"),
                "current_task": "",
                "can_lead_team": True,
                "scores": r.get("scores") or {},
                "comment": r.get("comment", ""),
                "system_prompt": r.get("system_prompt", ""),
                "task_ids": [],
                "message_history": [],
            })
        return result

    def _parse_roster_md(self, content: str) -> List[Dict[str, Any]]:
        """解析成员管理表 markdown 表格，返回成员字典列表。

        兼容两种列布局：
        - 新 13 列（P4 生成视图）：ID|名称|模型|层级|创建时间|工作状态|评价|
          角色|职责|质量|效率|协作性|准确性
        - 旧 11 列（历史数据）：无 角色/职责 列，评分紧随评价之后
        """
        members: List[Dict[str, Any]] = []
        for raw_line in content.splitlines():
            line = raw_line.strip()
            if not line.startswith("|"):
                continue
            # 跳过表头行
            if "ID" in line and "名称" in line:
                continue
            # 跳过分隔行
            if "---" in line.replace("|", ""):
                continue
            parts = [p.strip() for p in line.strip("|").split("|")]
            if len(parts) < 11:
                continue
            try:
                level_str = parts[3]
                level = int(level_str) if level_str.isdigit() else 0
            except (ValueError, IndexError):
                level = 0
            member_id = parts[0]
            if not member_id:
                continue
            # 新 13 列：角色=7、职责=8、评分 9-12；旧 11 列：评分 7-10
            new_format = len(parts) >= 13
            role = parts[7] if new_format else ""
            duty = parts[8] if new_format else ""
            if new_format:
                q, e, c, a = parts[9], parts[10], parts[11], parts[12]
            else:
                q, e, c, a = parts[7], parts[8], parts[9], parts[10]
            members.append(
                {
                    "id": member_id,
                    "name": parts[1],
                    "role": role,
                    "duty": duty,
                    "model_id": parts[2],
                    "model_name": parts[2],
                    "level": level,
                    # member_id 同时作为 workspace_id（create_workspace 的约定）
                    "workspace_id": member_id,
                    "container_id": "",
                    "parent_workspace_id": self.workspace_id,
                    # 旧 roster 文件无直属 leader 列：历史语义为「本 agent 的
                    # 成员视图」，视为直属（与 team_store 回退约定一致）
                    "parent_agent_id": self.agent_id,
                    "leader_name": self._leader_name(),
                    "created_at": parts[4],
                    "work_status": parts[5] or "idle",
                    "current_task": "",
                    "can_lead_team": True,
                    "scores": {
                        "quality": _to_score(q),
                        "efficiency": _to_score(e),
                        "collaboration": _to_score(c),
                        "accuracy": _to_score(a),
                    },
                    "comment": parts[6],
                    "task_ids": [],
                    "message_history": [],
                }
            )
        return members

    # ------------------------------------------------------------------
    # SubTask 7.2: 成员工作状态（状态治理：以 _active_tasks 为准，不写持久化）
    # ------------------------------------------------------------------
    def mark_member_idle(self, member_id: str) -> None:
        """（已废弃）成员工作状态复位占位。

        【状态治理】成员是否在工作由 ``chat._active_tasks``（实际 tool loop
        登记）唯一决定：``_process_member_message`` 开始前登记、结束时清除
        并推送 ``agent_status=idle``，前端/API 据此展示。此处不再写内存态 /
        roster / team_members 表，保留函数仅为兼容历史调用方。

        :param member_id: 成员 ID
        """
        return

    # ------------------------------------------------------------------
    # SubTask 7.3: 多维评分机制
    # ------------------------------------------------------------------
    def update_member_score(
        self, member_id: str, scores: dict, comment: str = ""
    ) -> dict:
        """更新成员多维评分与评价。

        :param member_id: 成员 ID
        :param scores: 评分字典，包含 quality/efficiency/collaboration/accuracy（0-10）
        :param comment: 简短评价（由父 agent 提供），也可通过 scores["comment"] 传入
        """
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}

        for key in SCORE_FIELDS:
            if key in scores:
                member["scores"][key] = _to_score(scores[key])

        # 评价：优先使用显式 comment 参数，其次从 scores 字典读取
        final_comment = comment or scores.get("comment", "")
        if final_comment:
            member["comment"] = final_comment

        # 更新成员管理表（视图）+ 同步 team_members 表（权威名单）
        self._save_roster()
        self._sync_member_to_team_store(
            member_id, scores=member["scores"], comment=member["comment"]
        )
        return {
            "member_id": member_id,
            "scores": member["scores"],
            "comment": member["comment"],
        }

    # ------------------------------------------------------------------
    # SubTask 7.4: 成员查询
    # ------------------------------------------------------------------
    def _action_list_members(self, arguments: dict) -> dict:
        """列出与本 agent 有关系的所有 agent，按分组返回。

        分组：
        - ``team_leader``：当前 agent 的上级 leader（成员视角；顶部 agent 无 leader）
        - ``teammates``：当前 agent 创建的**直属成员**（下属，parent_agent_id
          等于当前 agent；P4 全量建队的成员直属 TOP）
        - ``team_member``：当前 agent 所属团队中的其他成员（同顶部 agent 旗下、
          非直属的其他层级成员）

        筛选参数（model_id / level / work_status）仅作用于 ``teammates`` 分组。
        """
        result = list(self.members)

        model_id = arguments.get("model_id")
        if model_id:
            result = [m for m in result if m.get("model_id") == model_id]

        level = arguments.get("level")
        if level is not None:
            try:
                lv = int(level)
                result = [m for m in result if m.get("level") == lv]
            except (TypeError, ValueError):
                pass

        work_status = arguments.get("work_status")
        if work_status:
            result = [
                m for m in result
                if self._live_work_status(m.get("id", "")) == work_status
            ]

        # 分组：直属（parent == 当前 agent）与同 TOP 非直属（平级/其他层级）
        own_id = self.agent_id or ""
        direct = [
            m for m in result
            if (m.get("parent_agent_id") or "") == own_id
        ]
        team_member = [
            m for m in result
            if (m.get("parent_agent_id") or "") != own_id
        ]

        # team_leader：自己的上级 leader
        team_leader: List[Dict[str, Any]] = []
        if self.leader_id:
            leader_agent = self._lookup_agent_by_id(self.leader_id)
            if leader_agent is not None:
                team_leader.append({
                    "id": leader_agent.get("id") or self.leader_id,
                    "name": leader_agent.get("name", ""),
                    "model_id": leader_agent.get("model_id", ""),
                    "level": 0,
                    "workspace_id": leader_agent.get("workspace_id") or self.leader_id,
                    "relation": "team_leader",
                })
            else:
                team_leader.append({
                    "id": self.leader_id,
                    "name": self.leader_id,
                    "model_id": "",
                    "level": 0,
                    "workspace_id": self.leader_id,
                    "relation": "team_leader",
                })

        # 基本信息完整性提示：role/duty 为空时提醒先 update_member 补充
        # （避免成员职责不明导致任务执行偏差，spec「基本信息先查」）。
        # model_id 为空**不**警告——存在自动回退机制（投递时回退所属 TOP
        # 模型），无需强制设置，避免对 agent 的持续骚扰。
        missing = [
            (m.get("name") or m.get("id"))
            for m in direct
            if not (m.get("role") and m.get("duty"))
        ]
        hint = ""
        if missing:
            hint = (
                "以下成员 role/duty 为空，建议用 update_member 补充完善后"
                "再派发任务（model_id 为空会自动回退所属 TOP 模型，无需设置）: "
                + "、".join(missing[:5])
            )
            if len(missing) > 5:
                hint += f" 等 {len(missing)} 名"

        # 【状态治理】返回前把 members 的 work_status 覆盖为**实际执行态**
        # （基于 _active_tasks），而非表/roster 中的快照（可能过时或假状态）。
        live_result = [dict(m) for m in direct]
        for m in live_result:
            m["work_status"] = self._live_work_status(m.get("id", ""))

        return {
            "groups": {
                "team_leader": team_leader,
                "teammates": live_result,
                "team_member": team_member,
            },
            "members": live_result,
            "total": len(team_leader) + len(live_result) + len(team_member),
            "hint": hint,
        }

    def _action_query_member(self, arguments: dict) -> dict:
        """按 member_id 查询单个成员详情。"""
        member_id = arguments.get("target_member_id") or arguments.get("member_id")
        if not member_id:
            return {"error": "缺少 target_member_id"}
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}
        return {"member": member}

    # 合法工作状态
    VALID_WORK_STATUS = ("idle", "working", "waiting_input", "stopped", "error")

    def _action_update_member(self, arguments: dict) -> dict:
        """编辑成员信息（name/model_id/can_lead_team/comment/scores/system_prompt）。

        仅更新显式提供的字段，其余保持不变；更新后持久化到成员管理表。
        **信息保留**：任何字段（含 name / system_prompt）的修改都只更新成员
        信息，**不重建工作区、不清空上下文**——成员的记忆与进行中任务不受
        影响；新的 system_prompt 在成员下次上下文重建（compact）时生效。

        【状态治理】工作状态（work_status）不可由 update_member 设置——成员
        是否在工作的唯一权威是 ``chat._active_tasks``（实际 tool loop 登记），
        由执行层登记/清除并经 WS ``agent_status`` 事件推送。需要停止成员请
        使用前端「停止」按钮（取消任务 + 清空队列），而非修改状态字段。
        """
        member_id = arguments.get("target_member_id") or arguments.get("member_id")
        if not member_id:
            return {"error": "缺少 target_member_id"}
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}

        # 状态字段只读：work_status 由 _active_tasks 实际执行态决定，拒绝写入
        if arguments.get("work_status") is not None:
            return {
                "error": "work_status 为只读字段（由实际执行状态决定），"
                "请勿通过 update_member 设置；如需停止成员请使用前端「停止」按钮",
            }

        updated: List[str] = []

        # 更新名称（角色）
        name = arguments.get("name")
        if name is not None:
            stripped = str(name).strip()
            if not stripped:
                return {"error": "成员名称不能为空"}
            member["name"] = stripped
            updated.append("name")

        # 更新成员独立提示词（角色/职责说明）。
        # 信息保留：只更新字段，不重建工作区、不清空上下文（新提示词在
        # 成员下次 compact 时经 system_prompt_rebuilder 现读生效）
        system_prompt = arguments.get("system_prompt")
        if system_prompt is not None:
            member["system_prompt"] = str(system_prompt)
            updated.append("system_prompt")

        # 更新模型（校验模型必须存在于模型池；按 checklist 12(a) 不重建工作区）
        model_id = arguments.get("model_id")
        if model_id is not None:
            if model_id not in self.model_configs:
                return {"error": f"模型不存在: {model_id}"}
            member["model_id"] = model_id
            member["model_name"] = self.model_configs[model_id].name
            updated.append("model")

        # 更新是否可创建子团队
        can_lead_team = arguments.get("can_lead_team")
        if can_lead_team is not None:
            member["can_lead_team"] = bool(can_lead_team)
            updated.append("can_lead_team")

        # 更新评价（checklist 12(a)：无重建）
        comment = arguments.get("comment")
        if comment is not None:
            member["comment"] = str(comment)
            updated.append("comment")

        # 更新多维评分（0-10）
        scores = arguments.get("scores")
        if isinstance(scores, dict):
            for key in SCORE_FIELDS:
                if key in scores:
                    member["scores"][key] = _to_score(scores[key])
            updated.append("scores")

        if not updated:
            return {"error": "未提供任何可更新的字段"}

        # 持久化到成员管理表（视图）+ 同步 team_members 表（权威名单）。
        # work_status 为只读（实际执行态），不同步写表。
        self._save_roster()
        self._sync_member_to_team_store(member_id,
                                        name=member.get("name"),
                                        role=member.get("role"),
                                        duty=member.get("duty"),
                                        model_id=member.get("model_id"),
                                        level=member.get("level"),
                                        comment=member.get("comment"),
                                        system_prompt=member.get("system_prompt"),
                                        scores=member.get("scores"))

        # 名单变更推送：TOP 修改成员信息后，向本 TOP 下所有 agent 推送更新后的
        # 名单（触发其 context 重构、注入最新成员拓扑）（spec「名单变更推送」）
        pushed = self._push_roster_update()

        return {
            "member_id": member_id,
            "updated": updated,
            "member": member,
            "roster_pushed": pushed,
        }

    def _sync_member_to_team_store(
        self, member_id: str, **fields: Any
    ) -> None:
        """把内存中的成员字段变更同步到 ``team_members`` 表（权威名单）。"""
        from data.team_store import get_members, update_member

        top_id = self.team_id or self.agent_id
        if not top_id:
            return
        patch = {k: v for k, v in fields.items() if v is not None}
        try:
            current = next(
                (m for m in get_members(top_id) if m.get("id") == member_id), None
            )
            if current is None:
                return
            # 仅同步实际发生变化的字段，避免覆盖 team_store 中未变动的值
            clean: Dict[str, Any] = {}
            for k, v in patch.items():
                if k == "scores":
                    continue  # scores 单独合并
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
        """名单变更推送：向本 TOP 下所有 agent 推送更新后的成员名单。

        复用消息投递（broker / message_dispatcher）触发各 agent 的 context
        重构；每次 compact 时 system prompt 重建回调会现读 ``team_store``
        注入最新成员拓扑（spec「成员拓扑常驻」）。

        :return: 成功推送的 agent 数
        """
        from data.team_store import get_members

        top_id = self.team_id or self.agent_id
        if not top_id:
            return 0
        members = []
        try:
            members = get_members(top_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("名单推送读取成员失败: %s", exc)
            return 0
        if not members:
            return 0
        roster_md = ""
        try:
            from data.team_store import render_roster_md

            roster_md = render_roster_md(members)
        except Exception as exc:  # noqa: BLE001
            logger.warning("名单推送渲染 roster 失败: %s", exc)
            return 0
        # 通知各成员：下发 roster 更新事件（内容为最新名单视图），触发重构
        return self._dispatch_roster_event(top_id, roster_md, members)

    def _dispatch_roster_event(
        self, top_id: str, roster_md: str,
        members: Optional[List[Dict[str, Any]]] = None,
    ) -> int:
        """向 TOP 下全部成员广播 roster 更新事件（经 broker 投递弱事件消息）。

        成员列表按 team_store 权威名单全量投递（跨层级），而非仅当前 agent
        的直属成员——名单变更影响整个 TOP 的拓扑认知。
        """
        if members is None:
            try:
                from data.team_store import get_members

                members = get_members(top_id) or []
            except Exception as exc:  # noqa: BLE001
                logger.warning("名单推送读取全量成员失败: %s", exc)
                return 0
        pushed = 0
        for m in (members or []):
            _id = m.get("id", "")
            if not _id:
                continue
            payload = {
                "user_id": self.user_id or "system",
                "agent_id": _id,
                "workspace_id": m.get("workspace_id") or _id,
                "model_id": m.get("model_id", ""),
                "system_prompt": m.get("system_prompt", ""),
                "leader_id": self.agent_id or top_id,
                "team_id": top_id,
                "content": ("【团队名单已更新】\n"
                            "请刷新你的成员拓扑认知，以最新名单为准：\n"
                            + roster_md),
                "event": "roster_update",
                # 透传当前会话：成员上下文按 session 隔离
                "session_id": self.session_id,
            }
            try:
                if self.broker is not None:
                    if self.broker.dispatch((self.user_id or "system", _id), payload):
                        pushed += 1
            except Exception as exc:  # noqa: BLE001
                logger.warning("名单推送投掷失败 %s: %s", _id, exc)
        return pushed

    # ------------------------------------------------------------------
    # SubTask 7.5: 工作状态查询
    # ------------------------------------------------------------------
    def _live_work_status(self, member_id: str) -> str:
        """返回成员**实际**工作状态（是否处于 tool loop）。

        【状态治理】唯一权威是 ``chat._active_tasks``（真实运行中的任务登记），
        不读表/roster/内存态的 work_status（那可能是过时或被错误设置的快照）。
        """
        if not self.user_id or not member_id:
            return "idle"
        try:
            from agent.chat import _is_agent_working

            return "working" if _is_agent_working(self.user_id, member_id) else "idle"
        except Exception:  # noqa: BLE001
            return "idle"

    def _action_query_status(self, arguments: dict) -> dict:
        """查询成员工作状态、当前任务与最后一次 Git 提交。

        工作状态返回**实际执行态**（基于 ``_active_tasks``），非表/roster 快照。
        """
        member_id = arguments.get("target_member_id")
        if not member_id:
            return {"error": "缺少 target_member_id"}
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}

        # 获取最后一次 Git 提交信息（通过 docker_manager.git_log）
        last_commit = ""
        ws_id = member.get("workspace_id")
        if ws_id:
            try:
                log_result = self.docker_manager.git_log(ws_id, limit=1)
                commits = log_result.get("commits", [])
                if commits:
                    last_commit = commits[0]
            except Exception as exc:  # noqa: BLE001
                logger.warning("获取成员 Git 提交失败: %s", exc)

        return {
            "member_id": member_id,
            "work_status": self._live_work_status(member_id),
            "current_task": member.get("current_task", ""),
            "last_commit": last_commit,
        }

    def _list_workspace_files(
        self, workspace_id: str
    ) -> List[Dict[str, Any]]:
        """列出成员工作空间根目录的产出文件（跳过 .git/.self 等内部目录）。"""
        try:
            result = self.docker_manager.exec_in_workspace(
                workspace_id,
                ["sh", "-c", "ls -la --time-style=long-iso . 2>&1"],
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("列出成员工作空间文件失败: %s", exc)
            return []
        if result.get("exit_code", 0) != 0:
            return []

        files: List[Dict[str, Any]] = []
        for line in result.get("stdout", "").splitlines():
            line = line.strip()
            if not line or line.startswith("total "):
                continue
            parts = line.split()
            if len(parts) < 8:
                continue
            name = " ".join(parts[7:])
            if name in (".", "..", ".git", ".self"):
                continue
            perms = parts[0]
            size = int(parts[4]) if parts[4].isdigit() else 0
            modified = f"{parts[5]} {parts[6]}"
            file_type = "dir" if perms.startswith("d") else "file"
            files.append(
                {
                    "name": name,
                    "size": size,
                    "type": file_type,
                    "modified": modified,
                }
            )
        return files

    def _action_view_member_output(self, arguments: dict) -> dict:
        """查看成员工作产出，供 leader 判断工作进度。

        返回成员当前状态、最近 Git 提交历史与工作空间产出文件列表。
        """
        member_id = arguments.get("target_member_id") or arguments.get("member_id")
        if not member_id:
            return {"error": "缺少 target_member_id"}
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}

        ws_id = member.get("workspace_id")
        if not ws_id:
            return {"error": "成员无工作空间"}

        # 最近提交历史
        try:
            limit = max(1, min(int(arguments.get("limit") or 10), 100))
        except (TypeError, ValueError):
            limit = 10
        commits: List[str] = []
        try:
            log_result = self.docker_manager.git_log(ws_id, limit=limit)
            commits = log_result.get("commits", [])
        except Exception as exc:  # noqa: BLE001
            logger.warning("获取成员提交历史失败: %s", exc)

        # 产出文件列表
        files = self._list_workspace_files(ws_id)

        return {
            "member_id": member_id,
            "name": member.get("name", ""),
            "work_status": self._live_work_status(member_id),
            "current_task": member.get("current_task", ""),
            "commits": commits,
            "files": files,
        }

    def _action_view_member_log(self, arguments: dict) -> dict:
        """查看成员活动日志（文字输出），供 leader 判断成员是否卡死。

        读取成员工作空间 ``.self/activity.log`` 最后 N 行。日志带时间戳，
        若最后一条距离当前时间过久且无 [done]，可判断成员可能卡死。
        """
        member_id = arguments.get("target_member_id") or arguments.get("member_id")
        if not member_id:
            return {"error": "缺少 target_member_id"}
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}

        ws_id = member.get("workspace_id")
        if not ws_id:
            return {"error": "成员无工作空间"}

        try:
            lines = max(1, min(int(arguments.get("lines") or 30), 500))
        except (TypeError, ValueError):
            lines = 30

        log_lines: List[str] = []
        try:
            result = self.docker_manager.exec_in_workspace(
                ws_id,
                ["sh", "-c", f"tail -n {lines} .self/activity.log 2>/dev/null"],
            )
            if result.get("exit_code", 0) == 0:
                log_lines = [
                    line for line in result.get("stdout", "").splitlines()
                ]
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取成员活动日志失败: %s", exc)

        return {
            "member_id": member_id,
            "name": member.get("name", ""),
            "work_status": self._live_work_status(member_id),
            "log_lines": log_lines,
            "total": len(log_lines),
        }

    # ------------------------------------------------------------------
    # SubTask 8.1: 点对点消息发送
    # ------------------------------------------------------------------
    def _action_send_message(self, arguments: dict) -> dict:
        """发送消息：目标支持单个 ID/名称或列表（一对多），收敛到统一消息 API。

        可发送给：直属成员（teammates，按 id 或 name）、上级 leader（team_leader）、
        本顶部 agent 旗下其他有关系的 agent（team_member），以及同用户名下的其他
        TOP agent（跨 Top 顶层寻址，按 TOP name/id）。成员按 name 基于拓扑解析。
        """
        target_raw = arguments.get("target_member_id") or arguments.get("target_ids")
        message = arguments.get("message", "")
        if not target_raw:
            return {"error": "缺少 target_member_id"}
        if not message:
            return {"error": "缺少 message"}

        # 支持字符串或列表（一对多）
        if isinstance(target_raw, str):
            target_raw_list = [target_raw]
        elif isinstance(target_raw, list):
            target_raw_list = [t for t in target_raw if isinstance(t, str) and t]
        else:
            return {"error": "target_member_id 必须是字符串或字符串列表"}
        if not target_raw_list:
            return {"error": "目标 ID 列表为空"}

        # name → id 解析（top 内成员按 name / 跨 Top 顶层按 TOP name）
        resolved_ids: List[str] = []
        unknown: List[str] = []
        for t in target_raw_list:
            r = self._resolve_target(t)
            if r["type"] in ("member", "top") and r["id"]:
                resolved_ids.append(r["id"])
            else:
                unknown.append(t)
        if not resolved_ids:
            return {
                "error": "目标不存在或不可达",
                "unknown": unknown,
                "hint": "top 内按成员 name 寻址；跨 Top 按 TOP agent name 寻址"
                "（先 list_teams 熟悉本用户名下 TOP）",
            }

        now = self._now()
        msg = {
            "id": self._generate_message_id(),
            "from": "self",
            "to": ",".join(resolved_ids),
            "type": "direct",
            "content": message,
            "timestamp": now,
        }
        self.messages.append(msg)
        # 在已知直属成员的消息历史中记录
        for tid in resolved_ids:
            member = self._find_member(tid)
            if member is not None:
                member.setdefault("message_history", []).append(msg)

        rejected: List[str] = list(unknown)
        # 收敛出口：统一消息 API（无 dispatcher 时退回 broker 直投）
        if self.message_dispatcher is not None:
            result = self.message_dispatcher(
                self.user_id,
                resolved_ids,
                message,
                source_agent_id=self.agent_id,
                team_id=self.team_id,
                system_prompt="",
                # 透传当前会话：成员上下文/历史按 session 隔离
                extra={"session_id": self.session_id},
            )
            dispatched = result.get("status") in ("sent", "partial")
            rejected += result.get("rejected", []) or []
        else:
            dispatched = False
            for tid in resolved_ids:
                member = self._find_member(tid)
                if member is not None:
                    if self._dispatch_to_member(member, message):
                        dispatched = True
                elif tid == self.leader_id:
                    leader_agent = self._lookup_agent_by_id(tid)
                    target = {
                        "id": tid,
                        "workspace_id": (leader_agent or {}).get("workspace_id") or tid,
                        "model_id": (leader_agent or {}).get("model_id") or "",
                        "system_prompt": "",
                    }
                    if self._dispatch_to_member(target, message):
                        dispatched = True
                else:
                    rejected.append(tid)

        return {
            "status": "sent" if dispatched else "error",
            "message_id": msg["id"],
            "to": resolved_ids,
            "dispatched": dispatched,
            "rejected": rejected,
        }

    # ------------------------------------------------------------------
    # SubTask 8.2: 广播消息
    # ------------------------------------------------------------------
    def _action_broadcast(self, arguments: dict) -> dict:
        """向所有直属成员发送广播消息（经统一消息 API 逐成员投递）。"""
        message = arguments.get("message", "")
        if not message:
            return {"error": "缺少 message"}

        now = self._now()
        msg = {
            "id": self._generate_message_id(),
            "from": "self",
            "to": "all",
            "type": "broadcast",
            "content": message,
            "timestamp": now,
        }
        self.messages.append(msg)
        # 仅投递给直属成员（parent_agent_id == 当前 agent；广播不跨层级）
        direct = [
            m for m in self.members
            if (m.get("parent_agent_id") or "") == self.agent_id
        ]
        member_ids = [m.get("id", "") for m in direct if m.get("id")]
        for m in direct:
            m.setdefault("message_history", []).append(msg)

        rejected: List[str] = []
        if self.message_dispatcher is not None:
            result = self.message_dispatcher(
                self.user_id,
                member_ids,
                message,
                source_agent_id=self.agent_id,
                team_id=self.team_id,
                # 透传当前会话：成员上下文/历史按 session 隔离
                extra={"session_id": self.session_id},
            )
            rejected = result.get("rejected", []) or []
        else:
            for m in direct:
                if not self._dispatch_to_member(m, message):
                    rejected.append(m.get("id", ""))

        return {
            "status": "broadcast",
            "message_id": msg["id"],
            "recipients": len(direct),
            "rejected": rejected,
        }

    # ------------------------------------------------------------------
    # SubTask 8.3: 文件发送
    # ------------------------------------------------------------------
    def _action_send_file(self, arguments: dict) -> dict:
        """文件发送已取消：team leader 与 teammates 共享工作目录 base。"""
        return {
            "status": "cancelled",
            "error": "文件发送功能已取消：team leader 与 teammates 共享工作目录，"
                     "文件直接写入双方可见的工作空间即可。",
        }
        # ---- 以下旧实现已废弃（保留引用，避免误删其它逻辑） ----
        target_id = arguments.get("target_member_id")
        file_path = arguments.get("file_path", "")
        if not target_id:
            return {"error": "缺少 target_member_id"}
        if not file_path:
            return {"error": "缺少 file_path"}

        target = self._find_member(target_id)
        if target is None:
            # 支持向 leader 发送文件（leader 不在队友的 roster 中）
            if target_id == self.leader_id:
                target = {
                    "id": self.leader_id,
                    "workspace_id": self.leader_id,
                    "model_id": "",
                    "system_prompt": "",
                }
            else:
                return {"error": f"目标成员不存在: {target_id}"}

        src_ws = self.workspace_id
        target_ws = target.get("workspace_id")
        if not src_ws:
            return {"error": "发送者无工作空间"}
        if not target_ws:
            return {"error": "目标成员无工作空间"}

        # 校验文件路径，防止路径穿越与命令注入
        safe_path = self._sanitize_file_path(file_path)
        if safe_path is None:
            return {"error": "非法文件路径"}

        # 通过 docker_manager.exec_in_workspace 执行文件复制：
        # 在源容器读取文件并 base64 编码（二进制安全），在目标容器解码写入
        read_result = self.docker_manager.exec_in_workspace(
            src_ws, ["sh", "-c", f"base64 {safe_path}"]
        )
        if read_result.get("exit_code") != 0:
            return {
                "error": "读取源文件失败",
                "detail": read_result.get("stdout", ""),
            }
        b64_content = read_result.get("stdout", "").strip()
        if not b64_content:
            return {"error": "源文件为空或不存在"}

        # 写入目标容器（base64 字符集不含单引号，可安全用于 echo '...'）
        dst_dir = os.path.dirname(safe_path) or "."
        write_cmd = [
            "sh",
            "-c",
            f"mkdir -p {dst_dir} && echo '{b64_content}' | base64 -d > {safe_path}",
        ]
        write_result = self.docker_manager.exec_in_workspace(target_ws, write_cmd)
        if write_result.get("exit_code") != 0:
            return {
                "error": "写入目标文件失败",
                "detail": write_result.get("stdout", ""),
            }

        # 接收者收到文件路径通知
        now = self._now()
        notice = {
            "id": self._generate_message_id(),
            "from": "self",
            "to": target_id,
            "type": "file",
            "content": f"[文件] {safe_path}",
            "file_path": safe_path,
            "timestamp": now,
        }
        self.messages.append(notice)
        target.setdefault("message_history", []).append(notice)

        return {"status": "sent", "file_path": safe_path, "to": target_id}

    # ------------------------------------------------------------------
    # SubTask 9.1: 任务分配
    # ------------------------------------------------------------------
    def _action_assign_task(self, arguments: dict) -> dict:
        """分配任务：创建任务对象并加入成员任务队列，更新成员工作状态为工作中。

        目标按成员 id 或 name 寻址（top 内，基于拓扑）。
        """
        target_id = arguments.get("target_member_id") or arguments.get("member_name")
        description = arguments.get("task_description", "")
        priority = arguments.get("task_priority", "normal")
        expected_output = arguments.get("task_output", "")

        if not target_id:
            return {"error": "缺少 target_member_id"}
        if not description:
            return {"error": "缺少 task_description"}

        member = self._find_member(target_id)
        if member is None:
            return {
                "error": f"目标成员不存在: {target_id}",
                "hint": "top 内按成员 name 或 id 寻址；成员职责未设时先 update_member 设置",
            }

        task_id = self._generate_task_id()
        now = self._now()
        task = {
            "id": task_id,
            "description": description,
            "priority": priority,
            "expected_output": expected_output,
            "assignee": target_id,
            "status": "pending",  # pending / in_progress / completed / failed
            "git_commit_hash": "",
            "summary": "",
            "created_at": now,
            "completed_at": "",
        }
        self.tasks.append(task)
        member.setdefault("task_ids", []).append(task_id)
        # 【状态治理】不写成员 work_status（工作状态由 _active_tasks 实际
        # tool loop 决定，投递后成员 worker 处理消息时自动登记 working、
        # 结束后自动清除并推送 idle）。任务对象继续跟踪任务状态。
        # 投递给成员，触发其异步串行处理任务
        dispatched = self._dispatch_to_member(member, description)

        return {
            "task_id": task_id,
            "assignee": target_id,
            "status": "pending",
            "dispatched": dispatched,
        }

    # ------------------------------------------------------------------
    # SubTask 9.2: 任务完成流程
    # ------------------------------------------------------------------
    def complete_task(
        self, task_id: str, git_commit_hash: str, summary: str
    ) -> dict:
        """成员通过 Git 提交工作成果后完成任务。

        - 记录 Git 提交哈希与总结
        - 更新任务状态为已完成
        - 通知父 agent（父 agent 可随后调用 update_member_score 评分）

        【状态治理】不再修改成员 work_status——成员工作状态由
        ``chat._active_tasks`` 实际 tool loop 决定（消息处理结束自动清除并
        推送 idle），不依赖成员显式调用 complete_task。

        :param task_id: 任务 ID
        :param git_commit_hash: 工作成果的 Git 提交哈希
        :param summary: 工作总结
        """
        task = None
        for t in self.tasks:
            if t.get("id") == task_id:
                task = t
                break
        if task is None:
            return {"error": f"任务不存在: {task_id}"}

        task["git_commit_hash"] = git_commit_hash
        task["summary"] = summary
        task["status"] = "completed"
        task["completed_at"] = self._now()

        # 更新成员管理表（父 agent 评分通过 update_member_score 单独触发）
        self._save_roster()
        return {"task_id": task_id, "status": "completed"}

    # ------------------------------------------------------------------
    # SubTask 14.5: 任务完成汇报与上下文隔离
    # ------------------------------------------------------------------
    def report_task_completion(
        self,
        task_id: str,
        tool_calls: list,
        git_commit: dict,
        result: str,
    ) -> dict:
        """子 agent 完成任务时汇报工作成果，并生成上下文隔离摘要注入父 agent 上下文。

        流程：
        1. 调用 ``complete_task`` 更新任务状态（保留原有任务完成流程）
        2. 调用 ``ContextIsolator.create_work_summary()`` 生成工作成果摘要
           （不含逐条 tool_call 执行记录）
        3. 通过 ``build_parent_context_entry()`` 构建父 agent 上下文条目
        4. 将摘要条目注入父 agent 的 ``session.context``，替代完整工作日志

        父 agent 上下文只接收摘要，不接收子 agent 的完整工作日志。

        :param task_id: 任务 ID
        :param tool_calls: 子 agent 执行的工具调用列表（每项含 name 字段）
        :param git_commit: Git 提交信息 dict（含 hash/message 键）
        :param result: 工作结果文本
        :return: 包含 task_id / status / summary / context_injected 的字典
        """
        # 查找任务，获取任务描述与负责人 ID（供摘要使用）
        task = None
        for t in self.tasks:
            if t.get("id") == task_id:
                task = t
                break
        if task is None:
            return {"error": f"任务不存在: {task_id}"}

        task_description = task.get("description", "")
        assignee = task.get("assignee", "")

        # 从 git_commit 提取 commit hash（供 complete_task 使用）
        git_commit_hash = ""
        if isinstance(git_commit, dict):
            git_commit_hash = (
                git_commit.get("hash")
                or git_commit.get("commit_hash")
                or ""
            )

        # 1. 调用 complete_task 更新任务状态（保留原有任务完成流程）
        complete_result = self.complete_task(
            task_id=task_id,
            git_commit_hash=git_commit_hash,
            summary=result,
        )
        if "error" in complete_result:
            return complete_result

        # 2. 生成工作成果摘要（不含逐条 tool_call 执行记录）
        summary_text = self.context_isolator.create_work_summary(
            task_description=task_description,
            tool_calls=tool_calls,
            git_commit=git_commit,
            result=result,
        )

        # 3. 构建父 agent 上下文条目（替代子 agent 完整工作日志）
        parent_entry = self.context_isolator.build_parent_context_entry(
            member_id=assignee,
            summary=summary_text,
        )

        # 4. 将摘要条目注入父 agent 的 session.context
        context_injected = False
        try:
            session_context = getattr(self.session, "context", None)
            if isinstance(session_context, list):
                session_context.append(parent_entry)
                context_injected = True
            else:
                logger.warning(
                    "父 agent session.context 不可用，跳过摘要注入, task=%s",
                    task_id,
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("注入父 agent 上下文失败: %s, task=%s", exc, task_id)

        return {
            "task_id": task_id,
            "status": "completed",
            "summary": summary_text,
            "context_injected": context_injected,
        }

    # ------------------------------------------------------------------
    # SubTask 9.3: 任务跟踪
    # ------------------------------------------------------------------
    def _action_query_tasks(self, arguments: dict) -> dict:
        """查询所有已分配任务的状态，并返回任务关联的 Git 提交记录。

        支持按 target_member_id 与 status 筛选。
        """
        target_id = arguments.get("target_member_id")
        status = arguments.get("status")

        tasks = list(self.tasks)
        if target_id:
            tasks = [t for t in tasks if t.get("assignee") == target_id]
        if status:
            tasks = [t for t in tasks if t.get("status") == status]

        # 按成员缓存 Git 提交记录，避免重复查询
        commit_cache: Dict[str, List[str]] = {}
        result = []
        for t in tasks:
            item = dict(t)
            assignee = t.get("assignee", "")
            if assignee not in commit_cache:
                commits: List[str] = []
                member = self._find_member(assignee)
                if member and member.get("workspace_id"):
                    try:
                        log_result = self.docker_manager.git_log(
                            member["workspace_id"], limit=10
                        )
                        commits = log_result.get("commits", [])
                    except Exception as exc:  # noqa: BLE001
                        logger.warning("获取任务关联 Git 提交失败: %s", exc)
                commit_cache[assignee] = commits
            item["git_commits"] = commit_cache[assignee]
            result.append(item)

        return {"tasks": result, "total": len(result)}

    # ------------------------------------------------------------------
    # SubTask 9.4: 等待成员完成
    # ------------------------------------------------------------------
    def _action_wait_for(self, arguments: dict) -> dict:
        """等待一个或多个成员完成当前任务后返回。

        轮询成员的工作状态，当所有指定成员的工作状态不再为 "working"
        时返回结果。支持通过 timeout 参数设置最大等待时间。

        参数：
            target_member_ids: 逗号分隔的成员 ID 列表（必填）
            timeout: 等待超时秒数（可选，默认 300，即 5 分钟）

        返回：
            members: 每个成员最终状态
            timed_out: 是否超时
            waited: 实际等待秒数
            hint: 超时时提示（可暂时结束本轮，成员完成后会自动推送消息）
        """
        raw_ids = arguments.get("target_member_ids", "")
        if not raw_ids:
            return {"error": "缺少 target_member_ids"}

        member_ids = [mid.strip() for mid in raw_ids.split(",") if mid.strip()]
        if not member_ids:
            return {"error": "target_member_ids 为空"}

        # 校验所有成员是否存在
        members_map: Dict[str, Dict[str, Any]] = {}
        for mid in member_ids:
            member = self._find_member(mid)
            if member is None:
                return {"error": f"成员不存在: {mid}"}
            members_map[mid] = member

        try:
            timeout = max(1, int(arguments.get("timeout", 300)))
        except (TypeError, ValueError):
            timeout = 300

        # 终端状态：成员不再处于工作状态（以 _active_tasks 实际执行态为准）
        terminal_statuses = {"idle", "stopped", "error"}

        deadline = time.time() + timeout
        poll_interval = 2  # 秒
        timed_out = False

        while True:
            # 检查剩余时间
            remaining = deadline - time.time()
            if remaining <= 0:
                timed_out = True
                break

            # 检查每个成员的状态（实时查询实际执行态）
            all_done = True
            for mid in member_ids:
                status = self._live_work_status(mid)
                if status not in terminal_statuses:
                    all_done = False
                    break

            if all_done:
                break

            # 等待下次轮询（不超过剩余时间）
            sleep_time = min(poll_interval, remaining)
            time.sleep(sleep_time)

        waited = timeout - max(0, deadline - time.time())

        # 收集最终状态（实时执行态）
        results = []
        for mid in member_ids:
            member = members_map[mid]
            results.append({
                "member_id": mid,
                "name": member.get("name", ""),
                "work_status": self._live_work_status(mid),
                "current_task": member.get("current_task", ""),
            })

        result = {
            "members": results,
            "timed_out": timed_out,
            "waited": round(waited, 1),
            "total": len(results),
        }
        if timed_out:
            # 超时提示：告知模型可暂时结束本轮，成员完成回复后会自动推送
            # 消息给 leader（chat 层成员回复回发机制），避免模型陷入反复
            # 轮询 wait_for 的循环。
            working = [
                r["name"] for r in results
                if r["work_status"] not in terminal_statuses
            ]
            result["hint"] = (
                "等待超时，以下成员仍在工作中："
                + ("、".join(working) if working else "（全部）")
                + "。你可以暂时结束本轮回复（无需继续轮询 wait_for）："
                "成员完成回复后会自动推送消息给你，"
                "届时你会收到新消息，再继续查看结果。"
            )
        return result
