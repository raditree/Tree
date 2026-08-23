"""Agent chat 编排：用户/成员消息处理、流式推送、统一消息投递。

自 main.py 迁出（P0 组件化重组），包含：
- 用户消息处理（_handle_user_message / _stream_agent_reply）
- 成员消息处理（_process_member_message，由 team broker worker 串行调用）
- 统一消息投递（_dispatch_agent_message / _find_roster_member / _parse_roster_table）
- .self 文档注入（identity/memory/rule，超限 LLM 压缩）
- 活动日志 / 取消事件 / 记忆更新阶段
"""
import asyncio
import datetime
import hashlib
import logging
import os
import queue
import threading
import time
import uuid
from typing import Any, Dict, List, Optional, Set, Tuple

from openai import RateLimitError

import state
from config.config import get_config
from config.models import ModelConfig
from data.agent_store import get_agent
from data.conversation_store import (
    load_context,
    save_context,
    store_message,
)
from data.data_collection_store import collect_sft_turn
from data.session_cache import get_session, set_session
from data.session_store import (
    DEFAULT_SESSION,
    create_session,
    touch_session,
    update_session_title_from_first_message,
)
from io_.workspace_io import run_io
from llm.llm import AgentLLMSession, _AskPaused
from tool import register_builtin_tools

# 模块级日志器
logger = logging.getLogger(__name__)


def _store_message(
    user_id: str,
    agent_id: str,
    role: str,
    content: str,
    usage: Optional[Dict[str, Any]] = None,
    kind: str = "text",
    tool_name: Optional[str] = None,
    tool_arguments: Optional[Dict[str, Any]] = None,
    tool_result: Optional[str] = None,
    session_id: str = DEFAULT_SESSION,
) -> Dict[str, Any]:
    """保存一条消息到 SQLite 持久化历史。"""
    return store_message(
        user_id, agent_id, role, content,
        usage=usage, kind=kind,
        tool_name=tool_name, tool_arguments=tool_arguments,
        tool_result=tool_result, session_id=session_id,
    )


async def _register_tools(
    session: AgentLLMSession, agent_id: str, user_id: str = "",
    leader_id: str = "", top_agent_id: str = "", member_system_prompt: str = "",
    session_id: str = DEFAULT_SESSION, is_member: bool = False,
) -> None:
    """给会话注册内置工具（team / mcp / spec 等）。

    封装对 register_builtin_tools 的调用，避免重复展开 mcp_config 取值逻辑。
    同时把消息投递器与用户标识传给 team 工具，用于异步触发成员处理。
    并给会话挂上 compact 时的 system prompt 重建回调（spec「注入时机」：
    重构 context 时重建 system prompt，注入最新 Spec 索引/已选 Spec/memory/成员拓扑）。
    """
    mcp_config = get_config().get("mcp")
    # 合并 DB 持久化的外部 MCP 服务（REST /api/mcp/services 注册），
    # 与 config yaml 内置服务一起注册到 MCPManager（spec「MCP services CRUD」）
    try:
        from data.mcp_service_store import load_services_as_config

        db_services = load_services_as_config()
        if db_services:
            merged = dict(mcp_config or {})
            merged.update(db_services)
            mcp_config = merged
    except Exception as exc:  # noqa: BLE001
        logger.warning("加载 DB 外部 MCP 服务失败(忽略): %s", exc)
    workspace_id = getattr(session, "workspace_id", "") or ""
    session.system_prompt_rebuilder = _make_system_prompt_rebuilder(
        workspace_id,
        member_system_prompt=member_system_prompt,
        user_id=user_id,
        agent_id=agent_id,
        top_agent_id=top_agent_id,
        session_id=session_id,
    )

    # workspace_extra_info 刷新回调：每次 compact 刷新时现读现算
    # （identity/memory.md 均为最新），避免会话构造时的一次性
    # 快照长期过期（memory.md 每次记忆维护都会更新）。
    def _extra_info_refresher() -> dict:
        return _build_workspace_extra_info(
            workspace_id,
            member_system_prompt=member_system_prompt,
            user_id=user_id,
            agent_id=top_agent_id or agent_id,
            local_executor=state.local_executor,
        )

    register_builtin_tools(
        session,
        docker_manager=state.docker_manager,
        model_configs=state.model_configs,
        mcp_config=mcp_config,
        broker=state.team_broker,
        user_id=user_id,
        ws_manager=state.ws_manager,
        agent_id=agent_id,
        leader_id=leader_id,
        top_agent_id=top_agent_id,
        local_executor=state.local_executor,
        message_dispatcher=_dispatch_agent_message,
        extra_info_refresher=_extra_info_refresher,
        session_id=session_id,
        is_member=is_member,
    )


def _make_system_prompt_rebuilder(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    top_agent_id: str = "",
    session_id: str = "",
) -> Any:
    """构造 compact（重构 context）时重建 system prompt 的同步回调。

    现读现算：.self 文档（identity/memory）、Spec 索引、已选 Spec 全文、
    成员拓扑均为最新。回调在后台线程（自动压缩）或 to_thread（手动 compact）
    中执行，其中读取 .self 经反向 WS（阻塞）不会卡死事件循环。
    """
    def _rebuild() -> str:
        extra_info = _build_workspace_extra_info(
            workspace_id,
            member_system_prompt=member_system_prompt,
            user_id=user_id,
            agent_id=top_agent_id or agent_id,
            local_executor=state.local_executor,
        )
        return _build_agent_system_prompt(
            workspace_id,
            member_system_prompt=member_system_prompt,
            user_id=user_id,
            agent_id=agent_id,
            top_agent_id=top_agent_id,
            session_id=session_id,
            extra_info=extra_info,
        )
    return _rebuild


def _upload_attachments(
    workspace_id: str, paths: Any
) -> List[str]:
    """将对话框上传的本地文件写入工作空间 ``.input/yyyymmdd/`` 目录。

    返回工作空间内的路径列表（如 ``/workspace/.input/20260808/xxx``）。
    Docker 不可用或文件不存在时跳过该文件。写入失败仅记录日志，不中断。

    :param workspace_id: agent 工作空间标识
    :param paths: 用户上传的本地文件路径列表
    :return: 成功写入工作空间的路径列表
    """
    if not paths or state.docker_manager is None or not state.docker_manager.available:
        return []
    date_dir = datetime.datetime.now().strftime("%Y%m%d")
    uploaded: List[str] = []
    for p in paths:
        path = str(p)
        if not os.path.isfile(path):
            logger.debug("附件不存在，跳过上传: %s", path)
            continue
        name = os.path.basename(path.replace("\\", "/"))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as exc:  # noqa: BLE001
            logger.warning("读取附件失败: %s (%s)", path, exc)
            continue
        container_path = f".input/{date_dir}/{name}"
        result = state.docker_manager.write_file(workspace_id, container_path, data)
        if result.get("exit_code") != 0 or "error" in result:
            logger.warning(
                "附件写入工作空间失败: %s (exit=%s, error=%s, detail=%s, stderr=%s)",
                name,
                result.get("exit_code"),
                result.get("error", ""),
                result.get("detail", ""),
                str(result.get("stderr", ""))[:200],
            )
            continue
        uploaded.append(f"/workspace/{container_path}")
    return uploaded


def _build_attachments_prompt(paths: Any) -> str:
    """构建注入到 LLM 提示词的附件路径块。

    附件已由 ``_upload_attachments`` 写入工作空间，此处仅将路径告知 LLM，
    不再读取文件内容注入；LLM 如需内容再通过 read 工具读取。

    :param paths: 工作空间内的附件路径列表
    :return: 提示词片段；无文件时返回空字符串
    """
    if not paths:
        return ""
    lines: List[str] = ["[用户上传的文件，已存入工作空间，如需内容请用 read 工具读取]"]
    for p in paths:
        name = os.path.basename(str(p).replace("\\", "/"))
        lines.append(f"- {name}: {p}")
    return "\n".join(lines)


def _read_workspace_file(workspace_id: str, rel_path: str) -> str:
    """从工作空间读取文件内容（不存在或失败时返回空字符串）。"""
    if not workspace_id or state.docker_manager is None:
        return ""
    try:
        result = state.docker_manager.exec_in_workspace(
            workspace_id, ["cat", rel_path]
        )
        if result.get("exit_code", -1) != 0:
            return ""
        return result.get("stdout", "") or ""
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取工作空间文件失败 %s/%s: %s", workspace_id, rel_path, exc)
        return ""


def _get_workspace_size(workspace_id: str) -> int:
    """获取工作空间已用字节数（查询失败返回 0）。"""
    if not workspace_id or state.docker_manager is None:
        return 0
    if state.docker_manager._use_local():
        # 本地模式：直接统计本地工作空间目录大小
        import os as _os

        local_workspace = state.docker_manager._local_workspace_path(workspace_id)
        if not local_workspace.exists():
            return 0
        total = 0
        for dirpath, _dirnames, filenames in _os.walk(str(local_workspace)):
            for fname in filenames:
                try:
                    total += _os.path.getsize(_os.path.join(dirpath, fname))
                except OSError:
                    continue
        return total
    try:
        result = state.docker_manager.exec_in_workspace(
            workspace_id, ["sh", "-c", "du -sb /workspace 2>/dev/null"]
        )
        if result.get("exit_code", -1) != 0:
            return 0
        out = result.get("stdout", "").strip()
        return int(out.split()[0]) if out else 0
    except Exception:  # noqa: BLE001
        return 0


# Spec 索引注入条数上限（超限提示用 spec search 取更多）
_SPEC_INDEX_LIMIT = 12


