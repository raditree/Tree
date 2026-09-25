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
    USER_AGENT_ID,
    _active_tasks,
    _clear_compacting_task,
    _dispatch_agent_message,
    _get_workspace_io,
    _is_agent_compacting,
    _is_agent_working,
    _parse_roster_table,
    _register_compacting_task,
    resume_after_answer,
)
from config.config import get_config
from config.models import (
    REASONING_EFFORT_ACCEPTED,
    REASONING_EFFORT_CANONICAL,
    declared_reasoning_effort_options,
    get_model_configs,
    normalize_reasoning_effort,
    normalize_reasoning_effort_options,
    resolve_reasoning_effort_options,
)
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
from ws.auth import _user_id_of, get_current_user

logger = logging.getLogger(__name__)


def _plugin_cascade(*args: Any, **kwargs: Any) -> None:
    """插件化埋点体系（一期）：实例级联清理接线（契约 §5.1 / §10.2）。

    默认关闭时零副作用；任何异常均吞掉，绝不影响路由主流程。
    """
    try:
        from plugin import plugin_cascade

        plugin_cascade(*args, **kwargs)
    except Exception:  # noqa: BLE001
        pass


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
            # 插件体系：级联清理该会话的 session 级实例（§5.1 接线点 2）
            _plugin_cascade(user_id, agent_id=agent["id"], session_id=session_id)
    else:
        clear_context(user_id, target, session_id=session_id)
        clear_user_agent(user_id, target, session_id=session_id)
        # 插件体系：级联清理该会话的 session 级实例（§5.1 接线点 2）
        _plugin_cascade(user_id, agent_id=target, session_id=session_id)
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

    状态行为：压缩期间登记 ``_compacting_tasks`` 并向 WS 推送
    ``agent_status=compacting``（前端显示「压缩中」），结束（含异常）后按
    实际工作状态推送 working/idle。互斥按同会话粒度：该会话正在 chat 或
    正在压缩时拒绝（reason=agent_working / already_compacting），
    其他会话的 working/compacting 不拦截（各自独立 AgentLLMSession）。
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
        # 插件埋点 scope：user/agent/session 装配；team_id 留空——
        # 本路径为 compact"从 DB 恢复的临时会话"，无团队上下文、亦无
        # "成员→团队"的轻量反查接口；该会话仅用于压缩（不执行工具循环、
        # 不发埋点事件），留空不影响一期埋点链路（详见 .output 交付说明）。
        session = AgentLLMSession(
            model_config=model_config,
            workspace_id=(agent or {}).get("workspace_id", "") or agent_id,
            system_prompt="",
            user_id=user_id,
            agent_id=agent_id,
            session_id=session_id,
        )
        session.context = restored
        restored_from_db = True

    # 压缩互斥（同会话粒度）：
    # - 该会话正在 chat（_active_tasks 已登记）→ 拒绝压缩：compress 会改写
    #   session.context，与 chat 线程并发读写上下文存在数据竞争；
    # - 该会话正在压缩（_compacting_tasks 已登记，如双击）→ 拒绝重复压缩。
    # 其他会话的 working/compacting 不拦截（各自独立 AgentLLMSession）。
    if (user_id, agent_id, session_id) in _active_tasks:
        return {
            "success": True,
            "compressed": False,
            "reason": "agent_working",
            "message": "该会话正在处理消息，请稍后再压缩",
        }
    if _is_agent_compacting(user_id, agent_id, session_id):
        return {
            "success": True,
            "compressed": False,
            "reason": "already_compacting",
            "message": "该会话正在压缩中",
        }

    # 进入 compacting 状态：登记 + 推送 WS 事件（前端据此显示「压缩中」）。
    # compress 是长时间操作（LLM 总结，本地模型可能数分钟），期间 UI 不能静默。
    _register_compacting_task(user_id, agent_id, session_id)
    await _send_agent_status(
        user_id, agent_id, session_id, "compacting"
    )
    try:
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
                "too_few_messages"
                if len(non_system) <= 1
                else "nothing_to_summarize"
            )
        return result
    finally:
        # 复位状态：注销登记 + 推送结束状态。若该 agent 其他会话仍在工作
        # （或压缩期间新消息被受理），按实际状态推送 working，避免误清。
        _clear_compacting_task(user_id, agent_id, session_id)
        end_status = (
            "working" if _is_agent_working(user_id, agent_id) else "idle"
        )
        await _send_agent_status(user_id, agent_id, session_id, end_status)


async def _send_agent_status(
    user_id: str, agent_id: str, session_id: str, status: str
) -> None:
    """推送 agent_status WS 事件（ws_manager 缺失/未连接时静默跳过）。

    compact 端点内使用：状态推送失败不应导致压缩请求失败，故全部吞掉。
    """
    try:
        wsm = getattr(state, "ws_manager", None)
        if wsm is None:
            return
        await wsm.send_message(
            user_id,
            {
                "type": "agent_status",
                "data": {
                    "agent_id": agent_id,
                    "status": status,
                    "session_id": session_id,
                },
            },
        )
    except Exception:  # noqa: BLE001
        pass


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
    # 插件体系：级联清理该会话的 session 级实例（§5.1 接线点 1）
    _plugin_cascade(user_id, agent_id=agent_id, session_id=session_id)
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


