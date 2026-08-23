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


def _exec_python(workspace_id: str, io: WorkspaceIO, script: str) -> dict:
    """在工作空间内执行 Python 脚本并返回解析后的 JSON 结果。"""
    # 将脚本内容缩进 4 格（放入 try 块），避免 f-string 多行替换丢失缩进
    indented_script = textwrap.indent(script, "    ")
    full_script = (
        "import json, sys\n"
        "try:\n"
        f"{indented_script}"
        "except Exception as e:\n"
        '    print(json.dumps({"success": False, "error": str(e)}))\n'
    )
    result = run_io(io.exec_argv(workspace_id, ["python3", "-c", full_script]))
    exit_code = result.get("exit_code", -1)
    stdout = result.get("stdout", "") or ""
    stderr = result.get("stderr", "") or ""

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
            "[解析 PDF 提取文本] | 贡献维度: 外部能力/文档处理\n"
            "何时使用: 需要读取 .pdf 文件内容（按页返回文本）\n"
            "何时不用: 非 PDF 文档用 read_docx/read_pptx/read_xlsx\n"
            "前置依赖: 文件须存在于工作空间且为 PDF",
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "工作空间内的 PDF 文件路径（如 /workspace/doc.pdf）",
                }
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


def _execute_tool(name: str, arguments: dict, workspace_id: str, io: WorkspaceIO) -> str:
    """执行具体工具逻辑。"""
    file_path = arguments.get("file_path", "")

    if name == "read_pdf":
        script = textwrap.dedent(f"""\
            import pymupdf
            doc = pymupdf.open("{file_path}")
            pages = [{{"page": i+1, "text": page.get_text()}} for i, page in enumerate(doc)]
            print(json.dumps({{"success": True, "pages": len(doc), "content": pages}}))
        """)
        return _dump(_exec_python(workspace_id, io, script))

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