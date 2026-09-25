# -*- coding: utf-8 -*-
"""message 文件发送（跨 agent 文件传输）测试。

需求与既定策略：
- **同 team 成员之间**：文件本就在共享工作根内（本地全队共用 baseDir、云端同卷、
  SSH 同远端根），因此"发送"只是共享目录内 ``cp``——**后端不接触文件内容**；
- **跨 TOP / 跨模式**：后端内存中转（源端按块读、目标端写），不落盘、不经 docker；
- **任一端 cloud**：由 CloudWorkspaceIO 落 docker（前端执行器触达不到容器，
  这是不可绕过的边界）。

覆盖：
- copy_file 同根走 cp（不调用 read/write 字节通道）
- copy_file 跨根走中转（分块、上限拒绝、源不存在、写失败）
- 落点语义（默认 .input/<日期>/、dest_dir 覆盖、目标文件名沿用）
- MessageTool.send_message 的 files 参数：路径写进正文、明细回传
- IO 层新契约：LocalWorkspaceIO 的 read_file_base64/write_file_base64 映射
  （含 offset/length 透传）
"""
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import io_.file_transfer as ft  # noqa: E402


class _FakeIO:
    """可控的假 WorkspaceIO：shell 与字节通道都被记录。"""

    def __init__(self, files=None, fail_write=False, unsupported=False,
                 fail_shell=False):
        # files: {path: bytes}
        self.files = dict(files or {})
        self.fail_write = fail_write
        self.unsupported = unsupported
        self.fail_shell = fail_shell
        self.shell_calls = []
        self.reads = []
        self.writes = []

    async def exec_shell(self, workspace_id, command, timeout=30):
        self.shell_calls.append((workspace_id, command))
        # 注意用 startswith：复制命令末尾也带 `wc -c < dst`，用 `in` 会把
        # 复制命令误判成探测命令（探测命令形如 `wc -c < src 2>/dev/null || true`）
        if command.startswith("wc -c <"):
            src = command.split("wc -c <")[1].strip().split()[0].strip("'")
            if src in self.files:
                return {"exit_code": 0, "stdout": f"{len(self.files[src])}\n"}
            return {"exit_code": 0, "stdout": ""}
        if self.fail_shell:
            return {"exit_code": 1, "stderr": "permission denied"}
        # 复制命令：直接模拟成功并回报目标大小
        return {"exit_code": 0, "stdout": "42\n"}

    async def read_file_base64(self, workspace_id, path, offset=0, length=0):
        if self.unsupported:
            raise AttributeError("unsupported")
        self.reads.append((workspace_id, path, offset, length))
        data = self.files.get(path, b"")
        start = max(0, offset)
        chunk = data[start:start + length] if length else data[start:]
        return {"exit_code": 0, "chunk": chunk, "eof": len(chunk) < length if length else True}

    async def write_file_base64(self, workspace_id, path, data):
        if self.unsupported:
            raise AttributeError("unsupported")
        if self.fail_write:
            return {"error": "磁盘写入失败"}
        self.writes.append((workspace_id, path, data))
        self.files[path] = data
        return {"success": True, "file_path": path}


