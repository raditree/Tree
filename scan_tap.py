import os, re

# 扫描 message_list.dart / message_panel.dart 中与 tap/提示/复制 相关的文案
for fn in ['lib/ui/widgets/message_list.dart', 'lib/ui/widgets/message_panel.dart',
           'lib/ui/widgets/teammates_window_page.dart']:
    if not os.path.exists(fn):
        print(f'--- {fn} NOT FOUND')
        continue
    print(f'--- {fn}')
    with open(fn, encoding='utf-8') as f:
        for i, line in enumerate(f, 1):
            low = line.lower()
            if any(k in low for k in ['tap', '顶部', '点击', '复制', '提示', 'copy', 'tip', 'tooltip']):
                print(f'{i}: {line.rstrip()[:120]}')
