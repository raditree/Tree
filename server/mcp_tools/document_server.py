"""MCP stdio server - 文档处理服务（PDF/PPTX/DOCX/XLSX）。

通过环境变量 ``WORKSPACE_ID`` 绑定到指定 agent 的 Docker 工作空间，
使用容器内安装的 Python 文档处理库（pymupdf / python-pptx / python-docx / openpyxl）
来读取和生成常见复杂文档。

注意：本 server 不依赖 mcp SDK / fastmcp，直接通过 JSON-RPC over stdio 通信，
避免项目内 anyio 版本兼容性问题。
"""

import base64
import json
import logging
import os
import sys
import textwrap
import traceback

# 确保 server 目录在 sys.path 中，便于导入 core
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from io_.docker_manager import DockerManager  # noqa: E402
from io_.workspace_io import CloudWorkspaceIO, WorkspaceIO, run_io  # noqa: E402
from prompt import versions  # noqa: E402

logger = logging.getLogger(__name__)

# MCP 协议版本
_PROTOCOL_VERSION = "2024-11-05"


def _tool_description(name: str, baseline: str) -> str:
    """取**激活版本**的工具描述；无法解析时回退到内联基线（v1.0.0 文本）。

    document_server 可作为后端进程（local/ssh 进程内）或云端 stdio 子进程运行，
    二者均有配置文件读取路径；此处兜底保证在缺少配置的裸沙箱中不至于使整个
    文档服务崩溃。
    """
    try:
        return versions.active_tool_description(name)
    except Exception:  # noqa: BLE001
        return baseline


_PY_INTERP_CACHE: dict = {}


def _pick_python(workspace_id: str, io: WorkspaceIO) -> str:
    """探测工作空间内可用的 Python 解释器（``python3`` 优先，回退 ``python``）。

    云端容器 / SSH 通常只有 ``python3``；本地（Windows）通常只有 ``python``。
    探测结果按 workspace 缓存，避免每次工具调用重复探测。
    """
    cached = _PY_INTERP_CACHE.get(workspace_id)
    if cached:
        return cached
    for cand in ("python3", "python"):
        try:
            probe = run_io(io.exec_argv(workspace_id, [cand, "-c", "print(1)"], timeout=20))
        except Exception:  # noqa: BLE001
            continue
        if not probe.get("error") and probe.get("exit_code", -1) == 0:
            _PY_INTERP_CACHE[workspace_id] = cand
            return cand
    _PY_INTERP_CACHE[workspace_id] = "python3"
    return "python3"


def _exec_python(
    workspace_id: str, io: WorkspaceIO, script: str, timeout: int = 120
) -> dict:
    """在工作空间内执行 Python 脚本并返回解析后的 JSON 结果。

    - 脚本模板负责将 stdout 重配置为 UTF-8（中文支持），后端按 UTF-8 解析。
    - 解释器按 ``python3 -> python`` 顺序探测：云端容器 / SSH 用 python3，
      本地 Windows 无 python3 时自动回退 python（修复 exit_code=9009）。
    """
    # 将脚本内容缩进 4 格（放入 try 块），避免 f-string 多行替换丢失缩进
    indented_script = textwrap.indent(script, "    ")
    full_script = (
        "import json, sys\n"
        "try:\n"
        f"{indented_script}"
        "except Exception as e:\n"
        '    print(json.dumps({"success": False, "error": str(e)}))\n'
    )
    interp = _pick_python(workspace_id, io)
    result = run_io(
        io.exec_argv(workspace_id, [interp, "-c", full_script], timeout=timeout)
    )
    exit_code = result.get("exit_code", -1)
    stdout = result.get("stdout", "") or ""
    stderr = result.get("stderr", "") or ""

    if result.get("error"):
        return {"success": False, "error": result["error"]}
    if exit_code != 0:
        return {"success": False, "error": stderr or stdout or f"exit_code={exit_code}"}

    for line in stdout.strip().splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {"success": True, "data": stdout.strip()}


def _dump(result: dict) -> str:
    return json.dumps(result, ensure_ascii=False)


# ── 工具定义 ──────────────────────────────────────────────────────────

