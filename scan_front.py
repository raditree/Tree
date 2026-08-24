# -*- coding: utf-8 -*-
import os, re, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
pats = [r'clipboard_paste', r'已存入工作空间', r'\.input', r'attachments', r'粘贴', r'upload']
for dp, dirs, files in os.walk('lib'):
    for f in sorted(files):
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dp, f)
        lines = open(p, encoding='utf-8').read().splitlines()
        for i, ln in enumerate(lines, 1):
            if any(re.search(pt, ln) for pt in pats):
                print(f'{p}:{i}: {ln.strip()[:150]}')
