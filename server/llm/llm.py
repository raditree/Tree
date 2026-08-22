"""LLM 接入层 - 通过 OpenAI SDK 调用模型，支持普通 LLM 和无限上下文 LLM。"""

import json
import logging
import random
import re
import time
from typing import Any, Callable, Dict, Generator, List, Optional

from openai import OpenAI, RateLimitError

from config.config import get_config
from config.models import ModelConfig

logger = logging.getLogger(__name__)


def _stringify_tool_result(result: Any) -> str:
    """将工具执行结果转为前端可读字符串。

    dict 结果会被格式化为人类可读文本，而非原始 JSON / Python dict 字符串。
    策略：
    1. 优先提取 content / output / result / message / text 等字段
    2. 提取 error 字段
    3. 将剩余 key-value 格式化为 ``标签: 值`` 行（跳过元数据字段）
    """
    if isinstance(result, dict):
        # 1. 已知内容字段
        for key in ("content", "output", "result", "message", "text", "summary"):
            val = result.get(key)
            if val is not None and str(val).strip():
                return str(val)
        # 2. error 字段
        err = result.get("error")
        if err is not None:
            return f"错误: {err}"
        # 3. 格式化所有字段为可读文本（跳过元数据）
        skip = {"tool_name", "service", "isError"}
        lines = []
        for k, v in result.items():
            if k in skip:
                continue
            label = _FIELD_LABELS.get(k, k)
            if isinstance(v, list):
                lines.append(f"{label}: {len(v)} 项")
            elif isinstance(v, bool):
                lines.append(f"{label}: {'是' if v else '否'}")
            elif v is not None:
                lines.append(f"{label}: {v}")
        if lines:
            return "\n".join(lines)
        # 空dict
        return str(result) if result else "完成"
    return str(result)


# 常见字段名的中文标签
_FIELD_LABELS: Dict[str, str] = {
    "success": "成功",
    "status": "状态",
    "task_id": "任务ID",
    "member_id": "成员ID",
    "member_name": "成员名称",
    "file_path": "文件路径",
    "to": "目标",
    "from": "来源",
    "count": "数量",
    "total": "总数",
    "models": "模型列表",
    "members": "成员列表",
    "tasks": "任务列表",
    "tools": "工具列表",
    "level": "层级",
    "model_id": "模型",
    "name": "名称",
    "action": "操作",
    "description": "描述",
    "comment": "评价",
    "work_status": "工作状态",
}


def extract_usage_counts(usage: Any) -> Dict[str, int]:
    """从流式 usage chunk 中稳健解析 token 用量。

    兼容三种缓存字段口径：
    1. OpenAI 协议: ``usage.prompt_tokens_details.cached_tokens``
    2. DeepSeek 官方: 顶层 ``usage.prompt_cache_hit_tokens``（或
       ``prompt_cache_miss_tokens``，二者同时存在）
    3. 兼容网关: 顶层 ``usage.cached_tokens``

    同时做防御性钳制：缓存命中数不超过输入 token 总数，避免网关异常值
    导致成本计算为负或缓存占比超过 100%。

    :param usage: OpenAI SDK 的 completion usage 对象（或任意相似属性命名）
    :return: ``{"prompt_tokens", "completion_tokens", "cached_tokens"}``
    """
    prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or 0)
    completion_tokens = int(getattr(usage, "completion_tokens", 0) or 0)
    cached_tokens = 0

    # 1. OpenAI 协议：prompt_tokens_details.cached_tokens
    details = getattr(usage, "prompt_tokens_details", None)
    if details is not None:
        cached_tokens = int(getattr(details, "cached_tokens", 0) or 0)

    # 2. DeepSeek 官方：顶层 prompt_cache_hit_tokens（优先），
    #    prompt_cache_miss_tokens 可交叉验证
    if not cached_tokens:
        cached_tokens = int(getattr(usage, "prompt_cache_hit_tokens", 0) or 0)
        if not cached_tokens:
            miss = int(getattr(usage, "prompt_cache_miss_tokens", 0) or 0)
            if prompt_tokens and miss:
                cached_tokens = max(0, prompt_tokens - miss)

    # 3. 兼容网关：顶层 cached_tokens
    if not cached_tokens:
        cached_tokens = int(getattr(usage, "cached_tokens", 0) or 0)

    # 防御性钳制：缓存命中不超过输入 token，且不小于 0
    cached_tokens = max(0, min(cached_tokens, prompt_tokens))
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "cached_tokens": cached_tokens,
    }


