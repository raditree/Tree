"""REST API 路由定义。"""
import base64
import datetime
import logging
import os
import secrets
import tempfile
import uuid
from typing import Any, Dict, List, Optional
from urllib.parse import urlencode

logger = logging.getLogger(__name__)

import httpx
from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Request,
    UploadFile,
)
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

try:
    import fitz  # PyMuPDF
except ImportError:
    fitz = None

from core import agent_store, user_store
from core.auth import (
    create_token,
    get_current_user,
    refresh_token,
    revoke_token,
)
from core.config import get_config
from core.conversation_store import clear_context
from core.models import get_model_configs
from core.session_cache import clear_user_agent

router = APIRouter(prefix="/api")

# 微信登录 state 暂存：state -> {"status": "pending"|"success", "token": ..., "user": ...}
_WECHAT_STATES: Dict[str, Dict[str, Any]] = {}


def _wechat_config() -> Dict[str, Any]:
    """获取微信配置段。"""
    return get_config().get("wechat", {})


def _is_mock_mode() -> bool:
    """判断是否为开发模拟模式（app_id 或 app_secret 为空时返回模拟数据）。"""
    cfg = _wechat_config()
    return not (cfg.get("app_id") and cfg.get("app_secret"))


@router.get("/health")
async def health_check():
    """健康检查端点。"""
    return {"status": "ok"}


# ===== 账号密码认证（checklist 1：替代微信登录） =====


class RegisterRequest(BaseModel):
    """注册请求体。"""

    username: str
    password: str
    nickname: str = ""


class LoginRequest(BaseModel):
    """登录请求体。"""

    username: str
    password: str


@router.post("/auth/register")
async def auth_register(req: RegisterRequest):
    """注册账号：用户名密码创建账号，成功后返回 JWT token。

    校验：
    - 用户名非空且长度 2-32
    - 密码长度不少于 6 位
    - 用户名唯一（冲突返回 409）
    """
    username = req.username.strip()
    if not username:
        raise HTTPException(status_code=400, detail="用户名不能为空")
    if len(username) < 2 or len(username) > 32:
        raise HTTPException(status_code=400, detail="用户名长度需在 2-32 之间")
    if not req.password or len(req.password) < 6:
        raise HTTPException(status_code=400, detail="密码长度不能少于 6 位")
    if user_store.get_user_by_username(username) is not None:
        raise HTTPException(status_code=409, detail="该用户名已被注册")
    user = user_store.create_account(username, req.password, req.nickname)
    token = create_token(user)
    return {"token": token, "user": user}


@router.post("/auth/login")
async def auth_login(req: LoginRequest):
    """账号密码登录：校验通过后返回 JWT token。"""
    username = req.username.strip()
    if not username or not req.password:
        raise HTTPException(status_code=400, detail="用户名和密码不能为空")
    user = user_store.authenticate(username, req.password)
    if user is None:
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    token = create_token(user)
    return {"token": token, "user": user}


# ===== 微信登录认证（保留，但前端已不再使用） =====


@router.get("/auth/wechat/qrcode")
async def wechat_qrcode():
    """生成微信登录二维码 URL。

    调用微信 OAuth API 生成扫码登录 URL，同时存储 state 用于后续验证。
    开发模式（app_id 为空）下返回模拟 URL。
    """
    state = secrets.token_urlsafe(16)

    if _is_mock_mode():
        # 开发模式：返回模拟 URL，前端可直接调用 callback 模拟登录
        url = f"https://open.weixin.qq.com/connect/qrconnect?state={state}&mock=1"
    else:
        cfg = _wechat_config()
        params = {
            "appid": cfg["app_id"],
            "redirect_uri": cfg.get("redirect_uri", ""),
            "response_type": "code",
            "scope": "snsapi_login",
            "state": state,
        }
        url = "https://open.weixin.qq.com/connect/qrconnect?" + urlencode(params)

    # 存储 state，初始状态为 pending
    _WECHAT_STATES[state] = {"status": "pending"}

    return {"url": url, "state": state}