TOOLS = [
    {
        "name": "read_pdf",
        "description": _tool_description(
            "read_pdf",
            "[解析 PDF：目录/按章节阅读/全文] | 贡献维度: 外部能力/文档处理\n"
            "何时使用: 需要读取 .pdf 文件，建议先取目录（默认 mode=toc），再按章节取正文\n"
            "何时不用: 非 PDF 文档用 read_docx/read_pptx/read_xlsx；目录阅读用 mode=chapters\n"
            "前置依赖: 文件须存在于工作空间且为 PDF；支持中文路径与中文书签标题\n"
            "参数说明: mode=toc 返回章节目录；mode=chapters + chapters 返回所选章节正文（如 1,3-5 或标题关键词或 p:5-8 页码范围）；mode=text 按页返回全文（兼容旧行为，可用 pages 限定范围）；max_chars 控制正文返回字符数（默认 8000，超出截断并标记）",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "工作空间内的 PDF 文件路径（支持中文路径，如 /workspace/docs/测试文档.pdf）",
                },
                "mode": {
                    "type": "string",
                    "enum": ["toc", "chapters", "text"],
                    "description": "读取模式，默认 toc：toc=仅返回章节目录（含页码）；chapters=按章节返回正文；text=按页返回全文",
                },
                "chapters": {
                    "type": "string",
                    "description": "mode=chapters 时选择章节（可一次多个）：书签序号 1 / 1,3-5；或章节标题关键词（如 第一章）；或页码范围 p:5-8",
                },
                "pages": {
                    "type": "string",
                    "description": "mode=text 时可选页范围（如 3-8 或 5）；不传返回全部页（受 max_chars 截断）",
                },
                "max_chars": {
                    "type": "integer",
                    "description": "正文返回的最大字符数，默认 8000；超出部分截断并在结果中标记（建议保持默认，避免结果被重定向）",
                },
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "read_docx",
        "description": _tool_description(
            "read_docx",
            "[解析 DOCX 提取文本与表格] | 贡献维度: 外部能力/文档处理\n"
            "何时使用: 需要读取 .docx 文件内容（段落文本与表格数据）\n"
            "何时不用: 非 DOCX 文档用对应的 read_* 工具\n"
            "前置依赖: 文件须存在于工作空间且为 DOCX",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "工作空间内的 DOCX 文件路径",
                }
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "read_pptx",
        "description": _tool_description(
            "read_pptx",
            "[解析 PPTX 提取幻灯片文本] | 贡献维度: 外部能力/文档处理\n"
            "何时使用: 需要读取 .pptx 文件内容（所有幻灯片的文本）\n"
            "何时不用: 非 PPTX 文档用对应的 read_* 工具\n"
            "前置依赖: 文件须存在于工作空间且为 PPTX",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "工作空间内的 PPTX 文件路径",
                }
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "read_xlsx",
        "description": _tool_description(
            "read_xlsx",
            "[解析 XLSX 提取工作表数据] | 贡献维度: 外部能力/文档处理\n"
            "何时使用: 需要读取 .xlsx 文件内容（各工作表数据）\n"
            "何时不用: 非 XLSX 文档用对应的 read_* 工具\n"
            "前置依赖: 文件须存在于工作空间且为 XLSX",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "工作空间内的 XLSX 文件路径",
                }
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "create_docx",
        "description": _tool_description(
            "create_docx",
            "[由文本生成 DOCX 文档] | 贡献维度: 外部能力/文档产出\n"
            "何时使用: 需要产出 .docx 文件（按文本内容，多行用 \\n 分隔）\n"
            "何时不用: 产出非 DOCX 用对应的 create_* 工具\n"
            "前置依赖: 保存路径可写；内容按工具约定的文本格式传入",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "保存路径（如 /workspace/output.docx）",
                },
                "content": {
                    "type": "string",
                    "description": "文档文本内容，多行文本用 \\n 分隔",
                },
            },
            "required": ["file_path", "content"],
        },
    },
    {
        "name": "create_pptx",
        "description": _tool_description(
            "create_pptx",
            "[由 JSON 生成 PPTX 幻灯片] | 贡献维度: 外部能力/文档产出\n"
            "何时使用: 需要产出 .pptx 文件（按 JSON 描述的标题/内容生成）\n"
            "何时不用: 产出非 PPTX 用对应的 create_* 工具\n"
            "前置依赖: 保存路径可写；slides 为合法 JSON 数组字符串",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "保存路径（如 /workspace/output.pptx）",
                },
                "slides": {
                    "type": "string",
                    "description": "JSON 数组字符串，每项格式：{\"title\": \"标题\", \"content\": \"内容\"}",
                },
            },
            "required": ["file_path", "slides"],
        },
    },
    {
        "name": "create_xlsx",
        "description": _tool_description(
            "create_xlsx",
            "[由 JSON 数据生成 XLSX] | 贡献维度: 外部能力/文档产出\n"
            "何时使用: 需要产出 .xlsx 文件（按 JSON 工作表数据生成）\n"
            "何时不用: 产出非 XLSX 用对应的 create_* 工具\n"
            "前置依赖: 保存路径可写；data 为合法 JSON 对象字符串",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "保存路径（如 /workspace/output.xlsx）",
                },
                "data": {
                    "type": "string",
                    "description": "JSON 对象字符串，格式：{\"Sheet1\": [[\"col1\", \"col2\"], [\"val1\", \"val2\"]]}",
                },
            },
            "required": ["file_path", "data"],
        },
    },
]


