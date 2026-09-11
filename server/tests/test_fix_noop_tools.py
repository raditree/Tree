# -*- coding: utf-8 -*-
"""修复"类 no-op 工具"（列表结果被截断成数量）与 selected spec 注入的单元测试。

覆盖：
- llm._stringify_tool_result：list 字段展开具体项（models/specs/teams/members），
  而非只显示数量（问题 1/4 根因）。
- spec_tool.current_status_text：selected spec 三类文案
  （未选择 / 已选但无内置 / 正常含内置），并标注内置/自定义（问题 3）。
- spec search/list 返回项标注 builtin 字段（问题 4）。
- TeamTool._action_list_models 返回具体模型（配合 _stringify 展开，问题 1）。
"""

import unittest
from unittest.mock import MagicMock, patch

from config.models import ModelConfig
from llm.llm import _stringify_tool_result


class TestStringifyToolResultLists(unittest.TestCase):
    """_stringify_tool_result 列表字段必须展开具体项，而非只给数量。"""

    def test_models_list_expanded_not_count_only(self):
        out = _stringify_tool_result({
            "models": [
                {"model_id": "deepseek-v4-flash-0731", "name": "DeepSeek V4"},
                {"model_id": "gpt-4o", "name": "GPT-4o"},
            ],
            "total": 2,
        })
        self.assertIn("模型列表: 2 项", out)
        self.assertIn("model_id=deepseek-v4-flash-0731", out)
        self.assertIn("name=DeepSeek V4", out)
        self.assertIn("总数: 2", out)

    def test_specs_list_expanded_with_builtin(self):
        out = _stringify_tool_result({
            "specs": [
                {"id": "easy-task", "task_type": "easy",
                 "title": "简单任务", "builtin": True},
                {"id": "my-spec", "task_type": "custom",
                 "title": "自定义", "builtin": False},
            ],
            "count": 2,
        })
        self.assertIn("Spec列表: 2 项", out)
        self.assertIn("id=easy-task", out)
        self.assertIn("builtin=是", out)
        self.assertIn("id=my-spec", out)
        self.assertIn("builtin=否", out)

    def test_members_list_expanded_empty_model_id_visible(self):
        # 空 model_id 字段也要可见（配合自动回退机制，模型能感知字段存在）
        out = _stringify_tool_result({
            "members": [
                {"id": "m1", "name": "婉宁", "role": "产品经理",
                 "duty": "需求", "model_id": ""},
            ],
        })
        self.assertIn("成员列表: 1 项", out)
        self.assertIn("id=m1", out)
        self.assertIn("model_id=", out)

    def test_teams_list_expanded(self):
        out = _stringify_tool_result({
            "teams": [{"id": "top_a", "name": "Alpha", "member_count": 3}],
            "total": 1,
        })
        self.assertIn("团队列表: 1 项", out)
        self.assertIn("id=top_a", out)
        self.assertIn("name=Alpha", out)

    def test_empty_list_shows_zero(self):
        out = _stringify_tool_result({"models": [], "total": 0})
        self.assertIn("模型列表: 0 项", out)

    def test_list_truncated_to_max(self):
        items = [{"id": f"m{i}", "name": f"n{i}"} for i in range(40)]
        out = _stringify_tool_result({"members": items})
        self.assertIn("成员列表: 40 项", out)
        self.assertIn("还有 10 项", out)

    def test_dict_value_formatted_not_python_repr(self):
        out = _stringify_tool_result({
            "member": {"id": "m1", "name": "婉宁", "model_id": "mx"},
        })
        self.assertIn("成员:", out)
        self.assertIn("id=m1", out)
        # 不应出现 Python dict repr（以 { 开头）
        self.assertNotIn("{'id':", out)


