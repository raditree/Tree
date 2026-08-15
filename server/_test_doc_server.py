"""测试文档 MCP 服务：启动服务、列出工具、测试读取/生成。"""
import asyncio
import os
import sys
import subprocess
import json

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def test():
    server_script = os.path.join(
        os.path.dirname(__file__), "mcp_tools", "document_server.py"
    )
    params = StdioServerParameters(
        command=sys.executable,
        args=[server_script],
        env={"WORKSPACE_ID": "top"},
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # 1. 列出工具
            tools = await session.list_tools()
            print(f"=== 工具列表 ({len(tools.tools)} 个) ===")
            for t in tools.tools:
                print(f"  - {t.name}: {t.description}")

            # 2. 创建测试 PDF
            test_pdf_path = "/workspace/.test_doc_server.pdf"
            subprocess.run([
                "docker", "exec", "workspace_top",
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
                "docker", "exec", "workspace_top",
                "rm", "-f", test_pdf_path, test_docx_path, test_xlsx_path, test_pptx_path
            ], capture_output=True)

    print("\n=== 所有测试完成 ===")


if __name__ == "__main__":
    asyncio.run(test())