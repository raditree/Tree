fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\theme_data.dart'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
for i in range(490, 530):
    print(f'{i}: {lines[i-1].rstrip()[:150]}')