class TestSameRootCopy(unittest.TestCase):
    """同共享工作根：cp 路径，后端不接触内容。"""

    def test_uses_cp_and_never_touches_byte_channels(self):
        io = _FakeIO({"out/report.md": b"hello"})
        result = ft.copy_file(io, "ws", "out/report.md", io, "ws")
        self.assertNotIn("error", result)
        self.assertEqual(result["kind"], "same_root")
        self.assertTrue(result["dest_path"].endswith("report.md"))
        # 关键：没有走字节读/写（内容不经过后端）
        self.assertEqual(io.reads, [])
        self.assertEqual(io.writes, [])
        # 确实执行了 cp
        joined = " ".join(c for _, c in io.shell_calls)
        self.assertIn("cp -f", joined)

    def test_dest_is_under_input_dir_with_same_basename(self):
        io = _FakeIO({"a/b/data.csv": b"x"})
        result = ft.copy_file(io, "ws", "a/b/data.csv", io, "ws")
        self.assertNotIn("error", result)
        self.assertTrue(result["dest_path"].startswith(".input/"))
        self.assertTrue(result["dest_path"].endswith("data.csv"))

    def test_dest_dir_override(self):
        io = _FakeIO({"a/f.txt": b"x"})
        result = ft.copy_file(io, "ws", "a/f.txt", io, "ws", dest_dir="shared/inbox")
        self.assertEqual(result["dest_path"], "shared/inbox/f.txt")

    def test_dest_name_override(self):
        io = _FakeIO({"a/f.txt": b"x"})
        result = ft.copy_file(
            io, "ws", "a/f.txt", io, "ws", dest_dir="d", dest_name="renamed.md"
        )
        self.assertEqual(result["dest_path"], "d/renamed.md")

    def test_missing_source_reported(self):
        io = _FakeIO({})
        result = ft.copy_file(io, "ws", "nope.txt", io, "ws")
        self.assertIn("error", result)
        self.assertIn("不存在", result["error"])

    def test_copy_failure_reported(self):
        io = _FakeIO({"a/f.txt": b"x"}, fail_shell=True)
        result = ft.copy_file(io, "ws", "a/f.txt", io, "ws")
        self.assertIn("error", result)
        self.assertIn("复制文件失败", result["error"])

    def test_different_workspace_uses_relay_not_cp(self):
        """不同工作空间 id（跨 TOP）不能用 cp：cp 只在同一物理根内成立。"""
        src = _FakeIO({"a/f.txt": b"payload"})
        dst = _FakeIO({})
        result = ft.copy_file(src, "ws-a", "a/f.txt", dst, "ws-b")
        self.assertEqual(result["kind"], "relay")
        # 源端不得执行任何 shell（cp 只在同根成立）；中转只走字节通道
        self.assertEqual(src.shell_calls, [])
        self.assertEqual(len(src.reads), 1)
        self.assertEqual(len(dst.writes), 1)


class TestRelayCopy(unittest.TestCase):
    """跨工作根：后端内存中转。"""

    def test_relay_copies_bytes(self):
        src = _FakeIO({"a/f.txt": b"payload-1234"})
        dst = _FakeIO({})
        result = ft.copy_file(src, "ws-a", "a/f.txt", dst, "ws-b")
        self.assertNotIn("error", result)
        self.assertEqual(result["kind"], "relay")
        self.assertEqual(result["size"], len(b"payload-1234"))
        _, path, data = dst.writes[0]
        self.assertTrue(path.startswith(".input/"))
        self.assertEqual(data, b"payload-1234")

    def test_relay_chunks_reads(self):
        """大文件按块读，不整文件一次性驻留内存。"""
        blob = b"x" * (ft._RELAY_CHUNK * 3 + 7)
        src = _FakeIO({"a/big.bin": blob})
        dst = _FakeIO({})
        result = ft.copy_file(src, "ws-a", "a/big.bin", dst, "ws-b")
        self.assertNotIn("error", result)
        self.assertGreater(len(src.reads), 1)
        _, _, data = dst.writes[0]
        self.assertEqual(data, blob)

    def test_relay_rejects_oversize(self):
        src = _FakeIO({})
        big = ft._RELAY_CHUNK
        # 让读取永远返回满块，触发上限
        async def _read(workspace_id, path, offset=0, length=0):
            return {"exit_code": 0, "chunk": b"y" * big, "eof": False}

        src.read_file_base64 = _read  # type: ignore[assignment]
        dst = _FakeIO({})
        # 上限压到 2 块：按真实 32MiB 上限要跑 512 轮 run_io（每轮新建一个事件
        # 循环），在 Windows 上偶发事件循环生命周期竞态导致假失败。这里只测
        # "超限即拒绝"的逻辑，量级口径由 test_relay_cap_is_32mib 单独锁定。
        with patch.object(ft, "MAX_RELAY_BYTES", big * 2):
            result = ft.copy_file(src, "ws-a", "a/big.bin", dst, "ws-b")
        self.assertIn("error", result)
        self.assertIn("中转上限", result["error"])

    def test_relay_cap_is_32mib(self):
        """中转上限口径固定 32 MiB（同根 cp 不受此限）。"""
        self.assertEqual(ft.MAX_RELAY_BYTES, 32 * 1024 * 1024)

    def test_relay_reports_read_error(self):
        src = _FakeIO({})

        async def _read(workspace_id, path, offset=0, length=0):
            return {"error": "文件不存在或无法读取"}

        src.read_file_base64 = _read  # type: ignore[assignment]
        dst = _FakeIO({})
        result = ft.copy_file(src, "ws-a", "a/f.txt", dst, "ws-b")
        self.assertIn("error", result)
        self.assertIn("读取源文件失败", result["error"])

    def test_relay_reports_write_error(self):
        src = _FakeIO({"a/f.txt": b"data"})
        dst = _FakeIO({}, fail_write=True)
        result = ft.copy_file(src, "ws-a", "a/f.txt", dst, "ws-b")
        self.assertIn("error", result)
        self.assertIn("写入目标文件失败", result["error"])

    def test_relay_unsupported_io_returns_hint(self):
        """IO 未提供字节通道时给出明确提示而不是抛栈。"""

        class _NoByteIO:
            async def exec_shell(self, workspace_id, command, timeout=30):
                return {"exit_code": 0, "stdout": ""}

        result = ft.copy_file(_NoByteIO(), "ws-a", "a/f.txt", _NoByteIO(), "ws-b")
        self.assertIn("error", result)
        self.assertIn("不支持", result["error"])

    def test_relay_handles_io_raising_attribute_error(self):
        """旧实现把缺失方法表现为抛 AttributeError 时也不应崩溃。"""
        src = _FakeIO({"a/f.txt": b"data"}, unsupported=True)
        dst = _FakeIO({}, unsupported=True)
        result = ft.copy_file(src, "ws-a", "a/f.txt", dst, "ws-b")
        self.assertIn("error", result)