def _collect_team_tree(agent_id: str, get_team_members) -> List[Dict[str, Any]]:
    """BFS 收集某 agent（顶部或成员 leader）的直属 + 子孙成员名单。

    成员的子团队有两种归属：历史实现直接把所有层级挂在顶部 team_id 下；
    成员自建子团队时把行挂在成员自身的 agent_id 名下。统一按
    ``team_members.team_id`` 自顶向下 BFS 去重收集，保证 teammates 窗口
    能看到 Level 2+ 成员，两种存储都不会漏。
    """
    seen = {agent_id}
    collected: List[Dict[str, Any]] = []
    queue = [agent_id]
    while queue:
        cur = queue.pop(0)
        try:
            rows = get_team_members(cur)
        except Exception:  # noqa: BLE001
            continue
        for m in rows:
            mid = m.get("id", "")
            if not mid or mid in seen:
                continue
            seen.add(mid)
            collected.append(m)
            # 成员若也是子团队 leader，其直属成员行挂在它自己的 id 名下
            queue.append(mid)
    return collected


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
            # 审核状态：前端据此渲染"等待赋模型/待审核"提示与红点
            "review_status": m.get("review_status", "") or "",
            # 成员级模型参数覆盖（供「模型配置」页回填；_row_to_member 已带出）。
            # 键名统一用线名 max_seqlen（而非库列名 max_seqlen_override），
            # 与 PATCH 请求体、右栏「模型信息」保持一致，前端无需换算。
            "reasoning_effort": m.get("reasoning_effort"),
            "max_seqlen": m.get("max_seqlen_override"),
            # 同时保留库列名：teammates 接口的 overrides 块与审核闸按库列名取值，
            # 两个名字指向同一字段可避免"接口这套名、内部那套名"的对齐错误
            "max_seqlen_override": m.get("max_seqlen_override"),
            "max_output_tokens": m.get("max_output_tokens"),
            "compress_threshold": m.get("compress_threshold"),
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

    from data.team_store import REVIEW_STATUS_NEEDS_USER
    from data.team_store import get_members as get_team_members
    # 成员生效参数（含 TOP 回退）的计算在 chat 里，与运行时同一份实现
    from agent.chat import _member_effective_overrides

    db_rows = _collect_team_tree(agent_id, get_team_members)
    if db_rows:
        # 权威名单含子孙团队（Level 2+），按层级、创建时间排序后返回
        members = _roster_from_db(db_rows)
        members.sort(key=lambda m: (m.get("level", 1), m.get("created_at", "")))
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
        if not m.get("review_status"):
            # roster 文件回退路径没有该列（历史数据）：按有无模型兜底
            m["review_status"] = (
                "approved" if str(m.get("model_id") or "").strip()
                else "pending_model"
            )
        # 成员级模型参数覆盖（null = 未设置）+ 实际生效值（含 TOP 回退），
        # 供「模型配置」页回填与提示"当前值来自 TOP"
        m["overrides"] = {
            "reasoning_effort": m.get("reasoning_effort"),
            "max_seqlen": m.get("max_seqlen_override"),
            "max_output_tokens": m.get("max_output_tokens"),
            "compress_threshold": m.get("compress_threshold"),
        }
        try:
            m["effective"] = _member_effective_overrides(user_id, mid, agent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("计算成员生效参数失败(忽略) %s: %s", mid, exc)
            m["effective"] = {}
    pending = sum(
        1 for m in members if m["review_status"] in REVIEW_STATUS_NEEDS_USER
    )
    return {
        "agent_id": agent_id,
        "members": members,
        # 等待用户处理的成员数（未赋模型 / 待审核）：前端红点徽章计数
        "pending_member_count": pending,
    }


@router.patch("/agents/{agent_id}/teammate/{member_id}")
async def update_teammate_endpoint(
    agent_id: str,
    member_id: str,
    body: Dict[str, Any],
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """为用户分配成员的模型 / 审核成员（「团队成员 → 模型配置」页提交）。

    这是**用户侧**入口，与 team 工具的 ``review_member`` 分开：
    TOP agent（LLM）无权设置成员模型，成员在用户审核通过前不接收任何消息。

    请求体（至少一项）：
    - ``model_id``：要分配的模型；显式传空串 = 清空模型（退回 ``pending_model``）
    - ``review_status``：``approved`` / ``rejected`` / ``pending_review``
    - ``reasoning_effort`` / ``max_seqlen`` / ``max_output_tokens`` /
      ``compress_threshold``：成员级模型参数覆盖；传 ``null`` = 清除该项
      （回退 TOP 的同名设置；TOP 也没有则用模型 .yaml 默认值）
      —— 不传该键 = 不修改
    """
    from data.agent_store import get_agent as _get_agent
    from data.team_store import (
        REVIEW_STATUSES,
        get_member,
        update_member,
        update_member_review_status,
    )

    user_id = current_user.get("openid", "")
    payload = body or {}
    has_model = "model_id" in payload
    has_status = "review_status" in payload
    override_keys = (
        "reasoning_effort", "max_seqlen", "max_output_tokens",
        "compress_threshold",
    )
    present_overrides = [k for k in override_keys if k in payload]
    if not has_model and not has_status and not present_overrides:
        raise HTTPException(
            status_code=400,
            detail=(
                "至少提供 model_id / review_status / 模型参数覆盖之一"
                f"（可覆盖项：{', '.join(override_keys)}）"
            ),
        )
    # 成员归属校验：必须确实在该 TOP 旗下，避免跨团队改成员
    member = get_member(agent_id, member_id)
    if member is None:
        raise HTTPException(status_code=404, detail=f"成员不存在: {member_id}")

    model_id = payload.get("model_id") if has_model else None
    if has_model and str(model_id or "").strip():
        model_id = str(model_id).strip()
        if model_id not in state.model_configs:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"模型不存在: {model_id}"
                    "（可先用 GET /api/models 获取可用模型池）"
                ),
            )
    elif has_model:
        model_id = ""  # 显式清空

    review_status = payload.get("review_status") if has_status else None
    if has_status and review_status is not None:
        review_status = str(review_status).strip().lower()
        if review_status not in REVIEW_STATUSES:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"审核状态非法: {review_status!r}"
                    f"（可选: {', '.join(REVIEW_STATUSES)}）"
                ),
            )

    try:
        row = update_member_review_status(
            agent_id, member_id, value=review_status, model_id=model_id
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if row is None:
        raise HTTPException(status_code=404, detail=f"成员不存在: {member_id}")

    # 成员级模型参数覆盖：不传的键不动，显式 null 清空（回退 TOP）
    if present_overrides:
        patch: Dict[str, Any] = {}
        if "reasoning_effort" in payload:
            raw_effort = payload.get("reasoning_effort")
            if raw_effort is None or not str(raw_effort).strip():
                patch["reasoning_effort"] = None
            else:
                # 与 TOP 侧同一口径：按该成员生效模型的档位校验并归一化
                patch["reasoning_effort"] = _validate_agent_reasoning_effort(
                    str(raw_effort),
                    model_id=row.get("model_id") or None,
                    user_id=user_id,
                    agent_id=agent_id,
                )
        for key, column in (
            ("max_seqlen", "max_seqlen_override"),
            ("max_output_tokens", "max_output_tokens"),
        ):
            if key not in payload:
                continue
            value = payload.get(key)
            if value is None or value == "":
                patch[column] = None
                continue
            try:
                number = int(value)
            except (TypeError, ValueError):
                raise HTTPException(
                    status_code=400, detail=f"{key} 必须为正整数"
                ) from None
            if number <= 0:
                raise HTTPException(status_code=400, detail=f"{key} 必须为正整数")
            patch[column] = number
        if "compress_threshold" in payload:
            raw_threshold = payload.get("compress_threshold")
            if raw_threshold is None or raw_threshold == "":
                patch["compress_threshold"] = None
            else:
                try:
                    threshold = float(raw_threshold)
                except (TypeError, ValueError):
                    raise HTTPException(
                        status_code=400,
                        detail="compress_threshold 必须是 0.1~0.95 之间的数值",
                    ) from None
                if not 0.1 <= threshold <= 0.95:
                    raise HTTPException(
                        status_code=400,
                        detail="compress_threshold 必须在 0.1~0.95 之间",
                    )
                patch["compress_threshold"] = threshold
        updated_row = update_member(agent_id, member_id, **patch)
        if updated_row is None:
            raise HTTPException(status_code=404, detail=f"成员不存在: {member_id}")
        row = updated_row

    # 审核通过后补投初始化消息：赋模型与审核期间成员收不到任何消息，
    # 这里补一次，让成员知道自己的角色与职责（此前在 create_member 时被跳过）。
    initialized = False
    if row.get("review_status") == "approved":
        initialized = await _dispatch_member_init_after_approval(
            user_id, agent_id, row
        )

    return {
        "success": True,
        "member": _member_override_view(user_id, agent_id, row),
        "initialized": initialized,
        "top_agent_name": (_get_agent(user_id, agent_id) or {}).get("name", ""),
    }


def _member_override_view(
    user_id: str, team_id: str, row: Dict[str, Any]
) -> Dict[str, Any]:
    """成员配置回显：基础字段 + 成员自身覆盖 + 实际生效值（含 TOP 回退）。

    前端据此既能把控件回填为"该成员设过的值"，也能提示"当前生效值来自 TOP"。
    """
    from agent.chat import _member_effective_overrides

    own = {
        "reasoning_effort": row.get("reasoning_effort"),
        "max_seqlen": row.get("max_seqlen_override"),
        "max_output_tokens": row.get("max_output_tokens"),
        "compress_threshold": row.get("compress_threshold"),
    }
    view = {
        "id": row.get("id", ""),
        "name": row.get("name", ""),
        "model_id": row.get("model_id", ""),
        "review_status": row.get("review_status", ""),
        # 该成员**自己设过**的覆盖（null = 未设置，沿用 TOP/模型默认）
        "overrides": own,
    }
    try:
        effective = _member_effective_overrides(user_id, row.get("id", ""), team_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("计算成员生效参数失败(仅回自身覆盖): %s", exc)
        effective = {}
    view["effective"] = effective
    return view


async def _dispatch_member_init_after_approval(
    user_id: str, agent_id: str, member: Dict[str, Any]
) -> bool:
    """成员审核通过后经 broker 补投一次初始化消息（失败返回 False）。

    成员在"未赋模型 / 未审核"期间被审核闸挡住，因此 create_member 当时跳过了
    初始化消息；审核通过后在这里补投，让成员知道自己的角色与职责。
    """
    broker = getattr(state, "team_broker", None)
    if broker is None:
        return False
    role = member.get("role") or "（未设）"
    duty = member.get("duty") or "（未设）"
    content = (
        "【团队初始化】你已通过用户审核，可以开始工作了。\n"
        f"你的角色：{role}\n你的职责：{duty}\n"
        "等待 leader 用 message send_message 派发工作；"
        "工作过程与产出请持续写入 .self/activity.log。"
    )
    try:
        return bool(
            broker.dispatch(
                (user_id, member.get("id", "")),
                {
                    "user_id": user_id,
                    "agent_id": member.get("id", ""),
                    "workspace_id": member.get("workspace_id") or member.get("id", ""),
                    "model_id": member.get("model_id", ""),
                    "system_prompt": member.get("system_prompt", ""),
                    "leader_id": member.get("parent_agent_id") or agent_id,
                    "team_id": agent_id,
                    "content": content,
                    "event": "member_approved",
                },
            )
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("成员审核通过后补投初始化消息失败 %s: %s", member.get("id"), exc)
        return False


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
    # active（Task 7.1）：是否为用户主动发起，默认 true；被动推送场景
    # 可显式传 false，接收侧不触发总结反向推送。
    active = bool((body or {}).get("active", True))

    # 收敛出口：统一消息 API（用户 -> 成员，走顶部 agent 的 roster 校验与投递）
    # 本地模式下 _find_roster_member 经反向 WS 读 roster（阻塞），放入线程池
    result = await asyncio.to_thread(
        _dispatch_agent_message,
        user_id,
        [member_id],
        content,
        # 用户直发：source_agent_id 统一标记为 USER_AGENT_ID（历史为空串）
        source_agent_id=USER_AGENT_ID,
        team_id=agent_id,
        # 用户直发：sender_id 统一标记为 USER_AGENT_ID，成员总结只留在成员
        # 会话/teammates 窗口，不转发给任何 agent（更不回发给 top），避免把
        # 顶部 agent 卷进来。
        extra={"session_id": session_id, "sender_id": USER_AGENT_ID},
        active=active,
    )
    if result.get("status") == "error":
        return {"success": False, "error": "消息投递失败", "detail": result}
    return {"success": True}


# ===== Agent CRUD 与模型列表 =====


def _agent_to_response(record: Dict[str, Any]) -> Dict[str, Any]:
    """将数据库记录转为前端 Agent 字段结构。

    叠加 ``pending_member_count``：该 TOP 旗下"等待用户处理"（未赋模型 /
    待审核）的成员数，前端据此在 Agent 列表与 teammates 入口显示红点徽章
    （要求 3：成员未就绪时需要用户去赋模型 + 审核）。
    """
    agent_id = record.get("id", "")
    pending = 0
    if agent_id:
        try:
            from data.team_store import (
                REVIEW_STATUS_NEEDS_USER,
                get_members as _get_members,
            )

            # 与 teammates 接口同一口径：按 parent/子团队逐层收集
            rows = _collect_team_tree(agent_id, _get_members)
            pending = sum(
                1 for m in rows
                if (m.get("review_status") or "") in REVIEW_STATUS_NEEDS_USER
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("统计待处理成员数失败(按 0 处理) %s: %s", agent_id, exc)
            pending = 0
    return {
        "id": agent_id,
        "name": record["name"],
        "model_id": record["model_id"],
        "type": "normal",
        "system_prompt": record.get("system_prompt", ""),
        "workspace_id": record.get("workspace_id", ""),
        "last_message": "已创建，等待任务分配",
        "last_message_time": None,
        "pending_member_count": pending,
    }


@router.get("/agents")
async def list_agents(current_user: dict = Depends(get_current_user)) -> Dict[str, Any]:
    """获取当前用户的 agent 列表（SQLite 持久化）。"""
    user_id = current_user.get("openid", "")
    records = get_agents(user_id)
    return {"agents": [_agent_to_response(r) for r in records]}


class CreateAgentRequest(BaseModel):
    """创建 agent 请求体。

    团队配置（max_level / max_members_per_level）在创建 TOP 时设定并持久化
    到 teams 表，创建后不可修改（成员只增不减）。
    """

    name: str
    model_id: str
    system_prompt: str = ""
    team_member_count: Optional[int] = None
    max_level: Optional[int] = None
    max_members_per_level: Optional[int] = None


class UpdateAgentRequest(BaseModel):
    """修改 agent 请求体（右侧"模型信息"页）。

    model_id / system_prompt / 四个模型参数覆盖至少提供一个；均可不传（不修改）。

    模型参数覆盖语义（见 ``data.agent_store.update_agent``）：
    - 某字段为 None = **不修改**（保留库中原值）；
    - ``clear_model_overrides=True`` = 一次性清除全部模型参数覆盖（回退模型默认）。
    这样避免"传 None 是清空还是不改"的歧义。
    """

    model_id: Optional[str] = None
    system_prompt: Optional[str] = None
    reasoning_effort: Optional[str] = None
    max_seqlen: Optional[int] = None
    max_output_tokens: Optional[int] = None
    compress_threshold: Optional[float] = None
    clear_model_overrides: bool = False


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
    # 顶层 agent 数量限制（配置 agents.max_per_user）。
    # max_per_user 为 -1、0 或缺失时表示不限制（跳过该检查）；
    # 实际运营上限由按用户等级控制的并发 agent 数决定
    # （见 registration.levels.*.max_concurrent_agents，动态披露后续实现）。
    raw_max = (get_config().get("agents") or {}).get("max_per_user")
    max_per_user = int(raw_max) if raw_max is not None else 0
    existing = get_agents(user_id)
    if max_per_user > 0 and len(existing) >= max_per_user:
        raise HTTPException(
            status_code=400,
            detail=f"每个用户最多创建 {max_per_user} 个 Agent，已达上限",
        )
    # 团队配置硬上限校验（防超量建队）：层级 / 每层成员上限超出硬上限直接拒绝
    # （在 create_agent 落库之前校验，避免留下孤儿 agent 记录）
    from config.team import HARD_MAX_LEVEL, HARD_MAX_MEMBERS, clamp_level, clamp_members

    max_level = clamp_level(req.max_level)
    max_members = clamp_members(req.max_members_per_level)
    if req.max_level is not None and max_level > HARD_MAX_LEVEL:
        raise HTTPException(
            status_code=400,
            detail=f"团队最大层级超出硬上限（{HARD_MAX_LEVEL}）",
        )
    if req.max_members_per_level is not None and max_members > HARD_MAX_MEMBERS:
        raise HTTPException(
            status_code=400,
            detail=f"每层成员上限超出硬上限（{HARD_MAX_MEMBERS}）",
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
    # 团队配置（max_level / max_members_per_level）在此一次性设定，此后不可修改。
    # 名字池耗尽属异常（同用户内全局唯一冲突/名字不足），返回明确错误提示扩充名字池。
    team_error = None
    team_result = None
    try:
        team_result = init_team_for_top(
            user_id, record, docker_manager,
            member_count=req.team_member_count,
            max_level=max_level,
            max_members_per_level=max_members,
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
        "team": {
            "max_level": max_level,
            "max_members_per_level": max_members,
            "member_count": int((team_result or {}).get("created_count") or 0),
        } if team_result and not team_result.get("error") else {
            "max_level": max_level,
            "max_members_per_level": max_members,
            "member_count": 0,
        },
    }


def _validate_agent_reasoning_effort(
    value: str,
    model_id: Optional[str],
    user_id: str,
    agent_id: str,
) -> str:
    """归一化并校验 per-agent 的思考强度覆盖。

    校验基准是**该 agent 生效模型**声明的可用档位
    （``config.models.resolve_reasoning_effort_options``：模型显式声明的
    ``reasoning_effort_options`` 优先，未声明则回退全局有实际区分度的档位）。

    这里拦下非法值，是为了把网关侧的
    ``422 unknown variant `xhigh```
    转换成路由侧一条可读的 400 —— 否则该错误会原样透传到前端，且每次发言都复现。

    :return: 归一化后的档位（别名已折叠，如 minimal→low）
    :raises HTTPException: 枚举外取值，或不属于该模型声明的档位
    """
    normalized = normalize_reasoning_effort(value)
    if normalized is None:
        raise HTTPException(
            status_code=400,
            detail=(
                f"思考强度取值非法: {value!r}"
                f"（可选: {', '.join(REASONING_EFFORT_ACCEPTED)}）"
            ),
        )
    # 未显式传 model_id 时按 agent 当前绑定的模型校验
    effective_model_id = model_id
    if effective_model_id is None:
        record = get_agent(user_id, agent_id) or {}
        effective_model_id = record.get("model_id") or ""
    cfg = state.model_configs.get(effective_model_id or "")
    if cfg is None:
        # 模型不存在（历史脏数据 / 已删除自定义模型）：不阻塞保存
        return normalized
    options = resolve_reasoning_effort_options(cfg.extra)
    if normalized not in options:
        raise HTTPException(
            status_code=400,
            detail=(
                f"模型 {effective_model_id} 的思考强度可选: "
                f"{', '.join(options)}；收到 {value!r}（归一化后 {normalized}）"
            ),
        )
    return normalized


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
    if (
        req.model_id is None
        and req.system_prompt is None
        and req.reasoning_effort is None
        and req.max_seqlen is None
        and req.max_output_tokens is None
        and req.compress_threshold is None
        and not req.clear_model_overrides
    ):
        raise HTTPException(
            status_code=400,
            detail="至少提供 model_id / system_prompt / 模型参数覆盖之一",
        )
    if req.model_id is not None and req.model_id not in state.model_configs:
        raise HTTPException(status_code=400, detail=f"模型不存在: {req.model_id}")
    # 数值范围校验（压缩阈值必须落在 (0,1)，否则会导致永不压缩或每轮压缩）
    if req.max_seqlen is not None and req.max_seqlen <= 0:
        raise HTTPException(status_code=400, detail="max_seqlen 必须为正整数")
    if req.max_output_tokens is not None and req.max_output_tokens <= 0:
        raise HTTPException(status_code=400, detail="max_output_tokens 必须为正整数")
    if req.compress_threshold is not None and not (
        0.1 <= float(req.compress_threshold) <= 0.95
    ):
        raise HTTPException(
            status_code=400, detail="compress_threshold 必须在 0.1~0.95 之间"
        )
    # 思考强度：归一化（strip/lower/别名折叠）后校验属于**该 agent 绑定的模型**
    # 声明的可用档位。校验放在这里而不是等到网关，是为了把 422
    # 「unknown variant」变成一条可读的 400；同时把别名折叠为规范档位再入库，
    # 避免库中出现 minimal/medium 这类与 low/high 等价的重复表示。
    effort: Optional[str] = None
    if req.reasoning_effort is not None:
        raw_effort = req.reasoning_effort
        if isinstance(raw_effort, str) and raw_effort.strip():
            effort = _validate_agent_reasoning_effort(
                raw_effort,
                model_id=req.model_id,
                user_id=user_id,
                agent_id=agent_id,
            )
    record = update_agent(
        user_id,
        agent_id,
        model_id=req.model_id,
        system_prompt=(
            req.system_prompt.strip()
            if req.system_prompt is not None else None
        ),
        reasoning_effort=effort,
        max_seqlen_override=req.max_seqlen,
        max_output_tokens=req.max_output_tokens,
        compress_threshold=req.compress_threshold,
        clear_model_overrides=req.clear_model_overrides,
    )
    if record is None:
        raise HTTPException(status_code=404, detail="Agent 不存在")
    # 清会话缓存（含上下文），下次发消息按新配置重建
    clear_user_agent(user_id, agent_id)
    # 插件体系：级联清理该 agent 的实例（对齐 clear_user_agent 行为；§5.1 接线点 4）
    _plugin_cascade(user_id, agent_id=agent_id)
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
            # 模型级默认值（右栏三个旋钮的"模型默认"参照）
            "reasoning_effort": cfg.extra.get("reasoning_effort"),
            "max_output_tokens": cfg.extra.get("max_output_tokens"),
            "compress_threshold": cfg.extra.get("compress_threshold"),
            # 该模型可选的思考强度档位（前端下拉据此渲染；未声明时回退全局档位）
            "reasoning_effort_options": resolve_reasoning_effort_options(cfg.extra),
        })
    return {
        "agent": {
            "id": agent["id"],
            "model_id": agent["model_id"],
            "system_prompt": agent.get("system_prompt", ""),
        },
        # 该 agent 的模型参数覆盖（NULL 表示未覆盖，前端控件留空）
        "overrides": {
            "reasoning_effort": agent.get("reasoning_effort"),
            "max_seqlen": agent.get("max_seqlen_override"),
            "max_output_tokens": agent.get("max_output_tokens"),
            "compress_threshold": agent.get("compress_threshold"),
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
    # 插件体系：级联清理该 agent 的 agent/会话级实例；
    # 若该 agent 为 TOP（团队解散），同时清理团队级实例（§5.1 接线点 3）
    _plugin_cascade(user_id, agent_id=agent_id)
    _plugin_cascade(user_id, team_id=agent_id)
    # 清理该 agent 持久化的会话上下文（数据库）
    clear_context(user_id, agent_id)
    # 清理 broker 队列/worker 与限流器注册（TOP 自身 + 其下全部成员），
    # 防止 300+ agent 长跑下 _queues/_workers/_limiters 无限增长
    try:
        from data.team_store import get_members
        from agent.team_broker import TeamMessageBroker
        from llm.rate_limit import remove_agent

        broker: TeamMessageBroker = state.team_broker
        for m in (get_members(agent_id) or []):
            mid = m.get("id", "")
            if not mid:
                continue
            if broker is not None:
                broker.remove_agent(user_id, mid)
            remove_agent(user_id, mid)
        if broker is not None:
            broker.remove_agent(user_id, agent_id)
        remove_agent(user_id, agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("清理删除 agent 的 broker/限流注册失败(已忽略): %s (%s)",
                       agent_id, exc)
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
                "reasoning_effort": cfg.extra.get("reasoning_effort"),
                "max_output_tokens": cfg.extra.get("max_output_tokens"),
                "compress_threshold": cfg.extra.get("compress_threshold"),
                # 模型可选思考强度档位（与 models-info 同一口径）
                "reasoning_effort_options": resolve_reasoning_effort_options(
                    cfg.extra
                ),
            }
        )
    return {"models": models}


# ===== 自定义模型管理（设置页「自定义模型」） =====


def _model_to_response(cfg: Any) -> Dict[str, Any]:
    """把 ModelConfig 转为前端可用的**白名单**字典。

    绝不返回 ``api_key``：``ModelConfig.to_dict()`` 会带上密钥，故此处逐字段
    手写（与 ``/models`` / ``models-info`` 同一口径）。``api_key`` 只回传
    「是否已配置」的布尔量，供前端表单提示。
    """
    return {
        "model_id": cfg.model_id,
        "name": cfg.name,
        "api_model_id": cfg.api_model_id,
        "base_url": _mask_base_url(cfg.base_url),
        "thinking": cfg.thinking,
        "if_vision": cfg.if_vision,
        "max_seqlen": cfg.extra.get("max_seqlen"),
        "reasoning_effort": cfg.extra.get("reasoning_effort"),
        "reasoning_effort_options": resolve_reasoning_effort_options(cfg.extra),
        "max_output_tokens": cfg.extra.get("max_output_tokens"),
        "compress_threshold": cfg.extra.get("compress_threshold"),
        "temperature": cfg.extra.get("temperature"),
        "top_k": cfg.extra.get("top_k"),
        "timeout_seconds": cfg.extra.get("timeout_seconds"),
        "has_api_key": bool(cfg.api_key),
    }


class SaveModelRequest(BaseModel):
    """自定义模型创建/更新请求体。

    更新语义：``api_key`` 留空 = **不修改**（保留原密钥）。密钥不回显到前端，
    因此"留空"是唯一不与数据最小化冲突的语义（不存在"清空密钥"操作）。
    """

    model_id: str
    name: str = ""
    base_url: str = ""
    api_key: str = ""
    api_model_id: Optional[str] = None
    thinking: Optional[bool] = None
    if_vision: Optional[bool] = None
    max_seqlen: Optional[int] = None
    reasoning_effort: Optional[str] = None
    reasoning_effort_options: Optional[List[str]] = None
    max_output_tokens: Optional[int] = None
    compress_threshold: Optional[float] = None
    temperature: Optional[float] = None
    top_k: Optional[int] = None
    timeout_seconds: Optional[int] = None


def _validate_model_payload(body: SaveModelRequest) -> None:
    """校验数值范围与思考强度（越界/非法直接 400，避免写入后 agent 静默异常）。

    ``reasoning_effort`` 在此处一律**归一化后落库**（strip + lower + 别名折叠），
    并校验属于 ``reasoning_effort_options`` 声明（未声明则用全局有区分度的档位）。
    否则一个手输的大写/带空格值会写进 YAML，此后每次发言都被网关 422 拒绝。
    """
    if body.max_seqlen is not None and body.max_seqlen <= 0:
        raise HTTPException(status_code=400, detail="max_seqlen 必须为正整数")
    if body.max_output_tokens is not None and body.max_output_tokens <= 0:
        raise HTTPException(status_code=400, detail="max_output_tokens 必须为正整数")
    if body.compress_threshold is not None and not (
        0.1 <= float(body.compress_threshold) <= 0.95
    ):
        raise HTTPException(
            status_code=400, detail="compress_threshold 必须在 0.1~0.95 之间"
        )
    if body.temperature is not None and not (0.0 <= float(body.temperature) <= 2.0):
        raise HTTPException(status_code=400, detail="temperature 必须在 0~2 之间")
    if body.timeout_seconds is not None and body.timeout_seconds <= 0:
        raise HTTPException(status_code=400, detail="timeout_seconds 必须为正整数")

    # 思考强度：先归一化可选档位声明，再校验默认值是否落在其中。
    # 未声明档位时回退「有实际区分度」的全局档位，而不是接受枚举全集——
    # 全集里 minimal/medium/xhigh/ultra 与服务端档位一一等价，属于假选项。
    declared_options = normalize_reasoning_effort_options(
        body.reasoning_effort_options
    )
    if body.reasoning_effort_options is not None and not declared_options:
        raise HTTPException(
            status_code=400,
            detail=(
                "reasoning_effort_options 声明无效：需为档位列表，可选 "
                f"{', '.join(REASONING_EFFORT_ACCEPTED)}（别名会被折叠）"
            ),
        )
    options = declared_options or list(REASONING_EFFORT_CANONICAL)
    if body.reasoning_effort is None or not str(body.reasoning_effort).strip():
        # 空白一律视为「未指定」并**从 payload 中剔除**，而不是落盘成 ""：
        # 空串不是合法枚举（网关 422 unknown variant），写进 YAML 会让
        # 该模型每次请求都触发一次"非法值已丢弃"告警。
        body.reasoning_effort = None
    else:
        normalized = normalize_reasoning_effort(body.reasoning_effort)
        if normalized is None:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"reasoning_effort 取值非法: {body.reasoning_effort!r}"
                    f"（可选: {', '.join(REASONING_EFFORT_ACCEPTED)}）"
                ),
            )
        if normalized not in options:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"reasoning_effort={body.reasoning_effort!r} 不在该模型声明的"
                    f"可选档位内: {', '.join(options)}"
                ),
            )
        body.reasoning_effort = normalized
    if body.reasoning_effort_options is not None:
        body.reasoning_effort_options = options


