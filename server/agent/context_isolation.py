"""Agent 上下文隔离 - 控制子 agent 上下文对父 agent 的影响。

提供子 agent 工作成果摘要汇报与上下文过滤机制，避免顶部 agent 上下文被子 agent
详细工作过程（逐条 tool_call 执行记录）淹没。
"""

import logging
from typing import Any

logger = logging.getLogger(__name__)


class ContextIsolator:
    """Agent 上下文隔离器。

    提供以下能力：
    - 子 agent 完成任务后生成工作成果摘要（不含逐条 tool_call 执行记录）
    - 生成成员状态报告供父 agent 查询
    - 过滤子 agent 上下文，仅保留摘要信息注入父 agent 上下文
    """

    # 工作结果摘要最大保留字符数
    RESULT_SUMMARY_MAX_CHARS: int = 2000

    def __init__(self) -> None:
        """初始化上下文隔离器。"""
        # 当前无内部状态，预留扩展点（如缓存、配置等）

    # ------------------------------------------------------------------
    # SubTask 14.5.1: 子 agent 工作成果摘要汇报机制
    # ------------------------------------------------------------------
    def create_work_summary(
        self,
        task_description: str,
        tool_calls: list[dict],
        git_commit: dict,
        result: str,
    ) -> str:
        """子 agent 完成任务后生成工作成果摘要。

        摘要包含：任务描述、工具调用数量与类型统计、Git 提交信息、工作结果摘要。
        不包含逐条 tool_call 执行记录。

        :param task_description: 任务描述（简短）
        :param tool_calls: 工具调用列表，每项为 dict（含 name 字段）
        :param git_commit: Git 提交信息 dict（含 hash/message 键）
        :param result: 工作结果文本
        :return: 格式化的摘要文本
        """
        lines: list[str] = []

        # 1. 任务描述
        lines.append(f"任务描述: {task_description or '(无)'}")

        # 2. 工具调用数量与类型统计
        tool_stats = self._count_tool_types(tool_calls)
        lines.append(f"工具调用: 使用了 {len(tool_calls)} 次工具调用: {tool_stats}")

        # 3. Git 提交信息（commit hash, message）
        commit_line = self._format_git_commit(git_commit)
        lines.append(f"Git 提交: {commit_line}")

        # 4. 工作结果摘要（前 500 字符，超长截断）
        result_summary = self._truncate_result(result)
        lines.append("工作结果摘要:")
        lines.append(result_summary)

        return "\n".join(lines)

    def create_status_report(
        self, member_id: str, task: dict, git_log: list
    ) -> str:
        """生成成员状态报告（供父 agent 查询时使用）。

        简短格式，包含成员 ID、当前任务、最近 Git 提交。不包含详细工作过程。

        :param member_id: 成员 ID
        :param task: 任务字典，含 description/status 等字段
        :param git_log: Git 提交历史列表（字符串或 dict 列表）
        :return: 格式化的状态报告文本
        """
        lines: list[str] = [f"成员 ID: {member_id}"]

        # 当前任务（简短）
        if task:
            desc = task.get("description") or task.get("summary") or ""
            status = task.get("status", "")
            status_part = f" [{status}]" if status else ""
            lines.append(f"当前任务: {desc or '(无)'}{status_part}")
        else:
            lines.append("当前任务: (无)")

        # 最近 Git 提交（最多 3 条，简短格式）
        recent_commits = self._format_recent_commits(git_log, limit=3)
        lines.append("最近 Git 提交:")
        if recent_commits:
            for commit in recent_commits:
                lines.append(f"  - {commit}")
        else:
            lines.append("  - (无)")

        return "\n".join(lines)

    # ------------------------------------------------------------------
    # SubTask 14.5.2: 顶部 agent 上下文内容控制
    # ------------------------------------------------------------------
    def filter_context_for_parent(
        self, child_context: list[dict]
    ) -> list[dict]:
        """过滤子 agent 上下文，只保留摘要信息。

        - 移除所有 tool_call 执行记录（role="tool" 的消息）
        - 保留 system 消息和 user/assistant 的文本消息
        - 如果 assistant 消息包含 tool_calls，移除 tool_calls 字段，只保留 text 内容

        :param child_context: 子 agent 的完整上下文列表
        :return: 过滤后的上下文列表（仅含摘要信息）
        """
        filtered: list[dict] = []
        for msg in child_context:
            if not isinstance(msg, dict):
                continue

            role = msg.get("role")

            # 移除工具执行结果消息（role="tool"）
            if role == "tool":
                continue

            # 复制消息，避免修改原上下文
            new_msg: dict = dict(msg)

            # assistant 消息含 tool_calls 时移除该字段，只保留 text 内容
            if role == "assistant" and "tool_calls" in new_msg:
                new_msg.pop("tool_calls", None)
                # content 为空时保留原值（可能为 None），不强行填充

            filtered.append(new_msg)
        return filtered

    @staticmethod
    def build_parent_context_entry(member_id: str, summary: str) -> dict:
        """构建一条注入父 agent 上下文的消息。

        这条消息替代子 agent 的完整工作日志，只包含工作成果摘要。

        :param member_id: 子 agent 成员 ID
        :param summary: 工作成果摘要文本
        :return: 父 agent 上下文消息字典
        """
        return {
            "role": "user",
            "content": f"[成员 {member_id} 工作成果摘要]\n{summary}",
        }

    # ------------------------------------------------------------------
    # 内部辅助方法
    # ------------------------------------------------------------------
    @staticmethod
    def _count_tool_types(tool_calls: list[dict]) -> str:
        """统计工具调用类型并格式化为 ``read(2), write(1)`` 形式。"""
        if not tool_calls:
            return "无"

        counts: dict[str, int] = {}
        for tc in tool_calls:
            name = (tc.get("name") if isinstance(tc, dict) else None) or "unknown"
            counts[name] = counts.get(name, 0) + 1

        return ", ".join(f"{name}({cnt})" for name, cnt in counts.items())

    @staticmethod
    def _format_git_commit(git_commit: Any) -> str:
        """格式化 Git 提交信息。

        支持以下形式：
        - dict 含 hash/message（或 commit_hash/subject）键
        - dict 为空时返回占位文本
        - 其他类型按字符串处理
        """
        if not git_commit:
            return "(无提交)"

        if isinstance(git_commit, dict):
            commit_hash = (
                git_commit.get("hash")
                or git_commit.get("commit_hash")
                or ""
            )
            message = (
                git_commit.get("message")
                or git_commit.get("subject")
                or ""
            )
            if commit_hash and message:
                return f"{commit_hash} {message}"
            return commit_hash or message or "(无提交)"

        # 字符串形式（如 git log --oneline 输出的一行）
        return str(git_commit)

    def _truncate_result(self, result: str) -> str:
        """截断工作结果文本至 RESULT_SUMMARY_MAX_CHARS 字符。"""
        if not result:
            return "(无结果)"

        if len(result) <= self.RESULT_SUMMARY_MAX_CHARS:
            return result

        return result[: self.RESULT_SUMMARY_MAX_CHARS] + "..."

    @staticmethod
    def _format_recent_commits(git_log: list, limit: int = 3) -> list[str]:
        """格式化最近的 Git 提交列表。

        支持列表项为字符串（git log --oneline 输出）或 dict（含 hash/message）。
        """
        if not git_log:
            return []

        result: list[str] = []
        for entry in git_log[:limit]:
            if isinstance(entry, dict):
                commit_hash = (
                    entry.get("hash")
                    or entry.get("commit_hash")
                    or ""
                )
                message = (
                    entry.get("message")
                    or entry.get("subject")
                    or ""
                )
                if commit_hash and message:
                    result.append(f"{commit_hash} {message}")
                else:
                    result.append(commit_hash or message or "(无)")
            else:
                result.append(str(entry))
        return result
