fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\tabs.dart'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
# TabBarDefaultsM2 定义附近（1880-1930）
for i in range(1870, 1935):
    print(f'{i}: {lines[i-1].rstrip()[:150]}')
