"""集中式、版本化、可审计的企业级提示词体系。

本包将系统提示词 / 工具提示词 / Spec 规范 / LLM 辅助提示词统一纳入版本
管理，作为整套提示词层级（prompt hierarchy）的单一事实来源。**版本内容
作为数据存放于 ``versions/<version>/`` 目录**，与代码解耦；运行期激活哪个
版本由 ``app.yaml`` 的 ``prompt.version`` 决定（见 :mod:`prompt.versions`）。

- :mod:`prompt.registry` —— 版本常量基线 + 审计工具（audit_header/chapter_manifest）；
- :mod:`prompt.versions` —— 版本选择层（读配置 → 激活版本，缓存，fail-fast）；
- :mod:`prompt.loader` —— 版本数据目录加载器（章节/压缩器/工具描述解析）；
- :mod:`prompt.llm_prompts` —— 上下文压缩器等 LLM 辅助提示词（v1.0.0 基线）；
- :mod:`prompt.tool_protocol` —— 工具描述结构化模板与版本清单；
- :mod:`prompt.schema` —— 提示词产物类型定义。

用法：``from prompt import versions`` / ``from prompt.registry import audit_header``。
"""

from .registry import (
    PROMPT_VERSION,
    TOOL_TEMPLATE_VERSION,
    COMPRESSOR_VERSION,
    SYSTEM_PROMPT_CHANGELOG,
    audit_header,
    chapter_manifest,
)
from .schema import Chapter, PromptVersion
from . import loader, llm_prompts, tool_protocol, versions  # noqa: F401

__version__ = PROMPT_VERSION

__all__ = [
    "PROMPT_VERSION",
    "TOOL_TEMPLATE_VERSION",
    "COMPRESSOR_VERSION",
    "SYSTEM_PROMPT_CHANGELOG",
    "audit_header",
    "chapter_manifest",
    "Chapter",
    "PromptVersion",
    "loader",
    "versions",
    "llm_prompts",
    "tool_protocol",
]