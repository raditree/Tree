# Agent 工作空间基础镜像
FROM python:3.10-slim

# 安装 Git 和基础工具（含 iptables，用于沙箱白名单式出站网络限制）
RUN apt-get update && apt-get install -y git iptables && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /workspace

# 安装 Python 基础包
RUN pip install --no-cache-dir openai mcp httpx pymupdf python-pptx python-docx openpyxl

# 默认命令
CMD ["sleep", "infinity"]
