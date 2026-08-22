"""Spec 元数据索引存储 - SQLite 持久化。

Spec = 任务型规范文件（Markdown），本体存于 ``workspace/<agent id>/spec/``
（内置 3 个为服务端模板 ``server/tool/spec/builtin/``）；本模块维护其
**元数据索引**（``specs`` 表：title/task_type/description/when/tags/
pinned/builtin/embedding），支撑索引列表、语义检索与"已选 Spec"挂 hook。

字段说明：
- ``agent_id``：NULL 表示内置 Spec（全用户共享）；自定义 Spec 归属某 agent。
- ``pinned``：内置 3 个置顶展示（``True``）。
- ``builtin``：是否为服务端内置模板（不随 agent 工作空间删除）。
- ``embedding``：description + when 的向量（JSON），供语义检索复用 Embed 组件。
"""
import json
import logging
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# 数据库目录：server/data
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 内置 Spec 模板目录：server/tool/spec/builtin/
_BUILTIN_DIR = (
    Path(__file__).resolve().parent.parent / "tool" / "spec" / "builtin"
)

# 内置 3 个 Spec 的固定 id（置顶顺序）
BUILTIN_SPEC_IDS = ("easy-task", "complex-task", "hard-task")

# 写操作锁
_write_lock = threading.Lock()
# 初始化标记
_initialized = False


