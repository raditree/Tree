import subprocess

# bat 方案：把命令原样写入 .bat，然后 cmd /c 执行 bat 文件
bat = 'findstr /n /c:"ThemeData" probe_ascii.txt'
with open('probe_run.bat', 'w', encoding='utf-8') as f:
    f.write('@echo off\r\n')
    f.write(bat + '\r\n')

r_bat = subprocess.run(['cmd', '/c', 'probe_run.bat'], capture_output=True, text=True)
print('BAT rc=', r_bat.returncode, 'out=', repr(r_bat.stdout[:80]), 'err=', repr(r_bat.stderr[:80]))

# 对照：交互式 cmd 直接输入同样命令（模拟真实用户 shell）
r_interactive = subprocess.run(
    ['cmd', '/c', r'findstr /n /c:"ThemeData" probe_ascii.txt'],
    capture_output=True, text=True)
print('INTERACTIVE-like rc=', r_interactive.returncode, 'out=', repr(r_interactive.stdout[:80]), 'err=', repr(r_interactive.stderr[:80]))