class TestSpecCurrentStatusText(unittest.TestCase):
    """selected spec 状态文案：未选择 / 无内置 / 正常三类。"""

    def _tool(self):
        import tool.spec_tool as st
        return st.SpecTool(MagicMock(), "ws", user_id="u", agent_id="a",
                           session_id="s")

    def test_not_selected_warning(self):
        tool = self._tool()
        with patch("tool.spec_tool.get_selected_spec_ids", return_value=[]):
            out = tool.current_status_text()
        self.assertEqual(out, '- "[Warning]spec 未选择"')

    def test_no_builtin_warning(self):
        tool = self._tool()
        with patch("tool.spec_tool.get_selected_spec_ids",
                   return_value=["my-spec"]):
            out = tool.current_status_text()
        self.assertIn('[Info]已选择：[my-spec(自定义)，]', out)
        self.assertIn('[Warning]至少选择一个内置 spec', out)

    def test_normal_with_builtin(self):
        tool = self._tool()
        with patch("tool.spec_tool.get_selected_spec_ids",
                   return_value=["easy-task", "my-spec"]):
            out = tool.current_status_text()
        self.assertIn('[Info]已选择：[easy-task(内置), my-spec(自定义)，]', out)
        self.assertNotIn('Warning', out)

    def test_multiple_no_warning_when_any_builtin(self):
        tool = self._tool()
        with patch("tool.spec_tool.get_selected_spec_ids",
                   return_value=["hard-task", "complex-task"]):
            out = tool.current_status_text()
        self.assertIn('hard-task(内置), complex-task(内置)', out)
        self.assertNotIn('Warning', out)


class TestSpecListBuiltinFlag(unittest.TestCase):
    """spec search/list 返回项必须标注 builtin（内置/自定义）。"""

    def _tool(self):
        import tool.spec_tool as st
        return st.SpecTool(MagicMock(), "ws", user_id="u", agent_id="a",
                           session_id="s")

    def test_search_items_have_builtin(self):
        import tool.spec_tool as st
        tool = self._tool()
        fake = [
            {"id": "easy-task", "task_type": "easy", "title": "t",
             "description": "", "when": [], "pinned": True, "builtin": True},
            {"id": "custom", "task_type": "custom", "title": "t2",
             "description": "", "when": [], "pinned": False, "builtin": False},
        ]
        with patch("tool.spec_tool.store_search_specs", return_value=fake):
            out = tool.execute({"action": "search", "query": "x"})
        self.assertTrue(out["specs"][0]["builtin"])
        self.assertFalse(out["specs"][1]["builtin"])

    def test_list_items_have_builtin(self):
        import tool.spec_tool as st
        tool = self._tool()
        fake = [
            {"id": "hard-task", "task_type": "hard", "title": "t",
             "description": "", "when": [], "pinned": True, "builtin": True},
            {"id": "custom", "task_type": "custom", "title": "t2",
             "description": "", "when": [], "pinned": False, "builtin": False},
        ]
        with patch("tool.spec_tool.store_list_specs", return_value=fake), \
             patch("tool.spec_tool.get_selected_spec_ids", return_value=[]):
            out = tool.execute({"action": "list"})
        self.assertTrue(out["specs"][0]["builtin"])
        self.assertFalse(out["specs"][1]["builtin"])

    def test_list_fallback_builtin_by_id(self):
        # 元数据缺 builtin 字段时按 id 归属判断（内置 id 集合）
        import tool.spec_tool as st
        tool = self._tool()
        fake = [
            {"id": "team-meeting", "task_type": "complex", "title": "t",
             "description": "", "when": [], "pinned": True},
        ]
        with patch("tool.spec_tool.store_list_specs", return_value=fake), \
             patch("tool.spec_tool.get_selected_spec_ids", return_value=[]):
            out = tool.execute({"action": "list"})
        self.assertTrue(out["specs"][0]["builtin"])


