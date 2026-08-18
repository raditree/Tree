import sys, importlib, io, os, glob

# 1) paramiko 是否可用
for lib in ['paramiko', 'asyncssh']:
    try:
        m = importlib.import_module(lib)
        print(f'{lib}: {getattr(m, "__version__", "?")} OK')
    except ImportError:
        print(f'{lib}: 未安装')

# 2) app.yaml 运行模式相关配置
for p in ['app.yaml', 'server/app.yaml']:
    if os.path.exists(p):
        d = io.open(p, encoding='utf-8').read()
        print(f'\n===== {p} (局部) =====')
        for i, line in enumerate(d.split('\n'), 1):
            if any(k in line.lower() for k in ['local', 'mode', 'ssh', 'docker', 'executor', 'base_dir']):
                print(f'{i}: {line.rstrip()[:120]}')

# 3) 前端结构（本地执行相关）
print('\n===== 前端 lib 结构 =====')
for f in sorted(glob.glob('lib/**/*.dart', recursive=True)):
    if any(k in f.lower() for k in ['local', 'executor', 'setting', 'mode', 'agent']):
        print(' ', f)
