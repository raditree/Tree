import sys, io, asyncio, logging
sys.path.insert(0, 'server')
logging.basicConfig(level=logging.WARNING)

# 模拟真实服务环境：构建 LocalWorkspaceIO 并尝试读取本地 .self/identity.md
# 由于真实 WS 需要前端连接，这里先检查 executor 注册状态
from core.local_executor import LocalExecutorClient
le = LocalExecutorClient()
print('is_local(None):', le.is_local('u1'))
print('_users:', getattr(le, '_users', {}))

# 直接验证：_get_workspace_io 的判定逻辑（模拟 _local_executor 为 None 时回退云端）
import main
io_obj = main._get_workspace_io('u1', 'agent_1787022784638')
print('无 local_executor 时 _get_workspace_io:', type(io_obj).__name__)
