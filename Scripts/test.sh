#!/bin/bash
# Builds the HTTP example binary the example tests need, then runs the full test suite.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swift test "$@"
