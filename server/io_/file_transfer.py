"""跨工作空间文件传输（message 工具的文件发送能力底座）。

设计取向（按需求确定的三层策略）：

1. **同一共享工作根内（同 team 成员之间）→ 直接 ``cp``，零字节过后端。**
   本地模式全队共用 ``<baseDir>``、云端全队挂同一卷、SSH 全队同一远端根
   （见 ``local_executor_service._resolveWorkspaceDir`` /
   ``docker_manager.create_workspace(shared_with=...)``），因此同一 team 内
   "发送文件"只是把共享目录里的文件拷到接收方目录，后端不接触文件内容。

2. **跨工作根（不同 TOP agent）/ 跨模式 → 后端内存中转。**
   源端读、目标端写，字节在内存中过一道：不落盘、不写中间文件、不经 docker。
   适用于 local↔local / local↔ssh / ssh↔ssh 等前端执行器组合。

3. **任一端是 cloud → 走后端 docker。**
   前端执行器触达不到容器，这是不可绕过的边界（docker 例外）。

统一的落点语义：接收方工作空间 ``.input/<yyyymmdd>/<filename>``，与用户上传
附件的落点一致，接收方 agent 用相对路径即可 read。
"""
import base64
import datetime
import logging
import os
import shlex
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# 中转上限：后端内存里过一道的字节数上限，超过则拒绝而不是把后端打爆。
# 同根 cp 路径不受此限制（不经过后端内存）。
MAX_RELAY_BYTES = 32 * 1024 * 1024

# 附件落点目录前缀（与 chat._upload_attachments 保持一致）
_INPUT_DIR = ".input"


def default_dest_dir() -> str:
    """接收方默认落点目录：``.input/<yyyymmdd>``（与用户附件同语义）。"""
    return f"{_INPUT_DIR}/{datetime.datetime.now().strftime('%Y%m%d')}"


def _norm(path: str) -> str:
    """规范化工作空间相对路径（统一分隔符、去掉 ./ 前缀）。"""
    p = str(path or "").replace("\\", "/").strip()
    while p.startswith("./"):
        p = p[2:]
    return p.lstrip("/")


def _join(dest_dir: str, filename: str) -> str:
    d = _norm(dest_dir)
    return f"{d}/{filename}" if d else filename


def _same_workspace_root(src_ws: str, dst_ws: str) -> bool:
    """两个 workspace 是否落在**同一物理工作根**（可直接 cp）。"""
    return bool(src_ws) and src_ws == dst_ws


def copy_file(
    src_io: Any,
    src_ws: str,
    src_path: str,
    dst_io: Any,
    dst_ws: str,
    dest_dir: Optional[str] = None,
    dest_name: Optional[str] = None,
) -> Dict[str, Any]:
    """把一个工作空间内的文件复制到另一个工作空间（同步接口）。

    :param src_io: 源端 WorkspaceIO
    :param src_ws: 源 workspace_id
    :param src_path: 源文件的工作空间相对路径
    :param dst_io: 目标端 WorkspaceIO
    :param dst_ws: 目标 workspace_id
    :param dest_dir: 目标目录（缺省 ``.input/<yyyymmdd>``）
    :param dest_name: 目标文件名（缺省沿用源文件名）
    :return: 成功 ``{"kind": "same_root"|"relay", "dest_path": "...", "size": n}``；
             失败 ``{"error": "...", "detail": ...}``
    """
    src_rel = _norm(src_path)
    if not src_rel:
        return {"error": "源文件路径为空"}
    name = dest_name or os.path.basename(src_rel)
    if not name:
        return {"error": f"无法确定目标文件名: {src_rel!r}"}
    dst_rel = _join(dest_dir or default_dest_dir(), name)

    # --- 策略 1：同一共享工作根 → cp（后端不接触内容） ---
    if _same_workspace_root(src_ws, dst_ws) and src_io is dst_io:
        return _copy_same_root(src_io, src_ws, src_rel, dst_rel)

    # --- 策略 2/3：跨工作根 → 读 + 写（cloud 端由 CloudWorkspaceIO 落 docker） ---
    return _copy_relay(src_io, src_ws, src_rel, dst_io, dst_ws, dst_rel)


