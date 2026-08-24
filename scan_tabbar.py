import re

fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\tab_bar.dart'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

# 找 TabBarDefaultsM2 或默认颜色实现
for i, line in enumerate(lines, 1):
    if 'TabBarDefaultsM2' in line or 'unselectedLabelColor' in line or 'Color?' in line and 'labelColor' in line:
        print(f'{i}: {line.rstrip()[:120]}')
