"""内置 set 工具 - 允许 LLM 设置自身运行参数。

提供 OpenAI function calling 格式的工具定义，支持设置：
- max_seqlen：上下文压缩时机（仅普通 LLM）
- temperature：采样温度（仅当 yaml 配置或通过本工具设置后才会下发）
- top_k：Top-K 采样（仅当 yaml 配置或通过本工具设置后才会下发）
- teammates：团队成员选择列表
"""

from typing import Any, Dict, List

from core.llm import AgentLLMSession

# 模型上下文长度上限默认值
_DEFAULT_CONTEXT_LIMIT: int = 8192


def _build_parameters_schema(
    include_max_seqlen: bool,
    include_temperature: bool,
    include_top_k: bool,
) -> Dict[str, Any]:
    """构建 set 工具的参数 schema。

    仅包含模型支持的参数：temperature / top_k 只有在对应模型的 yaml 中
    显式配置时才出现，否则 LLM 无法设置它们。

    :param include_max_seqlen: 是否包含 max_seqlen 参数（普通 LLM 包含，无限上下文 LLM 不包含）
    :param include_temperature: 是否包含 temperature 参数（模型 yaml 配置了才包含）
    :param include_top_k: 是否包含 top_k 参数（模型 yaml 配置了才包含）
    :return: JSON Schema 格式的参数定义
    """
    properties: Dict[str, Any] = {}

    if include_max_seqlen:
        properties["max_seqlen"] = {
            "type": "integer",
            "description": "决定上下文压缩时机，必须大于 0 且小于模型上下文长度上限",
            "exclusiveMinimum": 0,
        }

    if include_temperature:
        properties["temperature"] = {
            "type": "number",
            "description": "采样温度，范围 0.0-2.0",
            "minimum": 0.0,
            "maximum": 2.0,
        }

    if include_top_k:
        properties["top_k"] = {
            "type": "integer",
            "description": "Top-K 采样参数，范围 1-100",
            "minimum": 1,
            "maximum": 100,
        }

    properties["teammates"] = {
        "type": "array",
        "description": "团队成员选择列表，每项含 member_id 与 can_lead_team",
        "items": {
            "type": "object",
            "properties": {
                "member_id": {
                    "type": "string",
                    "description": "团队成员标识",
                },
                "can_lead_team": {
                    "type": "boolean",
                    "description": "该成员是否可以带队",
                },
            },
            "required": ["member_id", "can_lead_team"],
        },
    }

    return {
        "type": "object",
        "properties": properties,
        # 所有参数均为可选，LLM 可仅设置部分参数
        "required": [],
    }


