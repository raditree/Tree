# Agent Team Desktop 效率工具

LLM 驱动的 **agent 团队桌面效率工具**：根据任务难度动态组建 agent 团队、适配无限上下文 LLM，提供云端运行 + 本地控制的混合工作流，让 LLM agent 通过 Git 仓库层级协作。

- **前端**：Flutter 桌面应用（三栏式工作界面：agent 列表 | 消息交互 | 文件管理）
- **后端**：Python / FastAPI 服务（REST + WebSocket），Docker 多 agent 工作空间隔离
- **目标平台**：Windows 7+ 桌面（受 Flutter 版本约束，请勿升级 Flutter ≥ 3.19）

---

## 功能特性

- **账号体系**：用户名 / 密码注册登录（已替换微信登录），JWT 会话；支持退出登录、注销账号（十日倒计时 + 数据保留 31 天后彻底删除）。
- **Agent 团队**：动态组建层级团队（最多四级：Level 0–3），每个 agent 拥有独立 Docker 工作空间（初始化为 Git 仓库），用户仅直接可见顶部 agent 工作目录。
- **模型接入**：OpenAI 协议统一接入，每个模型一个独立配置文件（`server/configs/models/*.yaml`），支持普通 LLM 与无限上下文 LLM。
- **内置工具体系**：`help / team / set / mcp / refresh`。
  - `team`：成员管理（创建、成员管理表与多维评分、查询、状态）、消息管理（点对点、广播、文件发送）、任务管理。
- **MCP 工具**：`read / write / edit / terminal / embed_search`。
- **上下文管理**：普通 LLM 记忆管理 + 手动/自动上下文压缩；无限上下文 LLM 原子上下文管理；上下文持久化到数据库（重启不丢失）。
- **上下文隔离**：子 agent 工作成果通过摘要汇报，不淹没父 agent 上下文。
- **文件能力**：多格式文件查看器（UTF-8、docx/odt/doc/rtf/pdf/pptx/xlsx/xls/jpg/png、markdown/svg 预览、一键复制）、双向文件同步、Git 历史与分支查看。
- **沙箱安全**：白名单式出站网络（iptables + 出站代理）、单次下载数据量上限（<1G）、磁盘软上限告警。

---

## 项目结构

```
flutter_application_tree/
├── lib/                    # Flutter 前端
│   ├── main.dart           # 应用入口（登录态路由）
│   ├── models/             # 数据模型（agent/message/file_node）
│   ├── pages/              # 登录、主界面、设置
│   ├── services/           # API / WebSocket / 认证 / 主题
│   └── widgets/            # agent 列表、消息面板、文件面板、Git 历史等
├── server/                 # Python 后端
│   ├── main.py             # FastAPI 入口
│   ├── api/routes.py       # REST 路由（认证、agent、文件、Git…）
│   ├── core/               # 核心：LLM、Docker 工作空间、会话、存储、团队
│   ├── tools/              # 内置工具：help/team/set/mcp/refresh
│   ├── mcp_tools/          # MCP：read/write/edit/terminal/embed_search
│   ├── configs/            # app.yaml 与模型配置
│   ├── docker/Dockerfile   # agent 工作空间基础镜像
│   └── tests/              # 后端测试
├── android/ ios/ linux/ macos/ web/ windows/   # Flutter 平台脚手架
└── .trae/specs/            # 开发规格文档
```

---

## 快速开始

### 1. 构建 Docker 工作空间镜像

```bash
docker build -t agent-workspace:latest server/docker
```

> 镜像需安装 `git` 与 `iptables`（用于沙箱白名单网络）。不重建镜像时，下载上限代理仍生效，但 iptables 白名单层不可用。

### 2. 配置后端

```bash
cd server
python -m venv .venv                  # 可选，建议使用虚拟环境
.venv\Scripts\pip install -r requirements.txt   # Windows
```

- 复制并填写模型配置：`server/configs/models/model.example.yaml` → `*.yaml`
- 修改 `server/configs/app.yaml`：服务端口、JWT 密钥、Docker 资源限制、沙箱白名单等。

### 3. 启动后端

```bash
cd server
.venv\Scripts\python.exe main.py
```

启动后控制台输出 `Application startup complete`，服务监听 `0.0.0.0:8000`。

### 4. 启动前端

```bash
flutter pub get
flutter run -d windows
```

首次登录需注册账号（用户名 + 密码）。

---

## 配置说明

### 模型配置（`server/configs/models/*.yaml`）

每个 `.yaml` 文件一个模型，必填字段见 `model.example.yaml`。`is_limitless_context: true` 表示无限上下文 LLM。

### 应用配置（`server/configs/app.yaml`）

| 段 | 说明 |
| --- | --- |
| `server` | 服务监听地址与端口 |
| `agents` | 每用户 agent 上限、团队最大层级 |
| `docker` | 工作空间镜像、资源配额（CPU/内存/磁盘）、每层成员上限 |
| `upload` | 单文件大小上限、沙箱总大小上限（软上限告警） |
| `sandbox.network` | 白名单式出站网络 + 单次下载上限 |
| `jwt` | 会话令牌密钥与有效期 |

---

## 常见问题

- **Docker 不可用**：后端会优雅降级，但工作空间隔离、Git 层级协作、沙箱限制不可用。
- **模型 API 拉取失败**：不影响已配置的 YAML 模型；提供服务商不可达时仅跳过该提供商的运行期拉取。
- **Windows 7 支持**：请保持 Flutter 版本 ≤ 3.19，使用 Visual Studio 2019 Build Tools + Windows 10 SDK 10.0.19041.0 构建。

---

## 文档

- [后端文档](server/README.md)
- [开发规格](.trae/specs/build-agent-team-tool/)