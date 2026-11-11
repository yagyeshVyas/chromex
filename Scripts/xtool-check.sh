#!/usr/bin/env bash
# Stage 1 gate: verify the Windows/WSL toolchain xtool needs.
# Usage: bash Scripts/xtool-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { printf '%s\n' "$*"; }
bad() { printf 'BLOCKER: %s\n' "$*" >&2; fail=1; }

note "== host =="
note "kernel: $(uname -srm)"
note "distro: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"

note ""
note "== swift =="
if command -v swift >/dev/null 2>&1; then
  note "$(swift --version 2>&1 | head -3 | tr '\n' ' ')"
else
  bad "swift not on PATH (xtool requires the Swift 6.4 toolchain)"
fi

note ""
note "== xtool =="
if command -v xtool >/dev/null 2>&1; then
  note "binary: $(command -v xtool)"
  note "version: $(xtool --version 2>&1 | head -1)"
else
  bad "xtool not on PATH — install from https://github.com/xtool-org/xtool/releases"
fi

note ""
note "== Darwin Swift SDK =="
SDK_STATUS="$(xtool sdk status 2>&1 || true)"
note "$SDK_STATUS"
if printf '%s' "$SDK_STATUS" | grep -qi 'not installed'; then
  bad "xtool's Darwin Swift SDK is not installed; nothing can be compiled for iOS."
  note "Fix (one time, needs an Apple ID and ~10-15 GB download):"
  note "  1. Download Xcode from https://developer.apple.com/download/all/?q=Xcode"
  note "  2. xtool sdk install /path/to/Xcode.xip --slim"
  note "Docs: https://xtool.sh/documentation/xtool/installation-linux"
fi

note ""
note "== package =="
if [ -f Package.swift ]; then
  if swift package dump-package >/dev/null 2>&1; then
    note "Package.swift: valid"
  else
    bad "Package.swift is present but SwiftPM cannot parse it"
  fi
else
  bad "Package.swift missing"
fi
[ -f xtool.yml ] && note "xtool.yml: present" || bad "xtool.yml missing"

note ""
note "== scripts =="
for script in Scripts/xtool-build.sh Scripts/verify_ipa.sh Scripts/set_bundle_id.sh; do
  [ -f "$script" ] && note "$script: present" || bad "$script missing"
done

note ""
if [ "$fail" -eq 0 ]; then
  note "READY: xtool can build this project."
else
  note "NOT READY: resolve the blockers above, then re-run this script."
fi
exit "$fail"