class TestHelpers(unittest.TestCase):
    def test_default_dest_dir_is_dated_input(self):
        import datetime

        expected = ".input/" + datetime.datetime.now().strftime("%Y%m%d")
        self.assertEqual(ft.default_dest_dir(), expected)

    def test_norm_strips_and_unifies(self):
        self.assertEqual(ft._norm("  ./a\\b/c.txt "), "a/b/c.txt")
        self.assertEqual(ft._norm("/abs/path"), "abs/path")

    def test_hint_block_lists_paths(self):
        block = ft.hint_block([
            {"dest_path": ".input/20260101/r.md", "size": 12},
        ])
        self.assertIn("read", block)
        self.assertIn(".input/20260101/r.md", block)
        self.assertIn("12", block)

    def test_hint_block_empty(self):
        self.assertEqual(ft.hint_block([]), "")

    def test_encode_decode_roundtrip(self):
        raw = bytes(range(256))
        self.assertEqual(ft.decode(ft.encode(raw)), raw)


class TestMessageToolFiles(unittest.TestCase):
    """send_message 的 files 参数：复制 + 路径写进正文 + 明细回传。"""

    def _tool(self):
        from tool.message_tool import MessageTool

        session = MagicMock()
        session.workspace_id = "ws-top"
        session.agent_name = "TOP"
        tool = MessageTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={},
            broker=MagicMock(),
            user_id="u1",
            agent_id="top1",
            leader_id="",
            team_id="top1",
        )
        tool.members = [
            {"id": "m1", "name": "成员甲", "parent_agent_id": "top1"},
        ]
        return tool

    def test_files_copied_and_paths_injected(self):
        tool = self._tool()
        captured = {}

        def _deliver(resolved, body):
            captured["body"] = body
            return "sent"

        tool._deliver_one = _deliver  # type: ignore[method-assign]
        with patch.object(
            tool, "_deliver_files",
            return_value={
                "copied": [{"source": "out/r.md", "dest_path": ".input/20260101/r.md",
                            "size": 5, "kind": "same_root"}],
                "failed": [],
            },
        ) as mock_copy:
            result = tool.execute({
                "action": "send_message",
                "target_member_id": "m1",
                "message": "报告已生成",
                "files": ["out/r.md"],
            })
        self.assertEqual(result["status"], "sent")
        mock_copy.assert_called_once()
        # 原消息保留，文件清单追加在后
        self.assertIn("报告已生成", captured["body"])
        self.assertIn(".input/20260101/r.md", captured["body"])
        detail = result["details"][0]
        self.assertEqual(len(detail["files_copied"]), 1)

    def test_files_failure_reported_not_fatal(self):
        tool = self._tool()
        tool._deliver_one = lambda resolved, body: "sent"  # type: ignore[method-assign]
        with patch.object(
            tool, "_deliver_files",
            return_value={"copied": [], "failed": [{"path": "nope.txt",
                                                    "error": "源文件不存在"}]},
        ):
            result = tool.execute({
                "action": "send_message",
                "target_member_id": "m1",
                "message": "hi",
                "files": ["nope.txt"],
            })
        # 消息仍投递成功，失败文件在明细里体现（不因附件失败而不发消息）
        self.assertEqual(result["status"], "sent")
        self.assertEqual(result["details"][0]["files_failed"][0]["path"], "nope.txt")

    def test_no_files_keeps_plain_body(self):
        tool = self._tool()
        captured = {}
        tool._deliver_one = lambda resolved, body: (captured.setdefault("b", body), "sent")[1]  # type: ignore[method-assign]
        with patch.object(tool, "_deliver_files") as mock_copy:
            tool.execute({
                "action": "send_message", "target_member_id": "m1", "message": "纯文本",
            })
        mock_copy.assert_not_called()
        self.assertEqual(captured["b"], "纯文本")

    def test_files_accepts_string_shorthand(self):
        tool = self._tool()
        tool._deliver_one = lambda resolved, body: "sent"  # type: ignore[method-assign]
        with patch.object(
            tool, "_deliver_files", return_value={"copied": [], "failed": []}
        ) as mock_copy:
            tool.execute({
                "action": "send_message", "target_member_id": "m1",
                "message": "hi", "files": "out/one.md",
            })
        passed = mock_copy.call_args[0][1]
        self.assertEqual(passed, ["out/one.md"])

    def test_tool_definition_exposes_files(self):
        props = self._tool().get_tool_definition()["function"]["parameters"]["properties"]
        self.assertIn("files", props)
        self.assertIn("dest_dir", props)


