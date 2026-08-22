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
├── main.py                 # 应用入口：lifespan 初始化、REST/WS 装配、全局状态注入
├── state.py                # 全局状态容器（lifespan 填充：ws_manager/docker_manager/...）
├── ws/                     # WebSocket 组件（全局核心组件）
│   ├── auth.py             # JWT 签发/校验
│   ├── ws_manager.py       # WS 连接管理/推送
│   └── endpoints.py        # WS 消息处理（会话、工具事件、模式注册）
├── agent/                  # Agent 组件
│   ├── chat.py             # Agent 会话主逻辑（LLM 循环、工具注册、消息分发）
│   ├── routes.py           # agent CRUD / 模型列表 / compact / teammates
│   ├── team_broker.py      # 团队成员消息串行投递（切入机制）
│   └── context_isolation.py
├── tool/                   # LLM 内置工具组件（9 工具集）
│   ├── read_tool.py / write_tool.py / edit_tool.py   # 文件读写
│   ├── terminal_tool.py    # terminal：沙箱命令执行
│   ├── mcp_tool.py         # mcp：MCP 工具调用
│   ├── team_tool.py        # team：成员/消息/任务管理
│   └── ask_question_tool.py# ask_user_question：向用户提问
├── io_/                    # IO 组件（WorkspaceIO 抽象 + 三模式）
│   ├── workspace_io.py     # WorkspaceIO 抽象 + Cloud/Local 实现
│   ├── mode_resolver.py    # cloud/local/ssh 三模式判定与互斥校验
│   ├── ssh_connection_manager.py / ssh_workspace_io.py / ssh_store.py
│   ├── docker_manager.py   # Docker 工作空间生命周期 + Git + 沙箱策略
│   ├── local_executor.py   # 本地反向 WS 执行器
│   └── routes.py           # IO 相关 REST（模式/SSH 配置）
├── llm/                    # LLM 组件（OpenAI 协议）
│   └── llm.py              # LLM 会话：上下文压缩 / thinking 解析 / usage 统计
├── data/                   # Data 组件（SQLite 持久化）
│   ├── agent_store.py / conversation_store.py / session_cache.py
│   ├── user_store.py / memory.py / embed_model.py / ssh_store.py
│   └── routes.py           # 对话历史等数据 REST
├── config/                 # Config 组件
│   ├── config.py           # 应用配置加载
│   └── models.py           # 模型配置加载（YAML）
├── configs/app.yaml        # 应用配置
├── configs/models/*.yaml   # 模型配置（含密钥，已被 gitignore）
├── docker/Dockerfile       # 工作空间基础镜像
├── mcp_tools/              # MCP 工具实现（document_server / embed_search / server）
└── workspaces/             # agent 工作空间（已被 gitignore）
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

每个 `.yaml` 一个模型，见 `model.example.yaml`。所有模型均支持手动/自动上下文压缩（超过 `max_seqlen` 参考值时触发）。

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