# store（数据根与存储层）

`<数据根>` 的路径布局、记录模型与读写实现。核心的单用户数据都在这里，且全部是**人能直接打开手改**的文本。

## 文件

| 文件 | 作用 |
| --- | --- |
| [tree_paths.dart](tree_paths.dart) | 数据根解析（override → `TREE_HOME` → 平台规范位置 → `~/.tree`）与布局定义 |
| [records.dart](records.dart) | 三个记录：`CoreAgent` / `CoreSession` / `CoreMessage`；持久化形态 `toJson` 与前端形态 `toApiJson` |
| [tree_store.dart](tree_store.dart) | 存储契约（两个实现共享同一份语义说明） |
| [file_store.dart](file_store.dart) | 落盘实现：YAML 配置 + 缩进 JSON 会话元数据 + jsonl 消息；懒加载 + 进程内缓存 + write-behind |
| [memory_store.dart](memory_store.dart) | 纯内存实现（测试与"无落盘"场景） |
| [write_queue.dart](write_queue.dart) | 每文件串行的后台写队列 |
| [atomic_file.dart](atomic_file.dart) | 原子快照（临时文件 + 改名）与 jsonl 读取（坏行跳过并计数） |
| [yaml_codec.dart](yaml_codec.dart) | 读取用 `package:yaml`（宽容手写），写入自己实现（稳定键序 / 文件头注释 / 块标量） |

## 不变量（assertions）

1. **布局固定**：`config/settings.yaml`、`config/models/<id>.yaml`、`agents/<id>.yaml`、`data/<agent_id>/<session_id>/{session.json,messages.jsonl}`。
   消息为什么用 jsonl：单个会话实测已达 2433 条 / 2.9 MB，全量重写会让每次追加变成 O(n) 写放大并放大崩溃损坏面；追加日志天然只影响一行。
2. **写语义是 write-behind**：写操作先改内存缓存并立即返回，落盘任务排进 `WriteQueue`（同路径串行、不同路径并行）。`flush()` **必须**在关停与测试里调用；进程被硬杀时未 flush 的任务会丢失——这是明确接受的代价。
3. **原子性**：会话元数据与其它快照一律"临时文件 + 改名"，任何时刻磁盘上要么旧、要么新，不会是半截。
4. **崩溃容错**：jsonl 里无法解析的行**跳过并计数**（`JsonlReadResult.skipped`），绝不因为一行坏数据让整个会话打不开。
5. **单调序号**：`appendMessage` 必须把时间戳抬成同一 `(agent, session)` 内**严格递增**——一轮回复的多条消息（思考段 / 中间正文 / 工具卡片 / 最终回复）常落在同一毫秒，而历史接口按时间戳排序、Dart 的 `List.sort` 又不保证稳定，重载顺序会漂移。
6. **压缩不删消息**：`setCompacted` 与 `setCompactedContext` 各自**清空对方**——"列表覆盖 12 条 + 摘要覆盖 6 条"不能同时挂在同一个会话上。
7. **两种形态各司其职**：持久化用 ISO-8601 字符串（人读友好、手改方便），前端形态用毫秒整数（`ChatSession.fromJson` 要求 int）；`JsonTime.decode` 两种都收，文件里怎么写都生效。
8. `messageCount` 只数**文本**消息：工具卡片不算"开始过对话"（前端据此锁定运行模式），口径必须与前端一致。
9. 不保证与**外部同时修改同一目录**的其它进程一致（桌面形态是单用户单实例，多实例各持内存缓存、互不感知）。
10. **`llm_hidden`（`llm_hidden: true` 落在 jsonl 里）是"用户看得见、模型看不见"的唯一开关**：打了标记的消息照常落库、照常下发（前端当普通气泡渲染），引擎重建请求时整条跳过。用它的是**系统发言**（失败 / 停止提示）与**过程提示**（重试进度）。
    为什么不做成新的 `kind`：`system` 会被读成 system prompt（协议里真有 `LlmRole.system`），而"进不进提示词"与"这条消息是正文 / 思考 / 工具卡 / 提示"是**两件正交的事**——`kind` 管渲染与翻译形态，这个布尔标记只管要不要喂模型。

## 测试

```bash
cd packages/tree_core
dart test test/store_contract.dart test/file_store_test.dart test/memory_store_test.dart \
          test/atomic_file_test.dart test/records_test.dart test/tree_paths_test.dart \
          test/yaml_codec_test.dart
```

`store_contract.dart` 是**共享契约**：两个实现跑同一份断言，业务代码因此不会依赖内存实现特有的行为。
