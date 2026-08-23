"""提示词体系核心类型定义。

企业级提示词工程将提示词视为可版本化、可审计的产物（artifacts）。本模块
定义最小可用的结构化类型，供集中式注册表（``registry``）与章节数据
（``system_chapters``）复用。
"""

from dataclasses import dataclass


# 章节层级枚举（用于审计/权限分级）
LEVEL_CORE = "core"            # 核心权威：身份、行为准则、任务范式
LEVEL_GUARDRAIL = "guardrail"  # 安全护栏：命令/数据/授权边界
LEVEL_OPS = "ops"              # 运行策略：工具路由、规范维护、进度纪律


@dataclass(frozen=True)
class Chapter:
    """系统提示词的一个章节（版本化、可审计、可追溯）。

    :param id: 章节唯一标识（如 ``authority`` / ``security_boundary``）
    :param title: 章节标题（渲染时加 ``## `` 前缀）
    :param version: 章节内容版本（整数，递增表示有内容变更）
    :param level: 章节层级，见 :data:`LEVEL_CORE` / :data:`LEVEL_GUARDRAIL`
                  / :data:`LEVEL_OPS`
    :param description: 章节用途说明（供审计清单 / 变更记录阅读）
    :param content: 章节正文（Markdown）；动态章节留空、由运行时注入
    """
    id: str
    title: str
    version: int
    level: str
    description: str
    content: str = ""  # 动态章节留空，由运行时注入