class TestLocalWorkspaceIoByteContract(unittest.TestCase):
    """LocalWorkspaceIO 的字节通道映射（含 offset/length 透传）。"""

    def _io(self):
        from io_.workspace_io import LocalWorkspaceIO

        executor = MagicMock()
        returned = {"exit_code": 0, "content_base64": ""}
        executor.request.return_value = returned
        io = LocalWorkspaceIO(executor, MagicMock(), "u1", "top1")
        return io, executor

    def test_read_maps_offset_and_length(self):
        io, executor = self._io()
        import base64

        executor.request.return_value = {
            "exit_code": 0, "content_base64": base64.b64encode(b"abcd").decode(),
        }
        import asyncio

        result = asyncio.run(io.read_file_base64("ws", "a.txt", offset=4, length=4))
        self.assertEqual(result["chunk"], b"abcd")
        payload = executor.request.call_args[0][2]
        self.assertEqual(payload["op"], "read_file_bytes")
        self.assertEqual(payload["offset"], 4)
        self.assertEqual(payload["length"], 4)

    def test_read_eof_when_short(self):
        io, executor = self._io()
        import base64

        executor.request.return_value = {
            "exit_code": 0, "content_base64": base64.b64encode(b"ab").decode(),
        }
        import asyncio

        result = asyncio.run(io.read_file_base64("ws", "a.txt", offset=0, length=8))
        self.assertTrue(result["eof"])

    def test_write_uses_upload_file_channel(self):
        io, executor = self._io()
        executor.request.return_value = {"success": True}
        import asyncio

        result = asyncio.run(io.write_file_base64("ws", ".input/d/f.bin", b"\x00\x01"))
        self.assertNotIn("error", result)
        payload = executor.request.call_args[0][2]
        self.assertEqual(payload["op"], "upload_file")
        self.assertEqual(payload["rel_path"], ".input/d/f.bin")
        import base64

        self.assertEqual(base64.b64decode(payload["data_base64"]), b"\x00\x01")


if __name__ == "__main__":
    unittest.main()
