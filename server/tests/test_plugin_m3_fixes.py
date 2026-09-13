r"""M3 修复补测（独立复核）：F-M3-2 快照端点归属 / F-M3-1 F3 兜底日志前缀。

来源：
- 观澜合并复核 F-M3-1 / F-M3-2（栖迟修复；地煞令）；
- F-M3-2：``agent/routes.py`` 快照端点 ``_user_id_of`` 兼容提取（openid / id）
  + **空归属 fail-closed**（不再因空值放行全量）；
- F-M3-1：``plugin/stations.py`` F3 兜底 debug 日志改走 ``_flog``
  （前缀 ``[plugin:station:f3]``）。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_m3_fixes.py -q
"""

from __future__ import annotations

import asyncio
import unittest

from plugin.registry import PluginRegistry
from plugin.stations import StationsHub
from plugin.watchdog import ProgressWatchdog
from ws.auth import _user_id_of


class UserIdExtractTests(unittest.TestCase):
    """F-M3-2 单元：_user_id_of 兼容提取（openid 优先 / id 回退 / 空）。"""

    def test_openid_preferred_then_id_then_empty(self):
        self.assertEqual(_user_id_of({"openid": "u-open"}), "u-open")
        self.assertEqual(_user_id_of({"id": "u-id"}), "u-id")
        # openid 优先于 id
        self.assertEqual(_user_id_of({"openid": "u-open", "id": "u-id"}), "u-open")
        # 空值 / 缺键 → 空串（fail-closed 由调用方处理）
        self.assertEqual(_user_id_of({}), "")
        self.assertEqual(_user_id_of({"openid": "", "id": ""}), "")
        self.assertEqual(_user_id_of({"openid": None, "id": "u-id"}), "u-id")


class SnapshotOwnerGateTests(unittest.TestCase):
    """F-M3-2 端点：空归属 fail-closed；常规归属返回快照（回归不变）。"""

    def _call(self, current_user):
        from agent.routes import get_plugin_snapshot

        return asyncio.run(
            get_plugin_snapshot(team_id=None, current_user=current_user)
        )

    def test_empty_owner_fail_closed(self):
        for cu in ({}, {"openid": ""}, {"openid": "", "id": ""}, {"id": ""}):
            r = self._call(cu)
            self.assertEqual(
                r, {"success": False, "error": "缺少用户归属"}, msg=f"cu={cu}"
            )
            # 不放行全量：不得含快照数据键
            self.assertNotIn("instances", r)
            self.assertNotIn("stations", r)
            self.assertNotIn("enabled", r)

    def test_normal_owner_returns_snapshot_shape(self):
        for cu in ({"openid": "u-check"}, {"id": "u-check2"}):
            r = self._call(cu)
            self.assertNotIn("error", r)
            self.assertIn("enabled", r)  # 快照骨架必有键
            self.assertIn("generated_at", r)


class SnapshotFilterPassingTests(unittest.TestCase):
    """F-M3-2：过滤参数正确传入（id 主键）；空归属不触达合成（不放行全量）。"""

    def _call(self, current_user, team_id=None):
        from agent.routes import get_plugin_snapshot

        return asyncio.run(
            get_plugin_snapshot(team_id=team_id, current_user=current_user)
        )

    def test_id_key_passes_user_id_and_team(self):
        from unittest import mock

        with mock.patch("plugin.get_snapshot", return_value={"enabled": True}) as m:
            r = self._call({"id": "u-id"}, team_id="t-9")
        self.assertEqual(r, {"enabled": True})
        # 证明：id 主键被正确提取并作为过滤参数传入（非全量、非空）
        m.assert_called_once_with(user_id="u-id", team_id="t-9")

    def test_empty_owner_does_not_reach_snapshot(self):
        from unittest import mock

        with mock.patch("plugin.get_snapshot") as m:
            r = self._call({})
        self.assertEqual(r["error"], "缺少用户归属")
        # 证明：空归属直接 fail-closed，不触达快照合成（不放行全量）
        m.assert_not_called()


class F3FallbackLogTests(unittest.TestCase):
    """F-M3-1：F3 兜底日志走 _flog —— 前缀 [plugin:station:f3]。"""

    def test_f3_fallback_log_prefix(self):
        reg = PluginRegistry()
        hub = StationsHub(reg, watchdog=ProgressWatchdog())
        self.addCleanup(reg.shutdown)

        class _BrokenInst:
            def note_station_error(self):
                raise RuntimeError("boom")

        with self.assertLogs("plugin.stations", level="DEBUG") as cm:
            # 兜底路径：内部异常被吞、不抛出
            hub._note_handler_result(_BrokenInst(), ok=False)  # noqa: SLF001
        joined = "\n".join(cm.output)
        self.assertIn("[plugin:station:f3] F3 计数/停用异常（忽略）", joined)


if __name__ == "__main__":
    unittest.main()
