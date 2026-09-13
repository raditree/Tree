# -*- coding: utf-8 -*-
"""插件总开关来源链单测：env（显式优先）→ app.yaml（plugin.enabled 兜底）。

覆盖：
- env 显式设置（含 "0"）→ 一律以 env 为准，不读配置；
- env 未设置（含空串）→ 回落 app.yaml plugin.enabled（缺省 False）；
- app.yaml 读取异常 → 按关闭处理（不抛出）。
"""
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config.config as config_module  # noqa: E402
import plugin  # noqa: E402


class PluginEnabledSwitchTests(unittest.TestCase):
    """开关来源链（_read_enabled / _read_config_enabled / _read_env_enabled）。"""

    def test_env_explicit_wins(self) -> None:
        """env 显式设置时优先（含 "0" 显式关闭），即使配置为开。"""
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": "1"}, clear=False):
            with patch.object(plugin, "_read_config_enabled", return_value=False):
                self.assertTrue(plugin._read_enabled())
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": "0"}, clear=False):
            with patch.object(plugin, "_read_config_enabled", return_value=True):
                self.assertFalse(plugin._read_enabled())
        # 兼容既有语义：true/yes/on 等写法
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": "yes"}, clear=False):
            self.assertTrue(plugin._read_env_enabled())

    def test_fallback_to_config_when_env_absent(self) -> None:
        """env 未设置（含空串）→ 回落配置开关。"""
        env = dict(os.environ)
        env.pop("TREE_PLUGIN_ENABLED", None)
        with patch.dict(os.environ, env, clear=True):
            with patch.object(plugin, "_read_config_enabled", return_value=True):
                self.assertTrue(plugin._read_enabled())
            with patch.object(plugin, "_read_config_enabled", return_value=False):
                self.assertFalse(plugin._read_enabled())
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": ""}, clear=False):
            with patch.object(plugin, "_read_config_enabled", return_value=True):
                self.assertTrue(plugin._read_enabled())

    def test_config_reader_value_and_errors(self) -> None:
        """_read_config_enabled：读 plugin.enabled；缺省/异常按 False。"""
        with patch.object(
            config_module, "get_config", return_value={"plugin": {"enabled": True}}
        ):
            self.assertTrue(plugin._read_config_enabled())
        with patch.object(config_module, "get_config", return_value={}):
            self.assertFalse(plugin._read_config_enabled())
        with patch.object(
            config_module, "get_config", side_effect=RuntimeError("boom")
        ):
            self.assertFalse(plugin._read_config_enabled())


if __name__ == "__main__":
    unittest.main()