# ----------------------------------------------------------------------
# 初始化与内置注册
# ----------------------------------------------------------------------
def _ensure_db() -> None:
    """确保 ``specs`` 表已创建，并注册内置 3 个 Spec 的元数据。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS specs (
                id TEXT NOT NULL,
                agent_id TEXT,
                title TEXT NOT NULL,
                task_type TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                when_json TEXT NOT NULL DEFAULT '[]',
                tags_json TEXT NOT NULL DEFAULT '[]',
                pinned INTEGER NOT NULL DEFAULT 0,
                builtin INTEGER NOT NULL DEFAULT 0,
                embedding TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (id, agent_id)
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_specs_agent "
            "ON specs (agent_id, pinned DESC, updated_at DESC)"
        )
        conn.commit()
    _register_builtin_specs()
    _initialized = True


def _register_builtin_specs() -> None:
    """把内置 3 个 Spec（server/tool/spec/builtin/*.md）的元数据写入 specs 表。

    内置 Spec 为服务端模板，agent_id = NULL（全局共享），置顶展示。
    模板文件不存在或已注册时跳过（幂等）。首次注册时同步 front matter 与
    description/when/tags 等元数据。
    """
    for spec_id in BUILTIN_SPEC_IDS:
        md_file = _BUILTIN_DIR / f"{spec_id}.md"
        if not md_file.exists():
            logger.warning("内置 Spec 模板缺失: %s", md_file)
            continue
        meta = _parse_front_matter(md_file.read_text(encoding="utf-8"))
        if meta is None:
            continue
        ts = int(time.time() * 1000)
        title = meta.get("title", spec_id)
        task_type = meta.get("task_type", "custom")
        description = meta.get("description", "")
        when_json = json.dumps(meta.get("when", []), ensure_ascii=False)
        tags_json = json.dumps(meta.get("tags", []), ensure_ascii=False)
        with _write_lock, sqlite3.connect(_DB_PATH) as conn:
            conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
            # 主键含 NULL 时 SQLite 唯一约束失效，不能用 INSERT OR IGNORE 幂等；
            # 改为"存在则更新、不存在则插入"（内置 id 在 agent_id IS NULL 下唯一）。
            existing = conn.execute(
                "SELECT 1 FROM specs WHERE id = ? AND agent_id IS NULL",
                (spec_id,),
            ).fetchone()
            if existing is None:
                conn.execute(
                    "INSERT INTO specs "
                    "(id, agent_id, title, task_type, description, when_json, "
                    "tags_json, pinned, builtin, created_at, updated_at) "
                    "VALUES (?, NULL, ?, ?, ?, ?, ?, 1, 1, ?, ?)",
                    (spec_id, title, task_type, description, when_json,
                     tags_json, ts, ts),
                )
            else:
                conn.execute(
                    "UPDATE specs SET title = ?, task_type = ?, description = ?, "
                    "when_json = ?, tags_json = ?, pinned = 1, builtin = 1, "
                    "updated_at = ? WHERE id = ? AND agent_id IS NULL",
                    (title, task_type, description, when_json, tags_json, ts, spec_id),
                )
            conn.commit()


def _parse_front_matter(md_text: str) -> Optional[Dict[str, Any]]:
    """解析 Spec Markdown 文件的 front matter（YAML 风格 ``--- ... ---`` 块）。

    :return: front matter 元数据字典；格式不合法时返回 None
    """
    if not md_text.startswith("---"):
        return None
    end = md_text.find("\n---", 3)
    if end == -1:
        return None
    fm_text = md_text[3:end].strip()
    meta: Dict[str, Any] = {}
    current_list_key: Optional[str] = None
    for line in fm_text.splitlines():
        line = line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # 缩进或顶格的 "- " 列表项：追加到当前列表键
        if stripped.startswith("- ") and current_list_key is not None:
            item = stripped[2:].strip().strip('"').strip("'")
            meta.setdefault(current_list_key, []).append(item)
            continue
        current_list_key = None
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if not value:
            current_list_key = key
            meta[key] = []
            continue
        # 内联数组 `[a, b, c]`：按逗号拆分并去除引号
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            meta[key] = (
                [
                    part.strip().strip('"').strip("'")
                    for part in inner.split(",")
                    if part.strip()
                ]
                if inner
                else []
            )
            continue
        value = value.strip('"').strip("'")
        if value.lower() in ("true", "false"):
            meta[key] = value.lower() == "true"
        else:
            try:
                meta[key] = int(value)
            except ValueError:
                meta[key] = value
    return meta or None


# ----------------------------------------------------------------------
# 行对象转换
# ----------------------------------------------------------------------
def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    """把 specs 表行转为字典（json 字段反序列化）。"""
    def _loads(raw: Optional[str], default: Any) -> Any:
        if not raw:
            return default
        try:
            data = json.loads(raw)
            # 防御旧脏数据：when/tags 期望列表，历史坏行可能存成字符串
            if isinstance(data, str):
                return default
            return data
        except Exception:  # noqa: BLE001
            return default

    return {
        "id": row["id"],
        "agent_id": row["agent_id"],
        "title": row["title"],
        "task_type": row["task_type"],
        "description": row["description"],
        "when": _loads(row["when_json"], []),
        "tags": _loads(row["tags_json"], []),
        "pinned": bool(row["pinned"]),
        "builtin": bool(row["builtin"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


# ----------------------------------------------------------------------
# 公开 API
# ----------------------------------------------------------------------
def list_specs(
    agent_id: Optional[str] = None,
    include_builtin: bool = True,
) -> List[Dict[str, Any]]:
    """列出 Spec 索引：内置 3 个置顶 + 该 agent 的自定义 Spec。

    :param agent_id: 指定 agent 时同时返回其自定义 Spec；None 仅返回内置。
    :param include_builtin: 是否包含内置 3 个（默认包含并置顶）。
    :return: Spec 元数据列表（不含正文）
    """
    _ensure_db()
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT * FROM specs WHERE agent_id IS NULL"
        ).fetchall()
        by_id = {r["id"]: _row_to_dict(r) for r in rows}
        # 内置 3 个按固定顺序置顶（easy/complex/hard），其余按 id
        result: List[Dict[str, Any]] = []
        for bid in BUILTIN_SPEC_IDS:
            if bid in by_id:
                result.append(by_id.pop(bid))
        result.extend(by_id.values())
        if agent_id:
            custom = conn.execute(
                "SELECT * FROM specs WHERE agent_id = ? "
                "ORDER BY updated_at DESC",
                (agent_id,),
            ).fetchall()
            result.extend(_row_to_dict(r) for r in custom)
        if not include_builtin:
            result = [s for s in result if not s["builtin"]]
        return result
    finally:
        conn.close()


def get_spec(spec_id: str, agent_id: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """按 (id, agent_id) 查询 Spec 元数据；内置 Spec agent_id 传 None。

    先精确匹配 ``(id, agent_id)``，再回退 ``(id, NULL)``（内置/全局）。
    """
    _ensure_db()
    conn = _connect()
    try:
        if agent_id:
            row = conn.execute(
                "SELECT * FROM specs WHERE id = ? AND agent_id = ?",
                (spec_id, agent_id),
            ).fetchone()
            if row is not None:
                return _row_to_dict(row)
        row = conn.execute(
            "SELECT * FROM specs WHERE id = ? AND agent_id IS NULL",
            (spec_id,),
        ).fetchone()
        return _row_to_dict(row) if row is not None else None
    finally:
        conn.close()


def create_spec(
    spec_id: str,
    agent_id: Optional[str],
    title: str,
    task_type: str,
    description: str = "",
    when: Optional[List[str]] = None,
    tags: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """创建自定义 Spec 的元数据索引（本体文件由调用方落盘到 workspace spec/）。

    :param spec_id: Spec id（agent 内唯一）
    :param agent_id: 归属 agent；自定义 Spec 必传（非 None）
    :return: 创建的 Spec 元数据
    """
    _ensure_db()
    ts = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT OR REPLACE INTO specs "
            "(id, agent_id, title, task_type, description, when_json, tags_json, "
            "pinned, builtin, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)",
            (
                spec_id,
                agent_id,
                title,
                task_type or "custom",
                description or "",
                json.dumps(when or [], ensure_ascii=False),
                json.dumps(tags or [], ensure_ascii=False),
                ts,
                ts,
            ),
        )
        conn.commit()
    return get_spec(spec_id, agent_id) or {}


def update_spec(
    spec_id: str,
    agent_id: Optional[str],
    **updates: Any,
) -> bool:
    """更新 Spec 元数据（title/task_type/description/when/tags）。

    内置 Spec（agent_id=None）仅允许更新 description 以外的字段？
    —— 内置 Spec 元数据来自模板，一般不改；此方法主要面向自定义 Spec。
    """
    _ensure_db()
    allowed = {"title", "task_type", "description", "when", "tags"}
    sets: List[str] = []
    values: List[Any] = []
    for key, val in updates.items():
        if key not in allowed:
            continue
        if key == "when":
            sets.append("when_json = ?")
            values.append(json.dumps(val or [], ensure_ascii=False))
        elif key == "tags":
            sets.append("tags_json = ?")
            values.append(json.dumps(val or [], ensure_ascii=False))
        else:
            sets.append(f"{key} = ?")
            values.append(val)
    if not sets:
        return False
    sets.append("updated_at = ?")
    values.append(int(time.time() * 1000))
    values.extend([spec_id, agent_id])
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        cur = conn.execute(
            f"UPDATE specs SET {', '.join(sets)} "
            "WHERE id = ? AND agent_id IS ?",
            values,
        )
        conn.commit()
        return cur.rowcount > 0


def delete_spec(spec_id: str, agent_id: Optional[str]) -> bool:
    """删除自定义 Spec 的元数据（内置 Spec 不可删）。"""
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        cur = conn.execute(
            "DELETE FROM specs WHERE id = ? AND agent_id IS ? AND builtin = 0",
            (spec_id, agent_id),
        )
        conn.commit()
        return cur.rowcount > 0


# ----------------------------------------------------------------------
# 语义检索
# ----------------------------------------------------------------------
def _compute_embedding(text: str) -> Optional[List[float]]:
    """调用 Embed 组件计算文本向量（配置缺失/失败时返回 None，回退关键词检索）。"""
    try:
        from data.embed_model import (
            EmbedModelConfig,
            get_embedding,
            load_embed_model_config,
        )

        cfg: Optional[EmbedModelConfig] = load_embed_model_config()
        if cfg is None:
            return None
        return get_embedding(text, cfg)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Spec embedding 计算失败，回退关键词检索: %s", exc)
        return None


def _cosine_sim(a: List[float], b: List[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    if not na or not nb:
        return 0.0
    return dot / (na * nb)


def _keyword_score(spec: Dict[str, Any], query: str) -> float:
    """朴素关键词评分：命中 title/description/when/tags 的加权和。"""
    q = query.lower()
    hay = (
        spec.get("title", "") + " " + spec.get("description", "")
        + " " + " ".join(spec.get("when", []))
        + " " + " ".join(spec.get("tags", []))
    ).lower()
    if not q:
        return 0.0
    hits = sum(1 for kw in q.split() if kw in hay)
    return hits / len(q.split())


def search_specs(
    query: str,
    agent_id: Optional[str] = None,
    limit: int = 10,
) -> List[Dict[str, Any]]:
    """语义检索 Spec 索引（复用 Embed 对 description/when 比对）。

    嵌入模型可用时按余弦相似度排序；不可用时回退关键词评分。内置 Spec 置顶
    于结果之前（保持稳定入口）。
    """
    _ensure_db()
    specs = list_specs(agent_id=agent_id)
    if not query.strip():
        return specs[:limit]

    q_vec = _compute_embedding(query)
    scored: List[Tuple[float, Dict[str, Any]]] = []
    for spec in specs:
        if q_vec is not None:
            s_vec = _compute_embedding(
                spec.get("description", "") + " " + " ".join(spec.get("when", []))
            )
            score = _cosine_sim(q_vec, s_vec) if s_vec else _keyword_score(spec, query)
        else:
            score = _keyword_score(spec, query)
        scored.append((score, spec))

    # 排序：内置置顶 > 相似度降序
    scored.sort(key=lambda t: (t[1].get("pinned", False), t[0]), reverse=True)
    return [s for _score, s in scored[:limit]]
