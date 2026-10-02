# files（工作空间文件服务）

REST 文件面板 / 查看器 / Git 面板的**唯一**数据源，也是唯一的**路径安全边界**：前端不直接读盘，所有文件访问都从这里过。

## 文件

| 文件 | 作用 |
| --- | --- |
| [file_service.dart](file_service.dart) | 读（`list` / `content` / `readBytes` / `pdfInfo` / `gitLog` / `gitBranches`）与写（分片上传 / `syncToLocal` / `archive`）；本机与 SSH 共用一套语义 |

## 不变量（assertions）

1. 一律**工作空间相对路径**：绝对路径、盘符、UNC、`..` 逃逸一律拒绝（本地与远端同一套边界）。
2. 本机走 `dart:io`、SSH 走 `WorkspaceFiles`（SFTP），**REST 语义与安全边界完全相同**；`remoteFilesFor` 返回的那个对象同时实现 `WorkspaceFiles` 与 `WorkspaceIO`（同一个连接），Git 面板经它跑 exec——不为 Git 再建连接，也不再加一个工厂。
3. 所有上限都显式且有理由：`maxListEntries` / `maxContentBytes` / `maxArchiveBytes` / `maxSyncFiles` / `maxSyncBytes` / `uploadTimeout` / `archiveTimeout`；超限**拒绝并给出可读原因**，不静默截断。`maxSyncBytes` 是必需的：真机验收时只按条数判断，在一个巨大的远端根上把测试跑超时了。
4. 远端上传 = 本地暂存分片 → `complete` 时**一次 SFTP 写**（远端不需要追加写）；远端 `archive` = 先拉回本地临时目录再用本地 `tar`（远端不一定有 tar，且这样只需一条代码路径）。
5. PDF 预览由**前端**渲染（核心只给字节），因此这里没有 `pdf_preview`。
6. **不假装成功**：远端没有 git / 后端没接线时返回空列表 + 退出码或可读 400，不让面板显示假数据。

## 测试

```bash
cd packages/tree_core
dart test test/files_api_test.dart test/ssh_files_api_test.dart
# 真机（设 TREE_SSH_TEST_HOST / TREE_SSH_TEST_USER / TREE_SSH_TEST_KEY 才跑，否则 skip）
dart test test/ssh_files_integration_test.dart
```
