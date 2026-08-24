import subprocess

CMD = 'findstr /n /c:"ThemeData" probe_ascii.txt'

# 方案1: 现状（模拟 Dart Process.run：argv 列表 → cmd /c command）
r1 = subprocess.run(['cmd', '/c', CMD], capture_output=True, text=True)
print('1 argv:/c cmd       rc=', r1.returncode, 'out=', repr(r1.stdout[:60]), 'err=', repr(r1.stderr[:60]))

# 方案2: cmd /d /s /c "command"（cmd 推荐形式：/s 修正引用规则）
r2 = subprocess.run(['cmd', '/d', '/s', '/c', '"%s"' % CMD], capture_output=True, text=True)
print('2 /d /s /c "..."     rc=', r2.returncode, 'out=', repr(r2.stdout[:60]), 'err=', repr(r2.stderr[:60]))

# 方案3: cmd /c ""command""（外层再包一层引号）
r3 = subprocess.run(['cmd', '/c', '""%s""' % CMD], capture_output=True, text=True)
print('3 /c ""cmd""        rc=', r3.returncode, 'out=', repr(r3.stdout[:60]), 'err=', repr(r3.stderr[:60]))

# 方案4: 命令本身不带引号的形式 findstr /n ThemeData（对照，已知成功）
CMD4 = 'findstr /n ThemeData probe_ascii.txt'
r4 = subprocess.run(['cmd', '/c', CMD4], capture_output=True, text=True)
print('4 无引号 对照        rc=', r4.returncode, 'out=', repr(r4.stdout[:60]), 'err=', repr(r4.stderr[:60]))

# 方案5: 直接用 cmd /c 但把双引号换成转义：\"
CMD5 = 'findstr /n /c:\\"ThemeData\\" probe_ascii.txt'
r5 = subprocess.run(['cmd', '/c', CMD5], capture_output=True, text=True)
print('5 反斜杠转义        rc=', r5.returncode, 'out=', repr(r5.stdout[:60]), 'err=', repr(r5.stderr[:60]))

# 方案6: 单引号（findstr 不认单引号，但 cmd 会保留）
CMD6 = "findstr /n /c:'ThemeData' probe_ascii.txt"
r6 = subprocess.run(['cmd', '/c', CMD6], capture_output=True, text=True)
print('6 单引号            rc=', r6.returncode, 'out=', repr(r6.stdout[:60]), 'err=', repr(r6.stderr[:60]))

# 方案7: 用 python 直接调 findstr 二进制（argv 形式，不经 cmd）
r7 = subprocess.run(['findstr', '/n', '/c:"ThemeData"', 'probe_ascii.txt'], capture_output=True, text=True)
print('7 直接 findstr argv  rc=', r7.returncode, 'out=', repr(r7.stdout[:60]), 'err=', repr(r7.stderr[:60]))
