"""Agent Team 后端应用入口（P0 组件化装配层）。

启动服务：``python server/main.py``

七核心组件：ws / agent / tool / io_ / llm / data / config。
全局单例（ws_manager / local_executor / docker_manager / 两个 broker /
model_configs）在 lifespan 中统一填充到 state 模块，各组件经 state 读取，
避免跨组件循环 import。
"""
import asyncio
import datetime
import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import state
from agent.chat import (
    _broker_process_user_message,
    _process_member_message,
)
from agent.routes import router as agent_router
from agent.team_broker import TeamMessageBroker
from config.config import get_config
from config.logging_config import setup_logging
from config.models import get_model_configs
from data.routes import router as data_router
from data.user_store import purge_expired_users
from io_.docker_manager import DockerManager
from io_.local_executor import LocalExecutorClient
from io_.routes import router as io_router
from ws.endpoints import register_ws
from ws.ws_manager import WebSocketManager

# 模块级日志器
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期：启动时加载配置与模型配置，关闭时清理资源。

    所有全局单例填充到 state 模块（组件内不持有模块级单例）。
    """
    # 初始化日志：控制台 + 滚动文件（server/logs/app.log），幂等可重复调用
    setup_logging()
    config = get_config()
    state.model_configs = get_model_configs()

    # 预载「主动延迟」开关到内存：限流器按 (user_id, agent_id) 从内存缓存判定，
    # 避免每次 API 调用查 SQLite（REST 设置接口写库后同步更新缓存）
    from data.rate_limit_store import load_all_rate_limit_prefs
    from llm.rate_limit import load_enabled_users

    load_enabled_users(load_all_rate_limit_prefs())

    # 本地执行器客户端：本地模式下工具调用经反向 WS 转发给前端本地执行
    local_executor = LocalExecutorClient()
    # 绑定主事件循环，供后台线程通过 run_coroutine_threadsafe 安全推送 WS 消息
    local_executor.bind_loop(asyncio.get_running_loop())
    state.local_executor = local_executor

    # 团队成员消息投递器：leader 发消息给成员时异步触发成员串行处理
    state.team_broker = TeamMessageBroker(process_fn=_process_member_message)
    # 顶部 agent 用户消息投递器（checklist 7）：串行消费用户消息，
    # agent working 时在 tool_call 间隙切入新消息，idle 时立即处理。
    state.top_chat_broker = TeamMessageBroker(process_fn=_broker_process_user_message)

    # 初始化 Docker 工作空间管理器（Docker 未安装时优雅降级）
    docker_manager = DockerManager()
    state.docker_manager = docker_manager

    # SSH 连接管理器（SSH 模式下管理远端主机连接，配置 DB 持久化）
    from io_.ssh_connection_manager import SSHConnectionManager

    state.ssh_manager = SSHConnectionManager()

    # WebSocket 连接管理器（全局单例）
    state.ws_manager = WebSocketManager()

    print(f"[启动] 服务配置: {config.get('server', {})}")
    print(f"[启动] 已加载模型: {list(state.model_configs.keys())}")
    if docker_manager.available:
        print(f"[启动] Docker 工作空间管理器就绪，镜像: {docker_manager.image}")
        # 自动创建顶部 agent 工作空间（若不存在），供前端文件管理使用
        top_status = docker_manager.get_workspace_status("top")
        if top_status.get("status") == "removed":
            init_result = docker_manager.create_workspace(
                "top", agent_name="首席 Agent"
            )
            if "error" in init_result:
                print(
                    f"[启动] 创建顶部工作空间失败: {init_result['error']} "
                    f"- {init_result.get('detail', '')}"
                )
            else:
                print(f"[启动] 顶部工作空间已创建: {init_result['workspace_id']}")
        else:
            print(f"[启动] 顶部工作空间已存在: top ({top_status.get('status')})")
    else:
        print(f"[启动] Docker 不可用，工作空间功能将降级: {docker_manager._unavailable_reason}")

    # 启动后台任务：定期彻底删除超过保留期的注销账号（checklist 3(b)）
    async def _purge_loop() -> None:
        while True:
            try:
                deleted = purge_expired_users()
                if deleted:
                    print(f"[注销] 已彻底删除 {deleted} 个过期账号")
            except Exception as exc:  # noqa: BLE001
                print(f"[注销] 清理任务异常: {exc}")
            await asyncio.sleep(3600)  # 每小时检查一次

    purge_task = asyncio.create_task(_purge_loop())

    # 启动后台任务：每日固定时刻自动导出 SFT 数据集（默认 01:43）
    async def _sft_export_loop() -> None:
        from data.data_collection_store import export_daily_sft

        daily_cfg = get_config().get("data_export", {})
        daily_time = str(daily_cfg.get("daily_time", "01:43"))
        try:
            hh, mm = (int(x) for x in daily_time.split(":"))
        except (ValueError, TypeError):
            hh, mm = 1, 43
        while True:
            now = datetime.datetime.now()
            # 距下一个导出时刻的秒数（当日已过则顺延到次日）
            next_dt = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
            if next_dt <= now:
                next_dt += datetime.timedelta(days=1)
            await asyncio.sleep((next_dt - now).total_seconds())
            try:
                export_daily_sft()
            except Exception as exc:  # noqa: BLE001
                logger.warning("每日 SFT 导出异常: %s", exc)

    sft_task = asyncio.create_task(_sft_export_loop())

    yield
    print("[关闭] 服务退出")
    purge_task.cancel()
    sft_task.cancel()
    try:
        await purge_task
    except asyncio.CancelledError:
        pass
    try:
        await sft_task
    except asyncio.CancelledError:
        pass


app = FastAPI(
    title="Agent Team Backend",
    description="LLM 驱动的 agent 团队效率工具后端",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS 中间件配置
# 允许源与是否允许凭据由配置（configs/app.yaml 的 cors 段）提供。
# 安全约束：永不出现「allow_origins 含 "*" 且 allow_credentials=True」的任意源带凭据组合。
cors_cfg = get_config().get("cors", {})
cors_origins = cors_cfg.get("allow_origins", []) or []
cors_credentials = bool(cors_cfg.get("allow_credentials", False))
if "*" in cors_origins:
    # "*" 与 credentials 不能共存（浏览器规范 + 安全要求），取更严格的：非 "*" 才允许凭据
    if cors_credentials:
        cors_origins = [origin for origin in cors_origins if origin != "*"]
    else:
        cors_origins = ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins if cors_origins else [],
    allow_credentials=cors_credentials and "*" not in cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 注册 REST API 路由（data：健康/认证/数据收集/embed；agent：agent CRUD/对话/
# MCP 服务管理/模型信息；io_：工作空间/Git）
app.include_router(data_router)
app.include_router(agent_router)
app.include_router(io_router)

# 注册全局 WebSocket 端点（/ws）
register_ws(app)


class _LifespanCancelFilter(logging.Filter):
    """屏蔽 uvicorn 强制退出时 lifespan 任务被取消产生的噪音堆栈。

    uvicorn 0.29+ 在 Windows 上 Ctrl+C 退出时会重抛捕获到的信号，导致
    asyncio 清理阶段取消仍存活的 lifespan 任务；starlette 随后将这段
    CancelledError 堆栈作为 lifespan.shutdown.failed 消息以 ERROR 级别打印。
    这里仅抑制这类"任务被取消"的堆栈，其它真实异常不受影响。
    """

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno < logging.ERROR:
            return True
        msg = record.getMessage()
        # 形式 1：starlette 把格式化后的取消堆栈作为消息（on.py send 分支）
        if msg.startswith("Traceback (most recent call last):") and msg.strip().endswith("CancelledError"):
            return False
        # 形式 2：uvicorn 直接以 exc_info 记录 lifespan 协议异常（on.py main 分支）
        if msg.startswith("Exception in 'lifespan' protocol") and record.exc_info:
            if record.exc_info[0] is asyncio.CancelledError:
                return False
        return True


if __name__ == "__main__":
    server_cfg = get_config().get("server", {})
    host = server_cfg.get("host", "0.0.0.0")
    port = int(server_cfg.get("port", 8000))
    # Windows 上 uvicorn 退出路径会触发上述 lifespan 取消噪音，预先挂上过滤器
    logging.getLogger("uvicorn.error").addFilter(_LifespanCancelFilter())
    try:
        # log_config=None：不覆盖我们初始化好的日志配置（控制台 + 文件）
        uvicorn.run(app, host=host, port=port, log_config=None)
    except KeyboardInterrupt:
        pass
    except asyncio.CancelledError:
        pass
