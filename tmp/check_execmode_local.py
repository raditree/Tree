import io, sys
sys.path.insert(0, 'server')

# 1) _build_exec_mode_text 实现
src = io.open('server/main.py', encoding='utf-8').read()
lines = src.split('\n')
i0 = None
for i, line in enumerate(lines, 1):
    if 'def _build_exec_mode_text' in line:
        i0 = i
        break
print(f'===== _build_exec_mode_text ({i0}) =====')
for i in range(i0-1, min(i0+50, len(lines))):
    print(f'{i+1}: {lines[i].rstrip()[:140]}')

# 2) is_local 实现
print('\n===== local_executor.is_local =====')
src2 = io.open('server/core/local_executor.py', encoding='utf-8').read()
lines2 = src2.split('\n')
for i, line in enumerate(lines2, 1):
    if 'def is_local' in line or 'def request' in line or '_local' in line.lower() or 'base_dir' in line.lower() or 'top_agent' in line.lower():
        print(f'{i}: {line.rstrip()[:140]}')
