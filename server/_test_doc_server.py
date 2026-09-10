"""测试文档 MCP 服务：经 SDK 内存流连接进程内服务，列出工具、测试读取/生成。

服务端在本进程内构建（``document_server.build_server``），执行落点由
``CloudWorkspaceIO``（docker exec）承担——与云端模式的实际链路一致。
"""
import asyncio
import os
import sys
import subprocess
import json

from anyio import create_task_group
from mcp import ClientSession
from mcp.shared.memory import create_client_server_memory_streams

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from io_.workspace_io import CloudWorkspaceIO  # noqa: E402
from io_.docker_manager import DockerManager  # noqa: E402
from mcp_tools import document_server  # noqa: E402


async def test():
    workspace_id = "top"
    server = document_server.build_server(
        workspace_id, CloudWorkspaceIO(DockerManager())
    )

    async with create_client_server_memory_streams() as (client_streams, server_streams):
        async with create_task_group() as task_group:
            task_group.start_soon(
                lambda: server.run(
                    server_streams[0],
                    server_streams[1],
                    server.create_initialization_options(),
                )
            )
            async with ClientSession(*client_streams) as session:
                await session.initialize()

                # 1. 列出工具
                tools = await session.list_tools()
                print(f"=== 工具列表 ({len(tools.tools)} 个) ===")
                for t in tools.tools:
                    print(f"  - {t.name}: {t.description}")

                # 2. 创建测试 PDF
                test_pdf_path = "/workspace/.test_doc_server.pdf"
                subprocess.run([
                    "docker", "exec", f"workspace_{workspace_id}",
                    "python3", "-c",
                    "import pymupdf; doc=pymupdf.open(); "
                    "page=doc.new_page(); page.insert_text((50,50), 'Hello PDF 测试'); "
                    f"doc.save('{test_pdf_path}')"
                ], capture_output=True)

                result = await session.call_tool("read_pdf", {"file_path": test_pdf_path})
                print(f"\n=== read_pdf ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 3. 生成 DOCX
                test_docx_path = "/workspace/.test_doc_server.docx"
                result = await session.call_tool(
                    "create_docx",
                    {"file_path": test_docx_path, "content": "Hello\nWorld\nDocx 测试"}
                )
                print(f"\n=== create_docx ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 4. 读取 DOCX
                result = await session.call_tool("read_docx", {"file_path": test_docx_path})
                print(f"\n=== read_docx ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 5. 生成 XLSX
                test_xlsx_path = "/workspace/.test_doc_server.xlsx"
                data = '{"Sheet1": [["Name", "Age"], ["Alice", "30"], ["Bob", "25"]]}'
                result = await session.call_tool(
                    "create_xlsx",
                    {"file_path": test_xlsx_path, "data": data}
                )
                print(f"\n=== create_xlsx ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 6. 读取 XLSX
                result = await session.call_tool("read_xlsx", {"file_path": test_xlsx_path})
                print(f"\n=== read_xlsx ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 7. 生成 PPTX
                test_pptx_path = "/workspace/.test_doc_server.pptx"
                slides = '[{"title": "Slide 1", "content": "Content 1"}, {"title": "Slide 2", "content": "Content 2"}]'
                result = await session.call_tool(
                    "create_pptx",
                    {"file_path": test_pptx_path, "slides": slides}
                )
                print(f"\n=== create_pptx ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 8. 读取 PPTX
                result = await session.call_tool("read_pptx", {"file_path": test_pptx_path})
                print(f"\n=== read_pptx ===")
                for item in result.content:
                    if hasattr(item, 'text'):
                        print(item.text[:500])

                # 清理
                subprocess.run([
                    "docker", "exec", f"workspace_{workspace_id}",
                    "rm", "-f", test_pdf_path, test_docx_path, test_xlsx_path, test_pptx_path
                ], capture_output=True)

            task_group.cancel_scope.cancel()

    print("\n=== 所有测试完成 ===")


if __name__ == "__main__":
    asyncio.run(test())