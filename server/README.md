# 后端服务（server/）

Python / FastAPI 后端，提供 agent 团队运行的完整运行时。七核心组件（`ws / agent / tool / io_ / llm / data / config`）组件化装配，全局单例在 `main.lifespan` 中填充到 `state`，避免跨组件循环 import。

---

## 环境要求

- Python 3.10+
- Docker（云端模式 agent 工作空间隔离；不可用时优雅降级）
- 各 LLM 提供商的 API Key

## 安装与启动

```bash
cd server
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt     # Windows

# 构建 agent 工作空间镜像（可选，需 docker 命令可用）
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
├── main.py                 # 应用入口：lifespan 装配、REST/WS 装配、CORS、后台任务
├── state.py                # 全局状态容器（ws_manager/docker_manager/local_executor/...）
├── ws/                     # WebSocket 组件
│   ├── auth.py             # JWT 签发/校验
│   ├── ws_manager.py       # WS 连接管理/推送
│   └── endpoints.py        # WS 消息处理（会话、工具事件、local/ssh 执行器注册）
├── agent/                  # Agent 组件
│   ├── chat.py             # 会话主逻辑（LLM 循环、工具注册、消息分发、唤醒续跑）
│   ├── routes.py           # agent CRUD / 模型 / compact / questions
│   ├── team_broker.py      # 团队成员 / 顶部 agent 消息串行投递
│   └── context_isolation.py
├── tool/                   # LLM 内置工具组件
│   ├── read_tool.py / write_tool.py / edit_tool.py   # 文件读写与替换
│   ├── terminal_tool.py    # terminal：命令执行 + hook 后台长任务
│   ├── mcp_tool.py         # mcp：外部 MCP 能力
│   ├── team_tool.py        # team：成员/消息/任务管理
│   ├── ask_question_tool.py# ask_user_question：持久化异步提问
│   ├── spec_tool.py / todo_tool.py
│   └── hook_manager.py     # 后台任务管理器（hook 模式）
├── io_/                    # IO 组件（WorkspaceIO 抽象 + 三模式）
│   ├── workspace_io.py     # WorkspaceIO 抽象 + Cloud/Local 实现
│   ├── mode_resolver.py    # cloud/local/ssh 模式判定（优先级 local > ssh > cloud）
│   ├── local_executor.py   # 本地反向 WS 执行器客户端（local/ssh 共用委托通道）
│   ├── ssh_connection_manager.py / ssh_workspace_io.py
│   ├── docker_manager.py   # Docker 工作空间生命周期 + Git + 沙箱策略
│   └── routes.py           # IO 相关 REST（工作空间/文件/Git/SSH 配置，含归属校验）
├── llm/                    # LLM 组件（OpenAI 协议）
│   └── llm.py              # 会话：上下文压缩 / thinking / usage / 主动延迟限流
├── data/                   # Data 组件（SQLite 持久化 + 数据 REST）
│   ├── agent_store.py / conversation_store.py / session_store.py
│   ├── user_store.py / team_store.py / memory.py / embed_model.py
│   ├── ssh_store.py        # SSH 配置持久化（仅定位信息，不存密码）
│   ├── rate_limit_store.py / spec_store.py / data_collection_store.py
│   └── routes.py           # 健康 / 认证 / 数据 REST
├── config/                 # 配置加载
│   ├── config.py           # 应用配置加载
│   ├── models.py           # 模型配置加载（YAML）
│   └── logging_config.py
├── configs/app.yaml        # 应用配置
├── configs/models/*.yaml   # 模型配置（含密钥，已被 gitignore）
├── prompt/                 # 提示词多版本体系
│   ├── versions/           # 1.0.0/：系统章节、工具描述、压缩器
│   ├── registry.py / loader.py / llm_prompts.py
│   └── versions.py
├── docker/Dockerfile       # 工作空间基础镜像
├── mcp_tools/              # MCP 工具实现（document_server / embed_search / server）
└── tests/                  # 后端测试
```

---

## 三运行模式

工具执行统一抽象为 `WorkspaceIO`，按 `(user_id, top_agent_id)` 判定模式（`local > ssh > cloud`）：

