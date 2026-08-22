"""内置工具 SetTodoList - 任务分解与进度跟踪。

将任务列表写入 agent 工作空间 ``.self/todos.md``（持久化），并通过 WebSocket
推送 ``todo_update`` 事件，供前端 Todo 面板实时展示。

动作：
- ``set``：整体替换 todos（提供完整的 todos 列表）
- ``update``：按 todo 项 id 更新（状态/进度/备注）
- ``clear``：清空当前 todos
- ``get``：读取当前 todos 快照

todos 每项结构：``{id, content, status, progress}``
- status ∈ pending / in_progress / completed / blocked
- progress：0-100 整数（可选，默认按 status 推断）
"""
import json
import logging
import re
import time
import uuid
from typing import Any, Dict, List, Optional

from io_.workspace_io import WorkspaceIO, run_io

logger = logging.getLogger(__name__)

# todos 持久化路径（agent 私人空间）
TODOS_PATH = ".self/todos.md"

# todo 状态全集
STATUS_VALUES = {"pending", "in_progress", "completed", "blocked"}

# 单次最大 todo 项数（防止模型一次性塞入超大列表）
MAX_TODOS = 200


class SetTodoListTool:
    """SetTodoList 内置工具：任务分解/进度跟踪。"""

    def __init__(
        self,
        io: WorkspaceIO,
        workspace_id: str,
        user_id: str = "",
        ws_manager: Any = None,
    ) -> None:
        self.io = io
        self.workspace_id = workspace_id
        self.user_id = user_id
        self.ws_manager = ws_manager

    # ------------------------------------------------------------------
    # 工具定义
    # ------------------------------------------------------------------
    def get_tool_definition(self) -> Dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": "set_todo_list",
                "description": (
                    "[任务分解与进度跟踪] | "
                    "贡献维度: 任务管理（把任务拆成可跟踪的 todo 列表，持续汇报进度）\n"
                    "何时使用: 开始复杂任务前先 SetTodoList 分解；执行中每完成一项用 "
                    "update 更新进度；长任务/团队任务必用\n"
                    "何时不用: 简单单文件改动（easy 任务）无需 todo\n"
                    "前置依赖: 工作空间可写（.self/todos.md）\n"
                    "动作: set(整体替换) / update(按 id 更新) / clear(清空) / get(读取快照)"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": ["set", "update", "clear", "get"],
                            "description": "要执行的动作",
                        },
                        "todos": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "content": {
                                        "type": "string",
                                        "description": "任务描述",
                                    },
                                    "status": {
                                        "type": "string",
                                        "enum": ["pending", "in_progress", "completed", "blocked"],
                                        "description": "状态（默认 pending）",
                                    },
                                    "progress": {
                                        "type": "integer",
                                        "description": "进度 0-100（可选）",
                                    },
                                },
                                "required": ["content"],
                            },
                            "description": "set 用：完整 todos 列表（不含 id，由工具生成）",
                        },
                        "todo_id": {
                            "type": "string",
                            "description": "update 用：目标 todo 项 id",
                        },
                        "content": {
                            "type": "string",
                            "description": "update 用：更新后的任务描述（可选）",
                        },
                        "status": {
                            "type": "string",
                            "enum": ["pending", "in_progress", "completed", "blocked"],
                            "description": "update 用：更新后的状态（可选）",
                        },
                        "progress": {
                            "type": "integer",
                            "description": "update 用：更新后的进度 0-100（可选）",
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
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}
        action = str(arguments.get("action", "")).strip()
        if action == "set":
            return self._action_set(arguments)
        if action == "update":
            return self._action_update(arguments)
        if action == "clear":
            return self._action_clear(arguments)
        if action == "get":
            return self._action_get(arguments)
        return {"error": f"未知动作: {action}（应为 set/update/clear/get）"}

    # ------------------------------------------------------------------
    # 具体动作
    # ------------------------------------------------------------------
    def _action_set(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        raw = arguments.get("todos")
        if not isinstance(raw, list) or not raw:
            return {"error": "set 需要非空 todos 列表（每项含 content）"}
        if len(raw) > MAX_TODOS:
            return {"error": f"todos 过多（{len(raw)} > {MAX_TODOS}），请拆分精简"}
        now = int(time.time() * 1000)
        todos: List[Dict[str, Any]] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            content = str(item.get("content", "")).strip()
            if not content:
                continue
            status = str(item.get("status", "pending")).strip()
            if status not in STATUS_VALUES:
                status = "pending"
            progress = _clamp_progress(item.get("progress"), status)
            todos.append({
                "id": _gen_todo_id(),
                "content": content,
                "status": status,
                "progress": progress,
                "updated_at": now,
            })
        if not todos:
            return {"error": "set 需要至少一个有效 todo（含 content）"}
        ok = self._save_todos(todos)
        if not ok:
            return {"error": "todos 写入失败（工作空间不可写）"}
        self._notify(todos)
        return {
            "action": "set",
            "count": len(todos),
            "todos": todos,
            "note": "todos 已保存到 .self/todos.md 并同步到前端面板。",
        }

    def _action_update(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        todo_id = str(arguments.get("todo_id", "")).strip()
        if not todo_id:
            return {"error": "update 需要 todo_id"}
        todos = self._load_todos()
        target = next((t for t in todos if t["id"] == todo_id), None)
        if target is None:
            return {"error": f"todo 不存在: {todo_id}（可 get 查看当前列表）"}
        if arguments.get("content"):
            target["content"] = str(arguments["content"]).strip() or target["content"]
        if arguments.get("status"):
            status = str(arguments["status"]).strip()
            if status in STATUS_VALUES:
                target["status"] = status
                if arguments.get("progress") is None:
                    target["progress"] = _clamp_progress(None, status)
        if arguments.get("progress") is not None:
            target["progress"] = _clamp_progress(arguments["progress"], target["status"])
        target["updated_at"] = int(time.time() * 1000)
        ok = self._save_todos(todos)
        if not ok:
            return {"error": "todos 写入失败（工作空间不可写）"}
        self._notify(todos)
        return {"action": "update", "todo": target, "todos": todos}

    def _action_clear(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        ok = self._save_todos([])
        if not ok:
            return {"error": "todos 写入失败（工作空间不可写）"}
        self._notify([])
        return {"action": "clear", "note": "todos 已清空。"}

    def _action_get(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        todos = self._load_todos()
        return {"action": "get", "count": len(todos), "todos": todos}

    # ------------------------------------------------------------------
    # 持久化与推送
    # ------------------------------------------------------------------
    def _load_todos(self) -> List[Dict[str, Any]]:
        """从 .self/todos.md 读取 todos（解析 JSON 数据块）。"""
        content = self._read_file(TODOS_PATH)
        if not content:
            return []
        match = re.search(r"```json\s*(.*?)\s*```", content, re.DOTALL)
        if not match:
            return []
        try:
            data = json.loads(match.group(1))
            return data if isinstance(data, list) else []
        except Exception:  # noqa: BLE001
            logger.warning("解析 todos.md JSON 失败，返回空列表")
            return []

    def _save_todos(self, todos: List[Dict[str, Any]]) -> bool:
        """把 todos 序列化写入 .self/todos.md。"""
        header = "# 任务清单（Todo List）\n\n"
        note = "> 由 SetTodoList 工具维护，前端 Todo 面板同步展示。\n\n"
        body = "```json\n" + json.dumps(todos, ensure_ascii=False, indent=2) + "\n```\n"
        content = header + note + body
        if not self.io:
            return False
        try:
            r = run_io(self.io.write_file(self.workspace_id, TODOS_PATH, content))
            return not r.get("error")
        except Exception as exc:  # noqa: BLE001
            logger.warning("todos 写入失败: %s", exc)
            return False

    def _read_file(self, path: str) -> str:
        if not self.io:
            return ""
        try:
            r = run_io(self.io.read_file(self.workspace_id, path))
            if r.get("error"):
                return ""
            return str(r.get("content") or "")
        except Exception as exc:  # noqa: BLE001
            logger.warning("读取 %s 失败: %s", path, exc)
            return ""

    def _notify(self, todos: List[Dict[str, Any]]) -> None:
        """推送 todo_update WS 事件（前端面板刷新）。"""
        if self.ws_manager is None or not self.user_id:
            return
        import asyncio

        payload = {
            "type": "todo_update",
            "data": {"todos": todos, "updated_at": int(time.time() * 1000)},
        }
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        try:
            if loop is not None and loop.is_running():
                asyncio.run_coroutine_threadsafe(
                    self.ws_manager.send_message(self.user_id, payload), loop
                )
            else:
                import asyncio as _a

                _a.run_until_complete(
                    self.ws_manager.send_message(self.user_id, payload)
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("todo_update 推送失败: %s", exc)


# ----------------------------------------------------------------------
# 辅助函数
# ----------------------------------------------------------------------
def _gen_todo_id() -> str:
    return f"todo_{int(time.time() * 1000)}_{uuid.uuid4().hex[:4]}"


def _clamp_progress(value: Any, status: str) -> int:
    """把进度值钳制到 0-100；未提供时按 status 推断。"""
    if value is not None:
        try:
            v = int(value)
            return max(0, min(100, v))
        except (TypeError, ValueError):
            pass
    return {"pending": 0, "in_progress": 50, "completed": 100, "blocked": 0}.get(
        status, 0
    )
