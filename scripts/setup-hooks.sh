#!/usr/bin/env bash
set -euo pipefail

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push

echo "✓ Git hooks installed (.githooks/)"
echo "  pre-commit: swiftlint + swiftformat --lint"
echo "  pre-push:   swift build + swift test"
