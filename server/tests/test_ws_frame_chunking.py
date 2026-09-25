# -*- coding: utf-8 -*-
"""WS 大帧分片测试（传输层 frame_begin / frame_chunk / frame_end）。

动因：后端 uvicorn 的 ``ws_max_size`` 默认 16MiB，且**只约束「前端→后端」的
接收方向**；超限会被判 1009 并**静默**关闭连接（``ws/endpoints.py`` 的
``except WebSocketDisconnect: pass`` 吞掉），连带注销执行器注册、打断在途工具
调用。因此出站超限消息需分片，入站分片需重组。

覆盖：
- 阈值内原样单帧透传（不引入额外帧开销）
- 超阈值时产出 begin + N x chunk + end，且重组后与原消息**逐字段相等**
- 分片按 UTF-8 字节预算切分，多字节字符（中文/emoji）不被切断
- 分片时打 warning 日志（可观测性，便于线上定位）
- ``WebSocketManager.send_message`` 在假 WS 上产生有序分片序列
- 入站重装：正常收齐 / 无起始帧丢弃 / TTL 过期清理 / 非分片消息原样放行

隔离：不触碰真实 DB；分片逻辑为纯函数，管理器用假 WebSocket。
"""
import asyncio
import json
import sys
import unittest
from pathlib import Path
from typing import Any, Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ws.ws_manager import (  # noqa: E402
    _WS_CHUNK_PART_BYTES,
    _WS_CHUNK_THRESHOLD_BYTES,
    WebSocketManager,
    chunk_message_frame,
    split_payload_by_bytes,
)


class TestSplitPayloadByBytes(unittest.TestCase):
    """按 UTF-8 字节预算的字符边界切分。"""

    def test_ascii_roundtrip(self):
        text = "a" * 500
        parts = split_payload_by_bytes(text, 64)
        self.assertGreater(len(parts), 1)
        self.assertEqual("".join(parts), text)
        for part in parts:
            self.assertLessEqual(len(part.encode("utf-8")), 64)

    def test_multibyte_roundtrip_not_split(self):
        """中文（3 字节）与 emoji（4 字节）不得被切成半个码点。"""
        text = ("x" * 7 + "中" * 5 + "🙂" * 4) * 200
        parts = split_payload_by_bytes(text, 64)
        self.assertEqual("".join(parts), text)
        for part in parts:
            # 能独立编码即说明未留下孤立代理项
            self.assertLessEqual(len(part.encode("utf-8")), 64)

    def test_single_codepoint_larger_than_budget_still_progresses(self):
        parts = split_payload_by_bytes("中中中", 2)
        self.assertEqual("".join(parts), "中中中")
        self.assertEqual(len(parts), 3)

    def test_empty_and_nonpositive_budget(self):
        self.assertEqual(split_payload_by_bytes("", 64), [""])
        self.assertEqual(split_payload_by_bytes("abc", 0), ["abc"])


class TestChunkMessageFrame(unittest.TestCase):
    """逻辑消息 → 帧序列。"""

    def test_small_message_single_frame(self):
        msg = {"type": "tool_end", "data": {"result": "ok"}}
        self.assertEqual(chunk_message_frame(msg), [msg])

    def test_at_threshold_still_single_frame(self):
        # 构造刚好不超过阈值的消息（阈值是编码后字节数）
        msg = {"type": "x", "data": {"s": "a" * (_WS_CHUNK_THRESHOLD_BYTES - 200)}}
        self.assertLessEqual(
            len(json.dumps(msg, ensure_ascii=False).encode("utf-8")),
            _WS_CHUNK_THRESHOLD_BYTES,
        )
        self.assertEqual(chunk_message_frame(msg), [msg])

    def test_large_message_chunked_and_reassembles(self):
        msg = {"type": "tool_end", "data": {"result": "中" * 7_000_000}}
        frames = chunk_message_frame(msg)
        self.assertGreater(len(frames), 2)
        self.assertEqual(frames[0]["type"], "frame_begin")
        self.assertEqual(frames[-1]["type"], "frame_end")
        self.assertEqual(frames[0]["total"], frames[-1]["total"])

        parts = [f for f in frames[1:-1]]
        self.assertEqual(len(parts), frames[0]["total"])
        self.assertEqual([f["seq"] for f in parts], list(range(len(parts))))
        # 每个分片自身不得超预算
        for frame in parts:
            self.assertLessEqual(
                len(frame["part"].encode("utf-8")), _WS_CHUNK_PART_BYTES
            )
        # 重组后与原消息完全一致（业务层据此无感）
        joined = "".join(f["part"] for f in parts)
        self.assertEqual(json.loads(joined), msg)

    def test_all_frames_share_transfer_id(self):
        msg = {"type": "big", "data": {"s": "x" * (_WS_CHUNK_THRESHOLD_BYTES + 10)}}
        frames = chunk_message_frame(msg)
        ids = {f["id"] for f in frames}
        self.assertEqual(len(ids), 1)

    def test_warning_logged(self):
        msg = {"type": "tool_end", "data": {"result": "中" * 7_000_000}}
        with self.assertLogs("ws.ws_manager", level="WARNING") as ctx:
            chunk_message_frame(msg)
        self.assertTrue(any("分片" in line for line in ctx.output))

    def test_no_warning_for_small_message(self):
        msg = {"type": "small"}
        with self.assertNoLogs("ws.ws_manager", level="WARNING"):
            chunk_message_frame(msg)


