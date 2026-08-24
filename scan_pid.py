fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\theme_data.dart'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
for i, line in enumerate(lines, 1):
    if 'primaryIsDark' in line:
        print(f'{i}: {line.rstrip()[:150]}')
