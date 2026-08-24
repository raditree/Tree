fp = r'D:\app\flutter\flutter\packages\flutter\lib\src\material\theme_data.dart'
with open(fp, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
# 看 560-600 行附近的 defaultPrimaryTextTheme 定义
for i in range(540, 610):
    print(f'{i}: {lines[i-1].rstrip()[:140]}')
