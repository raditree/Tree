import 'package:tree_core/tree_core.dart';

import 'store_contract.dart';

void main() {
  // 内存实现跑同一份契约（落盘实现见 file_store_test.dart）
  runStoreContract('MemoryStore', MemoryStore.new);
}