def _build_agent_system_prompt(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    top_agent_id: str = "",
    session_id: str = "",
    extra_info: Optional[Dict[str, Any]] = None,
) -> str:
    """构建 agent 系统提示词：9 章节全量注入（spec「system prompt 内容」）。

    ① 身份与角色（.self/identity.md，默认顶层 Agent 说明）
    ② 任务执行范式（任务分型路由：判型 easy/complex/hard → 选对应内置 Spec →
       按其 workflow 执行）
    ③ 需求→工具路由表（7 需求维度 → 内置工具）
    ④ .self 文档注入（memory.md，超 4k 已由 _build_workspace_extra_info 压缩）
    ⑤ Spec 索引（内置 3 置顶 + 自定义，id/task_type/title/when 摘要）
    ⑥ 已选 Spec 全文（本会话挂 hook 的 Spec，注入 workflow/规范/注意事项全文）
    ⑦ 工作空间与执行模式（三模式 + shell 类型 + 存储软上限告警）
    ⑧ 成员拓扑与寻址规则（TOP + 全体成员；top 内按 name 寻址、跨 Top 顶层寻址、
       回复路径）
    ⑨ Spec 维护指引（何时应 search/select/create spec）

    :param workspace_id: 工作空间标识
    :param member_system_prompt: 成员专属系统提示词（leader 通过 update_member 设置）
    :param user_id: 用户标识
    :param agent_id: 当前 agent 的 ID
    :param top_agent_id: 所属顶层 agent ID（顶层 agent 自身即 agent_id）
    :param session_id: 当前会话 ID（读取已选 Spec）
    :param extra_info: ``_build_workspace_extra_info`` 的输出（identity/memory/
                       exec_mode/storage_warning 等现算信息）
    :return: 9 章节系统提示词
    """
    extra_info = extra_info or {}
    mode_key = top_agent_id or agent_id
    chapters: List[str] = []

    # ① 身份与角色
    identity = str(extra_info.get("identity") or "").strip()
    if not identity:
        identity = "顶层 Agent（Level 0），直属用户，可创建并带领子团队。"
    identity_chapter = ["## ① 身份与角色", identity]
    if member_system_prompt:
        identity_chapter.append(f"\n角色分工（leader 设定）:\n{member_system_prompt}")
    chapters.append("\n".join(identity_chapter))

    # ② 任务执行范式：任务分型路由
    chapters.append(_build_task_paradigm_text())

    # ③ 需求→工具路由表（7 维度）
    chapters.append(_build_tool_routing_text())

    # ④ .self 私人文档（memory.md；rule.md 已移除）
    memory = str(extra_info.get("memory") or "").strip()
    if memory:
        chapters.append("## ④ .self 私人文档（memory.md）\n" + memory)
    else:
        chapters.append(
            "## ④ .self 私人文档\n暂无 memory.md；任务完成/关键结论请维护到 "
            ".self/memory.md 供跨会话记忆。"
        )

    # ⑤ Spec 索引（内置 3 置顶 + 自定义）
    chapters.append(
        "## ⑤ Spec 索引（内置 3 置顶 + 自定义）\n" + _build_spec_index_text(agent_id)
    )

    # ⑥ 已选 Spec 全文（本会话挂 hook）
    selected_text = _build_selected_specs_text(
        workspace_id, user_id, mode_key, session_id
    )
    if selected_text:
        chapters.append("## ⑥ 已选 Spec 全文（本会话挂 hook）\n" + selected_text)

    # ⑦ 工作空间与执行模式
    exec_mode = str(extra_info.get("exec_mode") or "").strip()
    if exec_mode:
        chapter7 = "## ⑦ 工作空间与执行模式\n" + exec_mode
        storage_warning = str(extra_info.get("storage_warning") or "").strip()
        if storage_warning:
            chapter7 += "\n" + storage_warning
        chapters.append(chapter7)

    # ⑧ 成员拓扑与寻址规则
    chapters.append(
        _build_member_topology_text(workspace_id, user_id, mode_key)
    )

    # ⑨ Spec 维护指引
    chapters.append(_build_spec_maintenance_text())

    # ⑩ 任务进度管理纪律（todo 及时更新）
    chapters.append(_build_todo_discipline_text())

    return "\n\n".join(chapters)


def _build_task_paradigm_text() -> str:
    """② 任务执行范式：任务分型路由（easy/complex/hard/team-meeting → 内置 Spec workflow）。"""
    return (
        "## ② 任务执行范式（任务分型路由）\n"
        "接到任务先判型，再选对应内置 Spec 按其 workflow 执行：\n"
        "- **easy-task**：单文件(≤3)局部改动 / 明确问答查资料 / tool call 预计 ≤5 / "
        "无新增依赖与接口变更。直接 read 读上下文 → edit/write/terminal 执行 → "
        "terminal 验证 → 汇报。\n"
        "- **complex-task**：跨文件跨模块 / 需分工 / 新功能多组件 / 环境依赖变更。"
        "先 spec search 找适用 Spec（命中→select 并遵循）→ set_todo_list 分解 → "
        "按需 team 指派成员 → 按 todo 执行并更新 → 全量验证 → 汇报 → "
        "无适用 Spec 时 spec create 沉淀。\n"
        "- **hard-task**：架构级框架级变更 / 新领域无经验 / 高不确定需多方案 / 高危。"
        "先界定边界 → 召开团队会议讨论选型（遵循 team-meeting，**会议期间只讨论不落地**）→ "
        "标准团队流水线（需求→方案→评审→实现→测试→交付）→ 高危操作 ask_user_question 确认 → "
        "末尾强制 spec create 补 Spec。\n"
        "- **team-meeting**：团队方案讨论/评审/定案。leader 召集会议只讨论、只产出方案；"
        "成员收到会议消息后**只发言不落地**（禁 write/edit/terminal/assign_task），"
        "收到明确执行指令后方可开工。\n"
        "easy 是初判非承诺：执行中复杂度增长（tool call >8 未收敛 / 发现跨文件影响）"
        "必须切换更高级别，不得硬撑。"
    )


def _build_tool_routing_text() -> str:
    """③ 需求→工具路由表：7 需求维度 → 内置工具映射。"""
    return (
        "## ③ 需求→工具路由表（按需求选工具）\n"
        "- **上下文获取**：read（读文件）/ spec（检索/读取任务规范）/ mcp call（MCP 工具）\n"
        "- **文件产出**：write（新建）/ edit（修改）/ read（先看再改）\n"
        "- **环境执行**：terminal（命令/git/构建/验证，注意 shell 类型语法）\n"
        "- **外部能力**：mcp call（workspace/document/外部 MCP 服务工具）\n"
        "- **协同**：team（向成员派发任务/收成果/看进度/跨 Top 顶层通信）\n"
        "- **任务管理**：set_todo_list（拆解/跟踪进度）/ spec（沉淀规范）\n"
        "- **人机协作**：ask_user_question（关键决策/高危操作需用户确认时）"
    )


def _build_spec_index_text(agent_id: str) -> str:
    """⑤ Spec 索引：内置 4 置顶 + 自定义 Spec（id/task_type/title/when 摘要），超限截断。"""
    try:
        from data.spec_store import list_specs

        specs = list_specs(agent_id=agent_id or None)
    except Exception as exc:  # noqa: BLE001
        logger.warning("构建 Spec 索引失败: %s", exc)
        return "（Spec 索引读取失败，可稍后用 spec list 查看）"
    if not specs:
        return "（暂无 Spec，任务完成前可用 spec create 沉淀）"
    lines: List[str] = []
    for s in specs[:_SPEC_INDEX_LIMIT]:
        when = "；".join(s.get("when") or [])
        if len(when) > 80:
            when = when[:80] + "…"
        line = f"- `{s['id']}` [{s.get('task_type', '')}] {s.get('title', '')}"
        # 标注内置模板（easy/complex/hard/team-meeting），与自定义 Spec 区分
        if s.get("builtin"):
            line += "（内置）"
        if when:
            line += f"（适用: {when}）"
        lines.append(line)
    if len(specs) > _SPEC_INDEX_LIMIT:
        lines.append(f"- …共 {len(specs)} 条，更多请用 spec search 检索")
    return "\n".join(lines)


def _read_spec_full_text(workspace_id: str, user_id: str, mode_key: str,
                         spec_id: str) -> str:
    """读取 Spec 全文：内置模板优先，其次工作空间 ``spec/<id>.md``（三模式通用）。"""
    from tool.spec_tool import _BUILTIN_DIR

    builtin_file = _BUILTIN_DIR / f"{spec_id}.md"
    if builtin_file.exists():
        return builtin_file.read_text(encoding="utf-8")
    io = _get_workspace_io(user_id, mode_key)
    if io is None:
        return _read_workspace_file(workspace_id, f"spec/{spec_id}.md")
    try:
        r = run_io(io.read_file(workspace_id, f"spec/{spec_id}.md"))
        if r.get("error"):
            return ""
        return str(r.get("content") or "")
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取 Spec 全文失败 %s/%s: %s", workspace_id, spec_id, exc)
        return ""


