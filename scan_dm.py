# -*- coding: utf-8 -*-
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
lines = open('server/io_/docker_manager.py', encoding='utf-8').read().splitlines()
start = None
for i, l in enumerate(lines, 1):
    if 'def write_file' in l or 'def read_file' in l or 'def _local' in l:
        print(f'--- {i}: {l.strip()}')
    if start is None and 'def write_file' in l:
        start = i
if start:
    print('\n'.join(f'{i:4}: {lines[i-1]}' for i in range(start, min(start+80, len(lines)+1))))
