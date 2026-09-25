# -*- coding: utf-8 -*-
"""自定义模型 CRUD 与每 agent 模型参数覆盖测试（计划项 6 / 7）。

项 7 背景：全仓原无任何模型写接口，且存在**双轨制**——``get_model_configs()``
每次重扫磁盘（仅展示接口用），而 ``state.model_configs`` 是启动快照（全部生效
路径用，含 ``PATCH /api/agents/{id}`` 的模型校验）。只写 YAML 不刷新快照，会
出现"下拉里看得见新模型、选中却被 400 拒绝"。本测试锁定该回归。

项 6 背景：模型参数（思考强度 / 输入长度 / 输出长度 / 压缩阈值）原先只能改
YAML。现支持**每 agent 覆盖**，存 ``agents`` 表新列；``None`` = 不修改，
``clear_model_overrides=True`` = 一次性清除。

覆盖：
- POST/PATCH/DELETE /api/models 往返，写盘后 ``state.model_configs`` 立即生效
- **api_key 绝不出现在响应中**（仅回 ``has_api_key``）
- model_id 路径穿越拒绝、非法字段 400、重名 400、不存在 404
- PATCH 留空 api_key = 保留原密钥；未传字段沿用现值
- PATCH /api/agents/{id} 写入四个覆盖字段 + 清除覆盖 + 数值范围校验
- models-info 返回 ``overrides`` 块
- agents 表迁移幂等
- 覆盖值经 ``_apply_agent_model_overrides`` 生效且**不污染共享 ModelConfig**

隔离：临时目录承载模型 YAML；临时 DB；TestClient override 认证。
"""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import config.models as models_mod  # noqa: E402
import data.agent_store as agent_store  # noqa: E402
import data.conversation_store as conv_store  # noqa: E402
import data.db as db_mod  # noqa: E402
import data.mcp_service_store as mcp_store  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
from agent.routes import router as agent_router  # noqa: E402
from config.models import ModelConfig  # noqa: E402

USER = {"openid": "u-model-test"}


def _redirect_db(tmpdir: Path) -> None:
    for mod in (
        agent_store, mcp_store, team_store, conv_store,
        session_store, db_mod,
    ):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]


class ModelApiBase(unittest.TestCase):
    _REDIRECT_MODS = (agent_store, mcp_store, team_store, conv_store,
                      session_store, db_mod)

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_model_"))
        self._models_dir = Path(tempfile.mkdtemp(prefix="trae_models_dir_"))
        self._orig_db = {m: m._DB_PATH for m in self._REDIRECT_MODS}
        self._orig_models_dir = models_mod._MODELS_DIR
        self._orig_state_configs = state.model_configs
        self.addCleanup(self._restore_globals)
        _redirect_db(self._tmp)
        models_mod._MODELS_DIR = self._models_dir

        state.model_configs = {
            "flash": ModelConfig(
                name="Flash", base_url="http://x/secret", api_key="sk-secret-key",
                model_id="flash", if_vision=True, thinking=True,
                extra={"max_seqlen": 8192},
            ),
        }
        app = FastAPI()
        app.include_router(agent_router)
        from ws.auth import get_current_user

        app.dependency_overrides[get_current_user] = lambda: dict(USER)
        self.client = TestClient(app)

    def _restore_globals(self):
        for m in self._REDIRECT_MODS:
            m._DB_PATH = self._orig_db[m]
            m._initialized = False
        models_mod._MODELS_DIR = self._orig_models_dir
        state.model_configs = self._orig_state_configs
        shutil.rmtree(self._tmp, ignore_errors=True)
        shutil.rmtree(self._models_dir, ignore_errors=True)

    def _create_payload(self, model_id: str = "my-model", **overrides):
        payload = {
            "model_id": model_id,
            "name": "My Model",
            "base_url": "http://localhost:8001/v1",
            "api_key": "sk-custom",
        }
        payload.update(overrides)
        return payload


