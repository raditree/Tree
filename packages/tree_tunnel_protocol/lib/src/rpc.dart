import 'constants.dart';

/// 一次 RPC 失败（带 JSON-RPC 的 code / message / data）。
///
/// 为什么要一个类型而不是 `Exception('...')`：核心侧要根据 [code] 决定"回退 vs 暴露"、
/// 把 `not_found` / `already_exists` / `parent_missing` 映射成业务语义（而不是一律当崩溃）；
/// 字符串异常做不到这件事。
class RpcException implements Exception {
  RpcException(this.code, this.message, {this.data});

  final int code;
  final String message;
  final Object? data;

  /// 是否属于"链路上的一次可读失败"（而不是协议/内部错误）。
  bool get isProtocolError =>
      code == RpcCodes.parseError ||
      code == RpcCodes.invalidRequest ||
      code == RpcCodes.methodNotFound ||
      code == RpcCodes.invalidParams;

  @override
  String toString() => 'RpcException($code): $message';
}

/// 构造一条**请求**：`{jsonrpc:'2.0', id, method, params}`。
Map<String, dynamic> rpcRequest(int id, String method, [Map<String, dynamic>? params]) =>
    <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };

/// 构造一条**通知**：`{jsonrpc:'2.0', method, params}`（**没有 id** ⇒ 对端不回响应）。
Map<String, dynamic> rpcNotification(String method, [Map<String, dynamic>? params]) =>
    <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };

/// 构造一条**成功响应**：`{jsonrpc:'2.0', id, result}`。
Map<String, dynamic> rpcResult(Object id, Object? result) => <String, dynamic>{
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

/// 构造一条**错误响应**：`{jsonrpc:'2.0', id, error:{code, message, data?}}`。
Map<String, dynamic> rpcErrorResult(
  Object id,
  int code,
  String message, [
  Object? data,
]) => <String, dynamic>{
  'jsonrpc': '2.0',
  'id': id,
  'error': <String, dynamic>{
    'code': code,
    'message': message,
    if (data != null) 'data': data,
  },
};

/// 从一条**响应**帧里取出结果；带 `error` 时抛 [RpcException]。
///
/// 只处理"有 id、没有 method"的响应形态（与既有 `PluginHost._onLine` 同口径）：
/// 带 method 的一定是请求/通知，不是响应。
Object? rpcUnwrap(Map<String, dynamic> frame) {
  final Object? error = frame['error'];
  if (error is Map) {
    final Map<String, dynamic> map = error.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    throw RpcException(
      (map['code'] as num?)?.toInt() ?? RpcCodes.internalError,
      (map['message'] ?? '未知错误').toString(),
      data: map['data'],
    );
  }
  return frame['result'];
}

/// 一个单调递增的请求 id 发生器（每条通道一个）。
///
/// 从 1 开始（0 与 null 在 JSON-RPC 里有特殊含义：通知的 id 必须缺席，不用 0）。
class RpcIds {
  int _next = 0;

  int next() => ++_next;

  /// 是否有在途请求（用于"链路断了 ⇒ 全部在途以显式错误收尾"）。
  static bool isResponse(Map<String, dynamic> frame) =>
      frame['method'] == null && frame['id'] != null;

  static bool isRequest(Map<String, dynamic> frame) =>
      frame['method'] is String && frame['id'] != null;

  static bool isNotification(Map<String, dynamic> frame) =>
      frame['method'] is String && frame['id'] == null;
}

/// 错误码 → 可读中文（日志 / 工具结果 / 用户面用；**不改协议**）。
String describeRpcCode(int code) {
  switch (code) {
    case RpcCodes.parseError:
      return '报文无法解析';
    case RpcCodes.invalidRequest:
      return '非法请求';
    case RpcCodes.methodNotFound:
      return '方法不存在';
    case RpcCodes.invalidParams:
      return '参数非法';
    case RpcCodes.internalError:
      return '内部错误';
    case TunnelErrorCodes.pathOutOfRoot:
      return '路径越出工作空间根';
    case TunnelErrorCodes.notFound:
      return '路径不存在';
    case TunnelErrorCodes.alreadyExists:
      return '目标已存在';
    case TunnelErrorCodes.notEmpty:
      return '目录非空';
    case TunnelErrorCodes.parentMissing:
      return '父目录不存在';
    case TunnelErrorCodes.ptyUnsupported:
      return '目标机不支持伪终端（缺少 script）';
    case TunnelErrorCodes.handshakeFailed:
      return '与目标机执行体握手失败';
    case TunnelErrorCodes.protocolMismatch:
      return '协议版本不匹配';
    case TunnelErrorCodes.permissionDenied:
      return '目标机拒绝访问（权限）';
    case TunnelErrorCodes.execFailed:
      return '命令无法启动';
    case TunnelErrorCodes.frameTooLarge:
      return '单帧超过上限';
    case TunnelErrorCodes.busy:
      return '目标正忙';
    default:
      return '未知错误（code=$code）';
  }
}

/// 把一条 `tunnel.ensure` 的 `error_kind` 转成"核心要不要回退"的判据。
bool shouldFallbackForErrorKind(String kind) =>
    TunnelErrorKinds.fallbackKinds.contains(kind.trim());
