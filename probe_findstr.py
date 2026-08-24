import subprocess

# A: findstr /n /c:"ThemeData" （带双引号）
r1 = subprocess.run(
    ['cmd', '/c', 'findstr /n /c:"ThemeData" probe_ascii.txt'],
    capture_output=True, text=True)
print('A rc=', r1.returncode, 'out=', repr(r1.stdout), 'err=', repr(r1.stderr))

# B: findstr /n ThemeData （无引号）
r2 = subprocess.run(
    ['cmd', '/c', 'findstr /n ThemeData probe_ascii.txt'],
    capture_output=True, text=True)
print('B rc=', r2.returncode, 'out=', repr(r2.stdout), 'err=', repr(r2.stderr))

# C: 直接执行 findstr（不经 cmd /c）
r3 = subprocess.run(
    ['findstr', '/n', '/c:"ThemeData"', 'probe_ascii.txt'],
    capture_output=True, text=True)
print('C rc=', r3.returncode, 'out=', repr(r3.stdout), 'err=', repr(r3.stderr))

# D: findstr /c:ThemeData（无引号单一字符串）
r4 = subprocess.run(
    ['findstr', '/n', '/c:ThemeData', 'probe_ascii.txt'],
    capture_output=True, text=True)
print('D rc=', r4.returncode, 'out=', repr(r4.stdout), 'err=', repr(r4.stderr))
