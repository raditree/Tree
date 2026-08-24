import os, re

# 全库搜 UI 字符串字面量中含 tap/Tab 相关文案（只搜 dart 文件中的字符串常量）
roots = ['lib']
pat = re.compile(r"'([^']*[Tt]ap[^']*)'|\"([^\"]*[Tt]ap[^\"]*)\"")
hits = []
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith('.dart'):
                continue
            fp = os.path.join(dirpath, fn)
            with open(fp, encoding='utf-8', errors='replace') as f:
                for i, line in enumerate(f, 1):
                    for m in pat.finditer(line):
                        s = m.group(1) or m.group(2)
                        # 只保留像 UI 文案的（含中文或常见词）
                        if any(c in s for c in ['点击', '进度', 'Tab', 'tab', 'tap', 'Tap']):
                            hits.append(f'{fp}:{i}: {s[:80]}')
for h in hits:
    print(h)
print('TOTAL:', len(hits))