def _handle_tool_call(name: str, arguments: dict, workspace_id: str, io: WorkspaceIO) -> str:
    """执行工具调用并返回 MCP CallToolResult 的 JSON 字符串。"""
    try:
        result_text = _execute_tool(name, arguments, workspace_id, io)
        return json.dumps({
            "content": [{"type": "text", "text": result_text}],
            "isError": False,
        })
    except Exception as e:
        return json.dumps({
            "content": [{"type": "text", "text": json.dumps({"success": False, "error": str(e)})}],
            "isError": True,
        })


# ── PDF 读取（中文支持 / 目录 / 按章节阅读） ──────────────────────────

# 模板占位符: %%FILE_B64%% / %%MODE_LIT%% / %%CHAPTERS_LIT%% / %%PAGES_LIT%% / %%MAX_CHARS%%
_PDF_SCRIPT_TEMPLATE = r"""
import base64, json, re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
try:
    import pymupdf
except Exception:
    import fitz as pymupdf

def _clean(t):
    if not t:
        return ""
    t = re.sub(r"[ \t]+\n", "\n", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()

def _toc_entries(doc):
    raw = doc.get_toc(simple=True) or []
    entries = []
    for i, item in enumerate(raw):
        try:
            lvl = int(item[0]) if len(item) > 0 else 1
        except Exception:
            lvl = 1
        title = str(item[1]).strip() if len(item) > 1 and item[1] else "(未命名章节)"
        try:
            page = int(item[2]) if len(item) > 2 else 1
        except Exception:
            page = 1
        if page < 1:
            page = 1
        entries.append({"index": i + 1, "level": max(1, lvl), "title": title[:120], "page": page})
    n = len(entries)
    for i, e in enumerate(entries):
        nxt = entries[i + 1]["page"] if i + 1 < n else doc.page_count + 1
        e["page_end"] = max(e["page"], nxt - 1)
    return entries

def _parse_chapters(expr, entries):
    result = []
    used = set()
    if not expr:
        return result
    for tok in re.split(r"[,\uff0c\u3001;；\s]+", expr.strip()):
        tok = tok.strip()
        if not tok:
            continue
        m = re.match(r"(?i)^(?:p|page|页)\s*[:：]?\s*(.+)$", tok)
        if m:
            seg = m.group(1)
            mm = re.fullmatch(r"(\d+)\s*[-~－]\s*(\d+)", seg)
            if mm:
                s, e = int(mm.group(1)), int(mm.group(2))
                if s > e:
                    s, e = e, s
                result.append({"index": None, "title": "第 %d-%d 页" % (s, e), "level": 0, "page": s, "page_end": e})
            elif seg.isdigit():
                n = int(seg)
                result.append({"index": None, "title": "第 %d 页" % n, "level": 0, "page": n, "page_end": n})
            continue
        m = re.fullmatch(r"(\d+)\s*[-~－]\s*(\d+)", tok)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            if a > b:
                a, b = b, a
            for idx in range(a, b + 1):
                if 1 <= idx <= len(entries) and idx not in used:
                    used.add(idx)
                    result.append(entries[idx - 1])
            continue
        if tok.isdigit():
            idx = int(tok)
            if 1 <= idx <= len(entries) and idx not in used:
                used.add(idx)
                result.append(entries[idx - 1])
            continue
        for ent in entries:
            if ent["index"] not in used and tok in ent["title"]:
                used.add(ent["index"])
                result.append(ent)
    return result

def _page_expr(expr):
    expr = (expr or "").strip()
    if not expr:
        return None
    m = re.fullmatch(r"(\d+)\s*[-~－]\s*(\d+)", expr)
    if m:
        s, e = int(m.group(1)), int(m.group(2))
        if s > e:
            s, e = e, s
        return (s, e)
    if expr.isdigit():
        n = int(expr)
        return (n, n)
    return None

def _section_text(doc, ent):
    parts = []
    for pno in range(ent["page"], ent["page_end"] + 1):
        if 1 <= pno <= doc.page_count:
            parts.append(doc[pno - 1].get_text())
    return _clean("\n".join(parts))

def _emit(obj):
    print(json.dumps(obj, ensure_ascii=False))

file_path = base64.b64decode("%%FILE_B64%%").decode("utf-8")
mode = %%MODE_LIT%%
chapters_expr = %%CHAPTERS_LIT%%
pages_expr = %%PAGES_LIT%%
max_chars = int(%%MAX_CHARS%%)

try:
    doc = pymupdf.open(file_path)
except Exception as e:
    _emit({"success": False, "error": "打开 PDF 失败: %s" % e})
    sys.exit(0)

info = {
    "success": True,
    "file": file_path,
    "pages": doc.page_count,
    "title": (doc.metadata or {}).get("title", "") or "",
    "author": (doc.metadata or {}).get("author", "") or "",
}

if mode == "toc":
    entries = _toc_entries(doc)
    info["mode"] = "toc"
    info["toc"] = entries
    if not entries:
        info["note"] = "该 PDF 未包含书签目录；可用 mode=text 按页阅读，或 mode=chapters 配合 p:页-页 指定范围"
    _emit(info)
    sys.exit(0)

if mode == "chapters":
    entries = _toc_entries(doc)
    if not entries:
        if not re.match(r"(?i)^(?:p|page|页)", (chapters_expr or "").strip()):
            info["success"] = False
            info["error"] = "该 PDF 无书签目录，无法按章节选择；可用 chapters=p:5-8 指定页码范围，或使用 mode=text"
            _emit(info)
            sys.exit(0)
    selected = _parse_chapters(chapters_expr, entries) if chapters_expr else []
    if not selected:
        info["success"] = False
        info["error"] = ("chapters=%r 未匹配到章节；请先用 mode=toc 查看目录序号。"
                         "支持: 1 / 1,3-5 / 标题关键词 / p:5-8") % chapters_expr
        _emit(info)
        sys.exit(0)
    budget = max(1, int(max_chars))
    used = 0
    sections = []
    truncated = False
    rest_hint = ""
    for pos, ent in enumerate(selected):
        text = _section_text(doc, ent)
        sec = {
            "index": ent.get("index"),
            "level": ent.get("level", 1),
            "title": ent.get("title", ""),
            "page_start": ent["page"],
            "page_end": ent["page_end"],
        }
        if not text:
            sec["text"] = ""
            sec["note"] = "该章节未提取到文本（可能为扫描件/图片页）"
            sections.append(sec)
            continue
        if used + len(text) > budget:
            remain = budget - used
            if remain >= 64:
                sec["text"] = text[:remain]
                sec["truncated"] = True
                sec["note"] = "该章节文本超出字符预算，已截断"
            else:
                sec["text"] = ""
                sec["truncated"] = True
                sec["note"] = "该章节未返回（字符预算不足）"
            sections.append(sec)
            truncated = True
            rest = []
            for e in selected[pos + 1:]:
                if e.get("index") is not None:
                    rest.append(str(e["index"]))
                else:
                    rest.append("p:%d-%d" % (e["page"], e["page_end"]))
            rest_hint = ", ".join(rest)
            break
        used += len(text)
        sec["text"] = text
        sections.append(sec)
    info["mode"] = "chapters"
    info["count"] = len(sections)
    info["sections"] = sections
    info["truncated"] = truncated
    if rest_hint:
        info["message"] = "未返回章节: " + rest_hint + "（字符预算不足）；可缩小章节范围或分次读取"
    _emit(info)
    sys.exit(0)

if mode == "text":
    rng = _page_expr(pages_expr) if pages_expr else None
    if rng:
        start, end = rng
    else:
        start, end = 1, doc.page_count
    start = max(1, start)
    end = min(doc.page_count, end)
    budget = max(1, int(max_chars))
    used = 0
    out_pages = []
    truncated = False
    for pno in range(start, end + 1):
        t = _clean(doc[pno - 1].get_text())
        if used + len(t) > budget:
            remain = budget - used
            if remain >= 64:
                out_pages.append({"page": pno, "text": t[:remain], "truncated": True})
            truncated = True
            break
        used += len(t)
        out_pages.append({"page": pno, "text": t})
    info["mode"] = "text"
    info["page_range"] = "%d-%d" % (start, end)
    info["pages_result"] = out_pages
    info["truncated"] = truncated
    if truncated:
        last_pg = out_pages[-1]["page"] if out_pages else start
        info["message"] = ("文本超长已截断（max_chars=%d，已返回至第 %d 页）；"
                           "可用 pages=%d-%d 缩小范围") % (budget, last_pg, start, end)
    _emit(info)
    sys.exit(0)

_emit({"success": False, "error": "未知 mode: %s" % mode})
sys.exit(0)
"""


