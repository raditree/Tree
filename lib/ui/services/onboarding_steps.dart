/// 新手引导的**步骤表**（纯数据，可单测）。
///
/// 用户 2026-10-04 定稿的首次使用顺序：
/// **模型配置（设置页）→ 创建 agent → 配置模型信息 → 配置工作目录 → 启用插件 → 文件浏览 →
/// Ctrl+J → demo 输入（「创建一名成员，负责插件开发」）**。
///
/// 三条口径：
/// 1. **每一步都能跳过**：单步的「下一步」= 不做这一步直接走（引导是路标，不是关卡），
///    整段的「跳过引导」一键收工；两种跳过都记在 [OnboardingState] 里，不再打扰；
/// 2. **「带我过去」只做导航**：打开设置页 / 建 agent 对话框 / 切右栏页签 / 唤起插件面板 /
///    唤起终端 / 弹工作目录选择器——不替用户做决定、不自动提交任何东西；
/// 3. **只有最后一步会写字**：把 demo 那句话**填进输入框**（光标就位，**不自动发送**），
///    用户自己看清了再按发送。
enum OnboardingStepId {
  models,
  createAgent,
  agentModel,
  workspace,
  plugins,
  files,
  terminal,
  demo,
}

/// 一步引导：标题 + 说明 + 「带我过去」那颗键的文案。
class OnboardingStep {
  const OnboardingStep({
    required this.id,
    required this.title,
    required this.body,
    required this.actionLabel,
  });

  final OnboardingStepId id;
  final String title;
  final String body;

  /// 「带我过去」按钮的文案（说清会把用户带到哪）。
  final String actionLabel;
}

/// demo 那一步要预填进输入框的**原话**（用户给的示例任务）。
const String kOnboardingDemoText = '创建一名成员，负责插件开发';

/// 引导步骤（**顺序就是用户定的顺序**，不要重排）。
const List<OnboardingStep> kOnboardingSteps = <OnboardingStep>[
  OnboardingStep(
    id: OnboardingStepId.models,
    title: '1/8 · 先配一个模型',
    body: 'Agent 没法凭空生成——先去设置页的「自定义模型」加一个模型配置（填 base_url / api_key /'
        '模型 id）。没有模型，后面的 agent 建出来也干不了活。',
    actionLabel: '打开设置 · 自定义模型',
  ),
  OnboardingStep(
    id: OnboardingStepId.createAgent,
    title: '2/8 · 创建一个 Agent',
    body: '左栏「Agent 列表」下方的 ⊕ 打开创建对话框：给它起个名字、选刚才那个模型。',
    actionLabel: '打开创建对话框',
  ),
  OnboardingStep(
    id: OnboardingStepId.agentModel,
    title: '3/8 · 确认它的模型信息',
    body: '右栏「模型信息」页是它的运行参数：模型、系统提示词、上下文与输出上限都在那里；'
        '改完立即生效（下一轮对话就用新参数）。',
    actionLabel: '打开右栏 · 模型信息',
  ),
  OnboardingStep(
    id: OnboardingStepId.workspace,
    title: '4/8 · 指定工作目录',
    body: '中栏左上角的目录按钮选一个项目目录——agent 的读写、命令、搜索都发生在那里；'
        '团队成员与临时员工共用这一个目录。',
    actionLabel: '选择工作目录',
  ),
  OnboardingStep(
    id: OnboardingStepId.plugins,
    title: '5/8 · 启用插件（可选）',
    body: '左栏「插件管理」里能看到插件与四类站点；插件能给模型加工具、改中转、往界面塞卡片。'
        '不用插件也能跑，跳过不影响。',
    actionLabel: '打开插件管理',
  ),
  OnboardingStep(
    id: OnboardingStepId.files,
    title: '6/8 · 用右栏浏览文件',
    body: '右栏「文件」页就是资源管理器：目录在左（可收起）、点文件在右边打开，能改、能存、'
        '能新建 / 改名 / 删除，git 状态直接染在名字上。',
    actionLabel: '展开右栏 · 文件',
  ),
  OnboardingStep(
    id: OnboardingStepId.terminal,
    title: '7/8 · Ctrl+J 唤起终端',
    body: '任何时候按 Ctrl+J：中栏的输入区整块换成真终端（本机 ConPTY / 远端 SSH 都行），'
        '再按一次回来。焦点在哪都生效。',
    actionLabel: '打开集成终端',
  ),
  OnboardingStep(
    id: OnboardingStepId.demo,
    title: '8/8 · 让它干第一件活',
    body: '把下面这句话填进输入框（不自动发送，你看清了再按发送）：'
        '「$kOnboardingDemoText」——它会用 team 工具当场建一个负责插件开发的成员。',
    actionLabel: '填入输入框',
  ),
];