class TestCreateModel(ModelApiBase):
    def test_create_writes_yaml_and_returns_masked(self):
        r = self.client.post("/api/models", json=self._create_payload())
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertTrue(body["success"])
        self.assertEqual(body["model"]["model_id"], "my-model")
        self.assertTrue(body["model"]["has_api_key"])
        # 密钥绝不回显
        self.assertNotIn("api_key", body["model"])
        self.assertNotIn("sk-custom", json.dumps(body))
        # 文件确实落盘
        self.assertTrue((self._models_dir / "my-model.yaml").exists())

    def test_create_refreshes_state_snapshot(self):
        """双轨制回归：写完必须让 state.model_configs 立即包含新模型。"""
        self.assertNotIn("my-model", state.model_configs)
        self.client.post("/api/models", json=self._create_payload())
        self.assertIn("my-model", state.model_configs)

    def test_created_model_can_be_bound_to_agent_immediately(self):
        """端到端：新建模型后 PATCH agent 绑它不应 400（此前会因快照未刷新而 400）。"""
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        self.client.post("/api/models", json=self._create_payload())
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"model_id": "my-model"}
        )
        self.assertEqual(r.status_code, 200, r.text)

    def test_duplicate_400(self):
        self.client.post("/api/models", json=self._create_payload())
        r = self.client.post("/api/models", json=self._create_payload())
        self.assertEqual(r.status_code, 400)

    def test_path_traversal_rejected(self):
        for bad in ("../evil", "a/b", "a\\b", "..", "x/../y"):
            r = self.client.post(
                "/api/models",
                json=self._create_payload(model_id=bad),
            )
            self.assertEqual(r.status_code, 400, f"model_id={bad!r} 应被拒绝")
        # 空 model_id 同样 400（缺主键）
        r = self.client.post("/api/models", json=self._create_payload(model_id=""))
        self.assertEqual(r.status_code, 400)
        # 目录外不得产生任何文件（含临时残留）
        self.assertEqual(list(self._models_dir.iterdir()), [])

    def test_missing_required_400(self):
        for field in ("name", "base_url", "api_key"):
            payload = self._create_payload()
            payload[field] = ""
            r = self.client.post("/api/models", json=payload)
            self.assertEqual(r.status_code, 400, f"缺 {field} 应 400")

    def test_out_of_range_400(self):
        cases = [
            {"max_seqlen": 0},
            {"max_output_tokens": -1},
            {"compress_threshold": 1.5},
            {"compress_threshold": 0.0},
            {"temperature": 9.0},
            {"timeout_seconds": 0},
        ]
        for extra in cases:
            r = self.client.post(
                "/api/models", json=self._create_payload(**extra)
            )
            self.assertEqual(r.status_code, 400, f"{extra} 应 400")

    def test_optional_params_persisted(self):
        r = self.client.post(
            "/api/models",
            json=self._create_payload(
                model_id="full",
                thinking=True,
                if_vision=True,
                max_seqlen=65536,
                reasoning_effort="high",
                max_output_tokens=4096,
                compress_threshold=0.6,
            ),
        )
        self.assertEqual(r.status_code, 200, r.text)
        cfg = models_mod.load_model_configs()["full"]
        self.assertTrue(cfg.thinking)
        self.assertEqual(cfg.extra["max_seqlen"], 65536)
        self.assertEqual(cfg.extra["reasoning_effort"], "high")
        self.assertEqual(cfg.extra["max_output_tokens"], 4096)
        self.assertAlmostEqual(cfg.extra["compress_threshold"], 0.6)