@router.post("/models")
async def create_model(
    body: SaveModelRequest,
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """新增一个自定义模型（写入 ``configs/models/<model_id>.yaml``）。

    写入成功后立即刷新 ``state.model_configs``，否则新模型"下拉可见、选中 400"
    （全部生效路径读的是启动快照，见 ``config.models.reload_model_configs``）。
    """
    from config.models import (
        is_valid_model_id,
        model_config_path,
        reload_model_configs,
        save_model_config,
    )

    if not is_valid_model_id(body.model_id):
        raise HTTPException(
            status_code=400,
            detail="model_id 非法：仅允许字母、数字与 . _ -",
        )
    path = model_config_path(body.model_id)
    if path is not None and path.exists():
        raise HTTPException(status_code=400, detail=f"模型已存在: {body.model_id}")
    # 新增必须齐备定位信息（更新时可由既有配置回填，故只在 create 校验）
    if not body.name.strip():
        raise HTTPException(status_code=400, detail="name 不能为空")
    if not body.base_url.strip():
        raise HTTPException(status_code=400, detail="base_url 不能为空")
    if not body.api_key.strip():
        raise HTTPException(status_code=400, detail="api_key 不能为空")
    _validate_model_payload(body)
    try:
        cfg = save_model_config(body.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"写入模型配置失败: {exc}") from None
    reload_model_configs()
    return {"success": True, "model": _model_to_response(cfg)}


@router.patch("/models/{model_id}")
async def update_model(
    model_id: str,
    body: SaveModelRequest,
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """更新一个自定义模型（``api_key`` 留空则保留原密钥）。"""
    from config.models import (
        get_model_configs,
        reload_model_configs,
        save_model_config,
    )

    existing = get_model_configs().get(model_id)
    if existing is None:
        raise HTTPException(status_code=404, detail=f"模型不存在: {model_id}")
    _validate_model_payload(body)

    payload = body.model_dump()
    payload["model_id"] = model_id
    if not str(payload.get("api_key") or "").strip():
        payload["api_key"] = existing.api_key
    # 未传的可选字段沿用现值（避免"部分更新"把已有配置清空）
    for key, current in (
        ("name", existing.name),
        ("base_url", existing.base_url),
        ("api_model_id", existing.api_model_id),
        ("thinking", existing.thinking),
        ("if_vision", existing.if_vision),
        ("max_seqlen", existing.extra.get("max_seqlen")),
        ("reasoning_effort", existing.extra.get("reasoning_effort")),
        # 档位声明不在设置页表单里（新增时才显式声明）；更新时未传则沿用文件现值，
        # 避免用全局回退值覆盖掉 YAML 里手工写的自定义档位
        (
            "reasoning_effort_options",
            declared_reasoning_effort_options(existing.extra),
        ),
        ("max_output_tokens", existing.extra.get("max_output_tokens")),
        ("compress_threshold", existing.extra.get("compress_threshold")),
        ("temperature", existing.extra.get("temperature")),
        ("top_k", existing.extra.get("top_k")),
        ("timeout_seconds", existing.extra.get("timeout_seconds")),
    ):
        if (payload.get(key) is None or payload.get(key) == "") and current is not None:
            payload[key] = current
    # 回填后仍缺关键定位信息则拒绝（避免写出不可用配置）
    if not str(payload.get("name") or "").strip():
        raise HTTPException(status_code=400, detail="name 不能为空")
    if not str(payload.get("base_url") or "").strip():
        raise HTTPException(status_code=400, detail="base_url 不能为空")
    if not str(payload.get("api_key") or "").strip():
        raise HTTPException(
            status_code=400,
            detail="api_key 为空且原配置也没有密钥，请在本次更新中提供",
        )
    try:
        cfg = save_model_config(payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"写入模型配置失败: {exc}") from None
    reload_model_configs()
    return {"success": True, "model": _model_to_response(cfg)}


@router.delete("/models/{model_id}")
async def delete_model(
    model_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """删除一个自定义模型配置文件。

    若仍有 agent 绑定该模型，一并返回 ``bound_agents`` 供前端提示（删除本身
    仍执行：配置文件已不可用，保留绑定只会让这些 agent 继续报"模型不存在"）。
    """
    from config.models import delete_model_config, reload_model_configs

    user_id = current_user.get("openid", "")
    bound = [
        {"id": record["id"], "name": record.get("name", "")}
        for record in (get_agents(user_id) or [])
        if record.get("model_id") == model_id
    ]
    removed = delete_model_config(model_id)
    if not removed:
        raise HTTPException(status_code=404, detail=f"模型不存在或不可删除: {model_id}")
    reload_model_configs()
    return {"success": True, "model_id": model_id, "bound_agents": bound}


# ===== MCP 服务管理（右侧" MCP 配置"页） =====


class RegisterMcpServiceRequest(BaseModel):
    """注册外部 MCP 服务请求体（stdio 外接）。"""

    name: str
    command: str
    args: List[str] = []
    scope: str = ""
    env: Dict[str, str] = {}


@router.get("/mcp/services")
async def list_mcp_services(
    _: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """列出已注册的外部 MCP 服务（含内置服务标记）。

    外部服务来自 SQLite ``mcp_services`` 表（REST 注册，权威持久化），
    每项含 scope / env / needs_confirmation；内置服务（workspace / document）
    在会话构建时由 ``register_builtin_tools`` 注册，此处仅列出外部配置。
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

    安全校验（spec「MCP services CRUD」）：底线形态过滤（禁 shell 解释器、
    禁 shell 元字符与内联执行参数），非可信启动器由前端首次确认后启动。
    ``scope`` / ``env`` 原样透传并持久化（env 值不写入日志）。
    """
    from data.mcp_service_store import register_service

    try:
        record = register_service(
            req.name, req.command, req.args, scope=req.scope, env=req.env
        )
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
            pending["team_id"],
            pending["session_id"],
            answer,
            pending["is_member"],
            # 原发送方：成员续跑后总结精确回发到"谁发给它的那位"；
            # 旧数据空串（用户直发）归一为 USER_AGENT_ID（读取侧等效）。
            pending.get("sender_id") or USER_AGENT_ID,
        )
    )
    return {"success": True, "qid": qid, "status": "answered"}


@router.get("/plugin/snapshot")
async def get_plugin_snapshot(
    team_id: Optional[str] = None,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """插件面板只读快照（二期 M1-b；契约 §15.1）。

    - 未启用（默认）/ 组件未初始化：返回 ``enabled=false`` 骨架（200）；
    - 按 user 过滤（token 归属；``openid``/``id`` 兼容提取）；可选 ``team_id`` 进一步过滤；
    - 归属为空 fail-closed（不得因空值放行全量）；只读、无副作用。
    """
    user_id = _user_id_of(current_user or {})
    if not user_id:
        return {"success": False, "error": "缺少用户归属"}
    from plugin import get_snapshot  # noqa: PLC0415（懒 import：插件模块按需加载）

    return get_snapshot(user_id=user_id, team_id=team_id or "")
