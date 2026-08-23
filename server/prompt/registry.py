"""提示词注册表：版本审计工具 + 版本常量基线。

提供：
- ``chapter_manifest``：章节审计清单（id/层级/版本号）。
- ``audit_header``：按**当前激活版本**（``versions.active_*``，由 app.yaml
  的 ``prompt.version`` 决定）生成系统提示词审计头。
- ``PROMPT_VERSION`` / ``TOOL_TEMPLATE_VERSION`` / ``COMPRESSOR_VERSION``：
  **v1.0.0 基线**常量。运行期实际使用哪个版本，以 ``prompt.version`` 配置与
  ``prompt/versions/`` 数据目录为准（见 :mod:`prompt.versions`）。

章节数据本体已迁至数据目录 ``versions/<version>/``（由 :mod:`prompt.loader`
读取），不再内嵌于代码。
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
    """生成**当前激活版本**系统提示词顶部的审计头（版本 + 章节清单）。

    章节取自激活版本数据目录（``versions.active_chapters()``），版本号取
    ``versions.active_version()``。保持简洁以控制上下文开销：仅列出章节
    id、层级与版本号。
    """
    # 惰性 import，避免与 versions/loader 形成循环依赖
    from .versions import active_chapters, active_version

    all_static = active_chapters()
    manifest_lines = []
    for c in chapter_manifest(all_static):
        manifest_lines.append(
            f"- [{c['level_label']}] {c['id']} v{c['version']}"
        )
    version = active_version()
    title_line = (
        f"系统提示词体系：版本 v{version}"
        "（工程来源 server/prompt/versions，激活版本以配置 prompt.version 为准）"
    )
    body = "\n".join(manifest_lines)
    return f"{title_line}\n已装载章节:\n{body}"