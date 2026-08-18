#!/bin/bash
echo '=== find .self ==='
find . -maxdepth 5 -name '.self' -type d 2>/dev/null
find . -maxdepth 5 -name 'memory.md' 2>/dev/null
find . -maxdepth 5 -name 'rule.md' 2>/dev/null
find . -maxdepth 5 -name 'identity.md' 2>/dev/null
echo '=== workspaces tree ==='
ls -la workspaces 2>&1
for d in workspaces/*/; do echo "-- $d"; ls -la "$d" 2>&1 | head -20; done
echo '=== DONE ==='
