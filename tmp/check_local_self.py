import io, os, datetime

# 1) 本地 .self 文件清单与大小
base = r'workspaces\agent_1787022784638\.self'
print('=== 本地 .self ===')
for f in sorted(os.listdir(base)):
    p = os.path.join(base, f)
    if os.path.isfile(p):
        print(f'  {f}: {os.path.getsize(p)} bytes, mtime={datetime.datetime.fromtimestamp(os.path.getmtime(p)).strftime("%H:%M:%S")}')

# 2) 本地 rule.md 前 400 字符
print('\n=== 本地 rule.md 前400 ===')
print(io.open(os.path.join(base, 'rule.md'), encoding='utf-8').read()[:400])
