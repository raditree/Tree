# files（工作空间文件服务）

REST 文件面板 / 查看器 / Git 面板的**唯一**数据源，也是唯一的**路径安全边界**：前端不直接读盘，所有文件访问都从这里过。

## 文件

| 文件 | 作用 |
| --- | --- |
| [file_service.dart](file_service.dart) | 读（`list` / `content` / `readBytes` / `pdfInfo` / `gitLog` / `gitBranches`）与写（`writeContent` 按内容写文本 / 分片上传 / `syncToLocal` / `archive`）；本机与 SSH 共用一套语义 |

## 不变量（assertions）

1. 一律**工作空间相对路径**：绝对路径、盘符、UNC、`..` 逃逸一律拒绝（本地与远端同一套边界）。
2. 本机走 `dart:io`、SSH 走 `WorkspaceFiles`（SFTP），**REST 语义与安全边界完全相同**；`remoteFilesFor` 返回的那个对象同时实现 `WorkspaceFiles` 与 `WorkspaceIO`（同一个连接），Git 面板经它跑 exec——不为 Git 再建连接，也不再加一个工厂。
3. 所有上限都显式且有理由：`maxListEntries` / `maxContentBytes` / `maxWriteBytes` / `maxArchiveBytes` / `maxSyncFiles` / `maxSyncBytes` / `uploadTimeout` / `archiveTimeout`；超限**拒绝并给出可读原因**，不静默截断。`maxSyncBytes` 是必需的：真机验收时只按条数判断，在一个巨大的远端根上把测试跑超时了。
4. 远端上传 = 本地暂存分片 → `complete` 时**一次 SFTP 写**（远端不需要追加写）；远端 `archive` = 先拉回本地临时目录再用本地 `tar`（远端不一定有 tar，且这样只需一条代码路径）。
5. PDF 预览由**前端**渲染（核心只给字节），因此这里没有 `pdf_preview`。
6. **不假装成功**：远端没有 git / 后端没接线时返回空列表 + 退出码或可读 400，不让面板显示假数据。
7. **按内容写文件**（`PUT /api/files/{id}/content`，源码编辑器保存）与**读路径同一套守卫**：空 / 绝对路径 / 盘符 / `~` / `..` 逃逸一律 400；图片 / PDF / Office / 压缩包按扩展名拒绝，现有文件头部含 NUL 也拒绝（与前端 `attachment_preview.dart` 同一口径）；新内容按 **UTF-8** 写且**原样保留换行**（不把 CRLF 规范化成 LF、不补尾换行）；超过 `maxWriteBytes`（4 MB）拒绝（整段内容一次写，大文件走分片上传）。
8. **写只走工作空间 IO 抽象**：本机 `LocalWorkspaceIO`、远端 `remoteIoFor` 的 `WorkspaceIO.writeFile`（与文件面板同一个 SSH 连接对象，不自己写盘、不自己起 ssh）。`if_size`（前端加载时看到的字节数）与当前字节数不符 → **409 + 当前 `size`**（前端提示刷新后重试），目标文件已不存在同样算冲突（**不带 `size`**，前端据此判定 missing），`force=1` 跳过该检查；远端取不到可用工作空间 IO 时给可读 400，**绝不假装成功**。

## 测试

```bash
cd packages/tree_core
dart test test/files_api_test.dart test/ssh_files_api_test.dart test/file_write_api_test.dart
# 真机（设 TREE_SSH_TEST_HOST / TREE_SSH_TEST_USER / TREE_SSH_TEST_KEY 才跑，否则 skip）
dart test test/ssh_files_integration_test.dart
```
