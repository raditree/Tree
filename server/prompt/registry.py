"""提示词注册表：全局版本号 + 章节审计清单 + 版本变更记录。

统一管理整套提示词体系的版本与可审计性：
- ``PROMPT_VERSION``：系统提示词体系当前版本（语义化版本，字符串）。
- ``TOOL_TEMPLATE_VERSION``：内置 / MCP 工具描述统一模板版本（整数）。
- ``COMPRESSOR_VERSION``：上下文压缩器提示词版本（整数，llm.py 使用）。
- ``SYSTEM_PROMPT_CHANGELOG``：系统提示词版本变更记录（audit），用于追溯
  各版本改了什么、为何改。

章节数据本身见 :mod:`prompt.system_chapters`，避免本模块与章节数据互相
依赖（仅在需要生成审计清单时惰性 import，切断循环依赖）。
"""

from __future__ import annotations

from typing import Dict, List

from .schema import LEVEL_CORE, LEVEL_GUARDRAIL, LEVEL_OPS  # noqa: F401  (重新导出)

# ---------------------------------------------------------------------------
# 全局版本号
# ---------------------------------------------------------------------------

# 系统提示词体系版本（语义化版本：主版本.次版本.修订）
PROMPT_VERSION = "1.0.0"

# 工具提示词统一结构化模板版本（内置工具 / MCP 工具 description 结构）
TOOL_TEMPLATE_VERSION = 1

# 上下文压缩器 prompt 版本（llm.py 的 compress/总结阶段使用）
COMPRESSOR_VERSION = 1

# ---------------------------------------------------------------------------
# 变更记录（audit）
# ---------------------------------------------------------------------------

SYSTEM_PROMPT_CHANGELOG: List[Dict[str, object]] = [
    {
        "version": "1.0.0",
        "date": "2026-08-23",
        "scope": "system / tool / spec / compressor",
        "changes": [
            "引入集中式版本化提示词注册表（server/prompt 包），章节数据与"
            "拼装逻辑解耦，支持版本号与章节审计清单。",
            "新增『角色权威与行为准则』章节（core）：权威边界、诚实性、"
            "先证后断、范围克制、不明即澄清。",
            "新增『安全与边界护栏』章节（guardrail）：数据安全、命令护栏、"
            "权限边界、合规与敏感信息处理。",
            "为既有全部系统提示词章节补充 version/level/description 元数据，"
            "并在系统提示词顶部注入审计头（版本 + 章节清单）。",
            "内置 / MCP 工具描述统一到结构化模板（贡献维度/何时使用/何时"
            "不用/前置依赖/动作），并登记工具提示词版本清单。",
            "内置 Spec（easy/complex/hard/team-meeting）补充 version / "
            "changelog / classification 前端字段，规范可追溯、可回滚。",
            "上下文压缩器 prompt 改为集中式版本化常量（llm.py 引用）。",
        ],
    },
]


# ---------------------------------------------------------------------------
# 审计工具
# ---------------------------------------------------------------------------

# 章节层级中文标签（审计清单可读性）
_LEVEL_LABEL = {
    LEVEL_CORE: "核心权威",
    LEVEL_GUARDRAIL: "安全护栏",
    LEVEL_OPS: "运行策略",
}


def chapter_manifest(chapters) -> List[Dict[str, str]]:
    """生成章节审计清单（不含正文，仅元数据）。

    :param chapters: ``Chapter`` 可迭代对象
    :return: ``[{"id", "title", "version", "level", "level_label",
                 "description"}]``
    """
    return [
        {
            "id": c.id,
            "title": c.title,
            "version": str(c.version),
            "level": c.level,
            "level_label": _LEVEL_LABEL.get(c.level, c.level),
            "description": c.description,
        }
        for c in chapters
    ]


def audit_header() -> str:
    """生成系统提示词顶部的审计头（版本 + 章节清单，纯文本、不占正文语义）。

    保持简洁以控制上下文开销：仅列出本章节 id、层级与版本号。
    """
    # 惰性 import，避免与 system_chapters 形成循环依赖
    from .system_chapters import (
        SYSTEM_STATIC_CHAPTERS,
        SYSTEM_STATIC_TAIL_CHAPTERS,
    )

    all_static = [*SYSTEM_STATIC_CHAPTERS, *SYSTEM_STATIC_TAIL_CHAPTERS]
    manifest_lines = []
    for c in chapter_manifest(all_static):
        manifest_lines.append(
            f"- [{c['level_label']}] {c['id']} v{c['version']}"
        )
    title_line = f"系统提示词体系：版本 v{PROMPT_VERSION}（工程来源 server/prompt）"
    body = "\n".join(manifest_lines)
    return f"{title_line}\n已装载章节:\n{body}"