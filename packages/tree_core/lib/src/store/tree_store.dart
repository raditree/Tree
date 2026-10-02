import 'records.dart';

export 'records.dart';

/// 落库时间戳的**单调序号**：消息（见 [TreeStore.appendMessage]）与提问
/// （见 `agent/question_store.dart` 的 `QuestionStore.add`）共用同一条规则。
///
/// [requested] 已经晚于上一条时原样保留（绝不伪造时间）；否则取"上一条 + 1ms"。
/// 因此它只把**同值/更旧**的抬成严格递增，不会把时间戳推离真实时刻。
///
/// 为什么必须有：列表接口按时间戳排序，而 Dart 的 `List.sort` **不保证稳定**——
/// 同毫秒的两条记录会在两次请求之间换位置（真机表现：`GET /api/questions` 偶发把
/// "最新的一条"排到后面；消息那边则是历史重载顺序漂移）。
int monotonicStamp(int requested, int previous) =>
    requested > previous ? requested : previous + 1;

/// 核心进程的存储契约（agent / 会话 / 消息）。
///
/// **接口即契约**：M1 的内存实现（[MemoryStore]）与 M2 的落盘实现
/// （`FileTreeStore`）都实现本接口，HTTP 路由与会话服务只依赖接口，因此
/// "换持久化"不影响任何业务代码。两份实现由同一套**契约测试**
/// （`test/store_contract.dart`）双向约束，避免行为漂移。
///
/// **写语义（重要）**：写操作先改内存缓存、返回结果，再把落盘任务排入
/// **每文件串行**的写队列（write-behind）。理由与代价：
/// - 单用户本机应用，写延迟不该阻塞 WS 流式对话；
/// - 队列保证同一文件的写入顺序与调用顺序一致；
/// - [flush] 等待全部落盘，**关停与测试必须调用**；
/// - 因此"进程被硬杀"最多丢失最后若干次尚未落盘的写入（已 flush 的不受影响）。
abstract interface class TreeStore {
  /// 兜底默认会话 id（前端在无会话时回退该值）。
  static const String defaultSessionId = CoreSession.defaultSessionId;

  // ── agent ────────────────────────────────────────────────────────────

  /// 全部 agent（按 `updated_at` 倒序，最近活跃在前）。
  List<CoreAgent> agents();

  /// 按 id 取 agent；不存在返回 null。
  CoreAgent? agent(String id);

  /// 全部**顶部 agent**（未加入任何团队的 agent），按 `updated_at` 倒序。
  List<CoreAgent> teams();

  /// 某团队（TOP agent id）的全部成员（按 `created_at` 升序；不含 TOP 自身）。
  List<CoreAgent> members(String teamId);

  /// 新建 agent 并保证其兜底默认会话存在。
  CoreAgent createAgent({
    required String name,
    String systemPrompt = '',
    String modelId = '',
    int teamMemberCount = 0,
    int maxLevel = TeamLimits.defaultMaxLevel,
    int maxMembersPerLevel = TeamLimits.defaultMaxMembersPerLevel,
  });

  /// 直接写入/覆盖一个 agent 记录（持久化层装载用，也用于测试构造）。
  void putAgent(CoreAgent agent);

  /// 更新 agent；仅当传入非 null 的字段被覆盖。不存在返回 null。
  CoreAgent? updateAgent(
    String id, {
    String? name,
    String? systemPrompt,
    String? modelId,
  });

  /// 删除 agent 及其全部会话与消息。
  bool deleteAgent(String id);

  /// 该 agent 最近一条**文本**消息（列表页预览用）；无则 null。
  CoreMessage? lastTextMessage(String agentId);

  // ── 会话 ─────────────────────────────────────────────────────────────

  /// 某 agent 的全部会话（`updated_at` 倒序）。
  List<CoreSession> sessions(String agentId);

  /// 按 (agent, session) 取会话；不存在返回 null。
  CoreSession? session(String agentId, String sessionId);

