"""升级 anyio 到 4.x 版本，修复 MCP 兼容性问题。"""
import subprocess
import sys

result = subprocess.run(
    [sys.executable, "-m", "pip", "install", "--upgrade", "anyio==4.4.0"],
    capture_output=True, text=True
)
print(f"exit: {result.returncode}")
print(result.stdout[-500:] if result.stdout else "")
print(result.stderr[-500:] if result.stderr else "")

# 验证
result = subprocess.run(
    [sys.executable, "-c", "import anyio; print(anyio.__file__)"],
    capture_output=True, text=True
)
print(f"verify: {result.stdout.strip()}")