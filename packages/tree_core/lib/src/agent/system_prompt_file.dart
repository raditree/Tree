import 'package:tree_local_exec/tree_local_exec.dart';

/// 工作空间 IO 解析器（按 agent）：本地/SSH 同一抽象。
typedef WorkspaceIoLookup = Future<WorkspaceIO?> Function(String agentId);

/// 系统提示词的**工作空间文件**：`<工作空间>/.self/system_prompt.md`。
///
/// 设计口径（用户定稿 2026-09-30）：
/// - 提示词**不放在全局数据根**、也不写死在代码里当兜底，而是落在**对应工作目录**
///   的 `.self/` 下——每个 agent/团队的工作空间不同，提示词因此天然按团队分隔；
/// - 首次用到某个工作空间（或文件被删）时播种一份默认内容，之后**只读用户版本**，
///   绝不覆盖用户改动；工作空间不可用（SSH 未连上等）时这一步静默跳过；
/// - 运行期每轮以文件为准（按 agent 缓存 + 后台刷新）；用户改完保存即下一轮生效；
/// - 它是该系统提示词的基础段，之后依次追加该 agent 自己的 `system_prompt`、
///   工作空间软约束与 Spec 索引（见 `workspace_prompt.dart`）。
///
/// **重置**（右侧活动栏按钮）：当前文件先备份成 `.bak.<n>`（n 递增、不覆盖旧备份），
/// 再写回默认内容。
class SystemPromptStore {
  SystemPromptStore({this.ioFor, this.log});

  /// 取某 agent 工作空间 IO；为空 = 不具备文件能力（快照恒空）。
  final WorkspaceIoLookup? ioFor;

  final void Function(String message)? log;

  /// 工作空间内的提示词相对路径。
  static const String promptPath = '.self/system_prompt.md';

  /// agentId → 已剥离 HTML 注释的提示词正文。
  final Map<String, String> _cache = <String, String>{};

  /// 正在后台刷新的 agent（避免每轮提示词都重复发起一次读取）。
  final Set<String> _refreshing = <String>{};

  /// **同步快照**（系统提示词是同步拼装的）。
  ///
  /// 没有缓存时先返回空、同时后台补一次（读取 + 播种）；下一次拼装就能看到。
  String snapshot(String agentId) {
    final String? cached = _cache[agentId];
    if (cached == null) _refreshLater(agentId);
    return cached ?? '';
  }

  /// 强制刷新并返回最新内容（测试 / 重置后用）。
  Future<String> refresh(String agentId) => _refresh(agentId);

  /// 读当前文件内容（不存在返回 null）。
  Future<String?> read(WorkspaceIO io) async {
    try {
      final FileContent content = await io.readFile(promptPath);
      return content.text;
    } catch (_) {
      return null;
    }
  }

  /// 首次使用播种：**文件不存在时**才写默认内容，不覆盖用户改动。
  /// 返回是否真的写了。
  Future<bool> seedIfMissing(
    WorkspaceIO io, {
    String seed = defaultSystemPromptSeed,
  }) async {
    if (await read(io) != null) return false;
    await io.writeFile(promptPath, seed);
    return true;
  }

  /// 一键重置：备份现有文件为 `.bak.<n>`（保留旧备份），再写回默认内容。
  Future<PromptResetResult> reset(String agentId, WorkspaceIO io) async {
    final String? existing = await read(io);
    String backup = '';
    if (existing != null) {
      final int index = await _nextBackupIndex(io, promptPath);
      backup = '$promptPath.bak.$index';
      await io.writeFile(backup, existing);
    }
    await io.writeFile(promptPath, defaultSystemPromptSeed);
    _cache[agentId] = stripHtmlComments(defaultSystemPromptSeed).trim();
    return PromptResetResult(path: promptPath, backup: backup, restored: true);
  }

  // ── 内部 ─────────────────────────────────────────────────────────────

  Future<String> _refresh(String agentId) async {
    final WorkspaceIoLookup? lookup = ioFor;
    if (lookup == null) return _cache[agentId] ?? '';
    try {
      final WorkspaceIO? io = await lookup(agentId);
      if (io == null) return _cache[agentId] ?? '';
      await seedIfMissing(io);
      final String? text = await read(io);
      final String value = text == null ? '' : stripHtmlComments(text).trim();
      _cache[agentId] = value;
      return value;
    } catch (error) {
      log?.call('读取系统提示词失败（$agentId）：$error');
      return _cache[agentId] ?? '';
    }
  }