def _build_selected_specs_text(
    workspace_id: str, user_id: str, mode_key: str, session_id: str
) -> str:
    """⑥ 已选 Spec 全文：本会话挂 hook 的 Spec 注入 workflow/规范/注意事项全文。"""
    if not (user_id and session_id):
        return ""
    try:
        from data.session_store import get_selected_spec_ids

        spec_ids = get_selected_spec_ids(user_id, session_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取已选 Spec 失败: %s", exc)
        return ""
    if not spec_ids:
        return ""
    blocks: List[str] = []
    for sid in spec_ids:
        content = _read_spec_full_text(workspace_id, user_id, mode_key, sid)
        if content.strip():
            blocks.append(f"### Spec: {sid}\n{content.strip()}")
    return "\n\n".join(blocks)


def _build_member_topology_text(
    workspace_id: str, user_id: str, mode_key: str
) -> str:
    """⑧ 成员拓扑与寻址规则：注入所属 TOP 的成员名单 + 寻址/回复路径规则。

    成员名单的权威来源是 ``team_members`` 表（P4 TOP 创建即全量建队），
    注入 name/role/duty/model_id/status（spec「成员拓扑常驻」）；
    未建队/旧数据时回退读取顶部 agent 工作空间的 ``.self/team_roster.md``。
    """
    members = _load_members_from_team_store(mode_key)
    roster = ""
    if not members:
        io = _get_workspace_io(user_id, mode_key)
        if io is not None:
            try:
                r = run_io(io.read_file(workspace_id, ".self/team_roster.md"))
                roster = "" if r.get("error") else (str(r.get("content") or ""))
            except Exception as exc:  # noqa: BLE001
                logger.warning("读取成员拓扑失败: %s", exc)
        if not roster.strip():
            roster = _read_workspace_file(workspace_id, ".self/team_roster.md")
        members = _parse_roster_table(roster) if roster.strip() else []

    lines = ["## ⑧ 成员拓扑与寻址规则"]
    if members:
        lines.append("当前团队成员（ID | 名称 | 角色 | 职责 | 模型 | 状态 | 层级）:")
        for m in members:
            # 状态列注入**实际执行态**（基于 _active_tasks），
            # 不读表/roster 快照（避免假 working）
            mid = m.get("id", "")
            live_status = (
                "working"
                if (user_id and mid and _is_agent_working(user_id, mid))
                else "idle"
            )
            lines.append(
                f"- {mid} | {m.get('name', '')} | "
                f"{m.get('role', '')} | {m.get('duty', '')} | "
                f"{m.get('model_id', '')} | {live_status} | "
                f"L{m.get('level', 1)}"
            )
    else:
        lines.append("当前为顶层 Agent，尚无成员（需要分工时经 team 指派/带领子团队）。")
    lines.append("寻址规则:")
    lines.append("- 本团队内按成员名称（name）寻址：team 派发任务/收成果时用成员 name。")
    lines.append("- 跨团队顶层沟通：先 list_teams 熟悉本用户名下 TOP，向其他 TOP agent "
                "按 TOP 名称寻址，经 team 投递。")
    lines.append("- 回复路径：成员→上级（TOP）；TOP→用户。成员不直接面向用户。")
    lines.append("- 使用 team 工具前先检查成员基本信息：role/duty 为空时用 "
                "update_member 补充完善再派发任务；model_id 为空会自动回退所属 "
                "TOP 模型（无需强制 update_member）。")
    return "\n".join(lines)


def _load_members_from_team_store(mode_key: str) -> List[Dict[str, Any]]:
    """从 ``team_members`` 表读取所属 TOP 的权威成员名单（含 role/duty）。

    ``mode_key`` 即顶部 agent ID（system prompt 构建时传 ``top_agent_id or
    agent_id``）。名单为空或读取失败时返回空列表（调用方回退 roster 文件）。
    """
    try:
        from data.team_store import get_members

        return get_members(mode_key) or []
    except Exception as exc:  # noqa: BLE001
        logger.warning("从 team_store 读取成员拓扑失败: %s", exc)
        return []


def _build_spec_maintenance_text() -> str:
    """⑨ Spec 维护指引：何时应 search/select/create spec。"""
    return (
        "## ⑨ Spec 维护指引\n"
        "- 任务开始前：先用 spec search 检索是否已有对应 Spec（内置 "
        "easy/complex/hard/team-meeting 或历史自定义）；命中则遵循其 workflow。\n"
        "- 任务过程中：用户/团队约定、可复用的工作流与规范值得沉淀时 spec create 记录。\n"
        "- 任务完成后（complex/hard 且无适用 Spec）：spec create 补充对应 Spec"
        "（hard 强制，缺则任务未闭环）。\n"
        "- 中途新增选择：spec select 挂 hook，下次重构 context（compact/新建会话）"
        "自动注入全文；立即使用请用 spec read 取全文进对话上下文。"
    )


def _build_todo_discipline_text() -> str:
    """⑩ 任务进度管理纪律：todo 必须增量、及时、诚实更新。

    提示词工程师要点：
    - 反模式：任务开始时一次 set 全量 todos，然后全程不动，直到全部完成才一次性
      update 标注 completed。评估与进度失真，用户无法感知中途进展。
    - 正模式：todos 是"活"清单。建好在里程碑（每完成/推进一项、遇到阻塞）处
      及时增量 update，让用户随时看到真实进度。
    """
    return (
        "## ⑩ 任务进度管理纪律（todo 须增量更新）\n"
        "- **及时性**：不要「建好 todos 后扔一边、最后统一标完成」。每完成一个子任务、"
        "每取得阶段性进展、每遇到阻塞，都要**立即**用 set_todo_list update 更新对应 "
        "todo（status/progress），让前端 Todo 面板始终反映真实进度。\n"
        "- **诚实性**：progress 按实际完成度填（如 0/50/100），status 只在真正完成时置 "
        "completed、受阻时置 blocked；不得为了好看虚报全绿。\n"
        "- **小步更新**：宁可多次小更新，不要攒到最后一次大改。100 条消息的复杂任务，"
        "每条 todo 应在它完成的那轮附近被标注，而非任务结束时才统一写完成。\n"
        "- **中途变化**：执行中发现原计划不适用需调整范围时，用 set_todo_list set "
        "整体替换清单并如实标注（含新增/删除/合并），不要保留已过时的 todo。\n"
        "- **长任务/团队任务必用**：hard / 多人协作务必全程维护 todos，作为进度契约"
        "与回滚依据；easy 小任务可不建。"
    )


def _build_exec_mode_text(
    workspace_id: str,
    user_id: str = "",
    agent_id: str = "",
    local_executor: Any = None,
) -> str:
    """构建执行模式说明文本（三模式 + shell 类型 + 工作空间位置），供 system prompt 注入。

    复用 ``io_.mode_resolver.describe_mode`` 透出三模式与 shell 类型（spec「shell
    类型透出」：cloud=Linux sh / local Windows=cmd.exe / local mac·linux=bash /
    ssh=远端 shell）。本地模式额外注明工作目录与 .self 私人空间位置；云端注明容器工作空间。
    """
    from io_.mode_resolver import describe_mode

    mode_key = agent_id or user_id or ""
    mode_text = ""
    if mode_key:
        try:
            mode_text = describe_mode(user_id, mode_key)
        except Exception:  # noqa: BLE001
            mode_text = ""
    if not mode_text:
        mode_text = "执行模式: 云端 Linux 容器。shell = sh (POSIX)，遵循 POSIX 命令语法。"

    is_local = False
    base_dir = ""
    if local_executor is not None and mode_key:
        try:
            is_local = bool(local_executor.is_local(user_id, mode_key))
        except Exception:  # noqa: BLE001
            is_local = False
        if is_local:
            try:
                reg = getattr(local_executor, "_users", {}) or {}
                base_dir = ((reg.get(user_id) or {}).get(mode_key) or "") or ""
            except Exception:  # noqa: BLE001
                base_dir = ""
    if is_local:
        ws_self = f"{base_dir or '<用户选择目录>'}/workspaces/{workspace_id}/.self"
        return (
            f"{mode_text}；工作目录 {base_dir or '<用户选择目录>'}"
            f"；你的私人空间 .self 位于 {ws_self}；"
            "团队成员共享该工作目录，直接在此读写文件协作（无需跨沙箱）"
        )
    return (
        f"{mode_text}；工作空间 {workspace_id} 位于 Docker 容器，"
        "工作文件与私人空间 .self 都在容器内"
    )


# .self 文档（memory.md / rule.md）注入大小上限（字符数）：未超限时全量注入
# help 的 workspace_extra_info，超限时经 LLM 压缩为摘要再注入，控制 help 输出
# 体积与 token 成本。
_SELF_DOC_INJECT_LIMIT = 4096
# .self 文档压缩结果缓存：doc_key -> (内容指纹, 压缩文本)。
# 文档未变化时直接复用缓存，避免重复触发 LLM 压缩。
_self_doc_compress_cache: Dict[str, Tuple[str, str]] = {}


def _compress_self_doc(workspace_id: str, doc_key: str, text: str,
                       kind: str = "记忆档案") -> str:
    """.self 文档（memory.md / rule.md）超过注入上限时压缩为中文摘要。

    优先调用 LLM 压缩（复用默认模型配置，失败回退）；回退方案为保头保尾截断。
    带指纹缓存：文档内容未变化时直接返回缓存结果。

    :param workspace_id: 工作空间标识
    :param doc_key: 文档标识（如 "memory.md" / "rule.md"），用于缓存区分
    :param text: 文档全文
    :param kind: 文档种类名（用于压缩提示词，如 记忆档案 / 工作准则）
    """
    cache_key = f"{workspace_id}:{doc_key}"
    digest = hashlib.md5(text.encode("utf-8")).hexdigest()
    cached = _self_doc_compress_cache.get(cache_key)
    if cached and cached[0] == digest:
        return cached[1]

    compressed = ""
    try:
        from llm.llm import LLMClientFactory

        model_id = next(iter(state.model_configs), "")
        cfg = state.model_configs.get(model_id) if model_id else None
        if cfg is not None:
            client = LLMClientFactory.create_client(cfg)
            resp = client.chat.completions.create(
                model=cfg.api_model_id or cfg.model_id,
                messages=[{
                    "role": "user",
                    "content": (
                        f"你是文档压缩器。以下是一份 agent 的{kind}文档（{doc_key}），"
                        f"共 {len(text)} 字，超过单次注入上限。"
                        "请压缩成 4000 字以内的中文摘要，保留：任务目标与最新要求、"
                        "关键决策、遇到的问题及解决方案、重要结论、待办事项。"
                        "不要逐条复述原文，保留必要事实（文件名、路径、数字、结论）。\n\n"
                        f"文档内容：\n{text[:12000]}"
                    ),
                }],
                temperature=0.2,
                max_tokens=1024,
            )
            if resp.choices:
                compressed = (resp.choices[0].message.content or "").strip()
    except Exception as exc:  # noqa: BLE001
        logger.warning("%s 压缩失败(%s)，回退截断: %s", doc_key, workspace_id, exc)
        compressed = ""

    if not compressed:
        # 回退方案：保留头部与尾部，中间省略（保留最新轮次与最早基线）
        compressed = (
            text[:1800].rstrip()
            + "\n\n...[文档超长已截断，省略中间内容]...\n\n"
            + text[-1600:].lstrip()
        )
    _self_doc_compress_cache[cache_key] = (digest, compressed)
    return compressed


def _get_workspace_io(user_id: str, agent_id: str) -> Any:
    """构建与内置工具一致的 WorkspaceIO 通道（经 ModeResolver 三模式统一判定）。

    本地模式经反向 WS 到前端本地执行器，由前端把 workspace 相对路径映射到
    用户选择的工作目录（.self 私人空间 → baseDir/workspaces/{workspace_id}/.self）；
    SSH 模式经 paramiko 转发到远端主机；云端模式走 Docker 容器。
    用于读 .self 文档时与内置工具（read/write/edit/terminal）保持同一路径语义，
    避免双轨制（记忆维护写本地 baseDir，help 注入却读 Docker 容器）导致
    memory/rule 注入读到旧内容或缺失。
    """
    from io_.mode_resolver import build_workspace_io

    try:
        return build_workspace_io(user_id, agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("构建模式 WorkspaceIO 失败，回退云端: %s", exc)
    from io_.workspace_io import CloudWorkspaceIO

    return CloudWorkspaceIO(state.docker_manager)


def _build_workspace_extra_info(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    local_executor: Any = None,
) -> dict:
    """构建工作空间额外信息，供 system prompt 章节注入（身份/memory/执行模式/存储告警）。

    覆盖原 checklist 6 / 9 / 10 / 15：
    - 6(c) 身份：从 ``.self/identity.md`` 读取 team / level / team leader / 是否开团队
    - 10   memory.md：注入 ``.self/memory.md`` 内容（超 4k 压缩为摘要）
    - 15    存储软上限：工作空间接近 ``upload.sandbox_max_size`` 时提示清理

    :param workspace_id: 工作空间标识
    :param member_system_prompt: 成员专属系统提示词
    :return: 包含身份、memory、exec_mode、存储告警等信息的字典
    """
    info: Dict[str, Any] = {}

    # 统一 IO 通道读 .self 文档：与内置工具同路径语义（本地 baseDir/云端容器），
    # 保证 memory/rule/identity 注入读到的是 agent 实际写入的私人空间文件。
    _io = _get_workspace_io(user_id, agent_id)

    def _read_self_doc(rel_path: str) -> str:
        if _io is not None:
            try:
                r = run_io(_io.read_file(workspace_id, rel_path))
                content = r.get("content")
                if content is not None and not r.get("error"):
                    return str(content) or ""
            except Exception as exc:  # noqa: BLE001
                logger.warning("io 读取 %s 失败，回退 docker: %s", rel_path, exc)
        return _read_workspace_file(workspace_id, rel_path)

    # 执行模式（本地 vs 云端沙箱）：让 agent 无需猜测自己的工作环境。
    # 本地执行器按顶部 agent 注册（mode_key=top_agent_id；顶部 agent 自身即 agent_id）。
    exec_mode = _build_exec_mode_text(
        workspace_id, user_id=user_id, agent_id=agent_id,
        local_executor=local_executor,
    )
    if exec_mode:
        info["exec_mode"] = exec_mode

    # 身份信息（checklist 6(c)）
    identity = _read_self_doc(".self/identity.md").strip()
    if identity:
        info["identity"] = identity
    else:
        info["identity"] = "顶层 Agent（Level 0），直属用户，可创建并带领子团队。"

    # 成员专属系统提示词（如有）
    if member_system_prompt:
        info["member_system_prompt"] = member_system_prompt

    # memory.md 注入：全量优先，超过大小上限时压缩为摘要后再注入。
    # compact 触发上下文重构时现读现算，避免依赖会话构造时的一次性快照。
    # （rule.md 已按 spec 从设计移除，不再注入。）
    memory = _read_self_doc(".self/memory.md").strip()
    if memory:
        if len(memory) <= _SELF_DOC_INJECT_LIMIT:
            info["memory"] = memory
        else:
            info["memory"] = _compress_self_doc(
                workspace_id, "memory.md", memory, "记忆档案"
            )

    # 存储软上限告警（checklist 15）
    try:
        upload_cfg = get_config().get("upload", {})
        sandbox_max = _parse_size(upload_cfg.get("sandbox_max_size"), 1024 ** 3)
    except Exception:  # noqa: BLE001
        sandbox_max = 1024 ** 3
    if sandbox_max > 0:
        used = _get_workspace_size(workspace_id)
        if used > 0:
            ratio = used / sandbox_max
            if ratio >= 0.85:
                info["storage_warning"] = (
                    f"工作空间已使用 {used/1024/1024:.0f}MB "
                    f"（上限 {sandbox_max/1024/1024:.0f}MB，约 {ratio*100:.0f}%）。"
                    "请清理不再需要的文件，避免达到上限影响后续工作。"
                )

    return info


async def _send_status_idle(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """发送 agent 恢复 idle 状态。"""
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "agent_status",
            "data": {
                "agent_id": agent_id,
                "status": "idle",
                "session_id": session_id,
            },
        },
    )


def _reset_member_work_status(
    user_id: str, leader_id: str, member_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """成员 tool loop 结束后复位其持久化 work_status 为 idle。

    【状态治理】工作状态不再由 leader/roster/表写入——成员是否在工作的
    唯一权威是 ``_active_tasks``（实际 tool loop 登记）：``_process_member_
    message`` 真正开始 chat 前登记、结束时清除，前端经 WS ``agent_status``
    事件感知，teammates API 的 ``live_status`` 亦基于 ``_active_tasks`` 实时
    计算。故本函数保留为兼容占位（不再写任何持久化状态）。
    """
    return


async def _send_status_working(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """发送 agent 进入 working 状态。"""
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "agent_status",
            "data": {
                "agent_id": agent_id,
                "status": "working",
                "session_id": session_id,
            },
        },
    )


async def _send_text_as_agent(
    user_id: str, agent_id: str, text: str, session_id: str = DEFAULT_SESSION
) -> None:
    """将一段文本作为普通 agent 消息发送（用于错误提示等）。

    同时将这条 agent 回复写入对话历史，避免切换窗口后丢失。
    """
    _store_message(user_id, agent_id, "agent", text, session_id=session_id)
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "message",
            "id": agent_id,
            "role": "agent",
            "content": text,
            "timestamp": int(asyncio.get_event_loop().time() * 1000),
            "session_id": session_id,
        },
    )


