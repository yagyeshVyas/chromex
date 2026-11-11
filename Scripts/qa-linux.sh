#!/usr/bin/env bash
# Runs the Linux QA harness: real parser/analyzer checks plus benchmarks.
# Usage: bash Scripts/qa-linux.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found; install the Swift toolchain" >&2
  exit 1
fi

python3 Scripts/make_fixtures.py

mkdir -p .build/qa
swiftc -O \
  Sources/CHROMEX/Core/Models.swift \
  Sources/CHROMEX/Core/URLResolver.swift \
  Sources/CHROMEX/Core/ExtensionManifest.swift \
  Sources/CHROMEX/Core/AdBlockRules.swift \
  QA/harness/main.swift \
  -o .build/qa/chromex-qa

.build/qa/chromex-qa
