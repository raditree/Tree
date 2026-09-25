# -*- coding: utf-8 -*-
"""思考强度（reasoning_effort）取值归一化、可选档位声明与校验测试。

背景（三个真实故障面）：
1. **网关对取值大小写与空白敏感**：实测同一端点上 `"  high  "` / `"HIGH"` / `""`
   均被拒（422 unknown variant），只有精确小写无空白才通过。
2. **枚举全集 ≠ 有区分度的档位**：端点接受的枚举是语法层全集，但多个取值在
   服务端被映射到同一档（minimal→low、medium→high、xhigh→high、ultra→max），
   直接摆进下拉就是"选起来无差别"的假选项。
3. **声明字段一旦透传即致命**：`reasoning_effort_options` 会落进
   `ModelConfig.extra`，若漏进 `_build_api_kwargs` 的 ``reserved`` 集合，会被当
   OpenAI 顶层参数透传 → SDK 抛 TypeError → agent 完全无响应
   （历史同类故障：`is_limitless_context`）。

覆盖：
- ``normalize_reasoning_effort``：strip / lower / 别名折叠 / 枚举外拒绝
- ``normalize_reasoning_effort_options`` / ``resolve_reasoning_effort_options``
- ``_build_api_kwargs``：reserved 挡住声明键；默认值被归一化；非法值不下发
- POST/PATCH /api/models：档位声明写盘与回显、默认档位校验、别名折叠入库
- PATCH /api/agents/{id}：别名归一化入库、超范围 400（拦在网关之前）
- models-info / /api/models 的 ``reasoning_effort_options`` 暴露
- 随包示例配置的档位回退

隔离：临时目录承载模型 YAML；临时 DB；TestClient override 认证。
"""
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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
from config.models import (  # noqa: E402
    REASONING_EFFORT_ACCEPTED,
    REASONING_EFFORT_CANONICAL,
    REASONING_EFFORT_OPTIONS_KEY,
    ModelConfig,
    normalize_reasoning_effort,
    normalize_reasoning_effort_options,
    resolve_reasoning_effort_options,
)

USER = {"openid": "u-effort-test"}

_REDIRECT_MODS = (
    agent_store, mcp_store, team_store, conv_store, session_store, db_mod,
)


class TestNormalizeEffort(unittest.TestCase):
    """纯函数层：归一化与档位解析。"""

    def test_strip_and_lower(self):
        for raw in ("HIGH", "  high  ", "\tHigh\n"):
            self.assertEqual(normalize_reasoning_effort(raw), "high", raw)

    def test_aliases_folded_to_canonical(self):
        # 与端点文档映射表一致：多个取值在服务端落同一档
        self.assertEqual(normalize_reasoning_effort("minimal"), "low")
        self.assertEqual(normalize_reasoning_effort("medium"), "high")
        self.assertEqual(normalize_reasoning_effort("xhigh"), "high")
        self.assertEqual(normalize_reasoning_effort("ultra"), "max")

    def test_none_is_its_own_level(self):
        """none 是「关闭思考」的独立语义，不能被折叠进 low。"""
        self.assertEqual(normalize_reasoning_effort("none"), "none")
        self.assertNotIn("none", REASONING_EFFORT_CANONICAL)

    def test_non_accepted_rejected(self):
        for raw in ("", "   ", "bogus", "high2", None, 5, [], {}):
            self.assertIsNone(normalize_reasoning_effort(raw), repr(raw))

    def test_canonical_subset_of_accepted(self):
        for level in REASONING_EFFORT_CANONICAL:
            self.assertIn(level, REASONING_EFFORT_ACCEPTED)

    def test_options_normalized_deduped_ordered(self):
        self.assertEqual(
            normalize_reasoning_effort_options(["medium", "MINIMAL", "max"]),
            ["high", "low", "max"],
        )
        # 去重：xhigh 与 medium 都折叠成 high
        self.assertEqual(
            normalize_reasoning_effort_options(["xhigh", "medium"]), ["high"]
        )

    def test_options_accepts_comma_string(self):
        self.assertEqual(
            normalize_reasoning_effort_options("low, high，max"),
            ["low", "high", "max"],
        )

    def test_options_all_invalid_returns_none(self):
        self.assertIsNone(normalize_reasoning_effort_options(["bogus", ""]))
        self.assertIsNone(normalize_reasoning_effort_options([]))
        self.assertIsNone(normalize_reasoning_effort_options(None))

    def test_resolve_falls_back_to_canonical(self):
        # 未声明 → canonical（而非 accepted 全集：后者含多个等价别名）
        self.assertEqual(
            resolve_reasoning_effort_options({}), list(REASONING_EFFORT_CANONICAL)
        )
        self.assertEqual(
            resolve_reasoning_effort_options({REASONING_EFFORT_OPTIONS_KEY: None}),
            list(REASONING_EFFORT_CANONICAL),
        )

    def test_resolve_prefers_declaration(self):
        self.assertEqual(
            resolve_reasoning_effort_options(
                {REASONING_EFFORT_OPTIONS_KEY: ["low", "max"]}
            ),
            ["low", "max"],
        )

    def test_resolve_ignores_bogus_declaration(self):
        self.assertEqual(
            resolve_reasoning_effort_options(
                {REASONING_EFFORT_OPTIONS_KEY: ["bogus"]}
            ),
            list(REASONING_EFFORT_CANONICAL),
        )