# 活动日志写入阈值：流式文本累积达到该长度后 flush 一次到工作空间日志
_ACTIVITY_FLUSH_CHARS = 300


# 进行中的 agent 任务取消事件表：(user_id, agent_id, session_id) -> Event。
# 前端点击"停止"时，WS 端点 set 对应事件，chat 消费线程在每条产出后检查并退出。
_active_tasks: Dict[Tuple[str, str, str], threading.Event] = {}


def _register_active_task(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> threading.Event:
    """登记一个进行中的任务，返回取消事件。"""
    event = threading.Event()
    _active_tasks[(user_id, agent_id, session_id)] = event
    return event


def _cancel_active_task(
    user_id: str, agent_id: str, session_id: Optional[str] = None
) -> bool:
    """请求取消指定 agent/会话的进行中任务。

    :param session_id: 指定会话；None 时取消该 agent 第一个进行中任务
                       （兼容旧前端 stop 不携带 session_id）
    """
    if session_id is not None:
        event = _active_tasks.get((user_id, agent_id, session_id))
    else:
        event = next(
            (
                ev
                for (uid, aid, _sid), ev in _active_tasks.items()
                if uid == user_id and aid == agent_id
            ),
            None,
        )
    if event is None:
        return False
    event.set()
    return True


def _clear_active_task(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """任务结束时清除取消事件登记。"""
    _active_tasks.pop((user_id, agent_id, session_id), None)


def _is_agent_working(user_id: str, agent_id: str) -> bool:
    """该 agent 是否有任意会话处于进行中（teammates 状态展示用）。"""
    return any(
        uid == user_id and aid == agent_id
        for (uid, aid, _sid) in _active_tasks
    )


def _cancel_all_agent_tasks(
    user_id: str, agent_id: str
) -> List[Tuple[str, str, str]]:
    """取消指定 agent 的全部进行中任务（所有会话），返回已取消的键列表。

    与 ``_cancel_active_task``（单会话）不同，停止级联需要把 TOP agent 与
    其下全部成员**所有会话**的进行中任务一次性取消，避免只停当前窗口会话
    而其他会话的任务仍在跑。
    """
    cancelled: List[Tuple[str, str, str]] = []
    for (uid, aid, sid), event in list(_active_tasks.items()):
        if uid == user_id and aid == agent_id:
            event.set()
            cancelled.append((uid, aid, sid))
    return cancelled


def _reset_member_status_to_idle(
    user_id: str, top_id: str, member_id: str
) -> None:
    """（已废弃）成员工作状态复位占位。

    【状态治理】工作状态唯一权威是 ``_active_tasks``（实际 tool loop 登记），
    不再写入 team_members 表 / roster / team_tool 内存态。停止 = 取消
    ``_active_tasks`` 中的任务 + 清空 broker 队列；成员 tool loop 的 finally
    会 ``_clear_active_task`` 并推送 ``agent_status=idle``，前端/API 状态
    自然回到 idle。保留本函数仅为兼容调用方，不再写任何持久化状态。
    """
    return


async def _stop_agent_tree(
    user_id: str,
    agent_id: str,
    session_id: Optional[str] = None,
) -> Dict[str, Any]:
    """停止按钮级联：停止指定 agent（TOP 或成员）及其全部相关任务。

    若 ``agent_id`` 为 TOP agent（agent_store 可查）：
    - 取消 TOP 自身全部进行中任务（所有会话，不止当前会话）
    - 查出其全部成员（``team_members`` 表），逐一取消成员全部进行中任务
    - 清空 ``top_chat_broker`` 中该 TOP 的排队用户消息、``team_broker`` 中
      各成员的排队消息（防止队列里残留的消息在停止后把成员又拉起来工作）
    - 向前端推送 TOP 与全部成员的 ``agent_status=idle``，UI 立即停止标识
      （工作状态唯一权威是 ``_active_tasks``，不写入表/roster）

    若 ``agent_id`` 为成员（不在 agent_store）：
    - 仅取消该成员任务、清空其 broker 队列、复位 idle

    关于「立即中止」的边界（如实说明）：
    - API 调用：取消事件在流式分块间隙、下一轮调用发起前、429 重试等待期、
      限流等待期均被检查，因此**不会再发起新的 API 调用**；正在进行的流式
      响应在下一个 chunk 到达即中止。
    - 工具调用：每次 tool_call 执行前检查取消，**不再启动新工具**；但正在
      阻塞执行的同步工具（如长 terminal 命令）无法从外部强杀 Python 线程，
      需等其返回后循环在检查点退出（属正常边界，已写入活动日志提示）。

    :return: ``{"stopped": bool, "cancelled": [...], "members": [...]}``
    """
    cancelled: List[Tuple[str, str, str]] = []
    member_ids: List[str] = []

    # 判断是否为 TOP agent（agent_store 可查即 TOP）
    from data.agent_store import get_agent

    is_top = get_agent(user_id, agent_id) is not None

    # 1) 取消 agent 自身全部任务
    cancelled += _cancel_all_agent_tasks(user_id, agent_id)

    if is_top:
        # 2) 查出成员并取消其全部任务
        try:
            from data.team_store import get_members

            members = get_members(agent_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("停止级联读取成员失败: %s", exc)
            members = []
        member_ids = [m.get("id", "") for m in members if m.get("id")]
        for mid in member_ids:
            cancelled += _cancel_all_agent_tasks(user_id, mid)

        # 3) 清空排队消息：TOP 的用户消息 + 各成员的 leader 消息
        try:
            if state.top_chat_broker is not None:
                state.top_chat_broker.cancel_agent(user_id, agent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("停止级联清空 TOP 队列失败: %s", exc)
        if state.team_broker is not None:
            for mid in member_ids:
                try:
                    state.team_broker.cancel_agent(user_id, mid)
                except Exception as exc:  # noqa: BLE001
                    logger.warning("停止级联清空成员队列失败 %s: %s", mid, exc)

        # 4) 推送 idle：TOP + 全部成员。成员工作状态无需写表——tool loop 的
        #    finally 会 _clear_active_task（_active_tasks 为唯一权威），
        #    此处推送 idle 让前端 UI 立即停止标识。
        for mid in [agent_id] + member_ids:
            await state.ws_manager.send_message(
                user_id,
                {
                    "type": "agent_status",
                    "data": {
                        "agent_id": mid,
                        "status": "idle",
                        "session_id": session_id,
                    },
                },
            )
    else:
        # 成员：清空其 broker 队列 + 推送 idle
        if state.team_broker is not None:
            try:
                state.team_broker.cancel_agent(user_id, agent_id)
            except Exception as exc:  # noqa: BLE001
                logger.warning("停止级联清空成员队列失败 %s: %s", agent_id, exc)
        await state.ws_manager.send_message(
            user_id,
            {
                "type": "agent_status",
                "data": {
                    "agent_id": agent_id,
                    "status": "idle",
                    "session_id": session_id,
                },
            },
        )

    return {
        "stopped": bool(cancelled) or bool(member_ids),
        "cancelled": cancelled,
        "members": member_ids,
    }


def _clock_now() -> str:
    """返回 HH:MM:SS 时间戳，用于活动日志。"""
    return time.strftime("%H:%M:%S")


def _append_activity_log(workspace_id: str, message: str) -> None:
    """将一行活动日志追加写入 agent 工作空间的 ``.self/activity.log``。

    供 team leader 通过 ``view_member_log`` 查看成员文字输出，判断工作是否卡死。
    - 记录带时间戳，便于判断最后活动时间
    - 使用 base64 写入，避免特殊字符导致命令注入或转义问题
    """
    if not workspace_id:
        return
    try:
        import base64 as _b64

        b64 = _b64.b64encode(message.encode("utf-8")).decode("ascii")
        cmd = [
            "sh",
            "-c",
            "mkdir -p .self && echo '{}' | base64 -d >> .self/activity.log".format(
                b64
            ),
        ]
        state.docker_manager.exec_in_workspace(workspace_id, cmd)
    except Exception as exc:  # noqa: BLE001
        logger.warning("写入活动日志失败: %s", exc)


def _new_seg_id(agent_id: str) -> str:
    """生成一条段（文本消息/工具卡片）的唯一 id。"""
    return f"{agent_id}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"


async def _stream_agent_reply(
    user_id: str,
    agent_id: str,
    workspace_id: str,
    session: Any,
    llm_content: str,
    on_tool_turn: Optional[Any] = None,
    cancel_event: Optional[threading.Event] = None,
    silent: bool = False,
    session_id: str = DEFAULT_SESSION,
) -> Tuple[str, str]:
    """在后台线程中运行 chat 循环，并向前端实时推送进度事件。

    解决"工作期间其他 API 卡住"的问题：LLM 流式调用与工具执行为同步阻塞，
    若直接在主线程遍历会独占事件循环。这里把生成器消费放到独立线程
    （``asyncio.to_thread``），通过线程安全的 ``asyncio.Queue`` 把产出
    传递回事件循环，逐条推送以下 WS 事件：

    - ``agent_status``：由调用方负责发送 working/idle（本函数不发）。
    - ``text`` 产出：以"段"为单位，先发 ``msg_start`` 再逐块 ``msg_chunk``，
      段结束时发 ``msg_end``（每一次中间输出独立成一条消息）。
    - ``tool_call`` 产出：先发 ``tool_start``（含参数），工具执行完成后在
      同一产出内发 ``tool_end``（含结果），前端据此渲染可折叠卡片。
    - 取消：检测到 ``cancel_event`` 置位时提前退出，返回 cancelled。

    :param silent: 静默模式。为 True 时不向前端推送任何 WS 事件（文本段、
                   工具卡片、历史持久化均跳过），仅执行工具与写活动日志，
                   用于后台记忆更新阶段。
    :return: ``(full_text, status, last_text_id)``，status 为 ``"ok"`` /
             ``"cancelled"`` / ``"error"``；``last_text_id`` 为结束时仍打开的
             文本段 id（可能为 None），供调用方在确定 usage 后补发 ``msg_usage``。
    """
    loop = asyncio.get_running_loop()
    out_q: "asyncio.Queue[Dict[str, Any]]" = asyncio.Queue()

    def _consume() -> None:
        """线程内消费 chat 生成器，产出经线程安全方式回传事件循环。"""
        try:
            for item in session.chat(llm_content, on_tool_turn=on_tool_turn, cancel_event=cancel_event):
                if cancel_event is not None and cancel_event.is_set():
                    loop.call_soon_threadsafe(out_q.put_nowait, {"type": "cancelled"})
                    return
                loop.call_soon_threadsafe(out_q.put_nowait, item)
        except asyncio.CancelledError:
            loop.call_soon_threadsafe(out_q.put_nowait, {"type": "cancelled"})
        except _AskPaused:
            # AskUserQuestion 暂停：不视为错误，通知主循环置"已提问待答"
            loop.call_soon_threadsafe(
                out_q.put_nowait, {"type": "ask_paused"}
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("chat 消费线程异常")
            # 将 OpenAI 限流错误格式化为可读提示，避免前端展示原始异常串
            if isinstance(exc, RateLimitError):
                content = "请求被限流（429），请稍后重试。"
            else:
                content = str(exc)
            loop.call_soon_threadsafe(
                out_q.put_nowait, {"type": "error", "content": content}
            )
        finally:
            loop.call_soon_threadsafe(out_q.put_nowait, {"type": "done"})

    thread_task = asyncio.create_task(asyncio.to_thread(_consume))

    full_parts: List[str] = []
    text_parts: List[str] = []  # 当前文本段的累积内容
    text_id: Optional[str] = None
    # 最后一次工具调用摘要（纯 tool loop 无文字输出时，兜底为回复内容推送
    # 给上一级 leader，避免成员完成工作后 leader 收不到任何结果）
    last_tool_text = ""
    # thinking（推理）段累积：每段独立 id，收到非 thinking 产出时关闭并持久化
    thinking_parts: List[str] = []
    thinking_id: Optional[str] = None
    flush_buf = ""
    status = "ok"

    def _close_thinking() -> None:
        """结束当前 thinking 段（msg_end + 持久化 kind='thinking'）。"""
        nonlocal thinking_id, thinking_parts
        if thinking_id is None:
            return
        thinking_text = "".join(thinking_parts)
        if not silent:
            asyncio.ensure_future(
                state.ws_manager.send_message(
                    user_id,
                    {
                        "type": "msg_end",
                        "id": thinking_id,
                        "agent_id": agent_id,
                        "session_id": session_id,
                    },
                )
            )
        # 持久化 thinking 段（messages 表 kind='thinking'），历史重载后可见
        if (not silent) and thinking_text.strip():
            try:
                _store_message(
                    user_id, agent_id, "agent", thinking_text,
                    kind="thinking", session_id=session_id,
                )
            except Exception:  # noqa: BLE001
                pass
        thinking_id = None
        thinking_parts = []

    def _close_text() -> None:
        """结束当前文本段（中间输出独立成一条消息，结束时不带 usage）。

        中间文本段持久化到历史表，重启后可通过 get_history 恢复。
        """
        nonlocal text_id, text_parts
        if text_id is not None:
            if not silent:
                asyncio.ensure_future(
                    state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_end",
                            "id": text_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                        },
                    )
                )
            # 持久化中间文本段（非最终回复）；静默阶段不写入历史
            intermediate_text = "".join(text_parts)
            if (not silent) and intermediate_text.strip():
                try:
                    _store_message(
                        user_id, agent_id, "agent", intermediate_text,
                        session_id=session_id,
                    )
                except Exception:  # noqa: BLE001
                    pass
            text_id = None
            text_parts = []

    try:
        while True:
            item = await out_q.get()
            itype = item.get("type")
            if itype == "done":
                break
            if itype == "cancelled":
                status = "cancelled"
                break
            if itype == "error":
                status = "error"
                full_parts.append(item.get("content", ""))
                break
            if itype == "ask_paused":
                # AskUserQuestion 已提问，本轮暂停（agent 归闲，等用户作答后唤醒）
                _close_thinking()
                _close_text()
                status = "paused"
                if flush_buf and workspace_id:
                    _append_activity_log(workspace_id, f"[{_clock_now()}] {flush_buf}")
                    flush_buf = ""
                break
            if itype == "thinking":
                content = item.get("content", "")
                thinking_parts.append(content)
                if not silent:
                    if thinking_id is None:
                        thinking_id = _new_seg_id(agent_id)
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_start",
                                "id": thinking_id,
                                "role": "agent",
                                "kind": "thinking",
                                "agent_id": agent_id,
                                "session_id": session_id,
                            },
                        )
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_chunk",
                            "id": thinking_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "chunk": content,
                        },
                    )
                continue
            if itype == "text":
                # 文本段开始前关闭未完成的 thinking 段
                _close_thinking()
                content = item.get("content", "")
                full_parts.append(content)
                text_parts.append(content)
                if not silent:
                    if text_id is None:
                        text_id = _new_seg_id(agent_id)
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_start",
                                "id": text_id,
                                "role": "agent",
                                "agent_id": agent_id,
                                "session_id": session_id,
                            },
                        )
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_chunk",
                            "id": text_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "chunk": content,
                        },
                    )
                if workspace_id:
                    flush_buf += content
                    if len(flush_buf) >= _ACTIVITY_FLUSH_CHARS:
                        _append_activity_log(workspace_id, f"[{_clock_now()}] {flush_buf}")
                        flush_buf = ""
            elif itype == "tool_call":
                # 结束上一段文本与 thinking（中间输出独立成消息）
                _close_thinking()
                _close_text()
                name = item.get("name", "")
                args = item.get("arguments") or {}
                result = item.get("result", "")
                # 记录最后一次工具调用摘要（结果截断，避免超长）
                last_tool_text = f"[工具 {name}] {str(result)[:500]}"
                if workspace_id:
                    _append_activity_log(
                        workspace_id,
                        f"[{_clock_now()}] [tool] {name} args="
                        f"{str(args)[:200]} -> {str(result)[:150]}",
                    )
                flush_buf = ""
                if not silent:
                    tool_id = _new_seg_id(agent_id)
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "tool_start",
                            "id": tool_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "name": name,
                            "arguments": args,
                        },
                    )
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "tool_end",
                            "id": tool_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "name": name,
                            "result": str(result),
                        },
                    )
                    # 持久化工具调用到历史表；静默阶段不写入历史
                    try:
                        _store_message(
                            user_id, agent_id, "agent", "",
                            kind="tool",
                            tool_name=name,
                            tool_arguments=args if isinstance(args, dict) else {},
                            tool_result=str(result),
                            session_id=session_id,
                        )
                    except Exception:  # noqa: BLE001
                        pass

                    # 工具循环中持续推送 token 用量：本轮 LLM 调用已产生新的
                    # last_usage，立即同步给前端，让「上下文长度」统计在 tool 循环
                    # 中持续跟进，而非等最终回复结束才一次性更新。
                    if getattr(session, "last_usage", None):
                        _mc = getattr(session, "model_config", None)
                        mid_max = (
                            int(_mc.extra.get("max_seqlen", 8192))
                            if _mc is not None else 8192
                        )
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_usage",
                                "id": tool_id,
                                "agent_id": agent_id,
                                "session_id": session_id,
                                "usage": {**session.last_usage, "max_tokens": mid_max},
                            },
                        )
            else:
                # 未知产出类型，忽略
                continue
    finally:
        await thread_task
        # 结束未关闭的 thinking 段（msg_end + 持久化）
        _close_thinking()
        if flush_buf and workspace_id:
            _append_activity_log(workspace_id, f"[{_clock_now()}] {flush_buf}")

    # 结束时仍打开的文本段即最终回复，交由调用方补发 msg_usage
    last_text_id = text_id
    # 纯 tool loop 无文字输出兜底：status=ok 且无任何文本时，用最后一次
    # 工具调用摘要作为回复内容（_process_member_message 据此推送给 leader）。
    if (
        status == "ok"
        and not full_parts
        and last_tool_text
    ):
        full_parts.append(f"（本轮无文字输出，最后执行：{last_tool_text}）")
    return "".join(full_parts), status, last_text_id


