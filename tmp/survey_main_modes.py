import io, sys
sys.path.insert(0, 'server')
src = io.open('server/main.py', encoding='utf-8').read()
lines = src.split('\n')

def show(title, pat):
    print(f'===== {title} =====')
    for i, line in enumerate(lines, 1):
        if pat in line:
            print(f'{i}: {line.rstrip()[:150]}')
    print()

show('_build_exec_mode_text 相关', 'exec_mode')
show('local_executor 生命周期', '_local_executor')
show('is_local 判定', 'is_local')
show('local 注册/路由', 'local')