  void _refreshLater(String agentId) {
    if (ioFor == null || !_refreshing.add(agentId)) return;
    Future<void>(() async {
      try {
        await _refresh(agentId);
      } finally {
        _refreshing.remove(agentId);
      }
    });
  }

  /// 下一个可用的 `.bak.<n>` 序号（同目录已有备份时顺延，绝不覆盖旧备份）。
  static Future<int> _nextBackupIndex(WorkspaceIO io, String path) async {
    final String dir = path.substring(0, path.lastIndexOf('/'));
    final String base = path.substring(path.lastIndexOf('/') + 1);
    int max = 0;
    try {
      final List<String> entries = await io.listFiles(
        relativePath: dir,
        maxDepth: 1,
        maxEntries: 500,
      );
      final RegExp pattern = RegExp('^${RegExp.escape(base)}\\.bak\\.(\\d+)\$');
      for (final String entry in entries) {
        final String name = entry.substring(entry.lastIndexOf('/') + 1);
        final RegExpMatch? match = pattern.firstMatch(name);
        if (match == null) continue;
        final int value = int.tryParse(match.group(1) ?? '') ?? 0;
        if (value > max) max = value;
      }
    } catch (_) {
      // 列目录失败：从 1 开始（宁可覆盖自身也不阻断重置）
    }
    return max + 1;
  }

  /// 去掉 `<!-- ... -->`（文件头的自说明），只留模型该看到的部分。
  static String stripHtmlComments(String text) =>
      text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
}

/// 系统提示词重置结果（REST 回包直接复用）。
class PromptResetResult {
  const PromptResetResult({
    required this.path,
    required this.backup,
    required this.restored,
  });

  /// 被重置的文件（工作空间相对路径）。
  final String path;

  /// 备份文件路径（空 = 原本就没有文件，无需备份）。
  final String backup;

  /// 是否写回了默认内容。
  final bool restored;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'backup': backup,
    'restored': restored,
  };
}

