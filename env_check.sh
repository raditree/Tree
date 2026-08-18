#!/bin/bash
echo '=== pwd ==='
pwd
echo '=== ls -la ==='
ls -la
echo '=== git status ==='
git status 2>&1 | head -20
echo '=== system ==='
uname -a
echo '=== python ==='
python3 --version 2>&1
echo '=== node ==='
node --version 2>&1
echo '=== cpu ==='
nproc
echo '=== memory ==='
free -h 2>&1 | head -3
echo '=== disk ==='
df -h 2>&1 | head -5
echo '=== done ==='
