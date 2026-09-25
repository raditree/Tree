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
    "remove_member",
    "query_member",
    "update_member",
    "review_member",
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
                                         "update_member / remove_member / "
                                         "review_member / query_status。"
                                         "create_member 为团队 leader 权限：仅在用户"
                                         "明确要求组建/扩充团队时调用；新建成员**默认"
                                         "不分配模型**，需用户在「团队成员 → 模型配置」"
                                         "页赋模型并审核通过后才会接收消息。"
                                         "remove_member 为团队 leader 权限：仅在用户"
                                         "明确要求移除/裁撤成员时调用，默认连同其下级"
                                         "子树一并移除（cascade=true）。"
                                         "review_member 仅在用户明确要求放行/驳回某成员"
                                         "时调用（审核权属于用户，不得自行放行）。"
                                         "派活/催进度/等待完成请改用 message 工具。",
                        },
                        "model_id": {
                            "type": "string",
                            "description": "create_member 时可选的成员模型（省略则由用户"
                                           "在模型配置页赋值）；update_member 时修改成员"
                                           "模型；review_member 时可与审核一并赋模型；"
                                           "list_members 时可作为筛选条件",
                        },
                        "member_name": {
                            "type": "string",
                            "description": "create_member 时的新成员名称（团队内勿重名）",
                        },
                        "target_member_id": {
                            "type": "string",
                            "description": "目标成员 ID 或名称（query_member/"
                                           "update_member/remove_member/"
                                           "query_status 必填）",
                        },
                        "cascade": {
                            "type": "boolean",
                            "description": "remove_member 时是否连同该成员的下级子树"
                                           "一并移除（默认 true）。false 时若目标仍有"
                                           "下级成员会被拒绝，避免留下孤儿成员",
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
                        "review_status": {
                            "type": "string",
                            "enum": ["approved", "rejected", "pending_review"],
                            "description": "review_member 的目标审核状态：approved（审核"
                                           "通过，成员开始可执行）/ rejected（驳回，不再"
                                           "接收消息）/ pending_review（退回待审核）。"
                                           "默认 approved。仅用户明确要求时使用",
                        },
                        "approve": {
                            "type": "boolean",
                            "description": "review_member 的简写：true=审核通过（等价于"
                                           "review_status=approved），false=驳回。"
                                           "未提供 review_status 时生效",
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
            "remove_member": self._action_remove_member,
            "query_member": self._action_query_member,
            "update_member": self._action_update_member,
            "review_member": self._action_review_member,
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
        # 模型**可选**：成员创建后不继承 TOP 模型，缺省留空并置 pending_model，
        # 由用户在「团队成员 → 模型配置」页赋模型 + 审核通过。leader 若确实指定
        # 了模型，则该成员进入 pending_review（赋了模型但用户尚未过审），
        # 仍需用户审核通过才能执行 —— 审核权始终在用户手里。
        if model_id:
            if model_id not in self.model_configs:
                return {
                    "error": f"模型不存在: {model_id}",
                    "hint": "请先用 list_models 获取可用模型 ID，或省略 model_id "
                            "交由用户在「团队成员 → 模型配置」页赋值",
                    "generated_at": self._now(),
                }
        else:
            model_id = ""

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
        # 审核状态与模型自洽：无模型 → pending_model；指定了模型 → pending_review
        from data.team_store import derive_review_status_for

        review_status = derive_review_status_for(model_id)
        member: Dict[str, Any] = {
            "id": member_id,
            "name": member_name,
            "role": role,
            "duty": duty,
            "model_id": model_id,
            "review_status": review_status,
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
                review_status=review_status,
                level=member["level"],
                system_prompt=system_prompt,
                parent_agent_id=self.agent_id,
                can_lead_team=can_lead_team,
            )
        except Exception as exc:  # noqa: BLE001
            persisted = False
            logger.warning("持久化新成员到 team_store 失败 %s: %s", member_id, exc)

        # 未赋模型 / 未过审的成员不投递初始化消息：此时消息必然被
        # _process_member_message 的审核闸拒绝（无模型无法执行），
        # 提前跳过避免制造一条注定失败的死信。
        initialized = False
        awaiting_review = review_status != "approved"
        if not awaiting_review:
            initialized = self._dispatch_member_init(member)

        result = {
            "member_id": member_id,
            "name": member_name,
            "role": role,
            "duty": duty,
            "model_id": model_id,
            "review_status": review_status,
            "level": member["level"],
            "can_lead_team": can_lead_team,
            "workspace_id": member["workspace_id"],
            "log_path": self._log_path(member_id),
            "created_at": now,
            "initialized": initialized,
            "persisted": persisted,
            "generated_at": now,
        }
        if awaiting_review:
            result["hint"] = (
                "成员已创建，但处于等待用户处理状态"
                f"（review_status={review_status}）："
                "请让用户在「团队成员 → 模型配置」页为其选择模型并审核通过后，"
                "该成员才会接收并执行消息。在此之前它无法工作。"
            )
        elif not initialized:
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
    # remove_member
    # ------------------------------------------------------------------
    def _action_remove_member(self, arguments: dict) -> dict:
        """移除成员（及可选的下级子树）。

        校验顺序：目标必填 → 目标存在 → **不可移除自身** → **不可移除上级**
        （只能由 leader 移除自己的下属）→ cascade 与现存下属冲突时拒绝。

        移除后级联清理（每步独立容错，任一失败不阻断其余）：
        名单行（team_members）→ 工作空间 → agents 行 → 插件实例 → 会话缓存 →
        上下文 → broker 队列/worker → 限流器注册；随后重写本实例内存名单、
        刷新 roster 文件并推送名单更新。

        产出目录不做物理删除：工作空间移除后其内容随之不可达，但保留磁盘数据
        便于事后审计（与 delete_agent 的软删除取向一致）。
        """
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
        top_id = self.team_id or self.agent_id
        if member is None:
            # 顶层 agent 本身不是 team_members 里的成员行，但对成员而言它就是
            # 祖先/团队所有者——用"上级"语义拒绝，而不是含糊的"成员不存在"
            if target == top_id:
                return {
                    "error": f"不可移除团队所有者: {top_id}",
                    "hint": "只能移除自己的直属/下级成员；解散团队请删除该顶层 agent",
                    "generated_at": self._now(),
                }
            return {
                "error": f"成员不存在: {target}",
                "hint": "请用 list_members 查看有效成员名单",
                "generated_at": self._now(),
            }
        member_id = str(member.get("id") or "")
        if not member_id:
            return {"error": "成员 id 缺失，无法移除", "generated_at": self._now()}

        # 权限闸 1：不可移除自身
        if member_id == self.agent_id:
            return {
                "error": "不可移除自己",
                "hint": "如需退出请由你的直属 leader 调用 remove_member",
                "generated_at": self._now(),
            }

        # 权限闸 2：不可移除上级（leader 及其祖先）。团队树通过 parent_agent_id
        # 表达，沿链上溯即可判定；不可只比 leader_id——被移除对象的祖先可能
        # 更深，需逐级上溯。
        ancestors = self._ancestor_ids()
        if member_id in ancestors:
            return {
                "error": f"不可移除自己的上级: {member.get('name') or member_id}",
                "hint": "只能移除自己的直属/下级成员；上级由更上层 leader 管理",
                "generated_at": self._now(),
            }

        # 权限闸 3：目标必须是本 agent 的**后代**（不能移除兄弟/平级）。
        # 仅比对 ancestors 不够——平级成员既非自身也非祖先，会漏过。
        try:
            from data.team_store import collect_member_subtree

            subtree = collect_member_subtree(top_id, member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("收集成员子树失败(按单成员处理): %s", exc)
            subtree = [member_id]
        descendants = [mid for mid in subtree if mid != member_id]

        if member_id not in set(self._descendant_ids()):
            return {
                "error": f"不可移除非直属/下级成员: {member.get('name') or member_id}",
                "hint": "只能移除自己的下级；平级成员请由你们的共同 leader 处理",
                "generated_at": self._now(),
            }

        cascade = arguments.get("cascade")
        cascade = True if cascade is None else bool(cascade)
        if descendants and not cascade:
            return {
                "error": f"成员 {member.get('name') or member_id} 仍有 "
                         f"{len(descendants)} 个下级成员，未指定 cascade",
                "hint": "请显式传 cascade=true 连同下级子树一并移除，"
                        "或先逐个移除其下级（避免留下孤儿成员）",
                "cascade_required": descendants,
                "generated_at": self._now(),
            }

        removed_ids = descendants if cascade else []
        # 名单行：cascade 时一次删子树，否则只删自身
        persisted = True
        try:
            from data.team_store import remove_member, remove_member_subtree

            if cascade and descendants:
                deleted = remove_member_subtree(top_id, member_id)
                persisted = bool(deleted)
            else:
                persisted = remove_member(top_id, member_id)
        except Exception as exc:  # noqa: BLE001
            persisted = False
            logger.warning("移除成员名单记录失败 %s: %s", member_id, exc)

        # 运行时/存储级联清理（逐个容错）
        purge_ids = [member_id, *(descendants if cascade else [])]
        for mid in purge_ids:
            self._purge_member_runtime(mid)

        # 内存名单：剔除已移除的成员，否则本实例后续动作仍会看到幽灵成员
        removed_set = set(purge_ids)
        self.members = [
            m for m in self.members
            if str(m.get("id") or "") not in removed_set
        ]

        self._save_roster()
        pushed = self._push_roster_update()

        result = {
            "member_id": member_id,
            "name": member.get("name") or "",
            "level": member.get("level"),
            "removed_ids": purge_ids,
            "subtree_removed": descendants,
            "cascade": cascade,
            "persisted": persisted,
            "roster_pushed": pushed,
            "generated_at": self._now(),
        }
        if not persisted:
            result["hint"] = "名单删除失败，成员可能仍出现在 list_members 中，请重试"
        elif descendants:
            result["hint"] = (
                f"已连同 {len(descendants)} 个下级成员一并移除；"
                "其工作空间已回收，磁盘数据保留供审计"
            )
        return result

    def _descendant_ids(self) -> set:
        """收集本 agent 的全部后代成员 id（不含自身）。

        用于「只能移除自己的下级」这一权限判定：仅比对"是否祖先"不够，平级
        成员既非自身也非祖先，会漏过。
        """
        try:
            from data.team_store import collect_member_subtree

            ids = collect_member_subtree(self.team_id or self.agent_id, self.agent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("收集自身后代失败(权限校验收紧为空集): %s", exc)
            return set()
        return {str(mid) for mid in ids if mid and mid != self.agent_id}

    def _ancestor_ids(self) -> set:
        """沿 parent_agent_id 上溯收集自身全部上级 id（含直属 leader）。"""
        try:
            from data.team_store import get_members

            rows = get_members(self.team_id or self.agent_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取成员树失败(权限校验回退 leader_id): %s", exc)
            return {self.leader_id} if self.leader_id else set()

        parent_of = {
            str(r.get("id") or ""): str(r.get("parent_agent_id") or "")
            for r in rows
        }
        ancestors: set = set()
        if self.leader_id:
            ancestors.add(self.leader_id)
        cursor = parent_of.get(self.agent_id, "") or self.leader_id
        guard = 0
        while cursor and cursor not in ancestors and guard < 64:
            ancestors.add(cursor)
            cursor = parent_of.get(cursor, "")
            guard += 1
        return ancestors

    def _purge_member_runtime(self, member_id: str) -> None:
        """清理单个成员的全部运行时/存储残留（逐项容错，不向上抛）。"""
        if not member_id:
            return
        # 工作空间（Docker 不可用或容器不存在时静默忽略）
        if self.docker_manager is not None:
            try:
                self.docker_manager.remove_workspace(member_id)
            except Exception as exc:  # noqa: BLE001
                logger.warning("移除成员工作空间失败(已忽略) %s: %s", member_id, exc)
        # agents 行（该成员同时也是顶层 agent 记录时；成员通常无此行）
        try:
            from data.agent_store import delete_agent

            delete_agent(self.user_id, member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("移除成员 agents 行失败(已忽略) %s: %s", member_id, exc)
        # 会话缓存 / 持久化上下文
        try:
            from data.session_cache import clear_user_agent

            clear_user_agent(self.user_id, member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("清理成员会话缓存失败(已忽略) %s: %s", member_id, exc)
        try:
            from data.conversation_store import clear_context

            clear_context(self.user_id, member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("清理成员上下文失败(已忽略) %s: %s", member_id, exc)
        # broker 队列/worker 与限流器注册（防长跑下注册表膨胀）
        try:
            if self.broker is not None:
                self.broker.remove_agent(self.user_id, member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("移除成员 broker 注册失败(已忽略) %s: %s", member_id, exc)
        try:
            from llm.rate_limit import remove_agent as remove_limiter

            remove_limiter(self.user_id, member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("移除成员限流器注册失败(已忽略) %s: %s", member_id, exc)
        # 插件体系实例（agent / 会话级）
        try:
            from plugin import plugin_cascade

            plugin_cascade(self.user_id, agent_id=member_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("插件级联清理失败(已忽略) %s: %s", member_id, exc)

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
            # 模型变更会牵动审核状态：赋模型 → pending_review，清空 → pending_model；
            # 已审核结论（approved/rejected）在模型非空时保留。显式同步到
            # team_store，避免内存视图与库中状态不一致（list_members 读库、
            # 本条返回读内存）。
            from data.team_store import derive_review_status_for

            current_status = member.get("review_status") or ""
            if not model_id:
                new_status = derive_review_status_for("")
            elif current_status in ("approved", "rejected"):
                new_status = current_status
            else:
                new_status = derive_review_status_for(model_id)
            member["review_status"] = new_status
            sync_fields["review_status"] = new_status

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
    # review_member
    # ------------------------------------------------------------------
    def _action_review_member(self, arguments: dict) -> dict:
        """审核成员（approve / reject / 撤销），并可选一并赋模型。

        **权限边界（重要）**：新成员默认处于 ``pending_model`` /
        ``pending_review``，在用户审核通过（``approved``）之前不会接收也不会
        执行任何消息。审核权属于**用户**；本 action 存在是为了让用户在
        「团队成员 → 模型配置」页点过按钮后，由 agent 侧同步一次状态，
        **不得**在没有用户明确指示的情况下自行放行成员。
        """
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

        raw = arguments.get("review_status")
        if raw is None:
            approve = arguments.get("approve")
            approve = True if approve is None else bool(approve)
            raw = "approved" if approve else "rejected"
        model_id = arguments.get("model_id")

        from data.team_store import update_member_review_status

        try:
            row = update_member_review_status(
                self.team_id or self.agent_id,
                str(member.get("id") or ""),
                value=raw,
                model_id=model_id,
            )
        except ValueError as exc:
            return {
                "error": str(exc),
                "hint": "可用状态：approved（审核通过）/ rejected（驳回）/ "
                        "pending_review（待审核）",
                "generated_at": self._now(),
            }
        if row is None:
            return {"error": f"成员不存在: {target}", "generated_at": self._now()}

        # 内存视图与 roster 同步（list_members 读库，此处保持本实例一致）
        member["review_status"] = row.get("review_status", "")
        if model_id is not None:
            member["model_id"] = row.get("model_id", "")
        self._save_roster()
        pushed = self._push_roster_update()

        status = row.get("review_status", "")
        result = {
            "member_id": row.get("id", ""),
            "name": row.get("name", ""),
            "review_status": status,
            "model_id": row.get("model_id", ""),
            "roster_pushed": pushed,
            "generated_at": self._now(),
        }
        if status == "approved":
            result["hint"] = "该成员已可接收并执行消息"
        elif status == "pending_model":
            result["hint"] = (
                "该成员尚未分配模型，仍不可工作：请让用户在"
                "「团队成员 → 模型配置」页选择模型"
            )
        elif status == "pending_review":
            result["hint"] = "模型已分配但尚未审核通过，该成员仍不可工作"
        else:
            result["hint"] = "该成员已被驳回，不会接收任何消息"
        return result

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
