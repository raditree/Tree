"""LLM 接入层 - 通过 OpenAI SDK 调用模型，支持普通 LLM 和无限上下文 LLM。"""

import json
import logging
import re
from typing import Any, Callable, Dict, Generator, List, Optional

from openai import OpenAI

from core.models import ModelConfig

logger = logging.getLogger(__name__)


class LLMClientFactory:
    """OpenAI SDK client 工厂。

    根据模型配置创建 OpenAI client，统一管理 client 的实例化逻辑。
    """

    @staticmethod
    def create_client(model_config: ModelConfig) -> OpenAI:
        """根据模型配置创建 OpenAI client。

        :param model_config: 模型配置，提供 base_url 与 api_key
        :return: openai.OpenAI 实例
        """
        return OpenAI(
            base_url=model_config.base_url,
            api_key=model_config.api_key,
        )


class AgentLLMSession:
    """单个 agent 的 LLM 会话管理（普通 LLM）。

    普通上下文 LLM 的会话管理：维护上下文列表、注册工具、流式调用 LLM、
    处理 tool_call 循环、并在上下文接近 max_seqlen 时执行压缩。
    """

    # 上下文压缩：保留最近消息数
    KEEP_RECENT_MESSAGES: int = 10
    # 上下文压缩阈值比例（达到 max_seqlen 的 80% 时触发）
    COMPRESS_THRESHOLD: float = 0.8

    def __init__(
        self,
        model_config: ModelConfig,
        workspace_id: str,
        system_prompt: str = "",
    ) -> None:
        """初始化 LLM 会话。

        :param model_config: 模型配置
        :param workspace_id: 工作空间标识
        :param system_prompt: 系统提示词，普通 LLM 初始化时注入上下文
        """
        self.model_config = model_config
        self.workspace_id = workspace_id
        self.system_prompt = system_prompt

        # 上下文列表：普通 LLM 初始化时注入系统提示词
        self.context: List[Dict[str, Any]] = []
        if system_prompt:
            self.context.append({"role": "system", "content": system_prompt})

        # 从 extra 读取参数
        # temperature / top_k 仅当 yaml 显式配置或通过 set 工具设置时才下发
        # （未配置且未设置时置 None，调用时不带）
        self.temperature: Optional[float] = (
            float(model_config.extra["temperature"])
            if "temperature" in model_config.extra
            else None
        )
        self.top_k: Optional[int] = (
            int(model_config.extra["top_k"])
            if "top_k" in model_config.extra
            else None
        )
        self.max_seqlen: int = int(model_config.extra.get("max_seqlen", 8192))

        # 注册的 tool_call 函数列表
        self.registered_tools: List[Dict[str, Any]] = []

        # 最近一次 API 调用的 token 用量（流式响应末尾携带）
        self.last_usage: Optional[Dict[str, int]] = None

        # 记忆更新标志位（后续 Task 13 通过回调或标志位触发记忆更新）
        self.memory_update_pending: bool = False

    # ------------------------------------------------------------------
    # 工具注册
    # ------------------------------------------------------------------
    def register_tool(
        self,
        name: str,
        description: str,
        parameters: Dict[str, Any],
        handler: Callable[..., Any],
    ) -> None:
        """注册一个 tool_call 函数。

        将工具信息添加到 registered_tools，并构建 OpenAI function calling
        格式的 tool 定义。

        :param name: 工具名称
        :param description: 工具描述
        :param parameters: JSON Schema 格式的参数定义
        :param handler: 工具执行函数，接收关键字参数
        """
        tool_definition = {
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": parameters,
            },
        }
        self.registered_tools.append({
            "definition": tool_definition,
            "handler": handler,
        })

    def _find_handler(self, name: str) -> Optional[Callable[..., Any]]:
        """根据工具名查找已注册的 handler。"""
        for tool in self.registered_tools:
            if tool["definition"]["function"]["name"] == name:
                return tool["handler"]
        return None

    # ------------------------------------------------------------------
    # API 调用辅助
    # ------------------------------------------------------------------
    def _build_api_kwargs(self) -> Dict[str, Any]:
        """构建 OpenAI chat.completions.create 调用参数。

        模型配置的 extra 字段按以下规则下发：
        - ``temperature``/``top_k``/``max_seqlen`` 为保留字段，已由会话读取
        - ``extra_body`` 中的嵌套字典合并进 ``extra_body``（非标准参数）
        - 其余字段作为 OpenAI 顶层参数原样透传（如 ``reasoning_effort``、
          ``max_tokens``、``top_p``）
        """
        kwargs: Dict[str, Any] = {
            "model": self.model_config.model_id,
            "messages": self.context,
            "stream": True,
            # 流式响应末尾返回 token 用量（OpenAI 规范：stream_options.include_usage）
            "stream_options": {"include_usage": True},
        }
        # temperature 仅在 yaml 显式配置或通过 set 工具设置时下发
        if self.temperature is not None:
            kwargs["temperature"] = self.temperature
        # 注入 tools（如有注册）
        if self.registered_tools:
            kwargs["tools"] = [t["definition"] for t in self.registered_tools]
        # top_k 通过 extra_body 传递（非 OpenAI 标准参数，由具体 API 端点决定是否支持）
        extra_body: Dict[str, Any] = {}
        if self.top_k is not None:
            extra_body["top_k"] = self.top_k
        extra = self.model_config.extra
        # 合并模型自定义的 extra_body 参数
        provider_extra = extra.get("extra_body")
        if isinstance(provider_extra, dict):
            extra_body.update(provider_extra)
        # 其余未保留字段作为 OpenAI 顶层参数透传
        reserved = {"temperature", "top_k", "max_seqlen", "extra_body"}
        for key, value in extra.items():
            if key not in reserved:
                kwargs[key] = value
        kwargs["extra_body"] = extra_body
        return kwargs

    @staticmethod
    def _safe_parse_arguments(raw: str) -> Dict[str, Any]:
        """容错解析 tool_call 参数。

        LLM 返回的 ``arguments`` 可能因截断或格式不规范而非合法 JSON，依次尝试：
        1. 直接 ``json.loads``
        2. 提取首个 ``{`` 到最后一个 ``}`` 的完整对象再解析
        3. 去除尾随逗号（``,}`` / `,``）后重试
        4. 均失败则返回空字典并记录警告（避免工具调用整体崩溃）
        """
        if not raw or not raw.strip():
            return {}

        def _loads(s: str) -> Optional[Dict[str, Any]]:
            try:
                obj = json.loads(s)
                return obj if isinstance(obj, dict) else None
            except Exception:  # noqa: BLE001
                return None

        raw = raw.strip()
        # 1. 直接解析
        obj = _loads(raw)
        if obj is not None:
            return obj

        # 2. 提取首个 { 到最后一个 } 的完整对象
        start = raw.find("{")
        end = raw.rfind("}")
        if start != -1 and end > start:
            obj = _loads(raw[start:end + 1])
            if obj is not None:
                return obj

        # 3. 去除尾随逗号后重试
        fixed = raw
        for _ in range(3):
            new_fixed = re.sub(r",\s*([}\]])", r"\1", fixed)
            if new_fixed == fixed:
                break
            fixed = new_fixed
        obj = _loads(fixed)
        if obj is not None:
            return obj

        logger.warning("无法解析 tool_call 参数，返回空参数: %.200r", raw)
        return {}

    def _run_completion_loop(
        self, client: OpenAI, on_tool_turn: Optional[Callable[[], str]] = None
    ) -> Generator[Dict[str, Any], None, None]:
        """运行 LLM 流式调用 + tool_call 循环。

        不断调用 LLM 直到返回最终文本（无 tool_call）。
        yield ``{"type": "text", "content": "..."}`` 或
        ``{"type": "tool_call", "name": "...", "result": "..."}``。

        :param on_tool_turn: 可选回调，在每次 tool_call 处理完、进入下一轮
                             调用前被调用。若返回非空字符串，则将其作为一条
                             user 消息插入上下文，供下一轮 LLM 处理（用于
                             在成员工作的间隙切入 leader 发来的新消息）。
        """
        while True:
            api_kwargs = self._build_api_kwargs()
            stream = client.chat.completions.create(**api_kwargs)

            content_parts: List[str] = []
            tool_calls: List[Dict[str, str]] = []
            finish_reason: Optional[str] = None

            # 流式接收响应
            for chunk in stream:
                # 流式末尾的 usage chunk 无 choices，但携带 token 用量
                usage = getattr(chunk, "usage", None)
                if usage is not None:
                    self.last_usage = {
                        "prompt_tokens": getattr(usage, "prompt_tokens", 0) or 0,
                        "completion_tokens": getattr(usage, "completion_tokens", 0) or 0,
                        "total_tokens": getattr(usage, "total_tokens", 0) or 0,
                    }
                if not chunk.choices:
                    continue
                choice = chunk.choices[0]
                delta = choice.delta
                finish_reason = choice.finish_reason

                # 流式输出文本
                if delta.content:
                    content_parts.append(delta.content)
                    yield {"type": "text", "content": delta.content}

                # 收集 tool_call 分片（流式时按 index 拼接）
                if delta.tool_calls:
                    for tc in delta.tool_calls:
                        idx = tc.index if tc.index is not None else 0
                        while len(tool_calls) <= idx:
                            tool_calls.append({"id": "", "name": "", "arguments": ""})
                        if tc.id:
                            tool_calls[idx]["id"] = tc.id
                        if tc.function and tc.function.name:
                            tool_calls[idx]["name"] = tc.function.name
                        if tc.function and tc.function.arguments:
                            tool_calls[idx]["arguments"] += tc.function.arguments

            # 拼接完整文本
            full_content = "".join(content_parts)

            # 处理 tool_call：执行 handler 并将结果添加到上下文，继续循环
            if finish_reason == "tool_calls" and tool_calls:
                assistant_msg: Dict[str, Any] = {
                    "role": "assistant",
                    "content": full_content or None,
                    "tool_calls": [
                        {
                            "id": tc["id"],
                            "type": "function",
                            "function": {
                                "name": tc["name"],
                                "arguments": tc["arguments"],
                            },
                        }
                        for tc in tool_calls
                    ],
                }
                self.context.append(assistant_msg)

                # 执行每个 tool_call
                for tc in tool_calls:
                    handler = self._find_handler(tc["name"])
                    if handler is not None:
                        try:
                            args = self._safe_parse_arguments(tc["arguments"])
                            result = handler(**args)
                        except Exception as exc:  # noqa: BLE001
                            logger.exception("工具 %s 执行出错", tc["name"])
                            result = f"工具执行出错: {exc}"
                    else:
                        result = f"未找到工具: {tc['name']}"

                    yield {"type": "tool_call", "name": tc["name"], "result": str(result)}

                    # 将工具结果添加到上下文
                    self.context.append({
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": str(result),
                    })

                # tool_call 间隙：若提供了插入回调，检查是否有新消息需要切入处理
                if on_tool_turn is not None:
                    try:
                        inserted = on_tool_turn()
                    except Exception:  # noqa: BLE001
                        inserted = None
                    if inserted:
                        self.context.append(
                            {"role": "user", "content": inserted}
                        )

                # 继续循环，让 LLM 处理工具结果
                continue

            # 无 tool_call，对话结束
            if full_content:
                self.context.append({"role": "assistant", "content": full_content})
            break

    # ------------------------------------------------------------------
    # 对话入口
    # ------------------------------------------------------------------
    def chat(
        self,
        user_message: str,
        on_tool_turn: Optional[Callable[[], Optional[str]]] = None,
    ) -> Generator[Dict[str, Any], None, None]:
        """与 LLM 对话，流式输出。

        将用户消息添加到上下文，检查是否需要压缩上下文，然后调用 LLM。
        处理 tool_call 循环，直到返回最终文本。

        :param user_message: 用户消息
        :param on_tool_turn: 可选回调，在每次 tool_call 间隙被调用，若返回
                             新消息文本则切入处理（见 _run_completion_loop）
        :return: 生成器，yield ``{"type": "text", "content": "..."}`` 或
                 ``{"type": "tool_call", "name": "...", "result": "..."}``
        """
        # 前缀一致性验证（普通 LLM 无需验证，由子类覆盖）
        self._validate_prefix(user_message)

        # 将用户消息添加到上下文
        self.context.append({"role": "user", "content": user_message})

        # 检查是否需要压缩上下文（普通 LLM 执行压缩，无限上下文 LLM 覆盖为空操作）
        self._compress_context()

        client = LLMClientFactory.create_client(self.model_config)

        yield from self._run_completion_loop(client, on_tool_turn=on_tool_turn)

    # ------------------------------------------------------------------
    # 钩子方法（可由子类覆盖）
    # ------------------------------------------------------------------
    def _validate_prefix(self, user_message: str) -> None:
        """前缀一致性验证钩子。

        普通 LLM 无需验证，空操作。无限上下文 LLM 覆盖此方法。
        """

    def _compress_context(self) -> None:
        """检查并压缩上下文（自动触发，带阈值判断）。

        当上下文总 token 数接近 max_seqlen 时执行压缩：
        - 保留系统提示词（第一条消息）
        - 保留最近 N 条消息（KEEP_RECENT_MESSAGES）
        - 中间消息总结为一条 summary 消息
        - 触发记忆更新标志位（后续 Task 13 使用）
        """
        self.compress(force=False)

    def compress(self, force: bool = False) -> bool:
        """压缩上下文。

        - ``force=False``：仅当 token 估算超过阈值时压缩（自动压缩，chat 调用）。
        - ``force=True``：手动 compact（compact 按钮），跳过阈值判断，
          只要有可压缩的消息就立即压缩。

        返回是否实际执行了压缩。
        """
        # 估算总 token 数（近似：len(str(msg)) // 4）
        total_tokens = sum(len(str(msg)) // 4 for msg in self.context)

        # 未超过阈值，且非强制压缩时跳过
        threshold = int(self.max_seqlen * self.COMPRESS_THRESHOLD)
        if not force and total_tokens <= threshold:
            return False

        # 分离 system 消息与其他消息
        system_msgs: List[Dict[str, Any]] = []
        other_msgs: List[Dict[str, Any]] = []
        for msg in self.context:
            if msg.get("role") == "system":
                system_msgs.append(msg)
            else:
                other_msgs.append(msg)

        # 强制压缩时：即使消息很少也立即压缩，只保留最近 1 条，其余全部总结。
        # 这样 compact 按钮无论什么情况都能生效（checklist 5）。
        keep = (1 if force else self.KEEP_RECENT_MESSAGES)

        # 消息数不足，无可压缩内容
        if len(other_msgs) <= keep:
            return False

        # 切分：待总结部分 + 保留部分
        to_summarize = other_msgs[:-keep]
        to_keep = other_msgs[-keep:]

        # 构建总结消息
        summary_lines: List[str] = [
            "之前的对话总结（上下文已被压缩，以下为历史要点；"
            "如需查看完整工作过程请查看工作空间内的文件与日志）:"
        ]
        for msg in to_summarize:
            role = msg.get("role", "unknown")
            content = str(msg.get("content", ""))[:200]
            summary_lines.append(f"- [{role}] {content}")

        summary_msg = {"role": "system", "content": "\n".join(summary_lines)}

        # 重组上下文：system 消息 + 总结 + 最近消息
        self.context = system_msgs + [summary_msg] + to_keep

        # 触发记忆更新标志位（后续 Task 13 通过回调或标志位处理）
        self.memory_update_pending = True

        logger.info(
            "上下文已压缩: 总结 %d 条消息, 保留最近 %d 条, "
            "workspace=%s, model=%s, force=%s",
            len(to_summarize),
            keep,
            self.workspace_id,
            self.model_config.model_id,
            force,
        )
        return True


class LimitlessContextSession(AgentLLMSession):
    """无限上下文 LLM 会话管理。

    与普通 LLM 的区别：
    - 初始化空上下文（跨任务保留），不注入系统提示词
    - 不从模型配置读取 max_seqlen
    - 对话前执行前缀一致性验证
    - 不执行上下文压缩
    - 上下文在对象生命周期内持久保留，不因任务结束而清空
    """

    def __init__(
        self,
        model_config: ModelConfig,
        workspace_id: str,
        system_prompt: str = "",
        docker_manager: Any = None,
    ) -> None:
        """初始化无限上下文 LLM 会话。

        :param model_config: 模型配置
        :param workspace_id: 工作空间标识
        :param system_prompt: 系统提示词（无限上下文 LLM 不注入上下文，仅保存）
        :param docker_manager: Docker 管理器实例，用于上下文持久化与崩溃恢复；
                               测试环境可传 None 跳过持久化
        """
        self.model_config = model_config
        self.workspace_id = workspace_id
        self.system_prompt = system_prompt
        self.docker_manager = docker_manager

        # 无限上下文：初始化空上下文（跨任务保留）
        self.context: List[Dict[str, Any]] = []

        # 从 extra 读取参数（不读取 max_seqlen）
        # temperature / top_k 仅当 yaml 显式配置或通过 set 工具设置时才下发
        self.temperature: Optional[float] = (
            float(model_config.extra["temperature"])
            if "temperature" in model_config.extra
            else None
        )
        self.top_k: Optional[int] = (
            int(model_config.extra["top_k"])
            if "top_k" in model_config.extra
            else None
        )
        self.max_seqlen: Optional[int] = None  # 无限上下文不需要

        # 注册的 tool_call 函数列表
        self.registered_tools: List[Dict[str, Any]] = []

        # 最近一次 API 调用的 token 用量（流式响应末尾携带）
        self.last_usage: Optional[Dict[str, int]] = None

        # 记忆更新标志位（无限上下文不触发）
        self.memory_update_pending: bool = False

        # 上下文快照（JSON 字符串），用于前缀一致性验证
        self._last_context_json: Optional[str] = None

        # 崩溃恢复：尝试从工作空间加载上下文快照
        loaded = self._load_context_snapshot()
        if loaded:
            self._last_context_json = json.dumps(
                self.context, ensure_ascii=False, sort_keys=True
            )
            logger.info(
                "从快照恢复上下文成功，共 %d 条消息, workspace=%s",
                len(self.context),
                self.workspace_id,
            )
        else:
            logger.warning(
                "未找到上下文快照或加载失败，使用空上下文, workspace=%s",
                self.workspace_id,
            )

    # ------------------------------------------------------------------
    # 钩子覆盖
    # ------------------------------------------------------------------
    def restore_context(self, context: List[Dict[str, Any]]) -> None:
        """从数据库恢复上下文，并同步前缀一致性快照。

        无限上下文 LLM 要求前后缀严格一致；从数据库整体恢复上下文时，
        必须同步更新 ``_last_context_json``，否则下一次 ``_validate_prefix``
        的快照一致性校验会因来源不同而误报失败。
        """
        self.context = list(context)
        self._last_context_json = json.dumps(
            self.context, ensure_ascii=False, sort_keys=True
        )

    def _validate_prefix(self, user_message: str) -> None:
        """前缀一致性验证。

        无限上下文 LLM 要求新输入的前缀与当前上下文完全一致。
        验证逻辑：``new_input = self.context + [新消息]``，
        检查 ``new_input[:len(self.context)] == self.context``。

        额外检查：当前上下文应与上次对话结束时的快照一致，
        如果上下文在两次对话之间被外部修改（如删除或篡改消息），
        则前缀一致性被破坏，拒绝发送。

        前缀不一致时记录警告日志，并拒绝发送。
        """
        new_input = self.context + [{"role": "user", "content": user_message}]
        if new_input[: len(self.context)] != self.context:
            logger.warning(
                "前缀一致性验证失败, workspace=%s, model=%s",
                self.workspace_id,
                self.model_config.model_id,
            )
            # 生产环境：拒绝发送，抛出异常
            raise ValueError("前缀一致性验证失败")

        # 上下文快照一致性检查：与上次对话结束时的状态比较
        if self._last_context_json is not None:
            current_json = json.dumps(
                self.context, ensure_ascii=False, sort_keys=True
            )
            if current_json != self._last_context_json:
                logger.warning(
                    "上下文快照一致性验证失败, workspace=%s, model=%s",
                    self.workspace_id,
                    self.model_config.model_id,
                )
                raise ValueError("前缀一致性验证失败")

    def _compress_context(self) -> None:
        """无限上下文 LLM 不执行上下文压缩。

        上下文在对象生命周期内持久保留，新任务的消息继续追加到现有上下文。
        """
        # 空操作：不压缩
        return

    def compress(self, force: bool = False) -> bool:
        """无限上下文 LLM 不执行上下文压缩。"""
        # 空操作：不压缩
        return False

    # ------------------------------------------------------------------
    # 上下文持久化与崩溃恢复
    # ------------------------------------------------------------------
    def chat(self, user_message: str) -> Generator[Dict[str, Any], None, None]:
        """与 LLM 对话，流式输出（无限上下文版本）。

        复用父类对话逻辑（前缀验证、消息追加、调用 LLM），
        在回复完成后持久化上下文到工作空间，并更新上下文快照
        用于下次前缀一致性验证。

        :param user_message: 用户消息
        :return: 生成器，yield ``{"type": "text", "content": "..."}`` 或
                 ``{"type": "tool_call", "name": "...", "result": "..."}``
        """
        # 复用父类对话逻辑（前缀验证、消息追加、调用 LLM）
        yield from super().chat(user_message)
        # 回复完成后持久化上下文
        self._persist_context()
        # 更新上下文快照用于下次前缀一致性验证
        self._last_context_json = json.dumps(
            self.context, ensure_ascii=False, sort_keys=True
        )

    def _persist_context(self) -> None:
        """将当前上下文持久化到工作空间的 JSON 文件。

        将 self.context 序列化为 JSON，通过 docker_manager 写入
        ``/workspace/.self/context_snapshot.json``。使用 heredoc 方式写入，
        避免特殊字符转义问题。docker_manager 为 None 时跳过（测试环境）。
        """
        if self.docker_manager is None:
            logger.debug(
                "docker_manager 不可用，跳过上下文持久化, workspace=%s",
                self.workspace_id,
            )
            return

        try:
            context_json = json.dumps(self.context, ensure_ascii=False)
            # 使用 heredoc 写入文件，避免 JSON 中的特殊字符导致命令注入或转义问题
            command = [
                "sh", "-c",
                f"cat > /workspace/.self/context_snapshot.json << 'CONTEXT_EOF'\n"
                f"{context_json}\n"
                f"CONTEXT_EOF",
            ]
            result = self.docker_manager.exec_in_workspace(
                self.workspace_id, command
            )
            if result.get("exit_code", -1) != 0:
                logger.warning(
                    "上下文持久化失败: %s, workspace=%s",
                    result.get("stderr", result.get("detail", "")),
                    self.workspace_id,
                )
            else:
                logger.info(
                    "上下文已持久化，共 %d 条消息, workspace=%s",
                    len(self.context),
                    self.workspace_id,
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "上下文持久化异常: %s, workspace=%s",
                exc,
                self.workspace_id,
            )

    def _load_context_snapshot(self) -> bool:
        """从工作空间加载上下文快照。

        从 ``/workspace/.self/context_snapshot.json`` 读取上下文并反序列化。
        如果文件存在且解析成功，设置 self.context 并返回 True；
        如果文件不存在或解析失败，保持空上下文并返回 False。
        docker_manager 为 None 时直接返回 False（测试环境）。

        :return: 是否成功加载上下文
        """
        if self.docker_manager is None:
            logger.debug(
                "docker_manager 不可用，跳过上下文快照加载, workspace=%s",
                self.workspace_id,
            )
            return False

        try:
            result = self.docker_manager.exec_in_workspace(
                self.workspace_id,
                ["cat", "/workspace/.self/context_snapshot.json"],
            )
            # 文件不存在或读取失败
            if result.get("exit_code", -1) != 0:
                logger.debug(
                    "上下文快照不存在或读取失败, workspace=%s",
                    self.workspace_id,
                )
                return False

            content = result.get("stdout", "")
            if not content or not content.strip():
                return False

            snapshot = json.loads(content)
            if isinstance(snapshot, list):
                self.context = snapshot
                return True

            logger.warning(
                "上下文快照格式异常（非列表）, workspace=%s",
                self.workspace_id,
            )
            return False
        except (json.JSONDecodeError, Exception) as exc:  # noqa: BLE001
            logger.warning(
                "加载上下文快照异常: %s, workspace=%s",
                exc,
                self.workspace_id,
            )
            return False
