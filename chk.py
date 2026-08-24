# -*- coding: utf-8 -*-
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
lines = open('server/agent/chat.py', encoding='utf-8').read().splitlines()
for i, l in enumerate(lines, 1):
    if '_upload_attachments' in l:
        print(f'{i}: {l.strip()[:140]}')
# 确认 state 导入与 datetime 存在
for i, l in enumerate(lines[:40], 1):
    if 'import' in l and ('state' in l or 'datetime' in l or 'os' in l):
        print(f'IMP {i}: {l.strip()[:120]}')
