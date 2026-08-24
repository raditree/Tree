# -*- coding: utf-8 -*-
import os, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
target = 'clipboard_paste_1787573548287.png'
roots = ['C:\\workspace', 'D:\\workspace', 'E:\\workspace', 'C:\\Users', 'D:\\', 'E:\\programs\\Tree']
for r in roots:
    if not os.path.isdir(r):
        continue
    for dp, dirs, files in os.walk(r):
        # 控制深度，避免全盘扫描
        depth = dp[len(r):].count(os.sep)
        if depth > 3:
            dirs[:] = []
            continue
        if target in files:
            print('FOUND:', os.path.join(dp, target))
        if depth > 3:
            break
print('done')
