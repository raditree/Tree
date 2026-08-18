import io, sys
sys.path.insert(0, 'server')
src = io.open('server/main.py', encoding='utf-8').read()
lines = src.split('\n')
# 找 _get_workspace_io 定义与 _build_workspace_extra_info 里调用处
for i, line in enumerate(lines, 1):
    if '_get_workspace_io' in line or 'def _build_workspace_extra_info' in line:
        print(f'{i}: {line.rstrip()[:140]}')
