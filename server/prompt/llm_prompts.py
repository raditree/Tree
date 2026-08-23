"""LLM 辅助提示词（版本化、集中式维护）。

将散落在 ``llm/llm.py`` 中的辅助 prompt（上下文压缩器）收敛为集中式常量，
便于统一改写并登记版本（可审计、可回滚）。改写需同步递增
:data:`prompt.registry.COMPRESSOR_VERSION` 并在 changelog 记录变更原因。
"""

from .registry import COMPRESSOR_VERSION  # noqa: F401  (供引用方感知版本)


def context_compressor_prompt(raw: str) -> str:
    """构建上下文压缩器提示词（用于长对话中压缩 tool 调用轨迹与任务上下文）。

    :param raw: 待压缩历史消息的中文紧凑表示（由调用方预处理/截断）
    :return: 发给压缩模型的中文总结指令
    """
    return (
        "你是上下文压缩器。以下是 agent 与用户、工具之间的一段历史对话，"
        "包含任务目标、已执行的工具调用轨迹与结果、以及当前进展。\n"
        "请用简洁的中文总结：1) 用户的任务目标与最新要求；2) 已完成的工具"
        "调用轨迹与关键结果；3) 当前进展与尚未完成的待办。保留必要的事实"
        "细节（文件名、路径、数字、结论），不要逐条复述原文。\n\n"
        f"历史对话：\n{raw}"
    )