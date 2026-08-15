"""在 Docker 沙箱容器内安装文档处理依赖。"""
import subprocess
import sys

def run_docker(cmd_list):
    result = subprocess.run(["docker"] + cmd_list, capture_output=True, text=True)
    return result

# 启动容器（如果已停止）
result = run_docker(["start", "workspace_top"])
print(f"Start container: exit={result.returncode}")

# 安装所有文档处理库
pkgs = ["pymupdf", "python-pptx", "python-docx", "openpyxl"]
result = run_docker(["exec", "workspace_top", "pip", "install"] + pkgs)
print(f"Install exit: {result.returncode}")
print(result.stdout[:500] if result.stdout else "")
if result.stderr:
    print(f"STDERR: {result.stderr[:500]}")

# 验证安装
result = run_docker(["exec", "workspace_top", "python3", "-c",
    "import pymupdf, pptx, docx, openpyxl; print('All document libraries OK')"])
print(f"Verify exit: {result.returncode}")
print(result.stdout)
if result.stderr:
    print(f"STDERR: {result.stderr}")