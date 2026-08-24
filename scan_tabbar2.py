import os

fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\tab_bar.dart'
print('exists:', os.path.exists(fp))
if not os.path.exists(fp):
    # 尝试其他路径
    for root in [r'D:\app\flutter\flutter\packages\flutter\lib\src\material']:
        for fn in os.listdir(root):
            if 'tab' in fn.lower():
                print('ALT:', os.path.join(root, fn))
else:
    with open(fp, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
    print('total lines:', len(lines))
    for i, line in enumerate(lines, 1):
        if 'TabBarDefaultsM2' in line or 'unselected' in line:
            print(f'{i}: {line.rstrip()[:130]}')