class _FakeWS:
    """假 WebSocket：记录 send_json 的帧，可注入失败。"""

    def __init__(self, fail: bool = False) -> None:
        self.sent: List[Dict[str, Any]] = []
        self.closed = False
        self.fail = fail

    async def accept(self) -> None:
        pass

    async def send_json(self, message: Dict[str, Any]) -> None:
        if self.fail:
            raise RuntimeError("send failed")
        self.sent.append(message)

    async def close(self) -> None:
        self.closed = True


def _run(coro):
    return asyncio.run(coro)


class TestSendMessageChunking(unittest.TestCase):
    """WebSocketManager 出站分片（超时按单帧计时，不按整条消息累计）。"""

    def test_small_payload_single_frame(self):
        manager = WebSocketManager()
        ws = _FakeWS()
        _run(manager.connect("u1", ws))
        _run(manager.send_message("u1", {"type": "ping"}))
        self.assertEqual(len(ws.sent), 1)
        self.assertEqual(ws.sent[0]["type"], "ping")

    def test_large_payload_chunked_in_order(self):
        manager = WebSocketManager()
        ws = _FakeWS()
        _run(manager.connect("u1", ws))
        msg = {"type": "tool_end", "data": {"result": "x" * (_WS_CHUNK_THRESHOLD_BYTES + 5)}}
        _run(manager.send_message("u1", msg))

        self.assertGreater(len(ws.sent), 2)
        self.assertEqual(ws.sent[0]["type"], "frame_begin")
        self.assertEqual(ws.sent[-1]["type"], "frame_end")
        parts = ws.sent[1:-1]
        self.assertEqual([f["seq"] for f in parts], list(range(len(parts))))
        self.assertEqual(json.loads("".join(f["part"] for f in parts)), msg)

    def test_targeted_send_chunked(self):
        manager = WebSocketManager()
        ws = _FakeWS()
        cid = _run(manager.connect("u1", ws))
        msg = {"type": "tool_exec_response", "data": {"blob": "y" * (_WS_CHUNK_THRESHOLD_BYTES + 5)}}
        ok = _run(manager.send_to_connection("u1", cid, msg))
        self.assertTrue(ok)
        self.assertEqual(ws.sent[0]["type"], "frame_begin")
        parts = ws.sent[1:-1]
        self.assertEqual(json.loads("".join(f["part"] for f in parts)), msg)

    def test_failing_chunk_removes_connection(self):
        """任一分片发送失败 → 该连接按既有策略被移除（分片不改变失败语义）。"""
        manager = WebSocketManager()
        ws = _FakeWS(fail=True)
        _run(manager.connect("u1", ws))
        _run(manager.send_message("u1", {"type": "ping"}))
        self.assertNotIn("u1", manager.connections)


