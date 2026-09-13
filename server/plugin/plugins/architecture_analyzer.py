"""示例插件：项目架构分析（最小版，演示三站全链路）。

链路演示：
- **广播站（订阅入口）**：订阅"工具执行"事件（``tool.call.completed``）；
- **中转站（触发/处理）**：累积事件计数，每 ``analyze_every`` 个事件
  触发一次分析（实例内串行由注册表保证）；
- **接收站（出站）**：经 ``PluginSDK`` 读取工作空间（workspaceIO）并
  向指定 agent 推送摘要（dispatch，active=False）；未配置推送目标时
  降级写活动日志，保证产出不丢。

一期为最小演示版：不做 UI、不做持久化、不引入第三方依赖。
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional, Set

from plugin.sdk import PluginSDK

logger = logging.getLogger(__name__)

# 插件标识（注册表键的一部分）
PLUGIN_ID = "architecture_analyzer"
# 订阅的事件类型（白名单：一期仅"工具执行"）
SUBSCRIBED_TYPES: Set[str] = {"tool.call.completed"}
# 每 N 个工具事件执行一次分析（演示默认 1；真实场景建议调大以控制频率）
DEFAULT_ANALYZE_EVERY = 1


class ArchitectureAnalyzerPlugin:
    """项目架构分析插件（最小演示版）。"""

    def __init__(
        self,
        sdk: PluginSDK,
        *,
        notify_targets: Optional[List[str]] = None,
        analyze_every: int = DEFAULT_ANALYZE_EVERY,
        read_path: str = "README.md",
    ) -> None:
        """
        :param sdk: 出站 SDK（绑定实例 scope）
        :param notify_targets: 分析结果推送目标（agent id 列表）；
            为空时降级为活动日志
        :param analyze_every: 每 N 个工具事件执行一次分析
        :param read_path: 读取检查的工作空间相对路径
        """
        self.sdk = sdk
        self.notify_targets = list(notify_targets or [])
        self.analyze_every = max(1, int(analyze_every))
        self.read_path = str(read_path or "README.md")
        # 运行统计（观测/演示）
        self.tool_events = 0
        self.analyses = 0
        self.last_tool = ""
        self.last_summary = ""

    # ------------------------------------------------------------------
    # 事件处理（作为注册表 handler：on_event(event)）
    # ------------------------------------------------------------------
    def on_event(self, event: Any) -> None:
        """处理一个总线事件（当前仅订阅 tool.call.completed）。"""
        payload: Dict[str, Any] = getattr(event, "payload", {}) or {}
        self.tool_events += 1
        tool = str(payload.get("tool_name") or payload.get("tool") or "")
        if tool:
            self.last_tool = tool
        if self.tool_events % self.analyze_every != 0:
            return
        self._run_analysis()

    def _run_analysis(self) -> None:
        """执行一次最小分析：读工作空间 + 生成摘要 + 出站推送。"""
        # 1) 经接收站读取工作空间（fail-closed：仅限实例 scope 归属）
        read = self.sdk.workspace_read(self.read_path)
        if read.get("error"):
            doc_state = f"读取失败（{read.get('error')}）"
        else:
            content_text = str(read.get("stdout", "") or read.get("content", "") or "")
            if content_text:
                doc_state = f"{self.read_path} 存在（{len(content_text)} 字符）"
            else:
                doc_state = f"{self.read_path} 不存在或为空"

        self.analyses += 1
        self.last_summary = (
            f"[架构分析·示例] 已观察工具事件 {self.tool_events} 次"
            f"（最近: {self.last_tool or '无'}）；文档检查: {doc_state}"
        )

        # 2) 出站推送：配置了目标则向 agent 推送，否则降级活动日志
        if self.notify_targets:
            result = self.sdk.dispatch_agent_message(
                self.notify_targets, self.last_summary
            )
            sent = bool(result) and not result.get("error") and bool(result.get("sent"))
            if not sent:
                # 推送未成功（如目标不可达）：降级活动日志，产出不丢
                self.sdk.activity_log(
                    self.last_summary + f"（推送未成功: {result}）"
                )
        else:
            self.sdk.activity_log(self.last_summary)

    def stats(self) -> Dict[str, Any]:
        """插件运行统计（观测/演示用）。"""
        return {
            "tool_events": self.tool_events,
            "analyses": self.analyses,
            "last_tool": self.last_tool,
            "last_summary": self.last_summary,
        }
