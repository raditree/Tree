"""临时冒烟测试：验证内置服务经标准 MCP（SDK 内存流）暴露与调用。

覆盖 cloud / local / ssh 三模式共用的注册形态（``server_factory``）：
工具发现（tools/list）与工具调用（tools/call）都走真实 MCP 协议，差异只在
背后的 WorkspaceIO；这里用 StubIO 代替真实执行环境。
"""
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from tool.mcp_tool import MCPManager, namespaced_tool_name


class StubIO:
    """最小 WorkspaceIO 桩：只实现文档脚本执行所需的 exec_argv。"""

    async def exec_argv(self, workspace_id, argv, timeout=30):
        # 文档工具的工作空间脚本以 print(json) 回传结果，这里直接回一个成功 JSON
        return {
            "exit_code": 0,
            "stdout": json.dumps({"success": True, "stub": True}),
            "stderr": "",
            "error": None,
        }


def main() -> None:
    from mcp_tools import document_server

    io = StubIO()
    mgr = MCPManager()
    mgr.register_service(
        "document",
        {"server_factory": lambda: document_server.build_server("top", io)},
    )

    # 发现：经 initialize + tools/list
    tools = mgr.get_tools(force=True)
    names = [t["name"] for t in tools]
    print("tools:", names)
    assert "read_pdf" in names, names
    for t in tools:
        assert t["name"], t
        assert t["parameters"] is not None, t
        assert t["mcp_name"] == namespaced_tool_name("document", t["name"]), t

    # 调用：模型注入路径（命名空间名）
    res = mgr.call_tool("mcp__document__read_pdf", {"file_path": "test.pdf"})
    print("call namespaced:", res)
    assert res.get("service") == "document", res
    assert "error" not in res, res
    assert '"success": true' in res.get("content", ""), res
    assert res.get("isError") is False, res

    # 调用：mcp 工具 call 兜底路径（裸工具名）
    res2 = mgr.call_tool("read_pdf", {"file_path": "test.pdf"})
    assert res2.get("service") == "document", res2

    # 未知工具 / 未知服务应返回错误而非抛异常
    assert "error" in mgr.call_tool("no_such", {}), "未知工具应报错"
    assert "error" in mgr.call_tool("mcp__no_such_svc__t", {}), "未知服务应报错"

    print("STANDARD MCP (IN-PROC MEMORY STREAM) SMOKE TEST PASSED")


if __name__ == "__main__":
    main()
