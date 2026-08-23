# 任务清单

# Tasks
- [x] Task 1: 工作空间归属授权（#3）
  - [x] SubTask 1.1: 新建归属解析助手：给定 `workspace_id`，结合 `agent_store`（workspace_id↔agent↔user_id）与团队 store 解析所有者 user_id，兼容 `top`/共享成员情形
  - [x] SubTask 1.2: 在 `server/io_/routes.py` 全部工作空间/文件/git 端点注入归属校验依赖或调用，未通过返回 403/404
  - [x] SubTask 1.3: 覆盖 `exec_in_workspace`、`delete_workspace`、`get_file_content`、`list_files`、`upload`、`download`、`git_*`、`create_workspace` 等端点
  - [x] 验证：本人/团队成员可访问；他人 workspace 返回 403/404 且不执行命令

- [x] Task 2: SSH/文本工具路径穿越防护（#4）
  - [x] SubTask 2.1: 收紧 `tool/read_tool.py`、`tool/write_tool.py` 的 `_is_valid_path`：拒绝绝对路径与 `..` 段
  - [x] SubTask 2.2: 在 `server/io_/ssh_workspace_io.py` 路径拼接前 `posixpath.normpath` 并校验仍在 `remote_base_dir` 下
  - [x] 验证：`../` 与绝对路径被拒；正常相对路径不受影响

- [x] Task 3: WebSocket 提问回答归属校验（#5）
  - [x] SubTask 3.1: `server/ws/endpoints.py` 的 `user_answer` 分支取到 `pending` 后校验 `pending["user_id"] == 连接用户`，不符则发 error 并 continue
  - [x] SubTask 3.2: `cancel_question` 分支同样校验归属
  - [x] 验证：他人 qid 被拒，不写答案不唤醒

- [x] Task 4: 账号状态响应脱敏（#6）
  - [x] SubTask 4.1: `/api/auth/account/status`（`server/data/routes.py`）对返回 user 应用 `_strip_sensitive_fields`（剔除 password_hash/salt）
  - [x] 验证：响应不含哈希/盐

- [x] Task 5: SSH 密码加密存储（#7）
  - [x] SubTask 5.1: `server/data/ssh_store.py` 增加密/解密封装（引用秘密、AES-GCM 或 Fernet 依项目依赖而定），写入时加密
  - [x] SubTask 5.2: `server/io_/ssh_connection_manager.py` 读取/注册处改用加解密；`get_all_connections` 返回不含明文密码或返回密文内部使用
  - [x] 验证：库里非明文；重启后仍可连接（密钥持久化/可配置）
  - [x] 兼容：既有明文存量数据迁移或优雅处理（如检测到无前缀则按旧逻辑读，新写一律加密）

- [x] Task 6: 登录速率限制（新增）
  - [x] SubTask 6.1: 在 `server/data/routes.py` 为 `/api/auth/login`、`/api/auth/register` 前置限流（内存滑动窗口，按 IP/用户名）
  - [x] SubTask 6.2: 超限返回 429 与提示
  - [x] 验证：窗口内超配额返回 429

- [x] Task 7: CORS 配置修正（新增）
  - [x] SubTask 7.1: `server/configs/app.yaml` 增加允许源配置（默认受限）
  - [x] SubTask 7.2: `server/main.py` 从配置构建 CORS，不再 `*`+credentials 组合
  - [x] 验证：配置的空/受限源下不开放任意源带凭据访问

# Task Dependencies
- [Task 1] 无强依赖，但归属解析需复用现有 store
- [Task 2] 独立
- [Task 3] 独立
- [Task 4] 独立
- [Task 5] 独立
- [Task 6] 独立
- [Task 7] 独立（Task 1–7 均可并行）
- 所有任务完成后统一回归：`server/tests/` 相关测试及手工冒烟