@router.get("/auth/wechat/callback")
async def wechat_callback(code: str, state: str):
    """微信 OAuth 回调。

    接收 ``code`` 和 ``state`` 参数，用 code 换取 access_token 并获取用户信息，
    生成 JWT token 返回。开发模式下返回模拟用户数据。
    """
    # 校验 state 是否已登记
    if state not in _WECHAT_STATES:
        raise HTTPException(status_code=400, detail="无效的 state")

    if _is_mock_mode():
        # 开发模式：返回模拟用户数据
        user: Dict[str, Any] = {
            "openid": f"mock_openid_{state[:8]}",
            "nickname": "开发者",
            "avatar": "",
        }
    else:
        cfg = _wechat_config()
        async with httpx.AsyncClient() as client:
            # 用 code 换取 access_token
            token_resp = await client.get(
                "https://api.weixin.qq.com/sns/oauth2/access_token",
                params={
                    "appid": cfg["app_id"],
                    "secret": cfg["app_secret"],
                    "code": code,
                    "grant_type": "authorization_code",
                },
            )
            token_data = token_resp.json()
            if "errcode" in token_data:
                raise HTTPException(
                    status_code=400,
                    detail=f"微信获取 access_token 失败: {token_data}",
                )

            access_token = token_data["access_token"]
            openid = token_data["openid"]

            # 获取用户信息
            user_resp = await client.get(
                "https://api.weixin.qq.com/sns/userinfo",
                params={
                    "access_token": access_token,
                    "openid": openid,
                },
            )
            user_data = user_resp.json()
            if "errcode" in user_data:
                raise HTTPException(
                    status_code=400,
                    detail=f"微信获取用户信息失败: {user_data}",
                )

            user = {
                "openid": user_data.get("openid", ""),
                "nickname": user_data.get("nickname", ""),
                "avatar": user_data.get("headimgurl", ""),
            }

    # 生成 JWT token
    token = create_token(user)

    # 更新 state 状态为 success，供轮询接口读取
    _WECHAT_STATES[state] = {
        "status": "success",
        "token": token,
        "user": user,
    }

    return {"token": token, "user": user}


@router.get("/auth/wechat/status")
async def wechat_status(state: str):
    """轮询微信登录状态。

    返回该 state 对应的登录状态：``pending`` 或 ``success``（含 token 与用户信息）。
    """
    session = _WECHAT_STATES.get(state)
    if session is None:
        raise HTTPException(status_code=404, detail="state 不存在或已过期")

    if session["status"] == "pending":
        return {"status": "pending"}

    return {
        "status": "success",
        "token": session["token"],
        "user": session["user"],
    }


@router.post("/auth/refresh")
async def auth_refresh(request: Request, _: dict = Depends(get_current_user)):
    """刷新 token。需要当前 token 有效。"""
    auth_header = request.headers.get("Authorization", "")
    token = auth_header[len("Bearer "):].strip()
    new_token = refresh_token(token)
    return {"token": new_token}


@router.post("/auth/logout")
async def auth_logout(request: Request, _: dict = Depends(get_current_user)):
    """撤销当前 token。"""
    auth_header = request.headers.get("Authorization", "")
    token = auth_header[len("Bearer "):].strip()
    revoke_token(token)
    return {"status": "ok"}


# ===== 账号注销（checklist 3：十日倒计时 + 31 天保留后删除） =====


@router.get("/auth/account/status")
async def account_status(current_user: dict = Depends(get_current_user)):
    """查询账号注销状态。

    返回 ``{"status": "active"|"pending_delete"|"deleting", ...}``：
    - ``active``：正常
    - ``pending_delete``：十日倒计时中，可随时取消（含剩余天数）
    - ``deleting``：倒计时结束，数据保留 31 天后彻底删除（含剩余天数）
    """
    openid = current_user.get("openid", "")
    return user_store.get_account_status(openid)


@router.post("/auth/account/delete-request")
async def account_delete_request(current_user: dict = Depends(get_current_user)):
    """请求注销账号：进入十日倒计时。

    注销期内后台数据照常、应用功能照常，可随时通过 delete-cancel 取消。
    """
    openid = current_user.get("openid", "")
    user = user_store.request_delete(openid)
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    return user_store.get_account_status(openid)


@router.post("/auth/account/delete-cancel")
async def account_delete_cancel(current_user: dict = Depends(get_current_user)):
    """取消注销：清除倒计时与删除时间，账号恢复正常。"""
    openid = current_user.get("openid", "")
    user = user_store.cancel_delete(openid)
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    return user_store.get_account_status(openid)


# ===== Agent 列表 =====