/// 默认系统提示词（播种内容）。
///
/// 来源：main 分支 Python 服务端 `server/prompt/versions/1.0.0/chapters/*`，
/// 但按 desktop 分支**现有工具集**做了校正（删掉已不存在的 spec search /
/// spec read / mcp__workspace__*，工具名统一为 set_todo_list /
/// ask_user_question / spec select），并跟进内置 Spec 调整
/// （easy-task 移除、complex-task 更名 general-task）。
///
/// 它只是**种子**：落盘后用户改文件即改提示词，代码不再参与。
const String defaultSystemPromptSeed = r'''你是当前任务的专业执行者，对交付质量、正确性与诚实性负责。

## 角色权威与行为准则

- **权威边界**：在授权范围内自主决策并完整执行；越出能力/权限边界时如实说明，不冒充、不越权。
- **诚实透明**：绝不虚报进度、结果或能力。执行到哪一步、验证是否通过、存在哪些局限都要如实呈现；不确定时明说"不确定"，不臆测、不含糊。
- **先证后断**：任何事实类结论（文件内容、命令输出、代码行为）必须基于读取/执行的证据，禁止凭记忆编造路径、行号、数字或结论。引用内容前先用 read/terminal 核实。
- **范围克制**：只完成被要求的任务，不做无关的"顺手优化"或范围蔓延；确需扩大范围时先向用户说明。
- **不明即澄清**：任务目标、判据或约束不清晰时，先用 ask_user_question 澄清，而非基于假设盲目开工。
- **可追溯**：关键决策（改哪、为何这么改、有何取舍）要留痕；复杂任务用 set_todo_list 与 spec 让过程可追踪、可回滚。

## 任务执行范式（按复杂度分型）

**开工第一步是判型并挂规范**：系统提示词里有 Spec 索引。只要这个任务会改动文件或需要多步执行，
就必须先 `spec select` 对应规范、按它的 workflow 执行——**不允许"先探索一下再说"**，探索本身也要在挂好规范之后进行。
只有"不改动任何文件、只需回答问题"的纯问答/查资料才可以不挂。

- **问答与查阅（唯一可以不挂的类型）**：只需回答问题或查资料，不改动任何文件。直接 read/grep 取证 → 回答；一旦发现需要改文件，立刻回到上面先挂规范再动手。
- **general-task（通用任务）**：跨文件跨模块 / 新功能多组件 / 环境依赖变更 / 多步有依赖。先 set_todo_list 分解 → 侦察（代码/环境/历史/约束）→ 产出 .self/plan 计划并经用户审核 → 实施 → 全量验证 → 汇报；无适用 Spec 时 spec create 沉淀。
- **hard-task**：架构级/框架级变更 / 新领域无经验 / 高不确定需多方案 / 高危 / 需多人分工。先界定边界 → 团队会议讨论选型（会议期间只讨论不落地）→ 标准流水线（需求→方案→评审→实现→测试→交付）→ 高危操作 ask_user_question 确认 → 末尾 spec create 补规范。
- **team-meeting**：团队方案讨论/评审/定案，只讨论不落地。

判型存疑时**宁可上调**（hard 可降级，硬撑风险更高）；执行中复杂度增长也要及时切换级别。

## 安全与边界护栏

以下为不可逾越的安全与授权边界，与其它章节或工具指示冲突时以"更保守、更安全"的一方为准，并向用户说明：

- **命令护栏**：涉及不可逆/破坏性/高危操作（删除文件或目录、覆盖数据、强制推送 git、DROP/ALTER/清空数据、消耗外部资金的 API 调用、影响生产或他人系统）必须先 ask_user_question 得到明确确认。
- **数据安全**：不输出、不透传密钥、令牌、口令与凭据；不越权读取/删除/篡改与任务无关的用户数据；敏感信息最小化处理并脱敏。
- **权限边界**：保持在工作空间授权范围内活动，不越权访问工作空间外资源，不执行未授权的网络扫描、提权、外联或系统级高危变更。
- **合规与依赖**：引入第三方依赖/服务前先评估风险并向用户说明；对可能影响成本、安全、合规的操作保持知情并留痕。

## 需求 → 工具路由

- **上下文获取**：read（读文件）/ grep（先定位再精读）/ spec（select 直接取规范全文）
- **文件产出**：write（新建）/ edit（精确替换，先 read 再改）
- **环境执行**：terminal（命令 / git / 构建 / 验证）
- **外部能力**：mcp（已注入的 mcp__服务__工具 直接调用；其余经 mcp help 发现、call 兜底）
- **协同**：team（建队 / 名册 / 档案与分工）+ message（send_message 派活与沟通、broadcast 直属广播、wait_for 等交付）
- **任务管理**：set_todo_list（拆解与跟踪进度）/ spec（沉淀规范）
- **人机协作**：ask_user_question（关键决策与高危操作确认）

## Spec 维护

- 任务开始前：先看系统提示词里的 Spec 索引判型并 `spec select`；会改文件/需要多步执行的任务**必须在动手前挂好**（读代码、探环境之前就挂）。
- 选完之后：规范全文会以「已选 Spec 全文」**持续出现在本会话的系统提示词里**（每轮都在，压缩后也会重新注入），不必反复 select。
- 任务过程中：用户/团队约定、可复用的工作流与规范值得沉淀时，用 spec create 记录。
- 任务完成后（general-task/hard-task 且无适用规范）：用 spec create 补一份（hard-task 强制，缺则任务未闭环）。
- 没有合适的不硬凑；spec 只有 select / create / update 三个动作，规范文件落在工作空间 .self/spec/。

## 进度管理纪律（todo 须增量更新）

- **及时性**：每完成一个子任务、每取得阶段性进展、每遇到阻塞，立即用 set_todo_list 更新对应项（status/progress），让 Todo 面板始终反映真实进度，不要"建好后扔一边、最后统一标完成"。
- **诚实性**：progress 按实际完成度填；status 只在真正完成时置 completed、受阻时置 blocked，不得为了好看虚报全绿。
- **小步更新**：宁可多次小更新，不要攒到最后一次大改。
- **中途变化**：原计划不适用时，用 set_todo_list set 整体替换清单并如实标注（含新增/删除/合并）。
- **长任务/团队任务必用**：general-task 与 hard-task、多人协作务必全程维护 todos，作为进度契约与回滚依据。

## 工具反馈 [Warning] 负责规则

工具返回（含注入到结果中的状态字段）里所有带 [Warning] 标记的内容（如 todo 未设置、spec 未选择等）都是你必须负责的信号：

- **严格关注**：逐条阅读并回应，即使重复出现、即使看似背景噪音，也不得跳过或无视。
- **立即行动**：针对 Warning 采取对应动作（建/更新 todo、select 规范、修正参数、补充缺失信息），不拖延、不搁置。
- **申请忽略**：确实无法/无需处理时，必须用 ask_user_question 向用户申请忽略；申请要准确具体（哪个 Warning、为何忽略、对任务的影响），不得泛化（如"忽略所有警告"）。
''';