class TestUpdateModel(ModelApiBase):
    def setUp(self):
        super().setUp()
        self.client.post("/api/models", json=self._create_payload())

    def test_update_blank_api_key_keeps_existing(self):
        r = self.client.patch(
            "/api/models/my-model",
            json={"model_id": "my-model", "name": "改名", "api_key": ""},
        )
        self.assertEqual(r.status_code, 200, r.text)
        cfg = models_mod.load_model_configs()["my-model"]
        self.assertEqual(cfg.name, "改名")
        self.assertEqual(cfg.api_key, "sk-custom")

    def test_update_keeps_unspecified_fields(self):
        r = self.client.patch(
            "/api/models/my-model",
            json={"model_id": "my-model", "max_seqlen": 12345},
        )
        self.assertEqual(r.status_code, 200, r.text)
        cfg = models_mod.load_model_configs()["my-model"]
        # base_url / name / api_key 全部沿用现值
        self.assertEqual(cfg.base_url, "http://localhost:8001/v1")
        self.assertEqual(cfg.name, "My Model")
        self.assertEqual(cfg.api_key, "sk-custom")
        self.assertEqual(cfg.extra["max_seqlen"], 12345)

    def test_update_api_key_when_provided(self):
        r = self.client.patch(
            "/api/models/my-model",
            json={"model_id": "my-model", "api_key": "sk-new"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            models_mod.load_model_configs()["my-model"].api_key, "sk-new"
        )

    def test_update_missing_404(self):
        r = self.client.patch(
            "/api/models/nope", json={"model_id": "nope", "name": "x"}
        )
        self.assertEqual(r.status_code, 404)

    def test_update_range_check(self):
        r = self.client.patch(
            "/api/models/my-model",
            json={"model_id": "my-model", "compress_threshold": 0.99},
        )
        self.assertEqual(r.status_code, 400)


class TestDeleteModel(ModelApiBase):
    def setUp(self):
        super().setUp()
        self.client.post("/api/models", json=self._create_payload())

    def test_delete_removes_file_and_refreshes(self):
        r = self.client.delete("/api/models/my-model")
        self.assertEqual(r.status_code, 200, r.text)
        self.assertFalse((self._models_dir / "my-model.yaml").exists())
        self.assertNotIn("my-model", state.model_configs)

    def test_delete_reports_bound_agents(self):
        agent = agent_store.create_agent(USER["openid"], "绑定者", "my-model")
        r = self.client.delete("/api/models/my-model")
        self.assertEqual(r.status_code, 200, r.text)
        bound = r.json()["bound_agents"]
        self.assertEqual([b["id"] for b in bound], [agent["id"]])

    def test_delete_missing_404(self):
        r = self.client.delete("/api/models/nope")
        self.assertEqual(r.status_code, 404)

    def test_delete_traversal_rejected(self):
        r = self.client.delete("/api/models/..%2F..%2Fetc%2Fpasswd")
        self.assertEqual(r.status_code, 404)


class TestAgentModelOverrides(ModelApiBase):
    def _agent(self):
        return agent_store.create_agent(USER["openid"], "测试", "flash")

    def test_patch_writes_overrides(self):
        agent = self._agent()
        r = self.client.patch(
            f"/api/agents/{agent['id']}",
            json={
                "reasoning_effort": "high",
                "max_seqlen": 32768,
                "max_output_tokens": 2048,
                "compress_threshold": 0.5,
            },
        )
        self.assertEqual(r.status_code, 200, r.text)
        row = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertEqual(row["reasoning_effort"], "high")
        self.assertEqual(row["max_seqlen_override"], 32768)
        self.assertEqual(row["max_output_tokens"], 2048)
        self.assertAlmostEqual(row["compress_threshold"], 0.5)

    def test_patch_none_means_unchanged(self):
        agent = self._agent()
        self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "low"}
        )
        # 只改提示词：reasoning_effort 必须保留
        self.client.patch(
            f"/api/agents/{agent['id']}", json={"system_prompt": "新"}
        )
        row = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertEqual(row["reasoning_effort"], "low")

    def test_clear_overrides(self):
        agent = self._agent()
        self.client.patch(
            f"/api/agents/{agent['id']}",
            json={
                "reasoning_effort": "max",
                "max_seqlen": 111,
                "max_output_tokens": 222,
                "compress_threshold": 0.3,
            },
        )
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"clear_model_overrides": True}
        )
        self.assertEqual(r.status_code, 200, r.text)
        row = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertIsNone(row["reasoning_effort"])
        self.assertIsNone(row["max_seqlen_override"])
        self.assertIsNone(row["max_output_tokens"])
        self.assertIsNone(row["compress_threshold"])

    def test_range_validation(self):
        agent = self._agent()
        bad_payloads = [
            {"max_seqlen": 0},
            {"max_output_tokens": 0},
            {"compress_threshold": 0.05},
            {"compress_threshold": 0.99},
        ]
        for payload in bad_payloads:
            r = self.client.patch(f"/api/agents/{agent['id']}", json=payload)
            self.assertEqual(r.status_code, 400, f"{payload} 应 400")

    def test_empty_body_400(self):
        agent = self._agent()
        r = self.client.patch(f"/api/agents/{agent['id']}", json={})
        self.assertEqual(r.status_code, 400)

    def test_models_info_exposes_overrides(self):
        agent = self._agent()
        # 档位校验基准是**该模型生效的档位**（flash 未声明 → 全局 low/high/max）。
        # `none`（关闭思考）是独立语义、不在有区分度的档位内，必须 400 而不是
        # 落库后在每次发言时被网关 422 拒绝。
        r_bad = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "none"}
        )
        self.assertEqual(r_bad.status_code, 400, r_bad.text)
        # 旧 UI 的别名取值仍被接受，但入库存规范值（minimal→low）
        r_alias = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "minimal"}
        )
        self.assertEqual(r_alias.status_code, 200, r_alias.text)
        self.assertEqual(
            agent_store.get_agent(USER["openid"], agent["id"])["reasoning_effort"],
            "low",
        )
        self.client.patch(
            f"/api/agents/{agent['id']}",
            json={"reasoning_effort": "high", "max_seqlen": 4096},
        )
        # models-info 走实时扫盘（get_model_configs），此处注入固定模型池
        with patch("agent.routes.get_model_configs",
                   return_value=dict(state.model_configs)):
            r = self.client.get(f"/api/agents/{agent['id']}/models-info")
        self.assertEqual(r.status_code, 200)
        data = r.json()
        self.assertEqual(data["overrides"]["reasoning_effort"], "high")
        self.assertEqual(data["overrides"]["max_seqlen"], 4096)
        self.assertIsNone(data["overrides"]["max_output_tokens"])
        # models[] 仍逐字段白名单且不含密钥
        model = data["models"][0]
        self.assertNotIn("api_key", model)
        self.assertNotIn("secret", model["base_url"])
        # 该模型未声明档位 → 后端回退「有实际区分度」的档位供前端下拉
        self.assertEqual(
            model["reasoning_effort_options"], ["low", "high", "max"]
        )


