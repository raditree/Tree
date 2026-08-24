import os

# 查 flutter SDK 位置：从常见环境推断
paths = [
    r'C:\flutter\bin\flutter.bat',
    r'C:\src\flutter\bin\flutter.bat',
    r'D:\flutter\bin\flutter.bat',
    r'E:\flutter\bin\flutter.bat',
    r'C:\Users\Administrator\flutter\bin\flutter.bat',
]
for p in paths:
    if os.path.exists(p):
        print('FOUND:', p)
# 也看看 flutter 环境文件
for p in [r'C:\flutter', r'D:\flutter', r'E:\flutter']:
    if os.path.exists(p):
        print('DIR:', p, os.listdir(p)[:10])
