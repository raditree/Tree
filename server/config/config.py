"""应用配置加载。

读取 ``server/configs/app.yaml``，并支持通过环境变量覆盖关键配置项
（如 ``SERVER_HOST`` / ``SERVER_PORT`` 覆盖服务监听地址）。
"""
import os
from pathlib import Path
from typing import Any, Dict

import yaml

# 配置缓存，避免重复解析文件
_CONFIG_CACHE: Dict[str, Any] | None = None
# 配置文件目录：server/configs
_CONFIG_DIR = Path(__file__).resolve().parent.parent / "configs"


def get_config() -> Dict[str, Any]:
    """返回应用配置字典。

    首次调用时从 ``configs/app.yaml`` 加载，并应用环境变量覆盖，结果会被缓存。
    """
    global _CONFIG_CACHE
    if _CONFIG_CACHE is not None:
        return _CONFIG_CACHE

    config_path = _CONFIG_DIR / "app.yaml"
    if not config_path.exists():
        raise FileNotFoundError(f"应用配置文件不存在: {config_path}")

    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f) or {}

    # 环境变量覆盖：SERVER_HOST / SERVER_PORT 覆盖服务监听地址
    server_cfg = config.setdefault("server", {})
    if env_host := os.environ.get("SERVER_HOST"):
        server_cfg["host"] = env_host
    if env_port := os.environ.get("SERVER_PORT"):
        server_cfg["port"] = int(env_port)

    _CONFIG_CACHE = config
    return config
