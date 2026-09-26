/// Server-Sent Events 增量解析器。
///
/// 只实现协议里我们需要的子集，但**严格按规范的事件边界**（空行）工作：
/// - `data:` 字段可重复，多行的值用 `\n` 连接；
/// - `:` 开头是注释（很多端点用它做心跳），忽略；
/// - `event:` / `id:` / `retry:` 其它字段忽略；
/// - 值前的一个空格按规范去掉，其余空格保留（JSON 里的缩进不能被吃掉）。
///
/// 解析器是**逐行喂入**的，因此天然支持"一个网络分片里包含半行/多行"的情况
/// （上层用 `LineSplitter` 处理分片边界）。
class SseParser {
  final StringBuffer _data = StringBuffer();

  /// 是否收到过 `data` 字段。
  ///
  /// 必须单独记账而不是看 `_data` 是否为空：SSE 规范里 `data:`（空值）也是一个
  /// 数据行，`data: a\ndata:\ndata: b` 的载荷是 `a\n\nb`（中间那个空行不能丢）。
  bool _sawData = false;

  /// 是否已积累未派发数据（自检用）。
  bool get hasPending => _sawData;

  /// 喂入一行（不含换行符）；返回一个完整事件的数据，未成事件时返回 null。
  String? accept(String line) {
    if (line.isEmpty) {
      if (!_sawData) return null;
      final String payload = _data.toString();
      _data.clear();
      _sawData = false;
      return payload;
    }
    if (line.startsWith(':')) return null;
    final int colon = line.indexOf(':');
    final String field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'data') return null;
    String value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (_sawData) _data.write('\n');
    _data.write(value);
    _sawData = true;
    return null;
  }

  /// 流结束时把残留数据当作最后一个事件（部分端点省掉末尾空行）。
  String? flush() {
    if (!_sawData) return null;
    final String payload = _data.toString();
    _data.clear();
    _sawData = false;
    return payload;
  }
}
