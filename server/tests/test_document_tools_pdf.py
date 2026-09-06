# -*- coding: utf-8 -*-
"""read_pdf v2 回归测试（纯后端可测部分，不依赖真实容器/前端执行器）。

覆盖（与 mcp.yaml read_pdf version: 2 对齐）：
1. TOOLS 列表含 read_pdf；inputSchema 含 mode/chapters/pages/max_chars 且 file_path 必填
2. versions.active_tool_description("read_pdf") 为 v2 描述（含"章节目录"/chapters）
3. _pick_python：python3(9009) → python 回退；结果按 workspace 缓存，二次调用不重复探测
4. _PDF_SCRIPT_TEMPLATE 含 5 个占位符；经 _run_read_pdf 生成的脚本无 %% 残留
5. _run_read_pdf 参数校验：缺 file_path / 非法 mode / mode=chapters 缺 chapters → success=False
6. 中文路径经 base64 传入脚本（脚本不直接内嵌中文）

实现说明：FakeIO 以 async exec_argv 模拟 WorkspaceIO 契约（run_io 为同步桥，
驱动协程），仅验证脚本生成与参数校验路径，不执行真实 PDF 解析。
"""

import base64
import json
import os
import re
import sys

import pytest

# 与 smoke_local_mcp_test.py 一致：将 server 目录加入 sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from mcp_tools import document_server as ds  # noqa: E402
from prompt import versions  # noqa: E402

PLACEHOLDERS = (
    "%%FILE_B64%%",
    "%%MODE_LIT%%",
    "%%CHAPTERS_LIT%%",
    "%%PAGES_LIT%%",
    "%%MAX_CHARS%%",
)

# _exec_python 解析 stdout 中行首为 "{" 的 JSON 行，故模拟出 success 输出
_DEFAULT_EXEC_FALLBACK = {
    "exit_code": 0,
    "stdout": '{"success": true, "data": "ok"}',
    "stderr": "",
}


class FakeIO:
    """最小 WorkspaceIO 桩：记录 exec_argv 调用，按解释器名返回预设结果。

    契约参照 WorkspaceIO.exec_argv（async），返回值形态与 docker_manager
    exec_in_workspace 兼容：{"exit_code", "stdout", "stderr"}。
    """

    def __init__(self, responses=None):
        self.responses = responses or {}
        self.calls = []  # [(workspace_id, argv, timeout)]

    async def exec_argv(self, workspace_id, argv, timeout=None):
        self.calls.append((workspace_id, list(argv), timeout))
        interp = argv[0]
        return dict(self.responses.get(interp, _DEFAULT_EXEC_FALLBACK))


def _win_python_responses():
    """模拟本地 Windows：python3 不可用（exit_code=9009），python 可用（0）。"""
    return {
        "python3": {"exit_code": 9009, "stdout": "", "stderr": ""},
        "python": {"exit_code": 0, "stdout": '{"success": true, "data": "ok"}', "stderr": ""},
    }


def _captured_exec_script(fake):
    """提取 _exec_python 实际提交给解释器的完整脚本（排除探测调用）。"""
    scripts = []
    for _ws, argv, _t in fake.calls:
        if len(argv) == 3 and argv[1] == "-c" and argv[2].startswith("import json, sys"):
            scripts.append(argv[2])
    assert scripts, "未捕获到执行脚本（_run_read_pdf 未走到 _exec_python？）"
    return scripts[-1]


@pytest.fixture(autouse=True)
def _isolate_interp_cache():
    """隔离模块级 _PY_INTERP_CACHE，避免用例间互相污染。"""
    saved = dict(ds._PY_INTERP_CACHE)
    ds._PY_INTERP_CACHE.clear()
    yield
    ds._PY_INTERP_CACHE.clear()
    ds._PY_INTERP_CACHE.update(saved)


# ---------------------------------------------------------------------------
# 用例 1：TOOLS 列表与 inputSchema
# ---------------------------------------------------------------------------

def test_tools_contains_read_pdf_with_schema():
    names = [t["name"] for t in ds.TOOLS]
    assert "read_pdf" in names

    pdf = next(t for t in ds.TOOLS if t["name"] == "read_pdf")
    schema = pdf["inputSchema"]
    props = schema["properties"]

    # v2 参数：mode/chapters/pages/max_chars
    assert {"file_path", "mode", "chapters", "pages", "max_chars"} <= set(props), (
        f"read_pdf 参数缺失: {sorted(set(props))}"
    )
    # file_path 必填
    assert "file_path" in schema.get("required", [])
    # mode 枚举（toc/chapters/text）
    assert {"toc", "chapters", "text"} <= set(props["mode"].get("enum", [])), (
        f"mode 枚举异常: {props['mode'].get('enum')}"
    )


