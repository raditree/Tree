/// 核心进程版本（协议握手与自描述共用）。
///
/// 单独成文件是为了避免循环依赖：`tree_core.dart` 导出服务器实现，而服务器
/// 需要版本常量。
const String treeCoreVersion = '0.1.0';