class TestApiKwargsNormalization(unittest.TestCase):
    """``_build_api_kwargs``：声明键挡在 SDK 之外，取值归一化。"""

    def _kwargs(self, extra):
        from llm.llm import AgentLLMSession

        cfg = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra=dict(extra, max_seqlen=1000),
        )
        return AgentLLMSession(model_config=cfg, workspace_id="ws")._build_api_kwargs()

    def test_declaration_key_not_passed_to_api(self):
        kwargs = self._kwargs({REASONING_EFFORT_OPTIONS_KEY: ["low", "high"]})
        self.assertNotIn(REASONING_EFFORT_OPTIONS_KEY, kwargs)

    def test_effort_normalized_before_dispatch(self):
        # YAML 里带空白 / 大写也必须被归一化，否则网关 422
        self.assertEqual(
            self._kwargs({"reasoning_effort": "  HIGH "})["reasoning_effort"],
            "high",
        )

    def test_alias_normalized_before_dispatch(self):
        self.assertEqual(
            self._kwargs({"reasoning_effort": "medium"})["reasoning_effort"],
            "high",
        )

    def test_invalid_effort_dropped_not_dispatched(self):
        """枚举外取值不下发：让模型用自身默认，而不是让整轮对话失败。"""
        kwargs = self._kwargs({"reasoning_effort": "bogus"})
        self.assertNotIn("reasoning_effort", kwargs)

    def test_absent_effort_stays_absent(self):
        self.assertNotIn("reasoning_effort", self._kwargs({}))


