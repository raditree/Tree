import io
for fp in ['lib/services/local_executor_service.dart', 'lib/pages/settings_page.dart']:
    try:
        src = io.open(fp, encoding='utf-8').read()
        print(f'===== {fp} ({len(src)} 字符) =====')
        for i, line in enumerate(src.split('\n'), 1):
            if any(k in line for k in ['class ', 'register', 'unregister', 'is_local', 'baseDir', 'base_dir', 'WebSocket', 'sendMessage', '_resolveWorkspace', 'Future<']):
                print(f'{i}: {line.rstrip()[:130]}')
        print()
    except Exception as e:
        print(fp, 'ERR', e)
