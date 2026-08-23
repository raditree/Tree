"""内置工具 AskUserQuestion - agent 主动向用户提问。

当 agent 在执行任务过程中需要用户澄清、选择或输入额外信息时，可调用
本工具。工具会把问题持久化到 SQLite（``pending_questions`` 表），并作为
一条会话历史消息展示，随后通过 WebSocket 向前端推送"待回答问题"卡片。

与旧版"阻塞等待 10 分钟"不同，本工具**不阻塞**：提问后返回哨兵，由
工具循环感知后暂停当前一轮（agent 归闲）。用户作答（无论多久、是否断线/
刷新）后，WS 端点按 qid 查库定位到 (agent, session)，注入答案并重新触发
该 agent 执行，实现"答完自动唤醒"。

注意：本工具是内置 tool（LLM 直接调用），而非 MCP tool。
"""

import logging
import uuid
from typing import Any, Dict, List, Optional

from data.conversation_store import save_pending_question, store_message
from prompt import versions

logger = logging.getLogger(__name__)

# 全局注册表：user_id -> AskUserQuestionTool（保留用于查询，路由统一走 DB）
_ask_registry: Dict[str, "AskUserQuestionTool"] = {}


def get_ask_tool(user_id: str) -> Optional["AskUserQuestionTool"]:
    """按用户获取 AskUserQuestionTool 实例（兼容旧调用，实际路由走 DB）。"""
    return _ask_registry.get(user_id)


def register_ask_tool(user_id: str, tool: "AskUserQuestionTool") -> None:
    """注册/覆盖某用户的 AskUserQuestionTool 实例。"""
    _ask_registry[user_id] = tool


# 暂停哨兵标记：工具循环据此停止本轮并等待用户作答
ASK_PAUSED_KEY = "__ask_paused__"


class AskUserQuestionTool:
    """agent 向用户提问的内置工具（非阻塞、持久化）。"""

    def __init__(
        self,
        ws_manager: Any = None,
        user_id: str = "",
        agent_id: str = "",
        top_agent_id: str = "",
        session_id: str = "",
        is_member: bool = False,
        session: Any = None,
    ) -> None:
        """初始化。

        :param ws_manager: WebSocketManager 实例，用于向前端推送问题卡片
        :param user_id: 当前用户标识，用于 WS 推送与注册
        :param agent_id: 提问方 agent（主 agent 或成员 id），持久化/唤醒定位用
        :param top_agent_id: 所属顶部 agent（成员提问时为成员所属 TOP；主 agent
            提问时即自身），唤醒路由成员 roster 时使用
        :param session_id: 所属会话 id（多会话隔离）
        :param is_member: 是否团队成员提问（决定唤醒时的分发路径）
        :param session: 对应的 LLM 会话，提问时读取 ``session.sender_id`` 作为
            原发送方持久化（供续跑后成员总结精确回发）
        """
        self.ws_manager = ws_manager
        self.user_id = user_id
        self.agent_id = agent_id
        self.top_agent_id = top_agent_id or agent_id
        self.session_id = session_id
        self.is_member = is_member
        self._session = session
        # 主事件循环引用（在 register_builtin_tools 的协程上下文中填充）
        self._loop: Optional[Any] = None
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
                "description": versions.active_tool_description("ask_user_question"),
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
                    },
                    "required": ["question"],
                },
            },
        }

    def execute(self, arguments: dict) -> dict:
        """执行提问：持久化 + 推送卡片 + 返回暂停哨兵（不阻塞）。

        :param arguments: 含 question / options
        :return: 哨兵 ``{"__ask_paused__": True, "qid": qid}``，工具循环据此
                 停止本轮，等待用户作答后由后端重新触发执行。
        """
        question = str(arguments.get("question", "")).strip()
        if not question:
            return {"error": "缺少 question 参数"}
        options = arguments.get("options") or []
        if not isinstance(options, list):
            options = []
        options = [str(o) for o in options]

        qid = f"q_{uuid.uuid4().hex[:8]}"

        # 1) 持久化待答提问（重启后仍可路由/唤醒）。记录当前发送方
        #    （session.sender_id，由 _process_member_message / 插入消息实时维护），
        #    供续跑后成员总结精确回发到原发送方。
        try:
            sender_id = getattr(self._session, "sender_id", "") if self._session else ""
            save_pending_question(
                self.user_id,
                self.agent_id,
                self.top_agent_id,
                self.session_id,
                qid,
                question,
                options,
                is_member=1 if self.is_member else 0,
                sender_id=sender_id,
            )
            # 2) 作为会话历史消息展示（断线/刷新后恢复卡片），qid 即 msg_id
            store_message(
                self.user_id,
                self.agent_id,
                "agent",
                question,
                kind="ask_user_question",
                tool_arguments={"options": options},
                session_id=self.session_id,
                answered=0,
                msg_id=qid,
            )
        except Exception:  # noqa: BLE001
            logger.exception("持久化 AskUserQuestion 问题失败: %s", qid)

        # 3) 向用户推送问题卡片（线程安全地调度到主事件循环），携带定位信息
        if self.ws_manager is not None and self.user_id:
            self._notify_user(qid, question, options)

        # 4) 返回暂停哨兵：不阻塞线程，本轮在此暂停
        return {ASK_PAUSED_KEY: True, "qid": qid}

    def _notify_user(self, qid: str, question: str, options: List[str]) -> None:
        """向用户推送问题卡片（在主事件循环中执行）。"""
        payload = {
            "type": "ask_user_question",
            "id": qid,
            "question": question,
            "options": options,
            "agent_id": self.agent_id,
            "session_id": self.session_id,
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