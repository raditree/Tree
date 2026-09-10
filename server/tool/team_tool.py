"""内置 team 工具 - 团队与成员管理。

仅覆盖团队管理子域（通信相关动作在独立的 ``message`` 工具中）：
- list_models：可用模型池
- list_teams：本用户名下的 TOP 团队（与 message 工具共用同一实现）
- list_members：成员名单（team_leader/teammates/team_member 分组，实时）
- create_member：团队 leader 创建成员（含工作空间/身份/私人空间/初始化消息）
- query_member：成员详情
- update_member：编辑成员信息（role/duty/model/can_lead_team/提示词/评分）
- query_status：成员实时工作状态与活动日志位置

层级约束：TOP 为 Level 0；最大层级深度与每层成员上限在创建 TOP 时写入
teams 表（不可修改）；can_lead_team=False 的成员不可再建子团队。
成员产出与进度统一通过其活动日志
``agentspace/{member_id}/.self/activity.log``（行首带日期时间）检索，
工作目录统一后 leader 可直接 read/grep，不再提供 view_member_log/output
或 git 产出查询（共享仓库下 git 记录无法按成员归属）。
"""

import logging
from typing import Any, Dict

from prompt import versions

from tool.team_base import (
    ROSTER_FILE_PATH,
    SCORE_FIELDS,
    TeamToolBase,
    _fmt_ts,
    _resolve_team_limits,
    _to_score,
)

logger = logging.getLogger(__name__)

# 兼容性别名：历史代码/测试从 tool.team_tool 导入这些符号
__all__ = [
    "TeamTool",
    "ROSTER_FILE_PATH",
    "SCORE_FIELDS",
    "_resolve_team_limits",
    "_to_score",
    "_fmt_ts",
]

# team 工具支持的 action（未知 action 错误中回显）
TEAM_ACTIONS = (
    "list_models",
    "list_teams",
    "list_members",
    "create_member",
    "query_member",
    "update_member",
    "query_status",
)


