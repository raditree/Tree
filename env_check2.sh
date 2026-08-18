#!/bin/bash
echo '=== git log ==='
git log --oneline -10 2>&1
echo '=== git status summary ==='
git status --short 2>&1 | head -30
echo '=== lib tree ==='
find lib -type f | head -50
echo '=== server tree ==='
find server -type f -not -path '*/node_modules/*' -not -path '*/.venv/*' | head -30
echo '=== workspaces ==='
ls -la workspaces 2>&1
echo '=== flutter version ==='
flutter --version 2>&1 | head -5
echo '=== dart version ==='
dart --version 2>&1
echo '=== pubspec ==='
cat pubspec.yaml
