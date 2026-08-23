"""集中式、版本化、可审计的企业级提示词体系。

本包将系统提示词 / 工具提示词 / Spec 规范 / LLM 辅助提示词统一纳入版本
管理，作为整套提示词层级（prompt hierarchy）的单一事实来源：

- :mod:`prompt.registry` —— 全局版本号、变更记录与章节审计清单；
- :mod:`prompt.system_chapters` —— 系统提示词静态章节数据（版本化）；
- :mod:`prompt.llm_prompts` —— 上下文压缩器等 LLM 辅助提示词；
- :mod:`prompt.tool_protocol` —— 工具描述结构化模板与版本清单；
- :mod:`prompt.schema` —— 提示词产物类型定义。

用法：``from prompt import PROMPT_VERSION, audit_header`` 等。
"""

from .registry import (
    PROMPT_VERSION,
    TOOL_TEMPLATE_VERSION,
    COMPRESSOR_VERSION,
    SYSTEM_PROMPT_CHANGELOG,
    audit_header,
    chapter_manifest,
)
from .schema import Chapter
from . import system_chapters, llm_prompts, tool_protocol  # noqa: F401

__version__ = PROMPT_VERSION

__all__ = [
    "PROMPT_VERSION",
    "TOOL_TEMPLATE_VERSION",
    "COMPRESSOR_VERSION",
    "SYSTEM_PROMPT_CHANGELOG",
    "audit_header",
    "chapter_manifest",
    "Chapter",
    "system_chapters",
    "llm_prompts",
    "tool_protocol",
]