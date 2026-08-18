git diff HEAD -- server/core/budget.py 2>&1 | head -80
echo ---LLM-DIFF---
git diff HEAD -- server/core/llm.py 2>&1 | head -120
echo ---DONE---