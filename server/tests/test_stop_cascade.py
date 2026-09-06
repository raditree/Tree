# -*- coding: utf-8 -*-
"""停止级联测试：取消全部任务 / broker 清队列 / 状态复位。

覆盖 spec「停止按钮级联」：
- _cancel_all_agent_tasks 取消指定 agent 全部会话的进行中任务（不止当前会话）
- TeamMessageBroker.cancel_agent 清空排队消息（防停止后成员被残留消息拉起）
- _reset_member_status_to_idle 复位成员持久化工作状态（team_members 表）
"""

import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.chat import (  # noqa: E402
    _active_tasks,
    _cancel_all_agent_tasks,
    _reset_member_status_to_idle,
)
from agent.team_broker import TeamMessageBroker  # noqa: E402


class TestCancelAllAgentTasks(unittest.TestCase):
    def setUp(self):
        # 清空全局任务表，避免影响其他测试
        _active_tasks.clear()

    def tearDown(self):
        _active_tasks.clear()

    def test_cancel_all_sessions(self):
        """同一 agent 的所有会话任务都被取消，其他 agent 不受影响。"""
        e1 = threading.Event()
        e2 = threading.Event()
        e3 = threading.Event()
        _active_tasks[("u1", "a1", "s1")] = e1
        _active_tasks[("u1", "a1", "s2")] = e2
        _active_tasks[("u1", "a2", "s1")] = e3

        cancelled = _cancel_all_agent_tasks("u1", "a1")

        self.assertTrue(e1.is_set())
        self.assertTrue(e2.is_set())
        self.assertFalse(e3.is_set(), "其他 agent 的任务不应被取消")
        # 返回已取消的键列表
        self.assertEqual(
            sorted(cancelled),
            sorted([("u1", "a1", "s1"), ("u1", "a1", "s2")]),
        )

    def test_no_task_noop(self):
        """无进行中任务时返回空列表（幂等）。"""
        self.assertEqual(_cancel_all_agent_tasks("u1", "a1"), [])


class TestTeamBrokerCancel(unittest.TestCase):
    def test_cancel_agent_clears_queue(self):
        """cancel_agent 清空该 agent 的排队消息，不影响其他成员。"""
        async def _process(payload, queue):
            pass

        broker = TeamMessageBroker(process_fn=_process)
        broker.dispatch(("u1", "m1"), {"content": "1"})
        broker.dispatch(("u1", "m1"), {"content": "2"})
        broker.dispatch(("u1", "m2"), {"content": "x"})

        cleared = broker.cancel_agent("u1", "m1")
        self.assertEqual(cleared, 2)
        self.assertEqual(broker._queues[("u1", "m1")].qsize(), 0)
        # 其他成员队列不受影响
        self.assertEqual(broker._queues[("u1", "m2")].qsize(), 1)

    def test_cancel_agent_no_queue(self):
        """无队列/未注册 agent：返回 0，不报错。"""
        broker = TeamMessageBroker(process_fn=None)
        self.assertEqual(broker.cancel_agent("u1", "ghost"), 0)


class TestResetMemberStatus(unittest.TestCase):
    def test_reset_member_status_to_idle_noop(self):
        """状态治理：_reset_member_status_to_idle 为兼容占位，不再写表。"""
        from agent import chat

        with patch("data.team_store.update_member") as upd:
            _reset_member_status_to_idle("u1", "top1", "m1")
        upd.assert_not_called()

    def test_reset_member_status_to_idle_empty_input(self):
        """缺参时静默返回，不抛异常。"""
        from agent import chat

        with patch("data.team_store.update_member") as upd:
            _reset_member_status_to_idle("", "top1", "m1")
            _reset_member_status_to_idle("u1", "", "m1")
            _reset_member_status_to_idle("u1", "top1", "")
        upd.assert_not_called()


class TestLiveStatus(unittest.TestCase):
    """状态治理：工作状态唯一权威是 _active_tasks（实际 tool loop 登记）。"""

    def setUp(self):
        _active_tasks.clear()

    def tearDown(self):
        _active_tasks.clear()

    def test_is_agent_working_reflects_registration(self):
        """登记了 tool loop 任务才 working；清除后立即 idle（非表/roster 快照）。"""
        from agent.chat import _is_agent_working

        self.assertFalse(_is_agent_working("u1", "m1"))
        _active_tasks[("u1", "m1", "s1")] = threading.Event()
        self.assertTrue(_is_agent_working("u1", "m1"))
        _active_tasks.pop(("u1", "m1", "s1"), None)
        self.assertFalse(_is_agent_working("u1", "m1"))

    def test_live_work_status_ignores_stale_table_status(self):
        """即使成员内存/表 work_status 残留 working，实际无任务登记仍返回 idle。"""
        from tool.team_tool import TeamTool
        from config.models import ModelConfig
        from unittest.mock import MagicMock

        mc = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 8192},
        )
        session = MagicMock()
        session.workspace_id = "ws1"
        tool = TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id="u1",
            agent_id="top1",
            leader_id="",
            team_id="top1",
        )
        # 表/内存中残留假 working（历史遗留），但 _active_tasks 无登记
        tool.members = [{"id": "m1", "name": "成员", "work_status": "working"}]
        self.assertEqual(tool._live_work_status("m1"), "idle")
        # 实际登记后才是 working
        _active_tasks[("u1", "m1", "s1")] = threading.Event()
        self.assertEqual(tool._live_work_status("m1"), "working")

    def test_update_member_rejects_work_status(self):
        """update_member 拒绝写入 work_status（状态为只读，由实际执行决定）。"""
        from tool.team_tool import TeamTool
        from config.models import ModelConfig
        from unittest.mock import MagicMock

        mc = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 8192},
        )
        session = MagicMock()
        session.workspace_id = "ws1"
        tool = TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id="u1",
            agent_id="top1",
            leader_id="",
            team_id="top1",
        )
        tool.members = [{"id": "m1", "name": "成员", "work_status": "idle"}]
        result = tool._action_update_member(
            {"target_member_id": "m1", "work_status": "working"}
        )
        self.assertIn("error", result)
        self.assertIn("只读", str(result))
        self.assertEqual(tool.members[0]["work_status"], "idle")


if __name__ == "__main__":
    unittest.main()
