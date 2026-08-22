"""临时单测：验证本地模式下 MCPManager 进程内 handler 能列出并调用 read/terminal 工具。"""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from tool.mcp_tool import MCPManager


class FakeLocalExecutor:
    def is_local(self, user_id: str) -> bool:
        return True


def build_io(executor):
    # 最小化 LocalWorkspaceIO 桩：直接返回结果
    class StubIO:
        def __init__(self, e):
            self.e = e

        def read_file(self, workspace_id, path, encoding="utf-8"):
            return {"content": "hello from stub", "file_path": path}

        def exec_shell(self, workspace_id, command, timeout=30):
            return {"exit_code": 0, "stdout": "stub-out", "stderr": ""}

    return StubIO(executor)


def main() -> None:
    from tool import _build_in_process_handler, _get_workspace_tool_defs
    from tool import _build_document_in_process_handler, _get_document_tool_defs

    executor = FakeLocalExecutor()
    io = build_io(executor)

    mgr = MCPManager()
    mgr.register_service(
        "workspace",
        {
            "handler": _build_in_process_handler("top", io),
            "tool_defs": _get_workspace_tool_defs(),
        },
    )
    mgr.register_service(
        "document",
        {
            "handler": _build_document_in_process_handler("top", io),
            "tool_defs": _get_document_tool_defs(),
        },
    )

    tools = mgr.get_tools(force=True)
    names = [t["name"] for t in tools]
    print("tools:", names)
    assert "read" in names, names
    assert "terminal" in names, names
    assert "read_pdf" in names, names
    # 校验每个工具都有 name/description/parameters
    for t in tools:
        assert t["name"], t
        assert t["description"], t
        assert isinstance(t["parameters"], dict), t

    # 调用 read（进程内 handler 分发）
    res = mgr.call_tool("read", {"file_path": "test.txt"})
    print("call read:", res)
    assert res.get("content") == "hello from stub", res
    assert "error" not in res, res

    res2 = mgr.call_tool("terminal", {"command": "echo hi"})
    print("call terminal:", res2)
    assert res2.get("stdout") == "stub-out", res2
    assert "error" not in res2, res2

    # 未知工具应报错
    res3 = mgr.call_tool("no_such", {})
    print("call unknown:", res3)
    assert "error" in res3, res3

    print("LOCAL MCP HANDLER TEST PASSED")


if __name__ == "__main__":
    main()
