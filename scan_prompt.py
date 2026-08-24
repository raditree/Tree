fp = 'server/prompt/versions/1.0.0/tools/builtin.yaml'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
for i, line in enumerate(lines, 1):
    if '2>&1' in line or '2>&' in line or 'redirect' in line.lower() or 'terminal' in line.lower():
        print(f'{i}: {line.rstrip()[:140]}')
