#!/usr/bin/env bash
# Milestone QA gate (plan §9). Usage: tool/check.sh [--builds]
set -euo pipefail
cd "$(dirname "$0")/.."
fvm dart format --set-exit-if-changed .
fvm flutter analyze
fvm flutter test
if [[ "${1:-}" == "--builds" ]]; then
  fvm flutter build apk --debug
  fvm flutter build ios --simulator --no-codesign
fi
