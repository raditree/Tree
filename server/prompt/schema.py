"""提示词体系核心类型定义。

企业级提示词工程将提示词视为可版本化、可审计的产物（artifacts）。本模块
定义最小可用的结构化类型，供集中式注册表（``registry``）与章节数据
（``system_chapters``）复用。
"""

from dataclasses import dataclass, field
from typing import Dict


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


@dataclass(frozen=True)
class PromptVersion:
    """一个版本打包（rule set）的提示词产物集合。

    由 :mod:`prompt.loader` 从 ``versions/<version>/`` 数据目录加载，作为
    「激活版本解析器」返回的完整版本包。

    :param version: 语义化版本号（与配置 ``prompt.version`` 对齐）
    :param system_head: 静态头章节（角色权威/任务范式/安全护栏/工具路由）
    :param system_tail: 静态尾章节（Spec 维护/todo 纪律/[Warning] 负责）
    :param compressor: 上下文压缩器模板函数（输入待压缩历史，输出压缩指令）
    :param tool_descriptions: 该版本的工具描述（``name -> description``）
    :param meta: 版本元数据（version/date/scope 等，来自 ``meta.yaml``）
    :param changelog: 版本变更记录列表
    """
    version: str
    system_head: tuple
    system_tail: tuple
    compressor: object
    tool_descriptions: Dict
    meta: Dict = field(default_factory=dict)
    changelog: tuple = ()