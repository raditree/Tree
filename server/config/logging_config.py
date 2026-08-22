"""统一日志配置：同时输出到控制台与滚动日志文件。

后端此前仅输出到控制台，LLM 调用异常等运行期错误没有落盘记录，
排查问题只能依赖数据库 message 表。本模块在服务启动时初始化日志，
将全部模块日志（含 uvicorn）写入 ``server/logs/app.log``，
单文件最大 10MB、保留 5 份滚动副本，避免日志无限增长。
"""
import logging
import logging.handlers
from pathlib import Path

# 日志文件目录：server/logs
_LOG_DIR = Path(__file__).resolve().parent.parent / "logs"
_LOG_FILE = _LOG_DIR / "app.log"
# 单文件最大 10MB
_MAX_BYTES = 10 * 1024 * 1024
# 滚动保留副本数
_BACKUP_COUNT = 5

# 已初始化标志，保证 setup_logging 幂等
_configured = False


def setup_logging(level: int = logging.INFO) -> None:
    """初始化全局日志：文件（滚动）+ 控制台。

    可重复调用（幂等）：重复调用时先清空 root 上旧 handler 再重建，
    避免同一 handler 被多次挂载导致日志重复输出。
    """
    global _configured
    if _configured:
        return
    _configured = True

    _LOG_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter(
        "%(asctime)s %(levelname)-8s [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = logging.handlers.RotatingFileHandler(
        _LOG_FILE,
        maxBytes=_MAX_BYTES,
        backupCount=_BACKUP_COUNT,
        encoding="utf-8",
    )
    file_handler.setFormatter(fmt)

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(fmt)

    root = logging.getLogger()
    root.setLevel(level)
    # 清空旧 handler，保证幂等调用后仅保留当前这一套
    for handler in list(root.handlers):
        root.removeHandler(handler)
    root.addHandler(file_handler)
    root.addHandler(console_handler)

    # uvicorn 相关 logger 统一汇入 root，避免其默认配置与本次配置重复/冲突
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = True
