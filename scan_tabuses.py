import os

# 全库找 TabBar 使用位置
for root in ['lib']:
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            with open(fp, encoding='utf-8', errors='replace') as f:
                for i, line in enumerate(f, 1):
                    if 'TabBar' in line or 'DefaultTabController' in line or 'Tab(' in line:
                        print(f'{fp}:{i}: {line.strip()[:110]}')
