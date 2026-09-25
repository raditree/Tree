# -*- coding: utf-8 -*-
"""P4 团队规模测试：创建 TOP 时设定、持久化、解析、钳制。

覆盖：
- config.team：默认值 / 硬上限 / 归一化（非法值回退默认）
- team_store.init_team 持久化 max_level / max_members_per_level（临时 DB）
- team_init.init_team_for_top：初始人数 = clamp(member_count or 上限, 1, 上限)
- team_tool._resolve_team_limits：从团队记录解析（不再读等级/app.yaml）
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.db as db_mod  # noqa: E402
import data.team_init as team_init  # noqa: E402
import data.team_store as team_store  # noqa: E402


class TeamLimitsBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_team_limits_"))
        self._orig_db = db_mod._DB_PATH
        team_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        team_store._initialized = False  # type: ignore[attr-defined]
        db_mod._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]

    def tearDown(self):
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)


class TestConfigTeam(unittest.TestCase):
    def test_defaults_and_clamps(self):
        from config.team import (
            HARD_MAX_LEVEL,
            HARD_MAX_MEMBERS,
            clamp_level,
            clamp_members,
            resolve_team_config,
        )
        self.assertEqual(HARD_MAX_LEVEL, 5)
        self.assertEqual(HARD_MAX_MEMBERS, 100)
        self.assertEqual(clamp_level(None), 3)
        self.assertEqual(clamp_level("abc"), 3)
        self.assertEqual(clamp_level(0), 1)
        self.assertEqual(clamp_level(4), 4)
        self.assertEqual(clamp_members(None), 7)
        self.assertEqual(clamp_members(10), 10)
        cfg = resolve_team_config(None, None)
        self.assertEqual(cfg, {"max_level": 3, "max_members_per_level": 7})
        cfg2 = resolve_team_config(4, 12)
        self.assertEqual(cfg2, {"max_level": 4, "max_members_per_level": 12})


class TestTeamStoreConfig(TeamLimitsBase):
    def test_init_team_persists_config(self):
        team = team_store.init_team("u1", "top1", "团队A", max_level=4,
                                    max_members_per_level=12)
        self.assertEqual(team["max_level"], 4)
        self.assertEqual(team["max_members_per_level"], 12)
        again = team_store.get_team("top1")
        self.assertEqual(again["max_level"], 4)
        self.assertEqual(again["max_members_per_level"], 12)

    def test_init_team_defaults(self):
        team = team_store.init_team("u1", "top2", "团队B")
        self.assertEqual(team["max_level"], 3)
        self.assertEqual(team["max_members_per_level"], 7)

    def test_add_member_records_parent_agent_id(self):
        team_store.init_team("u1", "top1", "团队A", max_level=4,
                             max_members_per_level=12)
        team_store.add_member("u1", "top1", "m1", "成员1",
                              parent_agent_id="top1")
        m = team_store.get_member("top1", "m1")
        self.assertEqual(m["parent_agent_id"], "top1")


class TestInitTeamForTop(TeamLimitsBase):
    def _top(self, name="TOP"):
        return {"id": "top1", "name": name, "workspace_id": "ws_top",
                "model_id": "m"}

    def test_member_count_clamped_to_cap(self):
        docker = MagicMock()
        with patch("data.team_init._pick_names",
                   return_value=[f"名字{i}" for i in range(20)]), \
             patch("data.team_init._generate_member_ids",
                   return_value=[f"member_{i}" for i in range(20)]):
            result = team_init.init_team_for_top(
                "u1", self._top(), docker,
                member_count=99, max_level=4, max_members_per_level=3,
            )
        self.assertEqual(result["created_count"], 3)  # 钳制到上限
        team = team_store.get_team("top1")
        self.assertEqual(team["max_level"], 4)
        self.assertEqual(team["max_members_per_level"], 3)

    def test_member_count_default_to_init_members(self):
        """建队预建数缺省 3（DEFAULT_TEAM_INIT_MEMBERS），**不是**每层上限。"""
        docker = MagicMock()
        with patch("data.team_init._pick_names",
                   return_value=[f"名字{i}" for i in range(20)]), \
             patch("data.team_init._generate_member_ids",
                   return_value=[f"member_{i}" for i in range(20)]):
            result = team_init.init_team_for_top(
                "u1", self._top(), docker,
                member_count=None, max_members_per_level=5,
            )
        # 建队预建 3 名；每层上限仍是 5（leader 可继续扩编到 5）
        self.assertEqual(result["created_count"], 3)
        self.assertEqual(team_store.get_team("top1")["max_members_per_level"], 5)
        members = team_store.get_members("top1")
        self.assertTrue(all(m["parent_agent_id"] == "top1" for m in members))

    def test_init_members_capped_by_per_level_limit(self):
        """每层上限小于 3 时，建队预建数被上限钳制。"""
        docker = MagicMock()
        with patch("data.team_init._pick_names",
                   return_value=[f"名字{i}" for i in range(20)]), \
             patch("data.team_init._generate_member_ids",
                   return_value=[f"member_{i}" for i in range(20)]):
            result = team_init.init_team_for_top(
                "u1", self._top(), docker,
                member_count=None, max_members_per_level=2,
            )
        self.assertEqual(result["created_count"], 2)

    def test_built_members_have_no_model_and_pending_status(self):
        """建队成员不继承 TOP 模型：model_id 空 + pending_model（等待用户赋模型）。"""
        docker = MagicMock()
        with patch("data.team_init._pick_names",
                   return_value=[f"名字{i}" for i in range(20)]), \
             patch("data.team_init._generate_member_ids",
                   return_value=[f"member_{i}" for i in range(20)]):
            team_init.init_team_for_top(
                "u1", self._top(), docker, max_members_per_level=5,
            )
        for m in team_store.get_members("top1"):
            self.assertEqual(m["model_id"], "")
            self.assertEqual(m["review_status"], "pending_model")

    def test_idempotent_existing_team(self):
        docker = MagicMock()
        with patch("data.team_init._pick_names",
                   return_value=[f"名字{i}" for i in range(20)]), \
             patch("data.team_init._generate_member_ids",
                   return_value=[f"member_{i}" for i in range(20)]):
            r1 = team_init.init_team_for_top("u1", self._top(), docker,
                                             max_members_per_level=3)
            r2 = team_init.init_team_for_top("u1", self._top(), docker,
                                             max_members_per_level=5)
        self.assertEqual(r1["created_count"], 3)
        self.assertEqual(r2["created_count"], 0)  # 幂等：已建团队直接返回
        team = team_store.get_team("top1")
        self.assertEqual(team["max_members_per_level"], 3)


class TestResolveTeamLimits(unittest.TestCase):
    def test_from_team_record(self):
        from tool.team_tool import _resolve_team_limits

        with patch("data.team_store.get_team", return_value={
            "max_level": 4, "max_members_per_level": 12,
        }):
            ml, mm = _resolve_team_limits("top1")
        self.assertEqual((ml, mm), (4, 12))

    def test_fallback_defaults_when_no_team(self):
        from tool.team_tool import _resolve_team_limits

        with patch("data.team_store.get_team", return_value=None):
            ml, mm = _resolve_team_limits("ghost_top")
        self.assertEqual((ml, mm), (3, 7))

    def test_fallback_when_bad_values(self):
        from tool.team_tool import _resolve_team_limits

        with patch("data.team_store.get_team", return_value={
            "max_level": "abc", "max_members_per_level": 0,
        }):
            ml, mm = _resolve_team_limits("top1")
        self.assertEqual((ml, mm), (3, 7))


if __name__ == "__main__":
    unittest.main()
