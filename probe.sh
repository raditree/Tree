#!/bin/bash
echo '=== server py files ==='
find server -type f -name '*.py' | head -60
echo '=== server tools/mcp dirs ==='
ls server/tools 2>&1
ls server/mcp_tools 2>&1
ls server/core 2>&1
echo '=== lib dart files ==='
find lib -type f -name '*.dart' | head -40
echo '=== tests ==='
find server/tests -type f 2>/dev/null | head -20
echo '=== requirements ==='
head -40 server/requirements.txt 2>/dev/null
echo '=== main.py head ==='
head -30 server/main.py 2>/dev/null
echo '=== DONE ==='
