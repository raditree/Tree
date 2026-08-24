# -*- coding: utf-8 -*-
import os, re, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
pat = re.compile(r'_buildAvatar|CircleAvatar|boxShape: BoxShape|头像')
for dp, dirs, files in os.walk('lib'):
    for f in sorted(files):
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dp, f)
        lines = open(p, encoding='utf-8').read().splitlines()
        for i, ln in enumerate(lines, 1):
            if pat.search(ln):
                print(f'{p}:{i}: {ln.strip()[:130]}')