def _run_read_pdf(workspace_id: str, io: WorkspaceIO, arguments: dict) -> str:
    """执行 read_pdf：目录 / 按章节阅读 / 按页全文（含中文支持与截断控制）。"""
    file_path = str(arguments.get("file_path", "") or "").strip()
    if not file_path:
        return json.dumps({"success": False, "error": "缺少 file_path 参数"})
    mode = str(arguments.get("mode", "toc") or "toc").strip().lower()
    if mode not in ("toc", "chapters", "text"):
        return json.dumps({
            "success": False,
            "error": f"无效 mode={mode!r}，可选值: toc | chapters | text",
        })
    chapters = str(arguments.get("chapters", "") or "").strip()
    if mode == "chapters" and not chapters:
        return json.dumps({
            "success": False,
            "error": "mode=chapters 需要 chapters 参数（如 1 / 1,3-5 / 标题关键词 / p:5-8）",
        })
    pages = str(arguments.get("pages", "") or "").strip()
    try:
        max_chars = int(arguments.get("max_chars", 8000) or 8000)
    except (TypeError, ValueError):
        max_chars = 8000
    max_chars = max(1, min(max_chars, 50000))
    # 路径经 base64 传入脚本，规避中文/空格/反斜杠/引号的字符串转义问题
    file_b64 = base64.b64encode(file_path.encode("utf-8")).decode("ascii")
    script = (
        _PDF_SCRIPT_TEMPLATE
        .replace("%%FILE_B64%%", file_b64)
        .replace("%%MODE_LIT%%", json.dumps(mode))
        .replace("%%CHAPTERS_LIT%%", json.dumps(chapters))
        .replace("%%PAGES_LIT%%", json.dumps(pages))
        .replace("%%MAX_CHARS%%", str(max_chars))
    )
    return _dump(_exec_python(workspace_id, io, script))


