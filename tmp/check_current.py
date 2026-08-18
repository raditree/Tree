import io, sys
sys.path.insert(0, 'server')
src = io.open('server/tools/help_tool.py', encoding='utf-8').read()
print('execute 含现刷:', '每次执行前刷新' in src)
src2 = io.open('server/main.py', encoding='utf-8').read()
print('main 含 _get_workspace_io:', '_get_workspace_io' in src2)
rkspace_io 判定逻辑
src2 = io.open('server/main.py', encoding='utf-8').read()
lines2 = src2.split('\n')
for i, line in enumerate(lines2, 1):
    if 'def _get_workspace_io' in line:
        for j in range(i-1, min(i+22, len(lines2))):
            print(f'{j+1}: {lines2[j].rstrip()}')
        break