| 模式 | 执行位置 | 实现 |
| --- | --- | --- |
| `cloud` | 后端 Docker 容器（沙箱 + 白名单网络） | `CloudWorkspaceIO` |
| `local` | 前端本机 | `LocalWorkspaceIO` 经反向 WS 委托 `LocalExecutorService` |
| `ssh` | 前端可达的远端主机 | `SSHWorkspaceIO(LocalWorkspaceIO)` 委托前端，前端用 `dartssh2` 建连执行 |

- **local / ssh 共享委托通道**：后端 `LocalExecutorClient` 把 `tool_exec_request` 经 WS 推给前端，前端执行后回传 `tool_exec_response`；后端只做模式判定与转发，不直接执行命令。
- **SSH 密码不落后端库**：连接由前端发起，后端仅持久化 host/port/username 等定位信息；`register_ssh_executor` 在边界剔除 `password` 字段。
- **模式切换**：前端切换时发送 `register_local_executor` / `register_ssh_executor` / `unregister_*`，后端更新委托守卫并清会话缓存。

---

## 配置

### 应用配置 `configs/app.yaml`

| 段 | 说明 |
| --- | --- |
| `server` | 监听地址与端口 |
| `cors` | 允许源与凭据（默认不放开任意源；`*` 与凭据不可共存） |
| `prompt` | 提示词体系版本 |
| `agents` | 每用户顶层 agent 上限、团队最大层级 |
| `docker` | 镜像、每层成员上限、资源配额 |
| `upload` | 单文件上限、沙箱总大小（软上限告警） |
| `llm` | 单次超时、重试、主动延迟限流 |
| `data_export` | 每日 SFT 导出时刻与管理员 openid |
| `sandbox.network` | 白名单式出站网络 + 单次下载上限 |
| `help_policy` | `help` 工具披露项 |
| `jwt` | 会话密钥与有效期（生产环境务必改默认密钥） |
| `wechat` | 微信配置（已停用，当前为账号密码登录） |

### 模型配置 `configs/models/*.yaml`

每个 `.yaml` 一个模型，见 `model.example.yaml`。所有模型均支持手动/自动上下文压缩（超过 `max_seqlen` 参考值时触发）。

模型池由 YAML 配置与提供商的运行期 API 拉取模型合并而成；`GET /api/models?refresh=true` 可强制刷新。

---

## 沙箱网络与下载限制

- **白名单式出站网络**：容器获得 `NET_ADMIN`，通过 iptables 仅放行白名单主机（`sandbox.network.whitelist`）的 80/443，其余出站 DROP。
- **单次下载上限**：容器内置出站代理（`127.0.0.1:3128`），`http_proxy/https_proxy` 环境变量路由所有 HTTP/HTTPS 流量，每次下载（下行方向）超过 `sandbox.network.max_download_size`（默认 `900m`，<1G）即截断。
- **磁盘软上限告警**：工作空间占用接近 `upload.sandbox_max_size` 时，系统提示词提示清理。

> `agent-workspace:latest` 镜像需包含 `git` 与 `iptables`；旧镜像重建后白名单 iptables 层才生效。

---

## 认证与安全

- 注册 / 登录：用户名 + 密码，返回 JWT；登录/注册接口带速率限制（滑动窗口，超限 429）。
- 会话：前端保存 token，请求头 / WS query 携带鉴权。
- 注销：点击注销进入十日倒计时（期间功能照常、可随时取消）；倒计时结束后数据保留 31 天，之后由后台任务彻底删除。
- **接口归属校验**：工作空间 / 文件 / Git 接口按「当前用户 → 工作空间归属」校验，`"top"` 共享演示工作空间除外；他人 workspace 返回 403。
- **路径穿越防护**：read/write 文本路径拒绝绝对路径与 `..` 段；SSH 远端路径约束在 `remote_base_dir` 之下。
- **提问归属校验**：`user_answer` / `cancel_question` 与 `POST /questions/{qid}/answer` 校验问题归属，跨用户 403。
- **账号脱敏**：`/api/auth/account/status` 响应不含 `password_hash` 与 `salt`。
- **CORS**：允许源与凭据随 `cors` 配置，杜绝任意源带凭据。

---

## 测试

```bash
cd server
.venv\Scripts\python.exe -m pytest tests/
```
