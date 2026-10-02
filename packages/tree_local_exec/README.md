# tree_local_exec

**工作空间 IO 的两个实现**（本机 `dart:io` / SSH `dartssh2`）+ shell 语义 + 判活。
内置工具只写一份，靠这里的接口屏蔽后端差异。

## 内容

| 文件 | 内容 |
| --- | --- |
| [lib/src/workspace_io.dart](lib/src/workspace_io.dart) | 接口：`WorkspaceIO`（read/write/edit/grep/list/exec/git）、`WorkspaceFiles`（文件面板：列目录 / 原始字节 / 流）、结果类型与路径异常 |
| [lib/src/local_workspace_io.dart](lib/src/local_workspace_io.dart) | 本机实现：进程树终止、非 UTF-8 输出标记（GBK 代码页尝试解码）、软超时交还活着的进程（`RunningLocalExec`） |
| [lib/src/ssh_workspace_io.dart](lib/src/ssh_workspace_io.dart) | SSH 实现：SFTP + exec，心跳判活，链路失活显式失败 |
| [lib/src/shell.dart](lib/src/shell.dart) | shell 参数：`-NonInteractive`、裸 `echo` 兼容翻译、逻辑运算符翻译（Windows/POSIX） |
| [lib/src/ssh_liveness.dart](lib/src/ssh_liveness.dart) | SSH 心跳台账（连续 N 拍丢失 ⇒ 判失活） |

## 不变量（assertions）

1. 只接受**工作空间相对路径**；`resolve` 拒绝绝对路径 / 盘符 / `..` 逃逸（`WorkspacePathException`）。
2. **没有静态任务超时**：本地判活 = 进程存活；SSH 判活 = 心跳。`exec(timeout:)` 是**本地软超时**，
   到点**不杀进程**，以 `LocalExecStillRunning` 交出活着的进程；SSH 侧忽略该参数。
3. 输出**字节不丢**：非 UTF-8 先尝试系统代码页；解不开时 latin1 兜底并标 `garbledOutput`。
4. 隐藏路径默认不扫（`.[!.]*`）；显式指向隐藏目录时按用户意图搜索。
5. 启动子进程时**禁用交互**（`-NonInteractive` + 关闭 stdin），否则等输入的命令会永久挂住
   （见 [../../docs/known-issues.md](../../docs/known-issues.md) #7）。
6. SSH 链路失活时**显式失败**（`SshLinkStaleException`），不静默挂起。

## 测试

```bash
cd packages/tree_local_exec && dart test         # 本机 + shell 语义 + 越界 + 软超时 + 挂死防护
dart analyze lib test

# 门控真机 SSH（本机无 sshd 时自动跳过）
$env:TREE_SSH_TEST_HOST='...'; $env:TREE_SSH_TEST_USER='...'; $env:TREE_SSH_TEST_KEY='...'
dart test
```

回归钉子：`exec_no_interactive_hang_test`（裸 `echo` 不再等输入）、`exec_soft_timeout_test`（软超时交还进程）、
`shell_translate_test`（裸 echo / 逻辑运算符翻译）。
