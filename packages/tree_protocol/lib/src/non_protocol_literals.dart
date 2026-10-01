/// 本仓库源码里出现的 `'type': '...'` 字面量，但**不属于**本协议。
///
/// 完备性测试用：扫描前端与各包的 Dart 源码时把这些排除，避免为了"覆盖"而把
/// JSON Schema 类型、消息 kind、角色枚举等误当成协议事件。每项都必须给出原因，
/// 新增项需评审——否则协议会出现无声漂移。（原先扫的是 server 的 Python 源码，
/// M7 删除 `server/` 后换成扫本仓库。）
const Map<String, String> nonProtocolTypeLiterals = <String, String>{
  // JSON Schema 类型（工具参数定义）
  'array': 'JSON Schema 类型（工具 parameters）',
  'boolean': 'JSON Schema 类型（工具 parameters）',
  'integer': 'JSON Schema 类型（工具 parameters）',
  'number': 'JSON Schema 类型（工具 parameters）',
  'object': 'JSON Schema 类型（工具 parameters / MCP 输入 schema）',
  'string': 'JSON Schema 类型（工具 parameters）',
  // OpenAI 协议内部类型（请求/响应体，经 HTTP 而非 WS）
  'function': 'OpenAI tool definition 的 type',
  'image_url': 'OpenAI vision content 的 type',
  // 图像走 Files API：chat 请求里 user 消息的 content 数组块
  //（`{"type":"file","file":{"file_id":...}}`，见 tree_core 的 LlmContentPart）
  'file': 'OpenAI/DeepSeek file 引用内容块的 type',
  // 业务枚举值（出现在 payload 的 "type" 键上，不是帧类型）
  'normal': '成员类型枚举（normal/...）',
  'leader': '团队角色枚举',
  'member': '团队角色枚举',
  'top': '团队角色枚举',
  'dir': '文件类型枚举（list_files 结果）',
  'unknown': '未知值兜底枚举',
  'message_type': 'WS 上行 payload 的字段名（非帧类型）',
};