# ---------------------------------------------------------------------------
# 用例 2：激活描述为 v2（含章节目录 / chapters）
# ---------------------------------------------------------------------------

def test_active_tool_description_is_v2():
    desc = versions.active_tool_description("read_pdf")
    assert "章节目录" in desc or "chapters" in desc


# ---------------------------------------------------------------------------
# 用例 3：_pick_python 回退与缓存
# ---------------------------------------------------------------------------

def test_pick_python_fallback_to_python_and_cache():
    fake = FakeIO(_win_python_responses())
    interp = ds._pick_python("ws_fallback", fake)
    assert interp == "python", "python3 失败后应回退选择 python"

    # 仅探测 python3 与 python 各一次（共 2 次）
    probes = [c for c in fake.calls if c[1][2] == "print(1)"]
    assert len(probes) == 2
    assert probes[0][1] == ["python3", "-c", "print(1)"]
    assert probes[1][1] == ["python", "-c", "print(1)"]

    # 再次调用应走缓存，不重复探测（新 FakeIO 无任何调用记录）
    fake2 = FakeIO({})
    assert ds._pick_python("ws_fallback", fake2) == "python"
    assert fake2.calls == [], "缓存命中后不应再次探测解释器"


def test_pick_python_all_fail_falls_back_to_python3():
    fake = FakeIO({"python3": {"exit_code": 1, "stdout": "", "stderr": "no"},
                   "python": {"exit_code": 1, "stdout": "", "stderr": "no"}})
    assert ds._pick_python("ws_none", fake) == "python3"


# ---------------------------------------------------------------------------
# 用例 4：模板占位符与生成脚本无残留
# ---------------------------------------------------------------------------

def test_template_has_exactly_five_placeholders():
    tpl = ds._PDF_SCRIPT_TEMPLATE
    for ph in PLACEHOLDERS:
        assert tpl.count(ph) == 1, f"占位符 {ph} 应恰好出现 1 次，实际 {tpl.count(ph)}"
    # 模板中 %% 总数 = 10（5 对占位符），不应存在其他 %%
    assert tpl.count("%%") == 10


def test_generated_script_has_no_residual_placeholder():
    fake = FakeIO(_win_python_responses())
    payload = ds._run_read_pdf(
        "ws_gen", fake, {"file_path": "docs/example.pdf", "mode": "toc"}
    )
    script = _captured_exec_script(fake)
    assert "%%" not in script, "生成脚本存在未替换的 %% 占位符残留"
    out = json.loads(payload)
    assert out.get("success") is True


# ---------------------------------------------------------------------------
# 用例 5：_run_read_pdf 参数校验
# ---------------------------------------------------------------------------

def test_run_read_pdf_validation_missing_file_path():
    payload = ds._run_read_pdf("ws_v", FakeIO(), {})
    out = json.loads(payload)
    assert out["success"] is False
    assert "file_path" in str(out["error"])


def test_run_read_pdf_validation_bad_mode():
    payload = ds._run_read_pdf("ws_v", FakeIO(), {"file_path": "a.pdf", "mode": "unknown"})
    out = json.loads(payload)
    assert out["success"] is False
    assert "mode" in str(out["error"])


def test_run_read_pdf_validation_chapters_missing():
    payload = ds._run_read_pdf(
        "ws_v", FakeIO(), {"file_path": "a.pdf", "mode": "chapters"}
    )
    out = json.loads(payload)
    assert out["success"] is False
    assert "chapters" in str(out["error"])


def test_run_read_pdf_validation_blank_file_path():
    payload = ds._run_read_pdf("ws_v", FakeIO(), {"file_path": "   "})
    out = json.loads(payload)
    assert out["success"] is False
    assert "file_path" in str(out["error"])


# ---------------------------------------------------------------------------
# 用例 6：中文路径经 base64 传入脚本
# ---------------------------------------------------------------------------

def test_chinese_path_goes_via_base64_in_script():
    fake = FakeIO(_win_python_responses())
    path = "docs/测试文档_中文示例.pdf"
    payload = ds._run_read_pdf("ws_zh", fake, {"file_path": path, "mode": "toc"})
    script = _captured_exec_script(fake)

    # 中文原文不得直接内嵌脚本
    assert "测试文档" not in script, "中文路径不应直接内嵌脚本（应为 base64）"
    # file_path 行应为 base64.b64decode(...) 解码形式
    m = re.search(r'base64\.b64decode\("([^"]+)"\)', script)
    assert m, "脚本中未找到 base64.b64decode(...) 调用"
    decoded = base64.b64decode(m.group(1)).decode("utf-8")
    assert decoded == path, f"base64 解码还原失败: {decoded!r} != {path!r}"

    out = json.loads(payload)
    assert out.get("success") is True


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
