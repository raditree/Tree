# 后端服务（server/）

Python / FastAPI 后端，提供 agent 团队运行的完整运行时：认证、LLM 调用、Docker 工作空间、团队协作、上下文管理、文件与 Git 能力。

---

## 环境要求

- Python 3.10+
- Docker（agent 工作空间隔离；不可用时后端优雅降级）
- 各 LLM 提供商的 API Key

## 安装与启动

```bash
cd server
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt     # Windows

# 构建 agent 工作空间镜像（需 docker 命令可用）
docker build -t agent-workspace:latest docker/

# 配置模型（必做）：复制示例并填写真实参数
xcopy configs\models\model.example.yaml configs\models\my-model.yaml

# 启动
.venv\Scripts\python.exe main.py
```

启动后服务监听 `0.0.0.0:8000`（见 `configs/app.yaml` 的 `server` 段）。

---

## 目录结构

```
server/
├── main.py                 # 应用入口：lifespan 初始化、WebSocket、会话/消息处理
├── api/routes.py           # REST 路由
├── core/                   # 核心逻辑
│   ├── auth.py             # JWT 签发/校验
│   ├── user_store.py       # 用户存储 + 注销（十日倒计时 + 31 天保留后彻底删除）
│   ├── agent_store.py      # agent 持久化（SQLite）
│   ├── conversation_store.py # 消息与上下文持久化
│   ├── session_cache.py    # 会话缓存
│   ├── llm.py              # LLM 会话：普通（上下文压缩）/ 无限上下文
│   ├── models.py           # 模型配置加载与合并（YAML + 运行期拉取）
│   ├── docker_manager.py   # Docker 工作空间生命周期 + Git + 沙箱网络/下载策略
│   ├── team_broker.py      # 团队成员消息串行投递（checklist 7 切入机制）
│   ├── memory.py           # 记忆管理
│   └── context_isolation.py
├── tools/                  # LLM 内置工具
│   ├── help_tool.py        # help：披露团队规模与资源限制
│   ├── team_tool.py        # team：成员/消息/任务管理（含文件发送、update 重生）
│   ├── set_tool.py         # set：模型/上下文参数
│   ├── mcp_tool.py         # mcp：MCP 工具调用
│   └── refresh_tool.py     # refresh：刷新 MCP 工具列表
├── mcp_tools/              # MCP 工具实现
│   ├── read_tool.py / write_tool.py / edit_tool.py
│   ├── terminal_tool.py    # terminal：沙箱命令执行
│   └── embed_search_tool.py# embed_search：工作空间文本搜索
├── configs/app.yaml        # 应用配置
├── configs/models/*.yaml   # 模型配置（含密钥，已被 gitignore）
├── docker/Dockerfile       # 工作空间基础镜像
└── data/                   # SQLite 运行时数据（已被 gitignore）
```

---

## 配置

### 应用配置 `configs/app.yaml`

| 段 | 说明 |
| --- | --- |
| `server` | 监听地址与端口 |
| `agents` | 每用户顶层 agent 上限、团队最大层级 |
| `docker` | 镜像、资源配额、每层成员上限 |
| `upload` | 单文件上限、沙箱总大小（软上限告警） |
| `sandbox.network` | 白名单式出站网络 + 单次下载上限 |
| `jwt` | 会话密钥与有效期 |
| `wechat` | 微信配置（已停用，当前为账号密码登录） |

### 模型配置 `configs/models/*.yaml`

每个 `.yaml` 一个模型，见 `model.example.yaml`。`is_limitless_context: true` 表示无限上下文 LLM（不支持上下文压缩，上下文原子追加）。普通 LLM 支持手动/自动上下文压缩。

模型池由 YAML 配置与提供商的运行期 API 拉取模型合并而成；`GET /api/models?refresh=true` 可强制刷新。

---

## 沙箱网络与下载限制（checklist 13/14）

- **白名单式出站网络**：容器获得 `NET_ADMIN`，通过 iptables 仅放行白名单主机（`sandbox.network.whitelist`）的 80/443，其余出站 DROP。
- **单次下载上限**：容器内置出站代理（`127.0.0.1:3128`），`http_proxy/https_proxy` 环境变量路由所有 HTTP/HTTPS 流量，每次下载（下行方向）超过 `sandbox.network.max_download_size`（默认 `900m`，<1G）即截断。
- **磁盘软上限告警**：工作空间占用接近 `upload.sandbox_max_size` 时，系统提示词提示清理。

> `agent-workspace:latest` 镜像需包含 `git` 与 `iptables`；旧镜像重建后白名单 iptables 层才生效。

---

## 认证与账号

- 注册 / 登录：用户名 + 密码，返回 JWT。
- 会话：前端保存 token，请求头携带鉴权。
- 注销：点击注销进入十日倒计时（期间功能照常、可随时取消）；倒计时结束后数据保留 31 天，之后由后台任务彻底删除。

---

## 测试

```bash
cd server
.venv\Scripts\python.exe -m pytest tests/
```