  /// 确保兜底默认会话存在（幂等），返回该会话。
  CoreSession ensureDefaultSession(String agentId);

  /// 新建会话；agent 不存在返回 null，sessionId 已存在时返回既有会话。
  CoreSession? createSession(
    String agentId, {
    String title = '',
    String? sessionId,
  });

  /// 重命名会话；不存在返回 false。
  bool renameSession(String agentId, String sessionId, String title);

  /// 删除会话及其消息；不存在返回 false。
  bool deleteSession(String agentId, String sessionId);

  /// 设置会话选中的 Spec 列表（M5 交付 Spec 体系前只做存取）。
  int setSelectedSpecs(String agentId, String sessionId, List<String> specIds);

  /// 记录一次上下文压缩（M7d-4）：[messageCount] 是**已被摘要覆盖**的前缀消息
  /// 数，[summary] 是替代它们的摘要。会话不存在返回 false。
  ///
  /// 消息本体不动——压缩只改"引擎该看多少历史"，历史全文仍可回看。
  ///
  /// **会清空 `compacted_context`**（中转站路径的产物）：两条压缩路径的权威只能有
  /// 一个，否则"列表覆盖 12 条 + 摘要覆盖 6 条"会同时挂在同一个会话上。
  bool setCompacted(
    String agentId,
    String sessionId, {
    required String summary,
    required int messageCount,
  });

  /// 记录一次**由中转站产出**的压缩（点位化 `system.relay.context.compact`）。
  ///
  /// [context] 是整份新上下文（OpenAI 线形态的消息数组），[coveredMessageCount] 是
  /// 这份上下文覆盖了原文的前多少条（引擎从这条之后继续追加新消息）。
  /// 会话不存在返回 false。
  ///
  /// **会清空 `compacted_summary`**：权威转移到这份列表上（见 [CoreSession]）。
  bool setCompactedContext(
    String agentId,
    String sessionId, {
    required List<Map<String, dynamic>> context,
    required int coveredMessageCount,
  });

  // ── 消息 ─────────────────────────────────────────────────────────────

  /// 某会话的全部消息（按写入顺序）。
  List<CoreMessage> messages(String agentId, String sessionId);

  /// 该会话的「有效消息数」：仅统计文本消息（工具卡片不计入）。
  ///
  /// 前端用 `message_count > 0` 判定该 agent 是否已开始过对话（运行模式
  /// 锁定），工具卡片不算对话开始，故与文本消息口径对齐。
  int messageCount(String agentId, String sessionId);

  /// 追加一条消息（同时更新所属会话与 agent 的 `updated_at`）。
  ///
  /// **单调序号（Q3）**：实现必须把消息时间戳抬成"同一 (agent, session) 内严格
  /// 递增"（见 [monotonicStamp]）。理由是一轮回复里的多条消息——思考段、
  /// 中间正文、工具卡片、最终回复——常常落在同一毫秒，而历史接口
  /// （`GET /api/conversations`）会**按时间戳排序**，Dart 的 `List.sort` 又不
  /// 保证稳定：同值时间戳会让重载顺序漂移。让"落库顺序"直接体现在时间戳上，
  /// 追加顺序 = 读回顺序就与任何排序实现无关。
  CoreMessage appendMessage(CoreMessage message);

  /// 清空消息；`sessionId` 为 null/空/`all` 时清空该 agent 全部会话。
  /// 返回被删除的消息条数。
  int clearMessages(String agentId, {String? sessionId});

  /// **本进程已知**的消息总数（已加载/已写入；不扫描未加载的历史文件）。
  /// 仅用于自检与日志，不保证等于磁盘上的历史总量。
  int get totalMessageCount;

  // ── 生命周期 ─────────────────────────────────────────────────────────

  /// 等待全部在途落盘任务完成（关停与测试必须调用）。
  Future<void> flush();

  /// flush 并释放资源（幂等）。
  Future<void> close();
}
