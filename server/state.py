"""全局应用状态容器。

应用启动时（main.lifespan）填充，各组件经此获取全局句柄
（WS 管理器 / 本地执行器 / Docker 管理器 / 消息投递器 / 模型配置），
避免组件间循环 import。
"""
from typing import Any, Dict, Optional

from config.models import ModelConfig

# WebSocket 连接管理器（全局单例，模块级实例化保证 import 期可用）
ws_manager: Optional[Any] = None
# 本地执行器客户端（全局单例）：本地模式下把工具调用转发给前端本地执行
local_executor: Optional[Any] = None
# Docker 工作空间管理器（Docker 不可用时为 None 或 available=False）
docker_manager: Optional[Any] = None
# 团队成员消息投递器（lifespan 中填充）
team_broker: Optional[Any] = None
# 顶部 agent 用户消息投递器（lifespan 中填充）
top_chat_broker: Optional[Any] = None
# SSH 连接管理器（lifespan 中填充）：SSH 模式下管理远端主机连接
ssh_manager: Optional[Any] = None
# 模型配置全局缓存（lifespan 中填充）
model_configs: Dict[str, ModelConfig] = {}
# MCP 服务管理器（lifespan 中填充）：管理全局外部 stdio MCP 服务
# （经 REST /api/mcp/services 注册，跨会话共享；各会话工具注册时复制外部服务）
