import subprocess

# 测试文件：含带空格字符串
with open('probe_ascii2.txt', 'w', encoding='utf-8') as f:
    f.write('hello world\n')
    f.write('"ThemeData" xyz\n')

# E: findstr /c:"hello world" —— 大众用法（含空格），看引号是否被剥离
r5 = subprocess.run(
    ['cmd', '/c', 'findstr /n /c:"hello world" probe_ascii2.txt'],
    capture_output=True, text=True)
print('E rc=', r5.returncode, 'out=', repr(r5.stdout), 'err=', repr(r5.stderr))

# F: findstr /c:"ThemeData" —— 无空格带引号
r6 = subprocess.run(
    ['cmd', '/c', 'findstr /n /c:"ThemeData" probe_ascii2.txt'],
    capture_output=True, text=True)
print('F rc=', r6.returncode, 'out=', repr(r6.stdout), 'err=', repr(r6.stderr))

# G: 与文件里 "ThemeData" 完全一致（含双引号字面）才发现匹配？先看文件内容
with open('probe_ascii2.txt', 'r', encoding='utf-8') as f:
    print('FILE CONTENT:', repr(f.read()))