class TestListModelsReturnsConcrete(unittest.TestCase):
    """list_models 返回具体模型（模型 id + 名称），配合 _stringify 展开。"""

    def test_action_list_models_returns_models(self):
        from tool.team_tool import TeamTool
        session = MagicMock()
        session.workspace_id = "ws"
        cfg = ModelConfig(name="DeepSeek V4", base_url="u", api_key="k",
                          model_id="deepseek-v4-flash-0731")
        tool = TeamTool(session, MagicMock(),
                        {"deepseek-v4-flash-0731": cfg},
                        user_id="u", agent_id="a", team_id="t")
        out = tool.execute({"action": "list_models"})
        self.assertEqual(out["total"], 1)
        self.assertEqual(out["models"][0]["model_id"], "deepseek-v4-flash-0731")
        self.assertEqual(out["models"][0]["name"], "DeepSeek V4")


class TestMemberReplyFallbackPushback(unittest.TestCase):
    """问题 2：成员完成 tool loop 但无文字输出时，最后一次工具结果
    兜底为回复内容，_process_member_message 据此推送给上一级 leader。"""

    def _run(self, coro):
        import asyncio
        return asyncio.run(coro)

    def test_stream_reply_fallback_to_last_tool_when_no_text(self):
        import asyncio
        from unittest.mock import AsyncMock
        from agent import chat as chat_mod

        class FakeSession:
            context = []
            last_usage = None
            model_config = None

            def chat(self, content, on_tool_turn=None, cancel_event=None):
                # 纯工具循环：只 yield tool_call，无任何 text 产出
                yield {
                    "type": "tool_call",
                    "name": "terminal",
                    "arguments": {"command": "git commit -m done"},
                    "result": "提交成功: abc123",
                }

        ws = MagicMock(send_message=AsyncMock())
        with patch.object(chat_mod, "_append_activity_log", return_value=None), \
                patch.object(chat_mod, "_new_seg_id", return_value="seg1"), \
                patch.object(chat_mod, "_store_message", return_value=None), \
                patch("agent.chat.state.ws_manager", ws):
            full, status, last_id, final_text = asyncio.run(
                chat_mod._stream_agent_reply(
                    "u1", "mem-1", "w1", FakeSession(), "do it",
                    session_id="s1"))
        self.assertEqual(status, "ok")
        # 兜底内容包含最后一次工具调用摘要
        self.assertIn("terminal", full)
        self.assertIn("提交成功: abc123", full)
        # 纯工具轮：最终回复回退兜底文本（供调用方持久化/回传）
        self.assertEqual(final_text, full)

    def test_stream_reply_keeps_text_when_present(self):
        import asyncio
        from unittest.mock import AsyncMock
        from agent import chat as chat_mod

        class FakeSession:
            context = []
            last_usage = None
            model_config = None

            def chat(self, content, on_tool_turn=None, cancel_event=None):
                yield {"type": "text", "content": "已完成任务"}
                yield {
                    "type": "tool_call",
                    "name": "write",
                    "arguments": {"file_path": "a.md"},
                    "result": "已写入",
                }
                yield {"type": "text", "content": "总结完毕"}

        stored: list = []

        def _fake_store(user_id, agent_id, role, content, **kwargs):
            stored.append(content)

        ws = MagicMock(send_message=AsyncMock())
        with patch.object(chat_mod, "_append_activity_log", return_value=None), \
                patch.object(chat_mod, "_new_seg_id", return_value="seg1"), \
                patch.object(chat_mod, "_store_message",
                             side_effect=_fake_store), \
                patch("agent.chat.state.ws_manager", ws):
            full, status, last_id, final_text = asyncio.run(
                chat_mod._stream_agent_reply(
                    "u1", "mem-1", "w1", FakeSession(), "do it",
                    session_id="s1"))
        # 有文字输出时不兜底，full 保持全量拼接（活动日志/兜底用途）
        self.assertEqual(full, "已完成任务总结完毕")
        # 最终回复只含最后一个文本段（"总结完毕"），不携带过程段
        self.assertEqual(final_text, "总结完毕")
        # 函数内仅持久化中间段（工具调用前关闭的那段），不保存全量拼接
        self.assertIn("已完成任务", stored)
        self.assertNotIn("已完成任务总结完毕", stored)

    def test_member_reply_pushed_to_leader_when_tool_loop(self):
        """成员 tool loop 结束（_stream_agent_reply 返回兜底文本）后，
        _process_member_message 把最后回复推送给 leader。"""
        from agent import chat as chat_mod
        from unittest.mock import AsyncMock
        import queue as _queue

        dispatched: list = []

        def _fake_dispatch(user_id, target_ids, content,
                           source_agent_id="", team_id="",
                           system_prompt="", extra=None):
            dispatched.append((target_ids, content))
            return {"status": "sent", "sent": list(target_ids), "rejected": []}

        async def _fake_stream(user_id, agent_id, workspace_id, session,
                               content, on_tool_turn=None, cancel_event=None,
                               session_id=None, team_id=None):
            return ("（本轮无文字输出，最后执行：[工具 terminal] 提交成功: abc123）",
                    "ok", None,
                    "（本轮无文字输出，最后执行：[工具 terminal] 提交成功: abc123）")

        q = _queue.Queue()
        with patch.object(chat_mod, "_stream_agent_reply", new=_fake_stream), \
                patch.object(chat_mod, "_dispatch_agent_message",
                             side_effect=_fake_dispatch), \
                patch.object(chat_mod, "_store_message", return_value=None), \
                patch.object(chat_mod, "_register_active_task",
                             return_value=MagicMock()), \
                patch.object(chat_mod, "_clear_active_task", return_value=None), \
                patch.object(chat_mod, "_send_status_idle", new=AsyncMock()), \
                patch.object(chat_mod, "save_context", return_value=None), \
                patch.object(chat_mod, "collect_sft_turn", return_value=None), \
                patch.object(chat_mod, "_append_activity_log", return_value=None), \
                patch.object(chat_mod, "_register_tools", new=AsyncMock()), \
                patch.object(chat_mod, "get_session", return_value=None), \
                patch.object(chat_mod, "load_context", return_value=None), \
                patch.object(chat_mod, "set_session", return_value=None), \
                patch("agent.chat.state.model_configs", {
                    "m1": MagicMock(api_key="k", name="M1", if_vision=False),
                }), \
                patch("agent.chat.state.ws_manager",
                      MagicMock(send_message=AsyncMock())):
            payload = {
                "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
                "model_id": "m1", "leader_id": "leader-1",
                "team_id": "top-1",
                "system_prompt": "", "content": "start",
                "session_id": "sess-current",
            }
            self._run(chat_mod._process_member_message(payload, q))

        # 必须推送给 leader，且内容包含成员最后回复
        self.assertTrue(dispatched, "成员完成回复后应推送 leader")
        targets, content = dispatched[0]
        self.assertIn("leader-1", targets)
        self.assertIn("提交成功: abc123", content)


