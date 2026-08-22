"""内置工具 AskUserQuestion - agent 主动向用户提问并等待回答。

当 agent 在执行任务过程中需要用户澄清、选择或输入额外信息时，可调用
本工具。工具会通过 WebSocket 向前端推送一条"待回答问题"卡片，然后阻塞
等待用户在界面上选择/输入答案；拿到答案后作为工具结果返回，供 LLM
在后续推理中继续使用（结果会写入上下文，等价于用户插话）。

注意：本工具是内置 tool（LLM 直接调用），而非 MCP tool。

线程模型说明：
- 工具 handler 在 chat 消费线程中执行，通过 ``threading.Event`` 阻塞等待
  用户回答，不阻塞后端事件循环。
- 前端通过 WebSocket 发送 ``{"type": "user_answer", "data": {...}}``，
  WS 端点调用 ``resolve()`` 唤醒等待中的线程。
"""

import logging
import threading
import uuid
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# 全局注册表：user_id -> AskUserQuestionTool，供 WS 端点解析用户答案
_ask_registry: Dict[str, "AskUserQuestionTool"] = {}

# 等待用户回答的超时时间（秒）
ANSWER_TIMEOUT: float = 600.0


def get_ask_tool(user_id: str) -> Optional["AskUserQuestionTool"]:
    """按用户获取 AskUserQuestionTool 实例（供 WS 端点调用）。"""
    return _ask_registry.get(user_id)


def register_ask_tool(user_id: str, tool: "AskUserQuestionTool") -> None:
    """注册/覆盖某用户的 AskUserQuestionTool 实例。"""
    _ask_registry[user_id] = tool


class AskUserQuestionTool:
    """agent 向用户提问的内置工具。"""

    def __init__(self, ws_manager: Any = None, user_id: str = "") -> None:
        """初始化。

        :param ws_manager: WebSocketManager 实例，用于向前端推送问题卡片
        :param user_id: 当前用户标识，用于 WS 推送与注册
        """
        self.ws_manager = ws_manager
        self.user_id = user_id
        # 主事件循环引用（在 register_builtin_tools 的协程上下文中填充）
        self._loop: Optional[Any] = None
        # 待回答问题: qid -> (event, holder)
        self._pending: Dict[str, Tuple[Any, Dict[str, Any]]] = {}
        if user_id:
            register_ask_tool(user_id, self)

    def bind_loop(self, loop: Any) -> None:
        """绑定主事件循环，供线程内安全地调度 WS 协程。"""
        self._loop = loop

    def get_tool_definition(self) -> dict:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "ask_user_question",
                "description": (
                    "[向用户提问并等待回答] | "
                    "贡献维度: 人机协作（获取用户决策/澄清/补充信息，消除歧义与风险）\n"
                    "何时使用: 任务信息不完整需要澄清；需要用户决策/选择；"
                    "高风险操作（删除/覆盖/破坏性/花钱）需确认；多方案让用户选型\n"
                    "何时不用: 可从现有上下文/文件推断时不提问；"
                    "琐碎问题自己能决策时不要打断用户；hard 任务之外避免频繁提问\n"
                    "前置依赖: 用户在线（WebSocket 连接）可收到问题卡片；"
                    "options 提供后用户可快速选择，否则自由输入"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "question": {
                            "type": "string",
                            "description": "向用户展示的问题内容",
                        },
                        "options": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "建议的选项列表（可为空，用户可自由输入）",
                        },
                        "default_answer": {
                            "type": "string",
                            "description": "默认答案（可选，用户未输入时使用）",
                        },
                    },
                    "required": ["question"],
                },
            },
        }

    def execute(self, arguments: dict) -> dict:
        """执行提问：推送问题卡片并阻塞等待用户回答。

        :param arguments: 含 question / options / default_answer
        :return: 用户回答内容（作为工具结果返回给 LLM）
        """
        question = str(arguments.get("question", "")).strip()
        if not question:
            return {"error": "缺少 question 参数"}
        options = arguments.get("options") or []
        if not isinstance(options, list):
            options = []
        options = [str(o) for o in options]
        default_answer = str(arguments.get("default_answer", "") or "")

        qid = f"q_{uuid.uuid4().hex[:8]}"
        event = threading.Event()
        holder: Dict[str, Any] = {"answer": None, "cancelled": False}
        self._pending[qid] = (event, holder)

        # 向用户推送问题卡片（线程安全地调度到主事件循环）
        if self.ws_manager is not None and self.user_id:
            self._notify_user(qid, question, options)

        # 阻塞等待用户回答（不阻塞事件循环）
        event.wait(timeout=ANSWER_TIMEOUT)
        self._pending.pop(qid, None)

        if holder["cancelled"]:
            return {"answer": None, "cancelled": True,
                    "note": "用户取消了本次提问"}
        if holder["answer"] is not None:
            return {"answer": holder["answer"]}
        if default_answer:
            return {"answer": default_answer, "note": "用户超时未回答，使用默认答案"}
        return {
            "answer": None,
            "note": "用户超时未回答，如需继续请向用户重新提问或自行决策",
        }

    def _notify_user(self, qid: str, question: str, options: List[str]) -> None:
        """向用户推送问题卡片（在主事件循环中执行）。"""
        payload = {
            "type": "ask_user_question",
            "id": qid,
            "question": question,
            "options": options,
        }
        try:
            if self._loop is not None and self._loop.is_running():
                import asyncio

                asyncio.run_coroutine_threadsafe(
                    self.ws_manager.send_message(self.user_id, payload),
                    self._loop,
                )
            else:
                # 回退：同步协程（仅当被调用时恰有事件循环，实际不会走到）
                import asyncio

                asyncio.get_event_loop().run_until_complete(
                    self.ws_manager.send_message(self.user_id, payload)
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("推送提问卡片失败: %s", exc)

    def resolve(self, qid: str, answer: Any) -> bool:
        """由 WS 端点调用：解析用户答案，唤醒等待中的线程。

        :param qid: 问题 ID
        :param answer: 用户回答
        :return: 是否找到对应的待回答问题
        """
        entry = self._pending.get(qid)
        if entry is None:
            return False
        event, holder = entry
        holder["answer"] = str(answer) if answer is not None else ""
        event.set()
        return True

    def cancel(self, qid: str) -> bool:
        """取消一个待回答问题（用户点击取消）。"""
        entry = self._pending.get(qid)
        if entry is None:
            return False
        event, holder = entry
        holder["cancelled"] = True
        event.set()
        return True