"""IO REST 路由：工作空间文件管理 / 工作空间生命周期 / Git 操作。

自 api/routes.py 迁出（P0 组件化重组）。
全局句柄统一经 state 模块读取（state.docker_manager / state.local_executor / state.ws_manager）。
"""
import asyncio
import base64
import datetime
import logging
import os
import tempfile
import uuid
from typing import Any, Dict, List, Optional
from urllib.parse import quote

logger = logging.getLogger(__name__)

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

import state
from config.config import get_config
from ws.auth import get_current_user

router = APIRouter(prefix="/api")


# ===== 工作空间文件管理 =====


def _escape_shell_path(path: str) -> str:
    """转义路径中的单引号，防止 shell 命令注入。"""
    return path.replace("'", "'\\''")


def _parse_ls_output(
    output: str, base_path: str = "", skip_names: Optional[set] = None
) -> List[Dict[str, Any]]:
    """解析 ``ls -la --time-style=long-iso`` 输出为文件信息列表。

    ：param base_path: 当前列出的目录（相对工作空间根），用于拼接文件完整路径，
        使前端能直接以 ``path`` 打开子目录中的文件（如 PDF 预览/内容读取）。
    ：param skip_names: 需要从列表中剔除的条目名集合（如共享成员隐藏 .git / workspaces）。
    """
    base = base_path.strip("/")
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
        if skip_names and name in skip_names:
            continue
        perms = parts[0]
        size_str = parts[4]
        size = int(size_str) if size_str.isdigit() else 0
        modified = f"{parts[5]} {parts[6]}"
        file_type = "dir" if perms.startswith("d") else "file"
        rel = f"{base}/{name}" if base else name
        files.append(
            {
                "name": name,
                "path": rel,
                "size": size,
                "type": file_type,
                "modified": modified,
            }
        )
    return files


def _get_docker_manager():
    """从全局 state 获取 DockerManager 实例。"""
    docker_manager = state.docker_manager
    if docker_manager is None:
        raise HTTPException(status_code=503, detail="Docker 管理器未初始化")
    return docker_manager


def _local_mode_ctx(user_id: str, local_key: str) -> Optional[Dict[str, Any]]:
    """若 (user_id, local_key) 处于本地模式，返回转发上下文，否则返回 None。

    local_executor / ws_manager 经全局 state 读取。
    """
    local_executor = state.local_executor
    ws_manager = state.ws_manager
    if local_executor is None or ws_manager is None:
        return None
    if not local_executor.is_local(user_id, local_key):
        return None
    return {"local_executor": local_executor, "ws_manager": ws_manager}