class TestApplyOverridesToModelConfig(unittest.TestCase):
    """``chat._apply_agent_model_overrides``：合并覆盖且不污染共享配置。"""

    def setUp(self):
        self._orig_state_configs = state.model_configs
        self._orig_db = agent_store._DB_PATH  # type: ignore[attr-defined]
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_ov_"))
        agent_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        agent_store._initialized = False  # type: ignore[attr-defined]
        base = ModelConfig(
            name="Flash", base_url="http://x", api_key="k", model_id="flash",
            extra={"max_seqlen": 8192},
        )
        self.base = base
        state.model_configs = {"flash": base}
        self.addCleanup(self._restore)

    def _restore(self):
        state.model_configs = self._orig_state_configs
        agent_store._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        agent_store._initialized = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_no_overrides_returns_same_object(self):
        from agent.chat import _apply_agent_model_overrides

        agent = agent_store.create_agent(USER["openid"], "a", "flash")
        self.assertIs(
            _apply_agent_model_overrides(self.base, agent["id"], USER["openid"]),
            self.base,
        )

    def test_overrides_merged_without_mutating_source(self):
        from agent.chat import _apply_agent_model_overrides

        agent = agent_store.create_agent(USER["openid"], "a", "flash")
        agent_store.update_agent(
            USER["openid"], agent["id"],
            reasoning_effort="high",
            max_seqlen_override=4096,
            max_output_tokens=1024,
            compress_threshold=0.5,
        )
        merged = _apply_agent_model_overrides(
            self.base, agent["id"], USER["openid"]
        )
        self.assertIsNot(merged, self.base)
        self.assertEqual(merged.extra["max_seqlen"], 4096)
        self.assertEqual(merged.extra["reasoning_effort"], "high")
        self.assertEqual(merged.extra["max_output_tokens"], 1024)
        self.assertAlmostEqual(merged.extra["compress_threshold"], 0.5)
        # 共享实例未被就地污染（否则同模型的其它 agent 会连带生效）
        self.assertEqual(self.base.extra["max_seqlen"], 8192)
        self.assertNotIn("reasoning_effort", self.base.extra)

    def test_session_reads_overrides(self):
        """端到端：覆盖值经 AgentLLMSession 生效（max_seqlen / 阈值 / 输出）。"""
        from llm.llm import AgentLLMSession

        agent = agent_store.create_agent(USER["openid"], "a", "flash")
        agent_store.update_agent(
            USER["openid"], agent["id"],
            max_seqlen_override=2048,
            max_output_tokens=512,
            compress_threshold=0.4,
        )
        from agent.chat import _apply_agent_model_overrides

        merged = _apply_agent_model_overrides(
            self.base, agent["id"], USER["openid"]
        )
        session = AgentLLMSession(model_config=merged, workspace_id="ws")
        self.assertEqual(session.max_seqlen, 2048)
        self.assertEqual(session.max_output_tokens, 512)
        self.assertAlmostEqual(session.compress_threshold, 0.4)

    def test_compress_threshold_clamped(self):
        """越界阈值被夹到 (0,1)，防"永不压缩/每轮压缩"。"""
        from llm.llm import AgentLLMSession

        for raw, expected in ((0.0, 0.1), (1.5, 0.95)):
            cfg = ModelConfig(
                name="m", base_url="http://x", api_key="k", model_id="m",
                extra={"max_seqlen": 1000, "compress_threshold": raw},
            )
            session = AgentLLMSession(model_config=cfg, workspace_id="ws")
            self.assertAlmostEqual(session.compress_threshold, expected)

    def test_max_tokens_dispatch(self):
        """max_output_tokens 下发为 kwargs['max_tokens']；未配置时不带。"""
        from llm.llm import AgentLLMSession

        cfg = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 1000, "max_output_tokens": 777},
        )
        session = AgentLLMSession(model_config=cfg, workspace_id="ws")
        self.assertEqual(session._build_api_kwargs()["max_tokens"], 777)

        cfg2 = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 1000},
        )
        session2 = AgentLLMSession(model_config=cfg2, workspace_id="ws")
        self.assertNotIn("max_tokens", session2._build_api_kwargs())

    def test_new_keys_not_passed_to_api(self):
        """reserved 黑名单必须挡住新键，否则 OpenAI SDK 抛 TypeError → agent 无响应。"""
        from llm.llm import AgentLLMSession

        cfg = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={
                "max_seqlen": 1000,
                "max_output_tokens": 100,
                "compress_threshold": 0.5,
                # 档位声明同样是纯声明字段，绝不能被当 OpenAI 顶层参数透传
                "reasoning_effort_options": ["low", "high"],
            },
        )
        session = AgentLLMSession(model_config=cfg, workspace_id="ws")
        kwargs = session._build_api_kwargs()
        self.assertNotIn("compress_threshold", kwargs)
        self.assertNotIn("max_output_tokens", kwargs)
        self.assertNotIn("reasoning_effort_options", kwargs)
        # 但输出长度必须已转成标准参数
        self.assertEqual(kwargs["max_tokens"], 100)


class TestMigrationIdempotent(ModelApiBase):
    def test_model_override_columns_added_and_idempotent(self):
        agent = agent_store.create_agent(USER["openid"], "a", "flash")
        # 重复触发 _ensure_db 不应抛错（ALTER TABLE 幂等）
        agent_store._initialized = False  # type: ignore[attr-defined]
        row = agent_store.get_agent(USER["openid"], agent["id"])
        for column in (
            "reasoning_effort", "max_seqlen_override",
            "max_output_tokens", "compress_threshold",
        ):
            self.assertIn(column, row)


if __name__ == "__main__":
    unittest.main()