class TestInboundReassembly(unittest.TestCase):
    """入站分片重装（ws/endpoints.py 的 _reassemble_inbound_frame）。"""

    @classmethod
    def setUpClass(cls):
        from ws import endpoints as ep

        cls.ep = ep

    def setUp(self):
        self.ep._inbound_frames.clear()

    def _frames(self, payload: Dict[str, Any], parts: List[str]) -> List[str]:
        transfer_id = "frg_test"
        out = [json.dumps({
            "type": "frame_begin", "id": transfer_id,
            "total": len(parts), "bytes": sum(len(p.encode()) for p in parts),
        })]
        out.extend(
            json.dumps({
                "type": "frame_chunk", "id": transfer_id, "seq": i, "part": p,
            })
            for i, p in enumerate(parts)
        )
        return out

    def test_non_frame_message_passes_through(self):
        raw = json.dumps({"type": "heartbeat"})
        self.assertEqual(
            self.ep._reassemble_inbound_frame("u1", "c1", raw), raw
        )

    def test_plain_text_passes_through(self):
        self.assertEqual(
            self.ep._reassemble_inbound_frame("u1", "c1", "not json"), "not json"
        )

    def test_reassembles_in_order(self):
        payload = {"type": "user_message", "data": {"content": "中文" * 100}}
        whole = json.dumps(payload, ensure_ascii=False)
        third = len(whole) // 3
        parts = [whole[:third], whole[third:2 * third], whole[2 * third:]]
        frames = self._frames(payload, parts)

        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", frames[0])
        )
        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", frames[1])
        )
        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", frames[2])
        )
        # 最后一片收齐 → 返回重组后的原始 JSON
        result = self.ep._reassemble_inbound_frame("u1", "c1", frames[3])
        self.assertIsNotNone(result)
        self.assertEqual(json.loads(result), payload)
        self.assertFalse(self.ep._inbound_frames)

    def test_out_of_order_chunks_still_reassemble(self):
        payload = {"type": "x", "data": {"s": "abcdefghijklmnopqrstuvwxyz"}}
        whole = json.dumps(payload)
        third = len(whole) // 3
        parts = [whole[:third], whole[third:2 * third], whole[2 * third:]]
        frames = self._frames(payload, parts)
        self.ep._reassemble_inbound_frame("u1", "c1", frames[0])
        # 乱序：先给末片与中间片，最后才补上第二片 → 补全时才返回结果
        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", frames[3])
        )
        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", frames[2])
        )
        result = self.ep._reassemble_inbound_frame("u1", "c1", frames[1])
        self.assertIsNotNone(result)
        self.assertEqual(json.loads(result), payload)

    def test_chunk_without_begin_discarded(self):
        raw = json.dumps({"type": "frame_chunk", "id": "orphan", "seq": 0, "part": "x"})
        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", raw)
        )

    def test_drop_inbound_frames_on_disconnect(self):
        raw = json.dumps({
            "type": "frame_begin", "id": "frg_a", "total": 2, "bytes": 10,
        })
        self.ep._reassemble_inbound_frame("u1", "c1", raw)
        self.assertTrue(self.ep._inbound_frames)
        self.ep._drop_inbound_frames("c1")
        self.assertFalse(self.ep._inbound_frames)

    def test_drop_does_not_touch_sibling_connection(self):
        """同用户并行连接：清理一个连接不得丢掉另一个的残片。"""
        raw_a = json.dumps({
            "type": "frame_begin", "id": "frg_a", "total": 2, "bytes": 10,
        })
        raw_b = json.dumps({
            "type": "frame_begin", "id": "frg_b", "total": 2, "bytes": 10,
        })
        self.ep._reassemble_inbound_frame("u1", "c1", raw_a)
        self.ep._reassemble_inbound_frame("u1", "c2", raw_b)
        self.ep._drop_inbound_frames("c1")
        self.assertEqual(
            [k[1] for k in self.ep._inbound_frames], ["frg_b"]
        )

    def test_expired_sequence_cleaned(self):
        raw = json.dumps({
            "type": "frame_begin", "id": "frg_old", "total": 2, "bytes": 10,
        })
        self.ep._reassemble_inbound_frame("u1", "c1", raw)
        # 人为把起始时刻推到 TTL 之前，下一次调用应清理它
        for buf in self.ep._inbound_frames.values():
            buf.started_at -= self.ep._FRAME_TTL_SECONDS + 1
        other = json.dumps({
            "type": "frame_begin", "id": "frg_new", "total": 1, "bytes": 1,
        })
        self.ep._reassemble_inbound_frame("u1", "c1", other)
        self.assertNotIn(("c1", "frg_old"), self.ep._inbound_frames)

    def test_bad_total_rejected(self):
        raw = json.dumps({
            "type": "frame_begin", "id": "frg_bad", "total": 0, "bytes": 0,
        })
        self.assertIsNone(
            self.ep._reassemble_inbound_frame("u1", "c1", raw)
        )
        self.assertFalse(self.ep._inbound_frames)


if __name__ == "__main__":
    unittest.main()
