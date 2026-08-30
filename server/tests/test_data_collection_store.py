# -*- coding: utf-8 -*-
"""SFT 数据收集测试：开关 / 增量收集 / 导出 / 级联删除（隔离临时 DB）。

覆盖：
1. 开关：set/get 开关持久化；开启后才收集，关闭即停止
2. 增量收集：base + diffs 按会话累加；未开启不写
3. 导出：还原 base+diffs 为完整 messages，写 jsonl；文件名按日期
4. 越权防护：导出 API 在 routes 层用管理员 openid 校验（此处测存储层的
   read_sft_file 路径穿越防护）
"""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.data_collection_store as dcs  # noqa: E402


def _redirect_db(tmpdir: Path) -> None:
    """把 data_collection_store 的 DB 路径指向临时目录并重置初始化标记。"""
    dcs._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
    dcs._SFT_DIR = tmpdir / "sft"  # type: ignore[attr-defined]
    dcs._initialized = False  # type: ignore[attr-defined]


class SftStoreBase(unittest.TestCase):
    """为每个测试创建独立临时 DB 目录。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_sft_"))
        _redirect_db(self._tmp)

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)


class TestDataCollectionPrefs(SftStoreBase):
    def test_default_disabled(self):
        self.assertFalse(dcs.is_collection_enabled("u1"))

    def test_toggle_enable_and_disable(self):
        dcs.set_collection_enabled("u1", True)
        self.assertTrue(dcs.is_collection_enabled("u1"))
        dcs.set_collection_enabled("u1", False)
        self.assertFalse(dcs.is_collection_enabled("u1"))

    def test_prefs_are_per_user(self):
        dcs.set_collection_enabled("u1", True)
        self.assertTrue(dcs.is_collection_enabled("u1"))
        self.assertFalse(dcs.is_collection_enabled("u2"))


class TestCollectSftTurn(SftStoreBase):
    def _base_ctx(self):
        return [{"role": "system", "content": "sys"}]

    def test_not_collected_when_disabled(self):
        ctx = self._base_ctx()
        dcs.collect_sft_turn("u1", "a1", "session_default", ctx, ctx + [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "hello"},
        ])
        files = dcs.list_sft_files()
        self.assertEqual(files, [])

    def test_collects_diff_across_turns(self):
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        # 第一轮
        ctx1 = ctx0 + [{"role": "user", "content": "q1"},
                        {"role": "assistant", "content": "a1"}]
        dcs.collect_sft_turn("u1", "a1", "sess1", ctx0, ctx1)
        # 第二轮（新增 diff）
        ctx2 = ctx1 + [{"role": "user", "content": "q2"},
                        {"role": "assistant", "content": "a2"}]
        dcs.collect_sft_turn("u1", "a1", "sess1", ctx1, ctx2)

        # 导出后应还原出完整的 5 条消息
        out = dcs.export_daily_sft()
        self.assertTrue(out.exists())
        lines = out.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 1)
        import json as _json
        rec = _json.loads(lines[0])
        msgs = rec["messages"]
        self.assertEqual(len(msgs), 5)
        roles = [m["role"] for m in msgs]
        self.assertEqual(roles, ["system", "user", "assistant", "user", "assistant"])
        self.assertEqual(msgs[-1]["content"], "a2")

    def test_sessions_isolated(self):
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        ctx1 = ctx0 + [{"role": "user", "content": "x"},
                        {"role": "assistant", "content": "y"}]
        # 同一用户不同 agent
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        dcs.collect_sft_turn("u1", "a2", "s", ctx0, ctx1)
        out = dcs.export_daily_sft()
        lines = out.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)


class TestMemberCollection(SftStoreBase):
    """团队成员轮次同样收集（agent_type 标注，按成员 agent_id 分键）。"""

    def _base_ctx(self):
        return [{"role": "system", "content": "member sys"}]

    def test_member_turn_collected_with_member_type(self):
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        ctx1 = ctx0 + [{"role": "user", "content": "任务"},
                       {"role": "assistant", "content": "成员回复"}]
        dcs.collect_sft_turn("u1", "member_1", "sess1", ctx0, ctx1,
                             agent_type="member")

        out = dcs.export_daily_sft()
        rec = json.loads(
            out.read_text(encoding="utf-8").strip().splitlines()[0]
        )
        self.assertEqual(rec["agent_id"], "member_1")
        self.assertEqual(rec["agent_type"], "member")
        self.assertEqual(rec["session_id"], "sess1")
        self.assertEqual(len(rec["messages"]), 3)

    def test_top_defaults_to_top_type(self):
        """不带 agent_type 的历史/TOP 路径默认 'top'。"""
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        ctx1 = ctx0 + [{"role": "user", "content": "q"},
                       {"role": "assistant", "content": "a"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)

        out = dcs.export_daily_sft()
        rec = json.loads(
            out.read_text(encoding="utf-8").strip().splitlines()[0]
        )
        self.assertEqual(rec["agent_id"], "a1")
        self.assertEqual(rec["agent_type"], "top")

    def test_top_and_member_same_session_separate_rows(self):
        """TOP 与成员在同一 session_id 下互不覆盖，导出两行各带类型。"""
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        ctx1 = ctx0 + [{"role": "user", "content": "x"},
                       {"role": "assistant", "content": "y"}]
        # 同一会话：TOP 收集 + 成员收集（成员用自己 agent_id）
        dcs.collect_sft_turn("u1", "top-1", "sess-x", ctx0, ctx1)
        dcs.collect_sft_turn("u1", "member_1", "sess-x", ctx0, ctx1,
                             agent_type="member")

        out = dcs.export_daily_sft()
        lines = out.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)
        types = sorted(json.loads(l)["agent_type"] for l in lines)
        self.assertEqual(types, ["member", "top"])


class TestCompactHandling(SftStoreBase):
    """compact（上下文压缩）下 diff 需做"减法"：前缀被替换/缩短时重置 base。"""

    def _base_ctx(self):
        return [{"role": "system", "content": "sys"}]

    def test_no_compact_appends_only_new(self):
        """无压缩：新增段 = after 越过公共前缀之后的消息。"""
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        ctx1 = ctx0 + [{"role": "user", "content": "q1"},
                        {"role": "assistant", "content": "a1"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        # 第二轮同样为纯追加
        ctx2 = ctx1 + [{"role": "user", "content": "q2"},
                        {"role": "assistant", "content": "a2"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx1, ctx2)
        out = dcs.export_daily_sft()
        lines = out.read_text(encoding="utf-8").strip().splitlines()
        rec = json.loads(lines[0])
        roles = [m["role"] for m in rec["messages"]]
        self.assertEqual(roles, ["system", "user", "assistant", "user", "assistant"])

    def test_compact_preserves_prior_history(self):
        """compact 缩短 context：旧历史被封存为 sealed 段，不覆盖不丢弃。"""
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        # 前两轮正常收集
        ctx1 = ctx0 + [{"role": "user", "content": "q1"},
                        {"role": "assistant", "content": "a1"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        ctx2 = ctx1 + [{"role": "user", "content": "q2"},
                        {"role": "assistant", "content": "a2"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx1, ctx2)
        # 第三轮触发 compact：历史被压缩成 summary，前缀不再一致
        ctx3_before = [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "q1"},
            {"role": "assistant", "content": "a1"},
            {"role": "user", "content": "q2"},
            {"role": "assistant", "content": "a2"},
        ]
        ctx3_after = [
            {"role": "system", "content": "sys"},
            {"role": "assistant", "content": "compact_summary"},
            {"role": "user", "content": "q3"},
            {"role": "assistant", "content": "a3"},
        ]
        dcs.collect_sft_turn("u1", "a1", "s", ctx3_before, ctx3_after)

        out = dcs.export_daily_sft()
        lines = out.read_text(encoding="utf-8").strip().splitlines()
        # 封存段 + 活动段 = 2 行，旧数据未被覆盖
        self.assertEqual(len(lines), 2)

        sealed_rec = json.loads(lines[0])
        sealed_msgs = sealed_rec["messages"]
        # 第一行为 compact 前还原的完整历史（system, q1-a1, q2-a2）
        sealed_roles = [m["role"] for m in sealed_msgs]
        self.assertEqual(
            sealed_roles, ["system", "user", "assistant", "user", "assistant"],
        )
        self.assertEqual(sealed_msgs[-1]["content"], "a2")

        active_rec = json.loads(lines[1])
        active_msgs = active_rec["messages"]
        # 第二行为 compact 后的活动段（system + summary + q3-a3）
        active_roles = [m["role"] for m in active_msgs]
        self.assertEqual(
            active_roles, ["system", "assistant", "user", "assistant"],
        )
        self.assertEqual(active_msgs[1]["content"], "compact_summary")
        self.assertEqual(active_msgs[-1]["content"], "a3")

    def test_compact_after_len_shrinks_does_not_lose_new_msgs(self):
        """旧实现（长度切片）在 after 变短时会丢新增消息；新实现不会。"""
        dcs.set_collection_enabled("u1", True)
        ctx0 = self._base_ctx()
        ctx1 = ctx0 + [{"role": "user", "content": "q1"},
                        {"role": "assistant", "content": "a1"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        # 第二次：before 很长（4条），after compact 后 3 条（更短）
        long_before = ctx1 + [{"role": "user", "content": "q2"},
                              {"role": "assistant", "content": "a2"}]
        short_after = [
            {"role": "system", "content": "sys"},
            {"role": "assistant", "content": "summary"},
            {"role": "user", "content": "q3"},
            {"role": "assistant", "content": "a3"},
        ]
        dcs.collect_sft_turn("u1", "a1", "s", long_before, short_after)
        out = dcs.export_daily_sft()
        lines = out.read_text(encoding="utf-8").strip().splitlines()
        # 封存历史 + 活动段 = 2 行
        self.assertEqual(len(lines), 2)
        # 第 1 行为封存的旧历史（DB 中活动段仅含第一轮 sys/q1/a1）
        sealed = json.loads(lines[0])
        self.assertEqual(sealed["messages"][-1]["content"], "a1")
        # 第 2 行为活动段，a3 必须存在
        rec = json.loads(lines[1])
        self.assertEqual(rec["messages"][-1]["content"], "a3")
        self.assertEqual(rec["messages"][-2]["content"], "q3")


class TestExportSft(SftStoreBase):
    def test_exports_multiple_days_files(self):
        dcs.set_collection_enabled("u1", True)
        ctx0 = [{"role": "system", "content": "sys"}]
        ctx1 = ctx0 + [{"role": "user", "content": "q"},
                        {"role": "assistant", "content": "a"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        p1 = dcs.export_daily_sft()
        p2 = dcs.export_daily_sft()  # 同一天，覆盖同一文件
        self.assertEqual(p1.name, p2.name)
        self.assertEqual(len(dcs.list_sft_files()), 1)

    def test_read_sft_file_rejects_path_traversal(self):
        # 路径穿越 / 非法文件名应返回 None
        self.assertIsNone(dcs.read_sft_file("../../evil.jsonl"))
        self.assertIsNone(dcs.read_sft_file("other.txt"))
        self.assertIsNone(dcs.read_sft_file("sft_missing.jsonl"))

    def test_read_sft_file_valid(self):
        dcs.set_collection_enabled("u1", True)
        ctx0 = [{"role": "system", "content": "sys"}]
        ctx1 = ctx0 + [{"role": "user", "content": "q"},
                        {"role": "assistant", "content": "a"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        p = dcs.export_daily_sft()
        data = dcs.read_sft_file(p.name)
        self.assertIsNotNone(data)
        self.assertIn(b"q", data)


class TestDeleteUserSft(SftStoreBase):
    def test_delete_removes_prefs_and_sessions(self):
        dcs.set_collection_enabled("u1", True)
        ctx0 = [{"role": "system", "content": "sys"}]
        ctx1 = ctx0 + [{"role": "user", "content": "q"},
                        {"role": "assistant", "content": "a"}]
        dcs.collect_sft_turn("u1", "a1", "s", ctx0, ctx1)
        self.assertTrue(dcs.is_collection_enabled("u1"))

        dcs.delete_user_sft("u1")
        self.assertFalse(dcs.is_collection_enabled("u1"))
        # 重新导出应为空（无会话记录）
        out = dcs.export_daily_sft()
        self.assertEqual(out.read_text(encoding="utf-8").strip(), "")


if __name__ == "__main__":
    unittest.main()