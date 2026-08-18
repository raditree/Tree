import io, os
# 查看 flutter_01.log 尾部（可能是后端启动日志）
p = r'flutter_01.log'
if os.path.exists(p):
    d = io.open(p, encoding='utf-8', errors='replace').read()
    lines = d.split('\n')
    print(f'总行数: {len(lines)}, 总字符: {len(d)}')
    # 找关键关键词
    for i, ln in enumerate(lines):
        if any(k in ln for k in ['本地 WorkspaceIO', '回退', 'read_file', 'extra_info', 'help', 'WorkspaceIO', 'memory', 'is_local', 'Uvicorn', 'Started server', 'Application startup']):
            print(f'{i+1}: {ln.rstrip()[:160]}')
    print('\n--- 最后 30 行 ---')
    for ln in lines[-30:]:
        print(ln.rstrip()[:160])
else:
    print('文件不存在')
