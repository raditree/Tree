"""LLM 接入层 - 通过 OpenAI SDK 调用模型，支持普通 LLM 和无限上下文 LLM。"""

import json
import logging
import random
import re
import threading
import time
from typing import Any, Callable, Dict, Generator, List, Optional

from openai import BadRequestError, OpenAI, RateLimitError

from config.config import get_config
from config.models import ModelConfig
from prompt import versions

logger = logging.getLogger(__name__)

# AskUserQuestion 暂停哨兵：工具检测到提问后停止本轮，等用户作答再由后端唤醒
# （与 tool/ask_question_tool.py 的 ASK_PAUSED_KEY 一致，避免反向依赖）
_ASK_PAUSED_KEY = "__ask_paused__"


class _AskPaused(Exception):
    """发出"已向用户提问、本轮应暂停等待作答"的信号。

    由工具循环在 AskUserQuestion 返回哨兵时抛出，向上终止当前 chat() 循环，
    外层调用链据此持久化上下文并使 agent 归闲。
    """

    def __init__(self, qid: str = "") -> None:
        self.qid = qid
        super().__init__(qid)


# 列表字段展开上限（防止超大列表撑爆上下文）与项内字段上限
_MAX_LIST_ITEMS = 30
_MAX_ITEM_FIELDS = 8
_MAX_VALUE_CHARS = 120

# 工具结果大小门控：单个工具结果字符串超过该字符数时，不再直进上下文，
# 重定向到工作空间 .self 私有目录文件，只把「文件位置+查看建议+原因」给 agent
RESULT_REDIRECT_THRESHOLD = 10_000
# 重定向提示中附带的结果预览长度（让 agent 快速判断是否值得查看）
_REDIRECT_PREVIEW_CHARS = 300


def _fmt_value(v: Any, max_chars: int = _MAX_VALUE_CHARS) -> str:
    """把单个值格式化为可读文本（截断超长字符串）。"""
    if isinstance(v, bool):
        return "是" if v else "否"
    if isinstance(v, list):
        return f"{len(v)} 项"
    if isinstance(v, dict):
        return "{...}"
    s = str(v)
    if len(s) > max_chars:
        s = s[:max_chars] + "..."
    return s


def _fmt_list_item(item: Any) -> str:
    """把列表中的一项格式化为一行（dict 紧凑 key=value）。

    保留空值字段（如 ``model_id=``），让模型能感知字段存在但为空
    （配合自动回退机制，避免"看不到 model_id"而误判）。
    """
    if isinstance(item, dict):
        parts = []
        for k2, v2 in item.items():
            parts.append(f"{k2}={_fmt_value(v2)}")
            if len(parts) >= _MAX_ITEM_FIELDS:
                break
        return "  - " + ", ".join(parts)
    return "  - " + _fmt_value(item)


def _format_list_block(label: str, items: list) -> str:
    """把工具结果中的列表字段展开为逐项可读文本（而非只显示数量）。

    修复"list_models / spec list 等仅返回数量、模型拿不到具体内容"的
    类 no-op 问题：models/specs/teams/members/tasks/tools 等列表字段
    全部展开具体项，控制规模（最多 _MAX_LIST_ITEMS 项、每项最多
    _MAX_ITEM_FIELDS 字段）。
    """
    total = len(items)
    head = f"{label}: {total} 项"
    if total == 0:
        return head
    shown = items[:_MAX_LIST_ITEMS]
    body = [_fmt_list_item(it) for it in shown]
    if total > len(shown):
        body.append(f"  ... 还有 {total - len(shown)} 项")
    return head + "\n" + "\n".join(body)


