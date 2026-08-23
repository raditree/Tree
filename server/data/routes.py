"""Data REST 路由：健康检查 / 认证（账号密码 + 微信）/ 账号注销 / embed。

自 api/routes.py 迁出（P0 组件化重组）。
"""
import logging
import secrets
from typing import Any, Dict, List, Optional
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from data import user_store
from data.data_collection_store import (
    is_collection_enabled,
    list_sft_files,
    read_sft_file,
    set_collection_enabled,
)
from data.rate_limit_store import (
    is_rate_limit_enabled,
    set_rate_limit_enabled,
)
from data.embed_model import (
    get_embedding,
    get_embeddings_batch,
    load_embed_model_config,
)
from ws.auth import (
    create_token,
    get_current_user,
    refresh_token,
    revoke_token,
)
from config.config import get_config

logger = logging.getLogger(__name__)

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


def _strip_sensitive_fields(user: Dict[str, Any]) -> Dict[str, Any]:
    """移除用户字典中的敏感字段（password_hash、salt），返回副本。"""
    return {k: v for k, v in user.items() if k not in ("password_hash", "salt")}


@router.post("/auth/register")
async def auth_register(req: RegisterRequest):
    """账号密码注册：创建新用户并返回 JWT token。"""
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
    public_user = _strip_sensitive_fields(user)
    token = create_token(public_user)
    return {"token": token, "user": public_user}


@router.post("/auth/login")
async def auth_login(req: LoginRequest):
    """账号密码登录：校验通过后返回 JWT token。"""
    username = req.username.strip()
    if not username or not req.password:
        raise HTTPException(status_code=400, detail="用户名和密码不能为空")
    user = user_store.authenticate(username, req.password)
    if user is None:
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    public_user = _strip_sensitive_fields(user)
    token = create_token(public_user)
    return {"token": token, "user": public_user}


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


class ChangePasswordRequest(BaseModel):
    """修改密码请求体。"""
    old_password: str
    new_password: str


@router.post("/auth/change-password")
async def auth_change_password(
    req: ChangePasswordRequest,
    current_user: dict = Depends(get_current_user),
):
    """修改密码：校验旧密码正确后更新为新密码。"""
    openid = current_user.get("openid", "")
    if not req.old_password or not req.new_password:
        raise HTTPException(status_code=400, detail="旧密码和新密码不能为空")
    if len(req.new_password) < 6:
        raise HTTPException(status_code=400, detail="新密码长度不能少于 6 位")
    success = user_store.change_password(openid, req.old_password, req.new_password)
    if not success:
        raise HTTPException(status_code=400, detail="旧密码错误或用户不存在")
    return {"success": True}


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


# ===== 嵌入模型 API =====


class EmbedRequest(BaseModel):
    """嵌入请求体。"""
    input: str
    dimensions: Optional[int] = None


class EmbedBatchRequest(BaseModel):
    """批量嵌入请求体。"""
    input: List[str]
    dimensions: Optional[int] = None


@router.get("/embed/models")
async def get_embed_model_info(
    _: dict = Depends(get_current_user),
):
    """获取嵌入模型配置信息。"""
    config = load_embed_model_config()
    if config is None:
        return {"embed_model": None}
    return {
        "embed_model": {
            "name": config.name,
            "model_id": config.model_id,
            "embedding_dimensions": config.extra.get("embedding_dimensions"),
            "max_input_length": config.extra.get("max_input_length"),
        }
    }


@router.post("/embed")
async def embed_text(
    req: EmbedRequest,
    _: dict = Depends(get_current_user),
):
    """将文本转为向量表示，透传至嵌入模型 API。

    请求体：
    - input: 输入文本
    - dimensions: 可选，向量维度（模型支持动态维度时使用）

    返回：
    - embedding: 浮点数向量列表
    - model: 使用的嵌入模型标识
    - dimensions: 实际向量维度
    """
    config = load_embed_model_config()
    if config is None:
        raise HTTPException(
            status_code=503,
            detail="嵌入模型未配置，请配置 server/configs/embed_model.yaml",
        )

    embedding = get_embedding(req.input, config, dimensions=req.dimensions)
    if embedding is None:
        raise HTTPException(
            status_code=502,
            detail="调用嵌入模型 API 失败",
        )

    return {
        "embedding": embedding,
        "model": config.model_id,
        "dimensions": len(embedding),
    }


