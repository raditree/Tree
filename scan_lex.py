# -*- coding: utf-8 -*-
import os, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
pat = ('register_local_executor', 'base_dir', 'baseDir', 'local_executor', 'LocalExecutor', 'base_dir')
for root in ('server',):
    for dp, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('.git', '__pycache__', '.venv', 'node_modules', 'logs', 'data')]
        for f in sorted(files):
            if not f.endswith('.py'):
                continue
            p = os.path.join(dp, f)
            try:
                lines = open(p, encoding='utf-8').read().splitlines()
            except Exception:
                continue
            for i, ln in enumerate(lines, 1):
                if any(k in ln for k in ('register_local_executor', 'base_dir', 'baseDir', 'local_executor')):
                    print(f'{p}:{i}: {ln.strip()[:150]}')
