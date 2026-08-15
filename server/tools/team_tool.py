"""内置 team 工具 - 团队成员管理、消息管理、任务管理。

工具覆盖三个子域：
- 成员管理：创建成员、成员管理表（.self/team_roster.md）、多维评分、成员/状态查询
- 消息管理：点对点消息、广播消息、文件发送
- 任务管理：任务分配、任务完成流程、任务跟踪

team 工具同时维护团队层级限制：顶部 agent 为 Level 0，最深 Level 3，
且 can_lead_team 为 False 的成员不可创建子团队。
"""

import logging
import os
import random
import string
import time
from typing import Any, Dict, List, Optional

from core.context_isolation import ContextIsolator
from core.config import get_config
from core.conversation_store import clear_context
from core.docker_manager import DockerManager
from core.llm import AgentLLMSession
from core.models import ModelConfig
from core.session_cache import clear_user_agent

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


class TeamTool:
    """team 工具：团队成员管理、消息管理、任务管理。

    每个 agent 持有一个 TeamTool 实例：
    - ``self.level`` 表示当前 agent 的层级，顶部 agent 为 Level 0
    - ``self.can_lead_team`` 表示当前 agent 是否可创建子团队
      （由 ``set`` 工具在配置 teammates 时设置；默认 True）
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
        """
        self.session = session
        self.docker_manager = docker_manager
        self.model_configs: Dict[str, ModelConfig] = model_configs
        self.workspace_id: str = getattr(session, "workspace_id", "") or ""
        self.broker = broker
        self.user_id = user_id
        self.agent_id = agent_id
        self.leader_id = leader_id

        # 成员列表（内存，同时持久化到 team_roster.md）
        self.members: List[Dict[str, Any]] = []
        # 消息历史（内存）：每条 {id, from, to, type, content, timestamp, ...}
        self.messages: List[Dict[str, Any]] = []
        # 任务列表（内存）：每条 {id, description, priority, ...}
        self.tasks: List[Dict[str, Any]] = []

        # 当前 agent 层级：顶部 agent 为 Level 0
        self.level: int = 0
        # 团队最大层级深度（配置 agents.max_level，顶部为 Level 0）
        self.max_team_level: int = int(
            get_config().get("agents", {}).get("max_level", 3)
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
                "description": "团队成员管理、消息管理、任务管理",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": [
                                "list_models",
                                "create_member",
                                "list_members",
                                "query_member",
                                "update_member",
                                "query_status",
                                "view_member_output",
                                "view_member_log",
                                "send_message",
                                "broadcast",
                                "send_file",
                                "assign_task",
                                "query_tasks",
                            ],
                            "description": "操作类型",
                        },
                        "model_id": {
                            "type": "string",
                            "description": "创建/编辑成员时选择的模型 ID",
                        },
                        "member_name": {
                            "type": "string",
                            "description": "成员名称",
                        },
                        "target_member_id": {
                            "type": "string",
                            "description": "目标成员 ID",
                        },
                        "name": {
                            "type": "string",
                            "description": "编辑成员时的新名称",
                        },
                        "work_status": {
                            "type": "string",
                            "enum": ["idle", "working", "waiting_input", "stopped", "error"],
                            "description": "成员工作状态",
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
                            "description": "成员的独立系统提示词/职责说明（更新后重建工作区并清空上下文，等价于重生）",
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
            "create_member": self._action_create_member,
            "list_members": self._action_list_members,
            "query_member": self._action_query_member,
            "update_member": self._action_update_member,
            "query_status": self._action_query_status,
            "view_member_output": self._action_view_member_output,
            "view_member_log": self._action_view_member_log,
            "send_message": self._action_send_message,
            "broadcast": self._action_broadcast,
            "send_file": self._action_send_file,
            "assign_task": self._action_assign_task,
            "query_tasks": self._action_query_tasks,
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
        """按 ID 查找成员，未找到返回 None。"""
        for m in self.members:
            if m.get("id") == member_id:
                return m
        return None

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
        return self.broker.dispatch(
            (self.user_id, member_id),
            {
                "user_id": self.user_id,
                "agent_id": member_id,
                "workspace_id": member.get("workspace_id", ""),
                "model_id": member.get("model_id", ""),
                "system_prompt": member.get("system_prompt", ""),
                "leader_id": self.leader_id,
                "content": content,
            },
        )

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
                "is_limitless_context": cfg.is_limitless_context,
            }
            for mid, cfg in self.model_configs.items()
        ]
        return {"models": models, "total": len(models)}

    def _action_create_member(self, arguments: dict) -> dict:
        """创建新成员流程。

        1. 层级校验：当前层级 >= 3 时拒绝
        2. can_lead_team 校验：当前 agent 不可带队时拒绝
        3. 未指定 model_id 时返回可用模型池
        4. 创建工作空间（parent_workspace_id = 当前 agent 的 workspace_id）
        5. 配置成员信息并加入 self.members
        6. 持久化到成员管理表
        """
        # 层级深度校验（配置 agents.max_level）
        if self.level >= self.max_team_level:
            return {"error": "已达最大层级（Level 3），不可继续创建子团队"}

        # 每级成员数量上限（配置 docker.max_members_per_level）
        max_members = getattr(self.docker_manager, "max_members_per_level", 8)
        if len(self.members) >= max_members:
            return {
                "error": f"当前 agent 的成员数量已达上限（{max_members}），"
                "不可继续创建子团队"
            }

        # 同步 set 工具设置的 can_lead_team：从 session.teammates 中查找当前成员的配置
        # （set_tool 将 teammates 保存在 session 上，此处与 team_tool 的 can_lead_team 联动）
        if hasattr(self.session, "teammates") and self.session.teammates:
            current_member_id = getattr(self, "member_id", None)
            if current_member_id is not None:
                member_config = next(
                    (
                        t
                        for t in self.session.teammates
                        if t.get("member_id") == current_member_id
                    ),
                    None,
                )
                if member_config is not None:
                    self.can_lead_team = member_config.get("can_lead_team", True)

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

        # 创建工作空间（含 Git，parent_workspace_id 设为当前 agent 的 workspace_id）
        ws_result = self.docker_manager.create_workspace(
            workspace_id=member_id,
            parent_workspace_id=self.workspace_id or None,
            agent_name=member_name,
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
            "leader_name": self._leader_name(),
            "created_at": now,
            "work_status": "idle",  # idle / working / waiting_input / stopped / error
            "current_task": "",
            "can_lead_team": True,
            # 成员独立系统提示词（leader 可后续通过 update_member 修改；
            # 修改后触发工作区重建与上下文清空，checklist 12）
            "system_prompt": "",
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

        # 记录到成员管理表
        self._save_roster()

        return {
            "member_id": member_id,
            "name": member_name,
            "model_id": model_id,
            "level": member["level"],
            "workspace_id": member["workspace_id"],
            "created_at": now,
        }

    # ------------------------------------------------------------------
    # SubTask 7.2: 成员管理表
    # ------------------------------------------------------------------
    def _save_roster(self) -> None:
        """将成员管理表保存到工作空间的 ``.self/team_roster.md``。

        通过 docker_manager.exec_in_workspace 写入文件。
        表格列：ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | 质量 | 效率 | 协作性 | 准确性
        """
        if not self.workspace_id:
            return

        header = (
            "| ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | "
            "质量 | 效率 | 协作性 | 准确性 |"
        )
        separator = "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        lines = [header, separator]
        for m in self.members:
            s = m.get("scores", {})
            lines.append(
                f"| {m.get('id', '')} | {m.get('name', '')} | "
                f"{m.get('model_id', '')} | {m.get('level', 0)} | "
                f"{m.get('created_at', '')} | {m.get('work_status', '')} | "
                f"{m.get('comment', '')} | "
                f"{_to_score(s.get('quality', 0))} | "
                f"{_to_score(s.get('efficiency', 0))} | "
                f"{_to_score(s.get('collaboration', 0))} | "
                f"{_to_score(s.get('accuracy', 0))} |"
            )
        content = "\n".join(lines) + "\n"

        # 使用 quoted here-doc 写入，避免变量展开与特殊字符问题
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
        """从工作空间加载成员管理表（若存在）。

        仅恢复表格中持久化的字段；消息历史与任务队列不持久化，重置为空。
        """
        if not self.workspace_id:
            return

        cmd = ["sh", "-c", f"cat {ROSTER_FILE_PATH} 2>/dev/null"]
        try:
            result = self.docker_manager.exec_in_workspace(self.workspace_id, cmd)
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取成员管理表失败: %s", exc)
            return

        if result.get("exit_code") != 0:
            return

        stdout = result.get("stdout", "")
        loaded = self._parse_roster_md(stdout)
        if loaded:
            self.members = loaded

    def _parse_roster_md(self, content: str) -> List[Dict[str, Any]]:
        """解析成员管理表 markdown 表格，返回成员字典列表。"""
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
            members.append(
                {
                    "id": member_id,
                    "name": parts[1],
                    "model_id": parts[2],
                    "model_name": parts[2],
                    "level": level,
                    # member_id 同时作为 workspace_id（create_workspace 的约定）
                    "workspace_id": member_id,
                    "container_id": "",
                    "parent_workspace_id": self.workspace_id,
                    "created_at": parts[4],
                    "work_status": parts[5] or "idle",
                    "current_task": "",
                    "can_lead_team": True,
                    "scores": {
                        "quality": _to_score(parts[7]),
                        "efficiency": _to_score(parts[8]),
                        "collaboration": _to_score(parts[9]),
                        "accuracy": _to_score(parts[10]),
                    },
                    "comment": parts[6],
                    "task_ids": [],
                    "message_history": [],
                }
            )
        return members

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

        # 更新成员管理表
        self._save_roster()
        return {
            "member_id": member_id,
            "scores": member["scores"],
            "comment": member["comment"],
        }

    # ------------------------------------------------------------------
    # SubTask 7.4: 成员查询
    # ------------------------------------------------------------------
    def _action_list_members(self, arguments: dict) -> dict:
        """列出所有成员（完整成员管理表），支持按模型/层级/工作状态筛选。"""
        result = list(self.members)

        # 按模型筛选
        model_id = arguments.get("model_id")
        if model_id:
            result = [m for m in result if m.get("model_id") == model_id]

        # 按层级筛选
        level = arguments.get("level")
        if level is not None:
            try:
                lv = int(level)
                result = [m for m in result if m.get("level") == lv]
            except (TypeError, ValueError):
                pass

        # 按工作状态筛选
        work_status = arguments.get("work_status")
        if work_status:
            result = [m for m in result if m.get("work_status") == work_status]

        return {"members": result, "total": len(result)}

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
        """编辑成员信息（name/model_id/work_status/can_lead_team/comment/scores/system_prompt）。

        仅更新显式提供的字段，其余保持不变；更新后持久化到成员管理表。

        checklist 12 语义：
        - 变 model_id / comment → 只更新成员管理表，无其他操作（不重建工作区）。
        - 变角色（name）/ 提示词（system_prompt）→ 重建工作区、清空上下文
          （相当于成员重生，用新角色/新提示词重新初始化）。
        """
        member_id = arguments.get("target_member_id") or arguments.get("member_id")
        if not member_id:
            return {"error": "缺少 target_member_id"}
        member = self._find_member(member_id)
        if member is None:
            return {"error": f"成员不存在: {member_id}"}

        updated: List[str] = []
        # 触发重生的字段：角色（name）/ 提示词（system_prompt）变化 → 重建工作区清空上下文
        rebirth_triggered = False

        # 更新名称（角色）
        name = arguments.get("name")
        if name is not None:
            stripped = str(name).strip()
            if not stripped:
                return {"error": "成员名称不能为空"}
            if member.get("name") != stripped:
                rebirth_triggered = True
            member["name"] = stripped
            updated.append("name")

        # 更新成员独立提示词（角色/职责说明）
        system_prompt = arguments.get("system_prompt")
        if system_prompt is not None:
            new_prompt = str(system_prompt)
            if member.get("system_prompt") != new_prompt:
                rebirth_triggered = True
            member["system_prompt"] = new_prompt
            updated.append("system_prompt")

        # 更新模型（校验模型必须存在于模型池；按 checklist 12(a) 不重建工作区）
        model_id = arguments.get("model_id")
        if model_id is not None:
            if model_id not in self.model_configs:
                return {"error": f"模型不存在: {model_id}"}
            member["model_id"] = model_id
            member["model_name"] = self.model_configs[model_id].name
            updated.append("model")

        # 更新工作状态（校验合法值）
        work_status = arguments.get("work_status")
        if work_status is not None:
            if work_status not in self.VALID_WORK_STATUS:
                return {"error": f"非法工作状态: {work_status}"}
            member["work_status"] = work_status
            updated.append("work_status")

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

        # 持久化到成员管理表
        self._save_roster()

        # checklist 12(b)：角色/提示词变化 → 重建工作区并清空上下文（重生）
        rebuilt = False
        cleared = False
        if rebirth_triggered:
            rebuilt, cleared = self._rebuild_member(member)

        return {
            "member_id": member_id,
            "updated": updated,
            "member": member,
            "rebirth": {
                "triggered": rebirth_triggered,
                "workspace_rebuilt": rebuilt,
                "context_cleared": cleared,
            },
        }

    def _rebuild_member(self, member: Dict[str, Any]) -> tuple:
        """重建成员工作空间并清空其上下文（checklist 12(b) 重生）。

        - 删除旧容器并重建（新角色/新提示词的干净工作空间，重新初始化 rule.md）
        - 重写 ``.self/identity.md`` 身份信息
        - 清空该成员在会话缓存与数据库中的上下文，使其下次处理消息时全新开始

        :return: ``(workspace_rebuilt, context_cleared)``
        """
        ws_id = member.get("workspace_id")
        workspace_rebuilt = False
        if ws_id:
            try:
                self.docker_manager.remove_workspace(ws_id)
                create_result = self.docker_manager.create_workspace(
                    workspace_id=ws_id,
                    parent_workspace_id=member.get("parent_workspace_id") or None,
                    agent_name=member.get("name") or "",
                )
                if "error" not in create_result:
                    workspace_rebuilt = True
                    # 用最新角色/信息重写身份文件
                    self._write_member_identity(member)
            except Exception as exc:  # noqa: BLE001
                logger.warning("重建成员工作空间失败: %s", exc)

        # 清空上下文：会话缓存 + 数据库持久化上下文
        context_cleared = False
        member_id = member.get("id", "")
        if self.user_id and member_id:
            try:
                clear_user_agent(self.user_id, member_id)
                clear_context(self.user_id, member_id)
                context_cleared = True
            except Exception as exc:  # noqa: BLE001
                logger.warning("清空成员上下文失败: %s", exc)

        return workspace_rebuilt, context_cleared

    # ------------------------------------------------------------------
    # SubTask 7.5: 工作状态查询
    # ------------------------------------------------------------------
    def _action_query_status(self, arguments: dict) -> dict:
        """查询成员工作状态、当前任务与最后一次 Git 提交。"""
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
            "work_status": member.get("work_status", "unknown"),
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
            "work_status": member.get("work_status", "unknown"),
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
            "work_status": member.get("work_status", "unknown"),
            "log_lines": log_lines,
            "total": len(log_lines),
        }

    # ------------------------------------------------------------------
    # SubTask 8.1: 点对点消息发送
    # ------------------------------------------------------------------
    def _action_send_message(self, arguments: dict) -> dict:
        """点对点发送消息：路由到目标成员并记录在双方消息历史中。"""
        target_id = arguments.get("target_member_id")
        message = arguments.get("message", "")
        if not target_id:
            return {"error": "缺少 target_member_id"}
        if not message:
            return {"error": "缺少 message"}

        target = self._find_member(target_id)
        if target is None:
            # 支持向 leader 发送消息（leader 不在队友的 roster 中）
            if target_id == self.leader_id:
                target = {
                    "id": self.leader_id,
                    "workspace_id": self.leader_id,
                    "model_id": "",
                    "system_prompt": "",
                }
            else:
                return {"error": f"目标成员不存在: {target_id}"}

        now = self._now()
        msg = {
            "id": self._generate_message_id(),
            "from": "self",
            "to": target_id,
            "type": "direct",
            "content": message,
            "timestamp": now,
        }
        self.messages.append(msg)
        # 在目标成员的消息历史中记录
        target.setdefault("message_history", []).append(msg)
        # 投递给目标成员，触发其异步串行处理
        dispatched = self._dispatch_to_member(target, message)

        return {
            "status": "sent",
            "message_id": msg["id"],
            "to": target_id,
            "dispatched": dispatched,
        }

    # ------------------------------------------------------------------
    # SubTask 8.2: 广播消息
    # ------------------------------------------------------------------
    def _action_broadcast(self, arguments: dict) -> dict:
        """向所有团队成员发送广播消息。"""
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
        # 每个成员的消息历史中记录该消息
        for m in self.members:
            m.setdefault("message_history", []).append(msg)

        return {
            "status": "broadcast",
            "message_id": msg["id"],
            "recipients": len(self.members),
        }

    # ------------------------------------------------------------------
    # SubTask 8.3: 文件发送
    # ------------------------------------------------------------------
    def _action_send_file(self, arguments: dict) -> dict:
        """从发送者工作空间复制文件到接收者工作空间（即时通信，与 Git 提交独立）。"""
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
        """分配任务：创建任务对象并加入成员任务队列，更新成员工作状态为工作中。"""
        target_id = arguments.get("target_member_id")
        description = arguments.get("task_description", "")
        priority = arguments.get("task_priority", "normal")
        expected_output = arguments.get("task_output", "")

        if not target_id:
            return {"error": "缺少 target_member_id"}
        if not description:
            return {"error": "缺少 task_description"}

        member = self._find_member(target_id)
        if member is None:
            return {"error": f"目标成员不存在: {target_id}"}

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
        # 更新成员工作状态为工作中
        member["work_status"] = "working"
        member["current_task"] = description
        self._save_roster()
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
        - 更新成员工作状态为空闲
        - 通知父 agent（父 agent 可随后调用 update_member_score 评分）

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

        # 更新成员工作状态
        member = self._find_member(task.get("assignee", ""))
        if member is not None:
            member["work_status"] = "idle"
            member["current_task"] = ""

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
