"""内置 help 工具 - 列出所有可用的内置工具及 MCP 工具。"""

import logging

from core.config import get_config

logger = logging.getLogger(__name__)


class HelpTool:
    """内置 help 工具。

    列出所有已注册的内置工具及其描述，同时包含当前可用的 MCP 工具列表。
    """

    def __init__(
        self,
        registered_tools: list[dict] = None,
        mcp_manager: "MCPManager" = None,
        session: "AgentLLMSession" = None,
        team_tool: "TeamTool" = None,
        workspace_extra_info: dict = None,
        refresh_extra_info: "Callable[[], dict]" = None,
    ) -> None:
        """初始化 help 工具。

        :param registered_tools: 已注册的工具定义列表，每项为 OpenAI function
            calling 格式的工具定义（或包含 ``definition`` 字段的注册项）
        :param mcp_manager: MCP 管理器实例，用于动态获取当前可用 MCP 工具；
            为 None 时退化为使用 ``mcp_tools`` 快照
        :param session: AgentLLMSession 实例，用于读取当前 agent 的身份/模型
            信息（名称、普通/无限上下文、上下文阈值等）
        :param team_tool: TeamTool 实例，用于读取当前 agent 的层级、是否可创建
            团队以及现有团队成员规模
        :param workspace_extra_info: 工作空间额外信息字典，包含身份、rule.md、
            存储告警等，由系统提示词构建时预先计算，help 工具统一透露
        :param refresh_extra_info: 可选回调，每次执行 help 时重新计算
            workspace_extra_info（现读 .self 文件）。memory.md 每次记忆维护
            都会更新，快照会过期，提供该回调可保证 help 输出始终最新；
            无回调时使用构造时快照。
        """
        self.registered_tools: list[dict] = (
            registered_tools if registered_tools is not None else []
        )
        self.mcp_manager = mcp_manager
        self.session = session
        self.team_tool = team_tool
        self.workspace_extra_info = workspace_extra_info or {}
        self.refresh_extra_info = refresh_extra_info
        # 当前可用的 MCP 工具列表快照（无 mcp_manager 时的兜底，由 set_mcp_tools 注入）
        self.mcp_tools: list[dict] = []

    def get_tool_definition(self) -> dict:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "help",
                "description": "列出所有可用的内置工具及其介绍",
                "parameters": {
                    "type": "object",
                    "properties": {},
                },
            },
        }

    def set_mcp_tools(self, mcp_tools: list[dict]) -> None:
        """设置当前可用的 MCP 工具列表。

        :param mcp_tools: MCP 工具列表，每项包含 name 与 description
        """
        self.mcp_tools = mcp_tools if mcp_tools is not None else []

    @staticmethod
    def _extract_name_desc(tool: dict) -> tuple[str, str]:
        """从工具定义中提取 name 与 description，兼容多种注册格式。

        支持以下格式：
        - ``{"definition": {"type": "function", "function": {"name":..., "description":...}}}``
          （llm.py 中 registered_tools 的注册项）
        - ``{"type": "function", "function": {"name":..., "description":...}}``
          （原始 OpenAI function calling 工具定义）
        - ``{"name":..., "description":...}``（扁平结构）
        """
        # 格式1: llm.py 中 registered_tools 的注册项
        if "definition" in tool:
            func = tool["definition"].get("function", {}) or {}
            return func.get("name", ""), func.get("description", "")
        # 格式2: 原始 OpenAI function calling 工具定义
        if "function" in tool:
            func = tool["function"] or {}
            return func.get("name", ""), func.get("description", "")
        # 格式3: 扁平结构
        return tool.get("name", ""), tool.get("description", "")

    @staticmethod
    def _resolve_config_path(config: dict, path: str):
        """按点号分隔路径读取配置值（如 ``docker.resource_limits.cpu``）。

        任意一级不存在时返回 None。
        """
        cur = config
        for part in path.split("."):
            if isinstance(cur, dict):
                cur = cur.get(part)
            else:
                return None
        return cur

    def _get_policy_lines(self) -> list[str]:
        """读取 ``help_policy`` 配置段，动态解析各限制项的当前值。

        值来源于 agents/docker 等源配置，随配置变化自动更新，不在此硬编码。
        """
        lines: list[str] = []
        try:
            policy = get_config().get("help_policy", []) or []
        except Exception:  # noqa: BLE001
            return lines
        for item in policy:
            name = item.get("name", "")
            path = item.get("path", "")
            value = self._resolve_config_path(get_config(), path)
            if name:
                shown = value if value is not None else "未配置"
                lines.append(f"- {name}: {shown}")
        return lines

    def execute(self, arguments: dict) -> dict:
        """执行 help 命令，返回按四大板块组织的工具/机制说明。

        本工具的核心宗旨是提供推理（CoT）的原材料而非现成的工作流：说明
        agent 框架提供的机制、工具与期望，由模型自主决定如何组合运用，
        不做过度流程化约束。

        :param arguments: 工具参数（help 工具无参数）
        :return: 包含格式化说明文档字符串的字典
        """
        # 注意：此处不自动刷新 workspace_extra_info。help 块作为历史消息留在
        # 上下文中，若每次执行都改变内容，会破坏前缀稳定性、频繁失效 KV 缓存。
        # 刷新统一在 compact 触发上下文重构时进行（render_fresh_content），
        # 此时整个前缀必然重排，刷新零额外成本。
        sections: list[str] = [
            self._build_identity_section(),
            self._build_workspace_info_section(),
            self._build_tool_mechanism_section(),
            self._build_system_mechanism_section(),
            self._build_user_expectation_section(),
            self._build_available_tools_section(),
        ]
        content = "\n\n".join(sections)
        logger.info(
            "help 工具执行完成, 内置工具 %d 个, MCP 工具 %d 个",
            len(self.registered_tools),
            len(self._get_mcp_tools()),
        )
        return {"content": content}

    def render_fresh_content(self) -> str:
        """刷新工作空间额外信息并重新渲染 help 内容。

        专供 compact 触发上下文重构时调用（此时整个前缀必然重排，刷新 help
        块不产生额外缓存失效）。平时 help 执行走 execute()，使用当前快照，
        保持前缀稳定、利于 KV 缓存命中。

        :return: 最新 help 渲染文本
        """
        if self.refresh_extra_info is not None:
            try:
                fresh = self.refresh_extra_info()
                if fresh:
                    self.workspace_extra_info = fresh
            except Exception as exc:  # noqa: BLE001
                logger.warning("刷新 workspace_extra_info 失败，沿用快照: %s", exc)
        return self.execute({}).get("content", "")

    # ------------------------------------------------------------------
    # 一、身份介绍
    # ------------------------------------------------------------------
    def _agent_name(self) -> str:
        """当前 agent 的名称。"""
        if self.session is not None:
            return getattr(self.session, "agent_name", "") or "AI agent"
        return "AI agent"

    def _model_label(self) -> str:
        """当前 agent 所驱动模型的标识（模型名 + 上下文类型）。"""
        if self.session is None or self.session.model_config is None:
            return "Large language model"
        cfg = self.session.model_config
        model_id = getattr(cfg, "model_id", "") or getattr(cfg, "name", "") or ""
        if getattr(cfg, "is_limitless_context", False):
            return f"{model_id or 'LLM'}（无限上下文）".strip()
        return model_id or "LLM"

    def _build_identity_section(self) -> str:
        """构建"身份介绍"板块。"""
        name = self._agent_name()
        model_label = self._model_label()

        # 团队位置：层级 + 是否可带队 + 是否已拥有团队
        if self.team_tool is not None:
            level = int(getattr(self.team_tool, "level", 0) or 0)
            can_lead = bool(getattr(self.team_tool, "can_lead_team", True))
            member_count = len(getattr(self.team_tool, "members", []) or [])
        else:
            level = 0
            can_lead = True
            member_count = 0

        if level == 0:
            position = "你是顶层 Agent（Level 0），直属用户。"
        else:
            position = f"你是团队成员（Level {level}）。"

        if can_lead and member_count > 0:
            lead_desc = f"你有权创建并带领子团队，当前已指挥 {member_count} 名成员。"
        elif can_lead:
            lead_desc = "你有权创建并带领子团队，目前尚未创建成员。"
        else:
            lead_desc = "你当前不可创建子团队（can_lead_team=False），聚焦完成分派的任务。"

        identity = (
            f"你是 {name}，由 {model_label} 驱动。{position}{lead_desc}"
        )

        # 知识卡片：关于你这类模型的自我认知（供自主决策的元认知材料）
        knowledge = (
            "知识卡片：你属于 AI agent，由 Large language model（一类通过深度学习"
            "算法构建的文本因果预测模型）驱动，通过 tool call 操作系统完成各种复杂"
            "任务。你这类模型使用标准注意力机制，擅长长程精确语义召回，但也容易发生"
            "注意力稀释而 lost in the middle。你的深层网络使你拥有非常强大的知觉与"
            "高维预测能力。通常来说，你自己的输出最符合你的数据分布，能够获得更好"
            "的召回结果。据此你可以自主判断：何时该依赖自身推理，何时该通过工具/"
            "查询获取外部事实，以及如何在长任务中主动管理自己的注意力与上下文。"
        )
        return "\n".join(["# 一、身份介绍", "", identity, "", knowledge])

    # ------------------------------------------------------------------
    # 二、工作空间信息（身份、rule.md、存储告警等）
    # ------------------------------------------------------------------
    def _build_workspace_info_section(self) -> str:
        """构建"工作空间信息"板块：从 workspace_extra_info 读取身份、rule.md 等。"""
        info = self.workspace_extra_info
        if not info:
            return ""

        lines = ["# 二、工作空间信息", ""]

        # 身份（来自 identity.md 或默认）
        identity = info.get("identity", "")
        if identity:
            lines.append(f"## 你的身份\n{identity}")
            lines.append("")

        # 成员专属提示词
        member_prompt = info.get("member_system_prompt", "")
        if member_prompt:
            lines.append(f"## 成员职责补充\n{member_prompt}")
            lines.append("")

        # rule.md
        rule = info.get("rule", "")
        if rule:
            lines.append(f"## 工作准则 (rule.md)\n{rule}")
            lines.append("")

        # memory.md（记忆档案：任务目标/关键决策/结论/待办；超限时已压缩）
        memory = info.get("memory", "")
        if memory:
            lines.append(f"## 记忆档案 (memory.md)\n{memory}")
            lines.append("")

        # 存储告警
        warning = info.get("storage_warning", "")
        if warning:
            lines.append(f"## 存储告警\n{warning}")
            lines.append("")

        return "\n".join(lines).rstrip()

    # ------------------------------------------------------------------
    # 三、工具机制
    # ------------------------------------------------------------------
    def _build_tool_mechanism_section(self) -> str:
        """构建"工具机制"板块：逐一说明内置工具的机制与作用。"""
        model_type = (
            "无限上下文" if (self.session and getattr(
                self.session.model_config, "is_limitless_context", False)) else "普通"
        )
        is_limitless = model_type == "无限上下文"

        lines = ["# 三、工具机制", ""]
        lines.append(
            "以下是你能调用的内置工具及其机制。它们给出的是“机制”而非"
            "“规定动作”，请你结合任务自主决定如何组合。"
        )

        # ---- 1. set ----
        set_block = (
            "只更新你显式提供的参数，未提供的保持不变。temperature/top_k 仅在当前"
            f"模型支持时才可设置（当前为{model_type} LLM，"
            + ("无限上下文 LLM 不支持 max_seqlen。" if is_limitless
               else "普通 LLM 可设置 max_seqlen。")
            + "）建议在新任务开始时按任务性质先配置一次。"
        )
        lines += [
            "## 1. set —— 设置自身运行参数",
            "### (a) 参数与作用",
            "- max_seqlen（仅普通 LLM）：上下文压缩触发阈值。当上下文总 token "
            "接近该值的 80% 时自动压缩，避免溢出。它决定你“何时开始遗忘并总结”。",
            "- temperature：采样温度（0.0-2.0）。越低越确定/保守，越高越多样/发散。",
            "- top_k：Top-K 采样（1-100）。限制每步从概率最高的 K 个词中采样。",
            "- teammates：团队成员选择列表，每项含 member_id 与 can_lead_team。"
            "用于声明你的协作对象及其是否可带队。",
            "### (b) 机制",
            set_block,
        ]

        # ---- 2. refresh ----
        lines += [
            "## 2. refresh —— 刷新 MCP 工具清单",
            "### (a) 机制",
            "强制重新连接各已注册的 MCP 服务，拉取最新工具列表并更新缓存，"
            "返回每个工具的 name/description/parameters。",
            "### (b) 作用",
            "在会话开始、新增 MCP 服务或怀疑工具列表过期时，用它获取当前可调用的"
            "全部 MCP 工具全貌，是了解“我能做什么”的入口。",
        ]

        # ---- 3. ask_user_question ----
        lines += [
            "## 3. ask_user_question —— 向用户提问",
            "### (a) 机制",
            "通过 WebSocket 向前端推送一张“待回答问题”卡片，随后阻塞等待用户在"
            "界面上选择或输入；得到答案后作为工具结果写回你的上下文（等价于用户"
            "插话）。可提供 options 供快速选择，可提供 default_answer 用于用户"
            "超时未答时兜底。",
            "### (b) 作用",
            "当任务信息不完整、需要用户决策、澄清或提供额外输入时，主动向用户提问"
            "以获取关键约束，而不是在信息缺失下盲目推进。",
        ]

        # ---- 4. mcp ----
        lines += [
            "## 4. mcp —— 调用 MCP 工具",
            "### (a) 机制",
            "通过 MCPManager 以 stdio 方式连接各 MCP 服务（含绑定到当前 agent "
            "工作空间的 workspace 服务）。action=help 列出可用 MCP 工具，"
            "action=call 传入 tool_name 与 arguments 执行具体工具。",
            "### (b) 作用",
            "在工作空间沙箱内执行底层操作，例如 read/write/edit（文件读写编辑）、"
            "terminal（沙箱命令执行）、embed_search（工作空间语义搜索）等，是实现"
            "实际文件与系统操作的主要通道。",
        ]

        # ---- 5. team ----
        lines += [
            "## 5. team —— 团队协作管理",
            "### (a) 机制",
            "覆盖成员管理、消息管理、任务管理三个子域。团队成员有层级（顶层为 "
            "Level 0，最深受配置约束），can_lead_team=False 的成员不可再创建子团队。"
            "成员管理表持久化到工作空间 .self/team_roster.md；消息与任务在内存维护。",
            "### (b) 作用",
            "- 成员管理：list_models / create_member / list_members / query_member "
            "/ update_member / query_status / view_member_output / view_member_log，"
            "以及多维评分（质量/效率/协作/准确性）。",
            "- 消息管理：send_message（点对点/一对多）/ broadcast（广播）。",
            "- 任务管理：assign_task / query_tasks / wait_for，成员完成后经 Git 提交并汇报。"
            " wait_for 可等待一个或多个成员完成当前任务，支持 timeout 超时参数。",
        ]
        return "\n".join(lines)

    # ------------------------------------------------------------------
    # 四、系统机制
    # ------------------------------------------------------------------
    def _build_system_mechanism_section(self) -> str:
        """构建"系统机制"板块：上下文、工作区沙箱、消息收发。"""
        is_limitless = bool(
            self.session and getattr(
                self.session.model_config, "is_limitless_context", False)
        )
        max_seqlen = None
        if self.session is not None:
            max_seqlen = getattr(self.session, "max_seqlen", None)
            if max_seqlen is None:
                cfg = getattr(self.session, "model_config", None)
                if cfg is not None:
                    max_seqlen = cfg.extra.get("max_seqlen")

        lines = ["# 四、系统机制", ""]

        # ---- compact 机制 ----
        if is_limitless:
            compact = (
                "你属于无限上下文 LLM：上下文不进行压缩，采用原子追加方式持久化，"
                "并要求前后输入保持精确前缀一致性。因此请避免对历史上下文做破坏性"
                "改动，专注连续推进任务。"
            )
        else:
            threshold = (
                f"（max_seqlen={max_seqlen}，达到其 80% 触发）" if max_seqlen
                else "（达到 max_seqlen 的 80% 触发）"
            )
            compact = (
                "当上下文总 token 接近上下文阈值时自动压缩" + threshold + "。压缩时"
                "保留系统提示词与你最近几次的用户要求原文，把更早的历史交给 LLM "
                "总结成一条 summary 消息，从而在长任务中保持对最新目标的聚焦、"
                "避免注意力稀释与 lost in the middle。你也可通过手动 compact 强制"
                "压缩。压缩后仍会保留关键事实与当前任务上下文。"
            )
        lines += ["## 1. compact 机制", compact, ""]

        # ---- 工作区与沙箱机制 ----
        policy_lines = self._get_policy_lines()
        resource_block = ""
        if policy_lines:
            resource_block = "\n".join(["（当前资源限制）"] + list(policy_lines))
        workspace = (
            "团队协作采用共享主工作区：同一顶层 agent 及其团队成员共享同一个"
            "工作空间（云端模式下共享顶层 agent 的 Docker 容器 /workspace，本地"
            "模式下共享用户选择的工作目录 <baseDir>），全队在同一份项目文件中读写"
            "执行、协同工作；而每个 agent 的私人记忆文件（.self/memory.md、"
            ".self/rule.md、.self/team_roster.md、.self/activity.log 等）分别"
            "存放在各自的私人空间（云端 workspaces/agent_<id>/.self，本地 "
            "<baseDir>/workspaces/agent_<id>/.self），与共享主工作区隔离、互不"
            "泄露。你通过 MCP 的 workspace 服务读写文件、执行命令、语义搜索。工作"
            "过程由内置 Git 仓库跟踪，每次阶段性成果建议提交，便于回溯与汇报；父"
            " agent 可通过 view_member_output/query_status 查看你的产出与提交。"
            "沙箱受到资源与网络限制（白名单出站、下载上限、存储软上限），请据此"
            "控制产出规模与下载行为。\n"
            + resource_block
        )
        lines += ["## 2. 工作区与沙箱机制", workspace, ""]

        # ---- 本地运行机制 ----
        local_mode = (
            "后端默认运行在云端服务器（Docker 沙箱）中。对于拥有较好设备的开发者，"
            "可通过前端消息窗口左上角的电源开关将运行模式切换为本地执行：后端仍在"
            "云端运行，但工具调用环境转移到用户本机——read/write/terminal/"
            "embed_search 等工具直接在用户选择的工作目录中执行，经反向 WebSocket "
            "把结果回传后端。\n"
            "本地执行模式按顶部 agent 单独控制：每个顶部 agent 可分别处于本地或"
            "云端模式，互不影响；开启时需选择该顶部 agent 的本机工作目录，开关与"
            "工作目录均按 agent 持久化，重启后依然生效。你（以及同属该顶部 agent "
            "的团队成员）的工具调用都跟随所属顶部 agent 的模式。\n"
            "协同语义：本地模式下，你与同属该顶部 agent 的所有成员的工具调用都在"
            "同一工作目录 <baseDir>（用户选择的目录）中读写执行，全队共享同一份"
            "项目文件以协同工作；而每个 agent 的私人记忆文件（如 .self/memory.md、"
            ".self/rule.md、.self/team_roster.md）分别存放在各自的私人空间 "
            "<baseDir>/workspaces/agent_<id>/.self 中，与共享工作目录隔离、互不"
            "泄露。\n"
            "重要约束：运行模式在对话开始（用户向该顶部 agent 发送首条消息）后即"
            "锁定，无法再切换——后端会话自此绑定本地/云端工具。因此在对话开始前"
            "就应确定模式；如需变更，只能在尚未对话的新对话上先切换再开始。"
            "此模式适合在用户自己的项目上直接开发调试；切换回云端模式后，工具调用"
            "恢复到云端共享主工作区（顶层 agent 的 Docker 沙箱）执行。"
        )
        lines += ["## 3. 本地执行模式", local_mode, ""]

        # ---- 消息收发机制 ----
        message = (
            "用户消息与团队成员消息通过消息投递器串行消费：你在工作中时，新消息会在"
            "工具调用间隙切入；空闲时立即处理。你（作为 leader）可通过 team 工具的 "
            "send_message/broadcast/assign_task 向成员投递消息与任务，成员"
            "异步串行处理并在完成后通过 Git 提交与汇报回传结果（结果以摘要形式注入"
            "你的上下文，而非完整日志）。你也可以通过 ask_user_question 主动向用户"
            "提问并等待回答。跨 agent 的消息/文件经各自的沙箱边界与团队机制流转。"
        )
        lines += ["## 4. 消息收发机制", message, ""]

        # ---- 5. 预算控制机制 ----
        budget = (
            "API 预算控制机制用于管理 LLM 调用成本：\n"
            "- 预算设置：顶层 agent 可设置独立预算（美元），其下属 teammates "
            "共享该顶层 agent 的预算。\n"
            "- 用量重置：每次用户向顶层 agent 发送消息时，API 用量计数器自动重置。\n"
            "- 消耗提醒：预算每消耗 10% 会收到一条系统告警提示（含当前用量与剩余预算），"
            "预算耗尽时需立即停止非关键 API 调用。\n"
            "- 工具结果注入：每次工具调用返回都会附带当前预算摘要（输入/输出/缓存 token "
            "消耗及剩余预算），供你根据剩余配额合理规划后续工作流。\n"
            "- 状态查询：可通过 GET /api/budget/{agent_id} 查询当前预算状态。\n"
            "建议在预算消耗 50% 前完成核心任务，预留余量用于后续调整与验证。"
        )
        lines += ["## 5. 预算控制机制", budget]
        return "\n".join(lines)

    # ------------------------------------------------------------------
    # 五、用户期望
    # ------------------------------------------------------------------
    @staticmethod
    def _build_user_expectation_section() -> str:
        """构建"用户期望"板块：用户对 agent 的核心诉求，作为价值取向材料。"""
        lines = [
            "# 五、用户期望",
            "用户对你的核心诉求，可据此校准你的工作取向与取舍：",
            "",
            "## 1. 效率",
            "尽快完成任务：善用并行、优先调用既有工具与团队成员分工，避免无谓的"
            "重复与空转，减少来回试探。",
            "",
            "## 2. 质量",
            "产出准确、可验证、符合规范：关键结论要有依据，工作成果尽量可追溯"
            "（如 Git 提交），并在交付时给出清晰总结。",
            "",
            "## 3. 成本（预算）",
            "控制资源与调用开销：合理规划工作流，在预算消耗 50% 前完成核心任务。"
            "善用工具结果中的预算摘要信息，根据剩余配额动态调整工作策略。"
            "合理管理上下文（及时压缩/选择性保留）、避免对昂贵或重模型的无谓调用、"
            "控制沙箱内下载与存储规模。",
            "",
            "## 4. 协作体验",
            "透明、主动、清晰的协作：明确自身身份与职责，重要决策及时同步或提问，"
            "对团队成员合理分派任务并跟进状态，让协作过程可被理解与追踪。"
            "学会打磨 rule.md，提升用户与团队成员间的协作体验",
        ]
        return "\n".join(lines)

    # ------------------------------------------------------------------
    # 附：当前可用工具清单（动态）
    # ------------------------------------------------------------------
    def _build_available_tools_section(self) -> str:
        """构建"当前可用工具"附录，供实际调用参考（动态获取，避免硬编码）。"""
        lines = ["# 附：当前可用工具清单", ""]

        lines.append("## 内置工具")
        for tool in self.registered_tools:
            name, desc = self._extract_name_desc(tool)
            if name:
                lines.append(f"- {name}: {desc}" if desc else f"- {name}")

        lines.append("")
        lines.append("## MCP 工具")
        mcp_tools = self._get_mcp_tools()
        if mcp_tools:
            for tool in mcp_tools:
                name = tool.get("name", "")
                desc = tool.get("description", "")
                if name:
                    lines.append(f"- {name}: {desc}" if desc else f"- {name}")
        else:
            lines.append("（暂无，可先调用 refresh 刷新）")

        lines.append("")
        lines.append("提示：如需了解某工具的参数细节，直接按其定义调用即可；"
                     "MCP 工具可先 refresh 后 mcp(action=help) 查看。")
        return "\n".join(lines)

    def _get_mcp_tools(self) -> list[dict]:
        """获取当前可用 MCP 工具列表。

        优先从 mcp_manager 动态获取（走工具缓存，不强制刷新）；
        无 mcp_manager 时回退到 mcp_tools 快照。
        """
        if self.mcp_manager is not None:
            try:
                return self.mcp_manager.get_tools() or []
            except Exception as exc:  # noqa: BLE001
                logger.warning("获取 MCP 工具列表失败: %s", exc)
                return []
        return list(self.mcp_tools)
