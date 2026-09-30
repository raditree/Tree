/// Tree 桌面端核心进程（desktop 分支）。
///
/// 设计约束（见 desktop 迁移方案 §4/§5）：
/// - **纯 Dart**：不依赖 Flutter，可用 `dart compile exe` 独立分发；
/// - **单进程单事件循环**：原 server 的"生成器 + to_thread + 线程安全队列"
///   改为 `Stream` + `await`；
/// - 面向 Flutter UI 暴露**本地回环 HTTP + WS**（协议见 tree_protocol），
///   使 lib/ui 无需改动；
/// - **零第三方依赖**：便于打包为单文件可执行。
///
/// 里程碑进度：
/// - M1：回环服务（握手/鉴权/路由）+ 内存存储 + WS 流式骨架（本文件所在的包）
/// - M2：`~/.tree` 的 yaml + jsonl 持久化
/// - M3：真实 LLM（openai_dart 或手写 SSE）+ 完整 LlmSession 语义
/// - M4：工具层（本机/SSH 工作空间 IO + 5 个工作空间工具 + 待办/hook）
/// - M5：人机协作与团队编排（提问回路、team/message 工具、成员审核闸门、级联停止、
///   Spec 体系与会话状态注入）
/// - M6：插件总线 + MCP（mcp_dart）+ 进程外插件宿主
library;

import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'src/version.dart';

export 'src/agent/agent_engine.dart';
export 'src/agent/compaction_service.dart';
export 'src/agent/conversation_service.dart';
export 'src/agent/question_broker.dart';
export 'src/agent/question_store.dart';
export 'src/agent/system_prompt_file.dart';
export 'src/agent/workspace_prompt.dart';
export 'src/team/message_dispatcher.dart';
export 'src/team/team_model.dart';
export 'src/team/team_service.dart';
export 'src/agent/scripted_agent.dart';
export 'src/llm/llm_agent_engine.dart';
export 'src/llm/llm_result_gate.dart';
export 'src/llm/llm_session.dart';
export 'src/llm/llm_summarizer.dart';
export 'src/llm/llm_transport.dart';
export 'src/llm/llm_types.dart';
export 'src/llm/openai_codec.dart';
export 'src/llm/sse_parser.dart';
export 'src/files/file_service.dart';
export 'src/mcp/mcp_client.dart';
export 'src/mcp/mcp_service.dart';
export 'src/plugin/agent_events.dart';
export 'src/plugin/builtin_plugins.dart';
export 'src/plugin/execute_mounts.dart';
export 'src/plugin/plugin_bus.dart';
export 'src/plugin/plugin_config_store.dart';
export 'src/plugin/plugin_host.dart';
export 'src/plugin/plugin_tool_definition.dart';
export 'src/plugin/station_instance.dart';
export 'src/plugin/station_runtime.dart';
export 'src/plugin/station_schema.dart';
export 'src/plugin/station_scope.dart';
export 'src/plugin/station_store.dart';
export 'src/plugin/stations.dart';
export 'src/tool/builtin_tools.dart';
export 'src/tool/mcp_tool.dart';
export 'src/tool/message_tool.dart';
export 'src/tool/plugin_tool.dart';
export 'src/tool/question_channel.dart';
export 'src/tool/spec_tool.dart';
export 'src/tool/status_text.dart';
export 'src/tool/team_tool.dart';
export 'src/tool/terminal_hooks.dart';
export 'src/tool/todo_store.dart';
export 'src/tool/tool_runner.dart';
export 'src/tool/workspace_tool_runner.dart';
export 'src/server/core_server.dart';
export 'src/server/http_io.dart';
export 'src/server/http_router.dart';
export 'src/server/ws_liveness.dart';
export 'src/settings/core_settings.dart';
export 'src/spec/builtin_specs.dart';
export 'src/spec/spec_service.dart';
export 'src/settings/file_settings_sink.dart';
export 'src/settings/ssh_config.dart';
export 'src/store/atomic_file.dart';
export 'src/store/file_store.dart';
export 'src/store/memory_store.dart';
export 'src/store/records.dart';
export 'src/store/tree_paths.dart';
export 'src/store/tree_store.dart';
export 'src/store/write_queue.dart';
export 'src/store/yaml_codec.dart';
export 'src/util/ids.dart';
export 'src/util/json_time.dart';
export 'src/util/liveness.dart';
export 'src/util/token.dart';
export 'src/util/tokens.dart';
export 'src/version.dart';
export 'src/ws/inbound_frames.dart';
export 'src/ws/ws_hub.dart';

/// 核心版本与骨架自描述（供 CLI 与测试断言）。
abstract final class TreeCore {
  /// 核心包版本。
  static const String version = treeCoreVersion;

  /// 协议里保留的 REST 路径数量（骨架自检用）。
  static int get keptApiPathCount => ApiPaths.kept.length;

  /// 本机执行原语可用性（M4 前仅报告实现分组数）。
  static String describe() =>
      'tree_core $version '
      '(apiPaths=${ApiPaths.kept.length}, '
      'inbound=${WsInboundType.all.length}, '
      'outbound=${WsOutboundType.all.length}, '
      'execBackends=${TreeLocalExec.backendCount})';
}
