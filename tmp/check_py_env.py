import psutil, sys
try:
    p = psutil.Process(142416)
    print('后端 PID 142416 exe:', p.exe())
    print('cwd:', p.cwd())
    cmd = p.cmdline()
    print('cmdline:', cmd)
except Exception as e:
    print('psutil err:', e)
# 尝试后端工作目录的 python 环境
import subprocess, os
for py in [sys.executable]:
    r = subprocess.run([py, '-c', 'import paramiko; print("paramiko", paramiko.__version__)'], capture_output=True, text=True)
    print(f'{py}: {r.stdout.strip() or r.stderr.strip()}')
