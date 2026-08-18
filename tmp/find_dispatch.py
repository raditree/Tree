import io, sys
sys.path.insert(0, 'server')
src = io.open('server/main.py', encoding='utf-8').read()
lines = src.split('\n')

def show(title, pat, n=3):
    print(f'===== {title} =====')
    cnt = 0
    for i, line in enumerate(lines, 1):
        if pat in line:
            print(f'{i}: {line.rstrip()[:140]}')
            cnt += 1
            if cnt >= n:
                break
    print()

show('_dispatch_agent_message 定义', 'def _dispatch_agent_message')
show('send_message 成员投递', '_dispatch_agent_message(')