@router.get("/files/{workspace_id}")
async def list_files(
    workspace_id: str,
    request: Request,
    path: str = Query("", description="子路径，默认根目录"),
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """获取工作空间文件列表。

    查询参数 ``path`` 指定子路径（默认根目录）。
    本地模式下通过反向 WS 转发给前端本地执行器，列出用户本机工作目录；
    云端模式通过 docker_manager.exec_in_workspace 执行 ``ls -la`` 获取文件列表。
    """
    # 本地模式：转发给前端本地执行器，列出本机工作空间目录
    user_id = current_user.get("openid", "")
    local_key = top_agent_id or workspace_id
    ctx = _local_mode_ctx(user_id, local_key)
    if ctx is not None:
        # 异步端点内不可阻塞事件循环（否则 WS 接收无法处理响应导致死锁），
        # 因此放入线程池中执行阻塞式请求
        result = await asyncio.to_thread(
            ctx["local_executor"].request,
            ctx["ws_manager"],
            user_id,
            {
                "op": "list_files",
                "workspace_id": workspace_id,
                "path": path,
            },
        )
        if "error" in result:
            raise HTTPException(status_code=404, detail=result)
        return {"files": result.get("files", [])}

    docker_manager = _get_docker_manager()
    if not path:
        # 根目录：使用 "."，避免空字符串被当作不存在的文件名
        result = docker_manager.exec_in_workspace(
            workspace_id, ["sh", "-c", "ls -la --time-style=long-iso . 2>&1"]
        )
    else:
        safe_path = _escape_shell_path(path)
        result = docker_manager.exec_in_workspace(
            workspace_id,
            ["sh", "-c", 'ls -la --time-style=long-iso "$1" 2>&1', "sh", safe_path],
        )
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    if result.get("exit_code", 0) != 0:
        raise HTTPException(status_code=404, detail=f"路径不存在: {path}")
    # 云端列表隐藏 .git（git 元数据）与 workspaces（各 agent 私人空间），
    # 与本地模式的文件浏览语义保持一致，避免私人记忆互相泄露
    files = _parse_ls_output(
        result.get("stdout", ""), path, {".git", "workspaces"}
    )
    return {"files": files}


@router.get("/files/{workspace_id}/content")
async def get_file_content(
    workspace_id: str,
    request: Request,
    path: str = Query(..., description="文件路径"),
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """获取文件内容。

    查询参数 ``path`` 指定文件路径。
    本地模式下通过反向 WS 转发给前端本地执行器读取本机文件；
    云端模式通过 docker_manager.exec_in_workspace 读取文件内容。
    图片文件（png/jpg/gif 等）返回 base64 编码，``is_base64=true``。
    """
    if not path:
        raise HTTPException(status_code=400, detail="path 参数不能为空")

    # 本地模式：转发给前端本地执行器，读取本机工作空间文件
    user_id = current_user.get("openid", "")
    local_key = top_agent_id or workspace_id
    ctx = _local_mode_ctx(user_id, local_key)
    if ctx is not None:
        result = await asyncio.to_thread(
            ctx["local_executor"].request,
            ctx["ws_manager"],
            user_id,
            {
                "op": "read_file",
                "workspace_id": workspace_id,
                "path": path,
                "encoding": "utf-8",
            },
        )
        if "error" in result or result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=404, detail="文件不存在或无法读取")
        content = result.get("content", "")
        return {
            "content": content,
            "path": path,
            "size": len(content.encode("utf-8")),
        }

    docker_manager = _get_docker_manager()
    safe_path = _escape_shell_path(path)

    # 图片文件：base64 编码返回，避免二进制被 cat 文本化破坏
    _image_exts = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".ico"}
    lower_path = path.lower()
    if any(lower_path.endswith(ext) for ext in _image_exts):
        result = docker_manager.exec_in_workspace(
            workspace_id,
            ["sh", "-c", 'base64 "$1" 2>/dev/null', "sh", safe_path],
        )
        if result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=404, detail="文件不存在或无法读取")
        b64 = result.get("stdout", "").replace("\n", "").replace("\r", "")
        return {
            "content": b64,
            "path": path,
            "size": len(b64),
            "is_base64": True,
        }

    result = docker_manager.exec_in_workspace(
        workspace_id,
        ["sh", "-c", 'cat "$1" 2>&1', "sh", safe_path],
    )
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=404, detail=result)
    if result.get("exit_code", 0) != 0:
        # 兼容旧工作空间：读取 .self/activity.log 缺失时先初始化再返回
        if path.rstrip("/").endswith("activity.log"):
            init = docker_manager.exec_in_workspace(
                workspace_id,
                ["sh", "-c", "mkdir -p .self && echo '# Agent 活动日志' > .self/activity.log"],
            )
            if init.get("exit_code", 0) == 0:
                result = docker_manager.exec_in_workspace(
                    workspace_id,
                    ["sh", "-c", 'cat "$1" 2>&1', "sh", safe_path],
                )
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

    本地模式下直接统计本地目录大小；查询失败时返回 0（不阻塞上传）。
    """
    if getattr(docker_manager, "_use_local", lambda: False)():
        import os as _os
        total = 0
        local_workspace = docker_manager._local_workspace_path(workspace_id)
        if not local_workspace.exists():
            return 0
        for dirpath, dirnames, filenames in _os.walk(str(local_workspace)):
            for fname in filenames:
                try:
                    total += _os.path.getsize(_os.path.join(dirpath, fname))
                except OSError:
                    continue
        return total
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
    docker_manager = _get_docker_manager()
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
        # 三个参数均通过 shell 位置参数传入，避免字符串插值带来的命令注入风险
        # b64_content 为 base64 字符（仅 [A-Za-z0-9+/=]），安全无注入风险
        result = docker_manager.exec_in_workspace(
            workspace_id,
            [
                "sh", "-c",
                'mkdir -p "$1" && echo "$2" | base64 -d > "$3"',
                "sh", safe_dirname, b64_content, safe_target,
            ],
        )
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
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """从工作空间下载文件，返回文件内容（StreamingResponse）。

    使用 base64 方案读取二进制内容（避免 cat 经 stdout 的 UTF-8 解码损坏二进制）。
    本地模式下读取用户本机文件。
    """
    content = await _read_file_bytes(
        workspace_id, req.path, current_user, top_agent_id
    )
    filename = req.path.rsplit("/", 1)[-1] or "download"
    # 使用 RFC 5987 格式支持非 Latin-1 字符（如中文文件名）
    encoded_filename = quote(filename, safe="")
    return StreamingResponse(
        iter([content]),
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{encoded_filename}"
        },
    )


@router.post("/files/{workspace_id}/download_folder")
async def download_folder(
    workspace_id: str,
    req: FileDownloadRequest,
    request: Request,
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """从工作空间下载文件夹，打包为 tar.gz 返回。"""
    # 本地模式暂不支持文件夹打包下载（tar 命令与路径跨平台差异较大）
    user_id = current_user.get("openid", "")
    local_key = top_agent_id or workspace_id
    if _local_mode_ctx(user_id, local_key) is not None:
        raise HTTPException(
            status_code=400,
            detail="本地模式暂不支持文件夹打包下载，请逐个下载文件",
        )
    docker_manager = _get_docker_manager()
    safe_path = _escape_shell_path(req.path)

    # 在容器内 tar 打包指定目录，base64 编码输出（避免二进制被 stdout 损坏）
    # safe_path 通过 shell 位置参数 $1 传入，避免字符串插值带来的命令注入风险
    result = docker_manager.exec_in_workspace(
        workspace_id,
        ["sh", "-c", 'tar -czf - -C /workspace "$1" 2>&1 | base64', "sh", safe_path],
    )
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=500, detail=str(result))
    if result.get("exit_code", 0) != 0:
        raise HTTPException(status_code=404, detail="目录不存在或无法读取")
    b64_data = "".join(result.get("stdout", "").split())
    if not b64_data:
        raise HTTPException(status_code=404, detail="目录为空或打包失败")
    content = base64.b64decode(b64_data)
    folder_name = req.path.rsplit("/", 1)[-1] or "download"
    filename = f"{folder_name}.tar.gz"
    return StreamingResponse(
        iter([content]),
        media_type="application/gzip",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


async def _read_file_bytes(
    workspace_id: str,
    path: str,
    current_user: Optional[dict] = None,
    top_agent_id: str = "",
) -> bytes:
    """从工作空间读取文件原始字节。

    本地模式下通过反向 WS 让前端本地执行器读取本机文件（base64 回传），
    服务器端解码后返回字节；云端模式在容器内用 base64 编码文件内容，
    服务器端解码后返回字节。适用于 PDF 等二进制文件。
    """
    # 本地模式：转发给前端本地执行器，读取本机文件字节（base64 回传）
    if current_user:
        user_id = current_user.get("openid", "")
        local_key = top_agent_id or workspace_id
        ctx = _local_mode_ctx(user_id, local_key)
        if ctx is not None:
            result = await asyncio.to_thread(
                ctx["local_executor"].request,
                ctx["ws_manager"],
                user_id,
                {
                    "op": "read_file_bytes",
                    "workspace_id": workspace_id,
                    "path": path,
                },
            )
            if "error" in result or result.get("exit_code", 0) != 0:
                raise HTTPException(status_code=404, detail="文件不存在或无法读取")
            b64_data = "".join(str(result.get("content_base64", "")).split())
            if not b64_data:
                raise HTTPException(status_code=500, detail="文件内容为空")
            return base64.b64decode(b64_data)

    docker_manager = _get_docker_manager()
    safe_path = _escape_shell_path(path)
    result = docker_manager.exec_in_workspace(
        workspace_id,
        ["sh", "-c", 'base64 "$1" 2>/dev/null', "sh", safe_path],
    )
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
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """获取 PDF 文件信息（总页数、标题、作者）。

    通过 PyMuPDF 解析 PDF 元数据，返回
    ``{"total_pages": N, "title": "...", "author": "..."}``。
    """
    if fitz is None:
        raise HTTPException(status_code=503, detail="PyMuPDF 未安装")
    if not path:
        raise HTTPException(status_code=400, detail="path 参数不能为空")

    pdf_bytes = await _read_file_bytes(
        workspace_id, path, current_user, top_agent_id
    )
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
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """获取 PDF 指定页的预览图片（PNG，base64 编码）。

    通过 PyMuPDF 将指定页渲染为 pixmap，转为 PNG 后 base64 编码返回：
    ``{"image": "...", "page": N, "total_pages": M, "width": W, "height": H}``。
    """
    if fitz is None:
        raise HTTPException(status_code=503, detail="PyMuPDF 未安装")
    if not path:
        raise HTTPException(status_code=400, detail="path 参数不能为空")

    pdf_bytes = await _read_file_bytes(
        workspace_id, path, current_user, top_agent_id
    )
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


class SyncToLocalRequest(BaseModel):
    """同步工作空间文件到本地目录请求体。"""

    local_path: str


@router.post("/files/{workspace_id}/syncToLocal")
async def sync_to_local(
    workspace_id: str,
    req: SyncToLocalRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """将工作空间内所有文件同步到本地目录。

    在容器内执行 ``tar`` 打包 /workspace 下所有文件，通过 Docker exec
    的 stdout 流式传回，服务端直接写入用户指定的本地路径。

    :param workspace_id: 工作空间标识
    :param req.local_path: 本地目标目录（不存在则自动创建）
    """
    import io as _io
    import tarfile

    local_path = req.local_path.strip()
    if not local_path:
        raise HTTPException(status_code=400, detail="local_path 不能为空")

    docker_manager = _get_docker_manager()

    # 容器内 tar 打包后 base64 编码，避免 exec stdout 二进制被 UTF-8 解码损坏
    result = docker_manager.exec_in_workspace(
        workspace_id,
        ["sh", "-c", "tar -cf - --exclude='.git' -C /workspace . | base64"],
    )
    if "error" in result and "exit_code" not in result:
        raise HTTPException(status_code=500, detail=result)

    b64_data = "".join(result.get("stdout", "").split())
    if not b64_data:
        raise HTTPException(status_code=500, detail="工作空间为空或打包失败")

    import base64 as _b64
    tar_bytes = _b64.b64decode(b64_data)

    # 确保本地目录存在
    os.makedirs(local_path, exist_ok=True)

    # 逐个解包 tar 成员：已存在的文件覆盖，已存在的目录跳过
    try:
        with tarfile.open(fileobj=_io.BytesIO(tar_bytes), mode="r") as tar:
            for member in tar.getmembers():
                member_path = os.path.join(local_path, member.name)
                # 防止路径穿越（如 ../../etc/passwd）
                normalized = os.path.normpath(member_path)
                if not normalized.startswith(os.path.normpath(local_path)):
                    continue
                if member.isdir():
                    os.makedirs(member_path, exist_ok=True)
                elif member.isfile():
                    os.makedirs(os.path.dirname(member_path), exist_ok=True)
                    tar.extract(member, path=local_path)
                # 符号链接等跳过
    except Exception as exc:
        raise HTTPException(
            status_code=500, detail=f"解包到本地失败: {exc}"
        ) from exc

    return {"success": True, "local_path": local_path}


# ===== 工作空间生命周期管理 =====


class CreateWorkspaceRequest(BaseModel):
    """创建工作空间请求体。"""

    agent_name: str
    parent_workspace_id: Optional[str] = None


class ExecCommandRequest(BaseModel):
    """在工作空间内执行命令的请求体。"""

    command: List[str]


@router.post("/workspaces")
async def create_workspace(
    req: CreateWorkspaceRequest,
    request: Request,
    _: dict = Depends(get_current_user),
):
    """创建工作空间。

    请求体：``{"agent_name": "...", "parent_workspace_id": "..."}``（parent 可选）
    """
    docker_manager = _get_docker_manager()
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
    docker_manager = _get_docker_manager()
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
    docker_manager = _get_docker_manager()
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
    docker_manager = _get_docker_manager()
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
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """查看提交历史。

    查询参数 ``limit``（默认 50），返回 ``{"commits": [...]}``。
    本地模式下通过反向 WS 让前端本地执行器在本机工作空间执行 ``git log``。
    """
    # 本地模式：转发给前端本地执行器，在本机工作空间执行 git log
    user_id = current_user.get("openid", "")
    local_key = top_agent_id or workspace_id
    ctx = _local_mode_ctx(user_id, local_key)
    if ctx is not None:
        result = await asyncio.to_thread(
            ctx["local_executor"].request,
            ctx["ws_manager"],
            user_id,
            {
                "op": "git_log",
                "workspace_id": workspace_id,
                "limit": int(limit),
            },
        )
        if "error" in result:
            raise HTTPException(status_code=500, detail=result)
        return {"commits": result.get("commits", [])}

    docker_manager = _get_docker_manager()
    result = docker_manager.git_log(workspace_id, limit=limit)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return {"commits": result.get("commits", [])}


@router.get("/workspaces/{workspace_id}/git/branches")
async def git_branches(
    workspace_id: str,
    request: Request,
    top_agent_id: str = Query("", description="所属顶层 agent ID（成员浏览时传入，用于本地模式判定）"),
    current_user: dict = Depends(get_current_user),
):
    """查看分支列表，返回 ``{"branches": [...], "current": "..."}``。"""
    # 本地模式：转发给前端本地执行器，在本机工作空间执行 git branch
    user_id = current_user.get("openid", "")
    local_key = top_agent_id or workspace_id
    ctx = _local_mode_ctx(user_id, local_key)
    if ctx is not None:
        result = await asyncio.to_thread(
            ctx["local_executor"].request,
            ctx["ws_manager"],
            user_id,
            {"op": "git_branches", "workspace_id": workspace_id},
        )
        if "error" in result:
            raise HTTPException(status_code=500, detail=result)
        return {
            "branches": result.get("branches", []),
            "current": result.get("current", ""),
        }

    docker_manager = _get_docker_manager()
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
    docker_manager = _get_docker_manager()
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
    docker_manager = _get_docker_manager()
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
    docker_manager = _get_docker_manager()
    result = docker_manager.git_fetch(workspace_id, remote=req.remote)
    if "error" in result:
        raise HTTPException(status_code=500, detail=result)
    return result


# ===== SSH 运行模式 =====


class SSHRegisterRequest(BaseModel):
    """注册 SSH 运行模式请求体。"""

    top_agent_id: str
    host: str
    port: int = 22
    username: str = ""
    auth_type: str = "password"
    password: str = ""
    private_key_path: str = ""
    remote_base_dir: str = ""


def _get_ssh_manager():
    """从全局 state 获取 SSHConnectionManager 实例。"""
    ssh_manager = state.ssh_manager
    if ssh_manager is None:
        raise HTTPException(status_code=503, detail="SSH 管理器未初始化")
    return ssh_manager


@router.post("/ssh")
async def register_ssh(
    req: SSHRegisterRequest,
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """注册 SSH 运行模式：先测试连接，成功后持久化并激活。

    与 local 模式互斥：同一 top agent 已启用 local 时拒绝（须先注销 local）。
    """
    user_id = current_user.get("openid", "")
    top_agent_id = req.top_agent_id.strip()
    if not top_agent_id:
        raise HTTPException(status_code=400, detail="top_agent_id 不能为空")

    from io_.mode_resolver import check_exclusive

    ok, reason = check_exclusive(user_id, top_agent_id, "ssh")
    if not ok:
        raise HTTPException(status_code=409, detail=reason)

    ssh_manager = _get_ssh_manager()
    ok, message = ssh_manager.register(
        user_id,
        top_agent_id,
        {
            "host": req.host,
            "port": req.port,
            "username": req.username,
            "auth_type": req.auth_type,
            "password": req.password,
            "private_key_path": req.private_key_path,
            "remote_base_dir": req.remote_base_dir,
        },
    )
    if not ok:
        raise HTTPException(status_code=400, detail=message)
    return {"success": True, "top_agent_id": top_agent_id}


@router.delete("/ssh")
async def unregister_ssh(
    top_agent_id: str = Query("", description="顶部 agent ID"),
    current_user: dict = Depends(get_current_user),
):
    """注销 SSH 运行模式：关闭连接并删除配置（该 agent 恢复云端执行）。"""
    user_id = current_user.get("openid", "")
    if not top_agent_id:
        raise HTTPException(status_code=400, detail="top_agent_id 不能为空")
    ssh_manager = _get_ssh_manager()
    removed = ssh_manager.unregister(user_id, top_agent_id)
    return {"success": True, "removed": removed}