@router.post("/embed/batch")
async def embed_texts_batch(
    req: EmbedBatchRequest,
    _: dict = Depends(get_current_user),
):
    """批量将文本转为向量表示，透传至嵌入模型 API。

    请求体：
    - input: 输入文本列表
    - dimensions: 可选，向量维度

    返回：
    - embeddings: 浮点数向量列表的列表（顺序与输入一致）
    - model: 使用的嵌入模型标识
    """
    config = load_embed_model_config()
    if config is None:
        raise HTTPException(
            status_code=503,
            detail="嵌入模型未配置，请配置 server/configs/embed_model.yaml",
        )

    embeddings = get_embeddings_batch(req.input, config, dimensions=req.dimensions)
    if embeddings is None:
        raise HTTPException(
            status_code=502,
            detail="调用嵌入模型 API 失败",
        )

    # ===== 数据收集（SFT 数据集）：仅开启期间收集 + 管理员导出 =====


class DataCollectionRequest(BaseModel):
    """数据收集开关请求体。"""

    enabled: bool


@router.get("/settings/data-collection")
async def get_data_collection(
    current_user: dict = Depends(get_current_user),
):
    """查询当前用户是否开启数据收集。"""
    openid = current_user.get("openid", "")
    return {
        "enabled": is_collection_enabled(openid),
        "openid": openid,
    }


@router.post("/settings/data-collection")
async def set_data_collection(
    req: DataCollectionRequest,
    current_user: dict = Depends(get_current_user),
):
    """设置当前用户的数据收集开关。

    只有开启后产生的对话才会被收集进 SFT 数据集；关闭即停止写入。
    """
    openid = current_user.get("openid", "")
    set_collection_enabled(openid, req.enabled)
    return {"enabled": req.enabled, "openid": openid}


# ===== 主动延迟（API 调用频率限制） =====


class RateLimitRequest(BaseModel):
    """主动延迟开关请求体。"""

    enabled: bool


@router.get("/settings/rate-limit")
async def get_rate_limit(
    current_user: dict = Depends(get_current_user),
):
    """查询当前用户是否开启主动延迟（限制单个 agent 的 API 调用频率）。"""
    openid = current_user.get("openid", "")
    return {
        "enabled": is_rate_limit_enabled(openid),
        "openid": openid,
    }


@router.post("/settings/rate-limit")
async def set_rate_limit(
    req: RateLimitRequest,
    current_user: dict = Depends(get_current_user),
):
    """设置当前用户的主动延迟开关。

    开启后限制单个 agent 的 LLM API 调用频率（平均 6 次/分钟），
    适合交互式开发。持久化到 ``rate_limit_prefs`` 表，并同步更新
    ``llm.rate_limit`` 内存缓存（立即对后续 API 调用生效）。
    """
    openid = current_user.get("openid", "")
    set_rate_limit_enabled(openid, req.enabled)
    # 同步内存缓存：限流器按 (user_id, agent_id) 从缓存判定开关
    from llm.rate_limit import set_user_enabled

    set_user_enabled(openid, req.enabled)
    return {"enabled": req.enabled, "openid": openid}


def _is_admin(openid: str) -> bool:
    """校验是否管理员（从 app.yaml 的 data_export.admin_openids 读取）。"""
    admin_ids = get_config().get("data_export", {}).get("admin_openids", [])
    return openid in (admin_ids or [])


@router.get("/settings/data-collection/exports")
async def list_sft_export_files(
    current_user: dict = Depends(get_current_user),
):
    """列出已导出的 SFT jsonl 文件（仅管理员）。防止普通用户拉取全量数据越权。"""
    openid = current_user.get("openid", "")
    if not _is_admin(openid):
        raise HTTPException(status_code=403, detail="仅管理员可查看 SFT 导出文件")
    return {"files": list_sft_files()}


@router.get("/settings/data-collection/exports/{filename}")
async def download_sft_export_file(
    filename: str,
    current_user: dict = Depends(get_current_user),
):
    """下载指定 SFT jsonl 导出文件（仅管理员）。"""
    openid = current_user.get("openid", "")
    if not _is_admin(openid):
        raise HTTPException(status_code=403, detail="仅管理员可下载 SFT 导出文件")
    data = read_sft_file(filename)
    if data is None:
        raise HTTPException(status_code=404, detail="导出文件不存在")
    from fastapi.responses import Response

    return Response(
        content=data,
        media_type="application/x-ndjson",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )