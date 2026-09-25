# -*- coding: utf-8 -*-
"""message 工具（send_message / broadcast / wait_for）回归测试。

覆盖缺陷：
- #7 send_message 明细缺失：多目标 sent/rejected/unknown 逐目标明细齐全，
  unknown 带「先 list_members」hint；成员跨 TOP 寻址被拒并带隔离 hint
- #12 broadcast 直属口径：L1 只命中其自建 L2（实时 DB 名单，不命中平级）；
  0 直属返回 no_recipients + hint，不伪装成功
- #6 wait_for 假完成竞态：从未 working → never_started；先 working 后 idle →
  completed；始终 working → 超时并给出明确 hint

所有用例使用临时 DB（team_members 为名单权威源）。
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.agent_store as agent_store  # noqa: E402
import data.conversation_store as conv  # noqa: E402
import data.db as db_mod  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.spec_store as spec_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402
from tool.message_tool import MessageTool  # noqa: E402

TOP_AGENTS = {
    "top1": {"id": "top1", "name": "顶层A", "model_id": "m1",
             "workspace_id": "top1"},
    "top2": {"id": "top2", "name": "顶层B", "model_id": "m1",
             "workspace_id": "top2"},
}


def _redirect_db_mods(tmpdir: Path) -> None:
    for mod in (conv, session_store, spec_store, team_store, agent_store):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]
    db_mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
    db_mod._wal_configured = False  # type: ignore[attr-defined]


def _fake_get_agents(user_id):
    return list(TOP_AGENTS.values()) if user_id == "u1" else []


def _fake_get_agent(user_id, agent_id):
    return TOP_AGENTS.get(agent_id)


class MessageToolBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_test_"))
        self._orig_db = db_mod._DB_PATH  # type: ignore[attr-defined]
        _redirect_db_mods(self._tmp)
        self._patchers = [
            patch("data.agent_store.get_agents", side_effect=_fake_get_agents),
            patch("data.agent_store.get_agent", side_effect=_fake_get_agent),
        ]
        for p in self._patchers:
            p.start()
        # top1：L1a/L1b 直属 TOP，L2a 直属 L1a
        team_store.init_team("u1", "top1", "顶层A")
        team_store.add_member("u1", "top1", "l1a", "一组组长", level=1,
                              parent_agent_id="top1", model_id="m1")
        team_store.add_member("u1", "top1", "l1b", "二组组长", level=1,
                              parent_agent_id="top1", model_id="m1")
        team_store.add_member("u1", "top1", "l2a", "小兵", level=2,
                              parent_agent_id="l1a", model_id="m2")
        # top2：无成员（用于 0 直属广播）

    def tearDown(self):
        for p in self._patchers:
            p.stop()
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _tool(self, agent_id, leader_id="", team_id="top1",
              dispatcher=None):
        mc = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 8192},
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        return MessageTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc, "m1": mc, "m2": mc},
            broker=MagicMock(),
            user_id="u1",
            agent_id=agent_id,
            leader_id=leader_id,
            team_id=team_id,
            message_dispatcher=dispatcher,
        )


class TestSendMessage(MessageToolBase):
    def test_mixed_details_sent_rejected_unknown(self):
        def _dispatcher(user_id, target_ids, content, source_agent_id="",
                        team_id="", extra=None):
            sent = [t for t in target_ids if t != "l1b"]
            rejected = [t for t in target_ids if t == "l1b"]
            return {"status": "sent" if not rejected else "partial",
                    "sent": sent, "rejected": rejected}

        tool = self._tool("top1", dispatcher=_dispatcher)
        result = tool._action_send_message({
            "target_ids": ["l1a", "l1b", "不存在的成员"], "message": "开工",
        })
        self.assertEqual(result["status"], "partial")
        self.assertEqual(len(result["details"]), 3)
        self.assertEqual(result["sent"], ["l1a"])
        self.assertEqual([r["id"] for r in result["rejected"]], ["l1b"])
        self.assertEqual(result["unknown"][0]["target"], "不存在的成员")
        self.assertEqual(result["unknown"][0]["reason"], "not_found")
        self.assertIn("hint", result)
        self.assertIn("未解析目标", result["hint"])
        # unknown 提示引导先查名单
        self.assertIn("list_members", result["hint"])
        self.assertRegex(
            result["generated_at"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        )

    def test_all_sent_status(self):
        def _dispatcher(user_id, target_ids, content, source_agent_id="",
                        team_id="", extra=None):
            return {"status": "sent", "sent": list(target_ids), "rejected": []}

        tool = self._tool("top1", dispatcher=_dispatcher)
        result = tool._action_send_message({
            "target_ids": ["l1a", "l1b"], "message": "开工",
        })
        self.assertEqual(result["status"], "sent")
        self.assertEqual(sorted(result["sent"]), ["l1a", "l1b"])
        self.assertEqual(result["unknown"], [])
        # 投递成功时带"回复机制"提醒：系统不代回传总结 + 提醒防交火
        self.assertIn("不会替对方回传总结", result["hint"])

    def test_member_cross_top_denied_with_isolation_hint(self):
        """成员（非 TOP）跨 TOP 寻址被拒，hint 说明需经直属 leader 转达。"""
        tool = self._tool("l1a", leader_id="top1")
        result = tool._action_send_message({
            "target_member_id": "顶层B", "message": "协作",
        })
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["unknown"][0]["reason"], "cross_top_denied")
        self.assertIn("跨 TOP", result["hint"])
        self.assertIn("leader", result["hint"])

    def test_missing_message_rejected(self):
        tool = self._tool("top1")
        result = tool._action_send_message({"target_member_id": "l1a"})
        self.assertIn("error", result)
        self.assertIn("message", str(result))

    def test_missing_target_rejected(self):
        tool = self._tool("top1")
        result = tool._action_send_message({"message": "hi"})
        self.assertIn("error", result)
        self.assertIn("target_member_id", str(result))

    def test_delivery_failure_reported_as_rejected(self):
        def _dispatcher(user_id, target_ids, content, source_agent_id="",
                        team_id="", extra=None):
            return {"status": "error", "sent": [], "rejected": list(target_ids)}

        tool = self._tool("top1", dispatcher=_dispatcher)
        result = tool._action_send_message({
            "target_member_id": "l1a", "message": "hi",
        })
        self.assertEqual(result["status"], "error")
        self.assertEqual([r["id"] for r in result["rejected"]], ["l1a"])


class TestBroadcast(MessageToolBase):
    def test_broadcast_only_direct_children(self):
        """L1 广播只命中其自建 L2，不命中平级/上级。"""
        calls = []

        def _dispatcher(user_id, target_ids, content, source_agent_id="",
                        team_id="", extra=None):
            calls.append(list(target_ids))
            return {"status": "sent", "sent": list(target_ids),
                    "rejected": []}

        tool = self._tool("l1a", leader_id="top1", dispatcher=_dispatcher)
        result = tool._action_broadcast({"message": "集合"})
        self.assertEqual(result["status"], "broadcast")
        self.assertEqual(result["recipients"], ["l2a"])
        self.assertEqual(result["recipient_count"], 1)
        self.assertEqual(calls, [["l2a"]])

    def test_broadcast_no_direct_recipients(self):
        """0 直属成员：返回 no_recipients + hint，不伪装成功。"""
        tool = self._tool("top2", team_id="top2")
        result = tool._action_broadcast({"message": "集合"})
        self.assertEqual(result["status"], "no_recipients")
        self.assertEqual(result["recipients"], [])
        self.assertEqual(result["recipient_count"], 0)
        self.assertIn("没有直属成员", result["hint"])
        self.assertIn("send_message", result["hint"])

    def test_broadcast_missing_message(self):
        tool = self._tool("l1a", leader_id="top1")
        result = tool._action_broadcast({})
        self.assertIn("error", result)


class TestWaitFor(MessageToolBase):
    def _wait(self, tool, grace=0.05, interval=0.01, **args):
        with patch.object(MessageTool, "START_GRACE_SEC", grace), \
                patch.object(MessageTool, "POLL_INTERVAL_SEC", interval):
            return tool._action_wait_for(args)

    def test_never_started_when_never_working(self):
        """目标从未进入 working → never_started（修复假完成竞态）。"""
        tool = self._tool("top1")
        with patch.object(MessageTool, "_live_work_status", return_value="idle"):
            result = self._wait(tool, target_member_ids="l1a", timeout=1)
        row = result["members"][0]
        self.assertEqual(row["outcome"], "never_started")
        self.assertFalse(result["timed_out"])
        self.assertIn("未观测到工作状态", result["hint"])
        self.assertIn("agentspace/l1a/.self/activity.log", result["hint"])

    def test_completed_after_working_then_idle(self):
        """先观测到 working、后转 idle → completed。"""
        tool = self._tool("top1")
        seq = ["working", "idle"]

        def _status(member_id):
            return seq.pop(0) if seq else "idle"

        with patch.object(MessageTool, "_live_work_status", side_effect=_status):
            result = self._wait(tool, target_member_ids="l1a", timeout=2)
        self.assertEqual(result["members"][0]["outcome"], "completed")
        self.assertFalse(result["timed_out"])

    def test_timeout_while_working_gives_hint(self):
        """始终 working → 超时，hint 说明需对方主动回发或自行核实/追问。"""
        tool = self._tool("top1")
        with patch.object(MessageTool, "_live_work_status", return_value="working"):
            result = self._wait(tool, target_member_ids="l1a", timeout=1)
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["members"][0]["outcome"], "working")
        self.assertIn("等待超时", result["hint"])
        # 总结自动回传已移除：提示明确"若主动回发才会唤醒"，并要求自行核实
        self.assertIn("主动回发消息", result["hint"])

    def test_unknown_target_rejected(self):
        tool = self._tool("top1")
        result = self._wait(tool, target_member_ids="不存在", timeout=1)
        self.assertIn("error", result)
        self.assertIn("list_members", result["hint"])

    def test_missing_targets(self):
        tool = self._tool("top1")
        result = self._wait(tool, timeout=1)
        self.assertIn("error", result)


if __name__ == "__main__":
    unittest.main()
