"""工具提示词协议（版本化、结构化模板 + 审计清单）。

内置工具与 MCP 工具的提示词（``description``）统一采用结构化模板：

    ``[工具名] | 贡献维度: ...``
    ``何时使用: ...``
    ``何时不用: ...``
    ``前置依赖: ...``

本模块提供：
- :func:`describe`：按模板渲染工具描述，保证所有工具措辞/结构一致；
- ``TOOL_MANIFEST``：各工具描述版本与用途登记（审计、可追溯）——
  描述**版本号不注入模型可见文本**（避免污染模型输入并增加 token 开销），
  仅存在于审计清单，供运维/回滚参考。

改写工具描述后需同步递增 ``TOOL_MANIFEST`` 中对应条目版本号。
"""

from typing import Dict, List, Optional

from .registry import TOOL_TEMPLATE_VERSION

# 当前结构化模板版本（所有工具描述共用）
__all__ = ["describe", "TOOL_TEMPLATE_VERSION", "TOOL_MANIFEST", "mcp_tool_description"]


def describe(
    name: str,
    contribution: str,
    when_use: str,
    when_not: str = "",
    prereq: str = "",
    actions: str = "",
) -> str:
    """按统一模板渲染工具描述。

    :param name: 工具名（方括号标题）
    :param contribution: 贡献维度（服务端所有需求维度之一，库里可选）
    :param when_use: 何时使用
    :param when_not: 何时不用（可选）
    :param prereq: 前置依赖（可选）
    :param actions: 动作枚举（可选；如 set/update 等子动作）
    :return: 结构化的工具描述字符串
    """
    parts: List[str] = [f"[{name}] | 贡献维度: {contribution}"]
    for label, val in (
        ("何时使用", when_use),
        ("何时不用", when_not),
        ("前置依赖", prereq),
        ("动作", actions),
    ):
        stripped = (val or "").strip()
        if stripped:
            parts.append(f"{label}: {stripped}")
    return "\n".join(parts)


def mcp_tool_description(
    name: str,
    contribution: str,
    when_use: str,
    when_not: str = "",
    prereq: str = "",
) -> str:
    """MCP 工具描述的简写别名（默认无语义拆分动作）。"""
    return describe(name, contribution, when_use, when_not, prereq)


# ---------------------------------------------------------------------------
# 工具描述版本清单（audit；版本号不注入模型可见文本）
# ---------------------------------------------------------------------------

TOOL_MANIFEST: Dict[str, Dict[str, object]] = {
    # 内置工具
    "read": {"version": 1, "purpose": "读取工作空间文件/图像，先证后断的前提"},
    "write": {"version": 1, "purpose": "新建/整写文件，自动创建父目录"},
    "edit": {"version": 1, "purpose": "对已有文件做唯一匹配的精确字符串替换"},
    "terminal": {"version": 1, "purpose": "执行 shell 命令（构建/测试/git/文件操作）"},
    "mcp": {"version": 1, "purpose": "调用外部/工作空间 MCP 能力（文档/搜索/三方服务）"},
    "team": {"version": 1, "purpose": "团队成员协作：派发/回收/进度/拓扑"},
    "set_todo_list": {"version": 1, "purpose": "任务分解与进度跟踪（set/update/clear/get）"},
    "ask_user_question": {"version": 1, "purpose": "向用户提问澄清/决策/高危确认（非阻塞）"},
    "spec": {"version": 1, "purpose": "任务型规范检索/选择/读取/沉淀"},
    # MCP 工作空间 / 文档
    "embed_search": {"version": 1, "purpose": "工作空间向量/文本搜索"},
    "read_pdf": {"version": 1, "purpose": "解析 PDF 提取文本"},
    "read_docx": {"version": 1, "purpose": "解析 DOCX 提取段落与表格"},
    "read_pptx": {"version": 1, "purpose": "解析 PPTX 提取幻灯片文本"},
    "read_xlsx": {"version": 1, "purpose": "解析 XLSX 提取工作表数据"},
    "create_docx": {"version": 1, "purpose": "由文本生成 DOCX"},
    "create_pptx": {"version": 1, "purpose": "由 JSON 生成 PPTX"},
    "create_xlsx": {"version": 1, "purpose": "由 JSON 数据生成 XLSX"},
}