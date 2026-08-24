# -*- coding: utf-8 -*-
import io, re
s = io.open('lib/ui/widgets/message_panel.dart', encoding='utf-8').read()
print('_firstActiveSession count:', s.count('_firstActiveSession'))
print('_restoreSession count:', s.count('_restoreSession'))
print('_lastSessionByAgent count:', s.count('_lastSessionByAgent'))
for n, l in enumerate(io.open('lib/ui/widgets/message_panel.dart', encoding='utf-8').readlines(), 1):
    if re.search(r'firstActiveSession|restoreSession|_lastSessionByAgent|会话|session', l) and 'import' not in l:
        print(f"{n}: {l.strip()[:140]}")
