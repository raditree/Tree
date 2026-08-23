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
    def test_reset_member_status_to_idle_updates_store(self):
        """复位成员状态：向 team_members 表写 idle。"""
        from agent import chat

        with patch("data.team_store.update_member") as upd:
            _reset_member_status_to_idle("u1", "top1", "m1")
        upd.assert_called_once()
        args, kwargs = upd.call_args
        self.assertEqual(args[0], "top1")
        self.assertEqual(args[1], "m1")
        self.assertEqual(kwargs.get("work_status"), "idle")
        self.assertEqual(kwargs.get("current_task"), "")

    def test_reset_member_status_to_idle_empty_input(self):
        """缺参时静默返回，不抛异常。"""
        from agent import chat

        with patch("data.team_store.update_member") as upd:
            _reset_member_status_to_idle("", "top1", "m1")
            _reset_member_status_to_idle("u1", "", "m1")
            _reset_member_status_to_idle("u1", "top1", "")
        upd.assert_not_called()


if __name__ == "__main__":
    unittest.main()
