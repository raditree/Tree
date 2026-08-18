import io, sys, glob
sys.path.insert(0, 'server')

# 1) 运行模式相关：local_executor / workspace_io
for fp in ['server/core/local_executor.py', 'server/core/workspace_io.py']:
    try:
        src = io.open(fp, encoding='utf-8').read()
        print(f'===== {fp} ({len(src)} 字符) =====')
        for i, line in enumerate(src.split('\n'), 1):
            if any(k in line for k in ['class ', 'def ', 'is_local', 'mode', 'request', 'exec_', 'read_file', 'write_file', 'list_files', 'git_log']):
                print(f'{i}: {line.rstrip()[:120]}')
        print()
    except Exception as e:
        print(fp, 'ERR', e)