class TeamTool(TeamToolBase):
    """team 工具：团队与成员管理。通信能力见 ``tool.message_tool.MessageTool``。"""

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
                            "enum": list(TEAM_ACTIONS),
                            "description": "操作类型。按成员寻址的操作必须提供 "
                                         "target_member_id（ID 或名称，调用前先 "
                                         "list_members 获取确切值）：query_member / "
                                         "update_member / query_status。"
                                         "create_member 为团队 leader 权限：仅在用户"
                                         "明确要求组建/扩充团队时调用，创建后系统会"
                                         "自动向新成员发送其 system prompt 初始化消息。"
                                         "派活/催进度/等待完成请改用 message 工具。",
                        },
                        "model_id": {
                            "type": "string",
                            "description": "create_member 时为新成员指定模型；"
                                           "update_member 时修改成员模型；"
                                           "list_members 时可作为筛选条件",
                        },
                        "member_name": {
                            "type": "string",
                            "description": "create_member 时的新成员名称（团队内勿重名）",
                        },
                        "target_member_id": {
                            "type": "string",
                            "description": "目标成员 ID 或名称（query_member/"
                                           "update_member/query_status 必填）",
                        },
                        "name": {
                            "type": "string",
                            "description": "update_member 时的成员新名称",
                        },
                        "role": {
                            "type": "string",
                            "description": "成员角色（如 后端工程师）；create_member/"
                                           "update_member 均可设置",
                        },
                        "duty": {
                            "type": "string",
                            "description": "成员职责/分工说明；create_member/"
                                           "update_member 均可设置",
                        },
                        "can_lead_team": {
                            "type": "boolean",
                            "description": "该成员是否允许再创建子团队（默认 true）",
                        },
                        "work_status": {
                            "type": "string",
                            "enum": ["idle", "working", "waiting_input", "stopped", "error"],
                            "description": "list_members 筛选条件。**只读**：由实际"
                                           "执行态决定，不可通过 update_member 设置",
                        },
                        "level": {
                            "integer": True,
                            "type": "integer",
                            "description": "list_members 按层级筛选（TOP=0）",
                        },
                        "comment": {
                            "type": "string",
                            "description": "对成员的评价（update_member）",
                        },
                        "system_prompt": {
                            "type": "string",
                            "description": "成员的独立系统提示词/职责说明（create_member "
                                         "创建时设置，或 update_member 修改；仅更新提示词，"
                                         "不清空成员上下文/工作区，新提示词在成员下次"
                                         "上下文重建时生效）",
                        },
                        "scores": {
                            "type": "object",
                            "description": "多维评分（0-10）：quality/efficiency/"
                                           "collaboration/accuracy",
                            "properties": {
                                "quality": {"type": "number"},
                                "efficiency": {"type": "number"},
                                "collaboration": {"type": "number"},
                                "accuracy": {"type": "number"},
                            },
                        },
                    },
                    "required": ["action"],
                },
            },
        }

    def execute(self, arguments: dict) -> dict:
        """根据 action 分发执行对应子流程。"""
        dispatch = {
            "list_models": self._action_list_models,
            "list_teams": self._action_list_teams,
            "list_members": self._action_list_members,
            "create_member": self._action_create_member,
            "query_member": self._action_query_member,
            "update_member": self._action_update_member,
            "query_status": self._action_query_status,
        }
        return self._dispatch_actions(dispatch, arguments)

    # ------------------------------------------------------------------
    # list_models
    # ------------------------------------------------------------------
    def _action_list_models(self, arguments: dict) -> dict:
        """列出可用模型池。"""
        models = [
            {"model_id": mid, "name": cfg.name}
            for mid, cfg in self.model_configs.items()
        ]
        return {
            "models": models,
            "total": len(models),
            "generated_at": self._now(),
        }

    # ------------------------------------------------------------------
    # create_member
    # ------------------------------------------------------------------
    def _action_create_member(self, arguments: dict) -> dict:
        """创建新成员（leader 权限）。

        校验顺序：层级深度 → can_lead_team → 直属实时人数 → 模型 → 重名。
        创建后：工作空间（云端共享 TOP / 本地统一目录）→ 身份文件 →
        私人空间 → roster 视图 → team_members 落库 → 初始化消息投递。
        """
        if self.level >= self.max_team_level:
            return {
                "error": f"已达最大层级（Level {self.max_team_level}），"
                "不可继续创建子团队",
                "hint": "可由更上层 leader 创建，或先用 message send_message "
                        "把工作派给现有成员",
                "generated_at": self._now(),
            }
        if not self.can_lead_team:
            return {
                "error": "当前成员不可创建子团队（can_lead_team=False）",
                "hint": "如需带队权限，请让你的直属 leader 用 team update_member "
                        "将你的 can_lead_team 置为 true",
                "generated_at": self._now(),
            }

        # 直属人数实时统计（team_store 权威；含本实例刚建未落库的内存成员）
        live_rows = self._live_members()
        direct_count = sum(
            1 for m in live_rows
            if (m.get("parent_agent_id") or "") == self.agent_id
        )
        if direct_count >= self.max_members_per_level:
            return {
                "error": f"你的直属成员数量已达上限"
                f"（{self.max_members_per_level}），不可继续创建成员",
                "hint": "可把新工作交给现有直属成员，由其再分工",
                "generated_at": self._now(),
            }

        model_id = arguments.get("model_id")
        if not model_id:
            pool = self._action_list_models(arguments)
            pool["hint"] = "缺少 model_id：请从上述 models 中选择后重新调用 create_member"
            return pool
        if model_id not in self.model_configs:
            return {
                "error": f"模型不存在: {model_id}",
                "hint": "请先用 list_models 获取可用模型 ID",
                "generated_at": self._now(),
            }
        model_cfg = self.model_configs[model_id]

        member_id = self._generate_member_id()
        member_name = str(
            arguments.get("member_name") or f"member-{member_id[-6:]}"
        ).strip()
        if not member_name:
            return {"error": "成员名称不能为空", "generated_at": self._now()}

        # 重名实时校验（team_store 权威 + 本实例内存名单）
        dup_db = 0
        try:
            from data.team_store import count_members_by_name

            dup_db = count_members_by_name(self.team_id, member_name)
        except Exception as exc:  # noqa: BLE001
            logger.warning("重名校验查询失败: %s", exc)
        dup_cache = any(
            m.get("name") == member_name for m in self.members
        )
        if dup_db > 0 or dup_cache:
            return {
                "error": f"成员名称已存在: {member_name}",
                "hint": "团队内成员名称需唯一（按名称寻址依赖唯一性），"
                        "请换一个名称后重试，或先用 list_members 查看现有成员",
                "generated_at": self._now(),
            }

        role = str(arguments.get("role") or "").strip()
        duty = str(arguments.get("duty") or "").strip()
        system_prompt = str(arguments.get("system_prompt") or "").strip()
        can_lead_team = arguments.get("can_lead_team")
        can_lead_team = True if can_lead_team is None else bool(can_lead_team)

        ws_result = self.docker_manager.create_workspace(
            workspace_id=member_id,
            parent_workspace_id=self.workspace_id or None,
            agent_name=member_name,
            shared_with=self.team_id,
        )
        if not isinstance(ws_result, dict) or "error" in ws_result:
            return {
                "error": "创建成员工作空间失败",
                "detail": ws_result,
                "generated_at": self._now(),
            }

        now = self._now()
        member: Dict[str, Any] = {
            "id": member_id,
            "name": member_name,
            "role": role,
            "duty": duty,
            "model_id": model_id,
            "level": self.level + 1,
            "can_lead_team": can_lead_team,
            "workspace_id": ws_result.get("workspace_id", member_id),
            "parent_agent_id": self.agent_id,
            "team_id": self.team_id,
            "leader_name": self._leader_display_name(),
            "created_at": now,
            "created_at_ms": None,
            "work_status": "idle",
            "scores": {k: 0.0 for k in SCORE_FIELDS},
            "comment": "",
            "system_prompt": system_prompt,
        }
        self.members.append(member)

        self._write_member_identity(member)
        self._init_member_private_space(member)
        self._save_roster()

        persisted = True
        try:
            from data.team_store import add_member

            add_member(
                user_id=self.user_id,
                team_id=self.team_id or self.agent_id,
                member_id=member_id,
                name=member_name,
                role=role,
                duty=duty,
                model_id=model_id,
                level=member["level"],
                system_prompt=system_prompt,
                parent_agent_id=self.agent_id,
                can_lead_team=can_lead_team,
            )
        except Exception as exc:  # noqa: BLE001
            persisted = False
            logger.warning("持久化新成员到 team_store 失败 %s: %s", member_id, exc)

        initialized = self._dispatch_member_init(member)

        result = {
            "member_id": member_id,
            "name": member_name,
            "role": role,
            "duty": duty,
            "model_id": model_id,
            "level": member["level"],
            "can_lead_team": can_lead_team,
            "workspace_id": member["workspace_id"],
            "log_path": self._log_path(member_id),
            "created_at": now,
            "initialized": initialized,
            "persisted": persisted,
            "generated_at": now,
        }
        if not initialized:
            result["hint"] = (
                "成员已创建但初始化消息投递失败（消息通道未就绪），"
                "可稍后用 message send_message 通知该成员"
            )
        elif not persisted:
            result["hint"] = "成员已创建并通知，但名单持久化失败，请稍后重试或联系管理员"
        return result

    def _dispatch_member_init(self, member: Dict[str, Any]) -> bool:
        """向新成员投递初始化消息（含角色职责/system prompt）。"""
        sp = (member.get("system_prompt") or "").strip()
        content = (
            "【团队初始化】你已加入团队（直属 leader: "
            f"{member.get('leader_name') or self._leader_display_name()}）。\n"
        )
        if member.get("role") or member.get("duty"):
            content += (
                f"你的角色：{member.get('role') or '（未设）'}\n"
                f"你的职责：{member.get('duty') or '（未设）'}\n"
            )
        if sp:
            content += f"你的角色与职责（system prompt）如下，请阅读并确认理解：\n{sp}\n"
        elif not (member.get("role") or member.get("duty")):
            content += "目前未设置独立分工，请先向 leader 确认你的角色与职责。\n"
        content += (
            "确认后等待 leader 用 message send_message 派发工作；"
            "工作过程与产出请持续写入 .self/activity.log。"
        )
        # 优先统一 dispatcher（与 message 工具同通道，leader_id 由 dispatcher
        # 按 source_agent_id 注入），不可用时回退 broker 直投
        if self.message_dispatcher is not None:
            try:
                r = self.message_dispatcher(
                    self.user_id,
                    [member.get("id", "")],
                    content,
                    source_agent_id=self.agent_id,
                    team_id=self.team_id,
                    extra={"session_id": self.session_id},
                )
                return bool(r and r.get("status") in ("sent", "partial")) \
                    or bool(r and r.get("sent"))
            except Exception as exc:  # noqa: BLE001
                logger.warning("初始化消息 dispatcher 投递失败，回退 broker: %s", exc)
        return self._dispatch_to_member(member, content)

    # ------------------------------------------------------------------
    # query_member
    # ------------------------------------------------------------------
    def _action_query_member(self, arguments: dict) -> dict:
        """按 id/name 查询单个成员详情。"""
        target = (
            arguments.get("target_member_id")
            or arguments.get("member_id")
            or arguments.get("member_name")
        )
        if not target:
            return {
                "error": "缺少 target_member_id",
                "hint": "请先调用 list_members 获取成员 ID 或名称",
                "generated_at": self._now(),
            }
        member = self._find_member(target)
        if member is None:
            return {
                "error": f"成员不存在: {target}",
                "hint": "请用 list_members 查看当前团队的有效成员名单（支持按名称寻址）",
                "generated_at": self._now(),
            }
        mid = member.get("id", "")
        view = self._member_view(member, "self" if mid == self.agent_id else "queried")
        # 管理查询额外暴露 leader 维护字段（不返回消息历史等内部运行态）
        view.update({
            "comment": member.get("comment", "") or "",
            "scores": member.get("scores") or {},
            "system_prompt": member.get("system_prompt", "") or "",
        })
        return {
            "member": view,
            "generated_at": self._now(),
        }

    # ------------------------------------------------------------------
    # update_member
    # ------------------------------------------------------------------
    VALID_WORK_STATUS = ("idle", "working", "waiting_input", "stopped", "error")

    def _action_update_member(self, arguments: dict) -> dict:
        """编辑成员信息（name/role/duty/model_id/can_lead_team/comment/
        scores/system_prompt）。只改信息，不重建工作区、不清空成员上下文。"""
        target = (
            arguments.get("target_member_id")
            or arguments.get("member_id")
            or arguments.get("member_name")
        )
        if not target:
            return {
                "error": "缺少 target_member_id",
                "hint": "请先调用 list_members 获取成员 ID 或名称",
                "generated_at": self._now(),
            }
        if arguments.get("work_status") is not None:
            return {
                "error": "work_status 为只读字段（由实际执行状态决定），"
                "请勿通过 update_member 设置；如需停止成员请使用前端「停止」按钮",
                "generated_at": self._now(),
            }
        member = self._find_member(target)
        if member is None:
            return {
                "error": f"成员不存在: {target}",
                "hint": "请用 list_members 查看有效成员名单",
                "generated_at": self._now(),
            }

        updated = []
        sync_fields: Dict[str, Any] = {}

        name = arguments.get("name")
        if name is not None:
            stripped = str(name).strip()
            if not stripped:
                return {"error": "成员名称不能为空", "generated_at": self._now()}
            if stripped != member.get("name"):
                dup = any(
                    m.get("name") == stripped and m.get("id") != member.get("id")
                    for m in self._live_members()
                )
                if dup:
                    return {
                        "error": f"成员名称已存在: {stripped}",
                        "hint": "团队内名称需唯一，请换名",
                        "generated_at": self._now(),
                    }
            member["name"] = stripped
            updated.append("name")
            sync_fields["name"] = stripped

        role = arguments.get("role")
        if role is not None:
            member["role"] = str(role)
            updated.append("role")
            sync_fields["role"] = str(role)

        duty = arguments.get("duty")
        if duty is not None:
            member["duty"] = str(duty)
            updated.append("duty")
            sync_fields["duty"] = str(duty)

        system_prompt = arguments.get("system_prompt")
        if system_prompt is not None:
            member["system_prompt"] = str(system_prompt)
            updated.append("system_prompt")
            sync_fields["system_prompt"] = str(system_prompt)

        model_id = arguments.get("model_id")
        if model_id is not None:
            if model_id not in self.model_configs:
                return {
                    "error": f"模型不存在: {model_id}",
                    "hint": "请先用 list_models 获取可用模型 ID",
                    "generated_at": self._now(),
                }
            member["model_id"] = model_id
            updated.append("model_id")
            sync_fields["model_id"] = model_id

        can_lead_team = arguments.get("can_lead_team")
        if can_lead_team is not None:
            flag = bool(can_lead_team)
            member["can_lead_team"] = flag
            updated.append("can_lead_team")
            sync_fields["can_lead_team"] = flag

        comment = arguments.get("comment")
        if comment is not None:
            member["comment"] = str(comment)
            updated.append("comment")
            sync_fields["comment"] = str(comment)

        scores = arguments.get("scores")
        if isinstance(scores, dict):
            member.setdefault("scores", {})
            for key in SCORE_FIELDS:
                if key in scores:
                    member["scores"][key] = _to_score(scores[key])
            updated.append("scores")
            sync_fields["scores"] = member["scores"]

        if not updated:
            return {
                "error": "未提供任何可更新的字段",
                "hint": "可更新字段：name/role/duty/model_id/can_lead_team/"
                        "comment/system_prompt/scores（work_status 只读）",
                "generated_at": self._now(),
            }

        self._sync_member_to_team_store(member.get("id", ""), **sync_fields)
        self._save_roster()
        pushed = self._push_roster_update()

        # 若更新的是当前 agent 自身，同步自身引导态
        if member.get("id") == self.agent_id and "can_lead_team" in sync_fields:
            self.can_lead_team = bool(sync_fields["can_lead_team"])

        # 管理动作返回详情（含 leader 维护字段，便于确认写入结果）
        view = self._member_view(member, "self")
        view.update({
            "comment": member.get("comment", "") or "",
            "scores": member.get("scores") or {},
            "system_prompt": member.get("system_prompt", "") or "",
        })
        return {
            "member_id": member.get("id", ""),
            "updated": updated,
            "member": view,
            "roster_pushed": pushed,
            "generated_at": self._now(),
        }

    # ------------------------------------------------------------------
    # query_status
    # ------------------------------------------------------------------
    def _action_query_status(self, arguments: dict) -> dict:
        """查询成员实时工作状态与活动日志位置（不含任何 git/任务字段）。"""
        target = (
            arguments.get("target_member_id")
            or arguments.get("member_id")
            or arguments.get("member_name")
        )
        if not target:
            return {
                "error": "缺少 target_member_id",
                "hint": "请先调用 list_members 获取成员 ID 或名称",
                "generated_at": self._now(),
            }
        member = self._find_member(target)
        if member is None:
            return {
                "error": f"成员不存在: {target}",
                "hint": "请用 list_members 查看有效成员名单",
                "generated_at": self._now(),
            }
        mid = member.get("id", "")
        ws_id = member.get("workspace_id") or mid
        last_active_at = self._last_activity_at(ws_id)
        log_path = self._log_path(mid)
        return {
            "member_id": mid,
            "name": member.get("name", ""),
            "work_status": self._live_work_status(mid),
            "last_active_at": last_active_at,
            "log_path": log_path,
            "hint": (
                "查看成员具体产出与进度：直接 read 其活动日志 "
                f"{log_path}（行首为日期时间），或用 terminal 执行 "
                f"`grep -E '\\[done\\]|\\[tool\\]' {log_path} | tail -n 30` "
                "定位完成记录与产出文件；产出文件在共享工作目录中可直接 read。"
                "work_status 仅反映实时执行态（working/idle），last_active_at "
                "为日志最后一条记录时间。"
            ),
            "generated_at": self._now(),
        }