class LLMClientFactory:
    """OpenAI SDK client 工厂。

    根据模型配置创建 OpenAI client，统一管理 client 的实例化逻辑。
    """

    @staticmethod
    def create_client(model_config: ModelConfig) -> OpenAI:
        """根据模型配置创建 OpenAI client。

        :param model_config: 模型配置，提供 base_url 与 api_key
        :return: openai.OpenAI 实例

        超时与重试次数为应用级配置（app.yaml 的 ``llm`` 段），未配置时
        使用默认值。长上下文 + thinking 模型响应可能很慢，但超时必须设
        上限，否则 API 挂起会导致前端永远显示 working（表现为卡死）。
        """
        llm_cfg = get_config().get("llm", {}) or {}
        timeout = float(llm_cfg.get("timeout_seconds", 300.0))
        max_retries = int(llm_cfg.get("max_retries", 1))
        return OpenAI(
            base_url=model_config.base_url,
            api_key=model_config.api_key,
            timeout=timeout,
            max_retries=max_retries,
        )


class AgentLLMSession:
    """单个 agent 的 LLM 会话管理（普通 LLM）。

    普通上下文 LLM 的会话管理：维护上下文列表、注册工具、流式调用 LLM、
    处理 tool_call 循环、并在上下文接近 max_seqlen 时执行压缩。
    """

    # 上下文压缩：保留最近 N 次用户要求原文（重要，保持不变）
    KEEP_RECENT_USER_MSGS: int = 3
    # 上下文压缩阈值比例（达到 max_seqlen 的 80% 时触发）
    COMPRESS_THRESHOLD: float = 0.8
    # 调用 LLM 总结时，截断送入总结器的最长文本长度（控制成本）
    SUMMARIZE_CHAR_LIMIT: int = 12000

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

        # 是否启用 thinking（推理）模式：ModelConfig 顶层布尔字段（默认 false）。
        # 仅 when True 时解析流式 reasoning_content 并产生 thinking 段。
        self.thinking: bool = bool(model_config.thinking)

        # 注册的 tool_call 函数列表
        self.registered_tools: List[Dict[str, Any]] = []

        # 最近一次 API 调用的 token 用量（流式响应末尾携带）
        self.last_usage: Optional[Dict[str, int]] = None

        # 上一次 API 调用返回的 prompt_tokens 与当时的上下文消息条数，
        # 用于准确估算当前上下文 token 数（避免 len(str)//4 对中文低估）
        self._last_prompt_tokens: Optional[int] = None
        self._context_len_at_last_call: int = 0

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
            "model": self.model_config.api_model_id or self.model_config.model_id,
            "messages": self.context,
            "stream": True,
            # 流式响应末尾返回 token 用量（OpenAI 规范：stream_options.include_usage）
            "stream_options": {"include_usage": True},
        }
        # temperature 仅在 yaml 显式配置或通过 set 工具设置时下发
        if self.temperature is not None:
            kwargs["temperature"] = self.temperature
        # thinking 模式仅用于解析流式 reasoning_content（见 _run_completion_loop），
        # 不作为 OpenAI 顶层参数透传——推理由模型配置的 extra_body.thinking 开启，
        # 顶层传 thinking 会被 OpenAI SDK 校验为未知参数而抛 TypeError。
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
        reserved = {
            "temperature", "top_k", "max_seqlen", "extra_body",
            "timeout_seconds", "max_retries",
            # 配置元数据字段（无 API 消费方，仅供展示/预算记录），不透传给 API
            "is_limitless_context",
            "input_price", "output_price", "cached_input_price",
        }
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

    def _create_completion(self, client: OpenAI, api_kwargs: Dict[str, Any]) -> Any:
        """调用 ``chat.completions.create``，触发 429 限流时指数退避重试。

        上游限流（如每分钟请求数上限）通常是短暂峰值，等待片刻后即可恢复；
        在最终抛错前给最多 5 次重试（间隔 5s → 60s，带随机抖动）。
        """
        max_attempts = 6  # 初始 1 次 + 重试 5 次
        for attempt in range(max_attempts):
            try:
                return client.chat.completions.create(**api_kwargs)
            except RateLimitError as exc:
                if attempt >= max_attempts - 1:
                    logger.warning("LLM 请求持续触发限流(429)，重试耗尽: %s", exc)
                    raise
                delay = min(60, 5 * (2 ** attempt)) * random.uniform(0.8, 1.2)
                logger.warning(
                    "LLM 请求触发限流(429)，%.1fs 后重试 %d/%d: %s",
                    delay,
                    attempt + 1,
                    max_attempts - 1,
                    exc,
                )
                time.sleep(delay)

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
            # 长任务 tool 循环中上下文会持续增长，每轮调用前检查是否需要及时压缩，
            # 避免任务结束前上下文就已超过 max_seqlen（约定阈值）
            self._compress_context()

            api_kwargs = self._build_api_kwargs()
            stream = self._create_completion(client, api_kwargs)

            content_parts: List[str] = []
            tool_calls: List[Dict[str, str]] = []
            # thinking（推理）分片累积：仅当模型启用 thinking 时收集
            thinking_parts: List[str] = []
            finish_reason: Optional[str] = None
            # usage 记账守卫：include_usage 下规范只应出现一个 usage chunk，
            # 但网关异常时可能重复，仅记录一次避免重复计费翻倍
            usage_recorded = False

            # 流式接收响应
            for chunk in stream:
                # 流式末尾的 usage chunk 无 token，但携带 token 用量
                usage = getattr(chunk, "usage", None)
                if usage is not None:
                    if usage_recorded:
                        # 防御：同一响应中重复的 usage chunk 只记一次，避免预算重复统计
                        continue
                    usage_recorded = True
                    counts = extract_usage_counts(usage)
                    prompt_tokens = counts["prompt_tokens"]
                    completion_tokens = counts["completion_tokens"]
                    cached_tokens = counts["cached_tokens"]
                    self.last_usage = {
                        "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens,
                        "total_tokens": getattr(usage, "total_tokens", 0) or 0,
                        "cached_tokens": cached_tokens,
                    }
                    # 记录真实 prompt_tokens，供后续压缩判断使用精确值
                    self._last_prompt_tokens = prompt_tokens
                    self._context_len_at_last_call = len(self.context)
                if not chunk.choices:
                    continue
                choice = chunk.choices[0]
                delta = choice.delta
                finish_reason = choice.finish_reason

                # 流式输出文本
                if delta.content:
                    content_parts.append(delta.content)
                    yield {"type": "text", "content": delta.content}

                # thinking（推理）内容：DeepSeek 采用 reasoning_content，
                # 兼容部分端点用 reasoning 字段。仅模型启用 thinking 时产出思考段
                reasoning = getattr(delta, "reasoning_content", None)
                if reasoning is None:
                    reasoning = getattr(delta, "reasoning", None)
                if reasoning:
                    if self.thinking:
                        thinking_parts.append(reasoning)
                        yield {"type": "thinking", "content": reasoning}
                    # thinking 未启用时不推送给前端（thinking 文本不进 content）

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
            # thinking 全文（供上下文回写：原样保留 reasoning_content 字段，
            # 避免同一 assistant 消息进入下一轮时网关 400）
            thinking_text = "".join(thinking_parts) if self.thinking else ""

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
                # thinking 内容原样回写进 assistant 消息，供下一轮上下文回传网关
                if thinking_text:
                    assistant_msg["reasoning_content"] = thinking_text
                self.context.append(assistant_msg)

                # 执行每个 tool_call
                for tc in tool_calls:
                    handler = self._find_handler(tc["name"])
                    # 参数与结果：默认空参数，解析失败/未找到 handler 时
                    # 仍能安全 yield（避免 yield 引用未定义变量）
                    args = {}
                    if handler is not None:
                        try:
                            args = self._safe_parse_arguments(tc["arguments"])
                            result = handler(**args)
                        except Exception as exc:  # noqa: BLE001
                            logger.exception("工具 %s 执行出错", tc["name"])
                            result = f"工具执行出错: {exc}"
                    else:
                        result = f"未找到工具: {tc['name']}"

                    # dict 结果提取可读内容，避免前端显示原始 dict 字符串
                    result_str = _stringify_tool_result(result)

                    yield {
                        "type": "tool_call",
                        "name": tc["name"],
                        "arguments": args,
                        "result": result_str,
                    }

                    # 将工具结果添加到上下文
                    self.context.append({
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": result_str,
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
                final_msg: Dict[str, Any] = {
                    "role": "assistant", "content": full_content,
                }
                # thinking 内容原样回写（最终回复也需回传网关）
                if thinking_text:
                    final_msg["reasoning_content"] = thinking_text
                self.context.append(final_msg)
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

    def _estimate_context_tokens(self) -> int:
        """估算当前上下文 token 数。

        优先基于上一次 API 调用返回的真实 ``prompt_tokens``（它反映了完整
        上下文的实际 token 数，对中文内容尤为准确），再叠加自上轮调用后新增
        消息的粗略估算（``len(str)//4``）。无历史调用时回退到字符数估算。

        返回时与字符估算取较大值：字符估算对中文可能低估，而真实
        ``prompt_tokens`` 在上下文被压缩/回滚后可能失真（锚点失效），
        取大值能确保压缩阈值判断不因估算偏低而漏触发。

        :return: 估算的上下文 token 总数
        """
        char_est = sum(len(str(m)) // 4 for m in self.context)
        base = getattr(self, "_last_prompt_tokens", None)
        if base is not None:
            anchor = getattr(self, "_context_len_at_last_call", 0)
            added = sum(len(str(m)) // 4 for m in self.context[anchor:])
            return max(base + added, char_est)
        return char_est

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

        压缩策略（针对"长程任务"重新设计）：
        - 系统提示词（system 消息）始终保留。
        - 保留最近 ``KEEP_RECENT_USER_MSGS`` 次用户要求原文，以及它们之后
          的所有消息（即当前任务上下文原样保留，不丢失用户最新指示）。
        - 更早的消息调用 LLM 总结工具调用轨迹与任务上下文，生成一条 summary，
          替换进上下文。

        返回是否实际执行了压缩。
        """
        # 估算总 token 数：优先使用上一次 API 返回的真实 prompt_tokens
        # （反映完整上下文实际 token 数），再叠加自上轮调用后新增消息的
        # 粗略估算；无历史调用时回退到字符数估算。
        total_tokens = self._estimate_context_tokens()

        # 未超过阈值，且非强制压缩时跳过
        threshold = int(self.max_seqlen * self.COMPRESS_THRESHOLD)
        if not force and total_tokens <= threshold:
            return False

        # 分离 system 消息与其他消息
        system_msgs: List[Dict[str, Any]] = [
            msg for msg in self.context if msg.get("role") == "system"
        ]
        other_msgs: List[Dict[str, Any]] = [
            msg for msg in self.context if msg.get("role") != "system"
        ]

        # 定位"需保留的起点"：保留最近 N 次用户要求及其后的所有消息。
        user_indices = [
            i for i, m in enumerate(other_msgs) if m.get("role") == "user"
        ]
        if len(other_msgs) <= 1:
            return False
        if user_indices:
            # 保留最近 KEEP_RECENT_USER_MSGS 次用户要求；不足时从第一条用户消息起保留
            keep_from = user_indices[
                max(0, len(user_indices) - self.KEEP_RECENT_USER_MSGS)
            ]
        else:
            # 没有用户消息（异常态），保留最近若干条
            keep_from = max(0, len(other_msgs) - 5)

        to_summarize = other_msgs[:keep_from]
        to_keep = other_msgs[keep_from:]

        # 无可总结内容（最近 N 次用户要求已覆盖全部消息）
        if not to_summarize:
            return False

        # 调用 LLM 总结工具调用轨迹与任务上下文
        summary_text = self._summarize_with_llm(to_summarize)
        summary_msg = {"role": "system", "content": summary_text}

        # 在覆盖 self.context 前，归档一份完整的 pre-compact 上下文快照，
        # 供后期审计（含 LLM CoT / 工具调用轨迹原文）。回调由 main.py 注入，
        # 未注入时（如单测）静默跳过。reason 区分手动 compact 与自动压缩。
        archiver = getattr(self, "archive_context_callback", None)
        if archiver is not None:
            try:
                archiver(
                    list(self.context),
                    "compact" if force else "auto_compress",
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("归档 pre-compact 上下文失败(已忽略): %s", exc)

        # 重组上下文：system 消息 + 总结 + 保留的最近用户要求及其后消息
        self.context = system_msgs + [summary_msg] + to_keep

        # 重构 context 完成后重建 system prompt（spec「注入时机」）：注入最新
        # Spec 索引 / 已选 Spec 全文 / memory / 成员拓扑。回调由 chat.py 注入
        # （_make_system_prompt_rebuilder）；未注入（如单测）则静默跳过。
        # 自动压缩运行在后台线程、手动 compact 经 to_thread 调用，回调内
        # 读取 .self（反向 WS 阻塞）不会卡死事件循环。
        rebuilder = getattr(self, "system_prompt_rebuilder", None)
        if rebuilder is not None:
            try:
                new_prompt = rebuilder()
                if new_prompt:
                    self.system_prompt = new_prompt
                    for _i, _msg in enumerate(self.context):
                        if _msg.get("role") == "system":
                            self.context[_i] = {
                                "role": "system", "content": new_prompt,
                            }
                            break
                    logger.info(
                        "compact 后已重建 system prompt: workspace=%s",
                        self.workspace_id,
                    )
            except Exception as exc:  # noqa: BLE001
                logger.warning("compact 后重建 system prompt 失败(已忽略): %s", exc)

        # 压缩后 context 长度变化，旧的真实 prompt_tokens 锚点已失效；
        # 重置锚点让下次估算以字符估算重新校准，避免高估触发重复压缩
        self._last_prompt_tokens = None
        self._context_len_at_last_call = len(self.context)

        logger.info(
            "上下文已压缩: 总结 %d 条消息, 保留最近 %d 条用户要求及其后 %d 条, "
            "workspace=%s, model=%s, force=%s",
            len(to_summarize),
            self.KEEP_RECENT_USER_MSGS,
            len(to_keep),
            self.workspace_id,
            self.model_config.model_id,
            force,
        )
        return True

    def _summarize_with_llm(self, messages: List[Dict[str, Any]]) -> str:
        """调用 LLM 总结一段历史消息（工具调用轨迹 + 任务上下文）。

        单独发起一次非流式补全请求，不携带工具，避免递归调用工具导致死循环。
        失败时回退到朴素的截断式摘要，保证压缩流程不中断。

        :param messages: 需要被压缩的历史消息列表
        :return: 中文总结文本
        """
        # 构造输入的紧凑表示，控制长度
        compact_lines: List[str] = []
        for msg in messages:
            role = msg.get("role", "unknown")
            content = str(msg.get("content", ""))
            if role == "tool":
                content = "[工具结果] " + content[:300]
            elif role == "assistant" and msg.get("tool_calls"):
                content = "[工具调用] " + content[:300]
            else:
                content = content[:400]
            compact_lines.append(f"- [{role}] {content}")
        raw = "\n".join(compact_lines)
        if len(raw) > self.SUMMARIZE_CHAR_LIMIT:
            raw = raw[: self.SUMMARIZE_CHAR_LIMIT] + "\n...[截断]"

        summarize_prompt = (
            "你是上下文压缩器。以下是 agent 与用户、工具之间的一段历史对话，"
            "包含任务目标、已执行的工具调用轨迹与结果、以及当前进展。\n"
            "请用简洁的中文总结：1) 用户的任务目标与最新要求；2) 已完成的工具"
            "调用轨迹与关键结果；3) 当前进展与尚未完成的待办。保留必要的事实"
            "细节（文件名、路径、数字、结论），不要逐条复述原文。\n\n"
            f"历史对话：\n{raw}"
        )

        try:
            client = LLMClientFactory.create_client(self.model_config)
            resp = client.chat.completions.create(
                model=self.model_config.api_model_id or self.model_config.model_id,
                messages=[{"role": "user", "content": summarize_prompt}],
                temperature=0.2,
            )
            summary = ""
            if resp.choices:
                summary = resp.choices[0].message.content or ""
            summary = summary.strip()
            if summary:
                return (
                    "以下是此前对话的总结（上下文已被压缩，当前任务目标与最新"
                    "要求已保留在最近对话中）:\n"
                    + summary
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("LLM 总结失败，回退到截断摘要: %s", exc)

        # 回退：朴素截断式摘要
        title = "以下是此前的对话记录（上下文已被压缩，以下为历史要点）:"
        return title + "\n" + raw[:2000]