def _stringify_tool_result(result: Any) -> str:
    """将工具执行结果转为前端可读字符串。

    dict 结果会被格式化为人类可读文本，而非原始 JSON / Python dict 字符串。
    策略：
    1. 优先提取 content / output / result / message / text 等字段
    2. 提取 error 字段
    3. 将剩余 key-value 格式化为 ``标签: 值`` 行（跳过元数据字段）；
       列表字段**展开具体项**（避免只给数量导致模型无法决策）。
    """
    if isinstance(result, dict):
        # 图像工具结果：不展开 base64 本体，输出摘要（前端展示友好）
        if result.get("image_base64"):
            mime = result.get("mime") or "image"
            fp = result.get("file_path") or ""
            size = len(str(result["image_base64"]))
            return f"已读取图像: {fp} ({mime}, base64 {size} 字符)"
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
                lines.append(_format_list_block(label, v))
            elif isinstance(v, dict):
                # dict 值（如 query_member 的 member）紧凑格式化，避免 Python repr
                lines.append(f"{label}:")
                lines.append(_fmt_list_item(v))
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
    "specs": "Spec列表",
    "teams": "团队列表",
    "commits": "提交历史",
    "files": "产出文件",
    "log_lines": "活动日志",
    "groups": "分组",
    "spec_ids": "已选Spec",
    "selected_spec_ids": "已选Spec",
    "member": "成员",
    "spec": "Spec",
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

        超时与重试次数优先取**模型级**配置（``model_config.extra`` 的
        ``timeout_seconds`` / ``max_retries``，支持本地大上下文模型长 prefill
        20min+），未配置时回退应用级默认（app.yaml ``llm`` 段，默认 300s / 1）。
        注意 OpenAI SDK 的 float timeout 同时覆盖 connect/read/总时长，流式
        接收按 chunk 重置——本地模型应显式调大 ``timeout_seconds``
        （如 1800~2400），否则首 token 前的 prefill 阶段即被 read 超时打断。
        """
        llm_cfg = get_config().get("llm", {}) or {}
        extra = getattr(model_config, "extra", {}) or {}
        timeout = float(
            extra.get("timeout_seconds", llm_cfg.get("timeout_seconds", 300.0))
        )
        max_retries = int(
            extra.get("max_retries", llm_cfg.get("max_retries", 1))
        )
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
    # 压缩时额外保留的最近消息条数（当前活动轮次尾部，保证工具序列连续）
    KEEP_TAIL_LENGTH: int = 8
    # 上下文压缩阈值比例（达到 max_seqlen 的 80% 时触发）
    COMPRESS_THRESHOLD: float = 0.8
    # 调用 LLM 总结时，截断送入总结器的最长文本长度（控制成本）
    SUMMARIZE_CHAR_LIMIT: int = 12000

    def __init__(
        self,
        model_config: ModelConfig,
        workspace_id: str,
        system_prompt: str = "",
        cancel_event: Optional[threading.Event] = None,
        user_id: str = "",
        agent_id: str = "",
        result_redirect_writer: Optional[Callable[[str, str], None]] = None,
    ) -> None:
        """初始化 LLM 会话。

        :param model_config: 模型配置
        :param workspace_id: 工作空间标识
        :param system_prompt: 系统提示词，普通 LLM 初始化时注入上下文
        :param cancel_event: 可选取消事件（前端"停止"按钮置位）。
                             置位后 ``_run_completion_loop`` 在每轮循环开始、
                             流式接收间隙与每次 tool_call 执行前退出，
                             使停止能快速中止 tool loop（不再启动新的工具调用）。
        :param user_id: 用户标识（主动延迟限流按用户开关判定）
        :param agent_id: agent 标识（主动延迟限流按 (user_id, agent_id) 粒度）
        :param result_redirect_writer: 可选同步回调 ``(rel_path, content) -> None``，
            用于把超长工具结果写入工作空间（如 ``.self/results/...``）；为 None
            时超长结果退化为本地截断。回调由 chat.py 注入，与内置工具共用
            同一 WorkspaceIO 通道，保证 .self 路径语义一致。
        """
        self.model_config = model_config
        self.workspace_id = workspace_id
        self.system_prompt = system_prompt
        self.cancel_event = cancel_event
        # 主动延迟限流归属：REST 设置接口按 openid 开关，限流器按 (user, agent)
        self.user_id = user_id or ""
        self.agent_id = agent_id or ""
        # 工具结果重定向写入器与重定向文件序号（会话级，工具循环单线程执行）
        self.result_redirect_writer = result_redirect_writer
        self._redirect_seq = 0

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
    # 工具结果大小门控
    # ------------------------------------------------------------------
    def _maybe_redirect_result(self, tool_name: str, result_str: str) -> str:
        """工具结果大小门控：超长结果重定向到 .self 私有文件，只返回提示。

        ``result_str`` 超过 :data:`RESULT_REDIRECT_THRESHOLD` 字符时：
        - 有写入器（``self.result_redirect_writer``）：把完整结果写入
          ``.self/results/<时间戳>_<序号>.<工具名>.result``，返回重定向提示
          （文件位置 + 推荐查看方式 + 原因 + 预览片段）；
        - 无写入器或写入失败：退化为本地截断，保证上下文始终有界。

        :param tool_name: 工具名（用于重定向文件名）
        :param result_str: 工具结果的字符串化文本
        :return: 写回上下文 / 展示的文本（原文本、重定向提示或截断文本）
        """
        if len(result_str) <= RESULT_REDIRECT_THRESHOLD:
            return result_str

        if self.result_redirect_writer is not None:
            try:
                self._redirect_seq += 1
                ts = time.strftime("%Y%m%d_%H%M%S")
                rel = (
                    f".self/results/{ts}_{self._redirect_seq:03d}."
                    f"{tool_name}.result"
                )
                self.result_redirect_writer(rel, result_str)
                return (
                    f"[工具结果已重定向] {tool_name} 返回结果过长"
                    f"（{len(result_str)} 字符 > {RESULT_REDIRECT_THRESHOLD} "
                    f"阈值），完整结果已写入私有文件 {rel}，未直接展示。\n"
                    f"如需查看：\n"
                    f"1) 用 read 工具对该文件分多次读取"
                    f"（start_line / line_count 控制范围）；\n"
                    f"2) 或用 terminal 工具（grep / sed / python 等）对文件"
                    f"进一步正则化解析，提取需要的有效信息。\n"
                    f"文件预览（前 {_REDIRECT_PREVIEW_CHARS} 字符）：\n"
                    f"{result_str[:_REDIRECT_PREVIEW_CHARS]}"
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "工具结果重定向写入失败（%s），退化为截断: %s",
                    tool_name, exc,
                )

        # 无写入能力或写入失败：退化为本地截断
        return (
            result_str[:RESULT_REDIRECT_THRESHOLD]
            + f"\n...[结果过长，共 {len(result_str)} 字符，已截断至 "
            f"{RESULT_REDIRECT_THRESHOLD} 字符]"
        )

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

        视觉模型（``if_vision=True``）会先把上下文中的"含图像用户消息"
        转为 OpenAI vision content 数组格式（``content: [{type:text},
        {type:image_url}]``）；非视觉模型不转换（天然降级，图像字段被忽略）。
        """
        # 视觉消息格式转换（仅当模型 if_vision=true 时执行）
        if self.model_config.if_vision:
            messages = self._convert_vision_messages(self.context)
        else:
            messages = self.context
        # 防御式修复：保证 tool 序列对网关合法（孤立 tool 丢弃 / 缺失响应补占位），
        # 避免压缩截断或恢复造成的 400 直接击倒 agent
        messages = self._sanitize_messages(messages)
        kwargs: Dict[str, Any] = {
            "model": self.model_config.api_model_id or self.model_config.model_id,
            "messages": messages,
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
            # 视觉能力开关是配置元数据，不透传给 API（防 OpenAI SDK 未知参数校验）
            "if_vision",
        }
        for key, value in extra.items():
            if key not in reserved:
                kwargs[key] = value
        kwargs["extra_body"] = extra_body
        return kwargs

    @staticmethod
    def _convert_vision_messages(
        context: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        """将上下文中的"含图像用户消息"转为 OpenAI vision content 数组格式。

        约定：``role == "user"`` 且 ``content`` 为 dict（含 ``text`` 与
        ``image_base64``/``image_url`` 字段）的消息为含图消息；转换为
        ``content: [{type:"text", text}, {type:"image_url", image_url:{url}}]``。
        dict content 之外的普通字符串消息原样保留。

        由调用方（``_build_api_kwargs``）仅在视觉模型（``if_vision=True``）
        时调用；非视觉模型不调用本方法（图像已在工具结果写入处降级）。
        """
        converted: List[Dict[str, Any]] = []
        for msg in context:
            content = msg.get("content")
            if (
                msg.get("role") == "user"
                and isinstance(content, dict)
                and content.get("image_base64")
            ):
                mime = content.get("mime", "image/png")
                data_url = (
                    content.get("image_url")
                    or f"data:{mime};base64,{content['image_base64']}"
                )
                parts: List[Dict[str, Any]] = []
                text = content.get("text", "")
                if text:
                    parts.append({"type": "text", "text": text})
                parts.append(
                    {"type": "image_url", "image_url": {"url": data_url}}
                )
                converted.append({"role": "user", "content": parts})
            else:
                converted.append(msg)
        return converted

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

    @staticmethod
    def _sanitize_messages(
        messages: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        """容错修复消息列表，保证工具序列对网关合法（类似 _safe_parse_arguments）。

        OpenAI 兼容网关对 tool 序列有严格要求，不合法会直接 400（如
        ``Messages with role 'tool' must be a response to a preceding message
        with 'tool_calls'``）。压缩截断、会话恢复、或图像 user 消息插入
        （``_append_image_user_msg``）都可能把序列弄坏。这里是纯函数式防御
        修复，双向处理：
        1. ``tool`` 消息缺少前置匹配的 assistant ``tool_calls``（孤立 tool，
           多为压缩截断残留）→ 丢弃；
        2. assistant ``tool_calls`` 缺少对应 ``tool`` 响应（多为中途被取消
           遗留）→ 补占位消息，让模型知道该工具调用被中止。

        不修改入参；无变化时返回原列表引用（避免无谓拷贝）。
        """
        if not messages:
            return messages
        have = {
            m.get("tool_call_id")
            for m in messages
            if m.get("role") == "tool" and m.get("tool_call_id")
        }
        out: Optional[List[Dict[str, Any]]] = None  # 惰性创建：仅在需要修复时
        declared: set = set()  # 已由前置 assistant tool_calls 声明的 id
        for i, msg in enumerate(messages):
            if msg.get("role") == "assistant" and msg.get("tool_calls"):
                if out is not None:
                    out.append(msg)
                for tc in msg["tool_calls"]:
                    tid = tc.get("id")
                    if tid:
                        declared.add(tid)
                    if tid and tid not in have:
                        if out is None:
                            out = messages[:i + 1]
                        out.append(
                            {
                                "role": "tool",
                                "tool_call_id": tid,
                                "content": "[已中止：任务被用户停止，该工具调用未返回结果]",
                            }
                        )
                        have.add(tid)
            elif msg.get("role") == "tool":
                tid = msg.get("tool_call_id")
                if tid and tid not in declared:
                    # 孤立 tool：丢弃（其原始轮次已提供给模型，属残留）
                    if out is None:
                        out = messages[:i]
                    continue
                if tid in declared:
                    declared.discard(tid)
                if out is not None:
                    out.append(msg)
            elif out is not None:
                out.append(msg)
        fixed = out if out is not None else messages
        # 步骤 2：重排 tool 响应紧随归属 assistant（修复历史版本把图像 user
        # 消息插入并行 tool 响应之间造成的「tool 响应不足」400）
        return AgentLLMSession._reflow_tool_responses(fixed)

    @staticmethod
    def _reflow_tool_responses(
        messages: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        """把每个 assistant tool_calls 的 tool 响应重排为紧随其后、连续排列。

        OpenAI 兼容网关（含 DeepSeek）要求 ``tool`` 响应必须紧跟声明它们的
        assistant 消息，中间出现任何其他消息（如历史版本 ``_append_image_user_msg``
        在并行工具结果之间插入的 user(图像)）都会被判定为「tool 响应不足」而
        400。此方法把夹在 tool 响应之间的非 tool 消息移到该轮最后一个 tool
        响应之后，恢复合法序列。

        纯函数，不修改入参；未发生重排时返回原列表引用。
        """
        if not messages:
            return messages
        out: List[Dict[str, Any]] = []
        changed = False
        i = 0
        n = len(messages)
        while i < n:
            msg = messages[i]
            if msg.get("role") == "assistant" and msg.get("tool_calls"):
                declared = {tc.get("id") for tc in msg["tool_calls"] if tc.get("id")}
                out.append(msg)
                i += 1
                if not declared:
                    continue  # 无 id 可校验，无法界定该轮范围，原样保留
                seen: set = set()
                pending: List[Dict[str, Any]] = []
                # 收集本轮全部 tool 响应；夹杂的非 tool 消息先缓存，轮末回填
                while i < n:
                    cur = messages[i]
                    tid = cur.get("tool_call_id")
                    if (
                        cur.get("role") == "tool"
                        and tid in declared
                        and tid not in seen
                    ):
                        out.append(cur)
                        seen.add(tid)
                        i += 1
                        if seen == declared:
                            break
                    else:
                        pending.append(cur)
                        i += 1
                if pending:
                    changed = True
                out.extend(pending)
                continue
            out.append(msg)
            i += 1
        return out if changed else messages

    def _create_completion(
        self,
        client: OpenAI,
        api_kwargs: Dict[str, Any],
        cancel_event: Optional[threading.Event] = None,
    ) -> Any:
        """调用 ``chat.completions.create``，触发 429 限流时指数退避重试。

        上游限流（如每分钟请求数上限）通常是短暂峰值，等待片刻后即可恢复；
        在最终抛错前给最多 5 次重试（间隔 5s → 60s，带随机抖动）。

        :param cancel_event: 取消事件（「停止」按钮置位）。重试等待期间
                             检查取消：已停止时不等待直接返回 None，避免
                             限流重试拖慢停止响应。
        :return: 流式响应；被取消时返回 None
        """
        max_attempts = 6  # 初始 1 次 + 重试 5 次
        for attempt in range(max_attempts):
            # 重试间隙/等待前检查取消：已停止不再发起新的 API 调用
            if self._is_cancelled(cancel_event):
                return None
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
                # 等待期间分片检查取消：已停止则放弃重试（停止优先于限流等待）
                deadline = time.time() + delay
                while time.time() < deadline:
                    if self._is_cancelled(cancel_event):
                        return None
                    time.sleep(min(0.2, deadline - time.time()))

    def _create_completion_guarded(
        self,
        client: OpenAI,
        cancel_event: Optional[threading.Event] = None,
    ) -> Any:
        """构建请求并调用 LLM；上下文非法导致 400 时修复上下文后重试一次。

        压缩/恢复可能把上下文截成非法 tool 序列（网关 400「tool 消息必须紧跟
        assistant tool_calls」）。若直接抛出，消费线程会把它当致命错误终止，
        使单个工具/上下文错误击倒整个 agent。这里捕获 ``BadRequestError``，
        调用 ``_repair_context`` 自愈后重建请求重试一次；二次失败仍抛出，
        由上层照常处理（避免掩盖真正的请求错误）。
        """
        api_kwargs = self._build_api_kwargs()
        try:
            return self._create_completion(client, api_kwargs, cancel_event)
        except BadRequestError:
            logger.warning(
                "LLM 请求 400（可能上下文含非法 tool 序列），修复上下文后重试一次"
            )
            self._repair_context()
            api_kwargs = self._build_api_kwargs()
            return self._create_completion(client, api_kwargs, cancel_event)

    def _tool_context_content(self, result: Any, result_str: str) -> Any:
        """构造写入上下文的工具结果 content。

        图像工具结果（dict 含 ``image_base64``）：
        - 工具消息本身只保留文本摘要（``result_str`` 已含"已读取图像"提示），
          图像本体经调用点追加为独立 ``user`` 消息（``_append_image_user_msg``），
          兼容仅支持 user 消息携带图像的各网关；
        - 非视觉模型 → 文本降级提示（``if_vision`` 缺失/ false），避免网关 400。
        其余结果原样返回字符串（与旧行为一致）。
        """
        if isinstance(result, dict) and result.get("image_base64"):
            if not self.model_config.if_vision:
                fp = result.get("file_path", "")
                return (
                    f"图像 {fp} 已读取，但当前模型不支持图像输入"
                    "（if_vision=false），无法解析图像内容。"
                )
            return result_str
        return result_str

    def _build_image_user_msg(self, result: Any) -> Optional[Dict[str, Any]]:
        """构造携带图像的 user 消息（供视觉模型下一轮消费），不追加。

        仅当结果含 ``image_base64`` 且模型开启视觉时返回消息，否则返回
        ``None``。调用方决定何时写入上下文：主工具循环会在本轮全部 tool
        响应追加完毕后统一写入，避免图像 user 消息夹在并行 tool 响应之间
        导致网关 400。

        content 为 dict（``text`` + ``image_base64`` + ``mime``），
        ``_build_api_kwargs`` 中的 ``_convert_vision_messages`` 会在请求
        构建时转成 OpenAI vision content 数组格式。
        """
        if not (isinstance(result, dict) and result.get("image_base64")):
            return None
        if not self.model_config.if_vision:
            return None
        return {
            "role": "user",
            "content": {
                "text": f"[图像读取结果] {result.get('file_path', '')}",
                "image_base64": str(result["image_base64"]),
                "mime": result.get("mime") or "image/png",
            },
        }

    def _append_image_user_msg(self, result: Any) -> None:
        """图像工具结果：立即把图像 user 消息追加进上下文。

        立即追加仅在单工具轮次下安全；并行工具轮次请改用
        ``_build_image_user_msg`` 收集后统一写入（见主工具循环）。
        """
        msg = self._build_image_user_msg(result)
        if msg is not None:
            self.context.append(msg)

    def _is_cancelled(
        self, cancel_event: Optional[threading.Event] = None
    ) -> bool:
        """检查取消事件是否已置位（前端"停止"按钮中止 tool loop）。

        :param cancel_event: 本次调用显式传入的取消事件；为 None 时回退到
                             会话级 ``self.cancel_event``（构造时注入）。
        :return: True 表示应中止当前回复生成
        """
        evt = cancel_event if cancel_event is not None else self.cancel_event
        return evt is not None and evt.is_set()

    def _acquire_rate_limit(
        self, cancel_event: Optional[threading.Event] = None
    ) -> bool:
        """主动延迟：开启时限制单个 agent 的 API 调用频率（平均 6 次/分钟）。

        - 用户未开启 / 会话未绑定 user_id/agent_id 时直接放行。
        - 等待令牌期间可响应 ``cancel_event``（「停止」按钮），收到取消
          立即返回 False，调用方中止本轮 API 调用（不拖慢停止）。
        :return: False 表示应中止本轮 API 调用
        """
        if not self.user_id or not self.agent_id:
            return True
        from llm.rate_limit import acquire

        return acquire(self.user_id, self.agent_id, cancel_event)

    def _run_completion_loop(
        self,
        client: OpenAI,
        on_tool_turn: Optional[Callable[[], str]] = None,
        cancel_event: Optional[threading.Event] = None,
    ) -> Generator[Dict[str, Any], None, None]:
        """运行 LLM 流式调用 + tool_call 循环。

        不断调用 LLM 直到返回最终文本（无 tool_call）。
        yield ``{"type": "text", "content": "..."}`` 或
        ``{"type": "tool_call", "name": "...", "result": "..."}``。

        :param on_tool_turn: 可选回调，在每次 tool_call 处理完、进入下一轮
                             调用前被调用。若返回非空字符串，则将其作为一条
                             user 消息插入上下文，供下一轮 LLM 处理（用于
                             在成员工作的间隙切入 leader 发来的新消息）。
        :param cancel_event: 可选取消事件；未传入时回退到会话级
                             ``self.cancel_event``（构造时注入）。
        """
        while True:
            # 停止中止：每轮循环开始检查取消事件（阻塞环节之间的间隙可响应停止）
            if self._is_cancelled(cancel_event):
                return
            # 长任务 tool 循环中上下文会持续增长，每轮调用前检查是否需要及时压缩，
            # 避免任务结束前上下文就已超过 max_seqlen（约定阈值）
            self._compress_context()

            # 主动延迟：开启时限制该 agent 的 API 调用频率（平均 6 次/分钟）。
            # 等待令牌期间若收到「停止」事件则中止本轮（与停止级联配合）。
            if not self._acquire_rate_limit(cancel_event):
                return

            stream = self._create_completion_guarded(client, cancel_event)
            if stream is None:
                # 已停止：_create_completion 在发起前或重试等待期间检测到取消
                return

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
                # 停止中止：流式接收间隙检查取消（响应较快时也能及时停止）
                if self._is_cancelled(cancel_event):
                    return
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
                pending_image_msgs: List[Dict[str, Any]] = []
                for tc in tool_calls:
                    # 停止中止：每次 tool_call 执行前检查取消，
                    # 已停止时不再启动新的工具调用（阻塞工具可被跳过）
                    if self._is_cancelled(cancel_event):
                        return
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

                    # AskUserQuestion 暂停：写入占位 tool 结果以保持上下文一致，
                    # 然后抛出哨兵终止本轮（agent 归闲，等用户作答后由后端唤醒）。
                    if isinstance(result, dict) and result.get(_ASK_PAUSED_KEY):
                        self.context.append({
                            "role": "tool",
                            "tool_call_id": tc["id"],
                            "content": (
                                f"等待用户回答..."
                            ),
                        })
                        raise _AskPaused(str(result.get("qid", "")))

                    # dict 结果提取可读内容，避免前端显示原始 dict 字符串
                    result_str = _stringify_tool_result(result)
                    # 工具结果大小门控：超长结果重定向到 .self 文件，
                    # 上下文/前端/历史表三处均只携带重定向提示
                    result_str = self._maybe_redirect_result(
                        tc["name"], result_str
                    )

                    yield {
                        "type": "tool_call",
                        "name": tc["name"],
                        "arguments": args,
                        "result": result_str,
                    }

                    # 将工具结果添加到上下文（含图像时按模型视觉能力构造 content）
                    # 注入会话级 current_todo_id：让每次工具返回都带给模型当前
                    # in_progress 的 todo，约束其及时增量更新 todo 进度。
                    base_content = self._tool_context_content(result, result_str)
                    status_provider = getattr(self, "current_todo_status", None)
                    current_todo_text = ""
                    if status_provider is not None:
                        try:
                            current_todo_text = str(status_provider() or "")
                        except Exception:  # noqa: BLE001
                            current_todo_text = ""
                    if current_todo_text:
                        base_content = (
                            f"当前 in_progress todo（current_todo_id）：\n"
                            f"{current_todo_text}\n\n"
                            f"{base_content}"
                        )
                    # 注入会话级 selected spec 状态：与 todo 一样随每次工具
                    # 返回带给模型，督促其始终挂接至少一个内置 Spec
                    # （easy/complex/hard/team-meeting）。
                    spec_provider = getattr(self, "current_spec_status", None)
                    current_spec_text = ""
                    if spec_provider is not None:
                        try:
                            current_spec_text = str(spec_provider() or "")
                        except Exception:  # noqa: BLE001
                            current_spec_text = ""
                    if current_spec_text:
                        base_content = (
                            f"当前 selected spec（selected spec）：\n"
                            f"{current_spec_text}\n\n"
                            f"{base_content}"
                        )
                    self.context.append({
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": base_content,
                    })
                    # 视觉模型：图像本体追加为独立 user 消息（网关兼容）。
                    # 注意不能在此处立即插入——若本轮有多个并行 tool_call，
                    # 图像 user 消息会夹在 tool 响应之间，网关判定「tool 响应
                    # 不足」直接 400（assistant tool_calls 后必须紧跟连续 tool
                    # 响应）。先收集，待本轮 tool 响应全部追加后再统一入上下文。
                    img_msg = self._build_image_user_msg(result)
                    if img_msg is not None:
                        pending_image_msgs.append(img_msg)

                # 本轮全部 tool 响应追加完毕后再追加图像 user 消息，保持
                # tool 响应紧随归属 assistant，避免网关 400
                for img_msg in pending_image_msgs:
                    self.context.append(img_msg)

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
        cancel_event: Optional[threading.Event] = None,
    ) -> Generator[Dict[str, Any], None, None]:
        """与 LLM 对话，流式输出。

        将用户消息添加到上下文，检查是否需要压缩上下文，然后调用 LLM。
        处理 tool_call 循环，直到返回最终文本。

        :param user_message: 用户消息
        :param on_tool_turn: 可选回调，在每次 tool_call 间隙被调用，若返回
                             新消息文本则切入处理（见 _run_completion_loop）
        :param cancel_event: 可选取消事件（"停止"按钮置位）。置位后在每轮
                             循环开始、流式接收间隙与每次 tool_call 执行前
                             退出生成器，使停止能快速中止 tool loop。
        :return: 生成器，yield ``{"type": "text", "content": "..."}`` 或
                 ``{"type": "tool_call", "name": "...", "result": "..."}``
        """
        # 前缀一致性验证（普通 LLM 无需验证，由子类覆盖）
        self._validate_prefix(user_message)

        # 自愈：中途「停止」/异常可能在 cancellation 点把上下文停在「assistant 带
        # tool_calls 但缺对应 tool 响应」的不一致状态，网关下轮必返 400。每次对话
        # 前修复，保证上下文对网关始终合法（保留历史，仅补充占位 tool 响应）。
        self._repair_context()

        # 将用户消息添加到上下文
        self.context.append({"role": "user", "content": user_message})

        # 检查是否需要压缩上下文（普通 LLM 执行压缩，无限上下文 LLM 覆盖为空操作）
        self._compress_context()

        client = LLMClientFactory.create_client(self.model_config)

        yield from self._run_completion_loop(
            client, on_tool_turn=on_tool_turn, cancel_event=cancel_event
        )

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

    @staticmethod
    def _legal_tail_start(other_msgs: List[Dict[str, Any]], start: int) -> int:
        """把截断起点回退到合法边界，保证 tail 内无孤立 tool 消息。

        后缀若以 ``role == "tool"`` 的消息开头，会引用已不在保留范围内的
        assistant tool_calls，导致对网关非法（400）。早期版本
        ``_append_image_user_msg`` 会在并行工具的结果之间插入 user（图像）
        消息，使 tool 响应与归属 assistant 不再连续（现已改为轮末统一追加，
        历史遗留数据仍可能存在）；因此不能只回退连续 tool 消息，需逐条校验
        tail 内每个 tool 消息都有前置匹配的 assistant tool_calls，否则把起点
        回退到其归属 assistant 重新扫描。

        :param other_msgs: 非 system 消息列表
        :param start: 期望的截断起点
        :return: 回退后的合法起点（不小于 0）
        """
        if start >= len(other_msgs):
            return start  # 空尾部（最后一条用户消息之后无内容）
        n = len(other_msgs)
        while 0 < start < n:
            declared = set()  # 当前已由前置 assistant tool_calls 声明的 id
            need_back = False
            for i in range(start, n):
                msg = other_msgs[i]
                if msg.get("role") == "assistant" and msg.get("tool_calls"):
                    for tc in msg["tool_calls"]:
                        tid = tc.get("id")
                        if tid:
                            declared.add(tid)
                elif msg.get("role") == "tool":
                    tid = msg.get("tool_call_id")
                    if tid and tid not in declared:
                        # 孤立 tool：归属 assistant 在 tail 之外，回退包含它
                        owner = None
                        for j in range(i - 1, -1, -1):
                            pm = other_msgs[j]
                            if pm.get("role") == "assistant" and pm.get("tool_calls"):
                                if tid in {tc.get("id") for tc in pm["tool_calls"]}:
                                    owner = j
                                    break
                        need_back = True
                        # 找不到归属（历史数据已损坏）时回退到 0，
                        # 交由 _repair_context 移除孤立 tool
                        start = owner if owner is not None else 0
                        break
            if not need_back:
                break
        return max(start, 0)

    def _repair_context(self) -> None:
        """修复上下文不一致并写回，保证后续请求对网关始终合法。

        消费线程在 ``yield`` 处被取消（GeneratorExit）、压缩截断或历史数据
        损坏都可能留下非法序列（孤立 tool / 缺失响应），网关下轮必返 400
        （问题会一直卡死后续回复）。这里调用 ``_sanitize_messages`` 做双向
        修复（丢弃孤立 tool、为缺失响应的 tool_call 补占位），并把结果写回
        ``self.context`` 使其持久生效，避免每个请求反复带病。
        """
        if not self.context:
            return
        fixed = self._sanitize_messages(self.context)
        if fixed is not self.context:
            logger.warning(
                "修复上下文消息序列（丢弃孤立 tool / 补占位 / 重排 tool 响应，%d 条 → %d 条）",
                len(self.context),
                len(fixed),
            )
            self.context = fixed

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
        - 优先保留用户输入：保留最近 ``KEEP_RECENT_USER_MSGS`` 次用户要求
          原文，而不是完整的 tool 调用轨迹。
        - 额外保留当前活动轮次尾部 ``KEEP_TAIL_LENGTH`` 条消息（保持工具
          序列连续、保留即时执行状态）。
        - 其余消息（更早的用户输入 + 中间/更早的 tool 调用轨迹）调用 LLM
          总结成一条 summary，替换进上下文。

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

        # 定位用户消息与当前活动轮次。
        user_indices = [
            i for i, m in enumerate(other_msgs) if m.get("role") == "user"
        ]
        if len(other_msgs) <= 1:
            return False

        # 保留策略（优先保留用户输入，而非完整 tool 调用轨迹）：
        # - 保留最近 KEEP_RECENT_USER_MSGS 条用户输入原文；
        # - 额外保留当前活动轮次尾部 KEEP_TAIL_LENGTH 条消息（保持工具序列
        #   连续、保留即时执行状态，但限制条数，避免单轮超长 tool 轨迹导致
        #   永不压缩）；
        # - 其余全部消息（更早的用户输入 + 中间/更早的 tool 轨迹）进总结。
        kept_user_msgs: List[Dict[str, Any]] = []
        tail_msgs: List[Dict[str, Any]] = []
        if user_indices:
            keep_user_from = user_indices[
                max(0, len(user_indices) - self.KEEP_RECENT_USER_MSGS)
            ]
            kept_user_msgs = [
                m for m in other_msgs[keep_user_from:] if m.get("role") == "user"
            ]
            last_user_idx = user_indices[-1]
            tail_start = max(
                last_user_idx + 1,
                len(other_msgs) - self.KEEP_TAIL_LENGTH,
            )
            tail_start = self._legal_tail_start(other_msgs, tail_start)
            tail_msgs = other_msgs[tail_start:]
        else:
            # 没有用户消息（异常态），仅保留最近若干条
            tail_start = max(
                0,
                len(other_msgs) - self.KEEP_TAIL_LENGTH,
            )
            tail_start = self._legal_tail_start(other_msgs, tail_start)
            tail_msgs = other_msgs[tail_start:]

        to_keep = kept_user_msgs + tail_msgs

        # 待总结：其余全部消息（按原始顺序，保留更早的用户输入与 tool 轨迹）
        kept_ids = {id(m) for m in to_keep}
        to_summarize = [m for m in other_msgs if id(m) not in kept_ids]

        # 无可总结内容（上下文本身较短，仍在保留窗口内）
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

        # 重组上下文：system 消息 + 总结 + 保留的最近用户输入 + 活动轮次尾部。
        # 尾部截断可能留下「assistant 带 tool_calls 但缺 tool 响应」的非法序列，
        # 重组后复用 _repair_context 补占位响应，保证对网关合法。
        self.context = system_msgs + [summary_msg] + to_keep
        self._repair_context()

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

        summarize_prompt = versions.active_compressor(raw)

        try:
            # 主动延迟：压缩总结也属于该 agent 的 API 调用，同样限速
            # （无取消事件：压缩时机不阻塞停止，停止检查点在主循环/流式间隙）
            self._acquire_rate_limit()
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
