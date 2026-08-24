# -*- coding: utf-8 -*-
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
# 1) LocalExecutorClient 类主体
lines = open('server/io_/local_executor.py', encoding='utf-8').read().splitlines()
print('==== local_executor.py: 1-100 ====')
for i, l in enumerate(lines[:100], 1):
    print(f'{i:4}: {l}')
