import io, sys
sys.path.insert(0, 'server')
src = io.open('server/main.py', encoding='utf-8').read()
lines = src.split('\n')

def show(a, b, title):
    print(f'===== {title} =====')
    for i in range(a-1, min(b, len(lines))):
        print(f'{i+1}: {lines[i].rstrip()[:140]}')
    print()

show(1280, 1363, '_process_member_message 尾部投递 (1280-1363)')
show(1363, 1500, '_dispatch_agent_message 完整 (1363-1500)')