async def _process_member_message(
    payload: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """处理投递给成员的消息（leader 通过 team send_message/assign_task 触发）。

    每个成员由 broker 的独立 worker 串行调用本函数。消息不在双方的
    tool_call / token 生成执行中途打断，而是在当前消息的 tool_call 间隙
    通过 ``on_tool_turn`` 回调切入处理新消息（append 到上下文供下一轮处理）。
    成员处理过程中的文字输出写入其工作空间活动日志，leader 可通过
    ``team view_member_log`` 查看判断进度。

    :param payload: 投递负载，含 user_id / agent_id / workspace_id /
                    model_id / content
    :param queue: 该成员的消息队列（broker worker 传入），用于在 tool_call
                  间隙切入新消息
    """
    user_id = payload.get("user_id", "")
    agent_id = payload.get("agent_id", "")
    workspace_id = payload.get("workspace_id", "")
    model_id = payload.get("model_id", "")
    content = payload.get("content", "")
    leader_id = payload.get("leader_id", "")
    top_agent_id = payload.get("top_agent_id", "")
    session_id = payload.get("session_id", DEFAULT_SESSION)
    if not agent_id or not content:
        return

    model_config = state.model_configs.get(model_id)
    if model_config is None and not model_id and top_agent_id:
        # 空 model_id 自动回退所属 TOP 的模型：建队默认继承 TOP 模型，
        # 此处兼容历史空 model_id 成员（无论从哪条投递路径进入，都不因
        # 模型缺失丢消息）。
        try:
            top_rec = get_agent(user_id, top_agent_id) or {}
            top_model = top_rec.get("model_id") or ""
            if top_model and top_model in state.model_configs:
                model_config = state.model_configs[top_model]
                model_id = top_model
        except Exception as exc:  # noqa: BLE001
            logger.warning("成员空 model_id 回退 TOP 模型失败: %s", exc)
    if model_config is None:
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [error] 成员模型不存在: {model_id!r}，"
            "消息未处理（leader 需先用 team update_member 为该成员设置 model_id）",
        )
        # 明确回传错误给 leader，避免消息被静默丢弃（表现为"成员没收到"）
        if leader_id:
            try:
                _dispatch_agent_message(
                    user_id,
                    [leader_id],
                    f"[成员 {agent_id} 无法处理消息] 未配置 LLM 模型"
                    f"（model_id={model_id!r}），消息已丢弃：{content[:120]}。"
                    "请用 team update_member 为该成员设置 model_id 后重试。",
                    source_agent_id=agent_id,
                    top_agent_id=top_agent_id or leader_id,
                    extra={"auto_reply": True, "session_id": session_id},
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("回传成员模型缺失错误失败: %s", exc)
        return

    # 保存成员收到的消息到历史（teammates 进度页可加载显示）
    _store_message(user_id, agent_id, "user", content, session_id=session_id)

    # 构建成员会话（normal 复用缓存累积上下文）
    # 系统提示词 9 章节全量注入（Spec 索引/已选 Spec/.self 文档/成员拓扑）
    member_system_prompt = payload.get("system_prompt", "")
    session = get_session(user_id, agent_id, session_id)
    if session is None:
        # 本地模式下读 .self 文件经反向 WS（阻塞），必须放入线程池避免死锁事件循环
        extra_info = await asyncio.to_thread(
            _build_workspace_extra_info,
            workspace_id, member_system_prompt=member_system_prompt,
            user_id=user_id, agent_id=top_agent_id or agent_id,
            local_executor=state.local_executor,
        )
        enhanced_prompt = await asyncio.to_thread(
            _build_agent_system_prompt,
            workspace_id,
            member_system_prompt=member_system_prompt,
            user_id=user_id,
            agent_id=agent_id,
            top_agent_id=top_agent_id,
            session_id=session_id,
            extra_info=extra_info,
        )
        session = AgentLLMSession(
            model_config=model_config,
            workspace_id=workspace_id,
            system_prompt=enhanced_prompt,
            user_id=user_id,
            agent_id=agent_id,
        )
        session.workspace_extra_info = extra_info
        set_session(user_id, agent_id, session, session_id)
        await _register_tools(session, agent_id, user_id,
                              leader_id=leader_id,
                              top_agent_id=top_agent_id,
                              member_system_prompt=member_system_prompt,
                              session_id=session_id,
                              is_member=True)
        restored = load_context(user_id, agent_id, session_id)
        if restored:
            session.context = restored

    _append_activity_log(
        workspace_id,
        f"[{_clock_now()}] [start(成员)] 收到 leader 消息: {content[:120]}",
    )

    def _pick_incoming() -> Optional[str]:
        """在 tool_call 间隙从队列切入 leader 发来的新消息。"""
        if queue is None:
            return None
        try:
            incoming = queue.get_nowait()
        except queue.Empty:
            return None
        # 跨会话隔离：只切入当前会话的消息；其他会话的消息放回队列，
        # 待当前消息处理完后由 worker 作为独立消息继续处理（不串入本会话上下文）
        incoming_session = incoming.get("session_id", DEFAULT_SESSION)
        if incoming_session != session_id:
            queue.put_nowait(incoming)
            return None
        incoming_content = incoming.get("content", "")
        if not incoming_content:
            return None
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [切入] 收到 leader 新消息: "
            f"{incoming_content[:120]}",
        )
        return incoming_content

    # 登记任务并通知用户该成员进入 working 状态（teammates 窗口可见）
    cancel_event = _register_active_task(user_id, agent_id, session_id)
    await state.ws_manager.send_message(
        user_id,
        {"type": "agent_status", "data": {"agent_id": agent_id, "status": "working",
                                           "session_id": session_id}},
    )
    try:
        full_reply, _status, _last = await _stream_agent_reply(
            user_id,
            agent_id,
            workspace_id,
            session,
            content,
            on_tool_turn=_pick_incoming,
            cancel_event=cancel_event,
            session_id=session_id,
        )
        # 关闭最终文本段（无 usage）
        if _last:
            await state.ws_manager.send_message(
                user_id,
                {"type": "msg_end", "id": _last, "agent_id": agent_id,
                 "usage": None, "session_id": session_id},
            )
        # 保存成员回复到历史（teammates 进度页可加载显示）
        if full_reply:
            _store_message(user_id, agent_id, "agent", full_reply,
                           session_id=session_id)
        _append_activity_log(workspace_id, f"[{_clock_now()}] [done(成员)] 回复完成")
        # 成员工具循环最后一次回复的 content 自动回发对应 leader
        if full_reply and leader_id:
            try:
                _dispatch_agent_message(
                    user_id,
                    [leader_id],
                    f"[成员 {agent_id} 完成回复] {full_reply}",
                    source_agent_id=agent_id,
                    top_agent_id=top_agent_id or leader_id,
                    extra={"auto_reply": True, "session_id": session_id},
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("成员回复回传 leader 失败: %s", exc)
    except Exception as exc:  # noqa: BLE001
        logger.exception("成员消息处理失败: %s", exc)
        _append_activity_log(
            workspace_id, f"[{_clock_now()}] [error] 成员处理失败: {exc}"
        )
    finally:
        # 状态治理：工作状态唯一权威是 _active_tasks——此处清除任务登记并
        # 推送 idle，前端/API 状态立即回到空闲；不再写 roster/表/内存态。
        _clear_active_task(user_id, agent_id, session_id)
        await _send_status_idle(user_id, agent_id, session_id)

    # 持久化上下文（成员回复已实时写入工作空间活动日志，供 leader 查看）
    try:
        save_context(user_id, agent_id, session.context, session_id=session_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("成员上下文持久化失败: %s", exc)


async def _broker_process_user_message(
    payload: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """顶部 agent 用户消息 broker 处理函数（checklist 7）。

    适配 TeamMessageBroker 的 ``(payload, queue)`` 签名，转发给真正的
    处理函数 ``_handle_user_message``。
    """
    user_id = payload.get("user_id", "")
    await _handle_user_message(user_id, payload, queue)


def _find_roster_member(
    user_id: str, roster_owner_id: str, member_id: str
) -> Optional[Dict[str, Any]]:
    """从指定 agent 的成员名单中查找成员（team 跨模式）。

    优先读 ``team_members`` 表（P4 建队后的权威名单，cloud/local/ssh 一致），
    表为空（未建队/旧数据）时回退解析工作空间 ``.self/team_roster.md``。
    成员记录补充 system_prompt 字段（表中有、文件视图无），供投递时使用。
    """
    if not roster_owner_id or not member_id:
        return None

    # 权威来源：team_store（teams/team_members 表）
    from data.team_store import get_member as get_team_member

    try:
        db_member = get_team_member(roster_owner_id, member_id)
    except Exception:  # noqa: BLE001
        db_member = None
    if db_member is not None:
        return {
            "id": db_member["id"],
            "name": db_member["name"],
            "model_id": db_member.get("model_id", ""),
            "level": db_member.get("level", 1),
            "created_at": db_member.get("created_at", ""),
            "work_status": db_member.get("work_status", "idle"),
            "comment": db_member.get("comment", ""),
            "role": db_member.get("role", ""),
            "duty": db_member.get("duty", ""),
            "system_prompt": db_member.get("system_prompt", ""),
            "workspace_id": db_member["id"],
        }

    # 回退：工作空间 roster 文件（未走 P4 建队的历史数据）
    owner = get_agent(user_id, roster_owner_id) or {}
    owner_ws = owner.get("workspace_id") or roster_owner_id
    # 本地模式下经反向 WS 读用户本机的 .self/team_roster.md（与 help 注入同路径）
    _io = _get_workspace_io(user_id, roster_owner_id)
    try:
        r = run_io(_io.read_file(owner_ws, ".self/team_roster.md"))
        roster_content = "" if r.get("error") else (r.get("content", "") or "")
    except Exception:  # noqa: BLE001
        roster_content = _read_workspace_file(owner_ws, ".self/team_roster.md")
    members = _parse_roster_table(roster_content)
    for m in members:
        if m.get("id") == member_id:
            return m
    return None


def _dispatch_agent_message(
    user_id: str,
    target_ids: Any,
    content: str,
    source_agent_id: str = "",
    top_agent_id: str = "",
    system_prompt: str = "",
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """统一消息发送 API：对本顶部 agent 旗下任意 agent_id 发送消息（一对多）。

    User-Agent 与 Agent-Agent 消息都收敛到本入口（顶部 agent 走
    ``state.top_chat_broker``，团队成员走 ``state.team_broker``），统一做：
    - 团队隔离：仅允许发送给与本 agent 有关系的对象（上级 leader / 直属成员），
      不同顶部 agent 旗下互不可见、不可达；
    - update memory 锁：目标正处于记忆维护时拒绝投递；
    - 目标解析：顶部 agent 经 agent_store 查询；成员经发送方 roster 解析。
    """
    if isinstance(target_ids, str):
        target_ids = [target_ids]
    if not target_ids or not content:
        return {"error": "目标 ID 或消息内容不能为空"}

    owner_top = top_agent_id or source_agent_id or ""
    sent: List[str] = []
    rejected: List[str] = []
    for target_id in target_ids:
        if not target_id or target_id == source_agent_id:
            rejected.append(target_id)
            continue

        # 1) 目标为顶部 agent（agent_store 中可查）
        target_agent = get_agent(user_id, target_id)
        if target_agent is not None:
            # 团队隔离：
            # - 成员向其他顶部 agent 发送被拒绝（跨顶部顶层通信仅限 TOP agent 之间）；
            # - TOP agent（source == owner_top）可向任意同用户 TOP 寻址（top-to-top）。
            # 目标经 get_agent(user_id) 查询，天然限同用户（跨用户不开放）。
            if (
                source_agent_id
                and owner_top
                and source_agent_id != owner_top
                and target_id != owner_top
            ):
                rejected.append(target_id)
                continue
            payload = {
                "user_id": user_id,
                "agent_id": target_id,
                "workspace_id": target_agent.get("workspace_id") or target_id,
                "model_id": target_agent.get("model_id") or "",
                "system_prompt": system_prompt,
                "leader_id": "",
                "top_agent_id": target_id,
                "content": content,
            }
            if extra:
                payload.update(extra)
            dispatched = False
            if state.top_chat_broker is not None:
                dispatched = state.top_chat_broker.dispatch(
                    (user_id, target_id), payload
                )
            if dispatched:
                sent.append(target_id)
            else:
                rejected.append(target_id)
            continue

        # 2) 目标为成员：从发送方（或所属顶部 agent）roster 查找直属成员
        member = _find_roster_member(
            user_id, top_agent_id or source_agent_id, target_id
        )
        if member is None:
            rejected.append(target_id)
            continue
        # 成员 model_id 为空时回退所属 TOP 的模型：建队默认继承 TOP 模型，
        # 此处兼容历史空 model_id 成员，避免消息被 _process_member_message
        # 因"模型不存在"静默丢弃（成员"收不到"消息）。
        member_model = member.get("model_id") or ""
        if not member_model and owner_top:
            try:
                top_rec = get_agent(user_id, owner_top) or {}
                member_model = top_rec.get("model_id") or ""
            except Exception:  # noqa: BLE001
                member_model = ""
        payload = {
            "user_id": user_id,
            "agent_id": target_id,
            "workspace_id": member.get("workspace_id") or target_id,
            "model_id": member_model,
            "system_prompt": member.get("system_prompt", "") or system_prompt,
            "leader_id": source_agent_id or top_agent_id,
            "top_agent_id": owner_top,
            "content": content,
        }
        if extra:
            payload.update(extra)
        dispatched = False
        if state.team_broker is not None:
            dispatched = state.team_broker.dispatch((user_id, target_id), payload)
        if dispatched:
            sent.append(target_id)
        else:
            rejected.append(target_id)

    if not sent:
        return {"status": "error", "sent": sent, "rejected": rejected}
    return {
        "status": "sent" if not rejected else "partial",
        "sent": sent,
        "rejected": rejected,
    }


async def _dispatch_user_message(user_id: str, data: Dict[str, Any]) -> None:
    """投递顶部 agent 用户消息（收敛到统一消息 API）。

    - agent idle：broker 立即新建 worker 消费消息，等价于直接发送。
    - agent working：消息进入该 agent 的队列，在当前 tool_call 间隙切入。
    """
    agent_id = data.get("agent_id", "")
    if not agent_id:
        asyncio.create_task(_handle_user_message(user_id, data))
        return
    content = data.get("content", "") or ""
    if not content and data.get("attachments"):
        content = "[附件消息]"

    # 本地模式下 _dispatch_agent_message 内部可能经反向 WS 读 roster（阻塞），
    # 放入线程池执行，避免在事件循环线程内空等（阻塞期间其他请求全部卡住）。
    result = await asyncio.to_thread(
        _dispatch_agent_message,
        user_id, [agent_id], content,
        "",
        agent_id,
        "",
        dict(data),
    )
    if result.get("status") == "error":
        asyncio.create_task(_handle_user_message(user_id, data))


async def resume_after_answer(
    user_id: str,
    agent_id: str,
    top_agent_id: str,
    session_id: str,
    answer: str,
    is_member: bool,
) -> None:
    """AskUserQuestion 作答后的唤醒：注入答案并重新触发该 agent 执行。

    agent 提问后暂停归闲、上下文已持久化（含 assistant tool_calls + 占位
    tool 结果）。这里把答案作为一条"用户回答"消息经既有 broker/消息派发
    通道重新投递给该 agent，使其续跑原任务。

    - 成员：经 ``_dispatch_agent_message``（team_broker）分发，需
      ``top_agent_id`` 解析 roster。
    - 主 agent：经 ``_dispatch_user_message``（top_chat_broker）分发。
    """
    content = f"[AskUserQuestion 用户回答] {answer}"
    try:
        if is_member:
            await asyncio.to_thread(
                _dispatch_agent_message,
                user_id, [agent_id], content,
                top_agent_id, top_agent_id, "",
                {"session_id": session_id},
            )
        else:
            await _dispatch_user_message(user_id, {
                "agent_id": agent_id,
                "session_id": session_id,
                "content": content,
            })
    except Exception as exc:  # noqa: BLE001
        logger.exception("唤醒 agent 失败: %s agent=%s", exc, agent_id)


async def _handle_user_message(
    user_id: str, data: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """处理用户消息：调用 LLM 并流式推送回复。

    流程：
    1. 校验参数并发送 agent_status（thinking）
    2. 选择模型配置（普通/无限上下文）
    3. 发送 stream_start（流式开始）
    4. 调用 LLM，分块发送 stream_chunk
    5. 发送 stream_end（流式结束）
    6. 恢复 agent_status（idle）

    LLM 调用失败（如未配置 API Key、网络错误）时，会向前端发送错误提示消息。

    :param queue: 该 agent 的用户消息队列（checklist 7）。当 agent 处于
                  working 状态时，新到的用户消息会进入队列，并在当前
                  tool_call 处理完、进入下一轮 LLM 调用前通过 ``on_tool_turn``
                  回调切入（插在工具结果之后）。idle 时消息立即被消费，
                  等价于直接发送。
    """
    agent_id = data.get("agent_id", "")
    content = data.get("content", "")
    session_id = data.get("session_id", DEFAULT_SESSION)

    if not agent_id or (not content and not data.get("attachments")):
        await _send_text_as_agent(user_id, agent_id or "unknown", "消息内容或 agent_id 不能为空")
        return

    # 确保会话元数据存在（多会话并行），更新访问时间并用首条消息生成标题
    create_session(user_id, agent_id, session_id=session_id)
    touch_session(user_id, session_id)
    update_session_title_from_first_message(user_id, agent_id, session_id, content)

    # 读取用户上传的附件路径（写入工作空间在获取 agent/workspace 后进行）
    attachments = data.get("attachments") or []
    llm_content = content

    # 保存用户消息到历史
    _store_message(user_id, agent_id, "user", content, session_id=session_id)

    # 获取模型配置
    if not state.model_configs:
        await _send_text_as_agent(user_id, agent_id, "后端未配置任何 LLM 模型", session_id=session_id)
        await _send_status_idle(user_id, agent_id, session_id)
        return

    # 根据 agent 绑定的模型选择模型配置
    agent = get_agent(user_id, agent_id)
    model_id = agent.get("model_id") if agent else None
    model_config = state.model_configs.get(model_id) if model_id else None
    # agent 的独立工作空间（旧数据回填为 agent 自身 id）
    workspace_id = agent.get("workspace_id") if agent else None
    if not workspace_id:
        workspace_id = agent_id if agent else "top"

    # 上传附件到工作空间 .input/yyyymmdd/，仅将路径告知 LLM
    uploaded_paths = _upload_attachments(workspace_id, attachments)
    attachments_prompt = _build_attachments_prompt(uploaded_paths)
    if attachments_prompt:
        llm_content = f"{llm_content}\n\n{attachments_prompt}" if llm_content else attachments_prompt

    # 兜底：agent 不存在或模型已删除时，回退到第一个配置
    if model_config is None:
        model_config = next(iter(state.model_configs.values()))

    if not model_config.api_key:
        await _send_text_as_agent(
            user_id,
            agent_id,
            f"模型 {model_config.name} 未配置 API Key，请在 server/configs/models/*.yaml 中配置",
            session_id=session_id,
        )
        await _send_status_idle(user_id, agent_id, session_id)
        return

    # 登记进行中的任务（供"停止"按钮取消）
    cancel_event = _register_active_task(user_id, agent_id, session_id)

    # 通知前端 agent 进入 working 状态
    await _send_status_working(user_id, agent_id, session_id)

    # 初始化变量，确保 finally 块中可访问
    session = None
    full_reply = ""
    last_text_id = None
    try:
        # normal LLM：按 (user_id, agent_id, session_id) 复用会话，使上下文跨消息累积
        session = get_session(user_id, agent_id, session_id)
        if session is None:
            # 本地模式下 _build_workspace_extra_info 经反向 WS 读 .self 文件（阻塞），
            # 必须放入线程池执行：否则 local_executor.request 会在事件循环线程内
            # 调用 run_coroutine_threadsafe 发送 WS 消息，但事件循环被自身阻塞，
            # send_message 永远不会被调度执行 → 死锁 ~120s/文件。
            extra_info = await asyncio.to_thread(
                _build_workspace_extra_info,
                workspace_id, user_id=user_id, agent_id=agent_id,
                local_executor=state.local_executor,
            )
            # 系统提示词 9 章节全量注入（Spec 索引/已选 Spec/.self 文档/成员拓扑）
            enhanced_prompt = await asyncio.to_thread(
                _build_agent_system_prompt,
                workspace_id,
                user_id=user_id,
                agent_id=agent_id,
                top_agent_id=agent_id,
                session_id=session_id,
                extra_info=extra_info,
            )
            session = AgentLLMSession(
                model_config=model_config,
                workspace_id=workspace_id,
                system_prompt=enhanced_prompt,
                user_id=user_id,
                agent_id=agent_id,
            )
            session.workspace_extra_info = extra_info
            set_session(user_id, agent_id, session, session_id)
            await _register_tools(session, agent_id, user_id,
                                  top_agent_id=agent_id,
                                  session_id=session_id)
            # 首次创建时从数据库恢复上下文（重启后重建会话）
            restored = load_context(user_id, agent_id, session_id)
            if restored:
                session.context = restored

        # 活动日志：记录本次对话开始，供 leader 判断是否卡死
        if workspace_id:
            _append_activity_log(
                workspace_id,
                f"[{_clock_now()}] [start] 收到输入: {llm_content[:120]}",
            )

        def _pick_incoming() -> Optional[str]:
            """在 tool_call 间隙从队列切入用户新发的消息（checklist 7）。

            仅在 agent 处于 working 状态时调用：当前消息处理到 tool_call 间隙，
            从队列取出用户新消息，插到工具结果之后供下一轮 LLM 处理。

            跨会话隔离：只切入当前会话的消息；其他会话的消息放回队列，
            待当前消息处理完后由 worker 作为独立消息继续处理（不串入本会话上下文）。
            """
            if queue is None:
                return None
            try:
                incoming = queue.get_nowait()
            except queue.Empty:
                return None
            incoming_session = incoming.get("session_id", DEFAULT_SESSION)
            if incoming_session != session_id:
                queue.put_nowait(incoming)
                return None
            incoming_content = incoming.get("content", "")
            if not incoming_content:
                return None
            if workspace_id:
                _append_activity_log(
                    workspace_id,
                    f"[{_clock_now()}] [切入] 收到用户新消息: "
                    f"{incoming_content[:120]}",
                )
            return incoming_content

        # SFT 数据收集：记录该轮处理前的上下文基线（仅开启数据收集期间有效，
        # 内部按开关过滤；含 CoT 的完整 context 在对话结束后与基线求 diff）
        context_before = list(session.context) if session is not None else []

        # 在后台线程运行 chat 循环，实时推送中间输出与工具调用
        full_reply, stream_status, last_text_id = await _stream_agent_reply(
            user_id,
            agent_id,
            workspace_id,
            session,
            llm_content,
            on_tool_turn=_pick_incoming,
            cancel_event=cancel_event,
            session_id=session_id,
        )

        if stream_status == "cancelled":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [stopped] 已停止"
                )
        elif stream_status == "paused":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [wait] 已提问，等待用户回答"
                )
        elif stream_status == "error":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [error] LLM 请求失败: {full_reply}"
                )
        else:
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [done] 回复完成"
                )
        # 对话结束后将上下文持久化到数据库（重启后恢复）
        if session is not None:
            save_context(user_id, agent_id, session.context, session_id=session_id)
            # SFT 数据收集：仅开启期间生效；把本轮新增消息（含 CoT）作为
            # diff 累加到该会话快照。带 try 避免收集异常影响主流程。
            try:
                collect_sft_turn(
                    user_id, agent_id, session_id,
                    context_before, session.context,
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("SFT 收集失败: %s", exc)
    except Exception as exc:  # noqa: BLE001
        await _send_text_as_agent(user_id, agent_id, f"LLM 请求失败: {exc}", session_id=session_id)
        full_reply = f"LLM 请求失败: {exc}"
        stream_status = "error"
        last_text_id = None
        if workspace_id:
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] [error] LLM 请求失败: {exc}"
            )
    finally:
        # 计算 token 用量
        usage_payload = None
        if session is not None and getattr(session, "last_usage", None):
            max_tokens = int(model_config.extra.get("max_seqlen", 8192))
            usage_payload = {**session.last_usage, "max_tokens": max_tokens}

        # 若最终文本段仍打开，补发 msg_end（附带 usage）
        if last_text_id:
            await state.ws_manager.send_message(
                user_id,
                {
                    "type": "msg_end",
                    "id": last_text_id,
                    "agent_id": agent_id,
                    "usage": usage_payload,
                    "session_id": session_id,
                },
            )

        # 保存 agent 回复到历史（附带 token 用量，便于切换 agent 后恢复显示）
        if full_reply:
            _store_message(
                user_id,
                agent_id,
                "agent",
                full_reply,
                usage=usage_payload,
                session_id=session_id,
            )

        # 恢复 idle 状态并清除任务登记
        _clear_active_task(user_id, agent_id, session_id)
        await _send_status_idle(user_id, agent_id, session_id)


def _parse_roster_table(content: str) -> List[Dict[str, Any]]:
    """解析成员管理表 markdown 表格，返回成员字典列表。

    表格列：ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | ...
    """
    members: List[Dict[str, Any]] = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        if "ID" in line and "名称" in line:
            continue
        if "---" in line.replace("|", ""):
            continue
        parts = [p.strip() for p in line.strip("|").split("|")]
        if len(parts) < 7:
            continue
        try:
            level = int(parts[3]) if parts[3].isdigit() else 0
        except (ValueError, IndexError):
            level = 0
        member_id = parts[0]
        if not member_id:
            continue
        members.append(
            {
                "id": member_id,
                "name": parts[1],
                "model_id": parts[2],
                "level": level,
                "created_at": parts[4],
                "work_status": parts[5],
                "comment": parts[6],
                # member_id 同时作为 workspace_id（create_workspace 的约定）
                "workspace_id": member_id,
            }
        )
    return members