def _resolve_agent_type(model_id: str) -> str:
    """根据模型池配置判断 agent 类型（normal/limitless）。"""
    for cfg in get_model_configs().values():
        if cfg.model_id == model_id:
            return "limitless" if cfg.is_limitless_context else "normal"
    return "normal"


def _agent_to_response(record: Dict[str, Any]) -> Dict[str, Any]:
    """将数据库记录转为前端 Agent 字段结构。"""
    return {
        "id": record["id"],
        "name": record["name"],
        "model_id": record["model_id"],
        "type": _resolve_agent_type(record["model_id"]),
        "system_prompt": record.get("system_prompt", ""),
        "workspace_id": record.get("workspace_id", ""),
        "last_message": "已创建，等待任务分配",
        "last_message_time": None,
    }


@router.get("/agents")
async def list_agents(current_user: dict = Depends(get_current_user)):
    """获取当前用户的 agent 列表（SQLite 持久化）。"""
    user_id = current_user.get("openid", "")
    records = agent_store.get_agents(user_id)
    return {"agents": [_agent_to_response(r) for r in records]}


class CreateAgentRequest(BaseModel):
    """创建 agent 请求体。"""

    name: str
    model_id: str
    system_prompt: str = ""


@router.post("/agents")
async def create_agent(
    req: CreateAgentRequest,
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """创建一个 agent 并持久化，同时为其创建独立的 Docker 工作空间。"""
    name = req.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Agent 名称不能为空")
    if not req.model_id:
        raise HTTPException(status_code=400, detail="请选择模型")
    user_id = current_user.get("openid", "")
    # 顶层 agent 数量限制（配置 agents.max_per_user）
    max_per_user = int(get_config().get("agents", {}).get("max_per_user", 5))
    existing = agent_store.get_agents(user_id)
    if len(existing) >= max_per_user:
        raise HTTPException(
            status_code=400,
            detail=f"每个用户最多创建 {max_per_user} 个 Agent，已达上限",
        )
    record = agent_store.create_agent(
        user_id, name, req.model_id, req.system_prompt.strip()
    )
    # 为该 agent 创建独立工作空间（Docker 不可用时不阻塞创建，仅记录降级）
    docker_manager = _get_docker_manager(request)
    workspace_id = record.get("workspace_id", "") or record["id"]
    ws_result = docker_manager.create_workspace(
        workspace_id, agent_name=name
    )
    ws_error = ws_result.get("error")
    if ws_error:
        logger.warning(
            "创建 agent 工作空间失败: %s (%s)", workspace_id, ws_error
        )
    return {
        "agent": _agent_to_response(record),
        "workspace_error": ws_error,
    }


@router.delete("/agents/{agent_id}")
async def delete_agent(
    agent_id: str,
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """删除指定 agent 及其对话历史，并清理其独立工作空间。"""
    user_id = current_user.get("openid", "")
    existed = agent_store.delete_agent(user_id, agent_id)
    if not existed:
        raise HTTPException(status_code=404, detail="Agent 不存在")
    # 清理该 agent 的工作空间（Docker 不可用或容器不存在时静默忽略）。
    # DB 删除已成功，workspace 清理失败不应使接口返回错误，否则前端
    # 无法即时刷新列表（卡片残留，刷新后才消失）。
    docker_manager = _get_docker_manager(request)
    try:
        docker_manager.remove_workspace(agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("删除 agent 工作空间失败(已忽略): %s (%s)", agent_id, exc)
    # 清理该 agent 的 normal LLM 会话缓存，避免内存泄漏
    clear_user_agent(user_id, agent_id)
    # 清理该 agent 持久化的会话上下文（数据库）
    clear_context(user_id, agent_id)
    return {"success": True}


@router.get("/models")
async def list_models(
    refresh: bool = Query(False, description="为 true 时强制从各供应商 API 重新拉取模型池"),
    _: dict = Depends(get_current_user),
):
    """获取模型池中的具体模型列表。

    由 yaml 配置 + 各供应商 API（``/models``）拉取的模型合并而成。
    ``refresh=true`` 时强制重新向供应商 API 查询。
    """
    configs = get_model_configs(refresh=refresh)
    models = []
    for cfg in configs.values():
        models.append(
            {
                "model_id": cfg.model_id,
                "name": cfg.name,
                "is_limitless_context": cfg.is_limitless_context,
                "max_seqlen": cfg.extra.get("max_seqlen"),
            }
        )
    return {"models": models}



# ===== 工作空间文件管理 =====


def _escape_shell_path(path: str) -> str:
    """转义路径中的单引号，防止 shell 命令注入。"""
    return path.replace("'", "'\\''")


def _parse_ls_output(output: str) -> List[Dict[str, Any]]:
    """解析 ``ls -la --time-style=long-iso`` 输出为文件信息列表。

    输出格式：``perms links owner group size date time name``
    """
    files: List[Dict[str, Any]] = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith("total "):
            continue
        parts = line.split()
        if len(parts) < 8:
            continue
        name = " ".join(parts[7:])
        if name in (".", ".."):
            continue
        perms = parts[0]
        size_str = parts[4]
        size = int(size_str) if size_str.isdigit() else 0
        modified = f"{parts[5]} {parts[6]}"
        file_type = "dir" if perms.startswith("d") else "file"
        files.append(
            {
                "name": name,
                "size": size,
                "type": file_type,
                "modified": modified,
            }
        )
    return files


@router.get("/files/{workspace_id}")
async def list_files(
    workspace_id: str,
    request: Request,
    path: str = Query("", description="子路径，默认根目录"),
    _: dict = Depends(get_current_user),
):
    """获取工作空间文件列表。

    查询参数 ``path`` 指定子路径（默认根目录），
    通过 docker_manager.exec_in_workspace 执行 ``ls -la`` 获取文件列表。
    """
    docker_manager = _get_docker_manager(request)
    if not path:
        # 根目录：使用 "."，避免空字符串被当作不存在的文件名
        cmd = "ls -la --time-style=long-iso . 2>&1"
    else:
        safe_path = _escape_shell_path(path)
        cmd = f"ls -la --time-style=long-iso '{safe_path}' 2>&1"
    result = docker_manager.exec_in_workspace(workspace_id, ["sh", "-c", cmd])
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    if result.get("exit_code", 0) != 0:
        raise HTTPException(status_code=404, detail=f"路径不存在: {path}")
    files = _parse_ls_output(result.get("stdout", ""))
    return {"files": files}


@router.get("/files/{workspace_id}/content")
async def get_file_content(
    workspace_id: str,
    request: Request,
    path: str = Query(..., description="文件路径"),
    _: dict = Depends(get_current_user),
):
    """获取文件内容。

    查询参数 ``path`` 指定文件路径，
    通过 docker_manager.exec_in_workspace 读取文件内容。
    """
    if not path:
        raise HTTPException(status_code=400, detail="path 参数不能为空")
    docker_manager = _get_docker_manager(request)
    safe_path = _escape_shell_path(path)
    result = docker_manager.exec_in_workspace(
        workspace_id, ["sh", "-c", f"cat '{safe_path}' 2>&1"]
    )
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    if result.get("exit_code", 0) != 0:
        raise HTTPException(status_code=404, detail="文件不存在或无法读取")
    content = result.get("stdout", "")
    return {
        "content": content,
        "path": path,
        "size": len(content.encode("utf-8")),
    }


def _parse_size(value: Any, default: int = 0) -> int:
    """将大小字符串（如 ``'10m'`` / ``'1g'`` / ``'512k'`` / ``1024``）解析为字节数。

    支持 ``b/k/m/g`` 后缀（1k=1024）。解析失败时返回 [default]。
    """
    if isinstance(value, (int, float)):
        return int(value)
    s = str(value or "").strip().lower()
    if not s:
        return default
    units = {"b": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}
    num = ""
    unit = "b"
    for ch in s:
        if ch.isdigit() or ch == ".":
            num += ch
        elif ch in units:
            unit = ch
            break
    try:
        return int(float(num) * units[unit])
    except ValueError:
        return default


def _get_workspace_size(docker_manager, workspace_id: str) -> int:
    """获取工作空间当前已用字节数（``du -sb /workspace``）。

    查询失败时返回 0（不阻塞上传）。
    """
    result = docker_manager.exec_in_workspace(
        workspace_id, ["sh", "-c", "du -sb /workspace 2>/dev/null"]
    )
    if result.get("exit_code", -1) != 0:
        return 0
    out = result.get("stdout", "").strip()
    try:
        return int(out.split()[0])
    except (ValueError, IndexError):
        return 0


@router.post("/files/{workspace_id}/upload")
async def upload_file(
    workspace_id: str,
    request: Request,
    files: List[UploadFile] = File(...),
    rel_paths: List[str] = Form(default=[]),
    _: dict = Depends(get_current_user),
):
    """上传多个文件到工作空间 ``.input/yyyymmdd/`` 目录。

    支持多文件及文件夹结构：每个文件可通过同名 ``rel_path`` 表单字段携带
    相对路径（含子目录），用于保留文件夹层级；未提供的文件保存到
    ``.input/yyyymmdd/`` 根目录（使用文件名）。

    上传前校验：
    - 单文件大小不超过 ``upload.max_file_size``
    - 沙箱总大小（当前已用 + 本次新增）不超过 ``upload.sandbox_max_size``

    返回 ``{"success": true, "paths": [...]}``（工作空间内绝对路径列表）。
    """
    docker_manager = _get_docker_manager(request)
    upload_cfg = get_config().get("upload", {})
    max_file_size = _parse_size(upload_cfg.get("max_file_size"), 10 * 1024 * 1024)
    sandbox_max_size = _parse_size(
        upload_cfg.get("sandbox_max_size"), 1024 * 1024 * 1024
    )

    date_dir = datetime.datetime.now().strftime("%Y%m%d")

    # 读取全部文件并统一校验
    payloads: List[tuple] = []  # (相对路径, 字节内容)
    total_new = 0
    for i, f in enumerate(files):
        data = await f.read()
        if len(data) > max_file_size:
            raise HTTPException(
                status_code=413,
                detail=f"文件过大（{f.filename}），最大支持 {max_file_size} 字节",
            )
        total_new += len(data)
        name = f.filename or f"uploaded_{i}"
        rel = (rel_paths[i].strip("/") if i < len(rel_paths) and rel_paths[i] else name)
        payloads.append((rel, data))

    # 沙箱总大小校验
    current_size = _get_workspace_size(docker_manager, workspace_id)
    if current_size + total_new > sandbox_max_size:
        raise HTTPException(
            status_code=413,
            detail=f"沙箱总大小将超过上限 {sandbox_max_size} 字节",
        )

    # 逐个写入 .input/yyyymmdd/ 目录
    saved: List[str] = []
    for rel, data in payloads:
        b64_content = base64.b64encode(data).decode("ascii")
        target = f".input/{date_dir}/{rel}"
        safe_target = _escape_shell_path(target)
        dirname = target.rsplit("/", 1)[0]
        safe_dirname = _escape_shell_path(dirname)
        cmd = (
            f"mkdir -p '{safe_dirname}' && "
            f"echo '{b64_content}' | base64 -d > '{safe_target}'"
        )
        result = docker_manager.exec_in_workspace(workspace_id, ["sh", "-c", cmd])
        if "error" in result and "exit_code" not in result:
            raise HTTPException(status_code=404, detail=result)
        if result.get("exit_code", 0) != 0:
            raise HTTPException(
                status_code=500, detail=f"上传失败: {result.get('stdout', '')}"
            )
        saved.append(f"/workspace/{target}")
    return {"success": True, "paths": saved}


class FileDownloadRequest(BaseModel):
    """文件下载请求体。"""

    path: str


@router.post("/files/{workspace_id}/download")
async def download_file(
    workspace_id: str,
    req: FileDownloadRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """从工作空间下载文件，返回文件内容（StreamingResponse）。"""
    docker_manager = _get_docker_manager(request)
    safe_path = _escape_shell_path(req.path)
    result = docker_manager.exec_in_workspace(
        workspace_id, ["sh", "-c", f"cat '{safe_path}' 2>&1"]
    )
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    if result.get("exit_code", 0) != 0:
        raise HTTPException(status_code=404, detail="文件不存在或无法读取")
    content = result.get("stdout", "").encode("utf-8")
    filename = req.path.rsplit("/", 1)[-1] or "download"
    return StreamingResponse(
        iter([content]),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def _read_file_bytes(workspace_id: str, path: str, request: Request) -> bytes:
    """从工作空间读取文件原始字节。

    在容器内用 base64 编码文件内容，服务器端解码后返回字节，
    适用于 PDF 等二进制文件。
    """
    docker_manager = _get_docker_manager(request)
    safe_path = _escape_shell_path(path)
    cmd = f"base64 '{safe_path}' 2>/dev/null"
    result = docker_manager.exec_in_workspace(workspace_id, ["sh", "-c", cmd])
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    if result.get("exit_code", 0) != 0:
        raise HTTPException(status_code=404, detail="文件不存在或无法读取")
    # 去除 base64 输出中的换行（默认每 76 字符换行）
    b64_data = "".join(result.get("stdout", "").split())
    if not b64_data:
        raise HTTPException(status_code=500, detail="文件内容为空")
    return base64.b64decode(b64_data)


def _save_temp_pdf(pdf_bytes: bytes) -> str:
    """将 PDF 字节写入临时文件并返回路径。

    使用 ``mkstemp`` 创建临时文件（避免 ``NamedTemporaryFile`` 在 Windows
    下无法被其他句柄打开的问题），调用方需在用完后删除临时文件。
    """
    fd, tmp_path = tempfile.mkstemp(suffix=".pdf")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(pdf_bytes)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return tmp_path


@router.get("/files/{workspace_id}/pdf_info")
async def get_pdf_info(
    workspace_id: str,
    request: Request,
    path: str = Query(..., description="PDF 文件路径"),
    _: dict = Depends(get_current_user),
):
    """获取 PDF 文件信息（总页数、标题、作者）。

    通过 PyMuPDF 解析 PDF 元数据，返回
    ``{"total_pages": N, "title": "...", "author": "..."}``。
    """
    if fitz is None:
        raise HTTPException(status_code=503, detail="PyMuPDF 未安装")
    if not path:
        raise HTTPException(status_code=400, detail="path 参数不能为空")

    pdf_bytes = _read_file_bytes(workspace_id, path, request)
    tmp_path = _save_temp_pdf(pdf_bytes)
    try:
        doc = fitz.open(tmp_path)
        try:
            metadata = doc.metadata or {}
            return {
                "total_pages": doc.page_count,
                "title": metadata.get("title", "") or "",
                "author": metadata.get("author", "") or "",
            }
        finally:
            doc.close()
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


@router.get("/files/{workspace_id}/pdf_preview")
async def get_pdf_preview(
    workspace_id: str,
    request: Request,
    path: str = Query(..., description="PDF 文件路径"),
    page: int = Query(1, ge=1, description="页码，从 1 开始"),
    scale: float = Query(2.0, gt=0, description="缩放比例"),
    _: dict = Depends(get_current_user),
):
    """获取 PDF 指定页的预览图片（PNG，base64 编码）。

    通过 PyMuPDF 将指定页渲染为 pixmap，转为 PNG 后 base64 编码返回：
    ``{"image": "...", "page": N, "total_pages": M, "width": W, "height": H}``。
    """
    if fitz is None:
        raise HTTPException(status_code=503, detail="PyMuPDF 未安装")
    if not path:
        raise HTTPException(status_code=400, detail="path 参数不能为空")

    pdf_bytes = _read_file_bytes(workspace_id, path, request)
    tmp_path = _save_temp_pdf(pdf_bytes)
    try:
        doc = fitz.open(tmp_path)
        try:
            total_pages = doc.page_count
            if page > total_pages:
                raise HTTPException(
                    status_code=400,
                    detail=f"页码超出范围，总页数 {total_pages}",
                )
            page_obj = doc.load_page(page - 1)
            matrix = fitz.Matrix(scale, scale)
            pixmap = page_obj.get_pixmap(matrix=matrix)
            png_bytes = pixmap.tobytes("png")
            img_b64 = base64.b64encode(png_bytes).decode("ascii")
            return {
                "image": img_b64,
                "page": page,
                "total_pages": total_pages,
                "width": pixmap.width,
                "height": pixmap.height,
            }
        finally:
            doc.close()
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


class FileSyncRequest(BaseModel):
    """文件同步请求体。"""

    direction: str  # "local_to_cloud" 或 "cloud_to_local"
    path: str = ""


@router.post("/files/{workspace_id}/sync")
async def sync_files(
    workspace_id: str,
    req: FileSyncRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """文件双向同步（本地 <-> 云端工作目录）。

    请求体 ``{"direction": "local_to_cloud"/"cloud_to_local", "path": "..."}``，
    暂未实现，返回 501（需要前端配合实现）。
    """
    raise HTTPException(
        status_code=501,
        detail="文件同步功能暂未实现，需要前端配合实现",
    )


# ===== 工作空间生命周期管理 =====


class CreateWorkspaceRequest(BaseModel):
    """创建工作空间请求体。"""

    agent_name: str
    parent_workspace_id: Optional[str] = None


class ExecCommandRequest(BaseModel):
    """在工作空间内执行命令的请求体。"""

    command: List[str]


def _get_docker_manager(request: Request):
    """从 app.state 获取 DockerManager 实例。"""
    docker_manager = getattr(request.app.state, "docker_manager", None)
    if docker_manager is None:
        raise HTTPException(status_code=503, detail="Docker 管理器未初始化")
    return docker_manager


@router.post("/workspaces")
async def create_workspace(
    req: CreateWorkspaceRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """创建工作空间。

    请求体：``{"agent_name": "...", "parent_workspace_id": "..."}``（parent 可选）
    """
    docker_manager = _get_docker_manager(request)
    workspace_id = uuid.uuid4().hex[:12]
    result = docker_manager.create_workspace(
        workspace_id=workspace_id,
        parent_workspace_id=req.parent_workspace_id,
        agent_name=req.agent_name,
    )
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return result


@router.get("/workspaces/{workspace_id}")
async def get_workspace(
    workspace_id: str,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """查询工作空间状态。"""
    docker_manager = _get_docker_manager(request)
    result = docker_manager.get_workspace_status(workspace_id)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return result


@router.delete("/workspaces/{workspace_id}")
async def delete_workspace(
    workspace_id: str,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """删除工作空间（停止并删除容器，保留卷）。"""
    docker_manager = _get_docker_manager(request)
    result = docker_manager.remove_workspace(workspace_id)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return result


@router.post("/workspaces/{workspace_id}/exec")
async def exec_in_workspace(
    workspace_id: str,
    req: ExecCommandRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """在工作空间内执行命令。

    请求体：``{"command": ["git", "status"]}``
    """
    docker_manager = _get_docker_manager(request)
    result = docker_manager.exec_in_workspace(workspace_id, req.command)
    # 容器不存在等场景返回 error 字段且无 exit_code
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    return result


# ===== Git 操作 =====


class GitMergeRequest(BaseModel):
    """合并分支请求体。"""

    branch: str


class GitFetchRequest(BaseModel):
    """fetch 远程请求体。"""

    remote: str = "parent"


@router.get("/workspaces/{workspace_id}/git/log")
async def git_log(
    workspace_id: str,
    request: Request,
    limit: int = 50,
    _: dict = Depends(get_current_user),
):
    """查看提交历史。

    查询参数 ``limit``（默认 50），返回 ``{"commits": [...]}``。
    """
    docker_manager = _get_docker_manager(request)
    result = docker_manager.git_log(workspace_id, limit=limit)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return {"commits": result.get("commits", [])}


@router.get("/workspaces/{workspace_id}/git/branches")
async def git_branches(
    workspace_id: str,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """查看分支列表，返回 ``{"branches": [...], "current": "..."}``。"""
    docker_manager = _get_docker_manager(request)
    result = docker_manager.git_branches(workspace_id)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return {
        "branches": result.get("branches", []),
        "current": result.get("current", ""),
    }


@router.get("/workspaces/{workspace_id}/git/diff")
async def git_diff(
    workspace_id: str,
    request: Request,
    branch: str,
    _: dict = Depends(get_current_user),
):
    """查看分支差异。

    查询参数 ``branch`` 指定要对比的分支名，返回 ``{"diff": "..."}``。
    """
    docker_manager = _get_docker_manager(request)
    result = docker_manager.git_diff(workspace_id, branch=branch)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return {"diff": result.get("diff", "")}


@router.post("/workspaces/{workspace_id}/git/merge")
async def git_merge(
    workspace_id: str,
    req: GitMergeRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """合并分支。

    请求体 ``{"branch": "member_xxx"}``，返回 ``{"success": true/false, "message": "..."}``。
    """
    docker_manager = _get_docker_manager(request)
    result = docker_manager.git_merge(workspace_id, branch=req.branch)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return {
        "success": result.get("success", False),
        "message": result.get("message", ""),
    }


@router.post("/workspaces/{workspace_id}/git/fetch")
async def git_fetch(
    workspace_id: str,
    req: GitFetchRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """fetch 远程。

    请求体 ``{"remote": "parent"}``（remote 可选，默认 parent），返回 fetch 结果。
    """
    docker_manager = _get_docker_manager(request)
    result = docker_manager.git_fetch(workspace_id, remote=req.remote)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return result
