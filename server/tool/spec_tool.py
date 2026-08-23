"""内置 spec 工具 - Spec 检索/选择/读取/创建/列索引/更新。

Spec = 任务型规范文件（Markdown，含 front matter + 工作流/规范/注意事项三段）。
- 内置 4 个（easy-task/complex-task/hard-task/team-meeting）为服务端模板，置顶不可删；
- 自定义 Spec 落盘到 ``workspace/<agent id>/spec/<id>.md``，元数据索引在
  ``specs`` 表（经 data.spec_store）。

动作：
- ``search``：语义检索（复用 Embed 对 title/description/when 比对，不可用时
  回退关键词），返回 id/task_type/title/when 摘要。
- ``select``：多选挂 hook（写 session ``selected_spec_ids``），实际注入发生在
  下次重构 context；立即使用请用 ``read`` 取全文进对话上下文。
- ``read``：返回 Spec 全文（内置模板 / 自定义文件）。
- ``list``：列出全部 Spec 索引（内置置顶）。
- ``create``：创建自定义 Spec（内容本体落盘到 workspace spec/ + 建索引）。
- ``update``：更新自定义 Spec（重写文件 + 更新索引）。
"""
import json
import logging
import os
import re
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from data.spec_store import (
    BUILTIN_SPEC_IDS,
    create_spec as store_create_spec,
    delete_spec as store_delete_spec,
    get_spec as store_get_spec,
    list_specs as store_list_specs,
    search_specs as store_search_specs,
    update_spec as store_update_spec,
)
from data.session_store import get_selected_spec_ids, set_selected_spec_ids
from io_.workspace_io import WorkspaceIO, run_io

logger = logging.getLogger(__name__)

# 内置 Spec 模板目录（服务端）
_BUILTIN_DIR = Path(__file__).resolve().parent / "spec" / "builtin"

# 自定义 Spec 在 agent 工作空间下的存放目录
SPEC_DIR = "spec"


