"""Agent REST 路由：agent CRUD / 模型列表 / 对话历史 / compact / teammates。

自 main.py 与 api/routes.py 迁出（P0 组件化重组）。
"""
import asyncio
import logging
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

import state
from agent.chat import (
    _active_tasks,
    _dispatch_agent_message,
    _get_workspace_io,
    _parse_roster_table,
    resume_after_answer,
)
from config.config import get_config
from config.models import get_model_configs
from data.agent_store import (
    create_agent,
    delete_agent,
    get_agent,
    get_agents,
    update_agent,
)
from data.conversation_store import (
    clear_context,
    clear_history,
    count_messages_by_session,
    get_history,
    get_pending_question,
    list_questions,
    load_context,
    mark_pending_answered,
    save_context,
)
from data.session_cache import clear_user_agent, get_session
from data.team_init import init_team_for_top
from data.team_store import delete_team
from io_.workspace_io import run_io
from llm.llm import AgentLLMSession
from data.session_store import (
    DEFAULT_SESSION,
    create_session,
    delete_session,
    get_selected_spec_ids,
    get_session_record,
    list_sessions,
    rename_session,
    set_selected_spec_ids,
    touch_session,
    update_session_title_from_first_message,
)
from ws.auth import get_current_user

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api")


@router.get("/conversations/{agent_id}")
async def get_conversation_history(
    agent_id: str,
    session_id: str = DEFAULT_SESSION,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """拉取指定 agent/会话的对话历史（SQLite 持久化）。

    ``session_id`` 缺省为默认会话；传 ``"all"`` 时返回该 agent 全部会话的消息
    （消息按会话分组），供前端"全部会话"视图使用。
    """
    user_id = current_user.get("openid", "")
    if session_id == "all":
        return {
            "agent_id": agent_id,
            "session_id": session_id,
            "messages": get_history(user_id, agent_id, session_id=None),
        }
    return {
        "agent_id": agent_id,
        "session_id": session_id,
        "messages": get_history(user_id, agent_id, session_id=session_id),
    }


@router.delete("/conversations/{agent_id}")
async def delete_conversation(
    agent_id: str,
    session_id: Optional[str] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """软删除指定 agent/会话的对话历史（``agent_id == "all"`` 时清空该用户全部）。

    软删除（标记 ``deleted_at``）三处数据，底层一律保留用于后期审计
    （含 LLM CoT / 完整上下文）：

    - ``messages``：对话消息（用户提问 + agent 回复 + 工具卡片）
    - ``agent_context``：LLM 持久化上下文（OpenAI messages 格式）
    - 内存会话缓存：使下次发消息重建会话（live 状态重置）

    传 ``session_id`` 时仅清空该会话（与 delete_session 配合使用）；
    不传时清空该 agent 全部会话。彻底清理只能由
    ``user_store.purge_expired_users`` 在用户注销保留期满后触发。
    """
    user_id = current_user.get("openid", "")
    target = None if agent_id == "all" else agent_id
    deleted = clear_history(user_id, target, session_id=session_id)
    # 同步软删除 LLM 上下文：否则清空后 agent 仍持有旧上下文，
    # 下次发消息会引用已软删除的历史消息，破坏"会话已重置"语义
    if target is None:
        clear_context(user_id, None, session_id=session_id)
        # 清空该用户全部内存会话缓存
        # （clear_user_agent 按 (user_id, agent_id) 清理，此处逐 agent 处理）
        for agent in get_agents(user_id):
            clear_user_agent(user_id, agent["id"], session_id=session_id)
    else:
        clear_context(user_id, target, session_id=session_id)
        clear_user_agent(user_id, target, session_id=session_id)
    return {"success": True, "deleted": deleted}


@router.post("/agents/{agent_id}/compact")
async def compact_agent_context(
    agent_id: str,
    body: Optional[Dict[str, Any]] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """手动压缩 normal LLM 的上下文（compact 按钮触发）。

    从会话缓存中取出该 agent 指定会话并强制压缩：
    - 中间消息总结为一条 summary，保留最近 N 条。
    - 无限上下文 LLM 无操作（返回 compressed=False）。

    缓存未命中（如后端重启后内存会话已清空）时，尝试从数据库
    ``agent_context`` 表恢复持久化上下文再压缩，避免误报
    "该 agent 当前没有活跃的会话上下文"。
    """
    user_id = current_user.get("openid", "")
    session_id = (body or {}).get("session_id") or DEFAULT_SESSION
    session = get_session(user_id, agent_id, session_id)
    restored_from_db = False
    if session is None:
        # 内存缓存未命中：尝试从 DB 恢复持久化上下文
        restored = load_context(user_id, agent_id, session_id)
        if not restored:
            return {
                "success": True,
                "compressed": False,
                "reason": "no_active_session",
                "message": "该 agent 当前没有活跃的会话上下文",
            }
        # 用 agent 绑定的模型构建会话（与发消息路径一致），
        # 仅加载持久化上下文用于压缩，不重复注入 system prompt。
        agent = get_agent(user_id, agent_id)
        model_id = agent.get("model_id") if agent else None
        model_config = state.model_configs.get(model_id)
        if model_config is None:
            model_config = next(iter(state.model_configs.values()))
        session = AgentLLMSession(
            model_config=model_config,
            workspace_id=(agent or {}).get("workspace_id", "") or agent_id,
            system_prompt="",
            user_id=user_id,
            agent_id=agent_id,
        )
        session.context = restored
        restored_from_db = True
    # compress 内会在重构 context 后重建 system prompt（读 .self 文件）；
    # 本地模式反向 WS 阻塞读，须放入线程池避免死锁事件循环
    compressed = await asyncio.to_thread(session.compress, force=True)
    if restored_from_db:
        # 压缩结果写回 DB，保证重启后上下文仍是压缩后的最新状态
        save_context(user_id, agent_id, session.context, session_id)
    result: Dict[str, Any] = {
        "success": True,
        "compressed": compressed,
        "context_size": len(session.context),
        "session_id": session_id,
    }
    # 有活跃会话但未实际压缩时，区分原因（对话消息太少 / 最近对话均在保留窗口内），
    # 避免前端误报"无需压缩或该 agent 不支持"
    if not compressed:
        non_system = [m for m in session.context if m.get("role") != "system"]
        result["reason"] = (
            "too_few_messages" if len(non_system) <= 1 else "nothing_to_summarize"
        )
    return result


# ===== 多会话管理（P2 多会话并行） =====


@router.get("/agents/{agent_id}/sessions")
async def list_agent_sessions(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """列出指定 agent 的全部会话元数据（按最近更新倒序）。"""
    user_id = current_user.get("openid", "")
    sessions = list_sessions(user_id, agent_id)
    # 各会话消息数：前端据其判断该 agent 是否已有任何会话开始过对话
    # （运行模式按 agent 级锁定，不受切换会话影响）
    counts = count_messages_by_session(user_id, agent_id)
    # 附带各会话的选中 Spec 与消息数/上下文占用，供前端会话列表展示
    for s in sessions:
        s["selected_spec_ids"] = get_selected_spec_ids(user_id, s["session_id"])
        s["message_count"] = counts.get(s["session_id"], 0)
    return {"agent_id": agent_id, "sessions": sessions}


@router.post("/agents/{agent_id}/sessions")
async def create_agent_session(
    agent_id: str,
    body: Optional[Dict[str, Any]] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """新建一个会话（可选 title / 指定 session_id）。"""
    user_id = current_user.get("openid", "")
    body = body or {}
    session = create_session(
        user_id,
        agent_id,
        title=str(body.get("title") or ""),
        session_id=str(body.get("session_id") or ""),
    )
    return {"success": True, "session": session}


@router.get("/agents/{agent_id}/sessions/{session_id}")
async def get_agent_session(
    agent_id: str,
    session_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """查询单个会话详情（元数据 + 对话历史 + 选中 Spec）。"""
    user_id = current_user.get("openid", "")
    record = get_session_record(user_id, session_id)
    if record is None:
        raise HTTPException(status_code=404, detail="会话不存在")
    record["selected_spec_ids"] = get_selected_spec_ids(user_id, session_id)
    record["messages"] = get_history(user_id, agent_id, session_id=session_id)
    return {"session": record}


@router.patch("/agents/{agent_id}/sessions/{session_id}")
async def rename_agent_session(
    agent_id: str,
    session_id: str,
    body: Optional[Dict[str, Any]] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """重命名会话标题。"""
    user_id = current_user.get("openid", "")
    title = str((body or {}).get("title") or "").strip()
    if not title:
        return {"success": False, "error": "标题不能为空"}
    ok = rename_session(user_id, session_id, title)
    if not ok:
        raise HTTPException(status_code=404, detail="会话不存在")
    touch_session(user_id, session_id)
    return {"success": True}


@router.delete("/agents/{agent_id}/sessions/{session_id}")
async def delete_agent_session(
    agent_id: str,
    session_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """删除会话（软删除元数据 + 消息 + 上下文 + 清空内存缓存）。"""
    user_id = current_user.get("openid", "")
    ok = delete_session(user_id, session_id)
    if not ok:
        raise HTTPException(status_code=404, detail="会话不存在")
    clear_user_agent(user_id, agent_id, session_id=session_id)
    return {"success": True}


@router.post("/agents/{agent_id}/sessions/{session_id}/specs")
async def set_agent_session_specs(
    agent_id: str,
    session_id: str,
    body: Optional[Dict[str, Any]] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """设置会话选中的 Spec（多选挂 hook，供 P4-spec 使用）。"""
    user_id = current_user.get("openid", "")
    spec_ids: List[str] = list((body or {}).get("spec_ids") or [])
    # 会话元数据可能尚不存在（如默认会话未发过消息）：先创建再写，
    # 否则 UPDATE 影响 0 行，勾选不会持久化
    create_session(user_id, agent_id, session_id=session_id)
    set_selected_spec_ids(user_id, session_id, spec_ids)
    touch_session(user_id, session_id)
    return {
        "success": True,
        "selected_spec_ids": get_selected_spec_ids(user_id, session_id),
    }


@router.get("/agents/{agent_id}/specs")
async def list_agent_specs(
    agent_id: str,
    session_id: str = "",
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """获取某 agent 的 Spec 索引列表（内置 3 置顶 + 自定义），供前端 Spec 面板。

    同时返回指定会话当前选中的 Spec id（供勾选状态回显）。
    """
    from data.spec_store import list_specs

    user_id = current_user.get("openid", "")
    specs = list_specs(agent_id=agent_id)
    selected: List[str] = []
    if session_id:
        try:
            selected = get_selected_spec_ids(user_id, session_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取会话已选 Spec 失败: %s", exc)
    return {"specs": specs, "selected_spec_ids": selected}


@router.get("/agents/{agent_id}/specs/{spec_id}")
async def get_agent_spec_detail(
    agent_id: str,
    spec_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """获取 Spec 全文：优先内置模板，其次该 agent 工作空间 ``spec/<id>.md``。"""
    from data.spec_store import get_spec
    from tool.spec_tool import _BUILTIN_DIR

    user_id = current_user.get("openid", "")
    meta = get_spec(spec_id, agent_id) or {}
    builtin_file = _BUILTIN_DIR / f"{spec_id}.md"
    content = ""
    if builtin_file.exists():
        content = builtin_file.read_text(encoding="utf-8")
    else:
        try:
            io = _get_workspace_io(user_id, agent_id)
            ws_id = (get_agent(user_id, agent_id) or {}).get(
                "workspace_id", ""
            ) or agent_id
            if io is not None:
                r = await asyncio.to_thread(
                    run_io, io.read_file(ws_id, f"spec/{spec_id}.md")
                )
                if not r.get("error"):
                    content = str(r.get("content") or "")
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取自定义 Spec 全文失败: %s", exc)
    return {"meta": meta, "content": content}


@router.get("/agents/{agent_id}/todos")
async def get_agent_todos(
    agent_id: str,
    session_id: str = "",
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """按 user_id + agent_id + session_id 查询该 agent 当前会话的兜底 todos。

    读取的路径与会话隔离存储一致（默认会话 .self/todos.md，其余会话
    .self/todos/todos_{session_id}.md），返回解析后的 todos 列表。
    """
    from tool.todo_tool import parse_todos, read_todos_file

    user_id = current_user.get("openid", "")
    try:
        io = _get_workspace_io(user_id, agent_id)
        ws_id = (get_agent(user_id, agent_id) or {}).get("workspace_id", "") or agent_id
        content = ""
        if io is not None:
            content = await asyncio.to_thread(
                read_todos_file, io, ws_id, session_id,
            )
        todos = parse_todos(content)
    except Exception as exc:  # noqa: BLE001
        logger.warning("查询 todos 失败(%s/%s/%s): %s", user_id, agent_id, session_id, exc)
        todos = []
    return {"agent_id": agent_id, "session_id": session_id, "todos": todos}


def _roster_from_db(db_members: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """将 team_members 表记录转换为前端 teammates 结构（与 roster 文件解析兼容）。

    team_members 表为成员名单结构化存储（权威源），转换后叠加
    role/duty/scores 额外字段（文件视图未包含），供前端工作进度窗口展示。
    member_id 同时作为 workspace_id（create_workspace 约定）。
    """
    members: List[Dict[str, Any]] = []
    for m in db_members:
        members.append({
            "id": m["id"],
            "name": m["name"],
            "model_id": m.get("model_id", ""),
            "level": m.get("level", 1),
            "created_at": m.get("created_at", ""),
            "work_status": m.get("work_status", "idle"),
            "comment": m.get("comment", ""),
            "role": m.get("role", ""),
            "duty": m.get("duty", ""),
            "scores": m.get("scores") or {},
            "workspace_id": m["id"],
        })
    return members


@router.get("/agents/{agent_id}/teammates")
async def get_agent_teammates(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """拉取某 agent 的团队成员拓扑（teammates 工作进度窗口）。

    优先读取 ``team_members`` 表（P4 建队后的权威名单，跨模式不丢：
    cloud/local/ssh 一致），表为空（未建队/旧数据）时回退解析工作空间
    ``.self/team_roster.md``。均叠加实时工作状态（来自 ``_active_tasks``）。
    """
    user_id = current_user.get("openid", "")
    agent = get_agent(user_id, agent_id)
    workspace_id = (agent.get("workspace_id") if agent else None) or agent_id

    from data.team_store import get_members as get_team_members

    try:
        db_members = get_team_members(agent_id)
    except Exception:  # noqa: BLE001
        db_members = []
    if db_members:
        members = _roster_from_db(db_members)
    else:
        # 回退：roster 文件（未走 P4 建队的历史数据，解析 13 列表格）
        _io = _get_workspace_io(user_id, agent_id)
        try:
            r = await _io.read_file(workspace_id, ".self/team_roster.md")
            content = "" if r.get("error") else (r.get("content", "") or "")
        except Exception:  # noqa: BLE001
            content = ""
        members = _parse_roster_table(content)
    for m in members:
        mid = m["id"]
        # 状态治理：live_status 唯一基于 _active_tasks（实际 tool loop 登记），
        # 不 fallback 表/roster 中的 work_status（可能是假状态/过时快照）。
        m["live_status"] = (
            "working"
            if any(k[0] == user_id and k[1] == mid for k in _active_tasks)
            else "idle"
        )
    return {"agent_id": agent_id, "members": members}


@router.get("/agents/{agent_id}/teammate/{member_id}/log")
async def get_teammate_log(
    agent_id: str,
    member_id: str,
    lines: int = 60,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """读取成员工作空间的活动日志（teammates 窗口展示工作进度）。"""
    user_id = current_user.get("openid", "")

    # WorkspaceIO 为 async 接口，直接 await（线程切换由 IO 实现内部完成）
    _io = _get_workspace_io(user_id, agent_id)
    try:
        r = await _io.read_file(member_id, ".self/activity.log")
        full_log = "" if r.get("error") else (r.get("content", "") or "")
    except Exception:  # noqa: BLE001
        full_log = ""
    if not full_log:
        return {"success": True, "log": ""}
    # 取最后 N 行（等价于原 tail -n 语义）
    log_lines = full_log.rstrip().split("\n")
    tail = "\n".join(log_lines[-int(lines):]) if lines > 0 else full_log
    return {"success": True, "log": tail}


@router.post("/agents/{agent_id}/teammate/{member_id}/message")
async def send_teammate_message(
    agent_id: str,
    member_id: str,
    body: Dict[str, Any],
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """用户直接向团队成员发送消息（teammates 窗口）。

    读取 leader 工作空间的成员管理表找到成员，经 broker 异步投递，
    成员会像收到 leader 消息一样开始处理。
    """
    user_id = current_user.get("openid", "")
    content = (body or {}).get("content", "")
    if not content:
        return {"success": False, "error": "缺少 content"}

    # 会话隔离：成员处理按 session_id 归集，缺省回退默认会话。
    # 若丢失 session_id，会串入默认会话（与其他会话交叉）。
    session_id = (body or {}).get("session_id") or DEFAULT_SESSION

    # 收敛出口：统一消息 API（用户 -> 成员，走顶部 agent 的 roster 校验与投递）
    # 本地模式下 _find_roster_member 经反向 WS 读 roster（阻塞），放入线程池
    result = await asyncio.to_thread(
        _dispatch_agent_message,
        user_id,
        [member_id],
        content,
        source_agent_id="",
        top_agent_id=agent_id,
        # 用户直发：sender_id 置空，成员总结只留在成员会话/teammates 窗口，
        # 不转发给任何 agent（更不回发给 top），避免把顶部 agent 卷进来。
        extra={"session_id": session_id, "sender_id": ""},
    )
    if result.get("status") == "error":
        return {"success": False, "error": "消息投递失败", "detail": result}
    return {"success": True}


# ===== Agent CRUD 与模型列表 =====


def _agent_to_response(record: Dict[str, Any]) -> Dict[str, Any]:
    """将数据库记录转为前端 Agent 字段结构。"""
    return {
        "id": record["id"],
        "name": record["name"],
        "model_id": record["model_id"],
        "type": "normal",
        "system_prompt": record.get("system_prompt", ""),
        "workspace_id": record.get("workspace_id", ""),
        "last_message": "已创建，等待任务分配",
        "last_message_time": None,
    }


@router.get("/agents")
async def list_agents(current_user: dict = Depends(get_current_user)) -> Dict[str, Any]:
    """获取当前用户的 agent 列表（SQLite 持久化）。"""
    user_id = current_user.get("openid", "")
    records = get_agents(user_id)
    return {"agents": [_agent_to_response(r) for r in records]}


class CreateAgentRequest(BaseModel):
    """创建 agent 请求体。"""

    name: str
    model_id: str
    system_prompt: str = ""
    team_member_count: Optional[int] = None


class UpdateAgentRequest(BaseModel):
    """修改 agent 请求体（右侧"模型信息"页）。

    model_id / system_prompt 至少提供一个；均可不传（不修改）。
    """

    model_id: Optional[str] = None
    system_prompt: Optional[str] = None


@router.post("/agents")
async def create_agent_endpoint(
    req: CreateAgentRequest,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """创建一个 agent 并持久化，同时为其创建独立的工作空间。"""
    name = req.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Agent 名称不能为空")
    if not req.model_id:
        raise HTTPException(status_code=400, detail="请选择模型")
    user_id = current_user.get("openid", "")
    # 顶层 agent 数量限制（配置 agents.max_per_user）
    max_per_user = int(get_config().get("agents", {}).get("max_per_user", 5))
    existing = get_agents(user_id)
    if len(existing) >= max_per_user:
        raise HTTPException(
            status_code=400,
            detail=f"每个用户最多创建 {max_per_user} 个 Agent，已达上限",
        )
    record = create_agent(user_id, name, req.model_id, req.system_prompt.strip())
    # 为该 agent 创建独立工作空间（Docker 不可用时不阻塞创建，仅记录降级）
    docker_manager = state.docker_manager
    workspace_id = record.get("workspace_id", "") or record["id"]
    ws_error = None
    if docker_manager is not None:
        ws_result = docker_manager.create_workspace(workspace_id, agent_name=name)
        ws_error = ws_result.get("error")
        if ws_error:
            logger.warning("创建 agent 工作空间失败: %s (%s)", workspace_id, ws_error)
    # P4：TOP 创建即全量建队（名字池 + 标准角色模板 + teams/team_members 登记 + roster 视图）。
    # 名字池耗尽属异常（同用户内全局唯一冲突/名字不足），返回明确错误提示扩充名字池。
    team_error = None
    try:
        team_result = init_team_for_top(
            user_id, record, docker_manager,
            member_count=req.team_member_count,
        )
        if team_result.get("error"):
            team_error = team_result["error"]
    except ValueError as exc:
        team_error = f"团队初始化失败: {exc}"
        logger.warning("TOP 建队失败 %s: %s", workspace_id, team_error)
    return {
        "agent": _agent_to_response(record),
        "workspace_error": ws_error,
        "team_error": team_error,
    }


@router.patch("/agents/{agent_id}")
async def update_agent_endpoint(
    agent_id: str,
    req: UpdateAgentRequest,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """修改 agent 的模型 / 系统提示词（右侧"模型信息"页提交 PATCH）。

    修改后清空该 agent 的会话缓存与上下文：下次发消息按新模型重建会话，
    避免旧模型上下文（工具注册/模型参数）残留；历史消息保留。
    """
    user_id = current_user.get("openid", "")
    if req.model_id is None and req.system_prompt is None:
        raise HTTPException(status_code=400, detail="至少提供 model_id 或 system_prompt 之一")
    if req.model_id is not None and req.model_id not in state.model_configs:
        raise HTTPException(status_code=400, detail=f"模型不存在: {req.model_id}")
    record = update_agent(
        user_id,
        agent_id,
        model_id=req.model_id,
        system_prompt=(
            req.system_prompt.strip()
            if req.system_prompt is not None else None
        ),
    )
    if record is None:
        raise HTTPException(status_code=404, detail="Agent 不存在")
    # 清会话缓存（含上下文），下次发消息按新配置重建
    clear_user_agent(user_id, agent_id)
    return {"success": True, "agent": _agent_to_response(record)}


def _mask_base_url(url: str) -> str:
    """脱敏 base_url：仅保留协议与主机名（去除路径与敏感信息）。"""
    from urllib.parse import urlparse

    try:
        p = urlparse(url)
        host = p.hostname or ""
        port = f":{p.port}" if p.port else ""
        return f"{p.scheme}://{host}{port}"
    except Exception:  # noqa: BLE001
        return url


@router.get("/agents/{agent_id}/models-info")
async def get_agent_models_info(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """获取 agent 的模型信息与可用模型池（右侧"模型信息"页展示）。

    返回：
    - ``agent``：当前 agent 的 id / model_id / system_prompt
    - ``models``：可用模型池（max_seqlen / thinking / if_vision / base_url 脱敏）
    """
    user_id = current_user.get("openid", "")
    agent = get_agent(user_id, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="Agent 不存在")
    models = []
    for cfg in get_model_configs().values():
        models.append({
            "model_id": cfg.model_id,
            "name": cfg.name,
            "max_seqlen": cfg.extra.get("max_seqlen"),
            "thinking": cfg.thinking,
            "if_vision": cfg.if_vision,
            "base_url": _mask_base_url(cfg.base_url),
        })
    return {
        "agent": {
            "id": agent["id"],
            "model_id": agent["model_id"],
            "system_prompt": agent.get("system_prompt", ""),
        },
        "models": models,
    }


@router.delete("/agents/{agent_id}")
async def delete_agent_endpoint(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """删除指定 agent 及其对话历史，并清理其独立工作空间。"""
    user_id = current_user.get("openid", "")
    existed = delete_agent(user_id, agent_id)
    if not existed:
        raise HTTPException(status_code=404, detail="Agent 不存在")
    # 清理该 agent 的工作空间（Docker 不可用或容器不存在时静默忽略）。
    # DB 删除已成功，workspace 清理失败不应使接口返回错误，否则前端
    # 无法即时刷新列表（卡片残留，刷新后才消失）。
    if state.docker_manager is not None:
        try:
            state.docker_manager.remove_workspace(agent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("删除 agent 工作空间失败(已忽略): %s (%s)", agent_id, exc)
    # 清理该 agent 的 normal LLM 会话缓存，避免内存泄漏
    clear_user_agent(user_id, agent_id)
    # 清理该 agent 持久化的会话上下文（数据库）
    clear_context(user_id, agent_id)
    # P4：同步清理该 TOP 的团队（teams/team_members 表），避免孤儿成员
    try:
        delete_team(agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("删除 TOP 团队记录失败(已忽略): %s (%s)", agent_id, exc)
    return {"success": True}


@router.get("/models")
async def list_models(
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """获取模型池中的具体模型列表（由 YAML 配置文件定义）。

    与 ``/agents/{id}/models-info`` 复用同一数据源（ModelConfig），
    避免两处模型信息不一致（spec「models-info 收敛复用」）。
    """
    configs = get_model_configs()
    models = []
    for cfg in configs.values():
        models.append(
            {
                "model_id": cfg.model_id,
                "name": cfg.name,
                "max_seqlen": cfg.extra.get("max_seqlen"),
                "thinking": cfg.thinking,
                "if_vision": cfg.if_vision,
                "base_url": _mask_base_url(cfg.base_url),
            }
        )
    return {"models": models}


# ===== MCP 服务管理（右侧" MCP 配置"页） =====


class RegisterMcpServiceRequest(BaseModel):
    """注册外部 MCP 服务请求体（stdio 外接）。"""

    name: str
    command: str
    args: List[str] = []


@router.get("/mcp/services")
async def list_mcp_services(
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """列出已注册的外部 MCP 服务（含内置服务标记）。

    外部服务来自 SQLite ``mcp_services`` 表（REST 注册，权威持久化）；
    内置服务（workspace / document / embed_search）在会话构建时由
    ``register_builtin_tools`` 注册，此处仅列出外部配置。
    """
    from data.mcp_service_store import list_services

    try:
        services = list_services()
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取 MCP 服务配置失败: %s", exc)
        services = []
    # 内置服务标记（不可删除），供前端区分展示
    builtin = {
        "workspace": "工作空间基础工具（read/write/edit/terminal/embed_search）",
        "document": "文档处理服务（PDF/PPTX/DOCX/XLSX）",
        "embed_search": "embed 向量搜索服务",
    }
    for svc in services:
        svc["builtin"] = False
    for name, desc in builtin.items():
        services.append({
            "name": name,
            "command": "",
            "args": [],
            "enabled": True,
            "builtin": True,
            "description": desc,
        })
    return {"services": services}


@router.post("/mcp/services")
async def register_mcp_service(
    req: RegisterMcpServiceRequest,
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """注册一个外部 MCP 服务（stdio 外接），持久化到 SQLite。

    安全校验（spec「MCP services CRUD 安全红线」）：命令白名单/绝对路径、
    禁 shell 元字符、禁危险参数，防止注册任意命令导致 RCE。
    """
    from data.mcp_service_store import register_service

    try:
        record = register_service(req.name, req.command, req.args)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"success": True, "service": record}


@router.delete("/mcp/services/{name}")
async def delete_mcp_service(
    name: str,
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """删除一个外部 MCP 服务配置。内置服务不可删除。

    仅删除配置（下次会话构建不再注册）；正在运行的会话不受影响
    （MCPManager 按会话构建，进程生命周期随会话）。
    """
    from data.mcp_service_store import delete_service

    ok = delete_service(name)
    if not ok:
        raise HTTPException(status_code=404, detail="服务不存在或为内置服务，无法删除")
    return {"success": True}


class AnswerQuestionRequest(BaseModel):
    """回答 AskUserQuestion 问题的请求体。"""

    answer: str


@router.get("/questions")
async def list_question_api(
    session_id: Optional[str] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """列出当前用户的提问（可选按会话过滤），供右侧「问题回复」页使用。

    ``session_id`` 缺省不过滤，返回该用户全部提问（含各 agent 与成员提问）。
    """
    user_id = current_user.get("openid", "")
    questions = list_questions(user_id, session_id)
    return {"questions": questions}


@router.post("/questions/{qid}/answer")
async def answer_question_api(
    qid: str,
    req: AnswerQuestionRequest,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """回答某条待答提问（REST 入口，与 WS user_answer 逻辑等价）。

    校验归属后标记 answered、推送 ask_user_question_resolved 供中栏同步，
    并异步唤醒对应 agent 续跑。
    """
    user_id = current_user.get("openid", "")
    pending = get_pending_question(qid)
    if pending is None or pending["status"] != "pending":
        raise HTTPException(status_code=400, detail="没有等待回答的问题")
    if pending.get("user_id") != user_id:
        raise HTTPException(status_code=403, detail="无权操作该提问")
    answer = str(req.answer or "")
    mark_pending_answered(qid, answer)
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "ask_user_question_resolved",
            "data": {"id": qid, "session_id": pending["session_id"]},
        },
    )
    # 唤醒：注入答案并重新触发该 agent 执行（异步，不阻塞请求）
    asyncio.create_task(
        resume_after_answer(
            pending["user_id"],
            pending["agent_id"],
            pending["top_agent_id"],
            pending["session_id"],
            answer,
            pending["is_member"],
            pending.get("sender_id", ""),
        )
    )
    return {"success": True, "qid": qid, "status": "answered"}
