git log --oneline -15 2>&1
echo ---STATUS---
git status --short 2>&1 | head -30
echo ---DIFF-LLM---
git diff --stat HEAD -- server/core/llm.py server/core/budget.py 2>&1
echo ---DONE---