class TestWarningAccountabilityPrompt(unittest.TestCase):
    """system prompt 必须包含 ⑬ 工具反馈 [Warning] 负责规则（来自 versioned 注册表）。"""

    def test_warning_accountability_text_has_rules(self):
        from prompt.versions import active_system_tail
        wc = [c for c in active_system_tail() if c.id == "warning-accountability"][0]
        self.assertIn("⑬ 工具反馈 [Warning] 负责规则", wc.title)
        text = wc.content
        self.assertIn("严格关注", text)
        self.assertIn("背景噪音", text)
        self.assertIn("ask_user_question", text)
        self.assertIn("准确、具体", text)
        # 反模式必须被禁止：不得泛化忽略
        self.assertIn("忽略所有", text)

    def test_agent_system_prompt_includes_warning_chapter(self):
        from agent.chat import _build_agent_system_prompt
        prompt = _build_agent_system_prompt(workspace_id="w1")
        self.assertIn("⑬ 工具反馈 [Warning] 负责规则", prompt)
        self.assertIn("⑫ 任务进度管理纪律", prompt)
        # 审计头：企业级可审计性
        self.assertIn("系统提示词体系：版本 v", prompt)
        self.assertIn("安全与边界护栏", prompt)
        self.assertIn("角色权威与行为准则", prompt)


if __name__ == "__main__":
    unittest.main()

