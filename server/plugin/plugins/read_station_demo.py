"""示范插件：read 结果处理站（半二期最小版，E2E 演示载体）。

链路演示（处理站全流程）：
- **订阅**：注册订阅 ``tool.read.result`` 站（站 × scope 键位唯一）；
- **触发 → 处理**：read 工具返回前，框架把结果交给本插件处理函数；
- **回填**：处理函数返回 ``str``（替换）或 ``None``（不改动），
  由框架回填为最终工具调用结果。

处理逻辑为**确定性转换**（演示用）：给非空结果加"处理站示范"标记前缀
并附字符数统计；空结果不改动（演示 ``None`` 语义）。不做 UI、不持久化。
"""

from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from plugin import get_stations
from plugin.stations import STATION_READ_RESULT, StationRequest

logger = logging.getLogger(__name__)

# 插件标识（订阅实例键的一部分）
PLUGIN_ID = "read_station_demo"
# 演示标记（确定性前缀）
DEFAULT_PREFIX = "[处理站示范] read 结果已处理"


class ReadStationDemoPlugin:
    """演示插件：read 结果加标记前缀（确定性、可预期）。"""

    def __init__(self, prefix: str = DEFAULT_PREFIX) -> None:
        self.prefix = str(prefix or DEFAULT_PREFIX)
        self.processed = 0
        self.passthrough = 0
        self.last_chars = 0

    def on_station(self, request: StationRequest) -> Optional[str]:
        """处理站处理函数：返回 ``str`` 替换 / ``None`` 不改动。"""
        text = str(request.data or "")
        if not text:
            self.passthrough += 1
            return None
        self.processed += 1
        self.last_chars = len(text)
        return f"{self.prefix}（{len(text)} 字符）\n\n{text}"

    def stats(self) -> Dict[str, Any]:
        """插件运行统计（观测/演示用）。"""
        return {
            "processed": self.processed,
            "passthrough": self.passthrough,
            "last_chars": self.last_chars,
        }


def register_demo_plugin(
    *,
    granularity: str = "agent",
    scope: Optional[Dict[str, str]] = None,
    pin: bool = True,
) -> Optional[ReadStationDemoPlugin]:
    """便捷注册：订阅 read 结果站（自动创建订阅实例，默认 Pin 常驻）。

    :param granularity: 订阅粒度（team/agent/session）
    :param scope: 订阅作用域（须含 user_id；其余按粒度）
    :param pin: 实例常驻标记（Pin 豁免 TTL 逐出；长期订阅建议 True）
    :return: 插件对象；订阅失败（键位被占等）返回 None
    """
    demo = ReadStationDemoPlugin()
    ok = get_stations().subscribe(
        STATION_READ_RESULT,
        PLUGIN_ID,
        demo.on_station,
        granularity=granularity,
        scope=scope,
        pin=pin,
    )
    if not ok:
        logger.warning("read 站示范插件订阅失败（可能键位已被占用）")
        return None
    return demo