class SetTool:
    """set 工具 - 允许 LLM 设置自身运行参数。

    根据 session.model_config.is_limitless_context 返回不同 schema：
    - 普通 LLM：包含 max_seqlen 参数
    - 无限上下文 LLM：不包含 max_seqlen 参数
    """

    def __init__(self, session: AgentLLMSession) -> None:
        """初始化 set 工具。

        :param session: AgentLLMSession 实例，参数将设置到该会话上
        """
        self.session = session
        # 初始化 teammates（若会话上尚未存在）
        if not hasattr(session, "teammates") or session.teammates is None:
            session.teammates = []

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。

        :return: ``{"type": "function", "function": {...}}`` 格式的工具定义字典
        """
        extra = self.session.model_config.extra
        include_max_seqlen = not self.session.model_config.is_limitless_context
        include_temperature = "temperature" in extra
        include_top_k = "top_k" in extra
        parameters = _build_parameters_schema(
            include_max_seqlen=include_max_seqlen,
            include_temperature=include_temperature,
            include_top_k=include_top_k,
        )
        return {
            "type": "function",
            "function": {
                "name": "set",
                "description": (
                    "设置 LLM 自身运行参数，包括采样温度、Top-K、"
                    "上下文压缩阈值（普通 LLM）、团队成员和 MCP 工具选择。"
                    "可仅设置部分参数，未提供的参数保持不变。"
                ),
                "parameters": parameters,
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行参数设置。

        对每个提供的参数进行校验后写入 session。校验失败时返回中文错误信息。

        :param arguments: 参数字典，键为参数名
        :return: 设置结果确认信息字典，成功含 ``updated`` 字段，失败含 ``error`` 字段
        """
        if not isinstance(arguments, dict):
            return {"success": False, "error": "参数必须是字典类型"}

        updated: Dict[str, Any] = {}

        # max_seqlen：仅普通 LLM 支持
        if "max_seqlen" in arguments:
            if self.session.model_config.is_limitless_context:
                return {"success": False, "error": "无限上下文 LLM 不支持设置 max_seqlen"}
            max_seqlen = arguments["max_seqlen"]
            # 校验为整数（排除 bool，bool 是 int 的子类）
            if not isinstance(max_seqlen, int) or isinstance(max_seqlen, bool):
                return {"success": False, "error": "max_seqlen 必须是整数"}
            # 校验 > 0 且 < 模型上下文上限
            context_limit = int(
                self.session.model_config.extra.get("max_seqlen", _DEFAULT_CONTEXT_LIMIT)
            )
            if max_seqlen <= 0:
                return {"success": False, "error": "max_seqlen 必须大于 0"}
            if max_seqlen >= context_limit:
                return {
                    "success": False,
                    "error": f"max_seqlen 必须小于模型上下文上限 {context_limit}",
                }
            self.session.max_seqlen = max_seqlen
            updated["max_seqlen"] = max_seqlen

        # temperature：仅当模型 yaml 配置了该参数时才允许设置
        if "temperature" in arguments:
            if "temperature" not in self.session.model_config.extra:
                return {"success": False, "error": "该模型未配置 temperature，不支持设置"}
            temperature = arguments["temperature"]
            if isinstance(temperature, bool) or not isinstance(temperature, (int, float)):
                return {"success": False, "error": "temperature 必须是数字"}
            temperature = float(temperature)
            if temperature < 0.0 or temperature > 2.0:
                return {"success": False, "error": "temperature 必须在 0.0-2.0 范围内"}
            # 设置后该值非 None，流式请求会自动下发 temperature
            self.session.temperature = temperature
            updated["temperature"] = temperature

        # top_k：仅当模型 yaml 配置了该参数时才允许设置
        if "top_k" in arguments:
            if "top_k" not in self.session.model_config.extra:
                return {"success": False, "error": "该模型未配置 top_k，不支持设置"}
            top_k = arguments["top_k"]
            if not isinstance(top_k, int) or isinstance(top_k, bool):
                return {"success": False, "error": "top_k 必须是整数"}
            if top_k < 1 or top_k > 100:
                return {"success": False, "error": "top_k 必须在 1-100 范围内"}
            # 设置后该值非 None，流式请求会自动经 extra_body 下发 top_k
            self.session.top_k = top_k
            updated["top_k"] = top_k

        # teammates：保存到 session.teammates
        if "teammates" in arguments:
            teammates = arguments["teammates"]
            if not isinstance(teammates, list):
                return {"success": False, "error": "teammates 必须是数组"}
            # 校验每个成员项的结构
            for idx, member in enumerate(teammates):
                if not isinstance(member, dict):
                    return {"success": False, "error": f"teammates[{idx}] 必须是对象"}
                if "member_id" not in member or not isinstance(member["member_id"], str):
                    return {
                        "success": False,
                        "error": f"teammates[{idx}].member_id 必须是字符串",
                    }
                if "can_lead_team" not in member or not isinstance(
                    member["can_lead_team"], bool
                ):
                    return {
                        "success": False,
                        "error": f"teammates[{idx}].can_lead_team 必须是布尔值",
                    }
            self.session.teammates = teammates
            updated["teammates"] = teammates

        return {
            "success": True,
            "message": "参数设置成功",
            "updated": updated,
        }

    def get_teammates_summary(self) -> str:
        """返回当前 teammates 配置的摘要文本。

        摘要包含每个成员的 ID 和 can_lead_team 状态。

        :return: 摘要文本
        """
        teammates = getattr(self.session, "teammates", [])
        if not teammates:
            return "当前未配置团队成员。"

        lines: List[str] = [f"当前团队成员配置（共 {len(teammates)} 人）:"]
        for member in teammates:
            member_id = member.get("member_id", "未知")
            can_lead = member.get("can_lead_team", False)
            lead_status = "可带队" if can_lead else "不可带队"
            lines.append(f"- {member_id}: {lead_status}")
        return "\n".join(lines)


def get_set_recommendation(session: AgentLLMSession) -> str:
    """返回新任务开始时的 set 工具推荐提示文本。

    根据 session.model_config 决定推荐内容：
    - 无限上下文 LLM 不含 max_seqlen
    - temperature / top_k 仅在模型 yaml 配置时才推荐

    :param session: AgentLLMSession 实例
    :return: 推荐提示文本
    """
    extra = session.model_config.extra
    lines: List[str] = ["【参数配置建议】", "建议在新任务开始时调用 set 工具配置运行参数，包括："]
    if not session.model_config.is_limitless_context:
        lines.append(
            "- max_seqlen: 上下文压缩阈值（必须大于 0 且小于模型上下文上限）"
        )
    if "temperature" in extra:
        lines.append("- temperature: 采样温度（0.0-2.0）")
    if "top_k" in extra:
        lines.append("- top_k: Top-K 采样参数（1-100）")
    lines.append("- teammates: 团队成员选择列表（每项含 member_id 与 can_lead_team）")
    lines.append("请根据当前任务需求设置合适的参数。")
    return "\n".join(lines)
