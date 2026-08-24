# -*- coding: utf-8 -*-
import os, re, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
pats = [r'clipboard_paste', r'\.input', r'上传', r'粘贴', r'upload', r'paste', r'attachment']
for dp, dirs, files in os.walk('server'):
    dirs[:] = [d for d in dirs if d not in ('.git', '__pycache__', '.venv', 'node_modules')]
    for f in sorted(files):
        if not f.endswith(('.py', '.js', '.ts', '.md', '.yaml', '.yml', '.json', '.html')):
            continue
        p = os.path.join(dp, f)
        try:
            lines = open(p, encoding='utf-8').read().splitlines()
        except Exception:
            continue
        for i, ln in enumerate(lines, 1):
            if any(re.search(pt, ln) for pt in pats):
                print(f'{p}:{i}: {ln.strip()[:150]}')
