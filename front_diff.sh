git show 78750e9 --stat 2>&1 | head -25
echo ===DIFF===
git show 78750e9 -- lib/services/local_executor_service.dart 2>&1 | head -160