def _safe_spec_id(value: str) -> str:
    """把任意输入规范化为安全 spec id（小写字母数字与连字符）。"""
    s = str(value or "").strip().lower()
    s = re.sub(r"[^a-z0-9\-]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    return s or f"spec-{int(time.time())}"


class SpecTool:
    """spec 内置工具：search/select/read/list/create/update。"""

    def __init__(
        self,
        io: WorkspaceIO,
        workspace_id: str,
        user_id: str = "",
        agent_id: str = "",
        session_id: str = "",
    ) -> None:
        self.io = io
        self.workspace_id = workspace_id
        self.user_id = user_id
        self.agent_id = agent_id
        self.session_id = session_id
        # 本会话已 read 过的 Spec id（select 前置校验：select 前必须先 read）。
        # 实例按会话创建，随会话生命周期存活；compact/重建会话后需重新 read。
        self._read_spec_ids: set = set()

    # ------------------------------------------------------------------
    # 工具定义
    # ------------------------------------------------------------------
    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义（含 7 需求维度量化）。"""
        return {
            "type": "function",
            "function": {
                "name": "spec",
                "description": (
                    "[任务型规范（Spec）检索/选择/沉淀] | "
                    "贡献维度: 任务管理（把任务经验沉淀为可复用规范，指导后续任务）"
                    " + 上下文获取（检索/读取历史任务规范）\n"
                    "何时使用: 任务开始前检索是否已有对应 Spec；任务完成前沉淀新 Spec；"
                    "用户/本会话已选 Spec 需读全文时\n"
                    "何时不用: 无。**必须调用**，即使单文件修改也必须先 **read 并 select** easy spec 再开始任务\n"
                    "前置依赖: 在搜索更多 spec 前必须先从四个内置基础 spec 中选择一个或多个\n"
                    "动作: search(语义检索) / list(索引) / read(全文) / "
                    "select(多选挂 hook) / create(创建) / update(更新)"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": ["search", "list", "read", "select", "create", "update"],
                            "description": "要执行的动作。**在使用 select 前必须先 read 对应 spec**，select 之后，旧的 spec_id 会被新的 spec_id 覆盖",
                        },
                        "query": {
                            "type": "string",
                            "description": "search 用：任务描述/关键词（自然语言）",
                        },
                        "spec_ids": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "select 用：要挂 hook 的 Spec id 列表（多选）。"
                                            "**传空数组 [] 表示取消全部选择**；"
                                            "传非空列表会整体替换当前已选集合。"
                                            "列表内的 Spec id 会自动去重",
                        },
                        "spec_id": {
                            "type": "string",
                            "description": "read/update 用：目标 Spec id",
                        },
                        "title": {
                            "type": "string",
                            "description": "create/update 用：Spec 标题",
                        },
                        "task_type": {
                            "type": "string",
                            "enum": ["easy", "complex", "hard", "custom"],
                            "description": "create/update 用：任务类型",
                        },
                        "description": {
                            "type": "string",
                            "description": "create/update 用：一句话描述（供索引与检索）",
                        },
                        "when": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "create/update 用：适用条件列表",
                        },
                        "workflow": {
                            "type": "string",
                            "description": "create/update 用：工作流（Markdown）",
                        },
                        "rules": {
                            "type": "string",
                            "description": "create/update 用：该类任务规范（Markdown）",
                        },
                        "notes": {
                            "type": "string",
                            "description": "create/update 用：注意事项（Markdown）",
                        },
                    },
                    "required": ["action"],
                },
            },
        }

    # ------------------------------------------------------------------
    # 动作分发
    # ------------------------------------------------------------------
    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 spec 动作。"""
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}
        action = str(arguments.get("action", "")).strip()
        if action == "search":
            return self._action_search(arguments)
        if action == "list":
            return self._action_list(arguments)
        if action == "read":
            return self._action_read(arguments)
        if action == "select":
            return self._action_select(arguments)
        if action == "create":
            return self._action_create(arguments)
        if action == "update":
            return self._action_update(arguments)
        return {"error": f"未知 spec 动作: {action}（应为 search/list/read/select/create/update）"}

    # ------------------------------------------------------------------
    # 会话级 selected spec 状态（供工具返回注入约束模型）
    # ------------------------------------------------------------------
    def current_status_text(self) -> str:
        """生成本会话 ``selected spec`` 状态文案（供工具返回注入，督促挂 Spec）。

        三态：
        - 未选择任何 Spec：``- "[Warning]spec 未选择"``
        - 已选但**无**内置基础 Spec（easy/complex/hard/team-meeting）：
          ``- "[Info]已选择：[<id0>, ][Warning]至少选择一个内置 spec"``
        - 正常（含至少一个内置 Spec）：
          ``- "[Info]已选择：[<id0>, ]"``

        每个 Spec 标注是否为内置（``(内置)`` / ``(自定义)``），
        让模型明确"内置基础 Spec"与"自定义 Spec"的区别。
        """
        selected: List[str] = []
        if self.user_id and self.session_id:
            try:
                selected = get_selected_spec_ids(self.user_id, self.session_id)
            except Exception as exc:  # noqa: BLE001
                logger.warning("读取已选 Spec 失败: %s", exc)
                selected = []
        if not selected:
            return '- "[Warning]spec 未选择"'
        labeled: List[str] = []
        has_builtin = False
        for sid in selected:
            is_builtin = sid in BUILTIN_SPEC_IDS
            if is_builtin:
                has_builtin = True
            labeled.append(f"{sid}({'内置' if is_builtin else '自定义'})")
        joined = ", ".join(labeled)
        if not has_builtin:
            return (
                f'- "[Info]已选择：[{joined}，]'
                '[Warning]至少选择一个内置 spec"'
            )
        return f'- "[Info]已选择：[{joined}，]'

    # ------------------------------------------------------------------
    # 具体动作
    # ------------------------------------------------------------------
    def _action_search(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        query = str(arguments.get("query", "")).strip()
        if not query:
            return {"error": "search 需要 query（任务描述/关键词）"}
        limit = 10
        try:
            results = store_search_specs(query, agent_id=self.agent_id or None, limit=limit)
        except Exception as exc:  # noqa: BLE001
            logger.warning("spec search 失败: %s", exc)
            results = store_list_specs(agent_id=self.agent_id or None)
        items = []
        for s in results:
            items.append({
                "id": s["id"],
                "task_type": s["task_type"],
                "title": s["title"],
                "description": s["description"],
                "when": s["when"],
                "pinned": s["pinned"],
                # 标注是否为内置模板（easy/complex/hard/team-meeting），
                # 供模型区分内置（可 select 挂 hook）与自定义 Spec
                "builtin": bool(s.get("builtin", s["id"] in BUILTIN_SPEC_IDS)),
            })
        return {"action": "search", "query": query, "count": len(items), "specs": items}

    def _action_list(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        results = store_list_specs(agent_id=self.agent_id or None)
        items = [
            {
                "id": s["id"],
                "task_type": s["task_type"],
                "title": s["title"],
                "description": s["description"],
                "when": s["when"],
                "pinned": s["pinned"],
                # 内置模板标注（BUILTIN_SPEC_IDS），自定义 Spec 为 False
                "builtin": bool(s.get("builtin", s["id"] in BUILTIN_SPEC_IDS)),
            }
            for s in results
        ]
        # 附带当前会话已选 Spec，方便模型了解 hook 状态
        selected = []
        if self.user_id and self.session_id:
            selected = get_selected_spec_ids(self.user_id, self.session_id)
        return {"action": "list", "count": len(items), "specs": items,
                "selected_spec_ids": selected}

    def _action_read(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        spec_id = str(arguments.get("spec_id", "")).strip()
        if not spec_id:
            return {"error": "read 需要 spec_id"}
        content = self._read_spec_content(spec_id)
        if content is None:
            return {"error": f"Spec 不存在: {spec_id}（可先 list/search 查看可用 id）"}
        # 记录本会话已 read 的 spec：select 前置校验依赖（select 前必须先 read）
        self._read_spec_ids.add(spec_id)
        return {"action": "read", "spec_id": spec_id, "content": content}

    def _action_select(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        raw = arguments.get("spec_ids") or []
        if not isinstance(raw, list):
            return {"error": "select 需要 spec_ids 列表"}
        spec_ids = [str(x).strip() for x in raw if str(x).strip()]
        # 去重，保持插入顺序
        spec_ids = list(dict.fromkeys(spec_ids))
        if not (self.user_id and self.session_id):
            return {"error": "当前会话未绑定，无法挂 hook（select 仅会话内生效）"}
        if spec_ids:
            # 校验全部 Spec 存在（内置或自定义）
            missing = [sid for sid in spec_ids if self._read_spec_content(sid) is None]
            if missing:
                return {"error": f"Spec 不存在: {missing}（可先 list/search 查看可用 id）"}
            # 校验全部已在本会话 read 过：select 前必须先 read 对应 Spec，
            # 未 read 直接 select 会被拒绝（防止未读全文就挂 hook）。
            not_read = [sid for sid in spec_ids if sid not in self._read_spec_ids]
            if not_read:
                return {
                    "error": (
                        f"select 前必须先 read 对应 Spec: {not_read}"
                        "（请先 spec read 取全文，再 select 挂 hook）"
                    )
                }
        set_selected_spec_ids(self.user_id, self.session_id, spec_ids)
        if not spec_ids:
            return {
                "action": "select",
                "spec_ids": [],
                "note": "已取消全部 Spec 选择（selected_spec_ids 已清空），"
                        "后续重构 context 将不再注入任何 Spec。",
            }
        return {
            "action": "select",
            "spec_ids": spec_ids,
            "note": "已挂 hook；实际注入发生在下次重构 context（compact/新建会话）。",
        }

    def _action_create(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        if not self.agent_id:
            return {"error": "创建 Spec 需要 agent_id（当前 agent 未绑定）"}
        title = str(arguments.get("title", "")).strip()
        if not title:
            return {"error": "create 需要 title"}
        spec_id = str(arguments.get("spec_id", "")).strip()
        spec_id = _safe_spec_id(spec_id or title)
        if self._read_spec_content(spec_id) is not None:
            return {"error": f"Spec 已存在: {spec_id}（如需修改请用 update）"}
        task_type = str(arguments.get("task_type", "custom")).strip() or "custom"
        description = str(arguments.get("description", "")).strip()
        when = _to_str_list(arguments.get("when"))
        workflow = str(arguments.get("workflow", "")).strip()
        rules = str(arguments.get("rules", "")).strip()
        notes = str(arguments.get("notes", "")).strip()
        if not (workflow or rules or notes):
            return {"error": "create 需要至少提供 workflow/rules/notes 之一"}
        tags = [task_type]

        md = _render_spec_markdown(
            spec_id=spec_id, title=title, task_type=task_type,
            description=description, when=when, tags=tags,
            workflow=workflow, rules=rules, notes=notes,
        )
        ok = self._write_spec_file(spec_id, md)
        if not ok:
            return {"error": f"Spec 文件写入失败: spec/{spec_id}.md"}
        try:
            store_create_spec(
                spec_id, self.agent_id, title=title, task_type=task_type,
                description=description, when=when, tags=tags,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("Spec 索引创建失败（文件已落盘）: %s", exc)
        return {
            "action": "create",
            "spec_id": spec_id,
            "title": title,
            "note": "已创建并落盘到工作空间 spec/；会出现在下次重构 context 的 Spec 索引中。",
        }

    def _action_update(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        if not self.agent_id:
            return {"error": "更新 Spec 需要 agent_id"}
        spec_id = str(arguments.get("spec_id", "")).strip()
        if not spec_id:
            return {"error": "update 需要 spec_id"}
        if spec_id in BUILTIN_SPEC_IDS:
            return {"error": f"{spec_id} 为内置 Spec，不可修改"}
        meta = store_get_spec(spec_id, self.agent_id)
        if meta is None:
            return {"error": f"Spec 不存在: {spec_id}"}
        content = self._read_spec_content(spec_id)
        if content is None:
            return {"error": f"Spec 文件不存在: spec/{spec_id}.md"}

        # 用参数覆盖原值；未提供的字段保持原样
        title = str(arguments.get("title", "")).strip() or meta["title"]
        task_type = str(arguments.get("task_type", "")).strip() or meta["task_type"]
        description = str(arguments.get("description", "")).strip() or meta["description"]
        when = arguments.get("when")
        when = _to_str_list(when) if when is not None else list(meta.get("when") or [])
        workflow = str(arguments.get("workflow", "")).strip()
        rules = str(arguments.get("rules", "")).strip()
        notes = str(arguments.get("notes", "")).strip()
        workflow, rules, notes = _merge_spec_body(content, workflow, rules, notes)

        md = _render_spec_markdown(
            spec_id=spec_id, title=title, task_type=task_type,
            description=description, when=when, tags=list(meta.get("tags") or []),
            workflow=workflow, rules=rules, notes=notes,
        )
        if not self._write_spec_file(spec_id, md):
            return {"error": f"Spec 文件写入失败: spec/{spec_id}.md"}
        store_update_spec(
            spec_id, self.agent_id, title=title, task_type=task_type,
            description=description, when=when, tags=list(meta.get("tags") or []),
        )
        return {"action": "update", "spec_id": spec_id, "title": title, "success": True}

    # ------------------------------------------------------------------
    # Spec 文件读写（内置模板 / 工作空间）
    # ------------------------------------------------------------------
    def _read_spec_content(self, spec_id: str) -> Optional[str]:
        """读取 Spec 全文：内置模板优先，其次工作空间 spec/<id>.md。"""
        builtin_file = _BUILTIN_DIR / f"{spec_id}.md"
        if builtin_file.exists():
            return builtin_file.read_text(encoding="utf-8")
        if not self.io:
            return None
        try:
            r = run_io(self.io.read_file(self.workspace_id, f"{SPEC_DIR}/{spec_id}.md"))
            if r.get("error"):
                return None
            return str(r.get("content") or "")
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取 Spec 文件失败 %s/%s: %s", spec_id, self.workspace_id, exc)
            return None

    def _write_spec_file(self, spec_id: str, content: str) -> bool:
        """把 Spec 全文写入工作空间 ``spec/<id>.md``（本地/云端/SSH 通用）。"""
        if not self.io:
            return False
        try:
            r = run_io(self.io.write_file(self.workspace_id, f"{SPEC_DIR}/{spec_id}.md", content))
            if r.get("error"):
                logger.warning("Spec 文件写入失败: %s", r.get("error"))
                return False
            return True
        except Exception as exc:  # noqa: BLE001
            logger.warning("Spec 文件写入异常: %s", exc)
            return False


# ----------------------------------------------------------------------
# 辅助函数
# ----------------------------------------------------------------------
def _to_str_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    return [str(v).strip() for v in value if str(v).strip()]


def _render_spec_markdown(
    spec_id: str,
    title: str,
    task_type: str,
    description: str,
    when: List[str],
    tags: List[str],
    workflow: str,
    rules: str,
    notes: str,
) -> str:
    """渲染 Spec Markdown（front matter + 固定三段正文）。"""
    def _fmt_list(items: List[str]) -> str:
        if not items:
            return ""
        return "\n".join(f"  - {item}" for item in items)

    def _fmt_tags(items: List[str]) -> str:
        if not items:
            return ""
        return "[" + ", ".join(items) + "]"

    ts = int(time.time())
    now = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
    when_block = _fmt_list(when)
    tags_block = _fmt_tags(tags)
    return (
        "---\n"
        f"id: {spec_id}\n"
        f"title: {title}\n"
        f"task_type: {task_type}\n"
        f"description: {description}\n"
        f"when:\n{when_block}\n"
        f"tags: {tags_block}\n"
        "pinned: false\n"
        "builtin: false\n"
        f"created_at: {ts}\n"
        f"updated_at: {ts}\n"
        "---\n\n"
        f"## 工作流（workflow）\n\n{workflow.strip()}\n\n"
        f"## 该类任务规范\n\n{rules.strip()}\n\n"
        f"## 注意事项\n\n{notes.strip()}\n"
    )


def _merge_spec_body(
    content: str,
    workflow: str,
    rules: str,
    notes: str,
) -> tuple:
    """把 update 参数与现有正文合并：提供的覆盖，未提供的保留原文。"""
    # 去掉 front matter，按 ## 标题切分正文段
    body = content
    if body.startswith("---"):
        end = body.find("\n---", 3)
        if end != -1:
            body = body[end + 4:]
    sections: Dict[str, str] = {}
    current: Optional[str] = None
    for line in body.splitlines():
        if line.startswith("## "):
            current = line[3:].strip()
            sections.setdefault(current, "")
        elif current is not None:
            sections[current] += line + "\n"

    def _pick(target: str, fallback_key: str) -> str:
        if target and target.strip():
            return target.strip()
        for key, val in sections.items():
            if key.startswith(fallback_key):
                return val.strip()
        return ""

    new_workflow = _pick(workflow, "工作流")
    new_rules = _pick(rules, "该类任务规范")
    new_notes = _pick(notes, "注意事项")
    return new_workflow, new_rules, new_notes