def _copy_same_root(
    io: Any, workspace_id: str, src_rel: str, dst_rel: str
) -> Dict[str, Any]:
    """同一工作根内直接 cp（不经后端内存，也不落中间文件）。"""
    from io_.workspace_io import run_io

    # 先确认源存在并取大小（避免 cp 失败时报出难懂的 shell 错误）
    probe = run_io(io.exec_shell(
        workspace_id,
        f"wc -c < {shlex.quote(src_rel)} 2>/dev/null || true",
        timeout=30,
    ))
    size_text = (probe.get("stdout", "") or "").strip()
    if not size_text.isdigit():
        return {
            "error": f"源文件不存在或不可读: {src_rel}",
            "detail": (probe.get("stderr") or probe.get("error") or "").strip()[:200],
        }
    dest_dir = os.path.dirname(dst_rel)
    cmd = (
        f"mkdir -p {shlex.quote(dest_dir)} && "
        f"cp -f {shlex.quote(src_rel)} {shlex.quote(dst_rel)} && "
        f"wc -c < {shlex.quote(dst_rel)}"
    )
    result = run_io(io.exec_shell(workspace_id, cmd, timeout=120))
    if result.get("error") or result.get("exit_code", -1) != 0:
        return {
            "error": f"复制文件失败: {src_rel} -> {dst_rel}",
            "detail": (
                result.get("error")
                or (result.get("stderr") or "").strip()
                or ""
            )[:300],
        }
    written = (result.get("stdout", "") or "").strip().splitlines()
    size = int(written[-1]) if written and written[-1].strip().isdigit() else int(size_text)
    return {"kind": "same_root", "dest_path": dst_rel, "size": size}


def _copy_relay(
    src_io: Any,
    src_ws: str,
    src_rel: str,
    dst_io: Any,
    dst_ws: str,
    dst_rel: str,
) -> Dict[str, Any]:
    """跨工作根：源端读字节、目标端写字节（后端仅作内存中转）。

    分块进行（块大小见 ``_RELAY_CHUNK``），避免把大文件整体驻留在内存里；
    超过 :data:`MAX_RELAY_BYTES` 时直接拒绝并说明原因（同根 cp 不受限）。
    """
    read = getattr(src_io, "read_file_base64", None)
    write = getattr(dst_io, "write_file_base64", None)
    if read is None or write is None:
        return {
            "error": "当前执行链路不支持跨工作空间文件传输",
            "hint": "同 team 成员之间走共享目录直接复制；跨团队请确认前端执行器在线",
        }

    from io_.workspace_io import run_io

    total = 0
    chunks: List[bytes] = []
    while True:
        try:
            part = run_io(read(src_ws, src_rel, offset=total, length=_RELAY_CHUNK))
        except AttributeError:
            # IO 实现未提供字节通道（旧实现/自定义实现）：明确报错而不是抛栈
            return {
                "error": "当前执行链路不支持跨工作空间文件传输",
                "hint": "同 team 成员之间走共享目录直接复制；跨团队请确认前端执行器在线",
            }
        except Exception as exc:  # noqa: BLE001
            return {
                "error": f"读取源文件失败: {src_rel}",
                "detail": str(exc)[:300],
            }
        if part.get("error"):
            return {
                "error": f"读取源文件失败: {src_rel}",
                "detail": str(part.get("error"))[:300],
            }
        raw = part.get("chunk") or b""
        if not raw:
            break
        total += len(raw)
        if total > MAX_RELAY_BYTES:
            return {
                "error": (
                    f"文件超过中转上限（{MAX_RELAY_BYTES // (1024 * 1024)} MiB）："
                    f"{src_rel}"
                ),
                "hint": "同 team 成员之间可直接在共享目录内复制，不受此限制；"
                        "跨团队大文件请改用共享目录或文件面板",
            }
        chunks.append(raw)
        if part.get("eof"):
            break

    if total == 0 and not chunks:
        return {"error": f"源文件为空或不存在: {src_rel}"}

    try:
        result = run_io(write(dst_ws, dst_rel, b"".join(chunks)))
    except AttributeError:
        return {
            "error": "当前执行链路不支持跨工作空间文件传输",
            "hint": "同 team 成员之间走共享目录直接复制；跨团队请确认前端执行器在线",
        }
    if result.get("error"):        return {
            "error": f"写入目标文件失败: {dst_rel}",
            "detail": str(result.get("error"))[:300],
        }
    return {"kind": "relay", "dest_path": dst_rel, "size": total}


# 中转分块大小：64 KiB 是 base64 膨胀（约 87 KiB）与往返次数之间的折中
_RELAY_CHUNK = 64 * 1024


def hint_block(copied: List[Dict[str, Any]]) -> str:
    """把已送达文件渲染成注入消息正文的路径块。"""
    if not copied:
        return ""
    lines = ["[随消息送达的文件，可直接用 read 工具读取]"]
    for item in copied:
        lines.append(f"- {item.get('dest_path', '')}（{item.get('size', 0)} 字节）")
    return "\n".join(lines)


def encode(data: bytes) -> str:
    """base64 编码（供各 IO 实现复用）。"""
    return base64.b64encode(data).decode("ascii")


def decode(text: str) -> bytes:
    """base64 解码（供各 IO 实现复用）。"""
    return base64.b64decode(text or "")
