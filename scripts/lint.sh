#!/bin/bash
# Lint gate — swift-format from the Xcode toolchain, config in .swift-format.
# No third-party installs.
# Usage: scripts/lint.sh          (check only)
#        scripts/lint.sh --fix    (rewrite in place, then check)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--fix" ]]; then
  xcrun swift-format format --in-place --recursive "$REPO/Sources"
fi
xcrun swift-format lint --strict --recursive "$REPO/Sources"
echo "✓ lint clean"
