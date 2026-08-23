"""提示词版本数据目录加载器。

从 ``prompt/versions/<version>/`` 目录读取一个版本打包的全部提示词内容，
解析为 :class:`~prompt.schema.PromptVersion`。数据目录布局（内容即数据，与代码解耦）：

    versions/<version>/
      meta.yaml            # 版本元数据：version/date/scope/changelog/head_ids/tail_ids
      chapters/*.md        # 系统静态章节：YAML front-matter（id/title/version/level/
                           #   description）+ Markdown 正文
      compressor.md        # 上下文压缩器模板（含 {raw} 占位）
      tools/builtin.yaml   # 内置工具描述：{name: {version, description}}
      tools/mcp.yaml       # MCP 工具描述：{name: {version, description}}

本模块只负责解析，不关心「哪个版本激活」。激活版本由 :mod:`prompt.versions`
依据 ``configs/app.yaml`` 的 ``prompt.version`` 决定。
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict

import yaml

from .schema import LEVEL_CORE, LEVEL_GUARDRAIL, LEVEL_OPS, Chapter, PromptVersion

# 章节目录/压缩器目录相对本模块的位置
_VERSIONS_DIR = Path(__file__).resolve().parent / "versions"

# level 字符串 → 层级常量
_LEVEL_MAP = {
    "core": LEVEL_CORE,
    "guardrail": LEVEL_GUARDRAIL,
    "ops": LEVEL_OPS,
    LEVEL_CORE: LEVEL_CORE,
    LEVEL_GUARDRAIL: LEVEL_GUARDRAIL,
    LEVEL_OPS: LEVEL_OPS,
}


class VersionMissingError(FileNotFoundError):
    """请求的提示词版本未登记（数据目录不存在或内容缺失）。"""


class _TagError(ValueError):
    """数据文件格式不符合约定。"""


# ---------------------------------------------------------------------------
# Markdown front-matter 解析
# ---------------------------------------------------------------------------

_FRONT_MATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n?(.*)\Z", re.DOTALL)


def _parse_front_matter(text: str, source: str):
    """解析 ``--- front-matter ---`` + 正文。

    :return: ``(meta: dict, body: str)``
    """
    m = _FRONT_MATTER_RE.match(text)
    if not m:
        raise _TagError(f"{source}: 缺少 YAML front-matter 头")
    body = m.group(2).strip()
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as exc:
        raise _TagError(f"{source}: front-matter 解析失败: {exc}") from exc
    if not isinstance(meta, dict):
        raise _TagError(f"{source}: front-matter 必须是映射")
    return meta, body


# ---------------------------------------------------------------------------
# 章节加载
# ---------------------------------------------------------------------------

def _load_chapter(path: Path) -> Chapter:
    meta, body = _parse_front_matter(path.read_text(encoding="utf-8"), str(path))
    try:
        cid = str(meta["id"])
        title = str(meta["title"])
        version = int(meta.get("version", 1))
        level_raw = str(meta.get("level", "ops"))
        description = str(meta.get("description", ""))
    except (KeyError, TypeError, ValueError) as exc:
        raise _TagError(f"{path}: 章节元数据缺 id/title 或 version 非法") from exc
    level = _LEVEL_MAP.get(level_raw, level_raw)
    return Chapter(
        id=cid, title=title, version=version, level=level,
        description=description, content=body,
    )


def _load_compressor(path: Path, compressor_md: str) -> object:
    """装配压缩器模板函数：``{raw}`` 占位替换为调用参数。"""
    def _compressor(raw: str) -> str:
        return compressor_md.replace("{raw}", raw)
    return _compressor


def _load_tool_descriptions(paths) -> Dict[str, str]:
    """合并多个工具 yaml 文件为 ``{name: description}``。"""
    out: Dict[str, str] = {}
    for path in paths:
        if not path.exists():
            continue
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            raise _TagError(f"{path}: 工具定义解析失败: {exc}") from exc
        for name, item in data.items():
            if isinstance(item, str):
                out[name] = item
                continue
            if isinstance(item, dict) and "description" in item:
                out[name] = str(item["description"])
            # 忽略无 description 的条目（容忍预留占位）
    return out


# ---------------------------------------------------------------------------
# 对外加载入口
# ---------------------------------------------------------------------------

def load_version(version: str) -> PromptVersion:
    """加载指定提示词版本的数据目录。

    :param version: 语义化版本号（如 ``"1.0.0"``）
    :return: 解析完成的 :class:`PromptVersion`
    :raises VersionMissingError: 版本未登记 / 目录缺失 / 内容不符合约定
    """
    vdir = _VERSIONS_DIR / version
    if not vdir.is_dir():
        raise VersionMissingError(f"提示词版本未登记（缺数据目录）: {version}")

    # meta
    meta: Dict = {}
    meta_path = vdir / "meta.yaml"
    if meta_path.exists():
        try:
            meta = yaml.safe_load(meta_path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            raise _TagError(f"{meta_path}: meta 解析失败: {exc}") from exc

    # chapters
    head_ids = [str(x) for x in meta.get("head_ids", [])]
    tail_ids = [str(x) for x in meta.get("tail_ids", [])]
    chapters_dir = vdir / "chapters"
    chapters = [
        _load_chapter(p) for p in sorted(chapters_dir.glob("*.md"))
    ] if chapters_dir.is_dir() else []
    by_id = {c.id: c for c in chapters}
    if (len(head_ids) + len(tail_ids)) != len(chapters):
        raise _TagError(
            f"{version}: head_ids+tail_ids（{len(head_ids)}+{len(tail_ids)}）与 "
            f"章节数（{len(chapters)}）不一致"
        )

    def _pick(ids):
        missing = [i for i in ids if i not in by_id]
        if missing:
            raise _TagError(f"{version}: meta 声明了但缺少章节文件: {missing}")
        return tuple(by_id[i] for i in ids)

    head = _pick(head_ids)
    tail = _pick(tail_ids)

    # compressor
    compressor_tpl = ""
    compressor_path = vdir / "compressor.md"
    if compressor_path.exists():
        compressor_tpl = compressor_path.read_text(encoding="utf-8")
    compressor = (
        _load_compressor(version, compressor_tpl)
        if compressor_tpl
        else (lambda raw: raw)
    )

    # tool descriptions
    tool_dir = vdir / "tools"
    tool_descriptions = _load_tool_descriptions([
        tool_dir / "builtin.yaml",
        tool_dir / "mcp.yaml",
    ])

    return PromptVersion(
        version=version,
        system_head=head,
        system_tail=tail,
        compressor=compressor,
        tool_descriptions=tool_descriptions,
        meta=meta,
        changelog=tuple(meta.get("changelog", [])),
    )