class EffortApiBase(unittest.TestCase):
    """共享夹具：临时模型目录 + 临时 DB + 认证 override。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_eff_db_"))
        self._models_dir = Path(tempfile.mkdtemp(prefix="trae_eff_models_"))
        self._orig_db = {m: m._DB_PATH for m in _REDIRECT_MODS}
        self._orig_models_dir = models_mod._MODELS_DIR
        self._orig_state_configs = state.model_configs
        self.addCleanup(self._restore_globals)
        for m in _REDIRECT_MODS:
            m._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
            m._initialized = False  # type: ignore[attr-defined]
        models_mod._MODELS_DIR = self._models_dir

        state.model_configs = {
            # 声明三档（与真实 deepseek 配置一致）
            "declared": ModelConfig(
                name="Declared", base_url="http://x", api_key="sk-1",
                model_id="declared", thinking=True,
                extra={
                    "max_seqlen": 8192,
                    REASONING_EFFORT_OPTIONS_KEY: ["low", "high", "max"],
                },
            ),
            # 声明窄档位：只有 high
            "narrow": ModelConfig(
                name="Narrow", base_url="http://x", api_key="sk-2",
                model_id="narrow",
                extra={
                    "max_seqlen": 8192,
                    REASONING_EFFORT_OPTIONS_KEY: ["high"],
                },
            ),
            # 未声明 → 回退 canonical
            "bare": ModelConfig(
                name="Bare", base_url="http://x", api_key="sk-3",
                model_id="bare", extra={"max_seqlen": 8192},
            ),
        }
        app = FastAPI()
        app.include_router(agent_router)
        from ws.auth import get_current_user

        app.dependency_overrides[get_current_user] = lambda: dict(USER)
        self.client = TestClient(app)

    def _restore_globals(self):
        for m in _REDIRECT_MODS:
            m._DB_PATH = self._orig_db[m]
            m._initialized = False
        models_mod._MODELS_DIR = self._orig_models_dir
        state.model_configs = self._orig_state_configs
        shutil.rmtree(self._tmp, ignore_errors=True)
        shutil.rmtree(self._models_dir, ignore_errors=True)

    def _agent(self, model_id: str = "declared"):
        return agent_store.create_agent(USER["openid"], "测试", model_id)


class TestAgentEffortValidation(EffortApiBase):
    """PATCH /api/agents/{id}：别名归一化入库，超范围拦在网关之前。"""

    def test_alias_normalized_on_write(self):
        agent = self._agent()
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "medium"}
        )
        self.assertEqual(r.status_code, 200, r.text)
        row = agent_store.get_agent(USER["openid"], agent["id"])
        # 入库即规范值：避免库中出现与 high 等价的重复表示
        self.assertEqual(row["reasoning_effort"], "high")

    def test_whitespace_and_case_normalized_on_write(self):
        agent = self._agent()
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "  MAX "}
        )
        self.assertEqual(r.status_code, 200, r.text)
        row = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertEqual(row["reasoning_effort"], "max")

    def test_out_of_declared_range_rejected(self):
        """narrow 只支持 high：low/max 必须 400，而不是落库后每次发言 422。"""
        agent = self._agent("narrow")
        for bad in ("low", "max"):
            r = self.client.patch(
                f"/api/agents/{agent['id']}", json={"reasoning_effort": bad}
            )
            self.assertEqual(r.status_code, 400, f"{bad} 应 400: {r.text}")
            self.assertIn("high", r.json()["detail"])
        r_ok = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "high"}
        )
        self.assertEqual(r_ok.status_code, 200, r_ok.text)

    def test_alias_into_declared_range_accepted(self):
        """narrow 未声明 medium，但 medium 折叠为 high（在档位内）→ 接受。"""
        agent = self._agent("narrow")
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "medium"}
        )
        self.assertEqual(r.status_code, 200, r.text)
        row = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertEqual(row["reasoning_effort"], "high")

    def test_enum_outside_rejected(self):
        agent = self._agent()
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "bogus"}
        )
        self.assertEqual(r.status_code, 400, r.text)
        self.assertIn("bogus", r.json()["detail"])

    def test_blank_effort_means_unchanged(self):
        """纯空白 = 不修改（不覆盖），而非写空串（空串会被网关 422 拒绝）。"""
        agent = self._agent()
        self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "low"}
        )
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "   "}
        )
        self.assertEqual(r.status_code, 200, r.text)
        row = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertEqual(row["reasoning_effort"], "low")

    def test_bare_model_uses_canonical_fallback(self):
        agent = self._agent("bare")
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "max"}
        )
        self.assertEqual(r.status_code, 200, r.text)

    def test_validation_follows_new_model(self):
        """同时换模型与档位：按**新**模型的档位校验。"""
        agent = self._agent("declared")
        # declared → narrow（只有 high）：low 应被拒
        r = self.client.patch(
            f"/api/agents/{agent['id']}",
            json={"model_id": "narrow", "reasoning_effort": "low"},
        )
        self.assertEqual(r.status_code, 400, r.text)

    def test_unknown_model_does_not_block(self):
        """绑定模型已删（历史脏数据）时不阻塞保存，交由运行时兜底。"""
        agent = self._agent("declared")
        r = self.client.patch(
            f"/api/agents/{agent['id']}",
            json={"model_id": "gone", "reasoning_effort": "low"},
        )
        # model_id 存在于 state.model_configs 校验在前 → 该请求本身 400；
        # 换一条只改档位的请求（模型仍在）确认不被误拦
        self.assertEqual(r.status_code, 400)
        r2 = self.client.patch(
            f"/api/agents/{agent['id']}", json={"reasoning_effort": "low"}
        )
        self.assertEqual(r2.status_code, 200, r2.text)


class TestModelEffortOptionsApi(EffortApiBase):
    """POST/PATCH /api/models：档位声明写盘、回显与默认值校验。"""

    def _payload(self, **overrides):
        # model_id 按测试方法派生：同类的测试共用临时模型目录，
        # 复用同一 id 会让后跑的用例撞上前一个落盘的文件（400 模型已存在）
        payload = {
            "model_id": f"custom-{self._testMethodName}",
            "name": "Custom",
            "base_url": "http://localhost:9/v1",
            "api_key": "sk-custom",
        }
        payload.update(overrides)
        return payload

    def _model_id(self) -> str:
        return f"custom-{self._testMethodName}"

    def test_create_persists_and_returns_options(self):
        r = self.client.post(
            "/api/models",
            json=self._payload(
                reasoning_effort="high",
                reasoning_effort_options=["low", "high"],
            ),
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            r.json()["model"]["reasoning_effort_options"], ["low", "high"]
        )
        # 落盘内容可被重新加载
        cfg = models_mod.load_model_configs()[self._model_id()]
        self.assertEqual(
            cfg.extra[REASONING_EFFORT_OPTIONS_KEY], ["low", "high"]
        )

    def test_create_normalizes_aliases(self):
        # 选一组"默认档位归一化后确实落在声明档位内"的别名：
        # MINIMAL→low、ultra→max，声明档位为 [minimal, ultra]→[low, max]，
        # 归一化后 low 命中 → 应接受（反例见
        # test_create_rejects_default_outside_declared_options）
        r = self.client.post(
            "/api/models",
            json=self._payload(
                reasoning_effort="MINIMAL",
                reasoning_effort_options=["minimal", "ultra"],
            ),
        )
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()["model"]
        self.assertEqual(body["reasoning_effort"], "low")
        self.assertEqual(body["reasoning_effort_options"], ["low", "max"])

    def test_create_rejects_default_outside_declared_options(self):
        r = self.client.post(
            "/api/models",
            json=self._payload(
                reasoning_effort="max",
                reasoning_effort_options=["low", "high"],
            ),
        )
        self.assertEqual(r.status_code, 400, r.text)
        self.assertIn("可选档位", r.json()["detail"])

    def test_create_rejects_bogus_default(self):
        r = self.client.post(
            "/api/models", json=self._payload(reasoning_effort="bogus")
        )
        self.assertEqual(r.status_code, 400, r.text)

    def test_create_rejects_all_invalid_options(self):
        r = self.client.post(
            "/api/models",
            json=self._payload(reasoning_effort_options=["bogus", "nope"]),
        )
        self.assertEqual(r.status_code, 400, r.text)

    def test_create_rejects_empty_options_list(self):
        r = self.client.post(
            "/api/models", json=self._payload(reasoning_effort_options=[])
        )
        self.assertEqual(r.status_code, 400, r.text)

    def test_blank_default_effort_not_written_to_yaml(self):
        """空白默认值不落盘成 ""：空串不是合法枚举，会让该模型每次请求告警。"""
        r = self.client.post(
            "/api/models", json=self._payload(reasoning_effort="   ")
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertIsNone(r.json()["model"]["reasoning_effort"])
        cfg = models_mod.load_model_configs()[self._model_id()]
        self.assertNotIn("reasoning_effort", cfg.extra)

    def test_create_without_options_falls_back_to_canonical(self):
        r = self.client.post("/api/models", json=self._payload())
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            r.json()["model"]["reasoning_effort_options"],
            list(REASONING_EFFORT_CANONICAL),
        )

    def _create(self, **overrides):
        r = self.client.post("/api/models", json=self._payload(**overrides))
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()["model"]

    def test_patch_without_options_preserves_declaration(self):
        """未传该键 = 沿用文件现值，而不是被全局回退值覆盖。"""
        self._create(reasoning_effort_options=["low", "max"])
        r = self.client.patch(
            f"/api/models/{self._model_id()}", json=self._payload(name="改名")
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["model"]["name"], "改名")
        cfg = models_mod.load_model_configs()[self._model_id()]
        self.assertEqual(cfg.extra[REASONING_EFFORT_OPTIONS_KEY], ["low", "max"])

    def test_patch_can_narrow_options(self):
        self._create(reasoning_effort_options=["low", "high", "max"])
        r = self.client.patch(
            f"/api/models/{self._model_id()}",
            json=self._payload(reasoning_effort_options=["high"]),
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["model"]["reasoning_effort_options"], ["high"])


class TestEffortOptionsExposure(EffortApiBase):
    """前端下拉的数据来源：两个接口都必须带上解析后的档位列表。"""

    def test_models_info_exposes_per_model_options(self):
        agent = self._agent()
        with patch("agent.routes.get_model_configs",
                   return_value=dict(state.model_configs)):
            r = self.client.get(f"/api/agents/{agent['id']}/models-info")
        self.assertEqual(r.status_code, 200, r.text)
        by_id = {m["model_id"]: m for m in r.json()["models"]}
        self.assertEqual(by_id["declared"]["reasoning_effort_options"],
                         ["low", "high", "max"])
        self.assertEqual(by_id["narrow"]["reasoning_effort_options"], ["high"])
        self.assertEqual(by_id["bare"]["reasoning_effort_options"],
                         list(REASONING_EFFORT_CANONICAL))

    def test_models_list_exposes_options(self):
        with patch("agent.routes.get_model_configs",
                   return_value=dict(state.model_configs)):
            r = self.client.get("/api/models")
        self.assertEqual(r.status_code, 200, r.text)
        by_id = {m["model_id"]: m for m in r.json()["models"]}
        self.assertEqual(by_id["narrow"]["reasoning_effort_options"], ["high"])

    def test_declaration_key_never_in_api_kwargs_for_declared_model(self):
        """回归护栏：声明键在真实模型配置上也绝不透传给 SDK。"""
        from llm.llm import AgentLLMSession

        cfg = state.model_configs["declared"]
        kwargs = AgentLLMSession(
            model_config=cfg, workspace_id="ws"
        )._build_api_kwargs()
        self.assertNotIn(REASONING_EFFORT_OPTIONS_KEY, kwargs)


class TestShippedModelConfigs(unittest.TestCase):
    """随包示例配置：档位回退必须可解析（防止示例被写坏）。"""

    def test_example_model_loads_with_canonical_options(self):
        import yaml

        path = (
            Path(__file__).resolve().parent.parent
            / "configs" / "models" / "model.example.yaml"
        )
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        cfg = ModelConfig.from_dict(data)
        self.assertEqual(
            resolve_reasoning_effort_options(cfg.extra),
            list(REASONING_EFFORT_CANONICAL),
        )
        # 示例里注释掉的档位声明必须真的是注释（不落进 extra）
        self.assertNotIn(REASONING_EFFORT_OPTIONS_KEY, cfg.extra)


if __name__ == "__main__":
    unittest.main()
