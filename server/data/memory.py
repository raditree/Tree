"""LLM 记忆管理 - 工作空间级别的持久化记忆。

普通 LLM 通过 ``.self/memory.md`` 文件维护跨任务的记忆，
在系统提示词中注入记忆内容，并在适当时机触发记忆更新。
无限上下文 LLM 由于上下文本身跨任务保留，跳过所有记忆操作。
"""

import logging
from typing import Any

logger = logging.getLogger(__name__)


class MemoryManager:
    """工作空间记忆管理器。

    负责记忆文件的创建、读取、注入与更新触发：
    - 普通 LLM：初始化时创建 ``.self/memory.md``，每次对话注入记忆到系统提示词
    - 无限上下文 LLM：所有记忆操作均为空操作（上下文本身已持久保留）

    :param docker_manager: Docker 管理器实例，测试环境可为 None
    :param workspace_id: 工作空间标识
    :param is_limitless: 是否为无限上下文 LLM
    """

    # 记忆文件在工作空间内的相对路径
    MEMORY_FILE_PATH: str = ".self/memory.md"

    def __init__(
        self,
        docker_manager: Any,
        workspace_id: str,
        is_limitless: bool,
    ) -> None:
        """初始化记忆管理器。

        :param docker_manager: Docker 管理器实例，测试环境可为 None
        :param workspace_id: 工作空间标识
        :param is_limitless: 是否为无限上下文 LLM
        """
        self.docker_manager = docker_manager
        self.workspace_id = workspace_id
        self.is_limitless = is_limitless

        # 无限上下文 LLM 不需要记忆文件
        if not is_limitless:
            self._init_memory_file()

    def _init_memory_file(self) -> None:
        """在工作空间中创建记忆文件（如果不存在）。

        通过 ``mkdir -p`` 确保 ``.self`` 目录存在，再 ``touch`` 创建空文件。
        docker_manager 为 None 时跳过（测试环境）。
        """
        if self.docker_manager is None:
            logger.debug(
                "docker_manager 不可用，跳过记忆文件初始化, workspace=%s",
                self.workspace_id,
            )
            return

        try:
            # 确保 .self 目录存在并创建空记忆文件（touch 不覆盖已有内容）
            command = [
                "sh", "-c",
                f"mkdir -p .self && touch {self.MEMORY_FILE_PATH}",
            ]
            result = self.docker_manager.exec_in_workspace(
                self.workspace_id, command
            )
            if result.get("exit_code", -1) != 0:
                logger.warning(
                    "记忆文件初始化失败: %s, workspace=%s",
                    result.get("stderr", result.get("detail", "")),
                    self.workspace_id,
                )
            else:
                logger.info(
                    "记忆文件已就绪: %s, workspace=%s",
                    self.MEMORY_FILE_PATH,
                    self.workspace_id,
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "记忆文件初始化异常: %s, workspace=%s",
                exc,
                self.workspace_id,
            )

    def get_memory(self) -> str:
        """读取记忆文件内容。

        从 ``.self/memory.md`` 读取记忆内容并返回。
        如果文件为空、不存在或 docker_manager 不可用，返回空字符串。
        无限上下文 LLM 始终返回空字符串（不注入记忆）。

        :return: 记忆内容字符串，无记忆时返回空字符串
        """
        if self.is_limitless:
            return ""

        if self.docker_manager is None:
            return ""

        try:
            result = self.docker_manager.exec_in_workspace(
                self.workspace_id,
                ["cat", self.MEMORY_FILE_PATH],
            )
            # 文件不存在或读取失败
            if result.get("exit_code", -1) != 0:
                return ""

            content = result.get("stdout", "")
            if not content or not content.strip():
                return ""
            return content
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "读取记忆文件异常: %s, workspace=%s",
                exc,
                self.workspace_id,
            )
            return ""

    def inject_memory(self, system_prompt: str) -> str:
        """将记忆内容注入到系统提示词。

        无限上下文 LLM 直接返回原始系统提示词（不注入记忆）。
        普通 LLM 读取记忆内容，追加到系统提示词下方。

        :param system_prompt: 原始系统提示词
        :return: 注入记忆后的系统提示词；无记忆时返回原始提示词
        """
        if self.is_limitless:
            return system_prompt

        memory = self.get_memory()
        if not memory:
            return system_prompt

        return f"{system_prompt}\n\n## 记忆\n{memory}"

    def get_memory_update_prompt(self) -> str:
        """返回记忆更新提示文本。

        提示 LLM 更新 ``.self/memory.md`` 文件，记录本次任务的关键信息。
        无限上下文 LLM 返回空字符串（不需要记忆更新）。

        :return: 记忆更新提示文本；无限上下文 LLM 返回空字符串
        """
        if self.is_limitless:
            return ""

        return (
            "请更新 .self/memory.md 文件，记录本次任务的关键信息，"
            "包括任务目标、关键决策、遇到的问题及解决方案等。"
            "使用 set 工具或直接写入文件来更新记忆内容。"
        )

    def should_update_memory(self, session: Any) -> bool:
        """检查是否需要更新记忆。

        触发条件（满足任一即触发）：
        1. ``session.memory_update_pending`` 为 True（上下文压缩时设置）
        2. ``session.task_completed`` 为 True（任务结束标志位）
        3. 上下文即将压缩（token 数接近压缩阈值）

        无限上下文 LLM 始终返回 False（不需要记忆更新）。

        :param session: LLM 会话实例
        :return: 是否需要更新记忆
        """
        if self.is_limitless:
            return False

        # 触发条件 1：memory_update_pending 为 True
        if getattr(session, "memory_update_pending", False):
            return True

        # 触发条件 2：任务结束标志位
        if getattr(session, "task_completed", False):
            return True

        # 触发条件 3：上下文即将压缩（token 数接近压缩阈值）
        max_seqlen = getattr(session, "max_seqlen", None)
        if max_seqlen and isinstance(max_seqlen, int) and max_seqlen > 0:
            context = getattr(session, "context", [])
            # 近似 token 估算：len(str(msg)) // 4
            total_tokens = sum(len(str(msg)) // 4 for msg in context)
            # 阈值口径必须与 llm.AgentLLMSession.compress 一致：优先读实例属性
            # compress_threshold（支持模型 YAML / 每 agent 覆盖），旧对象缺该
            # 属性时回退类常量默认值 0.8
            compress_threshold = getattr(session, "compress_threshold", None)
            if compress_threshold is None:
                compress_threshold = getattr(session, "COMPRESS_THRESHOLD", 0.8)
            threshold = int(max_seqlen * compress_threshold)
            if total_tokens >= threshold:
                return True

        return False
