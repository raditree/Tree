# Agent 工作空间基础镜像
FROM python:3.10-slim

# 安装 Git 和基础工具（含 iptables，用于沙箱白名单式出站网络限制）
RUN apt-get update && apt-get install -y git iptables && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /workspace

# 安装 Python 基础包
RUN pip install --no-cache-dir openai mcp httpx pymupdf python-pptx python-docx openpyxl

# 加固：创建非 root 运行用户（uid 1000），并将 /workspace 与系统 Python 环境
# 放权给该用户，使容器默认以普通用户运行，同时保留容器内 pip install 能力。
# 注：新建工作空间卷挂载到 /workspace 时会继承此处属主（agent 可写）。
RUN useradd -m -u 1000 agent \
    && chown -R 1000:1000 /workspace \
    && chown -R 1000:1000 /usr/local/lib/python3.* /usr/local/bin

# 默认以普通用户运行（docker_manager 还会显式指定 user 与最小能力集加固）
USER agent

# 默认命令
CMD ["sleep", "infinity"]
