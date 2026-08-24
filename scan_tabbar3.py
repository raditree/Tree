fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\tabs.dart'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
print('total lines:', len(lines))
for i, line in enumerate(lines, 1):
    low = line.lower()
    if 'unselectedlabelcolor' in low or 'labelcolor' in low or 'tabbardefaults' in low:
        print(f'{i}: {line.rstrip()[:140]}')