def _execute_tool(name: str, arguments: dict, workspace_id: str, io: WorkspaceIO) -> str:
    """执行具体工具逻辑。"""
    file_path = arguments.get("file_path", "")

    if name == "read_pdf":
        return _run_read_pdf(workspace_id, io, arguments)

    elif name == "read_docx":
        script = textwrap.dedent(f"""\
            import docx
            doc = docx.Document("{file_path}")
            paragraphs = [p.text for p in doc.paragraphs]
            tables = []
            for table in doc.tables:
                rows = []
                for row in table.rows:
                    rows.append([cell.text for cell in row.cells])
                tables.append(rows)
            print(json.dumps({{"success": True, "paragraphs": paragraphs, "tables": tables}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

    elif name == "read_pptx":
        script = textwrap.dedent(f"""\
            from pptx import Presentation
            prs = Presentation("{file_path}")
            slides = []
            for i, slide in enumerate(prs.slides):
                texts = []
                for shape in slide.shapes:
                    if shape.has_text_frame:
                        texts.append(shape.text)
                slides.append({{"slide": i+1, "texts": texts}})
            print(json.dumps({{"success": True, "slides": slides}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

    elif name == "read_xlsx":
        script = textwrap.dedent(f"""\
            import openpyxl
            wb = openpyxl.load_workbook("{file_path}", data_only=True)
            sheets = []
            for name in wb.sheetnames:
                ws = wb[name]
                rows = []
                for row in ws.iter_rows(values_only=True):
                    rows.append([str(c) if c is not None else "" for c in row])
                sheets.append({{"name": name, "rows": rows}})
            print(json.dumps({{"success": True, "sheets": sheets}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

    elif name == "create_docx":
        content = arguments.get("content", "")
        b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
        script = textwrap.dedent(f"""\
            import base64, docx
            doc = docx.Document()
            text = base64.b64decode("{b64}").decode("utf-8")
            for line in text.split("\\n"):
                doc.add_paragraph(line)
            doc.save("{file_path}")
            print(json.dumps({{"success": True, "file_path": "{file_path}"}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

    elif name == "create_pptx":
        slides = arguments.get("slides", "[]")
        b64 = base64.b64encode(slides.encode("utf-8")).decode("ascii")
        script = textwrap.dedent(f"""\
            import base64, json
            from pptx import Presentation
            prs = Presentation()
            slides_data = json.loads(base64.b64decode("{b64}").decode("utf-8"))
            for s in slides_data:
                slide = prs.slides.add_slide(prs.slide_layouts[1])
                title = slide.shapes.title
                if title and s.get("title"):
                    title.text = s["title"]
                content = slide.placeholders[1]
                if content and s.get("content"):
                    content.text = s["content"]
            prs.save("{file_path}")
            print(json.dumps({{"success": True, "file_path": "{file_path}"}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

    elif name == "create_xlsx":
        data = arguments.get("data", "{}")
        b64 = base64.b64encode(data.encode("utf-8")).decode("ascii")
        script = textwrap.dedent(f"""\
            import base64, json
            import openpyxl
            from openpyxl.styles import Font
            wb = openpyxl.Workbook()
            wb.remove(wb.active)
            sheets_data = json.loads(base64.b64decode("{b64}").decode("utf-8"))
            for sheet_name, rows in sheets_data.items():
                ws = wb.create_sheet(title=sheet_name)
                for row_idx, row_data in enumerate(rows, 1):
                    for col_idx, cell_value in enumerate(row_data, 1):
                        cell = ws.cell(row=row_idx, column=col_idx, value=cell_value)
                        if row_idx == 1:
                            cell.font = Font(bold=True)
            wb.save("{file_path}")
            print(json.dumps({{"success": True, "file_path": "{file_path}"}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

    else:
        return json.dumps({"success": False, "error": f"未知工具: {name}"})


def _handle_request(request: dict, workspace_id: str, io: WorkspaceIO) -> str:
    """处理单个 JSON-RPC 请求，返回 JSON-RPC 响应字符串。"""
    req_id = request.get("id")
    method = request.get("method", "")
    params = request.get("params", {}) or {}

    if method == "initialize":
        return json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": _PROTOCOL_VERSION,
                "capabilities": {
                    "tools": {},
                },
                "serverInfo": {
                    "name": f"document-{workspace_id or 'default'}",
                    "version": "1.0.0",
                },
            },
        })

    elif method == "notifications/initialized":
        # 不需要响应
        return ""

    elif method == "tools/list":
        return json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "tools": TOOLS,
            },
        })

    elif method == "tools/call":
        name = params.get("name", "")
        arguments = params.get("arguments", {}) or {}
        result_text = _handle_tool_call(name, arguments, workspace_id, io)
        # 返回结果已经包含 content
        resp = json.loads(result_text)
        return json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": resp,
        })

    elif method == "ping":
        return json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {},
        })

    else:
        return json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        })


def main() -> None:
    """启动文档处理 MCP stdio server（直接 JSON-RPC over stdio）。"""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s:%(name)s:%(message)s")
    workspace_id = os.environ.get("WORKSPACE_ID", "")
    docker_manager = DockerManager()
    io: WorkspaceIO = CloudWorkspaceIO(docker_manager)

    if not docker_manager.available:
        logger.warning("Docker 不可用，文档处理服务将无法工作")

    logger.info("启动文档处理 MCP server: document-%s", workspace_id or "default")

    # 逐行读取 stdin 的 JSON-RPC 请求，处理后写入 stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            logger.error("无效的 JSON-RPC 请求: %s", line[:200])
            continue

        try:
            response = _handle_request(request, workspace_id, io)
            if response:
                sys.stdout.write(response + "\n")
                sys.stdout.flush()
        except Exception as e:
            logger.error("处理请求失败: %s", e)
            traceback.print_exc()
            error_resp = json.dumps({
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {"code": -32603, "message": str(e)},
            })
            sys.stdout.write(error_resp + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()